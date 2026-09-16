package com.example.xiaozhi_im_client

import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.Build
import java.security.MessageDigest

/**
 * 包完整性自校验（客户端加固，2026-09-16，任务 #127）。
 *
 * 【为什么这件事必须放在原生做】
 * Dart 层拿不到"这个 APK 是用哪把密钥签的"。签名信息在 PackageManager 里，
 * 只有原生能读。Dart 侧（core/integrity.dart）只负责"读结论 + 拒绝进入"。
 *
 * 【它到底防住了什么】
 * 别人反编译 → 改代码（去掉授权校验、改成连自己服务器、塞后门）→ **重新签名打包**。
 * 重签之后的包，签名证书指纹**必然**与我们的不同 —— 因此启动即被拒。
 * 这是安卓上唯一一个"攻击者不掌握私钥就绕不过去"的判据（R8 混淆只是让改代码变贵）。
 *
 * ⚠️ 期望值只能改这里一处（Dart 侧不再重复写一份，避免两边不一致时误判）。
 *    它是 dev keystore 的证书 SHA-256；换签名密钥必须同步改这里，
 *    否则自己人也会被拦下。
 */
object AppIntegrity {

    /** 小写十六进制、无冒号，与 core/integrity.dart 的展示格式一致 */
    const val EXPECTED_CERT_SHA256 =
        "64d99000e061259a94c2a54cc408487c9461cf678f7f155f488293534e0ed6d5"

    const val VERDICT_OK = "ok"
    const val VERDICT_TAMPERED = "tampered"

    /** 拿不到签名信息时的兜底结论 —— 上层遇到它**放行**（辅助机制不锁人） */
    const val VERDICT_UNKNOWN = "unknown"

    /**
     * 返回 Map：
     *   verdict     ok | tampered | unknown
     *   certSha256  实际证书指纹（可能为空串）
     *   expected    期望指纹
     *   detail      给人看的补充说明
     */
    fun check(ctx: Context): Map<String, String> {
        val actual = try {
            apkSigningCertSha256(ctx)
        } catch (e: Exception) {
            return mapOf(
                "verdict" to VERDICT_UNKNOWN,
                "certSha256" to "",
                "expected" to EXPECTED_CERT_SHA256,
                "detail" to "读取签名失败: ${e.javaClass.simpleName}",
            )
        }
        if (actual.isEmpty()) {
            return mapOf(
                "verdict" to VERDICT_UNKNOWN,
                "certSha256" to "",
                "expected" to EXPECTED_CERT_SHA256,
                "detail" to "系统未返回签名证书（可能是特殊安装方式）",
            )
        }
        val ok = actual.equals(EXPECTED_CERT_SHA256, ignoreCase = true)
        return mapOf(
            "verdict" to if (ok) VERDICT_OK else VERDICT_TAMPERED,
            "certSha256" to actual,
            "expected" to EXPECTED_CERT_SHA256,
            "detail" to if (ok) "" else "签名证书与本 App 官方密钥不一致",
        )
    }

    /**
     * 取当前安装包**实际**的签名证书 SHA-256。
     *
     * API 28 起签名信息挪到了 signingInfo（一个包可以有多份签名者 /
     * 一条证书轮换历史），旧设备走已废弃的 signatures 字段 —— 两条都要接，
     * 否则在旧机上会恒返回空、校验形同虚设。
     */
    @Suppress("DEPRECATION")
    private fun apkSigningCertSha256(ctx: Context): String {
        val pm = ctx.packageManager
        val pkg = ctx.packageName
        // ⚠️ 类型必须写成**可空**的 Array<out Signature>?：
        //    API 28 起 signingInfo 可空；旧分支 signatures 也是可空数组。
        //    写成 Array<Signature> 会以
        //    "Initializer type mismatch: expected 'Array<Signature>', actual 'Array<(out) Signature!>?'"
        //    直接编译不过（本机 Kotlin 编译器实测拦下）。
        val certs: Array<out Signature>? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val info = pm.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES)
            val si = info.signingInfo ?: return ""
            // 多签名者（多把密钥共同签）取 apkContentsSigners；
            // 单签名者取 signingCertificateHistory —— 其第一个元素就是当前证书
            if (si.hasMultipleSigners()) si.apkContentsSigners
            else si.signingCertificateHistory
        } else {
            pm.getPackageInfo(pkg, PackageManager.GET_SIGNATURES).signatures
        }
        val cert = certs?.firstOrNull() ?: return ""
        val digest = MessageDigest.getInstance("SHA-256").digest(cert.toByteArray())
        val sb = StringBuilder(digest.size * 2)
        for (b in digest) {
            val v = b.toInt() and 0xFF
            if (v < 0x10) sb.append('0')
            sb.append(Integer.toHexString(v))
        }
        return sb.toString()
    }
}
