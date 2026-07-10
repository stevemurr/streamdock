"""streamdock — userspace driver + CLI for HOTSPOTEK/MiraBox-Ajazz Stream Dock macropads."""
from __future__ import annotations

from .device import (
    KEY_PX,
    PACKET,
    PID,
    USAGE_PAGE,
    VID,
    DeviceNotFound,
    StreamDock,
)
from .layout import DEFAULT_LAYOUT, HOTSPOTEK_5548_1000, Layout
from .profile import DEFAULT_PROFILE, HOTSPOTEK_M18, DeviceProfile, profile_for

__all__ = [
    "StreamDock",
    "DeviceNotFound",
    "Layout",
    "DEFAULT_LAYOUT",
    "HOTSPOTEK_5548_1000",
    "VID",
    "PID",
    "USAGE_PAGE",
    "PACKET",
    "KEY_PX",
    "DeviceProfile",
    "DEFAULT_PROFILE",
    "HOTSPOTEK_M18",
    "profile_for",
]

__version__ = "0.1.0"
