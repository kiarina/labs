#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif
import AVFoundation
import Foundation

/// Method channel `tts_pcm`. Synthesis uses `AVSpeechSynthesizer.write`, which
/// hands buffers over as they are rendered and plays nothing. Each request
/// gets its own synthesizer so cancelling one does not stop the others.
public class TtsPcmPlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private var running: [String: AVSpeechSynthesizer] = [:]

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: "tts_pcm", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(TtsPcmPlugin(channel: channel), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "voices":
      result(AVSpeechSynthesisVoice.speechVoices().map { v -> [String: Any] in
        let quality: String
        switch v.quality {
        case .enhanced: quality = "enhanced"
        case .premium: quality = "premium"
        default: quality = "default"
        }
        return ["id": v.identifier, "name": v.name, "language": v.language, "quality": quality]
      })
    case "synthesize":
      guard let id = args["id"] as? String, let text = args["text"] as? String else {
        result(FlutterError(code: "invalid", message: "id and text are required", details: nil))
        return
      }
      synthesize(
        id: id, text: text, language: args["language"] as? String,
        voice: args["voice"] as? String, rate: args["rate"] as? Double ?? 1.0)
      result(nil)
    case "cancel":
      if let id = args["id"] as? String, let synth = running.removeValue(forKey: id) {
        synth.stopSpeaking(at: .immediate)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func synthesize(id: String, text: String, language: String?, voice: String?, rate: Double) {
    let utterance = AVSpeechUtterance(string: text)
    if let voice, let v = AVSpeechSynthesisVoice(identifier: voice) {
      utterance.voice = v
    } else if let language {
      utterance.voice = AVSpeechSynthesisVoice(language: language)
    }
    let r = Float(Double(AVSpeechUtteranceDefaultSpeechRate) * rate)
    utterance.rate = min(max(r, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)

    let synth = AVSpeechSynthesizer()
    running[id] = synth
    synth.write(utterance) { [weak self] buffer in
      guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
      // A zero-length buffer marks the end of the utterance.
      if pcm.frameLength == 0 {
        DispatchQueue.main.async {
          if self.running.removeValue(forKey: id) != nil {
            self.channel.invokeMethod("done", arguments: ["id": id])
          }
        }
        return
      }
      let data = Self.int16Mono(pcm)
      let rate = Int(pcm.format.sampleRate)
      let f = pcm.format
      let format = "\(f.commonFormat.rawValue == 1 ? "float32" : f.commonFormat.rawValue == 3 ? "int16" : "fmt\(f.commonFormat.rawValue)") \(rate) Hz \(f.channelCount) ch\(f.isInterleaved ? " interleaved" : "")"
      DispatchQueue.main.async {
        guard self.running[id] != nil else { return }
        self.channel.invokeMethod(
          "chunk",
          arguments: ["id": id, "pcm": FlutterStandardTypedData(bytes: data), "sampleRate": rate, "format": format])
      }
    }
  }

  /// First channel as 16-bit little-endian PCM, whatever the buffer's format.
  private static func int16Mono(_ pcm: AVAudioPCMBuffer) -> Data {
    let n = Int(pcm.frameLength)
    var out = [Int16](repeating: 0, count: n)
    if let ch = pcm.int16ChannelData {
      let stride = pcm.format.isInterleaved ? Int(pcm.format.channelCount) : 1
      for i in 0..<n { out[i] = ch[0][i * stride] }
    } else if let ch = pcm.floatChannelData {
      let stride = pcm.format.isInterleaved ? Int(pcm.format.channelCount) : 1
      for i in 0..<n {
        let v = max(-1, min(1, ch[0][i * stride]))
        out[i] = Int16(v * 32767)
      }
    } else if let ch = pcm.int32ChannelData {
      let stride = pcm.format.isInterleaved ? Int(pcm.format.channelCount) : 1
      for i in 0..<n { out[i] = Int16(ch[0][i * stride] >> 16) }
    }
    return out.withUnsafeBufferPointer { Data(buffer: $0) }
  }
}
