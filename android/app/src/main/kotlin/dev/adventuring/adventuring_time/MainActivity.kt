package dev.adventuring.adventuring_time

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

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

        MethodChannel(messenger, channel).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    requestNotificationPermission()
                    requestIgnoreBattery()
                    sendAction(LocationForegroundService.ACTION_START)
                    result.success(null)
                }
                "pause" -> {
                    sendAction(LocationForegroundService.ACTION_PAUSE)
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
                else -> result.notImplemented()
            }
        }
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
