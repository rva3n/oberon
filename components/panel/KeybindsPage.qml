import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../core"
import "../../ui"
import "../settings"

Item {
    id: page

    property var win: null
    property var binds: []
    property string query: ""
    property string comboText: ""
    property string actionText: ""
    property string editingKeys: ""
    property string selectedPreset: ""
    property string statusText: ""
    property string taskKind: ""
    property var queuedTaskArgs: []
    property string queuedTaskKind: ""
    property string renameTarget: ""
    property string deleteCombo: ""
    property bool repeatEnabled: true
    property bool captureOpen: false
    property bool captureKeyDown: false
    property bool statusIsError: false
    property bool statusIsWarning: false
    property bool taskValidationWarning: false
    property bool hasBackup: false
    property var captureModifiers: []
    property string captureCombo: ""
    property string captureKey: ""
    property int captureKeyScan: -1

    readonly property string scriptPath: Quickshell.env("HOME") + "/oberon/scripts/keybinds.py"
    readonly property var actionOptions: [
        { key: "", label: "Выбрать популярное действие" },
        { key: "spawn:ghostty", label: "Запустить Ghostty" },
        { key: "window-close", label: "Закрыть окно" },
        { key: "window-toggle-fullscreen", label: "Полноэкранный режим" },
        { key: "window-toggle-floating", label: "Плавающее окно" },
        { key: "window-toggle-maximize", label: "Развернуть колонку" },
        { key: "workspace-switch:1", label: "Рабочий стол 1" },
        { key: "workspace-switch:2", label: "Рабочий стол 2" },
        { key: "workspace-switch:3", label: "Рабочий стол 3" },
        { key: "window-move-to-workspace:1", label: "Переместить окно на стол 1" },
        { key: "overview-toggle", label: "Обзор рабочих столов" },
        { key: "cheatsheet-toggle", label: "Шпаргалка сочетаний" },
        { key: "keyboard-layout-next", label: "Следующая раскладка" },
        { key: "shortcuts-inhibit-toggle", label: "Пропуск сочетаний в приложении" },
        { key: "session-quit", label: "Завершить с подтверждением" },
        { key: "session-quit:skip-confirmation", label: "Немедленно завершить сессию" }
    ]
    readonly property var filteredBinds: {
        const q = page.query.trim().toLowerCase();
        return page.binds.filter((bind) => {
            const special = Array.isArray(bind.special) ? bind.special.join(" ") : "";
            const text = [bind.keys, bind.action, bind.note || "", special].join(" ").toLowerCase();
            return q === "" || text.indexOf(q) >= 0;
        });
    }
    readonly property string comboConflict: {
        const candidate = page.comboText.trim();
        if (candidate === "") return "";
        for (let i = 0; i < page.binds.length; i++) {
            const bind = page.binds[i];
            if (bind.keys === candidate && bind.keys !== page.editingKeys)
                return "Сочетание уже используется для действия «" + bind.action + "».";
        }
        return "";
    }

    Layout.fillWidth: true
    implicitHeight: content.implicitHeight

    function enterPage() {
        page.statusText = "";
        page.statusIsError = false;
        page.statusIsWarning = false;
        page.runTask(["backup"], "initial-backup");
    }

    function runTask(args, kind) {
        if (taskProc.running || page.queuedTaskKind !== "")
            return false;
        if (kind === "write" || kind === "remove" || kind === "rename" || kind === "restore") {
            page.taskValidationWarning = false;
            page.statusIsWarning = false;
        }
        taskProc.args = args;
        taskProc.kind = kind;
        taskProc.stdoutText = "";
        taskProc.stderrText = "";
        page.taskKind = kind;
        taskProc.running = true;
        return true;
    }

    function queueTask(args, kind) {
        if (page.queuedTaskKind !== "")
            return false;
        page.queuedTaskArgs = args.slice();
        page.queuedTaskKind = kind;
        taskRestartTimer.restart();
        return true;
    }

    function startQueuedTask() {
        if (taskProc.running || page.queuedTaskKind === "")
            return;
        const args = page.queuedTaskArgs;
        const kind = page.queuedTaskKind;
        page.queuedTaskArgs = [];
        page.queuedTaskKind = "";
        if (!page.runTask(args, kind)) {
            page.queuedTaskArgs = args;
            page.queuedTaskKind = kind;
        }
    }

    function finishTask(exitCode) {
        const kind = taskProc.kind;
        const output = taskProc.stdoutText.trim();
        const errorOutput = taskProc.stderrText.trim();
        taskProc.kind = "";
        page.taskKind = "";

        if (kind === "list") {
            if (exitCode !== 0) {
                page.statusText = errorOutput || "Не удалось прочитать сочетания клавиш.";
                page.statusIsError = true;
                page.statusIsWarning = false;
                return;
            }
            try {
                const parsed = JSON.parse(output || "[]");
                if (!Array.isArray(parsed)) throw new Error("invalid keybind list");
                page.binds = parsed;
            } catch (error) {
                page.statusText = "Скрипт вернул некорректный список сочетаний.";
                page.statusIsError = true;
                page.statusIsWarning = false;
            }
            return;
        }

        if (kind === "initial-backup" || kind === "backup") {
            page.hasBackup = exitCode === 0;
            if (exitCode === 0) {
                page.statusText = kind === "backup" ? "Резервная копия обновлена." : "Резервная копия готова.";
                page.statusIsError = false;
                page.statusIsWarning = false;
            } else {
                page.statusText = errorOutput || "Не удалось создать резервную копию.";
                page.statusIsError = true;
                page.statusIsWarning = false;
            }
            if (kind === "initial-backup")
                page.queueTask(["list"], "list");
            return;
        }

        if (kind === "write" || kind === "remove" || kind === "rename" || kind === "restore") {
            const validatorUnavailable = exitCode === 2;
            if (exitCode !== 0 && !validatorUnavailable) {
                page.statusText = errorOutput || "Операция не прошла проверку конфигурации.";
                page.statusIsError = true;
                page.statusIsWarning = false;
                page.queueTask(["list"], "list");
                return;
            }
            if (kind === "rename") {
                page.editingKeys = page.renameTarget;
                page.comboText = page.renameTarget;
            } else if (kind === "write") {
                page.editingKeys = page.comboText.trim();
            } else if (kind === "remove" && page.deleteCombo === page.editingKeys) {
                page.clearEditor();
            }
            page.taskValidationWarning = validatorUnavailable;
            page.statusText = validatorUnavailable
                ? "Записано, но не проверено: валидатор недоступен."
                : "Проверка пройдена — применяю изменения…";
            page.statusIsError = false;
            page.statusIsWarning = validatorUnavailable;
            page.queueTask(["apply"], "apply");
            return;
        }

        if (kind === "apply") {
            if (exitCode === 2)
                page.taskValidationWarning = true;
            if (exitCode === 0 || exitCode === 2) {
                page.statusText = page.taskValidationWarning
                    ? "Записано, но не проверено: валидатор недоступен."
                        + (output !== "" ? " " + output : "")
                    : (output || "Изменения применены.");
                page.statusIsError = false;
                page.statusIsWarning = page.taskValidationWarning;
            } else {
                page.statusText = errorOutput || "Не удалось применить изменения.";
                page.statusIsError = true;
                page.statusIsWarning = false;
            }
            page.taskValidationWarning = false;
            page.queueTask(["list"], "list");
        }
    }

    function refreshBinds() {
        page.runTask(["list"], "list");
    }

    function saveBackup() {
        page.runTask(["backup", "--force"], "backup");
    }

    function restoreBackup() {
        if (!page.hasBackup || taskProc.running) return;
        page.runTask(["restore"], "restore");
    }

    function newBinding() {
        page.editingKeys = "";
        page.comboText = "";
        page.actionText = "";
        page.selectedPreset = "";
        page.repeatEnabled = true;
        page.statusText = "";
        page.statusIsError = false;
        page.statusIsWarning = false;
    }

    function editBinding(bind) {
        page.editingKeys = String(bind.keys || "");
        page.comboText = page.editingKeys;
        page.actionText = String(bind.action || "");
        page.selectedPreset = page.presetFor(page.actionText);
        page.repeatEnabled = bind.repeat !== false;
        page.statusText = "";
        page.statusIsError = false;
        page.statusIsWarning = false;
    }

    function clearEditor() {
        page.editingKeys = "";
        page.comboText = "";
        page.actionText = "";
        page.selectedPreset = "";
        page.repeatEnabled = true;
    }

    function presetFor(action) {
        for (let i = 0; i < page.actionOptions.length; i++)
            if (page.actionOptions[i].key === action) return action;
        return "";
    }

    function saveBinding() {
        if (taskProc.running) return;
        const combo = page.comboText.trim();
        const action = page.actionText.trim();
        if (combo === "" || action === "") {
            page.statusText = "Укажите сочетание и действие.";
            page.statusIsError = true;
            page.statusIsWarning = false;
            return;
        }
        if (/[\r\n]/.test(combo) || /[\r\n]/.test(action)) {
            page.statusText = "Переводы строк в сочетании и действии не поддерживаются.";
            page.statusIsError = true;
            page.statusIsWarning = false;
            return;
        }
        page.comboText = combo;
        page.actionText = action;
        page.renameTarget = combo;
        const repeatArg = page.repeatEnabled ? "--repeat=true" : "--repeat=false";
        const renaming = page.editingKeys !== "" && page.editingKeys !== combo;
        const args = renaming
            ? ["rename", page.editingKeys, combo, action, repeatArg]
            : ["set", combo, action, repeatArg];
        page.runTask(args, renaming ? "rename" : "write");
    }

    function removeBinding(bind) {
        if (taskProc.running) return;
        page.deleteCombo = String(bind.keys || "");
        page.runTask(["remove", page.deleteCombo], "remove");
    }

    function isCritical(action) {
        return String(action || "").indexOf("session-quit") === 0;
    }

    function specialText(bind) {
        if (!bind || !Array.isArray(bind.special) || bind.special.length === 0) return "";
        return "Параметры: " + bind.special.join(", ");
    }

    function modifierForKey(key) {
        if (key === Qt.Key_Meta || key === Qt.Key_Super_L || key === Qt.Key_Super_R) return "Super";
        if (key === Qt.Key_Control) return "Ctrl";
        if (key === Qt.Key_Alt || key === Qt.Key_AltGr) return "Alt";
        if (key === Qt.Key_Shift) return "Shift";
        return "";
    }

    function orderedModifiers(values) {
        const order = ["Super", "Ctrl", "Alt", "Shift"];
        return order.filter((name) => values.indexOf(name) >= 0);
    }

    function modifiersForEvent(event) {
        let values = page.captureModifiers.slice();
        if (event.modifiers & Qt.MetaModifier) values.push("Super");
        if (event.modifiers & Qt.ControlModifier) values.push("Ctrl");
        if (event.modifiers & Qt.AltModifier) values.push("Alt");
        if (event.modifiers & Qt.ShiftModifier) values.push("Shift");
        return page.orderedModifiers(values);
    }

    function keyName(event) {
        const key = event.key;
        if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(key);
        if (key >= Qt.Key_0 && key <= Qt.Key_9) return String.fromCharCode(key);
        if (key >= Qt.Key_F1 && key <= Qt.Key_F24) return "F" + (key - Qt.Key_F1 + 1);
        switch (key) {
        case Qt.Key_Return: return "Return";
        case Qt.Key_Enter: return "KP_Enter";
        case Qt.Key_Escape: return "Escape";
        case Qt.Key_Backspace: return "BackSpace";
        case Qt.Key_Tab:
        case Qt.Key_Backtab: return "Tab";
        case Qt.Key_Space: return "Space";
        case Qt.Key_Delete: return "Delete";
        case Qt.Key_Insert: return "Insert";
        case Qt.Key_Home: return "Home";
        case Qt.Key_End: return "End";
        case Qt.Key_PageUp: return "Page_Up";
        case Qt.Key_PageDown: return "Page_Down";
        case Qt.Key_Left: return "Left";
        case Qt.Key_Right: return "Right";
        case Qt.Key_Up: return "Up";
        case Qt.Key_Down: return "Down";
        case Qt.Key_Print: return "Print";
        case Qt.Key_Comma: return "comma";
        case Qt.Key_Period: return "period";
        case Qt.Key_Slash: return "slash";
        case Qt.Key_Minus: return "minus";
        case Qt.Key_Equal: return "equal";
        case Qt.Key_Semicolon: return "semicolon";
        case Qt.Key_Apostrophe: return "apostrophe";
        case Qt.Key_QuoteLeft: return "grave";
        case Qt.Key_Backslash: return "backslash";
        case Qt.Key_BracketLeft: return "bracketleft";
        case Qt.Key_BracketRight: return "bracketright";
        case Qt.Key_VolumeUp: return "XF86AudioRaiseVolume";
        case Qt.Key_VolumeDown: return "XF86AudioLowerVolume";
        case Qt.Key_VolumeMute: return "XF86AudioMute";
        case Qt.Key_MicMute: return "XF86AudioMicMute";
        case Qt.Key_MonBrightnessUp: return "XF86MonBrightnessUp";
        case Qt.Key_MonBrightnessDown: return "XF86MonBrightnessDown";
        case Qt.Key_MediaPlay:
        case Qt.Key_MediaTogglePlayPause: return "XF86AudioPlay";
        case Qt.Key_MediaPause: return "XF86AudioPause";
        case Qt.Key_MediaNext: return "XF86AudioNext";
        case Qt.Key_MediaPrevious: return "XF86AudioPrev";
        case Qt.Key_MediaStop: return "XF86AudioStop";
        case Qt.Key_Calculator: return "XF86Calculator";
        }
        return "";
    }

    function startCapture() {
        page.captureModifiers = [];
        page.captureCombo = "";
        page.captureKey = "";
        page.captureKeyScan = -1;
        page.captureKeyDown = false;
        page.captureOpen = true;
        page.statusText = "Запись сочетания: нажмите клавиши или Esc для отмены (8 секунд).";
        page.statusIsError = false;
        page.statusIsWarning = false;
        if (page.win) page.win.settingsKeysCapture = true;
        captureTimeout.restart();
        captureFocusTimer.restart();
    }

    function stopCapture(restoreFocus) {
        captureTimeout.stop();
        captureFocusTimer.stop();
        page.captureOpen = false;
        page.captureModifiers = [];
        page.captureKeyDown = false;
        if (page.win) page.win.settingsKeysCapture = false;
        if (restoreFocus && page.visible) comboField.forceActiveFocus();
    }

    function finishCapture(combo) {
        if (!combo) return;
        page.comboText = combo;
        page.statusText = "Сочетание захвачено: " + combo;
        page.statusIsError = false;
        page.statusIsWarning = false;
        page.stopCapture(true);
    }

    function capturePressed(event) {
        event.accepted = true;
        if (!page.captureOpen || event.isAutoRepeat) return;
        if (event.key === Qt.Key_Escape) {
            page.statusText = "Запись сочетания отменена.";
            page.statusIsError = false;
            page.statusIsWarning = false;
            page.stopCapture(true);
            return;
        }
        const modifier = page.modifierForKey(event.key);
        if (modifier !== "") {
            if (page.captureModifiers.indexOf(modifier) < 0)
                page.captureModifiers = page.captureModifiers.concat([modifier]);
            page.captureCombo = page.orderedModifiers(page.captureModifiers).join("+");
            return;
        }
        const key = page.keyName(event);
        if (key === "") {
            page.statusText = "Эту клавишу не удалось распознать — введите сочетание вручную.";
            page.statusIsError = false;
            page.statusIsWarning = false;
            return;
        }
        page.captureKey = key;
        page.captureKeyScan = Number(event.nativeScanCode);
        page.captureKeyDown = true;
        page.captureCombo = page.modifiersForEvent(event).concat([key]).join("+");
    }

    function captureReleased(event) {
        event.accepted = true;
        if (!page.captureOpen || event.isAutoRepeat) return;
        const modifier = page.modifierForKey(event.key);
        if (modifier !== "") {
            page.captureModifiers = page.captureModifiers.filter((name) => name !== modifier);
        } else if (page.captureKeyDown
                   && ((page.captureKeyScan >= 0 && Number(event.nativeScanCode) === page.captureKeyScan)
                       || page.keyName(event) === page.captureKey)) {
            page.captureKeyDown = false;
        }
        if (!page.captureKeyDown && page.captureModifiers.length === 0 && page.captureCombo !== "")
            page.finishCapture(page.captureCombo);
    }

    onVisibleChanged: {
        if (visible) page.enterPage();
        else page.stopCapture(false);
    }
    Component.onCompleted: if (page.visible) page.enterPage()
    Component.onDestruction: page.stopCapture(false)

    Connections {
        target: page.win
        function onVisibleChanged() {
            if (page.win && !page.win.visible) page.stopCapture(false);
        }
    }

    ColumnLayout {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.dp(12)

        SCard {
            Layout.fillWidth: true
            title: page.editingKeys === "" ? "Добавить сочетание" : "Изменить сочетание"

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.dp(8)

                TextField {
                    id: comboField
                    Layout.fillWidth: true
                    variant: "outlined"
                    label: "Сочетание клавиш"
                    placeholder: "Например, Mod+Return"
                    text: page.comboText
                    onTextEdited: page.comboText = comboField.text
                    onAccepted: page.saveBinding()
                }

                Button {
                    text: page.captureOpen ? "Отменить захват" : "Захватить"
                    icon: "keyboard"
                    variant: "tonal"
                    disabled: taskProc.running
                    onClicked: page.captureOpen ? page.stopCapture(true) : page.startCapture()
                }
            }

            LText {
                Layout.fillWidth: true
                role: "bodySmall"
                color: Theme.subtext
                wrapMode: Text.WordWrap
                text: page.captureOpen
                    ? "Нажмите сочетание; Esc отменяет запись. Таймаут — 8 секунд. XF86- и mouse-клавиши можно ввести вручную."
                    : "Можно захватить сочетание или ввести его вручную — это нужно для XF86- и mouse-клавиш."
            }

            SPick {
                label: "Популярное действие"
                options: page.actionOptions
                value: page.selectedPreset
                searchable: true
                placeholder: "Поиск действия"
                onPicked: (value) => {
                    page.selectedPreset = String(value);
                    if (String(value) !== "") page.actionText = String(value);
                }
            }

            TextField {
                id: actionField
                Layout.fillWidth: true
                variant: "outlined"
                label: "Действие Umbriel"
                placeholder: "spawn:команда, window-close, workspace-switch:1…"
                text: page.actionText
                onTextEdited: {
                    page.actionText = actionField.text;
                    page.selectedPreset = page.presetFor(page.actionText);
                }
                onAccepted: page.saveBinding()
            }

            LText {
                Layout.fillWidth: true
                visible: page.isCritical(page.actionText)
                role: "bodySmall"
                color: Theme.error
                wrapMode: Text.WordWrap
                text: page.actionText.indexOf("skip-confirmation") >= 0
                    ? "Критичное действие: сочетание немедленно завершит сессию без подтверждения."
                    : "Критичное действие: завершение сессии. Проверьте сочетание перед сохранением."
            }

            SToggle {
                label: "Повторять при удержании"
                sub: "Отключите для одноразового действия. По умолчанию Umbriel повторяет сочетания."
                checked: page.repeatEnabled
                onToggled: (value) => page.repeatEnabled = value
            }

            LText {
                Layout.fillWidth: true
                visible: page.comboConflict !== ""
                role: "bodySmall"
                color: Theme.error
                wrapMode: Text.WordWrap
                text: page.comboConflict + " Конфликтующие бинды могут срабатывать одновременно."
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.dp(8)

                Button {
                    text: "Сохранить"
                    icon: "check"
                    disabled: taskProc.running || page.comboText.trim() === "" || page.actionText.trim() === ""
                    onClicked: page.saveBinding()
                }
                Button {
                    visible: page.editingKeys !== ""
                    text: "Новое сочетание"
                    variant: "text"
                    disabled: taskProc.running
                    onClicked: page.newBinding()
                }
                Item { Layout.fillWidth: true }
                LText {
                    visible: page.statusText !== ""
                    Layout.fillWidth: true
                    role: "bodySmall"
                    color: page.statusIsError ? Theme.error
                        : (page.statusIsWarning ? Theme.warning : Theme.primary)
                    wrapMode: Text.WordWrap
                    text: page.statusText
                }
            }
        }

        SCard {
            Layout.fillWidth: true
            title: "Текущие сочетания"
            actionIcon: "refresh"
            onActionClicked: page.refreshBinds()

            RowLayout {
                Layout.fillWidth: true
                TextField {
                    Layout.fillWidth: true
                    variant: "search"
                    icon: "search"
                    placeholder: "Поиск по сочетанию, действию или заметке"
                    text: page.query
                    onTextEdited: page.query = text
                }
                LText {
                    role: "labelMedium"
                    color: Theme.subtext
                    visible: page.query.trim() !== ""
                    text: String(page.filteredBinds.length)
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.dp(8)
                Button {
                    text: "Сохранить копию"
                    icon: "save"
                    variant: "tonal"
                    disabled: taskProc.running
                    onClicked: page.saveBackup()
                }
                Button {
                    text: "Вернуть как было"
                    icon: "undo"
                    variant: "outlined"
                    danger: true
                    disabled: taskProc.running || !page.hasBackup
                    onClicked: page.restoreBackup()
                }
                LText {
                    Layout.fillWidth: true
                    role: "bodySmall"
                    color: Theme.subtext
                    text: page.hasBackup ? "Копия: keybinds.toml.bak" : "Резервная копия недоступна"
                    elide: Text.ElideRight
                }
            }

            LText {
                visible: page.binds.length === 0 && !taskProc.running
                Layout.fillWidth: true
                role: "bodySmall"
                color: Theme.subtext
                text: "Сочетания не найдены или пока не загружены."
            }
            LText {
                visible: page.binds.length > 0 && page.filteredBinds.length === 0
                Layout.fillWidth: true
                role: "bodySmall"
                color: Theme.subtext
                text: "По запросу ничего не найдено."
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.dp(6)

                Repeater {
                    model: page.filteredBinds

                    Item {
                        id: bindRow
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: Math.max(Theme.dp(58), rowContent.implicitHeight + Theme.dp(16))

                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.rad(12)
                            color: Theme.a(Theme.text, 0.035)
                        }

                        RowLayout {
                            id: rowContent
                            anchors.fill: parent
                            anchors.leftMargin: Theme.dp(10)
                            anchors.rightMargin: Theme.dp(8)
                            spacing: Theme.dp(8)

                            LText {
                                Layout.preferredWidth: Math.min(Theme.dp(150), bindRow.width * 0.28)
                                role: "labelLarge"
                                mono: true
                                color: Theme.text
                                text: bindRow.modelData.keys
                                wrapMode: Text.WrapAnywhere
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Theme.dp(2)
                                LText {
                                    Layout.fillWidth: true
                                    role: "bodyMedium"
                                    color: page.isCritical(bindRow.modelData.action) ? Theme.error : Theme.text
                                    text: bindRow.modelData.action
                                    wrapMode: Text.WrapAnywhere
                                }
                                LText {
                                    Layout.fillWidth: true
                                    visible: String(bindRow.modelData.note || "") !== "" || page.specialText(bindRow.modelData) !== ""
                                    role: "bodySmall"
                                    color: Theme.subtext
                                    text: [String(bindRow.modelData.note || ""), page.specialText(bindRow.modelData)]
                                        .filter((value) => value !== "").join(" · ")
                                    wrapMode: Text.WordWrap
                                }
                            }

                            ColumnLayout {
                                Layout.alignment: Qt.AlignVCenter
                                spacing: Theme.dp(3)
                                LText {
                                    Layout.alignment: Qt.AlignRight
                                    role: "labelSmall"
                                    color: bindRow.modelData.repeat ? Theme.subtext : Theme.primary
                                    text: bindRow.modelData.repeat ? "Повтор" : "Без повтора"
                                }
                                RowLayout {
                                    spacing: Theme.dp(2)
                                    Button {
                                        size: "xs"
                                        variant: "text"
                                        text: "Изменить"
                                        disabled: taskProc.running
                                        onClicked: page.editBinding(bindRow.modelData)
                                    }
                                    Button {
                                        size: "xs"
                                        variant: "text"
                                        danger: true
                                        text: "Удалить"
                                        disabled: taskProc.running
                                        onClicked: page.removeBinding(bindRow.modelData)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        SCard {
            Layout.fillWidth: true
            title: "Важно"
            LText {
                Layout.fillWidth: true
                role: "bodySmall"
                color: Theme.subtext
                wrapMode: Text.WordWrap
                text: "Редактирование может отключить сочетания или привести к конфликтам. После записи Umbriel проверяет конфигурацию; при ошибке скрипт восстанавливает keybinds.toml.bak. Новые бинды применяются после перезагрузки конфигурации."
            }
            LText {
                Layout.fillWidth: true
                role: "bodySmall"
                color: Theme.error
                wrapMode: Text.WordWrap
                text: "session-quit — критичное действие; вариант skip-confirmation завершает сессию немедленно."
            }
        }
    }

    Item {
        id: captureSink
        anchors.fill: parent
        visible: page.visible
        enabled: page.captureOpen
        focus: page.captureOpen
        z: 10
        Keys.onPressed: (event) => page.capturePressed(event)
        Keys.onReleased: (event) => page.captureReleased(event)
    }

    Timer {
        id: taskRestartTimer
        interval: 0
        onTriggered: page.startQueuedTask()
    }

    Timer {
        id: captureTimeout
        interval: 8000
        onTriggered: {
            page.stopCapture(true);
            page.statusText = "Время записи истекло. Введите сочетание вручную или начните захват ещё раз.";
            page.statusIsError = false;
            page.statusIsWarning = false;
        }
    }

    Timer {
        id: captureFocusTimer
        interval: 50
        onTriggered: if (page.captureOpen) captureSink.forceActiveFocus()
    }

    Process {
        id: taskProc
        property var args: []
        property string kind: ""
        property string stdoutText: ""
        property string stderrText: ""
        running: false
        command: ["python3", page.scriptPath].concat(taskProc.args)
        stdout: SplitParser {
            onRead: (line) => taskProc.stdoutText += (taskProc.stdoutText === "" ? "" : "\n") + line
        }
        stderr: SplitParser {
            onRead: (line) => taskProc.stderrText += line + "\n"
        }
        onExited: (exitCode) => {
            page.finishTask(exitCode);
            if (page.queuedTaskKind !== "") taskRestartTimer.start();
        }
        onRunningChanged: if (!running && page.queuedTaskKind !== "") taskRestartTimer.start()
    }
}
