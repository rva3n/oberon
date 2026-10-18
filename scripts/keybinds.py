#!/usr/bin/env python3
"""Read and safely edit Umbriel's keybinds.toml without dropping comments."""

import fcntl
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path

try:
    import tomllib
except ImportError:  # pragma: no cover - Python < 3.11
    print("Нужен Python 3.11 или новее (tomllib).", file=sys.stderr)
    raise SystemExit(1)


KEYBINDS = Path(
    os.environ.get("OBERON_KEYBINDS_FILE")
    or (Path.home() / ".config" / "umbriel" / "src" / "keybinds.toml")
).expanduser()
BACKUP = KEYBINDS.with_name(KEYBINDS.name + ".bak")
LOCK = KEYBINDS.with_name(KEYBINDS.name + ".lock")
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


def value_has_unclosed_construct(value):
    """Return whether an array/table or multiline string continues below this line."""
    value = value.lstrip()
    if not value.startswith(("[", "{", '"""', "'''")):
        return False

    stack = []
    quote = None
    quote_length = 0
    escaped = False
    index = 0
    while index < len(value):
        char = value[index]
        if quote is not None:
            if quote == '"' and escaped:
                escaped = False
                index += 1
                continue
            if quote == '"' and char == "\\":
                escaped = True
                index += 1
                continue
            if value.startswith(quote * quote_length, index):
                index += quote_length
                quote = None
                quote_length = 0
                continue
            index += 1
            continue

        if char in ('"', "'"):
            quote = char
            quote_length = 3 if value.startswith(char * 3, index) else 1
            index += quote_length
            continue
        if char == "#":
            break
        if char in "[{":
            stack.append("]" if char == "[" else "}")
        elif char in "]}":
            if stack and stack[-1] == char:
                stack.pop()
            if not stack:
                return False
        index += 1

    return bool(stack) or (quote is not None and quote_length == 3)


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
    if value_has_unclosed_construct(value):
        raise KeybindError("формат не поддерживается, правьте вручную")
    return {
        "key": key,
        "value": value,
        "comment": comment,
        "body": body,
        "ending": ending,
        "prefix": body[:match.end()],
        "key_prefix": body[:match.start(1)],
        "key_suffix": body[match.end(1):match.end()],
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


@contextmanager
def keybind_lock():
    fd = None
    try:
        fd = os.open(LOCK, os.O_CREAT | os.O_RDWR, 0o600)
        lock_file = os.fdopen(fd, "a+b")
        fd = None
    except OSError as exc:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        raise KeybindError(f"Не удалось заблокировать {KEYBINDS}: {exc.strerror or exc}") from exc
    try:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
    except OSError as exc:
        lock_file.close()
        raise KeybindError(f"Не удалось заблокировать {KEYBINDS}: {exc.strerror or exc}") from exc
    try:
        yield
    finally:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        lock_file.close()


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


def create_backup(overwrite=False):
    if not KEYBINDS.is_file():
        raise KeybindError(f"Файл биндов не найден: {KEYBINDS}")
    if BACKUP.exists() and not overwrite:
        return False
    try:
        shutil.copy2(KEYBINDS, BACKUP)
    except OSError as exc:
        raise KeybindError(f"Не удалось создать резервную копию: {exc.strerror or exc}") from exc
    return True


def restore_backup():
    if not BACKUP.is_file():
        raise KeybindError(f"Резервная копия не найдена: {BACKUP}")
    try:
        atomic_write(BACKUP.read_bytes())
    except OSError as exc:
        raise KeybindError(f"Не удалось восстановить резервную копию: {exc.strerror or exc}") from exc


def run_umbriel(args):
    try:
        code = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, check=False, timeout=20).returncode
    except subprocess.TimeoutExpired:
        return 2
    except OSError:
        return 2
    return code if code in (0, 1, 2) else 2


def reload_config():
    code = run_umbriel(["umbriel", "msg", "config-reload"])
    if code != 0:
        print(f"Не удалось перезагрузить конфигурацию Umbriel (код {code}).", file=sys.stderr)
        return code
    print("Конфигурация Umbriel перезагружена.")
    return 0


def validate_config(rollback=True, original=None):
    code = run_umbriel(["umbriel", "config", "validate"])
    if code == 0:
        return 0
    if code == 2:
        print("изменения записаны, но проверить не удалось (umbriel недоступен)", file=sys.stderr)
        return 2
    print(f"Проверка конфигурации не пройдена (код {code}).", file=sys.stderr)
    if rollback:
        try:
            if original is None:
                restore_backup()
            else:
                atomic_write(original)
        except KeybindError as exc:
            print(f"Откат не выполнен: {exc}", file=sys.stderr)
            return code
        except OSError as exc:
            print(f"Откат не выполнен: {exc.strerror or exc}", file=sys.stderr)
            return code
        if original is None:
            print("Файл восстановлен из keybinds.toml.bak.", file=sys.stderr)
        else:
            print("Исходный файл восстановлен.", file=sys.stderr)
        reload_code = run_umbriel(["umbriel", "msg", "config-reload"])
        if reload_code != 0:
            print(f"Не удалось перезагрузить восстановленную конфигурацию (код {reload_code}).", file=sys.stderr)
    return code


def find_binding(lines, combo):
    return [(index, entry) for index, entry in binding_lines(lines) if entry["key"] == combo]


def validate_binding_args(combo, action):
    if not combo or "\n" in combo or "\r" in combo:
        raise KeybindError("Сочетание клавиш не должно быть пустым или содержать перевод строки.")
    if not action or "\n" in action or "\r" in action:
        raise KeybindError("Действие не должно быть пустым или содержать перевод строки.")


def set_binding(combo, action, repeat):
    validate_binding_args(combo, action)

    original, text = read_file()
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
    code = validate_config(rollback=True, original=original)
    if code != 0:
        return code
    print(f"{message}: {combo}. Конфигурация проверена; для применения выполните apply.")
    return 0


def rename_binding(old_combo, new_combo, action, repeat):
    validate_binding_args(old_combo, action)
    if not new_combo or "\n" in new_combo or "\r" in new_combo:
        raise KeybindError("Новое сочетание клавиш не должно быть пустым или содержать перевод строки.")
    if old_combo == new_combo:
        raise KeybindError("Старое и новое сочетания клавиш должны отличаться.")

    original, text = read_file()
    _, table = parse_document(text)
    lines = text.splitlines(keepends=True)
    matches = find_binding(lines, old_combo)
    if not matches or old_combo not in table:
        raise KeybindError(f"Бинд не найден: {old_combo}")
    if new_combo in table:
        raise KeybindError(f"Бинд уже существует: {new_combo}")

    index, entry = matches[0]
    value = render_value(table[old_combo], entry["value"], action, repeat)
    raw_value = entry["value_raw"]
    leading = raw_value[:len(raw_value) - len(raw_value.lstrip())]
    trailing = raw_value[len(raw_value.rstrip()):]
    lines[index] = (
        entry["key_prefix"] + toml_string(new_combo) + entry["key_suffix"]
        + leading + value + trailing + entry["comment"] + entry["ending"]
    )

    create_backup(overwrite=False)
    write_text("".join(lines))
    code = validate_config(rollback=True, original=original)
    if code != 0:
        return code
    code = reload_config()
    if code != 0:
        return code
    print(f"Бинд переименован: {old_combo} → {new_combo}. Конфигурация проверена и применена.")
    return 0


def remove_binding(combo):
    if not combo or "\n" in combo or "\r" in combo:
        raise KeybindError("Укажите сочетание клавиш без переводов строки.")
    original, text = read_file()
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
    code = validate_config(rollback=True, original=original)
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
    if code == 2:
        return code
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
    print("Использование: keybinds.py list|backup [--force]|restore|validate|apply|set <combo> <action> [--repeat=false|--repeat=true]|rename <old> <new> <action> [--repeat=false|--repeat=true]|remove <combo>", file=sys.stderr)
    return 2


def main(argv):
    if not argv:
        return usage()
    command = argv[0]
    try:
        if command == "list" and len(argv) == 1:
            list_bindings()
            return 0
        if command == "backup" and len(argv) in (1, 2) and (len(argv) == 1 or argv[1] == "--force"):
            with keybind_lock():
                created = create_backup(overwrite=len(argv) == 2)
            if created:
                print("Резервная копия keybinds.toml.bak создана.")
            else:
                print("Резервная копия keybinds.toml.bak уже существует; оставлена без изменений.")
            return 0
        if command == "restore" and len(argv) == 1:
            with keybind_lock():
                return restore_command()
        if command == "validate" and len(argv) == 1:
            with keybind_lock():
                code = validate_config(rollback=True)
            if code == 0:
                print("Конфигурация Umbriel корректна.")
            return code
        if command == "apply" and len(argv) == 1:
            with keybind_lock():
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
            with keybind_lock():
                return set_binding(argv[1], argv[2], repeat)
        if command == "rename" and len(argv) in (4, 5):
            repeat = None
            if len(argv) == 5:
                if argv[4] == "--repeat=false":
                    repeat = False
                elif argv[4] == "--repeat=true":
                    repeat = True
                else:
                    return usage()
            with keybind_lock():
                return rename_binding(argv[1], argv[2], argv[3], repeat)
        if command == "remove" and len(argv) == 2:
            with keybind_lock():
                return remove_binding(argv[1])
        return usage()
    except KeybindError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
