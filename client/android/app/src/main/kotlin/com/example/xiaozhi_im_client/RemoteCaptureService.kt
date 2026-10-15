package com.example.xiaozhi_im_client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 远程协助「被控端」的屏幕采集前台服务。
 *
 * ─────────────────────────────────────────────────────────────
 * 为什么必须有它（否则 Android 14 上直接崩）
 * ─────────────────────────────────────────────────────────────
 * Android 10（API 29）起，MediaProjection 要求调用方在前台；
 * Android 14（API 34）起更是写死了一条：没有正在运行的
 * **mediaProjection 类型前台服务**，`getMediaProjection()` 直接抛
 * SecurityException，连错误提示都没有 —— 现象就是"点开始共享，画面永远黑的"，
 * 而 Dart 侧只能看到一个 SecurityException，看不出是缺了这个服务。
 *
 * flutter_webrtc 自己**不带**这个服务（它的 AndroidManifest 是空的，
 * 见 pub 缓存里的包），所以必须由宿主 App 提供：
 * 在 getDisplayMedia 之前把它拉起来，会话结束再停掉。
 *
 * ─────────────────────────────────────────────────────────────
 * 为什么要一条常驻通知
 * ─────────────────────────────────────────────────────────────
 * 屏幕共享是**能被滥用**的能力：一个后台 App 悄悄录屏，用户在状态栏上什么都
 * 看不到。Android 的对策就是强制前台服务 + 强制通知 —— 那条通知不是噪音，
 * 是"有人在录你的屏"的常亮提示，也是用户可以一键停掉它的入口。
 * 所以这里刻意不去做"隐藏通知"这类小动作。
 */
class RemoteCaptureService : Service() {

    override fun onCreate() {
        super.onCreate()
        createChannel()
        // 必须在 startForeground **之前**拿到 notification，
        // 顺序反了在部分机型上会抛 "Bad notification for startForeground"
        val n = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID,
                n,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIF_ID, n)
        }
        running = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 被系统杀掉后不重建：屏幕共享中断了就让它断，
        // 悄悄重连会在用户不知情的情况下又开始录屏
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        @Suppress("DEPRECATION")
        stopForeground(true)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CH_ID) != null) return
        // IMPORTANCE_LOW：常驻但不响不震。它只是个状态提示，不是新消息
        nm.createNotificationChannel(
            NotificationChannel(CH_ID, "屏幕共享", NotificationManager.IMPORTANCE_LOW),
        )
    }

    private fun buildNotification(): Notification {
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CH_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return b
            .setContentTitle("正在共享屏幕")
            .setContentText("远程协助进行中，下拉可结束本次共享")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CH_ID = "remote_capture"
        private const val NOTIF_ID = 6101

        /// 与 Dart 侧 core/remote_capture.dart 的通道名必须逐字一致
        const val CHANNEL = "xiaozhi/remote_capture"

        @Volatile
        var running = false
            private set

        fun start(context: Context) {
            if (running) return
            try {
                val i = Intent(context, RemoteCaptureService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(i)
                } else {
                    context.startService(i)
                }
            } catch (e: Exception) {
                // 起不来也要让共享继续尝试：老机型（<29）本来也不需要它。
                // 真正的失败会由 getMediaProjection 那一步报出来。
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, RemoteCaptureService::class.java))
            } catch (e: Exception) {
                // 停不掉就算了：进程被杀时系统会连通知一起收走
            }
        }
    }
}
