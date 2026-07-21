import Testing
import AVFoundation
@testable import SpeechAnalyzerCLI

@Test func japaneseNormalization() {
    #expect(normalizeJapanese("もしもし、駅に着いた？\n") == "もしもし駅に着いた")
}

@Test func editDistanceExamples() {
    #expect(editDistance("kitten", "sitting") == 3)
    #expect(editDistance("駅", "駅") == 0)
    #expect(editDistance("", "abc") == 3)
}

@Test func characterErrorRateIgnoresPunctuation() {
    #expect(characterErrorRate(reference: "今日は、寒いね。", hypothesis: "今日は寒いね") == 0)
}

@Test func floatSamplesConvertToRequiredInt16Format() throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    ))
    let input = try makeBuffer(samples: [-1, 0, 1], format: format, startSample: 0)
    let channel = try #require(input.buffer.int16ChannelData?[0])
    #expect(channel[0] == -32_767)
    #expect(channel[1] == 0)
    #expect(channel[2] == 32_767)
}
