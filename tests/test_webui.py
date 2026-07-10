"""Web UI: pure validation/preview helpers, and the HTTP API exercised against
a real server on an ephemeral 127.0.0.1 port (no browser, no device)."""
import http.client
import json
import threading

import pytest

from streamdock.control import KeyConfig, load_config
from streamdock.webui import (
    create_server,
    list_apps,
    preview_png,
    validate_config_data,
)

VALID = {
    "settings": {"brightness": 80, "keepalive_seconds": 2.0, "clear_on_exit": True},
    "pages": [
        {"name": "main", "keys": [
            {"position": 0, "label": "Term", "icon": "gear", "app": "Terminal"},
            {"position": 14, "icon": "cycle", "action": "page:next"},
        ]},
        {"name": "media", "keys": [
            {"position": 1, "command": "say hi", "color": "#a03020", "level": 0.5},
            {"position": 2, "action": "page:main"},
            {"position": 3, "action": "sleep"},
        ]},
    ],
}


# ---- validation (pure) ---------------------------------------------------------
def test_valid_config_has_no_errors():
    assert validate_config_data(VALID) == []


@pytest.mark.parametrize("mutate, expect", [
    (lambda d: d.update(pages=[]), "at least one page"),
    (lambda d: d["pages"][0].update(name=""), "non-empty name"),
    (lambda d: d["pages"][1].update(name="main"), "duplicate page names"),
    (lambda d: d["pages"][0]["keys"][0].update(position=15), "position"),
    (lambda d: d["pages"][0]["keys"][0].update(position="0"), "position"),
    (lambda d: d["pages"][0]["keys"][0].update(icon="nope"), "unknown icon"),
    (lambda d: d["pages"][0]["keys"][0].update(color="#zzz"), "color"),
    (lambda d: d["pages"][0]["keys"][0].update(level=7000), "level"),
    (lambda d: d["pages"][0]["keys"][0].update(action="explode"), "unknown action"),
    (lambda d: d["pages"][0]["keys"][1].update(action="page:nope"), "unknown page"),
    (lambda d: d["pages"][0]["keys"].append({"position": 0}), "duplicate key"),
    (lambda d: d.update(settings={"brightness": 200}), "brightness"),
])
def test_bad_configs_are_rejected_with_a_message(mutate, expect):
    data = json.loads(json.dumps(VALID))    # deep copy
    mutate(data)
    errors = validate_config_data(data)
    assert errors and any(expect in e for e in errors), errors


def test_non_dict_config_is_rejected():
    assert validate_config_data([1, 2]) == ["config must be an object"]


# ---- previews & app listing -------------------------------------------------------
def test_preview_png_renders_a_png():
    png = preview_png({"label": "Term", "icon": "gear", "color": "#1e6ea0"}, ".")
    assert png.startswith(b"\x89PNG\r\n")


def test_preview_rejects_bad_input():
    with pytest.raises(ValueError):
        preview_png({"color": "#zzz"}, ".")
    with pytest.raises(ValueError):
        preview_png({"icon": "nope"}, ".")
    with pytest.raises(ValueError):
        preview_png({"image": "does-not-exist.png"}, ".")


def test_list_apps_reads_app_bundle_names(tmp_path):
    (tmp_path / "Safari.app").mkdir()
    (tmp_path / "Google Chrome.app").mkdir()
    (tmp_path / "notes.txt").write_text("")
    assert list_apps([str(tmp_path), str(tmp_path / "missing")]) \
        == ["Google Chrome", "Safari"]


# ---- save-path policy ----------------------------------------------------------------
def test_toml_config_saves_to_sibling_yaml(tmp_path):
    srv = create_server(tmp_path / "deck.toml", port=0)
    try:
        assert srv.save_path == tmp_path / "deck.yaml"
        assert srv.config_path == tmp_path / "deck.toml"
    finally:
        srv.server_close()


def test_yaml_config_saves_in_place(tmp_path):
    srv = create_server(tmp_path / "deck.yaml", port=0)
    try:
        assert srv.save_path == tmp_path / "deck.yaml"
    finally:
        srv.server_close()


# ---- HTTP round-trip -------------------------------------------------------------------
@pytest.fixture()
def server(tmp_path):
    srv = create_server(tmp_path / "deck.yaml", port=0)     # ephemeral port
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield srv
    srv.shutdown()
    srv.server_close()


def request(srv, method, path, body=None):
    conn = http.client.HTTPConnection("127.0.0.1", srv.server_address[1], timeout=5)
    headers = {"Content-Type": "application/json"} if body is not None else {}
    conn.request(method, path, body=json.dumps(body) if body is not None else None,
                 headers=headers)
    r = conn.getresponse()
    data = r.read()
    conn.close()
    return r.status, r.getheader("Content-Type"), data


def test_index_serves_the_app(server):
    status, ctype, body = request(server, "GET", "/")
    assert status == 200 and "text/html" in ctype
    assert b"streamdock" in body and b"/api/config" in body


def test_get_config_before_first_save_is_an_empty_main_page(server):
    status, _, body = request(server, "GET", "/api/config")
    d = json.loads(body)
    assert status == 200
    assert [p["name"] for p in d["pages"]] == ["main"]
    assert d["loaded_from"] is None
    assert d["path"].endswith("deck.yaml")
    assert (d["rows"], d["cols"]) == (3, 5)


def test_post_config_writes_yaml_then_get_reads_it_back(server):
    status, _, body = request(server, "POST", "/api/config", VALID)
    assert status == 200 and json.loads(body)["ok"] is True

    cfg = load_config(server.save_path)                 # file on disk is real YAML
    assert [p.name for p in cfg.pages] == ["main", "media"]
    assert cfg.pages[0].keys[0] == KeyConfig(position=0, label="Term",
                                             icon="gear", app="Terminal")
    assert cfg.pages[1].keys[0].color == (160, 48, 32)

    status, _, body = request(server, "GET", "/api/config")
    d = json.loads(body)
    assert status == 200 and d["loaded_from"] == str(server.save_path)
    assert d["pages"][1]["keys"][2] == {"position": 3, "action": "sleep"}


def test_post_invalid_config_is_a_400_and_writes_nothing(server):
    bad = json.loads(json.dumps(VALID))
    bad["pages"][0]["keys"][0]["position"] = 99
    status, _, body = request(server, "POST", "/api/config", bad)
    assert status == 400
    assert "position" in json.loads(body)["error"]
    assert not server.save_path.exists()


def test_post_non_json_body_is_a_400(server):
    conn = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=5)
    conn.request("POST", "/api/config", body="not json{",
                 headers={"Content-Type": "application/json"})
    r = conn.getresponse()
    assert r.status == 400
    conn.close()


def test_icons_and_apps_endpoints(server):
    status, _, body = request(server, "GET", "/api/icons")
    assert status == 200 and "gear" in json.loads(body)["icons"]
    status, _, body = request(server, "GET", "/api/apps")
    assert status == 200 and isinstance(json.loads(body)["apps"], list)


def test_preview_endpoint_returns_a_png(server):
    status, ctype, body = request(
        server, "GET", "/api/preview?label=Term&icon=gear&color=%231e6ea0")
    assert status == 200 and ctype == "image/png"
    assert body.startswith(b"\x89PNG\r\n")


def test_preview_endpoint_rejects_bad_color(server):
    status, _, body = request(server, "GET", "/api/preview?color=zzz")
    assert status == 400
    assert json.loads(body)["error"]


def test_unknown_paths_404(server):
    assert request(server, "GET", "/nope")[0] == 404
    assert request(server, "POST", "/nope", {})[0] == 404
