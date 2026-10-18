package com.kiarina.labs.external_aec_app

import android.os.Bundle
import android.view.WindowManager
import android.util.Log
import android.system.Os
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    // Lab autorun: `adb shell am start -n <pkg>/.MainActivity --es scenario all ...`
    // exports the extras as EXTERNAL_* environment variables for the Dart side.
    override fun onCreate(savedInstanceState: Bundle?) {
        val extras = intent?.extras
        for (key in listOf("synthetic", "exit")) {
            extras?.getString(key)?.let { Os.setenv("EXTERNAL_${key.uppercase()}", it, true) }
        }
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
    override fun onResume() { super.onResume(); Log.i("AEC_LIFECYCLE", "resume") }
    override fun onPause() { Log.i("AEC_LIFECYCLE", "pause"); super.onPause() }
    override fun onStop() { Log.i("AEC_LIFECYCLE", "stop"); super.onStop() }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        Log.i("AEC_LIFECYCLE", "windowFocus=$hasFocus")
    }
}
