import unittest

from benchmark import common_prefix_length, summarize_trials


class BenchmarkHelpersTests(unittest.TestCase):
    def test_common_prefix_length(self) -> None:
        self.assertEqual(common_prefix_length([1, 2, 3], [1, 2, 4]), 2)
        self.assertEqual(common_prefix_length([], [1]), 0)

    def test_summarize_trials(self) -> None:
        trials = [
            {
                "prefill_seconds": 0.3,
                "decode_tokens_per_second": 10.0,
                "total_seconds": 0.8,
            },
            {
                "prefill_seconds": 0.1,
                "decode_tokens_per_second": 30.0,
                "total_seconds": 0.4,
            },
            {
                "prefill_seconds": 0.2,
                "decode_tokens_per_second": 20.0,
                "total_seconds": 0.6,
            },
        ]
        summary = summarize_trials(trials)
        self.assertEqual(summary["prefill_seconds_median"], 0.2)
        self.assertEqual(summary["decode_tokens_per_second_median"], 20.0)
        self.assertEqual(summary["total_seconds_median"], 0.6)


if __name__ == "__main__":
    unittest.main()
