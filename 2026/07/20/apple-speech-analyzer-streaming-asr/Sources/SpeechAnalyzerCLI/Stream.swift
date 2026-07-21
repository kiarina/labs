import AVFoundation
import Foundation
import Speech

func streamStandardInput(arguments: [String]) async throws {
    let sampleRate = Double(optionalValue(after: "--sample-rate", in: arguments) ?? "16000") ?? 16000
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ) else { throw CLIError.message("Invalid input audio format") }

    let emitter = JSONLineEmitter()
    let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    let sampleCounter = SampleCounter()
    let reader = Task.detached {
        var remainder = Data()
        while let data = try FileHandle.standardInput.read(upToCount: 16_384), !data.isEmpty {
            remainder.append(data)
            let byteCount = remainder.count - remainder.count % MemoryLayout<Float>.size
            guard byteCount > 0 else { continue }
            let complete = remainder.prefix(byteCount)
            remainder.removeFirst(byteCount)
            let samples = complete.withUnsafeBytes { raw -> [Float] in
                Array(raw.bindMemory(to: Float.self))
            }
            let start = await sampleCounter.take(samples.count)
            let input = try makeBuffer(samples: samples, format: format, startSample: start)
            continuation.yield(input)
        }
        continuation.finish()
    }

    await emitter.emit(StreamMessage.ready(sampleRate: sampleRate))
    do {
        let summary = try await runSession(
            preset: .progressive,
            inputFormat: format,
            input: stream,
            audioDuration: { Double(await sampleCounter.value) / sampleRate },
            callback: { event in
                await emitter.emit(StreamMessage.result(event))
            }
        )
        try await reader.value
        await emitter.emit(StreamMessage.done(elapsed: summary.elapsedSeconds))
    } catch {
        reader.cancel()
        continuation.finish()
        throw error
    }
}

actor SampleCounter {
    private(set) var value: Int64 = 0

    func take(_ count: Int) -> Int64 {
        let start = value
        value += Int64(count)
        return start
    }
}
