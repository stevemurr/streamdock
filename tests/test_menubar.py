"""The menu bar app itself needs a GUI session, but the module must import
cleanly (rumps is imported lazily inside run_with_menubar) and expose a title."""
import streamdock.menubar as mb


def test_module_imports_without_rumps_present():
    # importing the module must not require rumps (it's imported lazily)
    assert hasattr(mb, "run_with_menubar")


def test_title_is_a_nonempty_string():
    assert isinstance(mb.TITLE, str) and mb.TITLE.strip()


def test_runner_exposes_status_for_the_menu():
    # the menu bar reads Runner.status; make sure it exists with a default
    from streamdock.control import Config, Runner
    r = Runner(Config())
    assert isinstance(r.status, str) and r.status
