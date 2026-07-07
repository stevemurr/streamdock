#!/usr/bin/env python3
"""Paint a rainbow, then react to presses. Run:

    uv run python examples/rainbow.py
"""
from streamdock import StreamDock

RAINBOW = [(230, 20, 20), (230, 120, 0), (220, 200, 0), (60, 200, 40),
           (30, 160, 220), (60, 60, 230), (150, 40, 220), (220, 40, 160),
           (40, 200, 160), (200, 200, 200)]


def main() -> None:
    with StreamDock() as sd:
        sd.initialize()
        print("firmware:", sd.firmware_version())
        sd.set_brightness(80)

        colors = {}
        ci = 0
        for pos in range(sd.layout.key_count):
            if not sd.has_screen(pos):
                continue
            colors[pos] = RAINBOW[ci % len(RAINBOW)]
            ci += 1
            sd.set_position_color(pos, colors[pos])

        print("Press keys (Ctrl-C to quit).")
        while True:
            ev = sd.read_position(timeout_ms=500)
            if ev is None:
                continue
            pos, down = ev
            tag = "LCD" if sd.has_screen(pos) else "button"
            print(f"  position {pos:>2} ({tag})  {'DOWN' if down else 'up'}")
            if pos in colors:
                sd.set_position_color(pos, (255, 255, 255) if down else colors[pos])


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        try:
            with StreamDock() as sd:
                sd.initialize()
                sd.clear_all()
        except Exception:
            pass
        print("\nbye")
