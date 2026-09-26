package com.example.xiaozhi_im_client

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.io.OutputStream
import java.util.UUID
import kotlin.concurrent.thread

/**
 * 蓝牙价签 / 标签打印机（经典蓝牙 SPP）。
 *
 * ── 为什么不用 flutter_blue_plus 之类的 Flutter 蓝牙包 ─────────────────
 * 试过 flutter_blue_plus：它用的 FlutterBluePlus License **明确要求营利组织
 * 单独买商业许可**（"For for-profit organizations, a commercial license is
 * required"）。超市收银/打价签是营利用途，用它就是违约。
 *
 * 而打印机这边**本来就不需要 BLE**：主流蓝牙价签机、标签机、收银小票机走的都是
 * 经典蓝牙 **SPP（串口 RFCOMM）**——SPP 的服务 UUID 是固定那个
 * 00001101-0000-1000-8000-00805F9B34FB，各家都一样，跟型号无关。
 * 用 Android 自带的 android.bluetooth（Apache-2.0）写，既没有许可问题，
 * 通用的范围反而比 BLE 那套自定义 GATT 更宽。
 *
 * 字节流也刚刚好：ESC/POS 就是把字节原样送出去，OutputStream 直接顶用，
 * 不需要解析器，也不需要知道任何厂商指令。
 *
 * ── 通道名 ────────────────────────────────────────────────────────
 * 'xiaozhi/btprint'，与 Dart 侧 core/bt_printer.dart 的 CHANNEL 必须逐字一致。
 */
class BluetoothPrinter(private val activity: Activity) {

    companion object {
        /** SPP / 串口蓝牙的规范 UUID。所有蓝牙打印机共用这一个，不要换。 */
        private val SPP_UUID: UUID =
            UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

        /** 每块 512 字节、块间隔 2ms。一次写太大，部分机器的蓝牙缓冲会顶住不吐。 */
        private const val CHUNK = 512

        const val ERR_PERMISSION = "PERMISSION_DENIED"
        const val ERR_BLUETOOTH_OFF = "BLUETOOTH_OFF"
        const val ERR_NO_PEER = "NO_PEER"
        const val ERR_CONNECT = "CONNECT_FAILED"
        const val ERR_NOT_OPEN = "NOT_OPEN"
    }

    private var socket: BluetoothSocket? = null
    private var out: OutputStream? = null

    private val adapter: BluetoothAdapter?
        get() = (activity.getSystemService(android.content.Context.BLUETOOTH_SERVICE)
                as? BluetoothAdapter) ?: BluetoothAdapter.getDefaultAdapter()

    /** 需要向系统申请的运行时权限。 */
    private fun neededPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                android.Manifest.permission.BLUETOOTH_CONNECT,
                android.Manifest.permission.BLUETOOTH_SCAN,
            )
        } else {
            // Android 11 及更早：读配对列表不需要 BLUETOOTH_CONNECT，
            // 但扫描（如果要扫新机器）需要位置权限，统一加上最不容易漏。
            arrayOf(
                android.Manifest.permission.BLUETOOTH,
                android.Manifest.permission.ACCESS_COARSE_LOCATION,
            )
        }

    /** 缺权限就去申请；返回 true 表示到调用时已经有权限了。 */
    fun ensurePermission(): Boolean {
        val a = adapter
        if (a == null || !a.isEnabled) return false
        val perms = neededPermissions()
        val missing = perms.filter {
            ContextCompat.checkSelfPermission(activity, it) != PackageManager.PERMISSION_GRANTED
        }.toTypedArray()
        if (missing.isEmpty()) return true
        ActivityCompat.requestPermissions(activity, missing, 0x5A21)
        // 不在这里等结果：requestPermissions 会弹系统对话框，
        // 在方法调用里同步等它 = 把 Flutter 引擎线程堵死，UI 会整个卡住。
        // Dart 侧看到 false 会提示"去设置里给权限"。
        return false
    }

    /** 已配对过的设备清单。打印机通常先在系统蓝牙里配对好，这里就够用了。 */
    fun listPaired(): List<Map<String, Any>> {
        val a = adapter ?: return emptyList()
        if (!a.isEnabled) return emptyList()
        val perms = neededPermissions()
        perms.forEach {
            if (ContextCompat.checkSelfPermission(activity, it) != PackageManager.PERMISSION_GRANTED) {
                return emptyList()
            }
        }
        return a.bondedDevices.map { d ->
            mapOf(
                "address" to (d.address ?: ""),
                "name" to (d.name ?: ""),
            )
        }
    }

    /** 连接。IO 放后台线程 —— connect() 在主线程跑会触发 ANR。 */
    fun connect(address: String) {
        val a = adapter
            ?: throw BluetoothPrinterException(ERR_NO_PEER, "这台设备没有蓝牙")
        if (!a.isEnabled) throw BluetoothPrinterException(ERR_BLUETOOTH_OFF, "手机蓝牙没开")
        val perms = neededPermissions()
        perms.forEach {
            if (ContextCompat.checkSelfPermission(activity, it) != PackageManager.PERMISSION_GRANTED) {
                throw BluetoothPrinterException(ERR_PERMISSION, "蓝牙权限还没给")
            }
        }
        val device: BluetoothDevice = a.getRemoteDevice(address)
            ?: throw BluetoothPrinterException(ERR_NO_PEER, "找不到这台设备")

        var sock: BluetoothSocket? = null
        // 配对过的设备用规范 UUID 连；有些机器对 UUID 挑剔，退一步试一次
        // 构造出来的端口（createInsecureRfcommSocket 允许未加密）。
        try {
            sock = device.createRfcommSocketToServiceRecord(SPP_UUID)
        } catch (e: Exception) {
            try {
                sock = device.createInsecureRfcommSocketToServiceRecord(SPP_UUID)
            } catch (e2: Exception) {
                throw BluetoothPrinterException(ERR_CONNECT, "这台机器的蓝牙端口打不开")
            }
        }
        try {
            sock.connect()
        } catch (e: Exception) {
            try {
                sock.close()
            } catch (_: Exception) {
            }
            throw BluetoothPrinterException(
                ERR_CONNECT,
                "连不上「${device.name ?: address}」——请确认它已开机、已配对",
            )
        }
        socket = sock
        out = sock.outputStream
    }

    /** 写字节。整批一次进来，这里按块往下推。 */
    fun write(bytes: ByteArray) {
        val o = out ?: throw BluetoothPrinterException(ERR_NOT_OPEN, "没有连上打印机")
        runBlockingQuiet {
            var i = 0
            while (i < bytes.size) {
                val end = (i + CHUNK).coerceAtMost(bytes.size)
                o.write(bytes, i, end - i)
                o.flush()
                i = end
                if (i < bytes.size) Thread.sleep(2)
            }
        }
    }

    /** 断开。重复断开不报错。 */
    fun disconnect() {
        try {
            out?.flush()
        } catch (_: Exception) {
        }
        out = null
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        socket = null
    }

    fun isOpen(): Boolean = socket != null && out != null

    /** 一次打完要花几秒，别在 Dart 的 UI 线程上干等。 */
    private fun runBlockingQuiet(body: () -> Unit) {
        var t: Thread? = null
        t = thread(name = "btprint-write") { body() }
        t.join(30_000)
    }
}

/** 带错误码的异常，Dart 侧靠 code 给出"能照做"的提示。 */
class BluetoothPrinterException(val code: String, message: String) : Exception(message)
