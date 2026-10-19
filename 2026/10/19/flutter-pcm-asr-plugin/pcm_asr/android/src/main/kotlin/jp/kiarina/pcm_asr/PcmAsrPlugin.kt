package jp.kiarina.pcm_asr

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Method channel `pcm_asr`. Every reply is a map; every failure is an error
 * whose code is one of the Dart `PcmAsrErrorCode` names.
 */
class PcmAsrPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var channel: MethodChannel
  private lateinit var context: Context
  private var engine: SpeechRecognizerEngine? = null
  private val main = Handler(Looper.getMainLooper())

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "pcm_asr")
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    engine?.dispose()
    engine = null
  }

  private fun engine(): SpeechRecognizerEngine {
    engine?.let { return it }
    return SpeechRecognizerEngine(context).also { engine = it }
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    val reply = Reply(result, main)
    try {
      when (call.method) {
        "support" -> engine().support(call.argument<String>("locale") ?: "", reply)
        "prepare" -> engine().prepare(call.argument<String>("locale") ?: "", reply)
        "transcribe" -> {
          val id = call.argument<String>("id")
          val locale = call.argument<String>("locale")
          val pcm = call.argument<ByteArray>("pcm16le")
          val sampleRate = call.argument<Int>("sample_rate")
          val channels = call.argument<Int>("channels")
          if (id == null || locale == null || pcm == null || sampleRate == null || channels == null) {
            reply.error("invalidPcm", "missing id, locale, pcm16le, sample_rate or channels")
            return
          }
          engine().transcribe(id, locale, pcm, sampleRate, channels, reply)
        }
        "cancel" -> {
          engine?.cancel(call.argument<String>("id") ?: "")
          reply.success(emptyMap<String, Any?>())
        }
        "dispose" -> {
          engine?.dispose()
          engine = null
          reply.success(emptyMap<String, Any?>())
        }
        else -> result.notImplemented()
      }
    } catch (e: Exception) {
      reply.error("engineFailure", e.toString())
    }
  }
}

/** Replies once, on the main thread. */
class Reply(private val result: MethodChannel.Result, private val main: Handler) {
  private var done = false

  fun success(value: Map<String, Any?>) = main.post {
    if (!done) { done = true; result.success(value) }
  }

  fun error(code: String, message: String) = main.post {
    if (!done) { done = true; result.error(code, message, null) }
  }
}
