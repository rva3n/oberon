import json
import os
import select
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parent))
from greetd_client import GreetdBridge, get_sessions, get_users  # noqa: E402


def read_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError("mock greetd disconnected")
        data.extend(chunk)
    return bytes(data)


def read_frame(sock):
    header = read_exact(sock, 4)
    size = struct.unpack("=I", header)[0]
    body = read_exact(sock, size)
    return header, body, json.loads(body.decode("utf-8"))


def send_frame(sock, message):
    body = json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    sock.sendall(struct.pack("=I", len(body)) + body)


class MockGreetdServer:
    def __init__(self, path, handler):
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(path)
        self.listener.listen(1)
        self.error = None
        self.thread = threading.Thread(target=self._serve, args=(handler,), daemon=True)
        self.thread.start()

    def _serve(self, handler):
        try:
            connection, _ = self.listener.accept()
            with connection:
                connection.settimeout(4)
                handler(connection)
        except BaseException as error:
            self.error = error
        finally:
            self.listener.close()

    def join(self):
        self.thread.join(timeout=5)
        if self.thread.is_alive():
            raise AssertionError("mock greetd did not finish")
        if self.error is not None:
            raise self.error


class GreetdClientTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.socket_path = str(Path(self.temp_dir.name) / "greetd.sock")
        self.original_socket_env = os.environ.get("GREETD_SOCK")
        self.events = []
        self.session = {
            "id": "umbriel",
            "name": "Umbriel",
            "cmd": ["/usr/bin/start-umbriel"],
            "env": [],
        }

    def tearDown(self):
        if self.original_socket_env is None:
            os.environ.pop("GREETD_SOCK", None)
        else:
            os.environ["GREETD_SOCK"] = self.original_socket_env
        self.temp_dir.cleanup()

    def bridge(self, session_loader=None):
        return GreetdBridge(
            self.events.append,
            session_loader=session_loader or (lambda: [self.session]),
        )

    def wait_for_response(self, bridge):
        self.assertIsNotNone(bridge.sock)
        readable, _, _ = select.select([bridge.sock], [], [], 3)
        self.assertTrue(readable, "timed out waiting for greetd response")
        bridge.read_socket()

    def server(self, handler):
        os.environ["GREETD_SOCK"] = self.socket_path
        return MockGreetdServer(self.socket_path, handler)

    def test_first_request_frame_has_native_u32_length_and_create_session(self):
        received = {}

        def handler(connection):
            header = read_exact(connection, 4)
            size = struct.unpack("=I", header)[0]
            body = read_exact(connection, size)
            received["header"] = header
            received["size"] = size
            received["body"] = body
            received["request"] = json.loads(body.decode("utf-8"))
            send_frame(connection, {"type": "success"})

        server = self.server(handler)
        bridge = self.bridge()
        bridge.handle_command({"cmd": "login", "user": "tony", "password": "first-secret"})
        self.wait_for_response(bridge)
        server.join()

        self.assertEqual(received["request"], {"type": "create_session", "username": "tony"})
        self.assertEqual(received["size"], len(received["body"]))
        self.assertEqual(received["header"], struct.pack("=I", len(received["body"])))
        self.assertEqual(self.events, [{"event": "ready"}])
        bridge.close()

    def test_login_success_then_start(self):
        requests = []

        def handler(connection):
            requests.append(read_frame(connection)[2])
            send_frame(
                connection,
                {
                    "type": "auth_message",
                    "auth_message_type": "secret",
                    "auth_message": "Password:",
                },
            )
            requests.append(read_frame(connection)[2])
            send_frame(connection, {"type": "success"})
            requests.append(read_frame(connection)[2])
            send_frame(connection, {"type": "success"})

        server = self.server(handler)
        bridge = self.bridge()
        bridge.handle_command(
            {"cmd": "login", "user": "tony", "password": "correct-password", "session": "umbriel"}
        )
        self.wait_for_response(bridge)
        self.wait_for_response(bridge)
        self.assertEqual(self.events, [{"event": "ready"}])

        bridge.handle_command({"cmd": "start"})
        self.wait_for_response(bridge)
        server.join()

        self.assertEqual(
            requests,
            [
                {"type": "create_session", "username": "tony"},
                {"type": "post_auth_message_response", "response": "correct-password"},
                {
                    "type": "start_session",
                    "cmd": ["/usr/bin/start-umbriel"],
                    "env": [],
                },
            ],
        )
        self.assertEqual(self.events, [{"event": "ready"}, {"event": "started"}])
        self.assertIsNone(bridge.sock)

    def test_extra_visible_prompt_waits_for_answer(self):
        requests = []

        def handler(connection):
            requests.append(read_frame(connection)[2])
            send_frame(
                connection,
                {"type": "auth_message", "auth_message_type": "secret", "auth_message": "Password:"},
            )
            requests.append(read_frame(connection)[2])
            send_frame(
                connection,
                {"type": "auth_message", "auth_message_type": "visible", "auth_message": "TOTP"},
            )
            requests.append(read_frame(connection)[2])
            send_frame(connection, {"type": "success"})

        server = self.server(handler)
        bridge = self.bridge()
        bridge.handle_command({"cmd": "login", "user": "tony", "password": "primary"})
        self.wait_for_response(bridge)
        self.wait_for_response(bridge)
        self.assertEqual(
            self.events,
            [{"event": "prompt", "kind": "visible", "text": "TOTP"}],
        )

        bridge.handle_command({"cmd": "answer", "value": "123456"})
        self.wait_for_response(bridge)
        server.join()
        self.assertEqual(requests[1], {"type": "post_auth_message_response", "response": "primary"})
        self.assertEqual(requests[2], {"type": "post_auth_message_response", "response": "123456"})
        self.assertEqual(self.events[-1], {"event": "ready"})
        bridge.close()

    def test_auth_error_is_reported(self):
        def handler(connection):
            read_frame(connection)
            send_frame(
                connection,
                {"type": "auth_message", "auth_message_type": "secret", "auth_message": "Password:"},
            )
            read_frame(connection)
            send_frame(
                connection,
                {"type": "error", "error_type": "auth_error", "description": "Invalid credentials"},
            )

        server = self.server(handler)
        bridge = self.bridge()
        bridge.handle_command({"cmd": "login", "user": "tony", "password": "wrong"})
        self.wait_for_response(bridge)
        self.wait_for_response(bridge)
        server.join()
        self.assertEqual(
            self.events,
            [{"event": "auth_error", "description": "Invalid credentials"}],
        )
        self.assertIsNone(bridge.sock)

    def test_cancel_sends_cancel_session(self):
        requests = []

        def handler(connection):
            requests.append(read_frame(connection)[2])
            send_frame(
                connection,
                {"type": "auth_message", "auth_message_type": "secret", "auth_message": "Password:"},
            )
            requests.append(read_frame(connection)[2])
            send_frame(
                connection,
                {"type": "auth_message", "auth_message_type": "info", "auth_message": "Continue?"},
            )
            requests.append(read_frame(connection)[2])
            send_frame(connection, {"type": "success"})

        server = self.server(handler)
        bridge = self.bridge()
        bridge.handle_command({"cmd": "login", "user": "tony", "password": "secret"})
        self.wait_for_response(bridge)
        self.wait_for_response(bridge)
        self.assertEqual(self.events[-1], {"event": "prompt", "kind": "info", "text": "Continue?"})

        bridge.handle_command({"cmd": "cancel"})
        self.wait_for_response(bridge)
        server.join()
        self.assertEqual(requests[-1], {"type": "cancel_session"})
        self.assertEqual(self.events[-1], {"event": "cancelled"})
        self.assertIsNone(bridge.sock)

    def test_missing_greetd_sock_emits_error(self):
        old_sock = os.environ.pop("GREETD_SOCK", None)
        try:
            bridge = self.bridge()
            bridge.handle_command({"cmd": "login", "user": "tony", "password": "secret"})
        finally:
            if old_sock is not None:
                os.environ["GREETD_SOCK"] = old_sock
        self.assertEqual(
            self.events,
            [{"event": "error", "description": "GREETD_SOCK не задан"}],
        )

    def test_users_and_sessions_read_real_system_files(self):
        users = get_users()
        sessions = get_sessions()
        print("users:", users)
        print("sessions:", sessions)
        self.assertIsInstance(users, list)
        self.assertIsInstance(sessions, list)

    def test_power_failure_is_reported_without_raising(self):
        result = mock.Mock(returncode=1, stderr="Access denied")
        with mock.patch("greetd_client.subprocess.run", return_value=result) as run:
            self.bridge().handle_command({"cmd": "power", "action": "suspend"})
        self.assertEqual(
            self.events,
            [{"event": "power_error", "description": "Access denied"}],
        )
        self.assertEqual(run.call_args.args[0], ["systemctl", "suspend"])

    def test_session_entries_remove_field_codes_and_prioritize_umbriel(self):
        directory = Path(self.temp_dir.name) / "wayland-sessions"
        directory.mkdir()
        (directory / "alpha.desktop").write_text(
            "[Desktop Entry]\nName=Alpha\nExec=/bin/alpha --file %f\n",
            encoding="utf-8",
        )
        (directory / "umbriel.desktop").write_text(
            "[Desktop Entry]\nName=Umbriel\nExec=/usr/bin/start-umbriel %U\n",
            encoding="utf-8",
        )
        sessions = get_sessions((directory,))
        self.assertEqual([session["id"] for session in sessions], ["umbriel", "alpha"])
        self.assertEqual(sessions[0]["cmd"], ["/usr/bin/start-umbriel"])
        self.assertEqual(sessions[1]["cmd"], ["/bin/alpha", "--file"])

    def test_password_is_not_in_process_list(self):
        password = "ps-check-only-9271"

        def handler(connection):
            read_frame(connection)
            send_frame(
                connection,
                {"type": "auth_message", "auth_message_type": "secret", "auth_message": "Password:"},
            )
            request = read_frame(connection)[2]
            if request.get("response") != password:
                raise AssertionError("password was not sent in the greetd response")
            send_frame(connection, {"type": "success"})
            while connection.recv(1024):
                pass

        server = self.server(handler)
        script = Path(__file__).with_name("greetd_client.py")
        environment = os.environ.copy()
        environment["GREETD_SOCK"] = self.socket_path
        process = subprocess.Popen(
            [sys.executable, str(script)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=environment,
        )
        try:
            process.stdin.write(
                json.dumps({"cmd": "login", "user": "tony", "password": password}) + "\n"
            )
            process.stdin.flush()
            readable, _, _ = select.select([process.stdout], [], [], 4)
            self.assertTrue(readable, "timed out waiting for ready event")
            event = json.loads(process.stdout.readline())
            self.assertEqual(event, {"event": "ready"})

            ps_result = subprocess.run(
                ["ps", "-o", "args=", "-p", str(process.pid)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotIn(password, ps_result.stdout)
        finally:
            if process.stdin and not process.stdin.closed:
                process.stdin.close()
            if process.poll() is None:
                process.wait(timeout=4)
        server.join()
        self.assertEqual(process.stderr.read(), "")
        process.stdout.close()
        process.stderr.close()


if __name__ == "__main__":
    unittest.main()
