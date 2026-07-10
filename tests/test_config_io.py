"""Config load/save: the YAML paged schema round-trips, legacy TOML still
loads (as a single page), and unset fields stay out of the written file."""
from streamdock.control import (
    Config,
    KeyConfig,
    Page,
    effective_command,
    key_from_dict,
    key_to_dict,
    load_config,
    save_config,
)


def sample_config() -> Config:
    return Config(
        brightness=65,
        keepalive_seconds=1.5,
        clear_on_exit=False,
        env_file="secrets.env",
        pages=[
            Page(name="main", keys=[
                KeyConfig(position=0, label="Terminal", icon="gear",
                          color=(30, 110, 160), app="Terminal"),
                KeyConfig(position=1, label="Build", command="make -C ~/proj build"),
                KeyConfig(position=14, icon="cycle", action="page:next"),
            ]),
            Page(name="media", keys=[
                KeyConfig(position=2, label="75%", icon="brightness", level=0.75),
                KeyConfig(position=14, icon="cycle", action="page:main"),
            ]),
        ],
    )


# ---- YAML round-trip ---------------------------------------------------------
def test_yaml_round_trip(tmp_path):
    cfg = sample_config()
    p = tmp_path / "deck.yaml"
    save_config(cfg, p)
    loaded = load_config(p)
    assert loaded.pages == cfg.pages
    assert (loaded.brightness, loaded.keepalive_seconds, loaded.clear_on_exit,
            loaded.env_file) == (65, 1.5, False, "secrets.env")
    assert loaded.base_dir == tmp_path.resolve()


def test_saved_yaml_omits_unset_fields_and_nulls(tmp_path):
    p = tmp_path / "deck.yaml"
    save_config(sample_config(), p)
    text = p.read_text()
    assert "null" not in text
    assert "image" not in text          # never set on any key
    assert "'#1e6ea0'" in text          # color saved as quoted hex
    assert text.index("settings") < text.index("pages")   # stable order


def test_yml_extension_also_loads_as_yaml(tmp_path):
    p = tmp_path / "deck.yml"
    save_config(sample_config(), p)
    assert load_config(p).pages[1].name == "media"


def test_empty_yaml_gives_one_empty_main_page(tmp_path):
    p = tmp_path / "deck.yaml"
    p.write_text("")
    cfg = load_config(p)
    assert [pg.name for pg in cfg.pages] == ["main"]
    assert cfg.pages[0].keys == []
    assert cfg.brightness == 80


def test_save_replaces_atomically_leaving_no_temp_files(tmp_path):
    p = tmp_path / "deck.yaml"
    save_config(sample_config(), p)
    save_config(sample_config(), p)     # overwrite the existing file
    assert [f.name for f in tmp_path.iterdir()] == ["deck.yaml"]


# ---- legacy TOML -------------------------------------------------------------
TOML = """
[settings]
brightness = 70

[[keys]]
position = 0
label = "Term"
icon = "monitor"
color = "#1e6ea0"
command = "open -a Terminal"

[[keys]]
position = 6
label = "Sleep"
action = "sleep"
"""


def test_toml_loads_as_single_page_named_main(tmp_path):
    p = tmp_path / "deck.toml"
    p.write_text(TOML)
    cfg = load_config(p)
    assert [pg.name for pg in cfg.pages] == ["main"]
    keys = cfg.pages[0].keys
    assert keys[0] == KeyConfig(position=0, label="Term", icon="monitor",
                                color=(30, 110, 160), command="open -a Terminal")
    assert keys[1].action == "sleep"
    assert cfg.brightness == 70


def test_toml_key_missing_position_still_rejected(tmp_path):
    p = tmp_path / "deck.toml"
    p.write_text('[[keys]]\nlabel = "x"\n')
    try:
        load_config(p)
        raise AssertionError("expected ValueError")
    except ValueError as e:
        assert "position" in str(e)


# ---- key dict (de)serialization ------------------------------------------------
def test_key_from_dict_accepts_color_list_and_hex():
    assert key_from_dict({"position": 1, "color": [1, 2, 3]}).color == (1, 2, 3)
    assert key_from_dict({"position": 1, "color": "#0a0b0c"}).color == (10, 11, 12)


def test_key_to_dict_is_minimal_and_ordered():
    d = key_to_dict(KeyConfig(position=3, label="X", color=(255, 0, 0), app="Safari"))
    assert d == {"position": 3, "label": "X", "color": "#ff0000", "app": "Safari"}
    assert list(d) == ["position", "label", "color", "app"]


# ---- app sugar ------------------------------------------------------------------
def test_app_expands_to_open_command_with_quoting():
    k = KeyConfig(position=0, app="Google Chrome")
    assert effective_command(k) == "open -a 'Google Chrome'"


def test_raw_command_wins_over_app():
    k = KeyConfig(position=0, app="Safari", command="echo hi")
    assert effective_command(k) == "echo hi"


def test_no_command_no_app_is_none():
    assert effective_command(KeyConfig(position=0, label="x")) is None
