import QtQuick
import Quickshell
import "../core"
import "../ui"

// Содержимое острова для idle/osd/notif. Внешнюю капсулу (фон Theme.bg,
// рамку, радиус) рисует сам Island, поэтому своего общего фона здесь нет:
// idle — ряд чипов [раскладка][погода][воркспейсы][часы][трей] в порядке
// Prefs-ключа islandOrder (нет ключа/не массив — дефолтный порядок),
// osd/notif — строки. API: mode/now/output/shell/tipHost.
Item {
    id: holder
    property string mode: "idle"
    property date now: new Date()
    property string output: ""
    property var shell: null
    // Тултип-хост (Island): объект с showTip(hoverItem, text)/hideTip(hoverItem)
    property var tipHost: null
    // Порядок чипов (islandOrder), приходит из Island; null/не массив → дефолт
    property var orderProp: null

    implicitWidth: mode === "notif" ? notifRow.implicitWidth
                 : mode === "osd" ? osdRow.implicitWidth
                 : idleRow.implicitWidth
    // notif ≥40 — тосту не тесно; osd 34, idle 28 (остров = +6)
    implicitHeight: mode === "notif" ? Math.max(Theme.dp(40), notifRow.implicitHeight)
                  : mode === "osd" ? Theme.dp(34)
                  : Theme.dp(28)

    // ── порядок чипов: islandOrder (id: kb/weather/ws/clock/go/tray) ──────
    // ВАЖНО: JsonAdapter отдаёт QVariantList, а не JS-Array — Array.isArray
    // для него false, поэтому копируем по length и фильтруем по типу.
    readonly property var defaultOrder: ["kb", "weather", "ws", "clock", "go", "tray"]
    readonly property var orderRaw: holder.orderProp
    readonly property var order: {
        const allowed = holder.defaultOrder;
        const raw = holder.orderRaw;
        const out = [];
        if (raw && typeof raw.length === "number") {
            for (let i = 0; i < raw.length; i++) {
                const id = raw[i];
                if (typeof id === "string" && allowed.includes(id) && !out.includes(id))
                    out.push(id);
            }
        }
        for (const id of allowed)
            if (!out.includes(id)) out.push(id);
        return out;
    }

    function tip(item, text) { if (holder.tipHost) holder.tipHost.showTip(item, text); }
    function untip(item)     { if (holder.tipHost) holder.tipHost.hideTip(item); }

    // ── idle: чипы в порядке islandOrder ───────────────────────────────
    // Чипы — Lucid-пилюли: без обводок, заливка ролью (bgTile/accent),
    // взаимодействие — StateLayer. Высота 24 внутри 28-полосы idle.
    // Ховер: плитка слегка вырастает (шириной 4dp), сам Item не меняется —
    // layout ряда не дрожит. Нажатие — прежнее сжатие 0.96.
    Component { id: kbChip
        Item {
            id: layoutChip
            visible: Umbriel.keyboardLayout !== "" && Prefs.islandLayout
            implicitWidth: layoutText.implicitWidth + Theme.dp(18)
            implicitHeight: Theme.dp(24)
            scale: layoutArea.pressed ? 0.96 : 1

            Behavior on scale {
                NumberAnimation {
                    duration: Theme.durFastEffects
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Theme.curveFastSpatial
                }
            }

            // растёт только фон, контент стоит на месте
            property real grow: layoutArea.containsMouse ? Theme.dp(4) : 0
            Behavior on grow {
                NumberAnimation {
                    duration: Theme.durFastEffects
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Theme.curveFastSpatial
                }
            }

            Rectangle {
                x: -layoutChip.grow / 2
                y: -layoutChip.grow / 2
                width: parent.width + layoutChip.grow
                height: parent.height + layoutChip.grow
                radius: Theme.radiusPill
                color: Theme.bgTile
                StateLayer {
                    id: layoutArea
                    radius: parent.radius
                    onEntered: holder.tip(layoutArea, "Раскладка клавиатуры — клик, чтобы сменить")
                    onExited: holder.untip(layoutArea)
                    onClicked: Quickshell.execDetached(["umbriel", "msg", "keyboard-layout-next"])
                }
            }

            LText {
                id: layoutText
                anchors.centerIn: parent
                role: "labelMedium"
                color: Theme.subtext
                text: Umbriel.keyboardLayout
                font.capitalization: Font.AllUppercase
            }
        }
    }

    Component { id: weatherChip
        Item {
            id: weatherOuter
            visible: Prefs.islandWeather
            implicitWidth: weatherRow.implicitWidth + Theme.dp(18)
            implicitHeight: Theme.dp(24)
            scale: weatherArea.pressed ? 0.96 : 1

            Behavior on scale {
                NumberAnimation {
                    duration: Theme.durFastEffects
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Theme.curveFastSpatial
                }
            }

            property real grow: weatherArea.containsMouse ? Theme.dp(4) : 0
            Behavior on grow {
                NumberAnimation {
                    duration: Theme.durFastEffects
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Theme.curveFastSpatial
                }
            }

            // status: "data" | "loading" | "error"
            readonly property string status: Weather.hasData && isFinite(Weather.temp) ? "data"
                : Weather.loading ? "loading" : "error"

            Rectangle {
                x: -weatherOuter.grow / 2
                y: -weatherOuter.grow / 2
                width: parent.width + weatherOuter.grow
                height: parent.height + weatherOuter.grow
                radius: Theme.radiusPill
                color: Theme.bgTile
                StateLayer {
                    id: weatherArea
                    radius: parent.radius
                    onEntered: holder.tip(weatherArea, weatherOuter.status === "data" ? "Погода: " + Weather.place : "Погода: " + (weatherOuter.status === "loading" ? "загрузка…" : "нет данных"))
                    onExited: holder.untip(weatherArea)
                    onClicked: if (holder.shell && weatherOuter.status === "data") holder.shell.setTab("weather")
                }
            }

            Row {
                id: weatherRow
                anchors.centerIn: parent
                spacing: Theme.dp(4)

                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: weatherOuter.status === "data" ? Weather.icon : "cloud"
                    size: Theme.dp(14)
                    color: Theme.primary
                }

                LText {
                    anchors.verticalCenter: parent.verticalCenter
                    role: "labelLarge"
                    tabular: true
                    color: Theme.text
                    text: weatherOuter.status === "data" ? Math.round(Weather.temp) + "°" : (weatherOuter.status === "loading" ? "..." : "—")
                }
            }
        }
    }

    Component { id: wsChip
        WorkspacesRow {
            id: wsRow
            output: holder.output
            visible: Prefs.islandWorkspaces
            tipHost: holder.tipHost
        }
    }

    Component { id: clockChip
        Item {
            id: clockOuter
            visible: Prefs.islandClock
            implicitWidth: clockText.implicitWidth + Theme.dp(20)
            implicitHeight: Theme.dp(24)
            scale: clockArea.pressed ? 0.96 : 1

            Behavior on scale {
                NumberAnimation {
                    duration: Theme.durFastEffects
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Theme.curveFastSpatial
                }
            }

            property real grow: clockArea.containsMouse ? Theme.dp(4) : 0
            Behavior on grow {
                NumberAnimation {
                    duration: Theme.durFastEffects
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Theme.curveFastSpatial
                }
            }

            Rectangle {
                x: -clockOuter.grow / 2
                y: -clockOuter.grow / 2
                width: parent.width + clockOuter.grow
                height: parent.height + clockOuter.grow
                radius: Theme.radiusPill
                color: Theme.primary
                StateLayer {
                    id: clockArea
                    radius: parent.radius
                    tint: Theme.fgAccent
                    onEntered: holder.tip(clockArea, "Часы — клик, чтобы открыть календарь")
                    onExited: holder.untip(clockArea)
                    onClicked: if (holder.shell) holder.shell.setTab("calendar")
                }
            }

            LText {
                id: clockText
                anchors.centerIn: parent
                anchors.verticalCenterOffset: Math.round(Theme.digitCenterOffset * size)
                role: "labelLarge"
                weight: 700
                rounded: 100
                tabular: true
                color: Theme.fgAccent
                text: Qt.formatDateTime(holder.now, Prefs.clock12
                    ? (Prefs.clockSeconds ? "h:mm:ss AP" : "h:mm AP")
                    : (Prefs.clockSeconds ? "HH:mm:ss" : "HH:mm"))
            }
        }
    }

    Component { id: goChip
        Item {
            id: goOuter
            visible: Prefs.islandGo
            implicitWidth: goRow.implicitWidth + Theme.dp(18)
            implicitHeight: Theme.dp(24)
            scale: goArea.pressed ? 0.96 : 1

            readonly property var chipInfo: GoUsage.chipOut(Prefs.goChipMode)
            readonly property bool warn: Boolean(goOuter.chipInfo && goOuter.chipInfo.warn)
            readonly property bool isErr: Boolean(goOuter.chipInfo && goOuter.chipInfo.tone === "error")

            Behavior on scale {
                NumberAnimation {
                    duration: Theme.durFastEffects
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Theme.curveFastSpatial
                }
            }

            property real grow: goArea.containsMouse ? Theme.dp(4) : 0
            Behavior on grow {
                NumberAnimation {
                    duration: Theme.durFastEffects
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Theme.curveFastSpatial
                }
            }

            Rectangle {
                x: -goOuter.grow / 2
                y: -goOuter.grow / 2
                width: parent.width + goOuter.grow
                height: parent.height + goOuter.grow
                radius: Theme.radiusPill
                color: Theme.bgTile
                StateLayer {
                    id: goArea
                    radius: parent.radius
                    onEntered: holder.tip(goArea, goOuter.chipInfo && goOuter.chipInfo.tip
                        ? goOuter.chipInfo.tip
                        : "OpenCode — клик, чтобы открыть лимиты")
                    onExited: holder.untip(goArea)
                    onClicked: if (holder.shell) holder.shell.setPage("opencode")
                }
            }

            Row {
                id: goRow
                anchors.centerIn: parent
                spacing: Theme.dp(4)

                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "bolt"
                    size: Theme.dp(14)
                    color: goOuter.isErr ? Theme.error : (goOuter.warn ? Theme.warning : Theme.primary)
                }

                LText {
                    anchors.verticalCenter: parent.verticalCenter
                    role: "labelLarge"
                    tabular: true
                    color: goOuter.isErr ? Theme.error : (goOuter.warn ? Theme.warning : Theme.text)
                    text: goOuter.chipInfo ? goOuter.chipInfo.text : "GO"
                }
            }
        }
    }

    Component { id: trayChip
        // Системный трей — правый край idle-ряда (как чип). Ширину берём с
        // содержимого: на пустом трее она 0 и капсула не занимает места.
        Loader {
            id: trayLoader
            source: "TrayRow.qml"
            active: Prefs.islandTray
            width: item ? item.implicitWidth : 0
            visible: width > 0
            // клик по капсуле открывает вид острова «трей»
            Binding { target: trayLoader.item; property: "shell"; value: holder.shell; when: trayLoader.item !== null }
            Binding { target: trayLoader.item; property: "tipHost"; value: holder.tipHost; when: trayLoader.item !== null }
        }
    }

    Row {
        id: idleRow
        visible: holder.mode === "idle"
        anchors.centerIn: parent
        spacing: Theme.dp(6)

        Repeater {
            id: chipRepeater
            model: holder.order

            delegate: Loader {
                id: chipLoader
                required property string modelData
                anchors.verticalCenter: parent.verticalCenter
                visible: chipLoader.modelData === "kb" ? (Umbriel.keyboardLayout !== "" && Prefs.islandLayout)
                       : chipLoader.modelData === "weather" ? Prefs.islandWeather
                       : chipLoader.modelData === "ws" ? Prefs.islandWorkspaces
                       : chipLoader.modelData === "clock" ? Prefs.islandClock
                       : chipLoader.modelData === "go" ? Prefs.islandGo
                       : Prefs.islandTray
                // id Component'ов не свойства — ссылаемся напрямую по id
                sourceComponent: chipLoader.modelData === "kb" ? kbChip
                               : chipLoader.modelData === "weather" ? weatherChip
                               : chipLoader.modelData === "ws" ? wsChip
                               : chipLoader.modelData === "clock" ? clockChip
                               : chipLoader.modelData === "go" ? goChip
                               : trayChip
            }
        }
    }

    // ── OSD: только содержимое, фон рисует Island ─────────────────────
    OsdRow {
        id: osdRow
        visible: holder.mode === "osd"
        anchors.centerIn: parent
        kind: Osd.kind
        value: Osd.value
        muted: Osd.muted
    }

    // ── Уведомление: только содержимое, фон рисует Island ─────────────
    NotifToastRow {
        id: notifRow
        visible: holder.mode === "notif"
        anchors.centerIn: parent
        current: Notif.current
    }
}
