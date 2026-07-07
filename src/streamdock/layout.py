"""Per-model physical layout.

The device reports button ``key_id``s in reading order, but its image *slot*
ids are not sequential, and some keys have no screen at all. A ``Layout`` maps
between three coordinate systems:

* **position** — reading order, 0 = top-left .. N-1 = bottom-right (what you use)
* **key_id**   — the 1-based id the device sends on a button event
* **slot**     — the id used when addressing a key's image (BAT command)

Calibrated for the HOTSPOTEK/MiraBox unit ``0x5548:0x1000``: 15 keys in a 3x5
grid, all with LCD screens. (``slot`` may still be ``None`` for other models
that have screenless buttons.)
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Layout:
    name: str
    rows: int
    cols: int
    # position (reading order) -> image slot id, or None for screenless keys
    position_to_slot: tuple[int | None, ...]

    @property
    def key_count(self) -> int:
        return len(self.position_to_slot)

    def slot(self, position: int) -> int | None:
        """Image slot for a reading-order position (None if no screen)."""
        return self.position_to_slot[position]

    def has_screen(self, position: int) -> bool:
        return 0 <= position < self.key_count and self.position_to_slot[position] is not None

    def key_id_to_position(self, key_id: int) -> int:
        """Device 1-based key_id -> reading-order position."""
        return key_id - 1

    def position_to_key_id(self, position: int) -> int:
        return position + 1


# The unit this project was built and calibrated against.
HOTSPOTEK_5548_1000 = Layout(
    name="HOTSPOTEK 0x5548:0x1000 (15 keys, 3x5)",
    rows=3,
    cols=5,
    position_to_slot=(
        11, 12, 13, 14, 15,   # top row    (key_id 1..5)
        6,  7,  8,  9,  10,    # middle row (key_id 6..10)
        1,  2,  3,  4,  5,     # bottom row (key_id 11..15)
    ),
)

DEFAULT_LAYOUT = HOTSPOTEK_5548_1000
