from __future__ import annotations

import unittest

from benchmark import median, swap_bytes


class BenchmarkTests(unittest.TestCase):
    def test_median_odd(self) -> None:
        self.assertEqual(median([3.0, 1.0, 2.0]), 2.0)

    def test_median_rejects_empty_input(self) -> None:
        with self.assertRaises(ValueError):
            median([])

    def test_swap_parser_returns_non_negative_bytes(self) -> None:
        value = swap_bytes()
        self.assertIsNotNone(value)
        self.assertGreaterEqual(value or 0, 0)


if __name__ == "__main__":
    unittest.main()
