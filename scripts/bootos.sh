#!/usr/bin/env bash
# Одноразовый выбор другой ОС. Перезагрузку выполняет вызывающая сторона.
set -u

GRUB_CFG="/boot/grub/grub.cfg"

grub_cmd() {
    for cmd in grub-reboot grub2-reboot; do
        if command -v "$cmd" >/dev/null 2>&1; then
            printf '%s' "$cmd"
            return 0
        fi
    done
    return 1
}

pretty_name() {
    printf '%s' "$1" \
        | sed -E \
            -e 's/ \(on \/dev\/[^)]*\)//g' \
            -e 's/[[:space:]]+[Bb]oot [Mm]anager$//; s/[[:space:]]+[Bb]ootloader$//' \
            -e 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

json_entry() {
    jq -cn --arg id "$1" --arg name "$2" --arg kind "$3" \
        '{id: $id, name: $name, kind: $kind}' 2>/dev/null
}

list_grub() {
    [ -r "$GRUB_CFG" ] || return 1
    grub_cmd >/dev/null || return 1

    while IFS= read -r line; do
        [[ "$line" == *osprober-* ]] || continue
        title=$(printf '%s\n' "$line" | sed -n "s/^[[:space:]]*menuentry '\([^']*\)'.*/\1/p")
        id=$(printf '%s\n' "$line" | grep -oE 'osprober-[a-zA-Z0-9._-]+' | head -n 1)
        [ -n "$title" ] && [ -n "$id" ] || continue

        kind=other
        case "${line,,}" in
            *--class\ windows*) kind=windows ;;
            *--class\ macosx*|*--class\ osx*) kind=mac ;;
            *--class\ gnu-linux*|*--class\ linux*) kind=linux ;;
        esac

        json_entry "$id" "$(pretty_name "$title")" "$kind"
    done < "$GRUB_CFG"
}

list_efi() {
    command -v efibootmgr >/dev/null 2>&1 || return 1
    local output current order line id name lower kind
    local -a boot_ids=()
    output=$(efibootmgr -v 2>/dev/null) || return 1
    current=$(printf '%s\n' "$output" | sed -n 's/^BootCurrent:[[:space:]]*//p' | head -n 1)
    order=$(printf '%s\n' "$output" | sed -n 's/^BootOrder:[[:space:]]*//p' | head -n 1 | tr -d '[:space:]')

    if [ -n "$order" ]; then
        IFS=',' read -r -a boot_ids <<< "$order"
    else
        while IFS= read -r line; do
            if [[ "$line" =~ ^Boot([[:xdigit:]]{4})\* ]]; then
                boot_ids+=("${BASH_REMATCH[1]}")
            fi
        done <<< "$output"
    fi

    for id in "${boot_ids[@]}"; do
        id=${id^^}
        [[ "$id" =~ ^[A-F0-9]{4}$ ]] || continue
        [ "$id" = "${current^^}" ] && continue
        line=$(printf '%s\n' "$output" | grep -m 1 -E "^Boot${id}\\*?[[:space:]]" || true)
        [ -n "$line" ] || continue
        name=$(printf '%s\n' "$line" | sed -E \
            -e 's/^Boot[0-9A-Fa-f]{4}\*?[[:space:]]*//' \
            -e 's/[[:space:]]+(HD|File|VenHw|FvFile|Acpi|PciRoot|USB|NVMe|SD|Uri|BBS|GPT)\(.*$//' \
            -e 's/\t.*$//' \
            -e 's/^[[:space:]]+//; s/[[:space:]]+$//')
        [ -n "$name" ] || continue
        lower=${name,,}
        case "$lower" in
            uefi:*|"uefi os"|grub|grub*|refind|systemd-boot*|"linux boot manager"|*cd/dvd*|*removable*|*network*) continue ;;
        esac

        kind=other
        case "${lower} ${line,,}" in
            *microsoft*|*bootmgfw.efi*) kind=windows ;;
            *apple*|*macos*|*system\\library*) kind=mac ;;
            *linux*|*vmlinuz*) kind=linux ;;
        esac
        json_entry "efi:$id" "$(pretty_name "$name")" "$kind"
    done
}

list_json() {
    command -v jq >/dev/null 2>&1 || { printf '[]\n'; return 0; }
    local entries
    entries=$(list_grub 2>/dev/null || true)
    [ -n "$entries" ] || entries=$(list_efi 2>/dev/null || true)
    [ -n "$entries" ] || { printf '[]\n'; return 0; }
    printf '%s\n' "$entries" | jq -cs '.' 2>/dev/null || printf '[]\n'
}

boot_into() {
    local id="${1:-}" cmd number
    [ -n "$id" ] || { echo "no id" >&2; return 2; }

    case "$id" in
        efi:*)
            number=${id#efi:}
            [[ "$number" =~ ^[[:xdigit:]]{4}$ ]] || { echo "invalid efi id" >&2; return 2; }
            command -v efibootmgr >/dev/null 2>&1 || { echo "no efibootmgr" >&2; return 1; }
            efibootmgr --bootnext "$number" >/dev/null 2>&1 || { echo "bootnext failed" >&2; return 1; }
            ;;
        osprober-*)
            [[ "$id" =~ ^osprober-[a-zA-Z0-9._-]+$ ]] || { echo "invalid grub id" >&2; return 2; }
            cmd=$(grub_cmd) || { echo "no grub-reboot" >&2; return 1; }
            "$cmd" "$id" >/dev/null 2>&1 || { echo "grub-reboot failed" >&2; return 1; }
            ;;
        *)
            echo "invalid id" >&2
            return 2
            ;;
    esac
}

case "${1:-list}" in
    list) list_json ;;
    boot) boot_into "${2:-}" ;;
    *) echo "usage: bootos.sh list|boot <id>" >&2; exit 2 ;;
esac
