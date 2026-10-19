import QtQuick
import Quickshell
import Quickshell.Wayland
import "../core"
import "../ui"

// Экран сессии (порт lucidsession/Session.qml): Заблокировать / Сон / Выйти /
// Перезагрузить / Выключить — каждый пункт на своей expressive-форме
// (M3 shape морфит к кругу, когда фокус уходит — тот же приём, что в
// ui/LoadingIndicator). У последних трёх двухшаговое подтверждение: первый
// Enter/клик «армит» — красная форма с кольцом-таймером 4с, второй выполняет.
// Сон выполняется сразу, без подтверждения. Проведение: shell.qml → IPC
// `oberon session`.
PanelWindow {
    id: ses

    signal closed()

    // шелл целиком (shell.qml root) — нужен для lock(): тот же путь, что у
    // IPC-функции oberon lock (root.lock устанавливает root.locked → Lockscreen)
    property var shell: null

    property bool shown: false

    // действие, ожидающее второго Enter
    property string armed: ""
    property int focusIndex: 0
    // от 1 к 0, пока действие «armed»
    property real armLeft: 0
    property real reveal: ses.shown ? 1 : 0

    readonly property var actions: [{
        "id": "lock",
        "label": "Заблокировать",
        "icon": "lock",
        "shape": "cookie4",
        "key": Qt.Key_L,
        "hint": "L"
    }, {
        "id": "suspend",
        "label": "Сон",
        "icon": "bedtime",
        "shape": "clover4",
        "key": Qt.Key_S,
        "hint": "S"
    }, {
        "id": "logout",
        "label": "Выйти",
        "icon": "logout",
        "shape": "pill",
        "key": Qt.Key_E,
        "hint": "E",
        "ask": "Выйти из сессии?"
    }, {
        "id": "reboot",
        "label": "Перезагрузить",
        "icon": "restart_alt",
        "shape": "cookie9",
        "key": Qt.Key_R,
        "hint": "R",
        "ask": "Перезагрузить сейчас?"
    }, {
        "id": "shutdown",
        "label": "Выключить",
        "icon": "power_settings_new",
        "shape": "sunny",
        "key": Qt.Key_P,
        "hint": "P",
        "ask": "Выключить сейчас?"
    }]

    function open() {
        ses.armed = "";
        ses.focusIndex = 0;
        ses.shown = true;
    }

    function close() {
        ses.shown = false;
        ses.armed = "";
    }

    function press(i) {
        const a = ses.actions[i];
        if (!a) return;
        ses.focusIndex = i;
        if (a.ask && ses.armed !== a.id) {
            ses.armed = a.id;
            disarm.restart();
            armAnim.restart();
            return;
        }
        // убрать экран до того, как сессия/блокировка вступят в силу
        ses.close();
        if (a.id === "lock") {
            if (ses.shell && ses.shell.lock) ses.shell.lock();
            else console.warn("SessionScreen: shell не задан, lock() пропущен");
            return;
        }
        runLater.pending = a.id;
        runLater.restart();
    }

    onShownChanged: {
        if (ses.shown) stage.forceActiveFocus();
        else closed();
    }

    visible: ses.shown || ses.reveal > 0.01
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "oberon-session"
    WlrLayershell.keyboardFocus: ses.shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Behavior on reveal {
        NumberAnimation {
            duration: ses.shown ? Theme.durDefaultSpatial : Theme.durFastEffects
            easing.type: Easing.Bezier
            easing.bezierCurve: Theme.curveDefaultSpatial
        }
    }

    NumberAnimation {
        id: armAnim
        target: ses
        property: "armLeft"
        from: 1
        to: 0
        duration: disarm.interval
    }

    Timer {
        id: disarm
        interval: 4000
        onTriggered: ses.armed = ""
    }

    // пусть экран успеет убрать сам себя до действия
    Timer {
        id: runLater
        property string pending: ""
        interval: 260
        onTriggered: {
            const id = runLater.pending;
            if (id === "logout") Sys.logout();
            else if (id === "reboot") Sys.reboot();
            else if (id === "shutdown") Sys.poweroff();
            else if (id === "suspend") Sys.suspend();
        }
    }

    Item {
        id: stage
        anchors.fill: parent
        focus: ses.shown
        opacity: Math.min(1, ses.reveal * 1.4)

        Keys.onPressed: (event) => {
            if (!ses.shown) { event.accepted = true; return; }
            if (event.key === Qt.Key_Escape) {
                if (ses.armed !== "") ses.armed = "";
                else ses.close();
            } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up ||
                       event.key === Qt.Key_Backtab ||
                       (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
                ses.focusIndex = (ses.focusIndex + ses.actions.length - 1) % ses.actions.length;
                ses.armed = "";
            } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
                ses.focusIndex = (ses.focusIndex + 1) % ses.actions.length;
                ses.armed = "";
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                ses.press(ses.focusIndex);
            } else {
                for (let i = 0; i < ses.actions.length; i++) {
                    if (ses.actions[i].key === event.key) { ses.press(i); break; }
                }
            }
            event.accepted = true;
        }

        // затемнение; клик мимо формы закрывает
        Rectangle {
            anchors.fill: parent
            color: Theme.alpha(Theme.cScrim, Theme.blurPct > 0 ? 0.42 : 0.72)
            opacity: ses.reveal

            MouseArea {
                anchors.fill: parent
                onClicked: ses.close()
            }
        }

        Column {
            anchors.centerIn: parent
            spacing: Theme.dp(44)

            Column {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.dp(6)
                transform: Translate { y: (1 - ses.reveal) * -Theme.dp(24) }

                LText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    role: "displayMedium"
                    weight: 560
                    rounded: 100
                    color: "white"
                    text: {
                        if (ses.armed === "") return "До скорой, " + (Quickshell.env("USER") || "user");
                        for (const a of ses.actions)
                            if (a.id === ses.armed) return a.ask;
                        return "";
                    }
                }

                LText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    role: "titleMedium"
                    color: Qt.rgba(1, 1, 1, 0.72)
                    text: ses.armed !== "" ? "Нажмите ещё раз, чтобы продолжить, Esc — остаться" : "Что делаем с этой сессией?"
                }
            }

            Flow {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.max(0, Math.min(stage.width - Theme.dp(48), Theme.dp(792)))
                spacing: Theme.dp(28)

                Repeater {
                    model: ses.actions

                    Item {
                        id: tile

                        required property var modelData
                        required property int index
                        readonly property bool focused: ses.focusIndex === tile.index
                        readonly property bool isArmed: ses.armed === tile.modelData.id
                        readonly property bool hot: tile.focused || tap.containsMouse
                        // каждая форма плывёт на место с опережением по номеру
                        readonly property real enter: Math.max(0, Math.min(1, ses.reveal * 1.6 - tile.index * 0.12))

                        width: Theme.dp(136)
                        height: Theme.dp(136) + Theme.dp(44)
                        opacity: tile.enter
                        transform: Translate { y: (1 - tile.enter) * 60 }

                        MaterialShape {
                            id: blob

                            anchors.horizontalCenter: parent.horizontalCenter
                            width: Theme.dp(136)
                            height: Theme.dp(136)
                            shape: tile.modelData.shape
                            to: "circle"
                            // не в фокусе — тянется к кругу; armed — к чистому
                            // кругу и красному кольцу
                            morph: tile.isArmed ? 0 : (tile.hot ? 0.0 : 0.55)
                            color: tile.isArmed ? Theme.error : (tile.hot ? Theme.primary : Theme.mHighest)
                            rotation: tile.isArmed ? 360 : (tile.hot ? 22 : 0)
                            scale: tap.pressed ? 0.92 : (tile.hot ? 1.06 : 1)

                            Behavior on morph {
                                NumberAnimation {
                                    duration: Theme.durDefaultSpatial
                                    easing.type: Easing.Bezier
                                    easing.bezierCurve: Theme.curveDefaultSpatial
                                }
                            }

                            Behavior on rotation {
                                NumberAnimation {
                                    duration: tile.isArmed ? Theme.ms(900) : Theme.durSlowSpatial
                                    easing.type: Easing.Bezier
                                    easing.bezierCurve: Theme.curveDefaultSpatial
                                }
                            }

                            Behavior on scale {
                                NumberAnimation {
                                    duration: Theme.durFastSpatial
                                    easing.type: Easing.Bezier
                                    easing.bezierCurve: Theme.curveFastSpatial
                                }
                            }

                            Behavior on color { ColorAnimation { duration: Theme.durDefaultEffects } }
                        }

                        Icon {
                            anchors.centerIn: blob
                            name: tile.modelData.icon
                            size: Theme.dp(46)
                            color: tile.isArmed ? Theme.fgError : (tile.hot ? Theme.fgPrimary : Theme.text)
                        }

                        // кольцо обратного отсчёта арма
                        CircularProgress {
                            visible: tile.isArmed
                            anchors.centerIn: blob
                            width: Theme.dp(156)
                            height: Theme.dp(156)
                            thickness: Theme.dp(4)
                            showTrack: false
                            animated: false
                            wavy: false
                            color: Theme.error
                            value: ses.armLeft
                        }

                        Column {
                            anchors.top: blob.bottom
                            anchors.topMargin: Theme.dp(14)
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: Theme.dp(2)

                            LText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                role: "titleMedium"
                                weight: tile.hot ? 640 : 500
                                color: "white"
                                text: tile.modelData.label
                            }

                            LText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                role: "labelSmall"
                                color: Qt.rgba(1, 1, 1, 0.5)
                                text: tile.modelData.hint
                            }
                        }

                        MouseArea {
                            id: tap
                            anchors.fill: blob
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: {
                                if (ses.focusIndex !== tile.index) {
                                    ses.focusIndex = tile.index;
                                    if (ses.armed !== tile.modelData.id) ses.armed = "";
                                }
                            }
                            onClicked: ses.press(tile.index)
                        }
                    }
                }
            }

            LText {
                anchors.horizontalCenter: parent.horizontalCenter
                role: "labelLarge"
                color: Qt.rgba(1, 1, 1, 0.5)
                text: "← → — выбор  ·  Enter — выполнить  ·  Esc — закрыть"
            }
        }
    }
}
