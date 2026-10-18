import QtQuick
import QtQuick.Layouts
import "../../core"
import ".."
import "../../ui" as Ui

// Multi-source wallpaper browser & search engine:
// Wallhaven (photos + rich filters/colors/pagination), MotionBGs (live videos + categories/pagination),
// Local Photos & Local Videos (filtered local scan + auto-rotation controls).
ColumnLayout {
    id: wallpapersPage

    property var win: null
    property string localFilter: ""

    readonly property var filteredPhotos: {
        const q = wallpapersPage.localFilter.trim().toLowerCase();
        if (q.length === 0) return Wallpaper.photos;
        return Wallpaper.photos.filter(it => (it.name || "").toLowerCase().indexOf(q) !== -1 || (it.path || "").toLowerCase().indexOf(q) !== -1);
    }

    readonly property var filteredVideos: {
        const q = wallpapersPage.localFilter.trim().toLowerCase();
        if (q.length === 0) return Wallpaper.videos;
        return Wallpaper.videos.filter(it => (it.name || "").toLowerCase().indexOf(q) !== -1 || (it.path || "").toLowerCase().indexOf(q) !== -1);
    }

    readonly property bool isBusy: Wallpaper.whBusy || Wallpaper.motionBusy || Wallpaper.applying || Wallpaper.localBusy

    visible: win !== null && win.mode === "panel" && win.page === "wallpapers"
    Layout.fillWidth: true
    spacing: Theme.dp(8)

    function switchTab(nextTab) {
        searchDebounce.stop();
        Wallpaper.tab = nextTab;
        if (nextTab === "wallhaven") {
            searchField.text = Wallpaper.whQuery;
            if (Wallpaper.results.length === 0 && !Wallpaper.whBusy)
                Wallpaper.searchWallhaven(Wallpaper.whQuery);
        } else if (nextTab === "motion") {
            searchField.text = Wallpaper.motionQuery;
            if (Wallpaper.motionResults.length === 0 && !Wallpaper.motionBusy)
                Wallpaper.motionSearch(Wallpaper.motionQuery);
        } else {
            searchField.text = wallpapersPage.localFilter;
            if (Wallpaper.localItems.length === 0 && !Wallpaper.localBusy)
                Wallpaper.refreshLocal();
        }
    }

    Timer {
        id: searchDebounce
        interval: 400
        repeat: false
        onTriggered: {
            if (Wallpaper.tab === "wallhaven")
                Wallpaper.searchWallhaven(searchField.text);
            else if (Wallpaper.tab === "motion")
                Wallpaper.motionSearch(searchField.text);
        }
    }

    // ── 1. Top Source Tabs (ui/Chip) ───────────────────────────────────
    Flow {
        Layout.fillWidth: true
        spacing: Theme.dp(6)

        Ui.Chip {
            size: "sm"
            kind: "assist"
            icon: "public"
            label: "Wallhaven"
            selected: Wallpaper.tab === "wallhaven"
            onClicked: wallpapersPage.switchTab("wallhaven")
        }

        Ui.Chip {
            size: "sm"
            kind: "assist"
            icon: "movie"
            label: "Живые (MotionBGs)"
            selected: Wallpaper.tab === "motion"
            onClicked: wallpapersPage.switchTab("motion")
        }

        Ui.Chip {
            size: "sm"
            kind: "assist"
            icon: "image"
            label: "Локальные фото (" + Wallpaper.photos.length + ")"
            selected: Wallpaper.tab === "photos"
            onClicked: wallpapersPage.switchTab("photos")
        }

        Ui.Chip {
            size: "sm"
            kind: "assist"
            icon: "videocam"
            label: "Локальные видео (" + Wallpaper.videos.length + ")"
            selected: Wallpaper.tab === "videos"
            onClicked: wallpapersPage.switchTab("videos")
        }
    }

    // ── 2. Search Bar + Action Row ─────────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.dp(6)

        Ui.TextField {
            id: searchField
            variant: "search"
            Layout.fillWidth: true
            placeholder: Wallpaper.tab === "wallhaven" ? "Поиск обоев Wallhaven (anime, cyberpunk, nature…)"
                       : Wallpaper.tab === "motion" ? "Поиск живых обоев MotionBGs…"
                       : "Фильтр по имени файла…"
            onTextEdited: {
                if (Wallpaper.tab === "wallhaven") {
                    Wallpaper.whQuery = text;
                    searchDebounce.restart();
                } else if (Wallpaper.tab === "motion") {
                    Wallpaper.motionQuery = text;
                    searchDebounce.restart();
                } else {
                    wallpapersPage.localFilter = text;
                }
            }
            onAccepted: {
                searchDebounce.stop();
                if (Wallpaper.tab === "wallhaven")
                    Wallpaper.searchWallhaven(text);
                else if (Wallpaper.tab === "motion")
                    Wallpaper.motionSearch(text);
                else
                    wallpapersPage.localFilter = text;
            }
        }

        Ui.IconButton {
            icon: "shuffle"
            size: "s"
            variant: "tonal"
            tooltip: "Случайные"
            onClicked: {
                if (Wallpaper.tab === "wallhaven") {
                    Wallpaper.whSorting = "random";
                    Wallpaper.searchWallhaven(Wallpaper.whQuery);
                } else if (Wallpaper.tab === "motion") {
                    if (Wallpaper.motionResults.length > 0) {
                        const it = Wallpaper.motionResults[Math.floor(Math.random() * Wallpaper.motionResults.length)];
                        Wallpaper.applyVideoUrl(it.video);
                    } else {
                        Wallpaper.motionGoPage(Math.floor(Math.random() * 5) + 1);
                    }
                } else {
                    Wallpaper.nextRandom();
                }
            }
        }

        Ui.IconButton {
            icon: "refresh"
            size: "s"
            variant: "standard"
            tooltip: "Обновить"
            onClicked: {
                if (Wallpaper.tab === "wallhaven")
                    Wallpaper.searchWallhaven(Wallpaper.whQuery);
                else if (Wallpaper.tab === "motion")
                    Wallpaper.motionSearch(Wallpaper.motionQuery);
                else
                    Wallpaper.refreshLocal();
            }
        }
    }

    // ── 3A. Wallhaven Filters ──────────────────────────────────────────
    Ui.Card {
        visible: Wallpaper.tab === "wallhaven"
        Layout.fillWidth: true
        pad: Theme.dp(10)

        // Row 1: Categories (multi-toggle) + Purity + Aspect Ratios + Minimum Resolution
        Flow {
            Layout.fillWidth: true
            spacing: Theme.dp(5)

            Ui.Chip {
                size: "sm"
                horizontalPadding: 7
                label: "General"
                selected: Wallpaper.whCategories.charAt(0) === "1"
                onClicked: Wallpaper.toggleWhCategory(0)
            }
            Ui.Chip {
                size: "sm"
                horizontalPadding: 7
                label: "Anime"
                selected: Wallpaper.whCategories.charAt(1) === "1"
                onClicked: Wallpaper.toggleWhCategory(1)
            }
            Ui.Chip {
                size: "sm"
                horizontalPadding: 7
                label: "People"
                selected: Wallpaper.whCategories.charAt(2) === "1"
                onClicked: Wallpaper.toggleWhCategory(2)
            }

            Rectangle {
                width: 1
                height: Theme.dp(20)
                color: Theme.outlineVariant
            }

            Ui.Chip {
                size: "sm"
                horizontalPadding: 7
                kind: "assist"
                label: "SFW"
                selected: Wallpaper.whPurity === "100"
                onClicked: {
                    Wallpaper.whPurity = "100";
                    Wallpaper.searchWallhaven();
                }
            }
            Ui.Chip {
                size: "sm"
                horizontalPadding: 7
                kind: "assist"
                label: "Sketchy"
                selected: Wallpaper.whPurity === "110"
                onClicked: {
                    Wallpaper.whPurity = Wallpaper.whPurity === "110" ? "100" : "110";
                    Wallpaper.searchWallhaven();
                }
            }

            Rectangle {
                width: 1
                height: Theme.dp(20)
                color: Theme.outlineVariant
            }

            Ui.Chip {
                size: "sm"
                horizontalPadding: 7
                kind: "assist"
                label: "Все"
                selected: Wallpaper.whRatios === ""
                onClicked: {
                    Wallpaper.whRatios = "";
                    Wallpaper.searchWallhaven();
                }
            }
            Ui.Chip {
                size: "sm"
                horizontalPadding: 7
                kind: "assist"
                label: "16:9"
                selected: Wallpaper.whRatios === "16x9,16x10" || Wallpaper.whRatios === "16x9"
                onClicked: {
                    Wallpaper.whRatios = "16x9,16x10";
                    Wallpaper.searchWallhaven();
                }
            }
            Ui.Chip {
                size: "sm"
                horizontalPadding: 7
                kind: "assist"
                label: "21:9"
                selected: Wallpaper.whRatios === "21x9"
                onClicked: {
                    Wallpaper.whRatios = "21x9";
                    Wallpaper.searchWallhaven();
                }
            }

            Rectangle {
                width: 1
                height: Theme.dp(20)
                color: Theme.outlineVariant
            }

            Repeater {
                model: [
                    { key: "", label: "Любое" },
                    { key: "1920x1080", label: "1080p+" },
                    { key: "2560x1440", label: "2K+" },
                    { key: "3840x2160", label: "4K+" }
                ]
                delegate: Ui.Chip {
                    required property var modelData
                    size: "sm"
                    horizontalPadding: 7
                    kind: "assist"
                    label: modelData.label
                    selected: Wallpaper.whAtleast === modelData.key
                    onClicked: {
                        Wallpaper.whAtleast = modelData.key;
                        Wallpaper.searchWallhaven();
                    }
                }
            }
        }

        // Row 2: Sorting + Top Range (when Топ active)
        Flow {
            Layout.fillWidth: true
            spacing: Theme.dp(5)

            Repeater {
                model: [
                    { key: "toplist", label: "Топ" },
                    { key: "hot", label: "Горячее" },
                    { key: "date_added", label: "Новое" },
                    { key: "views", label: "Просмотры" },
                    { key: "favorites", label: "Избранное" },
                    { key: "random", label: "Случайные" }
                ]
                delegate: Ui.Chip {
                    required property var modelData
                    size: "sm"
                    horizontalPadding: 7
                    kind: "assist"
                    label: modelData.label
                    selected: Wallpaper.whSorting === modelData.key
                    onClicked: {
                        Wallpaper.whSorting = modelData.key;
                        Wallpaper.searchWallhaven();
                    }
                }
            }

            Rectangle {
                visible: Wallpaper.whSorting === "toplist"
                width: 1
                height: Theme.dp(20)
                color: Theme.outlineVariant
            }

            Repeater {
                model: Wallpaper.whSorting === "toplist" ? [
                    { key: "1d", label: "1д" },
                    { key: "1w", label: "1н" },
                    { key: "1M", label: "1м" },
                    { key: "3M", label: "3м" },
                    { key: "1y", label: "1г" },
                    { key: "", label: "Все" }
                ] : []
                delegate: Ui.Chip {
                    required property var modelData
                    size: "sm"
                    horizontalPadding: 6
                    kind: "assist"
                    label: modelData.label
                    selected: Wallpaper.whTopRange === modelData.key
                    onClicked: {
                        Wallpaper.whTopRange = modelData.key;
                        Wallpaper.searchWallhaven();
                    }
                }
            }
        }

        // Row 3: Dominant Color Palette Strip (All reset + 12 key Wallhaven colors)
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(5)

            // Reset ("All") circle
            Rectangle {
                width: Theme.dp(20)
                height: Theme.dp(20)
                radius: Theme.dp(10)
                color: Wallpaper.whColor === "" ? Theme.secondaryContainer : Theme.bgTrack
                border.width: Wallpaper.whColor === "" ? 2 : 1
                border.color: Wallpaper.whColor === "" ? Theme.primary : Theme.outline

                Ui.Icon {
                    anchors.centerIn: parent
                    name: "palette"
                    size: Theme.dp(12)
                    color: Wallpaper.whColor === "" ? Theme.fgSecondaryContainer : Theme.subtext
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (Wallpaper.whColor !== "") {
                            Wallpaper.whColor = "";
                            Wallpaper.searchWallhaven();
                        }
                    }
                }
            }

            Repeater {
                model: [
                    "cc0000", "ea4c88", "993399", "663399",
                    "0066cc", "0099cc", "77cc33", "ffcc33",
                    "ff6600", "996633", "424153", "000000"
                ]
                delegate: Rectangle {
                    required property string modelData
                    readonly property bool active: Wallpaper.whColor === modelData

                    width: Theme.dp(20)
                    height: Theme.dp(20)
                    radius: Theme.dp(10)
                    color: "#" + modelData
                    scale: active ? 1.15 : 1.0
                    border.width: active ? 2 : 1
                    border.color: active ? Theme.text : Theme.a(Theme.outline, 0.5)

                    Behavior on scale {
                        NumberAnimation {
                            duration: Theme.durFastSpatial
                            easing.type: Easing.OutCubic
                        }
                    }

                    Ui.Icon {
                        visible: parent.active
                        anchors.centerIn: parent
                        name: "check"
                        size: Theme.dp(12)
                        color: modelData === "ffcc33" || modelData === "77cc33" ? "#111318" : "#ffffff"
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            Wallpaper.whColor = (Wallpaper.whColor === modelData) ? "" : modelData;
                            Wallpaper.searchWallhaven();
                        }
                    }
                }
            }

            Item { Layout.fillWidth: true }
        }
    }

    // ── 3B. MotionBGs Category Bar ─────────────────────────────────────
    Ui.Card {
        visible: Wallpaper.tab === "motion"
        Layout.fillWidth: true
        pad: Theme.dp(10)

        Flow {
            Layout.fillWidth: true
            spacing: Theme.dp(5)

            Repeater {
                model: [
                    { key: "", label: "Популярные" },
                    { key: "anime", label: "Аниме" },
                    { key: "games", label: "Игры" },
                    { key: "cyberpunk", label: "Киберпанк" },
                    { key: "nature", label: "Природа" },
                    { key: "space", label: "Космос" },
                    { key: "car", label: "Авто" },
                    { key: "fantasy", label: "Фэнтези" },
                    { key: "dark", label: "Тёмные" }
                ]
                delegate: Ui.Chip {
                    required property var modelData
                    size: "sm"
                    kind: "assist"
                    label: modelData.label
                    selected: Wallpaper.motionCategory === modelData.key && Wallpaper.motionQuery.trim() === ""
                    onClicked: {
                        searchField.text = "";
                        Wallpaper.motionSetCategory(modelData.key);
                    }
                }
            }
        }
    }

    // ── 3C. Local Photos / Videos Auto-rotation Card ───────────────────
    Ui.Card {
        visible: Wallpaper.tab === "photos" || Wallpaper.tab === "videos"
        Layout.fillWidth: true
        pad: Theme.dp(10)

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            Ui.Icon {
                name: "autorenew"
                size: Theme.dp(18)
                color: Wallpaper.autoEnabled ? Theme.primary : Theme.subtext
            }

            Ui.LText {
                Layout.fillWidth: true
                role: "labelLarge"
                color: Theme.text
                text: "Автосмена обоев"
            }

            Ui.Chip {
                size: "sm"
                kind: "assist"
                icon: "folder_open"
                label: "Обновить папку"
                onClicked: Wallpaper.refreshLocal()
            }

            Ui.Switch {
                checked: Wallpaper.autoEnabled
                onToggled: (v) => {
                    Wallpaper.autoEnabled = v;
                    Wallpaper.saveState();
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            Ui.LText {
                role: "labelSmall"
                color: Theme.subtext
                text: "1м"
            }

            Ui.Slider {
                Layout.fillWidth: true
                value: (Wallpaper.autoMinutes - 1) / 1439
                onMoved: (v) => {
                    if (win && win.setAuto) {
                        win.setAuto(v);
                    } else {
                        Wallpaper.autoMinutes = Math.max(1, Math.min(1440, Math.round(1 + v * 1439)));
                        Wallpaper.saveState();
                    }
                }
            }

            Ui.LText {
                role: "labelSmall"
                color: Theme.subtext
                text: "24ч"
            }

            Ui.LText {
                Layout.preferredWidth: Theme.dp(52)
                horizontalAlignment: Text.AlignRight
                role: "labelSmall"
                color: Theme.text
                text: win ? win.autoLabel : (Wallpaper.autoMinutes + "м")
            }
        }
    }

    // ── 4. Wallpaper Grid ──────────────────────────────────────────────
    Item {
        Layout.fillWidth: true
        Layout.preferredHeight: Theme.dp(390)

        GridView {
            id: wpGrid

            readonly property int cols: width >= Theme.dp(720) ? 4 : 3

            anchors.fill: parent
            clip: true
            cellWidth: Math.floor(width / cols)
            cellHeight: Math.round(cellWidth * 0.58)

            model: Wallpaper.tab === "photos" ? wallpapersPage.filteredPhotos
                 : Wallpaper.tab === "videos" ? wallpapersPage.filteredVideos
                 : Wallpaper.tab === "motion" ? Wallpaper.motionResults
                 : Wallpaper.results

            delegate: Rectangle {
                id: cell

                required property var modelData

                readonly property bool selected: {
                    if (!Wallpaper.currentPath || Wallpaper.currentPath.length === 0) return false;
                    if (Wallpaper.tab === "wallhaven")
                        return (modelData.id && Wallpaper.currentPath.indexOf("/" + modelData.id + ".") !== -1) || Wallpaper.currentPath === modelData.path;
                    if (Wallpaper.tab === "motion")
                        return (modelData.id && Wallpaper.currentPath.indexOf("motion-" + modelData.id) !== -1) || Wallpaper.currentPath === modelData.video;
                    return Wallpaper.currentPath === modelData.path;
                }

                readonly property bool useThumb: Wallpaper.tab === "wallhaven" || Wallpaper.tab === "motion"
                readonly property bool isVideoItem: Wallpaper.tab === "motion" || Wallpaper.tab === "videos" || !!modelData.video
                readonly property bool localVideo: !cell.useThumb && !!modelData.video
                readonly property string badgeText: {
                    if (Wallpaper.tab === "motion" || cell.isVideoItem)
                        return "LIVE";
                    if (modelData.resolution && String(modelData.resolution).length > 0)
                        return String(modelData.resolution).replace("x", "×");
                    return "";
                }

                width: Math.max(Theme.dp(96), wpGrid.cellWidth - Theme.dp(8))
                height: Math.max(Theme.dp(56), wpGrid.cellHeight - Theme.dp(8))
                radius: Theme.shapeLg
                color: Theme.bgTile
                clip: true
                scale: cell.selected ? 1.03 : 1
                z: cell.selected ? 2 : 0

                Behavior on scale {
                    NumberAnimation {
                        duration: Theme.durDefaultSpatial
                        easing.type: Easing.Bezier
                        easing.bezierCurve: Theme.curveDefaultSpatial
                    }
                }

                Image {
                    anchors.fill: parent
                    visible: !cell.localVideo
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    source: cell.localVideo ? "" : (cell.useThumb ? modelData.thumb : ("file://" + modelData.path))
                }

                Rectangle {
                    visible: cell.localVideo
                    anchors.fill: parent
                    color: Theme.bgTrack

                    Column {
                        anchors.centerIn: parent
                        spacing: Theme.dp(2)

                        Ui.Icon {
                            anchors.horizontalCenter: parent.horizontalCenter
                            name: "movie"
                            size: Theme.dp(24)
                            color: Theme.subtext
                        }

                        Ui.LText {
                            width: Math.max(Theme.dp(80), cell.width - Theme.dp(16))
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideMiddle
                            role: "labelSmall"
                            color: Theme.subtext
                            text: modelData.name || ""
                        }
                    }
                }

                Rectangle {
                    visible: cell.isVideoItem
                    anchors.fill: parent
                    radius: parent.radius
                    color: Theme.alpha(Theme.shadow, 0.35)

                    Ui.Icon {
                        anchors.centerIn: parent
                        name: "play_circle"
                        size: Theme.dp(24)
                        color: Theme.text
                    }
                }

                // Resolution / LIVE badge
                Rectangle {
                    visible: cell.badgeText !== ""
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.margins: Theme.dp(4)
                    height: Theme.dp(16)
                    width: resLabel.implicitWidth + Theme.dp(8)
                    radius: Theme.dp(5)
                    color: cell.badgeText === "LIVE" ? Theme.alpha(Theme.primary, 0.88) : Theme.alpha(Theme.shadow, 0.72)

                    Ui.LText {
                        id: resLabel
                        anchors.centerIn: parent
                        role: "labelSmall"
                        color: cell.badgeText === "LIVE" ? Theme.fgPrimary : "#ffffff"
                        text: cell.badgeText
                    }
                }

                // Hover state layer
                Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    color: Theme.text
                    opacity: wpMouse.containsMouse ? Theme.stateHover : 0

                    Behavior on opacity {
                        NumberAnimation {
                            duration: Theme.ms(100)
                            easing.type: Theme.easeStandard
                        }
                    }
                }

                // Selected outline
                Rectangle {
                    visible: cell.selected
                    anchors.fill: parent
                    radius: parent.radius
                    color: "transparent"
                    border.width: 2
                    border.color: Theme.accent
                }

                // Selected check badge
                Rectangle {
                    visible: cell.selected
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.margins: Theme.dp(4)
                    width: Theme.dp(20)
                    height: Theme.dp(20)
                    radius: Theme.radiusPill
                    color: Theme.accentContainer
                    border.width: 1
                    border.color: Theme.a(Theme.accent, 0.45)

                    Ui.Icon {
                        anchors.centerIn: parent
                        name: "check"
                        size: Theme.dp(13)
                        color: Theme.fgAccentContainer
                    }
                }

                MouseArea {
                    id: wpMouse

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (Wallpaper.tab === "wallhaven")
                            Wallpaper.applyWallhaven(modelData);
                        else if (Wallpaper.tab === "motion")
                            Wallpaper.applyVideoUrl(modelData.video);
                        else
                            Wallpaper.apply(modelData.path, !!modelData.video);
                    }
                }
            }

            Ui.LText {
                anchors.centerIn: parent
                visible: wpGrid.count === 0 && !wallpapersPage.isBusy
                role: "bodyMedium"
                color: Theme.subtext
                text: "Ничего не найдено"
            }
        }

        // Loading / applying overlay badge
        Rectangle {
            visible: Wallpaper.whBusy || Wallpaper.motionBusy || Wallpaper.applying
            anchors.centerIn: parent
            width: busyRow.implicitWidth + Theme.dp(24)
            height: Theme.dp(42)
            radius: Theme.radiusPill
            color: Theme.alpha(Theme.mHighest, 0.94)
            border.width: 1
            border.color: Theme.outline

            RowLayout {
                id: busyRow
                anchors.centerIn: parent
                spacing: Theme.dp(8)

                Ui.LoadingIndicator {
                    Layout.preferredWidth: Theme.dp(24)
                    Layout.preferredHeight: Theme.dp(24)
                    running: parent.visible
                }

                Ui.LText {
                    role: "labelLarge"
                    color: Theme.text
                    text: Wallpaper.applying ? "Скачивание обоев…" : "Загрузка…"
                }
            }
        }
    }

    // ── 5. Bottom Pagination Bar (Wallhaven & MotionBGs) ───────────────
    RowLayout {
        visible: Wallpaper.tab === "wallhaven" || Wallpaper.tab === "motion"
        Layout.fillWidth: true
        spacing: Theme.dp(6)

        Ui.IconButton {
            icon: "chevron_left"
            size: "xs"
            variant: "tonal"
            disabled: Wallpaper.tab === "wallhaven"
                    ? (Wallpaper.whPage <= 1 || Wallpaper.whBusy)
                    : (Wallpaper.motionPage <= 1 || Wallpaper.motionBusy)
            onClicked: {
                if (Wallpaper.tab === "wallhaven")
                    Wallpaper.whPrevPage();
                else
                    Wallpaper.motionPrevPage();
            }
        }

        Ui.Chip {
            visible: (Wallpaper.tab === "wallhaven" ? Wallpaper.whPage : Wallpaper.motionPage) > 1
            size: "sm"
            horizontalPadding: 7
            kind: "assist"
            label: "1"
            onClicked: {
                if (Wallpaper.tab === "wallhaven")
                    Wallpaper.whGoPage(1);
                else
                    Wallpaper.motionGoPage(1);
            }
        }

        Ui.LText {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            role: "labelSmall"
            color: Theme.subtext
            text: Wallpaper.tab === "wallhaven"
                ? ("Стр. " + Wallpaper.whPage + " из " + Wallpaper.whLastPage + " (всего " + Wallpaper.whTotal + ")")
                : ("Стр. " + Wallpaper.motionPage + (Wallpaper.motionCategory !== "" ? " • " + Wallpaper.motionCategory : ""))
        }

        Ui.Chip {
            size: "sm"
            horizontalPadding: 7
            kind: "assist"
            label: "+1"
            disabled: Wallpaper.tab === "wallhaven"
                    ? (Wallpaper.whPage >= Wallpaper.whLastPage || Wallpaper.whBusy)
                    : (!Wallpaper.motionHasMore || Wallpaper.motionBusy)
            onClicked: {
                if (Wallpaper.tab === "wallhaven")
                    Wallpaper.whNextPage();
                else
                    Wallpaper.motionNextPage();
            }
        }

        Ui.Chip {
            size: "sm"
            horizontalPadding: 7
            kind: "assist"
            label: "+5"
            disabled: Wallpaper.tab === "wallhaven"
                    ? (Wallpaper.whPage >= Wallpaper.whLastPage || Wallpaper.whBusy)
                    : (!Wallpaper.motionHasMore || Wallpaper.motionBusy)
            onClicked: {
                if (Wallpaper.tab === "wallhaven")
                    Wallpaper.whGoPage(Wallpaper.whPage + 5);
                else
                    Wallpaper.motionGoPage(Wallpaper.motionPage + 5);
            }
        }

        Ui.IconButton {
            icon: "chevron_right"
            size: "xs"
            variant: "tonal"
            disabled: Wallpaper.tab === "wallhaven"
                    ? (Wallpaper.whPage >= Wallpaper.whLastPage || Wallpaper.whBusy)
                    : (!Wallpaper.motionHasMore || Wallpaper.motionBusy)
            onClicked: {
                if (Wallpaper.tab === "wallhaven")
                    Wallpaper.whNextPage();
                else
                    Wallpaper.motionNextPage();
            }
        }
    }
}
