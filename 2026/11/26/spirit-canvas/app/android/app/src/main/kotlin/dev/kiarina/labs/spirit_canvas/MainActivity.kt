package dev.kiarina.labs.spirit_canvas

import android.graphics.Bitmap
import android.graphics.Canvas
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Pictures of the `web` elements' pages (see the macOS and iOS
        // Runners): the page's android.webkit.WebView, from
        // webview_flutter_android's external API (the Dart side's
        // AndroidWebViewController.webViewIdentifier), drawn into a bitmap.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "spirit_canvas/webview")
            .setMethodCallHandler { call, result ->
                if (call.method != "snapshot") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val id = (call.argument<Number>("id") ?: run {
                    result.error("bad_args", "no id", null)
                    return@setMethodCallHandler
                }).toLong()
                val web = WebViewFlutterAndroidExternalApi.getWebView(flutterEngine, id)
                if (web == null) {
                    result.error("no_webview", "no web view $id", null)
                    return@setMethodCallHandler
                }
                if (web.width <= 0 || web.height <= 0) {
                    result.error("snapshot_failed", "the web view has no size yet", null)
                    return@setMethodCallHandler
                }
                try {
                    val bitmap = Bitmap.createBitmap(web.width, web.height, Bitmap.Config.ARGB_8888)
                    web.draw(Canvas(bitmap))
                    val png = ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, png)
                    bitmap.recycle()
                    result.success(png.toByteArray())
                } catch (e: Exception) {
                    result.error("snapshot_failed", e.toString(), null)
                }
            }
    }
}
