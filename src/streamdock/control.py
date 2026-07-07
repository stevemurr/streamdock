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
        ))
    return Config(
        brightness=int(settings.get("brightness", 80)),
        keepalive_seconds=float(settings.get("keepalive_seconds", 2.0)),
        clear_on_exit=bool(settings.get("clear_on_exit", True)),
        env_file=settings.get("env_file"),
        base_dir=path.resolve().parent,
        keys=keys,
    )


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


class Runner:
    def __init__(self, config: Config, vid: int = VID, pid: int = PID, verbose: bool = True):
        self.cfg = config
        self.vid = vid
        self.pid = pid
        self.verbose = verbose
        self.by_pos = {k.position: k for k in config.keys}
        self._rendered: "dict[int, Image.Image]" = {}

    def _log(self, *a):
        if self.verbose:
            print(*a, flush=True)

    # ---- rendering ---------------------------------------------------------
    def _key_image(self, key: KeyConfig):
        if key.image:
            p = key.image if os.path.isabs(key.image) else str(self.cfg.base_dir / key.image)
            return Image.open(p).convert("RGB").resize((KEY_PX, KEY_PX))
        if key.label or key.icon or key.color:
            return render_key(label=key.label, icon=key.icon, color=key.color,
                              level=_auto_level(key))
        return None

    def render_all(self, sd: StreamDock):
        self._rendered.clear()
        sd.clear_all()
        for pos, key in sorted(self.by_pos.items()):
            if not sd.has_screen(pos):
                continue      # screenless buttons can still have a command
            img = self._key_image(key)
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
                self._log(f"device unavailable ({e}); retrying in 2s...")
                time.sleep(2.0)

    def _run_session(self):
        with StreamDock(self.vid, self.pid) as sd:
            sd.initialize()
            sd.set_brightness(self.cfg.brightness)
            self.render_all(sd)
            self._log(f"control loop running: {len(self._rendered)} keys drawn, "
                      f"{len(self.by_pos)} configured, keep-alive every "
                      f"{self.cfg.keepalive_seconds}s. Ctrl-C to stop.")
            last_ka = 0.0
            try:
                while True:
                    now = time.monotonic()
                    if now - last_ka >= self.cfg.keepalive_seconds:
                        sd.keep_alive()
                        last_ka = now
                    ev = sd.read_position(timeout_ms=200)
                    if ev is None:
                        continue
                    pos, down = ev
                    key = self.by_pos.get(pos)
                    tag = "LCD" if sd.has_screen(pos) else "button"
                    self._log(f"position {pos} ({tag}) {'DOWN' if down else 'up'}")
                    if key is None:
                        continue
                    if down:
                        if pos in self._rendered:
                            sd.set_position_color(pos, (255, 255, 255))   # press flash
                        self._dispatch(key)
                    elif pos in self._rendered:
                        sd.set_position_image(pos, self._rendered[pos])   # restore
            except KeyboardInterrupt:
                self._log("\nstopping")
                if self.cfg.clear_on_exit:
                    sd.clear_all()
