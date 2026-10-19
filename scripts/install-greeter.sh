#!/usr/bin/env bash
set -euo pipefail

POLKIT=0
for argument in "$@"; do
    case "$argument" in
        --polkit) POLKIT=1 ;;
        -h|--help)
            printf 'Usage: %s [--polkit]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\nUsage: %s [--polkit]\n' "$argument" "$0" >&2
            exit 2
            ;;
    esac
done

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
GREETER_SOURCE="$PROJECT_ROOT/greeter"
QS_SOURCE="$PROJECT_ROOT/build/prefix/bin/oberonqs"
DEST_DIR="/usr/local/lib/oberon-greeter"
INSTALL_BIN="/usr/local/bin/oberon-greeter"
GREETD_CONFIG="/etc/greetd/config.toml"
GREETD_BACKUP="/etc/greetd/config.toml.pre-oberon.bak"
POLKIT_RULE="/etc/polkit-1/rules.d/49-oberon-greeter.rules"
POLKIT_BACKUP="${POLKIT_RULE}.pre-oberon.bak"

[[ -d "$GREETER_SOURCE" ]] || { printf 'Greeter source not found: %s\n' "$GREETER_SOURCE" >&2; exit 1; }
[[ -f "$GREETER_SOURCE/greetd_client.py" ]] || { printf 'Missing greeter/greetd_client.py (complete wave G1 first).\n' >&2; exit 1; }
[[ -f "$GREETER_SOURCE/shell.qml" ]] || { printf 'Missing greeter/shell.qml.\n' >&2; exit 1; }
[[ -f "$GREETER_SOURCE/greeter.sh" ]] || { printf 'Missing greeter/greeter.sh.\n' >&2; exit 1; }
[[ -x "$QS_SOURCE" ]] || { printf 'Built oberonqs not found or not executable: %s\n' "$QS_SOURCE" >&2; exit 1; }

if [[ "$EUID" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || { printf 'sudo is required.\n' >&2; exit 1; }
    SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
    exec sudo -- "$SCRIPT_PATH" "$@"
fi

[[ -d /etc/greetd ]] || { printf '/etc/greetd does not exist; refusing to install.\n' >&2; exit 1; }
[[ -f "$GREETD_CONFIG" ]] || { printf 'greetd config not found: %s\n' "$GREETD_CONFIG" >&2; exit 1; }
getent passwd greeter >/dev/null || { printf 'System user greeter does not exist.\n' >&2; exit 1; }

STAGE=""
CONFIG_TMP=""
RULE_TMP=""
cleanup() {
    [[ -z "$STAGE" || ! -d "$STAGE" ]] || rm -rf -- "$STAGE"
    [[ -z "$CONFIG_TMP" || ! -e "$CONFIG_TMP" ]] || rm -f -- "$CONFIG_TMP"
    [[ -z "$RULE_TMP" || ! -e "$RULE_TMP" ]] || rm -f -- "$RULE_TMP"
}
trap cleanup EXIT

install -d -o root -g root -m 0755 "$DEST_DIR"
STAGE="$(mktemp -d "$DEST_DIR/.staging.XXXXXX")"
cp -R -- "$GREETER_SOURCE" "$STAGE/greeter"
find "$STAGE/greeter" -type d -exec chmod 0755 {} +
find "$STAGE/greeter" -type f -exec chmod 0644 {} +
chmod 0755 "$STAGE/greeter/greeter.sh"
install -o root -g root -m 0755 "$QS_SOURCE" "$STAGE/oberonqs"

rm -rf -- "$DEST_DIR/greeter"
mv -- "$STAGE/greeter" "$DEST_DIR/greeter"
mv -- "$STAGE/oberonqs" "$DEST_DIR/oberonqs"
rmdir -- "$STAGE"
STAGE=""
install -o root -g root -m 0755 "$GREETER_SOURCE/greeter.sh" "$INSTALL_BIN"

# Keep the first pre-Oberon config intact across reinstallations.
if [[ ! -e "$GREETD_BACKUP" ]]; then
    cp -a -- "$GREETD_CONFIG" "$GREETD_BACKUP"
fi

if (( POLKIT )); then
    install -d -o root -g root -m 0755 "$(dirname -- "$POLKIT_RULE")"
    if [[ -e "$POLKIT_RULE" && ! -e "$POLKIT_BACKUP" ]]; then
        cp -a -- "$POLKIT_RULE" "$POLKIT_BACKUP"
    fi
    RULE_TMP="$(mktemp "${POLKIT_RULE}.tmp.XXXXXX")"
    cat >"$RULE_TMP" <<'EOF'
polkit.addRule(function(action, subject) {
    var allowed = [
        "org.freedesktop.login1.power-off",
        "org.freedesktop.login1.power-off-multiple-sessions",
        "org.freedesktop.login1.reboot",
        "org.freedesktop.login1.reboot-multiple-sessions",
        "org.freedesktop.login1.suspend",
        "org.freedesktop.login1.suspend-multiple-sessions"
    ];
    if (subject.user === "greeter" && allowed.indexOf(action.id) !== -1)
        return polkit.Result.YES;
});
EOF
    chmod 0644 "$RULE_TMP"
    chown root:root "$RULE_TMP"
    mv -f -- "$RULE_TMP" "$POLKIT_RULE"
    RULE_TMP=""
fi

CONFIG_TMP="$(mktemp "${GREETD_CONFIG}.tmp.XXXXXX")"
cat >"$CONFIG_TMP" <<'EOF'
[terminal]
vt = 1

[default_session]
command = "dbus-run-session cage -s -mlast -d -- /usr/local/bin/oberon-greeter"
user = "greeter"
EOF
chmod 0644 "$CONFIG_TMP"
chown root:root "$CONFIG_TMP"
mv -f -- "$CONFIG_TMP" "$GREETD_CONFIG"
CONFIG_TMP=""

printf 'Oberon greeter installed to %s.\n' "$DEST_DIR"
if (( POLKIT )); then
    printf 'Power actions enabled for user greeter by %s.\n' "$POLKIT_RULE"
else
    printf 'No polkit rule installed; power actions work only if existing permissions allow them.\n'
fi
printf '\nCheck: save your work, log out of the graphical session to return to greetd, then verify sign-in; a reboot can check the boot path.\n'
printf 'Rollback: sudo %s/scripts/greeter-revert.sh\n' "$PROJECT_ROOT"
