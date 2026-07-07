"""Parse a color string into an (r, g, b) tuple. Raises ValueError on bad input."""
from __future__ import annotations


def parse_color(s: str) -> tuple[int, int, int]:
    s = s.strip().lstrip("#")
    if "," in s:
        parts = tuple(int(x) for x in s.split(","))
        if len(parts) == 3 and all(0 <= v <= 255 for v in parts):
            return parts  # type: ignore[return-value]
    elif len(s) == 6:
        return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]
    elif len(s) == 3:
        return tuple(int(s[i] * 2, 16) for i in range(3))  # type: ignore[return-value]
    raise ValueError(f"expected '#rrggbb' or 'r,g,b', got {s!r}")
