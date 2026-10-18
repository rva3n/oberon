#!/usr/bin/env bash
# Backend for Oberon's v1 file browser.
set -u

PATH="${PATH}:/usr/bin:/usr/local/bin:/bin:/usr/sbin:/sbin"
export PATH

exec python3 - "$@" <<'PY'
import json
import os
import stat
import subprocess
import sys


def fail(message, code=1):
    print(f"files.sh: {message}", file=sys.stderr)
    raise SystemExit(code)


def emit(value):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="backslashreplace")
    print(json.dumps(value, ensure_ascii=False))


def home_dir():
    return os.path.abspath(os.environ.get("HOME") or os.path.expanduser("~"))


def expand_path(value):
    value = os.path.expanduser(str(value))
    if not os.path.isabs(value):
        value = os.path.join(os.getcwd(), value)
    return os.path.abspath(value)


def run_tool(args):
    try:
        result = subprocess.run(args, text=True, encoding="utf-8", errors="replace",
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except FileNotFoundError:
        fail(f"{args[0]} не установлен.")
    except OSError as error:
        fail(str(error))
    if result.returncode != 0:
        fail((result.stderr or result.stdout).strip() or f"Команда завершилась с кодом {result.returncode}.")
    if result.stdout:
        sys.stdout.write(result.stdout)
    return result.stdout.strip()


def xdg_place(key, fallback):
    try:
        result = subprocess.run(["xdg-user-dir", key], text=True, encoding="utf-8",
                                errors="replace", stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, check=False)
    except OSError:
        result = None
    value = result.stdout.strip() if result and result.returncode == 0 else ""
    return expand_path(value) if value else fallback


def list_places():
    home = home_dir()
    defaults = [
        ("Дом", home),
        ("Документы", xdg_place("DOCUMENTS", os.path.join(home, "Documents"))),
        ("Загрузки", xdg_place("DOWNLOAD", os.path.join(home, "Downloads"))),
        ("Изображения", xdg_place("PICTURES", os.path.join(home, "Pictures"))),
        ("Видео", xdg_place("VIDEOS", os.path.join(home, "Videos"))),
        ("Музыка", xdg_place("MUSIC", os.path.join(home, "Music"))),
        ("Рабочий стол", xdg_place("DESKTOP", os.path.join(home, "Desktop"))),
    ]
    places = []
    seen = set()
    for name, path in defaults:
        path = os.path.abspath(path)
        if path not in seen and os.path.isdir(path):
            places.append({"name": name, "path": path})
            seen.add(path)
    emit(places)


def list_directory(raw_path):
    path = expand_path(raw_path)
    try:
        with os.scandir(path) as scanner:
            children = list(scanner)
    except OSError as error:
        fail(f"Не удалось прочитать папку «{path}»: {error.strerror or error}.")

    entries = []
    for child in children:
        if child.name.startswith("."):
            continue
        try:
            info = child.stat(follow_symlinks=False)
            is_dir = child.is_dir(follow_symlinks=True)
        except OSError:
            continue
        entries.append({
            "name": child.name,
            "path": os.path.join(path, child.name),
            "dir": is_dir,
            "size": 0 if is_dir else info.st_size,
            "mtime": int(info.st_mtime),
            "mode": stat.filemode(info.st_mode),
            "isLink": stat.S_ISLNK(info.st_mode),
        })
    entries.sort(key=lambda item: (not item["dir"], item["name"].casefold()))
    emit(entries)


def mountable_disks():
    try:
        result = subprocess.run(
            ["lsblk", "--json", "--bytes", "--output", "NAME,PATH,LABEL,SIZE,FSTYPE,MOUNTPOINTS,RM,TYPE"],
            text=True, encoding="utf-8", errors="replace", stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, check=False)
    except FileNotFoundError:
        fail("lsblk не установлен.")
    except OSError as error:
        fail(str(error))
    if result.returncode != 0:
        fail((result.stderr or "Не удалось прочитать список дисков.").strip())
    try:
        tree = json.loads(result.stdout).get("blockdevices", [])
    except (ValueError, AttributeError):
        fail("Не удалось разобрать список дисков.")

    disks = []

    def walk(nodes, inherited_removable=False):
        for node in nodes or []:
            kind = str(node.get("type") or "")
            children = node.get("children") or []
            removable = inherited_removable or str(node.get("rm", "0")).lower() in ("1", "true", "yes")
            points = node.get("mountpoints")
            if not isinstance(points, list):
                points = [node.get("mountpoint")]
            mountpoint = next((str(point) for point in points if point), "")
            has_partitions = any(str(child.get("type") or "") == "part" for child in children)
            show = kind == "part" or (kind == "disk" and not has_partitions)
            if show and node.get("path"):
                name = str(node.get("name") or os.path.basename(node["path"]))
                label = str(node.get("label") or name)
                disks.append({
                    "name": name,
                    "path": str(node["path"]),
                    "label": label,
                    "size": int(node.get("size") or 0),
                    "fstype": str(node.get("fstype") or ""),
                    "mountpoint": mountpoint,
                    "removable": removable,
                    "mounted": bool(mountpoint),
                })
            walk(children, removable)

    walk(tree)
    emit(disks)


def trash_dir():
    data_home = os.environ.get("XDG_DATA_HOME") or os.path.join(home_dir(), ".local", "share")
    if not os.path.isabs(data_home):
        data_home = os.path.join(home_dir(), data_home)
    return os.path.join(data_home, "Trash", "files")


def trash_count():
    try:
        count = len(os.listdir(trash_dir()))
    except FileNotFoundError:
        count = 0
    except OSError as error:
        fail(f"Не удалось прочитать корзину: {error.strerror or error}.")
    print(count)


def require_device(raw_path):
    path = expand_path(raw_path)
    if not path.startswith("/dev/"):
        fail("Устройство должно иметь путь в /dev/.", 2)
    return path


def removable_device(path):
    try:
        result = subprocess.run(["lsblk", "--noheadings", "--output", "RM", "--", path],
                                text=True, encoding="utf-8", errors="replace",
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except OSError as error:
        fail(str(error))
    if result.returncode != 0:
        fail((result.stderr or "Не удалось определить тип устройства.").strip())
    return result.stdout.strip() == "1"


def parent_device(path):
    try:
        result = subprocess.run(["lsblk", "--noheadings", "--output", "PKNAME", "--", path],
                                text=True, encoding="utf-8", errors="replace",
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except OSError as error:
        fail(str(error))
    if result.returncode != 0:
        fail((result.stderr or "Не удалось определить родительский диск.").strip())
    name = result.stdout.strip().splitlines()[0] if result.stdout.strip() else ""
    return os.path.join("/dev", name) if name else path


def safe_name(raw_name):
    name = str(raw_name)
    if not name or name in (".", "..") or "/" in name or "\0" in name:
        fail("Укажите корректное имя файла или папки.", 2)
    return name


def main(args):
    if not args:
        fail("Использование: files.sh {places|list|disks|mount|eject|trash|emptytrash|trashcount|rename|mkdir} ...", 2)
    action, *values = args

    if action == "places" and not values:
        list_places()
    elif action == "list" and len(values) == 1:
        list_directory(values[0])
    elif action == "disks" and not values:
        mountable_disks()
    elif action == "mount" and len(values) == 1:
        run_tool(["udisksctl", "mount", "-b", require_device(values[0])])
    elif action == "eject" and len(values) == 1:
        device = require_device(values[0])
        run_tool(["udisksctl", "unmount", "-b", device])
        if removable_device(device):
            run_tool(["udisksctl", "power-off", "-b", parent_device(device)])
    elif action == "trash" and values:
        run_tool(["gio", "trash"] + [expand_path(value) for value in values])
    elif action == "emptytrash" and not values:
        run_tool(["gio", "trash", "--empty"])
    elif action == "trashcount" and not values:
        trash_count()
    elif action == "rename" and len(values) == 2:
        source = expand_path(values[0])
        name = safe_name(values[1])
        if not os.path.lexists(source):
            fail(f"Путь не найден: {source}")
        destination = os.path.join(os.path.dirname(source), name)
        if os.path.lexists(destination):
            fail(f"Уже существует: {destination}")
        try:
            os.rename(source, destination)
        except OSError as error:
            fail(f"Не удалось переименовать: {error.strerror or error}.")
    elif action == "mkdir" and len(values) == 2:
        directory = expand_path(values[0])
        name = safe_name(values[1])
        try:
            os.mkdir(os.path.join(directory, name))
        except OSError as error:
            fail(f"Не удалось создать папку: {error.strerror or error}.")
    else:
        fail("Неверные аргументы команды files.sh.", 2)


main(sys.argv[1:])
PY
