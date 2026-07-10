"""Paging: the pure page-switch decision, page keys in plan_event, keeping the
active page across a config reload, and the hot-reload parse-error guard."""
from streamdock.control import (
    Config,
    KeyConfig,
    Page,
    load_config,
    plan_event,
    preserve_page_index,
    reload_config,
    resolve_page,
    save_config,
)

NAMES = ["main", "media", "dev"]


def key(**kw):
    return KeyConfig(position=0, **kw)


# ---- resolve_page ------------------------------------------------------------
def test_next_advances_and_wraps():
    assert resolve_page(NAMES, 0, "page:next") == 1
    assert resolve_page(NAMES, 2, "page:next") == 0


def test_prev_goes_back_and_wraps():
    assert resolve_page(NAMES, 2, "page:prev") == 1
    assert resolve_page(NAMES, 0, "page:prev") == 2


def test_goto_page_by_name():
    assert resolve_page(NAMES, 0, "page:dev") == 2
    assert resolve_page(NAMES, 2, "page:main") == 0


def test_unknown_page_name_is_noop():
    assert resolve_page(NAMES, 0, "page:nope") is None


def test_non_page_actions_and_empty_deck_are_noops():
    assert resolve_page(NAMES, 0, "sleep") is None
    assert resolve_page(NAMES, 0, None) is None
    assert resolve_page([], 0, "page:next") is None


def test_single_page_next_stays_put():
    assert resolve_page(["main"], 0, "page:next") == 0


# ---- plan_event with page keys --------------------------------------------------
def test_page_key_press_switches_without_flash():
    # no flash: the whole deck re-renders, so no flash/restore over stale faces
    assert plan_event(False, key(action="page:next"), down=True, has_render=True) \
        == (False, ["page"])


def test_page_key_with_command_dispatches_first():
    assert plan_event(False, key(action="page:media", command="say hi"),
                      down=True, has_render=True) == (False, ["dispatch", "page"])


def test_page_key_press_while_asleep_only_wakes():
    assert plan_event(True, key(action="page:next"), down=True, has_render=True) \
        == (False, ["wake"])


def test_app_key_press_flashes_and_dispatches():
    assert plan_event(False, key(app="Terminal"), down=True, has_render=True) \
        == (False, ["flash", "dispatch"])


# ---- preserve_page_index ---------------------------------------------------------
def pages(*names):
    return [Page(name=n) for n in names]


def test_active_page_is_kept_by_name_across_reload():
    assert preserve_page_index(pages("main", "media"), 1, pages("media", "main", "dev")) == 0
    assert preserve_page_index(pages("main", "media"), 1, pages("x", "media")) == 1


def test_vanished_page_falls_back_to_first():
    assert preserve_page_index(pages("main", "media"), 1, pages("main", "dev")) == 0
    assert preserve_page_index(pages("main"), 5, pages("main")) == 0     # bad old index


# ---- hot-reload guard --------------------------------------------------------------
def cfg2():
    return Config(pages=[Page(name="main", keys=[KeyConfig(position=0, label="A")]),
                         Page(name="media")])


def test_reload_returns_new_config_on_valid_file(tmp_path):
    p = tmp_path / "deck.yaml"
    save_config(cfg2(), p)
    old = Config()
    new = reload_config(p, old)
    assert new is not old
    assert [pg.name for pg in new.pages] == ["main", "media"]


def test_parse_error_keeps_the_old_config(tmp_path):
    p = tmp_path / "deck.yaml"
    save_config(cfg2(), p)
    old = load_config(p)
    p.write_text("pages: [ {name: broken\n")         # half-written / torn file
    assert reload_config(p, old) is old
    p.write_text("- just\n- a list\n")                # parses, but wrong root type
    assert reload_config(p, old) is old


def test_missing_file_keeps_the_old_config(tmp_path):
    old = cfg2()
    assert reload_config(tmp_path / "gone.yaml", old) is old
