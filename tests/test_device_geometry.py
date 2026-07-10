"""The M18's hardware image contract, independent of a connected device."""
import io
import struct

from PIL import Image

from streamdock.device import StreamDock
from streamdock.profile import HOTSPOTEK_M18, profile_for


def test_exact_usb_id_selects_the_64px_m18_profile():
    profile = profile_for(0x5548, 0x1000)
    assert profile is HOTSPOTEK_M18
    assert profile.key_px == 64


def test_unknown_usb_id_has_no_guessed_geometry():
    assert profile_for(0xFFFF, 0xFFFF) is None


def test_transport_encodes_a_64px_jpeg():
    """Catch regressions between renderer geometry and the actual BAT payload."""
    sd = object.__new__(StreamDock)
    sd.profile = HOTSPOTEK_M18
    captured = {}
    sd._write = lambda payload, prefix=b"": captured.setdefault("header", payload)
    sd._write_raw_chunks = lambda data: captured.setdefault("jpeg", data)
    sd.refresh = lambda: None

    sd.set_slot_image(11, Image.new("RGB", (137, 91), "red"))

    header = captured["header"]
    jpeg = captured["jpeg"]
    assert header[:3] == b"BAT"
    assert struct.unpack(">I", header[3:7])[0] == len(jpeg)
    assert header[7] == 11
    assert Image.open(io.BytesIO(jpeg)).size == (64, 64)
