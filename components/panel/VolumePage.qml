pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import "../../core"
import "../../ui"
import ".."

// Звук: Lucid-анатомия control-centre — мастер-слайдер, устройства вывода/ввода
// как связные группы DeviceRow (стыкующиеся углы, spacing 0, один Card на
// группу), приложения и микрофоны отдельными карточками со строками.
ColumnLayout {
    id: volumePage

    property var win: null

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
        const direct = p["application.icon.name"];
        if (direct) {
            const dp = Quickshell.iconPath(String(direct), true);
            if (dp !== "") return dp;
        }
        const ix = volumePage.iconIndex;
        const keys = [p["application.name"], p["application.process.binary"],
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
        return p["application.name"] || n.description || n.name || "";
    }

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

    // playback-потоки: isStream && isSink; capture-потоки: isStream && !isSink
    readonly property var playbackStreams: {
        const out = [];
        const ss = volumePage.win ? volumePage.win.streams : null;
        if (!ss) return out;
        for (const n of ss) if (n.isSink) out.push(n);
        return out;
    }
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

                model: volumePage.win ? volumePage.win.outputs : []

                delegate: DeviceRow {
                    required property var modelData
                    required property int index

                    Layout.fillWidth: true
                    icon: volumePage.devIcon(modelData)
                    devName: modelData.description || modelData.name
                    position: volumePage.groupPos(index, outRep.count)
                    selected: !!(volumePage.win && volumePage.win.sink && volumePage.win.sink.id === modelData.id)
                    onClicked: Sys.setDefaultAudio(modelData.id)
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

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            Repeater {
                id: inRep

                model: volumePage.win ? volumePage.win.inputs : []

                delegate: DeviceRow {
                    required property var modelData
                    required property int index

                    Layout.fillWidth: true
                    icon: "mic"
                    devName: modelData.description || modelData.name
                    position: volumePage.groupPos(index, inRep.count)
                    selected: !!(volumePage.win && volumePage.win.source && volumePage.win.source.id === modelData.id)
                    onClicked: Sys.setDefaultAudio(modelData.id)
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

    // громкость воспроизводящих приложений (playback: isStream && isSink)
    Card {
        Layout.fillWidth: true
        title: "Приложения"

        LText { // пустое состояние — карточка всегда на виду
            visible: volumePage.playbackStreams.length === 0
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(4)
            role: "bodySmall"
            color: Theme.subtextDim
            text: "Ничего не воспроизводится"
        }

        Repeater {
            model: volumePage.playbackStreams

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
}
