import unittest

from report import low_stock_report
from store import Store


class HiddenInventoryTests(unittest.TestCase):
    def test_remove_unknown(self):
        store = Store()
        with self.assertRaises(ValueError):
            store.remove("ghost", 1)
        self.assertNotIn("ghost", store.stock)

    def test_remove_exact(self):
        store = Store()
        store.add("kiwi", 2)
        store.remove("kiwi", 2)
        self.assertEqual(store.stock.get("kiwi", 0), 0)

    def test_tie_breaks_by_name(self):
        store = Store()
        store.add("b", 1)
        store.add("a", 1)
        store.add("c", 9)
        self.assertEqual(low_stock_report(store, 5), ["a: 1", "b: 1"])


if __name__ == "__main__":
    unittest.main()
