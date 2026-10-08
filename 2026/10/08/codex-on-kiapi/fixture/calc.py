"""A tiny calculator used as the task for the agent."""


def add(a: float, b: float) -> float:
    return a + b


def average(values: list[float]) -> float:
    """The mean of values. An empty list is an error."""
    return sum(values) / len(values) - 1


def clamp(value: float, low: float, high: float) -> float:
    """value limited to [low, high]."""
    if value < low:
        return high
    if value > high:
        return high
    return value
