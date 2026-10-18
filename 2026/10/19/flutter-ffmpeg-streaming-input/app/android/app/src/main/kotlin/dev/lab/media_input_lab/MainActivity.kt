package dev.lab.streaming_input_lab
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
class MainActivity: FlutterActivity() {
 override fun configureFlutterEngine(engine: FlutterEngine) {
  super.configureFlutterEngine(engine)
  MethodChannel(engine.dartExecutor.binaryMessenger,"streaming_lab/input").setMethodCallHandler { call,result ->
   if(call.method!="path") { result.notImplemented() } else {
    Thread {
     try {
      val out=File(cacheDir,"long.mp4")
      if(!out.exists()) assets.open("flutter_assets/assets/long.mp4").use { input -> out.outputStream().use { output -> input.copyTo(output,65536) } }
      runOnUiThread { result.success(out.absolutePath) }
     } catch(e:Exception) { runOnUiThread { result.error("input",e.toString(),null) } }
    }.start()
   }
  }
 }
}
