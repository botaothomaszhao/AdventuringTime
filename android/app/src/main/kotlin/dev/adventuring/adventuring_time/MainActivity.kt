package dev.adventuring.adventuring_time

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        val messenger = engine.dartExecutor.binaryMessenger
        val channel = "adventuring_time/location"

        EventChannel(messenger, "$channel/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                LocationForegroundService.attachSink(events)
            }

            override fun onCancel(arguments: Any?) {
                LocationForegroundService.attachSink(null)
            }
        })

        // 实时位置通道：蓝点/实时速度用，前台模式每次定位推送
        EventChannel(messenger, "$channel/position").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                LocationForegroundService.attachPositionSink(events)
            }

            override fun onCancel(arguments: Any?) {
                LocationForegroundService.attachPositionSink(null)
            }
        })

        MethodChannel(messenger, channel).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    requestNotificationPermission()
                    requestIgnoreBattery()
                    sendAction(LocationForegroundService.ACTION_START)
                    result.success(null)
                }
                "resume" -> {
                    sendAction(LocationForegroundService.ACTION_RESUME)
                    result.success(null)
                }
                "stop" -> {
                    // 先收集点再停服务：主线程串行，期间不会有新的定位回调
                    result.success(LocationForegroundService.collectAndClear(this))
                    sendAction(LocationForegroundService.ACTION_STOP)
                }
                "getSession" -> result.success(LocationForegroundService.sessionSnapshot(this))
                "setMode" -> {
                    // 服务未运行时不启动（空闲时无需调频）
                    if (LocationForegroundService.running) {
                        when (call.arguments as? String) {
                            "foreground" ->
                                sendAction(LocationForegroundService.ACTION_MODE_FOREGROUND)
                            "background" ->
                                sendAction(LocationForegroundService.ACTION_MODE_BACKGROUND)
                        }
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // 导入导出：把导出文件写入公共下载目录
        MethodChannel(messenger, "adventuring_time/files").setMethodCallHandler { call, result ->
            when (call.method) {
                "saveToDownloads" -> {
                    try {
                        val filename = call.argument<String>("filename") ?: "adventuring_time.atrip"
                        val data = call.argument<ByteArray>("data") ?: ByteArray(0)
                        result.success(saveToDownloads(filename, data))
                    } catch (e: Exception) {
                        result.error("save_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun saveToDownloads(filename: String, data: ByteArray): String {
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, filename)
                put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            }
            val resolver = contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IOException("无法写入下载目录")
            resolver.openOutputStream(uri)?.use { it.write(data) }
                ?: throw IOException("无法打开输出流")
            return Environment.DIRECTORY_DOWNLOADS + "/" + filename
        }
        // Android 9 及以下：写公共下载目录（需 WRITE_EXTERNAL_STORAGE）
        val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        if (!dir.exists()) dir.mkdirs()
        val f = File(dir, filename)
        f.writeBytes(data)
        return f.absolutePath
    }

    private fun sendAction(action: String) {
        val intent = Intent(this, LocationForegroundService::class.java).setAction(action)
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    private fun requestIgnoreBattery() {
        if (Build.VERSION.SDK_INT < 23) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (pm.isIgnoringBatteryOptimizations(packageName)) return
        val prefs = getSharedPreferences("at_location", Context.MODE_PRIVATE)
        if (prefs.getBoolean("batteryAsked", false)) return
        prefs.edit().putBoolean("batteryAsked", true).apply()
        try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:$packageName"))
            )
        } catch (_: Exception) {
            // 部分厂商不支持该 intent，失败不阻塞
        }
    }
}
