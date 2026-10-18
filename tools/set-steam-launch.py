#!/usr/bin/env python3
"""Прописать или прочитать параметры запуска игр в Steam (localconfig.vdf).

Использование:
    python3 tools/set-steam-launch.py <appid> "<параметры>"
    python3 tools/set-steam-launch.py --kill-steam <appid> "<параметры>"
    python3 tools/set-steam-launch.py --list
"""
import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

NON_GAME_APPIDS = {
    "228980",   # Steamworks Common Redistributables
    "1070560",  # Steam Linux Runtime
    "1391110",  # Steam Linux Runtime - Soldier
    "1628350",  # Steam Linux Runtime - Sniper
    "1493710",  # Proton Experimental
    "2180100",  # Proton Hotfix
    "1887720",  # Proton 7.0
    "2348590",  # Proton 8.0
    "2805730",  # Proton 9.0
}

NON_GAME_NAME_RE = re.compile(
    r"^(Proton\b|Steam Linux Runtime\b|Steamworks Common Redistributables\b|SteamVR\b)",
    re.IGNORECASE,
)


def steam_running() -> bool:
    try:
        return subprocess.run(["pgrep", "-x", "steam"], capture_output=True).returncode == 0
    except FileNotFoundError:
        return False


def stop_steam(timeout: float = 4.0) -> None:
    if not steam_running():
        return
    try:
        subprocess.run(
            ["steam", "-shutdown"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2,
        )
    except Exception:
        pass

    deadline = time.monotonic() + timeout
    killed = False
    while time.monotonic() < deadline:
        if not steam_running():
            return
        if not killed and (deadline - time.monotonic()) < (timeout * 0.6):
            try:
                subprocess.run(["pkill", "-x", "steam"], capture_output=True)
            except Exception:
                pass
            killed = True
        time.sleep(0.2)

    if steam_running():
        try:
            subprocess.run(["pkill", "-x", "steam"], capture_output=True)
            time.sleep(0.3)
        except Exception:
            pass


def find_localconfig(required: bool = True) -> str:
    candidates = []
    for base in ("~/.local/share/Steam", "~/.steam/steam"):
        pattern = os.path.expanduser(f"{base}/userdata/*/config/localconfig.vdf")
        candidates.extend(glob.glob(pattern))
    seen = set()
    unique = []
    for p in candidates:
        rp = os.path.realpath(p)
        if rp not in seen and os.path.isfile(rp):
            seen.add(rp)
            unique.append(rp)
    if not unique:
        if required:
            sys.exit("localconfig.vdf не найден")
        return ""
    unique.sort(key=os.path.getmtime, reverse=True)
    return unique[0]


def find_steamapps_dirs() -> list[str]:
    dirs = []
    seen = set()

    def add_dir(d: str) -> None:
        expanded = os.path.expanduser(d)
        if not os.path.isdir(expanded):
            return
        rp = os.path.realpath(expanded)
        if rp not in seen:
            seen.add(rp)
            dirs.append(rp)

    for base in ("~/.local/share/Steam/steamapps", "~/.steam/steam/steamapps"):
        add_dir(base)

    for sa in list(dirs):
        lf = os.path.join(sa, "libraryfolders.vdf")
        if os.path.isfile(lf):
            try:
                with open(lf, "r", encoding="utf-8", errors="surrogateescape") as fh:
                    text = fh.read()
                for m in re.finditer(r'"path"\s+"((?:\\.|[^"\\])*)"', text):
                    raw_path = m.group(1).replace(r"\\", "\\")
                    add_dir(os.path.join(raw_path, "steamapps"))
            except Exception:
                pass

    return dirs


def unescape_vdf(val: str) -> str:
    return val.replace(r'\"', '"').replace(r"\\", "\\")


def escape_vdf(val: str) -> str:
    return val.replace("\\", "\\\\").replace('"', '\\"')


def extract_launch_options(vdf_text: str, appid: str) -> str:
    if not vdf_text:
        return ""
    m = re.search(r'(\n(\t{4,6})"%s"\n\2\{\n)' % re.escape(appid), vdf_text)
    if not m:
        return ""
    indent = m.group(2)
    start = m.end()
    rest = vdf_text[start:]
    end = re.search(r"\n" + indent + r"\}", rest)
    block = rest[:end.start()] if end else rest
    opt_m = re.search(r'(?:^|\n)\t+"LaunchOptions"[ \t]*"((?:\\.|[^"\\])*)"', block)
    if not opt_m:
        return ""
    return unescape_vdf(opt_m.group(1))


def list_games(localconfig_path: str | None = None) -> dict:
    lc_path = localconfig_path if localconfig_path is not None else find_localconfig(required=False)
    vdf_text = ""
    if lc_path and os.path.isfile(lc_path):
        try:
            with open(lc_path, "r", encoding="utf-8", errors="surrogateescape") as fh:
                vdf_text = fh.read()
        except Exception:
            vdf_text = ""

    games_by_id: dict[str, dict] = {}
    for sa_dir in find_steamapps_dirs():
        for acf in glob.glob(os.path.join(sa_dir, "appmanifest_*.acf")):
            try:
                with open(acf, "r", encoding="utf-8", errors="surrogateescape") as fh:
                    content = fh.read()
            except Exception:
                continue
            appid_m = re.search(r'"appid"\s+"(\d+)"', content, re.IGNORECASE)
            name_m = re.search(r'"name"\s+"((?:\\.|[^"\\])*)"', content, re.IGNORECASE)
            if not appid_m or not name_m:
                continue
            appid = appid_m.group(1)
            name = unescape_vdf(name_m.group(1)).strip()
            if appid in NON_GAME_APPIDS or NON_GAME_NAME_RE.search(name):
                continue
            games_by_id[appid] = {
                "appid": appid,
                "name": name,
                "options": extract_launch_options(vdf_text, appid),
            }

    games = sorted(games_by_id.values(), key=lambda g: g["name"].lower())
    return {
        "steam_running": steam_running(),
        "localconfig": lc_path or "",
        "games": games,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("appid", nargs="?", default=None, help="Steam AppID")
    ap.add_argument("options", nargs="?", default=None, help="Строка параметров запуска")
    ap.add_argument("--list", action="store_true", help="Вывести список установленных игр и их LaunchOptions в JSON")
    ap.add_argument("--kill-steam", action="store_true", help="Закрыть Steam перед записью localconfig.vdf")
    ap.add_argument("--file", default=None, help="путь к localconfig.vdf (по умолчанию — самый свежий)")
    ap.add_argument("--force", action="store_true", help="не проверять, закрыт ли Steam")
    args = ap.parse_args()

    if args.list:
        print(json.dumps(list_games(args.file), ensure_ascii=False))
        return 0

    if args.appid is None or args.options is None:
        ap.error("требуются аргументы <appid> и <options> (или флаг --list)")

    path = args.file or find_localconfig(required=True)
    if not os.path.isfile(path):
        sys.exit(f"нет файла: {path}")

    if steam_running():
        if args.kill_steam:
            stop_steam(4.0)
        elif not args.force:
            sys.exit("Steam запущен — закрой его и повтори (иначе Steam затрёт правку).")

    with open(path, "r", encoding="utf-8", errors="surrogateescape") as fh:
        text = fh.read()

    # блок приложения: 5 табов «appid» + 5 табов «{»
    m = re.search(r'(\n(\t{4,6})"%s"\n\2\{\n)' % re.escape(args.appid), text)
    if not m:
        # Если игра ещё ни разу не запускалась и её блока нет в секции apps, создадим его
        apps_m = re.search(r'(\n(\t{3,5})"apps"\n\2\{\n)', text)
        if not apps_m:
            sys.exit(f"не найден блок приложения {args.appid} в {path}")
        app_indent = apps_m.group(2) + "\t"
        prop_indent = app_indent + "\t"
        value = escape_vdf(args.options)
        insert_pos = apps_m.end()
        new_block = (
            f'{app_indent}"{args.appid}"\n'
            f'{app_indent}{{\n'
            f'{prop_indent}"LaunchOptions"\t\t"{value}"\n'
            f'{app_indent}}}\n'
        )
        new_text = text[:insert_pos] + new_block + text[insert_pos:]
        action = "добавлены"
    else:
        indent = m.group(2)
        prop_indent = indent + "\t"
        start = m.end()
        rest = text[start:]
        end = re.search(r"\n" + indent + r"\}", rest)
        block = rest[:end.start()] if end else rest

        value = escape_vdf(args.options)
        opt_re = re.compile(r'((?:^|\n)' + prop_indent + r'"LaunchOptions"[ \t]*)"(?:\\.|[^"\\])*"', re.M)
        if opt_re.search(block):
            block_new = opt_re.sub(lambda mo: mo.group(1) + '"' + value + '"', block, count=1)
            action = "обновлены"
        else:
            block_new = f'{prop_indent}"LaunchOptions"\t\t"{value}"\n' + block
            action = "добавлены"

        new_text = text[:start] + block_new + text[start + len(block):]

    backup = path + ".bak-" + time.strftime("%Y%m%d-%H%M%S")
    shutil.copy2(path, backup)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write(new_text)

    print(f"ok: параметры запуска {action} для {args.appid}: {args.options}")
    print(f"бэкап: {backup}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
