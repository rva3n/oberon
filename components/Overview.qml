import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "../core"
import "../ui"

// Обзор воркспейсов Umbriel. Отдельное overlay-окно, как Switcher.
PanelWindow {
    id: overview

    property bool shown: false
    property string selectedWorkspaceId: ""

    readonly property var outputScreen: {
        const screens = Quickshell.screens || [];
        const output = Umbriel.activeOutput;
        for (let i = 0; i < screens.length; i++)
            if (screens[i] && screens[i].name === output) return screens[i];
        return screens.length > 0 ? screens[0] : null;
    }
    readonly property var items: {
        const source = Array.isArray(Umbriel.workspaces) ? Umbriel.workspaces : [];
        const output = String(Umbriel.activeOutput || "");
        const result = [];
        for (let i = 0; i < source.length; i++) {
            const ws = source[i];
            if (!ws || (output !== "" && ws.output !== output)) continue;
            result.push(ws);
        }
        result.sort((a, b) => Number(a.index || 0) - Number(b.index || 0));
        return result;
    }

    readonly property real sideMargin: Theme.dp(32)
    readonly property real gap: Theme.dp(14)
    readonly property int columns: {
        const count = Math.max(1, overview.items.length);
        const minCard = Theme.dp(220);
        const fit = Math.max(1, Math.floor((overview.width - 2 * overview.sideMargin + overview.gap)
            / (minCard + overview.gap)));
        return Math.min(4, Math.ceil(Math.sqrt(count)), fit);
    }
    readonly property int rows: Math.ceil(overview.items.length / overview.columns)
    readonly property real cardWidth: Math.max(Theme.dp(200), Math.min(Theme.dp(480),
        (overview.width - 2 * overview.sideMargin - (overview.columns - 1) * overview.gap)
            / overview.columns))
    readonly property real gridAreaHeight: Math.max(Theme.dp(120), overview.height - Theme.dp(164))
    readonly property real cardHeight: Math.max(Theme.dp(150), Math.min(Theme.dp(240),
        (overview.gridAreaHeight - Math.max(0, overview.rows - 1) * overview.gap)
            / Math.max(1, overview.rows)))
    readonly property real gridWidth: overview.columns * overview.cardWidth
        + Math.max(0, overview.columns - 1) * overview.gap
    readonly property real gridHeight: overview.rows * overview.cardHeight
        + Math.max(0, overview.rows - 1) * overview.gap

    readonly property var iconIndex: {
        const byId = {};
        const byClass = {};
        for (const entry of DesktopEntries.applications.values) {
            if (!entry.icon) continue;
            if (entry.id) byId[String(entry.id).toLowerCase()] = entry.icon;
            if (entry.startupClass) byClass[String(entry.startupClass).toLowerCase()] = entry.icon;
        }
        return { byId: byId, byClass: byClass };
    }

    function iconPath(appId) {
        const key = String(appId || "").toLowerCase();
        if (key === "") return "";
        const index = overview.iconIndex;
        const name = index.byId[key] || index.byClass[key] || "";
        return name !== "" ? Quickshell.iconPath(name, true) : "";
    }

    function windowsForWorkspace(workspaceId) {
        const source = Array.isArray(Umbriel.windows) ? Umbriel.windows : [];
        const result = [];
        const id = String(workspaceId || "");
        for (let i = 0; i < source.length; i++) {
            const win = source[i];
            if (win && String(win.workspace || "") === id) result.push(win);
        }
        return result;
    }

    function activeWorkspaceId() {
        for (let i = 0; i < overview.items.length; i++) {
            const ws = overview.items[i];
            if (ws && (ws.active === true || Umbriel.activeWorkspaces[ws.output] === ws.id))
                return String(ws.id || "");
        }
        return overview.items.length > 0 ? String(overview.items[0].id || "") : "";
    }

    readonly property int selectedIndex: {
        const selected = String(overview.selectedWorkspaceId || "");
        for (let i = 0; i < overview.items.length; i++)
            if (String(overview.items[i].id || "") === selected) return i;
        for (let j = 0; j < overview.items.length; j++)
            if (overview.items[j] && overview.items[j].active === true) return j;
        return overview.items.length > 0 ? 0 : -1;
    }

    function selectIndex(index) {
        if (overview.items.length === 0) return;
        const i = Math.max(0, Math.min(overview.items.length - 1, index));
        overview.selectedWorkspaceId = String(overview.items[i].id || "");
    }

    function moveSelection(delta) {
        if (overview.selectedIndex < 0) return;
        overview.selectIndex(overview.selectedIndex + delta);
    }

    function pickWorkspace(index) {
        if (index < 0 || index >= overview.items.length) return;
        const ws = overview.items[index];
        const output = String(ws.output || "");
        let selector = "";
        if (ws.named === true) {
            selector = String(ws.name || "");
            if (/^\d+$/.test(selector)) selector = "\"" + selector + "\"";
        } else if (ws.index !== undefined && ws.index !== null) {
            selector = String(ws.index);
        } else {
            selector = String(ws.name || "");
        }
        if (selector === "") return;
        const action = "workspace-switch:" + selector + (output !== "" ? "/" + output : "");
        Quickshell.execDetached(["umbriel", "msg", action]);
        overview.close();
    }

    function focusWindow(win) {
        const id = win && win.id !== undefined && win.id !== null ? String(win.id) : "";
        if (id === "") return;
        Quickshell.execDetached(["umbriel", "msg", "window-focus:" + id]);
        overview.close();
    }

    function closeWindow(win) {
        const id = win && win.id !== undefined && win.id !== null ? String(win.id) : "";
        if (id !== "") Quickshell.execDetached(["umbriel", "msg", "window-close:" + id]);
    }

    function open() { overview.shown = true; }

    function close() {
        overview.shown = false;
    }

    onItemsChanged: {
        let found = false;
        for (let i = 0; i < overview.items.length; i++)
            if (String(overview.items[i].id || "") === overview.selectedWorkspaceId) found = true;
        if (!found) overview.selectedWorkspaceId = overview.activeWorkspaceId();
    }
    onShownChanged: {
        if (overview.shown) {
            overview.selectedWorkspaceId = overview.activeWorkspaceId();
            stage.forceActiveFocus();
        }
    }

    screen: overview.outputScreen
    visible: overview.shown
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusiveZone: 0
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "oberon-overview"
    WlrLayershell.keyboardFocus: overview.shown ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    Item {
        id: stage
        anchors.fill: parent
        focus: overview.shown

        Keys.onPressed: (event) => {
            if (!overview.shown) return;
            if (event.key === Qt.Key_Escape) {
                overview.close();
                event.accepted = true;
            } else if (event.key === Qt.Key_Left) {
                overview.moveSelection(-1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Right) {
                overview.moveSelection(1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Up) {
                overview.moveSelection(-overview.columns);
                event.accepted = true;
            } else if (event.key === Qt.Key_Down) {
                overview.moveSelection(overview.columns);
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                overview.pickWorkspace(overview.selectedIndex);
                event.accepted = true;
            }
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.alpha(Theme.cShadow, Theme.blurPct > 0 ? 0.28 : 0.48)

            MouseArea {
                anchors.fill: parent
                onClicked: overview.close()
            }
        }

        LText {
            anchors.top: parent.top
            anchors.topMargin: Theme.dp(24)
            anchors.horizontalCenter: parent.horizontalCenter
            role: "titleLarge"
            color: Theme.text
            text: "Рабочие столы"
        }

        Flickable {
            id: viewport
            x: overview.sideMargin
            y: Theme.dp(76)
            width: Math.max(0, overview.width - overview.sideMargin * 2)
            height: overview.gridAreaHeight
            contentWidth: width
            contentHeight: Math.max(height, grid.height)
            clip: true
            interactive: contentHeight > height + 1
            boundsBehavior: Flickable.StopAtBounds

            MouseArea {
                anchors.fill: parent
                onClicked: overview.close()
            }

            Item {
                id: grid
                x: Math.max(0, (viewport.width - width) / 2)
                y: height < viewport.height ? (viewport.height - height) / 2 : 0
                width: overview.gridWidth
                height: overview.gridHeight

                Repeater {
                    model: overview.items

                    delegate: Rectangle {
                        id: workspaceCard
                        required property var modelData
                        required property int index

                        readonly property string workspaceId: String(modelData.id || "")
                        readonly property bool active: modelData.active === true
                            || Umbriel.activeWorkspaces[modelData.output] === modelData.id
                        readonly property bool selected: overview.selectedWorkspaceId === workspaceId
                        readonly property var windows: overview.windowsForWorkspace(workspaceId)

                        x: (index % overview.columns) * (overview.cardWidth + overview.gap)
                        y: Math.floor(index / overview.columns) * (overview.cardHeight + overview.gap)
                        width: overview.cardWidth
                        height: overview.cardHeight
                        radius: Theme.rad(18)
                        color: workspaceCard.active ? Theme.mHigh : Theme.bgSunken
                        border.width: workspaceCard.selected ? Theme.dp(2) : (workspaceCard.active ? 1 : 0)
                        border.color: workspaceCard.selected ? Theme.primary
                            : Theme.alpha(Theme.primary, workspaceCard.active ? 0.42 : 0)
                        clip: true

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: overview.selectedWorkspaceId = workspaceCard.workspaceId
                            onClicked: overview.pickWorkspace(workspaceCard.index)
                        }

                        RowLayout {
                            id: workspaceHeader
                            x: Theme.dp(12)
                            y: Theme.dp(10)
                            width: parent.width - Theme.dp(24)
                            height: Theme.dp(30)
                            spacing: Theme.dp(8)

                            Icon {
                                Layout.alignment: Qt.AlignVCenter
                                name: "workspaces"
                                size: Theme.dp(18)
                                color: workspaceCard.active ? Theme.primary : Theme.subtext
                            }
                            LText {
                                Layout.alignment: Qt.AlignVCenter
                                Layout.fillWidth: true
                                role: "titleSmall"
                                color: Theme.text
                                text: String(workspaceCard.modelData.name || workspaceCard.modelData.index || "")
                            }
                            LText {
                                Layout.alignment: Qt.AlignVCenter
                                role: "labelSmall"
                                color: workspaceCard.active ? Theme.primary : Theme.subtext
                                text: workspaceCard.active ? "ТЕКУЩИЙ" : (workspaceCard.windows.length + " окон")
                            }
                        }

                        ListView {
                            id: windowList
                            x: Theme.dp(10)
                            y: Theme.dp(48)
                            width: parent.width - Theme.dp(20)
                            height: parent.height - Theme.dp(56)
                            model: workspaceCard.windows
                            spacing: Theme.dp(5)
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds

                            delegate: Item {
                                id: windowCard
                                required property var modelData
                                required property int index

                                readonly property string appId: String(modelData.app_id || "")
                                readonly property string title: String(modelData.title || "")
                                readonly property string icon: overview.iconPath(appId)

                                width: windowList.width
                                height: Theme.dp(42)

                                Rectangle {
                                    anchors.fill: parent
                                    radius: Theme.rad(10)
                                    color: Theme.bgSunken
                                    border.width: 1
                                    border.color: Theme.alpha(Theme.text, 0.08)
                                }

                                // Umbriel's current windows JSON has no Wayland object. If it
                                // gains one, use it directly; otherwise the icon/title below is
                                // the intentional fallback.
                                ScreencopyView {
                                    id: livePreview
                                    anchors.fill: parent
                                    captureSource: windowCard.modelData && windowCard.modelData.wayland
                                        ? windowCard.modelData.wayland : null
                                    live: true
                                    paintCursor: false
                                    visible: hasContent
                                    smooth: true
                                    antialiasing: true
                                    layer.enabled: true
                                    layer.smooth: true
                                    layer.mipmap: true
                                }

                                Rectangle {
                                    anchors.fill: parent
                                    visible: livePreview.hasContent
                                    color: Theme.alpha(Theme.bg, 0.48)
                                }

                                Row {
                                    anchors.fill: parent
                                    anchors.leftMargin: Theme.dp(8)
                                    anchors.rightMargin: Theme.dp(34)
                                    spacing: Theme.dp(8)

                                    AppIcon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: windowCard.icon !== ""
                                        source: windowCard.icon
                                        size: Theme.dp(20)
                                    }
                                    Icon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: windowCard.icon === ""
                                        name: "select_window"
                                        size: Theme.dp(20)
                                        color: Theme.subtext
                                    }
                                    Column {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - Theme.dp(30)
                                        spacing: 0

                                        LText {
                                            width: parent.width
                                            role: "labelMedium"
                                            color: Theme.text
                                            elide: Text.ElideRight
                                            text: windowCard.title !== "" ? windowCard.title : windowCard.appId
                                        }
                                        LText {
                                            width: parent.width
                                            visible: windowCard.appId !== ""
                                            role: "labelSmall"
                                            color: Theme.subtext
                                            elide: Text.ElideRight
                                            text: windowCard.appId
                                        }
                                    }
                                }

                                MouseArea {
                                    id: windowTap
                                    anchors.fill: parent
                                    z: 2
                                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: (mouse) => {
                                        overview.selectedWorkspaceId = workspaceCard.workspaceId;
                                        if (mouse.button === Qt.MiddleButton) overview.closeWindow(windowCard.modelData);
                                        else overview.focusWindow(windowCard.modelData);
                                    }
                                }

                                Item {
                                    id: closeButton
                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.dp(4)
                                    anchors.verticalCenter: parent.verticalCenter
                                    z: 3
                                    width: Theme.dp(28)
                                    height: Theme.dp(28)

                                    Icon {
                                        anchors.centerIn: parent
                                        name: "close"
                                        size: Theme.dp(16)
                                        color: Theme.subtext
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: overview.closeWindow(windowCard.modelData)
                                    }
                                }
                            }
                        }

                        Column {
                            anchors.centerIn: parent
                            anchors.verticalCenterOffset: Theme.dp(10)
                            visible: workspaceCard.windows.length === 0
                            spacing: Theme.dp(6)

                            Icon {
                                anchors.horizontalCenter: parent.horizontalCenter
                                name: "select_window"
                                size: Theme.dp(26)
                                color: Theme.subtext
                            }
                            LText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                role: "labelMedium"
                                color: Theme.subtext
                                text: "Пустой воркспейс"
                            }
                        }
                    }
                }
            }
        }

        LText {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Theme.dp(18)
            anchors.horizontalCenter: parent.horizontalCenter
            role: "labelMedium"
            color: Theme.subtext
            text: "Стрелки — выбрать  ·  Enter — перейти  ·  Клик по окну — фокус  ·  Средний клик — закрыть  ·  Esc — закрыть"
        }

        LText {
            anchors.centerIn: parent
            visible: overview.items.length === 0
            role: "titleMedium"
            color: Theme.subtext
            text: "Нет доступных рабочих столов"
        }
    }
}
