"""Command-line interface: ``streamdock <command>``.

Everything here is a thin wrapper over the same public API you can import:
``from streamdock import StreamDock``.
"""
from __future__ import annotations

import os
import sys
from typing import Optional

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
    for p in ("streamdock.toml",
              os.path.expanduser("~/.config/streamdock/config.toml")):
        if os.path.exists(p):
            return p
    return "streamdock.toml"


@app.command()
def run(
    config: Optional[str] = typer.Argument(
        None, help="TOML config (default: ./streamdock.toml or ~/.config/streamdock/config.toml)"),
    vid: int = VidOpt, pid: int = PidOpt,
):
    """Run the persistent control loop from a config file.

    Renders your configured buttons, runs each button's command on press, and
    keeps the device alive so it does not revert to its kiosk image. Ctrl-C to
    stop. See the example streamdock.toml in the repo for the format.
    """
    from .control import Runner, load_config
    path = config or _default_config()
    try:
        cfg = load_config(path)
    except FileNotFoundError:
        raise _err(f"config not found: {path}")
    except Exception as e:  # noqa: BLE001
        raise _err(f"bad config: {e}")
    Runner(cfg, vid, pid).run()


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


def main() -> None:  # convenience entry
    app()


if __name__ == "__main__":
    sys.exit(app())  # type: ignore[func-returns-value]
