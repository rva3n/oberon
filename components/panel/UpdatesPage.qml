import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../core"
import "../../ui"

// Страница обновлений Oberon: проверка репозитория и обновление компонентов.
ColumnLayout {
    id: page

    property var win: null
    property var components: []
    property var applyLog: []
    property var lastCheckedAt: null
    property bool checking: false
    property bool applying: false
    property bool initialCheckStarted: false
    property string resultState: "idle"
    property string checkError: ""
    property string applyError: ""

    readonly property string updateScript: Quickshell.env("HOME") + "/oberon/scripts/update.sh"
    readonly property string restartScript: Quickshell.env("HOME") + "/oberon/scripts/restart.sh"
    readonly property bool hasUpdates: page.components.some((component) => component.behind > 0)
    readonly property var componentNames: ({
        "quickshell": "oberonqs",
        "matugen": "oberoncolor",
        "awww": "oberonwall",
        "cava": "oberoncava",
        "hypridle": "oberonidle",
        "umbriel": "Umbriel"
    })
    readonly property string statusText: {
        if (page.resultState === "checking") return "Проверяю обновления…";
        if (page.resultState === "available") return "Есть обновления";
        if (page.resultState === "current") return "Всё актуально";
        if (page.resultState === "applying") return "Обновление…";
        if (page.resultState === "updated") return "Обновлено";
        if (page.resultState === "error") return "Ошибка";
        if (page.resultState === "checkError") return "Ошибка проверки";
        return "Проверка ещё не выполнялась";
    }
    readonly property color statusColor: {
        if (page.resultState === "error" || page.resultState === "checkError") return Theme.error;
        if (page.resultState === "available" || page.resultState === "applying") return Theme.primary;
        if (page.resultState === "updated") return Theme.primary;
        return Theme.text;
    }

    visible: win !== null && win.mode === "panel" && win.page === "updates"
    Layout.fillWidth: true
    spacing: Theme.pageSpacing

    onVisibleChanged: if (visible) page.checkOnFirstShow()

    Component.onCompleted: if (page.visible) page.checkOnFirstShow()

    function checkOnFirstShow() {
        if (page.initialCheckStarted) return;
        page.initialCheckStarted = true;
        page.checkUpdates();
    }

    function checkUpdates() {
        if (page.checking || page.applying) return;

        page.components = [];
        page.checkError = "";
        page.applyError = "";
        page.checking = true;
        page.resultState = "checking";
        checkProcess.running = false;
        checkProcess.running = true;
    }

    function parseCheckLine(line) {
        const fields = String(line).trim().split(/\s+/);
        if (fields.length < 3) return;

        if (fields[0] === "MAIN") {
            const behind = Number(fields[1]);
            if (isNaN(behind)) return;
            page.setComponent("main", "Oberon", behind, fields[2]);
            return;
        }

        if (fields[0] === "SUB" && fields.length >= 4) {
            const behind = Number(fields[2]);
            if (isNaN(behind)) return;
            const name = page.componentNames[fields[1]] || fields[1];
            page.setComponent(fields[1], name, behind, fields[3]);
        }
    }

    function setComponent(key, label, behind, hash) {
        const next = page.components.filter((component) => component.key !== key);
        next.push({
            "key": key,
            "label": label,
            "behind": Math.max(0, Math.floor(behind)),
            "hash": String(hash)
        });
        page.components = next;
    }

    function finishCheck(exitCode) {
        page.checking = false;
        page.lastCheckedAt = new Date();

        if (exitCode !== 0) {
            page.checkError = "Скрипт проверки завершился с кодом " + exitCode + ".";
            page.resultState = "checkError";
            return;
        }
        if (page.components.length === 0) {
            page.checkError = "Скрипт не вернул список компонентов.";
            page.resultState = "checkError";
            return;
        }

        page.resultState = page.hasUpdates ? "available" : "current";
    }

    function applyUpdates() {
        if (page.applying || page.checking || !page.hasUpdates || page.resultState === "updated") return;

        page.applyLog = [];
        page.applyError = "";
        page.applying = true;
        page.resultState = "applying";
        applyProcess.running = false;
        applyProcess.running = true;
    }

    function appendApplyLine(line) {
        const text = String(line).replace(/\r/g, "");
        if (text.trim() === "") return;

        const next = page.applyLog.slice();
        next.push(text);
        page.applyLog = next.slice(-12);
        page.scrollLogToEnd();
    }

    function finishApply(exitCode) {
        page.applying = false;
        if (exitCode === 0) {
            page.resultState = "updated";
            return;
        }

        page.applyError = "Обновление завершилось с кодом " + exitCode + ".";
        page.resultState = "error";
    }

    function shortHash(hash) {
        const value = String(hash);
        return value.length > 8 ? value.slice(0, 8) : value;
    }

    function formatCheckedAt(value) {
        const date = new Date(value);
        const pad = (number) => number < 10 ? "0" + number : String(number);
        return pad(date.getDate()) + "." + pad(date.getMonth() + 1) + "." + date.getFullYear()
                + " " + pad(date.getHours()) + ":" + pad(date.getMinutes());
    }

    function scrollLogToEnd() {
        Qt.callLater(() => {
            logFlick.contentY = Math.max(0, logFlick.contentHeight - logFlick.height);
        });
    }

    LText {
        role: "titleMedium"
        color: Theme.text
        text: "Обновления"
    }

    LText {
        Layout.fillWidth: true
        role: "bodySmall"
        color: Theme.subtext
        wrapMode: Text.WordWrap
        text: "Проверка состояния и обновление компонентов Oberon"
    }

    Card {
        Layout.fillWidth: true
        title: "Состояние"

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            LText {
                Layout.fillWidth: true
                role: "titleMedium"
                color: page.statusColor
                wrapMode: Text.WordWrap
                text: page.statusText
            }

            LoadingIndicator {
                visible: page.checking
                running: page.checking
                Layout.preferredWidth: Theme.dp(30)
                Layout.preferredHeight: Theme.dp(30)
            }

            Button {
                text: "Проверить"
                icon: "refresh"
                variant: "tonal"
                disabled: page.checking || page.applying
                onClicked: page.checkUpdates()
            }
        }

        LText {
            Layout.fillWidth: true
            role: "bodySmall"
            color: Theme.subtext
            text: page.lastCheckedAt === null
                  ? "Проверка ещё не выполнялась"
                  : "Последняя проверка: " + page.formatCheckedAt(page.lastCheckedAt)
        }

        LText {
            visible: page.resultState === "checkError"
            Layout.fillWidth: true
            role: "bodySmall"
            color: Theme.error
            wrapMode: Text.WordWrap
            text: page.checkError
        }
    }

    Card {
        visible: page.components.length > 0
        Layout.fillWidth: true
        title: "Компоненты"

        Repeater {
            model: page.components

            delegate: RowLayout {
                id: componentRow

                required property var modelData

                Layout.fillWidth: true
                spacing: Theme.dp(10)

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(1)

                    LText {
                        Layout.fillWidth: true
                        role: "bodyMedium"
                        color: Theme.text
                        text: componentRow.modelData.label
                    }

                    LText {
                        role: "labelSmall"
                        color: Theme.subtextDim
                        text: "hash " + page.shortHash(componentRow.modelData.hash)
                    }
                }

                Rectangle {
                    readonly property bool behind: componentRow.modelData.behind > 0

                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: badgeText.implicitWidth + Theme.dp(20)
                    implicitHeight: Theme.dp(28)
                    radius: Theme.pill(height)
                    color: behind ? Theme.primaryContainer : Theme.secondaryContainer

                    LText {
                        id: badgeText

                        anchors.centerIn: parent
                        role: "labelSmall"
                        color: parent.behind ? Theme.fgPrimaryContainer : Theme.fgSecondaryContainer
                        text: parent.behind
                              ? String(componentRow.modelData.behind) + " новых"
                              : "актуально"
                    }
                }
            }
        }
    }

    Card {
        Layout.fillWidth: true
        title: "Обновление"

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            Button {
                text: "Обновить"
                variant: "filled"
                disabled: !page.hasUpdates || page.checking || page.applying || page.resultState === "updated"
                onClicked: page.applyUpdates()
            }

            Button {
                visible: page.resultState === "updated"
                text: "Перезапустить шелл"
                variant: "tonal"
                onClicked: Quickshell.execDetached(["setsid", "sh", page.restartScript])
            }
        }

        LText {
            Layout.fillWidth: true
            role: "bodySmall"
            color: Theme.subtextDim
            wrapMode: Text.WordWrap
            text: "Если обновился сам шелл — нажми «Перезапустить», чтобы применить."
        }

        LinearProgress {
            visible: page.applying
            Layout.fillWidth: true
            indeterminate: true
        }

        LText {
            visible: page.resultState === "error"
            Layout.fillWidth: true
            role: "bodySmall"
            color: Theme.error
            wrapMode: Text.WordWrap
            text: page.applyError
        }
    }

    Card {
        visible: page.applying || page.applyLog.length > 0 || page.resultState === "error" || page.resultState === "updated"
        Layout.fillWidth: true
        title: "Журнал обновления"

        Flickable {
            id: logFlick

            Layout.fillWidth: true
            Layout.minimumHeight: Theme.dp(96)
            Layout.maximumHeight: Theme.dp(220)
            Layout.preferredHeight: Math.max(Theme.dp(96), Math.min(Theme.dp(220), logText.implicitHeight))
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            contentWidth: width
            contentHeight: logText.height
            interactive: contentHeight > height
            onContentHeightChanged: page.scrollLogToEnd()
            onHeightChanged: page.scrollLogToEnd()

            LText {
                id: logText

                width: logFlick.width
                height: implicitHeight
                role: "bodySmall"
                mono: true
                text: page.applyLog.length > 0
                      ? page.applyLog.join("\n")
                      : page.applying ? "Ожидание вывода…" : "Нет строк вывода."
                textFormat: Text.PlainText
                wrapMode: Text.WrapAnywhere
                color: page.applyLog.length > 0 ? Theme.text : Theme.subtext
                verticalAlignment: Text.AlignTop
            }
        }
    }

    Process {
        id: checkProcess

        command: ["sh", page.updateScript, "--check"]
        stdout: SplitParser {
            onRead: (line) => page.parseCheckLine(line)
        }
        onExited: (exitCode) => page.finishCheck(exitCode)
    }

    Process {
        id: applyProcess

        command: ["sh", "-c", "sh \"$1\" --apply 2>&1", "oberon-update", page.updateScript]
        stdout: SplitParser {
            onRead: (line) => page.appendApplyLine(line)
        }
        onExited: (exitCode) => page.finishApply(exitCode)
    }
}
