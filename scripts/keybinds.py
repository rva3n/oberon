#!/usr/bin/env python3
"""Read and safely edit Umbriel's keybinds.toml without dropping comments."""

import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import tomllib
except ImportError:  # pragma: no cover - Python < 3.11
    print("Нужен Python 3.11 или новее (tomllib).", file=sys.stderr)
    raise SystemExit(1)


KEYBINDS = Path.home() / ".config" / "umbriel" / "src" / "keybinds.toml"
BACKUP = KEYBINDS.with_name(KEYBINDS.name + ".bak")
ENTRY_RE = re.compile(r'^\s*("(?:\\.|[^"\\])*")\s*=\s*')
HEADER_RE = re.compile(r"^\s*\[([^\]]+)\]\s*(?:#.*)?$")


class KeybindError(Exception):
    """An expected error that can be reported without a traceback."""


def split_ending(line):
    if line.endswith("\r\n"):
        return line[:-2], "\r\n"
    if line.endswith("\n") or line.endswith("\r"):
        return line[:-1], line[-1:]
    return line, ""


def split_comment(value):
    """Return TOML value text and a trailing comment, ignoring # in strings."""
    in_string = False
    escaped = False
    for index, char in enumerate(value):
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char == "#":
            return value[:index], value[index:]
    return value, ""


def parse_document(text):
    try:
        document = tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        raise KeybindError(f"keybinds.toml не является корректным TOML: {exc}") from exc
    table = document.get("keybinds", {})
    if not isinstance(table, dict):
        raise KeybindError("В keybinds.toml ожидается таблица [keybinds].")
    return document, table


def table_bounds(lines):
    start = None
    for index, line in enumerate(lines):
        body, _ = split_ending(line)
        header = HEADER_RE.match(body)
        if not header:
            continue
        name = header.group(1).strip()
        if start is not None:
            return start, index
        if name == "keybinds":
            start = index
    if start is None:
        return None
    return start, len(lines)


def entry_at(line):
    body, ending = split_ending(line)
    match = ENTRY_RE.match(body)
    if not match:
        return None
    try:
        key = tomllib.loads("key = " + match.group(1))["key"]
    except (tomllib.TOMLDecodeError, KeyError):
        return None
    value_and_comment = body[match.end():]
    value_raw, comment = split_comment(value_and_comment)
    value = value_raw.strip()
    if not value:
        return None
    return {
        "key": key,
        "value": value,
        "comment": comment,
        "body": body,
        "ending": ending,
        "prefix": body[:match.end()],
        "value_raw": value_raw,
    }


def binding_lines(lines):
    bounds = table_bounds(lines)
    if bounds is None:
        return []
    start, end = bounds
    result = []
    for index in range(start + 1, end):
        entry = entry_at(lines[index])
        if entry is not None:
            result.append((index, entry))
    return result


def read_file():
    try:
        raw = KEYBINDS.read_bytes()
    except OSError as exc:
        raise KeybindError(f"Не удалось прочитать {KEYBINDS}: {exc.strerror or exc}") from exc
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise KeybindError("keybinds.toml должен быть в кодировке UTF-8.") from exc
    return raw, text


def list_bindings():
    _, text = read_file()
    _, table = parse_document(text)
    lines = text.splitlines(keepends=True)
    result = []
    for index, entry in binding_lines(lines):
        value = table.get(entry["key"])
        if isinstance(value, str):
            action = value
            repeat = True
            special = []
        elif isinstance(value, dict):
            action = value.get("action", "")
            if not isinstance(action, str):
                action = str(action)
            repeat = value.get("repeat", True)
            if not isinstance(repeat, bool):
                repeat = True
            special = sorted(str(key) for key in value if key not in ("action", "repeat"))
        else:
            continue

        bind = {
            "keys": entry["key"],
            "action": action,
            "repeat": repeat,
            "line": index + 1,
        }
        note = entry["comment"][1:].strip()
        if note:
            bind["note"] = note
        if special:
            bind["special"] = special
        result.append(bind)
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))


def toml_string(value):
    return json.dumps(value, ensure_ascii=False)


def split_inline_fields(inner):
    fields = []
    start = 0
    in_string = False
    escaped = False
    depth = 0
    for index, char in enumerate(inner):
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char in "[{":
            depth += 1
        elif char in "]}":
            depth -= 1
        elif char == "," and depth == 0:
            fields.append(inner[start:index].strip())
            start = index + 1
    tail = inner[start:].strip()
    if tail:
        fields.append(tail)
    return fields


def inline_field_name(field):
    in_string = False
    escaped = False
    equals = -1
    for index, char in enumerate(field):
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char == "=":
            equals = index
            break
    if equals < 0:
        return None
    raw_name = field[:equals].strip()
    try:
        if raw_name.startswith('"'):
            name = next(iter(tomllib.loads(raw_name + " = 0")))
        else:
            name = raw_name
    except (tomllib.TOMLDecodeError, StopIteration):
        return None
    return name, equals


def rewrite_inline_table(value_text, action, repeat):
    stripped = value_text.strip()
    if not (stripped.startswith("{") and stripped.endswith("}")):
        raise KeybindError("Поддерживаются только однострочные inline-таблицы биндов.")
    fields = split_inline_fields(stripped[1:-1])
    output = []
    found_action = False
    found_repeat = False
    for field in fields:
        parsed = inline_field_name(field)
        if parsed is None:
            raise KeybindError("Не удалось разобрать параметры существующего бинда.")
        name, equals = parsed
        if name == "action":
            output.append(field[:equals + 1] + " " + toml_string(action))
            found_action = True
        elif name == "repeat" and repeat is not None:
            output.append(field[:equals + 1] + (" false" if repeat is False else " true"))
            found_repeat = True
        else:
            output.append(field)
            if name == "repeat":
                found_repeat = True
    if not found_action:
        output.append("action = " + toml_string(action))
    if repeat is not None and not found_repeat:
        output.append("repeat = " + ("false" if repeat is False else "true"))
    return "{ " + ", ".join(output) + " }"


def render_value(old_value, old_text, action, repeat):
    if isinstance(old_value, dict):
        return rewrite_inline_table(old_text, action, repeat)
    if repeat is False:
        return "{ action = " + toml_string(action) + ", repeat = false }"
    return toml_string(action)


def atomic_write(raw):
    try:
        mode = stat.S_IMODE(KEYBINDS.stat().st_mode)
        KEYBINDS.parent.mkdir(parents=True, exist_ok=True)
        fd, temp_name = tempfile.mkstemp(prefix=".keybinds.", suffix=".tmp", dir=KEYBINDS.parent)
        try:
            os.fchmod(fd, mode)
            with os.fdopen(fd, "wb") as target:
                target.write(raw)
                target.flush()
                os.fsync(target.fileno())
            os.replace(temp_name, KEYBINDS)
        except Exception:
            try:
                os.unlink(temp_name)
            except OSError:
                pass
            raise
    except OSError as exc:
        raise KeybindError(f"Не удалось записать keybinds.toml: {exc.strerror or exc}") from exc


def write_text(text):
    atomic_write(text.encode("utf-8"))


def create_backup(overwrite=True):
    if not KEYBINDS.is_file():
        raise KeybindError(f"Файл биндов не найден: {KEYBINDS}")
    if BACKUP.exists() and not overwrite:
        return
    try:
        shutil.copy2(KEYBINDS, BACKUP)
    except OSError as exc:
        raise KeybindError(f"Не удалось создать резервную копию: {exc.strerror or exc}") from exc


def restore_backup():
    if not BACKUP.is_file():
        raise KeybindError(f"Резервная копия не найдена: {BACKUP}")
    try:
        atomic_write(BACKUP.read_bytes())
    except OSError as exc:
        raise KeybindError(f"Не удалось восстановить резервную копию: {exc.strerror or exc}") from exc


def run_umbriel(args):
    try:
        return subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, check=False, timeout=20).returncode
    except FileNotFoundError:
        return 127
    except subprocess.TimeoutExpired:
        return 124
    except OSError:
        return 1


def reload_config():
    code = run_umbriel(["umbriel", "msg", "config-reload"])
    if code != 0:
        print(f"Не удалось перезагрузить конфигурацию Umbriel (код {code}).", file=sys.stderr)
        return code
    print("Конфигурация Umbriel перезагружена.")
    return 0


def validate_config(rollback=True):
    code = run_umbriel(["umbriel", "config", "validate"])
    if code == 0:
        return 0
    print(f"Проверка конфигурации не пройдена (код {code}).", file=sys.stderr)
    if rollback:
        try:
            restore_backup()
        except KeybindError as exc:
            print(f"Откат не выполнен: {exc}", file=sys.stderr)
            return code
        print("Файл восстановлен из keybinds.toml.bak.", file=sys.stderr)
        reload_code = run_umbriel(["umbriel", "msg", "config-reload"])
        if reload_code != 0:
            print(f"Не удалось перезагрузить восстановленную конфигурацию (код {reload_code}).", file=sys.stderr)
    return code


def find_binding(lines, combo):
    return [(index, entry) for index, entry in binding_lines(lines) if entry["key"] == combo]


def set_binding(combo, action, repeat):
    if not combo or "\n" in combo or "\r" in combo:
        raise KeybindError("Сочетание клавиш не должно быть пустым или содержать перевод строки.")
    if not action or "\n" in action or "\r" in action:
        raise KeybindError("Действие не должно быть пустым или содержать перевод строки.")

    _, text = read_file()
    document, table = parse_document(text)
    lines = text.splitlines(keepends=True)
    matches = find_binding(lines, combo)
    old_value = table.get(combo)

    create_backup(overwrite=False)
    if matches:
        index, entry = matches[0]
        value = render_value(old_value, entry["value"], action, repeat)
        raw_value = entry["value_raw"]
        leading = raw_value[:len(raw_value) - len(raw_value.lstrip())]
        trailing = raw_value[len(raw_value.rstrip()):]
        lines[index] = (entry["prefix"] + leading + value + trailing
                        + entry["comment"] + entry["ending"])
        message = "Бинд обновлён"
    else:
        if "keybinds" in document and table_bounds(lines) is None:
            raise KeybindError("В keybinds.toml используется неподдерживаемый формат таблицы биндов.")
        if "keybinds" in document and not isinstance(document["keybinds"], dict):
            raise KeybindError("В keybinds.toml ожидается таблица [keybinds].")
        if repeat is False:
            value = "{ action = " + toml_string(action) + ", repeat = false }"
        else:
            value = toml_string(action)
        line = toml_string(combo) + " = " + value
        bounds = table_bounds(lines)
        if bounds is None:
            if text and not text.endswith(("\n", "\r")):
                text += "\n"
            if text and not text.endswith("\n\n"):
                text += "\n"
            lines = text.splitlines(keepends=True)
            newline = next((split_ending(item)[1] for item in lines if split_ending(item)[1]), "\n")
            if lines and not lines[-1].endswith(("\n", "\r")):
                lines[-1] += newline
            lines.extend(["[keybinds]" + newline, line + newline])
        else:
            start, end = bounds
            insert_at = end
            while insert_at > start + 1 and not split_ending(lines[insert_at - 1])[0].strip():
                insert_at -= 1
            newline = next((split_ending(item)[1] for item in lines if split_ending(item)[1]), "\n")
            if insert_at > 0 and not lines[insert_at - 1].endswith(("\n", "\r")):
                lines[insert_at - 1] += newline
            has_following_table = end < len(lines)
            original_had_newline = text.endswith(("\n", "\r"))
            line_ending = newline if has_following_table or original_had_newline else ""
            lines.insert(insert_at, line + line_ending)
        message = "Бинд добавлен"

    write_text("".join(lines))
    code = validate_config(rollback=True)
    if code != 0:
        return code
    print(f"{message}: {combo}. Конфигурация проверена; для применения выполните apply.")
    return 0


def remove_binding(combo):
    if not combo or "\n" in combo or "\r" in combo:
        raise KeybindError("Укажите сочетание клавиш без переводов строки.")
    _, text = read_file()
    _, table = parse_document(text)
    lines = text.splitlines(keepends=True)
    matches = find_binding(lines, combo)
    if not matches or combo not in table:
        raise KeybindError(f"Бинд не найден: {combo}")

    create_backup(overwrite=False)
    del lines[matches[0][0]]
    updated = "".join(lines)
    try:
        backup_text = BACKUP.read_bytes().decode("utf-8")
    except (OSError, UnicodeDecodeError):
        backup_text = None
    if backup_text is not None and updated in (backup_text + "\n", backup_text + "\r\n"):
        updated = backup_text
    write_text(updated)
    code = validate_config(rollback=True)
    if code != 0:
        return code
    print(f"Бинд удалён: {combo}. Конфигурация проверена; для применения выполните apply.")
    return 0


def restore_command():
    if not BACKUP.is_file():
        raise KeybindError(f"Резервная копия не найдена: {BACKUP}")
    current, _ = read_file()
    restore_backup()
    code = validate_config(rollback=False)
    if code != 0:
        atomic_write(current)
        print("Резервная копия не прошла проверку; исходный файл восстановлен.", file=sys.stderr)
        reload_code = run_umbriel(["umbriel", "msg", "config-reload"])
        if reload_code != 0:
            print(f"Не удалось перезагрузить исходную конфигурацию (код {reload_code}).", file=sys.stderr)
        return code
    print("Файл восстановлен из keybinds.toml.bak; выполните apply для перезагрузки.")
    return 0


def usage():
    print("Использование: keybinds.py list|backup|restore|validate|apply|set <combo> <action> [--repeat=false|--repeat=true]|remove <combo>", file=sys.stderr)
    return 2


def main(argv):
    if not argv:
        return usage()
    command = argv[0]
    try:
        if command == "list" and len(argv) == 1:
            list_bindings()
            return 0
        if command == "backup" and len(argv) == 1:
            create_backup(overwrite=True)
            print("Резервная копия keybinds.toml.bak создана.")
            return 0
        if command == "restore" and len(argv) == 1:
            return restore_command()
        if command == "validate" and len(argv) == 1:
            code = validate_config(rollback=True)
            if code == 0:
                print("Конфигурация Umbriel корректна.")
            return code
        if command == "apply" and len(argv) == 1:
            code = validate_config(rollback=True)
            if code != 0:
                return code
            return reload_config()
        if command == "set" and len(argv) in (3, 4):
            repeat = None
            if len(argv) == 4:
                if argv[3] == "--repeat=false":
                    repeat = False
                elif argv[3] == "--repeat=true":
                    repeat = True
                else:
                    return usage()
            return set_binding(argv[1], argv[2], repeat)
        if command == "remove" and len(argv) == 2:
            return remove_binding(argv[1])
        return usage()
    except KeybindError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
