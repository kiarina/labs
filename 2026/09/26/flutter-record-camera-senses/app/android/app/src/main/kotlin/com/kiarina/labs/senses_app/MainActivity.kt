package com.kiarina.labs.senses_app

import android.os.Bundle
import android.system.Os
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    // Lab autorun: `adb shell am start -n <pkg>/.MainActivity --es scenario all ...`
    // exports the extras as SENSES_* environment variables for the Dart side.
    override fun onCreate(savedInstanceState: Bundle?) {
        val extras = intent?.extras
        for (key in listOf("scenario", "seconds", "interval", "preset", "echo", "exit")) {
            extras?.getString(key)?.let { Os.setenv("SENSES_${key.uppercase()}", it, true) }
        }
        super.onCreate(savedInstanceState)
    }
}
