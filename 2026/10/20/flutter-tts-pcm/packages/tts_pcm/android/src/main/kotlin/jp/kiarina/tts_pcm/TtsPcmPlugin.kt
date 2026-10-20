package jp.kiarina.tts_pcm

import android.content.Context
import android.media.AudioFormat
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale

/**
 * Method channel `tts_pcm`. Synthesis uses `TextToSpeech.synthesizeToFile`;
 * the PCM is forwarded from `onAudioAvailable` while the engine renders it,
 * and the file is deleted afterwards. The engine is shared, so voice,
 * language and rate apply to the request being started, and `cancel` stops
 * everything the engine is doing.
 */
class TtsPcmPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var channel: MethodChannel
  private lateinit var context: Context
  private val main = Handler(Looper.getMainLooper())
  private var tts: TextToSpeech? = null
  private var ready = false
  private val pending = mutableListOf<() -> Unit>()

  private class Job(val file: File) {
    var sampleRate = 0
    var format = AudioFormat.ENCODING_PCM_16BIT
    var channels = 1
    var formatLabel = ""
  }

  private val jobs = mutableMapOf<String, Job>()

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "tts_pcm")
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    tts?.shutdown()
    tts = null
  }

  /** Runs [block] once the engine has initialized (or failed: then [onError]). */
  private fun withEngine(onError: (String) -> Unit, block: (TextToSpeech) -> Unit) {
    val engine = tts
    if (engine != null && ready) {
      block(engine)
      return
    }
    pending.add { tts?.let(block) ?: onError("TextToSpeech is not available") }
    if (engine != null) return
    tts = TextToSpeech(context) { status ->
      main.post {
        if (status == TextToSpeech.SUCCESS) {
          ready = true
          tts?.setOnUtteranceProgressListener(listener)
        } else {
          tts = null
        }
        val run = pending.toList()
        pending.clear()
        run.forEach { it() }
      }
    }
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "voices" -> withEngine({ result.error("unavailable", it, null) }) { engine ->
        result.success(engine.voices.orEmpty().map { v ->
          mapOf(
            "id" to v.name,
            "name" to v.name,
            "language" to v.locale.toLanguageTag(),
            "quality" to "${v.quality}${if (v.isNetworkConnectionRequired) " network" else ""}",
          )
        })
      }
      "synthesize" -> {
        val id = call.argument<String>("id")!!
        val text = call.argument<String>("text")!!
        val language = call.argument<String>("language")
        val voice = call.argument<String>("voice")
        val rate = call.argument<Double>("rate") ?: 1.0
        withEngine({ result.error("unavailable", it, null) }) { engine ->
          val v = voice?.let { name -> engine.voices.orEmpty().firstOrNull { it.name == name } }
          if (v != null) engine.voice = v
          else if (language != null) engine.language = Locale.forLanguageTag(language)
          engine.setSpeechRate(rate.toFloat())
          val file = File(context.cacheDir, "tts_pcm_$id.wav")
          jobs[id] = Job(file)
          val code = engine.synthesizeToFile(text, Bundle(), file, id)
          if (code != TextToSpeech.SUCCESS) {
            jobs.remove(id)?.file?.delete()
            result.error("failed", "synthesizeToFile returned $code", null)
          } else {
            result.success(null)
          }
        }
      }
      "cancel" -> {
        val id = call.argument<String>("id")!!
        if (jobs.remove(id) != null) tts?.stop()
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  private val listener = object : UtteranceProgressListener() {
    override fun onStart(utteranceId: String) {}

    override fun onBeginSynthesis(utteranceId: String, sampleRateInHz: Int, audioFormat: Int, channelCount: Int) {
      main.post {
        jobs[utteranceId]?.let {
          it.sampleRate = sampleRateInHz
          it.format = audioFormat
          it.channels = channelCount
          val f = when (audioFormat) {
            AudioFormat.ENCODING_PCM_16BIT -> "int16"
            AudioFormat.ENCODING_PCM_FLOAT -> "float32"
            AudioFormat.ENCODING_PCM_8BIT -> "uint8"
            else -> "fmt$audioFormat"
          }
          it.formatLabel = "$f $sampleRateInHz Hz $channelCount ch"
        }
      }
    }

    override fun onAudioAvailable(utteranceId: String, audio: ByteArray) {
      main.post {
        val job = jobs[utteranceId] ?: return@post
        channel.invokeMethod(
          "chunk",
          mapOf(
            "id" to utteranceId,
            "pcm" to int16Mono(audio, job.format, job.channels),
            "sampleRate" to job.sampleRate,
            "format" to job.formatLabel,
          ),
        )
      }
    }

    override fun onDone(utteranceId: String) {
      main.post {
        jobs.remove(utteranceId)?.file?.delete() ?: return@post
        channel.invokeMethod("done", mapOf("id" to utteranceId))
      }
    }

    @Deprecated("Deprecated in Java")
    override fun onError(utteranceId: String) = onError(utteranceId, -1)

    override fun onError(utteranceId: String, errorCode: Int) {
      main.post {
        jobs.remove(utteranceId)?.file?.delete() ?: return@post
        channel.invokeMethod("error", mapOf("id" to utteranceId, "message" to "TextToSpeech error $errorCode"))
      }
    }

    override fun onStop(utteranceId: String, interrupted: Boolean) {
      main.post { jobs.remove(utteranceId)?.file?.delete() }
    }
  }

  /** First channel as 16-bit little-endian PCM. */
  private fun int16Mono(audio: ByteArray, format: Int, channels: Int): ByteArray {
    val inBuf = ByteBuffer.wrap(audio).order(ByteOrder.LITTLE_ENDIAN)
    val frames = when (format) {
      AudioFormat.ENCODING_PCM_FLOAT -> audio.size / 4 / channels
      AudioFormat.ENCODING_PCM_8BIT -> audio.size / channels
      else -> audio.size / 2 / channels
    }
    if (format == AudioFormat.ENCODING_PCM_16BIT && channels == 1) return audio
    val out = ByteBuffer.allocate(frames * 2).order(ByteOrder.LITTLE_ENDIAN)
    for (i in 0 until frames) {
      val v: Int = when (format) {
        AudioFormat.ENCODING_PCM_FLOAT ->
          (inBuf.getFloat(i * channels * 4).coerceIn(-1f, 1f) * 32767).toInt()
        AudioFormat.ENCODING_PCM_8BIT -> ((audio[i * channels].toInt() and 0xff) - 128) shl 8
        else -> inBuf.getShort(i * channels * 2).toInt()
      }
      out.putShort(v.toShort())
    }
    return out.array()
  }
}
