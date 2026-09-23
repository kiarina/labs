import unittest

from pager import paginate, total_pages


class HiddenPagerTests(unittest.TestCase):
    def test_exact_multiple(self):
        self.assertEqual(total_pages(9, 3), 3)
        self.assertEqual(paginate(list(range(9)), 3, 3), [6, 7, 8])

    def test_empty(self):
        self.assertEqual(total_pages(0, 5), 0)
        self.assertEqual(paginate([], 1, 5), [])

    def test_beyond_last_page(self):
        self.assertEqual(paginate(list(range(4)), 3, 2), [])

    def test_rejects_invalid(self):
        with self.assertRaises(ValueError):
            paginate([1], 0, 1)
        with self.assertRaises(ValueError):
            total_pages(3, 0)


if __name__ == "__main__":
    unittest.main()
