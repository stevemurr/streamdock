#!/usr/bin/env python3
"""
Userspace driver for HOTSPOTEK / MiraBox / Ajazz "Stream Dock" macropads
(USB 0x5548:0x1000 and relatives).

Transport: hidapi (IOHIDManager on macOS). We talk to HID interface 0, which
exposes a vendor-defined usage page (0xFFA0). libusb cannot be used on macOS
because IOHIDFamily claims the interface; hidapi goes through the OS HID stack
instead, so no kernel-driver detach is needed.

Wire protocol (reverse-engineered by the community; see 4ndv/mirajazz and
rigor789/mirabox-streamdock-node):

  Each command = 0x00 (hidapi report id) + b"CRT\\x00\\x00" + <verb+payload>,
  zero-padded to PACKET (1024) bytes. This is a protocol-v3 device; reports
  SHORTER than 1024 bytes are silently ignored.

    MOD  4d 4f 44 00 00 <0x30+m>      set mode (1=keyboard 2=calc 3=software)
    LIG  4c 49 47 00 00 VV            set brightness (VV = 0..100)
    CLE  43 4c 45 00 00 00 TT         clear (TT=0xff all, or a slot id)
    DIS  44 49 53 00 00               wake screen
    STP  53 54 50 00 00               flush / refresh (commit pending image)
    BAT  42 41 54 <len:u32 be> KK     begin image for slot KK, len JPEG bytes

  Image bytes then stream as raw 1024-byte HID reports (no CRT prefix), and a
  trailing STP commits them. Key image = 96x96 JPEG. You MUST send MOD=software
  (initialize()) before the device reports button presses on this interface.

  Button input report, framed b"ACK\\x00\\x00OK\\x00\\x00": byte[9] = 1-based
  key id, byte[10] = state (1 = down, 0 = up).
"""
from __future__ import annotations

import io
import struct
import time

from ._hidapi_path import preload_hidapi

preload_hidapi()          # must run before importing hid
import hid  # noqa: E402
from PIL import Image  # noqa: E402

from .layout import DEFAULT_LAYOUT, Layout  # noqa: E402

VID = 0x5548
PID = 0x1000
USAGE_PAGE = 0xFFA0          # vendor page => the data interface (interface 0)
PACKET = 1024                # protocol v3 uses 1024-byte reports (v1 used 512)
KEY_PX = 96                  # per-key image is 96x96
ROTATE = 0                   # image rotation in degrees

CRT = b"CRT\x00\x00"         # 43 52 54 00 00

RGB = "tuple[int, int, int]"
ImageLike = "Image.Image | str | bytes"


class DeviceNotFound(RuntimeError):
    pass


class StreamDock:
    # device operating modes (MOD command). The device boots in KEYBOARD mode,
    # emitting keystrokes on interface 1; only in SOFTWARE mode does it report
    # button presses on this vendor interface.
    MODE_KEYBOARD = 1
    MODE_CALCULATOR = 2
    MODE_SOFTWARE = 3

    def __init__(self, vid: int = VID, pid: int = PID, layout: Layout = DEFAULT_LAYOUT):
        self.layout = layout
        path = self._find_path(vid, pid)
        if path is None:
            raise DeviceNotFound(
                f"No Stream Dock data interface for {vid:#06x}:{pid:#06x} "
                f"(usage_page {USAGE_PAGE:#06x}). Is it plugged in?"
            )
        self.h = hid.device()
        self.h.open_path(path)
        self.h.set_nonblocking(0)   # blocking; read() uses an explicit timeout

    @staticmethod
    def _find_path(vid: int, pid: int):
        # Pick the vendor-usage-page collection (interface 0), NOT the fake
        # keyboard on interface 1 (usage_page 0x0001).
        cands = [d for d in hid.enumerate(vid, pid) if d["usage_page"] == USAGE_PAGE]
        cands.sort(key=lambda d: d["usage"])   # prefer usage 0x0001
        return cands[0]["path"] if cands else None

    @staticmethod
    def list_devices(vid: int = VID, pid: int = PID) -> list[dict]:
        """All matching HID collections (for diagnostics)."""
        return list(hid.enumerate(vid, pid))

    # ---- low level ---------------------------------------------------------
    def _write(self, payload: bytes, prefix: bytes = CRT):
        buf = prefix + payload
        if len(buf) < PACKET:
            buf += b"\x00" * (PACKET - len(buf))
        self.h.write(b"\x00" + buf)     # hidapi: first byte is the report id

    def _write_raw_chunks(self, data: bytes):
        for off in range(0, len(data), PACKET):
            self._write(data[off:off + PACKET], prefix=b"")

    def set_mode(self, mode: int):
        self._write(b"MOD\x00\x00" + bytes([0x30 + mode]))

    def initialize(self, mode: int = MODE_SOFTWARE):
        """Switch to software mode (so buttons report here), then run the
        DIS + LIG init handshake. Must run before reading button events."""
        self.set_mode(mode)
        time.sleep(0.05)
        self._write(b"DIS\x00\x00")
        self._write(b"LIG\x00\x00\x00\x00")

    def keep_alive(self):
        """Send CONNECT. Poll this periodically (~every 1-3s) or the firmware
        falls back to its onboard kiosk/screensaver image and drops the keys
        you've drawn. The control loop (streamdock.control) does this for you."""
        self._write(b"CONNECT")

    # ---- commands ----------------------------------------------------------
    def wake(self):
        self._write(b"DIS\x00\x00")

    def set_brightness(self, percent: int):
        percent = max(0, min(100, int(percent)))
        self._write(b"LIG\x00\x00" + bytes([percent]))

    def clear_all(self):
        self._write(b"CLE\x00\x00\x00\xff")

    def clear_slot(self, slot: int):
        self._write(b"CLE\x00\x00\x00" + bytes([slot]))

    def refresh(self):
        self._write(b"STP\x00\x00")

    def firmware_version(self) -> str:
        data = bytes(self.h.get_feature_report(0x01, 512))
        return data.split(b"\x00", 1)[0].decode("ascii", "replace")

    def set_slot_image(self, slot: int, image: ImageLike):
        """Draw to a raw image *slot* id. Prefer set_position_image()."""
        if isinstance(image, str):
            img = Image.open(image)
        elif isinstance(image, (bytes, bytearray)):
            img = Image.open(io.BytesIO(bytes(image)))
        else:
            img = image
        img = img.convert("RGB").resize((KEY_PX, KEY_PX)).rotate(ROTATE)
        jpeg = io.BytesIO()
        img.save(jpeg, format="JPEG", quality=100)
        blob = jpeg.getvalue()
        self._write(b"BAT" + struct.pack(">I", len(blob)) + bytes([slot]))
        self._write_raw_chunks(blob)
        self.refresh()

    def set_slot_color(self, slot: int, rgb: RGB):
        self.set_slot_image(slot, Image.new("RGB", (KEY_PX, KEY_PX), rgb))

    # ---- position API (reading order 0..N-1; handles the slot remap) -------
    def has_screen(self, position: int) -> bool:
        return self.layout.has_screen(position)

    def set_position_image(self, position: int, image: ImageLike) -> bool:
        """Draw to the key at reading-order `position` (0 = top-left).
        Returns False for screenless keys (nothing drawn)."""
        slot = self.layout.slot(position)
        if slot is None:
            return False
        self.set_slot_image(slot, image)
        return True

    def set_position_color(self, position: int, rgb: RGB) -> bool:
        slot = self.layout.slot(position)
        if slot is None:
            return False
        self.set_slot_color(slot, rgb)
        return True

    def clear_position(self, position: int) -> bool:
        slot = self.layout.slot(position)
        if slot is None:
            return False
        self.clear_slot(slot)
        return True

    # ---- input -------------------------------------------------------------
    def read_raw(self, timeout_ms: int = 1000) -> bytes:
        return bytes(self.h.read(512, timeout_ms))

    def read_key(self, timeout_ms: int = 1000):
        """Return (key_id, is_down) or None on timeout. key_id is the device's
        own 1-based id (byte 9); state byte (10) is 1 on press, 0 on release."""
        r = self.read_raw(timeout_ms)
        if not r or len(r) < 11 or r[:3] != b"ACK":
            return None
        return (r[9], bool(r[10]))

    def read_position(self, timeout_ms: int = 1000):
        """Like read_key but returns (position, is_down) in reading order
        (0 = top-left .. N-1 = bottom-right), or None on timeout."""
        ev = self.read_key(timeout_ms)
        if ev is None:
            return None
        key_id, down = ev
        return (self.layout.key_id_to_position(key_id), down)

    # ---- lifecycle ---------------------------------------------------------
    def close(self):
        try:
            self.h.close()
        except Exception:
            pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
