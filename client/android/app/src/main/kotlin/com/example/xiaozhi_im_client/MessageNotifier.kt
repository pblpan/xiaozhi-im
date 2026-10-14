package com.example.xiaozhi_im_client

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * 新消息通知 + 桌面图标角标。
 *
 * 为什么用原生而不是 Flutter 插件：这台机器连不上 pub.dev（详见项目记忆），
 * 而且需求本身很薄 —— 就是"后台来消息时在通知栏露个脸 + 图标上标个未读数"。
 * 照蓝牙打印（BluetoothPrinter）那次的路子走 MethodChannel，零新依赖，
 * CI 不会因为多一个包挂掉。
 *
 * 两条通道（channel）分开的用意：
 *   · msg_alert  —— 后台到达：响一声 + 震动 + 抬腕弹条（IMPORTANCE_HIGH）
 *   · msg_quiet  —— 前台到达：只更新通知栏与角标，**不发声**
 * 同一条通道没法做到"这条响、那条不响"（API 26 起提示方式由通道决定），
 * 所以拆两个。Dart 侧按前后台选通道，两不打架 —— 否则前台来消息会是
 * "提示音响完通知再响一遍"的双响。
 */
object MessageNotifier {

    /** 与 Dart 侧 core/notifier.dart 的通道名必须逐字一致（写错 = 通知静默失效） */
    const val CHANNEL = "xiaozhi/notify"

    private const val CH_ALERT = "msg_alert"
    private const val CH_QUIET = "msg_quiet"

    /** 通知 id 直接用会话 id：同一会话的新消息覆盖旧通知，不会在通知栏刷屏 */
    private const val EXTRA_CONV_ID = "conv_id"
    private const val EXTRA_FROM_NOTIFY = "from_notify"

    /** 通知权限的 requestCode。公开（internal）是为了 MainActivity 的
     *  onRequestPermissionsResult 能对上号，不用把 4177 抄两遍 */
    internal const val REQ_POST_NOTIFICATIONS = 4177

    private lateinit var appCtx: Context
    private var activity: Activity? = null

    /** 冷启动时先到的点击：Dart 还没接上通道，先存着，等它来问 */
    private var pendingTapConv: Int = 0

    fun init(context: Context) {
        appCtx = context.applicationContext
        createChannels()
    }

    fun bindActivity(a: Activity?) {
        activity = a
    }

    private fun createChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = appCtx.getSystemService(NotificationManager::class.java)
        // 后台到达：要能被听见（IMPORTANCE_HIGH = 响 + 震 + 弹条）
        nm.createNotificationChannel(
            NotificationChannel(
                CH_ALERT, "消息提醒", NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "App 在后台时收到新消息：响铃、震动并在屏幕顶部弹出"
                enableVibration(true)
                // 🔴 后台提示音走**系统通知音**，不靠 App 内播放：
                //    部分国产 ROM 会限制后台进程的音频输出，audioplayers 播不出来；
                //    而系统通知音由 SystemUI 放，跟 App 活没活着无关。
                //    与之配套：Dart 侧 SoundService 在 Android 且后台时不播
                //    （core/sound_service.dart），否则就是双响。
                setSound(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
                    Notification.AUDIO_ATTRIBUTES_DEFAULT
                )
            }
        )
        // 前台到达：用户正盯着屏幕，别再响一次（IMPORTANCE_LOW = 无提示音）
        nm.createNotificationChannel(
            NotificationChannel(
                CH_QUIET, "消息提醒（前台静默）", NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "App 正在前台使用时收到新消息：只更新通知栏与图标角标，不发声"
                setSound(null, null)
                enableVibration(false)
            }
        )
    }

    /**
     * Android 13+ 申请通知权限（运行时权限）。
     *
     * 返回值是**当前是否已授权**，不是"申请后的结果" —— 系统弹窗是异步的，
     * 用户点什么都要等一会儿。Dart 只在启动时调一次触发弹窗，不当场拿它做判断：
     * 授权了后面通知自然发得出来，拒了也别弹窗骚扰（Android 自己两次后就不再问了）。
     */
    fun ensurePermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return NotificationManagerCompat.from(appCtx).areNotificationsEnabled()
        }
        val a = activity ?: return NotificationManagerCompat.from(appCtx).areNotificationsEnabled()
        val granted = ContextCompat.checkSelfPermission(
            a, android.Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) return true
        ActivityCompat.requestPermissions(
            a,
            arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
            REQ_POST_NOTIFICATIONS
        )
        return false
    }

    fun hasPermission(): Boolean =
        NotificationManagerCompat.from(appCtx).areNotificationsEnabled()

    /**
     * 发一条新消息通知（同会话自动覆盖上一条）。
     *
     * @param conversationId 会话 id，兼作通知 id
     * @param title          标题（单聊=对方名字；群聊=群名）
     * @param body           正文（群聊形如"张三: 大家好"）
     * @param number         未读总数，写进通知供启动器显示角标
     * @param alert          true=后台到达（震动+弹条），false=前台到达（纯静默更新）
     */
    fun showMessage(
        conversationId: Int,
        title: String,
        body: String,
        number: Int,
        alert: Boolean
    ) {
        if (!hasPermission()) return
        val tap = Intent(appCtx, MainActivity::class.java).apply {
            // singleTop（见 AndroidManifest）：App 活着时走 onNewIntent 复用实例，
            // 不会新拉一个进程把用户正在看的页面顶掉。
            action = Intent.ACTION_MAIN
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EXTRA_CONV_ID, conversationId)
            putExtra(EXTRA_FROM_NOTIFY, true)
        }
        // FLAG_IMMUTABLE 是 API 23 才有的常量。minSdk 21/22 的老机型上传入
        // 这个位理论上会被忽略，但各家 ROM 表现不一，干脆按版本拼，不赌。
        var piFlags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            piFlags = piFlags or PendingIntent.FLAG_IMMUTABLE
        }
        val pi = PendingIntent.getActivity(
            appCtx,
            // requestCode 必须按会话区分：同一个 PendingIntent 会被系统按
            // requestCode+Intent 内容缓存复用，全用 0 的话点哪条通知都跳到第一个会话
            // （FLAG_UPDATE_CURRENT 也救不了 requestCode 相同的情况）。
            conversationId,
            tap,
            piFlags
        )
        val n = NotificationCompat.Builder(appCtx, if (alert) CH_ALERT else CH_QUIET)
            .setSmallIcon(R.drawable.ic_stat_xiaozhi)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setNumber(number.coerceAtLeast(1)) // 桌面图标角标数
            .setWhen(System.currentTimeMillis())
            .setShowWhen(true)
            .setAutoCancel(true) // 点了自己消失
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setContentIntent(pi)
            .build()
        try {
            NotificationManagerCompat.from(appCtx).notify(conversationId, n)
        } catch (_: SecurityException) {
            // 极端情况：通知权限被用户在系统设置里临关掉。不发就不发，别崩。
        }
    }

    /** 撤掉某会话的通知（用户已读了那条会话） */
    fun cancelFor(conversationId: Int) {
        try {
            NotificationManagerCompat.from(appCtx).cancel(conversationId)
        } catch (_: SecurityException) {
        }
    }

    /** 全部撤掉（未读清零 / 退出登录时） */
    fun cancelAll() {
        try {
            NotificationManagerCompat.from(appCtx).cancelAll()
        } catch (_: SecurityException) {
        }
    }

    // ---------------- 点击意图的收发 ----------------

    /** onNewIntent 里调用：App 活着时用户点了通知 → 立刻推给 Dart */
    fun onNotificationIntent(intent: Intent?): Int {
        if (intent == null) return 0
        if (!intent.getBooleanExtra(EXTRA_FROM_NOTIFY, false)) return 0
        val conv = intent.getIntExtra(EXTRA_CONV_ID, 0)
        if (conv <= 0) return 0
        pendingTapConv = conv
        return conv
    }

    /** Dart 冷启动来问"有没有一条没消费的点击" */
    fun consumePendingTap(): Int {
        val c = pendingTapConv
        pendingTapConv = 0
        return c
    }
}
