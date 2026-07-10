"""Local web UI for editing a streamdock config.

``streamdock ui`` serves a small single-page app (stdlib http.server, no web
framework, no external assets) on 127.0.0.1 where you assign macOS apps, shell
commands, page switches and looks to keys, across multiple pages. Save writes
the YAML config atomically; a concurrently-running ``streamdock run`` on the
same file hot-reloads it live.

API (all JSON unless noted):
  GET  /              the app
  GET  /api/config    current config (from disk) + the path saves go to
  POST /api/config    validate + save the posted config as YAML
  GET  /api/icons     built-in icon names
  GET  /api/apps      installed .app names (/Applications, ~/Applications, ...)
  GET  /api/preview   key-face PNG for ?label=&icon=&color=&level=&image=
"""
from __future__ import annotations

import json
import os
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from PIL import Image

from ._color import parse_color
from .control import (
    Config,
    Page,
    _auto_level,
    config_from_dict,
    config_to_dict,
    key_from_dict,
    load_config,
    save_config,
)
from .device import KEY_PX
from .layout import DEFAULT_LAYOUT
from .render import ICONS, icon_names, render_key

APP_DIRS = [
    "/Applications",
    "/Applications/Utilities",
    "/System/Applications",
    "/System/Applications/Utilities",
    "~/Applications",
]


def list_apps(dirs: "list[str] | None" = None) -> "list[str]":
    """Names of installed .app bundles (the value the `app:` field wants)."""
    names = set()
    for d in dirs if dirs is not None else APP_DIRS:
        try:
            entries = os.listdir(os.path.expanduser(d))
        except OSError:
            continue
        for e in entries:
            if e.endswith(".app"):
                names.add(e[:-len(".app")])
    return sorted(names, key=str.lower)


# ---- validation (pure; unit-tested) -----------------------------------------

def _validate_key(k, page: str, key_count: int, page_names: "list[str]", seen: set) -> "list[str]":
    errs: "list[str]" = []
    if not isinstance(k, dict):
        return [f"page '{page}': key entries must be objects"]
    pos = k.get("position")
    if isinstance(pos, bool) or not isinstance(pos, int) or not (0 <= pos < key_count):
        return [f"page '{page}': key position must be an integer 0-{key_count - 1}, "
                f"got {pos!r}"]
    where = f"page '{page}' key {pos}"
    if pos in seen:
        errs.append(f"page '{page}': duplicate key at position {pos}")
    seen.add(pos)
    icon = k.get("icon")
    if icon and icon not in ICONS:
        errs.append(f"{where}: unknown icon {icon!r}")
    color = k.get("color")
    if color:
        if isinstance(color, (list, tuple)):
            if len(color) != 3 or not all(isinstance(c, int) and 0 <= c <= 255 for c in color):
                errs.append(f"{where}: bad color {color!r}")
        else:
            try:
                parse_color(str(color))
            except ValueError as e:
                errs.append(f"{where}: bad color {color!r} ({e})")
    level = k.get("level")
    if level is not None:
        try:
            if not 0 <= float(level) <= 100:
                raise ValueError
        except (TypeError, ValueError):
            errs.append(f"{where}: level must be a number 0-1 (or a 0-100 percent)")
    action = k.get("action")
    if action:
        if not isinstance(action, str):
            errs.append(f"{where}: action must be a string")
        elif action.startswith("page:"):
            target = action[len("page:"):].strip()
            if target not in ("next", "prev") and target not in page_names:
                errs.append(f"{where}: page action targets unknown page {target!r}")
        elif action != "sleep":
            errs.append(f"{where}: unknown action {action!r} (use 'sleep' or 'page:...')")
    for name in ("label", "app", "command", "image"):
        v = k.get(name)
        if v is not None and not isinstance(v, str):
            errs.append(f"{where}: {name} must be a string")
    return errs


def validate_config_data(data, key_count: "int | None" = None) -> "list[str]":
    """Validate the config dict the UI posts (same shape as the YAML file).
    Returns a list of human-readable problems; empty means valid."""
    if key_count is None:
        key_count = DEFAULT_LAYOUT.key_count
    if not isinstance(data, dict):
        return ["config must be an object"]
    errors: "list[str]" = []
    settings = data.get("settings") or {}
    if not isinstance(settings, dict):
        errors.append("settings must be an object")
        settings = {}
    b = settings.get("brightness")
    if b is not None:
        try:
            if isinstance(b, bool) or not (0 <= int(b) <= 100):
                raise ValueError
        except (TypeError, ValueError):
            errors.append("settings.brightness must be an integer 0-100")
    ka = settings.get("keepalive_seconds")
    if ka is not None:
        try:
            if float(ka) <= 0:
                raise ValueError
        except (TypeError, ValueError):
            errors.append("settings.keepalive_seconds must be a positive number")
    pages = data.get("pages")
    if not isinstance(pages, list) or not pages:
        errors.append("config needs at least one page")
        return errors
    names: "list[str]" = []
    for i, p in enumerate(pages):
        if not isinstance(p, dict):
            errors.append(f"pages[{i}] must be an object")
            names.append("")
            continue
        name = str(p.get("name") or "").strip()
        if not name:
            errors.append(f"pages[{i}] needs a non-empty name")
        names.append(name)
    dupes = sorted({n for n in names if n and names.count(n) > 1})
    if dupes:
        errors.append("duplicate page names: " + ", ".join(dupes))
    for i, p in enumerate(pages):
        if not isinstance(p, dict):
            continue
        keys = p.get("keys") or []
        if not isinstance(keys, list):
            errors.append(f"page '{names[i]}': keys must be a list")
            continue
        seen: set = set()
        for k in keys:
            errors.extend(_validate_key(k, names[i] or f"#{i}", key_count, names, seen))
    return errors


# ---- preview rendering -------------------------------------------------------

def preview_png(params: "dict[str, str]", base_dir: "str | Path") -> bytes:
    """Render a key-face preview PNG from query params (label/icon/color/level/
    image). Raises ValueError on bad input (mapped to HTTP 400)."""
    image = params.get("image")
    if image:
        p = image if os.path.isabs(image) else str(Path(base_dir) / image)
        try:
            img = Image.open(p).convert("RGB").resize((KEY_PX, KEY_PX))
        except OSError as e:
            raise ValueError(f"cannot load image {image!r}: {e}")
    else:
        icon = params.get("icon") or None
        if icon and icon not in ICONS:
            raise ValueError(f"unknown icon {icon!r}")
        color = parse_color(params["color"]) if params.get("color") else None
        raw = params.get("level")
        try:
            level = float(raw) if raw not in (None, "") else None
        except ValueError:
            raise ValueError(f"bad level {raw!r}")
        key = key_from_dict({"position": 0, "label": params.get("label") or None,
                             "icon": icon, "level": level})
        img = render_key(label=key.label, icon=key.icon, color=color,
                         level=_auto_level(key))
    buf = BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


# ---- HTTP server --------------------------------------------------------------

class WebUIServer(ThreadingHTTPServer):
    """127.0.0.1-only server that knows which config file it edits.

    A legacy .toml config is loaded for editing, but saves go to the sibling
    .yaml path (the canonical format going forward); once saved, the .yaml is
    what gets read back.
    """
    daemon_threads = True

    def __init__(self, config_path: "str | Path", port: int = 8383):
        self.config_path = Path(config_path)
        if self.config_path.suffix.lower() in (".yaml", ".yml"):
            self.save_path = self.config_path
        else:
            self.save_path = self.config_path.with_suffix(".yaml")
        self.base_dir = self.save_path.resolve().parent
        super().__init__(("127.0.0.1", port), _Handler)

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server_address[1]}/"

    def _read_path(self) -> "Path | None":
        for p in (self.save_path, self.config_path):
            if p.exists():
                return p
        return None

    def config_payload(self) -> dict:
        p = self._read_path()
        if p is None:
            cfg = Config(base_dir=self.base_dir, pages=[Page(name="main")])
        else:
            cfg = load_config(p)
        d = config_to_dict(cfg)
        d["path"] = str(self.save_path)
        d["loaded_from"] = str(p) if p else None
        d["rows"] = DEFAULT_LAYOUT.rows
        d["cols"] = DEFAULT_LAYOUT.cols
        return d

    def save_payload(self, data: dict) -> "tuple[int, dict]":
        errors = validate_config_data(data)
        if errors:
            return 400, {"error": "; ".join(errors)}
        cfg = config_from_dict(data, base_dir=self.base_dir)
        save_config(cfg, self.save_path)
        return 200, {"ok": True, "path": str(self.save_path)}


class _Handler(BaseHTTPRequestHandler):
    server: WebUIServer   # type: ignore[assignment]

    def log_message(self, format, *args):   # noqa: A002 - stdlib signature
        pass                                # keep the terminal quiet

    def _send(self, code: int, body, ctype: str = "application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):   # noqa: N802 - stdlib name
        u = urlparse(self.path)
        try:
            if u.path == "/":
                self._send(200, _INDEX_HTML.encode("utf-8"), "text/html; charset=utf-8")
            elif u.path == "/api/config":
                self._send(200, self.server.config_payload())
            elif u.path == "/api/icons":
                self._send(200, {"icons": icon_names()})
            elif u.path == "/api/apps":
                self._send(200, {"apps": list_apps()})
            elif u.path == "/api/preview":
                q = {k: v[0] for k, v in parse_qs(u.query).items()}
                self._send(200, preview_png(q, self.server.base_dir), "image/png")
            else:
                self._send(404, {"error": "not found"})
        except ValueError as e:
            self._send(400, {"error": str(e)})
        except Exception as e:      # noqa: BLE001
            self._send(500, {"error": f"{type(e).__name__}: {e}"})

    def do_POST(self):   # noqa: N802 - stdlib name
        u = urlparse(self.path)
        if u.path != "/api/config":
            self._send(404, {"error": "not found"})
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            data = json.loads(self.rfile.read(n).decode("utf-8"))
        except Exception:   # noqa: BLE001
            self._send(400, {"error": "body must be valid JSON"})
            return
        try:
            code, body = self.server.save_payload(data)
        except ValueError as e:
            code, body = 400, {"error": str(e)}
        except Exception as e:      # noqa: BLE001
            code, body = 500, {"error": f"save failed: {e}"}
        self._send(code, body)


def create_server(config_path: "str | Path", port: int = 8383) -> WebUIServer:
    return WebUIServer(config_path, port=port)


def serve(config_path: "str | Path", port: int = 8383, open_browser: bool = True) -> None:
    """Run the config web UI until Ctrl-C."""
    httpd = create_server(config_path, port=port)
    print(f"streamdock ui: editing {httpd.save_path}"
          + (f" (loaded from {httpd.config_path})"
             if httpd.save_path != httpd.config_path else ""), flush=True)
    print(f"open {httpd.url}  (Ctrl-C to stop)", flush=True)
    if open_browser:
        webbrowser.open(httpd.url)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping", flush=True)
    finally:
        httpd.server_close()


# ---- the app (embedded; no build step, no external assets) --------------------

_INDEX_HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>streamdock</title>
<style>
  :root {
    --bg: #16181d; --panel: #1e2128; --panel2: #262a33; --line: #333845;
    --fg: #e8eaf0; --dim: #8a90a0; --accent: #4ea1ff; --danger: #e05555;
    --ok: #58c472;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--fg);
    font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  }
  header {
    display: flex; align-items: center; gap: 12px; padding: 10px 16px;
    background: var(--panel); border-bottom: 1px solid var(--line);
    position: sticky; top: 0; z-index: 2;
  }
  header h1 { font-size: 16px; margin: 0; font-weight: 600; }
  header .path { color: var(--dim); font-size: 12px; overflow: hidden;
                 text-overflow: ellipsis; white-space: nowrap; flex: 1; }
  #status { font-size: 12px; color: var(--dim); }
  #status.err { color: var(--danger); }
  #status.ok { color: var(--ok); }
  button {
    background: var(--panel2); color: var(--fg); border: 1px solid var(--line);
    border-radius: 6px; padding: 6px 12px; cursor: pointer; font: inherit;
  }
  button:hover { border-color: var(--accent); }
  button.primary { background: var(--accent); border-color: var(--accent); color: #0b1826; font-weight: 600; }
  button.danger:hover { border-color: var(--danger); color: var(--danger); }
  main { display: flex; gap: 16px; padding: 16px; align-items: flex-start; flex-wrap: wrap; }
  #left { flex: 0 0 auto; }
  /* page tabs */
  #tabs { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; margin-bottom: 10px; }
  #tabs .tab {
    padding: 5px 14px; border-radius: 6px 6px 0 0; border-bottom: 2px solid transparent;
  }
  #tabs .tab.active { border-bottom-color: var(--accent); color: var(--accent); }
  #tabs .mini { padding: 5px 8px; font-size: 12px; color: var(--dim); }
  /* key grid */
  #grid {
    display: grid; grid-template-columns: repeat(5, 92px); gap: 10px;
    padding: 16px; background: var(--panel); border: 1px solid var(--line);
    border-radius: 14px;
  }
  .key {
    width: 92px; height: 92px; border-radius: 12px; position: relative;
    background: #101216; border: 1px solid var(--line); cursor: pointer; overflow: hidden;
  }
  .key:hover { border-color: var(--dim); }
  .key.sel { border-color: var(--accent); box-shadow: 0 0 0 2px var(--accent); }
  .key img { width: 100%; height: 100%; display: block; }
  .key .pos {
    position: absolute; top: 3px; left: 6px; font-size: 10px; color: var(--dim);
    text-shadow: 0 1px 2px #000;
  }
  .key.empty .pos { color: #4a4f5c; }
  .key .tag {
    position: absolute; bottom: 3px; right: 6px; font-size: 9px; color: var(--dim);
    text-transform: uppercase; letter-spacing: .5px; text-shadow: 0 1px 2px #000;
  }
  #settings { margin-top: 12px; color: var(--dim); font-size: 13px;
              display: flex; gap: 8px; align-items: center; }
  #settings input { width: 64px; }
  /* editor */
  #editor {
    flex: 1 1 320px; min-width: 320px; max-width: 460px;
    background: var(--panel); border: 1px solid var(--line); border-radius: 14px;
    padding: 16px;
  }
  #editor h2 { margin: 0 0 12px; font-size: 14px; font-weight: 600; }
  #editor .hint { color: var(--dim); }
  .row { display: flex; align-items: center; gap: 10px; margin-bottom: 10px; }
  .row label { flex: 0 0 70px; color: var(--dim); font-size: 12px; }
  .row input[type=text], .row select, .row textarea, .row input[type=number] {
    flex: 1; background: var(--panel2); color: var(--fg);
    border: 1px solid var(--line); border-radius: 6px; padding: 6px 8px; font: inherit;
  }
  .row textarea { min-height: 64px; resize: vertical;
                  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
  .row input[type=color] { width: 44px; height: 30px; padding: 0 2px;
                           background: var(--panel2); border: 1px solid var(--line);
                           border-radius: 6px; }
  .row .note { color: var(--dim); font-size: 12px; }
  #ed-actions { display: flex; gap: 8px; margin-top: 14px; }
  .hidden { display: none !important; }
  hr { border: none; border-top: 1px solid var(--line); margin: 14px 0; }
</style>
</head>
<body>
<header>
  <h1>streamdock</h1>
  <span class="path" id="cfgpath"></span>
  <span id="status"></span>
  <button id="btn-reload" title="Discard edits and re-read the config file">Reload from disk</button>
  <button id="btn-save" class="primary">Save</button>
</header>
<main>
  <div id="left">
    <div id="tabs"></div>
    <div id="grid"></div>
    <div id="settings">
      <span>brightness</span>
      <input type="number" id="set-brightness" min="0" max="100">
      <span>%</span>
    </div>
  </div>
  <aside id="editor">
    <h2 id="ed-title">Select a key</h2>
    <div id="ed-body" class="hidden">
      <div class="row"><label for="ed-label">Label</label>
        <input type="text" id="ed-label" placeholder="caption text"></div>
      <div class="row"><label for="ed-icon">Icon</label>
        <select id="ed-icon"></select></div>
      <div class="row"><label for="ed-color">Color</label>
        <input type="checkbox" id="ed-usecolor" title="use a custom color">
        <input type="color" id="ed-color" value="#2e3139">
        <span class="note">gradient + contrast derived from it</span></div>
      <div class="row"><label for="ed-level">Level</label>
        <input type="number" id="ed-level" min="0" max="1" step="0.05" placeholder="auto">
        <span class="note">0..1 fill for meter icons</span></div>
      <div class="row"><label for="ed-image">Image</label>
        <input type="text" id="ed-image" placeholder="path to image (overrides icon/label)"></div>
      <hr>
      <div class="row"><label for="ed-action-type">On press</label>
        <select id="ed-action-type">
          <option value="none">nothing</option>
          <option value="app">open a macOS app</option>
          <option value="command">run a shell command</option>
          <option value="page">switch page</option>
          <option value="sleep">sleep the deck</option>
        </select></div>
      <div class="row" id="row-app"><label for="ed-app">App</label>
        <input type="text" id="ed-app" list="apps-list" placeholder="e.g. Terminal">
        <datalist id="apps-list"></datalist></div>
      <div class="row" id="row-command"><label for="ed-command">Command</label>
        <textarea id="ed-command" spellcheck="false"></textarea></div>
      <div class="row" id="row-page"><label for="ed-page-target">Go to</label>
        <select id="ed-page-target"></select></div>
      <div class="row hidden" id="row-sleep-note">
        <label></label><span class="note">panel off; any key press wakes it.
        The command above (optional) runs first.</span></div>
      <div id="ed-actions">
        <button id="btn-clear" class="danger">Clear key</button>
      </div>
    </div>
    <p class="hint" id="ed-hint">Click a key on the grid to configure it.</p>
  </aside>
</main>
<script>
"use strict";
let state = null;                // {settings, pages}
let icons = [], apps = [];
let active = 0;                  // active page index
let sel = null;                  // selected key position
let dirty = false;
let previewTimer = null;

const $ = id => document.getElementById(id);
const pageKeys = () => state.pages[active].keys || (state.pages[active].keys = []);
const getKey = pos => pageKeys().find(k => k.position === pos);

function setStatus(msg, cls) {
  const s = $('status');
  s.textContent = msg || '';
  s.className = cls || '';
}
function markDirty() { dirty = true; setStatus('unsaved changes'); }

function hasVisual(k) { return !!(k && (k.label || k.icon || k.color || k.image)); }

function previewURL(k) {
  const q = new URLSearchParams();
  if (k.image) q.set('image', k.image);
  if (k.label) q.set('label', k.label);
  if (k.icon) q.set('icon', k.icon);
  if (k.color) q.set('color', k.color);
  if (k.level !== undefined && k.level !== null && k.level !== '') q.set('level', k.level);
  return '/api/preview?' + q.toString();
}

function actionTag(k) {
  if (!k) return '';
  if (k.action === 'sleep') return 'sleep';
  if (k.action && k.action.indexOf('page:') === 0) return k.action.slice(5);
  if (k.app) return 'app';
  if (k.command) return 'cmd';
  return '';
}

// ---- rendering --------------------------------------------------------------
function renderTabs() {
  const t = $('tabs');
  t.textContent = '';
  state.pages.forEach((p, i) => {
    const b = document.createElement('button');
    b.className = 'tab' + (i === active ? ' active' : '');
    b.textContent = p.name;
    b.onclick = () => { active = i; sel = null; renderAll(); };
    t.appendChild(b);
  });
  const mk = (txt, title, fn) => {
    const b = document.createElement('button');
    b.className = 'mini'; b.textContent = txt; b.title = title; b.onclick = fn;
    t.appendChild(b);
  };
  mk('+', 'add page', addPage);
  mk('rename', 'rename this page', renamePage);
  mk('◀', 'move this page left', () => movePage(-1));
  mk('▶', 'move this page right', () => movePage(1));
  if (state.pages.length > 1) mk('delete', 'delete this page', deletePage);
}

function renderGrid() {
  const g = $('grid');
  g.textContent = '';
  for (let pos = 0; pos < 15; pos++) {
    const k = getKey(pos);
    const cell = document.createElement('div');
    cell.className = 'key' + (hasVisual(k) ? '' : ' empty') + (pos === sel ? ' sel' : '');
    cell.dataset.pos = pos;
    if (hasVisual(k)) {
      const img = document.createElement('img');
      img.src = previewURL(k);
      img.alt = k.label || k.icon || 'key ' + pos;
      cell.appendChild(img);
    }
    const n = document.createElement('span');
    n.className = 'pos'; n.textContent = pos;
    cell.appendChild(n);
    const tag = actionTag(k);
    if (tag) {
      const s = document.createElement('span');
      s.className = 'tag'; s.textContent = tag;
      cell.appendChild(s);
    }
    cell.onclick = () => { sel = pos; renderGrid(); renderEditor(); };
    g.appendChild(cell);
  }
}

function refreshCell(pos) {
  const cell = document.querySelector('.key[data-pos="' + pos + '"]');
  if (!cell) return;
  const k = getKey(pos);
  const old = cell.querySelector('img');
  if (hasVisual(k)) {
    cell.classList.remove('empty');
    const img = old || cell.insertBefore(document.createElement('img'), cell.firstChild);
    img.src = previewURL(k);
  } else {
    cell.classList.add('empty');
    if (old) old.remove();
  }
  let tag = cell.querySelector('.tag');
  const txt = actionTag(k);
  if (txt) {
    if (!tag) { tag = document.createElement('span'); tag.className = 'tag'; cell.appendChild(tag); }
    tag.textContent = txt;
  } else if (tag) tag.remove();
}

function scheduleRefresh(pos) {
  clearTimeout(previewTimer);
  previewTimer = setTimeout(() => refreshCell(pos), 250);
}

function actionTypeOf(k) {
  if (!k) return 'none';
  if (k.action === 'sleep') return 'sleep';
  if (k.action && k.action.indexOf('page:') === 0) return 'page';
  if (k.app) return 'app';
  if (k.command) return 'command';
  return 'none';
}

function renderPageTargets(selected) {
  const s = $('ed-page-target');
  s.textContent = '';
  const opts = [['next', 'next page (wraps)'], ['prev', 'previous page (wraps)']];
  state.pages.forEach(p => opts.push([p.name, 'page: ' + p.name]));
  for (const [v, txt] of opts) {
    const o = document.createElement('option');
    o.value = v; o.textContent = txt;
    s.appendChild(o);
  }
  s.value = opts.some(o => o[0] === selected) ? selected : 'next';
}

function renderEditor() {
  const body = $('ed-body'), hint = $('ed-hint');
  if (sel === null) {
    body.classList.add('hidden'); hint.classList.remove('hidden');
    $('ed-title').textContent = 'Select a key';
    return;
  }
  body.classList.remove('hidden'); hint.classList.add('hidden');
  const k = getKey(sel) || {position: sel};
  $('ed-title').textContent = 'Key ' + sel + ' — page “' + state.pages[active].name + '”';
  $('ed-label').value = k.label || '';
  $('ed-icon').value = k.icon || '';
  $('ed-usecolor').checked = !!k.color;
  if (k.color) $('ed-color').value = k.color;
  $('ed-level').value = (k.level === undefined || k.level === null) ? '' : k.level;
  $('ed-image').value = k.image || '';
  const t = actionTypeOf(k);
  $('ed-action-type').value = t;
  $('ed-app').value = k.app || '';
  $('ed-command').value = k.command || '';
  renderPageTargets(t === 'page' ? k.action.slice(5) : 'next');
  updateActionRows();
}

function updateActionRows() {
  const t = $('ed-action-type').value;
  $('row-app').classList.toggle('hidden', t !== 'app');
  $('row-command').classList.toggle('hidden', t !== 'command' && t !== 'sleep');
  $('row-page').classList.toggle('hidden', t !== 'page');
  $('row-sleep-note').classList.toggle('hidden', t !== 'sleep');
  $('ed-command').placeholder = t === 'sleep'
    ? 'optional command to run before sleeping'
    : 'any shell command, e.g. make -C ~/proj build';
}

function renderAll() { renderTabs(); renderGrid(); renderEditor(); }

// ---- editing ----------------------------------------------------------------
function writeBack() {
  if (sel === null) return;
  let k = getKey(sel);
  if (!k) { k = {position: sel}; pageKeys().push(k); }
  const set = (f, v) => { if (v === '' || v === undefined || v === null) delete k[f]; else k[f] = v; };
  set('label', $('ed-label').value);
  set('icon', $('ed-icon').value);
  set('color', $('ed-usecolor').checked ? $('ed-color').value : '');
  set('level', $('ed-level').value === '' ? '' : parseFloat($('ed-level').value));
  set('image', $('ed-image').value);
  const t = $('ed-action-type').value;
  delete k.app; delete k.command; delete k.action;
  if (t === 'app') set('app', $('ed-app').value);
  else if (t === 'command') set('command', $('ed-command').value);
  else if (t === 'page') k.action = 'page:' + $('ed-page-target').value;
  else if (t === 'sleep') { k.action = 'sleep'; set('command', $('ed-command').value); }
  if (Object.keys(k).every(f => f === 'position')) {
    const keys = pageKeys();
    keys.splice(keys.indexOf(k), 1);
  }
  markDirty();
  scheduleRefresh(sel);
}

function clearKey() {
  if (sel === null) return;
  const keys = pageKeys();
  const i = keys.findIndex(k => k.position === sel);
  if (i >= 0) keys.splice(i, 1);
  markDirty();
  renderGrid(); renderEditor();
}

// ---- page operations ----------------------------------------------------------
function addPage() {
  const name = (prompt('New page name:', 'page' + (state.pages.length + 1)) || '').trim();
  if (!name) return;
  if (state.pages.some(p => p.name === name)) { alert('page name already exists'); return; }
  state.pages.push({name: name, keys: []});
  active = state.pages.length - 1; sel = null;
  markDirty(); renderAll();
}
function renamePage() {
  const p = state.pages[active];
  const name = (prompt('Rename page:', p.name) || '').trim();
  if (!name || name === p.name) return;
  if (state.pages.some(q => q.name === name)) { alert('page name already exists'); return; }
  // keep page:<oldname> references working
  for (const pg of state.pages)
    for (const k of (pg.keys || []))
      if (k.action === 'page:' + p.name) k.action = 'page:' + name;
  p.name = name;
  markDirty(); renderAll();
}
function deletePage() {
  const p = state.pages[active];
  if (state.pages.length <= 1) return;
  if (!confirm('Delete page “' + p.name + '” and its keys?')) return;
  state.pages.splice(active, 1);
  active = Math.max(0, active - 1); sel = null;
  markDirty(); renderAll();
}
function movePage(d) {
  const j = active + d;
  if (j < 0 || j >= state.pages.length) return;
  const [p] = state.pages.splice(active, 1);
  state.pages.splice(j, 0, p);
  active = j;
  markDirty(); renderAll();
}

// ---- load/save -----------------------------------------------------------------
function cleanedState() {
  return {
    settings: state.settings,
    pages: state.pages.map(p => ({
      name: p.name,
      keys: (p.keys || []).filter(k =>
        Object.keys(k).some(f => f !== 'position' && k[f] !== undefined && k[f] !== '')),
    })),
  };
}

async function save() {
  try {
    const res = await fetch('/api/config', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify(cleanedState()),
    });
    const j = await res.json();
    if (!res.ok) { setStatus(j.error || 'save failed', 'err'); return; }
    dirty = false;
    setStatus('saved ' + new Date().toLocaleTimeString(), 'ok');
  } catch (e) {
    setStatus('save failed: ' + e, 'err');
  }
}

async function load() {
  try {
    const [c, i, a] = await Promise.all(
      [fetch('/api/config'), fetch('/api/icons'), fetch('/api/apps')]);
    const cj = await c.json();
    if (!c.ok) { setStatus(cj.error || 'load failed', 'err'); return; }
    icons = (await i.json()).icons;
    apps = (await a.json()).apps;
    state = {settings: cj.settings || {}, pages: cj.pages && cj.pages.length ? cj.pages : [{name: 'main', keys: []}]};
    $('cfgpath').textContent = cj.path;
    document.title = 'streamdock — ' + cj.path.split('/').pop();
    active = Math.min(active, state.pages.length - 1);
    sel = null; dirty = false;
    // icon dropdown
    const s = $('ed-icon');
    s.textContent = '';
    const none = document.createElement('option');
    none.value = ''; none.textContent = '(none)';
    s.appendChild(none);
    for (const name of icons) {
      const o = document.createElement('option');
      o.value = name; o.textContent = name;
      s.appendChild(o);
    }
    // app names datalist
    const dl = $('apps-list');
    dl.textContent = '';
    for (const name of apps) {
      const o = document.createElement('option');
      o.value = name;
      dl.appendChild(o);
    }
    $('set-brightness').value = state.settings.brightness !== undefined ? state.settings.brightness : 80;
    setStatus('');
    renderAll();
  } catch (e) {
    setStatus('load failed: ' + e, 'err');
  }
}

// ---- wire-up --------------------------------------------------------------------
$('btn-save').onclick = save;
$('btn-reload').onclick = () => {
  if (!dirty || confirm('Discard unsaved changes and reload from disk?')) load();
};
$('btn-clear').onclick = clearKey;
for (const id of ['ed-label', 'ed-icon', 'ed-usecolor', 'ed-color', 'ed-level',
                  'ed-image', 'ed-app', 'ed-command', 'ed-page-target']) {
  $(id).addEventListener('input', writeBack);
  $(id).addEventListener('change', writeBack);
}
$('ed-action-type').addEventListener('change', () => { updateActionRows(); writeBack(); });
$('set-brightness').addEventListener('change', () => {
  const v = parseInt($('set-brightness').value, 10);
  if (!isNaN(v)) { state.settings.brightness = Math.max(0, Math.min(100, v)); markDirty(); }
});
window.addEventListener('beforeunload', e => { if (dirty) e.preventDefault(); });
load();
</script>
</body>
</html>
"""
