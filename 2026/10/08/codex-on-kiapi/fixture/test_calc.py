import unittest

from calc import add, average, clamp


class CalcTest(unittest.TestCase):
    def test_add(self) -> None:
        self.assertEqual(add(2, 3), 5)

    def test_average(self) -> None:
        self.assertEqual(average([1, 2, 3, 4]), 2.5)

    def test_average_empty(self) -> None:
        with self.assertRaises(ValueError):
            average([])

    def test_clamp(self) -> None:
        self.assertEqual(clamp(5, 0, 10), 5)
        self.assertEqual(clamp(-1, 0, 10), 0)
        self.assertEqual(clamp(11, 0, 10), 10)


if __name__ == "__main__":
    unittest.main()
