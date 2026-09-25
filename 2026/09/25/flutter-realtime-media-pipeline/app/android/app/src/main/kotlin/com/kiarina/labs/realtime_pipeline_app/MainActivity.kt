package com.kiarina.labs.realtime_pipeline_app

import android.os.Bundle
import android.system.Os
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    // Lab autorun: `adb shell am start -n <pkg>/.MainActivity --es autorun loopback ...`
    // exports the extras as REALTIME_* environment variables, which the Dart
    // side reads the same way as on desktop.
    override fun onCreate(savedInstanceState: Bundle?) {
        val extras = intent?.extras
        for (key in listOf("autorun", "probe", "seconds", "exit", "signaling", "room")) {
            extras?.getString(key)?.let { Os.setenv("REALTIME_${key.uppercase()}", it, true) }
        }
        super.onCreate(savedInstanceState)
    }
}
