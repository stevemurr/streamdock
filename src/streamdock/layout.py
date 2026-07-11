"""Per-model physical layout.

The device reports button ``key_id``s in reading order, but its image *slot*
ids are not sequential, and some keys have no screen at all. A ``Layout`` maps
between three coordinate systems:

* **position** — reading order, 0 = top-left .. N-1 = bottom-right (what you use)
* **key_id**   — the 1-based id the device sends on a button event
* **slot**     — the id used when addressing a key's image (BAT command)

Calibrated for the HOTSPOTEK/MiraBox unit ``0x5548:0x1000``: 15 keys in a 3x5
grid, all with LCD screens, plus 3 screenless hardware buttons below the
screen. (``slot`` may still be ``None`` for other models with screenless keys
*inside* the grid.)
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
    # key_ids of hardware buttons outside the grid (no screen, arbitrary ids),
    # in reading order; button i lives at position len(position_to_slot) + i
    extra_button_key_ids: tuple[int, ...] = ()

    @property
    def key_count(self) -> int:
        return len(self.position_to_slot) + len(self.extra_button_key_ids)

    def slot(self, position: int) -> int | None:
        """Image slot for a reading-order position (None if no screen)."""
        if position >= len(self.position_to_slot):
            return None
        return self.position_to_slot[position]

    def has_screen(self, position: int) -> bool:
        return 0 <= position < len(self.position_to_slot) \
            and self.position_to_slot[position] is not None

    def key_id_to_position(self, key_id: int) -> int:
        """Device 1-based key_id -> reading-order position."""
        if key_id in self.extra_button_key_ids:
            return len(self.position_to_slot) + self.extra_button_key_ids.index(key_id)
        return key_id - 1

    def position_to_key_id(self, position: int) -> int:
        if position >= len(self.position_to_slot):
            return self.extra_button_key_ids[position - len(self.position_to_slot)]
        return position + 1


# The unit this project was built and calibrated against.
HOTSPOTEK_5548_1000 = Layout(
    name="HOTSPOTEK 0x5548:0x1000 (15 keys 3x5 + 3 buttons)",
    rows=3,
    cols=5,
    position_to_slot=(
        11, 12, 13, 14, 15,   # top row    (key_id 1..5)
        6,  7,  8,  9,  10,    # middle row (key_id 6..10)
        1,  2,  3,  4,  5,     # bottom row (key_id 11..15)
    ),
    # the 3 screenless buttons under the screen, left to right
    # (positions 15/16/17; ids captured on hardware)
    extra_button_key_ids=(0x25, 0x30, 0x31),
)

DEFAULT_LAYOUT = HOTSPOTEK_5548_1000
