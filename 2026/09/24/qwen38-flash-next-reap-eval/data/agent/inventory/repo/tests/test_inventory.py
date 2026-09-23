import unittest

from report import low_stock_report
from store import Store


class InventoryTests(unittest.TestCase):
    def test_remove_too_many(self):
        store = Store()
        store.add("apple", 3)
        with self.assertRaises(ValueError):
            store.remove("apple", 5)
        self.assertEqual(store.stock["apple"], 3)

    def test_report_order(self):
        store = Store()
        store.add("pear", 4)
        store.add("apple", 1)
        store.add("fig", 2)
        self.assertEqual(low_stock_report(store, 5), ["apple: 1", "fig: 2", "pear: 4"])


if __name__ == "__main__":
    unittest.main()
