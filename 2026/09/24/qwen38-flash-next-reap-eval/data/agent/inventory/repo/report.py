from store import Store


def low_stock_report(store: Store, threshold: int) -> list[str]:
    """Lines like "name: qty" for items whose quantity is below `threshold`."""
    rows = [(name, qty) for name, qty in store.stock.items() if qty < threshold]
    rows.sort(key=lambda row: row[1], reverse=True)
    return [f"{name}: {qty}" for name, qty in rows]
