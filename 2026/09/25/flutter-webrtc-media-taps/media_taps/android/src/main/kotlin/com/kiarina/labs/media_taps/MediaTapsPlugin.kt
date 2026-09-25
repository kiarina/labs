package com.kiarina.labs.media_taps

import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.audio.LocalAudioTrack
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.webrtc.AudioTrack
import org.webrtc.AudioTrackSink
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Attaches sinks to flutter_webrtc's native tracks. Everything the sinks see is
 * summarised in counters (and optionally copied into bounded queues); Dart
 * pulls it with `poll`. All channel calls run on the platform thread, where
 * flutter_webrtc also mutates its track maps.
 */
class MediaTapsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private val taps = HashMap<Int, Tap>()
    private var nextId = 1

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "media_taps")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        taps.values.forEach { it.detach() }
        taps.clear()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "attach" -> result.success(attach(call))
                "detach" -> {
                    taps.remove(call.argument<Int>("id"))?.detach()
                    result.success(null)
                }
                "poll" -> result.success(taps.values.map { it.drain() })
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("media_taps", e.toString(), null)
        }
    }

    private fun attach(call: MethodCall): Int {
        val trackId = call.argument<String>("trackId")!!
        val kind = call.argument<String>("kind")!!
        val local = call.argument<Boolean>("local")!!
        val convertWidth = call.argument<Int>("convertWidth") ?: 0
        val deliver = call.argument<Boolean>("deliver") ?: false
        val plugin = FlutterWebRTCPlugin.sharedSingleton
            ?: throw IllegalStateException("flutter_webrtc is not registered")
        val id = nextId++
        // Remote tracks: use the stream-backed registry. Wrappers from the
        // transceiver fallback are disposed by later getTransceivers() calls,
        // which silently removes their sinks.
        val tap: Tap = if (kind == "video") {
            val track = (if (local) plugin.getLocalTrack(trackId)?.track else plugin.getRemoteTrack(trackId))
                as? VideoTrack ?: throw IllegalArgumentException("no video track $trackId")
            VideoTap(id, track, convertWidth, deliver)
        } else if (local) {
            val track = plugin.getLocalTrack(trackId) as? LocalAudioTrack
                ?: throw IllegalArgumentException("no local audio track $trackId")
            LocalAudioTap(id, track, deliver)
        } else {
            val track = plugin.getRemoteTrack(trackId) as? AudioTrack
                ?: throw IllegalArgumentException("no remote audio track $trackId")
            RemoteAudioTap(id, track, deliver)
        }
        taps[id] = tap
        return id
    }
}

private abstract class Tap(val id: Int, val kind: String) {
    protected val lock = Any()
    protected val counters = HashMap<String, Any?>()

    protected fun inc(key: String, by: Long = 1) {
        counters[key] = ((counters[key] as? Long) ?: 0L) + by
    }

    abstract fun detach()
    abstract fun drain(): Map<String, Any?>
}

private class VideoTap(
    id: Int,
    private val track: VideoTrack,
    private val convertWidth: Int,
    private val deliver: Boolean,
) : Tap(id, "video"), VideoSink {
    private val queue = ArrayDeque<Map<String, Any>>()

    init {
        track.addSink(this)
    }

    override fun onFrame(frame: VideoFrame) {
        val buffer = frame.buffer
        val w = buffer.width
        val h = buffer.height
        var luma: ByteArray? = null
        var dw = 0
        var dh = 0
        var us = 0L
        if (convertWidth != 0) {
            val t0 = System.nanoTime()
            dw = if (convertWidth < 0) w else convertWidth
            dh = (h * dw / w) and 1.inv()
            // cropAndScale first: on a TextureBuffer it is only a matrix change,
            // so the GPU readback in toI420() happens at the small size.
            val scaled = if (dw == w && dh == h) buffer.also { it.retain() }
            else buffer.cropAndScale(0, 0, w, h, dw, dh)
            val i420 = scaled.toI420()
            scaled.release()
            if (i420 != null) {
                val out = ByteArray(dw * dh)
                val y = i420.dataY
                val stride = i420.strideY
                for (row in 0 until dh) {
                    y.position(row * stride)
                    y.get(out, row * dw, dw)
                }
                i420.release()
                luma = out
            }
            us = (System.nanoTime() - t0) / 1000
        }
        synchronized(lock) {
            inc("callbacks")
            counters["width"] = w
            counters["height"] = h
            counters["rotation"] = frame.rotation
            counters["bufferType"] = when (buffer) {
                is VideoFrame.TextureBuffer -> "texture-${buffer.type.name.lowercase()}"
                is VideoFrame.I420Buffer -> "i420"
                else -> buffer.javaClass.simpleName
            }
            if (convertWidth != 0) {
                inc("convertCount")
                inc("convertUsTotal", us)
                counters["convertUsMax"] = max((counters["convertUsMax"] as? Long) ?: 0L, us)
            }
            if (deliver && luma != null) {
                if (queue.size >= MAX_FRAMES) {
                    queue.removeFirst()
                    inc("droppedToDart")
                }
                queue.addLast(mapOf("width" to dw, "height" to dh, "luma" to luma))
            }
        }
    }

    override fun detach() {
        if (!track.isDisposed) track.removeSink(this)
    }

    override fun drain(): Map<String, Any?> = synchronized(lock) {
        val frames = queue.toList()
        queue.clear()
        mapOf("id" to id, "kind" to kind, "counters" to HashMap(counters), "frames" to frames)
    }

    companion object {
        const val MAX_FRAMES = 8
    }
}

private abstract class AudioTap(id: Int, private val deliver: Boolean) : Tap(id, "audio"), AudioTrackSink {
    private var sumSquares = 0.0
    private var samples = 0L
    private val pcm = java.io.ByteArrayOutputStream()

    override fun onData(
        audioData: ByteBuffer, bitsPerSample: Int, sampleRate: Int,
        numberOfChannels: Int, numberOfFrames: Int, absoluteCaptureTimestampMs: Long,
    ) {
        val n = numberOfFrames * numberOfChannels
        val bytes = n * bitsPerSample / 8
        val data = audioData.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        var sq = 0.0
        if (bitsPerSample == 16) {
            for (i in 0 until n) {
                val s = data.getShort(data.position() + i * 2).toDouble()
                sq += s * s
            }
        }
        synchronized(lock) {
            inc("callbacks")
            counters["sampleRate"] = sampleRate
            counters["channels"] = numberOfChannels
            counters["framesPerChunk"] = numberOfFrames
            counters["bitsPerSample"] = bitsPerSample
            sumSquares += sq
            samples += n
            if (deliver) {
                if (pcm.size() + bytes > MAX_PCM_BYTES) {
                    inc("droppedToDart")
                } else {
                    val chunk = ByteArray(bytes)
                    data.position(data.position())
                    data.get(chunk, 0, minOf(bytes, data.remaining()))
                    pcm.write(chunk)
                }
            }
        }
    }

    override fun drain(): Map<String, Any?> = synchronized(lock) {
        counters["rms"] = if (samples == 0L) null else sqrt(sumSquares / samples) / 32768.0
        sumSquares = 0.0
        samples = 0
        val out = mutableMapOf<String, Any?>("id" to id, "kind" to kind, "counters" to HashMap(counters))
        if (pcm.size() > 0) {
            out["pcm"] = pcm.toByteArray()
            pcm.reset()
        }
        out
    }

    companion object {
        const val MAX_PCM_BYTES = 96_000
    }
}

/** Raw mic samples fanned out by flutter_webrtc's LocalAudioTrack (before APM). */
private class LocalAudioTap(id: Int, private val track: LocalAudioTrack, deliver: Boolean) :
    AudioTap(id, deliver) {
    init {
        track.addSink(this)
    }

    override fun detach() = track.removeSink(this)
}

/** Decoded per-track PCM before mixing (native AudioTrack sink). */
private class RemoteAudioTap(id: Int, private val track: AudioTrack, deliver: Boolean) :
    AudioTap(id, deliver) {
    init {
        track.addSink(this)
    }

    override fun detach() {
        if (!track.isDisposed) track.removeSink(this)
    }
}
