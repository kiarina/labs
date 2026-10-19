package jp.kiarina.pcm_asr

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import android.speech.ModelDownloadListener
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import java.util.concurrent.Executors

/**
 * One request = one `startListening` on `android.speech.SpeechRecognizer`
 * with the PCM delivered through a pipe (`RecognizerIntent.EXTRA_AUDIO_SOURCE`,
 * API 33). The microphone is never opened. The session ends when the write
 * end of the pipe is closed; `stopListening` is never called (Google's
 * on-device recognizer answers it with ERROR_CLIENT).
 *
 * Audio is written at real-time pace by default: Google's recognizers drop
 * the utterance (ERROR_NO_MATCH) when the whole clip arrives at once.
 * `PACE` lets the lab measure whether faster delivery is tolerated.
 *
 * Requests are serialized on one recognizer instance: the framework allows
 * one session per listener and a second instance per client has been seen to
 * kill the live session.
 */
class SpeechRecognizerEngine(private val context: Context) {
  companion object {
    const val ENGINE_ID = "android.speech-recognizer"
    private const val TAG = "pcm_asr"
    /**
     * 1.0 = real time, 0 = as fast as the pipe accepts. Field reports said Google's
     * recognizers need real-time delivery; on a Pixel 6 (Android 17) the lab got the
     * same text at 0 with a sixth of the latency, so 0 is the default here. The writer
     * always waits for onReadyForSpeech first: closing the pipe before the service
     * opened it stalled the session.
     */
    @JvmStatic var PACE = 0.0
    /** Silence written after the segment before the pipe is closed; closing right away cut the last syllable. */
    @JvmStatic var TAIL_MS = 600L
    private const val CHUNK_MS = 100L
    /** A session with no speech never ends after the pipe closes; end it ourselves after this. */
    @JvmStatic var SILENCE_WATCHDOG_MS = 8000L
  }

  private val main = Handler(Looper.getMainLooper())
  private var recognizer: SpeechRecognizer? = null
  private var onDevice = false
  private val queue = ArrayDeque<Request>()
  private var current: Request? = null

  private class Request(
    val id: String,
    val locale: String,
    val pcm: ByteArray,
    val sampleRate: Int,
    val channels: Int,
    val reply: Reply,
  ) {
    var startedAt = 0L
    var lastPartial: String? = null
    var finalText: String? = null
    var readFd: ParcelFileDescriptor? = null
    var writeFd: ParcelFileDescriptor? = null
    var retries = 0
    @Volatile var cancelled = false
    /** Set when the request has been answered; the writer stops and the pipe is closed. */
    @Volatile var done = false
    @Volatile var ready = java.util.concurrent.CountDownLatch(1)
    fun readyReset() { ready = java.util.concurrent.CountDownLatch(1) }
  }

  // MARK: support / prepare

  fun support(locale: String, reply: Reply) {
    val out = HashMap<String, Any?>()
    out["engine"] = ENGINE_ID
    out["supported"] = false
    out["accepts_external_pcm"] = true
    out["on_device"] = false
    out["model_state"] = "unknown"
    out["locale"] = null
    out["sample_rates"] = listOf(16000)
    out["needs_network_for_model"] = true
    out["reason"] = null
    if (Build.VERSION.SDK_INT < 33) {
      out["engine"] = "none"
      out["reason"] = "os_too_old"
      reply.success(out); return
    }
    if (!SpeechRecognizer.isRecognitionAvailable(context)) {
      out["reason"] = "engine_unavailable"
      reply.success(out); return
    }
    val localOk = SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
    out["on_device"] = localOk
    main.post {
      try {
        val probe = if (localOk) SpeechRecognizer.createOnDeviceSpeechRecognizer(context) else SpeechRecognizer.createSpeechRecognizer(context)
        probe.checkRecognitionSupport(intentFor(locale, null), Executors.newSingleThreadExecutor(), object : RecognitionSupportCallback {
          override fun onSupportResult(support: RecognitionSupport) {
            main.post { probe.destroy() }
            val tag = matchLocale(locale, support)
            out["locale"] = tag
            when {
              tag != null && support.installedOnDeviceLanguages.any { it.equals(tag, true) } -> { out["model_state"] = "installed"; out["supported"] = true }
              tag != null && support.pendingOnDeviceLanguages.any { it.equals(tag, true) } -> { out["model_state"] = "installing"; out["supported"] = true }
              tag != null && support.supportedOnDeviceLanguages.any { it.equals(tag, true) } -> { out["model_state"] = "downloadable"; out["supported"] = true }
              tag != null && support.onlineLanguages.any { it.equals(tag, true) } -> { out["model_state"] = "unknown"; out["on_device"] = false; out["supported"] = !localOk }
              else -> { out["model_state"] = "unavailable"; out["reason"] = "unsupported_locale" }
            }
            reply.success(out)
          }
          override fun onError(error: Int) {
            main.post { probe.destroy() }
            out["reason"] = "support_check_failed_$error"
            reply.success(out)
          }
        })
      } catch (e: Exception) {
        out["reason"] = "engine_unavailable"
        reply.success(out)
      }
    }
  }

  private fun matchLocale(wanted: String, support: RecognitionSupport): String? {
    val all = support.installedOnDeviceLanguages + support.pendingOnDeviceLanguages + support.supportedOnDeviceLanguages + support.onlineLanguages
    val norm = wanted.replace('_', '-')
    return all.firstOrNull { it.equals(norm, true) }
      ?: all.firstOrNull { it.substringBefore('-').equals(norm.substringBefore('-'), true) }
  }

  fun prepare(locale: String, reply: Reply) {
    if (Build.VERSION.SDK_INT < 33) { reply.error("unsupportedPlatform", "SpeechRecognizer EXTRA_AUDIO_SOURCE needs API 33"); return }
    main.post {
      val probe = try {
        if (SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) SpeechRecognizer.createOnDeviceSpeechRecognizer(context) else SpeechRecognizer.createSpeechRecognizer(context)
      } catch (e: Exception) { reply.error("unsupportedPlatform", e.toString()); return@post }
      val executor = Executors.newSingleThreadExecutor()
      val intent = intentFor(locale, null)
      probe.checkRecognitionSupport(intent, executor, object : RecognitionSupportCallback {
        override fun onSupportResult(support: RecognitionSupport) {
          val tag = matchLocale(locale, support)
          if (tag == null) { main.post { probe.destroy() }; reply.error("unsupportedLocale", "no recognizer language for $locale"); return }
          if (support.installedOnDeviceLanguages.any { it.equals(tag, true) } || !SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
            main.post { probe.destroy() }; reply.success(emptyMap()); return
          }
          if (!support.supportedOnDeviceLanguages.any { it.equals(tag, true) } && !support.pendingOnDeviceLanguages.any { it.equals(tag, true) }) {
            main.post { probe.destroy() }; reply.error("modelUnavailable", "$tag is not downloadable on this device"); return
          }
          // The listener is unreliable on Pixel (only onScheduled seen); poll checkRecognitionSupport.
          main.post {
            if (Build.VERSION.SDK_INT >= 34) {
              probe.triggerModelDownload(intentFor(tag, null), executor, object : ModelDownloadListener {
                override fun onProgress(completedPercent: Int) {}
                override fun onSuccess() {}
                override fun onScheduled() {}
                override fun onError(error: Int) {}
              })
            } else {
              probe.triggerModelDownload(intentFor(tag, null))
            }
            pollInstalled(probe, tag, executor, reply, deadline = SystemClock.elapsedRealtime() + 180_000)
          }
        }
        override fun onError(error: Int) { main.post { probe.destroy() }; reply.error("engineFailure", "checkRecognitionSupport error $error") }
      })
    }
  }

  private fun pollInstalled(probe: SpeechRecognizer, tag: String, executor: java.util.concurrent.Executor, reply: Reply, deadline: Long) {
    main.postDelayed({
      probe.checkRecognitionSupport(intentFor(tag, null), executor, object : RecognitionSupportCallback {
        override fun onSupportResult(support: RecognitionSupport) {
          if (support.installedOnDeviceLanguages.any { it.equals(tag, true) }) { main.post { probe.destroy() }; reply.success(emptyMap()) }
          else if (SystemClock.elapsedRealtime() > deadline) { main.post { probe.destroy() }; reply.error("modelUnavailable", "$tag did not finish installing in time") }
          else pollInstalled(probe, tag, executor, reply, deadline)
        }
        override fun onError(error: Int) { main.post { probe.destroy() }; reply.error("engineFailure", "checkRecognitionSupport error $error") }
      })
    }, 1000)
  }

  // MARK: transcribe

  fun transcribe(id: String, locale: String, pcm: ByteArray, sampleRate: Int, channels: Int, reply: Reply) {
    if (Build.VERSION.SDK_INT < 33) { reply.error("unsupportedPlatform", "SpeechRecognizer EXTRA_AUDIO_SOURCE needs API 33"); return }
    if (pcm.isEmpty() || channels < 1 || pcm.size % (2 * channels) != 0) { reply.error("invalidPcm", "pcm16le must hold whole frames"); return }
    val request = Request(id, locale, pcm, sampleRate, channels, reply)
    main.post {
      if (queue.any { it.id == id } || current?.id == id) { reply.error("engineFailure", "request id already running: $id"); return@post }
      queue.addLast(request)
      pump()
    }
  }

  fun cancel(id: String) = main.post {
    queue.firstOrNull { it.id == id }?.let { queue.remove(it); it.reply.error("cancelled", "cancelled: $id") }
    current?.takeIf { it.id == id }?.let { r ->
      r.cancelled = true
      recognizer?.cancel()
      finish(r, error = "cancelled" to "cancelled: $id")
    }
  }

  fun dispose() = main.post {
    queue.forEach { it.reply.error("cancelled", "disposed") }
    queue.clear()
    current?.let { r -> r.cancelled = true; finish(r, error = "cancelled" to "disposed") }
    recognizer?.destroy()
    recognizer = null
  }

  private fun ensureRecognizer(): SpeechRecognizer {
    recognizer?.let { return it }
    onDevice = SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
    val r = if (onDevice) SpeechRecognizer.createOnDeviceSpeechRecognizer(context) else SpeechRecognizer.createSpeechRecognizer(context)
    r.setRecognitionListener(listener)
    recognizer = r
    return r
  }

  /** Main thread only. */
  private fun pump() {
    if (current != null) return
    val r = queue.removeFirstOrNull() ?: return
    current = r
    try {
      r.readyReset()
      r.done = false
      val pipe = ParcelFileDescriptor.createPipe()
      r.readFd = pipe[0]
      r.writeFd = pipe[1]
      val intent = intentFor(r.locale, r)
      r.startedAt = SystemClock.elapsedRealtime()
      Log.d(TAG, "startListening ${r.id} bytes=${r.pcm.size}")
      ensureRecognizer().startListening(intent)
      // One thread per request: a writer blocked on a dead pipe must not delay the next request.
      Thread({ write(r) }, "pcm_asr-writer").start()
    } catch (e: Exception) {
      finish(r, error = "engineFailure" to e.toString())
    }
  }

  private fun write(r: Request) {
    val out = ParcelFileDescriptor.AutoCloseOutputStream(r.writeFd)
    try {
      // Do not close the pipe before the service has opened it.
      val ready = r.ready.await(5, java.util.concurrent.TimeUnit.SECONDS)
      Log.d(TAG, "write ${r.id} begins ready=$ready done=${r.done}")
      if (r.done) return
      val bytesPerMs = r.sampleRate * r.channels * 2 / 1000
      val chunk = (bytesPerMs * CHUNK_MS).toInt()
      val tail = ByteArray((bytesPerMs * TAIL_MS).toInt())
      val origin = SystemClock.elapsedRealtime()
      var written = 0L
      for (data in listOf(r.pcm, tail)) {
        var offset = 0
        while (offset < data.size && !r.cancelled && !r.done) {
          val n = minOf(chunk, data.size - offset)
          out.write(data, offset, n)
          out.flush()
          offset += n
          written += n
          val due = origin + (written * PACE / bytesPerMs).toLong()
          val wait = due - SystemClock.elapsedRealtime()
          if (wait > 0) Thread.sleep(wait)
        }
      }
    } catch (e: Exception) {
      main.post { if (current === r) finish(r, error = "engineFailure" to "pipe write failed: $e") }
    } finally {
      try { out.close() } catch (_: Exception) {}
      Log.d(TAG, "write ${r.id} closed pipe after ${SystemClock.elapsedRealtime() - r.startedAt} ms")
      main.postDelayed({
        if (current === r && !r.cancelled) {
          // Nothing came back after the audio ended: treat it as "no speech".
          Log.d(TAG, "watchdog ${r.id}")
          recognizer?.cancel()
          finish(r, text = r.finalText ?: r.lastPartial ?: "", source = "watchdog")
        }
      }, SILENCE_WATCHDOG_MS)
    }
  }

  private fun intentFor(locale: String, r: Request?): Intent {
    val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
    intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
    intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale.replace('_', '-'))
    intent.putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
    intent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
    intent.putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
    if (r != null) {
      intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, r.readFd)
      intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, r.channels)
      intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
      intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, r.sampleRate)
    }
    return intent
  }

  private val listener = object : RecognitionListener {
    override fun onReadyForSpeech(params: Bundle?) { Log.d(TAG, "onReadyForSpeech ${current?.id}"); current?.ready?.countDown() }
    override fun onBeginningOfSpeech() {}
    override fun onRmsChanged(rmsdB: Float) {}
    override fun onBufferReceived(buffer: ByteArray?) {}
    override fun onEndOfSpeech() { Log.d(TAG, "onEndOfSpeech ${current?.id}") }

    override fun onPartialResults(partialResults: Bundle?) {
      val r = current ?: return
      val list = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
      Log.d(TAG, "onPartialResults ${r.id} final=${partialResults?.getBoolean("final_result", false)} ${list?.firstOrNull()}")
      val text = list?.firstOrNull { it.isNotBlank() } ?: return
      r.lastPartial = text
      // Google's recognizers mark the settled hypothesis with final_result=true.
      if (partialResults.getBoolean("final_result", false)) r.finalText = text
    }

    override fun onResults(results: Bundle?) {
      val r = current ?: return
      Log.d(TAG, "onResults ${r.id} ${results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)}")
      val list = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
      val text = list?.firstOrNull { it.isNotBlank() } ?: r.finalText ?: r.lastPartial ?: ""
      finish(r, text = text, source = if (list?.firstOrNull { it.isNotBlank() } != null) "onResults" else if (r.finalText != null) "final_partial" else "last_partial")
    }

    override fun onError(error: Int) {
      val r = current ?: return
      Log.d(TAG, "onError ${r.id} $error")
      if (r.cancelled) return
      when (error) {
        SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT ->
          finish(r, text = r.finalText ?: r.lastPartial ?: "", source = "error_$error")
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
          finish(r, error = "engineFailure" to "recognizer ignored EXTRA_AUDIO_SOURCE and asked for the microphone (error $error)")
        SpeechRecognizer.ERROR_SERVER_DISCONNECTED, SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> {
          // The service connection was lost (seen after cancel()); retry once on a fresh recognizer.
          if (r.retries < 3) {
            r.retries++
            current = null
            r.done = true
            r.ready.countDown()
            try { r.writeFd?.close() } catch (_: Exception) {}
            try { r.readFd?.close() } catch (_: Exception) {}
            recognizer?.destroy()
            recognizer = null
            queue.addFirst(r)
            main.postDelayed({ pump() }, 300L * r.retries)
          } else finish(r, error = "engineFailure" to "SpeechRecognizer error $error after ${r.retries} retries")
        }
        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> finish(r, error = "unsupportedLocale" to "error $error")
        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> finish(r, error = "modelUnavailable" to "error $error")
        else -> finish(r, error = "engineFailure" to "SpeechRecognizer error $error")
      }
    }

    override fun onEvent(eventType: Int, params: Bundle?) {}
  }

  /** Main thread only. Completes the current request and starts the next. */
  private fun finish(r: Request, text: String? = null, source: String? = null, error: Pair<String, String>? = null) {
    if (current !== r) return
    current = null
    r.done = true
    r.ready.countDown()
    // Closing both ends unblocks a writer stuck on a pipe nobody reads.
    try { r.writeFd?.close() } catch (_: Exception) {}
    try { r.readFd?.close() } catch (_: Exception) {}
    if (error != null) {
      r.reply.error(error.first, error.second)
    } else {
      val elapsed = SystemClock.elapsedRealtime() - r.startedAt
      r.reply.success(mapOf(
        "id" to r.id,
        "text" to (text ?: ""),
        "engine" to ENGINE_ID + (if (onDevice) "/on-device" else "/default"),
        "locale" to r.locale,
        "elapsed_ms" to elapsed.toDouble(),
        "ranges" to emptyList<Any>(),
        "source" to source,
      ))
    }
    if (error != null) {
      // Reset the service connection after a failure or cancel; the next request recreates it.
      recognizer?.destroy()
      recognizer = null
    }
    pump()
  }
}
