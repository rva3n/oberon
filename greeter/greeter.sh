#!/usr/bin/env bash
set -u

# Usage: greeter.sh [quickshell-bin] [--no-fallback]
# The same file is installed as /usr/local/bin/oberon-greeter.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -f "$SCRIPT_DIR/shell.qml" ]]; then
    GREETER_DIR="$SCRIPT_DIR"
else
    GREETER_DIR="${OBERON_GREETER_DIR:-/usr/local/lib/oberon-greeter/greeter}"
fi

QS_BIN="${1:-${OBERON_QS_BIN:-oberonqs}}"
if (($# > 0)); then
    shift
fi

FALLBACK_MODE="${OBERON_GREETER_FALLBACK:-enabled}"
if [[ "${1:-}" == "--no-fallback" ]]; then
    FALLBACK_MODE="disabled"
    shift
elif [[ "${1:-}" == "--fallback" ]]; then
    FALLBACK_MODE="enabled"
    shift
fi

if (($# > 0)); then
    printf 'Usage: %s [quickshell-bin] [--no-fallback]\n' "$0" >&2
    exit 2
fi

case "${FALLBACK_MODE,,}" in
    0|false|off|disabled|no) FALLBACK_ENABLED=0 ;;
    *) FALLBACK_ENABLED=1 ;;
esac

# Prefer the installed, self-contained copy while preserving the documented
# PATH default for a source-tree/local preview run.
if [[ "$QS_BIN" == "oberonqs" && -x /usr/local/lib/oberon-greeter/oberonqs ]]; then
    QS_BIN="/usr/local/lib/oberon-greeter/oberonqs"
fi

run_fallback() {
    local reason="$1"
    if (( ! FALLBACK_ENABLED )); then
        printf 'Oberon greeter %s; fallback is disabled.\n' "$reason" >&2
        exit 127
    fi

    printf 'Oberon greeter %s; trying a system greeter.\n' "$reason" >&2
    if command -v regreet >/dev/null 2>&1; then
        exec regreet
    elif command -v agreety >/dev/null 2>&1; then
        exec agreety
    fi

    printf 'No fallback greeter found (install regreet or agreety); cannot continue login.\n' >&2
    exit 127
}

if [[ "$QS_BIN" == */* ]]; then
    [[ -x "$QS_BIN" ]] || run_fallback "binary '$QS_BIN' is missing or not executable"
elif ! command -v "$QS_BIN" >/dev/null 2>&1; then
    run_fallback "binary '$QS_BIN' was not found in PATH"
fi

if (( ! FALLBACK_ENABLED )); then
    exec "$QS_BIN" -p "$GREETER_DIR"
fi

"$QS_BIN" -p "$GREETER_DIR" &
GREETER_PID=$!

stop_greeter() {
    kill -TERM "$GREETER_PID" 2>/dev/null || true
    wait "$GREETER_PID" 2>/dev/null || true
    exit 143
}
trap stop_greeter HUP INT TERM

# A process that exits (or becomes a zombie) during this grace period never
# reached a stable greeter window, so hand control back to greetd-compatible UI.
for ((attempt = 0; attempt < 80; ++attempt)); do
    sleep 0.1
    if ! kill -0 "$GREETER_PID" 2>/dev/null; then
        wait "$GREETER_PID"
        status=$?
        run_fallback "exited during startup (status $status)"
    fi

    child_state="$(ps -o stat= -p "$GREETER_PID" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$child_state" == Z* || "$child_state" == X* ]]; then
        wait "$GREETER_PID"
        status=$?
        run_fallback "exited during startup (status $status)"
    fi
done

# It survived the startup window; preserve normal greeter lifetime and status.
wait "$GREETER_PID"
