"""Pure-logic tests for the layout mapping (no hardware needed)."""
from streamdock.layout import DEFAULT_LAYOUT, HOTSPOTEK_5548_1000, Layout


def test_default_is_the_calibrated_unit():
    assert DEFAULT_LAYOUT is HOTSPOTEK_5548_1000
    assert DEFAULT_LAYOUT.key_count == 18     # 15 LCD keys + 3 bottom buttons


def test_reading_order_key_id_roundtrip():
    lay = DEFAULT_LAYOUT
    for pos in range(lay.key_count):
        assert lay.key_id_to_position(lay.position_to_key_id(pos)) == pos
    # key_id 1 == top-left position 0
    assert lay.key_id_to_position(1) == 0
    assert lay.position_to_key_id(0) == 1


def test_grid_keys_have_screens_bottom_buttons_do_not():
    lay = DEFAULT_LAYOUT
    assert all(lay.has_screen(p) for p in range(15))            # all 15 grid keys are LCD
    assert not any(lay.has_screen(p) for p in range(15, 18))    # bottom buttons are not
    assert [lay.slot(p) for p in range(15, 18)] == [None, None, None]


def test_bottom_button_key_ids_map_past_the_grid():
    lay = DEFAULT_LAYOUT
    # ids captured on hardware: left/middle/right under the screen
    assert lay.key_id_to_position(0x25) == 15
    assert lay.key_id_to_position(0x30) == 16
    assert lay.key_id_to_position(0x31) == 17


def test_slot_mapping_values():
    lay = DEFAULT_LAYOUT
    assert [lay.slot(p) for p in range(5)] == [11, 12, 13, 14, 15]     # top row
    assert [lay.slot(p) for p in range(5, 10)] == [6, 7, 8, 9, 10]     # middle row
    assert [lay.slot(p) for p in range(10, 15)] == [1, 2, 3, 4, 5]     # bottom row


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
