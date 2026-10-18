#!/usr/bin/env bash
# Probe, trim and crop media files for Oberon's MediaView.
set -u

PATH="${PATH}:/usr/bin:/usr/local/bin:/bin:/usr/sbin:/sbin"
export PATH

fail() {
    printf 'media.sh: %s\n' "$1" >&2
    exit "${2:-1}"
}

need_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 не установлен."
}

input_file() {
    local file="$1"
    [[ -n "$file" ]] || fail "Не указан входной файл." 2
    [[ -f "$file" && -r "$file" ]] || fail "Файл не найден или недоступен: $file"
}

value_for() {
    local key="$1" data="$2"
    awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' <<< "$data"
}

valid_uint() {
    [[ "$1" =~ ^[0-9]{1,9}$ ]]
}

valid_time() {
    [[ "$1" =~ ^[0-9]+([.][0-9]{1,6})?$ ]]
}

make_unique_path() {
    local requested="$1" dir name stem ext candidate n
    [[ -n "$requested" ]] || fail "Не указан путь сохранения." 2
    dir=$(dirname -- "$requested")
    name=$(basename -- "$requested")
    if [[ "$name" == *.* && "$name" != .* ]]; then
        stem="${name%.*}"
        ext=".${name##*.}"
    else
        stem="$name"
        ext=""
    fi
    candidate="$requested"
    n=2
    while [[ -e "$candidate" ]]; do
        candidate="$dir/$stem-$n$ext"
        n=$((n + 1))
    done
    printf '%s\n' "$candidate"
}

probe_file() {
    local file="$1" streams duration width height codec fps_rate fps size
    need_tool ffprobe
    input_file "$file"

    streams=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height,codec_name,r_frame_rate \
        -of default=noprint_wrappers=1 "$file" 2>/dev/null) \
        || fail "Не удалось прочитать медиаданные: $file"
    width=$(value_for width "$streams")
    height=$(value_for height "$streams")
    codec=$(value_for codec_name "$streams")
    fps_rate=$(value_for r_frame_rate "$streams")
    [[ "$width" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ ]] \
        || fail "В файле не найден видеопоток: $file"

    duration=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -n 1 || true)
    [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]] || duration=0
    fps=0
    if [[ "$fps_rate" =~ ^([0-9]+)(/([0-9]+))?$ ]]; then
        local numerator="${BASH_REMATCH[1]}" denominator="${BASH_REMATCH[3]:-1}"
        if [[ "$denominator" =~ ^[0-9]+$ ]] && (( denominator > 0 )); then
            fps=$(awk -v n="$numerator" -v d="$denominator" 'BEGIN { printf "%.3f", n / d }')
        fi
    fi
    [[ "$codec" =~ ^[A-Za-z0-9_.-]+$ ]] || codec="unknown"
    size=$(stat -c '%s' -- "$file" 2>/dev/null) || fail "Не удалось прочитать размер файла: $file"
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    printf '{"duration":%s,"width":%s,"height":%s,"codec":"%s","fps":%s,"size":%s}\n' \
        "$duration" "$width" "$height" "$codec" "$fps" "$size"
}

cut_file() {
    local input="$1" start="$2" end="$3" requested="$4" output ext
    local -a args
    need_tool ffmpeg
    input_file "$input"
    valid_time "$start" && valid_time "$end" || fail "Время должно быть числом в секундах." 2
    awk -v start="$start" -v end="$end" 'BEGIN { exit !(end > start) }' \
        || fail "Конец фрагмента должен быть позже начала." 2
    output=$(make_unique_path "$requested")
    mkdir -p -- "$(dirname -- "$output")" || fail "Не удалось создать папку для результата."
    ext="${input##*.}"
    args=(-nostdin -n -v error -ss "$start" -to "$end" -i "$input"
        -map 0:v:0 -map '0:a?' -sn -dn)
    if [[ "${ext,,}" == "gif" ]]; then
        args+=(-loop 0)
    else
        args+=(-avoid_negative_ts make_zero)
    fi
    args+=("$output")
    ffmpeg "${args[@]}" </dev/null || {
        rm -f -- "$output"
        if [[ "${ext,,}" == "gif" ]]; then fail "Не удалось обрезать GIF."; fi
        fail "Не удалось обрезать видео."
    }
    printf '%s\n' "$output"
}

crop_file() {
    local rect="$1" input="$2" requested="$3" width height x y streams src_w src_h has_video output ext
    need_tool ffmpeg
    need_tool ffprobe
    input_file "$input"
    [[ "$rect" =~ ^([0-9]{1,9}):([0-9]{1,9}):([0-9]{1,9}):([0-9]{1,9})$ ]] \
        || fail "Область задаётся как W:H:X:Y (целые пиксели)." 2
    width=$((10#${BASH_REMATCH[1]}))
    height=$((10#${BASH_REMATCH[2]}))
    x=$((10#${BASH_REMATCH[3]}))
    y=$((10#${BASH_REMATCH[4]}))
    (( width > 0 && height > 0 )) || fail "Ширина и высота области должны быть больше нуля." 2

    streams=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height -of default=noprint_wrappers=1 "$input" 2>/dev/null) \
        || fail "Не удалось прочитать размер кадра: $input"
    src_w=$(value_for width "$streams")
    src_h=$(value_for height "$streams")
    [[ "$src_w" =~ ^[0-9]+$ && "$src_h" =~ ^[0-9]+$ ]] \
        || fail "В файле не найден видеопоток: $input"
    (( x + width <= src_w && y + height <= src_h )) \
        || fail "Область обрезки выходит за границы кадра (${src_w}x${src_h})." 2

    has_video=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of default=nw=1:nk=1 "$input" 2>/dev/null | head -n 1 || true)
    [[ -n "$has_video" ]] || fail "В файле не найден видеопоток: $input"
    output=$(make_unique_path "$requested")
    mkdir -p -- "$(dirname -- "$output")" || fail "Не удалось создать папку для результата."
    ext="${output##*.}"
    local -a args=(-nostdin -n -v error -i "$input" -vf "crop=${width}:${height}:${x}:${y}")
    if [[ "${ext,,}" == "gif" ]]; then
        args+=(-loop 0)
    elif [[ "${ext,,}" == "mp4" || "${ext,,}" == "m4v" || "${ext,,}" == "mov" ]]; then
        args+=(-movflags +faststart)
    fi
    args+=("$output")
    ffmpeg "${args[@]}" </dev/null || { rm -f -- "$output"; fail "Не удалось обрезать кадр."; }
    printf '%s\n' "$output"
}

usage() {
    printf '%s\n' \
        "usage: media.sh probe <path>" \
        "       media.sh cut <input> <start> <end> <outpath>" \
        "       media.sh crop <w:h:x:y> <input> <outpath>" >&2
    exit 2
}

case "${1:-}" in
    probe)
        [[ $# -eq 2 ]] || usage
        probe_file "$2"
        ;;
    cut)
        [[ $# -eq 5 ]] || usage
        cut_file "$2" "$3" "$4" "$5"
        ;;
    crop)
        [[ $# -eq 4 ]] || usage
        crop_file "$2" "$3" "$4"
        ;;
    *) usage ;;
esac
