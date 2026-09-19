package com.pblpan.xiaozhi_scanner

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 独立扫码枪的主 Activity。
 *
 * 它只干一件事：**把导出的账甩给系统分享面板**。
 *
 * 为什么这段必须在原生做、不能交给纯 Dart：
 * Android 7.0（API 24）起，把 `file://` 交给别的 App 会直接抛
 * FileUriExposedException —— 系统不允许外部进程拿到我们的私有路径。
 * 必须由原生侧用 `FileProvider` 把自己的文件转成 `content://` 再交出去，
 * 且只授一次性读权限。Dart 层拿不到 `FileProvider`，所以只能原生做。
 *
 * ── 从 IM 客户端那份里砍掉了什么 ─────────────────────────────
 * 客户端的 MainActivity 还有一整套「分享到小智IM」的**入站**处理
 * （getInitialShare / onNewIntent / collect / copyInto …）。
 * 独立扫码枪不需要：没有人会"把一张图片分享到扫码枪"。
 * 留着那套代码的唯一后果是多一堆 intent-filter 和一段没人走的路，
 * 所以只保留出站这一条。
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 通道名与 Dart 侧 core/file_share.dart 的 'xiaozhi/share' 必须**逐字一致**。
        // 写错的症状是"点了分享毫无反应" —— 因为 MissingPluginException 在 Dart 侧
        // 被 catch 掉了，界面只会显示"当前版本不支持直接分享"。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
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
                    // 把 APK 里内置的商品档案拷到内部存储，把**路径**给 Dart。
                    //
                    // 为什么要绕这一下，而不是让 Dart 直接 rootBundle 读：
                    // 内置档案放在 android 的 assets srcDirs 里（只有 hyd 这个
                    // flavor 才有），而 rootBundle 只认 flutter_assets —— 读不到。
                    // 所以原生拷一份到 filesDir，Dart 再按普通文件读。
                    //
                    // 为什么返回路径而不是把字节传过去：这份文件 6.6MB，
                    // 走 MethodChannel 传字节要在 Dart 侧再占一份内存
                    // （老机器上就是一次没必要的 GC 压力）。
                    "builtinMaster" -> {
                        try {
                            val out = File(filesDir, BUILTIN_NAME)
                            // 已经拷过就别再拷（6.6MB，每次启动都来一遍纯浪费）
                            if (!out.exists() || out.length() == 0L) {
                                val tmp = File(filesDir, "$BUILTIN_NAME.tmp")
                                assets.open(BUILTIN_NAME).use { input ->
                                    tmp.outputStream().use { output -> input.copyTo(output) }
                                }
                                // 拷完再改名：中途断电/被杀不会留下一个半截文件，
                                // 下次启动看到的是"没拷过"，重新拷一遍就行。
                                if (out.exists()) out.delete()
                                tmp.renameTo(out)
                            }
                            result.success(out.absolutePath)
                        } catch (e: Exception) {
                            // 通用版（std）里没有这份 asset —— **不是错误**，
                            // 返回 null，Dart 侧据此不显示"内置档案"入口。
                            result.success(null)
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

    companion object {
        /// 与 Dart 侧 FileShare 的通道名必须逐字一致（写错 = 点了分享毫无反应）
        private const val CHANNEL = "xiaozhi/share"

        /// APK 里内置商品档案的文件名。**刻意用纯 ASCII**：
        /// aapt 对中文资源路径有坑（打包期报错还很难读懂），别给自己找事。
        private const val BUILTIN_NAME = "builtin_master.csv"
    }
}
