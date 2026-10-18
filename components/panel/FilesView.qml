pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../core"
import "../../ui"
import ".."

// Провідник v1: места, диски и список файлов в Material-стиле Oberon.
ColumnLayout {
    id: page

    property var win: null
    property string dir: ""
    property var history: []
    property int historyIndex: -1
    property var places: []
    property var disks: []
    property var rawEntries: []
    property var entries: []
    property string selectedPath: ""
    property string sortBy: "name"
    property bool sortDesc: false
    property bool loading: false
    property string errorText: ""
    property string statusText: ""
    property int trashCount: 0
    property bool menuOpen: false
    property string dialogMode: ""
    property string dialogText: ""

    readonly property string homeDir: Quickshell.env("HOME") || "/"
    readonly property string scriptPath: homeDir + "/oberon/scripts/files.sh"
    readonly property bool canGoBack: historyIndex > 0
    readonly property bool canGoForward: historyIndex >= 0 && historyIndex < history.length - 1
    readonly property var selectedEntry: {
        for (const entry of page.entries)
            if (entry.path === page.selectedPath)
                return entry;
        return null;
    }
    readonly property bool selectedMedia: page.selectedEntry !== null && page.isMediaEntry(page.selectedEntry)

    visible: win !== null && win.mode === "panel" && win.page === "files"
    Layout.fillWidth: true
    Layout.preferredHeight: Theme.dp(520)
    spacing: Theme.pageSpacing

    function normalizePath(value) {
        let raw = String(value || "").trim();
        if (raw === "" || raw === "~")
            raw = page.homeDir;
        else if (raw.indexOf("~/") === 0)
            raw = page.homeDir + raw.slice(1);
        else if (raw.charAt(0) !== "/")
            raw = (page.dir || page.homeDir) + "/" + raw;

        const parts = [];
        for (const part of raw.split("/")) {
            if (part === "" || part === ".")
                continue;
            if (part === "..") {
                if (parts.length > 0)
                    parts.pop();
            } else {
                parts.push(part);
            }
        }
        return "/" + parts.join("/");
    }

    function enterPage() {
        const requested = win && win.shell ? String(win.shell.filesStartPath || "") : "";
        if (requested !== "") {
            page.dir = page.normalizePath(requested);
            page.history = [page.dir];
            page.historyIndex = 0;
            page.selectedPath = "";
            page.menuOpen = false;
            win.shell.filesStartPath = "";
        } else if (page.dir === "") {
            page.dir = page.homeDir;
        }

        if (page.history.length === 0) {
            page.history = [page.dir];
            page.historyIndex = 0;
        }
        pathInput.text = page.dir;
        page.refreshAll();
    }

    function navigate(target, addToHistory) {
        const next = page.normalizePath(target);
        if (addToHistory !== false) {
            const updated = page.history.slice(0, page.historyIndex + 1);
            if (updated.length === 0 || updated[updated.length - 1] !== next)
                updated.push(next);
            page.history = updated;
            page.historyIndex = updated.length - 1;
        }
        page.dir = next;
        page.selectedPath = "";
        page.menuOpen = false;
        page.dialogMode = "";
        page.statusText = "";
        pathInput.text = next;
        page.reloadDirectory();
    }

    function goBack() {
        if (!page.canGoBack)
            return;
        page.historyIndex--;
        page.navigate(page.history[page.historyIndex], false);
    }

    function goForward() {
        if (!page.canGoForward)
            return;
        page.historyIndex++;
        page.navigate(page.history[page.historyIndex], false);
    }

    function goUp() {
        if (page.dir === "" || page.dir === "/")
            return;
        const slash = page.dir.lastIndexOf("/");
        page.navigate(slash <= 0 ? "/" : page.dir.slice(0, slash));
    }

    function refreshAll() {
        page.reloadDirectory();
        placesProc.output = "";
        placesProc.errorOutput = "";
        placesProc.running = false;
        placesProc.running = true;
        page.refreshDisks();
        page.refreshTrashCount();
    }

    function reloadDirectory() {
        page.loading = true;
        page.errorText = "";
        page.rawEntries = [];
        page.entries = [];
        listProc.output = "";
        listProc.errorOutput = "";
        listProc.running = false;
        listProc.command = ["bash", page.scriptPath, "list", page.dir];
        listProc.running = true;
    }

    function refreshDisks() {
        disksProc.output = "";
        disksProc.errorOutput = "";
        disksProc.running = false;
        disksProc.running = true;
    }

    function refreshTrashCount() {
        trashProc.output = "";
        trashProc.errorOutput = "";
        trashProc.running = false;
        trashProc.running = true;
    }

    function finishList(exitCode) {
        page.loading = false;
        if (exitCode !== 0) {
            page.rawEntries = [];
            page.entries = [];
            page.errorText = listProc.errorOutput.trim() || "Не удалось открыть папку. Проверьте путь и права доступа.";
            return;
        }
        try {
            const result = JSON.parse(listProc.output.trim() || "[]");
            if (!Array.isArray(result))
                throw new Error("invalid list");
            page.rawEntries = result;
            page.applySort();
            if (!result.some(entry => entry.path === page.selectedPath))
                page.selectedPath = "";
            page.errorText = "";
        } catch (error) {
            page.rawEntries = [];
            page.entries = [];
            page.errorText = "Не удалось разобрать список файлов.";
        }
    }

    function applySort() {
        const rows = page.rawEntries.slice();
        const direction = page.sortDesc ? -1 : 1;
        const kindOrder = { image: 0, video: 1, archive: 2, file: 3 };
        rows.sort((a, b) => {
            if (!!a.dir !== !!b.dir)
                return a.dir ? -1 : 1;

            let comparison = 0;
            if (page.sortBy === "size")
                comparison = (Number(a.size) || 0) - (Number(b.size) || 0);
            else if (page.sortBy === "time")
                comparison = (Number(a.mtime) || 0) - (Number(b.mtime) || 0);
            else if (page.sortBy === "type")
                comparison = (kindOrder[page.entryType(a)] || 0) - (kindOrder[page.entryType(b)] || 0);

            if (comparison === 0)
                comparison = String(a.name).toLocaleLowerCase().localeCompare(String(b.name).toLocaleLowerCase());
            return comparison * direction;
        });
        page.entries = rows;
    }

    function setSort(field) {
        if (page.sortBy === field)
            page.sortDesc = !page.sortDesc;
        else {
            page.sortBy = field;
            page.sortDesc = false;
        }
        page.applySort();
    }

    function extension(path) {
        const name = String(path || "").split("/").pop();
        const dot = name.lastIndexOf(".");
        return dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
    }

    function entryType(entry) {
        if (entry.dir)
            return "folder";
        const ext = page.extension(entry.name);
        if (["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "avif", "svg"].includes(ext))
            return "image";
        if (["mp4", "mkv", "webm", "mov", "avi", "m4v", "wmv", "flv", "mpg", "mpeg", "ts", "m2ts"].includes(ext))
            return "video";
        if (["zip", "7z", "rar", "tar", "gz", "bz2", "xz", "zst", "iso"].includes(ext))
            return "archive";
        return "file";
    }

    function isMediaEntry(entry) {
        const kind = page.entryType(entry);
        return kind === "image" || kind === "video";
    }

    function entryIcon(entry) {
        switch (page.entryType(entry)) {
        case "folder": return "folder";
        case "image": return "image";
        case "video": return "movie";
        case "archive": return "archive";
        default: return "description";
        }
    }

    function typeLabel(entry) {
        switch (page.entryType(entry)) {
        case "folder": return "Папка";
        case "image": return "Фото";
        case "video": return "Видео";
        case "archive": return "Архив";
        default: return "Файл";
        }
    }

    function placeIcon(name) {
        switch (name) {
        case "Дом": return "home";
        case "Документы": return "description";
        case "Загрузки": return "download";
        case "Изображения": return "image";
        case "Видео": return "movie";
        case "Музыка": return "music_note";
        case "Рабочий стол": return "desktop_windows";
        default: return "folder";
        }
    }

    function formatBytes(value) {
        let size = Math.max(0, Number(value) || 0);
        if (size < 1024)
            return size + " Б";
        const units = ["КиБ", "МиБ", "ГиБ", "ТиБ"];
        let index = -1;
        do {
            size /= 1024;
            index++;
        } while (size >= 1024 && index < units.length - 1);
        return size.toFixed(1) + " " + units[index];
    }

    function formatDate(value) {
        const date = new Date((Number(value) || 0) * 1000);
        return isNaN(date.getTime()) || Number(value) <= 0 ? "—" : Qt.formatDateTime(date, "dd.MM.yy HH:mm");
    }

    function openEntry(entry) {
        page.selectedPath = entry.path;
        if (entry.dir)
            page.navigate(entry.path);
        else
            Quickshell.execDetached(["xdg-open", entry.path]);
    }

    function openSelectedMedia() {
        if (!page.selectedMedia || !win || !win.shell)
            return;
        // Тот же обработчик, который вызывает IPC oberon media <path>.
        win.shell.openMedia(page.selectedEntry.path);
        page.menuOpen = false;
    }

    function copySelectedPath() {
        if (!page.selectedEntry)
            return;
        Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" | wl-copy", "sh", page.selectedEntry.path]);
        page.statusText = "Путь скопирован";
        page.menuOpen = false;
    }

    function beginRename() {
        if (!page.selectedEntry)
            return;
        page.dialogMode = "rename";
        page.dialogText = page.selectedEntry.name;
        page.menuOpen = false;
        Qt.callLater(() => {
            renameInput.forceActiveFocus();
            renameInput.input.selectAll();
        });
    }

    function beginMkdir() {
        page.dialogMode = "mkdir";
        page.dialogText = "";
        page.menuOpen = false;
        Qt.callLater(() => renameInput.forceActiveFocus());
    }

    function submitName() {
        const name = String(page.dialogText);
        if (name.length === 0) {
            page.statusText = "Введите имя.";
            return;
        }
        if (page.dialogMode === "rename" && page.selectedEntry)
            page.runAction("rename", [page.selectedEntry.path, name]);
        else if (page.dialogMode === "mkdir")
            page.runAction("mkdir", [page.dir, name]);
        page.dialogMode = "";
    }

    function runAction(action, args) {
        if (actionProc.running)
            return;
        page.statusText = "";
        actionProc.actionName = action;
        actionProc.errorOutput = "";
        actionProc.actionArgs = [action].concat(args || []);
        actionProc.command = ["bash", page.scriptPath].concat(actionProc.actionArgs);
        actionProc.running = true;
    }

    onVisibleChanged: if (visible) page.enterPage()

    Connections {
        target: page.win ? page.win.shell : null
        ignoreUnknownSignals: true
        function onFilesStartPathChanged() {
            if (page.visible && page.win && page.win.shell && page.win.shell.filesStartPath)
                page.enterPage();
        }
    }

    Process {
        id: listProc
        property string output: ""
        property string errorOutput: ""
        command: ["bash", page.scriptPath, "list", page.dir]
        stdout: SplitParser {
            onRead: line => listProc.output += (listProc.output === "" ? "" : "\n") + line
        }
        stderr: SplitParser {
            onRead: line => listProc.errorOutput += line + "\n"
        }
        onExited: exitCode => page.finishList(exitCode)
    }

    Process {
        id: placesProc
        property string output: ""
        property string errorOutput: ""
        command: ["bash", page.scriptPath, "places"]
        stdout: SplitParser {
            onRead: line => placesProc.output += (placesProc.output === "" ? "" : "\n") + line
        }
        stderr: SplitParser {
            onRead: line => placesProc.errorOutput += line + "\n"
        }
        onExited: exitCode => {
            if (exitCode !== 0) {
                page.statusText = placesProc.errorOutput.trim() || "Не удалось загрузить закладки.";
                return;
            }
            try {
                const result = JSON.parse(placesProc.output.trim() || "[]");
                page.places = Array.isArray(result) ? result : [];
            } catch (error) {
                page.places = [];
            }
        }
    }

    Process {
        id: disksProc
        property string output: ""
        property string errorOutput: ""
        command: ["bash", page.scriptPath, "disks"]
        stdout: SplitParser {
            onRead: line => disksProc.output += (disksProc.output === "" ? "" : "\n") + line
        }
        stderr: SplitParser {
            onRead: line => disksProc.errorOutput += line + "\n"
        }
        onExited: exitCode => {
            if (exitCode !== 0) {
                page.statusText = disksProc.errorOutput.trim() || "Не удалось загрузить список дисков.";
                page.disks = [];
                return;
            }
            try {
                const result = JSON.parse(disksProc.output.trim() || "[]");
                page.disks = Array.isArray(result) ? result : [];
            } catch (error) {
                page.disks = [];
            }
        }
    }

    Process {
        id: trashProc
        property string output: ""
        property string errorOutput: ""
        command: ["bash", page.scriptPath, "trashcount"]
        stdout: SplitParser {
            onRead: line => trashProc.output += line
        }
        stderr: SplitParser {
            onRead: line => trashProc.errorOutput += line + "\n"
        }
        onExited: exitCode => {
            page.trashCount = exitCode === 0 ? Math.max(0, parseInt(trashProc.output.trim(), 10) || 0) : 0;
            if (exitCode !== 0)
                page.statusText = trashProc.errorOutput.trim() || "Не удалось прочитать корзину.";
        }
    }

    Process {
        id: actionProc
        property var actionArgs: []
        property string actionName: ""
        property string errorOutput: ""
        command: ["bash", page.scriptPath].concat(actionArgs)
        stderr: SplitParser {
            onRead: line => actionProc.errorOutput += line + "\n"
        }
        onExited: exitCode => {
            const action = actionProc.actionName;
            if (exitCode !== 0)
                page.statusText = actionProc.errorOutput.trim() || "Операция не выполнена.";
            else
                page.statusText = "Готово";
            actionProc.actionName = "";
            page.menuOpen = false;
            if (action === "trash")
                page.selectedPath = "";
            page.refreshAll();
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.dp(6)

        IconButton {
            icon: "arrow_back"
            tooltip: "Назад"
            disabled: !page.canGoBack || listProc.running
            onClicked: page.goBack()
        }
        IconButton {
            icon: "arrow_forward"
            tooltip: "Вперёд"
            disabled: !page.canGoForward || listProc.running
            onClicked: page.goForward()
        }
        IconButton {
            icon: "arrow_upward"
            tooltip: "Вверх"
            disabled: page.dir === "/" || page.dir === "" || listProc.running
            onClicked: page.goUp()
        }
        TextField {
            id: pathInput
            Layout.fillWidth: true
            variant: "search"
            icon: "folder_open"
            placeholder: "Путь к папке"
            text: page.dir
            enabled: !listProc.running
            onAccepted: page.navigate(text)
        }
        IconButton {
            icon: "refresh"
            tooltip: "Обновить"
            disabled: listProc.running
            onClicked: page.refreshAll()
        }
        Button {
            text: "Новая папка"
            icon: "folder"
            size: "xs"
            variant: "tonal"
            disabled: actionProc.running
            onClicked: page.beginMkdir()
        }
        IconButton {
            visible: page.selectedEntry !== null
            icon: "more_vert"
            tooltip: "Действия"
            disabled: actionProc.running
            onClicked: page.menuOpen = !page.menuOpen
        }
    }

    RowLayout {
        visible: page.menuOpen && page.selectedEntry !== null
        Layout.fillWidth: true
        spacing: Theme.dp(6)

        Button {
            text: "Открыть"
            icon: "open_in_new"
            size: "xs"
            variant: "text"
            onClicked: {
                const entry = page.selectedEntry;
                if (entry)
                    page.openEntry(entry);
                page.menuOpen = false;
            }
        }
        Button {
            visible: page.selectedMedia
            text: "Открыть в Медиа"
            icon: "play_arrow"
            size: "xs"
            variant: "text"
            onClicked: page.openSelectedMedia()
        }
        Button {
            text: "Копировать путь"
            icon: "content_copy"
            size: "xs"
            variant: "text"
            onClicked: page.copySelectedPath()
        }
        Button {
            text: "Переименовать"
            icon: "edit"
            size: "xs"
            variant: "text"
            onClicked: page.beginRename()
        }
        Button {
            text: "В корзину"
            icon: "delete"
            size: "xs"
            variant: "text"
            danger: true
            disabled: actionProc.running
            onClicked: {
                if (page.selectedEntry)
                    page.runAction("trash", [page.selectedEntry.path]);
            }
        }
    }

    RowLayout {
        visible: page.dialogMode !== ""
        Layout.fillWidth: true
        spacing: Theme.dp(8)

        TextField {
            id: renameInput
            Layout.fillWidth: true
            variant: "outlined"
            icon: page.dialogMode === "mkdir" ? "folder" : "edit"
            placeholder: page.dialogMode === "mkdir" ? "Имя новой папки" : "Новое имя"
            text: page.dialogText
            enabled: !actionProc.running
            onTextEdited: page.dialogText = text
            onAccepted: page.submitName()
        }
        Button {
            text: "Сохранить"
            icon: "check"
            size: "xs"
            disabled: actionProc.running
            onClicked: page.submitName()
        }
        Button {
            text: "Отмена"
            icon: "close"
            size: "xs"
            variant: "text"
            onClicked: page.dialogMode = ""
        }
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.preferredHeight: Theme.dp(382)
        Layout.minimumHeight: Theme.dp(300)
        spacing: Theme.dp(10)

        Rectangle {
            Layout.preferredWidth: Theme.dp(196)
            Layout.fillHeight: true
            radius: Theme.shapeLgInc
            color: Theme.mHigh
            clip: true

            Flickable {
                id: placesScroll
                anchors.fill: parent
                anchors.margins: Theme.dp(8)
                clip: true
                contentWidth: width
                contentHeight: placesColumn.implicitHeight
                flickableDirection: Flickable.VerticalFlick
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: placesColumn
                    width: placesScroll.width
                    spacing: Theme.dp(4)

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: Theme.dp(4)
                        Layout.bottomMargin: Theme.dp(2)
                        LText {
                            Layout.fillWidth: true
                            text: "Места"
                            role: "labelLarge"
                            color: Theme.subtext
                        }
                    }
                    Repeater {
                        model: page.places
                        delegate: Button {
                            required property var modelData
                            Layout.fillWidth: true
                            text: modelData.name
                            icon: page.placeIcon(modelData.name)
                            size: "xs"
                            variant: "text"
                            checkable: true
                            checked: page.dir === modelData.path
                            onClicked: page.navigate(modelData.path)
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: Theme.dp(8)
                        Layout.bottomMargin: Theme.dp(2)
                        LText {
                            Layout.fillWidth: true
                            text: "Диски"
                            role: "labelLarge"
                            color: Theme.subtext
                        }
                        IconButton {
                            size: "xs"
                            icon: "refresh"
                            tooltip: "Обновить диски"
                            disabled: disksProc.running || actionProc.running
                            onClicked: page.refreshDisks()
                        }
                    }
                    Repeater {
                        model: page.disks
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: Theme.dp(4)

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Theme.dp(1)
                                LText {
                                    Layout.fillWidth: true
                                    text: modelData.label || modelData.name
                                    role: "bodySmall"
                                    weight: 500
                                    elide: Text.ElideRight
                                }
                                LText {
                                    Layout.fillWidth: true
                                    text: modelData.mounted ? modelData.mountpoint : page.formatBytes(modelData.size)
                                    role: "labelSmall"
                                    color: Theme.subtext
                                    elide: Text.ElideMiddle
                                }
                            }
                            Button {
                                Layout.preferredWidth: Theme.dp(84)
                                text: modelData.mounted ? "Извлечь" : "Подключить"
                                icon: modelData.mounted ? "logout" : "usb"
                                size: "xs"
                                variant: "text"
                                disabled: actionProc.running
                                onClicked: page.runAction(modelData.mounted ? "eject" : "mount", [modelData.path])
                            }
                        }
                    }
                    LText {
                        visible: page.disks.length === 0 && !disksProc.running
                        Layout.fillWidth: true
                        Layout.leftMargin: Theme.dp(8)
                        text: "Нет доступных дисков"
                        role: "bodySmall"
                        color: Theme.subtext
                    }
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Theme.dp(4)

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.dp(10)
                Layout.rightMargin: Theme.dp(10)
                spacing: Theme.dp(8)

                Item {
                    Layout.preferredWidth: Theme.dp(18)
                    Layout.preferredHeight: Theme.dp(30)
                }
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.dp(30)
                    RowLayout {
                        anchors.fill: parent
                        LText { Layout.fillWidth: true; text: "Имя"; role: "labelMedium"; color: Theme.subtext }
                        Icon {
                            visible: page.sortBy === "name"
                            name: page.sortDesc ? "arrow_downward" : "arrow_upward"
                            size: Theme.dp(14)
                            color: Theme.subtext
                        }
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: page.setSort("name") }
                }
                Item {
                    Layout.preferredWidth: Theme.dp(66)
                    Layout.preferredHeight: Theme.dp(30)
                    RowLayout {
                        anchors.fill: parent
                        LText { Layout.fillWidth: true; text: "Размер"; role: "labelMedium"; color: Theme.subtext }
                        Icon {
                            visible: page.sortBy === "size"
                            name: page.sortDesc ? "arrow_downward" : "arrow_upward"
                            size: Theme.dp(14)
                            color: Theme.subtext
                        }
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: page.setSort("size") }
                }
                Item {
                    Layout.preferredWidth: Theme.dp(110)
                    Layout.preferredHeight: Theme.dp(30)
                    RowLayout {
                        anchors.fill: parent
                        LText { Layout.fillWidth: true; text: "Изменён"; role: "labelMedium"; color: Theme.subtext }
                        Icon {
                            visible: page.sortBy === "time"
                            name: page.sortDesc ? "arrow_downward" : "arrow_upward"
                            size: Theme.dp(14)
                            color: Theme.subtext
                        }
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: page.setSort("time") }
                }
                Item {
                    Layout.preferredWidth: Theme.dp(62)
                    Layout.preferredHeight: Theme.dp(30)
                    RowLayout {
                        anchors.fill: parent
                        LText { Layout.fillWidth: true; text: "Тип"; role: "labelMedium"; color: Theme.subtext }
                        Icon {
                            visible: page.sortBy === "type"
                            name: page.sortDesc ? "arrow_downward" : "arrow_upward"
                            size: Theme.dp(14)
                            color: Theme.subtext
                        }
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: page.setSort("type") }
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: Theme.dp(340)

                ListView {
                    id: filesList
                    anchors.fill: parent
                    model: page.entries
                    clip: true
                    spacing: Theme.dp(2)
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Item {
                        required property var modelData
                        width: filesList.width
                        height: Theme.dp(42)

                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.rad(10)
                            color: page.selectedPath === modelData.path
                                ? Theme.secondaryContainer
                                : (rowMouse.containsMouse ? Theme.bgHover : "transparent")
                        }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Theme.dp(8)
                            anchors.rightMargin: Theme.dp(8)
                            spacing: Theme.dp(8)

                            Icon {
                                Layout.preferredWidth: Theme.dp(18)
                                name: page.entryIcon(modelData)
                                size: Theme.dp(18)
                                color: page.selectedPath === modelData.path ? Theme.fgSecondaryContainer : Theme.primary
                            }
                            LText {
                                Layout.fillWidth: true
                                text: modelData.name + (modelData.isLink ? " ↗" : "")
                                role: "bodyMedium"
                                color: page.selectedPath === modelData.path ? Theme.fgSecondaryContainer : Theme.text
                                elide: Text.ElideRight
                            }
                            LText {
                                Layout.preferredWidth: Theme.dp(66)
                                text: modelData.dir ? "—" : page.formatBytes(modelData.size)
                                role: "bodySmall"
                                color: Theme.subtext
                                horizontalAlignment: Text.AlignRight
                                elide: Text.ElideRight
                            }
                            LText {
                                Layout.preferredWidth: Theme.dp(110)
                                text: page.formatDate(modelData.mtime)
                                role: "bodySmall"
                                color: Theme.subtext
                                horizontalAlignment: Text.AlignRight
                            }
                            LText {
                                Layout.preferredWidth: Theme.dp(62)
                                text: page.typeLabel(modelData)
                                role: "bodySmall"
                                color: Theme.subtext
                                horizontalAlignment: Text.AlignRight
                                elide: Text.ElideRight
                            }
                        }
                        MouseArea {
                            id: rowMouse
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            hoverEnabled: true
                            onClicked: mouse => {
                                page.selectedPath = modelData.path;
                                page.menuOpen = mouse.button === Qt.RightButton;
                            }
                            onDoubleClicked: mouse => {
                                if (mouse.button === Qt.LeftButton)
                                    page.openEntry(modelData);
                            }
                        }
                    }
                }

                ColumnLayout {
                    anchors.centerIn: parent
                    width: Math.min(parent.width - Theme.dp(32), Theme.dp(320))
                    visible: page.entries.length === 0
                    spacing: Theme.dp(8)
                    Icon {
                        Layout.alignment: Qt.AlignHCenter
                        name: page.errorText !== "" ? "error" : "folder_open"
                        size: Theme.dp(32)
                        color: page.errorText !== "" ? Theme.error : Theme.subtext
                    }
                    LText {
                        Layout.fillWidth: true
                        text: page.loading ? "Загрузка…"
                            : (page.errorText !== "" ? page.errorText : "Папка пуста")
                        role: "bodyMedium"
                        color: page.errorText !== "" ? Theme.error : Theme.subtext
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.dp(8)
        LText {
            Layout.fillWidth: true
            text: page.statusText !== "" ? page.statusText
                : (page.loading ? "Загрузка…" : page.entries.length + " элементов")
            role: "bodySmall"
            color: page.statusText !== "" ? Theme.primary : Theme.subtext
            elide: Text.ElideRight
        }
        LText {
            text: "Корзина: " + page.trashCount
            role: "bodySmall"
            color: Theme.subtext
        }
        Button {
            text: "Очистить корзину"
            icon: "delete_sweep"
            size: "xs"
            variant: "text"
            danger: true
            disabled: page.trashCount === 0 || actionProc.running
            onClicked: page.runAction("emptytrash", [])
        }
    }
}
