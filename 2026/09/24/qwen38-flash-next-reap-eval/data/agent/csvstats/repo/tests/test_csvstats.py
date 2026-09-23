import unittest

from csvstats import median, percentile, stdev, summarize, summarize_all, to_numbers

CSV = """city,visitors,rating,note
Gifu,"1,200",4.5,ok
Mie,800,,closed on Monday
Aichi,1500,4.0,
Shiga,600,3.5,new
"""


class CsvStatsTests(unittest.TestCase):
    def test_even_median(self):
        self.assertEqual(median([4, 1, 3, 2]), 2.5)

    def test_odd_median(self):
        self.assertEqual(median([5, 1, 3]), 3)

    def test_blank_cells_are_missing(self):
        self.assertEqual(to_numbers(["1", " ", "", "2,000"]), [1.0, 2000.0])

    def test_summary_with_blank(self):
        s = summarize(CSV, "rating")
        self.assertEqual((s.count, s.missing), (3, 1))
        self.assertEqual(s.median, 4.0)

    def test_summary_even(self):
        s = summarize(CSV, "visitors")
        self.assertEqual(s.median, 1000.0)
        self.assertEqual(s.maximum, 1500.0)

    def test_summarize_all_skips_text_columns(self):
        self.assertEqual([s.name for s in summarize_all(CSV)], ["visitors", "rating"])

    def test_other_stats_unchanged(self):
        self.assertAlmostEqual(stdev([2, 4, 4, 4, 5, 5, 7, 9]), 2.138089935299395)
        self.assertEqual(percentile([1, 2, 3, 4], 50), 2.5)


if __name__ == "__main__":
    unittest.main()
