import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import QtQuick.Shapes
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

    screen: modelData
    color: "transparent"
    anchors { top: true; left: true; right: true }
    // Полоска под остров зарезервирована ровно по капсулу (6 + 34), чтобы
    // максимизированные окна не заезжали под неё; отступ снизу даёт само окно.
    // В fullscreen остров скрывается и зона не держится.
    exclusiveZone: win.fullscreenActive ? 0 : Theme.topReserve
    implicitHeight: Math.max(664, win.panelMax + Theme.dp(16))
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "oberon-island"
    WlrLayershell.keyboardFocus: (view === "launcher" || view === "panel" || view === "taskman" || view === "tray")
        ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    mask: Region { item: pill; radius: pill.radius }

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
        opencode: "l",
        calendar: "m",
        weather: "m",
        timers: "m"
    })
    readonly property var sizeClasses: ({
        s: Theme.dp(440),
        m: Theme.dp(520),
        l: Theme.dp(820),
        xl: Theme.dp(860)
    })
    readonly property int panelW: {
        const rawW = win.view === "taskman" ? Theme.dp(960)
            : win.view === "tray" ? Theme.dp(360)
            : win.view === "launcher" ? ((win.shell && win.shell.launcherTab === "packages") ? Theme.dp(820) : Theme.dp(680))
            : win.view === "panel" ? win.sizeClasses[win.pageSizes[win.page] || "s"]
            : Theme.dp(440);
        return win.width > 0 ? Math.min(rawW, win.width - Theme.dp(24)) : rawW;
    }
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

    // ── Ключи редизайна острова: barStyle / islandOrder / islandAllScreens ──
    // Теперь живут в Prefs (JsonAdapter); чтение защитное: не «notch» → island,
    // не массив → дефолтный порядок, не true → false.
    readonly property string barStyle: Prefs.barStyle === "notch" ? "notch" : "island"
    readonly property bool notch: win.barStyle === "notch"
    readonly property var islandOrder: Prefs.islandOrder
    readonly property bool islandAllScreens: Prefs.islandAllScreens === true

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

    // Настоящая тень: обёртка с запасом, layer.effect рисует капсулу
    // с гауссовой тенью (в Umbriel теней слоёв нет — делаем сами).
    Item {
        id: shadowHost
        readonly property int padH: Theme.dp(30)
        readonly property int padTop: Theme.dp(10)
        readonly property int padBottom: Theme.dp(24)

        x: Math.round((parent.width - width) / 2)
        // notch: капсула прижата к верхней кромке (y=0)
        y: (win.notch ? 0 : Theme.dp(6)) - padTop
        width: pill.width + padH * 2
        height: pill.height + padTop + padBottom
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
            x: shadowHost.padH
            y: shadowHost.padTop
            width: win.big ? win.panelW : (idlePill.implicitWidth + Theme.dp(12) * 2)
            height: win.big ? Math.min(contentCol.implicitHeight + panelFace.headerSpace + Theme.dp(32), win.panelMax) : Math.max(Theme.dp(34), idlePill.implicitHeight + Theme.dp(6))
            // idle — Lucid-пилюля (radiusPill), панель — крупный скруглённый
            // контейнер (radiusXl / shapeXlInc для лончера). Без обводки.
            // notch: капсула прижата к кромке — верхние углы прямые, низ полный
            radius: win.big ? (win.mode === "launcher" ? Theme.shapeXlInc : Theme.radiusXl) : height / 2
            topLeftRadius: win.notch ? 0 : radius
            topRightRadius: win.notch ? 0 : radius
            color: win.big ? Theme.withBlur(Theme.mContainer) : Theme.bg
            clip: true
            // OPEN — emphasizedDecel @ durEnter, CLOSE — emphasizedAccel @ durExit
            Behavior on width { NumberAnimation { duration: win.big ? Theme.durEnter : Theme.durExit; easing.type: Easing.Bezier; easing.bezierCurve: win.big ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel } }
            Behavior on height { NumberAnimation { duration: win.big ? Theme.durEnter : Theme.durExit; easing.type: Easing.Bezier; easing.bezierCurve: win.big ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel } }
            Behavior on radius { NumberAnimation { duration: win.big ? Theme.durEnter : Theme.durExit; easing.type: Easing.Bezier; easing.bezierCurve: win.big ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel } }
            Behavior on topLeftRadius { NumberAnimation { duration: win.big ? Theme.durEnter : Theme.durExit; easing.type: Easing.Bezier; easing.bezierCurve: win.big ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel } }
            Behavior on topRightRadius { NumberAnimation { duration: win.big ? Theme.durEnter : Theme.durExit; easing.type: Easing.Bezier; easing.bezierCurve: win.big ? Theme.easeEmphasizedDecel : Theme.easeEmphasizedAccel } }
            Behavior on color { ColorAnimation { duration: win.big ? Theme.durEnter : Theme.durExit } }

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
            width: win.panelW - Theme.dp(32)
            height: Theme.dp(52)
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: Theme.dp(16)
            spacing: Theme.dp(8)
            IconButton {
                icon: "arrow_back"
                visible: win.mode === "panel" && win.page !== ""
                onClicked: if (win.shell) win.shell.setPage("")
            }
            ColumnLayout {
                spacing: -Theme.dp(1)
                visible: win.mode === "panel" && win.page === ""
                LText {
                    role: "titleMedium"
                    color: Theme.text
                    text: Qt.formatDateTime(win.now, "HH:mm")
                }
                LText {
                    role: "bodySmall"
                    color: Theme.subtext
                    text: win.now.toLocaleDateString(Qt.locale("ru_RU"), "dddd, d MMMM")
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
            IconButton {
                visible: win.mode === "panel" && win.page === ""
                icon: "settings"
                onClicked: if (win.shell) win.shell.setPage(win.page === "settings" ? "" : "settings")
            }
            IconButton {
                visible: win.mode === "panel"
                icon: "power_settings_new"
                variant: "tonal"
                onClicked: if (win.shell) win.shell.setPage(win.page === "power" ? "" : "power")
            }
        }

        Flickable {
            id: panelView
            width: win.panelW - Theme.dp(32)
            height: Math.min(contentCol.implicitHeight, win.panelMax - Theme.dp(32) - panelFace.headerSpace)
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: Theme.dp(16) + panelFace.headerSpace
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
                SettingsPage { win: win }
                GamesPage { win: win }
                UpdatesPage { win: win }
                OpenCodePage { win: win }

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

    // ── Notch «плавники» (порт lucidbar/BarFlare.qml) ──────────────────
    // Четверть-круги цвета фона по бокам капсулы, смыкающиеся с верхней
    // кромкой экрана: слева — прямой, справа — зеркальный (transform -1).
    Item {
        id: flares
        visible: win.notch && !win.big

        x: shadowHost.x + pill.x
        y: shadowHost.y + pill.y


        readonly property real bite: 0.5
        readonly property real finSize: Theme.dp(14)

        // левый (прямой)
        Item {
            x: -flares.finSize + flares.bite
            y: 0
            width: flares.finSize
            height: flares.finSize

            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                antialiasing: true

                ShapePath {
                    strokeWidth: 0
                    fillColor: Theme.bg
                    startX: flares.finSize
                    startY: flares.finSize

                    PathArc {
                        x: 0
                        y: 0
                        radiusX: flares.finSize
                        radiusY: flares.finSize
                        direction: PathArc.Counterclockwise
                    }

                    PathLine {
                        x: flares.finSize
                        y: 0
                    }

                    PathLine {
                        x: flares.finSize
                        y: flares.finSize
                    }
                }
            }
        }

        // правый (зеркальный, как BarFlare с mirrored: true)
        Item {
            x: pill.width - flares.bite
            y: 0
            width: flares.finSize
            height: flares.finSize

            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                antialiasing: true

                transform: Scale {
                    xScale: -1
                    origin.x: flares.finSize / 2
                }

                ShapePath {
                    strokeWidth: 0
                    fillColor: Theme.bg
                    startX: flares.finSize
                    startY: flares.finSize

                    PathArc {
                        x: 0
                        y: 0
                        radiusX: flares.finSize
                        radiusY: flares.finSize
                        direction: PathArc.Counterclockwise
                    }

                    PathLine {
                        x: flares.finSize
                        y: 0
                    }

                    PathLine {
                        x: flares.finSize
                        y: flares.finSize
                    }
                }
            }
        }
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
        opencode: "OpenCode",
        emoji: "Эмодзи",
        games: "Игры",
        updates: "Обновления",
        settings: "Настройки"
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
