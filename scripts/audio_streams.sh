#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Adapted from Panacea's audio_streams.sh for Oberon.
set -euo pipefail

usage() {
    echo "usage: $0 list | set-app-volume <index> <pct> | toggle-app-mute <index> | set-default-sink <id> | set-default-source <id> | mic-volume <pct> | mic-mute <on|off>" >&2
    exit 2
}

valid_index() {
    [[ ${1:-} =~ ^[0-9]+$ ]]
}

percent() {
    [[ ${1:-} =~ ^[0-9]+$ ]] || return 1
    (( $1 > 100 )) && printf '100' || printf '%s' "$1"
}

pactl_json() {
    local kind=$1 output
    if ! output=$(pactl -f json list "$kind" 2>/dev/null); then
        printf '[]'
        return
    fi
    if ! printf '%s\n' "$output" | jq -ce 'if type == "array" then . else [] end' 2>/dev/null; then
        printf '[]'
    fi
}

list_audio() {
    local apps sinks sources default_sink default_source
    apps=$(pactl_json sink-inputs)
    sinks=$(pactl_json sinks)
    sources=$(pactl_json sources)
    default_sink=$(pactl get-default-sink 2>/dev/null || true)
    default_source=$(pactl get-default-source 2>/dev/null || true)

    jq -n -c \
        --argjson rawApps "$apps" \
        --argjson rawSinks "$sinks" \
        --argjson rawSources "$sources" \
        --arg defaultSink "$default_sink" \
        --arg defaultSource "$default_source" '
        def first_text($values; $fallback):
            [$values[] | select(type == "string" and . != "" and . != "(null)")][0] // $fallback;
        def volume_pct:
            ([.volume // {} | to_entries[]? | (.value.value_percent? // "100%")
                | tostring | sub("%$"; "") | tonumber?] | map(select(. != null))) as $values
            | (if ($values | length) == 0 then 100 else (($values | add / length) | floor) end)
            | if . < 0 then 0 elif . > 100 then 100 else . end;
        def device($item):
            ($item.properties // {}) as $properties
            | {
                id: ($item.index // 0),
                index: ($item.index // 0),
                name: ($item.name // ""),
                description: first_text([$item.description, $properties["device.description"],
                    $properties["device.nick"], $properties["node.nick"], $item.name]; "Audio"),
                volume: ($item | volume_pct),
                mute: ($item.mute // false)
            };
        {
            apps: [ $rawApps[]? | . as $item | ($item.properties // {}) as $properties
                | {
                    index: ($item.index // 0),
                    name: first_text([$properties["application.name"], $properties["media.name"],
                        $properties["node.name"], $properties["application.process.binary"]]; "Приложение"),
                    app: first_text([$properties["application.name"],
                        $properties["application.process.binary"]]; ""),
                    binary: first_text([$properties["application.process.binary"],
                        $properties["node.name"]]; ""),
                    icon: first_text([$properties["application.icon.name"],
                        $properties["application.icon_name"], $properties["application.icon-name"]]; ""),
                    volume: ($item | volume_pct),
                    mute: ($item.mute // false)
                }
                | select(([.app, .binary, .name] | join(" ") | ascii_downcase
                    | test("cava|quickshell|oberonqs|speech-dispatcher") | not)) ],
            sinks: [ $rawSinks[]? | . as $item | device($item) | select(.name != "") ],
            sources: [ $rawSources[]? | . as $item | device($item) as $source
                | select($source.name != "" and ($source.name | endswith(".monitor") | not)
                    and (($item.properties["device.class"] // "") != "monitor")
                    and ($item.monitor_of_sink? // null) == null)
                | $source ],
            defaultSink: $defaultSink,
            defaultSource: $defaultSource
        }
    '
}

case "${1:-list}" in
    list)
        list_audio
        ;;
    set-app-volume)
        valid_index "${2:-}" && volume=$(percent "${3:-}") || usage
        pactl set-sink-input-volume "$2" "${volume}%"
        ;;
    toggle-app-mute)
        valid_index "${2:-}" || usage
        pactl set-sink-input-mute "$2" toggle
        ;;
    set-default-sink)
        [[ -n ${2:-} ]] || usage
        pactl set-default-sink "$2"
        ;;
    set-default-source)
        [[ -n ${2:-} ]] || usage
        pactl set-default-source "$2"
        ;;
    mic-volume)
        volume=$(percent "${2:-}") || usage
        pactl set-source-volume @DEFAULT_SOURCE@ "${volume}%"
        ;;
    mic-mute)
        case "${2:-}" in
            on) pactl set-source-mute @DEFAULT_SOURCE@ 1 ;;
            off) pactl set-source-mute @DEFAULT_SOURCE@ 0 ;;
            *) usage ;;
        esac
        ;;
    *)
        usage
        ;;
esac
