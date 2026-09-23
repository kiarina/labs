import unittest

from csvstats import median, to_numbers


class HiddenCsvStatsTests(unittest.TestCase):
    def test_non_numeric_still_raises(self):
        with self.assertRaises(ValueError):
            to_numbers(["1", "abc"])

    def test_median_two(self):
        self.assertEqual(median([10, 20]), 15)

    def test_median_empty(self):
        with self.assertRaises(ValueError):
            median([])


if __name__ == "__main__":
    unittest.main()
