import unittest
from unittest.mock import patch

import torch

from benchmark import BenchmarkCase, dense_mask, main, token_density


class BenchmarkHelpersTests(unittest.TestCase):
    def test_sliding_window_density(self) -> None:
        self.assertAlmostEqual(token_density(8, 2), 15 / 64)
        self.assertAlmostEqual(token_density(8, 8), 36 / 64)

    def test_dense_mask_matches_causal_sliding_window(self) -> None:
        case = BenchmarkCase("local", sequence=8, window=3)
        actual = dense_mask(case, torch.device("cpu"))
        expected = torch.tensor([
            [1, 0, 0, 0, 0, 0, 0, 0],
            [1, 1, 0, 0, 0, 0, 0, 0],
            [1, 1, 1, 0, 0, 0, 0, 0],
            [0, 1, 1, 1, 0, 0, 0, 0],
            [0, 0, 1, 1, 1, 0, 0, 0],
            [0, 0, 0, 1, 1, 1, 0, 0],
            [0, 0, 0, 0, 1, 1, 1, 0],
            [0, 0, 0, 0, 0, 1, 1, 1],
        ], dtype=torch.bool)
        self.assertTrue(torch.equal(actual, expected))

    @patch("benchmark.torch.backends.mps.is_available", return_value=False)
    def test_benchmark_requires_mps(self, _is_available) -> None:
        with self.assertRaisesRegex(SystemExit, "MPS is not available"):
            main([])


if __name__ == "__main__":
    unittest.main()
