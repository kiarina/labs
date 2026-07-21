import AVFoundation
import Foundation
import Speech

struct TrialReport: Codable {
    let trial: Int
    let summary: SessionSummary
    let reference: String
    let normalizedReference: String
    let normalizedTranscript: String
    let characterErrorRate: Double
}

struct BenchmarkReport: Codable {
    let generatedAt: String
    let audio: String
    let locale: String
    let inputDurationSeconds: Double
    let chunkMilliseconds: Int
    let realTimeInput: Bool
    let trials: [TrialReport]
}

func benchmark(arguments: [String]) async throws {
    let audioPath = try value(after: "--audio", in: arguments)
    let referencePath = try value(after: "--reference", in: arguments)
    let outputPath = try value(after: "--output", in: arguments)
    let trialCount = Int(optionalValue(after: "--trials", in: arguments) ?? "3") ?? 3
    let chunkMilliseconds = Int(optionalValue(after: "--chunk-ms", in: arguments) ?? "100") ?? 100
    let realTime = !arguments.contains("--no-realtime")
    let reference = try String(contentsOfFile: referencePath, encoding: .utf8)

    var reports: [TrialReport] = []
    for preset in PresetName.allCases {
        for trial in 1...trialCount {
            writeError("\(preset.rawValue) trial \(trial)/\(trialCount)")
            let summary = try await transcribeFile(
                at: audioPath,
                preset: preset,
                chunkMilliseconds: chunkMilliseconds,
                realTime: realTime
            )
            reports.append(TrialReport(
                trial: trial,
                summary: summary,
                reference: reference.trimmingCharacters(in: .whitespacesAndNewlines),
                normalizedReference: normalizeJapanese(reference),
                normalizedTranscript: normalizeJapanese(summary.transcript),
                characterErrorRate: characterErrorRate(
                    reference: reference,
                    hypothesis: summary.transcript
                )
            ))
        }
    }

    let firstDuration = reports.first?.summary.audioDurationSeconds ?? 0
    let locale = await SpeechTranscriber.supportedLocale(
        equivalentTo: Locale(identifier: "ja-JP")
    )?.identifier ?? "unsupported"
    let report = BenchmarkReport(
        generatedAt: ISO8601DateFormatter().string(from: Date()),
        audio: audioPath,
        locale: locale,
        inputDurationSeconds: firstDuration,
        chunkMilliseconds: chunkMilliseconds,
        realTimeInput: realTime,
        trials: reports
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(report)
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: outputPath).deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)

    for item in reports {
        let summary = item.summary
        print(String(format:
            "%@ trial=%d CER=%.3f partial=%d final=%d lag_p95=%.3fs RTF=%.3f transcript=%@",
            summary.preset.rawValue,
            item.trial,
            item.characterErrorRate,
            summary.partialResults,
            summary.finalResults,
            summary.finalDeliveryLagP95Seconds ?? -1,
            summary.realTimeFactor,
            summary.transcript
        ))
    }
    print("report: \(outputPath)")
}

func transcribeFile(
    at path: String,
    preset: PresetName,
    chunkMilliseconds: Int,
    realTime: Bool
) async throws -> SessionSummary {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    if !realTime {
        return try await transcribeFileDirect(file: file, preset: preset)
    }
    let format = file.processingFormat
    guard format.commonFormat == .pcmFormatFloat32,
          !format.isInterleaved,
          format.channelCount == 1
    else {
        throw CLIError.message("Expected a mono Float32 audio file, got \(format)")
    }
    let chunkFrames = max(1, Int(format.sampleRate * Double(chunkMilliseconds) / 1000))
    guard let analyzerInputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: format.sampleRate,
        channels: 1,
        interleaved: false
    ) else { throw CLIError.message("Could not create analyzer input format") }
    let duration = Double(file.length) / format.sampleRate
    let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

    let feeder = Task {
        defer { continuation.finish() }
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let capacity = min(Int64(chunkFrames), remaining)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(capacity)
            ) else { throw CLIError.message("Could not allocate file buffer") }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            let converted = try convertFloatBufferToInt16(buffer, format: analyzerInputFormat)
            continuation.yield(AnalyzerInput(buffer: converted))
            if realTime {
                let seconds = Double(buffer.frameLength) / format.sampleRate
                try await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    do {
        let summary = try await runSession(
            preset: preset,
            inputFormat: analyzerInputFormat,
            input: stream,
            audioDuration: { duration }
        )
        try await feeder.value
        return summary
    } catch {
        feeder.cancel()
        continuation.finish()
        throw error
    }
}

func transcribeFileDirect(
    file: AVAudioFile,
    preset: PresetName
) async throws -> SessionSummary {
    let (_, transcriber) = try await makeTranscriber(preset: preset)
    let collector = EventCollector()
    let analyzer = SpeechAnalyzer(
        modules: [transcriber],
        options: .init(priority: .userInitiated, modelRetention: .processLifetime)
    )
    let resultsTask = Task {
        for try await result in transcriber.results {
            await collector.record(result)
        }
    }
    let started = ContinuousClock.now
    do {
        if let lastSampleTime = try await analyzer.analyzeSequence(from: file) {
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
    let duration = Double(file.length) / file.processingFormat.sampleRate
    return await collector.summary(preset: preset, audioDuration: duration, elapsed: elapsed)
}
