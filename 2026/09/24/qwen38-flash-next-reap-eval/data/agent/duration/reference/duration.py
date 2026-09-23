import re

_EN = re.compile(r"(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?")
_JA = re.compile(r"(?:(\d+)時間)?(?:(\d+)分)?(?:(\d+)秒)?")


def parse_duration(text: str) -> int:
    """Parse "1h30m15s" or "1時間30分15秒" into seconds; see the task spec."""
    text = text.strip()
    for pattern in (_EN, _JA):
        match = pattern.fullmatch(text)
        if match and any(match.groups()):
            h, m, s = (int(g) if g else 0 for g in match.groups())
            return h * 3600 + m * 60 + s
    raise ValueError(f"invalid duration: {text!r}")
