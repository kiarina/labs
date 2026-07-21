import Foundation
import Speech

enum CLIError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): text
        }
    }
}

@main
struct SpeechAnalyzerCommand {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else {
                throw CLIError.message(usage)
            }
            switch command {
            case "benchmark":
                try await benchmark(arguments: Array(arguments.dropFirst()))
            case "stream":
                try await streamStandardInput(arguments: Array(arguments.dropFirst()))
            case "locales":
                try await printLocales()
            default:
                throw CLIError.message(usage)
            }
        } catch {
            writeError("error: \(error)")
            Foundation.exit(1)
        }
    }

    static let usage = """
    Usage:
      speech-analyzer locales
      speech-analyzer benchmark --audio FILE --reference FILE --output FILE [--trials 3] [--chunk-ms 100] [--no-realtime]
      speech-analyzer stream [--sample-rate 16000] < float32le.pcm
    """
}

func printLocales() async throws {
    let supported = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
    let installed = await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
    let japanese = await SpeechTranscriber.supportedLocale(
        equivalentTo: Locale(identifier: "ja-JP")
    )?.identifier
    print("available: \(SpeechTranscriber.isAvailable)")
    print("ja-JP equivalent: \(japanese ?? "unsupported")")
    print("installed: \(installed.joined(separator: ", "))")
    print("supported: \(supported.joined(separator: ", "))")
}

func value(after flag: String, in arguments: [String]) throws -> String {
    guard let value = optionalValue(after: flag, in: arguments) else {
        throw CLIError.message("Missing required argument \(flag)")
    }
    return value
}

func optionalValue(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}
