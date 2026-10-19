import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "g" 1.0 as G

PanelWindow {
    id: root

    property string phase: "connecting" // connecting | ready | prompt | busy | auth_error | starting | started
    property var users: []
    property var sessions: []
    property string selectedUser: ""
    property string selectedSession: ""
    property string errorText: ""
    property string promptText: "Пароль"
    property string powerMessage: ""
    property string pendingPower: ""
    property bool userMenuOpen: false
    property bool usersLoaded: false
    property bool sessionsLoaded: false
    property bool loginInProgress: false
    property bool awaitingAnswer: false
    property bool powerBusy: false
    property bool powerError: false
    property bool escapeArmed: false
    property bool backendListsRequested: false
    property var clockNow: new Date()
    readonly property bool previewMode: !String(Quickshell.env("GREETD_SOCK") || "").length
    readonly property bool busy: root.phase === "connecting" || root.phase === "busy"
        || root.phase === "starting" || root.phase === "started"
    readonly property string userLabel: root.labelForUser(root.selectedUser)
    readonly property string avatarLetter: root.firstLetter(root.userLabel)
    readonly property var previewUsers: [{ name: "preview", label: "Предпросмотр" }]
    readonly property var previewSessions: [
        { name: "Umbriel", id: "umbriel", command: "" },
        { name: "Plasma", id: "plasma", command: "" }
    ]
    readonly property var powerActions: [
        { action: "reboot", label: "Перезагрузка", icon: "reboot" },
        { action: "poweroff", label: "Выключить", icon: "power" },
        { action: "suspend", label: "Сон", icon: "bedtime" }
    ]

    color: G.Theme.background
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusiveZone: 0
    focusable: true
    WlrLayershell.namespace: "oberon-greeter"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    function firstLetter(value) {
        const text = String(value || "").trim();
        return text.length ? text.charAt(0).toLocaleUpperCase() : "?";
    }

    function labelForUser(name) {
        for (let i = 0; i < root.users.length; ++i) {
            if (root.users[i].name === name)
                return root.users[i].label;
        }
        return name || "Выберите пользователя";
    }

    function normalizeUsers(value) {
        let source = value;
        if (source && !Array.isArray(source))
            source = source.users || source.items || source.data || [];
        if (!Array.isArray(source))
            return [];

        const result = [];
        for (let i = 0; i < source.length; ++i) {
            const item = source[i];
            const name = typeof item === "string" ? item
                : String(item.username || item.user || item.login || item.name || item.id || "");
            const label = typeof item === "string" ? item
                : String(item.display_name || item.displayName || item.full_name || item.display || item.label || item.name || name);
            if (name.length)
                result.push({ name: name, label: label });
        }
        return result;
    }

    function normalizeSessions(value) {
        let source = value;
        if (source && !Array.isArray(source))
            source = source.sessions || source.items || source.data || [];
        if (!Array.isArray(source))
            return [];

        const result = [];
        for (let i = 0; i < source.length; ++i) {
            const item = source[i];
            const name = typeof item === "string" ? item
                : String(item.name || item.label || item.session || item.id || item.desktop || item.command || item.cmd || "");
            if (name.length) {
                result.push({
                    name: name,
                    label: typeof item === "string" ? item : String(item.label || item.name || name),
                    id: typeof item === "string" ? item : String(item.id || item.session || name),
                    command: typeof item === "string" ? "" : (item.command || item.cmd || item.exec || ""),
                    desktop: typeof item === "string" ? "" : (item.desktop || item.desktop_file || "")
                });
            }
        }
        result.sort(function(a, b) {
            const aUmbriel = a.name.toLowerCase().indexOf("umbriel") === 0 || a.id.toLowerCase().indexOf("umbriel") === 0 ? 0 : 1;
            const bUmbriel = b.name.toLowerCase().indexOf("umbriel") === 0 || b.id.toLowerCase().indexOf("umbriel") === 0 ? 0 : 1;
            return aUmbriel - bUmbriel;
        });
        return result;
    }

    function setUsers(value) {
        root.users = root.normalizeUsers(value);
        root.usersLoaded = true;
        if (!root.users.some(function(user) { return user.name === root.selectedUser; }))
            root.selectedUser = root.users.length ? root.users[0].name : "";
        root.finishConnecting();
    }

    function setSessions(value) {
        root.sessions = root.normalizeSessions(value);
        root.sessionsLoaded = true;
        if (!root.sessions.some(function(session) { return session.name === root.selectedSession; }))
            root.selectedSession = root.sessions.length ? root.sessions[0].name : "";
        root.finishConnecting();
    }

    function finishConnecting() {
        if (root.phase === "connecting" && root.usersLoaded && root.sessionsLoaded) {
            root.phase = "ready";
            passwordField.focusInput();
        }
    }

    function requestBackendLists() {
        if (root.previewMode || root.backendListsRequested)
            return;
        root.backendListsRequested = true;
        root.sendRequest("users", {});
        root.sendRequest("sessions", {});
    }

    function sendRequest(cmd, fields) {
        if (root.previewMode || !client.running)
            return false;

        const request = { cmd: cmd };
        if (fields) {
            for (const key in fields)
                request[key] = fields[key];
        }
        try {
            client.write(JSON.stringify(request) + "\n");
            return true;
        } catch (error) {
            root.errorText = "Не удалось связаться с greetd";
            root.phase = "auth_error";
            return false;
        }
    }

    function eventName(message) {
        let event = String(message.event || message.type || message.kind || message.name || message.status || "");
        if (event.length)
            return event.toLowerCase().replace(/-/g, "_");
        const known = ["users", "sessions", "prompt", "auth_error", "ready", "started", "cancelled", "power_ok", "power_error", "error"];
        for (let i = 0; i < known.length; ++i) {
            if (message[known[i]] !== undefined)
                return known[i];
        }
        return "";
    }

    function messageValue(message, key) {
        if (message[key] !== undefined)
            return message[key];
        if (message.data !== undefined)
            return message.data;
        if (message.payload !== undefined)
            return message.payload;
        if (message.result !== undefined)
            return message.result;
        if (message.items !== undefined)
            return message.items;
        return undefined;
    }

    function handleLine(line) {
        const text = String(line || "").trim();
        if (!text.length)
            return;

        let message;
        try {
            message = JSON.parse(text);
        } catch (error) {
            return;
        }
        if (!message || typeof message !== "object")
            return;

        const event = root.eventName(message);
        switch (event) {
        case "users":
            root.setUsers(root.messageValue(message, "users"));
            break;
        case "sessions":
            root.setSessions(root.messageValue(message, "sessions"));
            break;
        case "prompt": {
            const prompt = message.message || message.prompt || message.text || message.label || "Пароль";
            root.promptText = String(prompt);
            root.errorText = "";
            root.phase = "prompt";
            if (passwordField.text.length)
                root.sendAnswer();
            else
                passwordField.focusInput();
            break;
        }
        case "auth_error":
            root.loginInProgress = false;
            root.awaitingAnswer = false;
            root.errorText = String(message.message || message.description || message.error || message.text || message.reason || "Неверный пароль");
            root.phase = "auth_error";
            passwordField.clear();
            passwordField.focusInput();
            break;
        case "ready":
            if (root.loginInProgress)
                root.startSession();
            else if (root.usersLoaded && root.sessionsLoaded)
                root.phase = "ready";
            break;
        case "started":
            root.loginInProgress = false;
            root.awaitingAnswer = false;
            root.phase = "started";
            break;
        case "cancelled":
            root.loginInProgress = false;
            root.awaitingAnswer = false;
            root.phase = root.usersLoaded && root.sessionsLoaded ? "ready" : "connecting";
            root.errorText = "";
            break;
        case "power_ok":
            root.powerBusy = false;
            root.powerError = false;
            root.pendingPower = "";
            root.powerMessage = String(message.message || "Команда отправлена");
            break;
        case "power_error":
            root.powerBusy = false;
            root.powerError = true;
            root.pendingPower = "";
            root.powerMessage = String(message.message || message.description || message.error || "Нет разрешения на действие питания");
            break;
        case "error":
            root.loginInProgress = false;
            root.awaitingAnswer = false;
            root.errorText = String(message.message || message.description || message.error || message.text || "Ошибка greetd");
            root.phase = "auth_error";
            break;
        default:
            break;
        }
    }

    function beginLogin() {
        if (root.previewMode || root.phase === "busy" || root.phase === "starting" || root.phase === "started")
            return;
        if (root.phase === "prompt" && root.loginInProgress) {
            root.sendAnswer();
            return;
        }
        if (!root.selectedUser.length) {
            root.errorText = "Выберите пользователя";
            root.phase = "auth_error";
            return;
        }
        const password = passwordField.text;
        if (!password.length) {
            root.promptText = "Пароль";
            root.phase = "prompt";
            passwordField.focusInput();
            return;
        }

        let selected = null;
        for (let i = 0; i < root.sessions.length; ++i) {
            if (root.sessions[i].name === root.selectedSession) {
                selected = root.sessions[i];
                break;
            }
        }

        root.errorText = "";
        root.loginInProgress = true;
        root.awaitingAnswer = false;
        root.phase = "busy";
        if (!root.sendRequest("login", {
            user: root.selectedUser,
            username: root.selectedUser,
            password: password,
            session: selected ? selected.id : root.selectedSession,
            session_name: root.selectedSession
        })) {
            root.loginInProgress = false;
            root.errorText = "Не удалось запустить запрос входа";
            root.phase = "auth_error";
        }
        passwordField.clear();
    }

    function sendAnswer() {
        if (root.previewMode || !root.loginInProgress)
            return;
        const password = passwordField.text;
        if (!password.length) {
            passwordField.focusInput();
            return;
        }

        root.errorText = "";
        root.phase = "busy";
        root.awaitingAnswer = true;
        const sent = root.sendRequest("answer", {
            value: password,
            answer: password,
            password: password,
            text: password
        });
        passwordField.clear();
        if (!sent) {
            root.loginInProgress = false;
            root.awaitingAnswer = false;
            root.errorText = "Не удалось отправить ответ greetd";
            root.phase = "auth_error";
        }
    }

    function startSession() {
        let selected = null;
        for (let i = 0; i < root.sessions.length; ++i) {
            if (root.sessions[i].name === root.selectedSession) {
                selected = root.sessions[i];
                break;
            }
        }
        root.phase = "starting";
        root.awaitingAnswer = false;
        if (!root.sendRequest("start", {
            session: root.selectedSession,
            session_name: root.selectedSession,
            session_id: selected ? selected.id : root.selectedSession,
            command: selected ? selected.command : "",
            desktop: selected ? selected.desktop : ""
        })) {
            root.loginInProgress = false;
            root.errorText = "Не удалось запустить выбранную сессию";
            root.phase = "auth_error";
        }
    }

    function handleEnter() {
        if (root.pendingPower.length && powerConfirmButton.activeFocus) {
            root.requestPower(root.pendingPower);
            return;
        }
        if (root.userMenuOpen && userSelect.activeFocus) {
            root.userMenuOpen = false;
            passwordField.focusInput();
            return;
        }
        root.beginLogin();
    }

    function selectUser(name) {
        root.selectedUser = name;
        root.userMenuOpen = false;
        root.errorText = "";
        if (root.phase === "auth_error")
            root.phase = "ready";
    }

    function cycleUser(direction) {
        if (!root.users.length)
            return;
        let index = 0;
        for (let i = 0; i < root.users.length; ++i) {
            if (root.users[i].name === root.selectedUser) {
                index = i;
                break;
            }
        }
        index = (index + direction + root.users.length) % root.users.length;
        root.selectedUser = root.users[index].name;
        root.userMenuOpen = true;
        root.errorText = "";
        if (root.phase === "auth_error")
            root.phase = "ready";
    }

    function cancelLogin() {
        if (root.loginInProgress)
            root.sendRequest("cancel", {});
        root.loginInProgress = false;
        root.awaitingAnswer = false;
        root.userMenuOpen = false;
        root.errorText = "";
        root.phase = root.usersLoaded && root.sessionsLoaded ? "ready" : "connecting";
    }

    function handleEscape() {
        if (!root.escapeArmed) {
            passwordField.clear();
            root.pendingPower = "";
            root.powerMessage = "";
            root.escapeArmed = true;
            escapeTimer.restart();
            return;
        }
        root.escapeArmed = false;
        escapeTimer.stop();
        root.cancelLogin();
        userSelect.forceActiveFocus();
    }

    function requestPower(action) {
        if (root.previewMode || root.powerBusy)
            return;
        if (action === "reboot" || action === "poweroff") {
            if (root.pendingPower !== action) {
                root.pendingPower = action;
                root.powerError = false;
                root.powerMessage = action === "reboot"
                    ? "Нажмите «Перезагрузка» ещё раз для подтверждения"
                    : "Нажмите «Выключить» ещё раз для подтверждения";
                powerConfirmButton.forceActiveFocus();
                return;
            }
        }

        root.pendingPower = "";
        root.powerMessage = "";
        root.powerBusy = true;
        root.powerError = false;
        if (!root.sendRequest("power", { action: action, target: action })) {
            root.powerBusy = false;
            root.powerError = true;
            root.powerMessage = "Не удалось отправить команду питания";
        }
    }

    function updateClock() {
        root.clockNow = new Date();
    }

    Component.onCompleted: {
        if (root.previewMode) {
            root.users = root.previewUsers;
            root.sessions = root.previewSessions;
            root.selectedUser = root.previewUsers[0].name;
            root.selectedSession = root.previewSessions[0].name;
            root.usersLoaded = true;
            root.sessionsLoaded = true;
            root.phase = "ready";
        }
    }

    Process {
        id: client
        command: ["python3", "-u", Qt.resolvedUrl("greetd_client.py").toString().replace(/^file:\/\//, "")]
        running: !root.previewMode
        stdinEnabled: true

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => root.handleLine(data)
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: data => console.warn("Oberon greeter client:", data)
        }

        onRunningChanged: {
            if (running)
                root.requestBackendLists();
        }

        onExited: (exitCode, exitStatus) => {
            if (!root.previewMode && root.phase !== "started" && exitCode !== 0) {
                root.loginInProgress = false;
                root.errorText = "Клиент greetd завершился с ошибкой";
                root.phase = "auth_error";
            }
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: root.updateClock()
    }

    Timer {
        id: escapeTimer
        interval: 1500
        repeat: false
        onTriggered: root.escapeArmed = false
    }

    Item {
        id: contentRoot
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
                root.handleEscape();
                event.accepted = true;
            } else if (event.key === Qt.Key_Tab) {
                if ((event.modifiers & Qt.ShiftModifier) !== 0) {
                    if (passwordField.activeFocus)
                        userSelect.forceActiveFocus();
                    else
                        passwordField.focusInput();
                } else if (passwordField.activeFocus) {
                    userSelect.forceActiveFocus();
                } else {
                    passwordField.focusInput();
                }
                event.accepted = true;
            } else if (event.key === Qt.Key_Up && (root.userMenuOpen || userSelect.activeFocus)) {
                root.cycleUser(-1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Down && (root.userMenuOpen || userSelect.activeFocus)) {
                root.cycleUser(1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.handleEnter();
                event.accepted = true;
            }
        }

        Image {
            id: wallpaper
            anchors.fill: parent
            source: "file:///etc/greetd/wallpaper.png"
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: false
            visible: status === Image.Ready
        }

        Rectangle {
            anchors.fill: parent
            visible: wallpaper.status !== Image.Ready
            gradient: Gradient {
                GradientStop { position: 0; color: "#232b3a" }
                GradientStop { position: 0.48; color: "#171d29" }
                GradientStop { position: 1; color: G.Theme.background }
            }
        }

        Rectangle {
            anchors.fill: parent
            color: "#080a0f"
            opacity: wallpaper.status === Image.Ready ? 0.54 : 0.24
        }

        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0; color: "#66070a12" }
                GradientStop { position: 0.48; color: "#00070a12" }
                GradientStop { position: 1; color: "#99070a12" }
            }
        }

        Column {
            id: clock
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.leftMargin: 56
            anchors.topMargin: 48
            spacing: 2

            G.GText {
                text: Qt.formatDateTime(root.clockNow, "hh:mm")
                role: "display"
                font.pixelSize: 62
                color: G.Theme.text
            }

            G.GText {
                text: Qt.formatDate(root.clockNow, "dddd, d MMMM yyyy")
                role: "title"
                color: G.Theme.subtext
            }
        }

        Row {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.rightMargin: 36
            anchors.topMargin: 36
            spacing: 8
            visible: root.previewMode

            Rectangle {
                width: previewLabel.implicitWidth + 38
                height: 36
                radius: G.Theme.radiusPill
                color: G.Theme.surfaceHigh
                border.width: 1
                border.color: G.Theme.outlineVariant

                Row {
                    anchors.centerIn: parent
                    spacing: 8
                    G.Icon { name: "person"; size: 16; color: G.Theme.accent }
                    G.GText {
                        id: previewLabel
                        text: "Предпросмотр greeter"
                        role: "label"
                        color: G.Theme.text
                    }
                }
            }
        }

        G.Card {
            id: loginCard
            property real shakeOffset: 0
            width: Math.min(contentRoot.width - 32, 460)
            anchors.centerIn: parent
            padding: 30
            spacing: 16
            opacity: root.phase === "started" ? 0 : 1
            scale: root.phase === "connecting" ? 0.985 : 1
            transform: Translate { x: loginCard.shakeOffset }
            Behavior on opacity {
                NumberAnimation { duration: G.Theme.durLong; easing.type: G.Theme.easeStandard }
            }
            Behavior on scale {
                NumberAnimation { duration: G.Theme.durEnter; easing.type: Easing.OutBack; overshoot: 0.7 }
            }

            Column {
                width: parent.width
                spacing: 16

                Row {
                    width: parent.width
                    spacing: 14

                    Rectangle {
                        width: 56
                        height: 56
                        radius: G.Theme.radiusPill
                        color: G.Theme.accentContainer

                        G.GText {
                            anchors.centerIn: parent
                            text: root.avatarLetter
                            role: "title"
                            font.pixelSize: G.Theme.fontHeadlineLarge
                            color: G.Theme.fgAccentContainer
                        }
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 70
                        spacing: 3

                        G.GText {
                            width: parent.width
                            text: "Добро пожаловать"
                            role: "title"
                            color: G.Theme.text
                        }

                        G.GText {
                            width: parent.width
                            text: root.userLabel
                            role: "body"
                            color: G.Theme.subtext
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                    }
                }

                G.Button {
                    id: userSelect
                    width: parent.width
                    text: root.userLabel
                    iconName: "person"
                    trailingIcon: "expand_more"
                    kind: "tonal"
                    enabled: !root.busy && !root.previewMode && root.users.length > 1
                    onClicked: root.userMenuOpen = !root.userMenuOpen
                }

                Repeater {
                    model: root.userMenuOpen ? root.users : []
                    delegate: G.Button {
                        width: parent.width
                        text: modelData.label
                        kind: "plain"
                        selected: modelData.name === root.selectedUser
                        onClicked: root.selectUser(modelData.name)
                    }
                }

                G.PasswordField {
                    id: passwordField
                    width: parent.width
                    placeholderText: root.promptText || "Пароль"
                    enabled: !root.previewMode && root.phase !== "busy" && root.phase !== "starting" && root.phase !== "started"
                    hasError: root.phase === "auth_error"
                    onAccepted: root.handleEnter()
                }

                G.GText {
                    width: parent.width
                    visible: root.errorText.length > 0
                    text: root.errorText
                    role: "bodySmall"
                    roleColor: G.Theme.error
                    horizontalAlignment: Text.AlignHCenter
                }

                G.GText {
                    width: parent.width
                    visible: root.phase === "connecting" || root.phase === "busy" || root.phase === "starting"
                    text: root.phase === "connecting" ? "Подключение к greetd…"
                        : (root.phase === "starting" ? "Запуск сессии…" : "Проверка пароля…")
                    role: "bodySmall"
                    roleColor: G.Theme.subtext
                    horizontalAlignment: Text.AlignHCenter
                }

                G.Button {
                    width: parent.width
                    text: root.phase === "starting" ? "Запуск…"
                        : (root.phase === "busy" ? "Проверка…" : "Войти")
                    iconName: "login"
                    kind: "filled"
                    enabled: !root.previewMode && !root.busy && root.selectedUser.length > 0
                    onClicked: root.beginLogin()
                }

                G.GText {
                    text: "СЕАНС"
                    role: "label"
                    roleColor: G.Theme.subtextDim
                }

                Flow {
                    width: parent.width
                    spacing: 8

                    Repeater {
                        model: root.sessions
                        delegate: G.Button {
                            text: modelData.label
                            kind: "chip"
                            selected: modelData.name === root.selectedSession
                            enabled: !root.busy
                            onClicked: root.selectedSession = modelData.name
                        }
                    }
                }

                G.GText {
                    width: parent.width
                    visible: root.previewMode
                    text: "Режим предпросмотра — вход отключён"
                    role: "bodySmall"
                    roleColor: G.Theme.subtextDim
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }

        Column {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 28
            spacing: 10

            G.GText {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.powerMessage.length > 0
                text: root.powerMessage
                role: "bodySmall"
                roleColor: root.powerError ? G.Theme.error : G.Theme.subtext
            }

            G.Button {
                id: powerConfirmButton
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.pendingPower.length > 0
                text: root.pendingPower === "reboot" ? "Подтвердить перезагрузку" : "Подтвердить выключение"
                iconName: "check"
                kind: "tonal"
                enabled: !root.previewMode && !root.powerBusy
                onClicked: root.requestPower(root.pendingPower)
            }

            Flow {
                width: Math.min(contentRoot.width - 32, 420)
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 8

                Repeater {
                    model: root.powerActions
                    delegate: G.Button {
                        text: modelData.label
                        iconName: modelData.icon
                        kind: "plain"
                        enabled: !root.previewMode && !root.powerBusy && root.phase !== "started"
                        onClicked: root.requestPower(modelData.action)
                    }
                }
            }
        }

        Rectangle {
            anchors.fill: parent
            z: 20
            color: "#000000"
            opacity: root.phase === "started" ? 1 : 0
            Behavior on opacity {
                NumberAnimation { duration: G.Theme.durLong; easing.type: G.Theme.easeStandard }
            }
        }

        SequentialAnimation {
            id: errorShake
            loops: 1
            NumberAnimation { target: loginCard; property: "shakeOffset"; to: -8; duration: 38; easing.type: Easing.OutCubic }
            NumberAnimation { target: loginCard; property: "shakeOffset"; to: 7; duration: 48; easing.type: Easing.InOutCubic }
            NumberAnimation { target: loginCard; property: "shakeOffset"; to: -4; duration: 42; easing.type: Easing.InOutCubic }
            NumberAnimation { target: loginCard; property: "shakeOffset"; to: 0; duration: 44; easing.type: Easing.OutCubic }
        }

        Connections {
            target: root
            function onPhaseChanged() {
                if (root.phase === "auth_error")
                    errorShake.restart();
            }
        }
    }
}
