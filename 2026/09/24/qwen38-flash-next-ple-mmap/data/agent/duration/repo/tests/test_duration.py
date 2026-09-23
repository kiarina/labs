import unittest

from duration import parse_duration


class DurationTests(unittest.TestCase):
    def test_english(self):
        self.assertEqual(parse_duration("1h30m15s"), 5415)
        self.assertEqual(parse_duration("45m"), 2700)

    def test_japanese(self):
        self.assertEqual(parse_duration("1時間30分"), 5400)
        self.assertEqual(parse_duration("90秒"), 90)

    def test_invalid(self):
        with self.assertRaises(ValueError):
            parse_duration("")


if __name__ == "__main__":
    unittest.main()
