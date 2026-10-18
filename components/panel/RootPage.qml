import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Pipewire
import "../../core"
import ".."
import "../../ui"

// Корневая страница панели в анатомии Material 3 Expressive Control Center:
// слайдеры громкости/яркости (size m, inactive = mHighest, клик по бейджу открывает
// страницы звука/яркости), 2-колоночная настраиваемая сетка практичных быстрых
// настроек (QuickTile с независимым тапом и шевроном) и сгруппированный центр
// уведомлений с бейджем количества, кнопкой «Очистить» и пустым состоянием.
ColumnLayout {
    id: rootPage

    property var win: null

    // ── редактор плиток (QuickTile-карандаш) ────────────────────────────
    property bool tilesEditing: false

    visible: win !== null && win.mode === "panel" && win.page === ""
    Layout.fillWidth: true
    spacing: Theme.pageSpacing

    // ── форматирование времени ──────────────────────────────────────────
    function fmtTimer(sec) {
        const t = Math.max(0, Math.round(sec));
        const m = Math.floor(t / 60);
        const s = t % 60;
        return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s;
    }

    // ── плитки: каталог + порядок/скрытые ──────────────────────────────
    readonly property var tileIds: ["wifi", "bluetooth", "dnd", "nightlight", "darkmode", "timers"]

    readonly property var tileCatalog: [
        { "id": "wifi", "icon": "wifi", "label": "Интернет" },
        { "id": "bluetooth", "icon": "bluetooth", "label": "Bluetooth" },
        { "id": "dnd", "icon": "do_not_disturb_on", "label": "Не беспокоить" },
        { "id": "nightlight", "icon": "bedtime", "label": "Ночной свет" },
        { "id": "darkmode", "icon": "dark_mode", "label": "Тёмная тема" },
        { "id": "timers", "icon": "timer", "label": "Таймер" }
    ]

    property var _tilesOrderOv: null
    property var _tilesHiddenOv: null

    function _parseTileList(s) {
        if (s === undefined || s === null || s === "")
            return null;

        try {
            const v = JSON.parse(String(s));
            return Array.isArray(v) ? v.filter(id => typeof id === "string") : null;
        } catch (e) {
            return null;
        }
    }

    readonly property var _tilesOrderStored: rootPage._composeOrder(rootPage._parseTileList(Prefs.tilesOrder))
    readonly property var _tilesHiddenStored: {
        const stored = rootPage._parseTileList(Prefs.tilesHidden);
        return stored ? stored.filter(id => rootPage._tilesOrderStored.includes(id)) : [];
    }
    readonly property var tilesOrder: rootPage._tilesOrderOv !== null ? rootPage._tilesOrderOv : rootPage._tilesOrderStored
    readonly property var tilesHidden: rootPage._tilesHiddenOv !== null ? rootPage._tilesHiddenOv : rootPage._tilesHiddenStored
    readonly property var tilesVisible: rootPage.tilesOrder.filter(id => rootPage.tilesHidden.indexOf(id) === -1)
    readonly property var tilesAddable: rootPage.tilesOrder.filter(id => rootPage.tilesHidden.indexOf(id) !== -1)

    function _composeOrder(stored) {
        const known = rootPage.tileIds;
        if (!stored)
            return known;

        const kept = stored.filter(id => known.includes(id));
        for (const id of known)
            if (!kept.includes(id))
                kept.push(id);
        return kept;
    }

    function _trySetPref(key, value) {
        try { Prefs.set(key, value); } catch (e) {}
    }

    function persistTiles() {
        if (_tilesOrderOv !== null && typeof Prefs.tilesOrder !== "undefined")
            _trySetPref("tilesOrder", JSON.stringify(_tilesOrderOv));

        if (_tilesHiddenOv !== null && typeof Prefs.tilesHidden !== "undefined")
            _trySetPref("tilesHidden", JSON.stringify(_tilesHiddenOv));
    }

    function hideTile(id) {
        if (rootPage.tilesHidden.indexOf(id) !== -1)
            return;

        if (_tilesOrderOv === null)
            _tilesOrderOv = rootPage.tilesOrder.slice();
        _tilesHiddenOv = rootPage.tilesHidden.concat([id]);
        rootPage.persistTiles();
    }

    function addTile(id) {
        if (rootPage.tilesHidden.indexOf(id) === -1)
            return;

        if (_tilesOrderOv === null)
            _tilesOrderOv = rootPage.tilesOrder.slice();
        _tilesHiddenOv = rootPage.tilesHidden.filter(x => x !== id);
        rootPage.persistTiles();
    }

    function resetTiles() {
        _tilesOrderOv = null;
        _tilesHiddenOv = null;
        if (typeof Prefs.tilesOrder !== "undefined")
            _trySetPref("tilesOrder", "");

        if (typeof Prefs.tilesHidden !== "undefined")
            _trySetPref("tilesHidden", "");
    }

    function tileMeta(id) {
        for (const t of rootPage.tileCatalog)
            if (t.id === id)
                return t;
        return null;
    }

    function tileById(id) {
        return rootPage.tileMeta(id);
    }

    function tileActive(id) {
        switch (id) {
        case "wifi":
            return Sys.wifiEnabled;
        case "bluetooth":
            return Sys.btEnabled;
        case "dnd":
            return Notif.dnd;
        case "nightlight":
            return Boolean(NightLight.enabled !== undefined ? NightLight.enabled : Prefs.nightLightEnabled);
        case "darkmode":
            return Prefs.themeMode !== "light";
        case "timers":
            return Chrono.running;
        }
        return false;
    }

    function tileSub(id) {
        switch (id) {
        case "wifi":
            return Sys.activeSsid !== "" ? Sys.activeSsid : (Sys.wifiEnabled ? "Не подключено" : "Выключен");
        case "bluetooth":
            return Sys.btEnabled
                ? (Sys.btConnected && Sys.btConnected.length > 0 ? Sys.btConnected[0] : "Включён")
                : "Выключен";
        case "dnd":
            return Notif.dnd ? "Включён" : "Выключен";
        case "nightlight":
            return NightLight.temp + " K";
        case "darkmode":
            return Prefs.themeMode === "light" ? "Светлая" : (Prefs.themeMode === "dark" ? "Тёмная" : "Авто");
        case "timers":
            return Chrono.running ? rootPage.fmtTimer(Chrono.remaining) : "Помодоро";
        }
        return "";
    }

    function tileSubtitle(id) {
        return rootPage.tileSub(id);
    }

    function tileExpandable(id) {
        return id === "wifi" || id === "bluetooth" || id === "dnd"
            || id === "nightlight" || id === "darkmode" || id === "timers";
    }

    function tileTap(id) {
        switch (id) {
        case "wifi":
            Sys.toggleWifi();
            return;
        case "bluetooth":
            Sys.toggleBt();
            return;
        case "dnd":
            if (typeof Notif.toggleDnd === "function")
                Notif.toggleDnd();
            else
                Prefs.set("dnd", !Notif.dnd);
            return;
        case "nightlight":
            Prefs.set("nightLightEnabled", !Prefs.nightLightEnabled);
            return;
        case "darkmode": {
            const next = Prefs.themeMode === "light" ? "dark" : "light";
            Prefs.set("themeMode", next);
            Wallpaper.applyThemeOnly();
            return;
        }
        case "timers":
            if (rootPage.win && rootPage.win.shell)
                rootPage.win.shell.setPage("timers");
            return;
        }
    }

    function tileExpand(id) {
        if (!(rootPage.win && rootPage.win.shell))
            return;

        switch (id) {
        case "wifi":
            Sys.refreshWifi();
            rootPage.win.shell.setPage("wifi");
            break;
        case "bluetooth":
            Sys.startBtScan();
            rootPage.win.shell.setPage("bluetooth");
            break;
        case "dnd":
            rootPage.win.shell.setPage("settings", 3);
            break;
        case "nightlight":
            rootPage.win.shell.setPage("settings", 9);
            break;
        case "darkmode":
            rootPage.win.shell.setPage("settings", 8);
            break;
        case "timers":
            rootPage.win.shell.setPage("timers");
            break;
        }
    }

    // ── уведомления: группировка по appName ────────────────────────────
    readonly property int sliceNotifCount: 3

    function groupNotifs(h) {
        const groups = [];
        const byApp = {};
        for (let i = 0; i < h.length; i++) {
            const n = h[i];
            if (!n)
                continue;

            const key = n.appName || "";
            let g = byApp[key];
            if (!g) {
                g = { "app": key, "appLabel": key !== "" ? key : "Без приложения", "appIcon": "", "ts": 0, "items": [] };
                byApp[key] = g;
                groups.push(g);
            }
            if (g.appIcon === "" && n.appIcon && n.appIcon !== "")
                g.appIcon = n.appIcon;
            if (n.ts && n.ts > g.ts)
                g.ts = n.ts;
            g.items.push({ "n": n, "i": i });
        }
        groups.sort((a, b) => b.ts - a.ts);
        return groups;
    }

    readonly property var notifGroups: rootPage.groupNotifs((rootPage.win ? Notif.history : []).slice(0, rootPage.sliceNotifCount))

    // ── плитка быстрого доступа Lucid ──────────────────────────────────
    component QuickTile: Item {
        id: qt

        property string icon: ""
        property string label: ""
        property string subtitle: ""
        property bool active: false
        property bool editing: false
        property bool expandable: true

        signal tapped()
        signal expanded()
        signal removed()

        Layout.fillWidth: true
        implicitHeight: Theme.dp(62)
        scale: qtArea.pressed ? 0.98 : 1

        Behavior on scale {
            NumberAnimation {
                duration: Theme.durFastSpatial
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.curveFastSpatial
            }
        }

        Rectangle {
            id: qtBg

            anchors.fill: parent
            radius: qt.active ? Theme.shapeLgInc : Theme.pill(height)
            color: qt.active ? Theme.accentContainer : Theme.mHighest

            Behavior on radius {
                NumberAnimation {
                    duration: Theme.durDefaultSpatial
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Theme.curveDefaultSpatial
                }
            }

            Behavior on color {
                ColorAnimation {
                    duration: Theme.durDefaultEffects
                }
            }

            StateLayer {
                id: qtArea

                radius: qtBg.radius
                tint: qt.active ? Theme.fgAccentContainer : Theme.text
                onClicked: if (!qt.editing) qt.tapped()
            }
        }

        Rectangle { // бейдж-иконка 42dp
            id: badge

            anchors.left: parent.left
            anchors.leftMargin: Theme.dp(10)
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.dp(42)
            height: Theme.dp(42)
            radius: width / 2
            color: qt.active ? Theme.alpha(Theme.fgAccentContainer, 0.14) : Theme.alpha(Theme.text, 0.08)

            Behavior on color {
                ColorAnimation {
                    duration: Theme.durDefaultEffects
                }
            }

            Icon {
                anchors.centerIn: parent
                name: qt.icon
                size: Theme.dp(21)
                fill: qt.active ? 1 : 0
                color: qt.active ? Theme.fgAccentContainer : Theme.text

                Behavior on color {
                    ColorAnimation {
                        duration: Theme.durDefaultEffects
                    }
                }
            }
        }

        Column { // заголовок + подпись
            anchors.left: badge.right
            anchors.leftMargin: Theme.dp(10)
            anchors.right: chevronSlot.left
            anchors.rightMargin: Theme.dp(2)
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            LText {
                width: parent.width
                role: "titleSmall"
                weight: 600
                text: qt.label
                color: qt.active ? Theme.fgAccentContainer : Theme.text
                elide: Text.ElideRight
            }

            LText {
                width: parent.width
                visible: text !== ""
                role: "bodySmall"
                text: qt.subtitle
                color: qt.active ? Theme.alpha(Theme.fgAccentContainer, 0.78) : Theme.subtext
                elide: Text.ElideRight
            }
        }

        Item { // правый слот: шеврон (клик раскрывает страницу) / «×» в редакторе
            id: chevronSlot

            anchors.right: parent.right
            anchors.rightMargin: Theme.dp(4)
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.dp(34)
            height: qt.height

            Rectangle {
                anchors.centerIn: parent
                width: Theme.dp(28)
                height: Theme.dp(28)
                radius: width / 2
                color: "transparent"
                visible: !qt.editing && qt.expandable

                StateLayer {
                    radius: parent.radius
                    tint: qt.active ? Theme.fgAccentContainer : Theme.text
                    onClicked: qt.expanded()
                }

                Icon {
                    id: chevron

                    anchors.centerIn: parent
                    name: "chevron_right"
                    size: Theme.dp(20)
                    color: qt.active ? Theme.fgAccentContainer : Theme.subtext
                }
            }

            IconButton {
                anchors.centerIn: parent
                visible: qt.editing
                icon: "close"
                size: "xs"
                variant: "filled"
                onClicked: qt.removed()
            }
        }
    }

    // ── 1. Top Sliders (Volume & Brightness) ───────────────────────────
    ColumnLayout {
        Layout.fillWidth: true
        spacing: Theme.dp(10)

        Slider {
            id: volumeSlider

            Layout.fillWidth: true
            size: "m"
            icon: Pipewire.defaultAudioSink && Pipewire.defaultAudioSink.audio.muted ? "volume_off" : "volume_up"
            value: Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.audio.volume : 0
            inactiveColor: Theme.mHighest
            onMoved: (v) => { if (Pipewire.defaultAudioSink) Pipewire.defaultAudioSink.audio.volume = v; }
            onCommitted: (v) => { if (Pipewire.defaultAudioSink) Pipewire.defaultAudioSink.audio.volume = v; }
            onIconClicked: if (rootPage.win && rootPage.win.shell) rootPage.win.shell.togglePage("volume")
        }

        Slider {
            id: brightnessSlider

            Layout.fillWidth: true
            size: "m"
            icon: "brightness_6"
            value: Sys.brightnessFraction
            inactiveColor: Theme.mHighest
            onCommitted: (v) => { Sys.setBrightnessPct(v * 100); }
            onIconClicked: if (rootPage.win && rootPage.win.shell) rootPage.win.shell.togglePage("brightness")
        }
    }

    // ── 2. Practical Quick Settings Tiles Grid (2 columns) ─────────────
    ColumnLayout {
        Layout.fillWidth: true
        spacing: Theme.dp(8)

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(4)

            LText {
                Layout.fillWidth: true
                role: "labelLarge"
                color: Theme.subtext
                text: rootPage.tilesEditing ? "Редактирование плиток" : "Быстрые настройки"
                elide: Text.ElideRight
            }

            Button {
                visible: rootPage.tilesEditing
                variant: "text"
                size: "s"
                icon: "restart_alt"
                text: "По умолчанию"
                onClicked: rootPage.resetTiles()
            }

            IconButton {
                icon: "edit"
                size: "s"
                checkable: true
                checked: rootPage.tilesEditing
                onToggled: (v) => rootPage.tilesEditing = v
            }
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: Theme.dp(10)
            rowSpacing: Theme.dp(10)

            Repeater {
                model: rootPage.tilesVisible

                delegate: QuickTile {
                    required property string modelData

                    editing: rootPage.tilesEditing
                    expandable: rootPage.tileExpandable(modelData)
                    icon: rootPage.tileMeta(modelData) ? rootPage.tileMeta(modelData).icon : ""
                    label: rootPage.tileMeta(modelData) ? rootPage.tileMeta(modelData).label : modelData
                    active: rootPage.tileActive(modelData)
                    subtitle: rootPage.tileSub(modelData)
                    onTapped: rootPage.tileTap(modelData)
                    onExpanded: rootPage.tileExpand(modelData)
                    onRemoved: rootPage.hideTile(modelData)
                }
            }
        }

        Flow { // каталог скрытых плиток в режиме редактирования
            visible: rootPage.tilesEditing && rootPage.tilesAddable.length > 0
            Layout.fillWidth: true
            Layout.leftMargin: Theme.dp(4)
            spacing: Theme.dp(6)

            Repeater {
                model: rootPage.tilesAddable

                delegate: Chip {
                    required property string modelData

                    kind: "assist"
                    icon: "add"
                    label: rootPage.tileMeta(modelData) ? rootPage.tileMeta(modelData).label : modelData
                    onClicked: rootPage.addTile(modelData)
                }
            }
        }

        LText {
            visible: rootPage.tilesEditing && rootPage.tilesVisible.length === 0
            role: "bodySmall"
            color: Theme.subtextDim
            text: "Все плитки скрыты — верните хотя бы одну."
        }
    }

    // ── 3. Grouped Notification Center (Уведомления) ───────────────────
    ColumnLayout {
        Layout.fillWidth: true
        spacing: Theme.dp(8)

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(6)

            LText {
                role: "labelLarge"
                color: Theme.subtext
                text: "Уведомления"
            }

            Badge {
                visible: Notif.history.length > 0
                Layout.alignment: Qt.AlignVCenter
                count: Notif.history.length
            }

            Item {
                Layout.fillWidth: true
            }

            Button {
                visible: Notif.history.length > 0
                variant: "text"
                size: "s"
                icon: "delete"
                text: "Очистить"
                onClicked: Notif.clearAll()
            }
        }

        Card {
            Layout.fillWidth: true

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.dp(10)

                LText {
                    visible: Notif.history.length === 0
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.dp(6)
                    Layout.bottomMargin: Theme.dp(6)
                    horizontalAlignment: Text.AlignHCenter
                    role: "bodySmall"
                    color: Theme.subtextDim
                    text: "Нет новых уведомлений"
                }

                Repeater {
                    model: rootPage.notifGroups

                    delegate: ColumnLayout {
                        required property var modelData

                        Layout.fillWidth: true
                        spacing: 0

                        RowLayout { // заголовок приложения + счётчик
                            Layout.fillWidth: true
                            spacing: Theme.dp(8)

                            Rectangle {
                                Layout.alignment: Qt.AlignVCenter
                                implicitWidth: Theme.dp(20)
                                implicitHeight: Theme.dp(20)
                                radius: Theme.radiusPill
                                color: Theme.accentContainer

                                AppIcon {
                                    anchors.centerIn: parent
                                    visible: modelData.appIcon !== ""
                                    source: modelData.appIcon
                                    size: Theme.dp(14)
                                }

                                Icon {
                                    anchors.centerIn: parent
                                    visible: modelData.appIcon === ""
                                    name: "notifications"
                                    size: Theme.dp(12)
                                    color: Theme.fgAccentContainer
                                }
                            }

                            LText {
                                role: "titleSmall"
                                color: Theme.text
                                elide: Text.ElideRight
                                text: modelData.appLabel
                            }

                            Badge {
                                Layout.alignment: Qt.AlignVCenter
                                count: modelData.items.length
                            }

                            Item {
                                Layout.fillWidth: true
                            }
                        }

                        Repeater {
                            model: modelData.items

                            delegate: NotifItem {
                                required property var modelData

                                Layout.fillWidth: true
                                item: modelData.n
                                itemIndex: modelData.i
                                showApp: false
                            }
                        }
                    }
                }
            }
        }
    }
}
