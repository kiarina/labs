package com.kiarina.labs.meanvc2_onnx

import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keep the screen on during the soak.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lab/device").setMethodCallHandler { call, result ->
            if (call.method != "status") return@setMethodCallHandler result.notImplemented()
            val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            val m = hashMapOf<String, Any>(
                "batteryLevel" to (if (scale > 0) level.toDouble() / scale else -1.0),
                "batteryTempC" to ((battery?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) ?: 0) / 10.0),
                "plugged" to (battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0),
                "model" to Build.MODEL,
            )
            if (Build.VERSION.SDK_INT >= 29) m["thermalStatus"] = pm.currentThermalStatus  // 0 none .. 6 shutdown
            if (Build.VERSION.SDK_INT >= 30) m["thermalHeadroom10s"] = pm.getThermalHeadroom(10).toDouble()
            result.success(m)
        }
    }
}
