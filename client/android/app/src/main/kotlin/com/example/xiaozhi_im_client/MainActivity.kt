package com.example.xiaozhi_im_client

import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 系统「分享到小智IM」的接入口。
 *
 * 为什么这段必须在原生做、不能交给纯 Dart：
 * 相册 / 文件管理器分享出来的**不是文件路径**，而是 `content://...` 这种虚拟地址 ——
 * 它由某个 App 的 ContentProvider 提供，只有拿得到 ContentResolver 的进程才读得了。
 * Dart 侧 `File(path)` 打开这种地址必然失败。所以"把字节流拷成本地文件"只能在原生完成，
 * 拷完再把**普通文件路径**交给 Dart，上传链路就能直接复用聊天页那一套（不重复实现）。
 *
 * 两条入口都要覆盖，缺一条就会出现"有时候能分享、有时候点了没反应"：
 *   · 冷启动 —— App 没开，用户在相册点分享把 App 拉起来 → onCreate 时 intent 就是 SEND，
 *                等 Dart 来问（getInitialShare）时再拷贝
 *   · 热启动 —— App 已在后台/前台，用户又分享一次 → 走 onNewIntent，主动推给 Dart
 */
class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch

        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                // 冷启动那一份。拷贝几十 MB 的图会卡住主线程，所以丢后台线程做；
                // 但 result 的回复必须回主线程 —— platform channel 不允许跨线程回。
                "getInitialShare" -> {
                    // 变量名刻意不叫 it：Thread { } 是无参 lambda，里面写 it 时读到的
                    // 究竟是"隐式参数"还是外层这个局部变量，全凭作用域规则解释。
                    // 本机没法编译验证，不值得在这种地方省几个字母。
                    val share = intent
                    if (!isShare(share)) {
                        // 正常点图标启动：明确回 null，Dart 才知道"不用弹发送页"。
                        // 这里若不回、只挂起，App 会卡在等回复上。
                        result.success(null)
                    } else {
                        Thread {
                            val payload = collect(share!!)
                            runOnUiThread { result.success(payload) }
                        }.start()
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // 必须存下来：getInitialShare 读的就是这份 intent，
        // 不 setIntent 的话"分享进来后又被重建"会读到上一次的旧数据。
        setIntent(intent)
        if (!isShare(intent)) return
        Thread {
            val payload = collect(intent)
            // invokeMethod 只能在主线程调，这里必须切回去
            runOnUiThread { channel?.invokeMethod("onShare", payload) }
        }.start()
    }

    private fun isShare(i: Intent?): Boolean {
        val a = i?.action ?: return false
        return a == Intent.ACTION_SEND || a == Intent.ACTION_SEND_MULTIPLE
    }

    /** 把这次分享收拾成 Dart 好读的形状：{files: [{path,name,mime,size}], text: "..."} */
    private fun collect(i: Intent): Map<String, Any?> {
        val files = ArrayList<Map<String, Any?>>()
        for (u in streamUris(i)) {
            val f = copyInto(u) ?: continue
            files.add(
                mapOf(
                    "path" to f.absolutePath,
                    "name" to (displayName(u) ?: f.name),
                    "mime" to (contentResolver.getType(u) ?: ""),
                    "size" to f.length(),
                )
            )
        }
        // 纯文字分享（浏览器/备忘录里"分享这段文字"）：没有附件，就把文字带回去，
        // Dart 侧预填到输入框，用户直接选人发送。
        val text = i.getStringExtra(Intent.EXTRA_TEXT) ?: ""
        return mapOf("files" to files, "text" to text)
    }

    /**
     * 取出这次分享带的附件地址。
     *
     * 优先看 ClipData：不少国产相册 / 第三方 App 分享时**只填 ClipData 不填 EXTRA_STREAM**，
     * 只读 EXTRA_STREAM 会得到一次"空分享"—— 界面弹出来了但一个文件都没有，
     * 用户只会觉得"小智分享是坏的"。
     */
    private fun streamUris(i: Intent): List<Uri> {
        val out = ArrayList<Uri>()
        i.clipData?.let { cd ->
            for (k in 0 until cd.itemCount) {
                val u = cd.getItemAt(k).uri ?: continue
                if (isReadable(u)) out.add(u)
            }
        }
        if (out.isNotEmpty()) return out

        @Suppress("DEPRECATION")
        when (i.action) {
            Intent.ACTION_SEND_MULTIPLE ->
                i.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                    ?.forEach { if (isReadable(it)) out.add(it) }

            Intent.ACTION_SEND ->
                i.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                    ?.let { if (isReadable(it)) out.add(it) }
        }
        return out
    }

    /** 只认真正能读的文件地址：分享网页时 ClipData 里会塞一条 http:// ，拷它是白费劲 */
    private fun isReadable(u: Uri): Boolean {
        val s = u.scheme ?: return false
        return s == "content" || s == "file"
    }

    /** 把 content:// 的字节流落到应用缓存目录，返回落地后的文件；失败返回 null。 */
    private fun copyInto(u: Uri): File? {
        return try {
            val dir = File(cacheDir, "share_in").apply { mkdirs() }
            // 加时间戳前缀：连发两张都叫 10086.jpg 时不会互相覆盖
            var base = (displayName(u) ?: "share").replace(Regex("[\\\\/:*?\"<>|]"), "_")
            if (base.length > 80) base = base.takeLast(80) // 保留尾部，扩展名不会丢
            val f = File(dir, "${System.currentTimeMillis()}_$base")
            contentResolver.openInputStream(u)?.use { input ->
                f.outputStream().use { input.copyTo(it) }
            } ?: return null

            if (f.length() == 0L) {
                // 有的 App 给的是已失效的地址：能打开但读不到字节。留个空文件只会让
                // 用户看到"发送失败"却不知为何，直接丢掉更干净。
                f.delete()
                null
            } else {
                f
            }
        } catch (e: Exception) {
            // 单个文件读不出来不该拖垮整次分享：跳过它，其余照发
            null
        }
    }

    /** 附件的原始文件名（相册里的 10086.jpg 全靠它保留） */
    private fun displayName(u: Uri): String? {
        if (u.scheme != "content") return u.lastPathSegment
        return try {
            contentResolver.query(
                u, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null
            )?.use { c ->
                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && c.moveToFirst()) c.getString(idx) else null
            }
        } catch (e: Exception) {
            null
        }
    }

    companion object {
        /// 与 Dart 侧 ShareIntake 的通道名必须逐字一致（写错 = 分享进来毫无反应）
        private const val CHANNEL = "xiaozhi/share"
    }
}
