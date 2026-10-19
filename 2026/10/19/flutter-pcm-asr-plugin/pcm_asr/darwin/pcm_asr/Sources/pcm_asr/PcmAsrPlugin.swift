#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif
import Foundation

/// Method channel `pcm_asr`. Every reply is a map; every failure is a
/// FlutterError whose code is one of the Dart `PcmAsrErrorCode` names.
public class PcmAsrPlugin: NSObject, FlutterPlugin {
  private let engine = SpeechAnalyzerEngine()

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: "pcm_asr", binaryMessenger: messenger)
    let instance = PcmAsrPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    Task {
      do {
        switch call.method {
        case "support":
          let support = await engine.support(locale: args["locale"] as? String ?? "")
          await reply(result, support)
        case "prepare":
          try await engine.prepare(locale: args["locale"] as? String ?? "")
          await reply(result, [:])
        case "transcribe":
          guard let id = args["id"] as? String,
                let locale = args["locale"] as? String,
                let pcm = args["pcm16le"] as? FlutterStandardTypedData,
                let sampleRate = args["sample_rate"] as? Int,
                let channels = args["channels"] as? Int
          else { throw EngineError.invalidPcm("missing id, locale, pcm16le, sample_rate or channels") }
          let row = try await engine.transcribe(id: id, locale: locale, pcm: pcm.data, sampleRate: Double(sampleRate), channels: channels)
          await reply(result, row)
        case "cancel":
          await engine.cancel(id: args["id"] as? String ?? "")
          await reply(result, [:])
        case "dispose":
          await engine.dispose()
          await reply(result, [:])
        default:
          await MainActor.run { result(FlutterMethodNotImplemented) }
        }
      } catch let error as EngineError {
        await MainActor.run { result(FlutterError(code: error.code, message: error.message, details: nil)) }
      } catch {
        await MainActor.run {
          result(FlutterError(code: "engineFailure", message: String(describing: error), details: String(describing: type(of: error))))
        }
      }
    }
  }

  private func reply(_ result: @escaping FlutterResult, _ value: [String: Any]) async {
    await MainActor.run { result(value) }
  }
}

enum EngineError: Error {
  case unsupportedPlatform(String)
  case unsupportedLocale(String)
  case modelUnavailable(String)
  case invalidPcm(String)
  case cancelled(String)
  case engineFailure(String)

  var code: String {
    switch self {
    case .unsupportedPlatform: return "unsupportedPlatform"
    case .unsupportedLocale: return "unsupportedLocale"
    case .modelUnavailable: return "modelUnavailable"
    case .invalidPcm: return "invalidPcm"
    case .cancelled: return "cancelled"
    case .engineFailure: return "engineFailure"
    }
  }

  var message: String {
    switch self {
    case .unsupportedPlatform(let m), .unsupportedLocale(let m), .modelUnavailable(let m),
         .invalidPcm(let m), .cancelled(let m), .engineFailure(let m):
      return m
    }
  }
}
