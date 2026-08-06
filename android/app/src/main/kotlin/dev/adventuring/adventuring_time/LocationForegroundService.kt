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
 * 按"位移 > 20m 或间隔 > 30s"采样，点即写落盘（JSONL 会话文件）并推送 EventChannel。
 * 会话与状态持久化：app/服务被杀后，START_STICKY 重启时按状态文件恢复采样，
 * 重进应用从文件拉回全部点，数据不丢、记录不中断。
 */
class LocationForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "adventuring_time_location"
        private const val NOTIF_ID = 1001
        private const val SESSION_FILE = "rec_session.jsonl"
        private const val STATE_FILE = "rec_state"
        const val STATE_RECORDING = "1"
        const val STATE_PAUSED = "0"

        const val ACTION_START = "start"
        const val ACTION_PAUSE = "pause"
        const val ACTION_RESUME = "resume"
        const val ACTION_STOP = "stop"

        @Volatile
        var running = false
            private set

        @Volatile
        private var sampling = false

        /** 当前记录段起始时间（ms）：暂停/被杀后重新采样时重置，用于累计记录时长。 */
        @Volatile
        private var segmentStartMs = 0L

        @Volatile
        private var sink: EventChannel.EventSink? = null

        fun attachSink(newSink: EventChannel.EventSink?) {
            sink = newSink
        }

        private fun push(point: Map<String, Any>) {
            sink?.let {
                try {
                    it.success(point)
                } catch (_: Throwable) {
                }
            }
        }

        /** 会话快照：运行状态、持久化状态（1 记录中/0 暂停）、开始时间、累计记录时长、当前段起始、采样点。 */
        fun sessionSnapshot(context: Context): Map<String, Any> {
            val (state, startMs, activeMs) = readState(context)
            return mapOf(
                "running" to running,
                "state" to state,
                "startAt" to startMs,
                "segmentStart" to segmentStartMs,
                "activeMs" to activeMs,
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

        /** 状态文件格式："state|startMs|activeMs"（activeMs=累计记录时长，暂停后不再增长）。 */
        fun writeState(context: Context, state: String, startMs: Long, activeMs: Long) {
            File(context.filesDir, STATE_FILE).writeText("$state|$startMs|$activeMs")
        }

        fun readState(context: Context): Triple<String, Long, Long> {
            val f = File(context.filesDir, STATE_FILE)
            if (!f.exists()) return Triple(STATE_PAUSED, 0L, 0L)
            val parts = f.readText().split('|')
            return if (parts.size >= 2) {
                Triple(parts[0], parts[1].toLongOrNull() ?: 0L, parts.getOrNull(2)?.toLongOrNull() ?: 0L)
            } else {
                Triple(STATE_PAUSED, 0L, 0L)
            }
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
    private val MIN_INTERVAL_MS = 30_000L

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
        startForegroundCompat()
        // 被杀后系统重启：按上次状态恢复采样（记录中断续记）
        if (readState(this).first == STATE_RECORDING) {
            segmentStartMs = System.currentTimeMillis()
            startUpdates()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PAUSE -> {
                val (state, startMs, activeMs) = readState(this)
                val active = activeMs + if (segmentStartMs > 0) System.currentTimeMillis() - segmentStartMs else 0
                segmentStartMs = 0
                writeState(this, STATE_PAUSED, startMs, active)
                stopUpdates()
            }
            ACTION_RESUME -> {
                val (state, startMs, activeMs) = readState(this)
                segmentStartMs = System.currentTimeMillis()
                writeState(this, STATE_RECORDING, startMs, activeMs)
                startUpdates()
            }
            ACTION_STOP -> {
                stopUpdates()
                segmentStartMs = 0
                stopForegroundCompat()
                stopSelf()
            }
            else -> { // ACTION_START：新会话，清空旧数据
                deleteSession(this)
                segmentStartMs = System.currentTimeMillis()
                writeState(this, STATE_RECORDING, System.currentTimeMillis(), 0)
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
        try {
            if (gpsOn) lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000L, 0f, listener)
            if (netOn) lm.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 1000L, 0f, listener)
        } catch (_: SecurityException) {
            // 定位权限被收回时静默失败，服务不崩
        }
        sampling = true
    }

    private fun stopUpdates() {
        try {
            lm.removeUpdates(listener)
        } catch (_: SecurityException) {
        }
        sampling = false
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
