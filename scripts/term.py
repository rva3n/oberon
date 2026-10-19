#!/usr/bin/env python3
import codecs
import errno
import fcntl
import html
import json
import os
import pty
import select
import shlex
import shutil
import signal
import struct
import sys
import termios
import time

# Modern high-contrast 16-color ANSI palette (Material / Catppuccin Mocha inspired)
ANSI_PALETTE = [
    "#1e1e2e",  # 0: Black
    "#f38ba8",  # 1: Red
    "#a6e3a1",  # 2: Green
    "#f9e2af",  # 3: Yellow
    "#89b4fa",  # 4: Blue
    "#cba6f7",  # 5: Magenta
    "#94e2d5",  # 6: Cyan
    "#bac2de",  # 7: White (light gray)
    "#585b70",  # 8: Bright Black (dark gray)
    "#fb7185",  # 9: Bright Red
    "#4ade80",  # 10: Bright Green
    "#facc15",  # 11: Bright Yellow
    "#60a5fa",  # 12: Bright Blue
    "#c084fc",  # 13: Bright Magenta
    "#2dd4bf",  # 14: Bright Cyan
    "#f8fafc",  # 15: Bright White
]

DEFAULT_FG_HEX = "#e2e2e9"
DEFAULT_BG_HEX = "#0c0e13"
CURSOR_BG_HEX = "#a8c7fa"
CURSOR_FG_HEX = "#062e6f"

MAX_SCROLLBACK = 300


def color_256_to_hex(idx: int) -> str:
    if idx < 0:
        return DEFAULT_FG_HEX
    if idx < 16:
        return ANSI_PALETTE[idx]
    if idx < 232:
        n = idx - 16
        r_idx = n // 36
        g_idx = (n // 6) % 6
        b_idx = n % 6
        levels = [0, 95, 135, 175, 215, 255]
        return f"#{levels[r_idx]:02x}{levels[g_idx]:02x}{levels[b_idx]:02x}"
    if idx <= 255:
        v = 8 + (idx - 232) * 10
        return f"#{v:02x}{v:02x}{v:02x}"
    return DEFAULT_FG_HEX


def resolve_shell(requested: str) -> str:
    if requested:
        expanded = os.path.expanduser(requested.strip())
        if os.path.isabs(expanded) and os.access(expanded, os.X_OK):
            return expanded
        found = shutil.which(expanded)
        if found:
            return found
    env_shell = os.environ.get("SHELL", "").strip()
    if env_shell and os.access(env_shell, os.X_OK):
        return env_shell
    for candidate in ("/bin/bash", "/usr/bin/bash", "/bin/sh"):
        if os.access(candidate, os.X_OK):
            return candidate
    return "/bin/sh"


def resolve_cwd(requested: str) -> str:
    home = os.environ.get("HOME") or os.path.expanduser("~") or "/"
    if requested:
        raw = requested.strip()
        if raw == "~":
            expanded = home
        elif raw.startswith("~/"):
            expanded = os.path.join(home, raw[2:])
        else:
            expanded = os.path.expanduser(raw)
        if os.path.isdir(expanded):
            return os.path.abspath(expanded)
    if os.path.isdir(home):
        return os.path.abspath(home)
    return "/"


def shorten_cwd(path: str) -> str:
    home = (os.environ.get("HOME") or os.path.expanduser("~") or "").rstrip("/")
    if home and path == home:
        return "~"
    if home and path.startswith(home + "/"):
        return "~" + path[len(home):]
    return path or "~"


def make_blank_cell(fg=None, bg=None):
    # [char, fg, bg, bold, underline, reverse]
    return [" ", fg, bg, False, False, False]


def make_row(cols: int, fg=None, bg=None):
    return [make_blank_cell(fg, bg) for _ in range(cols)]


class VT100Screen:
    """Pure-Python VT100 / xterm ANSI screen buffer with alternate screen and scrollback."""

    def __init__(self, rows: int = 24, cols: int = 96):
        self.rows = max(2, int(rows))
        self.cols = max(10, int(cols))
        self.reset()

    def reset(self):
        self.main_grid = [make_row(self.cols) for _ in range(self.rows)]
        self.alt_grid = [make_row(self.cols) for _ in range(self.rows)]
        self.scrollback = []
        self.using_alt = False
        self.grid = self.main_grid

        self.cursor_r = 0
        self.cursor_c = 0
        self.cursor_visible = True
        self.wrap_pending = False

        self.saved_main = (0, 0, None, None, False, False, False)
        self.saved_alt = (0, 0, None, None, False, False, False)

        self.scroll_top = 0
        self.scroll_bottom = self.rows - 1

        # Current SGR attributes
        self.fg = None
        self.bg = None
        self.bold = False
        self.dim = False
        self.underline = False
        self.reverse = False

        self.title = ""
        self.osc_cwd = ""

        # Parser state: "ground", "esc", "esc_intermediate", "csi", "osc", "osc_esc"
        self.state = "ground"
        self.csi_buf = []
        self.osc_buf = []
        self.pty_replies = []

    def clear_all(self):
        self.scrollback.clear()
        for r in range(self.rows):
            self.grid[r] = make_row(self.cols)
        self.cursor_r = 0
        self.cursor_c = 0
        self.wrap_pending = False

    def resize(self, new_rows: int, new_cols: int):
        new_rows = max(2, int(new_rows))
        new_cols = max(10, int(new_cols))
        if new_rows == self.rows and new_cols == self.cols:
            return

        def resize_grid(g, is_main: bool):
            # Adjust columns on existing rows
            for r in range(len(g)):
                row = g[r]
                if len(row) < new_cols:
                    row.extend(make_blank_cell() for _ in range(new_cols - len(row)))
                elif len(row) > new_cols:
                    g[r] = row[:new_cols]

            if new_rows > len(g):
                for _ in range(new_rows - len(g)):
                    g.append(make_row(new_cols))
            elif new_rows < len(g):
                diff = len(g) - new_rows
                if is_main and self.cursor_r >= new_rows:
                    push = min(diff, self.cursor_r - new_rows + 1)
                    for i in range(push):
                        self.scrollback.append(g[i])
                    if len(self.scrollback) > MAX_SCROLLBACK:
                        self.scrollback = self.scrollback[-MAX_SCROLLBACK:]
                    del g[:push]
                    self.cursor_r = max(0, self.cursor_r - push)
                while len(g) > new_rows:
                    g.pop()
            return g

        self.main_grid = resize_grid(self.main_grid, True)
        self.alt_grid = resize_grid(self.alt_grid, False)
        self.grid = self.alt_grid if self.using_alt else self.main_grid
        self.rows = new_rows
        self.cols = new_cols
        self.scroll_top = 0
        self.scroll_bottom = self.rows - 1
        self.cursor_r = max(0, min(self.rows - 1, self.cursor_r))
        self.cursor_c = max(0, min(self.cols - 1, self.cursor_c))
        self.wrap_pending = False

    def _scroll_up(self, top: int, bottom: int, count: int = 1):
        top = max(0, min(self.rows - 1, top))
        bottom = max(top, min(self.rows - 1, bottom))
        count = max(1, min(bottom - top + 1, count))
        for _ in range(count):
            removed = self.grid.pop(top)
            if not self.using_alt and top == 0:
                self.scrollback.append(removed)
                if len(self.scrollback) > MAX_SCROLLBACK:
                    del self.scrollback[0]
            self.grid.insert(bottom, make_row(self.cols, None, self.bg))

    def _scroll_down(self, top: int, bottom: int, count: int = 1):
        top = max(0, min(self.rows - 1, top))
        bottom = max(top, min(self.rows - 1, bottom))
        count = max(1, min(bottom - top + 1, count))
        for _ in range(count):
            self.grid.pop(bottom)
            self.grid.insert(top, make_row(self.cols, None, self.bg))

    def _linefeed(self):
        self.wrap_pending = False
        if self.cursor_r == self.scroll_bottom:
            self._scroll_up(self.scroll_top, self.scroll_bottom, 1)
        elif self.cursor_r < self.rows - 1:
            self.cursor_r += 1

    def _reverse_index(self):
        self.wrap_pending = False
        if self.cursor_r == self.scroll_top:
            self._scroll_down(self.scroll_top, self.scroll_bottom, 1)
        elif self.cursor_r > 0:
            self.cursor_r -= 1

    def _put_char(self, ch: str):
        if self.wrap_pending:
            self.cursor_c = 0
            self._linefeed()
            self.wrap_pending = False

        r = max(0, min(self.rows - 1, self.cursor_r))
        c = max(0, min(self.cols - 1, self.cursor_c))
        fg = self.fg
        if self.dim and fg is None:
            fg = ANSI_PALETTE[8]
        self.grid[r][c] = [ch, fg, self.bg, self.bold, self.underline, self.reverse]

        if self.cursor_c >= self.cols - 1:
            self.wrap_pending = True
        else:
            self.cursor_c += 1

    def _save_cursor(self):
        state = (
            self.cursor_r,
            self.cursor_c,
            self.fg,
            self.bg,
            self.bold,
            self.underline,
            self.reverse,
        )
        if self.using_alt:
            self.saved_alt = state
        else:
            self.saved_main = state

    def _restore_cursor(self):
        state = self.saved_alt if self.using_alt else self.saved_main
        (
            r,
            c,
            self.fg,
            self.bg,
            self.bold,
            self.underline,
            self.reverse,
        ) = state
        self.cursor_r = max(0, min(self.rows - 1, r))
        self.cursor_c = max(0, min(self.cols - 1, c))
        self.wrap_pending = False

    def _switch_alt_screen(self, enable: bool, save_restore: bool, clear_alt: bool):
        if enable and not self.using_alt:
            if save_restore:
                self._save_cursor()
            self.using_alt = True
            self.grid = self.alt_grid
            if clear_alt:
                for r in range(self.rows):
                    self.alt_grid[r] = make_row(self.cols)
                self.cursor_r = 0
                self.cursor_c = 0
            self.scroll_top = 0
            self.scroll_bottom = self.rows - 1
            self.wrap_pending = False
        elif not enable and self.using_alt:
            self.using_alt = False
            self.grid = self.main_grid
            self.scroll_top = 0
            self.scroll_bottom = self.rows - 1
            if save_restore:
                self._restore_cursor()
            self.wrap_pending = False

    def _handle_sgr(self, params_str: str):
        if not params_str:
            params = [0]
        else:
            # Handle both ';' and ':' subparameters
            normalized = params_str.replace(":", ";")
            params = [int(p) if p.isdigit() else 0 for p in normalized.split(";")]

        i = 0
        n = len(params)
        while i < n:
            code = params[i]
            if code == 0:
                self.fg = None
                self.bg = None
                self.bold = False
                self.dim = False
                self.underline = False
                self.reverse = False
            elif code == 1:
                self.bold = True
            elif code == 2:
                self.dim = True
            elif code == 4:
                self.underline = True
            elif code == 7:
                self.reverse = True
            elif code == 21 or code == 22:
                self.bold = False
                self.dim = False
            elif code == 24:
                self.underline = False
            elif code == 27:
                self.reverse = False
            elif 30 <= code <= 37:
                idx = code - 30
                self.fg = ANSI_PALETTE[idx + (8 if self.bold else 0)]
            elif code == 39:
                self.fg = None
            elif 40 <= code <= 47:
                self.bg = ANSI_PALETTE[code - 40]
            elif code == 49:
                self.bg = None
            elif 90 <= code <= 97:
                self.fg = ANSI_PALETTE[code - 90 + 8]
            elif 100 <= code <= 107:
                self.bg = ANSI_PALETTE[code - 100 + 8]
            elif code in (38, 48):
                is_fg = code == 38
                if i + 1 < n:
                    mode = params[i + 1]
                    if mode == 5 and i + 2 < n:
                        color_hex = color_256_to_hex(params[i + 2])
                        if is_fg:
                            self.fg = color_hex
                        else:
                            self.bg = color_hex
                        i += 2
                    elif mode == 2 and i + 4 < n:
                        r = max(0, min(255, params[i + 2]))
                        g = max(0, min(255, params[i + 3]))
                        b = max(0, min(255, params[i + 4]))
                        color_hex = f"#{r:02x}{g:02x}{b:02x}"
                        if is_fg:
                            self.fg = color_hex
                        else:
                            self.bg = color_hex
                        i += 4
            i += 1

    def _handle_csi(self, seq: str):
        if not seq:
            return
        final = seq[-1]
        body = seq[:-1]

        private_prefix = ""
        if body and body[0] in "?><=":
            private_prefix = body[0]
            body = body[1:]

        # Strip any trailing intermediate bytes (like space or !)
        while body and not (body[-1].isdigit() or body[-1] in ";:"):
            body = body[:-1]

        raw_parts = body.split(";") if body else []
        params = [int(p) if p.isdigit() else 0 for p in raw_parts]

        def param(idx: int, default: int = 1) -> int:
            if idx < len(params) and params[idx] > 0:
                return params[idx]
            return default

        if private_prefix == "?":
            if final in ("h", "l"):
                enable = final == "h"
                for p in params:
                    if p == 25:
                        self.cursor_visible = enable
                    elif p == 1049:
                        self._switch_alt_screen(enable, save_restore=True, clear_alt=True)
                    elif p in (47, 1047):
                        self._switch_alt_screen(enable, save_restore=False, clear_alt=enable)
            return

        if final == "m":
            self._handle_sgr(body)
        elif final == "A":  # CUU - Cursor Up
            self.wrap_pending = False
            self.cursor_r = max(0, self.cursor_r - param(0, 1))
        elif final == "B":  # CUD - Cursor Down
            self.wrap_pending = False
            self.cursor_r = min(self.rows - 1, self.cursor_r + param(0, 1))
        elif final == "C":  # CUF - Cursor Forward
            self.wrap_pending = False
            self.cursor_c = min(self.cols - 1, self.cursor_c + param(0, 1))
        elif final == "D":  # CUB - Cursor Back
            self.wrap_pending = False
            self.cursor_c = max(0, self.cursor_c - param(0, 1))
        elif final == "E":  # CNL - Cursor Next Line
            self.wrap_pending = False
            self.cursor_r = min(self.rows - 1, self.cursor_r + param(0, 1))
            self.cursor_c = 0
        elif final == "F":  # CPL - Cursor Preceding Line
            self.wrap_pending = False
            self.cursor_r = max(0, self.cursor_r - param(0, 1))
            self.cursor_c = 0
        elif final in ("G", "`"):  # CHA - Cursor Horizontal Absolute
            self.wrap_pending = False
            self.cursor_c = max(0, min(self.cols - 1, param(0, 1) - 1))
        elif final in ("H", "f"):  # CUP - Cursor Position
            self.wrap_pending = False
            r = param(0, 1) - 1
            c = param(1, 1) - 1
            self.cursor_r = max(0, min(self.rows - 1, r))
            self.cursor_c = max(0, min(self.cols - 1, c))
        elif final == "d":  # VPA - Vertical Line Position Absolute
            self.wrap_pending = False
            self.cursor_r = max(0, min(self.rows - 1, param(0, 1) - 1))
        elif final == "J":  # ED - Erase in Display
            mode = params[0] if params else 0
            if mode == 0:
                # Cursor to end of screen
                for c in range(self.cursor_c, self.cols):
                    self.grid[self.cursor_r][c] = make_blank_cell(None, self.bg)
                for r in range(self.cursor_r + 1, self.rows):
                    self.grid[r] = make_row(self.cols, None, self.bg)
            elif mode == 1:
                # Start of screen to cursor
                for r in range(0, self.cursor_r):
                    self.grid[r] = make_row(self.cols, None, self.bg)
                for c in range(0, self.cursor_c + 1):
                    self.grid[self.cursor_r][c] = make_blank_cell(None, self.bg)
            elif mode in (2, 3):
                for r in range(self.rows):
                    self.grid[r] = make_row(self.cols, None, self.bg)
                if mode == 3 and not self.using_alt:
                    self.scrollback.clear()
        elif final == "K":  # EL - Erase in Line
            mode = params[0] if params else 0
            row = self.grid[self.cursor_r]
            if mode == 0:
                for c in range(self.cursor_c, self.cols):
                    row[c] = make_blank_cell(None, self.bg)
            elif mode == 1:
                for c in range(0, self.cursor_c + 1):
                    row[c] = make_blank_cell(None, self.bg)
            elif mode == 2:
                self.grid[self.cursor_r] = make_row(self.cols, None, self.bg)
        elif final == "L":  # IL - Insert Lines
            if self.scroll_top <= self.cursor_r <= self.scroll_bottom:
                count = min(param(0, 1), self.scroll_bottom - self.cursor_r + 1)
                for _ in range(count):
                    self.grid.pop(self.scroll_bottom)
                    self.grid.insert(self.cursor_r, make_row(self.cols, None, self.bg))
        elif final == "M":  # DL - Delete Lines
            if self.scroll_top <= self.cursor_r <= self.scroll_bottom:
                count = min(param(0, 1), self.scroll_bottom - self.cursor_r + 1)
                for _ in range(count):
                    self.grid.pop(self.cursor_r)
                    self.grid.insert(self.scroll_bottom, make_row(self.cols, None, self.bg))
        elif final == "P":  # DCH - Delete Characters
            count = min(param(0, 1), self.cols - self.cursor_c)
            row = self.grid[self.cursor_r]
            del row[self.cursor_c : self.cursor_c + count]
            row.extend(make_blank_cell(None, self.bg) for _ in range(count))
        elif final == "@":  # ICH - Insert Blank Characters
            count = min(param(0, 1), self.cols - self.cursor_c)
            row = self.grid[self.cursor_r]
            for _ in range(count):
                row.insert(self.cursor_c, make_blank_cell(None, self.bg))
                row.pop()
        elif final == "X":  # ECH - Erase Characters
            count = min(param(0, 1), self.cols - self.cursor_c)
            row = self.grid[self.cursor_r]
            for c in range(self.cursor_c, self.cursor_c + count):
                row[c] = make_blank_cell(None, self.bg)
        elif final == "r":  # DECSTBM - Set Top and Bottom Margins
            top = (params[0] if len(params) >= 1 and params[0] > 0 else 1) - 1
            bottom = (params[1] if len(params) >= 2 and params[1] > 0 else self.rows) - 1
            top = max(0, min(self.rows - 2, top))
            bottom = max(top + 1, min(self.rows - 1, bottom))
            self.scroll_top = top
            self.scroll_bottom = bottom
            self.cursor_r = 0
            self.cursor_c = 0
            self.wrap_pending = False
        elif final == "S":  # SU - Scroll Up
            self._scroll_up(self.scroll_top, self.scroll_bottom, param(0, 1))
        elif final == "T":  # SD - Scroll Down
            self._scroll_down(self.scroll_top, self.scroll_bottom, param(0, 1))
        elif final == "s":  # Save cursor
            if not private_prefix:
                self._save_cursor()
        elif final == "u":  # Restore cursor
            if not private_prefix:
                self._restore_cursor()
        elif final == "n" and not private_prefix:  # DSR - Device Status Report
            code = params[0] if params else 0
            if code == 5:
                self.pty_replies.append("\x1b[0n")
            elif code == 6:
                self.pty_replies.append(f"\x1b[{self.cursor_r + 1};{self.cursor_c + 1}R")
        elif final == "c":  # DA - Device Attributes
            self.pty_replies.append("\x1b[?1;2c")

    def _handle_osc(self, content: str):
        semi = content.find(";")
        if semi < 0:
            return
        cmd = content[:semi].strip()
        payload = content[semi + 1 :]
        if cmd in ("0", "1", "2"):
            clean_title = "".join(ch for ch in payload if ch >= " ").strip()
            if clean_title:
                self.title = clean_title[:80]
        elif cmd == "7":
            # file://hostname/path
            if payload.startswith("file://"):
                rest = payload[7:]
                slash = rest.find("/")
                if slash >= 0:
                    from urllib.parse import unquote
                    path = unquote(rest[slash:])
                    if os.path.isdir(path):
                        self.osc_cwd = path

    def feed(self, text: str):
        for ch in text:
            code = ord(ch)
            st = self.state

            if st == "ground":
                if ch == "\x1b":
                    self.state = "esc"
                elif ch == "\r":
                    self.cursor_c = 0
                    self.wrap_pending = False
                elif ch in ("\n", "\x0b", "\x0c"):
                    self._linefeed()
                elif ch == "\b":
                    self.wrap_pending = False
                    if self.cursor_c > 0:
                        self.cursor_c -= 1
                elif ch == "\t":
                    self.wrap_pending = False
                    next_tab = ((self.cursor_c // 8) + 1) * 8
                    self.cursor_c = min(self.cols - 1, next_tab)
                elif ch in ("\x07", "\x00", "\x0e", "\x0f"):
                    pass
                elif code >= 32:
                    self._put_char(ch)

            elif st == "esc":
                if ch == "[":
                    self.state = "csi"
                    self.csi_buf.clear()
                elif ch == "]":
                    self.state = "osc"
                    self.osc_buf.clear()
                elif ch in ("(", ")", "*", "+", "-", ".", "/"):
                    self.state = "esc_intermediate"
                elif ch == "7":
                    self._save_cursor()
                    self.state = "ground"
                elif ch == "8":
                    self._restore_cursor()
                    self.state = "ground"
                elif ch == "M":
                    self._reverse_index()
                    self.state = "ground"
                elif ch == "D":
                    self._linefeed()
                    self.state = "ground"
                elif ch == "E":
                    self.cursor_c = 0
                    self._linefeed()
                    self.state = "ground"
                elif ch == "c":
                    self.reset()
                else:
                    self.state = "ground"

            elif st == "esc_intermediate":
                self.state = "ground"

            elif st == "csi":
                if ch == "\x1b":
                    self.state = "esc"
                elif 0x40 <= code <= 0x7E:
                    self.csi_buf.append(ch)
                    seq = "".join(self.csi_buf)
                    self.csi_buf.clear()
                    self.state = "ground"
                    self._handle_csi(seq)
                else:
                    if len(self.csi_buf) < 64:
                        self.csi_buf.append(ch)
                    else:
                        self.csi_buf.clear()
                        self.state = "ground"

            elif st == "osc":
                if ch == "\x07":
                    content = "".join(self.osc_buf)
                    self.osc_buf.clear()
                    self.state = "ground"
                    self._handle_osc(content)
                elif ch == "\x1b":
                    self.state = "osc_esc"
                else:
                    if len(self.osc_buf) < 512:
                        self.osc_buf.append(ch)

            elif st == "osc_esc":
                if ch == "\\":
                    content = "".join(self.osc_buf)
                    self.osc_buf.clear()
                    self.state = "ground"
                    self._handle_osc(content)
                else:
                    self.osc_buf.clear()
                    self.state = "ground"

    def render(self):
        """Returns (html_str, plain_str) for the current buffer."""
        if self.using_alt:
            lines = self.grid
            cur_line_idx = self.cursor_r
            total_lines = self.rows
        else:
            # Find last non-empty row on main screen (at least cursor_r)
            last_active_r = self.cursor_r
            for r in range(self.rows - 1, self.cursor_r, -1):
                row = self.grid[r]
                if any(cell[0] != " " or cell[1] is not None or cell[2] is not None or cell[4] or cell[5] for cell in row):
                    last_active_r = r
                    break
            active_rows = self.grid[: last_active_r + 1]
            lines = self.scrollback + active_rows
            cur_line_idx = len(self.scrollback) + self.cursor_r
            total_lines = len(lines)

        plain_lines = []
        html_lines = []

        for idx in range(total_lines):
            row = lines[idx]
            is_cursor_row = self.cursor_visible and (idx == cur_line_idx)

            # Determine effective rightmost column for this row
            last_col = -1
            for c in range(len(row) - 1, -1, -1):
                cell = row[c]
                if cell[0] != " " or cell[2] is not None or cell[4] or cell[5]:
                    last_col = c
                    break
            if is_cursor_row and self.cursor_c > last_col:
                last_col = min(len(row) - 1, self.cursor_c)

            if last_col < 0:
                plain_lines.append("")
                html_lines.append("")
                continue

            # Plain text line
            plain_chars = [row[c][0] for c in range(last_col + 1)]
            plain_lines.append("".join(plain_chars).rstrip(" "))

            # HTML line with span run-length coalescing
            spans = []
            run_chars = []
            run_style = None

            for c in range(last_col + 1):
                ch, fg, bg, bold, underline, rev = row[c]
                is_cur = is_cursor_row and (c == self.cursor_c)

                if is_cur:
                    eff_fg = CURSOR_FG_HEX
                    eff_bg = CURSOR_BG_HEX
                elif rev:
                    eff_fg = bg if bg is not None else DEFAULT_BG_HEX
                    eff_bg = fg if fg is not None else DEFAULT_FG_HEX
                else:
                    eff_fg = fg
                    eff_bg = bg

                style_key = (eff_fg, eff_bg, bold, underline)
                if style_key != run_style:
                    if run_chars:
                        spans.append(self._format_span(run_chars, run_style))
                    run_chars = [ch]
                    run_style = style_key
                else:
                    run_chars.append(ch)

            if run_chars:
                spans.append(self._format_span(run_chars, run_style))

            html_lines.append("".join(spans))

        plain_text = "\n".join(plain_lines)
        html_body = "\n".join(html_lines)
        html_out = f'<pre style="margin:0;white-space:pre;">{html_body}</pre>'
        return html_out, plain_text

    @staticmethod
    def _format_span(chars, style_key) -> str:
        escaped = html.escape("".join(chars), quote=False)
        fg, bg, bold, underline = style_key
        if fg is None and bg is None and not bold and not underline:
            return escaped
        css = []
        if fg is not None:
            css.append(f"color:{fg}")
        if bg is not None:
            css.append(f"background-color:{bg}")
        if bold:
            css.append("font-weight:bold")
        if underline:
            css.append("text-decoration:underline")
        return f'<span style="{";".join(css)};">{escaped}</span>'


class TerminalTab:
    def __init__(self, tab_id: int, master_fd: int, pid: int, shell_path: str, initial_cwd: str, rows: int, cols: int):
        self.id = tab_id
        self.fd = master_fd
        self.pid = pid
        self.shell_path = shell_path
        self.shell_name = os.path.basename(shell_path) or "bash"
        self.last_cwd = initial_cwd
        self.screen = VT100Screen(rows, cols)
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")

    def get_cwd(self) -> str:
        # Try foreground process group leader first, then shell pid
        pids = []
        try:
            fg_pid = os.tcgetpgrp(self.fd)
            if fg_pid > 0:
                pids.append(fg_pid)
        except OSError:
            pass
        pids.append(self.pid)

        for p in pids:
            try:
                target = os.readlink(f"/proc/{p}/cwd")
                if target and os.path.isdir(target):
                    self.last_cwd = target
                    return target
            except OSError:
                continue

        if self.screen.osc_cwd and os.path.isdir(self.screen.osc_cwd):
            self.last_cwd = self.screen.osc_cwd
        return self.last_cwd

    def get_title(self) -> str:
        try:
            fg_pid = os.tcgetpgrp(self.fd)
            if fg_pid > 0 and fg_pid != self.pid:
                with open(f"/proc/{fg_pid}/comm", "r", encoding="utf-8", errors="replace") as fh:
                    comm = fh.read().strip()
                    if comm:
                        return comm
        except OSError:
            pass
        if self.screen.title:
            return self.screen.title
        return self.shell_name


class TerminalManager:
    def __init__(self):
        self.tabs = {}
        self.tab_order = []
        self.active_tab_id = 0
        self.next_tab_id = 1
        self.rows = 24
        self.cols = 96
        self.default_shell = ""
        self.default_cwd = ""

    @staticmethod
    def _set_winsize(fd: int, rows: int, cols: int):
        try:
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        except OSError:
            pass

    def spawn_tab(self, shell: str = "", cwd: str = "") -> int:
        use_shell = resolve_shell(shell or self.default_shell)
        use_cwd = resolve_cwd(cwd or self.default_cwd)

        pid, master_fd = pty.fork()
        if pid == 0:
            # Child process
            try:
                os.chdir(use_cwd)
            except OSError:
                try:
                    os.chdir(os.path.expanduser("~"))
                except OSError:
                    pass

            env = os.environ.copy()
            env["TERM"] = "xterm-256color"
            env["COLORTERM"] = "truecolor"
            env["PWD"] = os.getcwd()
            # Ensure clean prompt in bash/zsh if needed
            shell_base = os.path.basename(use_shell)
            argv = [use_shell]
            if shell_base in ("bash", "zsh", "fish"):
                argv = [use_shell, "-i"]
            try:
                os.execvpe(use_shell, argv, env)
            except OSError:
                os.execvp("/bin/sh", ["/bin/sh", "-i"])
            os._exit(1)

        # Parent process
        flags = fcntl.fcntl(master_fd, fcntl.F_GETFL)
        fcntl.fcntl(master_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        self._set_winsize(master_fd, self.rows, self.cols)

        tab_id = self.next_tab_id
        self.next_tab_id += 1
        tab = TerminalTab(tab_id, master_fd, pid, use_shell, use_cwd, self.rows, self.cols)
        self.tabs[tab_id] = tab
        self.tab_order.append(tab_id)
        self.active_tab_id = tab_id
        return tab_id

    def get_active_tab(self):
        if self.active_tab_id in self.tabs:
            return self.tabs[self.active_tab_id]
        if self.tab_order:
            self.active_tab_id = self.tab_order[-1]
            return self.tabs[self.active_tab_id]
        return None

    def write_to_tab(self, tab: TerminalTab, data: bytes):
        if not tab or not data:
            return
        view = memoryview(data)
        total = len(view)
        offset = 0
        while offset < total:
            try:
                written = os.write(tab.fd, view[offset:])
                if written <= 0:
                    break
                offset += written
            except BlockingIOError:
                try:
                    select.select([], [tab.fd], [], 0.02)
                except OSError:
                    break
            except OSError:
                break

    def close_tab(self, tab_id: int, respawn_if_empty: bool = True):
        tab = self.tabs.pop(tab_id, None)
        if tab_id in self.tab_order:
            self.tab_order.remove(tab_id)
        if tab is not None:
            try:
                os.close(tab.fd)
            except OSError:
                pass
            for sig in (signal.SIGHUP, signal.SIGTERM):
                try:
                    os.killpg(tab.pid, sig)
                except OSError:
                    try:
                        os.kill(tab.pid, sig)
                    except OSError:
                        pass
            try:
                os.waitpid(tab.pid, os.WNOHANG)
            except OSError:
                pass

        if self.active_tab_id == tab_id:
            self.active_tab_id = self.tab_order[-1] if self.tab_order else 0

        if not self.tabs and respawn_if_empty:
            self.spawn_tab(self.default_shell, os.environ.get("HOME") or "~")

    def close_all(self):
        for tid in list(self.tabs.keys()):
            self.close_tab(tid, respawn_if_empty=False)

    def resize_all(self, rows: int, cols: int):
        self.rows = max(2, min(200, int(rows)))
        self.cols = max(10, min(400, int(cols)))
        for tab in self.tabs.values():
            tab.screen.resize(self.rows, self.cols)
            self._set_winsize(tab.fd, self.rows, self.cols)

    def handle_command(self, msg: dict) -> bool:
        """Returns True if an immediate snapshot should be emitted."""
        cmd = str(msg.get("cmd") or "").strip()
        if not cmd:
            return False

        if cmd == "init":
            shell = str(msg.get("shell") or "")
            cwd = str(msg.get("cwd") or "")
            if shell:
                self.default_shell = shell
            if cwd:
                self.default_cwd = cwd
            rows = int(msg.get("rows") or self.rows or 24)
            cols = int(msg.get("cols") or self.cols or 96)
            self.resize_all(rows, cols)
            if not self.tabs:
                self.spawn_tab(shell, cwd)
            return True

        if cmd == "new":
            shell = str(msg.get("shell") or self.default_shell)
            cwd = str(msg.get("cwd") or "")
            if not cwd:
                active = self.get_active_tab()
                cwd = active.get_cwd() if active else self.default_cwd
            self.spawn_tab(shell, cwd)
            return True

        if cmd == "switch":
            try:
                tid = int(msg.get("tab") or 0)
            except (TypeError, ValueError):
                return False
            if tid in self.tabs:
                self.active_tab_id = tid
                return True
            return False

        if cmd == "close":
            try:
                tid = int(msg.get("tab") or self.active_tab_id)
            except (TypeError, ValueError):
                tid = self.active_tab_id
            if tid in self.tabs:
                self.close_tab(tid, respawn_if_empty=True)
                return True
            return False

        if cmd == "input":
            data = str(msg.get("data") or "")
            if not self.tabs:
                self.spawn_tab()
            active = self.get_active_tab()
            if active and data:
                self.write_to_tab(active, data.encode("utf-8", errors="replace"))
            return False

        if cmd == "cd":
            path = str(msg.get("path") or "").strip()
            if not path:
                return False
            resolved = resolve_cwd(path)
            if not self.tabs:
                self.spawn_tab(self.default_shell, resolved)
                return True
            active = self.get_active_tab()
            if active:
                active.last_cwd = resolved
                seq = f"\x15cd -- {shlex.quote(resolved)} && clear\r"
                self.write_to_tab(active, seq.encode("utf-8", errors="replace"))
                return True
            return False

        if cmd == "resize":
            rows = int(msg.get("rows") or self.rows)
            cols = int(msg.get("cols") or self.cols)
            self.resize_all(rows, cols)
            return True

        if cmd == "clear":
            active = self.get_active_tab()
            if active:
                active.screen.clear_all()
                self.write_to_tab(active, b"\x0c")
                return True
            return False

        if cmd == "sigint":
            active = self.get_active_tab()
            if active:
                self.write_to_tab(active, b"\x03")
            return False

        return False

    def build_snapshot(self) -> dict:
        if not self.tabs:
            self.spawn_tab()
        active = self.get_active_tab()
        tabs_list = []
        for tid in self.tab_order:
            t = self.tabs.get(tid)
            if not t:
                continue
            tcwd = t.get_cwd()
            tabs_list.append({
                "id": t.id,
                "title": t.get_title(),
                "cwd": tcwd,
                "cwd_short": shorten_cwd(tcwd),
            })

        cwd = active.get_cwd()
        html_out, plain_out = active.screen.render()
        return {
            "active_tab": active.id,
            "tabs": tabs_list,
            "cwd": cwd,
            "cwd_short": shorten_cwd(cwd),
            "rows": self.rows,
            "cols": self.cols,
            "cursor_r": active.screen.cursor_r,
            "cursor_c": active.screen.cursor_c,
            "cursor_visible": active.screen.cursor_visible,
            "html": html_out,
            "plain": plain_out,
        }


def emit_snapshot(mgr: TerminalManager):
    snap = mgr.build_snapshot()
    line = json.dumps(snap, ensure_ascii=False, separators=(",", ":")) + "\n"
    try:
        sys.stdout.write(line)
        sys.stdout.flush()
    except OSError:
        pass


def main():
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)

    stdin_fd = sys.stdin.fileno()
    flags = fcntl.fcntl(stdin_fd, fcntl.F_GETFL)
    fcntl.fcntl(stdin_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

    mgr = TerminalManager()
    stdin_buf = bytearray()

    dirty = False
    dirty_deadline = None
    last_emit_time = 0.0
    last_cwd_check = 0.0
    last_known_cwd = ""

    try:
        while True:
            now = time.monotonic()

            if dirty and dirty_deadline is not None and now >= dirty_deadline:
                emit_snapshot(mgr)
                last_emit_time = time.monotonic()
                dirty = False
                dirty_deadline = None
                active = mgr.get_active_tab()
                if active:
                    last_known_cwd = active.last_cwd

            # Periodically check if active shell changed directory even without recent output
            if not dirty and mgr.tabs and (now - last_cwd_check >= 0.4):
                last_cwd_check = now
                active = mgr.get_active_tab()
                if active:
                    live_cwd = active.get_cwd()
                    if live_cwd != last_known_cwd:
                        last_known_cwd = live_cwd
                        emit_snapshot(mgr)
                        last_emit_time = time.monotonic()

            # Reap any exited children
            try:
                while True:
                    wpid, _ = os.waitpid(-1, os.WNOHANG)
                    if wpid <= 0:
                        break
            except ChildProcessError:
                pass
            except OSError:
                pass

            fd_to_tab = {tab.fd: tab for tab in mgr.tabs.values()}
            rlist = [stdin_fd] + list(fd_to_tab.keys())

            if dirty and dirty_deadline is not None:
                timeout = max(0.001, dirty_deadline - time.monotonic())
            else:
                timeout = 0.4

            try:
                ready, _, _ = select.select(rlist, [], [], timeout)
            except InterruptedError:
                continue
            except (ValueError, OSError):
                continue

            if stdin_fd in ready:
                eof = False
                while True:
                    try:
                        chunk = os.read(stdin_fd, 65536)
                        if not chunk:
                            eof = True
                            break
                        stdin_buf.extend(chunk)
                    except BlockingIOError:
                        break
                    except OSError as exc:
                        if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                            break
                        eof = True
                        break

                while b"\n" in stdin_buf:
                    nl_idx = stdin_buf.index(b"\n")
                    raw_line = bytes(stdin_buf[:nl_idx]).decode("utf-8", errors="replace").strip()
                    del stdin_buf[: nl_idx + 1]
                    if not raw_line:
                        continue
                    try:
                        msg = json.loads(raw_line)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(msg, dict):
                        if mgr.handle_command(msg):
                            emit_snapshot(mgr)
                            last_emit_time = time.monotonic()
                            dirty = False
                            dirty_deadline = None

                if eof:
                    break

            dead_tab_ids = []
            for fd, tab in fd_to_tab.items():
                if fd not in ready:
                    continue
                read_any = False
                while True:
                    try:
                        data = os.read(fd, 65536)
                        if not data:
                            dead_tab_ids.append(tab.id)
                            break
                        read_any = True
                        text = tab.decoder.decode(data, final=False)
                        if text:
                            tab.screen.feed(text)
                        if tab.screen.pty_replies:
                            for reply in tab.screen.pty_replies:
                                mgr.write_to_tab(tab, reply.encode("utf-8"))
                            tab.screen.pty_replies.clear()
                    except BlockingIOError:
                        break
                    except OSError as exc:
                        if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                            break
                        dead_tab_ids.append(tab.id)
                        break

                if read_any:
                    dirty = True
                    if dirty_deadline is None:
                        now_t = time.monotonic()
                        dirty_deadline = max(now_t + 0.008, last_emit_time + 0.030)

            if dead_tab_ids:
                for tid in dead_tab_ids:
                    mgr.close_tab(tid, respawn_if_empty=True)
                emit_snapshot(mgr)
                last_emit_time = time.monotonic()
                dirty = False
                dirty_deadline = None

    finally:
        mgr.close_all()


if __name__ == "__main__":
    main()
