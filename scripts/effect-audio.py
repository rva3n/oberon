#!/usr/bin/env python3
"""Oberon -> Umbriel audio-reactive shader bridge.

Reads normalized audio levels (0.0..1.0 float per line) from sys.stdin
(or semicolon/space-separated Cava bar values 0..100), connects to Umbriel's
UNIX socket ($UMBRIEL_SOCKET or $XDG_RUNTIME_DIR/umbriel-$WAYLAND_DISPLAY.sock),
and sends:
    {"cmd":"effect-audio","version":1,"level":<0.0..1.0>}\n
reading the {"ok":true} acknowledgment up to 45 times/sec.
Uses select() with a 100ms timeout to keep sending 0.0 during silence so
Umbriel's 250ms watchdog keeps umbriel_audio_available() = 1 while active.
"""
import glob
import os
import select
import signal
import socket
import sys
import time

MAX_FPS = 45.0
MIN_INTERVAL = 1.0 / MAX_FPS
SELECT_TIMEOUT = 0.100  # 100ms watchdog heartbeat (< 250ms Umbriel watchdog)
RECONNECT_BACKOFF = 0.25


def resolve_socket_path() -> str:
    env_sock = os.environ.get("UMBRIEL_SOCKET", "").strip()
    if env_sock:
        return env_sock

    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "").strip()
    if not runtime_dir:
        runtime_dir = f"/run/user/{os.getuid()}"

    wayland_display = os.environ.get("WAYLAND_DISPLAY", "").strip()
    if wayland_display:
        candidate = os.path.join(runtime_dir, f"umbriel-{wayland_display}.sock")
        if os.path.exists(candidate):
            return candidate
        # Return expected path even if compositor socket is not ready yet
        matches = sorted(glob.glob(os.path.join(runtime_dir, "umbriel-*.sock")))
        return matches[0] if matches else candidate

    matches = sorted(glob.glob(os.path.join(runtime_dir, "umbriel-*.sock")))
    if matches:
        return matches[0]
    return os.path.join(runtime_dir, "umbriel-wayland-1.sock")


def parse_level(line: str):
    raw = line.strip().rstrip(";").strip()
    if not raw:
        return None

    # Single float value (0.0..1.0 or 0..100)
    if ";" not in raw and " " not in raw and "\t" not in raw:
        try:
            val = float(raw)
        except ValueError:
            return None
        if val > 1.0:
            val = val / 100.0
        return max(0.0, min(1.0, val))

    # Semicolon- or whitespace-separated Cava bar values (0..100 or 0.0..1.0)
    sep = ";" if ";" in raw else None
    tokens = raw.split(sep) if sep else raw.split()
    vals = []
    for tok in tokens:
        tok = tok.strip()
        if not tok:
            continue
        try:
            vals.append(float(tok))
        except ValueError:
            continue

    if not vals:
        return None

    # Normalize 0..100 Cava values if needed
    scale = 100.0 if any(v > 1.0 for v in vals) else 1.0
    norm = [max(0.0, min(1.0, v / scale)) for v in vals]

    # Bass + peak + average blend
    bass_count = max(1, int(len(norm) * 0.35))
    bass_avg = sum(norm[:bass_count]) / bass_count
    overall_avg = sum(norm) / len(norm)
    peak = max(norm)
    level = 0.50 * bass_avg + 0.30 * peak + 0.20 * overall_avg
    return max(0.0, min(1.0, level))


class UmbrielAudioClient:
    def __init__(self):
        self.sock = None
        self.rx_buf = b""
        self.last_connect_attempt = 0.0

    def close(self):
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None
        self.rx_buf = b""

    def ensure_connected(self) -> bool:
        if self.sock is not None:
            return True
        now = time.monotonic()
        if now - self.last_connect_attempt < RECONNECT_BACKOFF:
            return False
        self.last_connect_attempt = now
        path = resolve_socket_path()
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.5)
            s.connect(path)
            self.sock = s
            self.rx_buf = b""
            return True
        except OSError:
            try:
                s.close()
            except Exception:
                pass
            self.sock = None
            return False

    def send_level(self, level: float) -> bool:
        clamped = max(0.0, min(1.0, float(level)))
        if not self.ensure_connected():
            return False
        msg = f'{{"cmd":"effect-audio","version":1,"level":{clamped:.4f}}}\n'.encode("utf-8")
        try:
            self.sock.sendall(msg)
            # Read {"ok":true} acknowledgment line
            while b"\n" not in self.rx_buf:
                chunk = self.sock.recv(256)
                if not chunk:
                    raise ConnectionResetError("EOF from Umbriel socket")
                self.rx_buf += chunk
            nl = self.rx_buf.find(b"\n")
            self.rx_buf = self.rx_buf[nl + 1 :]
            return True
        except OSError:
            self.close()
            # Try one immediate reconnect if the socket reset
            if self.ensure_connected():
                try:
                    self.sock.sendall(msg)
                    while b"\n" not in self.rx_buf:
                        chunk = self.sock.recv(256)
                        if not chunk:
                            raise ConnectionResetError("EOF on retry")
                        self.rx_buf += chunk
                    nl = self.rx_buf.find(b"\n")
                    self.rx_buf = self.rx_buf[nl + 1 :]
                    return True
                except OSError:
                    self.close()
            return False


def main() -> int:
    running = True

    def _stop(_signum, _frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    stdin_fd = sys.stdin.fileno()
    os.set_blocking(stdin_fd, False)

    client = UmbrielAudioClient()
    in_buf = b""
    last_send = 0.0
    pending_level = None

    try:
        while running:
            now = time.monotonic()
            if pending_level is not None:
                wait = max(0.0, MIN_INTERVAL - (now - last_send))
                timeout = min(SELECT_TIMEOUT, wait)
            else:
                timeout = SELECT_TIMEOUT

            try:
                readable, _, _ = select.select([stdin_fd], [], [], timeout)
            except (InterruptedError, ValueError):
                break

            eof = False
            if readable:
                while True:
                    try:
                        chunk = os.read(stdin_fd, 4096)
                    except BlockingIOError:
                        break
                    except OSError:
                        eof = True
                        break
                    if not chunk:
                        eof = True
                        break
                    in_buf += chunk

                while b"\n" in in_buf:
                    raw_line, in_buf = in_buf.split(b"\n", 1)
                    lvl = parse_level(raw_line.decode("utf-8", errors="ignore"))
                    if lvl is not None:
                        pending_level = lvl

            now = time.monotonic()
            if pending_level is not None and (now - last_send) >= MIN_INTERVAL:
                client.send_level(pending_level)
                last_send = time.monotonic()
                pending_level = None
            elif pending_level is None and (now - last_send) >= SELECT_TIMEOUT:
                # Silence keepalive (100ms timeout) so Umbriel's 250ms watchdog stays alive
                client.send_level(0.0)
                last_send = time.monotonic()

            if eof:
                if in_buf:
                    lvl = parse_level(in_buf.decode("utf-8", errors="ignore"))
                    if lvl is not None:
                        client.send_level(lvl)
                break
    finally:
        client.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
