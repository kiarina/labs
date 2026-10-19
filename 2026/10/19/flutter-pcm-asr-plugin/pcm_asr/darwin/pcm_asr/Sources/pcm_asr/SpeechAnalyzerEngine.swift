import AVFoundation
import Foundation
import Speech

/// One request = one SpeechAnalyzer + SpeechTranscriber over one in-memory
/// buffer. The input is ended explicitly, `finalizeAndFinish` is awaited and
/// the results stream is drained, so the reply holds the final text only.
///
/// Requires macOS 26 / iOS 26 (SpeechAnalyzer). Older systems report
/// `unsupportedPlatform`; no SFSpeechRecognizer fallback is implemented here.
actor SpeechAnalyzerEngine {
  static let engineId = "apple.speech-analyzer"

  private var running: [String: RunningRequest] = [:]

  private final class RunningRequest {
    let task: Task<[String: Any], Error>
    let cancelHandler: @Sendable () async -> Void
    init(task: Task<[String: Any], Error>, cancelHandler: @escaping @Sendable () async -> Void) {
      self.task = task
      self.cancelHandler = cancelHandler
    }
  }

  // MARK: support / prepare

  func support(locale tag: String) async -> [String: Any] {
    var out: [String: Any] = [
      "engine": Self.engineId,
      "supported": false,
      "accepts_external_pcm": true,
      "on_device": true,
      "model_state": "unknown",
      "locale": NSNull(),
      "sample_rates": [Int](),
      "needs_network_for_model": true,
      "reason": NSNull(),
    ]
    guard #available(macOS 26.0, iOS 26.0, *) else {
      out["engine"] = "none"
      out["reason"] = "os_too_old"
      return out
    }
    guard SpeechTranscriber.isAvailable else {
      out["reason"] = "engine_unavailable"
      return out
    }
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: tag)) else {
      out["reason"] = "unsupported_locale"
      out["model_state"] = "unavailable"
      return out
    }
    out["locale"] = locale.identifier(.bcp47)
    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
    let status = await AssetInventory.status(forModules: [transcriber])
    out["model_state"] = Self.modelState(status)
    out["supported"] = status != .unsupported
    if status == .unsupported { out["reason"] = "model_unavailable" }
    let probe = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)
    if let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: probe) {
      out["sample_rates"] = [Int(best.sampleRate)]
    }
    return out
  }

  func prepare(locale tag: String) async throws {
    guard #available(macOS 26.0, iOS 26.0, *) else { throw EngineError.unsupportedPlatform("SpeechAnalyzer needs macOS 26 or iOS 26") }
    let locale = try await resolve(tag)
    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
    _ = try await AssetInventory.reserve(locale: locale)
    let status = await AssetInventory.status(forModules: [transcriber])
    if status == .unsupported { throw EngineError.modelUnavailable("no model for \(locale.identifier(.bcp47))") }
    if status != .installed {
      guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
        throw EngineError.modelUnavailable("installation request unavailable for \(locale.identifier(.bcp47))")
      }
      try await request.downloadAndInstall()
    }
  }

  // MARK: transcribe

  func transcribe(id: String, locale tag: String, pcm: Data, sampleRate: Double, channels: Int) async throws -> [String: Any] {
    guard #available(macOS 26.0, iOS 26.0, *) else { throw EngineError.unsupportedPlatform("SpeechAnalyzer needs macOS 26 or iOS 26") }
    guard running[id] == nil else { throw EngineError.engineFailure("request id already running: \(id)") }
    let locale = try await resolve(tag)
    let buffer = try Self.makeBuffer(pcm: pcm, sampleRate: sampleRate, channels: channels)

    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
    let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
    let cancelHandler: @Sendable () async -> Void = { await analyzer.cancelAndFinishNow() }
    let task = Task<[String: Any], Error> {
      let origin = ContinuousClock.now
      let input = try await Self.inputBuffer(for: buffer, transcriber: transcriber)
      try await analyzer.prepareToAnalyze(in: input.format)
      let collector = Collector()
      let drain = Task { for try await r in transcriber.results { await collector.add(r) } }
      let stream = AsyncStream<AnalyzerInput> { c in c.yield(AnalyzerInput(buffer: input)); c.finish() }
      do {
        if let last = try await analyzer.analyzeSequence(stream) {
          try await analyzer.finalizeAndFinish(through: last)
        } else {
          await analyzer.cancelAndFinishNow()
        }
        try await drain.value
      } catch {
        drain.cancel()
        await analyzer.cancelAndFinishNow()
        throw error
      }
      if Task.isCancelled { throw EngineError.cancelled("cancelled: \(id)") }
      let finals = await collector.finals()
      let elapsed = origin.duration(to: .now)
      return [
        "id": id,
        "text": finals.map(\.text).joined(),
        "engine": Self.engineId,
        "locale": locale.identifier(.bcp47),
        "elapsed_ms": Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15,
        "ranges": finals.map { ["text": $0.text, "start": $0.start, "end": $0.end] },
      ]
    }
    running[id] = RunningRequest(task: task, cancelHandler: cancelHandler)
    defer { running[id] = nil }
    do {
      return try await task.value
    } catch is CancellationError {
      throw EngineError.cancelled("cancelled: \(id)")
    }
  }

  func cancel(id: String) async {
    guard let request = running[id] else { return }
    request.task.cancel()
    await request.cancelHandler()
  }

  func dispose() async {
    for (_, request) in running {
      request.task.cancel()
      await request.cancelHandler()
    }
    running.removeAll()
  }

  // MARK: helpers

  @available(macOS 26.0, iOS 26.0, *)
  private func resolve(_ tag: String) async throws -> Locale {
    guard SpeechTranscriber.isAvailable else { throw EngineError.unsupportedPlatform("SpeechTranscriber is unavailable on this device") }
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: tag)) else {
      throw EngineError.unsupportedLocale("no SpeechTranscriber locale equivalent to \(tag)")
    }
    return locale
  }

  @available(macOS 26.0, iOS 26.0, *)
  private static func modelState(_ status: AssetInventory.Status) -> String {
    switch status {
    case .installed: return "installed"
    case .supported: return "downloadable"
    case .downloading: return "installing"
    case .unsupported: return "unavailable"
    @unknown default: return "unknown"
    }
  }

  private static func makeBuffer(pcm: Data, sampleRate: Double, channels: Int) throws -> AVAudioPCMBuffer {
    guard channels >= 1, pcm.count > 0, pcm.count % (2 * channels) == 0 else {
      throw EngineError.invalidPcm("pcm16le must hold whole frames; got \(pcm.count) bytes for \(channels) channel(s)")
    }
    guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: true) else {
      throw EngineError.invalidPcm("unsupported format: \(sampleRate) Hz, \(channels) channel(s)")
    }
    let frames = AVAudioFrameCount(pcm.count / (2 * channels))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
      throw EngineError.invalidPcm("could not allocate \(frames) frames")
    }
    buffer.frameLength = frames
    let dst = buffer.audioBufferList.pointee.mBuffers
    pcm.withUnsafeBytes { src in
      dst.mData!.copyMemory(from: src.baseAddress!, byteCount: pcm.count)
    }
    return buffer
  }

  /// Converts to the format the transcriber prefers when it differs from the
  /// input (sample rate or layout). Mono 16 kHz int16 was accepted as-is on
  /// macOS 26/27 in the earlier lab, so this usually returns the input.
  @available(macOS 26.0, iOS 26.0, *)
  private static func inputBuffer(for buffer: AVAudioPCMBuffer, transcriber: SpeechTranscriber) async throws -> AVAudioPCMBuffer {
    guard let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: buffer.format) else {
      throw EngineError.engineFailure("no compatible audio format")
    }
    if best.sampleRate == buffer.format.sampleRate, best.channelCount == buffer.format.channelCount,
       best.commonFormat == buffer.format.commonFormat, best.isInterleaved == buffer.format.isInterleaved {
      return buffer
    }
    guard let converter = AVAudioConverter(from: buffer.format, to: best) else {
      throw EngineError.engineFailure("cannot convert \(buffer.format) to \(best)")
    }
    let ratio = best.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 64)
    guard let out = AVAudioPCMBuffer(pcmFormat: best, frameCapacity: capacity) else {
      throw EngineError.engineFailure("could not allocate converted buffer")
    }
    var consumed = false
    var conversionError: NSError?
    let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
      if consumed { outStatus.pointee = .endOfStream; return nil }
      consumed = true
      outStatus.pointee = .haveData
      return buffer
    }
    if let conversionError { throw EngineError.engineFailure("conversion failed: \(conversionError)") }
    if status == .error { throw EngineError.engineFailure("conversion failed") }
    return out
  }

  @available(macOS 26.0, iOS 26.0, *)
  private actor Collector {
    struct Final: Sendable { let text: String; let start: Double; let end: Double }
    private var items: [Final] = []
    func add(_ r: SpeechTranscriber.Result) {
      guard r.isFinal else { return }
      items.append(Final(text: String(r.text.characters), start: r.range.start.seconds, end: r.range.end.seconds))
    }
    func finals() -> [Final] { items.sorted { $0.start < $1.start } }
  }
}
