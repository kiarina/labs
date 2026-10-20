package com.kiarina.labs.tts_app

import android.os.Bundle
import android.system.Os
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    // Lab autorun: `adb shell am start -n <pkg>/.MainActivity --es config <base64 JSON>`
    // exports the config as TTS_CONFIG for the Dart side.
    override fun onCreate(savedInstanceState: Bundle?) {
        intent?.getStringExtra("config")?.let {
            Os.setenv("TTS_CONFIG", String(Base64.decode(it, Base64.URL_SAFE or Base64.NO_WRAP)), true)
        }
        super.onCreate(savedInstanceState)
    }
}
