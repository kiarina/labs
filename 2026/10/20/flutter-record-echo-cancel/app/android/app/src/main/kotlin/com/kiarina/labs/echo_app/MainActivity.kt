package com.kiarina.labs.echo_app

import android.os.Bundle
import android.system.Os
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    // Lab autorun: `adb shell am start -n <pkg>/.MainActivity --es config <base64 JSON>`
    // exports the config as ECHO_CONFIG for the Dart side.
    override fun onCreate(savedInstanceState: Bundle?) {
        intent?.getStringExtra("config")?.let {
            val json = String(Base64.decode(it, Base64.URL_SAFE or Base64.NO_WRAP))
            Os.setenv("ECHO_CONFIG", json, true)
        }
        super.onCreate(savedInstanceState)
    }
}
