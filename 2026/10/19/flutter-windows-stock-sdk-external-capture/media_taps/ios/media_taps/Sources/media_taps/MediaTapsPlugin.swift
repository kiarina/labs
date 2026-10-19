// Shared by iOS and macOS (macos/ holds an identical copy).
import AVFoundation
import WebRTC
import flutter_webrtc

#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// Attaches sinks to flutter_webrtc's native tracks. Counters (and optional
/// bounded copies) are pulled by Dart with `poll`. Channel calls run on the
/// main thread, where flutter_webrtc also mutates its track dictionaries.
public class MediaTapsPlugin: NSObject, FlutterPlugin {
  private var taps: [Int: Tap] = [:]
  private var nextId = 1

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: "media_taps", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(MediaTapsPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "attach":
      do {
        result(try attach(args))
      } catch {
        result(FlutterError(code: "media_taps", message: "\(error)", details: nil))
      }
    case "detach":
      if let id = args["id"] as? Int { taps.removeValue(forKey: id)?.detach() }
      result(nil)
    case "poll":
      result(taps.keys.sorted().compactMap { taps[$0]?.drain() })
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private struct TapError: Error, CustomStringConvertible {
    let description: String
  }

  private func attach(_ args: [String: Any]) throws -> Int {
    guard let trackId = args["trackId"] as? String,
      let kind = args["kind"] as? String,
      let local = args["local"] as? Bool
    else { throw TapError(description: "bad arguments") }
    let convertWidth = args["convertWidth"] as? Int ?? 0
    let deliver = args["deliver"] as? Bool ?? false
    guard let plugin = FlutterWebRTCPlugin.sharedSingleton() else {
      throw TapError(description: "flutter_webrtc is not registered")
    }
    let localTrack = plugin.localTracks?[trackId] as? LocalTrack
    let id = nextId
    nextId += 1
    let tap: Tap
    if kind == "video" {
      let track = local ? localTrack?.track() : plugin.remoteTrack(forId: trackId)
      guard let video = track as? RTCVideoTrack else {
        throw TapError(description: "no video track \(trackId)")
      }
      tap = VideoTap(id: id, track: video, convertWidth: convertWidth, deliver: deliver)
    } else if local {
      // A renderer on a local RTCAudioTrack receives nothing (the local
      // source's AddSink is a no-op); flutter_webrtc routes local audio
      // through the audio processing module instead. This is process-wide.
      guard let audio = localTrack as? LocalAudioTrack else {
        throw TapError(description: "no local audio track \(trackId)")
      }
      tap = LocalAudioTap(id: id, track: audio, deliver: deliver)
    } else {
      guard let audio = plugin.remoteTrack(forId: trackId) as? RTCAudioTrack else {
        throw TapError(description: "no remote audio track \(trackId)")
      }
      tap = RemoteAudioTap(id: id, track: audio, deliver: deliver)
    }
    taps[id] = tap
    return id
  }
}

private class Tap: NSObject {
  let id: Int
  let kind: String
  let lock = NSLock()
  var counters: [String: Any] = [:]

  init(id: Int, kind: String) {
    self.id = id
    self.kind = kind
    super.init()
  }

  func inc(_ key: String, _ by: Int = 1) {
    counters[key] = (counters[key] as? Int ?? 0) + by
  }

  func detach() {}
  func drain() -> [String: Any] { [:] }
}

private func fourCC(_ value: OSType) -> String {
  let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
  return String(bytes: bytes, encoding: .ascii) ?? "\(value)"
}

private final class VideoTap: Tap, RTCVideoRenderer {
  static let maxFrames = 8
  private let track: RTCVideoTrack
  private let convertWidth: Int
  private let deliver: Bool
  private var queue: [[String: Any]] = []

  init(id: Int, track: RTCVideoTrack, convertWidth: Int, deliver: Bool) {
    self.track = track
    self.convertWidth = convertWidth
    self.deliver = deliver
    super.init(id: id, kind: "video")
    track.add(self)
  }

  func setSize(_ size: CGSize) {}

  func renderFrame(_ frame: RTCVideoFrame?) {
    guard let frame = frame else { return }
    let buffer = frame.buffer
    let w = Int(buffer.width)
    let h = Int(buffer.height)
    let bufferType: String
    if let cv = buffer as? RTCCVPixelBuffer {
      bufferType = "cvpixelbuffer-" + fourCC(CVPixelBufferGetPixelFormatType(cv.pixelBuffer))
    } else if buffer is RTCI420Buffer {
      bufferType = "i420"
    } else {
      bufferType = String(describing: type(of: buffer))
    }
    var luma: Data? = nil
    var dw = 0
    var dh = 0
    var us = 0
    if convertWidth != 0 {
      let t0 = DispatchTime.now().uptimeNanoseconds
      dw = convertWidth < 0 ? w : convertWidth
      dh = (h * dw / w) & ~1
      let scaled: RTCVideoFrameBuffer
      if dw != w || dh != h,
        let s = buffer.cropAndScale?(
          with: 0, offsetY: 0, cropWidth: Int32(w), cropHeight: Int32(h),
          scaleWidth: Int32(dw), scaleHeight: Int32(dh))
      {
        scaled = s
      } else {
        scaled = buffer
        dw = w
        dh = h
      }
      let i420 = scaled.toI420()
      var out = Data(count: dw * dh)
      out.withUnsafeMutableBytes { raw in
        let dst = raw.bindMemory(to: UInt8.self).baseAddress!
        let stride = Int(i420.strideY)
        for row in 0..<dh {
          (dst + row * dw).update(from: i420.dataY + row * stride, count: dw)
        }
      }
      luma = out
      us = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1000)
    }
    lock.lock()
    defer { lock.unlock() }
    inc("callbacks")
    counters["width"] = w
    counters["height"] = h
    counters["rotation"] = frame.rotation.rawValue
    counters["bufferType"] = bufferType
    if convertWidth != 0 {
      inc("convertCount")
      inc("convertUsTotal", us)
      counters["convertUsMax"] = max(counters["convertUsMax"] as? Int ?? 0, us)
    }
    if deliver, let luma = luma {
      if queue.count >= Self.maxFrames {
        queue.removeFirst()
        inc("droppedToDart")
      }
      queue.append(["width": dw, "height": dh, "luma": FlutterStandardTypedData(bytes: luma)])
    }
  }

  override func detach() { track.remove(self) }

  override func drain() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    let frames = queue
    queue.removeAll()
    return ["id": id, "kind": kind, "counters": counters, "frames": frames]
  }
}

private class AudioTap: Tap {
  static let maxPcmBytes = 96_000
  private let deliver: Bool
  private var sumSquares = 0.0
  private var samples = 0
  private var pcm = Data()

  init(id: Int, deliver: Bool) {
    self.deliver = deliver
    super.init(id: id, kind: "audio")
  }

  /// Called with interleaved Int16 samples.
  func record(
    _ data: UnsafePointer<Int16>, frames: Int, channels: Int, sampleRate: Int
  ) {
    let n = frames * channels
    var sq = 0.0
    for i in 0..<n {
      let s = Double(data[i])
      sq += s * s
    }
    lock.lock()
    defer { lock.unlock() }
    inc("callbacks")
    counters["sampleRate"] = sampleRate
    counters["channels"] = channels
    counters["framesPerChunk"] = frames
    counters["bitsPerSample"] = 16
    sumSquares += sq
    samples += n
    if deliver {
      if pcm.count + n * 2 > Self.maxPcmBytes {
        inc("droppedToDart")
      } else {
        data.withMemoryRebound(to: UInt8.self, capacity: n * 2) {
          pcm.append($0, count: n * 2)
        }
      }
    }
  }

  override func drain() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    counters["rms"] = samples == 0 ? NSNull() : (sqrt(sumSquares / Double(samples)) / 32768.0) as Any
    sumSquares = 0
    samples = 0
    var out: [String: Any] = ["id": id, "kind": kind, "counters": counters]
    if !pcm.isEmpty {
      out["pcm"] = FlutterStandardTypedData(bytes: pcm)
      pcm = Data()
    }
    return out
  }
}

/// Mic after echo cancellation / noise suppression, via flutter_webrtc's
/// capture post-processing hook (process-wide, not per track).
private final class LocalAudioTap: AudioTap, ExternalAudioProcessingDelegate {
  private let track: LocalAudioTrack
  private var sampleRate = 0
  private var scratch: [Int16] = []

  init(id: Int, track: LocalAudioTrack, deliver: Bool) {
    self.track = track
    super.init(id: id, deliver: deliver)
    track.addProcessing(self)
  }

  func audioProcessingInitialize(withSampleRate sampleRateHz: Int, channels: Int) {
    sampleRate = sampleRateHz
  }

  func audioProcessingProcess(_ audioBuffer: RTCAudioBuffer) {
    // Channel 0 only; float samples on the int16 scale.
    let frames = Int(audioBuffer.frames)
    let src = audioBuffer.rawBuffer(forChannel: 0)
    if scratch.count < frames { scratch = [Int16](repeating: 0, count: frames) }
    for i in 0..<frames {
      scratch[i] = Int16(max(-32768, min(32767, src[i])))
    }
    let rate = sampleRate > 0 ? sampleRate : frames * 100
    scratch.withUnsafeBufferPointer {
      record($0.baseAddress!, frames: frames, channels: 1, sampleRate: rate)
    }
  }

  func audioProcessingRelease() {}

  override func detach() { track.removeProcessing(self) }
}

/// Decoded per-track PCM before mixing.
private final class RemoteAudioTap: AudioTap, RTCAudioRenderer {
  private let track: RTCAudioTrack

  init(id: Int, track: RTCAudioTrack, deliver: Bool) {
    self.track = track
    super.init(id: id, deliver: deliver)
    track.add(self)
  }

  func render(pcmBuffer: AVAudioPCMBuffer) {
    guard let data = pcmBuffer.int16ChannelData else { return }
    // RTCAudioRendererAdapter delivers interleaved Int16 in channel 0.
    record(
      data[0], frames: Int(pcmBuffer.frameLength),
      channels: Int(pcmBuffer.format.channelCount),
      sampleRate: Int(pcmBuffer.format.sampleRate))
  }

  override func detach() { track.remove(self) }
}
