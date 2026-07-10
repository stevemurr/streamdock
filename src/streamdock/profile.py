"""Per-model device contracts.

Image geometry is not exposed by the HID descriptor, so it must be part of the
device profile just like the button/slot layout.  Keeping it here prevents the
renderer, transport, CLI, and documentation from growing independent guesses.
"""
from __future__ import annotations

from dataclasses import dataclass

from .layout import HOTSPOTEK_5548_1000, Layout


@dataclass(frozen=True)
class DeviceProfile:
    name: str
    vid: int
    pid: int
    layout: Layout
    key_px: int
    rotation: int = 0


HOTSPOTEK_M18 = DeviceProfile(
    name="VSD Inside M18 / HOTSPOTEK 0x5548:0x1000",
    vid=0x5548,
    pid=0x1000,
    layout=HOTSPOTEK_5548_1000,
    key_px=64,
)

DEFAULT_PROFILE = HOTSPOTEK_M18
PROFILES = {(HOTSPOTEK_M18.vid, HOTSPOTEK_M18.pid): HOTSPOTEK_M18}


def profile_for(vid: int, pid: int) -> DeviceProfile | None:
    return PROFILES.get((vid, pid))
