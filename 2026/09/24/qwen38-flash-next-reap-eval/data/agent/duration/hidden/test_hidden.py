import unittest

from duration import parse_duration


class HiddenDurationTests(unittest.TestCase):
    def test_whitespace(self):
        self.assertEqual(parse_duration("  2h "), 7200)

    def test_seconds_only(self):
        self.assertEqual(parse_duration("90s"), 90)

    def test_full_japanese(self):
        self.assertEqual(parse_duration("1時間30分15秒"), 5415)

    def test_rejects(self):
        for bad in ["1x", "30m1h", "1h1h", "1時間30m", "h", "abc", "1.5h", "-1h"]:
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    parse_duration(bad)


if __name__ == "__main__":
    unittest.main()
