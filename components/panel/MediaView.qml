pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtMultimedia
import Quickshell
import Quickshell.Io
import "../../core"
import "../../ui"
import ".."

ColumnLayout {
    id: page

    property var win: null
    property real sourceWidth: 0
    property real sourceHeight: 0
    property real sourceDuration: 0
    property real sourceSize: 0
    property real sourceFps: 0
    property string sourceCodec: ""
    property string errorText: ""
    property string savedPath: ""
    property string busyText: ""
    property string probeTargetPath: ""
    property string probeOutput: ""
    property string probeError: ""
    property string operationOutput: ""
    property string operationError: ""
    property string operationPath: ""
    property real trimStart: 0
    property real trimEnd: 0
    property bool trimCustomized: false
    property string cropWidthText: "0"
    property string cropHeightText: "0"
    property string cropXText: "0"
    property string cropYText: "0"

    readonly property string path: win && win.shell ? String(win.shell.mediaPath || "") : ""
    readonly property string fileName: page.path.split("/").pop()
    readonly property string fileExt: page.fileName.split(".").pop().toLowerCase()
    readonly property bool isVideo: ["mp4", "mkv", "webm", "mov", "avi", "m4v", "wmv", "flv", "mpg", "mpeg", "ts"].indexOf(page.fileExt) >= 0
    readonly property bool isAnimated: ["gif", "webp", "apng"].indexOf(page.fileExt) >= 0
    readonly property string scriptPath: Quickshell.env("HOME") + "/oberon/scripts/media.sh"
    readonly property real durationSeconds: player.duration > 0 ? player.duration / 1000 : page.sourceDuration
    readonly property real playbackSeconds: player.position > 0 ? player.position / 1000 : 0
    readonly property int cropWidth: page.numberOrZero(page.cropWidthText)
    readonly property int cropHeight: page.numberOrZero(page.cropHeightText)
    readonly property int cropX: page.numberOrZero(page.cropXText)
    readonly property int cropY: page.numberOrZero(page.cropYText)
    readonly property bool hasMetadata: page.sourceWidth > 0 && page.sourceHeight > 0
    readonly property bool cropValid: page.hasMetadata && page.cropWidth > 0 && page.cropHeight > 0
        && page.cropX >= 0 && page.cropY >= 0
        && page.cropX + page.cropWidth <= page.sourceWidth
        && page.cropY + page.cropHeight <= page.sourceHeight
    readonly property bool canTrim: page.isVideo && page.durationSeconds > 0
        && page.trimEnd - page.trimStart >= 0.05

    visible: win !== null && win.mode === "panel" && win.page === "media"
    Layout.fillWidth: true
    spacing: Theme.pageSpacing

    function numberOrZero(value) {
        const result = parseInt(String(value), 10);
        return isFinite(result) ? Math.max(0, result) : 0;
    }

    function localFileUrl(value) {
        return "file://" + String(value || "").split("/").map(part => encodeURIComponent(part)).join("/");
    }

    function formatTime(seconds) {
        const total = Math.max(0, Math.floor(Number(seconds) || 0));
        const hours = Math.floor(total / 3600);
        const minutes = Math.floor(total / 60) % 60;
        const secs = total % 60;
        const mm = (minutes < 10 ? "0" : "") + minutes;
        const ss = (secs < 10 ? "0" : "") + secs;
        return hours > 0 ? hours + ":" + mm + ":" + ss : mm + ":" + ss;
    }

    function formatBytes(bytes) {
        let size = Math.max(0, Number(bytes) || 0);
        if (size < 1024) return size + " Б";
        const units = ["КиБ", "МиБ", "ГиБ"];
        let unit = -1;
        do {
            size /= 1024;
            unit++;
        } while (size >= 1024 && unit < units.length - 1);
        return size.toFixed(1) + " " + units[unit];
    }

    function outputPath(suffix) {
        const source = page.path;
        const slash = source.lastIndexOf("/");
        const dot = source.lastIndexOf(".");
        const base = dot > slash ? source.slice(0, dot) : source;
        const ext = dot > slash ? source.slice(dot) : "";
        return base + "-" + suffix + ext;
    }

    function startProbe(target) {
        if (target === "" || target !== page.path) return;
        page.probeTargetPath = target;
        page.probeOutput = "";
        page.probeError = "";
        probeProc.command = ["bash", page.scriptPath, "probe", target];
        probeProc.running = true;
    }

    function loadPath() {
        const target = page.path.trim();
        player.stop();
        page.sourceWidth = 0;
        page.sourceHeight = 0;
        page.sourceDuration = 0;
        page.sourceSize = 0;
        page.sourceFps = 0;
        page.sourceCodec = "";
        page.errorText = "";
        page.savedPath = "";
        page.busyText = "";
        page.trimStart = 0;
        page.trimEnd = 0;
        page.trimCustomized = false;
        page.cropWidthText = "0";
        page.cropHeightText = "0";
        page.cropXText = "0";
        page.cropYText = "0";
        if (probeProc.running) {
            probeProc.running = false;
            if (target !== "") Qt.callLater(() => page.startProbe(target));
        } else if (target !== "") {
            page.startProbe(target);
        }
    }

    function finishProbe(exitCode) {
        if (page.probeTargetPath !== page.path) return;
        if (exitCode !== 0) {
            page.errorText = page.probeError.trim() || "Не удалось прочитать файл.";
            return;
        }
        try {
            const data = JSON.parse(page.probeOutput.trim());
            const width = Math.floor(Number(data.width) || 0);
            const height = Math.floor(Number(data.height) || 0);
            if (width <= 0 || height <= 0) throw new Error("empty dimensions");
            page.sourceWidth = width;
            page.sourceHeight = height;
            page.sourceDuration = Math.max(0, Number(data.duration) || 0);
            page.sourceSize = Math.max(0, Number(data.size) || 0);
            page.sourceFps = Math.max(0, Number(data.fps) || 0);
            page.sourceCodec = String(data.codec || "Неизвестно");
            page.cropWidthText = String(width);
            page.cropHeightText = String(height);
            page.cropXText = "0";
            page.cropYText = "0";
            page.trimStart = 0;
            page.trimEnd = page.sourceDuration;
            page.errorText = "";
        } catch (e) {
            page.errorText = "Не удалось разобрать сведения о файле.";
        }
    }

    function seek(seconds) {
        const duration = page.durationSeconds;
        player.position = Math.round(Math.max(0, Math.min(duration, Number(seconds) || 0)) * 1000);
    }

    function setTrimStart(seconds) {
        const maxStart = Math.max(0, page.trimEnd - 0.05);
        page.trimStart = Math.max(0, Math.min(maxStart, Number(seconds) || 0));
        page.trimCustomized = true;
    }

    function setTrimEnd(seconds) {
        const duration = page.durationSeconds;
        if (duration <= 0) return;
        const gap = Math.min(0.05, duration / 2);
        const minEnd = Math.min(duration, page.trimStart + gap);
        page.trimEnd = Math.max(minEnd, Math.min(duration, Number(seconds) || 0));
        page.trimCustomized = true;
    }

    function runOperation(args, message) {
        if (editProc.running || page.path === "") return;
        page.errorText = "";
        page.savedPath = "";
        page.busyText = message;
        page.operationOutput = "";
        page.operationError = "";
        page.operationPath = page.path;
        editProc.command = ["bash", page.scriptPath].concat(args);
        editProc.running = true;
    }

    function saveTrim() {
        if (!page.canTrim) return;
        page.runOperation(["cut", page.path, page.trimStart.toFixed(3), page.trimEnd.toFixed(3), page.outputPath("trim")], "Обрезаю видео…");
    }

    function saveCrop() {
        if (!page.cropValid) return;
        const rect = page.cropWidth + ":" + page.cropHeight + ":" + page.cropX + ":" + page.cropY;
        page.runOperation(["crop", rect, page.path, page.outputPath("crop")], "Обрезаю кадр…");
    }

    function finishOperation(exitCode) {
        page.busyText = "";
        if (exitCode !== 0) {
            page.errorText = page.operationError.trim() || page.operationOutput.trim()
                || "Не удалось обработать файл.";
            return;
        }
        const lines = page.operationOutput.trim().split("\n").filter(line => line.trim() !== "");
        page.savedPath = lines.length > 0 ? lines[lines.length - 1].trim() : "";
    }

    onPathChanged: page.loadPath()
    onVisibleChanged: {
        if (!visible) player.pause();
        else if (page.isVideo && player.mediaStatus === MediaPlayer.LoadedMedia) player.play();
    }
    Component.onCompleted: if (page.path !== "") page.loadPath()

    Process {
        id: probeProc
        stdout: SplitParser { onRead: line => page.probeOutput += line + "\n" }
        stderr: SplitParser { onRead: line => page.probeError += line + "\n" }
        onExited: (exitCode) => page.finishProbe(exitCode)
    }

    Process {
        id: editProc
        stdout: SplitParser { onRead: line => page.operationOutput += line + "\n" }
        stderr: SplitParser { onRead: line => page.operationError += line + "\n" }
        onExited: (exitCode) => page.finishOperation(exitCode)
    }

    MediaPlayer {
        id: player
        source: page.isVideo && page.path !== "" ? page.localFileUrl(page.path) : ""
        videoOutput: videoOutput
        audioOutput: AudioOutput { volume: 0.8 }
        onDurationChanged: {
            if (duration > 0 && !page.trimCustomized) {
                page.trimStart = 0;
                page.trimEnd = duration / 1000;
            }
        }
        onMediaStatusChanged: {
            if (mediaStatus === MediaPlayer.LoadedMedia && page.visible) play();
            else if (mediaStatus === MediaPlayer.InvalidMedia)
                page.errorText = errorString || "Не удалось открыть видео.";
        }
        onErrorOccurred: (error, errorString) => {
            if (errorString !== "") page.errorText = errorString;
        }
    }

    Card {
        Layout.fillWidth: true
        visible: page.path === ""

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            Icon {
                Layout.alignment: Qt.AlignHCenter
                name: "perm_media"
                size: Theme.dp(32)
                color: Theme.subtext
            }
            LText {
                Layout.fillWidth: true
                role: "titleMedium"
                color: Theme.text
                horizontalAlignment: Text.AlignHCenter
                text: "Нет файла"
            }
            LText {
                Layout.fillWidth: true
                role: "bodySmall"
                color: Theme.subtext
                horizontalAlignment: Text.AlignHCenter
                text: "Откройте изображение или видео через IPC: oberon media <путь>"
                wrapMode: Text.WordWrap
            }
        }
    }

    Card {
        id: previewCard
        Layout.fillWidth: true
        visible: page.path !== ""
        title: page.fileName !== "" ? page.fileName : "Просмотр файла"

        Rectangle {
            id: stage
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.dp(340)
            radius: Theme.shapeLgInc
            color: "#000000"
            clip: true

            Image {
                id: stillImage
                anchors.fill: parent
                visible: page.path !== "" && !page.isVideo && !page.isAnimated
                source: visible ? page.localFileUrl(page.path) : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: true
                smooth: true
                sourceSize: Qt.size(Math.max(1, stage.width), Math.max(1, stage.height))
                onStatusChanged: if (status === Image.Error) page.errorText = "Не удалось загрузить изображение."
            }

            AnimatedImage {
                id: animatedImage
                anchors.fill: parent
                visible: page.path !== "" && !page.isVideo && page.isAnimated
                source: visible ? page.localFileUrl(page.path) : ""
                fillMode: Image.PreserveAspectFit
                playing: visible
                cache: true
                sourceSize: Qt.size(Math.max(1, stage.width), Math.max(1, stage.height))
                onStatusChanged: if (status === AnimatedImage.Error) page.errorText = "Не удалось загрузить анимацию."
            }

            VideoOutput {
                id: videoOutput
                anchors.fill: parent
                visible: page.isVideo
                fillMode: VideoOutput.PreserveAspectFit
            }

            QtObject {
                id: frame
                readonly property real width: page.isVideo ? videoOutput.contentRect.width
                    : (page.isAnimated ? animatedImage.paintedWidth : stillImage.paintedWidth)
                readonly property real height: page.isVideo ? videoOutput.contentRect.height
                    : (page.isAnimated ? animatedImage.paintedHeight : stillImage.paintedHeight)
                readonly property real x: page.isVideo ? videoOutput.contentRect.x : (stage.width - width) / 2
                readonly property real y: page.isVideo ? videoOutput.contentRect.y : (stage.height - height) / 2
            }

            Item {
                id: cropOverlay
                anchors.fill: parent
                visible: page.cropValid && frame.width > 0 && frame.height > 0
                readonly property real cropLeft: frame.x + page.cropX / page.sourceWidth * frame.width
                readonly property real cropTop: frame.y + page.cropY / page.sourceHeight * frame.height
                readonly property real cropWidth: page.cropWidth / page.sourceWidth * frame.width
                readonly property real cropHeight: page.cropHeight / page.sourceHeight * frame.height
                readonly property color shade: Qt.rgba(0, 0, 0, 0.55)

                Rectangle {
                    x: frame.x; y: frame.y; width: frame.width
                    height: Math.max(0, cropOverlay.cropTop - frame.y)
                    color: cropOverlay.shade
                }
                Rectangle {
                    x: frame.x; y: cropOverlay.cropTop
                    width: Math.max(0, cropOverlay.cropLeft - frame.x); height: cropOverlay.cropHeight
                    color: cropOverlay.shade
                }
                Rectangle {
                    x: cropOverlay.cropLeft + cropOverlay.cropWidth; y: cropOverlay.cropTop
                    width: Math.max(0, frame.x + frame.width - x); height: cropOverlay.cropHeight
                    color: cropOverlay.shade
                }
                Rectangle {
                    x: frame.x; y: cropOverlay.cropTop + cropOverlay.cropHeight; width: frame.width
                    height: Math.max(0, frame.y + frame.height - y)
                    color: cropOverlay.shade
                }
                Rectangle {
                    x: cropOverlay.cropLeft; y: cropOverlay.cropTop
                    width: cropOverlay.cropWidth; height: cropOverlay.cropHeight
                    color: "transparent"
                    border.width: Theme.dp(2)
                    border.color: Theme.primary
                }
            }

            LText {
                anchors.centerIn: parent
                visible: page.path !== "" && !page.hasMetadata && !probeProc.running && page.errorText === ""
                role: "bodyMedium"
                color: "white"
                text: "Читаю файл…"
            }
        }

        LText {
            Layout.fillWidth: true
            visible: page.busyText !== ""
            role: "bodySmall"
            color: Theme.primary
            text: page.busyText
        }
        LText {
            Layout.fillWidth: true
            visible: page.savedPath !== ""
            role: "bodySmall"
            color: Theme.success
            text: "Сохранено: " + page.savedPath
            wrapMode: Text.WrapAnywhere
        }
        LText {
            Layout.fillWidth: true
            visible: page.errorText !== ""
            role: "bodySmall"
            color: Theme.error
            text: page.errorText
            wrapMode: Text.WrapAnywhere
        }
    }

    Card {
        Layout.fillWidth: true
        visible: page.isVideo && page.path !== ""
        title: "Управление видео"

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            Button {
                size: "s"
                variant: "tonal"
                icon: player.playbackState === MediaPlayer.PlayingState ? "pause" : "play_arrow"
                text: player.playbackState === MediaPlayer.PlayingState ? "Пауза" : "Воспроизвести"
                disabled: page.errorText !== ""
                onClicked: player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play()
            }
            Button {
                size: "s"
                variant: "text"
                text: "−5 с"
                disabled: page.durationSeconds <= 0
                onClicked: page.seek(page.playbackSeconds - 5)
            }
            Slider {
                Layout.fillWidth: true
                from: 0
                to: Math.max(0, page.durationSeconds)
                value: page.playbackSeconds
                stepSize: 0.1
                showValue: false
                disabled: page.durationSeconds <= 0
                onMoved: value => page.seek(value)
            }
            Button {
                size: "s"
                variant: "text"
                text: "+5 с"
                disabled: page.durationSeconds <= 0
                onClicked: page.seek(page.playbackSeconds + 5)
            }
        }
        LText {
            Layout.alignment: Qt.AlignRight
            role: "labelMedium"
            color: Theme.subtext
            tabular: true
            text: page.formatTime(page.playbackSeconds) + " / " + page.formatTime(page.durationSeconds)
        }
    }

    Card {
        Layout.fillWidth: true
        visible: page.isVideo && page.path !== ""
        title: "Обрезка по времени"

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(10)
            LText {
                Layout.preferredWidth: Theme.dp(70)
                role: "labelLarge"
                color: Theme.subtext
                text: "Начало"
            }
            Slider {
                Layout.fillWidth: true
                from: 0
                to: Math.max(0, page.durationSeconds)
                value: page.trimStart
                stepSize: 0.05
                showValue: false
                disabled: page.durationSeconds <= 0 || editProc.running
                onMoved: value => page.setTrimStart(value)
            }
            LText {
                Layout.preferredWidth: Theme.dp(54)
                horizontalAlignment: Text.AlignRight
                role: "labelMedium"
                color: Theme.text
                tabular: true
                text: page.formatTime(page.trimStart)
            }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(10)
            LText {
                Layout.preferredWidth: Theme.dp(70)
                role: "labelLarge"
                color: Theme.subtext
                text: "Конец"
            }
            Slider {
                Layout.fillWidth: true
                from: 0
                to: Math.max(0, page.durationSeconds)
                value: page.trimEnd
                stepSize: 0.05
                showValue: false
                disabled: page.durationSeconds <= 0 || editProc.running
                onMoved: value => page.setTrimEnd(value)
            }
            LText {
                Layout.preferredWidth: Theme.dp(54)
                horizontalAlignment: Text.AlignRight
                role: "labelMedium"
                color: Theme.text
                tabular: true
                text: page.formatTime(page.trimEnd)
            }
        }
        RowLayout {
            Layout.fillWidth: true
            LText {
                Layout.fillWidth: true
                role: "bodySmall"
                color: Theme.subtext
                text: "Выбранный фрагмент: " + page.formatTime(page.trimStart) + " — " + page.formatTime(page.trimEnd)
            }
            Button {
                size: "m"
                icon: "content_cut"
                text: "Обрезать"
                disabled: !page.canTrim || editProc.running
                onClicked: page.saveTrim()
            }
        }
    }

    Card {
        Layout.fillWidth: true
        visible: page.hasMetadata
        title: "Обрезать кадр"

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            TextField {
                id: cropWidthField
                Layout.fillWidth: true
                variant: "outlined"
                label: "W"
                text: page.cropWidthText
                input.validator: IntValidator { bottom: 0; top: Math.max(1, page.sourceWidth) }
                onTextEdited: page.cropWidthText = cropWidthField.text
            }
            TextField {
                id: cropHeightField
                Layout.fillWidth: true
                variant: "outlined"
                label: "H"
                text: page.cropHeightText
                input.validator: IntValidator { bottom: 0; top: Math.max(1, page.sourceHeight) }
                onTextEdited: page.cropHeightText = cropHeightField.text
            }
            TextField {
                id: cropXField
                Layout.fillWidth: true
                variant: "outlined"
                label: "X"
                text: page.cropXText
                input.validator: IntValidator { bottom: 0; top: Math.max(1, page.sourceWidth) }
                onTextEdited: page.cropXText = cropXField.text
            }
            TextField {
                id: cropYField
                Layout.fillWidth: true
                variant: "outlined"
                label: "Y"
                text: page.cropYText
                input.validator: IntValidator { bottom: 0; top: Math.max(1, page.sourceHeight) }
                onTextEdited: page.cropYText = cropYField.text
            }
        }

        RowLayout {
            Layout.fillWidth: true
            LText {
                Layout.fillWidth: true
                role: "bodySmall"
                color: page.cropValid ? Theme.subtext : Theme.error
                text: "Пиксели исходного кадра · " + page.sourceWidth + " × " + page.sourceHeight
            }
            Button {
                size: "m"
                icon: "crop"
                text: "Обрезать кадр"
                disabled: !page.cropValid || editProc.running
                onClicked: page.saveCrop()
            }
        }
    }

    Card {
        Layout.fillWidth: true
        visible: page.path !== ""
        title: "Информация"

        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: Theme.dp(16)
            rowSpacing: Theme.dp(6)

            LText { role: "bodySmall"; color: Theme.subtext; text: "Имя" }
            LText { Layout.fillWidth: true; role: "bodyMedium"; color: Theme.text; text: page.fileName; elide: Text.ElideMiddle }
            LText { role: "bodySmall"; color: Theme.subtext; text: "Размер" }
            LText { Layout.fillWidth: true; role: "bodyMedium"; color: Theme.text; text: page.hasMetadata ? page.formatBytes(page.sourceSize) : "—" }
            LText { role: "bodySmall"; color: Theme.subtext; text: "Разрешение" }
            LText { Layout.fillWidth: true; role: "bodyMedium"; color: Theme.text; text: page.hasMetadata ? page.sourceWidth + " × " + page.sourceHeight : "—" }
            LText { role: "bodySmall"; color: Theme.subtext; text: "Длительность" }
            LText { Layout.fillWidth: true; role: "bodyMedium"; color: Theme.text; text: page.sourceDuration > 0 ? page.formatTime(page.sourceDuration) : "—" }
            LText { role: "bodySmall"; color: Theme.subtext; text: "Кодек" }
            LText { Layout.fillWidth: true; role: "bodyMedium"; color: Theme.text; text: page.sourceCodec || "—" }
            LText { role: "bodySmall"; color: Theme.subtext; text: "FPS" }
            LText { Layout.fillWidth: true; role: "bodyMedium"; color: Theme.text; text: page.sourceFps > 0 ? page.sourceFps.toFixed(2) : "—" }
        }
    }
}
