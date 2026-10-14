package com.example.xiaozhi_im_client

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
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

    /// 通知通道（原生 → Dart 的点击回调用它，别和分享那个混）
    private var notifyChannel: MethodChannel? = null

    /// 蓝牙打印机。持有 Activity 引用（要申请运行时权限），所以在这里建。
    private val btPrinter: BluetoothPrinter by lazy { BluetoothPrinter(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch

        // 新消息通知 / 图标角标。通道名与 Dart 侧 core/notifier.dart 的
        // 'xiaozhi/notify' 必须逐字一致（写错 = 通知静默失效，且不报错）。
        MessageNotifier.init(applicationContext)
        MessageNotifier.bindActivity(this)
        // 冷启动：App 没活进程，用户点通知把它拉起来 → intent 在 onCreate 就到了，
        // 但那时 Dart 还没接上通道。先存进 pendingTapConv，等 Dart 来问
        // （getInitialNotification）时再取走 —— 与 getInitialShare 同一套路。
        MessageNotifier.onNotificationIntent(intent)
        notifyChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, MessageNotifier.CHANNEL
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MessageNotifier.CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 申请通知权限（Android 13+ 弹系统窗）。异步，返回"当前是否已授权"。
                    "ensurePermission" -> result.success(MessageNotifier.ensurePermission())
                    "hasPermission" -> result.success(MessageNotifier.hasPermission())
                    "showMessage" -> {
                        val conv = call.argument<Int>("conversationId") ?: 0
                        val title = call.argument<String>("title") ?: "新消息"
                        val body = call.argument<String>("body") ?: ""
                        val number = call.argument<Int>("number") ?: 1
                        // Dart 传 "alert"/"quiet"：后台到达要震+弹条，前台只更新角标
                        val alert = (call.argument<String>("mode") ?: "alert") == "alert"
                        if (conv <= 0) {
                            result.error("bad_args", "conversationId 缺失", null)
                        } else {
                            MessageNotifier.showMessage(conv, title, body, number, alert)
                            result.success(true)
                        }
                    }
                    "cancelFor" -> {
                        MessageNotifier.cancelFor(call.argument<Int>("conversationId") ?: 0)
                        result.success(true)
                    }
                    "cancelAll" -> {
                        MessageNotifier.cancelAll()
                        result.success(true)
                    }
                    // 冷启动时先到的通知点击：Dart 接上通道后来问一次
                    "getInitialNotification" ->
                        result.success(MessageNotifier.consumePendingTap())
                    else -> result.notImplemented()
                }
            }

        // 蓝牙价签 / 标签机。经典蓝牙 SPP，见 BluetoothPrinter.kt。
        // 通道名与 Dart 侧 core/bt_printer.dart 的 'xiaozhi/btprint' 必须逐字一致。
        // 写字节要走 socket，不能在主线程跑 —— 交给 BluetoothPrinter 自己开线程。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BT_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ensurePermission" -> result.success(btPrinter.ensurePermission())
                    "listPaired" -> result.success(btPrinter.listPaired())
                    "connect" -> {
                        val addr = call.argument<String>("address")
                        if (addr == null) {
                            result.error("BAD_ARG", "缺 address", null)
                        } else {
                            try {
                                btPrinter.connect(addr)
                                result.success(true)
                            } catch (e: BluetoothPrinterException) {
                                result.error(e.code, e.message, null)
                            }
                        }
                    }
                    "write" -> {
                        val addr = call.argument<String>("address")
                        val bytes = call.argument<ByteArray>("bytes")
                        if (addr == null || bytes == null) {
                            result.error("BAD_ARG", "缺 address 或 bytes", null)
                        } else {
                            try {
                                btPrinter.write(bytes)
                                result.success(true)
                            } catch (e: BluetoothPrinterException) {
                                result.error(e.code, e.message, null)
                            }
                        }
                    }
                    "disconnect" -> {
                        btPrinter.disconnect()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // 包完整性自校验：读本 APK 的签名证书指纹，与内置官方指纹比对。
        // 同步返回 —— 读 PackageManager 是内存操作，不值得为它开线程。
        // 通道名与 Dart 侧 core/integrity.dart 的 'xiaozhi/guard' 必须逐字一致。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, GUARD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkIntegrity" -> result.success(AppIntegrity.check(applicationContext))
                    else -> result.notImplemented()
                }
            }

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

                // 出站：把本地导出的账（.txt/.csv）直接甩给系统分享面板，
                // 用户选微信/企微/钉钉/本 App 就能直接发给同事，
                // 不用先"另存为"再自己找文件。
                "shareFile" -> {
                    val path = call.argument<String>("path")
                    val mime = call.argument<String>("mime") ?: "*/*"
                    val subject = call.argument<String>("subject") ?: ""
                    if (path.isNullOrBlank()) {
                        result.error("bad_args", "缺少 path", null)
                    } else {
                        // 拉分享面板是 UI 动作，必须在主线程
                        runOnUiThread {
                            result.success(shareFile(path, mime, subject))
                        }
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    /**
     * 把本地文件经 FileProvider 转成 content:// 后拉系统分享面板。
     *
     * 返回值是**给用户看的失败原因**，成功返回空串 —— 与 Dart 侧
     * FileIo.open() 的约定保持一致（空 = 成功），免得两套约定混用。
     */
    private fun shareFile(path: String, mime: String, subject: String): String {
        val f = File(path)
        if (!f.exists() || f.length() == 0L) return "文件不存在或为空"
        return try {
            val uri: Uri = FileProvider.getUriForFile(
                this, "$packageName.sharefiles", f
            )
            val send = Intent(Intent.ACTION_SEND).apply {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
                if (subject.isNotEmpty()) putExtra(Intent.EXTRA_SUBJECT, subject)
                // 只授读权限：对方能读我们这一个文件，改不了、也拿不到别的
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }

            // ⚠️ 不少国产 App 不声明 text/csv 这类具体 mime，只认 */*。
            //    直接拿 text/csv 去 chooser 会出现"分享面板是空的"，
            //    现象很像"分享坏了"。所以先看有没有 App 认这个具体类型，
            //    没有就退到 */*。resolveActivity 必须带 MATCH_DEFAULT_ONLY，
            //    否则会把只有 intent-filter 没 DEFAULT 的条目也算进来。
            val probes = Intent(Intent.ACTION_SEND).apply { type = mime }
            val handled = packageManager.resolveActivity(
                probes, PackageManager.MATCH_DEFAULT_ONLY
            ) != null
            if (!handled) send.type = "*/*"

            val chooser = Intent.createChooser(send, "发给同事").apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(chooser)
            ""
        } catch (e: IllegalArgumentException) {
            // FileProvider 没覆盖到这个路径时会抛这个 —— 是配置问题，得明说
            "分享失败：文件不在可分享目录内（$e）"
        } catch (e: Exception) {
            "分享失败：$e"
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // 必须存下来：getInitialShare 读的就是这份 intent，
        // 不 setIntent 的话"分享进来后又被重建"会读到上一次的旧数据。
        setIntent(intent)
        if (!isShare(intent)) {
            // 不是分享，就看是不是通知栏点进来的
            val conv = MessageNotifier.onNotificationIntent(intent)
            if (conv > 0) {
                notifyChannel?.invokeMethod("onNotificationTap", conv)
            }
            return
        }
        Thread {
            val payload = collect(intent)
            // invokeMethod 只能在主线程调，这里必须切回去
            runOnUiThread { channel?.invokeMethod("onShare", payload) }
        }.start()
    }

    /// 通知权限弹窗的结果。异步回来，推给 Dart 记着（拒了要给用户一句提示）
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == MessageNotifier.REQ_POST_NOTIFICATIONS) {
            val ok = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            notifyChannel?.invokeMethod("permissionResult", ok)
        }
    }

    override fun onDestroy() {
        // 防泄漏：Activity 销毁后不再持着它（通知权限弹窗要用）
        MessageNotifier.bindActivity(null)
        super.onDestroy()
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

        /// 与 Dart 侧 core/integrity.dart 的通道名必须逐字一致（写错 = 校验静默失效）
        private const val GUARD_CHANNEL = "xiaozhi/guard"

        /// 与 Dart 侧 core/bt_printer.dart 的通道名必须逐字一致
        /// （写错 = 点打印毫无反应，且不报错）
        private const val BT_CHANNEL = "xiaozhi/btprint"
    }
}
