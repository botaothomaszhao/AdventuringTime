package dev.adventuring.adventuring_time

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import io.flutter.plugin.common.EventChannel
import org.json.JSONObject
import java.io.File

/**
 * 前台轨迹记录服务：系统 LocationManager 持续定位（GPS 优先、网络兜底），
 * 仅"记录中"运行——暂停功能已移除，路径记录一定是一整段。按"位移 > 20m 或间隔 > 20s"采样，
 * 点即写落盘（JSONL 会话文件）并推送 EventChannel；前台模式每次定位都推送实时位置
 * 到位置通道供蓝点/实时速度使用（与采样解耦，每秒更新）。
 * 会话持久化：状态文件仅存会话开始时间，计时=当前-开始（大退/被杀重进也算时间）；
 * 服务被杀后 START_STICKY 重启按 startMs 恢复采样，重进应用从文件拉回全部点与开始时间。
 */
class LocationForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "adventuring_time_location"
        private const val NOTIF_ID = 1001
        private const val SESSION_FILE = "rec_session.jsonl"
        private const val STATE_FILE = "rec_state"

        const val ACTION_START = "start"
        const val ACTION_RESUME = "resume" // 重进应用恢复采样（会话 startMs 保留）
        const val ACTION_STOP = "stop"
        const val ACTION_MODE_FOREGROUND = "mode_foreground"
        const val ACTION_MODE_BACKGROUND = "mode_background"

        const val MODE_FOREGROUND = "foreground"
        const val MODE_BACKGROUND = "background"

        @Volatile
        var running = false
            private set

        /** 前台/后台模式：前台 1s 定位喂蓝点，后台降频只采样。 */
        @Volatile
        private var mode = MODE_BACKGROUND

        @Volatile
        private var sink: EventChannel.EventSink? = null

        /** 实时位置通道（蓝点/实时速度用，前台模式每次定位都推送）。 */
        @Volatile
        private var positionSink: EventChannel.EventSink? = null

        fun attachSink(newSink: EventChannel.EventSink?) {
            sink = newSink
        }

        fun attachPositionSink(newSink: EventChannel.EventSink?) {
            positionSink = newSink
        }

        private fun push(point: Map<String, Any>) {
            sink?.let {
                try {
                    it.success(point)
                } catch (_: Throwable) {
                }
            }
        }

        private fun pushPosition(loc: Location) {
            positionSink?.let {
                try {
                    it.success(mapOf(
                        "lat" to loc.latitude,
                        "lon" to loc.longitude,
                        "time" to loc.time,
                    ))
                } catch (_: Throwable) {
                }
            }
        }

        /** 会话快照：运行状态、会话开始时间、采样点。 */
        fun sessionSnapshot(context: Context): Map<String, Any> {
            return mapOf(
                "running" to running,
                "startAt" to readStartMs(context),
                "points" to readPoints(context),
            )
        }

        /** 收集会话全部点并清空会话文件（停止保存时调用）。 */
        fun collectAndClear(context: Context): List<Map<String, Any>> {
            val pts = readPoints(context)
            deleteSession(context)
            return pts
        }

        fun deleteSession(context: Context) {
            File(context.filesDir, SESSION_FILE).delete()
            File(context.filesDir, STATE_FILE).delete()
        }

        /** 状态文件只存会话开始时间（ms）；兼容旧版"state|startMs|..."（旧暂停会话不恢复）。 */
        fun writeStartMs(context: Context, startMs: Long) {
            File(context.filesDir, STATE_FILE).writeText("$startMs")
        }

        fun readStartMs(context: Context): Long {
            val f = File(context.filesDir, STATE_FILE)
            if (!f.exists()) return 0L
            val p = f.readText().split('|')
            if (p.size >= 2 && p[0] == "0") return 0L // 旧版暂停会话不再恢复
            return (if (p.size >= 2) p[1] else p[0]).toLongOrNull() ?: 0L
        }

        fun readPoints(context: Context): List<Map<String, Any>> {
            val f = File(context.filesDir, SESSION_FILE)
            if (!f.exists()) return emptyList()
            val out = mutableListOf<Map<String, Any>>()
            f.forEachLine { line ->
                try {
                    val o = JSONObject(line)
                    out.add(mapOf(
                        "lat" to o.getDouble("lat"),
                        "lon" to o.getDouble("lon"),
                        "time" to o.getLong("time"),
                    ))
                } catch (_: Exception) {
                    // 跳过损坏行
                }
            }
            return out
        }
    }

    private val MIN_DIST_M = 20f
    private val MIN_INTERVAL_MS = 20_000L

    private val lm: LocationManager by lazy {
        getSystemService(Context.LOCATION_SERVICE) as LocationManager
    }

    private var lastGpsMs = 0L
    private var lastSample: Location? = null
    private var lastSampleMs = 0L

    private val listener = object : LocationListener {
        override fun onLocationChanged(loc: Location) {
            if (loc.provider == LocationManager.NETWORK_PROVIDER &&
                System.currentTimeMillis() - lastGpsMs < 15_000
            ) {
                return // GPS 刚有 fix 时忽略网络定位，避免轨迹抖动
            }
            if (loc.provider == LocationManager.GPS_PROVIDER) lastGpsMs = System.currentTimeMillis()
            // 前台每次定位都推实时位置（蓝点/实时速度）；后台不推（蓝点不可见）
            if (mode == MODE_FOREGROUND) pushPosition(loc)
            val last = lastSample
            if (last != null && System.currentTimeMillis() - lastSampleMs < MIN_INTERVAL_MS &&
                loc.distanceTo(last) < MIN_DIST_M
            ) {
                return // 位移与间隔均未超阈值，不采样
            }
            lastSample = loc
            lastSampleMs = System.currentTimeMillis()
            appendPoint(loc)
            push(mapOf(
                "lat" to loc.latitude,
                "lon" to loc.longitude,
                "time" to loc.time,
            ))
        }

        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

        override fun onProviderEnabled(provider: String) {}

        override fun onProviderDisabled(provider: String) {}
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
        mode = MODE_BACKGROUND // 系统重启场景视为后台，Dart 前台时会纠正
        startForegroundCompat()
        // 被杀后系统重启：有未结束会话（startMs>0）即恢复采样，计时不停
        if (readStartMs(this) > 0) startUpdates()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_RESUME -> startUpdates() // 重进应用恢复采样（会话 startMs 保留）
            ACTION_STOP -> {
                stopUpdates()
                stopForegroundCompat()
                stopSelf()
            }
            ACTION_MODE_FOREGROUND -> {
                mode = MODE_FOREGROUND
                startUpdates() // 重注册为前台频率
            }
            ACTION_MODE_BACKGROUND -> {
                mode = MODE_BACKGROUND
                startUpdates() // 重注册为后台低频
            }
            else -> { // ACTION_START：新会话，清空旧数据
                deleteSession(this)
                writeStartMs(this, System.currentTimeMillis())
                startUpdates()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopUpdates()
        running = false
        super.onDestroy()
    }

    private fun appendPoint(loc: Location) {
        try {
            File(filesDir, SESSION_FILE)
                .appendText("{\"lat\":${loc.latitude},\"lon\":${loc.longitude},\"time\":${loc.time}}\n")
        } catch (_: Exception) {
            // 磁盘不可写时丢弃，不阻塞定位
        }
    }

    private fun startUpdates() {
        val gpsOn = lm.isProviderEnabled(LocationManager.GPS_PROVIDER)
        val netOn = lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        if (!gpsOn && !netOn) return
        stopUpdates()
        // 前台 1s（蓝点实时），后台降频 5s（采样阈值 20m/20s，低频无损）
        val minTime = if (mode == MODE_FOREGROUND) 1_000L else 5_000L
        try {
            if (gpsOn) lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, minTime, 0f, listener)
            if (netOn) lm.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, minTime, 0f, listener)
        } catch (_: SecurityException) {
            // 定位权限被收回时静默失败，服务不崩
        }
    }

    private fun stopUpdates() {
        try {
            lm.removeUpdates(listener)
        } catch (_: SecurityException) {
        }
    }

    private fun startForegroundCompat() {
        val n = buildNotification()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(NOTIF_ID, n)
        }
    }

    @Suppress("DEPRECATION")
    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE) else stopForeground(true)
    }

    private fun buildNotification(): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            val ch = NotificationChannel(CHANNEL_ID, "轨迹记录", NotificationManager.IMPORTANCE_LOW)
            ch.setShowBadge(false)
            nm.createNotificationChannel(ch)
        }
        val pi = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE)
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("正在记录轨迹")
            .setContentText("探索的时光正在记录位置")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pi)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }
}
