"""Persistent control loop.

Renders a configured button layout, dispatches presses to actions, and sends a
periodic keep-alive so the device stays in software mode instead of reverting
to its onboard kiosk/screensaver image. Auto-reconnects if the device is
unplugged. Drive it from a TOML config via ``streamdock run``.
"""
from __future__ import annotations

import os
import re
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

from PIL import Image

from ._color import parse_color
from .device import KEY_PX, PID, VID, DeviceNotFound, StreamDock
from .render import render_key

try:
    import tomllib as _toml
except ModuleNotFoundError:      # Python < 3.11
    import tomli as _toml


@dataclass
class KeyConfig:
    position: int
    label: "str | None" = None
    icon: "str | None" = None
    image: "str | None" = None
    color: "tuple[int, int, int] | None" = None
    level: "float | None" = None       # 0..1 fill for brightness/meter icons
    command: "str | None" = None
    action: "str | None" = None        # built-in action, e.g. "sleep"


@dataclass
class Config:
    brightness: int = 80
    keepalive_seconds: float = 2.0
    clear_on_exit: bool = True
    env_file: "str | None" = None      # KEY=VALUE file loaded into the command env
    base_dir: Path = field(default_factory=Path.cwd)
    keys: "list[KeyConfig]" = field(default_factory=list)


def load_config(path: "str | Path") -> Config:
    path = Path(path)
    with open(path, "rb") as f:
        data = _toml.load(f)
    settings = data.get("settings", {})
    keys = []
    for k in data.get("keys", []):
        if "position" not in k:
            raise ValueError(f"key entry missing 'position': {k!r}")
        keys.append(KeyConfig(
            position=int(k["position"]),
            label=k.get("label"),
            icon=k.get("icon"),
            image=k.get("image"),
            color=parse_color(k["color"]) if k.get("color") else None,
            level=float(k["level"]) if k.get("level") is not None else None,
            command=k.get("command"),
            action=k.get("action"),
        ))
    return Config(
        brightness=int(settings.get("brightness", 80)),
        keepalive_seconds=float(settings.get("keepalive_seconds", 2.0)),
        clear_on_exit=bool(settings.get("clear_on_exit", True)),
        env_file=settings.get("env_file"),
        base_dir=path.resolve().parent,
        keys=keys,
    )


# Per-row downward content nudge (fraction of key height). Some rows on this
# device map the image with a slightly different vertical crop; nudging the
# content compensates. Keyed by row index (0 = top).
ROW_NUDGE = {2: 0.07}

_LEVEL_ICONS = {"brightness", "meter", "contrast"}


def _auto_level(key: KeyConfig):
    """Fill level for meter-style icons: explicit `level`, else a number in the
    label (e.g. '75%' -> 0.75)."""
    if key.level is not None:
        return key.level if key.level <= 1 else key.level / 100
    if key.icon in _LEVEL_ICONS and key.label:
        m = re.search(r"\d+", key.label)
        if m:
            return min(1.0, int(m.group()) / 100)
    return None


def plan_event(asleep, key, down, has_render):
    """Pure decision for a key event. Returns (new_asleep, effects) where
    effects is an ordered list drawn from: 'wake', 'sleep', 'dispatch', 'flash',
    'restore'. Kept pure so the sleep/wake/press behavior is unit-testable
    without any hardware.

    - while asleep, any key *press* wakes the deck and is otherwise consumed
    - a key whose action == 'sleep' puts the display to sleep (running its
      command first, if it has one)
    - a normal press flashes (if it has a rendered image) then dispatches its
      command; release restores the image
    """
    if asleep:
        return (False, ["wake"]) if down else (True, [])
    if key is None:
        return (asleep, [])
    if down:
        if key.action == "sleep":
            return (True, (["dispatch"] if key.command else []) + ["sleep"])
        effects = []
        if has_render:
            effects.append("flash")
        if key.command:
            effects.append("dispatch")
        return (False, effects)
    return (asleep, ["restore"] if has_render else [])   # key release


class Runner:
    def __init__(self, config: Config, vid: int = VID, pid: int = PID, verbose: bool = True):
        self.cfg = config
        self.vid = vid
        self.pid = pid
        self.verbose = verbose
        self.by_pos = {k.position: k for k in config.keys}
        self._rendered: "dict[int, Image.Image]" = {}
        self.status = "starting"        # human-readable state for the menu bar

    def _log(self, *a):
        if self.verbose:
            print(*a, flush=True)

    # ---- rendering ---------------------------------------------------------
    def _key_image(self, key: KeyConfig, nudge_y: float = 0.0):
        if key.image:
            p = key.image if os.path.isabs(key.image) else str(self.cfg.base_dir / key.image)
            return Image.open(p).convert("RGB").resize((KEY_PX, KEY_PX))
        if key.label or key.icon or key.color:
            return render_key(label=key.label, icon=key.icon, color=key.color,
                              level=_auto_level(key), nudge_y=nudge_y)
        return None

    def render_all(self, sd: StreamDock):
        self._rendered.clear()
        sd.clear_all()
        cols = sd.layout.cols
        for pos, key in sorted(self.by_pos.items()):
            if not sd.has_screen(pos):
                continue      # screenless buttons can still have a command
            nudge = ROW_NUDGE.get(pos // cols, 0.0)
            img = self._key_image(key, nudge_y=nudge)
            if img is None:
                continue
            self._rendered[pos] = img
            sd.set_position_image(pos, img)

    # ---- actions -----------------------------------------------------------
    def _dispatch(self, key: KeyConfig):
        if not key.command:
            return
        self._log(f"  -> {key.command}")
        try:
            subprocess.Popen(key.command, shell=True)
        except Exception as e:      # noqa: BLE001
            self._log(f"  !! command failed: {e}")

    # ---- loop --------------------------------------------------------------
    def _load_env(self):
        """Load KEY=VALUE lines from cfg.env_file into os.environ so button
        commands (run via the shell) can reference secrets like $HA_TOKEN
        without hardcoding them in the config."""
        ef = self.cfg.env_file
        if not ef:
            return
        p = ef if os.path.isabs(ef) else str(self.cfg.base_dir / ef)
        try:
            with open(p) as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    k, v = line.split("=", 1)
                    os.environ[k.strip()] = v.strip().strip('"').strip("'")
        except FileNotFoundError:
            self._log(f"env_file not found: {p}")

    def run(self):
        """Run forever, reconnecting if the device disappears. Ctrl-C to stop."""
        self._load_env()
        while True:
            try:
                self._run_session()
                return  # clean Ctrl-C exit
            except (DeviceNotFound, OSError) as e:
                self.status = "device not found — retrying"
                self._log(f"device unavailable ({e}); retrying in 2s...")
                time.sleep(2.0)

    def _run_session(self):
        with StreamDock(self.vid, self.pid) as sd:
            sd.initialize()
            sd.set_brightness(self.cfg.brightness)
            self.render_all(sd)
            self.status = f"running — {sd.firmware_version()}, {len(self._rendered)} keys"
            self._log(f"control loop running: {len(self._rendered)} keys drawn, "
                      f"{len(self.by_pos)} configured, keep-alive every "
                      f"{self.cfg.keepalive_seconds}s. Ctrl-C to stop.")
            last_ka = 0.0
            asleep = False
            try:
                while True:
                    now = time.monotonic()
                    if now - last_ka >= self.cfg.keepalive_seconds:
                        sd.keep_alive()          # keep alive even while asleep
                        last_ka = now
                    ev = sd.read_position(timeout_ms=200)
                    if ev is None:
                        continue
                    pos, down = ev
                    key = self.by_pos.get(pos)
                    asleep, effects = plan_event(asleep, key, down, pos in self._rendered)
                    for eff in effects:
                        if eff == "wake":
                            sd.wake()
                            sd.set_brightness(self.cfg.brightness)
                            self.render_all(sd)                            # buttons back
                            self.status = self.status.replace("asleep — ", "")
                            self._log("woke")
                        elif eff == "sleep":
                            sd.sleep_display()                             # panel off
                            self.status = "asleep — " + self.status
                            self._log("sleeping")
                        elif eff == "dispatch":
                            self._dispatch(key)
                        elif eff == "flash":
                            sd.set_position_color(pos, (255, 255, 255))    # press flash
                        elif eff == "restore":
                            sd.set_position_image(pos, self._rendered[pos])
            except KeyboardInterrupt:
                self._log("\nstopping")
                if self.cfg.clear_on_exit:
                    sd.clear_all()
