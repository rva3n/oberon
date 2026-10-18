#!/usr/bin/env bash
# Oberon screen recorder (wf-recorder). Audio mixing/finalization adapted from
# Panacea's MIT-licensed recorder script.
set -u

PATH="${PATH}:/usr/bin:/usr/local/bin:/bin:/usr/sbin:/sbin"
export PATH

STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/oberon"
STATE="$STATE_DIR/record.state"
LOG="$STATE_DIR/record.log"
mkdir -p "$STATE_DIR" || exit 1

PID=""
STARTED=""
PAUSED_AT=""
PAUSED_TOTAL=0
FILE=""
MODULES=""

read_saved_state() {
    [ -f "$STATE" ] || return 1
    {
        IFS= read -r PID || return 1
        IFS= read -r STARTED || return 1
        IFS= read -r PAUSED_AT || return 1
        IFS= read -r PAUSED_TOTAL || return 1
        IFS= read -r FILE || return 1
        IFS= read -r MODULES || MODULES=""
    } < "$STATE"
    [[ "$PID" =~ ^[0-9]+$ ]] || return 1
    [[ "$STARTED" =~ ^[0-9]+$ ]] || return 1
    [[ "$PAUSED_TOTAL" =~ ^[0-9]+$ ]] || PAUSED_TOTAL=0
    return 0
}

process_alive() {
    local stat
    kill -0 "$1" 2>/dev/null || return 1
    stat=$(ps -o stat= -p "$1" 2>/dev/null || true)
    [[ -n "$stat" && "$stat" != Z* ]]
}

write_state() {
    local tmp="$STATE.tmp.$$"
    printf '%s\n' "$PID" "$STARTED" "$PAUSED_AT" "$PAUSED_TOTAL" "$FILE" "$MODULES" > "$tmp" || return 1
    mv -f -- "$tmp" "$STATE"
}

unload_modules() {
    local id
    for id in ${1:-}; do
        [[ "$id" =~ ^[0-9]+$ ]] && pactl unload-module "$id" >/dev/null 2>&1 || true
    done
}

default_monitor() {
    local sink
    sink=$(pactl get-default-sink 2>/dev/null || true)
    [ -n "$sink" ] && printf '%s.monitor\n' "$sink"
}

default_mic() {
    pactl get-default-source 2>/dev/null || true
}

finalize() {
    local file="$1" has_audio="" tmp
    [ -s "$file" ] || return 0
    command -v ffmpeg >/dev/null 2>&1 || return 0

    if command -v ffprobe >/dev/null 2>&1; then
        has_audio=$(ffprobe -v error -select_streams a -show_entries stream=index \
            -of csv=p=0 "$file" 2>/dev/null | head -n 1 || true)
    else
        has_audio="unknown"
    fi

    tmp="${file%.mp4}.tmp.mp4"
    if [ -n "$has_audio" ]; then
        ffmpeg -y -v error -i "$file" -c copy -movflags +faststart "$tmp" 2>>"$LOG" || true
    else
        ffmpeg -y -v error -i "$file" \
            -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000 \
            -shortest -c:v copy -c:a aac -b:a 96k -movflags +faststart "$tmp" 2>>"$LOG" || true
    fi

    if [ -s "$tmp" ]; then
        mv -f -- "$tmp" "$file"
    else
        rm -f -- "$tmp"
    fi
}

cleanup_stale_state() {
    if read_saved_state && ! process_alive "$PID"; then
        unload_modules "$MODULES"
        rm -f -- "$STATE"
        finalize "$FILE"
    fi
}

fail_start() {
    echo "$1" >&2
    if [ -s "$LOG" ]; then tail -n 4 "$LOG" >&2; fi
    unload_modules "$MODULES"
    MODULES=""
    return 1
}

start_recording() {
    local fps="${2:-60}" dir="${3:-$HOME/Videos}" sys="${4:-0}" mic="${5:-0}"
    local mic_dev="${6:-}" wf_rec sys_dev="" audio_dev="" mix_sink="" module="" loopback=""
    local stamp suffix=0

    if read_saved_state && process_alive "$PID"; then
        echo "Запись уже выполняется." >&2
        return 1
    fi
    [ -f "$STATE" ] && cleanup_stale_state

    case "$fps" in 30|60|120) ;; *) echo "FPS должен быть 30, 60 или 120." >&2; return 1 ;; esac
    case "$sys" in 1) ;; 0|"") sys=0 ;; *) echo "Некорректный флаг системного звука." >&2; return 1 ;; esac
    case "$mic" in 1) ;; 0|"") mic=0 ;; *) echo "Некорректный флаг микрофона." >&2; return 1 ;; esac

    wf_rec=$(command -v wf-recorder 2>/dev/null || true)
    if [ -z "$wf_rec" ]; then
        echo "wf-recorder не установлен." >&2
        return 1
    fi

    case "$dir" in
        "~") dir="$HOME" ;;
        "~/"*) dir="$HOME/${dir#~/}" ;;
        '$HOME') dir="$HOME" ;;
        '$HOME/'*) dir="$HOME/${dir#\$HOME/}" ;;
    esac
    if ! mkdir -p -- "$dir"; then
        echo "Не удалось создать папку: $dir" >&2
        return 1
    fi

    if [ "$sys" = "1" ] || [ "$mic" = "1" ]; then
        if ! command -v pactl >/dev/null 2>&1; then
            echo "Для записи звука нужен pactl (PipeWire PulseAudio)." >&2
            return 1
        fi
    fi

    if [ "$sys" = "1" ]; then
        sys_dev=$(default_monitor)
        if [ -z "$sys_dev" ]; then
            echo "Не найден монитор системного звука." >&2
            return 1
        fi
    fi
    if [ "$mic" = "1" ] && [ -z "$mic_dev" ]; then
        mic_dev=$(default_mic)
        if [ -z "$mic_dev" ]; then
            echo "Не найден источник микрофона." >&2
            return 1
        fi
    fi

    MODULES=""
    if [ "$sys" = "1" ] && [ "$mic" = "1" ]; then
        mix_sink="oberon_record_mix_${$}_$(date +%s)"
        module=$(pactl load-module module-null-sink "sink_name=$mix_sink" \
            sink_properties=device.description=OberonRecordMix 2>/dev/null || true)
        if [[ ! "$module" =~ ^[0-9]+$ ]]; then
            echo "Не удалось создать микшер для системного звука и микрофона." >&2
            return 1
        fi
        MODULES="$module"
        loopback=$(pactl load-module module-loopback "source=$sys_dev" "sink=$mix_sink" \
            latency_msec=40 2>/dev/null || true)
        if [[ ! "$loopback" =~ ^[0-9]+$ ]]; then
            unload_modules "$MODULES"
            MODULES=""
            echo "Не удалось подключить системный звук к микшеру." >&2
            return 1
        fi
        MODULES="$MODULES $loopback"
        loopback=$(pactl load-module module-loopback "source=$mic_dev" "sink=$mix_sink" \
            latency_msec=40 2>/dev/null || true)
        if [[ ! "$loopback" =~ ^[0-9]+$ ]]; then
            unload_modules "$MODULES"
            MODULES=""
            echo "Не удалось подключить микрофон к микшеру." >&2
            return 1
        fi
        MODULES="$MODULES $loopback"
        audio_dev="$mix_sink.monitor"
    elif [ "$sys" = "1" ]; then
        audio_dev="$sys_dev"
    elif [ "$mic" = "1" ]; then
        audio_dev="$mic_dev"
    fi

    stamp=$(date +%Y%m%d-%H%M%S)
    FILE="$dir/oberon-$stamp.mp4"
    while [ -e "$FILE" ]; do
        suffix=$((suffix + 1))
        FILE="$dir/oberon-$stamp-$suffix.mp4"
    done

    : > "$LOG"
    local -a args
    args=(-f "$FILE" -r "$fps")
    [ -n "$audio_dev" ] && args+=("--audio=$audio_dev")
    nohup "$wf_rec" "${args[@]}" >"$LOG" 2>&1 </dev/null &
    PID=$!
    sleep 0.5
    if ! process_alive "$PID"; then
        fail_start "Не удалось начать запись wf-recorder."
        return 1
    fi

    STARTED=$(date +%s)
    PAUSED_AT=""
    PAUSED_TOTAL=0
    if ! write_state; then
        kill -INT "$PID" 2>/dev/null || true
        unload_modules "$MODULES"
        MODULES=""
        echo "Не удалось сохранить состояние записи." >&2
        return 1
    fi
    printf '%s\n' "$FILE"
}

pause_recording() {
    if ! read_saved_state || ! process_alive "$PID"; then
        echo "Активная запись не найдена." >&2
        return 1
    fi
    [ -n "$PAUSED_AT" ] && return 0
    kill -STOP "$PID" 2>/dev/null || { echo "Не удалось приостановить запись." >&2; return 1; }
    PAUSED_AT=$(date +%s)
    write_state
}

resume_recording() {
    if ! read_saved_state || ! process_alive "$PID"; then
        echo "Активная запись не найдена." >&2
        return 1
    fi
    [ -z "$PAUSED_AT" ] && return 0
    kill -CONT "$PID" 2>/dev/null || { echo "Не удалось продолжить запись." >&2; return 1; }
    PAUSED_TOTAL=$((PAUSED_TOTAL + $(date +%s) - PAUSED_AT))
    PAUSED_AT=""
    write_state
}

stop_recording() {
    local i=0
    if ! read_saved_state; then
        echo "Активная запись не найдена." >&2
        return 1
    fi
    if ! process_alive "$PID"; then
        cleanup_stale_state
        printf '%s\n' "$FILE"
        return 0
    fi

    [ -n "$PAUSED_AT" ] && kill -CONT "$PID" 2>/dev/null || true
    kill -INT "$PID" 2>/dev/null || true
    while process_alive "$PID" && [ "$i" -lt 80 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    if process_alive "$PID"; then
        kill -TERM "$PID" 2>/dev/null || true
        i=0
        while process_alive "$PID" && [ "$i" -lt 20 ]; do
            sleep 0.1
            i=$((i + 1))
        done
    fi
    if process_alive "$PID"; then
        kill -KILL "$PID" 2>/dev/null || true
        sleep 0.1
    fi

    unload_modules "$MODULES"
    rm -f -- "$STATE"
    finalize "$FILE"
    printf '%s\n' "$FILE"
}

status_recording() {
    local paused_total now
    if read_saved_state && process_alive "$PID"; then
        if [ -n "$PAUSED_AT" ]; then
            now=$(date +%s)
            paused_total=$((PAUSED_TOTAL + now - PAUSED_AT))
            printf 'paused|%s|%s|%s|%s\n' "$PID" "$STARTED" "$paused_total" "$FILE"
        else
            printf 'rec|%s|%s|%s|%s\n' "$PID" "$STARTED" "$PAUSED_TOTAL" "$FILE"
        fi
    else
        [ -f "$STATE" ] && cleanup_stale_state
        echo "idle"
    fi
}

case "${1:-}" in
    start) start_recording "$@" ;;
    stop) stop_recording ;;
    pause) pause_recording ;;
    resume) resume_recording ;;
    status) status_recording ;;
    *)
        echo "usage: record.sh start FPS DIR SYS MIC [MIC_SOURCE] | pause | resume | stop | status" >&2
        exit 2
        ;;
esac
