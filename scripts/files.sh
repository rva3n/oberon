#!/usr/bin/env bash
# Backend for Oberon's all-in-one File Manager, Media/Image Studio, PDF/Document Reader,
# Archive Manager, Code/SQLite/CSV Viewer, and Font Installer.
set -u

PATH="${PATH}:/usr/bin:/usr/local/bin:/bin:/usr/sbin:/sbin"
export PATH

if command -v python3 >/dev/null 2>&1; then
exec python3 - "$@" <<'PY'
import csv
import hashlib
import io
import json
import mimetypes
import os
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tarfile
import zipfile


ARCHIVE_COMPOUND_EXTS = (
    ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz", ".tar.lz4",
)
ARCHIVE_EXTS = {
    "zip", "tar", "tgz", "tbz", "tbz2", "txz", "tzst", "7z", "rar", "gz", "bz2", "xz", "zst", "iso",
}
IMAGE_EXTS = {
    "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "avif", "svg", "ico", "heic", "heif", "jxl", "ppm", "pgm", "pbm",
}
VIDEO_EXTS = {
    "mp4", "mkv", "webm", "mov", "avi", "m4v", "wmv", "flv", "mpg", "mpeg", "ts", "m2ts", "ogv", "3gp",
}
AUDIO_EXTS = {
    "mp3", "flac", "ogg", "opus", "wav", "m4a", "aac", "wma", "ape", "alac", "aiff", "mid", "midi",
}
PDF_EXTS = {"pdf"}
MARKDOWN_EXTS = {"md", "markdown", "mdx", "rst"}
TABLE_EXTS = {"csv", "tsv"}
SQLITE_EXTS = {"sqlite", "db", "sqlite3", "db3"}
FONT_EXTS = {"ttf", "otf", "woff", "woff2", "ttc"}
CODE_EXTS = {
    "py", "sh", "bash", "zsh", "fish", "js", "mjs", "cjs", "ts", "tsx", "jsx", "qml",
    "c", "h", "cpp", "hpp", "cc", "cxx", "rs", "go", "java", "kt", "swift", "rb", "php",
    "pl", "pm", "lua", "sql", "html", "htm", "css", "scss", "less", "json", "jsonc",
    "yaml", "yml", "toml", "ini", "conf", "cfg", "xml", "vim", "el", "hs", "ml", "zig",
    "nim", "cmake", "mk", "dockerfile", "service", "timer", "desktop", "gradle", "vue", "svelte",
}
CODE_NAMES = {
    "makefile", "dockerfile", "cmakelists.txt", "pkgbuild", ".bashrc", ".zshrc", ".profile", ".gitignore",
}
TEXT_EXTS = {
    "txt", "log", "text", "nfo", "sub", "srt", "vtt", "ass", "env", "license",
}
TEXT_NAMES = {"license", "readme", "authors", "changelog", "todo", "copying"}


def fail(message, code=1):
    print(f"files.sh: {message}", file=sys.stderr)
    raise SystemExit(code)


def emit(value):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="backslashreplace")
    print(json.dumps(value, ensure_ascii=False))


def home_dir():
    return os.path.abspath(os.environ.get("HOME") or os.path.expanduser("~"))


def cache_dir(*parts):
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(home_dir(), ".cache")
    path = os.path.join(base, "oberon", *parts)
    os.makedirs(path, exist_ok=True)
    return path


def expand_path(value):
    value = os.path.expanduser(str(value))
    if not os.path.isabs(value):
        value = os.path.join(os.getcwd(), value)
    return os.path.abspath(value)


def split_stem_ext(filename):
    lower = filename.lower()
    for comp in ARCHIVE_COMPOUND_EXTS:
        if lower.endswith(comp) and len(filename) > len(comp):
            return filename[:-len(comp)], filename[-len(comp):]
    if "." in filename and not filename.startswith("."):
        idx = filename.rfind(".")
        return filename[:idx], filename[idx:]
    return filename, ""


def entry_kind(path, is_dir=False):
    if is_dir:
        return "dir"
    name = os.path.basename(path)
    lower = name.lower()
    for comp in ARCHIVE_COMPOUND_EXTS:
        if lower.endswith(comp):
            return "archive"
    dot = lower.rfind(".")
    ext = lower[dot + 1:] if dot > 0 else ""
    if ext in IMAGE_EXTS:
        return "image"
    if ext in VIDEO_EXTS:
        return "video"
    if ext in AUDIO_EXTS:
        return "audio"
    if ext in PDF_EXTS:
        return "pdf"
    if ext in ARCHIVE_EXTS:
        return "archive"
    if ext in MARKDOWN_EXTS:
        return "markdown"
    if ext in TABLE_EXTS:
        return "table"
    if ext in SQLITE_EXTS:
        return "sqlite"
    if ext in FONT_EXTS:
        return "font"
    if ext in CODE_EXTS or lower in CODE_NAMES:
        return "code"
    if ext in TEXT_EXTS or lower in TEXT_NAMES:
        return "text"
    return "file"


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
            target_info = child.stat(follow_symlinks=True) if not is_dir else info
        except OSError:
            continue
        full_path = os.path.join(path, child.name)
        kind = entry_kind(full_path, is_dir)
        mode_str = stat.filemode(info.st_mode)
        entries.append({
            "name": child.name,
            "path": full_path,
            "dir": is_dir,
            "kind": kind,
            "subkind": kind,
            "size": 0 if is_dir else target_info.st_size,
            "mtime": int(target_info.st_mtime),
            "mode": mode_str,
            "permissions": mode_str[1:],
            "isLink": stat.S_ISLNK(info.st_mode),
        })
    entries.sort(key=lambda item: (not item["dir"], item["name"].casefold()))
    emit(entries)


def detect_mime(path, is_dir):
    if is_dir:
        return "inode/directory"
    try:
        res = subprocess.run(["file", "--brief", "--mime-type", "--", path],
                             text=True, encoding="utf-8", errors="replace",
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
        if res.returncode == 0 and res.stdout.strip():
            return res.stdout.strip()
    except OSError:
        pass
    guessed, _ = mimetypes.guess_type(path)
    return guessed or "application/octet-stream"


def list_siblings(path, kind):
    if kind == "dir":
        return []
    parent = os.path.dirname(path)
    siblings = []
    try:
        with os.scandir(parent) as scanner:
            for child in scanner:
                if child.name.startswith("."):
                    continue
                try:
                    is_dir = child.is_dir(follow_symlinks=True)
                except OSError:
                    continue
                if is_dir:
                    continue
                full = os.path.join(parent, child.name)
                if entry_kind(full, False) == kind:
                    siblings.append((child.name.casefold(), full))
    except OSError:
        return [path]
    siblings.sort(key=lambda item: item[0])
    paths = [item[1] for item in siblings]
    if len(paths) > 200:
        if path in paths:
            idx = paths.index(path)
            start = max(0, min(idx - 100, len(paths) - 200))
            paths = paths[start:start + 200]
        else:
            paths = paths[:200]
    return paths


def inspect_text_file(path, max_lines=400):
    lines = []
    total = 0
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                total += 1
                if total <= max_lines:
                    lines.append(line.rstrip("\r\n"))
    except OSError:
        return "", 0, False
    return "\n".join(lines), total, total > max_lines


def inspect_table(path):
    lower = path.lower()
    default_delim = "\t" if lower.endswith(".tsv") else ","
    headers = []
    rows = []
    total_rows = 0
    try:
        with open(path, "r", encoding="utf-8", errors="replace", newline="") as f:
            sample = f.read(4096)
            f.seek(0)
            delim = default_delim
            if not lower.endswith(".tsv"):
                try:
                    dialect = csv.Sniffer().sniff(sample, delimiters=",;\t|")
                    delim = dialect.delimiter
                except csv.Error:
                    delim = default_delim
            reader = csv.reader(f, delimiter=delim)
            for idx, row in enumerate(reader):
                if idx == 0:
                    headers = [str(cell) for cell in row]
                else:
                    total_rows += 1
                    if len(rows) < 100:
                        rows.append([str(cell) for cell in row])
    except OSError:
        pass
    preview, line_count, _ = inspect_text_file(path, 100)
    return {
        "headers": headers,
        "rows": rows,
        "row_count": total_rows,
        "truncated": total_rows > 100,
        "text_preview": preview,
        "line_count": line_count,
    }


def inspect_sqlite(path, requested_table=""):
    tables = []
    active_table = ""
    headers = []
    rows = []
    try:
        uri = "file:" + path.replace("?", "%3F").replace("#", "%23") + "?mode=ro"
        conn = sqlite3.connect(uri, uri=True)
        try:
            cur = conn.cursor()
            cur.execute("SELECT name FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name")
            tables = [str(r[0]) for r in cur.fetchall() if r and r[0]]
            if requested_table and requested_table in tables:
                active_table = requested_table
            elif tables:
                active_table = tables[0]
            if active_table:
                safe_tbl = active_table.replace('"', '""')
                cur.execute(f'SELECT * FROM "{safe_tbl}" LIMIT 100')
                headers = [str(col[0]) for col in (cur.description or [])]
                for r in cur.fetchall():
                    rows.append(["" if val is None else str(val) for val in r])
        finally:
            conn.close()
    except Exception:
        pass
    return {
        "tables": tables,
        "active_table": active_table,
        "headers": headers,
        "rows": rows,
    }


def inspect_archive(path):
    entries = []
    total = 0
    lower = path.lower()
    try:
        if lower.endswith(".zip") and zipfile.is_zipfile(path):
            with zipfile.ZipFile(path, "r") as zf:
                infos = zf.infolist()
                total = len(infos)
                for info in infos[:200]:
                    is_dir = info.is_dir() if hasattr(info, "is_dir") else info.filename.endswith("/")
                    entries.append({
                        "name": info.filename.rstrip("/") if is_dir else info.filename,
                        "size": 0 if is_dir else int(info.file_size or 0),
                        "is_dir": bool(is_dir),
                    })
            return {"archive_entries": entries, "total_entries": total}
        if any(lower.endswith(ext) for ext in (".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz")):
            with tarfile.open(path, "r:*") as tf:
                for member in tf:
                    total += 1
                    if len(entries) < 200:
                        is_dir = member.isdir()
                        entries.append({
                            "name": member.name.rstrip("/") if is_dir else member.name,
                            "size": 0 if is_dir else int(member.size or 0),
                            "is_dir": bool(is_dir),
                        })
            return {"archive_entries": entries, "total_entries": total}
    except Exception:
        entries = []
        total = 0

    if shutil.which("bsdtar"):
        res = subprocess.run(["bsdtar", "-tvf", path], text=True, encoding="utf-8", errors="replace",
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                line = line.strip()
                if not line:
                    continue
                total += 1
                if len(entries) < 200:
                    parts = line.split(None, 8)
                    if len(parts) >= 9:
                        mode_s, _, _, _, size_s, _, _, _, name_s = parts
                        is_dir = mode_s.startswith("d") or name_s.endswith("/")
                        try:
                            sz = int(size_s)
                        except ValueError:
                            sz = 0
                        entries.append({
                            "name": name_s.rstrip("/") if is_dir else name_s,
                            "size": 0 if is_dir else sz,
                            "is_dir": is_dir,
                        })
                    else:
                        is_dir = line.endswith("/")
                        entries.append({"name": line.rstrip("/"), "size": 0, "is_dir": is_dir})
            return {"archive_entries": entries, "total_entries": total}

    if shutil.which("7z"):
        res = subprocess.run(["7z", "l", "-ba", path], text=True, encoding="utf-8", errors="replace",
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                if len(line) > 53:
                    attr = line[20:25]
                    size_s = line[26:38].strip()
                    name_s = line[53:].strip()
                    if not name_s:
                        continue
                    total += 1
                    if len(entries) < 200:
                        is_dir = "D" in attr
                        try:
                            sz = int(size_s)
                        except ValueError:
                            sz = 0
                        entries.append({"name": name_s, "size": 0 if is_dir else sz, "is_dir": is_dir})

    return {"archive_entries": entries, "total_entries": total}


def inspect_pdf(path, mtime, extra_arg):
    try:
        page = max(1, int(extra_arg)) if extra_arg else 1
    except ValueError:
        page = 1

    page_count = 0
    if shutil.which("pdfinfo"):
        res = subprocess.run(["pdfinfo", path], text=True, encoding="utf-8", errors="replace",
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
        if res.returncode == 0:
            m = re.search(r"^Pages:\s*(\d+)", res.stdout, re.MULTILINE)
            if m:
                page_count = int(m.group(1))
    if page_count <= 0 and shutil.which("mutool"):
        res = subprocess.run(["mutool", "info", path], text=True, encoding="utf-8", errors="replace",
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
        if res.returncode == 0:
            m = re.search(r"^Pages:\s*(\d+)", res.stdout, re.MULTILINE)
            if m:
                page_count = int(m.group(1))
    if page_count <= 0:
        try:
            with open(path, "rb") as f:
                data = f.read(512 * 1024)
            counts = [int(x) for x in re.findall(rb"/Count\s+(\d+)", data)]
            if counts:
                page_count = max(counts)
        except OSError:
            pass
    if page_count <= 0:
        page_count = 1
    page = min(page, page_count)

    key = hashlib.sha1(f"{path}:{mtime}".encode("utf-8", errors="replace")).hexdigest()
    out_dir = cache_dir("doc-preview", key)
    out_png = os.path.join(out_dir, f"page-{page}.png")
    out_prefix = os.path.join(out_dir, f"page-{page}")

    if not os.path.isfile(out_png):
        if shutil.which("pdftoppm"):
            subprocess.run(["pdftoppm", "-png", "-r", "140", "-f", str(page), "-l", str(page),
                            "-singlefile", path, out_prefix],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        if not os.path.isfile(out_png) and shutil.which("mutool"):
            subprocess.run(["mutool", "draw", "-o", out_png, "-r", "140", path, str(page)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        if not os.path.isfile(out_png) and shutil.which("magick"):
            subprocess.run(["magick", "-density", "140", f"{path}[{page - 1}]", out_png],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        if not os.path.isfile(out_png) and shutil.which("ffmpeg"):
            subprocess.run(["ffmpeg", "-nostdin", "-y", "-v", "error", "-i", path, "-frames:v", "1", out_png],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

    extracted_text = ""
    if shutil.which("pdftotext"):
        res = subprocess.run(["pdftotext", "-f", str(page), "-l", str(page), path, "-"],
                             text=True, encoding="utf-8", errors="replace",
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
        if res.returncode == 0:
            extracted_text = res.stdout.strip()

    return {
        "pdf_page": page,
        "pdf_pages": page_count,
        "preview_image": out_png if os.path.isfile(out_png) else "",
        "text_preview": extracted_text,
    }


def inspect_media(path, mtime, kind):
    media_info = {
        "duration": 0.0,
        "width": 0,
        "height": 0,
        "video_codec": "",
        "audio_codec": "",
        "sample_rate": 0,
        "channels": 0,
        "bit_rate": 0,
        "title": "",
        "artist": "",
        "album": "",
    }
    if shutil.which("ffprobe"):
        res = subprocess.run(
            ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", path],
            text=True, encoding="utf-8", errors="replace",
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False
        )
        if res.returncode == 0 and res.stdout.strip():
            try:
                data = json.loads(res.stdout)
                fmt = data.get("format") or {}
                if fmt.get("duration"):
                    try:
                        media_info["duration"] = round(float(fmt["duration"]), 3)
                    except (ValueError, TypeError):
                        pass
                if fmt.get("bit_rate"):
                    try:
                        media_info["bit_rate"] = int(fmt["bit_rate"])
                    except (ValueError, TypeError):
                        pass
                tags = {str(k).lower(): str(v) for k, v in (fmt.get("tags") or {}).items()}
                media_info["title"] = tags.get("title", "")
                media_info["artist"] = tags.get("artist", "")
                media_info["album"] = tags.get("album", "")

                for stream in data.get("streams") or []:
                    stype = stream.get("codec_type")
                    if stype == "video" and not media_info["video_codec"]:
                        media_info["width"] = int(stream.get("width") or 0)
                        media_info["height"] = int(stream.get("height") or 0)
                        media_info["video_codec"] = str(stream.get("codec_name") or "")
                    elif stype == "audio" and not media_info["audio_codec"]:
                        media_info["audio_codec"] = str(stream.get("codec_name") or "")
                        try:
                            media_info["sample_rate"] = int(stream.get("sample_rate") or 0)
                        except (ValueError, TypeError):
                            pass
                        try:
                            media_info["channels"] = int(stream.get("channels") or 0)
                        except (ValueError, TypeError):
                            pass
                        if not media_info["bit_rate"] and stream.get("bit_rate"):
                            try:
                                media_info["bit_rate"] = int(stream["bit_rate"])
                            except (ValueError, TypeError):
                                pass
                        stags = {str(k).lower(): str(v) for k, v in (stream.get("tags") or {}).items()}
                        if not media_info["title"]:
                            media_info["title"] = stags.get("title", "")
                        if not media_info["artist"]:
                            media_info["artist"] = stags.get("artist", "")
                        if not media_info["album"]:
                            media_info["album"] = stags.get("album", "")
            except ValueError:
                pass

    preview_image = path if kind == "image" else ""
    if kind in ("video", "audio") and shutil.which("ffmpeg"):
        key = hashlib.sha1(f"{path}:{mtime}".encode("utf-8", errors="replace")).hexdigest()
        thumb = os.path.join(cache_dir("thumbs"), f"{key}.jpg")
        if not os.path.isfile(thumb):
            cmd = ["ffmpeg", "-nostdin", "-y", "-v", "error"]
            if kind == "video":
                cmd += ["-ss", "1"]
            cmd += ["-i", path, "-frames:v", "1", "-vf", "scale=320:-1", thumb]
            subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            if not os.path.isfile(thumb) and kind == "video":
                subprocess.run(
                    ["ffmpeg", "-nostdin", "-y", "-v", "error", "-i", path, "-frames:v", "1", "-vf", "scale=320:-1", thumb],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False
                )
        if os.path.isfile(thumb):
            preview_image = thumb

    return {
        "media_info": media_info,
        "preview_image": preview_image,
    }


def inspect_path(raw_path, extra_arg=""):
    path = expand_path(raw_path)
    if not os.path.lexists(path):
        fail(f"Путь не найден: {path}")
    try:
        info = os.stat(path, follow_symlinks=True)
        is_dir = stat.S_ISDIR(info.st_mode)
    except OSError:
        info = os.lstat(path)
        is_dir = False

    kind = entry_kind(path, is_dir)
    mode_str = stat.filemode(info.st_mode)
    result = {
        "name": os.path.basename(path) or path,
        "path": path,
        "parent": os.path.dirname(path),
        "dir": is_dir,
        "kind": kind,
        "subkind": kind,
        "size": 0 if is_dir else int(info.st_size),
        "mtime": int(info.st_mtime),
        "mode": mode_str,
        "permissions": mode_str[1:],
        "mime": detect_mime(path, is_dir),
        "siblings": list_siblings(path, kind),
    }

    if kind in ("code", "text", "markdown"):
        preview, line_count, truncated = inspect_text_file(path, 400)
        result["text_preview"] = preview
        result["line_count"] = line_count
        result["truncated"] = truncated
    elif kind == "table":
        result.update(inspect_table(path))
    elif kind == "sqlite":
        result.update(inspect_sqlite(path, extra_arg))
    elif kind == "archive":
        result.update(inspect_archive(path))
    elif kind == "pdf":
        result.update(inspect_pdf(path, int(info.st_mtime), extra_arg))
    elif kind in ("audio", "video", "image"):
        result.update(inspect_media(path, int(info.st_mtime), kind))
    elif kind == "file" and not is_dir and info.st_size <= 2 * 1024 * 1024:
        try:
            with open(path, "rb") as f:
                chunk = f.read(4096)
            if b"\x00" not in chunk:
                preview, line_count, truncated = inspect_text_file(path, 400)
                result["text_preview"] = preview
                result["line_count"] = line_count
                result["truncated"] = truncated
        except OSError:
            pass

    emit(result)


def unique_dest_path(dest_dir, basename):
    candidate = os.path.join(dest_dir, basename)
    if not os.path.lexists(candidate):
        return candidate
    stem, ext = split_stem_ext(basename)
    candidate = os.path.join(dest_dir, f"{stem} (copy){ext}")
    idx = 2
    while os.path.lexists(candidate):
        candidate = os.path.join(dest_dir, f"{stem} (copy {idx}){ext}")
        idx += 1
    return candidate


def copy_items(raw_dest, raw_sources):
    dest_dir = expand_path(raw_dest)
    if not os.path.isdir(dest_dir):
        fail(f"Папка назначения не найдена: {dest_dir}")
    count = 0
    for raw_src in raw_sources:
        src = expand_path(raw_src)
        if not os.path.lexists(src):
            fail(f"Источник не найден: {src}")
        target = unique_dest_path(dest_dir, os.path.basename(src))
        try:
            if os.path.isdir(src) and not os.path.islink(src):
                shutil.copytree(src, target, symlinks=True)
            else:
                shutil.copy2(src, target, follow_symlinks=False)
            count += 1
        except OSError as error:
            fail(f"Не удалось скопировать «{src}»: {error.strerror or error}.")
    emit({"ok": True, "count": count})


def move_items(raw_dest, raw_sources):
    dest_dir = expand_path(raw_dest)
    if not os.path.isdir(dest_dir):
        fail(f"Папка назначения не найдена: {dest_dir}")
    count = 0
    for raw_src in raw_sources:
        src = expand_path(raw_src)
        if not os.path.lexists(src):
            fail(f"Источник не найден: {src}")
        default_target = os.path.join(dest_dir, os.path.basename(src))
        if os.path.abspath(src) == os.path.abspath(default_target):
            count += 1
            continue
        target = unique_dest_path(dest_dir, os.path.basename(src))
        try:
            shutil.move(src, target)
            count += 1
        except OSError as error:
            fail(f"Не удалось переместить «{src}»: {error.strerror or error}.")
    emit({"ok": True, "count": count})


def extract_archive(raw_archive, raw_dest=""):
    archive_path = expand_path(raw_archive)
    if not os.path.isfile(archive_path):
        fail(f"Архив не найден: {archive_path}")
    dest_base = expand_path(raw_dest) if raw_dest else os.path.dirname(archive_path)
    os.makedirs(dest_base, exist_ok=True)
    stem, _ = split_stem_ext(os.path.basename(archive_path))
    target_dir = unique_dest_path(dest_base, stem or "extracted")
    os.makedirs(target_dir, exist_ok=True)

    lower = archive_path.lower()
    extracted = False
    try:
        if lower.endswith(".zip") and zipfile.is_zipfile(archive_path):
            with zipfile.ZipFile(archive_path, "r") as zf:
                for member in zf.infolist():
                    dest_member = os.path.abspath(os.path.join(target_dir, member.filename))
                    if dest_member == target_dir or dest_member.startswith(target_dir + os.sep):
                        zf.extract(member, target_dir)
            extracted = True
        elif any(lower.endswith(ext) for ext in (".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz")):
            with tarfile.open(archive_path, "r:*") as tf:
                for member in tf.getmembers():
                    dest_member = os.path.abspath(os.path.join(target_dir, member.name))
                    if dest_member == target_dir or dest_member.startswith(target_dir + os.sep):
                        tf.extract(member, target_dir)
            extracted = True
    except Exception:
        extracted = False

    if not extracted and shutil.which("bsdtar"):
        res = subprocess.run(["bsdtar", "-xf", archive_path, "-C", target_dir],
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, check=False)
        if res.returncode == 0:
            extracted = True

    if not extracted and shutil.which("7z"):
        res = subprocess.run(["7z", "x", "-y", f"-o{target_dir}", archive_path],
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, check=False)
        if res.returncode == 0:
            extracted = True

    if not extracted:
        try:
            shutil.unpack_archive(archive_path, target_dir)
            extracted = True
        except Exception as error:
            shutil.rmtree(target_dir, ignore_errors=True)
            fail(f"Не удалось распаковать архив: {error}")

    emit({"ok": True, "path": target_dir})


def compress_archive(raw_archive, raw_sources):
    if not raw_sources:
        fail("Укажите файлы для упаковки.", 2)
    sources = [expand_path(s) for s in raw_sources]
    for src in sources:
        if not os.path.lexists(src):
            fail(f"Файл не найден: {src}")
    archive_path = os.path.expanduser(str(raw_archive))
    if not os.path.isabs(archive_path):
        archive_path = os.path.abspath(os.path.join(os.path.dirname(sources[0]), archive_path))
    if "." not in os.path.basename(archive_path):
        archive_path += ".zip"
    os.makedirs(os.path.dirname(archive_path), exist_ok=True)

    lower = archive_path.lower()
    try:
        if lower.endswith(".zip"):
            with zipfile.ZipFile(archive_path, "w", zipfile.ZIP_DEFLATED) as zf:
                for src in sources:
                    base_name = os.path.basename(src)
                    if os.path.isdir(src) and not os.path.islink(src):
                        for root, dirs, files in os.walk(src):
                            rel_root = os.path.relpath(root, os.path.dirname(src))
                            if not files and not dirs:
                                zf.writestr(rel_root.rstrip("/") + "/", "")
                            for fname in files:
                                full_f = os.path.join(root, fname)
                                arc_f = os.path.join(rel_root, fname)
                                if os.path.isfile(full_f):
                                    zf.write(full_f, arc_f)
                    else:
                        zf.write(src, base_name)
        elif any(lower.endswith(ext) for ext in (".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz", ".tar")):
            mode = "w"
            if lower.endswith((".tar.gz", ".tgz")):
                mode = "w:gz"
            elif lower.endswith((".tar.bz2", ".tbz2")):
                mode = "w:bz2"
            elif lower.endswith((".tar.xz", ".txz")):
                mode = "w:xz"
            with tarfile.open(archive_path, mode) as tf:
                for src in sources:
                    tf.add(src, arcname=os.path.basename(src))
        elif shutil.which("bsdtar"):
            cmd = ["bsdtar", "-a", "-cf", archive_path]
            for src in sources:
                cmd += ["-C", os.path.dirname(src), os.path.basename(src)]
            run_tool(cmd)
        else:
            with zipfile.ZipFile(archive_path, "w", zipfile.ZIP_DEFLATED) as zf:
                for src in sources:
                    zf.write(src, os.path.basename(src))
    except Exception as error:
        fail(f"Не удалось создать архив: {error}")

    emit({"ok": True, "path": archive_path})


def install_font(raw_font):
    font_path = expand_path(raw_font)
    if not os.path.isfile(font_path):
        fail(f"Файл шрифта не найден: {font_path}")
    ext = os.path.splitext(font_path)[1].lower().lstrip(".")
    if ext not in FONT_EXTS:
        fail("Поддерживаются только шрифты .ttf, .otf, .ttc, .woff, .woff2.", 2)
    data_home = os.environ.get("XDG_DATA_HOME") or os.path.join(home_dir(), ".local", "share")
    dest_dir = os.path.join(data_home, "fonts", "oberon")
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, os.path.basename(font_path))
    try:
        shutil.copy2(font_path, dest)
    except OSError as error:
        fail(f"Не удалось установить шрифт: {error.strerror or error}.")
    if shutil.which("fc-cache"):
        subprocess.run(["fc-cache", "-f", dest_dir],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    emit({"ok": True, "path": dest})


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


def trash_count(as_json=False):
    tdir = trash_dir()
    count = 0
    total_size = 0
    try:
        with os.scandir(tdir) as scanner:
            for entry in scanner:
                count += 1
                if as_json:
                    try:
                        total_size += entry.stat(follow_symlinks=False).st_size
                    except OSError:
                        pass
    except FileNotFoundError:
        count = 0
    except OSError as error:
        fail(f"Не удалось прочитать корзину: {error.strerror or error}.")
    if as_json:
        emit({"count": count, "size": total_size})
    else:
        print(count)


def trash_items(raw_paths):
    paths = [expand_path(p) for p in raw_paths]
    if shutil.which("gio"):
        res = subprocess.run(["gio", "trash"] + paths, text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        if res.returncode == 0:
            return
    tdir = trash_dir()
    os.makedirs(tdir, exist_ok=True)
    for p in paths:
        if not os.path.lexists(p):
            fail(f"Путь не найден: {p}")
        target = unique_dest_path(tdir, os.path.basename(p))
        shutil.move(p, target)


def empty_trash():
    if shutil.which("gio"):
        subprocess.run(["gio", "trash", "--empty"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    tdir = trash_dir()
    idir = os.path.join(os.path.dirname(tdir), "info")
    for d in (tdir, idir):
        if os.path.isdir(d):
            for name in os.listdir(d):
                full = os.path.join(d, name)
                try:
                    if os.path.isdir(full) and not os.path.islink(full):
                        shutil.rmtree(full)
                    else:
                        os.unlink(full)
                except OSError:
                    pass


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
        fail("Использование: files.sh {places|list|inspect|disks|mount|eject|trash|emptytrash|trashcount|rename|mkdir|copy|move|extract|compress|install-font} ...", 2)
    action, *values = args

    if action == "places" and not values:
        list_places()
    elif action == "list" and len(values) <= 1:
        list_directory(values[0] if values else home_dir())
    elif action == "inspect" and 1 <= len(values) <= 2:
        inspect_path(values[0], values[1] if len(values) > 1 else "")
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
        trash_items(values)
    elif action in ("emptytrash", "empty-trash") and not values:
        empty_trash()
    elif action == "trashcount" and not values:
        trash_count(as_json=False)
    elif action == "trash-info" and not values:
        trash_count(as_json=True)
    elif action == "rename" and len(values) == 2:
        source = expand_path(values[0])
        name = safe_name(os.path.basename(values[1]) if "/" in values[1] else values[1])
        if not os.path.lexists(source):
            fail(f"Путь не найден: {source}")
        destination = os.path.join(os.path.dirname(source), name)
        if os.path.lexists(destination):
            fail(f"Уже существует: {destination}")
        try:
            os.rename(source, destination)
        except OSError as error:
            fail(f"Не удалось переименовать: {error.strerror or error}.")
    elif action == "mkdir" and 1 <= len(values) <= 2:
        if len(values) == 2:
            target = os.path.join(expand_path(values[0]), safe_name(values[1]))
        else:
            target = expand_path(values[0])
        try:
            os.mkdir(target)
        except OSError as error:
            fail(f"Не удалось создать папку: {error.strerror or error}.")
    elif action == "copy" and len(values) >= 2:
        copy_items(values[0], values[1:])
    elif action == "move" and len(values) >= 2:
        move_items(values[0], values[1:])
    elif action == "extract" and 1 <= len(values) <= 2:
        extract_archive(values[0], values[1] if len(values) > 1 else "")
    elif action == "compress" and len(values) >= 2:
        compress_archive(values[0], values[1:])
    elif action == "install-font" and len(values) == 1:
        install_font(values[0])
    else:
        fail("Неверные аргументы команды files.sh.", 2)


main(sys.argv[1:])
PY
else
exec perl -CSD - "$@" <<'PL'
use strict;
use warnings;
use utf8;
use JSON::PP qw(encode_json decode_json);
use File::Basename qw(basename dirname);
use File::Path qw(make_path remove_tree);
use File::Copy qw(copy move);
use File::Spec;
use Cwd qw(abs_path getcwd);
use Digest::SHA qw(sha1_hex);
use Fcntl ':mode';

my @ARCHIVE_COMPOUND = ('.tar.gz', '.tar.bz2', '.tar.xz', '.tar.zst', '.tar.lz', '.tar.lz4');
my %ARCHIVE_EXTS = map { $_ => 1 } qw(zip tar tgz tbz tbz2 txz tzst 7z rar gz bz2 xz zst iso);
my %IMAGE_EXTS = map { $_ => 1 } qw(png jpg jpeg gif webp bmp tif tiff avif svg ico heic heif jxl ppm pgm pbm);
my %VIDEO_EXTS = map { $_ => 1 } qw(mp4 mkv webm mov avi m4v wmv flv mpg mpeg ts m2ts ogv 3gp);
my %AUDIO_EXTS = map { $_ => 1 } qw(mp3 flac ogg opus wav m4a aac wma ape alac aiff mid midi);
my %PDF_EXTS = map { $_ => 1 } qw(pdf);
my %MARKDOWN_EXTS = map { $_ => 1 } qw(md markdown mdx rst);
my %TABLE_EXTS = map { $_ => 1 } qw(csv tsv);
my %SQLITE_EXTS = map { $_ => 1 } qw(sqlite db sqlite3 db3);
my %FONT_EXTS = map { $_ => 1 } qw(ttf otf woff woff2 ttc);
my %CODE_EXTS = map { $_ => 1 } qw(
    py sh bash zsh fish js mjs cjs ts tsx jsx qml c h cpp hpp cc cxx rs go java kt swift
    rb php pl pm lua sql html htm css scss less json jsonc yaml yml toml ini conf cfg xml
    vim el hs ml zig nim cmake mk dockerfile service timer desktop gradle vue svelte
);
my %CODE_NAMES = map { $_ => 1 } ('makefile', 'dockerfile', 'cmakelists.txt', 'pkgbuild', '.bashrc', '.zshrc', '.profile', '.gitignore');
my %TEXT_EXTS = map { $_ => 1 } qw(txt log text nfo sub srt vtt ass env license);
my %TEXT_NAMES = map { $_ => 1 } qw(license readme authors changelog todo copying);

sub fail {
    my ($msg, $code) = @_;
    $code //= 1;
    print STDERR "files.sh: $msg\n";
    exit $code;
}

sub emit {
    my ($val) = @_;
    my $coder = JSON::PP->new->utf8(0);
    print $coder->encode($val), "\n";
}

sub home_dir {
    return $ENV{HOME} || '/root';
}

sub cache_dir {
    my @parts = @_;
    my $base = $ENV{XDG_CACHE_HOME} || File::Spec->catdir(home_dir(), '.cache');
    my $dir = File::Spec->catdir($base, 'oberon', @parts);
    make_path($dir);
    return $dir;
}

sub expand_path {
    my ($val) = @_;
    $val //= '';
    my $home = home_dir();
    $val =~ s/^~(?=\/|$)/$home/;
    if ($val !~ m{^/}) {
        $val = File::Spec->catfile(getcwd(), $val);
    }
    my @parts;
    for my $p (split m{/}, $val) {
        next if $p eq '' || $p eq '.';
        if ($p eq '..') {
            pop @parts if @parts;
        } else {
            push @parts, $p;
        }
    }
    return '/' . join('/', @parts);
}

sub split_stem_ext {
    my ($name) = @_;
    my $lower = lc($name);
    for my $comp (@ARCHIVE_COMPOUND) {
        if (length($name) > length($comp) && substr($lower, -length($comp)) eq $comp) {
            return (substr($name, 0, length($name) - length($comp)), substr($name, -length($comp)));
        }
    }
    if ($name =~ /^(..*?)(\.[^.]+)$/ && $name !~ /^\.[^.]+$/) {
        return ($1, $2);
    }
    return ($name, '');
}

sub entry_kind {
    my ($path, $is_dir) = @_;
    return 'dir' if $is_dir;
    my $name = basename($path);
    my $lower = lc($name);
    for my $comp (@ARCHIVE_COMPOUND) {
        return 'archive' if substr($lower, -length($comp)) eq $comp;
    }
    my $ext = '';
    if ($lower =~ /\.([^.]+)$/ && $lower !~ /^\.[^.]+$/) {
        $ext = $1;
    }
    return 'image'    if $IMAGE_EXTS{$ext};
    return 'video'    if $VIDEO_EXTS{$ext};
    return 'audio'    if $AUDIO_EXTS{$ext};
    return 'pdf'      if $PDF_EXTS{$ext};
    return 'archive'  if $ARCHIVE_EXTS{$ext};
    return 'markdown' if $MARKDOWN_EXTS{$ext};
    return 'table'    if $TABLE_EXTS{$ext};
    return 'sqlite'   if $SQLITE_EXTS{$ext};
    return 'font'     if $FONT_EXTS{$ext};
    return 'code'     if $CODE_EXTS{$ext} || $CODE_NAMES{$lower};
    return 'text'     if $TEXT_EXTS{$ext} || $TEXT_NAMES{$lower};
    return 'file';
}

sub format_mode {
    my ($mode) = @_;
    my $type = '-';
    if (S_ISDIR($mode))  { $type = 'd'; }
    elsif (S_ISLNK($mode)) { $type = 'l'; }
    elsif (S_ISCHR($mode)) { $type = 'c'; }
    elsif (S_ISBLK($mode)) { $type = 'b'; }
    elsif (S_ISFIFO($mode)){ $type = 'p'; }
    elsif (S_ISSOCK($mode)){ $type = 's'; }
    my $perms = '';
    $perms .= ($mode & S_IRUSR) ? 'r' : '-';
    $perms .= ($mode & S_IWUSR) ? 'w' : '-';
    $perms .= ($mode & S_IXUSR) ? 'x' : '-';
    $perms .= ($mode & S_IRGRP) ? 'r' : '-';
    $perms .= ($mode & S_IWGRP) ? 'w' : '-';
    $perms .= ($mode & S_IXGRP) ? 'x' : '-';
    $perms .= ($mode & S_IROTH) ? 'r' : '-';
    $perms .= ($mode & S_IWOTH) ? 'w' : '-';
    $perms .= ($mode & S_IXOTH) ? 'x' : '-';
    return ($type . $perms, $perms);
}

sub has_cmd {
    my ($cmd) = @_;
    for my $dir (split /:/, $ENV{PATH} || '') {
        return 1 if -x "$dir/$cmd";
    }
    return 0;
}

sub run_capture {
    my (@cmd) = @_;
    open(my $fh, '-|', @cmd) or return ('', 1);
    local $/;
    my $out = <$fh> // '';
    close($fh);
    return ($out, $? >> 8);
}

sub list_places {
    my $home = home_dir();
    my @defaults = (
        ['Дом', $home],
        ['Документы', "$home/Documents"],
        ['Загрузки', "$home/Downloads"],
        ['Изображения', "$home/Pictures"],
        ['Видео', "$home/Videos"],
        ['Музыка', "$home/Music"],
        ['Рабочий стол', "$home/Desktop"],
    );
    my @places;
    my %seen;
    for my $item (@defaults) {
        my ($name, $p) = @$item;
        $p = expand_path($p);
        if (!$seen{$p} && -d $p) {
            push @places, { name => $name, path => $p };
            $seen{$p} = 1;
        }
    }
    emit(\@places);
}

sub list_directory {
    my ($raw) = @_;
    my $path = expand_path($raw);
    opendir(my $dh, $path) or fail("Не удалось прочитать папку «$path»: $!");
    my @names = readdir($dh);
    closedir($dh);

    my @entries;
    for my $name (@names) {
        next if $name =~ /^\./;
        my $full = $path eq '/' ? "/$name" : "$path/$name";
        my @lst = lstat($full);
        next unless @lst;
        my @st = stat($full);
        @st = @lst unless @st;
        my $is_dir = S_ISDIR($st[2]) ? JSON::PP::true : JSON::PP::false;
        my $is_link = S_ISLNK($lst[2]) ? JSON::PP::true : JSON::PP::false;
        my ($mode_str, $perms) = format_mode($lst[2]);
        my $kind = entry_kind($full, $is_dir ? 1 : 0);
        push @entries, {
            name        => $name,
            path        => $full,
            dir         => $is_dir,
            kind        => $kind,
            subkind     => $kind,
            size        => $is_dir ? 0 : int($st[7] || 0),
            mtime       => int($st[9] || 0),
            mode        => $mode_str,
            permissions => $perms,
            isLink      => $is_link,
        };
    }
    @entries = sort {
        (($b->{dir} ? 1 : 0) <=> ($a->{dir} ? 1 : 0))
        || (lc($a->{name}) cmp lc($b->{name}))
    } @entries;
    emit(\@entries);
}

sub parse_csv_line {
    my ($line, $delim) = @_;
    $line =~ s/\r?\n$//;
    my @fields;
    my $cur = '';
    my $in_quotes = 0;
    my $len = length($line);
    for (my $i = 0; $i < $len; $i++) {
        my $ch = substr($line, $i, 1);
        if ($in_quotes) {
            if ($ch eq '"') {
                if ($i + 1 < $len && substr($line, $i + 1, 1) eq '"') {
                    $cur .= '"';
                    $i++;
                } else {
                    $in_quotes = 0;
                }
            } else {
                $cur .= $ch;
            }
        } else {
            if ($ch eq '"') {
                $in_quotes = 1;
            } elsif ($ch eq $delim) {
                push @fields, $cur;
                $cur = '';
            } else {
                $cur .= $ch;
            }
        }
    }
    push @fields, $cur;
    return \@fields;
}

sub inspect_path {
    my ($raw, $extra) = @_;
    $extra //= '';
    my $path = expand_path($raw);
    my @lst = lstat($path);
    fail("Путь не найден: $path") unless @lst;
    my @st = stat($path);
    @st = @lst unless @st;
    my $is_dir = S_ISDIR($st[2]) ? 1 : 0;
    my $kind = entry_kind($path, $is_dir);
    my ($mode_str, $perms) = format_mode($st[2]);

    my $mime = $is_dir ? 'inode/directory' : 'application/octet-stream';
    if (!$is_dir && has_cmd('file')) {
        my ($out, $rc) = run_capture('file', '--brief', '--mime-type', '--', $path);
        if ($rc == 0 && $out =~ /\S/) {
            $out =~ s/^\s+|\s+$//g;
            $mime = $out;
        }
    }

    my $parent = dirname($path);
    my @siblings;
    if (!$is_dir && opendir(my $dh, $parent)) {
        while (defined(my $n = readdir($dh))) {
            next if $n =~ /^\./;
            my $f = $parent eq '/' ? "/$n" : "$parent/$n";
            next if -d $f;
            if (entry_kind($f, 0) eq $kind) {
                push @siblings, $f;
            }
        }
        closedir($dh);
        @siblings = sort { lc(basename($a)) cmp lc(basename($b)) } @siblings;
        if (@siblings > 200) {
            @siblings = @siblings[0..199];
        }
    }

    my %res = (
        name        => basename($path) || $path,
        path        => $path,
        parent      => $parent,
        dir         => $is_dir ? JSON::PP::true : JSON::PP::false,
        kind        => $kind,
        subkind     => $kind,
        size        => $is_dir ? 0 : int($st[7] || 0),
        mtime       => int($st[9] || 0),
        mode        => $mode_str,
        permissions => $perms,
        mime        => $mime,
        siblings    => \@siblings,
    );

    if ($kind eq 'code' || $kind eq 'text' || $kind eq 'markdown') {
        my @lines;
        my $total = 0;
        if (open(my $fh, '<:utf8', $path)) {
            while (my $line = <$fh>) {
                $total++;
                if ($total <= 400) {
                    $line =~ s/\r?\n$//;
                    push @lines, $line;
                }
            }
            close($fh);
        }
        $res{text_preview} = join("\n", @lines);
        $res{line_count}   = $total;
        $res{truncated}    = $total > 400 ? JSON::PP::true : JSON::PP::false;
    } elsif ($kind eq 'table') {
        my $delim = ($path =~ /\.tsv$/i) ? "\t" : ",";
        my @headers;
        my @rows;
        my $total_rows = 0;
        my @preview_lines;
        if (open(my $fh, '<:utf8', $path)) {
            my $idx = 0;
            while (my $line = <$fh>) {
                if (@preview_lines < 100) {
                    my $pl = $line;
                    $pl =~ s/\r?\n$//;
                    push @preview_lines, $pl;
                }
                my $parsed = parse_csv_line($line, $delim);
                if ($idx == 0) {
                    @headers = @$parsed;
                } else {
                    $total_rows++;
                    push @rows, $parsed if @rows < 100;
                }
                $idx++;
            }
            close($fh);
        }
        $res{headers}      = \@headers;
        $res{rows}         = \@rows;
        $res{row_count}    = $total_rows;
        $res{truncated}    = $total_rows > 100 ? JSON::PP::true : JSON::PP::false;
        $res{text_preview} = join("\n", @preview_lines);
    } elsif ($kind eq 'sqlite') {
        my @tables;
        my $active = '';
        my @headers;
        my @rows;
        if (has_cmd('sqlite3')) {
            my ($tout, $trc) = run_capture('sqlite3', '-readonly', '-json', $path,
                "SELECT name FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name;");
            if ($trc == 0 && $tout =~ /\[/) {
                my $tarr = eval { decode_json($tout) } || [];
                @tables = map { $_->{name} } @$tarr;
            }
            if ($extra ne '' && grep { $_ eq $extra } @tables) {
                $active = $extra;
            } elsif (@tables) {
                $active = $tables[0];
            }
            if ($active ne '') {
                my $safe = $active;
                $safe =~ s/"/""/g;
                my ($pout, $prc) = run_capture('sqlite3', '-readonly', '-json', $path, qq{PRAGMA table_info("$safe");});
                if ($prc == 0 && $pout =~ /\[/) {
                    my $parr = eval { decode_json($pout) } || [];
                    @headers = map { $_->{name} } @$parr;
                }
                my ($rout, $rrc) = run_capture('sqlite3', '-readonly', '-json', $path, qq{SELECT * FROM "$safe" LIMIT 100;});
                if ($rrc == 0 && $rout =~ /\[/) {
                    my $rarr = eval { decode_json($rout) } || [];
                    if (!@headers && @$rarr) {
                        @headers = sort keys %{$rarr->[0]};
                    }
                    for my $r (@$rarr) {
                        push @rows, [ map { defined($r->{$_}) ? "$r->{$_}" : '' } @headers ];
                    }
                }
            }
        }
        $res{tables}       = \@tables;
        $res{active_table} = $active;
        $res{headers}      = \@headers;
        $res{rows}         = \@rows;
    } elsif ($kind eq 'archive') {
        my @entries;
        my $total = 0;
        if (has_cmd('bsdtar')) {
            my ($out, $rc) = run_capture('bsdtar', '-tvf', $path);
            if ($rc == 0) {
                for my $line (split /\n/, $out) {
                    next unless $line =~ /\S/;
                    $total++;
                    if (@entries < 200) {
                        my @p = split /\s+/, $line, 9;
                        if (@p >= 9) {
                            my $is_d = ($p[0] =~ /^d/ || $p[8] =~ m{/$}) ? 1 : 0;
                            my $nm = $p[8];
                            $nm =~ s{/$}{} if $is_d;
                            push @entries, {
                                name   => $nm,
                                size   => $is_d ? 0 : int($p[4] || 0),
                                is_dir => $is_d ? JSON::PP::true : JSON::PP::false,
                            };
                        }
                    }
                }
            }
        }
        $res{archive_entries} = \@entries;
        $res{total_entries}   = $total;
    } elsif ($kind eq 'pdf') {
        my $page = ($extra =~ /^\d+$/ && $extra > 0) ? int($extra) : 1;
        my $page_count = 0;
        if (open(my $fh, '<:raw', $path)) {
            read($fh, my $buf, 524288);
            close($fh);
            while ($buf =~ m{/Count\s+(\d+)}g) {
                $page_count = int($1) if int($1) > $page_count;
            }
        }
        $page_count = 1 if $page_count <= 0;
        $page = $page_count if $page > $page_count;
        my $key = sha1_hex("$path:$st[9]");
        my $odir = cache_dir('doc-preview', $key);
        my $opng = "$odir/page-$page.png";
        my $oprefix = "$odir/page-$page";
        if (!-f $opng && has_cmd('pdftoppm')) {
            run_capture('pdftoppm', '-png', '-r', '140', '-f', $page, '-l', $page, '-singlefile', $path, $oprefix);
        }
        my $txt = '';
        if (has_cmd('pdftotext')) {
            my ($tout, $trc) = run_capture('pdftotext', '-f', $page, '-l', $page, $path, '-');
            $txt = $tout if $trc == 0;
        }
        $res{pdf_page}      = $page;
        $res{pdf_pages}     = $page_count;
        $res{preview_image} = (-f $opng) ? $opng : '';
        $res{text_preview}  = $txt;
    } elsif ($kind eq 'audio' || $kind eq 'video' || $kind eq 'image') {
        my %minfo = (
            duration    => 0,
            width       => 0,
            height      => 0,
            video_codec => '',
            audio_codec => '',
            sample_rate => 0,
            channels    => 0,
            bit_rate    => 0,
            title       => '',
            artist      => '',
            album       => '',
        );
        if (has_cmd('ffprobe')) {
            my ($out, $rc) = run_capture('ffprobe', '-v', 'quiet', '-print_format', 'json', '-show_format', '-show_streams', $path);
            if ($rc == 0 && $out =~ /\{/) {
                my $d = eval { decode_json($out) } || {};
                my $fmt = $d->{format} || {};
                $minfo{duration} = 0 + sprintf("%.3f", $fmt->{duration}) if defined $fmt->{duration};
                $minfo{bit_rate} = int($fmt->{bit_rate}) if defined $fmt->{bit_rate};
                my $tags = $fmt->{tags} || {};
                for my $k (keys %$tags) {
                    $minfo{title}  = "$tags->{$k}" if lc($k) eq 'title';
                    $minfo{artist} = "$tags->{$k}" if lc($k) eq 'artist';
                    $minfo{album}  = "$tags->{$k}" if lc($k) eq 'album';
                }
                for my $s (@{$d->{streams} || []}) {
                    if (($s->{codec_type} // '') eq 'video' && !$minfo{video_codec}) {
                        $minfo{width}       = int($s->{width} || 0);
                        $minfo{height}      = int($s->{height} || 0);
                        $minfo{video_codec} = "$s->{codec_name}" if defined $s->{codec_name};
                    } elsif (($s->{codec_type} // '') eq 'audio' && !$minfo{audio_codec}) {
                        $minfo{audio_codec} = "$s->{codec_name}" if defined $s->{codec_name};
                        $minfo{sample_rate} = int($s->{sample_rate} || 0);
                        $minfo{channels}    = int($s->{channels} || 0);
                    }
                }
            }
        }
        my $preview = ($kind eq 'image') ? $path : '';
        if (($kind eq 'video' || $kind eq 'audio') && has_cmd('ffmpeg')) {
            my $key = sha1_hex("$path:$st[9]");
            my $thumb = File::Spec->catfile(cache_dir('thumbs'), "$key.jpg");
            if (!-f $thumb) {
                run_capture('ffmpeg', '-nostdin', '-y', '-v', 'error', '-ss', '1', '-i', $path, '-frames:v', '1', '-vf', 'scale=320:-1', $thumb);
            }
            $preview = $thumb if -f $thumb;
        }
        $res{media_info}    = \%minfo;
        $res{preview_image} = $preview;
    }

    emit(\%res);
}

sub unique_dest_path {
    my ($dest_dir, $basename) = @_;
    my $cand = "$dest_dir/$basename";
    return $cand unless -e $cand || -l $cand;
    my ($stem, $ext) = split_stem_ext($basename);
    $cand = "$dest_dir/$stem (copy)$ext";
    my $idx = 2;
    while (-e $cand || -l $cand) {
        $cand = "$dest_dir/$stem (copy $idx)$ext";
        $idx++;
    }
    return $cand;
}

sub copy_recursive {
    my ($src, $dst) = @_;
    if (-d $src && !-l $src) {
        make_path($dst);
        opendir(my $dh, $src) or fail("Не удалось открыть $src: $!");
        my @items = readdir($dh);
        closedir($dh);
        for my $item (@items) {
            next if $item eq '.' || $item eq '..';
            copy_recursive("$src/$item", "$dst/$item");
        }
    } else {
        copy($src, $dst) or fail("Не удалось скопировать $src: $!");
    }
}

sub copy_items {
    my ($raw_dest, @sources) = @_;
    my $dest_dir = expand_path($raw_dest);
    fail("Папка назначения не найдена: $dest_dir") unless -d $dest_dir;
    my $count = 0;
    for my $raw_src (@sources) {
        my $src = expand_path($raw_src);
        fail("Источник не найден: $src") unless -e $src || -l $src;
        my $target = unique_dest_path($dest_dir, basename($src));
        copy_recursive($src, $target);
        $count++;
    }
    emit({ ok => JSON::PP::true, count => $count });
}

sub move_items {
    my ($raw_dest, @sources) = @_;
    my $dest_dir = expand_path($raw_dest);
    fail("Папка назначения не найдена: $dest_dir") unless -d $dest_dir;
    my $count = 0;
    for my $raw_src (@sources) {
        my $src = expand_path($raw_src);
        fail("Источник не найден: $src") unless -e $src || -l $src;
        my $def_target = "$dest_dir/" . basename($src);
        if ($src eq $def_target) {
            $count++;
            next;
        }
        my $target = unique_dest_path($dest_dir, basename($src));
        if (!rename($src, $target)) {
            copy_recursive($src, $target);
            if (-d $src && !-l $src) {
                remove_tree($src);
            } else {
                unlink($src);
            }
        }
        $count++;
    }
    emit({ ok => JSON::PP::true, count => $count });
}

sub extract_archive {
    my ($raw_arch, $raw_dest) = @_;
    my $arch = expand_path($raw_arch);
    fail("Архив не найден: $arch") unless -f $arch;
    my $dest_base = ($raw_dest && $raw_dest ne '') ? expand_path($raw_dest) : dirname($arch);
    make_path($dest_base);
    my ($stem, undef) = split_stem_ext(basename($arch));
    my $target_dir = unique_dest_path($dest_base, $stem || 'extracted');
    make_path($target_dir);
    my ($out, $rc) = run_capture('bsdtar', '-xf', $arch, '-C', $target_dir);
    if ($rc != 0) {
        remove_tree($target_dir);
        fail("Не удалось распаковать архив: $arch");
    }
    emit({ ok => JSON::PP::true, path => $target_dir });
}

sub compress_archive {
    my ($raw_arch, @raw_sources) = @_;
    fail("Укажите файлы для упаковки.", 2) unless @raw_sources;
    my @sources = map { expand_path($_) } @raw_sources;
    for my $s (@sources) {
        fail("Файл не найден: $s") unless -e $s || -l $s;
    }
    my $arch = $raw_arch;
    my $home = home_dir();
    $arch =~ s/^~(?=\/|$)/$home/;
    if ($arch !~ m{^/}) {
        $arch = dirname($sources[0]) . "/$arch";
    }
    $arch = expand_path($arch);
    $arch .= '.zip' unless basename($arch) =~ /\./;
    make_path(dirname($arch));
    my @cmd = ('bsdtar', '-a', '-cf', $arch);
    for my $s (@sources) {
        push @cmd, '-C', dirname($s), basename($s);
    }
    my ($out, $rc) = run_capture(@cmd);
    fail("Не удалось создать архив: $arch") if $rc != 0;
    emit({ ok => JSON::PP::true, path => $arch });
}

sub install_font {
    my ($raw_font) = @_;
    my $font = expand_path($raw_font);
    fail("Файл шрифта не найден: $font") unless -f $font;
    my $ext = '';
    $ext = lc($1) if $font =~ /\.([^.]+)$/;
    fail("Поддерживаются только шрифты .ttf, .otf, .ttc, .woff, .woff2.", 2) unless $FONT_EXTS{$ext};
    my $data_home = $ENV{XDG_DATA_HOME} || (home_dir() . '/.local/share');
    my $dest_dir = "$data_home/fonts/oberon";
    make_path($dest_dir);
    my $dest = "$dest_dir/" . basename($font);
    copy($font, $dest) or fail("Не удалось установить шрифт: $!");
    if (has_cmd('fc-cache')) {
        run_capture('fc-cache', '-f', $dest_dir);
    }
    emit({ ok => JSON::PP::true, path => $dest });
}

sub mountable_disks {
    my ($out, $rc) = run_capture('lsblk', '--json', '--bytes', '--output', 'NAME,PATH,LABEL,SIZE,FSTYPE,MOUNTPOINTS,RM,TYPE');
    fail("Не удалось прочитать список дисков.") if $rc != 0;
    my $data = eval { decode_json($out) } || {};
    my $tree = $data->{blockdevices} || [];
    my @disks;
    my $walk;
    $walk = sub {
        my ($nodes, $inh_rm) = @_;
        for my $node (@{$nodes || []}) {
            my $kind = "$node->{type}";
            my $children = $node->{children} || [];
            my $rm_val = lc($node->{rm} // '0');
            my $rem = $inh_rm || ($rm_val eq '1' || $rm_val eq 'true' || $rm_val eq 'yes');
            my $pts = $node->{mountpoints};
            $pts = [$node->{mountpoint}] unless ref($pts) eq 'ARRAY';
            my $mp = '';
            for my $p (@$pts) {
                if (defined $p && $p ne '') { $mp = "$p"; last; }
            }
            my $has_part = grep { (($_->{type} // '') eq 'part') } @$children;
            my $show = ($kind eq 'part') || ($kind eq 'disk' && !$has_part);
            if ($show && $node->{path}) {
                my $name = $node->{name} || basename($node->{path});
                my $label = $node->{label} || $name;
                push @disks, {
                    name       => "$name",
                    path       => "$node->{path}",
                    label      => "$label",
                    size       => int($node->{size} || 0),
                    fstype     => "" . ($node->{fstype} // ''),
                    mountpoint => $mp,
                    removable  => $rem ? JSON::PP::true : JSON::PP::false,
                    mounted    => ($mp ne '') ? JSON::PP::true : JSON::PP::false,
                };
            }
            $walk->($children, $rem);
        }
    };
    $walk->($tree, 0);
    emit(\@disks);
}

sub trash_dir {
    my $data_home = $ENV{XDG_DATA_HOME} || (home_dir() . '/.local/share');
    return "$data_home/Trash/files";
}

sub trash_count {
    my ($as_json) = @_;
    my $tdir = trash_dir();
    my $count = 0;
    my $size = 0;
    if (opendir(my $dh, $tdir)) {
        while (defined(my $n = readdir($dh))) {
            next if $n eq '.' || $n eq '..';
            $count++;
            my @st = lstat("$tdir/$n");
            $size += int($st[7] || 0) if @st;
        }
        closedir($dh);
    }
    if ($as_json) {
        emit({ count => $count, size => $size });
    } else {
        print "$count\n";
    }
}

sub safe_name {
    my ($name) = @_;
    fail("Укажите корректное имя файла или папки.", 2)
        if !defined($name) || $name eq '' || $name eq '.' || $name eq '..' || $name =~ m{/|\0};
    return $name;
}

my $action = shift @ARGV // fail("Неверные аргументы команды files.sh.", 2);
if ($action eq 'places' && !@ARGV) {
    list_places();
} elsif ($action eq 'list' && @ARGV <= 1) {
    list_directory($ARGV[0] // home_dir());
} elsif ($action eq 'inspect' && @ARGV >= 1 && @ARGV <= 2) {
    inspect_path($ARGV[0], $ARGV[1] // '');
} elsif ($action eq 'disks' && !@ARGV) {
    mountable_disks();
} elsif ($action eq 'trashcount' && !@ARGV) {
    trash_count(0);
} elsif ($action eq 'trash-info' && !@ARGV) {
    trash_count(1);
} elsif (($action eq 'emptytrash' || $action eq 'empty-trash') && !@ARGV) {
    if (has_cmd('gio')) {
        run_capture('gio', 'trash', '--empty');
    }
    my $tdir = trash_dir();
    remove_tree($tdir, { keep_root => 1 }) if -d $tdir;
} elsif ($action eq 'trash' && @ARGV) {
    my @paths = map { expand_path($_) } @ARGV;
    my $ok = 0;
    if (has_cmd('gio')) {
        my (undef, $rc) = run_capture('gio', 'trash', @paths);
        $ok = ($rc == 0);
    }
    if (!$ok) {
        my $tdir = trash_dir();
        make_path($tdir);
        for my $p (@paths) {
            fail("Путь не найден: $p") unless -e $p || -l $p;
            my $dst = unique_dest_path($tdir, basename($p));
            rename($p, $dst) or move($p, $dst) or fail("Не удалось переместить в корзину: $p");
        }
    }
} elsif ($action eq 'rename' && @ARGV == 2) {
    my $src = expand_path($ARGV[0]);
    my $nm = safe_name($ARGV[1] =~ m{/} ? basename($ARGV[1]) : $ARGV[1]);
    fail("Путь не найден: $src") unless -e $src || -l $src;
    my $dst = dirname($src) . "/$nm";
    fail("Уже существует: $dst") if -e $dst || -l $dst;
    rename($src, $dst) or fail("Не удалось переименовать: $!");
} elsif ($action eq 'mkdir' && (@ARGV == 1 || @ARGV == 2)) {
    my $target = (@ARGV == 2) ? (expand_path($ARGV[0]) . "/" . safe_name($ARGV[1])) : expand_path($ARGV[0]);
    mkdir($target) or fail("Не удалось создать папку: $!");
} elsif ($action eq 'copy' && @ARGV >= 2) {
    copy_items($ARGV[0], @ARGV[1..$#ARGV]);
} elsif ($action eq 'move' && @ARGV >= 2) {
    move_items($ARGV[0], @ARGV[1..$#ARGV]);
} elsif ($action eq 'extract' && (@ARGV == 1 || @ARGV == 2)) {
    extract_archive($ARGV[0], $ARGV[1] // '');
} elsif ($action eq 'compress' && @ARGV >= 2) {
    compress_archive($ARGV[0], @ARGV[1..$#ARGV]);
} elsif ($action eq 'install-font' && @ARGV == 1) {
    install_font($ARGV[0]);
} else {
    fail("Неверные аргументы команды files.sh.", 2);
}
PL
fi
