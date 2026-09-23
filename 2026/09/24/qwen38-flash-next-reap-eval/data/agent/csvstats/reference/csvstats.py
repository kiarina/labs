"""Column statistics for small CSV files.

The module is intentionally dependency-free so that it can run anywhere a
plain Python interpreter is available.
"""

from __future__ import annotations

import csv
import io
import math
from dataclasses import dataclass


# --- parsing ---------------------------------------------------------------


def read_rows(text: str) -> tuple[list[str], list[list[str]]]:
    """Return (header, rows) from CSV text. Blank lines are skipped."""
    reader = csv.reader(io.StringIO(text))
    header: list[str] | None = None
    rows: list[list[str]] = []
    for row in reader:
        if not row or all(cell.strip() == "" for cell in row):
            continue
        if header is None:
            header = [cell.strip() for cell in row]
            continue
        rows.append(row)
    if header is None:
        raise ValueError("empty CSV")
    return header, rows


def column(header: list[str], rows: list[list[str]], name: str) -> list[str]:
    """Raw cells of column `name`. Short rows yield an empty cell."""
    try:
        index = header.index(name)
    except ValueError:
        raise KeyError(name) from None
    return [row[index] if index < len(row) else "" for row in rows]


def to_numbers(cells: list[str]) -> list[float]:
    """Convert cells to floats.

    Empty or whitespace-only cells are missing values and are skipped.
    Thousands separators ("1,234") are accepted. Any other non-numeric cell
    raises ValueError.
    """
    numbers: list[float] = []
    for cell in cells:
        cell = cell.strip()
        if not cell:
            continue
        numbers.append(float(cell.replace(",", "")))
    return numbers


# --- statistics ------------------------------------------------------------


def mean(values: list[float]) -> float:
    if not values:
        raise ValueError("no values")
    return sum(values) / len(values)


def median(values: list[float]) -> float:
    """Median; for an even count, the mean of the two middle values."""
    if not values:
        raise ValueError("no values")
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2


def stdev(values: list[float]) -> float:
    """Sample standard deviation (n - 1). Needs at least two values."""
    if len(values) < 2:
        raise ValueError("need at least two values")
    m = mean(values)
    return math.sqrt(sum((v - m) ** 2 for v in values) / (len(values) - 1))


def percentile(values: list[float], p: float) -> float:
    """Linear-interpolated percentile, p in [0, 100]."""
    if not values:
        raise ValueError("no values")
    if not 0 <= p <= 100:
        raise ValueError("p out of range")
    ordered = sorted(values)
    k = (len(ordered) - 1) * p / 100
    lo, hi = math.floor(k), math.ceil(k)
    if lo == hi:
        return ordered[lo]
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (k - lo)


# --- summary ---------------------------------------------------------------


@dataclass
class Summary:
    name: str
    count: int
    missing: int
    mean: float
    median: float
    minimum: float
    maximum: float

    def format(self) -> str:
        return (
            f"{self.name}: n={self.count} missing={self.missing} "
            f"mean={self.mean:.2f} median={self.median:.2f} "
            f"min={self.minimum:g} max={self.maximum:g}"
        )


def summarize(text: str, name: str) -> Summary:
    """Summary of one numeric column. `missing` counts empty cells."""
    header, rows = read_rows(text)
    cells = column(header, rows, name)
    numbers = to_numbers(cells)
    return Summary(
        name=name,
        count=len(numbers),
        missing=len(cells) - len(numbers),
        mean=mean(numbers),
        median=median(numbers),
        minimum=min(numbers),
        maximum=max(numbers),
    )


def summarize_all(text: str) -> list[Summary]:
    """Summaries for every column whose non-empty cells are all numeric."""
    header, rows = read_rows(text)
    out: list[Summary] = []
    for name in header:
        try:
            out.append(summarize(text, name))
        except ValueError:
            continue
    return out


# --- command line ----------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    import argparse
    import sys

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path")
    parser.add_argument("--column")
    args = parser.parse_args(argv)
    with open(args.path, encoding="utf-8") as f:
        text = f.read()
    summaries = [summarize(text, args.column)] if args.column else summarize_all(text)
    for summary in summaries:
        sys.stdout.write(summary.format() + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
