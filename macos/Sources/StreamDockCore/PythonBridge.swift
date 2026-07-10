import Foundation

/// Installs the `streamdock` Python module that lets a key's Python action
/// press other keys through the app's control socket. The module is embedded
/// here as a string so the app can (re)write it into Application Support on
/// every launch; it depends only on the Python standard library.
public enum PythonBridge {
    public static let moduleFileName = "streamdock.py"

    /// Writes (and overwrites) `streamdock.py` into `directory`, creating the
    /// directory if needed. Point `PYTHONPATH` at the directory afterwards.
    public static func install(into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(moduleFileName)
        try moduleSource.write(to: url, atomically: true, encoding: .utf8)
    }

    public static let moduleSource = #"""
# StreamDock control module, installed by the StreamDock macOS app.
# Lets a key's Python action press other keys and switch pages:
#
#     import streamdock
#     streamdock.key(4).press()
#     streamdock.press("Amber", page="main")
#     streamdock.switch_page("next")
#
# Speaks JSON-lines over the app's Unix control socket (STREAMDOCK_SOCKET).
# Standard library only.

import json
import os
import socket


def _request(payload):
    path = os.environ.get("STREAMDOCK_SOCKET")
    if not path:
        raise RuntimeError(
            "STREAMDOCK_SOCKET is not set; run this from a StreamDock key action "
            "(or point it at the app's control.sock)"
        )
    try:
        depth = int(os.environ.get("STREAMDOCK_PRESS_DEPTH", "0"))
    except ValueError:
        depth = 0
    message = dict(payload)
    message["depth"] = depth
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            client.settimeout(10.0)
            client.connect(path)
            client.sendall((json.dumps(message) + "\n").encode("utf-8"))
            data = b""
            while b"\n" not in data:
                chunk = client.recv(65536)
                if not chunk:
                    break
                data += chunk
        finally:
            client.close()
    except OSError as exc:
        raise RuntimeError("could not reach StreamDock at %s: %s" % (path, exc))
    if not data:
        raise RuntimeError("no response from StreamDock")
    response = json.loads(data.split(b"\n", 1)[0].decode("utf-8"))
    if not response.get("ok"):
        raise RuntimeError(response.get("error") or "StreamDock request failed")
    return response


def press(key, page=None):
    # Press another key by position (int) or case-insensitive label (str).
    message = {"command": "press", "key": str(key)}
    if page is not None:
        message["page"] = page
    return _request(message).get("detail")


def switch_page(target):
    # Switch the active page; target is a page name, "next", or "prev".
    return _request({"command": "switch-page", "page": str(target)}).get("detail")


def list_keys():
    # Every configured key: [{"position": ..., "label": ..., "page": ...}, ...]
    return _request({"command": "list"}).get("keys") or []


def status():
    # The app's device status line.
    return _request({"command": "status"}).get("detail")


class Key:
    def __init__(self, ref, page=None):
        self.ref = ref
        self.page = page

    def press(self):
        return press(self.ref, self.page)

    def __repr__(self):
        return "Key(%r, page=%r)" % (self.ref, self.page)


def key(ref, page=None):
    # Handle to a key, so streamdock.key(4).press() reads naturally.
    return Key(ref, page)
"""#
}
