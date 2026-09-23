def parse_duration(text: str) -> int:
    """Parse a duration string and return the total number of seconds.

    Accepted forms (units must appear in descending order, each at most once,
    and at least one unit is required; surrounding whitespace is ignored):

    - English: "2h", "45m", "1h30m", "1h30m15s", "90s"
    - Japanese: "2時間", "45分", "1時間30分", "1時間30分15秒", "90秒"

    English and Japanese units must not be mixed in one string.
    Anything else raises ValueError.
    """
    raise NotImplementedError
