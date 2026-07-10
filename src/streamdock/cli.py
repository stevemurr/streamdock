"""Command-line interface: ``streamdock <command>``.

Everything here is a thin wrapper over the same public API you can import:
``from streamdock import StreamDock``.
"""
from __future__ import annotations

import os
import subprocess
import sys
from typing import Optional
from xml.sax.saxutils import escape

import typer

from . import __version__
from ._color import parse_color as _parse_color
from .device import PID, VID, DeviceNotFound, StreamDock

app = typer.Typer(
    add_completion=False,
    help="Control a HOTSPOTEK/MiraBox-Ajazz Stream Dock macropad.",
    no_args_is_help=True,
)


def _err(msg: str) -> "typer.Exit":
    typer.secho(msg, fg=typer.colors.RED, err=True)
    return typer.Exit(code=1)


def parse_color(s: str) -> tuple[int, int, int]:
    try:
        return _parse_color(s)
    except ValueError as e:
        raise typer.BadParameter(str(e))


# shared device options
VidOpt = typer.Option(VID, "--vid", help="USB vendor id.")
PidOpt = typer.Option(PID, "--pid", help="USB product id.")


def _open(vid: int, pid: int, init: bool = True) -> StreamDock:
    try:
        sd = StreamDock(vid, pid)
    except DeviceNotFound as e:
        raise _err(str(e))
    if init:
        sd.initialize()
    return sd


@app.command()
def version():
    """Print the streamdock version."""
    typer.echo(__version__)


@app.command()
def info(vid: int = VidOpt, pid: int = PidOpt):
    """Show device info and the physical layout."""
    with _open(vid, pid) as sd:
        lay = sd.layout
        typer.echo(f"device      : {vid:#06x}:{pid:#06x}")
        typer.echo(f"firmware    : {sd.firmware_version()}")
        typer.echo(f"layout      : {lay.name}")
        typer.echo(f"keys        : {lay.key_count} ({lay.rows}x{lay.cols} nominal)")
        typer.echo("positions   : ('##'=LCD  'btn'=no screen)")
        cols = lay.cols
        for start in range(0, lay.key_count, cols):
            cells = []
            for pos in range(start, min(start + cols, lay.key_count)):
                cells.append(f"{pos:>2}" if lay.has_screen(pos) else "btn")
            typer.echo("   " + "  ".join(cells))


@app.command()
def brightness(
    percent: int = typer.Argument(..., min=0, max=100, help="0-100"),
    vid: int = VidOpt, pid: int = PidOpt,
):
    """Set screen brightness (0-100)."""
    with _open(vid, pid) as sd:
        sd.set_brightness(percent)
    typer.echo(f"brightness -> {percent}%")


@app.command()
def color(
    position: int = typer.Argument(..., help="reading-order key, 0 = top-left"),
    value: str = typer.Argument(..., help="'#rrggbb' or 'r,g,b'"),
    vid: int = VidOpt, pid: int = PidOpt,
):
    """Set one key to a solid color, by reading-order position."""
    rgb = parse_color(value)
    with _open(vid, pid) as sd:
        if not sd.set_position_color(position, rgb):
            raise _err(f"position {position} has no screen (or is out of range)")
    typer.echo(f"position {position} -> rgb{rgb}")


@app.command()
def image(
    position: int = typer.Argument(..., help="reading-order key, 0 = top-left"),
    path: str = typer.Argument(..., help="image file (png/jpg/...)"),
    vid: int = VidOpt, pid: int = PidOpt,
):
    """Draw an image file onto one key."""
    with _open(vid, pid) as sd:
        if not sd.set_position_image(position, path):
            raise _err(f"position {position} has no screen (or is out of range)")
    typer.echo(f"position {position} <- {path}")


@app.command()
def clear(
    position: Optional[int] = typer.Argument(None, help="key to clear; omit for --all"),
    all_: bool = typer.Option(False, "--all", help="clear every key"),
    vid: int = VidOpt, pid: int = PidOpt,
):
    """Clear one key, or all keys with --all."""
    with _open(vid, pid) as sd:
        if all_ or position is None:
            sd.clear_all()
            typer.echo("cleared all")
        else:
            sd.clear_position(position)
            typer.echo(f"cleared position {position}")


@app.command()
def identify(vid: int = VidOpt, pid: int = PidOpt):
    """Draw each key's position number on its screen (layout sanity check)."""
    from PIL import Image, ImageDraw, ImageFont

    def _font(size: int):
        for p in ("/System/Library/Fonts/Helvetica.ttc",
                  "/System/Library/Fonts/Supplemental/Arial.ttf"):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
        return ImageFont.load_default()

    f = _font(56)
    with _open(vid, pid) as sd:
        sd.set_brightness(90)
        sd.clear_all()
        for pos in range(sd.layout.key_count):
            if not sd.has_screen(pos):
                continue
            img = Image.new("RGB", (96, 96), (30, 90, 160) if pos < 5 else (150, 60, 30))
            d = ImageDraw.Draw(img)
            s = str(pos)
            box = d.textbbox((0, 0), s, font=f)
            w, h = box[2] - box[0], box[3] - box[1]
            d.text(((96 - w) / 2 - box[0], (96 - h) / 2 - box[1]), s, font=f, fill="white")
            sd.set_position_image(pos, img)
    typer.echo("drew position numbers on the LCD keys")


@app.command()
def rainbow(vid: int = VidOpt, pid: int = PidOpt):
    """Paint every LCD key with a rainbow (demo)."""
    palette = [(230, 20, 20), (230, 120, 0), (220, 200, 0), (60, 200, 40),
               (30, 160, 220), (60, 60, 230), (150, 40, 220), (220, 40, 160),
               (40, 200, 160), (200, 200, 200)]
    with _open(vid, pid) as sd:
        sd.set_brightness(85)
        ci = 0
        for pos in range(sd.layout.key_count):
            if sd.set_position_color(pos, palette[ci % len(palette)]):
                ci += 1
    typer.echo("painted rainbow")


def _default_config() -> str:
    for p in ("streamdock.yaml",
              "streamdock.toml",
              os.path.expanduser("~/.config/streamdock/config.yaml"),
              os.path.expanduser("~/.config/streamdock/config.toml")):
        if os.path.exists(p):
            return p
    return "streamdock.yaml"


@app.command()
def run(
    config: Optional[str] = typer.Argument(
        None, help="YAML/TOML config (default: ./streamdock.yaml, ./streamdock.toml, "
                   "or the same names under ~/.config/streamdock/)"),
    menubar: bool = typer.Option(False, "--menubar", help="show a macOS menu bar status icon"),
    vid: int = VidOpt, pid: int = PidOpt,
):
    """Run the persistent control loop from a config file.

    Renders your configured buttons, runs each button's command on press, and
    keeps the device alive so it does not revert to its kiosk image. Edits to
    the config file (e.g. saving from `streamdock ui`) hot-reload live. Ctrl-C
    to stop. See the example streamdock.yaml in the repo for the format.
    """
    from .control import Runner, load_config
    path = config or _default_config()
    try:
        cfg = load_config(path)
    except FileNotFoundError:
        raise _err(f"config not found: {path}")
    except Exception as e:  # noqa: BLE001
        raise _err(f"bad config: {e}")
    runner = Runner(cfg, vid, pid, config_path=path)
    if menubar:
        from .menubar import run_with_menubar
        run_with_menubar(runner)
    else:
        runner.run()


@app.command()
def ui(
    config: Optional[str] = typer.Argument(
        None, help="config file to edit (default: resolved like `run`; created on first save)"),
    port: int = typer.Option(8383, "--port", help="port to listen on (localhost only)"),
    no_open: bool = typer.Option(False, "--no-open", help="don't open the browser"),
):
    """Configure the deck's buttons in a local web UI.

    Assign macOS apps, shell commands, page switches and looks to keys across
    multiple pages, then Save — the file is written as YAML, and a running
    `streamdock run` on the same file picks the change up live. A legacy TOML
    config is loaded for editing but saved next to it as .yaml (the new
    canonical format).
    """
    from .webui import serve
    path = config or _default_config()
    try:
        serve(path, port=port, open_browser=not no_open)
    except OSError as e:
        raise _err(f"could not start server on 127.0.0.1:{port}: {e}")


@app.command()
def watch(vid: int = VidOpt, pid: int = PidOpt):
    """Stream button events until Ctrl-C."""
    with _open(vid, pid) as sd:
        typer.echo("watching for key events (Ctrl-C to stop)...")
        try:
            while True:
                ev = sd.read_position(timeout_ms=500)
                if ev is None:
                    continue
                pos, down = ev
                tag = "LCD" if sd.has_screen(pos) else "button"
                typer.echo(f"position {pos:>2} ({tag})  {'DOWN' if down else 'up'}")
        except KeyboardInterrupt:
            typer.echo("\nstopped")


@app.command()
def icons():
    """List the built-in icon names (use as `icon = ...` in a config)."""
    from .render import icon_names
    typer.echo("  ".join(icon_names()))


@app.command()
def icon(
    position: int = typer.Argument(..., help="reading-order key, 0 = top-left"),
    name: str = typer.Argument(..., help="icon name (see `streamdock icons`)"),
    label: Optional[str] = typer.Option(None, "--label", "-l", help="caption under the icon"),
    color: Optional[str] = typer.Option(None, "--color", "-c", help="'#rrggbb' or 'r,g,b'"),
    level: Optional[float] = typer.Option(None, "--level", help="0..1 fill for meter icons"),
    vid: int = VidOpt, pid: int = PidOpt,
):
    """Draw a built-in icon (optionally with a caption) on one key."""
    from .render import ICONS, render_key
    if name not in ICONS:
        raise _err(f"unknown icon {name!r}; see `streamdock icons`")
    rgb = None
    if color:
        try:
            rgb = _parse_color(color)
        except ValueError as e:
            raise typer.BadParameter(str(e))
    img = render_key(label=label, icon=name, color=rgb, level=level)
    with _open(vid, pid) as sd:
        if not sd.set_position_image(position, img):
            raise _err(f"position {position} has no screen (or is out of range)")
    typer.echo(f"position {position} <- icon {name}")


# ---- LaunchAgent (macOS: run the control loop at login) --------------------
AGENT_LABEL = "com.streamdock.run"

_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key>
  <array>
{args}
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>{log}</string>
  <key>StandardErrorPath</key><string>{log}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
"""


def _plist_path() -> str:
    return os.path.expanduser(f"~/Library/LaunchAgents/{AGENT_LABEL}.plist")


def _streamdock_exe() -> str:
    # the console script installed next to the running interpreter
    return os.path.join(os.path.dirname(os.path.abspath(sys.executable)), "streamdock")


@app.command("install-agent")
def install_agent(
    config: Optional[str] = typer.Option(
        None, "--config", "-c", help="config to run (default: resolved like `run`)"),
    menubar: bool = typer.Option(True, "--menubar/--no-menubar",
                                 help="show a menu bar status icon while running"),
):
    """Install & start a macOS LaunchAgent that runs the control loop at login
    (and restarts it if it ever exits). Idempotent — safe to re-run."""
    if sys.platform != "darwin":
        raise _err("install-agent is macOS-only (uses launchd)")
    # a login agent has no cwd context, so default to the absolute user config,
    # not the cwd-relative example that `run` falls back to.
    default_cfg = os.path.expanduser("~/.config/streamdock/config.yaml")
    if config is None and not os.path.exists(default_cfg):
        default_cfg = os.path.expanduser("~/.config/streamdock/config.toml")
    cfg = os.path.abspath(os.path.expanduser(config or default_cfg))
    if not os.path.exists(cfg):
        raise _err(f"config not found: {cfg} (create it or pass --config)")
    exe = _streamdock_exe()
    if not os.path.exists(exe):
        raise _err(f"streamdock executable not found at {exe}")
    log = os.path.expanduser("~/.config/streamdock/agent.log")
    os.makedirs(os.path.dirname(log), exist_ok=True)
    path = _plist_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    argv = [exe, "run", cfg] + (["--menubar"] if menubar else [])
    args = "\n".join(f"    <string>{escape(a)}</string>" for a in argv)
    with open(path, "w") as f:
        f.write(_PLIST.format(label=AGENT_LABEL, args=args, log=escape(log)))
    subprocess.run(["launchctl", "unload", path], capture_output=True)   # if already loaded
    r = subprocess.run(["launchctl", "load", "-w", path], capture_output=True, text=True)
    if r.returncode != 0:
        raise _err(f"launchctl load failed: {r.stderr.strip() or r.stdout.strip()}")
    typer.secho(f"installed + started LaunchAgent {AGENT_LABEL}", fg=typer.colors.GREEN)
    typer.echo(f"  plist : {path}")
    typer.echo(f"  runs  : {' '.join(argv)}")
    typer.echo(f"  log   : {log}")


@app.command("uninstall-agent")
def uninstall_agent():
    """Stop and remove the control-loop LaunchAgent."""
    path = _plist_path()
    if not os.path.exists(path):
        typer.echo("no LaunchAgent installed")
        return
    subprocess.run(["launchctl", "unload", "-w", path], capture_output=True)
    os.remove(path)
    typer.echo(f"removed LaunchAgent {AGENT_LABEL}")


@app.command("agent-status")
def agent_status():
    """Show whether the control-loop LaunchAgent is loaded (PID / last exit)."""
    r = subprocess.run(["launchctl", "list"], capture_output=True, text=True)
    line = next((ln for ln in r.stdout.splitlines() if AGENT_LABEL in ln), None)
    if line:
        pid = line.split("\t")[0]
        typer.echo(f"loaded ({'running, pid ' + pid if pid.isdigit() else 'not running'})")
        typer.echo(f"  {line}")
        typer.echo(f"  log: {os.path.expanduser('~/.config/streamdock/agent.log')}")
    else:
        typer.echo("not loaded  (install with: streamdock install-agent)")


def main() -> None:  # convenience entry
    app()


if __name__ == "__main__":
    sys.exit(app())  # type: ignore[func-returns-value]
