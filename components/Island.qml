import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import Quickshell.Services.SystemTray
import Quickshell.Services.UPower
import "../core"
import "../ui"
import "panel"
import "taskman"

// Oberon island. The Wayland surface is a fixed-size transparent band; the pill
// inside it is animated in QML (smooth). Input is limited to the pill via mask.
PanelWindow {
    id: win
    required property var modelData
    property var shell: null
    property string view: "idle"        // idle | panel | launcher | taskman | tray
    property bool settingsKeysCapture: false
    property bool pillDragging: false
    property point pillDragCenterOffset: Qt.point(0, 0)

    screen: modelData
    color: "transparent"
    readonly property string islandPos: {
        const pos = String(Prefs.islandPos || "top");
        return pos === "bottom" || pos === "left" || pos === "right" ? pos : "top";
    }
    readonly property bool islandAtTop: win.islandPos === "top"
    readonly property bool islandAtBottom: win.islandPos === "bottom"
    readonly property bool islandAtLeft: win.islandPos === "left"
    readonly property bool islandAtRight: win.islandPos === "right"
    readonly property bool islandVertical: win.islandAtLeft || win.islandAtRight
    readonly property int islandThickness: Theme.dp(Math.max(1, Prefs.islandHeight))
    readonly property int islandGap: Theme.dp(Math.max(0, Prefs.islandGap))
    readonly property int revealSize: Theme.dp(5)
    readonly property bool islandAutoHide: Prefs.islandAutoHide === true
    readonly property real notchRadius: Theme.dp(Math.max(0, Prefs.notchFlare))

    // Окно — полоса по кромке капсулы, а не весь экран: Umbriel дублирует
    // полноэкранную layer-поверхность при непустом exclusiveZone.
    // Крепимся только к своей кромке — композитор центрирует окно по другой
    // оси (как у Panacea). Растянутая поверхность + exclusiveZone заставляет
    // Umbriel рисовать содержимое дважды.
    anchors {
        top: win.islandAtTop
        bottom: win.islandAtBottom
        left: win.islandAtLeft
        right: win.islandAtRight
    }
    // Поперечный размер окна — с запасом под раскрытую панель и тень.
    readonly property real stripExtent: Math.min(
        win.islandVertical ? (win.screen ? win.screen.width : 1920) : (win.screen ? win.screen.height : 1080),
        Math.max(Theme.dp(664), win.panelHeightMax + Theme.dp(80)))
    implicitWidth: win.islandVertical ? win.stripExtent
        : Math.min(win.screen ? win.screen.width : 1920, Theme.dp(1024))
    implicitHeight: win.islandVertical
        ? Math.min(win.screen ? win.screen.height : 1080, Theme.dp(1024))
        : win.stripExtent
    // Резерв не запрашиваем: Umbriel рисует поверхность с exclusiveZone
    // дважды (сдвиг на толщину), а капсула и так парит над окнами —
    // как pillOverlay=true у Panacea.
    exclusiveZone: 0
    // Overlay: панель/лончер обязаны быть выше полноэкранного клик-фона
    // (components/Backdrop.qml — Top-слой), иначе клик внутри панели её закрывает.
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "oberon-island"
    WlrLayershell.keyboardFocus: win.settingsKeysCapture ? WlrKeyboardFocus.Exclusive
        : ((view === "launcher" || view === "panel" || view === "taskman" || view === "tray")
            ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None)
    mask: Region {
        item: pill
        radius: pill.radius
        Region {
            item: win.islandAutoHide ? revealStrip : null
            intersection: Intersection.Combine
        }
    }

    readonly property bool isActiveOutput: !win.screen || Umbriel.activeOutput === ""
        || win.screen.name === Umbriel.activeOutput
    function transientHere(showOn) {
        const output = String(showOn || "");
        return output === "" ? (win.islandAllScreens || win.isActiveOutput)
            : (win.islandAllScreens || (!!win.screen && win.screen.name === output));
    }
    readonly property bool osdHere: Osd.visible && win.transientHere(Osd.showOn)
    readonly property bool notifHere: Notif.visible && win.transientHere(Notif.showOn)
    readonly property bool transientHereNow: win.osdHere || win.notifHere
    readonly property string mode: (win.notifHere && view === "idle") ? "notif"
                                 : (win.osdHere && view === "idle") ? "osd" : view
    readonly property bool big: mode === "panel" || mode === "launcher" || mode === "taskman" || mode === "tray"
    readonly property string page: win.shell ? win.shell.panelPage : ""
    // Классы размеров капсулы.
    readonly property var pageSizes: ({
        wallpapers: "xl",
        settings: "l",
        games: "l",
        updates: "l",
        media: "l",
        files: "l",
        vault: "m",
        calendar: "m",
        weather: "m",
        timers: "m",
        record: "m"
    })
    readonly property var sizeClasses: ({
        s: Theme.dp(440),
        m: Theme.dp(520),
        l: Theme.dp(820),
        xl: Theme.dp(860)
    })
    readonly property int panelBaseW: {
        const rawW = win.view === "taskman" ? Theme.dp(960)
            : win.view === "tray" ? Theme.dp(360)
            : win.view === "launcher" ? ((win.shell && win.shell.launcherTab === "packages") ? Theme.dp(820) : Theme.dp(680))
            : win.view === "panel" ? win.sizeClasses[win.pageSizes[win.page] || "s"]
            : Theme.dp(440);
        return rawW;
    }
    readonly property int panelW: {
        const screenWidth = win.screen ? win.screen.width : 1920;
        const screenLimit = Math.max(Theme.dp(1), screenWidth - Theme.dp(24));
        const prefLimit = Prefs.islandExpandedWidth > 0
            ? Theme.dp(Prefs.islandExpandedWidth) : win.panelBaseW;
        return Math.max(Theme.dp(1), Math.min(win.panelBaseW, prefLimit, screenLimit));
    }
    readonly property int panelContentW: Math.max(Theme.dp(1), win.panelW - Theme.dp(32))
    // активное окно во весь экран на этом output → остров уступает игрушке
    readonly property bool fullscreenActive: win.screen
        ? Umbriel.fullscreenFor(win.screen.name) : false
    // Панели живут на активном выводе; idle и transient-пилюля следуют islandAllScreens.
    visible: win.big ? win.isActiveOutput
        : (win.transientHereNow
            || ((win.islandAllScreens || win.isActiveOutput) && !win.fullscreenActive))
    // Максимальная высота панели: 82% экрана, чтобы высокие страницы (обои,
    // настройки, пакеты, диспетчер) помещались свободно.
    readonly property real panelMax: Math.max(360, Math.round((win.screen ? win.screen.height : 900) * 0.82))
    // 0 означает прежний динамический предел (82% экрана); заданное значение
    // лишь дополнительно ограничивает высоту открытой капсулы.
    readonly property real panelHeightMax: Math.min(win.panelMax,
        Prefs.islandExpandedHeight > 0 ? Theme.dp(Prefs.islandExpandedHeight) : win.panelMax)

    // ── Настройки капсулы; barStyle оставлен для старых конфигов/IPC ───────
    readonly property string barStyle: Prefs.barStyle === "notch" ? "notch" : "island"
    // Prefs мигрирует legacy barStyle="notch" в этот переключатель; дальше
    // notchMode — источник истины, чтобы его можно было выключить независимо.
    readonly property bool notch: Prefs.notchMode === true
    readonly property real edgeGap: win.notch ? 0 : win.islandGap
    readonly property var islandOrder: Prefs.islandOrder
    readonly property bool islandAllScreens: Prefs.islandAllScreens === true

    // При автоскрытии оставляем только тонкий край для повторного наведения.
    readonly property bool revealHeld: revealHover.hovered || revealHoldTimer.running
        || collapseTimer.running || capsuleRevealHover.hovered
    readonly property bool pillHidden: win.islandAutoHide && !win.big
        && !win.transientHereNow && !win.revealHeld

    function openPanelFromPill() {
        if (!win.shell || win.big || win.mode !== "idle" || win.pillDragging)
            return;
        win.shell.openPanel();
    }

    function beginPillDrag(pointerPoint) {
        const center = pill.mapToGlobal(pill.width / 2, pill.height / 2);
        win.pillDragCenterOffset = Qt.point(center.x - pointerPoint.x, center.y - pointerPoint.y);
    }

    function finishPillDrag(pointerPoint) {
        if (!win.screen)
            return;
        const center = Qt.point(pointerPoint.x + win.pillDragCenterOffset.x,
                                pointerPoint.y + win.pillDragCenterOffset.y);
        const sx = win.screen.x;
        const sy = win.screen.y;
        const sw = win.screen.width;
        const sh = win.screen.height;
        const candidates = [];
        if (center.x <= sx + sw / 4)
            candidates.push({ pos: "left", distance: Math.abs(center.x - sx) });
        if (center.x >= sx + sw * 3 / 4)
            candidates.push({ pos: "right", distance: Math.abs(sx + sw - center.x) });
        if (center.y <= sy + sh / 4)
            candidates.push({ pos: "top", distance: Math.abs(center.y - sy) });
        if (center.y >= sy + sh * 3 / 4)
            candidates.push({ pos: "bottom", distance: Math.abs(sy + sh - center.y) });
        if (candidates.length === 0)
            return;
        candidates.sort((a, b) => a.distance - b.distance);
        const next = candidates[0].pos;
        if (next !== win.islandPos)
            Prefs.set("islandPos", next);
    }

    property date now: new Date()
    Timer { interval: 1000; running: true; repeat: true; onTriggered: win.now = new Date() }

    readonly property var player: {
        const ps = Mpris.players.values;
        if (!ps || ps.length === 0) return null;
        for (const p of ps) if (p.isPlaying) return p;
        return ps[0];
    }
    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource
    readonly property var battery: UPower.displayDevice
    readonly property bool showBattery: battery !== null && battery.isPresent
        && String(battery.iconName).indexOf("missing") === -1

    // PipeWire device lists
    readonly property var outputs: {
        const out = [];
        for (const n of Pipewire.nodes.values) if (n.isSink && !n.isStream && n.audio) out.push(n);
        return out;
    }
    readonly property var inputs: {
        const out = [];
        for (const n of Pipewire.nodes.values) if (!n.isSink && !n.isStream && n.audio) out.push(n);
        return out;
    }
    readonly property var streams: {
        const out = [];
        for (const n of Pipewire.nodes.values) if (n.isStream && n.audio) out.push(n);
        return out;
    }
    // Wi-Fi list (dedup + sort)
    readonly property var wifiList: {
        const seen = {}; const out = [];
        for (const n of Sys.wifiNetworks) {
            if (!n.ssid || seen[n.ssid]) continue;
            seen[n.ssid] = true; out.push(n);
        }
        out.sort((a, b) => b.signal - a.signal);
        return out.slice(0, 8);
    }

    // ── Тултип чипов островка (ui/Tooltip) ─────────────────────────────
    // Живёт прямо в окне: окно прозрачное ниже капсулы, тултип рисуем в
    // свободной зоне; input ограничен маской капсулы — тултип не ловит клики.
    // Объявлен ДО shadowHost: IdlePill связывается с ним по id при создании.
    Tooltip {
        id: chipTip
        z: 50
    }

    // Узкий edge-trigger возвращает спрятанный остров. Короткая задержка
    // удерживает его на виду, пока курсор проходит gap до капсулы.
    Item {
        id: revealStrip
        visible: win.islandAutoHide
        z: 100
        x: win.islandVertical ? (win.islandAtRight ? parent.width - win.revealSize : 0) : 0
        y: win.islandVertical ? 0 : (win.islandAtBottom ? parent.height - win.revealSize : 0)
        width: win.islandVertical ? win.revealSize : parent.width
        height: win.islandVertical ? parent.height : win.revealSize

        HoverHandler {
            id: revealHover
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onHoveredChanged: {
                if (hovered)
                    revealHoldTimer.restart();
                else if (!capsuleRevealHover.hovered)
                    revealHoldTimer.restart();
            }
        }
    }

    Timer {
        id: revealHoldTimer
        interval: 360
    }

    // Настоящая тень: обёртка с запасом, layer.effect рисует капсулу
    // с гауссовой тенью (в Umbriel теней слоёв нет — делаем сами).
    Item {
        id: shadowHost
        readonly property int padH: Theme.dp(30)
        readonly property int padTop: Theme.dp(10)
        readonly property int padBottom: Theme.dp(24)
        readonly property real targetPillX: win.islandAtLeft
            ? (win.pillHidden ? -pill.width + win.revealSize : win.edgeGap)
            : (win.pillHidden ? parent.width - win.revealSize : parent.width - win.edgeGap - pill.width)
        readonly property real targetPillY: win.islandAtTop
            ? (win.pillHidden ? -pill.height + win.revealSize : win.edgeGap)
            : (win.pillHidden ? parent.height - win.revealSize : parent.height - win.edgeGap - pill.height)
        x: win.islandVertical ? targetPillX - padTop : Math.round((parent.width - width) / 2)
        y: win.islandVertical ? Math.round((parent.height - height) / 2) : targetPillY - padTop
        width: pill.width + (win.islandVertical ? padTop + padBottom : padH * 2)
        height: pill.height + (win.islandVertical ? padH * 2 : padTop + padBottom)
        Behavior on x {
            enabled: win.islandAutoHide && !win.big
            NumberAnimation { duration: Theme.durShort; easing.type: Easing.OutCubic }
        }
        Behavior on y {
            enabled: win.islandAutoHide && !win.big
            NumberAnimation { duration: Theme.durShort; easing.type: Easing.OutCubic }
        }
        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled: true
            // Lucid-бар без тени; оставляем только шёпот для отделения от светлых
            // обоев. Альфа ниже blur_ignore_alpha (0.72), чтобы композитор не
            // размывал фон под тенью — только под самой капсулой.
            shadowColor: Theme.a(Theme.scrim, 0.42)
            shadowBlur: 0.6
            shadowVerticalOffset: Theme.dp(3)
            shadowOpacity: 0.7
        }

        Rectangle {
            id: pill
            x: win.islandVertical ? shadowHost.padTop : shadowHost.padH
            y: win.islandVertical ? shadowHost.padH : shadowHost.padTop
            readonly property real collapsedLength: {
                const contentLength = win.islandVertical
                    ? idlePill.implicitHeight + Theme.dp(24)
                    : idlePill.implicitWidth + Theme.dp(24);
                const minLength = Theme.dp(Math.max(0, Prefs.islandWidth));
                return pill.evenUp(Math.max(contentLength, minLength));
            }
            function evenUp(value) { return Math.round(value / 2) * 2; }
            readonly property real fullRadius: win.big
                ? (win.mode === "launcher" ? Theme.shapeXlInc : Theme.radiusXl)
                : Math.min(width, height) / 2
            readonly property real attachedRadius: {
                if (win.notch)
                    return 0;
                if (win.big)
                    return pill.fullRadius;
                const configured = Math.max(0, Prefs.islandRadius);
                const radius = configured > 0 ? Theme.dp(configured)
                    : (win.islandVertical ? width : height) / 2;
                return Math.min(radius, pill.fullRadius);
            }
            width: win.big ? win.panelW : win.islandVertical ? win.islandThickness : pill.collapsedLength
            height: win.big ? Math.min(contentCol.implicitHeight + panelFace.headerSpace + Theme.dp(32), win.panelHeightMax)
                : win.islandVertical ? pill.collapsedLength
                : win.mode === "idle" ? win.islandThickness
                : Math.max(win.islandThickness, idlePill.implicitHeight + Theme.dp(6))
            // idle — Lucid-пилюля (radiusPill), панель — крупный скруглённый
            // контейнер (radiusXl / shapeXlInc для лончера). Без обводки.
            // Прижатая сторона получает свой радиус, остальные остаются полными.
            radius: pill.fullRadius
            topLeftRadius: win.islandAtTop || win.islandAtLeft ? pill.attachedRadius : pill.fullRadius
            topRightRadius: win.islandAtTop || win.islandAtRight ? pill.attachedRadius : pill.fullRadius
            bottomLeftRadius: win.islandAtBottom || win.islandAtLeft ? pill.attachedRadius : pill.fullRadius
            bottomRightRadius: win.islandAtBottom || win.islandAtRight ? pill.attachedRadius : pill.fullRadius
            color: win.big ? Theme.withBlur(Theme.mContainer) : Theme.bg
            clip: true
            // OPEN — emphasizedDecel @ durEnter, CLOSE — emphasizedAccel @ durExit
            Behavior on width { NumberAnimation { duration: win.big ? Theme.durEnter : Theme.durExit; easing.type: Easing.Bezier; easing.bezierCurve: win.big ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel } }
            Behavior on height { NumberAnimation { duration: win.big ? Theme.durEnter : Theme.durExit; easing.type: Easing.Bezier; easing.bezierCurve: win.big ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel } }
            Behavior on radius { NumberAnimation { duration: win.big ? Theme.durEnter : Theme.durExit; easing.type: Easing.Bezier; easing.bezierCurve: win.big ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel } }
            Behavior on topLeftRadius { NumberAnimation { duration: win.big ? Theme.durEnter : Theme.durExit; easing.type: Easing.Bezier; easing.bezierCurve: win.big ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel } }
            Behavior on topRightRadius { NumberAnimation { duration: win.big ? Theme.durEnter : Theme.durExit; easing.type: Easing.Bezier; easing.bezierCurve: win.big ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel } }
            Behavior on bottomLeftRadius { NumberAnimation { duration: win.big ? Theme.durEnter : Theme.durExit; easing.type: Easing.Bezier; easing.bezierCurve: win.big ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel } }
            Behavior on bottomRightRadius { NumberAnimation { duration: win.big ? Theme.durEnter : Theme.durExit; easing.type: Easing.Bezier; easing.bezierCurve: win.big ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel } }
            Behavior on color { ColorAnimation { duration: win.big ? Theme.durEnter : Theme.durExit } }

            // Щелчок по свободной части капсулы открывает компактную панель.
            MouseArea {
                anchors.fill: parent
                z: -1
                enabled: !win.big && win.mode === "idle" && !win.pillDragging
                cursorShape: Qt.PointingHandCursor
                onClicked: win.openPanelFromPill()
            }

            // Auto-hide only: keep the collapsed capsule present under the
            // pointer. This handler never opens or expands the panel.
            HoverHandler {
                id: capsuleRevealHover
                enabled: win.islandAutoHide
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onHoveredChanged: {
                    if (hovered) {
                        collapseTimer.stop();
                        revealHoldTimer.stop();
                    } else if (!revealHover.hovered) {
                        collapseTimer.restart();
                    }
                }
            }

            // ── IDLE / OSD / NOTIF ─────────────────────────────────────
            // компактное лицо: при открытии панели съёживается (0.82) и гаснет,
            // как compactFace в Lucid BarPill
            Item {
                id: compactFace
                anchors.fill: parent
                visible: opacity > 0.01
                opacity: win.big ? 0 : 1
                scale: win.big ? 0.82 : 1

                Behavior on opacity { NumberAnimation { duration: win.big ? Theme.durExit : Theme.durEnter; easing.type: Easing.OutCubic } }
                Behavior on scale { NumberAnimation { duration: Theme.ms(220); easing.type: Easing.OutCubic } }

                IdlePill {
                    id: idlePill
                    anchors.centerIn: parent
                    mode: win.mode
                    now: win.now
                    output: win.screen.name
                    shell: win.shell
                    isVertical: win.islandVertical
                    player: win.player
                    battery: win.battery
                    showBattery: win.showBattery
                    orderProp: win.islandOrder
                    tipHost: chipTip
                }
            }

            // ── PANEL ────────────────────────────────────────────────────
            // панельное лицо: гаснет при закрытии, входящее — 1.04 → 1
            FocusScope {
                id: panelFace
                anchors.fill: parent
                visible: opacity > 0.01
                opacity: win.big ? 1 : 0
                scale: win.big ? 1 : 1.04
                focus: win.big
                readonly property int headerSpace: panelHeader.visible
                    ? panelHeader.height + (contentCol.implicitHeight > 0 ? Theme.dp(14) : 0) : 0
                Keys.onEscapePressed: (event) => {
                    if (win.shell) win.shell.closeOverlays();
                    event.accepted = true;
                }
                Shortcut {
                    sequence: "Escape"
                    enabled: win.mode === "panel" && win.isActiveOutput
                    onActivated: if (win.shell) win.shell.closeOverlays()
                }

                Behavior on opacity { NumberAnimation { duration: win.big ? Theme.durEnter : Theme.durExit; easing.type: Easing.OutCubic } }
                Behavior on scale { NumberAnimation { duration: Theme.ms(220); easing.type: Easing.OutCubic } }

                SequentialAnimation {
                    id: pageEnterAnimation
                    PropertyAction { target: panelView; property: "opacity"; value: 0 }
                    NumberAnimation {
                        target: panelView
                        property: "opacity"
                        to: 1
                        duration: Theme.durEnter
                        easing.type: Easing.Bezier
                        easing.bezierCurve: Theme.easeEmphasizedDecel
                    }
                }

        // Шапка вне прокручиваемой области: не мигает при смене страницы.
        RowLayout {
            id: panelHeader
            visible: win.mode === "panel" || win.mode === "tray"
            width: win.panelContentW
            height: Theme.dp(52)
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: Theme.dp(16)
            spacing: Theme.dp(8)
            IconButton {
                icon: "arrow_back"
                visible: win.mode === "panel" && win.page !== ""
                disabled: win.pillDragging
                onClicked: if (win.shell) win.shell.setPage("")
            }
            ColumnLayout {
                spacing: -Theme.dp(1)
                visible: win.mode === "panel" && win.page === ""
                LText {
                    role: "titleMedium"
                    color: Theme.text
                    text: Qt.formatDateTime(win.now, Prefs.clock12 ? "h:mm AP" : "HH:mm")
                }
                LText {
                    role: "bodySmall"
                    color: Theme.subtext
                    text: win.now.toLocaleDateString(Qt.locale("ru_RU"),
                        Prefs.clockWeekday ? "dddd, " + Prefs.clockDateFmt : Prefs.clockDateFmt)
                }
            }
            LText {
                visible: win.mode === "panel" && win.page !== ""
                role: "titleMedium"
                color: Theme.text
                text: win.pageTitle
            }
            LText { // заголовок вида «трей»
                visible: win.mode === "tray"
                role: "titleMedium"
                color: Theme.text
                text: "Трей"
            }
            Item { Layout.fillWidth: true }
            Item {
                id: dragHandle
                visible: Prefs.islandDrag && (win.mode === "panel" || win.mode === "tray")
                Layout.preferredWidth: Theme.dp(40)
                Layout.preferredHeight: Theme.dp(40)
                implicitWidth: Theme.dp(40)
                implicitHeight: Theme.dp(40)

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radiusPill
                    color: dragHandleHover.hovered ? Theme.bgTile : "transparent"
                }

                Icon {
                    anchors.centerIn: parent
                    name: "drag_indicator"
                    size: Theme.dp(20)
                    color: dragHandleHover.hovered ? Theme.text : Theme.subtext
                }

                HoverHandler {
                    id: dragHandleHover
                    enabled: dragHandle.visible
                }

                DragHandler {
                    id: islandDragHandler
                    enabled: dragHandle.visible
                    target: null
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    property point globalPoint: Qt.point(0, 0)

                    onActiveChanged: {
                        if (active) {
                            globalPoint = dragHandle.mapToGlobal(centroid.position);
                            win.beginPillDrag(globalPoint);
                            win.pillDragging = true;
                        } else if (win.pillDragging) {
                            if (Prefs.islandDrag)
                                win.finishPillDrag(globalPoint);
                            win.pillDragging = false;
                        }
                    }
                    onTranslationChanged: if (active)
                        globalPoint = dragHandle.mapToGlobal(centroid.position)
                }
            }
            IconButton {
                visible: win.mode === "panel" && win.page === ""
                icon: "settings"
                disabled: win.pillDragging
                onClicked: if (win.shell) win.shell.setPage(win.page === "settings" ? "" : "settings")
            }
            IconButton {
                visible: win.mode === "panel"
                icon: "power_settings_new"
                variant: "tonal"
                disabled: win.pillDragging
                onClicked: if (win.shell) win.shell.setPage(win.page === "power" ? "" : "power")
            }
        }

        Flickable {
            id: panelView
            width: win.panelContentW
            height: Math.max(0, Math.min(contentCol.implicitHeight,
                win.panelHeightMax - Theme.dp(32) - panelFace.headerSpace))
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: Theme.dp(16) + panelFace.headerSpace
            enabled: !win.pillDragging
            contentWidth: width
            contentHeight: contentCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick

            ColumnLayout {
                id: contentCol
                width: panelView.width
                spacing: Theme.dp(14)

                RootPage { win: win }
                WifiPage { win: win }
                BtPage { win: win }
                VolumePage { win: win }
                BrightnessPage { win: win }
                WallpapersPage { win: win }
                PowerPage { win: win }
                WeatherPage { win: win }
                CalendarPage { win: win }
                TimersPage { win: win }
                RecordView { win: win }
                MediaView { win: win }
                SettingsPage { win: win }
                GamesPage { win: win }
                UpdatesPage { win: win }
                FilesView { win: win }
                VaultView { win: win }

                TaskManager { visible: win.mode === "taskman"; shell: win.shell; initialTab: win.shell ? win.shell.taskmanTab : 0 }

                // Трей — вид острова: список живёт в той же капсуле под шапкой,
                // как страницы панели. qmldir не объявляет TrayList, поэтому
                // грузим по source (как TrayRow в IdlePill).
                Loader {
                    id: trayPage
                    active: win.mode === "tray"
                    // пустой Loader оставался видимым и добавлял спейсинг
                    // ColumnLayout снизу (фантомный отступ под контентом).
                    visible: active
                    source: "TrayList.qml"
                    Layout.fillWidth: true
                    Binding { target: trayPage.item; property: "shell"; value: win.shell; when: trayPage.item !== null }
                    Binding { target: trayPage.item; property: "win"; value: win; when: trayPage.item !== null }
                }

                Launcher { active: win.mode === "launcher"; shell: win.shell; tab: win.shell ? win.shell.launcherTab : "apps" }
            }
        }
            }
        }
    }

    Timer {
        id: collapseTimer
        interval: 180
    }

    // Вогнутые уголки примыкания: по бокам горизонтальной капсулы, а у
    // вертикальной — над и под ней. barStyle="notch" остаётся совместимым.
    NotchCorner {
        id: notchBefore
        visible: win.notch && !win.big && !win.pillHidden
        side: win.islandVertical ? (win.islandAtLeft ? "right" : "left") : "left"
        fill: Theme.bg
        r: win.notchRadius
        transform: Scale {
            origin.y: notchBefore.r / 2
            yScale: win.islandVertical ? -1 : (win.islandAtBottom ? -1 : 1)
        }
        x: win.islandAtLeft ? 0
         : win.islandAtRight ? win.width - width
         : Math.round(shadowHost.x + pill.x) - width
        y: win.islandVertical ? Math.round(shadowHost.y + pill.y) - height
         : win.islandAtBottom ? win.height - height : 0
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.durFastEffects } }
    }
    NotchCorner {
        id: notchAfter
        visible: win.notch && !win.big && !win.pillHidden
        side: win.islandVertical ? (win.islandAtLeft ? "right" : "left") : "right"
        fill: Theme.bg
        r: win.notchRadius
        transform: Scale {
            origin.y: notchAfter.r / 2
            yScale: win.islandVertical ? 1 : (win.islandAtBottom ? -1 : 1)
        }
        x: win.islandAtLeft ? 0
         : win.islandAtRight ? win.width - width
         : Math.round(shadowHost.x + pill.x + pill.width)
        y: win.islandVertical ? Math.round(shadowHost.y + pill.y + pill.height)
         : win.islandAtBottom ? win.height - height : 0
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.durFastEffects } }
    }

    readonly property var pageTitles: ({
        wifi: "Wi-Fi",
        bluetooth: "Bluetooth",
        volume: "Звук",
        brightness: "Яркость",
        power: "Питание",
        wallpapers: "Обои",
        clipboard: "Буфер обмена",
        weather: "Погода",
        system: "Система",
        calendar: "Календарь",
        timers: "Таймеры",
        emoji: "Эмодзи",
        games: "Игры",
        updates: "Обновления",
        settings: "Настройки",
        record: "Запись",
        media: "Медиа",
        files: "Файлы",
        vault: "Пароли"
    })
    readonly property string pageTitle: pageTitles[page] || ""

    property string wifiSel: ""
    property bool showAuto: false
    readonly property string autoLabel: {
        const m = Wallpaper.autoMinutes;
        const h = Math.floor(m / 60), mm = m % 60;
        return h > 0 ? (h + "ч" + (mm > 0 ? " " + mm + "м" : "")) : (mm + "м");
    }
    function setAuto(frac) {
        Wallpaper.autoMinutes = Math.max(1, Math.min(1440, Math.round(1 + frac * 1439)));
        Wallpaper.saveState();
    }
    function submitWifi(pass) {
        if (win.wifiSel === "") return;
        Sys.connectWifi(win.wifiSel, pass || "");
        win.wifiSel = "";
        if (win.shell) win.shell.setPage("");
    }
    onPageChanged: {
        if (page !== "" && win.mode === "panel" && panelFace.opacity >= 1)
            pageEnterAnimation.restart();
        else {
            pageEnterAnimation.stop();
            panelView.opacity = 1;
        }

        if (page === "wifi") { win.wifiSel = ""; Sys.refreshWifi(); }
        else if (page === "bluetooth") Sys.startBtScan();
    }
}
