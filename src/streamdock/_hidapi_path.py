"""Locate and preload the native hidapi shared library.

The PyPI ``hidapi`` wheel/extension links against ``libhidapi`` but does not
always embed an rpath to it, so on macOS you normally have to export
``DYLD_LIBRARY_PATH=/opt/homebrew/lib`` before importing ``hid``. Preloading the
dylib with ``RTLD_GLOBAL`` before that import removes the need for any env var,
so ``uv run streamdock`` just works.

Best-effort and silent: on systems where ``import hid`` already resolves its
library normally (most Linux), this is a no-op.
"""
from __future__ import annotations

import ctypes
import glob
import os
import subprocess

_LIB_NAMES = (
    "libhidapi.dylib",
    "libhidapi.0.dylib",
    "libhidapi-hidraw.so.0",
    "libhidapi-libusb.so.0",
    "libhidapi-hidraw.so",
    "libhidapi-libusb.so",
)


def _candidate_dirs() -> list[str]:
    dirs: list[str] = []
    env = os.environ.get("STREAMDOCK_HIDAPI_DIR")
    if env:
        dirs.append(env)
    try:
        prefix = subprocess.check_output(
            ["brew", "--prefix"], text=True, stderr=subprocess.DEVNULL
        ).strip()
        if prefix:
            dirs.append(os.path.join(prefix, "lib"))
    except Exception:
        pass
    dirs += ["/opt/homebrew/lib", "/usr/local/lib", "/usr/lib", "/lib"]
    # de-dup, keep order
    seen: set[str] = set()
    return [d for d in dirs if d and not (d in seen or seen.add(d))]


def preload_hidapi() -> str | None:
    """Preload libhidapi so a later ``import hid`` resolves it. Returns the
    loaded path, or None if nothing was found (in which case we let ``import
    hid`` try on its own)."""
    for d in _candidate_dirs():
        for name in _LIB_NAMES:
            for path in glob.glob(os.path.join(d, name)):
                try:
                    ctypes.CDLL(path, mode=ctypes.RTLD_GLOBAL)
                    return path
                except OSError:
                    continue
    return None
