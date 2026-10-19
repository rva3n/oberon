#!/usr/bin/env bash
# Oberon: Screen Region OCR + Live Translator -> JSON + wl-copy.
# Usage:
#   shot-translate.sh [target_lang] [existing_ocr_text]
set -u

target_lang="${1:-}"
has_existing=0
if [ $# -ge 2 ]; then
    existing_text="$2"
    has_existing=1
elif [ "${OBERON_OCR_TEXT+x}" = "x" ]; then
    existing_text="$OBERON_OCR_TEXT"
    has_existing=1
else
    existing_text=""
fi

if [ "$has_existing" -eq 1 ]; then
    ocr_text="$existing_text"
else
    sleep 0.2
    geom=$(slurp 2>/dev/null) || exit 2
    [ -n "$geom" ] || exit 2

    tmp=$(mktemp /tmp/oberon-shot-translate-XXXXXX.png)
    trap 'rm -f "$tmp"' EXIT

    if ! grim -g "$geom" "$tmp" 2>/dev/null; then
        printf '%s\n' '{"ok": false, "error": "Не удалось захватить выбранную область экрана"}'
        exit 1
    fi

    ocr_text=$(
        tesseract "$tmp" stdout -l rus+eng+jpn 2>/dev/null \
        || tesseract "$tmp" stdout -l rus+eng 2>/dev/null \
        || tesseract "$tmp" stdout 2>/dev/null \
        || true
    )
fi

OCR_RAW="$ocr_text" TARGET_LANG="$target_lang" python3 - "$target_lang" <<'PY'
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request


def clean_ocr_text(raw: str) -> str:
    if not raw:
        return ""
    text = raw.replace("\x0c", "").replace("\r\n", "\n").replace("\r", "\n")
    # Rejoin words split across lines with a hyphen
    text = re.sub(r"([A-Za-zА-Яа-яЁё])-\s*\n\s*([A-Za-zА-Яа-яЁё])", r"\1\2", text)
    # Split into paragraphs by blank lines, then collapse single line breaks inside paragraphs
    paragraphs = re.split(r"\n\s*\n+", text.strip())
    cleaned_paragraphs = []
    for p in paragraphs:
        lines = [ln.strip() for ln in p.splitlines() if ln.strip()]
        if not lines:
            continue
        merged = " ".join(lines)
        merged = re.sub(r"[ \t]{2,}", " ", merged).strip()
        if merged:
            cleaned_paragraphs.append(merged)
    return "\n\n".join(cleaned_paragraphs).strip()


def detect_languages(text: str, explicit_target: str):
    letters = [ch for ch in text if ch.isalpha()]
    total_letters = len(letters)
    cyrillic = sum(1 for ch in letters if ("\u0400" <= ch <= "\u04ff") or ("\u0500" <= ch <= "\u052f"))
    japanese = sum(1 for ch in text if ("\u3040" <= ch <= "\u30ff") or ("\u4e00" <= ch <= "\u9fff"))
    cyr_ratio = (cyrillic / total_letters) if total_letters > 0 else 0.0

    if cyr_ratio > 0.4:
        guessed_source = "ru"
    elif total_letters > 0 and (japanese / max(1, len(text))) > 0.15:
        guessed_source = "ja"
    else:
        guessed_source = "en"

    target = explicit_target.strip().lower() if explicit_target else ""
    if not target:
        target = "en" if cyr_ratio > 0.4 else "ru"

    return guessed_source, target


def translate_google(text: str, target: str):
    q = urllib.parse.quote(text)
    tl = urllib.parse.quote(target)
    url = f"https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl={tl}&dt=t&q={q}"
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36"
        },
    )
    with urllib.request.urlopen(req, timeout=8) as resp:
        data = json.loads(resp.read().decode("utf-8", errors="replace"))
    segments = data[0] if isinstance(data, list) and len(data) > 0 and isinstance(data[0], list) else []
    translated_parts = [seg[0] for seg in segments if isinstance(seg, list) and len(seg) > 0 and seg[0]]
    translated = "".join(translated_parts).strip()
    detected_src = data[2] if isinstance(data, list) and len(data) > 2 and isinstance(data[2], str) else ""
    if not translated:
        raise ValueError("Empty translation from Google endpoint")
    return translated, detected_src


def translate_mymemory(text: str, source_lang: str, target: str):
    src = source_lang if source_lang and source_lang != "auto" else ("en" if target != "en" else "ru")
    if src == target:
        src = "en" if target != "en" else "ru"
    params = urllib.parse.urlencode({"q": text[:500], "langpair": f"{src}|{target}"})
    url = f"https://api.mymemory.translated.net/get?{params}"
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) OberonTranslator/1.0"},
    )
    with urllib.request.urlopen(req, timeout=8) as resp:
        data = json.loads(resp.read().decode("utf-8", errors="replace"))
    translated = (
        data.get("responseData", {}).get("translatedText", "")
        if isinstance(data, dict)
        else ""
    )
    translated = (translated or "").strip()
    if not translated:
        raise ValueError("Empty translation from MyMemory API")
    return translated, src


def copy_to_clipboard(text: str):
    if not text:
        return
    try:
        subprocess.run(
            ["wl-copy"],
            input=text.encode("utf-8"),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=3,
            check=False,
        )
    except Exception:
        pass


def main():
    raw = os.environ.get("OCR_RAW", "")
    explicit_target = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("TARGET_LANG", "")
    cleaned = clean_ocr_text(raw)

    if not cleaned:
        print(json.dumps({"ok": False, "error": "Текст на изображении не найден"}, ensure_ascii=False))
        return

    guessed_source, target_lang = detect_languages(cleaned, explicit_target)
    source_lang = guessed_source
    translated = ""

    try:
        translated, detected_src = translate_google(cleaned, target_lang)
        if detected_src:
            source_lang = detected_src
    except Exception:
        try:
            translated, fallback_src = translate_mymemory(cleaned, guessed_source, target_lang)
            if fallback_src:
                source_lang = fallback_src
        except Exception as exc:
            print(
                json.dumps(
                    {
                        "ok": False,
                        "error": f"Ошибка перевода: {exc}",
                        "source_lang": source_lang,
                        "target_lang": target_lang,
                        "original": cleaned,
                        "translated": "",
                    },
                    ensure_ascii=False,
                )
            )
            return

    copy_to_clipboard(translated)
    print(
        json.dumps(
            {
                "ok": True,
                "source_lang": source_lang,
                "target_lang": target_lang,
                "original": cleaned,
                "translated": translated,
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
PY
