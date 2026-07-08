"""Tests for the control-loop event state machine (sleep / wake / press).

`plan_event` is pure, so the whole sleep-key behavior is verified here without
any hardware.
"""
from streamdock.control import KeyConfig, plan_event


def key(**kw):
    return KeyConfig(position=0, **kw)


# ---- sleep / wake ----------------------------------------------------------
def test_press_while_asleep_wakes_and_is_consumed():
    # any key press while asleep -> wake, and it does NOT dispatch that key
    assert plan_event(True, key(command="open x"), down=True, has_render=True) == (False, ["wake"])


def test_release_while_asleep_does_nothing():
    assert plan_event(True, key(), down=False, has_render=True) == (True, [])


def test_sleep_key_puts_display_to_sleep():
    assert plan_event(False, key(action="sleep"), down=True, has_render=True) == (True, ["sleep"])


def test_sleep_key_runs_its_command_first():
    plan = plan_event(False, key(action="sleep", command="hass off"), down=True, has_render=True)
    assert plan == (True, ["dispatch", "sleep"])


def test_full_sleep_then_wake_cycle():
    asleep, eff = plan_event(False, key(action="sleep"), down=True, has_render=True)
    assert asleep and eff == ["sleep"]
    # the sleep key's own release while asleep is ignored
    asleep, eff = plan_event(asleep, key(action="sleep"), down=False, has_render=True)
    assert asleep and eff == []
    # next press wakes it
    asleep, eff = plan_event(asleep, key(command="x"), down=True, has_render=True)
    assert asleep is False and eff == ["wake"]


# ---- normal presses --------------------------------------------------------
def test_normal_press_flashes_then_dispatches():
    assert plan_event(False, key(command="open x"), down=True, has_render=True) \
        == (False, ["flash", "dispatch"])


def test_press_without_screen_only_dispatches():
    # a screenless button (has_render False) still runs its command, no flash
    assert plan_event(False, key(command="say hi"), down=True, has_render=False) \
        == (False, ["dispatch"])


def test_press_without_command_only_flashes():
    assert plan_event(False, key(), down=True, has_render=True) == (False, ["flash"])


def test_release_restores_rendered_image():
    assert plan_event(False, key(command="x"), down=False, has_render=True) == (False, ["restore"])


def test_release_without_render_is_noop():
    assert plan_event(False, key(), down=False, has_render=False) == (False, [])


def test_unconfigured_position_is_ignored():
    assert plan_event(False, None, down=True, has_render=False) == (False, [])
