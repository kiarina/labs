package com.kiarina.labs.gpt_live_app

import android.os.Bundle
import android.system.Os
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    // Lab autorun: `adb shell am start -n <pkg>/.MainActivity --es relay http://... ...`
    // exports the extras as LIVE_* environment variables for the Dart side.
    override fun onCreate(savedInstanceState: Bundle?) {
        val extras = intent?.extras
        for (key in listOf("relay", "seconds", "exit")) {
            extras?.getString(key)?.let { Os.setenv("LIVE_${key.uppercase()}", it, true) }
        }
        super.onCreate(savedInstanceState)
    }
}
