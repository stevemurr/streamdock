"""Persistent control loop.

Renders a configured button layout, dispatches presses to actions, and sends a
periodic keep-alive so the device stays in software mode instead of reverting
to its onboard kiosk/screensaver image. Auto-reconnects if the device is
unplugged. Drive it from a YAML (or legacy TOML) config via ``streamdock run``.
"""
from __future__ import annotations

import os
import re
import shlex
import subprocess
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

import yaml
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
    app: "str | None" = None           # macOS app name; sugar for `open -a <app>`
    command: "str | None" = None
    action: "str | None" = None        # built-in action: "sleep", "page:..."


@dataclass
class Page:
    name: str = "main"
    keys: "list[KeyConfig]" = field(default_factory=list)


@dataclass
class Config:
    brightness: int = 80
    keepalive_seconds: float = 2.0
    clear_on_exit: bool = True
    env_file: "str | None" = None      # KEY=VALUE file loaded into the command env
    base_dir: Path = field(default_factory=Path.cwd)
    pages: "list[Page]" = field(default_factory=list)


def effective_command(key: KeyConfig) -> "str | None":
    """The shell command a key runs on press: raw ``command`` wins, else the
    ``app`` sugar expands to ``open -a <name>``."""
    if key.command:
        return key.command
    if key.app:
        return "open -a " + shlex.quote(key.app)
    return None


# ---- config (de)serialization ----------------------------------------------
# The dict shape below is the YAML representation used for configuration:
# {"settings": {...}, "pages": [{"name": ..., "keys": [{...}, ...]}]}.

def key_from_dict(k: dict) -> KeyConfig:
    if "position" not in k:
        raise ValueError(f"key entry missing 'position': {k!r}")
    color = k.get("color")
    if isinstance(color, (list, tuple)):
        color = tuple(int(c) for c in color)
        if len(color) != 3:
            raise ValueError(f"color must have 3 components: {k.get('color')!r}")
    elif color:
        color = parse_color(str(color))
    else:
        color = None
    return KeyConfig(
        position=int(k["position"]),
        label=k.get("label"),
        icon=k.get("icon"),
        image=k.get("image"),
        color=color,
        level=float(k["level"]) if k.get("level") is not None else None,
        app=k.get("app"),
        command=k.get("command"),
        action=k.get("action"),
    )


def key_to_dict(key: KeyConfig) -> dict:
    """Serialize one key, omitting unset fields, in a stable order."""
    d: dict = {"position": key.position}
    for name in ("label", "icon", "image"):
        v = getattr(key, name)
        if v is not None:
            d[name] = v
    if key.color is not None:
        d["color"] = "#%02x%02x%02x" % tuple(key.color)
    if key.level is not None:
        d["level"] = key.level
    for name in ("app", "command", "action"):
        v = getattr(key, name)
        if v is not None:
            d[name] = v
    return d


def config_from_dict(data: dict, base_dir: "str | Path | None" = None) -> Config:
    settings = data.get("settings") or {}
    pages = []
    for i, p in enumerate(data.get("pages") or []):
        name = str(p.get("name") or "").strip() or f"page{i + 1}"
        pages.append(Page(name=name, keys=[key_from_dict(k) for k in (p.get("keys") or [])]))
    if not pages:
        pages = [Page(name="main")]
    return Config(
        brightness=int(settings.get("brightness", 80)),
        keepalive_seconds=float(settings.get("keepalive_seconds", 2.0)),
        clear_on_exit=bool(settings.get("clear_on_exit", True)),
        env_file=settings.get("env_file"),
        base_dir=Path(base_dir) if base_dir else Path.cwd(),
        pages=pages,
    )


def config_to_dict(cfg: Config) -> dict:
    settings: dict = {
        "brightness": cfg.brightness,
        "keepalive_seconds": cfg.keepalive_seconds,
        "clear_on_exit": cfg.clear_on_exit,
    }
    if cfg.env_file:
        settings["env_file"] = cfg.env_file
    return {
        "settings": settings,
        "pages": [{"name": p.name, "keys": [key_to_dict(k) for k in p.keys]}
                  for p in cfg.pages],
    }


def _load_toml_config(path: Path) -> Config:
    """Legacy flat TOML: a [[keys]] list, loaded as a single page named 'main'."""
    with open(path, "rb") as f:
        data = _toml.load(f)
    keys = [key_from_dict(k) for k in data.get("keys", [])]
    cfg = config_from_dict({"settings": data.get("settings", {}),
                            "pages": [{"name": "main"}]},
                           base_dir=path.resolve().parent)
    cfg.pages[0].keys = keys
    return cfg


def _load_yaml_config(path: Path) -> Config:
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f)
    if data is None:
        data = {}
    if not isinstance(data, dict):
        raise ValueError(f"config root must be a mapping, got {type(data).__name__}")
    return config_from_dict(data, base_dir=path.resolve().parent)


def load_config(path: "str | Path") -> Config:
    """Load a config file: .yaml/.yml -> paged schema, anything else -> legacy
    flat TOML (kept working so existing streamdock.toml users are unaffected)."""
    path = Path(path)
    if path.suffix.lower() in (".yaml", ".yml"):
        return _load_yaml_config(path)
    return _load_toml_config(path)


def save_config(cfg: Config, path: "str | Path") -> None:
    """Write the config as clean YAML. Atomic: writes a temp file in the same
    directory then os.replace()s it, so a concurrently-running control loop's
    hot-reload never sees a torn file."""
    path = Path(path)
    text = yaml.safe_dump(config_to_dict(cfg), sort_keys=False,
                          default_flow_style=None, allow_unicode=True, width=120)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent or Path(".")),
                               prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ---- paging ------------------------------------------------------------------

def resolve_page(names: "list[str]", current: int, action: "str | None") -> "int | None":
    """Pure paging decision: map a 'page:next' / 'page:prev' / 'page:<name>'
    action to a new page index, or None for a no-op (unknown action/name).
    next/prev wrap around."""
    if not action or not action.startswith("page:") or not names:
        return None
    spec = action[len("page:"):].strip()
    if spec == "next":
        return (current + 1) % len(names)
    if spec == "prev":
        return (current - 1) % len(names)
    if spec in names:
        return names.index(spec)
    return None


def preserve_page_index(old_pages: "list[Page]", old_index: int,
                        new_pages: "list[Page]") -> int:
    """After a config reload, keep the active page by *name* when possible,
    else fall back to the first page."""
    if 0 <= old_index < len(old_pages):
        name = old_pages[old_index].name
        for i, p in enumerate(new_pages):
            if p.name == name:
                return i
    return 0


def reload_config(path: "str | Path", old_cfg: Config) -> Config:
    """Reload the config file; on *any* error (half-written file, parse error,
    vanished file) return the old config unchanged."""
    try:
        return load_config(path)
    except Exception:  # noqa: BLE001
        return old_cfg


# Whole-face display calibration: (dx, dy) as a fraction of key width / height.
# The physical panel can crop a few pixels off an edge; this shifts the *entire*
# rendered face — frame, icon and caption together — so the composition lands
# centered after that crop. Applied uniformly to every key (the crop is the same
# for all of them). (0, 0) = no shift, which is correct when KEY_PX matches the
# panel's native size; tune on hardware only if the faces sit off-center.
DISPLAY_CAL = (0.0, 0.0)

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
    'restore', 'page'. Kept pure so the sleep/wake/press behavior is
    unit-testable without any hardware.

    - while asleep, any key *press* wakes the deck and is otherwise consumed
    - a key whose action == 'sleep' puts the display to sleep (running its
      command first, if it has one)
    - a key whose action is 'page:...' switches the active page (running its
      command first, if it has one); no flash — the whole deck re-renders
    - a normal press flashes (if it has a rendered image) then dispatches its
      command; release restores the image
    """
    if asleep:
        return (False, ["wake"]) if down else (True, [])
    if key is None:
        return (asleep, [])
    if down:
        has_cmd = bool(key.command or key.app)
        if key.action == "sleep":
            return (True, (["dispatch"] if has_cmd else []) + ["sleep"])
        if key.action and key.action.startswith("page:"):
            return (False, (["dispatch"] if has_cmd else []) + ["page"])
        effects = []
        if has_render:
            effects.append("flash")
        if has_cmd:
            effects.append("dispatch")
        return (False, effects)
    return (asleep, ["restore"] if has_render else [])   # key release


class Runner:
    RELOAD_CHECK_SECONDS = 2.0          # how often to poll the config's mtime

    def __init__(self, config: Config, vid: int = VID, pid: int = PID, verbose: bool = True,
                 config_path: "str | Path | None" = None):
        self.cfg = config
        self.vid = vid
        self.pid = pid
        self.verbose = verbose
        self.config_path = Path(config_path) if config_path else None
        self.page_index = 0
        self.by_pos = self._active_by_pos()
        self._rendered: "dict[int, Image.Image]" = {}
        self._cfg_mtime = self._config_mtime()
        self._last_reload_check = 0.0
        self.status = "starting"        # human-readable state for the menu bar

    def _log(self, *a):
        if self.verbose:
            print(*a, flush=True)

    # ---- pages -------------------------------------------------------------
    def _active_by_pos(self) -> "dict[int, KeyConfig]":
        """Position -> key map for the active page (clamping the index)."""
        if not self.cfg.pages:
            return {}
        self.page_index = max(0, min(self.page_index, len(self.cfg.pages) - 1))
        return {k.position: k for k in self.cfg.pages[self.page_index].keys}

    def _switch_page(self, sd: StreamDock, action: "str | None"):
        names = [p.name for p in self.cfg.pages]
        idx = resolve_page(names, self.page_index, action)
        if idx is None or idx == self.page_index:
            return
        self.page_index = idx
        self.by_pos = self._active_by_pos()
        self.render_all(sd)             # full redraw; no flash/restore of stale faces
        self._log(f"page -> {names[idx]}")

    # ---- config hot-reload ---------------------------------------------------
    def _config_mtime(self):
        if self.config_path is None:
            return None
        try:
            return os.stat(self.config_path).st_mtime
        except OSError:
            return None

    def _maybe_reload_config(self, sd: StreamDock, now: float, asleep: bool):
        """Poll the config file's mtime (at most every RELOAD_CHECK_SECONDS) and
        hot-apply changes. A file that fails to parse keeps the previous
        config."""
        if self.config_path is None or now - self._last_reload_check < self.RELOAD_CHECK_SECONDS:
            return
        self._last_reload_check = now
        mtime = self._config_mtime()
        if mtime is None or mtime == self._cfg_mtime:
            return
        self._cfg_mtime = mtime
        new_cfg = reload_config(self.config_path, self.cfg)
        if new_cfg is self.cfg:
            self._log(f"config change ignored (parse error): {self.config_path}")
            return
        old_pages, old_index = self.cfg.pages, self.page_index
        self.cfg = new_cfg
        self.page_index = preserve_page_index(old_pages, old_index, new_cfg.pages)
        self.by_pos = self._active_by_pos()
        if not asleep:
            sd.set_brightness(self.cfg.brightness)
            self.render_all(sd)         # while asleep, the wake path re-renders
        self._log(f"config reloaded: {self.config_path}")

    # ---- rendering ---------------------------------------------------------
    def _key_image(self, key: KeyConfig, key_px: int = KEY_PX,
                   nudge_x: float = 0.0, nudge_y: float = 0.0):
        if key.image:
            p = key.image if os.path.isabs(key.image) else str(self.cfg.base_dir / key.image)
            return Image.open(p).convert("RGB").resize((key_px, key_px))
        if key.label or key.icon or key.color:
            return render_key(label=key.label, icon=key.icon, color=key.color,
                              level=_auto_level(key), nudge_x=nudge_x, nudge_y=nudge_y,
                              key_px=key_px)
        return None

    def render_all(self, sd: StreamDock):
        self._rendered.clear()
        sd.clear_all()
        cal_x, cal_y = DISPLAY_CAL
        key_px = sd.profile.key_px
        for pos, key in sorted(self.by_pos.items()):
            if not sd.has_screen(pos):
                continue      # screenless buttons can still have a command
            img = self._key_image(key, key_px=key_px, nudge_x=cal_x, nudge_y=cal_y)
            if img is None:
                continue
            self._rendered[pos] = img
            sd.set_position_image(pos, img)

    # ---- actions -----------------------------------------------------------
    def _dispatch(self, key: KeyConfig):
        cmd = effective_command(key)
        if not cmd:
            return
        self._log(f"  -> {cmd}")
        try:
            subprocess.Popen(cmd, shell=True)
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
                    self._maybe_reload_config(sd, now, asleep)
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
                        elif eff == "page":
                            self._switch_page(sd, key.action)
                        elif eff == "flash":
                            sd.set_position_color(pos, (255, 255, 255))    # press flash
                        elif eff == "restore":
                            sd.set_position_image(pos, self._rendered[pos])
            except KeyboardInterrupt:
                self._log("\nstopping")
                if self.cfg.clear_on_exit:
                    sd.clear_all()
