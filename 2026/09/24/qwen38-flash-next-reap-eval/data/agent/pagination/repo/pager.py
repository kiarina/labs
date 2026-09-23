def total_pages(count: int, per_page: int) -> int:
    """Number of pages needed to show `count` items, `per_page` at a time."""
    if per_page <= 0:
        raise ValueError("per_page must be positive")
    return count // per_page


def paginate(items: list, page: int, per_page: int) -> list:
    """Return the items on `page` (1-based)."""
    if page < 1:
        raise ValueError("page must be >= 1")
    start = page * per_page
    return items[start : start + per_page]
