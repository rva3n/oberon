import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../core"
import "../ui"

// Оверлей-шпаргалка кейбиндов Umbriel (аналог KEYBINDS.qml Lucid, но в Oberon он
// fullscreen-оверлей по образцу Switcher). Источник — ~/.config/umbriel/src/
// keybinds.toml простым парсером: комментарии-заголовки дают секции, строки
// «"Keys" = "action"/{ action = ... }» — построчные записи. Плюс служебный блок
// «Oberon (IPC)» с основными вызовами IPC. Поиск не предусмотрен.
PanelWindow {
    id: sheet

    signal closed()

    property bool shown: false

    property real reveal: sheet.shown ? 1 : 0

    // [{ title, rows: [{ keys, desc }] }]
    property var sections: []
    readonly property var tomlPath: Quickshell.env("HOME") + "/.config/umbriel/src/keybinds.toml"

    // человекочитаемые описания известных действий Umbriel
    readonly property var actionNames: ({
        "window-close": "Закрыть окно",
        "window-toggle-fullscreen": "Полноэкранный режим",
        "window-toggle-floating": "Вкл./выкл. плавающее окно",
        "workspace-switch": "Перейти на рабочий стол",
        "window-move-to-workspace": "Окно на рабочий стол",
        "session-quit:skip-confirmation": "Завершить сессию",
        "session-quit": "Завершить сессию (с подтверждением)"
    })

    function open() { sheet.shown = true; }
    function close() { sheet.shown = false; }

    onShownChanged: {
        if (sheet.shown) catcher.forceActiveFocus();
        else closed();
    }

    // "Mod+period" → ["Super", "."]
    function keyTokens(keys) {
        const cap = {
            "mod": "Super",
            "shift": "Shift",
            "ctrl": "Ctrl",
            "control": "Ctrl",
            "alt": "Alt",
            "return": "Enter",
            "kp_enter": "Enter",
            "backspace": "Backspace",
            "escape": "Esc",
            "space": "Space",
            "tab": "Tab",
            "period": ".",
            "comma": ",",
            "slash": "/",
            "minus": "−",
            "equal": "=",
            "apostrophe": "'",
            "semicolon": ";",
            "grave": "`",
            "print": "PrtSc",
            "backslash": "\\",
            "bracketleft": "[",
            "bracketright": "]"
        };
        return String(keys || "").split("+").map((p) => p.trim()).filter((p) => p !== "").map((p) => {
            const l = p.toLowerCase();
            if (l.indexOf("xf86") === 0) return p.slice(4);
            return cap[l] !== undefined ? cap[l] : (p.length === 1 ? p.toUpperCase() : p);
        });
    }

    // "spawn:ghostty" → "ghostty"; "spawn:... ipc call oberon X" → по IPC-словарю
    function describe(action) {
        const a = String(action || "").trim();
        const orange = a.match(/action\s*=\s*"([^"]*)"/);   // { action = "...", repeat = true }
        const raw = orange ? orange[1] : a;
        const ipc = raw.match(/ipc call oberon ([a-zA-Z]+)/);
        if (ipc) return "Oberon: " + ipcTitle(ipc[1]);
        if (raw.indexOf("session-quit") === 0)
            return raw === "session-quit:skip-confirmation"
                ? sheet.actionNames["session-quit:skip-confirmation"]
                : sheet.actionNames["session-quit"];
        for (const k in sheet.actionNames) {
            if (k === "session-quit" || k === "session-quit:skip-confirmation") continue;
            if (k === "workspace-switch" || k === "window-move-to-workspace") {
                const m = raw.match(new RegExp("^" + k + ":(.+)$"));
                if (m) return sheet.actionNames[k] + " " + m[1];
                continue;
            }
            if (raw === k) return sheet.actionNames[k];
        }
        if (raw.indexOf("spawn:") === 0) {
            const cmd = raw.slice(6).split(/\s+/)[0];
            return "Запуск: " + (cmd.indexOf("/") !== -1 ? cmd.split("/").pop() : cmd);
        }
        return raw !== "" ? raw : "—";
    }

    function ipcTitle(fn) {
        const names = {
            "launcher": "Лончер", "quicksettings": "Быстрые настройки",
            "panel": "Панель", "tray": "Трей", "lock": "Блокировка",
            "wallpapers": "Обои", "clipboard": "Буфер обмена", "emoji": "Эмодзи",
            "session": "Экран сессии", "cheatsheet": "Шпаргалка",
            "screenshotRegion": "Скриншот (тулбар)", "screenshotFull": "Скриншот экрана",
            "switcher": "Переключатель окон", "closeAll": "Закрыть оверлеи",
            "taskman": "Диспетчер задач"
        };
        return names[fn] || fn;
    }

    // простой парсер TOML: # заголовки → секции, "Keys" = "action" → строки
    function parseToml(text) {
        const sections = [];
        let cur = null;
        const lines = String(text || "").split("\n");
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i];
            if (line.trim() === "" || /^\[.*\]$/.test(line.trim())) continue;
            const h = line.match(/^#\s+(.{2,80})\s*$/);
            if (h) {
                cur = { "title": h[1].trim(), "rows": [] };
                sections.push(cur);
                continue;
            }
            const m = line.match(/^\s*"([^"]+)"\s*=\s*(.+)$/);
            if (m && cur) {
                // "action" или { action = "...", repeat = true } — до чистой строки
                const v = m[2].trim();
                const action = v.startsWith('"') && v.lastIndexOf('"') > 0
                    ? v.slice(1, v.lastIndexOf('"'))
                    : v;
                cur.rows.push({ "keys": m[1], "action": action });
            }
        }
        const secs = sections.filter((s) => s.rows.length > 0);
        // служебный блок корабля поверх выписанного из TOML
        const oberon = {
            "title": "Oberon (IPC)",
            "rows": [
                { "keys": "oberon session", "action": "Экран сессии", "desc": "Oberon: экран сессии" },
                { "keys": "oberon cheatsheet", "action": "Шпаргалка кейбиндов", "desc": "Oberon: шпаргалка кейбиндов" },
                { "keys": "oberon closeAll", "action": "Закрыть все оверлеи", "desc": "Oberon: закрыть все оверлеи" },
                { "keys": "oberon screenshotRegion", "action": "Скриншот-тулбар", "desc": "Oberon: скриншот-тулбар" },
                { "keys": "oberon screenshotFull", "action": "Быстрый снимок экрана", "desc": "Oberon: быстрый снимок всего экрана" },
                { "keys": "oberon lock", "action": "Заблокировать экран", "desc": "Oberon: заблокировать экран" }
            ]
        };
        secs.push(oberon);
        return secs.map((s) => ({
            "title": s.title,
            "rows": s.rows.map((r) => ({
                "keys": r.keys,
                "desc": r.desc || sheet.describe(r.action)
            }))
        }));
    }

    visible: sheet.shown || sheet.reveal > 0.01
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "oberon-cheatsheet"
    WlrLayershell.keyboardFocus: sheet.shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Behavior on reveal {
        NumberAnimation {
            duration: sheet.shown ? Theme.durDefaultSpatial : Theme.durFastEffects
            easing.type: Easing.Bezier
            easing.bezierCurve: Theme.curveDefaultSpatial
        }
    }

    FileView {
        id: file
        path: sheet.tomlPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: sheet.sections = sheet.parseToml(text())
        onLoadFailed: sheet.sections = [{ "title": "Кейбинды недоступны", "rows": [] }]
    }

    // фон и клик мимо карточки — закрыть
    Rectangle {
        anchors.fill: parent
        color: Theme.alpha(Theme.cScrim, Theme.blurPct > 0 ? 0.28 : 0.45)
        opacity: sheet.reveal

        MouseArea {
            anchors.fill: parent
            onClicked: sheet.close()
        }
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(Theme.dp(640), Math.max(Theme.dp(320), sheet.width * 0.7))
        height: Math.min(Theme.dp(780), sheet.height * 0.82)
        radius: Theme.shapeXl
        color: Theme.bg
        opacity: sheet.reveal
        transform: Translate { y: (1 - sheet.reveal) * Theme.dp(16) }

        MouseArea { anchors.fill: parent }   // не пропускает клики к фону

        Column {
            x: Theme.dp(8)
            y: Theme.dp(16)
            width: card.width - Theme.dp(16)
            height: card.height - Theme.dp(48)
            spacing: 0

            // Заголовок + подсказка о закрытии
            Item {
                width: parent.width
                height: Theme.dp(44)

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.dp(8)

                    Item {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Theme.dp(28)
                        height: Theme.dp(28)
                        Icon {
                            anchors.centerIn: parent
                            name: "keyboard"
                            size: Theme.dp(22)
                            color: Theme.primary
                        }
                    }
                    LText {
                        anchors.verticalCenter: parent.verticalCenter
                        role: "titleLarge"
                        text: "Кейбинды"
                    }
                }

                LText {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    role: "labelMedium"
                    color: Theme.subtextDim
                    text: "Esc — закрыть  ·  колесо — прокрутка"
                }
            }

            Flickable {
                id: view
                width: parent.width
                height: parent.height - Theme.dp(44)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                contentWidth: width
                contentHeight: col.implicitHeight

                Column {
                    id: col
                    x: Theme.dp(8)
                    width: view.width - Theme.dp(16)
                    spacing: Theme.dp(20)

                    Repeater {
                        model: sheet.sections

                        Column {
                            id: sec
                            required property var modelData
                            width: col.width
                            spacing: Theme.dp(8)

                            Item {
                                width: parent.width
                                height: child.implicitHeight
                                LText {
                                    id: child
                                    width: parent.width
                                    role: "titleMedium"
                                    color: Theme.primary
                                    text: sec.modelData.title
                                }
                            }

                            Column {
                                width: parent.width
                                spacing: Theme.dp(6)

                                Repeater {
                                    model: sec.modelData.rows

                                    delegate: Rectangle {
                                        id: row
                                        required property var modelData
                                        width: parent.width
                                        height: Math.max(Theme.dp(38), caps.implicitHeight + Theme.dp(14))
                                        radius: Theme.rad(12)
                                        color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.04)

                                        Row {
                                            id: caps
                                            anchors.verticalCenter: parent.verticalCenter
                                            x: Theme.dp(12)
                                            width: Math.min(implicitWidth, row.width * 0.5)
                                            clip: true
                                            spacing: Theme.dp(6)

                                            Repeater {
                                                model: sheet.keyTokens(row.modelData.keys)

                                                Rectangle {
                                                    required property string modelData
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    implicitWidth: Math.max(Theme.dp(24), lbl.implicitWidth + Theme.dp(12))
                                                    height: Theme.dp(26)
                                                    radius: Theme.dp(8)
                                                    color: Theme.bgTile

                                                    LText {
                                                        id: lbl
                                                        anchors.centerIn: parent
                                                        role: "labelLarge"
                                                        text: parent.modelData
                                                        color: Theme.text
                                                    }
                                                }
                                            }
                                        }

                                        LText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.right: parent.right
                                            anchors.left: caps.right
                                            anchors.leftMargin: Theme.dp(12)
                                            anchors.rightMargin: Theme.dp(12)
                                            role: "bodyMedium"
                                            color: Theme.text
                                            elide: Text.ElideRight
                                            text: row.modelData.desc
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // клавиатура: Esc закрыть, ↑/↓/PgUp/PgDn прокрутка
    Item {
        id: catcher
        anchors.fill: parent
        focus: sheet.shown

        Keys.onPressed: (event) => {
            if (!sheet.shown) { event.accepted = true; return; }
            if (event.key === Qt.Key_Escape) {
                sheet.close();
                event.accepted = true;
            } else if (event.key === Qt.Key_Up) {
                view.contentY = Math.max(0, view.contentY - Theme.dp(60));
                event.accepted = true;
            } else if (event.key === Qt.Key_Down) {
                view.contentY = Math.min(Math.max(0, view.contentHeight - view.height), view.contentY + Theme.dp(60));
                event.accepted = true;
            } else if (event.key === Qt.Key_PageUp) {
                view.contentY = Math.max(0, view.contentY - view.height * 0.8);
                event.accepted = true;
            } else if (event.key === Qt.Key_PageDown) {
                view.contentY = Math.min(Math.max(0, view.contentHeight - view.height), view.contentY + view.height * 0.8);
                event.accepted = true;
            }
        }
    }
}
