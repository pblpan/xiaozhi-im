package com.example.xiaozhi_im_client

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.util.DisplayMetrics
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import kotlin.math.roundToInt

/**
 * 远程协助「被控端」的**输入执行器**（Android）。
 *
 * ─────────────────────────────────────────────────────────────
 * 为什么必须是无障碍服务
 * ─────────────────────────────────────────────────────────────
 * Android 从设计上禁止普通 App 伪造触摸事件 —— 那条口子一旦开放，
 * 恶意 App 就能自我点击广告、也能在用户不知情时替他点"确认付款"。
 * 唯一合法的通路是面向辅助功能开放的 `AccessibilityService#dispatchGesture`。
 * 所以用户会先在系统设置里看到一个"是否允许这个辅助功能"的开关，
 * 那不是我们绕不过去的坑，是 Android 有意设的关卡 —— 这个能力本来就
 * 应该由用户亲手交出来。
 *
 * 这也是"电脑能控手机"之前唯一缺的一环：屏幕采集（MediaProjection）早就
 * 能拿到画面，但触摸注入一直是空的，控制端发出的点击全都掉在地上。
 *
 * ─────────────────────────────────────────────────────────────
 * 坐标为什么必须在这一层换算
 * ─────────────────────────────────────────────────────────────
 * 控制端发过来的是**归一化 0..1**（它看到的画面尺寸 ≠ 本机的真实分辨率）。
 * 换算成像素必须发生在被控端，因为只有被控端知道自己屏幕到底多大；
 * 而且必须是 **getRealMetrics 那套真实像素** —— 采集（MediaProjection）抓的
 * 就是整块真实屏幕（含导航栏），用带导航栏扣除的那套尺寸会让点击整体偏移。
 */
class RemoteInputService : AccessibilityService() {

    /** 手指按下的可见时长。太短（<50ms）部分机型会当成无效手势直接丢掉。 */
    private val tapMs = 60L
    private val longPressMs = 700L

    private var connected = false

    override fun onServiceConnected() {
        super.onServiceConnected()
        connected = true
        instance = this
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        connected = false
        if (instance === this) instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        connected = false
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onInterrupt() {}
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    val isConnected: Boolean
        get() = connected

    // ------------------------------------------------------------ 尺寸

    /**
     * 真实屏幕像素。刻意用 getRealMetrics 而不是 Resources.getSystem()：
     * 后者在部分机型上会扣掉导航栏高度，与采集到的画面不是同一套坐标系，
     * 结果是"点在标题栏、实际落到状态栏下面一点"。
     */
    @Suppress("DEPRECATION")
    private fun screenSize(): Pair<Int, Int> {
        val dm = DisplayMetrics()
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        // API 30 起 getRealMetrics 被标 deprecated（推荐 currentWindowMetrics），
        // 但后者给的是**应用窗口**的边界（会扣掉系统装饰），
        // 而 MediaProjection 抓的是整块真实屏幕 —— 两者不是同一套坐标系。
        // 这里要的就是真实屏幕，所以坚持用 getRealMetrics。
        wm.defaultDisplay.getRealMetrics(dm)
        return dm.widthPixels to dm.heightPixels
    }

    private fun px(nx: Float, ny: Float): Pair<Float, Float> {
        val (w, h) = screenSize()
        return (nx * w) to (ny * h)
    }

    // ------------------------------------------------------------ 手势

    private fun dispatch(path: Path, durationMs: Long, startMs: Long = 0): Boolean {
        return try {
            val stroke = GestureDescription.StrokeDescription(path, startMs, durationMs)
            dispatchGesture(
                GestureDescription.Builder().addStroke(stroke).build(),
                null,
                null,
            )
        } catch (e: Exception) {
            false
        }
    }

    /**
     * 单击。
     *
     * ⚠️ 路径必须有**两个点**（moveTo + lineTo 到同一处）。只有一个 moveTo 的
     *    Path 在部分机型上会被判成"空路径"直接丢弃 —— 表现是"点击完全没反应"。
     */
    fun tap(nx: Float, ny: Float): Boolean {
        val (x, y) = px(nx, ny)
        val path = Path().apply { moveTo(x, y); lineTo(x, y) }
        return dispatch(path, tapMs)
    }

    fun longPress(nx: Float, ny: Float): Boolean {
        val (x, y) = px(nx, ny)
        val path = Path().apply { moveTo(x, y); lineTo(x, y) }
        return dispatch(path, longPressMs)
    }

    /** 拖动（含拖拽选中、下拉刷新都靠它）。坐标全部是归一化的。 */
    fun drag(
        nx1: Float, ny1: Float,
        nx2: Float, ny2: Float,
        durationMs: Long,
    ): Boolean {
        val (x1, y1) = px(nx1, ny1)
        val (x2, y2) = px(nx2, ny2)
        val path = Path().apply { moveTo(x1, y1); lineTo(x2, y2) }
        return dispatch(path, durationMs.coerceIn(50, 2000))
    }

    /**
     * 滚动。delta 为正 = 向上滚（与桌面滚轮方向一致）。
     *
     * 手势是"从屏幕下半部往上划"，起点刻意不取正中：
     * 正中常常正好压着列表项，会先触发一次误点击。
     */
    fun scroll(nx: Float, ny: Float, delta: Int): Boolean {
        val (x, y) = px(nx, ny)
        val (_, h) = screenSize()
        // 一格 ≈ 屏幕高度的 18%，与常见列表一屏能滚的幅度接近
        val dist = (h * 0.18f * delta.coerceIn(-3, 3)).roundToInt().toFloat()
        val y1 = (y + dist / 2).coerceIn(0f, h.toFloat())
        val y2 = (y - dist / 2).coerceIn(0f, h.toFloat())
        val path = Path().apply { moveTo(x, y1); lineTo(x, y2) }
        return dispatch(path, 220)
    }

    // ------------------------------------------------------------ 系统键

    /** 返回 / 主页 / 最近任务。这三样在手机上就是导航栏那三个键。 */
    fun globalAction(action: Int): Boolean = performGlobalAction(action)

    // ------------------------------------------------------------ 文字

    /**
     * 当前获得输入焦点的可编辑节点。
     *
     * 不能只信 rootInActiveWindow.findFocus：部分 App（尤其自绘输入框）不给
     * 焦点标记，findFocus 会返回 null —— 那时退一步遍历整棵树找第一个可编辑的。
     */
    private fun findEditable(): AccessibilityNodeInfo? {
        val root = rootInActiveWindow ?: return null
        val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (focused != null && focused.isEditable) return focused
        return findEditableIn(root)
    }

    private fun findEditableIn(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (node.isEditable) return node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val hit = findEditableIn(child)
            if (hit != null) return hit
            child.recycle()
        }
        return null
    }

    /**
     * 在光标处插一个字符。
     *
     * 为什么不用"逐字符按键事件"：Android 上普通 App 发不出按键注入，
     * 而 ACTION_SET_TEXT 是无障碍给的正路。它的语义是**替换整段文本**，
     * 所以必须先读出当前内容、拼好、再整体写回，否则打第二个字会把第一个字冲掉。
     * 写完还要把光标挪到新字符后面，不然下一个字会插到串尾（中文输入时很明显）。
     */
    fun typeChar(text: String): Boolean {
        if (text.isEmpty()) return false
        val node = findEditable() ?: return false
        return try {
            val cur = node.text?.toString() ?: ""
            val end = if (node.textSelectionEnd >= 0) node.textSelectionEnd else cur.length
            val start = if (node.textSelectionStart >= 0) node.textSelectionStart else end
            val lo = minOf(start, end)
            val hi = maxOf(start, end)
            val next = cur.substring(0, lo) + text + cur.substring(minOf(hi, cur.length))
            val args = Bundle().apply {
                putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                    next,
                )
            }
            if (!node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) false
            else {
                val pos = lo + text.length
                val sel = Bundle().apply {
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, pos)
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, pos)
                }
                node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, sel)
                true
            }
        } catch (e: Exception) {
            false
        }
    }

    /**
     * 回车。交给 IME 处理（在手机上是"提交/换行"，各 App 自己解释）。
     *
     * ACTION_IME_ENTER 是 API 30 才有的；老机型上退一步直接把换行写进文本 ——
     * 那在搜索框里等于"换行而不搜索"，体验差一档，但总比什么都不做强。
     */
    fun enter(): Boolean {
        val node = findEditable() ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return try {
                node.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
            } catch (e: Exception) {
                typeChar("\n")
            }
        }
        return typeChar("\n")
    }

    /** 退格：删掉光标前的一个字符（有选区就删掉选区）。 */
    fun backspace(): Boolean {
        val node = findEditable() ?: return false
        return try {
            val cur = node.text?.toString() ?: ""
            val end = if (node.textSelectionEnd >= 0) node.textSelectionEnd else cur.length
            val start = if (node.textSelectionStart >= 0) node.textSelectionStart else end
            val lo = minOf(start, end)
            val hi = maxOf(start, end)
            val delFrom = if (hi > lo) lo else (lo - 1).coerceAtLeast(0)
            val next = cur.substring(0, delFrom) + cur.substring(minOf(hi, cur.length))
            val args = Bundle().apply {
                putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                    next,
                )
            }
            if (!node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) false
            else {
                val sel = Bundle().apply {
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, delFrom)
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, delFrom)
                }
                node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, sel)
                true
            }
        } catch (e: Exception) {
            false
        }
    }

    companion object {
        /// 与 Dart 侧 core/remote_input.dart 的通道名必须逐字一致
        /// （写错 = 点"去开启"毫无反应，且不报错）
        const val CHANNEL = "xiaozhi/remote_input"

        /**
         * 服务实例。无障碍服务与 App 同进程，所以静态引用是安全的 ——
         * 也是把 Dart 的方法调用接到服务上的唯一直接办法
         * （服务由系统 bind，拿不到它的 Binder 句柄）。
         */
        @Volatile
        private var instance: RemoteInputService? = null

        /** 服务是否已连上（= 用户在系统设置里把它打开了） */
        fun isConnected(): Boolean = instance?.isConnected == true

        // ---- 下面这些全部是"转发给服务实例"。
        //      服务没开时一律返回 false（而不是抛异常）——
        //      Dart 侧据此如实告诉用户"还没开"，绝不能假装成功。
        //      ⚠️ 返回布尔值是刻意的：dispatchGesture 本身是异步的，
        //         它的回调里拿不到可靠结果（null 回调时系统只保证"已收到"）。
        //         所以这里表达的是"这条指令是否真的被交给了系统"，
        //         而不是"手势是否已经画完" —— 别把 false 当成"点击失败了"。

        fun tap(nx: Float, ny: Float) = instance?.tap(nx, ny) ?: false

        fun longPress(nx: Float, ny: Float) = instance?.longPress(nx, ny) ?: false

        fun drag(nx1: Float, ny1: Float, nx2: Float, ny2: Float, ms: Long) =
            instance?.drag(nx1, ny1, nx2, ny2, ms) ?: false

        fun scroll(nx: Float, ny: Float, delta: Int) =
            instance?.scroll(nx, ny, delta) ?: false

        fun global(action: Int) = instance?.globalAction(action) ?: false

        fun enter() = instance?.enter() ?: false

        fun typeChar(text: String) = instance?.typeChar(text) ?: false

        fun backspace() = instance?.backspace() ?: false
    }
}
