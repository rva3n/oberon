pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../core"
import "../../ui"

// Встроенный многовкладочный PTY/VT100-терминал Oberon в капсуле острова.
ColumnLayout {
    id: root

    property var win: null
    readonly property bool active: win !== null && win.mode === "panel" && win.page === "terminal"

    readonly property string homeDir: Quickshell.env("HOME") || "/"
    readonly property string scriptPath: homeDir + "/oberon/scripts/term.py"

    property int activeTabId: 1
    property var tabsModel: ([
        { id: 1, title: "bash", cwd: homeDir, cwd_short: "~" }
    ])
    property string currentCwd: homeDir
    property string currentCwdShort: "~"
    property int termRows: 24
    property int termCols: 96
    property int cursorR: 0
    property int cursorC: 0
    property bool cursorVisible: true
    property string screenHtml: "<pre style=\"margin:0;white-space:pre;\"></pre>"
    property string screenPlain: ""
    property string statusText: ""
    property string pendingCdPath: ""
    property bool backendInitialized: false

    readonly property var quickCommands: [
        { label: "fastfetch", cmd: "fastfetch", icon: "terminal" },
        { label: "git status", cmd: "git status", icon: "code" },
        { label: "paru -Syu", cmd: "paru -Syu", icon: "system_update_alt" },
        { label: "df -h", cmd: "df -h", icon: "hard_drive" },
        { label: "ip -br a", cmd: "ip -br a", icon: "lan" },
        { label: "free -h", cmd: "free -h", icon: "memory" },
        { label: "journalctl -p 3 -xb", cmd: "journalctl -p 3 -xb", icon: "receipt_long" }
    ]

    visible: root.active
    Layout.fillWidth: true
    Layout.preferredHeight: Theme.dp(540)
    spacing: Theme.dp(8)

    FontMetrics {
        id: monoMetrics
        font.family: "monospace"
        font.pixelSize: Theme.fs(Prefs.termFontSize !== undefined ? Prefs.termFontSize : 13)
    }

    function ensureRunning() {
        if (!termProc.running) {
            termProc.running = true;
        }
    }

    function sendCmd(payload) {
        root.ensureRunning();
        if (!termProc.running)
            return false;
        try {
            termProc.write(JSON.stringify(payload) + "\n");
            return true;
        } catch (e) {
            return false;
        }
    }

    function sendInput(text) {
        if (!text || text.length === 0)
            return;
        root.sendCmd({ cmd: "input", data: String(text) });
    }

    function sendQuickCommand(cmdText) {
        const clean = String(cmdText || "");
        if (clean.length === 0)
            return;
        root.sendCmd({ cmd: "input", data: clean + "\r" });
        termFocus.forceActiveFocus();
    }

    function requestCd(path) {
        const clean = String(path || "").trim();
        if (clean === "")
            return;
        if (!termProc.running || !root.backendInitialized) {
            root.pendingCdPath = clean;
            root.ensureRunning();
            return;
        }
        root.sendCmd({ cmd: "cd", path: clean });
        Qt.callLater(() => termFocus.forceActiveFocus());
    }

    function computeGridDimensions() {
        const availW = Math.max(Theme.dp(240), termFlick.width - Theme.dp(24));
        const availH = Math.max(Theme.dp(140), termFlick.height - Theme.dp(20));
        const charW = Math.max(6, monoMetrics.averageCharacterWidth || 8);
        const lineH = Math.max(12, monoMetrics.lineSpacing || 16);
        const cols = Math.max(40, Math.min(220, Math.floor(availW / charW)));
        const rows = Math.max(10, Math.min(80, Math.floor(availH / lineH)));
        return { rows: rows, cols: cols };
    }

    function syncResize() {
        const dims = root.computeGridDimensions();
        if (dims.rows !== root.termRows || dims.cols !== root.termCols) {
            root.termRows = dims.rows;
            root.termCols = dims.cols;
            if (termProc.running && root.backendInitialized) {
                root.sendCmd({ cmd: "resize", rows: dims.rows, cols: dims.cols });
            }
        }
    }

    function pasteClipboard() {
        if (pasteProc.running)
            return;
        pasteProc.buf = "";
        pasteProc.running = true;
        termFocus.forceActiveFocus();
    }

    function copyOutput() {
        const text = String(root.screenPlain || "");
        if (text.trim() === "") {
            root.statusText = "Экран пуст";
            statusClearTimer.restart();
            return;
        }
        Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" | wl-copy", "sh", text]);
        root.statusText = "Вывод скопирован в буфер";
        statusClearTimer.restart();
        termFocus.forceActiveFocus();
    }

    function openExternalTerminal() {
        const dir = root.currentCwd || root.homeDir;
        const customShell = String(Prefs.termShell !== undefined ? Prefs.termShell : "");
        Quickshell.execDetached([
            "sh", "-c",
            "cd -- \"$1\" 2>/dev/null || cd \"$HOME\"; " +
            "for term in kitty ghostty alacritty foot wezterm; do " +
            "  if command -v \"$term\" >/dev/null 2>&1; then exec \"$term\"; fi; " +
            "done",
            "sh", dir, customShell
        ]);
    }

    function submitQuickBar() {
        const cmd = quickInput.text;
        quickInput.text = "";
        root.sendCmd({ cmd: "input", data: cmd + "\r" });
        termFocus.forceActiveFocus();
    }

    function handleSnapshotLine(line) {
        const raw = String(line || "").trim();
        if (raw === "")
            return;
        try {
            const snap = JSON.parse(raw);
            if (!snap || typeof snap !== "object")
                return;
            const wasAtBottom = termFlick.contentHeight <= termFlick.height
                || (termFlick.contentY >= termFlick.contentHeight - termFlick.height - Theme.dp(32));

            if (typeof snap.active_tab === "number")
                root.activeTabId = snap.active_tab;
            if (Array.isArray(snap.tabs) && snap.tabs.length > 0)
                root.tabsModel = snap.tabs;
            if (typeof snap.cwd === "string" && snap.cwd !== "")
                root.currentCwd = snap.cwd;
            if (typeof snap.cwd_short === "string" && snap.cwd_short !== "")
                root.currentCwdShort = snap.cwd_short;
            if (typeof snap.rows === "number")
                root.termRows = snap.rows;
            if (typeof snap.cols === "number")
                root.termCols = snap.cols;
            if (typeof snap.cursor_r === "number")
                root.cursorR = snap.cursor_r;
            if (typeof snap.cursor_c === "number")
                root.cursorC = snap.cursor_c;
            if (typeof snap.cursor_visible === "boolean")
                root.cursorVisible = snap.cursor_visible;
            if (typeof snap.html === "string")
                root.screenHtml = snap.html;
            if (typeof snap.plain === "string")
                root.screenPlain = snap.plain;

            if (wasAtBottom) {
                Qt.callLater(() => {
                    if (termFlick.contentHeight > termFlick.height)
                        termFlick.contentY = termFlick.contentHeight - termFlick.height;
                    else
                        termFlick.contentY = 0;
                });
            }
        } catch (e) {}
    }

    onActiveChanged: {
        if (root.active) {
            root.ensureRunning();
            if (root.backendInitialized) {
                if (root.pendingCdPath !== "") {
                    const target = root.pendingCdPath;
                    root.pendingCdPath = "";
                    root.sendCmd({ cmd: "cd", path: target });
                }
            }
            Qt.callLater(() => {
                root.syncResize();
                termFocus.forceActiveFocus();
            });
        }
    }

    Connections {
        target: root.win ? root.win.shell : null
        ignoreUnknownSignals: true
        function onTerminalCdRequested(path) {
            root.requestCd(path);
        }
    }

    Timer {
        id: resizeDebounce
        interval: 90
        onTriggered: root.syncResize()
    }

    Timer {
        id: statusClearTimer
        interval: 2200
        onTriggered: root.statusText = ""
    }

    Process {
        id: termProc
        command: ["python3", "-u", root.scriptPath]
        running: false
        stdinEnabled: true

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => root.handleSnapshotLine(line)
        }

        onRunningChanged: {
            if (termProc.running) {
                const dims = root.computeGridDimensions();
                root.termRows = dims.rows;
                root.termCols = dims.cols;
                const initCwd = root.pendingCdPath !== ""
                    ? root.pendingCdPath
                    : String(Prefs.termCwd !== undefined ? Prefs.termCwd : "");
                const initShell = String(Prefs.termShell !== undefined ? Prefs.termShell : "");
                root.backendInitialized = true;
                root.sendCmd({
                    cmd: "init",
                    shell: initShell,
                    cwd: initCwd,
                    rows: dims.rows,
                    cols: dims.cols
                });
                if (root.pendingCdPath !== "") {
                    const cdTarget = root.pendingCdPath;
                    root.pendingCdPath = "";
                    root.sendCmd({ cmd: "cd", path: cdTarget });
                }
            } else {
                root.backendInitialized = false;
            }
        }
    }

    Process {
        id: pasteProc
        property string buf: ""
        command: ["wl-paste", "-n"]
        running: false
        stdout: SplitParser {
            splitMarker: ""
            onRead: chunk => pasteProc.buf += chunk
        }
        onExited: exitCode => {
            if (exitCode === 0 && pasteProc.buf.length > 0) {
                root.sendInput(pasteProc.buf);
            }
            pasteProc.buf = "";
        }
    }

    // ── 1. ВЕРХНЯЯ ПАНЕЛЬ ВКЛАДОК PTY, ТЕКУЩЕЙ ПАПКИ И БЫСТРЫХ ДЕЙСТВИЙ ──
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.dp(6)

        Flickable {
            id: tabsFlick
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.dp(30)
            contentWidth: tabsRow.implicitWidth
            contentHeight: height
            clip: true
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds

            Row {
                id: tabsRow
                height: parent.height
                spacing: Theme.dp(6)

                Repeater {
                    model: root.tabsModel
                    delegate: Chip {
                        id: tabChip
                        required property var modelData
                        size: "sm"
                        kind: "filter"
                        icon: "terminal"
                        selected: Number(tabChip.modelData.id) === root.activeTabId
                        closable: true
                        label: String(tabChip.modelData.id) + ": " + String(tabChip.modelData.cwd_short || tabChip.modelData.title || "~")
                        onClicked: {
                            root.sendCmd({ cmd: "switch", tab: Number(tabChip.modelData.id) });
                            termFocus.forceActiveFocus();
                        }
                        onCloseClicked: {
                            root.sendCmd({ cmd: "close", tab: Number(tabChip.modelData.id) });
                            termFocus.forceActiveFocus();
                        }
                    }
                }
            }
        }

        IconButton {
            size: "xs"
            variant: "tonal"
            icon: "add"
            tooltip: "Новая вкладка (Ctrl+Shift+T)"
            onClicked: {
                root.sendCmd({
                    cmd: "new",
                    shell: String(Prefs.termShell !== undefined ? Prefs.termShell : ""),
                    cwd: root.currentCwd
                });
                termFocus.forceActiveFocus();
            }
        }

        Chip {
            size: "sm"
            kind: "assist"
            icon: "folder_open"
            label: root.currentCwdShort || "~"
            onClicked: {
                if (root.win && root.win.shell)
                    root.win.shell.openFiles(root.currentCwd);
            }
        }

        IconButton {
            size: "xs"
            icon: "content_paste"
            tooltip: "Вставить"
            onClicked: root.pasteClipboard()
        }

        IconButton {
            size: "xs"
            icon: "content_copy"
            tooltip: "Копировать вывод"
            onClicked: root.copyOutput()
        }

        IconButton {
            size: "xs"
            icon: "stop_circle"
            tooltip: "Прервать (Ctrl+C)"
            onClicked: {
                root.sendCmd({ cmd: "sigint" });
                termFocus.forceActiveFocus();
            }
        }

        IconButton {
            size: "xs"
            icon: "delete_sweep"
            tooltip: "Очистить"
            onClicked: {
                root.sendCmd({ cmd: "clear" });
                termFocus.forceActiveFocus();
            }
        }

        IconButton {
            size: "xs"
            icon: "open_in_new"
            tooltip: "В отдельное окно"
            onClicked: root.openExternalTerminal()
        }

        IconButton {
            size: "xs"
            icon: "tune"
            tooltip: "Настройки терминала"
            onClicked: {
                if (root.win && root.win.shell)
                    root.win.shell.setPage("settings", "terminal");
            }
        }
    }

    // ── 2. ПОЛОСА БЫСТРЫХ КОМАНД (ЧИПЫ) ──────────────────────────────────
    Flickable {
        visible: Prefs.termShowChips === undefined ? true : Prefs.termShowChips
        Layout.fillWidth: true
        Layout.preferredHeight: Theme.dp(28)
        contentWidth: quickChipsRow.implicitWidth
        contentHeight: height
        clip: true
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds

        Row {
            id: quickChipsRow
            height: parent.height
            spacing: Theme.dp(6)

            Repeater {
                model: root.quickCommands
                delegate: Chip {
                    id: qChip
                    required property var modelData
                    size: "sm"
                    kind: "suggestion"
                    icon: qChip.modelData.icon
                    label: qChip.modelData.label
                    onClicked: root.sendQuickCommand(qChip.modelData.cmd)
                }
            }
        }
    }

    // ── 3. ИНТЕРАКТИВНЫЙ ЭКРАН ТЕРМИНАЛА (VT100 / ANSI) ──────────────────
    Rectangle {
        id: viewportCard
        Layout.fillWidth: true
        Layout.fillHeight: true
        radius: Theme.shapeLg
        color: Theme.alpha(Theme.mLowest, Prefs.termOpacity !== undefined ? Prefs.termOpacity : 0.92)
        border.width: termFocus.activeFocus ? 1 : 0
        border.color: Theme.outline
        clip: true

        FocusScope {
            id: termFocus
            anchors.fill: parent
            focus: true
            activeFocusOnTab: true
            Keys.priority: Keys.BeforeItem

            Keys.onPressed: event => {
                const mods = event.modifiers;
                const ctrl = (mods & Qt.ControlModifier) !== 0;
                const shift = (mods & Qt.ShiftModifier) !== 0;
                const alt = (mods & Qt.AltModifier) !== 0;

                if (event.key === Qt.Key_Escape) {
                    if (shift) {
                        root.sendInput("\x1b");
                    } else if (root.win && root.win.shell) {
                        root.win.shell.closeOverlays();
                    }
                    event.accepted = true;
                    return;
                }

                // Ctrl+Shift shortcuts
                if (ctrl && shift) {
                    if (event.key === Qt.Key_C) {
                        root.copyOutput();
                        event.accepted = true;
                        return;
                    }
                    if (event.key === Qt.Key_V) {
                        root.pasteClipboard();
                        event.accepted = true;
                        return;
                    }
                    if (event.key === Qt.Key_T) {
                        root.sendCmd({
                            cmd: "new",
                            shell: String(Prefs.termShell !== undefined ? Prefs.termShell : ""),
                            cwd: root.currentCwd
                        });
                        event.accepted = true;
                        return;
                    }
                    if (event.key === Qt.Key_W) {
                        root.sendCmd({ cmd: "close", tab: root.activeTabId });
                        event.accepted = true;
                        return;
                    }
                }

                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.sendInput("\r");
                    event.accepted = true;
                    return;
                }
                if (event.key === Qt.Key_Backspace) {
                    root.sendInput(ctrl ? "\x17" : "\x7f");
                    event.accepted = true;
                    return;
                }
                if (event.key === Qt.Key_Tab) {
                    root.sendInput(shift ? "\x1b[Z" : "\t");
                    event.accepted = true;
                    return;
                }
                if (event.key === Qt.Key_Backtab) {
                    root.sendInput("\x1b[Z");
                    event.accepted = true;
                    return;
                }
                if (event.key === Qt.Key_Up) {
                    root.sendInput("\x1b[A");
                    event.accepted = true;
                    return;
                }
                if (event.key === Qt.Key_Down) {
                    root.sendInput("\x1b[B");
                    event.accepted = true;
                    return;
                }
                if (event.key === Qt.Key_Right) {
                    root.sendInput(ctrl ? "\x1b[1;5C" : "\x1b[C");
                    event.accepted = true;
                    return;
                }
                if (event.key === Qt.Key_Left) {
                    root.sendInput(ctrl ? "\x1b[1;5D" : "\x1b[D");
                    event.accepted = true;
                    return;
                }
                if (event.key === Qt.Key_Home) {
                    root.sendInput("\x1b[H");
                    event.accepted = true;
                    return;
                }
                if (event.key === Qt.Key_End) {
                    root.sendInput("\x1b[F");
                    event.accepted = true;
                    return;
                }
                if (event.key === Qt.Key_PageUp) {
                    root.sendInput("\x1b[5~");
                    event.accepted = true;
                    return;
                }
                if (event.key === Qt.Key_PageDown) {
                    root.sendInput("\x1b[6~");
                    event.accepted = true;
                    return;
                }
                if (event.key === Qt.Key_Delete) {
                    root.sendInput("\x1b[3~");
                    event.accepted = true;
                    return;
                }
                if (event.key === Qt.Key_Insert) {
                    root.sendInput("\x1b[2~");
                    event.accepted = true;
                    return;
                }

                // Ctrl+<A..Z>
                if (ctrl && !alt && event.key >= Qt.Key_A && event.key <= Qt.Key_Z) {
                    const code = event.key - Qt.Key_A + 1;
                    root.sendInput(String.fromCharCode(code));
                    event.accepted = true;
                    return;
                }

                if (event.text && event.text.length > 0) {
                    if (alt && !ctrl)
                        root.sendInput("\x1b" + event.text);
                    else
                        root.sendInput(event.text);
                    event.accepted = true;
                }
            }

            Flickable {
                id: termFlick
                anchors.fill: parent
                anchors.margins: Theme.dp(10)
                contentWidth: Math.max(width, termOutputText.implicitWidth)
                contentHeight: Math.max(height, termOutputText.implicitHeight)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.HorizontalAndVerticalFlick

                onWidthChanged: resizeDebounce.restart()
                onHeightChanged: resizeDebounce.restart()

                Text {
                    id: termOutputText
                    width: Math.max(termFlick.width, implicitWidth)
                    textFormat: Text.RichText
                    font.family: "monospace"
                    font.pixelSize: Theme.fs(Prefs.termFontSize !== undefined ? Prefs.termFontSize : 13)
                    color: Theme.text
                    text: root.screenHtml
                    onFontChanged: resizeDebounce.restart()
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                    cursorShape: Qt.IBeamCursor
                    onPressed: mouse => {
                        termFocus.forceActiveFocus();
                        if (mouse.button === Qt.MiddleButton || mouse.button === Qt.RightButton) {
                            root.pasteClipboard();
                        }
                        mouse.accepted = false;
                    }
                    onClicked: termFocus.forceActiveFocus()
                }
            }

            // Индикатор статуса или подсказка фокуса в правом нижнем углу
            Rectangle {
                visible: root.statusText !== "" || !termFocus.activeFocus
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: Theme.dp(8)
                height: Theme.dp(22)
                width: statusLabel.implicitWidth + Theme.dp(14)
                radius: Theme.radiusPill
                color: Theme.alpha(Theme.mHighest, 0.85)

                LText {
                    id: statusLabel
                    anchors.centerIn: parent
                    role: "labelSmall"
                    color: root.statusText !== "" ? Theme.primary : Theme.subtext
                    text: root.statusText !== ""
                        ? root.statusText
                        : "Щёлкните для фокуса клавиатуры · " + root.termCols + "×" + root.termRows
                }
            }
        }
    }

    // ── 4. НИЖНЯЯ СТРОКА БЫСТРОГО ВВОДА КОМАНДЫ ──────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.dp(8)

        TextField {
            id: quickInput
            Layout.fillWidth: true
            variant: "search"
            icon: "chevron_right"
            placeholder: "Быстрый ввод команды или текста (Enter — отправить в PTY)…"
            onAccepted: root.submitQuickBar()
            onEscaped: termFocus.forceActiveFocus()
        }

        Button {
            size: "s"
            variant: "tonal"
            icon: "send"
            text: "Отправить"
            onClicked: root.submitQuickBar()
        }
    }
}
