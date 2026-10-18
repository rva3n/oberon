pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../core"
import "../../ui"
import ".."

// Панель управления записью экрана через scripts/record.sh.
ColumnLayout {
    id: page

    property var win: null
    property bool recordActive: false
    property bool recordPaused: false
    property string currentFile: ""
    property int startedAt: 0
    property int pausedSeconds: 0
    property int elapsedSeconds: 0
    property string recordError: ""
    property string micError: ""
    property var micSources: []
    property string actionName: ""
    property var actionArgs: []
    property string actionOutput: ""
    property string actionError: ""
    property string statusOutput: ""
    property string statusError: ""
    property string micOutput: ""

    readonly property string scriptPath: Quickshell.env("HOME") + "/oberon/scripts/record.sh"
    readonly property bool controlsLocked: page.recordActive || actionProc.running
    readonly property var fpsOptions: [30, 60, 120]

    visible: win !== null && win.mode === "panel" && win.page === "record"
    Layout.fillWidth: true
    spacing: Theme.pageSpacing

    function commitDirectory() {
        const dir = dirField.text.trim();
        if (dir === "") {
            page.recordError = "Укажите папку для сохранения записи.";
            dirField.text = Prefs.recordDir;
            return false;
        }
        Prefs.set("recordDir", dir);
        return true;
    }

    function refreshMicSources() {
        if (micProc.running) return;
        page.micError = "";
        page.micOutput = "";
        page.micSources = [];
        micProc.running = true;
    }

    function refreshStatus() {
        if (statusProc.running || actionProc.running) return;
        page.statusOutput = "";
        page.statusError = "";
        statusProc.running = true;
    }

    function runAction(name, args) {
        if (actionProc.running) return;
        page.actionName = name;
        page.actionArgs = args || [];
        page.actionOutput = "";
        page.actionError = "";
        actionProc.running = true;
    }

    function startRecording() {
        if (page.controlsLocked || !page.commitDirectory()) return;
        page.recordError = "";
        page.currentFile = "";
        page.runAction("start", [String(Prefs.recordFps), Prefs.recordDir,
            Prefs.recordAudio ? "1" : "0", Prefs.recordMic ? "1" : "0",
            Prefs.recordMicSource]);
    }

    function pauseRecording() {
        if (!page.controlsLocked)
            page.runAction(page.recordPaused ? "resume" : "pause", []);
    }

    function stopRecording() {
        if (page.recordActive && !actionProc.running)
            page.runAction("stop", []);
    }

    function formatElapsed(seconds) {
        const value = Math.max(0, Math.floor(seconds));
        const hours = Math.floor(value / 3600);
        const minutes = Math.floor(value / 60) % 60;
        const secs = value % 60;
        const mm = (minutes < 10 ? "0" : "") + minutes;
        const ss = (secs < 10 ? "0" : "") + secs;
        return hours > 0 ? hours + ":" + mm + ":" + ss : mm + ":" + ss;
    }

    function updateElapsed() {
        if (!page.recordActive || page.startedAt <= 0) {
            page.elapsedSeconds = 0;
            return;
        }
        page.elapsedSeconds = Math.max(0, Math.floor(Date.now() / 1000) - page.startedAt - page.pausedSeconds);
    }

    function applyStatus(value) {
        const status = String(value || "").trim();
        if (status === "" || status === "idle") {
            page.recordActive = false;
            page.recordPaused = false;
            page.startedAt = 0;
            page.pausedSeconds = 0;
            page.elapsedSeconds = 0;
            return;
        }

        const fields = status.split("|");
        if ((fields[0] !== "rec" && fields[0] !== "paused") || fields.length < 5) {
            page.recordError = "Не удалось прочитать статус записи.";
            return;
        }
        page.recordActive = true;
        page.recordPaused = fields[0] === "paused";
        page.startedAt = Number(fields[2]) || 0;
        page.pausedSeconds = Number(fields[3]) || 0;
        page.currentFile = fields.slice(4).join("|");
        page.updateElapsed();
    }

    function finishAction(exitCode) {
        const output = page.actionOutput.trim();
        const error = page.actionError.trim();
        if (exitCode === 0) {
            page.recordError = "";
            if (page.actionName === "start" || page.actionName === "stop") {
                const lines = output.split("\n").filter(line => line.trim() !== "");
                if (lines.length > 0) page.currentFile = lines[lines.length - 1].trim();
            }
        } else {
            page.recordError = error || output || "Не удалось выполнить действие записи.";
        }
        Qt.callLater(() => page.refreshStatus());
    }

    function finishMicRefresh(exitCode) {
        if (exitCode !== 0) {
            page.micError = "Не удалось получить источники микрофона через pactl.";
            return;
        }
        try {
            const sources = JSON.parse(page.micOutput || "[]");
            if (!Array.isArray(sources)) throw new Error("invalid pactl response");
            const filtered = [];
            for (const source of sources) {
                const name = String(source.name || "");
                if (name === "" || name.endsWith(".monitor") || source.monitor_of_sink !== null
                        && source.monitor_of_sink !== undefined || source.monitor_source_name
                        || name.indexOf("oberon_record_mix") >= 0)
                    continue;
                filtered.push({ name: name, description: String(source.description || name) });
            }
            page.micSources = filtered;
        } catch (e) {
            page.micError = "Не удалось разобрать список источников pactl.";
        }
    }

    function finishStatus(exitCode) {
        if (exitCode !== 0) {
            page.recordError = page.statusError.trim() || "Не удалось получить статус записи.";
            return;
        }
        page.applyStatus(page.statusOutput);
    }

    onVisibleChanged: if (visible) {
        page.refreshStatus();
        if (Prefs.recordMic) page.refreshMicSources();
    }

    Component.onCompleted: {
        page.refreshStatus();
        if (Prefs.recordMic) page.refreshMicSources();
    }

    Process {
        id: actionProc
        command: ["bash", page.scriptPath, page.actionName].concat(page.actionArgs)
        stdout: SplitParser { onRead: line => page.actionOutput += line + "\n" }
        stderr: SplitParser { onRead: line => page.actionError += line + "\n" }
        onExited: (exitCode) => page.finishAction(exitCode)
    }

    Process {
        id: statusProc
        command: ["bash", page.scriptPath, "status"]
        stdout: SplitParser { onRead: line => page.statusOutput += line + "\n" }
        stderr: SplitParser { onRead: line => page.statusError += line + "\n" }
        onExited: (exitCode) => page.finishStatus(exitCode)
    }

    Process {
        id: micProc
        command: ["pactl", "-f", "json", "list", "sources"]
        stdout: SplitParser { onRead: line => page.micOutput += line + "\n" }
        onExited: (exitCode) => page.finishMicRefresh(exitCode)
    }

    Timer {
        interval: 1000
        repeat: true
        running: page.visible || page.recordActive || actionProc.running
        onTriggered: {
            page.updateElapsed();
            page.refreshStatus();
        }
    }

    Connections {
        target: Prefs
        function onRecordDirChanged() {
            if (!dirField.activeFocus) dirField.text = Prefs.recordDir;
        }
    }

    Card {
        Layout.fillWidth: true
        title: "Параметры записи"

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            LText {
                Layout.preferredWidth: Theme.dp(52)
                role: "labelLarge"
                color: Theme.subtext
                text: "FPS"
            }

            Repeater {
                model: page.fpsOptions
                delegate: Chip {
                    required property var modelData
                    label: String(modelData)
                    selected: Prefs.recordFps === Number(modelData)
                    disabled: page.controlsLocked
                    onClicked: Prefs.set("recordFps", Number(modelData))
                }
            }

            Item { Layout.fillWidth: true }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            TextField {
                id: dirField
                Layout.fillWidth: true
                enabled: !page.controlsLocked
                variant: "filled"
                label: "Папка сохранения"
                supporting: "Можно ввести путь вручную, например ~/Videos"
                text: Prefs.recordDir
                onAccepted: page.commitDirectory()
                onActiveFocusChanged: if (!activeFocus) page.commitDirectory()
            }

            Button {
                text: "Применить"
                variant: "tonal"
                disabled: page.controlsLocked
                onClicked: page.commitDirectory()
            }
        }

        ToggleRow {
            label: "Системный звук"
            sub: "Записывать звук текущего устройства вывода."
            checked: Prefs.recordAudio
            enabled: !page.controlsLocked
            onToggled: (value) => Prefs.set("recordAudio", value)
        }

        ToggleRow {
            label: "Микрофон"
            sub: "Можно выбрать конкретный источник ввода."
            checked: Prefs.recordMic
            enabled: !page.controlsLocked
            onToggled: (value) => {
                Prefs.set("recordMic", value);
                if (value) page.refreshMicSources();
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.dp(8)
            spacing: Theme.dp(2)
            visible: Prefs.recordMic

            ListItem {
                Layout.fillWidth: true
                headline: "По умолчанию"
                supporting: "Системный источник ввода"
                selected: Prefs.recordMicSource === ""
                disabled: page.controlsLocked
                icon: "mic"
                iconColor: Theme.primary
                onClicked: if (!page.controlsLocked) Prefs.set("recordMicSource", "")
                trailing: Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: Prefs.recordMicSource === ""
                    name: "check"
                    size: Theme.dp(18)
                    color: Theme.primary
                }
            }

            Repeater {
                model: page.micSources
                delegate: ListItem {
                    required property var modelData
                    Layout.fillWidth: true
                    headline: modelData.description
                    supporting: modelData.name
                    selected: Prefs.recordMicSource === modelData.name
                    disabled: page.controlsLocked
                    icon: "mic"
                    iconColor: Theme.primary
                    onClicked: if (!page.controlsLocked) Prefs.set("recordMicSource", modelData.name)
                    trailing: Icon {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: Prefs.recordMicSource === modelData.name
                        name: "check"
                        size: Theme.dp(18)
                        color: Theme.primary
                    }
                }
            }

            LText {
                Layout.fillWidth: true
                visible: Prefs.recordMic && page.micSources.length === 0 && !micProc.running && page.micError === ""
                role: "bodySmall"
                color: Theme.subtextDim
                text: "Источники микрофона не найдены."
            }
            LText {
                Layout.fillWidth: true
                visible: page.micError !== ""
                role: "bodySmall"
                color: Theme.error
                text: page.micError
                wrapMode: Text.WordWrap
            }
        }
    }

    Card {
        Layout.fillWidth: true
        title: page.recordActive ? (page.recordPaused ? "Запись приостановлена" : "Идёт запись") : "Запись экрана"

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(10)

            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: Theme.dp(12)
                Layout.preferredHeight: Theme.dp(12)
                radius: Theme.radiusPill
                color: !page.recordActive ? Theme.outline
                    : (page.recordPaused ? Theme.warning : Theme.error)
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.dp(2)

                LText {
                    Layout.fillWidth: true
                    role: "bodyMedium"
                    color: Theme.text
                    text: page.currentFile !== "" ? page.currentFile : "Файл будет сохранён в " + Prefs.recordDir
                    elide: Text.ElideMiddle
                }
                LText {
                    Layout.fillWidth: true
                    visible: page.recordActive
                    role: "bodySmall"
                    color: page.recordPaused ? Theme.warning : Theme.error
                    text: page.formatElapsed(page.elapsedSeconds)
                }
            }
        }

        LText {
            Layout.fillWidth: true
            visible: page.recordError !== ""
            role: "bodySmall"
            color: Theme.error
            text: page.recordError
            wrapMode: Text.WordWrap
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            Button {
                Layout.fillWidth: true
                visible: !page.recordActive
                text: "Начать запись"
                icon: "fiber_manual_record"
                variant: "filled"
                danger: true
                disabled: actionProc.running
                onClicked: page.startRecording()
            }

            Button {
                Layout.fillWidth: true
                visible: page.recordActive
                text: page.recordPaused ? "Продолжить" : "Пауза"
                icon: page.recordPaused ? "play_arrow" : "pause"
                variant: "tonal"
                disabled: actionProc.running
                onClicked: page.pauseRecording()
            }

            Button {
                Layout.fillWidth: true
                visible: page.recordActive
                text: "Стоп"
                icon: "stop"
                variant: "filled"
                danger: true
                disabled: actionProc.running
                onClicked: page.stopRecording()
            }
        }
    }
}
