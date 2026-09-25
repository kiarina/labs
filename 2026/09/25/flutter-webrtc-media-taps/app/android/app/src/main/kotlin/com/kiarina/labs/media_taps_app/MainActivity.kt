package com.kiarina.labs.media_taps_app

import android.os.Bundle
import android.system.Os
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    // Lab autorun: `adb shell am start -n <pkg>/.MainActivity --es scenario loopback ...`
    // exports the extras as TAPS_* environment variables for the Dart side.
    override fun onCreate(savedInstanceState: Bundle?) {
        val extras = intent?.extras
        for (key in listOf("scenario", "seconds", "convert", "deliver", "startrecording", "exit")) {
            extras?.getString(key)?.let { Os.setenv("TAPS_${key.uppercase()}", it, true) }
        }
        super.onCreate(savedInstanceState)
    }
}
