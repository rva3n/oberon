import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import "../core"
import "../ui"
import "launcher"

// Единая поверхность лончера: вкладки «Приложения / Буфер / Эмодзи / Пакеты»,
// общий поиск и карточка с содержимым активной вкладки. Клавиатура: ↑/↓, Enter, Esc.
FocusScope {
    id: launcher

    property bool active: false
    property var shell: null
    // внешняя вкладка (shell.launcherTab): apps | clipboard | emoji | packages
    property string tab: "apps"

    // внутренняя вкладка живёт отдельно, чтобы клик по чипу не терялся
    property string currentTab: "apps"
    property string query: ""
    property int sel: 0

    readonly property real screenAvailHeight: Screen.desktopAvailableHeight > 0
        ? Screen.desktopAvailableHeight : (Screen.height > 0 ? Screen.height : 900)
    readonly property real screenH: launcher.screenAvailHeight
    // Island caps its content view at 82% of the output; reserve room for the
    // launcher header, search field, card padding, and a small safety margin.
    readonly property int workspaceHeight: Math.max(Theme.dp(240),
        Math.min(Theme.dp(520), Math.round(screenH * 0.78) - Theme.dp(140)))
    // Переключение вкладок не меняет эту высоту; раскрытие/сворачивание острова
    // уже плавно анимирует pill.height в Island.qml через motion-токены Theme.

    readonly property var activeTab: launcher.currentTab === "apps" ? appsTab
                                   : launcher.currentTab === "clipboard" ? clipTab
                                   : launcher.currentTab === "packages" ? pkgTab : emojiTab
    readonly property int count: launcher.activeTab ? launcher.activeTab.count : 0

    visible: active
    focus: active
    Layout.fillWidth: true
    implicitWidth: contentLayout.implicitWidth
    implicitHeight: contentLayout.implicitHeight

    // сброс поиска и выделения
    function resetSearch() {
        launcher.query = "";
        launcher.sel = 0;
        searchField.text = "";
    }
    // применить вкладку (валидные: apps | clipboard | emoji | packages)
    function applyTab(t) {
        const v = (t === "clipboard" || t === "emoji" || t === "packages") ? t : "apps";
        if (launcher.currentTab === v) return;
        launcher.currentTab = v;
        launcher.resetSearch();
    }
    function switchTab(t) {
        launcher.applyTab(t);
        if (launcher.shell) launcher.shell.launcherTab = t;
        if (launcher.active) searchField.forceActiveFocus();
    }
    function setSel(i) {
        launcher.sel = Math.max(0, Math.min(i, launcher.count - 1));
    }
    function moveSelection(delta) {
        const target = launcher.activeTab;
        if (!target || launcher.count <= 0) return;
        if (target.moveSelCols) target.moveSelCols(target.columns, delta);
        else if (target.moveSel) target.moveSel(delta);
    }
    function moveHorizontalSelection(delta) {
        if (launcher.currentTab === "emoji" && emojiTab.count > 0)
            emojiTab.moveSel(delta);
    }
    function handleEscape() {
        if (launcher.currentTab === "packages" && pkgTab.detailsOpen) {
            pkgTab.closeDetails();
            return;
        }
        if (launcher.shell) launcher.shell.closeOverlays();
    }
    function activateSel() {
        if (launcher.activeTab && launcher.count > 0) launcher.activeTab.activate(launcher.sel);
    }

    // при открытии — вкладка из shell.launcherTab (IPC: launcher/clipboard/emoji/packages)
    onActiveChanged: if (launcher.active) {
        launcher.applyTab(launcher.tab);
        launcher.forceActiveFocus();
        searchField.forceActiveFocus();
    }
    onTabChanged: if (launcher.active) launcher.applyTab(launcher.tab)
    onCountChanged: launcher.setSel(launcher.sel) // clamp после смены вкладки/фильтра
    onQueryChanged: launcher.sel = 0

    Keys.onEscapePressed: (event) => {
        launcher.handleEscape();
        event.accepted = true;
    }
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
            launcher.moveSelection(event.key === Qt.Key_Down ? 1 : -1);
            event.accepted = true;
        } else if (!searchField.active && launcher.currentTab === "emoji"
                   && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) {
            launcher.moveHorizontalSelection(event.key === Qt.Key_Right ? 1 : -1);
            event.accepted = true;
        }
    }

    Shortcut {
        sequence: "Ctrl+1"
        enabled: launcher.active
        onActivated: launcher.switchTab("apps")
    }
    Shortcut {
        sequence: "Ctrl+2"
        enabled: launcher.active
        onActivated: launcher.switchTab("clipboard")
    }
    Shortcut {
        sequence: "Ctrl+3"
        enabled: launcher.active
        onActivated: launcher.switchTab("emoji")
    }
    Shortcut {
        sequence: "Ctrl+4"
        enabled: launcher.active
        onActivated: launcher.switchTab("packages")
    }
    Shortcut {
        sequence: "Left"
        enabled: launcher.active && launcher.currentTab === "emoji"
                 && searchField.active && searchField.text === ""
        onActivated: launcher.moveHorizontalSelection(-1)
    }
    Shortcut {
        sequence: "Right"
        enabled: launcher.active && launcher.currentTab === "emoji"
                 && searchField.active && searchField.text === ""
        onActivated: launcher.moveHorizontalSelection(1)
    }

    ColumnLayout {
        id: contentLayout

        anchors.fill: parent
        spacing: Theme.dp(12)

    // ── вкладки; справа — фильтр скрытых (только в приложениях) ───────
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.dp(6)

        Chip {
            id: appsTabChip
            label: "Приложения"; icon: "apps"
            KeyNavigation.tab: clipboardTabChip
            KeyNavigation.backtab: searchField
            selected: launcher.currentTab === "apps"
            onClicked: launcher.switchTab("apps")
        }
        Chip {
            id: clipboardTabChip
            label: "Буфер"; icon: "content_paste"
            KeyNavigation.tab: emojiTabChip
            KeyNavigation.backtab: appsTabChip
            selected: launcher.currentTab === "clipboard"
            onClicked: launcher.switchTab("clipboard")
        }
        Chip {
            id: emojiTabChip
            label: "Эмодзи"; icon: "mood"
            KeyNavigation.tab: packagesTabChip
            KeyNavigation.backtab: clipboardTabChip
            selected: launcher.currentTab === "emoji"
            onClicked: launcher.switchTab("emoji")
        }
        Chip {
            id: packagesTabChip
            label: "Пакеты"; icon: "inventory_2"
            KeyNavigation.tab: hiddenFilterChip.visible ? hiddenFilterChip : searchField
            KeyNavigation.backtab: emojiTabChip
            selected: launcher.currentTab === "packages"
            onClicked: launcher.switchTab("packages")
        }

        Item { Layout.fillWidth: true }

        Chip {
            id: hiddenFilterChip
            visible: launcher.currentTab === "apps"
            label: "Скрытые (" + Apps.hidden.length + ")"
            icon: "visibility"
            KeyNavigation.tab: searchField
            KeyNavigation.backtab: packagesTabChip
            selected: Apps.showHidden
            onClicked: Apps.showHidden = !Apps.showHidden
        }
    }

    // ── поиск: общий для всех вкладок ─────────────────────────────────
    TextField {
        id: searchField

        Layout.fillWidth: true
        activeFocusOnTab: true
        focus: launcher.active
        KeyNavigation.tab: appsTabChip
        KeyNavigation.backtab: hiddenFilterChip.visible ? hiddenFilterChip : packagesTabChip
        placeholder: launcher.currentTab === "apps" ? "Поиск приложений…"
                   : launcher.currentTab === "clipboard" ? "Поиск в буфере…"
                   : launcher.currentTab === "packages" ? "Поиск пакетов…"
                   : "Поиск эмодзи…"
        onTextChanged: launcher.query = searchField.text
        onAccepted: launcher.activateSel()
        onEscaped: launcher.handleEscape()
        Keys.onDownPressed: (event) => {
            launcher.moveSelection(1);
            event.accepted = true;
        }
        Keys.onUpPressed: (event) => {
            launcher.moveSelection(-1);
            event.accepted = true;
        }
    }

    // ── содержимое активной вкладки ───────────────────────────────────
    // Lucid-карточка: размытый surfaceHigh, крупный радиус shapeXl
    Card {
        Layout.fillWidth: true
        Layout.preferredHeight: launcher.workspaceHeight + Theme.dp(20)
        radius: Theme.shapeXl
        pad: Theme.dp(10)
        color: Theme.withBlur(Theme.mHigh)

        Item {
            id: tabWorkspace

            Layout.fillWidth: true
            Layout.preferredHeight: launcher.workspaceHeight
            Layout.minimumHeight: launcher.workspaceHeight
            Layout.maximumHeight: launcher.workspaceHeight
            clip: true

            AppsTab {
                id: appsTab
                anchors.fill: parent
                visible: launcher.currentTab === "apps"
                shell: launcher.shell
                query: launcher.query
                sel: launcher.sel
                onHovered: (i) => launcher.setSel(i)
                onSelectionRequested: (i) => launcher.setSel(i)
            }

            ClipboardTab {
                id: clipTab
                anchors.fill: parent
                visible: launcher.currentTab === "clipboard"
                shell: launcher.shell
                active: launcher.active && launcher.currentTab === "clipboard"
                query: launcher.query
                sel: launcher.sel
                onHovered: (i) => launcher.setSel(i)
                onSelectionRequested: (i) => launcher.setSel(i)
            }

            EmojiTab {
                id: emojiTab
                anchors.fill: parent
                visible: launcher.currentTab === "emoji"
                shell: launcher.shell
                query: launcher.query
                sel: launcher.sel
                onHovered: (i) => launcher.setSel(i)
                onSearchReset: launcher.resetSearch()
                onSelectionRequested: (i) => launcher.setSel(i)
            }

            PackagesTab {
                id: pkgTab
                anchors.fill: parent
                visible: launcher.currentTab === "packages"
                shell: launcher.shell
                active: launcher.active && launcher.currentTab === "packages"
                workspaceHeight: launcher.workspaceHeight
                query: launcher.query
                sel: launcher.sel
                onHovered: (i) => launcher.setSel(i)
                onSelectionRequested: (i) => launcher.setSel(i)
            }
        }
    }
    }
}
