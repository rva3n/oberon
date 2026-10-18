#!/bin/sh
# Установщик Oberon — Material 3 shell для композитора Umbriel.
#
#   curl -fsSL https://raw.githubusercontent.com/rva3n/oberon/main/install.sh | sh
#   # с флагами:  ... | sh -s -- --start
#
# Флаги: --no-deps (не трогать pacman), --no-build, --no-wire (не править
# конфиги Umbriel), --start (запустить после установки).
set -eu

DIR="$HOME/oberon"
REPO="https://github.com/rva3n/oberon.git"
NO_DEPS=0 NO_BUILD=0 NO_WIRE=0 START=0

for a in "$@"; do
	case "$a" in
		--no-deps) NO_DEPS=1 ;;
		--no-build) NO_BUILD=1 ;;
		--no-wire) NO_WIRE=1 ;;
		--start) START=1 ;;
		-h|--help)
			cat <<'EOF'
Oberon installer (Arch/Umbriel)

  curl -fsSL https://raw.githubusercontent.com/rva3n/oberon/main/install.sh | sh
  # флаги (через sh -s --):  ... | sh -s -- --start

Флаги:
  --no-deps   не ставить системные пакеты (pacman)
  --no-build  не собирать (только клон/обновление и конфиги)
  --no-wire   не трогать конфиги Umbriel
  --start     запустить шелл после установки

Ставится в ~/oberon (путь зашит в шелле).
EOF
			exit 0 ;;
		*) echo "неизвестный флаг: $a (--help для справки)" >&2; exit 2 ;;
	esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] && die "запускай от обычного пользователя (sudo спросится сам)"

if ! grep -qiE '^(ID=arch|ID_LIKE=.*arch)' /etc/os-release 2>/dev/null; then
	echo "!! Замечено не-Arch окружение — зависимости pacman'ом не ставлю."
	NO_DEPS=1
fi

# ── системные зависимости ─────────────────────────────────────────────
if [ "$NO_DEPS" = 0 ]; then
	say "Системные зависимости (pacman)"
	PKGS="base-devel cmake ninja git pkgconf jq curl python
qt6-base qt6-declarative qt6-svg qt6-wayland qt6-shadertools
jemalloc libdrm mesa pipewire wireplumber glib2 polkit wayland wayland-protocols
libxcb xcb-util-cursor xcb-util-wm
pugixml hyprlang hyprutils sdbus-cpp
fftw ncurses iniparser alsa-lib libpulse
grim slurp wf-recorder ffmpeg wl-clipboard cliphist imagemagick ddcutil gammastep
procps-ng upower bluez-utils networkmanager
tesseract tesseract-data-eng tesseract-data-rus"
	# shellcheck disable=SC2086
	sudo pacman -S --needed --noconfirm $PKGS
	if ! command -v cargo >/dev/null 2>&1; then
		sudo pacman -S --needed --noconfirm rust
	fi
fi

# ── клон / обновление ─────────────────────────────────────────────────
if [ -d "$DIR/.git" ]; then
	say "Обновляю репозиторий: $DIR"
	if ! git -C "$DIR" pull --ff-only; then
		die "не удалось обновить ~/oberon (локальные изменения?) — приведи репо в порядок и повтори"
	fi
	git -C "$DIR" submodule update --init --recursive
elif [ -e "$DIR" ]; then
	die "$DIR уже существует, но это не git-репозиторий — убери его и повтори"
else
	say "Клонирую Oberon в $DIR"
	git clone --recurse-submodules "$REPO" "$DIR"
fi

# ── сборка ────────────────────────────────────────────────────────────
if [ "$NO_BUILD" = 0 ]; then
	say "Сборка вендорного стека (первый раз ~10–20 минут)"
	sh "$DIR/scripts/build-deps.sh" </dev/null
fi

# ── конфиги Umbriel ───────────────────────────────────────────────────
QSBIN="$DIR/build/prefix/bin/oberonqs"
HLBIN="$DIR/build/prefix/bin/oberonidle"
UMB="$HOME/.config/umbriel"
if [ "$NO_WIRE" = 1 ] || [ ! -d "$UMB" ]; then
	echo "~/.config/umbriel не найден (или --no-wire) — конфиги не трогаю."
elif [ ! -x "$QSBIN" ]; then
	echo "!! бинарники не собраны ($QSBIN нет) — конфиги Umbriel не трогаю."
else
	say "Конфиги Umbriel"
	TS=$(date +%Y%m%d-%H%M%S)
	G="$UMB/src/general.toml"; K="$UMB/src/keybinds.toml"; R="$UMB/src/rules.toml"
	QSE=$(printf '%s' "$QSBIN" | sed -e 's/[\\&|]/\\&/g')
	HLE=$(printf '%s' "$HLBIN" | sed -e 's/[\\&|]/\\&/g')

	if [ -f "$UMB/hypridle.conf" ] && [ ! -f "$UMB/oberonidle.conf" ]; then
		mv "$UMB/hypridle.conf" "$UMB/oberonidle.conf"
		echo "  hypridle.conf -> oberonidle.conf"
	fi
	if [ -f "$G" ] && grep -qE '/usr/bin/qs -p |"qs -p |spawn:qs -p |"hypridle -c |hypridle\.conf' "$G"; then
		cp -a "$G" "$G.bak-$TS"
		sed -i -E "s|/usr/bin/qs -p |$QSE -p |g; s|\"qs -p |\"$QSE -p |g; s|spawn:qs -p |spawn:$QSE -p |g; s|\"hypridle -c |\"$HLE -c |g; s|hypridle\.conf|oberonidle.conf|g" "$G"
		echo "  general.toml: автозапуск -> Oberon (бэкап: $G.bak-$TS)"
	fi
	if [ -f "$K" ] && grep -qE '/usr/bin/qs -p |"qs -p |spawn:qs -p ' "$K"; then
		cp -a "$K" "$K.bak-$TS"
		sed -i -E "s|/usr/bin/qs -p |$QSE -p |g; s|\"qs -p |\"$QSE -p |g; s|spawn:qs -p |spawn:$QSE -p |g" "$K"
		echo "  keybinds.toml: qs -p -> oberonqs (бэкап: $K.bak-$TS)"
	fi
	if [ -f "$R" ] && ! grep -q 'oberon-island' "$R"; then
		cp -a "$R" "$R.bak-$TS"
		cat >> "$R" <<'EOF'

# Блюр по контуру острова Oberon (добавлено установщиком)
[[layer_rule]]
match.namespace = "^(oberon-island|oberon-media)$"
blur = true
blur_ignore_alpha = 0.2
EOF
		echo "  rules.toml: добавлено blur-правило (бэкап: $R.bak-$TS)"
	fi
	if command -v umbriel >/dev/null 2>&1; then
		umbriel config validate || true
	fi
fi

# ── запуск ────────────────────────────────────────────────────────────
if [ "$START" = 1 ] && [ -x "$QSBIN" ]; then
	say "Запускаю Oberon"
	setsid "$QSBIN" -p "$DIR" >/dev/null 2>&1 < /dev/null &
fi

# ── сводка ────────────────────────────────────────────────────────────
say "Сводка"
echo "  шелл:       $DIR"
echo "  бинарники:  $DIR/build/prefix/bin (oberonqs, oberoncolor, oberonwall, oberonwall-daemon, oberoncava, oberonidle)"
echo "  запуск:     $QSBIN -p $DIR"
echo "  обновление: повторить установочную команду"
