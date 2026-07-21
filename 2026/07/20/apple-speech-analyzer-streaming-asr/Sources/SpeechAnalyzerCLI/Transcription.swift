import AVFoundation
import CoreMedia
import Foundation
import Speech

enum PresetName: String, Codable, CaseIterable {
    case transcription
    case progressive

    var speechPreset: SpeechTranscriber.Preset {
        switch self {
        case .transcription:
            .transcription
        case .progressive:
            .progressiveTranscription
        }
    }
}

struct TranscriptEvent: Codable, Sendable {
    let text: String
    let isFinal: Bool
    let receivedSeconds: Double
    let audioStartSeconds: Double
    let audioEndSeconds: Double
    let deliveryLagSeconds: Double
}

struct SessionSummary: Codable, Sendable {
    let preset: PresetName
    let transcript: String
    let events: [TranscriptEvent]
    let audioDurationSeconds: Double
    let elapsedSeconds: Double
    let realTimeFactor: Double
    let partialResults: Int
    let finalResults: Int
    let firstPartialSeconds: Double?
    let firstFinalSeconds: Double?
    let finalDeliveryLagP50Seconds: Double?
    let finalDeliveryLagP95Seconds: Double?
}

actor EventCollector {
    private let started = ContinuousClock.now
    private var events: [TranscriptEvent] = []
    private var finalSegments: [(start: Double, text: String)] = []
    private let callback: (@Sendable (TranscriptEvent) async -> Void)?

    init(callback: (@Sendable (TranscriptEvent) async -> Void)? = nil) {
        self.callback = callback
    }

    func record(_ result: SpeechTranscriber.Result) async {
        let elapsed = secondsSince(started)
        let start = result.range.start.seconds
        let end = result.range.end.seconds
        let event = TranscriptEvent(
            text: String(result.text.characters),
            isFinal: result.isFinal,
            receivedSeconds: elapsed,
            audioStartSeconds: start,
            audioEndSeconds: end,
            deliveryLagSeconds: elapsed - end
        )
        events.append(event)
        if result.isFinal {
            finalSegments.append((start: start, text: event.text))
        }
        await callback?(event)
    }

    func summary(
        preset: PresetName,
        audioDuration: Double,
        elapsed: Double
    ) -> SessionSummary {
        let transcript = finalSegments
            .sorted { $0.start < $1.start }
            .map(\.text)
            .joined()
        let partial = events.filter { !$0.isFinal }
        let final = events.filter(\.isFinal)
        let lags = final.map(\.deliveryLagSeconds).sorted()
        return SessionSummary(
            preset: preset,
            transcript: transcript,
            events: events,
            audioDurationSeconds: audioDuration,
            elapsedSeconds: elapsed,
            realTimeFactor: audioDuration > 0 ? elapsed / audioDuration : 0,
            partialResults: partial.count,
            finalResults: final.count,
            firstPartialSeconds: partial.first?.receivedSeconds,
            firstFinalSeconds: final.first?.receivedSeconds,
            finalDeliveryLagP50Seconds: percentile(lags, 0.50),
            finalDeliveryLagP95Seconds: percentile(lags, 0.95)
        )
    }
}

actor JSONLineEmitter {
    private let encoder = JSONEncoder()

    func emit<T: Encodable>(_ value: T) {
        guard let data = try? encoder.encode(value),
              let line = String(data: data, encoding: .utf8)
        else { return }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

struct StreamMessage: Codable, Sendable {
    let type: String
    let text: String?
    let final: Bool?
    let sampleRate: Double?
    let elapsedSeconds: Double?
    let deliveryLagSeconds: Double?

    static func ready(sampleRate: Double) -> Self {
        .init(type: "ready", text: nil, final: nil, sampleRate: sampleRate,
              elapsedSeconds: nil, deliveryLagSeconds: nil)
    }

    static func result(_ event: TranscriptEvent) -> Self {
        .init(type: "result", text: event.text, final: event.isFinal, sampleRate: nil,
              elapsedSeconds: event.receivedSeconds,
              deliveryLagSeconds: event.deliveryLagSeconds)
    }

    static func done(elapsed: Double) -> Self {
        .init(type: "done", text: nil, final: nil, sampleRate: nil,
              elapsedSeconds: elapsed, deliveryLagSeconds: nil)
    }
}

func makeTranscriber(preset: PresetName) async throws -> (Locale, SpeechTranscriber) {
    guard SpeechTranscriber.isAvailable else {
        throw CLIError.message("SpeechTranscriber is unavailable on this Mac")
    }
    guard let locale = await SpeechTranscriber.supportedLocale(
        equivalentTo: Locale(identifier: "ja-JP")
    ) else {
        throw CLIError.message("SpeechTranscriber does not support ja-JP on this Mac")
    }

    let transcriber = SpeechTranscriber(locale: locale, preset: preset.speechPreset)
    _ = try await AssetInventory.reserve(locale: locale)
    let assetStatus = await AssetInventory.status(forModules: [transcriber])
    if assetStatus != .installed,
       let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        writeError("Installing SpeechTranscriber asset for \(locale.identifier)...")
        try await request.downloadAndInstall()
    }
    return (locale, transcriber)
}

func runSession(
    preset: PresetName,
    inputFormat: AVAudioFormat,
    input: AsyncStream<AnalyzerInput>,
    audioDuration: @escaping @Sendable () async -> Double,
    callback: (@Sendable (TranscriptEvent) async -> Void)? = nil
) async throws -> SessionSummary {
    let (_, transcriber) = try await makeTranscriber(preset: preset)
    let compatibleFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
        compatibleWith: [transcriber],
        considering: inputFormat
    )
    writeError("input format: \(inputFormat); analyzer format: \(String(describing: compatibleFormat))")
    guard let compatibleFormat,
          compatibleFormat.sampleRate == inputFormat.sampleRate,
          compatibleFormat.channelCount == inputFormat.channelCount
    else {
        throw CLIError.message(
            "Input format \(Int(inputFormat.sampleRate)) Hz/\(inputFormat.channelCount)ch "
                + "is not directly supported"
        )
    }

    let collector = EventCollector(callback: callback)
    let analyzer = SpeechAnalyzer(
        modules: [transcriber],
        options: .init(priority: .userInitiated, modelRetention: .processLifetime)
    )
    try await analyzer.prepareToAnalyze(in: inputFormat)

    let resultsTask = Task {
        for try await result in transcriber.results {
            await collector.record(result)
        }
    }
    let started = ContinuousClock.now
    do {
        if let lastSampleTime = try await analyzer.analyzeSequence(input) {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        try await resultsTask.value
    } catch {
        resultsTask.cancel()
        await analyzer.cancelAndFinishNow()
        throw error
    }
    let elapsed = secondsSince(started)
    return await collector.summary(
        preset: preset,
        audioDuration: audioDuration(),
        elapsed: elapsed
    )
}

func makeBuffer(samples: [Float], format: AVAudioFormat, startSample: Int64) throws -> AnalyzerInput {
    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
    )
    else {
        throw CLIError.message("Could not allocate PCM buffer")
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    switch format.commonFormat {
    case .pcmFormatFloat32:
        guard let channel = buffer.floatChannelData?[0] else {
            throw CLIError.message("Could not access Float32 PCM channel")
        }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
    case .pcmFormatInt16:
        guard let channel = buffer.int16ChannelData?[0] else {
            throw CLIError.message("Could not access Int16 PCM channel")
        }
        for (index, sample) in samples.enumerated() {
            channel[index] = Int16(clamping: Int((sample.clamped(to: -1...1) * 32_767).rounded()))
        }
    default:
        throw CLIError.message("Unsupported PCM format \(format.commonFormat)")
    }
    _ = startSample
    return AnalyzerInput(buffer: buffer)
}

func convertFloatBufferToInt16(_ source: AVAudioPCMBuffer, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    guard let sourceChannel = source.floatChannelData?[0] else {
        throw CLIError.message("Could not access source Float32 channel")
    }
    let samples = Array(UnsafeBufferPointer(
        start: sourceChannel,
        count: Int(source.frameLength)
    ))
    return try makeBuffer(samples: samples, format: format, startSample: 0).buffer
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

func percentile(_ values: [Double], _ quantile: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let position = quantile * Double(values.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = Int(position.rounded(.up))
    if lower == upper { return values[lower] }
    let fraction = position - Double(lower)
    return values[lower] * (1 - fraction) + values[upper] * fraction
}

func secondsSince(_ instant: ContinuousClock.Instant) -> Double {
    let duration = instant.duration(to: .now)
    return Double(duration.components.seconds)
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
}

func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
