"""macOS menu bar indicator for the streamdock daemon.

Shows a menu bar icon while the control loop is running, so you can see the
daemon is alive and read its device status. The control loop runs on a
background thread; the menu bar (rumps / AppKit) owns the main thread.

Requires ``rumps`` (a macOS-only dependency, installed automatically on macOS).
"""
from __future__ import annotations

import threading

TITLE = "🎛"          # menu bar glyph — its presence means the daemon is running


def run_with_menubar(runner) -> None:
    """Run ``runner`` on a background thread and show a menu bar item on the
    main thread. Blocks until the user quits from the menu."""
    try:
        import rumps
    except ImportError as e:      # pragma: no cover - depends on platform
        raise RuntimeError(
            "the --menubar option needs 'rumps' (macOS only). "
            "Install it with: uv sync   (or: pip install rumps)"
        ) from e

    # menu-bar-only app (no Dock icon)
    try:                          # pragma: no cover
        from AppKit import NSApplication
        NSApplication.sharedApplication().setActivationPolicy_(1)  # Accessory
    except Exception:
        pass

    class StreamDockApp(rumps.App):
        def __init__(self):
            super().__init__(TITLE, quit_button="Quit streamdock")
            self.status_item = rumps.MenuItem(runner.status)   # no callback => disabled/info
            self.menu = [self.status_item, None]
            threading.Thread(target=runner.run, daemon=True).start()

        @rumps.timer(2)
        def _refresh(self, _):
            self.status_item.title = runner.status

    StreamDockApp().run()
