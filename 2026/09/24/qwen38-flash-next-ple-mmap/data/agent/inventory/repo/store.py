class Store:
    def __init__(self) -> None:
        self.stock: dict[str, int] = {}

    def add(self, name: str, qty: int) -> None:
        if qty <= 0:
            raise ValueError("qty must be positive")
        self.stock[name] = self.stock.get(name, 0) + qty

    def remove(self, name: str, qty: int) -> None:
        if qty <= 0:
            raise ValueError("qty must be positive")
        self.stock[name] = self.stock.get(name, 0) - qty
