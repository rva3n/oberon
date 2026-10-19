#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Oberon AI Assistant Backend (scripts/ai-chat.py)
Supports:
  - OpenCode API (https://opencode.ai/zen/v1/chat/completions) & OpenCode CLI (`opencode run --format json`)
  - Google Gemini API (https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent)
  - OpenRouter API (https://openrouter.ai/api/v1/chat/completions)
  - OpenAI-compatible API (custom base_url, default https://api.openai.com/v1/chat/completions)
  - Local Ollama (http://127.0.0.1:11434/api/chat & /api/tags)

Secure key storage: ~/.local/share/oberon/ai-keys.json (chmod 0600)
"""

import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

KEYS_PATH = os.path.expanduser("~/.local/share/oberon/ai-keys.json")

DEFAULT_PROVIDERS = {
    "opencode": {
        "name": "OpenCode",
        "base_url": "https://opencode.ai/zen/v1/chat/completions",
        "models": [
            "gemini-4-argon-contributor",
            "claude-sonnet-4-5",
            "gpt-5.4",
            "qwen3.7-plus",
            "deepseek-v3",
            "opencode-cli",
        ],
    },
    "gemini": {
        "name": "Google Gemini",
        "base_url": "https://generativelanguage.googleapis.com/v1beta",
        "models": [
            "gemini-2.5-flash",
            "gemini-2.5-pro",
            "gemini-2.0-flash",
        ],
    },
    "openrouter": {
        "name": "OpenRouter",
        "base_url": "https://openrouter.ai/api/v1/chat/completions",
        "models": [
            "deepseek/deepseek-chat-v3-0324:free",
            "google/gemini-2.5-flash",
            "anthropic/claude-3.7-sonnet",
            "openai/gpt-4o-mini",
        ],
    },
    "openai": {
        "name": "OpenAI",
        "base_url": "https://api.openai.com/v1/chat/completions",
        "models": [
            "gpt-4o-mini",
            "gpt-4o",
            "deepseek-chat",
        ],
    },
    "ollama": {
        "name": "Ollama (Локально)",
        "base_url": "http://127.0.0.1:11434",
        "models": [
            "llama3.2",
            "qwen2.5-coder",
            "deepseek-r1",
        ],
    },
}

DEFAULT_SYSTEM_PROMPT = (
    "Ты — встроенный ИИ-ассистент рабочей среды Oberon (композитор Umbriel, Arch Linux). "
    "Отвечай чётко, по делу и дружелюбно на русском языке (если пользователь не попросил иной язык). "
    "Команды терминала и фрагменты кода всегда оформляй в блоки ```bash или соответствующий язык."
)


def load_keys():
    if not os.path.exists(KEYS_PATH):
        return {}
    try:
        with open(KEYS_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_keys(data):
    parent = os.path.dirname(KEYS_PATH)
    os.makedirs(parent, exist_ok=True)
    tmp_path = KEYS_PATH + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, KEYS_PATH)
    try:
        os.chmod(KEYS_PATH, 0o600)
    except Exception:
        pass


def mask_key(key):
    if not key or not isinstance(key, str):
        return ""
    s = key.strip()
    if len(s) <= 8:
        return s[:2] + "..." + s[-2:] if len(s) >= 4 else "***"
    return s[:4] + "..." + s[-4:]


def query_ollama_models(base_url):
    base = (base_url or "http://127.0.0.1:11434").rstrip("/")
    if base.endswith("/api/chat"):
        base = base[: -len("/api/chat")]
    tags_url = base + "/api/tags"
    req = urllib.request.Request(tags_url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=1.2) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            data = json.loads(raw)
            models = []
            for item in data.get("models", []):
                name = item.get("name") or item.get("model")
                if name:
                    models.append(str(name))
            return True, (models if models else DEFAULT_PROVIDERS["ollama"]["models"])
    except Exception:
        return False, DEFAULT_PROVIDERS["ollama"]["models"]


def build_status():
    stored = load_keys()
    opencode_cli = shutil.which("opencode") is not None
    ollama_cfg = stored.get("ollama", {}) if isinstance(stored.get("ollama"), dict) else {}
    ollama_base = ollama_cfg.get("base_url") or DEFAULT_PROVIDERS["ollama"]["base_url"]
    ollama_online, ollama_models = query_ollama_models(ollama_base)

    providers_out = {}
    for pid, meta in DEFAULT_PROVIDERS.items():
        entry = stored.get(pid, {})
        if isinstance(entry, str):
            entry = {"api_key": entry}
        elif not isinstance(entry, dict):
            entry = {}

        api_key = str(entry.get("api_key", "")).strip()
        base_url = str(entry.get("base_url", "")).strip() or meta["base_url"]
        custom_models = entry.get("models", [])

        if pid == "ollama":
            models = ollama_models
            has_key = True
        else:
            models = list(meta["models"])
            if isinstance(custom_models, list):
                for cm in custom_models:
                    if cm and str(cm) not in models:
                        models.insert(0, str(cm))
            has_key = bool(api_key)

        providers_out[pid] = {
            "name": meta["name"],
            "has_key": has_key,
            "key_preview": mask_key(api_key) if api_key else ("CLI" if pid == "opencode" and opencode_cli else ""),
            "base_url": base_url,
            "models": models,
            "ready": has_key or (pid == "opencode" and opencode_cli) or (pid == "ollama" and ollama_online),
        }

    return {
        "ok": True,
        "opencode_cli_available": opencode_cli,
        "ollama_online": ollama_online,
        "providers": providers_out,
    }


def collect_sysinfo(extra_window=""):
    info_parts = []
    try:
        uname = platform.uname()
        info_parts.append(f"ОС: Arch Linux ({uname.system} {uname.release} {uname.machine})")
    except Exception:
        info_parts.append("ОС: Arch Linux")

    info_parts.append(f"Рабочая папка: {os.getcwd()}")
    desktop = os.environ.get("XDG_CURRENT_DESKTOP") or "Umbriel / Oberon"
    info_parts.append(f"Окружение: {desktop}")
    if extra_window:
        info_parts.append(f"Активное окно: {extra_window}")
    return "Контекст системы пользователя:\n" + "\n".join(f"- {p}" for p in info_parts)


def extract_code_blocks(text):
    if not text:
        return []
    blocks = []
    pattern = re.compile(r"```([a-zA-Z0-9_+-]*)\s*\n(.*?)```", re.DOTALL)
    for match in pattern.finditer(text):
        lang = (match.group(1) or "text").strip().lower()
        code = match.group(2).rstrip("\n")
        if code.strip():
            blocks.append({"lang": lang or "text", "code": code})
    return blocks


def http_post_json(url, payload, headers, timeout=90):
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req_headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": "Oberon-AI-Assistant/1.0",
    }
    req_headers.update(headers or {})
    req = urllib.request.Request(url, data=body, headers=req_headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return True, json.loads(raw)
    except urllib.error.HTTPError as e:
        err_body = ""
        try:
            err_body = e.read().decode("utf-8", errors="replace")
        except Exception:
            pass
        msg = f"HTTP {e.code}: {e.reason}"
        if err_body:
            try:
                err_json = json.loads(err_body)
                detail = (
                    err_json.get("error", {}).get("message")
                    if isinstance(err_json.get("error"), dict)
                    else err_json.get("error") or err_json.get("message")
                )
                if detail:
                    msg += f" — {detail}"
                else:
                    msg += f" — {err_body[:240]}"
            except Exception:
                msg += f" — {err_body[:240]}"
        return False, msg
    except urllib.error.URLError as e:
        return False, f"Ошибка сети: {e.reason}"
    except Exception as e:
        return False, f"Ошибка запроса: {e}"


def parse_openai_like_reply(data):
    if not isinstance(data, dict):
        return None
    choices = data.get("choices")
    if isinstance(choices, list) and len(choices) > 0:
        first = choices[0] or {}
        msg = first.get("message") or {}
        content = msg.get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts = []
            for item in content:
                if isinstance(item, dict) and item.get("text"):
                    parts.append(str(item["text"]))
            return "\n".join(parts)
        if isinstance(first.get("text"), str):
            return first["text"]
    if isinstance(data.get("reply"), str):
        return data["reply"]
    return None


def run_opencode_cli(messages, system_prompt, model):
    if shutil.which("opencode") is None:
        return False, (
            "Не задан API-ключ OpenCode и не найден CLI `opencode` в PATH. "
            "Нажмите «🔑 Ключ API», чтобы указать ваш ключ OpenCode."
        )

    # Собираем диалог в промпт для `opencode run`
    conv_parts = []
    if system_prompt:
        conv_parts.append(f"[Системная инструкция]: {system_prompt}")
    for m in messages[-10:]:
        role = m.get("role", "user")
        content = str(m.get("content", "")).strip()
        if not content:
            continue
        if role == "user":
            conv_parts.append(f"Пользователь: {content}")
        elif role == "assistant":
            conv_parts.append(f"Ассистент: {content}")
    prompt_text = "\n\n".join(conv_parts) if len(conv_parts) > 1 else (
        str(messages[-1].get("content", "")) if messages else "Привет"
    )

    cmd = ["opencode", "run", "--format", "json"]
    if model and model != "opencode-cli":
        # Если передана конкретная модель вида provider/model, передаём -m
        if "/" in model:
            cmd.extend(["-m", model])
    cmd.append(prompt_text)

    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=90,
        )
        text_chunks = []
        raw_out = proc.stdout or ""
        for line in raw_out.splitlines():
            line_s = line.strip()
            if not line_s:
                continue
            try:
                ev = json.loads(line_s)
                if isinstance(ev, dict):
                    ev_type = ev.get("type", "")
                    part = ev.get("part") if isinstance(ev.get("part"), dict) else {}
                    if ev_type == "text" and part.get("text"):
                        text_chunks.append(str(part["text"]))
                    elif isinstance(ev.get("text"), str):
                        text_chunks.append(ev["text"])
                    elif isinstance(ev.get("content"), str):
                        text_chunks.append(ev["content"])
            except Exception:
                # Не JSON-строка
                pass

        reply = "".join(text_chunks).strip()
        if not reply and raw_out.strip():
            # Fallback если вывод был простым текстом
            reply = raw_out.strip()
        if reply:
            return True, reply
        err_text = (proc.stderr or "").strip()
        return False, f"OpenCode CLI не вернул ответ. {err_text[:240]}".strip()
    except subprocess.TimeoutExpired:
        return False, "Превышено время ожидания ответа от OpenCode CLI (90 с)."
    except Exception as e:
        return False, f"Ошибка запуска OpenCode CLI: {e}"


def ask_opencode(api_key, base_url, model, temperature, messages, system_prompt):
    if not api_key or model == "opencode-cli":
        return run_opencode_cli(messages, system_prompt, model)

    url = (base_url or DEFAULT_PROVIDERS["opencode"]["base_url"]).strip()
    if not url.endswith("/chat/completions") and not url.endswith("/completions"):
        url = url.rstrip("/") + "/chat/completions"

    api_messages = []
    if system_prompt:
        api_messages.append({"role": "system", "content": system_prompt})
    for m in messages:
        role = m.get("role", "user")
        content = str(m.get("content", ""))
        if role in ("user", "assistant", "system") and content:
            api_messages.append({"role": role, "content": content})

    payload = {
        "model": model,
        "messages": api_messages,
        "temperature": temperature,
    }
    headers = {"Authorization": f"Bearer {api_key}"}
    ok, res = http_post_json(url, payload, headers)
    if not ok:
        return False, f"Ошибка OpenCode API ({res})"
    reply = parse_openai_like_reply(res)
    if not reply:
        return False, "Пустой ответ от OpenCode API."
    return True, reply


def ask_gemini(api_key, base_url, model, temperature, messages, system_prompt):
    if not api_key:
        return False, "Не задан ключ Google Gemini API. Нажмите «🔑 Ключ API» и сохраните ключ."

    base = (base_url or DEFAULT_PROVIDERS["gemini"]["base_url"]).rstrip("/")
    clean_model = model or "gemini-2.5-flash"
    if clean_model.startswith("models/"):
        clean_model = clean_model[len("models/") :]
    url = f"{base}/models/{urllib.parse.quote(clean_model)}:generateContent?key={urllib.parse.quote(api_key)}"

    contents = []
    for m in messages:
        role = m.get("role", "user")
        content = str(m.get("content", ""))
        if not content:
            continue
        gem_role = "model" if role == "assistant" else "user"
        contents.append({"role": gem_role, "parts": [{"text": content}]})

    if not contents:
        return False, "Список сообщений пуст."

    payload = {
        "contents": contents,
        "generationConfig": {
            "temperature": temperature,
        },
    }
    if system_prompt:
        payload["systemInstruction"] = {"parts": [{"text": system_prompt}]}

    ok, res = http_post_json(url, payload, {})
    if not ok:
        return False, f"Ошибка Gemini API ({res})"

    try:
        candidates = res.get("candidates") or []
        if not candidates:
            return False, "Gemini API не вернул вариантов ответа."
        parts = candidates[0].get("content", {}).get("parts", [])
        reply = "".join(str(p.get("text", "")) for p in parts if isinstance(p, dict)).strip()
        if not reply:
            return False, "Пустой текст ответа от Gemini API."
        return True, reply
    except Exception as e:
        return False, f"Ошибка разбора ответа Gemini: {e}"


def ask_openai_compatible(provider_label, api_key, base_url, model, temperature, messages, system_prompt, extra_headers=None):
    if not api_key:
        return False, f"Не задан API-ключ для {provider_label}. Нажмите «🔑 Ключ API» и введите ключ."

    url = (base_url or "").strip()
    if not url.endswith("/chat/completions") and not url.endswith("/completions"):
        url = url.rstrip("/") + "/chat/completions"

    api_messages = []
    if system_prompt:
        api_messages.append({"role": "system", "content": system_prompt})
    for m in messages:
        role = m.get("role", "user")
        content = str(m.get("content", ""))
        if role in ("user", "assistant", "system") and content:
            api_messages.append({"role": role, "content": content})

    payload = {
        "model": model,
        "messages": api_messages,
        "temperature": temperature,
    }
    headers = {"Authorization": f"Bearer {api_key}"}
    if extra_headers:
        headers.update(extra_headers)

    ok, res = http_post_json(url, payload, headers)
    if not ok:
        return False, f"Ошибка {provider_label} ({res})"
    reply = parse_openai_like_reply(res)
    if not reply:
        return False, f"Пустой ответ от {provider_label}."
    return True, reply


def ask_ollama(base_url, model, temperature, messages, system_prompt):
    base = (base_url or DEFAULT_PROVIDERS["ollama"]["base_url"]).rstrip("/")
    if base.endswith("/api/chat"):
        chat_url = base
    else:
        chat_url = base + "/api/chat"

    api_messages = []
    if system_prompt:
        api_messages.append({"role": "system", "content": system_prompt})
    for m in messages:
        role = m.get("role", "user")
        content = str(m.get("content", ""))
        if role in ("user", "assistant", "system") and content:
            api_messages.append({"role": role, "content": content})

    payload = {
        "model": model or "llama3.2",
        "messages": api_messages,
        "stream": False,
        "options": {
            "temperature": temperature,
        },
    }
    ok, res = http_post_json(chat_url, payload, {}, timeout=120)
    if not ok:
        return False, (
            f"Не удалось связаться с локальным сервером Ollama ({res}). "
            "Убедитесь, что служба запущена (`systemctl start ollama` или `ollama serve`)."
        )
    if isinstance(res, dict):
        msg = res.get("message")
        if isinstance(msg, dict) and isinstance(msg.get("content"), str):
            return True, msg["content"].strip()
        if isinstance(res.get("response"), str):
            return True, res["response"].strip()
    return False, "Пустой ответ от локального сервера Ollama."


def handle_ask(provider, model, temp_str):
    provider = (provider or "opencode").strip().lower()
    if provider not in DEFAULT_PROVIDERS:
        return {"ok": False, "error": f"Неизвестный провайдер: {provider}"}

    try:
        temperature = float(temp_str)
    except Exception:
        temperature = 0.7

    raw_stdin = sys.stdin.read()
    try:
        req_data = json.loads(raw_stdin) if raw_stdin.strip() else {}
    except Exception as e:
        return {"ok": False, "error": f"Некорректный JSON во входном потоке: {e}"}

    messages = req_data.get("messages")
    if not isinstance(messages, list) or len(messages) == 0:
        return {"ok": False, "error": "Нет сообщений для отправки."}

    custom_system = str(req_data.get("system") or "").strip()
    system_prompt = custom_system if custom_system else DEFAULT_SYSTEM_PROMPT

    include_sysinfo = bool(req_data.get("include_sysinfo", False))
    active_window = str(req_data.get("active_window") or "").strip()
    if include_sysinfo:
        system_prompt = system_prompt + "\n\n" + collect_sysinfo(active_window)

    stored = load_keys()
    prov_cfg = stored.get(provider, {})
    if isinstance(prov_cfg, str):
        prov_cfg = {"api_key": prov_cfg}
    elif not isinstance(prov_cfg, dict):
        prov_cfg = {}

    api_key = str(prov_cfg.get("api_key", "")).strip()
    base_url = str(prov_cfg.get("base_url", "")).strip() or DEFAULT_PROVIDERS[provider]["base_url"]
    chosen_model = (model or "").strip() or DEFAULT_PROVIDERS[provider]["models"][0]

    if provider == "opencode":
        ok, reply_or_err = ask_opencode(api_key, base_url, chosen_model, temperature, messages, system_prompt)
    elif provider == "gemini":
        ok, reply_or_err = ask_gemini(api_key, base_url, chosen_model, temperature, messages, system_prompt)
    elif provider == "openrouter":
        ok, reply_or_err = ask_openai_compatible(
            "OpenRouter",
            api_key,
            base_url,
            chosen_model,
            temperature,
            messages,
            system_prompt,
            extra_headers={
                "HTTP-Referer": "https://oberon.local",
                "X-Title": "Oberon Shell AI",
            },
        )
    elif provider == "openai":
        ok, reply_or_err = ask_openai_compatible(
            "OpenAI",
            api_key,
            base_url,
            chosen_model,
            temperature,
            messages,
            system_prompt,
        )
    elif provider == "ollama":
        ok, reply_or_err = ask_ollama(base_url, chosen_model, temperature, messages, system_prompt)
    else:
        ok, reply_or_err = False, f"Провайдер {provider} не поддерживается."

    if not ok:
        return {
            "ok": False,
            "error": str(reply_or_err),
            "provider": provider,
            "model": chosen_model,
        }

    reply_text = str(reply_or_err).strip()
    blocks = extract_code_blocks(reply_text)
    return {
        "ok": True,
        "reply": reply_text,
        "blocks": blocks,
        "model": chosen_model,
        "provider": provider,
    }


def main():
    args = sys.argv[1:]
    cmd = args[0] if args else "status"

    if cmd == "status":
        out = build_status()
        print(json.dumps(out, ensure_ascii=False))
        return

    if cmd == "set-key":
        if len(args) < 3:
            print(json.dumps({"ok": False, "error": "Использование: set-key <provider> <api_key> [base_url]"}, ensure_ascii=False))
            return
        provider = args[1].strip().lower()
        api_key = args[2].strip()
        base_url = args[3].strip() if len(args) >= 4 else ""

        if provider not in DEFAULT_PROVIDERS:
            print(json.dumps({"ok": False, "error": f"Неизвестный провайдер: {provider}"}, ensure_ascii=False))
            return

        stored = load_keys()
        prev = stored.get(provider, {})
        if not isinstance(prev, dict):
            prev = {}
        if api_key or provider == "ollama":
            prev["api_key"] = api_key
        if base_url:
            prev["base_url"] = base_url
        elif "base_url" in prev and not base_url:
            # Сброс к стандартному URL, если передан пустой base_url
            del prev["base_url"]
        stored[provider] = prev
        save_keys(stored)
        out = build_status()
        print(json.dumps(out, ensure_ascii=False))
        return

    if cmd == "remove-key":
        if len(args) < 2:
            print(json.dumps({"ok": False, "error": "Использование: remove-key <provider>"}, ensure_ascii=False))
            return
        provider = args[1].strip().lower()
        stored = load_keys()
        if provider in stored:
            del stored[provider]
            save_keys(stored)
        out = build_status()
        print(json.dumps(out, ensure_ascii=False))
        return

    if cmd == "ask":
        provider = args[1] if len(args) >= 2 else "opencode"
        model = args[2] if len(args) >= 3 else ""
        temp_str = args[3] if len(args) >= 4 else "0.7"
        out = handle_ask(provider, model, temp_str)
        print(json.dumps(out, ensure_ascii=False))
        return

    print(json.dumps({"ok": False, "error": f"Неизвестная команда: {cmd}"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
