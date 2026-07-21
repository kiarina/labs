import math
import unittest
from array import array

from demo_server import AudioStats, StreamingLinearResampler


def sine_wave(sample_rate: int, seconds: int = 1) -> array:
    return array(
        "f",
        (math.sin(2 * math.pi * 440 * index / sample_rate)
         for index in range(sample_rate * seconds)),
    )


class StreamingLinearResamplerTests(unittest.TestCase):
    def test_resamples_48khz_audio_worklet_blocks_to_16khz(self) -> None:
        source = sine_wave(48_000)
        resampler = StreamingLinearResampler(48_000)
        output = bytearray()
        block_size = 128

        for offset in range(0, len(source), block_size):
            output.extend(resampler.feed(source[offset:offset + block_size].tobytes()))
        output.extend(resampler.flush())

        self.assertEqual(len(output) // 4, 16_000)

    def test_preserves_16khz_samples_across_unaligned_messages(self) -> None:
        source = sine_wave(16_000)
        source_bytes = source.tobytes()
        resampler = StreamingLinearResampler(16_000)
        output = bytearray()

        for offset in range(0, len(source_bytes), 511):
            output.extend(resampler.feed(source_bytes[offset:offset + 511]))
        output.extend(resampler.flush())
        actual = array("f")
        actual.frombytes(output)

        self.assertEqual(len(actual), len(source))
        self.assertAlmostEqual(actual[-1], source[-1])


class AudioStatsTests(unittest.TestCase):
    def test_reports_one_second_rms_and_duration(self) -> None:
        samples = array("f", [0.5] * 16_000)

        result = AudioStats().add(samples.tobytes())

        self.assertIsNotNone(result)
        assert result
        self.assertAlmostEqual(result["audioSeconds"], 1.0)
        self.assertAlmostEqual(result["rmsDbfs"], -6.0206, places=3)
        self.assertEqual(result["peak"], 0.5)


if __name__ == "__main__":
    unittest.main()
