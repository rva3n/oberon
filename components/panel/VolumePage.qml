pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../core"
import "../../ui"
import ".."

// Звук: Lucid-анатомия control-centre — мастер-слайдер, устройства вывода/ввода
// как связные группы DeviceRow (стыкующиеся углы, spacing 0, один Card на
// группу), приложения и микрофоны отдельными карточками со строками.
ColumnLayout {
    id: volumePage

    property var win: null
    property var audioState: ({ apps: [], sources: [], sinks: [], defaultSink: "", defaultSource: "" })
    property string audioOutput: ""
    property int micVolumePct: 0
    property bool isUserDragging: false
    property var actionQueue: []
    property var pendingActions: ({})

    readonly property string scriptPath: Quickshell.env("HOME") + "/oberon/scripts/audio_streams.sh"

    visible: win !== null && win.mode === "panel" && win.page === "volume"
    Layout.fillWidth: true
    spacing: Theme.pageSpacing

    // application.name (lowercase) → имя иконки; тот же приём, что и в
    // WorkspacesRow/Switcher, плюс сопоставление по Name десктоп-файла, потому
    // что PipeWire отдаёт человекочитаемое имя приложения.
    readonly property var iconIndex: {
        const byId = {};
        const byClass = {};
        const byName = {};
        for (const e of DesktopEntries.applications.values) {
            if (!e.icon) continue;
            if (e.id) byId[String(e.id).toLowerCase()] = e.icon;
            if (e.startupClass) byClass[String(e.startupClass).toLowerCase()] = e.icon;
            if (e.name) byName[String(e.name).toLowerCase()] = e.icon;
        }
        return { byId: byId, byClass: byClass, byName: byName };
    }

    function iconFor(n) {
        if (!n) return "";
        const p = n.properties || {};
        const direct = n.icon || p["application.icon.name"] || p["application.icon_name"] || p["application.icon-name"];
        if (direct) {
            const dp = Quickshell.iconPath(String(direct), true);
            if (dp !== "") return dp;
        }
        const ix = volumePage.iconIndex;
        const keys = [n.app, n.binary, p["application.name"], p["application.process.binary"],
                      n.description, n.name];
        for (const raw of keys) {
            const k = String(raw || "").toLowerCase();
            if (k === "") continue;
            const nm = ix.byId[k] || ix.byClass[k] || ix.byName[k];
            if (nm) {
                const path = Quickshell.iconPath(nm, true);
                if (path !== "") return path;
            }
        }
        return "";
    }

    function streamName(n) {
        if (!n) return "";
        const p = n.properties || {};
        return n.app || p["application.name"] || n.name || n.description || "";
    }

    readonly property var defaultMic: {
        const sources = volumePage.audioState.sources || [];
        for (const source of sources)
            if (String(source.name) === String(volumePage.audioState.defaultSource)) return source;
        return null;
    }

    function refreshAudio() {
        if (!volumePage.visible || audioListProc.running || audioActionProc.running
                || volumePage.actionQueue.length > 0 || volumePage.isUserDragging)
            return;
        volumePage.audioOutput = "";
        audioListProc.running = true;
    }

    function finishAudioRefresh(exitCode) {
        const output = volumePage.audioOutput.trim();
        volumePage.audioOutput = "";
        if (exitCode !== 0 || volumePage.isUserDragging || output === "") return;
        try {
            const data = JSON.parse(output);
            volumePage.audioState = {
                apps: Array.isArray(data.apps) ? data.apps : [],
                sinks: Array.isArray(data.sinks) ? data.sinks : [],
                sources: Array.isArray(data.sources) ? data.sources : [],
                defaultSink: String(data.defaultSink || ""),
                defaultSource: String(data.defaultSource || "")
            };
            const mic = volumePage.defaultMic;
            volumePage.micVolumePct = mic
                    ? Math.max(0, Math.min(100, Math.round(Number(mic.volume) || 0))) : 0;
        } catch (e) {}
    }

    function queueAudioAction(key, args) {
        const queue = volumePage.actionQueue.slice();
        const pending = Object.assign({}, volumePage.pendingActions);
        if (queue.indexOf(key) === -1) queue.push(key);
        pending[key] = args;
        volumePage.actionQueue = queue;
        volumePage.pendingActions = pending;
        volumePage.runNextAudioAction();
    }

    function runNextAudioAction() {
        if (audioActionProc.running || volumePage.actionQueue.length === 0) return;
        const key = volumePage.actionQueue[0];
        const pending = Object.assign({}, volumePage.pendingActions);
        const args = pending[key] || [];
        delete pending[key];
        volumePage.actionQueue = volumePage.actionQueue.slice(1);
        volumePage.pendingActions = pending;
        audioActionProc.actionArgs = args;
        audioActionProc.running = true;
    }

    function setAppVolume(index, pct) {
        const id = Number(index);
        if (!isFinite(id) || Math.floor(id) !== id || id < 0) return;
        const value = Math.max(0, Math.min(100, Math.round(Number(pct) || 0)));
        volumePage.queueAudioAction("app-volume-" + id,
            ["set-app-volume", String(id), String(value)]);
    }

    function toggleAppMute(index) {
        const id = Number(index);
        if (!isFinite(id) || Math.floor(id) !== id || id < 0) return;
        volumePage.queueAudioAction("app-mute-" + id, ["toggle-app-mute", String(id)]);
    }

    function setDefaultSink(id) {
        volumePage.queueAudioAction("default-sink", ["set-default-sink", String(id)]);
    }

    function setDefaultSource(id) {
        volumePage.queueAudioAction("default-source", ["set-default-source", String(id)]);
    }

    function setMicVolume(pct) {
        if (!volumePage.defaultMic) return;
        const value = Math.max(0, Math.min(100, Math.round(Number(pct) || 0)));
        volumePage.queueAudioAction("mic-volume", ["mic-volume", String(value)]);
    }

    function setMicMute(muted) {
        if (!volumePage.defaultMic) return;
        volumePage.queueAudioAction("mic-mute", ["mic-mute", muted ? "on" : "off"]);
    }

    onVisibleChanged: {
        if (visible) volumePage.refreshAudio();
        else volumePage.isUserDragging = false;
    }

    Component.onCompleted: if (volumePage.visible) volumePage.refreshAudio()

    // иконка устройства по имени/порту — наушники/HDMI/колонка
    function devIcon(n) {
        const s = ((n.description || "") + " " + (n.name || "")).toLowerCase();
        if (s.indexOf("head") >= 0 || s.indexOf("bluez") >= 0) return "headphones";
        if (s.indexOf("hdmi") >= 0 || s.indexOf("display") >= 0) return "tv";
        return "speaker";
    }

    // положение строки в связной группе (стыкующиеся углы DeviceRow)
    function groupPos(i, n) {
        if (n <= 1) return "single";
        if (i === 0) return "top";
        if (i === n - 1) return "bottom";
        return "middle";
    }

    // входящие потоки: isStream && !isSink
    readonly property var captureStreams: {
        const out = [];
        const ss = volumePage.win ? volumePage.win.streams : null;
        if (!ss) return out;
        for (const n of ss) if (!n.isSink) out.push(n);
        return out;
    }

    // общая громкость: клик по иконке — mute
    Card {
        Layout.fillWidth: true
        pad: Theme.dp(6)

        SliderRow {
            Layout.fillWidth: true
            icon: (win && win.sink && win.sink.audio.muted) ? "volume_off" : "volume_up"
            value: win && win.sink ? win.sink.audio.volume : 0
            onMoved: (v) => { if (win.sink) win.sink.audio.volume = v; }
            onIconClicked: { if (win.sink) win.sink.audio.muted = !win.sink.audio.muted; }
        }
    }

    // устройства вывода звука — одна связная группа
    Card {
        Layout.fillWidth: true
        title: "Вывод звука"

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            Repeater {
                id: outRep

                model: volumePage.audioState.sinks

                delegate: DeviceRow {
                    required property var modelData
                    required property int index

                    Layout.fillWidth: true
                    icon: volumePage.devIcon(modelData)
                    devName: modelData.description || modelData.name
                    position: volumePage.groupPos(index, outRep.count)
                    selected: volumePage.audioState.defaultSink === String(modelData.name)
                    onClicked: volumePage.setDefaultSink(modelData.id)
                }
            }

            LText {
                visible: outRep.count === 0
                Layout.fillWidth: true
                Layout.topMargin: Theme.dp(4)
                role: "bodySmall"
                color: Theme.subtextDim
                text: "Нет устройств вывода"
            }
        }
    }

    // устройства ввода — одна связная группа
    Card {
        Layout.fillWidth: true
        title: "Микрофон"

        RowLayout {
            visible: volumePage.defaultMic !== null
            Layout.fillWidth: true
            spacing: Theme.dp(4)

            SliderRow {
                Layout.fillWidth: true
                icon: "mic"
                value: volumePage.micVolumePct / 100
                onMoved: (v) => {
                    volumePage.isUserDragging = true;
                    volumePage.micVolumePct = Math.round(v * 100);
                    volumePage.setMicVolume(volumePage.micVolumePct);
                }
                onCommitted: (v) => {
                    volumePage.micVolumePct = Math.round(v * 100);
                    volumePage.setMicVolume(volumePage.micVolumePct);
                    volumePage.isUserDragging = false;
                    quickRefresh.restart();
                }
            }

            IconButton {
                Layout.alignment: Qt.AlignVCenter
                icon: volumePage.defaultMic && volumePage.defaultMic.mute ? "mic_off" : "mic"
                tooltip: volumePage.defaultMic && volumePage.defaultMic.mute ? "Включить микрофон" : "Выключить микрофон"
                onClicked: if (volumePage.defaultMic) volumePage.setMicMute(!volumePage.defaultMic.mute)
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            Repeater {
                id: inRep

                model: volumePage.audioState.sources

                delegate: DeviceRow {
                    required property var modelData
                    required property int index

                    Layout.fillWidth: true
                    icon: "mic"
                    devName: modelData.description || modelData.name
                    position: volumePage.groupPos(index, inRep.count)
                    selected: volumePage.audioState.defaultSource === String(modelData.name)
                    onClicked: volumePage.setDefaultSource(modelData.id)
                }
            }

            LText {
                visible: inRep.count === 0
                Layout.fillWidth: true
                Layout.topMargin: Theme.dp(4)
                role: "bodySmall"
                color: Theme.subtextDim
                text: "Нет устройств ввода"
            }
        }
    }

    // микшер sink-inputs (активные потоки playback) из pactl
    Card {
        Layout.fillWidth: true
        title: "Приложения"

        LText { // пустое состояние — карточка всегда на виду
            visible: volumePage.audioState.apps.length === 0
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(4)
            role: "bodySmall"
            color: Theme.subtextDim
            text: "Нет активных приложений"
        }

        Repeater {
            model: volumePage.audioState.apps

            delegate: Item {
                id: appRow

                required property var modelData
                property int currentVolumePct: Math.max(0, Math.min(100, Math.round(Number(modelData.volume) || 0)))
                readonly property bool isMuted: !!modelData.mute
                onModelDataChanged: currentVolumePct = Math.max(0, Math.min(100,
                    Math.round(Number(modelData.volume) || 0)))

                Layout.fillWidth: true
                implicitHeight: Theme.dp(56)

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.dp(8)
                    anchors.rightMargin: Theme.dp(8)
                    spacing: Theme.dp(10)

                    Rectangle { // иконка приложения 40×40
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: Theme.dp(40)
                        implicitHeight: Theme.dp(40)
                        radius: Theme.rad(12)
                        color: Theme.bgTrack

                        readonly property string iconPath: volumePage.iconFor(appRow.modelData)

                        Icon {
                            anchors.centerIn: parent
                            visible: parent.iconPath === ""
                            name: "graphic_eq"
                            size: Theme.dp(20)
                            color: Theme.subtext
                        }
                        AppIcon {
                            anchors.centerIn: parent
                            visible: parent.iconPath !== ""
                            source: parent.iconPath
                            size: Theme.dp(22)
                        }
                    }

                    ColumnLayout {
                        Layout.preferredWidth: Theme.dp(92)
                        Layout.alignment: Qt.AlignVCenter
                        spacing: Theme.dp(1)

                        LText {
                            Layout.fillWidth: true
                            role: "bodyLarge"
                            weight: 480
                            color: Theme.text
                            elide: Text.ElideRight
                            text: volumePage.streamName(appRow.modelData)
                        }

                        LText {
                            Layout.fillWidth: true
                            visible: appRow.isMuted
                            role: "bodySmall"
                            color: Theme.subtext
                            text: "Без звука"
                        }
                    }

                    Slider {
                        Layout.fillWidth: true
                        size: "s"
                        from: 0
                        to: 1
                        value: appRow.currentVolumePct / 100
                        onMoved: (v) => {
                            volumePage.isUserDragging = true;
                            appRow.currentVolumePct = Math.round(v * 100);
                            volumePage.setAppVolume(appRow.modelData.index, appRow.currentVolumePct);
                        }
                        onCommitted: (v) => {
                            appRow.currentVolumePct = Math.round(v * 100);
                            volumePage.setAppVolume(appRow.modelData.index, appRow.currentVolumePct);
                            volumePage.isUserDragging = false;
                            quickRefresh.restart();
                        }
                        onDraggingChanged: {
                            volumePage.isUserDragging = dragging;
                            if (!dragging) quickRefresh.restart();
                        }
                    }

                    LText {
                        Layout.preferredWidth: Theme.dp(34)
                        Layout.alignment: Qt.AlignVCenter
                        horizontalAlignment: Text.AlignRight
                        role: "bodySmall"
                        tabular: true
                        color: Theme.subtext
                        text: appRow.currentVolumePct + "%"
                    }

                    IconButton {
                        Layout.alignment: Qt.AlignVCenter
                        size: "s"
                        icon: appRow.isMuted ? "volume_off" : "volume_up"
                        onClicked: volumePage.toggleAppMute(appRow.modelData.index)
                    }
                }
            }
        }
    }

    // громкость захватывающих приложений (capture: isStream && !isSink)
    Card {
        Layout.fillWidth: true
        title: "Микрофоны"

        LText { // пустое состояние — карточка всегда на виду
            visible: volumePage.captureStreams.length === 0
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(4)
            role: "bodySmall"
            color: Theme.subtextDim
            text: "Нет активных микрофонов"
        }

        Repeater {
            model: volumePage.captureStreams

            delegate: Item {
                required property var modelData

                Layout.fillWidth: true
                implicitHeight: Theme.dp(56)

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.dp(8)
                    anchors.rightMargin: Theme.dp(8)
                    spacing: Theme.dp(10)

                    Rectangle { // иконка приложения 40×40
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: Theme.dp(40)
                        implicitHeight: Theme.dp(40)
                        radius: Theme.rad(12)
                        color: Theme.bgTrack

                        readonly property string iconPath: volumePage.iconFor(modelData)

                        Icon {
                            anchors.centerIn: parent
                            visible: parent.iconPath === ""
                            name: "graphic_eq"
                            size: Theme.dp(20)
                            color: Theme.subtext
                        }
                        AppIcon {
                            anchors.centerIn: parent
                            visible: parent.iconPath !== ""
                            source: parent.iconPath
                            size: Theme.dp(22)
                        }
                    }

                    ColumnLayout {
                        Layout.preferredWidth: Theme.dp(92)
                        Layout.alignment: Qt.AlignVCenter
                        spacing: Theme.dp(1)

                        LText {
                            Layout.fillWidth: true
                            role: "bodyLarge"
                            weight: 480
                            color: Theme.text
                            elide: Text.ElideRight
                            text: volumePage.streamName(modelData)
                        }

                        LText {
                            Layout.fillWidth: true
                            visible: !!(modelData.audio && modelData.audio.muted)
                            role: "bodySmall"
                            color: Theme.subtext
                            text: "Без звука"
                        }
                    }

                    Slider {
                        Layout.fillWidth: true
                        size: "s"
                        value: modelData.audio ? modelData.audio.volume : 0
                        onMoved: (v) => { if (modelData.audio) modelData.audio.volume = v; }
                        onCommitted: (v) => { if (modelData.audio) modelData.audio.volume = v; }
                    }

                    LText {
                        Layout.preferredWidth: Theme.dp(34)
                        Layout.alignment: Qt.AlignVCenter
                        horizontalAlignment: Text.AlignRight
                        role: "bodySmall"
                        tabular: true
                        color: Theme.subtext
                        text: modelData.audio ? Math.round(modelData.audio.volume * 100) + "%" : "0%"
                    }

                    IconButton {
                        Layout.alignment: Qt.AlignVCenter
                        size: "s"
                        icon: (modelData.audio && modelData.audio.muted) ? "volume_off" : "volume_up"
                        onClicked: { if (modelData.audio) modelData.audio.muted = !modelData.audio.muted; }
                    }
                }
            }
        }
    }

    Process {
        id: audioListProc
        command: ["bash", volumePage.scriptPath, "list"]
        stdout: SplitParser { onRead: line => volumePage.audioOutput += line + "\n" }
        onExited: (exitCode) => volumePage.finishAudioRefresh(exitCode)
    }

    Process {
        id: audioActionProc
        property var actionArgs: []
        command: ["bash", volumePage.scriptPath].concat(actionArgs)
        onExited: {
            volumePage.runNextAudioAction();
            if (!audioActionProc.running && volumePage.actionQueue.length === 0)
                quickRefresh.restart();
        }
    }

    Timer {
        id: audioRefreshTimer
        interval: 1000
        repeat: true
        running: volumePage.visible
        triggeredOnStart: true
        onTriggered: volumePage.refreshAudio()
    }

    Timer {
        id: quickRefresh
        interval: 150
        onTriggered: volumePage.refreshAudio()
    }
}
