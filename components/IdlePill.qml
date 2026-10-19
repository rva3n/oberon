import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.SystemTray
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
    property bool isVertical: false
    property var player: null
    property var battery: null
    property bool showBattery: false
    // Тултип-хост (Island): объект с showTip(hoverItem, text)/hideTip(hoverItem)
    property var tipHost: null
    // Порядок чипов (islandOrder), приходит из Island; null/не массив → дефолт
    property var orderProp: null

    implicitWidth: mode === "notif" ? notifRow.implicitWidth
                 : mode === "osd" ? osdRow.implicitWidth
                 : isVertical ? verticalColumn.implicitWidth : idleRow.implicitWidth
    // notif ≥40 — тосту не тесно; osd 34, idle 28 (остров = +6)
    implicitHeight: mode === "notif" ? Math.max(Theme.dp(40), notifRow.implicitHeight)
                   : mode === "osd" ? Theme.dp(34)
                   : isVertical ? verticalColumn.implicitHeight : Theme.dp(28)

    // Общие значения чипов вычисляются один раз и используются обеими
    // раскладками. Горизонтальный ряд сохраняет прежний состав и порядок.
    readonly property bool showLayout: Umbriel.keyboardLayout !== "" && Prefs.islandLayout
    readonly property string clockTime: Qt.formatDateTime(holder.now, Prefs.clock12
        ? (Prefs.clockSeconds ? "h:mm:ss AP" : "h:mm AP")
        : (Prefs.clockSeconds ? "HH:mm:ss" : "HH:mm"))
    readonly property string compactClockTime: Qt.formatDateTime(holder.now,
        Prefs.clock12 ? "h:mm" : "HH:mm")
    readonly property string dayLabel: holder.now.toLocaleDateString(Qt.locale("ru_RU"), "ddd")
    readonly property string weatherStatus: Weather.hasData && isFinite(Weather.temp) ? "data"
        : Weather.loading ? "loading" : "error"
    readonly property string weatherLabel: weatherStatus === "data" ? Math.round(Weather.temp) + "°"
        : weatherStatus === "loading" ? "..." : "—"
    readonly property string systemLoadLabel: SysStats.gpuLoadAvailable
        ? "C " + SysStats.cpuPercent + " G " + SysStats.gpuUsage
        : "C " + SysStats.cpuPercent + "%"
    readonly property string systemLoadTip: "Загрузка CPU: " + SysStats.cpuPercent + "%"
        + (SysStats.gpuLoadAvailable ? " · GPU: " + SysStats.gpuUsage + "%" : "")
    readonly property string mediaArt: holder.player ? String(holder.player.trackArtUrl || "") : ""
    readonly property string mediaTitle: holder.player ? String(holder.player.trackTitle || "") : ""
    readonly property int batteryPercent: {
        if (!holder.battery)
            return 0;
        const value = Number(holder.battery.percentage || 0);
        return Math.round(value <= 1 ? value * 100 : value);
    }
    readonly property bool batteryCharging: holder.battery
        ? String(holder.battery.iconName || "").indexOf("charging") !== -1
            || String(holder.battery.state || "").toLowerCase().indexOf("charging") !== -1
        : false
    readonly property var workspaceItems: Umbriel.workspacesFor(holder.output)
    readonly property var activeWorkspace: {
        const items = holder.workspaceItems || [];
        for (let i = 0; i < items.length; i++)
            if (items[i] && items[i].active) return items[i];
        return null;
    }
    readonly property string workspaceNumber: holder.activeWorkspace
        ? String(holder.activeWorkspace.index) : "—"
    readonly property var trayItems: {
        const items = SystemTray.items ? SystemTray.items.values : [];
        return items.filter((item) => item.status !== Status.Passive);
    }

    function resolveTrayIcon(raw) {
        if (!raw)
            return "";
        if (raw.startsWith("image://") || raw.startsWith("file://") || raw.startsWith("/"))
            return raw;
        const qIdx = raw.indexOf("?path=");
        if (qIdx !== -1) {
            const name = raw.substring(0, qIdx);
            const dir = raw.substring(qIdx + 6);
            return "file://" + dir + "/" + name.substring(name.lastIndexOf("/") + 1);
        }
        return Quickshell.iconPath(raw, true);
    }

    // ── порядок чипов: islandOrder (id: kb/weather/ws/clock/tray) ──────
    // ВАЖНО: JsonAdapter отдаёт QVariantList, а не JS-Array — Array.isArray
    // для него false, поэтому копируем по length и фильтруем по типу.
    readonly property var defaultOrder: ["kb", "weather", "ws", "clock", "term", "ai", "tray"]
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
    readonly property var idleOrder: {
        const out = holder.order.slice();
        const clockAt = out.indexOf("clock");
        const trayAt = out.indexOf("tray");
        let insertAt = clockAt >= 0 ? clockAt + 1 : (trayAt >= 0 ? trayAt : out.length);
        if (trayAt >= 0 && clockAt >= trayAt)
            insertAt = trayAt;
        out.splice(insertAt, 0, "system");
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
            visible: holder.showLayout
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
            readonly property string status: holder.weatherStatus

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
                    text: holder.weatherLabel
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
                text: holder.clockTime
            }
        }
    }

    Component { id: systemLoadChip
        Item {
            id: systemLoadOuter
            visible: Prefs.systemLoadOnIsland
            implicitWidth: systemLoadText.implicitWidth + Theme.dp(18)
            implicitHeight: Theme.dp(24)
            scale: systemLoadArea.pressed ? 0.96 : 1

            Behavior on scale {
                NumberAnimation {
                    duration: Theme.durFastEffects
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Theme.curveFastSpatial
                }
            }

            property real grow: systemLoadArea.containsMouse ? Theme.dp(4) : 0
            Behavior on grow {
                NumberAnimation {
                    duration: Theme.durFastEffects
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Theme.curveFastSpatial
                }
            }

            Rectangle {
                x: -systemLoadOuter.grow / 2
                y: -systemLoadOuter.grow / 2
                width: parent.width + systemLoadOuter.grow
                height: parent.height + systemLoadOuter.grow
                radius: Theme.radiusPill
                color: Theme.bgTile
                StateLayer {
                    id: systemLoadArea
                    radius: parent.radius
                    onEntered: holder.tip(systemLoadArea, holder.systemLoadTip + " — клик, чтобы открыть диспетчер задач")
                    onExited: holder.untip(systemLoadArea)
                    onClicked: if (holder.shell) holder.shell.taskman()
                }
            }

            LText {
                id: systemLoadText
                anchors.centerIn: parent
                role: "labelLarge"
                tabular: true
                color: Theme.text
                text: holder.systemLoadLabel
            }
        }
    }

    Component { id: termChip
        Item {
            id: termOuter
            visible: Prefs.islandTerminal
            implicitWidth: Theme.dp(28)
            implicitHeight: Theme.dp(24)
            scale: termArea.pressed ? 0.96 : 1

            Behavior on scale {
                NumberAnimation {
                    duration: Theme.durFastEffects
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Theme.curveFastSpatial
                }
            }

            property real grow: termArea.containsMouse ? Theme.dp(4) : 0
            Behavior on grow {
                NumberAnimation {
                    duration: Theme.durFastEffects
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Theme.curveFastSpatial
                }
            }

            Rectangle {
                x: -termOuter.grow / 2
                y: -termOuter.grow / 2
                width: parent.width + termOuter.grow
                height: parent.height + termOuter.grow
                radius: Theme.radiusPill
                color: Theme.bgTile
                StateLayer {
                    id: termArea
                    radius: parent.radius
                    onEntered: holder.tip(termArea, "Терминал — клик, чтобы открыть")
                    onExited: holder.untip(termArea)
                    onClicked: if (holder.shell) holder.shell.toggleTerminal()
                }
            }

            Icon {
                anchors.centerIn: parent
                name: "terminal"
                size: Theme.dp(15)
                color: Theme.primary
            }
        }
    }

    Component { id: aiChip
        Item {
            id: aiOuter
            visible: Prefs.islandAi
            implicitWidth: Theme.dp(28)
            implicitHeight: Theme.dp(24)
            scale: aiArea.pressed ? 0.96 : 1

            Behavior on scale {
                NumberAnimation {
                    duration: Theme.durFastEffects
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Theme.curveFastSpatial
                }
            }

            property real grow: aiArea.containsMouse ? Theme.dp(4) : 0
            Behavior on grow {
                NumberAnimation {
                    duration: Theme.durFastEffects
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Theme.curveFastSpatial
                }
            }

            Rectangle {
                x: -aiOuter.grow / 2
                y: -aiOuter.grow / 2
                width: parent.width + aiOuter.grow
                height: parent.height + aiOuter.grow
                radius: Theme.radiusPill
                color: Theme.bgTile
                StateLayer {
                    id: aiArea
                    radius: parent.radius
                    onEntered: holder.tip(aiArea, "ИИ-Ассистент — клик, чтобы открыть")
                    onExited: holder.untip(aiArea)
                    onClicked: if (holder.shell) holder.shell.toggleAi()
                }
            }

            Icon {
                anchors.centerIn: parent
                name: "auto_awesome"
                size: Theme.dp(15)
                color: Theme.primary
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
        visible: holder.mode === "idle" && !holder.isVertical
        anchors.centerIn: parent
        spacing: Theme.dp(6)

        Repeater {
            id: chipRepeater
            model: holder.idleOrder

            delegate: Loader {
                id: chipLoader
                required property string modelData
                anchors.verticalCenter: parent.verticalCenter
                visible: chipLoader.modelData === "kb" ? (Umbriel.keyboardLayout !== "" && Prefs.islandLayout)
                       : chipLoader.modelData === "weather" ? Prefs.islandWeather
                       : chipLoader.modelData === "ws" ? Prefs.islandWorkspaces
                       : chipLoader.modelData === "clock" ? Prefs.islandClock
                       : chipLoader.modelData === "term" ? Prefs.islandTerminal
                       : chipLoader.modelData === "ai" ? Prefs.islandAi
                       : chipLoader.modelData === "system" ? Prefs.systemLoadOnIsland
                       : Prefs.islandTray
                active: (chipLoader.modelData !== "system" || Prefs.systemLoadOnIsland)
                    && (chipLoader.modelData !== "term" || Prefs.islandTerminal)
                    && (chipLoader.modelData !== "ai" || Prefs.islandAi)
                // id Component'ов не свойства — ссылаемся напрямую по id
                sourceComponent: chipLoader.modelData === "kb" ? kbChip
                                : chipLoader.modelData === "weather" ? weatherChip
                                : chipLoader.modelData === "ws" ? wsChip
                                : chipLoader.modelData === "clock" ? clockChip
                                : chipLoader.modelData === "term" ? termChip
                                : chipLoader.modelData === "ai" ? aiChip
                                : chipLoader.modelData === "system" ? systemLoadChip
                                : trayChip
            }
        }
    }

    // У боковой кромки те же источники данных складываются столбиком. Список
    // намеренно компактный: подписи длинных чипов остаются в тултипах.
    readonly property var verticalOrder: ["media", "clock", "weather", "battery", "kb", "ws", "term", "ai", "system", "tray"]

    Component { id: verticalMediaChip
        Item {
            id: mediaChip
            implicitWidth: Theme.dp(26)
            implicitHeight: Theme.dp(26)
            scale: mediaArea.pressed ? 0.96 : 1

            Behavior on scale {
                NumberAnimation { duration: Theme.durFastEffects; easing.type: Easing.OutCubic }
            }

            Rectangle {
                id: artFrame
                anchors.centerIn: parent
                width: Theme.dp(24)
                height: Theme.dp(24)
                radius: Theme.rad(7)
                color: Theme.bgTile

                Image {
                    id: mediaArtImage
                    anchors.fill: parent
                    source: holder.mediaArt
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                    sourceSize.width: Theme.dp(64)
                    visible: false
                    layer.enabled: true
                }
                Item {
                    id: mediaArtMask
                    anchors.fill: parent
                    visible: false
                    layer.enabled: true
                    Rectangle { anchors.fill: parent; radius: artFrame.radius; color: "#ffffff" }
                }
                MultiEffect {
                    anchors.fill: parent
                    source: mediaArtImage
                    maskEnabled: true
                    maskSource: mediaArtMask
                    visible: mediaArtImage.status === Image.Ready
                }
                Icon {
                    anchors.centerIn: parent
                    name: "music_note"
                    size: Theme.dp(15)
                    color: Theme.subtext
                    visible: mediaArtImage.status !== Image.Ready
                }
                StateLayer {
                    id: mediaArea
                    anchors.fill: parent
                    radius: artFrame.radius
                    tint: Theme.primary
                    onEntered: holder.tip(mediaArea, holder.mediaTitle || "Медиа")
                    onExited: holder.untip(mediaArea)
                    onClicked: if (holder.shell) holder.shell.setPage("media")
                }
            }
        }
    }

    Component { id: verticalClockChip
        Item {
            id: verticalClock
            implicitWidth: clockColumn.implicitWidth
            implicitHeight: clockColumn.implicitHeight
            Column {
                id: clockColumn
                anchors.centerIn: parent
                spacing: -Theme.dp(1)

                LText {
                    id: verticalDay
                    anchors.horizontalCenter: parent.horizontalCenter
                    role: "labelSmall"
                    color: Theme.subtext
                    text: holder.dayLabel
                    font.capitalization: Font.AllUppercase
                }
                LText {
                    id: verticalTime
                    anchors.horizontalCenter: parent.horizontalCenter
                    role: "labelMedium"
                    weight: 700
                    rounded: 100
                    tabular: true
                    color: Theme.fgAccent
                    text: holder.compactClockTime
                }
            }
            StateLayer {
                id: verticalClockArea
                anchors.fill: verticalClock
                radius: Theme.radiusSm
                tint: Theme.fgAccent
                onEntered: holder.tip(verticalClockArea, "Часы — клик, чтобы открыть календарь")
                onExited: holder.untip(verticalClockArea)
                onClicked: if (holder.shell) holder.shell.setTab("calendar")
            }
        }
    }

    Component { id: verticalWeatherChip
        Item {
            id: verticalWeather
            implicitWidth: weatherColumn.implicitWidth
            implicitHeight: weatherColumn.implicitHeight
            Column {
                id: weatherColumn
                anchors.centerIn: parent
                spacing: 0
                Icon {
                    id: verticalWeatherIcon
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: holder.weatherStatus === "data" ? Weather.icon : "cloud"
                    size: Theme.dp(15)
                    color: Theme.primary
                }
                LText {
                    id: verticalWeatherValue
                    anchors.horizontalCenter: parent.horizontalCenter
                    role: "labelSmall"
                    tabular: true
                    color: Theme.text
                    text: holder.weatherLabel
                }
            }
            StateLayer {
                id: verticalWeatherArea
                anchors.fill: verticalWeather
                radius: Theme.radiusSm
                onEntered: holder.tip(verticalWeatherArea, holder.weatherStatus === "data"
                    ? "Погода: " + Weather.place
                    : "Погода: " + (holder.weatherStatus === "loading" ? "загрузка…" : "нет данных"))
                onExited: holder.untip(verticalWeatherArea)
                onClicked: if (holder.shell && holder.weatherStatus === "data") holder.shell.setTab("weather")
            }
        }
    }

    Component { id: verticalBatteryChip
        Item {
            id: verticalBattery
            implicitWidth: batteryColumn.implicitWidth
            implicitHeight: batteryColumn.implicitHeight
            Column {
                id: batteryColumn
                anchors.centerIn: parent
                spacing: 0
                Icon {
                    id: verticalBatteryIcon
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: holder.batteryCharging ? "battery_charging_full" : "battery_full"
                    size: Theme.dp(15)
                    color: holder.batteryPercent <= 15 ? Theme.error
                        : (holder.batteryPercent <= 30 ? Theme.warning : Theme.primary)
                }
                LText {
                    id: verticalBatteryValue
                    anchors.horizontalCenter: parent.horizontalCenter
                    role: "labelSmall"
                    tabular: true
                    color: verticalBatteryIcon.color
                    text: holder.batteryPercent + "%"
                }
            }
            StateLayer {
                id: verticalBatteryArea
                anchors.fill: verticalBattery
                radius: Theme.radiusSm
                onEntered: holder.tip(verticalBatteryArea, "Заряд батареи: " + holder.batteryPercent + "%")
                onExited: holder.untip(verticalBatteryArea)
            }
        }
    }

    Component { id: verticalSystemLoadChip
        Item {
            id: verticalSystemLoad
            implicitWidth: systemLoadColumn.implicitWidth
            implicitHeight: systemLoadColumn.implicitHeight

            Column {
                id: systemLoadColumn
                anchors.centerIn: parent
                spacing: -Theme.dp(1)

                LText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    role: "labelSmall"
                    tabular: true
                    color: Theme.text
                    text: "C " + SysStats.cpuPercent
                }
                LText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: SysStats.gpuLoadAvailable
                    role: "labelSmall"
                    tabular: true
                    color: Theme.subtext
                    text: "G " + SysStats.gpuUsage
                }
            }

            StateLayer {
                id: verticalSystemLoadArea
                anchors.fill: parent
                radius: Theme.radiusSm
                onEntered: holder.tip(verticalSystemLoadArea, holder.systemLoadTip + " — клик, чтобы открыть диспетчер задач")
                onExited: holder.untip(verticalSystemLoadArea)
                onClicked: if (holder.shell) holder.shell.taskman()
            }
        }
    }

    Component { id: verticalLayoutChip
        Item {
            implicitWidth: Theme.dp(26)
            implicitHeight: Theme.dp(24)

            Rectangle {
                anchors.fill: parent
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
                anchors.centerIn: parent
                role: "labelSmall"
                color: Theme.subtext
                text: Umbriel.keyboardLayout
                font.capitalization: Font.AllUppercase
            }
        }
    }

    Component { id: verticalWorkspaceChip
        Item {
            implicitWidth: Theme.dp(26)
            implicitHeight: Theme.dp(24)

            Rectangle {
                anchors.fill: parent
                radius: Theme.radiusPill
                color: Theme.bgTile
                StateLayer {
                    id: workspaceArea
                    radius: parent.radius
                    onEntered: holder.tip(workspaceArea, "Рабочий стол " + holder.workspaceNumber)
                    onExited: holder.untip(workspaceArea)
                    onClicked: if (holder.activeWorkspace)
                        Quickshell.execDetached(["umbriel", "msg", "workspace-switch:" + holder.activeWorkspace.index])
                }
            }
            LText {
                anchors.centerIn: parent
                role: "labelMedium"
                color: Theme.text
                text: holder.workspaceNumber
            }
        }
    }

    Component { id: verticalTermChip
        Item {
            visible: Prefs.islandTerminal
            implicitWidth: Theme.dp(26)
            implicitHeight: Theme.dp(24)

            Rectangle {
                anchors.fill: parent
                radius: Theme.radiusPill
                color: Theme.bgTile
                StateLayer {
                    id: verticalTermArea
                    radius: parent.radius
                    onEntered: holder.tip(verticalTermArea, "Терминал — клик, чтобы открыть")
                    onExited: holder.untip(verticalTermArea)
                    onClicked: if (holder.shell) holder.shell.toggleTerminal()
                }
            }
            Icon {
                anchors.centerIn: parent
                name: "terminal"
                size: Theme.dp(15)
                color: Theme.primary
            }
        }
    }

    Component { id: verticalAiChip
        Item {
            visible: Prefs.islandAi
            implicitWidth: Theme.dp(26)
            implicitHeight: Theme.dp(24)

            Rectangle {
                anchors.fill: parent
                radius: Theme.radiusPill
                color: Theme.bgTile
                StateLayer {
                    id: verticalAiArea
                    radius: parent.radius
                    onEntered: holder.tip(verticalAiArea, "ИИ-Ассистент — клик, чтобы открыть")
                    onExited: holder.untip(verticalAiArea)
                    onClicked: if (holder.shell) holder.shell.toggleAi()
                }
            }
            Icon {
                anchors.centerIn: parent
                name: "auto_awesome"
                size: Theme.dp(15)
                color: Theme.primary
            }
        }
    }

    Component { id: verticalTrayChip
        Item {
            id: verticalTray
            readonly property int shownCount: Math.min(3, holder.trayItems.length)
            implicitWidth: Theme.dp(24)
            implicitHeight: shownCount > 0
                ? shownCount * Theme.dp(18) + (shownCount - 1) * Theme.dp(2) : 0

            Column {
                anchors.centerIn: parent
                spacing: Theme.dp(2)
                Repeater {
                    model: verticalTray.shownCount
                    delegate: Image {
                        required property int index
                        readonly property var trayItem: holder.trayItems[index]
                        width: Theme.dp(18)
                        height: Theme.dp(18)
                        source: trayItem ? holder.resolveTrayIcon(trayItem.icon) : ""
                        sourceSize.width: Theme.dp(36)
                        sourceSize.height: Theme.dp(36)
                        smooth: true
                        asynchronous: true
                        fillMode: Image.PreserveAspectFit
                    }
                }
            }
            StateLayer {
                id: verticalTrayArea
                anchors.fill: parent
                radius: Theme.radiusSm
                onEntered: holder.tip(verticalTrayArea, "Системный трей — клик, чтобы открыть")
                onExited: holder.untip(verticalTrayArea)
                onClicked: if (holder.shell) holder.shell.toggleTray()
            }
        }
    }

    ColumnLayout {
        id: verticalColumn
        visible: holder.mode === "idle" && holder.isVertical
        anchors.centerIn: parent
        spacing: Theme.dp(5)

        Repeater {
            model: holder.verticalOrder
            delegate: Loader {
                id: verticalChipLoader
                required property string modelData
                readonly property bool chipShown: holder.mode === "idle" && holder.isVertical
                    && (modelData === "media" ? holder.player !== null
                    : modelData === "clock" ? Prefs.islandClock
                    : modelData === "weather" ? Prefs.islandWeather
                    : modelData === "battery" ? holder.showBattery
                    : modelData === "kb" ? holder.showLayout
                    : modelData === "ws" ? Prefs.islandWorkspaces
                    : modelData === "term" ? Prefs.islandTerminal
                    : modelData === "ai" ? Prefs.islandAi
                    : modelData === "system" ? Prefs.systemLoadOnIsland
                    : Prefs.islandTray && holder.trayItems.length > 0)
                active: chipShown
                visible: chipShown
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: item ? item.implicitWidth : 0
                Layout.preferredHeight: item ? item.implicitHeight : 0
                sourceComponent: modelData === "media" ? verticalMediaChip
                    : modelData === "clock" ? verticalClockChip
                    : modelData === "weather" ? verticalWeatherChip
                    : modelData === "battery" ? verticalBatteryChip
                    : modelData === "system" ? verticalSystemLoadChip
                    : modelData === "kb" ? verticalLayoutChip
                    : modelData === "ws" ? verticalWorkspaceChip
                    : modelData === "term" ? verticalTermChip
                    : modelData === "ai" ? verticalAiChip
                    : verticalTrayChip
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
