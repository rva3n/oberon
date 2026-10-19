#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
GREETD_CONFIG="/etc/greetd/config.toml"
GREETD_BACKUP="/etc/greetd/config.toml.pre-oberon.bak"
POLKIT_RULE="/etc/polkit-1/rules.d/49-oberon-greeter.rules"
POLKIT_BACKUP="${POLKIT_RULE}.pre-oberon.bak"

if [[ "$EUID" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || { printf 'sudo is required.\n' >&2; exit 1; }
    SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
    exec sudo -- "$SCRIPT_PATH" "$@"
fi

if [[ -f "$GREETD_BACKUP" ]]; then
    RESTORE_TMP="$(mktemp "${GREETD_CONFIG}.restore.XXXXXX")"
    cp -a -- "$GREETD_BACKUP" "$RESTORE_TMP"
    mv -f -- "$RESTORE_TMP" "$GREETD_CONFIG"
    printf 'Restored %s from its pre-Oberon backup.\n' "$GREETD_CONFIG"
elif [[ -f "$GREETD_CONFIG" ]] && grep -Fq '/usr/local/bin/oberon-greeter' "$GREETD_CONFIG"; then
    printf 'Refusing to remove the greeter: %s is missing while greetd config still references it.\n' "$GREETD_BACKUP" >&2
    exit 1
else
    printf 'No greetd backup found; current config does not reference the Oberon wrapper.\n'
fi

rm -rf -- /usr/local/lib/oberon-greeter
rm -f -- /usr/local/bin/oberon-greeter

if [[ -f "$POLKIT_BACKUP" ]]; then
    install -d -o root -g root -m 0755 "$(dirname -- "$POLKIT_RULE")"
    RULE_RESTORE_TMP="$(mktemp "${POLKIT_RULE}.restore.XXXXXX")"
    cp -a -- "$POLKIT_BACKUP" "$RULE_RESTORE_TMP"
    mv -f -- "$RULE_RESTORE_TMP" "$POLKIT_RULE"
elif [[ -e "$POLKIT_RULE" ]]; then
    rm -f -- "$POLKIT_RULE"
fi

printf 'Removed /usr/local/lib/oberon-greeter and /usr/local/bin/oberon-greeter.\n'
printf 'If polkit was installed before Oberon, its saved rule remains at %s.\n' "$POLKIT_BACKUP"
printf 'Rollback completed.\n'
