import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../core"
import "../ui"

// Компактный скриншот-тулбар (порт идеи lucidshot/SnapOverlay, но карточкой
// по центру сверху по образцу Switcher): Область / Экран / Текст (OCR) /
// Видео / Цвет / Перевод. Область и Экран — grim+slurp в ~/Pictures/Screenshots с
// wl-copy и уведомлением (логика перенесена из shell.qml), OCR и цвет —
// scripts/shot-ocr.sh и scripts/shot-color.sh, видео — toggle wf-recorder
// через scripts/shot-video.sh (pid-файл в /tmp), перевод — scripts/shot-translate.sh
// с показом карточки результата (translateResult).
PanelWindow {
    id: toolbar

    signal closed()

    property var shell: typeof root !== "undefined" ? root : null

    property bool shown: false

    property real reveal: toolbar.shown ? 1 : 0
    property int _focus: 0
    property string mode: "region"

    // Состояние карточки перевода (Translation Result Card Mode)
    property bool translateResult: false
    property bool translating: false
    property bool capturingTranslate: false
    property bool translateOk: false
    property string source_lang: "auto"
    property string target_lang: "ru"
    property string original: ""
    property string translated: ""
    property string translateError: ""
    property string _pendingTargetLang: ""
    property string _translateStdout: ""

    readonly property var targetLangs: ["RU", "EN", "DE", "JA"]

    readonly property var modes: [{
        "id": "region",
        "label": "Область",
        "icon": "screenshot_region"
    }, {
        "id": "full",
        "label": "Экран",
        "icon": "fullscreen"
    }, {
        "id": "ocr",
        "label": "Текст",
        "icon": "text_fields"
    }, {
        "id": "video",
        "label": "Видео",
        "icon": "videocam"
    }, {
        "id": "color",
        "label": "Цвет",
        "icon": "colorize"
    }, {
        "id": "translate",
        "icon": "translate",
        "label": "Перевод"
    }]

    // зависим только от системного каталога: файлы лежат рядом с корнем шелла
    readonly property string scriptsDir: Qt.resolvedUrl("../scripts/").toString().replace("file://", "")
    readonly property string translateScriptPath: Quickshell.env("HOME") + "/oberon/scripts/shot-translate.sh"
    readonly property string recPidFile: "/tmp/oberon-recorder.pid"
    property bool recording: false

    function open(mode) {
        toolbar.mode = mode || "region";
        toolbar.translateResult = false;
        toolbar.translating = false;
        toolbar.capturingTranslate = false;
        toolbar.translateError = "";
        const i = toolbar.modes.findIndex((m) => m.id === toolbar.mode);
        toolbar._focus = i >= 0 ? i : 0;
        toolbar.shown = true;
        recProc.running = false;
        recProc.running = true;
    }

    function close() {
        toolbar.shown = false;
        toolbar.recording = false;
        toolbar.translateResult = false;
        toolbar.translating = false;
        toolbar.capturingTranslate = false;
    }

    function activate(index) {
        const m = toolbar.modes[index];
        if (!m) return;
        if (m.id === "video") {
            // toggle: окно остаётся (даже можно закрыть — запись продолжится)
            runScript("shot-video.sh");
            statePoll.restart();
            return;
        }
        if (m.id === "translate") {
            toolbar.startTranslate("");
            return;
        }
        toolbar.close();
        // слой должен исчезнуть до slurp/grim: пауза в командах
        Qt.callLater(() => {
            if (m.id === "region") shoot(false);
            else if (m.id === "full") shoot(true);
            else if (m.id === "ocr") runScript("shot-ocr.sh");
            else if (m.id === "color") runScript("shot-color.sh");
        });
    }

    function startTranslate(targetLang) {
        toolbar._pendingTargetLang = targetLang || "";
        toolbar._translateStdout = "";
        toolbar.translateResult = false;
        toolbar.translating = true;
        toolbar.capturingTranslate = true;
        // Скрываем пилюли тулбара пока работает slurp
        toolbar.shown = false;
        Qt.callLater(() => {
            translateProc.running = false;
            if (toolbar._pendingTargetLang !== "")
                translateProc.command = [toolbar.translateScriptPath, toolbar._pendingTargetLang];
            else
                translateProc.command = [toolbar.translateScriptPath];
            translateProc.running = true;
        });
    }

    function retranslate(targetLang) {
        const tl = String(targetLang || "ru").toLowerCase();
        toolbar.target_lang = tl;
        if (toolbar.original === "") {
            toolbar.startTranslate(tl);
            return;
        }
        toolbar._pendingTargetLang = tl;
        toolbar._translateStdout = "";
        toolbar.translating = true;
        translateProc.running = false;
        translateProc.command = [toolbar.translateScriptPath, tl, toolbar.original];
        translateProc.running = true;
    }

    function copyText(txt) {
        if (!txt) return;
        Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" | wl-copy", "oberon-copy", String(txt)]);
    }

    function askAiAboutTranslation() {
        const original = toolbar.original;
        const translated = toolbar.translated;
        const shell = toolbar.shell || (typeof root !== "undefined" ? root : null);
        toolbar.close();
        if (shell && typeof shell.openAiWithPrompt === "function") {
            shell.openAiWithPrompt("Объясни подробнее этот текст:\n" + original + "\n\nПеревод:\n" + translated);
        }
    }

    function _handleTranslateOutput(rawText, exitCode) {
        toolbar.capturingTranslate = false;
        toolbar.translating = false;
        if (exitCode === 2 && rawText.trim() === "") {
            toolbar.shown = false;
            toolbar.translateResult = false;
            return;
        }
        const lines = String(rawText || "").trim().split("\n");
        const lastLine = lines.length > 0 ? lines[lines.length - 1].trim() : "";
        if (lastLine === "") {
            if (exitCode !== 0) {
                toolbar.shown = false;
                toolbar.translateResult = false;
            }
            return;
        }
        try {
            const res = JSON.parse(lastLine);
            toolbar.translateOk = Boolean(res.ok);
            toolbar.source_lang = res.source_lang || "auto";
            toolbar.target_lang = res.target_lang || (toolbar._pendingTargetLang || "ru");
            toolbar.original = res.original || "";
            toolbar.translated = res.translated || "";
            toolbar.translateError = res.ok ? "" : (res.error || "Текст на изображении не найден");
            toolbar.translateResult = true;
            toolbar.shown = true;
            catcher.forceActiveFocus();
        } catch (e) {
            toolbar.translateOk = false;
            toolbar.translateError = "Не удалось разобрать ответ переводчика";
            toolbar.translateResult = true;
            toolbar.shown = true;
            catcher.forceActiveFocus();
        }
    }

    function runScript(name) {
        Quickshell.execDetached(["sh", toolbar.scriptsDir + name]);
    }

    // прежнее поведение screenshotRegion/screenshotFull из shell.qml, только с
    // паузой, чтобы тулбар успел скрыться перед slurp
    function shoot(fullscreen) {
        Quickshell.execDetached(["sh", "-c",
            "sleep 0.25; mkdir -p \"$HOME/Pictures/Screenshots\"; f=\"$HOME/Pictures/Screenshots/$(date +%F_%H-%M-%S).png\"; " +
            "if grim" + (fullscreen ? "" : " -g \"$(slurp)\"") + " \"$f\" 2>/dev/null; then wl-copy < \"$f\"; " +
            "notify-send -a Oberon 'Скриншот' '" + (fullscreen ? "Весь экран сохранён и скопирован" : "Область сохранена и скопирована") + "'; fi"]);
    }

    onShownChanged: {
        if (toolbar.shown) catcher.forceActiveFocus();
        else if (!toolbar.capturingTranslate) closed();
    }

    visible: toolbar.shown || toolbar.reveal > 0.01
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "oberon-shottoolbar"
    WlrLayershell.keyboardFocus: toolbar.shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Behavior on reveal {
        NumberAnimation {
            duration: toolbar.shown ? Theme.durFastSpatial : Theme.durFastEffects
            easing.type: Easing.Bezier
            easing.bezierCurve: Theme.curveDefaultSpatial
        }
    }

    // клик мимо карточки — закрыть
    MouseArea {
        anchors.fill: parent
        onClicked: toolbar.close()
    }

    // ── карточка пилюль по центру сверху ──────────────────────────────
    Rectangle {
        id: card
        visible: !toolbar.translateResult && !toolbar.capturingTranslate
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: Theme.topReserve + Theme.dp(24)
        width: row.implicitWidth + Theme.dp(28)
        height: Theme.dp(96)
        radius: Theme.shapeXl
        color: Theme.bg
        opacity: toolbar.reveal
        transform: Translate { y: (1 - toolbar.reveal) * -Theme.dp(12) }

        MouseArea { anchors.fill: parent }   // клики внутри не закрывают

        Row {
            id: row
            anchors.centerIn: parent
            spacing: Theme.dp(8)

            Repeater {
                model: toolbar.modes

                Item {
                    id: tile

                    required property var modelData
                    required property int index
                    readonly property bool focused: toolbar._focus === tile.index
                    readonly property bool hot: tile.focused || tap.containsMouse
                    readonly property bool isVideo: tile.modelData.id === "video"

                    width: Theme.dp(76)
                    height: card.height - Theme.dp(16)

                    Rectangle {
                        id: face

                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        width: Theme.dp(58)
                        height: Theme.dp(58)
                        radius: height / 2
                        color: toolbar.recording && tile.isVideo ? Theme.error
                            : (tile.hot ? Theme.primaryContainer : Theme.bgTile)
                        scale: tap.pressed ? 0.94 : (tile.hot ? 1.04 : 1)

                        Behavior on color { ColorAnimation { duration: Theme.durFastEffects } }
                        Behavior on scale {
                            NumberAnimation {
                                duration: Theme.durFastSpatial
                                easing.type: Easing.Bezier
                                easing.bezierCurve: Theme.curveFastSpatial
                            }
                        }

                        // StateLayer кладётся поверх, рябь обрезается по кругу
                        StateLayer {
                            id: tap
                            anchors.fill: parent
                            radius: parent.radius
                            tint: toolbar.recording && tile.isVideo ? Theme.fgError : Theme.text
                            onClicked: toolbar.activate(tile.index)
                            onEntered: {
                                if (toolbar._focus !== tile.index) toolbar._focus = tile.index;
                            }
                        }

                        Icon {
                            anchors.centerIn: parent
                            name: toolbar.recording && tile.isVideo ? "stop" : tile.modelData.icon
                            size: Theme.dp(26)
                            color: toolbar.recording && tile.isVideo ? Theme.fgError
                                : (tile.hot ? Theme.fgPrimaryContainer : Theme.text)
                        }
                    }

                    LText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Theme.dp(4)
                        role: "labelSmall"
                        color: tile.hot ? Theme.primary : Theme.subtext
                        text: toolbar.recording && tile.isVideo ? "Стоп" : tile.modelData.label

                        Behavior on color { ColorAnimation { duration: Theme.durFastEffects } }
                    }
                }
            }
        }

        // индикатор активной записи — над карточкой
        Row {
            visible: toolbar.recording
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.top
            anchors.bottomMargin: Theme.dp(12)
            spacing: Theme.dp(6)

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.dp(8)
                height: Theme.dp(8)
                radius: height / 2
                color: Theme.error
            }
            LText {
                anchors.verticalCenter: parent.verticalCenter
                role: "labelSmall"
                color: Theme.subtext
                text: "ведётся запись"
            }
        }
    }

    // ── Translation Result Card Mode (translateResult) ────────────────
    Card {
        id: translateCard
        visible: toolbar.translateResult
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: Theme.topReserve + Theme.dp(24)
        width: Theme.dp(520)
        pad: Theme.dp(16)
        color: Theme.mHigh
        opacity: toolbar.reveal
        transform: Translate { y: (1 - toolbar.reveal) * -Theme.dp(12) }

        MouseArea {
            anchors.fill: parent
            z: -1
        }

        // Header: "Перевод экрана (" + source_lang + " → " + target_lang + ")",
        // target language switch chips (RU, EN, DE, JA), and Close (Esc) button.
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            Icon {
                name: "translate"
                size: Theme.dp(20)
                color: Theme.primary
            }

            LText {
                Layout.fillWidth: true
                role: "titleSmall"
                color: Theme.text
                elide: Text.ElideRight
                text: "Перевод экрана (" + toolbar.source_lang + " → " + toolbar.target_lang + ")"
            }

            Row {
                spacing: Theme.dp(4)

                Repeater {
                    model: toolbar.targetLangs

                    Chip {
                        required property string modelData
                        kind: "filter"
                        size: "sm"
                        label: modelData
                        selected: toolbar.target_lang.toUpperCase() === modelData
                        onClicked: toolbar.retranslate(modelData.toLowerCase())
                    }
                }
            }

            IconButton {
                icon: "close"
                size: "xs"
                tooltip: "Закрыть (Esc)"
                onClicked: toolbar.close()
            }
        }

        // Оригинал (OCR): selectable/scrollable LText in a sunken Theme.mLow box + "Копировать оригинал" button
        ColumnLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(6)
            spacing: Theme.dp(6)

            RowLayout {
                Layout.fillWidth: true

                LText {
                    role: "labelMedium"
                    color: Theme.subtext
                    text: "Оригинал (OCR)"
                    Layout.fillWidth: true
                }

                Button {
                    variant: "tonal"
                    size: "xs"
                    icon: "content_copy"
                    text: "Копировать оригинал"
                    disabled: toolbar.original === ""
                    onClicked: toolbar.copyText(toolbar.original)
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: Math.min(Theme.dp(130), Math.max(Theme.dp(56), origText.implicitHeight + Theme.dp(20)))
                radius: Theme.shapeMd
                color: Theme.mLow
                clip: true

                Flickable {
                    id: origFlick
                    anchors.fill: parent
                    anchors.margins: Theme.dp(10)
                    contentWidth: width
                    contentHeight: origText.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    clip: true

                    LText {
                        id: origText
                        width: origFlick.width
                        role: "bodyMedium"
                        color: toolbar.original !== "" ? Theme.text : Theme.subtext
                        wrapMode: Text.Wrap
                        text: toolbar.original !== "" ? toolbar.original : (toolbar.translateError || "Текст не найден")
                    }

                    TextEdit {
                        anchors.fill: origText
                        text: origText.text
                        font: origText.font
                        color: "transparent"
                        selectedTextColor: Theme.fgPrimary
                        selectionColor: Theme.primary
                        readOnly: true
                        selectByMouse: true
                        wrapMode: TextEdit.Wrap
                    }
                }
            }
        }

        // Перевод: prominent bodyLarge Theme.text in a Theme.primaryContainer / Theme.mHigh box
        // + "Скопировать перевод" button + "Спросить ИИ" button
        ColumnLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(6)
            spacing: Theme.dp(8)

            RowLayout {
                Layout.fillWidth: true

                LText {
                    role: "labelMedium"
                    color: Theme.primary
                    text: toolbar.translating ? "Перевод (обновление…)" : "Перевод"
                    Layout.fillWidth: true
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: Math.min(Theme.dp(160), Math.max(Theme.dp(64), transText.implicitHeight + Theme.dp(24)))
                radius: Theme.shapeMd
                color: Theme.primaryContainer
                border.width: 1
                border.color: Theme.alpha(Theme.primary, 0.35)
                clip: true

                Flickable {
                    id: transFlick
                    anchors.fill: parent
                    anchors.margins: Theme.dp(12)
                    contentWidth: width
                    contentHeight: transText.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    clip: true

                    LText {
                        id: transText
                        width: transFlick.width
                        role: "bodyLarge"
                        color: Theme.text
                        wrapMode: Text.Wrap
                        text: toolbar.translating && toolbar.translated === ""
                            ? "Переводим…"
                            : (toolbar.translated !== "" ? toolbar.translated : toolbar.translateError)
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.dp(8)

                Button {
                    variant: "tonal"
                    size: "xs"
                    icon: "content_copy"
                    text: "Скопировать перевод"
                    disabled: toolbar.translated === ""
                    onClicked: toolbar.copyText(toolbar.translated)
                }

                Item { Layout.fillWidth: true }

                Button {
                    variant: "filled"
                    size: "xs"
                    icon: "auto_awesome"
                    text: "Спросить ИИ"
                    disabled: toolbar.original === "" && toolbar.translated === ""
                    onClicked: toolbar.askAiAboutTranslation()
                }
            }
        }
    }

    // ── клавиатура ────────────────────────────────────────────────────
    Item {
        id: catcher
        anchors.fill: parent
        focus: toolbar.shown

        Keys.onPressed: (event) => {
            if (!toolbar.shown) { event.accepted = true; return; }
            if (event.key === Qt.Key_Escape) {
                toolbar.close();
                event.accepted = true;
            } else if (!toolbar.translateResult && event.key === Qt.Key_Left) {
                toolbar._focus = (toolbar._focus + toolbar.modes.length - 1) % toolbar.modes.length;
                event.accepted = true;
            } else if (!toolbar.translateResult && event.key === Qt.Key_Right) {
                toolbar._focus = (toolbar._focus + 1) % toolbar.modes.length;
                event.accepted = true;
            } else if (!toolbar.translateResult && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                toolbar.activate(toolbar._focus);
                event.accepted = true;
            } else if (!toolbar.translateResult && event.key >= Qt.Key_1 && event.key <= Qt.Key_6) {
                toolbar.activate(event.key - Qt.Key_1);
                event.accepted = true;
            }
        }
    }

    // статус записи — по pid-файлу из shot-video.sh
    Timer {
        id: statePoll
        interval: 800
        repeat: true
        running: toolbar.shown && !toolbar.translateResult
        onTriggered: {
            recProc.running = false;
            recProc.running = true;
        }
    }

    Process {
        id: recProc
        command: ["sh", "-c", "[ -f " + toolbar.recPidFile + " ] && kill -0 \"$(cat " + toolbar.recPidFile + ")\" 2>/dev/null && echo recording || echo idle"]
        stdout: StdioCollector {
            onStreamFinished: toolbar.recording = text.indexOf("recording") !== -1
        }
    }

    Process {
        id: translateProc
        stdout: StdioCollector {
            onStreamFinished: toolbar._translateStdout = text
        }
        onExited: (exitCode, exitStatus) => {
            toolbar._handleTranslateOutput(toolbar._translateStdout, exitCode);
        }
    }
}
