import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "../core"
import "../ui"

// Переключатель окон (аналог Alt+Tab). Оверлей во весь экран (Overlay), по
// центру — Lucid-карточка shapeXl с сеткой плиток окон Umbriel. Логика:
//   summon(1)  — открыть и выбрать следующее окно после активного
//   summon(-1) — открыть и выбрать предыдущее
//   summon(dir) при открытом — шаг по списку на dir с закольцовкой
//   close()    — закрыть
// Переключение одиночным вызовом IPC ради клавиши Alt+Tab (циклично), но
// подтверждение — Enter/клик; активация через `umbriel msg window-focus:<id>`.
PanelWindow {
    id: switcher

    property bool open: false
    property int _sel: 0
    // анимация появления/ухода карточки
    property real reveal: 0
    // даёт плиткам плавно переезжать при смене состава окон
    property bool glide: false

    // порядок — как отдаёт Umbriel, без сортировки
    readonly property var items: Umbriel.windows
    readonly property int count: items ? items.length : 0

    // ── сетка плиток (Lucid fit) ──────────────────────────────────────
    readonly property int gap: Theme.dp(18)
    readonly property int footH: Theme.dp(40)
    readonly property int cols: Math.max(1, Math.min(4, Math.ceil(Math.sqrt(Math.max(1, switcher.count)))))
    readonly property real availW: Math.max(Theme.dp(280), switcher.width - Theme.dp(160))
    readonly property real tileW: Math.max(Theme.dp(140), Math.min(Theme.dp(200), Math.floor((switcher.availW - (switcher.cols - 1) * switcher.gap) / switcher.cols)))
    readonly property real thumbH: Math.round(switcher.tileW / 1.6)
    readonly property real tileH: switcher.thumbH + Theme.dp(8) + Theme.dp(22)
    readonly property int rows: Math.ceil(Math.max(1, switcher.count) / switcher.cols)
    readonly property real gridW: switcher.cols * switcher.tileW + (switcher.cols - 1) * switcher.gap
    readonly property real gridH: switcher.rows * switcher.tileH + (switcher.rows - 1) * switcher.gap
    readonly property real viewMaxH: Math.max(Theme.dp(200), switcher.height * 0.72 - Theme.dp(32) - switcher.footH)
    readonly property real viewH: switcher.count > 0 ? Math.min(switcher.gridH, switcher.viewMaxH) : 0

    // ── icon index: app_id (lowercase) → имя иконки ───────────────────
    // тот же приём, что и в WorkspacesRow: точное совпадение по id, затем
    // startupClass; затем Quickshell.iconPath(name, true).
    readonly property var iconIndex: {
        const byId = {};
        const byClass = {};
        for (const e of DesktopEntries.applications.values) {
            if (!e.icon) continue;
            if (e.id) byId[String(e.id).toLowerCase()] = e.icon;
            if (e.startupClass) byClass[String(e.startupClass).toLowerCase()] = e.icon;
        }
        return { byId: byId, byClass: byClass };
    }

    function iconFor(appId) {
        const k = String(appId || "").toLowerCase();
        if (k === "") return "";
        const ix = switcher.iconIndex;
        const name = ix.byId[k] || ix.byClass[k] || "";
        return name !== "" ? Quickshell.iconPath(name, true) : "";
    }

    // ── навигация ─────────────────────────────────────────────────────
    function _wrapIndex(i) {
        const n = switcher.count;
        if (n <= 0) return 0;
        return ((i % n) + n) % n;
    }

    function _step(dir) {
        if (switcher.count === 0) return;
        switcher._sel = switcher._wrapIndex(switcher._sel + dir);
    }

    function summon(dir) {
        if (!switcher.open) {
            switcher.open = true;
            const n = switcher.count;
            if (n === 0) { switcher._sel = 0; return; }
            // активный в списке; если активного нет — с -1 для dir>0
            let base = -1;
            for (let i = 0; i < n; i++) {
                if (switcher.items[i] && switcher.items[i].active) { base = i; break; }
            }
            if (base < 0) base = dir < 0 ? 0 : -1;
            switcher._sel = switcher._wrapIndex(base + dir);
        } else {
            switcher._step(dir);
        }
    }

    function close() {
        switcher.open = false;
    }

    function activate() {
        const it = switcher.items[switcher._sel];
        const id = it ? it.id : "";
        if (id === undefined || id === null || String(id) === "") {
            switcher.close();
            return;
        }
        Quickshell.execDetached(["umbriel", "msg", "window-focus:" + id]);
        switcher.close();
    }

    // список изменился — не выходим за границы
    onItemsChanged: {
        const n = switcher.count;
        if (n === 0) { switcher._sel = 0; return; }
        switcher._sel = Math.max(0, Math.min(switcher._sel, n - 1));
    }

    // при открытии — забрать клавиатуру + включить glide
    onOpenChanged: {
        switcher.reveal = switcher.open ? 1 : 0;
        if (switcher.open) {
            keyCatcher.forceActiveFocus();
            glideOff.stop();
            glideOn.restart();
        }
    }

    visible: switcher.open || switcher.reveal > 0.01
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "oberon-switcher"
    WlrLayershell.keyboardFocus: switcher.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    Timer { id: glideOn; interval: 60; onTriggered: switcher.glide = true }
    Timer { id: glideOff; interval: 60; onTriggered: switcher.glide = false }

    Behavior on reveal {
        NumberAnimation {
            duration: switcher.open ? Theme.durFastEffects : Theme.ms(90)
            easing.type: switcher.open ? Easing.OutCubic : Easing.InCubic
        }
    }

    // ── приглушённый фон и перехват кликов вне карточки ───────────────
    Rectangle {
        anchors.fill: parent
        color: Theme.alpha(Theme.cShadow, Theme.blurPct > 0 ? 0.28 : 0.45)
        opacity: switcher.reveal

        MouseArea {
            anchors.fill: parent
            onClicked: switcher.close()
        }
    }

    // ── карточка ──────────────────────────────────────────────────────
    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.max(Theme.dp(420), switcher.gridW + Theme.dp(32))
        height: (switcher.count > 0 ? switcher.viewH : Theme.dp(140)) + Theme.dp(32) + switcher.footH
        radius: Theme.shapeXl
        color: Theme.bg
        opacity: switcher.reveal

        // клики между плитками не должны доставать до затемнения
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
        }

        Flickable {
            id: view
            visible: switcher.count > 0
            x: Theme.dp(16)
            y: Theme.dp(16)
            width: card.width - Theme.dp(32)
            height: switcher.viewH
            contentWidth: width
            contentHeight: switcher.gridH
            interactive: contentHeight > height + 1
            clip: interactive
            boundsBehavior: Flickable.StopAtBounds

            Item {
                id: grid
                x: (view.width - switcher.gridW) / 2
                width: switcher.gridW
                height: switcher.gridH
                transform: Translate { y: (1 - switcher.reveal) * Theme.dp(10) }

                Repeater {
                    model: switcher.items

                    delegate: Item {
                        id: tile

                        required property var modelData
                        required property int index

                        readonly property bool selected: index === switcher._sel
                        readonly property string title: (modelData && modelData.title) ? modelData.title : ""
                        readonly property string appId: (modelData && modelData.app_id) ? modelData.app_id : ""
                        readonly property string ws: (modelData && modelData.workspace) ? String(modelData.workspace) : ""
                        readonly property string iconPath: switcher.iconFor(appId)

                        x: (index % switcher.cols) * (switcher.tileW + switcher.gap)
                        y: Math.floor(index / switcher.cols) * (switcher.tileH + switcher.gap)
                        width: switcher.tileW
                        height: switcher.tileH

                        MouseArea {
                            id: tap
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                switcher._sel = tile.index;
                                switcher.activate();
                            }
                        }

                        // превью-карточка окна (Lucid: radius rad(18)/rad(12),
                        // фиксированные заливки mHighest/mHigh). Живого захвата
                        // у Umbriel нет,
                        // поэтому внутри — иконка приложения.
                        Rectangle {
                            id: shot

                            width: tile.width
                            height: switcher.thumbH
                            radius: tile.selected ? Theme.rad(18) : Theme.rad(12)
                            color: tile.selected ? Theme.mHighest : Theme.mHigh
                            border.width: tile.selected ? 3 : 0
                            border.color: Theme.primary
                            scale: tap.pressed ? 0.985 : (tile.selected ? 1.03 : 1)

                            Behavior on radius {
                                NumberAnimation {
                                    duration: Theme.durDefaultSpatial
                                    easing.type: Easing.Bezier
                                    easing.bezierCurve: Theme.curveStandard
                                }
                            }
                            Behavior on color { ColorAnimation { duration: Theme.durFastEffects } }
                            Behavior on border.color { ColorAnimation { duration: Theme.durFastEffects } }
                            Behavior on scale {
                                NumberAnimation { duration: Theme.durFastEffects; easing.type: Easing.OutCubic }
                            }

                            // внутренняя карточка — концентрична внешней
                            Rectangle {
                                id: inner

                                anchors.fill: parent
                                anchors.margins: Theme.dp(5)
                                radius: Math.max(Theme.dp(6), shot.radius - Theme.dp(5))
                                color: Theme.bgSunken
                                border.width: tile.selected ? 2 : 1
                                border.color: tile.selected ? Theme.accent : Theme.a(Theme.text, 0.25)

                                AppIcon {
                                    anchors.centerIn: parent
                                    visible: tile.iconPath !== ""
                                    source: tile.iconPath
                                    size: Math.round(Math.min(Theme.dp(56), inner.height * 0.42))
                                }
                                Icon {
                                    anchors.centerIn: parent
                                    visible: tile.iconPath === ""
                                    name: "select_window"
                                    size: Theme.dp(40)
                                    color: tile.selected ? Theme.primary : Theme.subtext
                                }

                                // бейдж воркспейса — сырая строка "DP-1:8"
                                Rectangle {
                                    visible: tile.ws !== ""
                                    anchors.left: parent.left
                                    anchors.bottom: parent.bottom
                                    anchors.margins: Theme.dp(6)
                                    implicitWidth: wsRow.implicitWidth + Theme.dp(14)
                                    height: Theme.dp(22)
                                    radius: Theme.dp(11)
                                    color: tile.selected ? Theme.primary : Theme.a(Theme.mHighest, 0.92)

                                    Row {
                                        id: wsRow
                                        anchors.centerIn: parent
                                        spacing: Theme.dp(4)

                                        Icon {
                                            anchors.verticalCenter: parent.verticalCenter
                                            name: "workspaces"
                                            size: Theme.dp(13)
                                            color: tile.selected ? Theme.fgPrimary : Theme.subtext
                                        }
                                        LText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            role: "labelSmall"
                                            tabular: true
                                            text: tile.ws
                                            color: tile.selected ? Theme.fgPrimary : Theme.text
                                        }
                                    }
                                }
                            }
                        }

                        // подпись: иконка + название
                        Row {
                            anchors.top: shot.bottom
                            anchors.topMargin: Theme.dp(8)
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: tile.width - Theme.dp(8)
                            spacing: Theme.dp(6)

                            AppIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: tile.iconPath !== ""
                                source: tile.iconPath
                                size: Theme.dp(16)
                            }
                            Icon {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: tile.iconPath === ""
                                name: "select_window"
                                size: Theme.dp(16)
                                color: tile.selected ? Theme.primary : Theme.subtext
                            }
                            LText {
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.min(implicitWidth, parent.width - Theme.dp(22))
                                role: "labelLarge"
                                color: tile.selected ? Theme.primary : Theme.text
                                elide: Text.ElideRight
                                text: tile.title !== "" ? tile.title : tile.appId

                                Behavior on color { ColorAnimation { duration: Theme.durFastEffects } }
                            }
                        }

                        Behavior on x {
                            enabled: switcher.glide
                            NumberAnimation {
                                duration: Theme.durFastSpatial
                                easing.type: Easing.Bezier
                                easing.bezierCurve: Theme.curveDefaultSpatial
                            }
                        }
                        Behavior on y {
                            enabled: switcher.glide
                            NumberAnimation {
                                duration: Theme.durFastSpatial
                                easing.type: Easing.Bezier
                                easing.bezierCurve: Theme.curveDefaultSpatial
                            }
                        }
                    }
                }
            }
        }

        // пусто
        Column {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: -switcher.footH / 2
            visible: switcher.count === 0
            spacing: Theme.dp(8)

            Icon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: "select_window"
                size: Theme.dp(36)
                color: Theme.subtext
            }
            LText {
                anchors.horizontalCenter: parent.horizontalCenter
                role: "titleMedium"
                color: Theme.subtext
                text: "Нет окон"
            }
        }

        // footer: счётчик + подсказка
        Item {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: Theme.dp(24)
            anchors.rightMargin: Theme.dp(24)
            height: switcher.footH

            Row {
                id: countRow
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.dp(6)

                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "select_window"
                    size: Theme.dp(16)
                    color: Theme.subtext
                }
                LText {
                    anchors.verticalCenter: parent.verticalCenter
                    role: "labelMedium"
                    color: Theme.subtext
                    text: switcher.count === 1 ? "1 окно" : switcher.count + " окон"
                }
            }

            LText {
                anchors.right: parent.right
                anchors.left: countRow.right
                anchors.leftMargin: Theme.dp(16)
                anchors.verticalCenter: countRow.verticalCenter
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideLeft
                role: "labelMedium"
                color: Theme.subtextDim
                text: switcher.count > 0 ? "Tab — двигать  ·  Enter — перейти  ·  Esc — отмена" : "Esc — закрыть"
            }
        }
    }

    // ── клавиатура ────────────────────────────────────────────────────
    // Фокусируемый прозрачный слой поверх окна; клавиши приходят только при
    // open (mirror PolkitPrompt: OnDemand focus + forceActiveFocus).
    Item {
        id: keyCatcher

        anchors.fill: parent
        focus: switcher.open

        Keys.onPressed: (event) => {
            if (!switcher.open) return;
            if (event.key === Qt.Key_Tab) {
                switcher._step((event.modifiers & Qt.ShiftModifier) ? -1 : 1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Backtab) {
                switcher._step(-1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Right) {
                switcher._step(1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Left) {
                switcher._step(-1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                switcher.activate();
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape) {
                switcher.close();
                event.accepted = true;
            }
        }
        Keys.onReleased: (event) => {
            if (!switcher.open) return;
            // по-виндовому: отпустил Alt — сразу переключаемся на выбранное окно
            if (event.key === Qt.Key_Alt || event.key === Qt.Key_Meta) {
                switcher.activate();
                event.accepted = true;
            }
        }
    }
}
