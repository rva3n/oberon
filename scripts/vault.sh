#!/usr/bin/env bash
# Oberon password vault. Passwords are accepted only on stdin and are passed
# to OpenSSL through a short-lived mode-600 file in the user's runtime tmpfs.

set -eu
umask 077

if [ -z "${HOME:-}" ]; then
    echo "HOME is not set" >&2
    exit 1
fi

DIR="$HOME/.local/state/oberon"
STORE="$DIR/vault.enc"
ITER=240000
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/dev/shm}"
PWFILE=""
JSONFILE=""
PLAINFILE=""
STORE_TMP=""

cleanup() {
    [ -z "$PWFILE" ] || rm -f -- "$PWFILE"
    [ -z "$JSONFILE" ] || rm -f -- "$JSONFILE"
    [ -z "$PLAINFILE" ] || rm -f -- "$PLAINFILE"
    [ -z "$STORE_TMP" ] || rm -f -- "$STORE_TMP"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

make_runtime_file() {
    if [ ! -d "$RUNTIME_DIR" ] || [ ! -w "$RUNTIME_DIR" ]; then
        RUNTIME_DIR=/dev/shm
    fi
    if [ ! -d "$RUNTIME_DIR" ] || [ ! -w "$RUNTIME_DIR" ]; then
        echo "No writable runtime directory" >&2
        return 1
    fi
    mktemp "$RUNTIME_DIR/oberon-vault.XXXXXX"
}

read_password() {
    PWFILE="$(make_runtime_file)" || return 1
    chmod 600 "$PWFILE"
    password=""
    IFS= read -r password || return 1
    if [ -z "$password" ]; then
        unset password
        return 1
    fi
    printf '%s' "$password" > "$PWFILE"
    unset password
}

new_runtime_file() {
    local path
    path="$(make_runtime_file)" || return 1
    chmod 600 "$path"
    printf '%s' "$path"
}

valid_entries() {
    jq -s -e 'length == 1 and (.[0] |
        type == "array" and all(.[];
        type == "object" and
        (.name | type == "string") and
        (.user | type == "string") and
        (.pass | type == "string") and
        (.url | type == "string") and
        (.notes | type == "string")))' "$1" >/dev/null 2>&1
}

encrypt_store() {
    STORE_TMP="$(mktemp "$DIR/.vault.enc.XXXXXX")" || return 1
    chmod 600 "$STORE_TMP"
    openssl enc -aes-256-cbc -pbkdf2 -iter "$ITER" -salt \
        -in "$JSONFILE" -out "$STORE_TMP" -pass "file:$PWFILE" || return 1
    chmod 600 "$STORE_TMP"
    mv -f -- "$STORE_TMP" "$STORE"
    STORE_TMP=""
    chmod 600 "$STORE"
}

decrypt_store() {
    [ -s "$STORE" ] || return 1
    PLAINFILE="$(new_runtime_file)" || return 1
    if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter "$ITER" \
            -in "$STORE" -out "$PLAINFILE" -pass "file:$PWFILE" 2>/dev/null; then
        return 2
    fi
    valid_entries "$PLAINFILE" || return 2
}

case "${1:-}" in
    exists)
        if [ -s "$STORE" ]; then
            printf 'да\n'
        else
            printf 'нет\n'
        fi
        ;;
    init)
        [ ! -e "$STORE" ] || { echo "Vault already exists" >&2; exit 1; }
        read_password || { echo "A non-empty password is required" >&2; exit 1; }
        mkdir -p "$DIR"
        chmod 700 "$DIR"
        JSONFILE="$(new_runtime_file)"
        printf '[]' > "$JSONFILE"
        encrypt_store
        ;;
    unlock)
        read_password || { echo "A non-empty password is required" >&2; exit 1; }
        decrypt_store || {
            result=$?
            [ "$result" -eq 2 ] && exit 2
            echo "Vault does not exist or cannot be read" >&2
            exit 1
        }
        cat -- "$PLAINFILE"
        ;;
    save)
        read_password || { echo "A non-empty password is required" >&2; exit 1; }
        JSONFILE="$(new_runtime_file)"
        cat > "$JSONFILE"
        valid_entries "$JSONFILE" || { echo "Invalid vault entries" >&2; exit 1; }
        decrypt_store || {
            result=$?
            [ "$result" -eq 2 ] && exit 2
            echo "Vault does not exist or cannot be read" >&2
            exit 1
        }
        mkdir -p "$DIR"
        chmod 700 "$DIR"
        encrypt_store
        ;;
    *)
        echo "usage: vault.sh exists|init|unlock|save" >&2
        exit 1
        ;;
esac
