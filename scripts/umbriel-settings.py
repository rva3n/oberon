#!/usr/bin/env python3
"""Umbriel settings — чтение и правка конфигурации композитора для Oberon.

Интерфейс заморожен (его дергает QML настроек):

    umbriel-settings.py read
        Печатает ОДНУ строку JSON с ТЕКУЩИМИ эффективными значениями.
        Значения берутся из ~/.config/umbriel/src/*.toml, но если тот же
        ключ есть и в главном config.toml — главный конфиг побеждает
        (main overrides). Для ключей, которых нет в файлах, подставляется
        значение по умолчанию из схемы (`umbriel config schema --json`),
        чтобы QML получал полный снимок эффективных значений.

    umbriel-settings.py set <file> <section> <key> <tomlValue>
        Например:
            set src/appearance.toml layout gap 12
            set src/input.toml input.mouse accel_profile "\\"adaptive\\""
            set src/appearance.toml output:DP-1 scale 1.25

        <section> для вывода — `output:DP-1`. <tomlValue> передаётся уже
        готовым TOML-литералом (строки — в кавычках), скрипт пишет как есть.

Только стандартная библиотека (tomllib есть в Python >= 3.11).
"""
import json
import os
import re
import subprocess
import sys

try:
    import tomllib
except ImportError:  # pragma: no cover - Python < 3.11
    print("нужен Python >= 3.11 (tomllib)", file=sys.stderr)
    raise SystemExit(1)

# --- Пути -------------------------------------------------------------------
CONFIG_DIR = os.path.join(os.path.expanduser("~"), ".config", "umbriel")
MAIN_CONFIG = os.path.join(CONFIG_DIR, "config.toml")
# Файлы, из которых читаются базовые (не-output) настройки.
SRC_FILES = (
    os.path.join(CONFIG_DIR, "src", "appearance.toml"),
    os.path.join(CONFIG_DIR, "src", "general.toml"),
    os.path.join(CONFIG_DIR, "src", "input.toml"),
)

DEVNULL = subprocess.DEVNULL

# Заголовок TOML-таблицы целиком (для определения границ секции).
HEADER_RE = re.compile(r"^\s*\[[^\]]*\]\s*(?:#.*)?$")


# --- Разбор TOML ------------------------------------------------------------
def load_toml(path):
    """Прочитать TOML, вернуть dict ({} если файла нет или он битый)."""
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError):
        return {}


def deep_merge(base, override):
    """Рекурсивно наложить override поверх base (override побеждает).

    Не мутирует исходные словари.
    """
    out = dict(base)
    for k, v in override.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def effective_config():
    """Эффективная конфигурация: src/*.toml, затем главный config.toml."""
    eff = {}
    for path in SRC_FILES:
        eff = deep_merge(eff, load_toml(path))
    return deep_merge(eff, load_toml(MAIN_CONFIG))


# --- Вывод `umbriel outputs` ------------------------------------------------
def parse_outputs():
    """Разобрать `umbriel outputs` -> {name: {...}} для подключённых голов.

    Поля: scale(float), transform(str), adaptive(str), current((w,h,hz)),
    modes[(w,h,hz)].
    """
    try:
        proc = subprocess.run(
            ["umbriel", "outputs"],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return {}
    heads = {}
    cur = None
    in_modes = False
    for raw in proc.stdout.splitlines():
        if not raw.strip():
            continue
        if not raw[0].isspace():  # строка головы: "DP-1 \"...\""
            name = raw.split()[0]
            cur = {"modes": []}
            heads[name] = cur
            in_modes = False
            continue
        if cur is None:
            continue
        line = raw.strip()
        if line.startswith("Modes:"):
            in_modes = True
            continue
        m = re.match(r"^(\d+)x(\d+)\s*@\s*([\d.]+)\s*Hz", line)
        if m:
            if in_modes:
                mode = (int(m.group(1)), int(m.group(2)), float(m.group(3)))
                cur["modes"].append(mode)
                if "(current)" in line:
                    cur["current"] = mode
            continue
        if ":" in line:
            k, v = line.split(":", 1)
            k, v = k.strip(), v.strip()
            if k == "Scale":
                try:
                    cur["scale"] = float(v)
                except ValueError:
                    pass
            elif k == "Transform":
                cur["transform"] = v
            elif k == "Adaptive sync":
                cur["adaptive"] = v
    return heads


def fmt_hz(hz):
    """60.000 -> '60', 59.940 -> '59.94', 75.025 -> '75.025'."""
    return "%g" % hz


def fmt_mode(mode):
    return "%dx%d@%s" % (mode[0], mode[1], fmt_hz(mode[2]))


# --- Чтение -----------------------------------------------------------------
# Ключи: (поле в JSON, путь после корня, тип)
SCALAR_KEYS = (
    # appearance / layout
    ("appearance.border_width", ("appearance", "border_width"), int),
    ("appearance.corner_radius", ("appearance", "corner_radius"), int),
    ("appearance.drag_opacity", ("appearance", "drag_opacity"), float),
    ("appearance.opaque_fullscreen", ("appearance", "opaque_fullscreen"), bool),
    ("appearance.shadow.enabled", ("appearance", "shadow", "enabled"), bool),
    ("appearance.shadow.softness", ("appearance", "shadow", "softness"), int),
    ("appearance.blur.enabled", ("appearance", "blur", "enabled"), bool),
    ("layout.gap", ("layout", "gap"), int),
    ("layout.mode", ("layout", "mode"), str),
    ("layout.new_exits_fullscreen", ("layout", "new_exits_fullscreen"), bool),
    ("layout.dwindle.new_toward_cursor", ("layout", "dwindle", "new_toward_cursor"), bool),
    ("layout.dwindle.preserve_split", ("layout", "dwindle", "preserve_split"), bool),
    ("layout.master.position", ("layout", "master", "position"), str),
    ("layout.master.default_width_fraction", ("layout", "master", "default_width_fraction"), float),
    ("layout.master.new_on_top", ("layout", "master", "new_on_top"), bool),
    ("layout.master.new_becomes_master", ("layout", "master", "new_becomes_master"), bool),
    ("layout.scrolling.default_extent_fraction", ("layout", "scrolling", "default_extent_fraction"), float),
    ("layout.scrolling.center_focused", ("layout", "scrolling", "center_focused"), str),
    ("layout.scrolling.center_underfull_strip", ("layout", "scrolling", "center_underfull_strip"), bool),
    ("layout.struts.top", ("layout", "struts", "top"), int),
    ("layout.struts.right", ("layout", "struts", "right"), int),
    ("layout.struts.bottom", ("layout", "struts", "bottom"), int),
    ("layout.struts.left", ("layout", "struts", "left"), int),
    ("workspaces.back_and_forth", ("workspaces", "back_and_forth"), bool),
    ("workspaces.empty_above", ("workspaces", "empty_above"), bool),
    ("overview.zoom", ("overview", "zoom"), float),
    ("overview.background_blur", ("overview", "background_blur"), bool),
    ("overview.workspace_wallpaper", ("overview", "workspace_wallpaper"), bool),
    ("overview.shortcuts", ("overview", "shortcuts"), bool),
    # animation
    ("animation.enabled", ("animation", "enabled"), bool),
    ("animation.windows_in.enabled", ("animation", "windows_in", "enabled"), bool),
    ("animation.windows_in.duration_ms", ("animation", "windows_in", "duration_ms"), int),
    ("animation.windows_in.style", ("animation", "windows_in", "style"), str),
    ("animation.windows_in.scale", ("animation", "windows_in", "scale"), float),
    ("animation.windows_in.effect", ("animation", "windows_in", "effect"), str),
    ("animation.windows_out.enabled", ("animation", "windows_out", "enabled"), bool),
    ("animation.windows_out.duration_ms", ("animation", "windows_out", "duration_ms"), int),
    ("animation.windows_out.style", ("animation", "windows_out", "style"), str),
    ("animation.windows_out.effect", ("animation", "windows_out", "effect"), str),
    ("animation.windows_move.enabled", ("animation", "windows_move", "enabled"), bool),
    ("animation.windows_move.duration_ms", ("animation", "windows_move", "duration_ms"), int),
    ("animation.windows_move.effect", ("animation", "windows_move", "effect"), str),
    ("animation.workspaces.enabled", ("animation", "workspaces", "enabled"), bool),
    ("animation.workspaces.duration_ms", ("animation", "workspaces", "duration_ms"), int),
    ("animation.workspaces.style", ("animation", "workspaces", "style"), str),
    ("animation.overview.enabled", ("animation", "overview", "enabled"), bool),
    ("animation.overview.duration_ms", ("animation", "overview", "duration_ms"), int),
    ("animation.border.enabled", ("animation", "border", "enabled"), bool),
    ("animation.border.duration_ms", ("animation", "border", "duration_ms"), int),
    ("animation.dim_unfocused.enabled", ("animation", "dim_unfocused", "enabled"), bool),
    ("animation.dim_unfocused.dim", ("animation", "dim_unfocused", "dim"), float),
    ("animation.scratchpad.enabled", ("animation", "scratchpad", "enabled"), bool),
    ("animation.scratchpad.dim", ("animation", "scratchpad", "dim"), float),
    ("animation.scratchpad.blur", ("animation", "scratchpad", "blur"), bool),
    ("animation.scratchpad.scale", ("animation", "scratchpad", "scale"), float),
    ("animation.layers.enabled", ("animation", "layers", "enabled"), bool),
    ("animation.windows_drag.physics", ("animation", "windows_drag", "physics"), bool),
    # effects
    ("effects.border", ("effects", "border"), str),
    ("effects.window", ("effects", "window"), str),
    ("effects.screen", ("effects", "screen"), str),
    ("effects.cursor", ("effects", "cursor"), str),
    ("effects.max_fps", ("effects", "max_fps"), int),
    # input
    ("input.client_window_drag", ("input", "client_window_drag"), bool),
    ("input.window_drag_toggle", ("input", "window_drag_toggle"), str),
    ("input.mouse.sensitivity", ("input", "mouse", "sensitivity"), float),
    ("input.mouse.natural_scroll", ("input", "mouse", "natural_scroll"), bool),
    ("input.mouse.accel_profile", ("input", "mouse", "accel_profile"), str),
    ("input.mouse.left_handed", ("input", "mouse", "left_handed"), bool),
    ("input.mouse.scroll_wheel_step", ("input", "mouse", "scroll_wheel_step"), int),
    ("input.touchpad.tap", ("input", "touchpad", "tap"), bool),
    ("input.touchpad.tap_button_map", ("input", "touchpad", "tap_button_map"), str),
    ("input.touchpad.click_method", ("input", "touchpad", "click_method"), str),
    ("input.touchpad.left_handed", ("input", "touchpad", "left_handed"), bool),
    ("input.touchpad.natural_scroll", ("input", "touchpad", "natural_scroll"), bool),
    ("input.touchpad.disable_while_typing", ("input", "touchpad", "disable_while_typing"), bool),
    ("input.touchpad.disable_on_external_mouse", ("input", "touchpad", "disable_on_external_mouse"), bool),
    ("input.keyboard.layout", ("input", "keyboard", "layout"), str),
    ("input.keyboard.repeat_delay", ("input", "keyboard", "repeat_delay"), int),
    ("input.keyboard.repeat_rate", ("input", "keyboard", "repeat_rate"), int),
    ("input.keyboard.options", ("input", "keyboard", "options"), str),
    ("input.focus.follows_mouse", ("input", "focus", "follows_mouse"), bool),
    ("input.focus.follows_mouse_max_scroll", ("input", "focus", "follows_mouse_max_scroll"), float),
    ("input.middle_click_paste", ("input", "middle_click_paste"), bool),
    ("input.cursor.hide_when_typing", ("input", "cursor", "hide_when_typing"), bool),
    # hot corners
    ("hot_corners.top_left.enabled", ("hot_corners", "top_left", "enabled"), bool),
    ("hot_corners.top_left.delay_ms", ("hot_corners", "top_left", "delay_ms"), int),
    ("hot_corners.top_left.action", ("hot_corners", "top_left", "action"), str),
    ("hot_corners.top_right.enabled", ("hot_corners", "top_right", "enabled"), bool),
    ("hot_corners.top_right.delay_ms", ("hot_corners", "top_right", "delay_ms"), int),
    ("hot_corners.top_right.action", ("hot_corners", "top_right", "action"), str),
    ("hot_corners.bottom_left.enabled", ("hot_corners", "bottom_left", "enabled"), bool),
    ("hot_corners.bottom_left.delay_ms", ("hot_corners", "bottom_left", "delay_ms"), int),
    ("hot_corners.bottom_left.action", ("hot_corners", "bottom_left", "action"), str),
    ("hot_corners.bottom_right.enabled", ("hot_corners", "bottom_right", "enabled"), bool),
    ("hot_corners.bottom_right.delay_ms", ("hot_corners", "bottom_right", "delay_ms"), int),
    ("hot_corners.bottom_right.action", ("hot_corners", "bottom_right", "action"), str),
)

# Ключи вывода: (суффикс в JSON, хвост пути после имени вывода, тип).
OUTPUT_KEYS = (
    ("cyclic_workspaces", ("cyclic_workspaces",), bool),
    ("workspace_axis", ("workspace_axis",), str),
    ("min_workspaces", ("min_workspaces",), int),
    ("hdr", ("hdr",), str),
    ("bit_depth", ("bit_depth",), int),
    ("sdr_white", ("sdr_white",), int),
    ("direct_scanout", ("direct_scanout",), bool),
    ("tearing", ("tearing",), bool),
    ("screen_effect", ("screen_effect",), str),
    ("focus_at_startup", ("focus_at_startup",), bool),
)


def _lookup(data, path):
    cur = data
    for part in path:
        if not isinstance(cur, dict) or part not in cur:
            return _MISSING
        cur = cur[part]
    return cur


_MISSING = object()

# Кэш значений по умолчанию из схемы Umbriel (path -> default).
_SCHEMA_DEFAULTS = None


def schema_defaults():
    """Значения по умолчанию из `umbriel config schema --json`.

    Нужны, чтобы `read` отдавал эффективные значения и для ключей, которых
    нет в файлах конфигурации. Если схему получить не удалось — пусто.
    """
    global _SCHEMA_DEFAULTS
    if _SCHEMA_DEFAULTS is not None:
        return _SCHEMA_DEFAULTS
    defaults = {}
    try:
        proc = subprocess.run(
            ["umbriel", "config", "schema", "--json"],
            capture_output=True, text=True, timeout=10,
        )
        data = json.loads(proc.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        _SCHEMA_DEFAULTS = defaults
        return defaults
    for opt in data.get("options", []):
        path = opt.get("path")
        if isinstance(path, str) and "default" in opt:
            defaults[path] = opt["default"]
    _SCHEMA_DEFAULTS = defaults
    return defaults


def _default_for(defaults, path):
    """Значение по умолчанию для пути (с учётом `output.<name>.*`)."""
    key = ".".join(path)
    if key in defaults:
        return defaults[key]
    if len(path) >= 3 and path[0] == "output":
        key = "output.<name>." + ".".join(path[2:])
        if key in defaults:
            return defaults[key]
    return _MISSING


def cmd_read():
    eff = effective_config()
    defaults = schema_defaults()
    result = {}
    for name, path, cast in SCALAR_KEYS:
        val = _lookup(eff, path)
        if val is _MISSING:
            val = _default_for(defaults, path)
        if val is _MISSING:
            continue
        try:
            result[name] = cast(val)
        except (TypeError, ValueError):
            continue

    # Выходы: значения из конфига, но список режимов и «сырые» поля — из
    # состояния композитора (`umbriel outputs`). Помимо подключённых голов
    # учитываем выходы, объявленные в конфиге (для их скалярных настроек).
    out_cfg = eff.get("output", {})
    if not isinstance(out_cfg, dict):
        out_cfg = {}
    live = parse_outputs()
    names = list(live.keys())
    for n in out_cfg:
        if n not in names:
            names.append(n)
    for name in names:
        info = live.get(name, {})
        cfg = out_cfg.get(name, {})
        if not isinstance(cfg, dict):
            cfg = {}

        if "scale" in cfg:
            result["output.%s.scale" % name] = float(cfg["scale"])
        elif "scale" in info:
            result["output.%s.scale" % name] = info["scale"]

        if "vrr" in cfg:
            result["output.%s.vrr" % name] = str(cfg["vrr"])
        elif "adaptive" in info:
            adv = info["adaptive"].lower()
            if adv.startswith("disabled") or adv == "off":
                result["output.%s.vrr" % name] = "disabled"
            elif "fullscreen" in adv:
                result["output.%s.vrr" % name] = "fullscreen"
            else:
                result["output.%s.vrr" % name] = "always"

        if "transform" in cfg:
            result["output.%s.transform" % name] = str(cfg["transform"])
        elif "transform" in info:
            result["output.%s.transform" % name] = info["transform"]

        if "mode" in cfg:
            result["output.%s.mode" % name] = str(cfg["mode"])
        elif "current" in info:
            result["output.%s.mode" % name] = fmt_mode(info["current"])

        modes = sorted(set(info.get("modes", [])), key=lambda t: (t[0], t[1], t[2]))
        if modes:
            result["output.%s.modes" % name] = [fmt_mode(m) for m in modes]

        for suffix, tail, cast in OUTPUT_KEYS:
            path = ("output", name) + tail
            val = _lookup(eff, path)
            if val is _MISSING:
                val = _default_for(defaults, path)
            if val is _MISSING:
                continue
            try:
                result["output.%s.%s" % (name, suffix)] = cast(val)
            except (TypeError, ValueError):
                continue

    print(json.dumps(result, ensure_ascii=False))
    return 0


# --- Правка -----------------------------------------------------------------
def _sec_re(section):
    """Регэксп заголовка секции (для output — с учётом кавычек)."""
    if section.startswith("output:"):
        name = re.escape(section[len("output:"):])
        return re.compile(
            r'^\s*\[output\s*\.\s*(?:"%s"|%s)\s*\]\s*(?:#.*)?$' % (name, name)
        )
    return re.compile(r"^\s*\[%s\]\s*(?:#.*)?$" % re.escape(section))


def _key_re(key):
    return re.compile(
        r"^(\s*)" + re.escape(key) + r"\s*=\s*(.*?)(\s+#.*)?$"
    )


def _header_for(section):
    if section.startswith("output:"):
        return 'output."%s"' % section[len("output:"):]
    return section


def apply_edit(text, section, key, value):
    """Заменить/добавить key = value в секции, вернуть новый текст."""
    lines = text.split("\n")
    sec_re = _sec_re(section)

    start = -1
    for i, line in enumerate(lines):
        if sec_re.match(line):
            start = i
            break

    if start == -1:
        # Секции нет нигде — дописываем в конец целевого файла.
        out = text
        if out and not out.endswith("\n"):
            out += "\n"
        if out and not out.endswith("\n\n"):
            out += "\n"
        out += "[%s]\n%s = %s\n" % (_header_for(section), key, value)
        return out

    # Границы секции — до следующего заголовка таблицы или EOF.
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if HEADER_RE.match(lines[j]):
            end = j
            break

    key_re = _key_re(key)
    found = -1
    for j in range(start + 1, end):
        if key_re.match(lines[j]):
            found = j
            break

    if found != -1:
        m = key_re.match(lines[found])
        comment = m.group(3) or ""
        lines[found] = "%s%s = %s%s" % (m.group(1), key, value, comment)
    else:
        # Вставляем в конец секции, но перед её хвостовыми пустыми строками.
        ins = end
        while ins > start + 1 and lines[ins - 1].strip() == "":
            ins -= 1
        lines.insert(ins, "%s = %s" % (key, value))
    return "\n".join(lines)


def _node(data, section):
    """Узел-словарь секции или None. section: 'a.b' или 'output:NAME'."""
    if section.startswith("output:"):
        path = ("output", section[len("output:"):])
    else:
        path = tuple(section.split("."))
    cur = data
    for part in path:
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur if isinstance(cur, dict) else None


def resolve_path(file_arg):
    if os.path.isabs(file_arg):
        return file_arg
    return os.path.join(CONFIG_DIR, file_arg)


def cmd_set(argv):
    if len(argv) != 4:
        print("usage: umbriel-settings.py set <file> <section> <key> <tomlValue>",
              file=sys.stderr)
        return 2
    file_arg, section, key, value = argv
    target = resolve_path(file_arg)
    if not os.path.isfile(target):
        print("нет файла: %s" % target, file=sys.stderr)
        return 1

    same_main = os.path.abspath(target) == os.path.abspath(MAIN_CONFIG)
    edit_path = target

    if not same_main:
        # Если ключ есть в главном конфиге (или секция только там) — правим
        # главный: именно он задаёт эффективное значение.
        main_data = load_toml(MAIN_CONFIG)
        tgt_data = load_toml(target)
        main_sec = _node(main_data, section)
        tgt_sec = _node(tgt_data, section)
        main_has_key = main_sec is not None and key in main_sec
        tgt_has_sec = tgt_sec is not None
        src_paths = {os.path.abspath(p) for p in SRC_FILES}
        if main_has_key or (main_sec is not None and not tgt_has_sec):
            edit_path = MAIN_CONFIG
        elif not tgt_has_sec and os.path.abspath(target) in src_paths:
            # Секции нет в целевом src-файле: если она уже есть в другом
            # src-файле — правим там, чтобы не плодить дубликаты таблицы.
            # Из нескольких — берём последний по порядку слияния (он главнее).
            skip = {os.path.abspath(target), os.path.abspath(MAIN_CONFIG)}
            for path in SRC_FILES:
                if os.path.abspath(path) in skip:
                    continue
                if _node(load_toml(path), section) is not None:
                    edit_path = path

    try:
        with open(edit_path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError as exc:
        print("не удалось прочитать %s: %s" % (edit_path, exc), file=sys.stderr)
        return 1

    new_text = apply_edit(text, section, key, value)
    try:
        with open(edit_path, "w", encoding="utf-8") as f:
            f.write(new_text)
    except OSError as exc:
        print("не удалось записать %s: %s" % (edit_path, exc), file=sys.stderr)
        return 1

    # Перечитать конфиг композитором; ошибки не фатальны.
    try:
        subprocess.run(["umbriel", "msg", "config-reload"],
                       stdout=DEVNULL, stderr=DEVNULL, timeout=10)
    except (OSError, subprocess.SubprocessError):
        pass
    return 0


# --- Точка входа ------------------------------------------------------------
def main(argv):
    if not argv:
        print("usage: umbriel-settings.py {read|set ...}", file=sys.stderr)
        return 2
    if argv[0] == "read":
        return cmd_read()
    if argv[0] == "set":
        return cmd_set(argv[1:])
    print("неизвестная команда: %s" % argv[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
