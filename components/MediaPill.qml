import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import QtQuick.Effects
import Quickshell.Wayland
import "../core"
import "../ui"

// Отдельный медиа-островок в левом верхнем углу экрана: есть плеер — виден,
// нет — скрыт. Компактное лицо модуля медиа из Lucid: обложка, название и
// исполнитель, кнопка play/pause. API прежний: modelData (экран).
PanelWindow {
    id: mp

    required property var modelData

    screen: modelData
    color: "transparent"
    anchors { top: true; left: true }
    implicitWidth: Theme.dp(420)
    implicitHeight: Theme.dp(84)
    // отступ слева как у окон (layout gap 7): визуальный край пилюли = 7px
    readonly property int padH: Theme.dp(26)
    // Umbriel сам сдвигает top-слой на зарезервированную островом полосу —
    // компенсируем её, чтобы пилюля встала на одну линию с островом (6px)
    margins { top: Theme.dp(6) - Theme.topReserve - Theme.dp(4); left: Theme.dp(7) - mp.padH }
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "oberon-media"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    readonly property var player: {
        const ps = Mpris.players.values;
        if (!ps || ps.length === 0)
            return null;
        for (const p of ps)
            if (p.isPlaying)
                return p;
        return null;
    }
    readonly property bool playing: mp.player && mp.player.isPlaying === true
    readonly property bool fullscreenActive: mp.screen
        ? Umbriel.fullscreenFor(mp.screen.name) : false
    readonly property bool isActiveOutput: !mp.screen || Umbriel.activeOutput === ""
        || mp.screen.name === Umbriel.activeOutput
    readonly property int vizBars: 7
    readonly property string cavaUid: "pill-" + (mp.screen ? mp.screen.name : "s")

    // спрос cava живёт вместе с окном: плеер ушёл / fullscreen — полосы отданы
    Component.onCompleted: if (mp.visible) Cava.want(mp.cavaUid, mp.vizBars)
    onVisibleChanged: {
        if (mp.visible)
            Cava.want(mp.cavaUid, mp.vizBars);
        else
            Cava.drop(mp.cavaUid);
    }
    onCavaUidChanged: if (mp.visible) Cava.want(mp.cavaUid, mp.vizBars)
    Component.onDestruction: Cava.drop(mp.cavaUid)

    visible: mp.playing && !mp.fullscreenActive && mp.isActiveOutput
    mask: Region { item: pill; radius: pill.radius }

    // тень как у острова: обёртка с запасом + layer.effect (MultiEffect)
    Item {
        id: shadowHost

        readonly property int padH: mp.padH
        readonly property int padTop: Theme.dp(4)
        readonly property int padBottom: Theme.dp(18)

        x: 0
        y: 0
        width: pill.width + padH * 2
        height: pill.height + padTop + padBottom
        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Theme.a(Theme.scrim, 0.68)
            shadowBlur: 0.9
            shadowVerticalOffset: Theme.dp(6)
            shadowOpacity: 1
        }

        Rectangle {
            id: pill

            x: shadowHost.padH
            y: shadowHost.padTop
            width: Theme.dp(300)
            // в размер облака: у острова капсула 34
            height: Theme.dp(34)
            radius: height / 2
            color: Theme.bg
            border.width: 1
            border.color: Theme.a(Theme.outline, 0.25)
            clip: true

            // фон-клик пилюли — play/pause (oberon-логика)
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: if (mp.player) mp.player.togglePlaying()
            }

            Row {
                anchors.fill: parent
                anchors.leftMargin: Theme.dp(5)
                anchors.rightMargin: Theme.dp(10)
                spacing: Theme.dp(8)

                Rectangle { // обложка dp(26), радиус rad(8)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.dp(26)
                    height: width
                    radius: width / 2
                    color: Theme.bgTrack
                    clip: true

                    Image {
                        id: artImg

                        anchors.fill: parent
                        fillMode: Image.PreserveAspectCrop
                        source: mp.player ? (mp.player.trackArtUrl || "") : ""
                        visible: status === Image.Ready
                    }

                    Icon { // заглушка без арта
                        anchors.centerIn: parent
                        visible: !artImg.visible
                        name: "music_note"
                        size: Theme.dp(15)
                        color: Theme.subtext
                    }
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Theme.dp(26) - Theme.dp(24) - Theme.dp(33) - Theme.dp(8) * 3
                    spacing: 0

                    Marquee {
                        width: parent.width
                        role: "labelLarge"
                        color: Theme.text
                        text: mp.player ? (mp.player.trackTitle || "") : ""
                    }

                    Marquee {
                        width: parent.width
                        visible: text !== ""
                        role: "labelSmall"
                        color: Theme.subtext
                        text: mp.player ? (mp.player.trackArtist || "") : ""
                    }
                }

                // мини-визуализатор cava: столбики снизу, при паузе прячется
                Item {
                    id: viz

                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.dp(33)
                    height: Theme.dp(16)

                    function barColor(level) {
                        // тишина — акцент-контейнер, бит — акцент
                        var f = 0.62;
                        var k = f + (1 - f) * Math.min(1, level * 1.25);
                        return Qt.rgba(
                            Theme.accentContainer.r * (1 - k) + Theme.accent.r * k,
                            Theme.accentContainer.g * (1 - k) + Theme.accent.g * k,
                            Theme.accentContainer.b * (1 - k) + Theme.accent.b * k, 1);
                    }

                    readonly property real slot: (viz.width - (mp.vizBars - 1) * Theme.dp(2)) / mp.vizBars

                    Row {
                        anchors.fill: parent
                        spacing: Theme.dp(2)

                        Repeater {
                            model: mp.vizBars

                            Rectangle {
                                required property int index

                                readonly property real level: (Cava.levels[index] !== undefined) ? Cava.levels[index] : 0

                                width: viz.slot
                                height: Math.min(viz.height, Math.max(width, level * viz.height))
                                anchors.bottom: parent.bottom
                                radius: width / 2
                                color: viz.barColor(level)

                                Behavior on height {
                                    NumberAnimation {
                                        duration: Theme.ms(70)
                                        easing.type: Easing.OutCubic
                                    }

                                }

                            }

                        }

                    }

                    opacity: mp.playing && Cava.running ? 1 : 0
                    Behavior on opacity {
                        NumberAnimation {
                            duration: Theme.durFastEffects
                            easing.type: Easing.OutCubic
                        }

                    }

                }

                // play/pause: залитая кнопка dp(24), круг → squircle при нажатии
                Rectangle {
                    id: playBtn

                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.dp(24)
                    height: width
                    radius: playArea.pressed ? Theme.rad(8) : width / 2
                    color: Theme.accent

                    Behavior on radius {
                        NumberAnimation {
                            duration: Theme.durFastSpatial
                            easing.type: Easing.Bezier
                            easing.bezierCurve: Theme.curveDefaultSpatial
                        }
                    }

                    Icon {
                        anchors.centerIn: parent
                        name: (mp.player && mp.player.isPlaying) ? "pause" : "play_arrow"
                        size: Theme.dp(14)
                        fill: 1
                        color: Theme.fgAccent
                    }

                    StateLayer {
                        id: playArea

                        radius: playBtn.radius
                        tint: Theme.fgAccent
                        onClicked: if (mp.player) mp.player.togglePlaying()
                    }
                }
            }
        }
    }
}
