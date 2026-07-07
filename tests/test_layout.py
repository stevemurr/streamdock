"""Pure-logic tests for the layout mapping (no hardware needed)."""
from streamdock.layout import DEFAULT_LAYOUT, HOTSPOTEK_5548_1000, Layout


def test_default_is_the_calibrated_unit():
    assert DEFAULT_LAYOUT is HOTSPOTEK_5548_1000
    assert DEFAULT_LAYOUT.key_count == 13


def test_reading_order_key_id_roundtrip():
    lay = DEFAULT_LAYOUT
    for pos in range(lay.key_count):
        assert lay.key_id_to_position(lay.position_to_key_id(pos)) == pos
    # key_id 1 == top-left position 0
    assert lay.key_id_to_position(1) == 0
    assert lay.position_to_key_id(0) == 1


def test_screen_vs_button_split():
    lay = DEFAULT_LAYOUT
    lcd = [p for p in range(lay.key_count) if lay.has_screen(p)]
    buttons = [p for p in range(lay.key_count) if not lay.has_screen(p)]
    assert lcd == list(range(10))          # first 10 are LCD keys
    assert buttons == [10, 11, 12]         # bottom row has no screens


def test_slot_mapping_values():
    lay = DEFAULT_LAYOUT
    assert [lay.slot(p) for p in range(5)] == [11, 12, 13, 14, 15]   # top row
    assert [lay.slot(p) for p in range(5, 10)] == [6, 7, 8, 9, 10]   # 2nd row
    assert all(lay.slot(p) is None for p in (10, 11, 12))            # buttons


def test_screen_slots_are_unique():
    lay = DEFAULT_LAYOUT
    slots = [lay.slot(p) for p in range(lay.key_count) if lay.has_screen(p)]
    assert len(slots) == len(set(slots))


def test_has_screen_bounds():
    lay = DEFAULT_LAYOUT
    assert not lay.has_screen(-1)
    assert not lay.has_screen(lay.key_count)


def test_layout_is_frozen():
    import dataclasses

    import pytest

    with pytest.raises(dataclasses.FrozenInstanceError):
        DEFAULT_LAYOUT.name = "nope"  # type: ignore[misc]


def test_custom_layout():
    lay = Layout(name="tiny", rows=1, cols=2, position_to_slot=(0, None))
    assert lay.key_count == 2
    assert lay.has_screen(0) and not lay.has_screen(1)
