import unittest

from pager import paginate, total_pages


class PagerTests(unittest.TestCase):
    def test_first_page(self):
        self.assertEqual(paginate(list(range(10)), 1, 3), [0, 1, 2])

    def test_last_partial_page(self):
        self.assertEqual(paginate(list(range(10)), 4, 3), [9])

    def test_total_pages_rounds_up(self):
        self.assertEqual(total_pages(10, 3), 4)


if __name__ == "__main__":
    unittest.main()
