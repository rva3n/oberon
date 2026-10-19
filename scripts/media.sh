#!/usr/bin/env bash
# Probe, trim, crop, rotate, frame-extract, convert and OCR media files for Oberon's MediaView.
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

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\f'/\\f}"
    s="${s//$'\b'/\\b}"
    printf '%s' "$s"
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

is_audio_ext() {
    local ext="${1##*.}"
    case "${ext,,}" in
        mp3|flac|ogg|opus|wav|m4a|aac|wma|ape|alac|aiff|mid|midi) return 0 ;;
        *) return 1 ;;
    esac
}

is_image_ext() {
    local ext="${1##*.}"
    case "${ext,,}" in
        png|jpg|jpeg|gif|webp|bmp|tif|tiff|avif|svg|ico|heic|heif|jxl|ppm|pgm|pbm) return 0 ;;
        *) return 1 ;;
    esac
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
    local file="$1" v_streams a_streams duration width height codec fps_rate fps size
    local attached_pic a_codec sample_rate channels bit_rate kind
    need_tool ffprobe
    input_file "$file"

    v_streams=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height,codec_name,r_frame_rate:stream_disposition=attached_pic \
        -of default=noprint_wrappers=1 "$file" 2>/dev/null || true)
    width=$(value_for width "$v_streams")
    height=$(value_for height "$v_streams")
    codec=$(value_for codec_name "$v_streams")
    fps_rate=$(value_for r_frame_rate "$v_streams")
    attached_pic=$(value_for attached_pic "$v_streams")

    a_streams=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_name,sample_rate,channels,bit_rate \
        -of default=noprint_wrappers=1 "$file" 2>/dev/null || true)
    a_codec=$(value_for codec_name "$a_streams")
    sample_rate=$(value_for sample_rate "$a_streams")
    channels=$(value_for channels "$a_streams")
    bit_rate=$(value_for bit_rate "$a_streams")
    [[ "$sample_rate" =~ ^[0-9]+$ ]] || sample_rate=0
    [[ "$channels" =~ ^[0-9]+$ ]] || channels=0
    [[ "$bit_rate" =~ ^[0-9]+$ ]] || bit_rate=0

    duration=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -n 1 || true)
    [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]] || duration=0

    size=$(stat -c '%s' -- "$file" 2>/dev/null) || fail "Не удалось прочитать размер файла: $file"
    [[ "$size" =~ ^[0-9]+$ ]] || size=0

    if is_audio_ext "$file" || [[ "$attached_pic" == "1" ]] || ! [[ "$width" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ ]]; then
        [[ -n "$a_codec" ]] || fail "В файле не найден видеопоток: $file"
        [[ "$a_codec" =~ ^[A-Za-z0-9_.-]+$ ]] || a_codec="unknown"
        printf '{"kind":"audio","duration":%s,"width":0,"height":0,"codec":"%s","fps":0,"sample_rate":%s,"channels":%s,"bit_rate":%s,"size":%s}\n' \
            "$duration" "$a_codec" "$sample_rate" "$channels" "$bit_rate" "$size"
        return 0
    fi

    fps=0
    if [[ "$fps_rate" =~ ^([0-9]+)(/([0-9]+))?$ ]]; then
        local numerator="${BASH_REMATCH[1]}" denominator="${BASH_REMATCH[3]:-1}"
        if [[ "$denominator" =~ ^[0-9]+$ ]] && (( denominator > 0 )); then
            fps=$(awk -v n="$numerator" -v d="$denominator" 'BEGIN { printf "%.3f", n / d }')
        fi
    fi
    [[ "$codec" =~ ^[A-Za-z0-9_.-]+$ ]] || codec="unknown"
    kind="video"
    if is_image_ext "$file"; then
        kind="image"
    fi
    printf '{"kind":"%s","duration":%s,"width":%s,"height":%s,"codec":"%s","fps":%s,"sample_rate":%s,"channels":%s,"bit_rate":%s,"size":%s}\n' \
        "$kind" "$duration" "$width" "$height" "$codec" "$fps" "$sample_rate" "$channels" "$bit_rate" "$size"
}

trim_file() {
    local input="$1" start="$2" end="$3" requested="$4" output ext v_streams width height attached_pic
    local -a args
    need_tool ffmpeg
    input_file "$input"
    valid_time "$start" && valid_time "$end" || fail "Время должно быть числом в секундах." 2
    awk -v start="$start" -v end="$end" 'BEGIN { exit !(end > start) }' \
        || fail "Конец фрагмента должен быть позже начала." 2
    output=$(make_unique_path "$requested")
    mkdir -p -- "$(dirname -- "$output")" || fail "Не удалось создать папку для результата."
    ext="${input##*.}"

    width=""
    height=""
    attached_pic=""
    if command -v ffprobe >/dev/null 2>&1; then
        v_streams=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=width,height:stream_disposition=attached_pic \
            -of default=noprint_wrappers=1 "$input" 2>/dev/null || true)
        width=$(value_for width "$v_streams")
        height=$(value_for height "$v_streams")
        attached_pic=$(value_for attached_pic "$v_streams")
    fi

    if is_audio_ext "$input" || [[ "$attached_pic" == "1" ]] || ! [[ "$width" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ ]]; then
        if ! ffmpeg -nostdin -y -v error -ss "$start" -to "$end" -i "$input" -vn -map '0:a:0?' -c:a copy "$output" </dev/null 2>/dev/null; then
            ffmpeg -nostdin -y -v error -ss "$start" -to "$end" -i "$input" -vn "$output" </dev/null || {
                rm -f -- "$output"
                fail "Не удалось обрезать аудио."
            }
        fi
        printf '%s\n' "$output"
        return 0
    fi

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

cut_file() {
    trim_file "$@"
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

rotate_file() {
    local input="$1" angle="$2" output="$3" vf target same_file=0
    need_tool ffmpeg
    input_file "$input"
    [[ -n "$output" ]] || fail "Не указан путь сохранения." 2
    case "$angle" in
        90)  vf="transpose=1" ;;
        180) vf="transpose=2,transpose=2" ;;
        270) vf="transpose=2" ;;
        *)   fail "Угол поворота должен быть 90, 180 или 270." 2 ;;
    esac
    mkdir -p -- "$(dirname -- "$output")" || fail "Не удалось создать папку для результата."
    target="$output"
    if [[ "$(realpath -m -- "$input" 2>/dev/null || printf '%s' "$input")" == "$(realpath -m -- "$output" 2>/dev/null || printf '%s' "$output")" ]]; then
        same_file=1
        target="${output%.*}.oberon-rot-$$.${output##*.}"
    fi
    ffmpeg -nostdin -y -v error -i "$input" -vf "$vf" "$target" </dev/null || {
        [[ "$same_file" -eq 1 ]] && rm -f -- "$target"
        fail "Не удалось повернуть файл."
    }
    if [[ "$same_file" -eq 1 ]]; then
        mv -f -- "$target" "$output" || fail "Не удалось сохранить повернутый файл."
    fi
    printf '{"output":"%s"}\n' "$(json_escape "$output")"
}

frame_file() {
    local input="$1" time_sec="$2" output_png="$3"
    need_tool ffmpeg
    input_file "$input"
    valid_time "$time_sec" || fail "Время должно быть числом в секундах." 2
    [[ -n "$output_png" ]] || fail "Не указан путь сохранения кадра." 2
    mkdir -p -- "$(dirname -- "$output_png")" || fail "Не удалось создать папку для результата."
    ffmpeg -nostdin -y -v error -ss "$time_sec" -i "$input" -frames:v 1 "$output_png" </dev/null || {
        rm -f -- "$output_png"
        fail "Не удалось извлечь кадр."
    }
    printf '{"output":"%s"}\n' "$(json_escape "$output_png")"
}

convert_file() {
    local input="$1" target_output="$2"
    need_tool ffmpeg
    input_file "$input"
    [[ -n "$target_output" ]] || fail "Не указан путь сохранения." 2
    mkdir -p -- "$(dirname -- "$target_output")" || fail "Не удалось создать папку для результата."
    ffmpeg -nostdin -y -v error -i "$input" "$target_output" </dev/null || {
        rm -f -- "$target_output"
        fail "Не удалось конвертировать файл."
    }
    printf '{"output":"%s"}\n' "$(json_escape "$target_output")"
}

ocr_file() {
    local input="$1" text=""
    need_tool tesseract
    input_file "$input"
    text=$(tesseract "$input" stdout -l rus+eng 2>/dev/null || tesseract "$input" stdout 2>/dev/null) \
        || fail "Не удалось распознать текст."
    text="${text%"${text##*[![:space:]]}"}"
    if [[ -n "$text" ]] && command -v wl-copy >/dev/null 2>&1; then
        printf '%s' "$text" | wl-copy 2>/dev/null || true
    fi
    printf '{"text":"%s"}\n' "$(json_escape "$text")"
}

usage() {
    printf '%s\n' \
        "usage: media.sh probe <path>" \
        "       media.sh cut <input> <start> <end> <outpath>" \
        "       media.sh crop <w:h:x:y> <input> <outpath>" \
        "       media.sh rotate <input> <90|180|270> <output>" \
        "       media.sh frame <input> <time_sec> <output_png>" \
        "       media.sh convert <input> <target_output>" \
        "       media.sh ocr <input>" >&2
    exit 2
}

case "${1:-}" in
    probe)
        [[ $# -eq 2 ]] || usage
        probe_file "$2"
        ;;
    cut|trim)
        [[ $# -eq 5 ]] || usage
        trim_file "$2" "$3" "$4" "$5"
        ;;
    crop)
        [[ $# -eq 4 ]] || usage
        crop_file "$2" "$3" "$4"
        ;;
    rotate)
        [[ $# -eq 4 ]] || usage
        rotate_file "$2" "$3" "$4"
        ;;
    frame)
        [[ $# -eq 4 ]] || usage
        frame_file "$2" "$3" "$4"
        ;;
    convert)
        [[ $# -eq 3 ]] || usage
        convert_file "$2" "$3"
        ;;
    ocr)
        [[ $# -eq 2 ]] || usage
        ocr_file "$2"
        ;;
    *) usage ;;
esac
