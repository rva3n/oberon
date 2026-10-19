#!/usr/bin/env python3
"""JSON-lines greeter bridge for greetd's Unix-socket protocol."""

import json
import os
import pwd
import re
import select
import shlex
import socket
import struct
import subprocess
import sys
from pathlib import Path


SESSION_DIRS = (
    Path("/usr/share/wayland-sessions"),
    Path("/usr/local/share/wayland-sessions"),
)
AUTH_MESSAGE_TYPES = {"secret", "visible", "info", "error"}
MAX_FRAME_SIZE = 16 * 1024 * 1024


class GreetdProtocolError(Exception):
    """An invalid or incomplete greetd protocol frame."""


def encode_frame(message):
    """Encode one greetd JSON object using the protocol's native u32 prefix."""
    try:
        body = json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    except (TypeError, ValueError, UnicodeEncodeError):
        raise GreetdProtocolError("Некорректный запрос greetd") from None
    if len(body) > 0xFFFFFFFF:
        raise GreetdProtocolError("Слишком большой запрос greetd")
    return struct.pack("=I", len(body)) + body


def _extract_frames(buffer):
    messages = []
    while len(buffer) >= 4:
        size = struct.unpack_from("=I", buffer)[0]
        if size > MAX_FRAME_SIZE:
            raise GreetdProtocolError("Слишком большой ответ greetd")
        frame_size = 4 + size
        if len(buffer) < frame_size:
            break
        body = bytes(buffer[4:frame_size])
        del buffer[:frame_size]
        try:
            message = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise GreetdProtocolError("Некорректный ответ greetd") from None
        if not isinstance(message, dict) or not isinstance(message.get("type"), str):
            raise GreetdProtocolError("Некорректный ответ greetd")
        messages.append(message)
    return messages


def get_users():
    """Return local login users suitable for the greeter's user list."""
    users = []
    try:
        entries = pwd.getpwall()
    except OSError:
        return users

    for entry in entries:
        if not 1000 <= entry.pw_uid <= 59999:
            continue
        if os.path.basename((entry.pw_shell or "").strip()) in {"nologin", "false"}:
            continue
        if not entry.pw_dir or not os.path.isdir(entry.pw_dir):
            continue
        display = (entry.pw_gecos or "").split(",", 1)[0].strip() or entry.pw_name
        users.append({"name": entry.pw_name, "display": display, "uid": entry.pw_uid})

    return sorted(users, key=lambda user: user["name"].casefold())


def get_sessions(directories=SESSION_DIRS):
    """Read Wayland desktop entries and return greetd start-session data."""
    sessions_by_id = {}
    for directory in directories:
        try:
            desktop_files = sorted(directory.glob("*.desktop"))
        except OSError:
            continue

        for desktop_file in desktop_files:
            try:
                contents = desktop_file.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue

            in_desktop_entry = False
            name = ""
            exec_line = ""
            for raw_line in contents.splitlines():
                line = raw_line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("[") and line.endswith("]"):
                    in_desktop_entry = line == "[Desktop Entry]"
                    continue
                if not in_desktop_entry:
                    continue
                key, separator, value = line.partition("=")
                if not separator:
                    continue
                if key.strip() == "Name":
                    name = value.strip()
                elif key.strip() == "Exec":
                    exec_line = value.strip()

            if not exec_line:
                continue
            # Desktop Exec field codes are placeholders, not argv values.
            without_field_codes = re.sub(r"%(?:[A-Za-z]|%)", "", exec_line)
            try:
                command = [part for part in shlex.split(without_field_codes) if part]
            except ValueError:
                continue
            if not command:
                continue

            session_id = desktop_file.stem
            sessions_by_id.setdefault(
                session_id,
                {
                    "id": session_id,
                    "name": name or session_id,
                    "cmd": command,
                    "env": [],
                },
            )

    sessions = list(sessions_by_id.values())
    sessions.sort(
        key=lambda session: (
            0
            if session["id"].casefold() == "umbriel" or session["name"].casefold() == "umbriel"
            else 1,
            session["name"].casefold(),
            session["id"].casefold(),
        )
    )
    return sessions


class GreetdBridge:
    """Translate JSON-line commands into greetd protocol requests."""

    def __init__(self, emit_event, socket_path=None, session_loader=get_sessions):
        self.emit_event = emit_event
        self.socket_path = os.environ.get("GREETD_SOCK") if socket_path is None else socket_path
        self.session_loader = session_loader
        self.sock = None
        self.rx_buffer = bytearray()
        self.state = "idle"
        self.selected_session_id = ""
        self.initial_password = None

    def _emit(self, event, **values):
        self.emit_event({"event": event, **values})

    def _close_connection(self):
        sock = self.sock
        self.sock = None
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass
        self.rx_buffer.clear()
        self.state = "idle"
        self.selected_session_id = ""
        self.initial_password = None

    def close(self):
        """Close the active socket without emitting an event."""
        self._close_connection()

    def _fail(self, description):
        self._emit("error", description=description)
        self._close_connection()

    def _connect(self):
        if not self.socket_path:
            self._emit("error", description="GREETD_SOCK не задан")
            return False

        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        except OSError:
            self._emit("error", description="Не удалось подключиться к greetd")
            return False
        try:
            sock.connect(self.socket_path)
        except OSError:
            sock.close()
            self._emit("error", description="Не удалось подключиться к greetd")
            return False
        self.sock = sock
        self.rx_buffer.clear()
        return True

    def _send(self, message):
        if self.sock is None:
            self._fail("Соединение с greetd закрыто")
            return False
        try:
            self.sock.sendall(encode_frame(message))
        except (OSError, GreetdProtocolError):
            self._fail("Не удалось отправить запрос greetd")
            return False
        return True

    def handle_command(self, command):
        if not isinstance(command, dict):
            self._emit("error", description="Некорректная команда")
            return

        command_type = command.get("cmd")
        if command_type == "users":
            self._emit("users", items=get_users())
        elif command_type == "sessions":
            try:
                items = self.session_loader()
            except (OSError, ValueError):
                items = []
            self._emit("sessions", items=items)
        elif command_type == "login":
            self._login(command)
        elif command_type == "answer":
            self._answer(command)
        elif command_type == "start":
            self._start()
        elif command_type == "cancel":
            self._cancel()
        elif command_type == "power":
            self._power(command.get("action"))
        else:
            self._emit("error", description="Неизвестная команда")

    def _login(self, command):
        if self.state != "idle":
            self._emit("error", description="Сначала завершите или отмените текущую сессию")
            return
        username = command.get("user")
        password = command.get("password")
        session_id = command.get("session", "")
        if not isinstance(username, str) or not username:
            self._emit("error", description="Не указано имя пользователя")
            return
        if not isinstance(password, str) or not isinstance(session_id, str):
            self._emit("error", description="Некорректная команда входа")
            return
        if not self._connect():
            return

        self.selected_session_id = session_id
        self.initial_password = password
        self.state = "login_wait"
        self._send({"type": "create_session", "username": username})

    def _answer(self, command):
        if self.state != "answer_wait":
            self._emit("error", description="Сейчас дополнительный ответ не ожидается")
            return
        value = command.get("value")
        if not isinstance(value, str):
            self._emit("error", description="Некорректный ответ")
            return
        self.state = "login_wait"
        self._send({"type": "post_auth_message_response", "response": value})

    def _start(self):
        if self.state != "ready":
            self._emit("error", description="Сначала выполните вход")
            return
        try:
            sessions = self.session_loader()
        except (OSError, ValueError):
            sessions = []
        session = next(
            (item for item in sessions if item.get("id") == self.selected_session_id),
            None,
        )
        if session is None:
            self._emit("error", description="Выбранная Wayland-сессия не найдена")
            return
        command = session.get("cmd")
        environment = session.get("env", [])
        if (
            not isinstance(command, list)
            or not command
            or not all(isinstance(item, str) for item in command)
            or not isinstance(environment, list)
            or not all(isinstance(item, str) for item in environment)
        ):
            self._emit("error", description="Некорректная команда Wayland-сессии")
            return

        self.state = "start_wait"
        self._send({"type": "start_session", "cmd": command, "env": environment})

    def _cancel(self):
        if self.sock is None:
            self._emit("cancelled")
            return
        if self.state == "cancel_wait":
            return
        if self.state not in {"login_wait", "answer_wait", "ready", "start_wait"}:
            self._emit("error", description="Невозможно отменить текущую сессию")
            return
        self.initial_password = None
        self.state = "cancel_wait"
        self._send({"type": "cancel_session"})

    def _power(self, action):
        actions = {"reboot": "reboot", "poweroff": "poweroff", "suspend": "suspend"}
        systemctl_action = actions.get(action) if isinstance(action, str) else None
        if systemctl_action is None:
            self._emit("power_error", description="Неизвестное действие питания")
            return
        try:
            result = subprocess.run(
                ["systemctl", systemctl_action],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
                errors="replace",
                timeout=30,
                check=False,
            )
        except subprocess.TimeoutExpired:
            self._emit("power_error", description="Истекло время ожидания systemctl")
            return
        except OSError:
            self._emit("power_error", description="Не удалось запустить systemctl")
            return

        if result.returncode == 0:
            self._emit("power_ok")
            return
        description = (result.stderr or "").strip()[:512]
        if not description:
            description = "systemctl завершился с ошибкой ({})".format(result.returncode)
        self._emit("power_error", description=description)

    def read_socket(self):
        """Read and dispatch all complete frames currently available."""
        sock = self.sock
        if sock is None:
            return
        try:
            chunk = sock.recv(65536)
        except InterruptedError:
            return
        except OSError:
            self._fail("Ошибка соединения с greetd")
            return
        if not chunk:
            self._fail("Соединение с greetd закрыто")
            return
        self.rx_buffer.extend(chunk)
        try:
            messages = _extract_frames(self.rx_buffer)
        except GreetdProtocolError as error:
            self._fail(str(error))
            return

        for message in messages:
            if self.sock is not sock:
                break
            self._handle_response(message)

    def _handle_response(self, message):
        response_type = message.get("type")
        if response_type == "error":
            error_type = message.get("error_type")
            description = message.get("description")
            if not isinstance(description, str):
                description = "Ошибка greetd"
            event = "auth_error" if error_type == "auth_error" else "error"
            self._emit(event, description=description)
            self._close_connection()
            return

        if response_type == "auth_message":
            if self.state != "login_wait":
                self._fail("Неожиданный запрос аутентификации greetd")
                return
            kind = message.get("auth_message_type")
            text = message.get("auth_message")
            if kind not in AUTH_MESSAGE_TYPES or not isinstance(text, str):
                self._fail("Некорректный запрос аутентификации greetd")
                return
            if kind in {"secret", "visible"} and self.initial_password is not None:
                password = self.initial_password
                self.initial_password = None
                self._send({"type": "post_auth_message_response", "response": password})
                return
            self.state = "answer_wait"
            self._emit("prompt", kind=kind, text=text)
            return

        if response_type == "success":
            if self.state == "login_wait":
                self.initial_password = None
                self.state = "ready"
                self._emit("ready")
            elif self.state == "start_wait":
                self._emit("started")
                self._close_connection()
            elif self.state == "cancel_wait":
                self._emit("cancelled")
                self._close_connection()
            else:
                self._fail("Неожиданный ответ greetd")
            return

        self._fail("Неизвестный ответ greetd")


def _emit_stdout(event):
    sys.stdout.write(json.dumps(event, separators=(",", ":"), ensure_ascii=True) + "\n")
    sys.stdout.flush()


def _dispatch_line(line, bridge):
    if not line.strip():
        return
    try:
        command = json.loads(line.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        _emit_stdout({"event": "error", "description": "Некорректная команда"})
        return
    bridge.handle_command(command)


def main():
    bridge = GreetdBridge(_emit_stdout)
    stdin_fd = sys.stdin.fileno()
    pending_input = bytearray()
    try:
        while True:
            active_socket = bridge.sock
            watched = [stdin_fd]
            if active_socket is not None:
                watched.append(active_socket)
            readable, _, _ = select.select(watched, [], [])

            # Process socket events first so an auth prompt is ready before a
            # corresponding answer line is dispatched from the same poll.
            if active_socket is not None and active_socket in readable and bridge.sock is active_socket:
                bridge.read_socket()

            if stdin_fd in readable:
                try:
                    chunk = os.read(stdin_fd, 4096)
                except InterruptedError:
                    continue
                if not chunk:
                    if pending_input:
                        _dispatch_line(bytes(pending_input), bridge)
                    break
                pending_input.extend(chunk)
                while True:
                    newline = pending_input.find(b"\n")
                    if newline < 0:
                        break
                    line = bytes(pending_input[:newline])
                    del pending_input[: newline + 1]
                    _dispatch_line(line, bridge)
    except KeyboardInterrupt:
        pass
    except OSError:
        _emit_stdout({"event": "error", "description": "Ошибка ввода-вывода greeter"})
    finally:
        bridge.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
