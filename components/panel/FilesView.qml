pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../core"
import "../../ui"
import ".."

// Файловый менеджер Oberon v2: вкладки папок, интерактивные хлебные крошки,
// мгновенный фильтр, плитка/список, буфер обмена файлов, архивы и живой QuickLook-инспектор.
ColumnLayout {
    id: page

    property var win: null
    property string dir: ""
    property alias currentPath: page.dir
    property var history: []
    property int historyIndex: -1
    property var tabsModel: []
    property int activeTabIndex: 0
    property bool editingPath: false
    property string filterText: ""
    property bool gridMode: false
    property bool inspectorOpen: true

    property var clipboardPaths: []
    property string clipboardMode: "" // "copy" | "cut"

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

    property var inspectData: null
    property bool inspectLoading: false
    property string inspectTarget: ""
    property bool pendingStartPathFallback: false
    property string pendingSelectPath: ""

    readonly property string homeDir: Quickshell.env("HOME") || "/"
    readonly property string trashFilesDir: {
        const dataHome = Quickshell.env("XDG_DATA_HOME") || (page.homeDir + "/.local/share");
        return dataHome + "/Trash/files";
    }
    readonly property string scriptPath: homeDir + "/oberon/scripts/files.sh"
    readonly property bool canGoBack: historyIndex > 0
    readonly property bool canGoForward: historyIndex >= 0 && historyIndex < history.length - 1
    readonly property var selectedEntry: {
        for (const entry of page.entries)
            if (entry.path === page.selectedPath)
                return entry;
        for (const entry of page.rawEntries)
            if (entry.path === page.selectedPath)
                return entry;
        return null;
    }
    readonly property string selectedKind: {
        if (page.inspectData && page.inspectData.kind)
            return String(page.inspectData.kind);
        if (page.selectedEntry)
            return page.entryKind(page.selectedEntry);
        return "";
    }
    readonly property bool selectedMedia: page.selectedEntry !== null && page.isStudioEntry(page.selectedEntry)
    readonly property var breadcrumbs: {
        const current = page.dir || "/";
        const out = [{ label: "/", path: "/" }];
        if (current === "/")
            return out;
        const parts = current.split("/").filter(Boolean);
        let acc = "";
        for (const part of parts) {
            acc += "/" + part;
            out.push({ label: part, path: acc });
        }
        return out;
    }

    visible: win !== null && win.mode === "panel" && win.page === "files"
    Layout.fillWidth: true
    Layout.preferredHeight: Theme.dp(560)
    spacing: Theme.dp(8)

    FontLoader {
        id: inspectorFontLoader
        source: page.selectedKind === "font" && page.selectedPath !== ""
            ? page.localFileUrl(page.selectedPath) : ""
    }

    function localFileUrl(value) {
        return "file://" + String(value || "").split("/").map(part => encodeURIComponent(part)).join("/");
    }

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

    function tabTitleFor(path) {
        const clean = page.normalizePath(path);
        if (clean === "/")
            return "/";
        if (clean === page.homeDir)
            return "Дом";
        if (clean === page.trashFilesDir)
            return "Корзина";
        const parts = clean.split("/").filter(Boolean);
        return parts.length > 0 ? parts[parts.length - 1] : "/";
    }

    function syncActiveTab() {
        if (page.tabsModel.length === 0) {
            page.tabsModel = [{
                path: page.dir || page.homeDir,
                title: page.tabTitleFor(page.dir || page.homeDir),
                history: page.history.slice(),
                historyIndex: page.historyIndex
            }];
            page.activeTabIndex = 0;
            return;
        }
        const idx = Math.max(0, Math.min(page.activeTabIndex, page.tabsModel.length - 1));
        const copy = page.tabsModel.slice();
        copy[idx] = {
            path: page.dir,
            title: page.tabTitleFor(page.dir),
            history: page.history.slice(),
            historyIndex: page.historyIndex
        };
        page.tabsModel = copy;
        page.activeTabIndex = idx;
    }

    function addTab(targetPath) {
        page.syncActiveTab();
        const path = page.normalizePath(targetPath || page.dir || page.homeDir);
        const copy = page.tabsModel.slice();
        copy.push({
            path: path,
            title: page.tabTitleFor(path),
            history: [path],
            historyIndex: 0
        });
        page.tabsModel = copy;
        page.activeTabIndex = copy.length - 1;
        page.dir = path;
        page.history = [path];
        page.historyIndex = 0;
        page.selectedPath = "";
        page.menuOpen = false;
        page.editingPath = false;
        pathInput.text = path;
        page.reloadDirectory();
    }

    function switchTab(index) {
        if (index < 0 || index >= page.tabsModel.length || index === page.activeTabIndex)
            return;
        page.syncActiveTab();
        const target = page.tabsModel[index];
        page.activeTabIndex = index;
        page.dir = target.path;
        page.history = Array.isArray(target.history) && target.history.length > 0 ? target.history.slice() : [target.path];
        page.historyIndex = typeof target.historyIndex === "number" ? target.historyIndex : (page.history.length - 1);
        page.selectedPath = "";
        page.menuOpen = false;
        page.editingPath = false;
        pathInput.text = page.dir;
        page.reloadDirectory();
    }

    function closeTab(index) {
        if (page.tabsModel.length <= 1 || index < 0 || index >= page.tabsModel.length)
            return;
        const copy = page.tabsModel.slice();
        copy.splice(index, 1);
        let nextIdx = page.activeTabIndex;
        if (index < nextIdx)
            nextIdx--;
        else if (nextIdx >= copy.length)
            nextIdx = copy.length - 1;
        page.tabsModel = copy;
        page.activeTabIndex = nextIdx;
        const active = copy[nextIdx];
        page.dir = active.path;
        page.history = Array.isArray(active.history) && active.history.length > 0 ? active.history.slice() : [active.path];
        page.historyIndex = typeof active.historyIndex === "number" ? active.historyIndex : (page.history.length - 1);
        page.selectedPath = "";
        page.menuOpen = false;
        page.editingPath = false;
        pathInput.text = page.dir;
        page.reloadDirectory();
    }

    function enterPage() {
        const requested = win && win.shell ? String(win.shell.filesStartPath || "") : "";
        if (requested !== "") {
            const norm = page.normalizePath(requested);
            page.pendingStartPathFallback = true;
            page.dir = norm;
            page.history = [norm];
            page.historyIndex = 0;
            page.selectedPath = "";
            page.menuOpen = false;
            win.shell.filesStartPath = "";
            page.syncActiveTab();
        } else if (page.dir === "") {
            page.dir = page.homeDir;
        }

        if (page.history.length === 0) {
            page.history = [page.dir];
            page.historyIndex = 0;
        }
        if (page.tabsModel.length === 0)
            page.syncActiveTab();
        pathInput.text = page.dir;
        page.refreshAll();
    }

    function navigateTo(target, addToHistory) {
        page.navigate(target, addToHistory);
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
        page.editingPath = false;
        page.statusText = "";
        pathInput.text = next;
        page.syncActiveTab();
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
        if (page.selectedPath !== "")
            page.startInspect(page.selectedPath);
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
            if (page.pendingStartPathFallback && page.dir !== "/" && page.dir !== "") {
                page.pendingStartPathFallback = false;
                const fileCandidate = page.dir;
                const slash = fileCandidate.lastIndexOf("/");
                const parentDir = slash <= 0 ? "/" : fileCandidate.slice(0, slash);
                page.pendingSelectPath = fileCandidate;
                page.dir = parentDir;
                page.history = [parentDir];
                page.historyIndex = 0;
                pathInput.text = parentDir;
                page.syncActiveTab();
                page.reloadDirectory();
                return;
            }
            page.pendingStartPathFallback = false;
            page.rawEntries = [];
            page.entries = [];
            page.errorText = listProc.errorOutput.trim() || "Не удалось открыть папку. Проверьте путь и права доступа.";
            return;
        }
        page.pendingStartPathFallback = false;
        try {
            const result = JSON.parse(listProc.output.trim() || "[]");
            if (!Array.isArray(result))
                throw new Error("invalid list");
            const enriched = result.map(item => {
                const copy = Object.assign({}, item);
                copy.kind = page.entryKind(copy);
                copy.dir = Boolean(copy.dir || copy.kind === "dir");
                return copy;
            });
            page.rawEntries = enriched;
            page.applySort();
            if (page.pendingSelectPath !== "") {
                const want = page.pendingSelectPath;
                page.pendingSelectPath = "";
                if (enriched.some(entry => entry.path === want))
                    page.selectedPath = want;
            } else if (!enriched.some(entry => entry.path === page.selectedPath)) {
                page.selectedPath = "";
            } else if (page.selectedPath !== "") {
                page.startInspect(page.selectedPath);
            }
            page.errorText = "";
        } catch (error) {
            page.rawEntries = [];
            page.entries = [];
            page.errorText = "Не удалось разобрать список файлов.";
        }
    }

    function applySort() {
        const query = String(page.filterText || "").trim().toLocaleLowerCase();
        const filtered = query === ""
            ? page.rawEntries.slice()
            : page.rawEntries.filter(item => String(item.name || "").toLocaleLowerCase().indexOf(query) >= 0);

        const direction = page.sortDesc ? -1 : 1;
        const kindOrder = {
            dir: 0,
            image: 1,
            video: 2,
            audio: 3,
            pdf: 4,
            markdown: 5,
            code: 6,
            text: 7,
            table: 8,
            sqlite: 9,
            archive: 10,
            font: 11,
            other: 12
        };
        filtered.sort((a, b) => {
            if (!!a.dir !== !!b.dir)
                return a.dir ? -1 : 1;

            let comparison = 0;
            if (page.sortBy === "size")
                comparison = (Number(a.size) || 0) - (Number(b.size) || 0);
            else if (page.sortBy === "time")
                comparison = (Number(a.mtime) || 0) - (Number(b.mtime) || 0);
            else if (page.sortBy === "type")
                comparison = (kindOrder[page.entryKind(a)] || 99) - (kindOrder[page.entryKind(b)] || 99);

            if (comparison === 0)
                comparison = String(a.name).toLocaleLowerCase().localeCompare(String(b.name).toLocaleLowerCase());
            return comparison * direction;
        });
        page.entries = filtered;
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

    function entryKind(entry) {
        if (!entry)
            return "other";
        if (entry.dir || entry.kind === "dir" || entry.kind === "folder")
            return "dir";
        if (entry.kind && entry.kind !== "file" && entry.kind !== "other")
            return String(entry.kind);
        const ext = page.extension(entry.name || entry.path);
        const lowerName = String(entry.name || "").toLowerCase();
        if (["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "avif", "svg", "ico", "heic", "jxl"].includes(ext))
            return "image";
        if (["mp4", "mkv", "webm", "mov", "avi", "m4v", "wmv", "flv", "mpg", "mpeg", "ts", "m2ts", "ogv", "3gp"].includes(ext))
            return "video";
        if (["mp3", "flac", "wav", "ogg", "oga", "opus", "m4a", "aac", "wma", "alac", "aiff", "mid", "midi"].includes(ext))
            return "audio";
        if (ext === "pdf")
            return "pdf";
        if (["md", "markdown", "mdx"].includes(ext))
            return "markdown";
        if (["py", "js", "ts", "jsx", "tsx", "qml", "sh", "bash", "zsh", "fish", "c", "cpp", "cc", "h", "hpp",
             "rs", "go", "java", "kt", "rb", "php", "lua", "html", "htm", "css", "scss", "json", "toml",
             "yaml", "yml", "xml", "sql", "nix", "conf", "ini", "cfg", "service", "desktop", "cmake"].includes(ext)
            || ["makefile", "dockerfile", "pkgbuild"].includes(lowerName))
            return "code";
        if (["txt", "log", "rtf", "org", "rst", "tex", "sub", "srt", "vtt", "env"].includes(ext)
            || lowerName === "readme" || lowerName === "license")
            return "text";
        if (["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz", "zst", "tzst", "iso", "deb", "rpm", "apk", "jar", "whl"].includes(ext))
            return "archive";
        if (["csv", "tsv"].includes(ext))
            return "table";
        if (["sqlite", "sqlite3", "db", "db3"].includes(ext))
            return "sqlite";
        if (["ttf", "otf", "woff", "woff2", "ttc"].includes(ext))
            return "font";
        return "other";
    }

    function entryType(entry) {
        return page.entryKind(entry);
    }

    function isStudioKind(kind) {
        return ["image", "video", "audio", "pdf", "code", "markdown", "text", "archive", "table", "sqlite", "font"].includes(String(kind || ""));
    }

    function isStudioEntry(entry) {
        return entry !== null && page.isStudioKind(page.entryKind(entry));
    }

    function isMediaEntry(entry) {
        return page.isStudioEntry(entry);
    }

    function kindIcon(kind) {
        switch (String(kind || "")) {
        case "dir":
        case "folder": return "folder";
        case "image": return "image";
        case "video": return "movie";
        case "audio": return "music_note";
        case "pdf": return "description";
        case "markdown": return "edit_note";
        case "code": return "code";
        case "text": return "notes";
        case "archive": return "archive";
        case "table": return "grid_view";
        case "sqlite": return "hard_drive";
        case "font": return "text_fields";
        default: return "description";
        }
    }

    function entryIcon(entry) {
        return page.kindIcon(page.entryKind(entry));
    }

    function kindLabel(kind) {
        switch (String(kind || "")) {
        case "dir":
        case "folder": return "Папка";
        case "image": return "Фото";
        case "video": return "Видео";
        case "audio": return "Аудио";
        case "pdf": return "PDF";
        case "markdown": return "Markdown";
        case "code": return "Код";
        case "text": return "Текст";
        case "archive": return "Архив";
        case "table": return "Таблица";
        case "sqlite": return "SQLite";
        case "font": return "Шрифт";
        default: return "Файл";
        }
    }

    function typeLabel(entry) {
        return page.kindLabel(page.entryKind(entry));
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
        case "Корзина": return "delete";
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

    function formatDuration(seconds) {
        const total = Math.max(0, Math.floor(Number(seconds) || 0));
        if (total <= 0)
            return "";
        const h = Math.floor(total / 3600);
        const m = Math.floor(total / 60) % 60;
        const s = total % 60;
        const mm = (m < 10 ? "0" : "") + m;
        const ss = (s < 10 ? "0" : "") + s;
        return h > 0 ? (h + ":" + mm + ":" + ss) : (mm + ":" + ss);
    }

    function formatPerms(modeStr) {
        const raw = String(modeStr || "").trim();
        if (raw.length === 10)
            return raw.slice(1);
        return raw || "rwxr-xr-x";
    }

    function activateEntry(entry) {
        if (!entry)
            return;
        page.selectedPath = entry.path;
        page.menuOpen = false;
        const kind = page.entryKind(entry);
        if (kind === "dir" || entry.dir) {
            page.navigateTo(entry.path);
            return;
        }
        if (page.isStudioKind(kind) && win && win.shell) {
            win.shell.openMedia(entry.path);
            return;
        }
        Quickshell.execDetached(["xdg-open", entry.path]);
    }

    function openEntry(entry) {
        page.activateEntry(entry);
    }

    function openExternal(entry) {
        const target = entry || page.selectedEntry;
        if (!target)
            return;
        Quickshell.execDetached(["xdg-open", target.path]);
        page.menuOpen = false;
    }

    function openSelectedMedia() {
        if (!page.selectedEntry || !win || !win.shell)
            return;
        win.shell.openMedia(page.selectedEntry.path);
        page.menuOpen = false;
    }

    function copyEntry(entry) {
        const target = entry || page.selectedEntry;
        if (!target)
            return;
        page.clipboardPaths = [target.path];
        page.clipboardMode = "copy";
        page.statusText = "Скопировано в буфер: " + target.name;
        page.menuOpen = false;
    }

    function cutEntry(entry) {
        const target = entry || page.selectedEntry;
        if (!target)
            return;
        page.clipboardPaths = [target.path];
        page.clipboardMode = "cut";
        page.statusText = "Вырезано в буфер: " + target.name;
        page.menuOpen = false;
    }

    function pasteClipboard() {
        if (page.clipboardPaths.length === 0 || actionProc.running)
            return;
        const op = page.clipboardMode === "cut" ? "move" : "copy";
        page.runAction(op, [page.dir].concat(page.clipboardPaths));
    }

    function compressEntry(entry) {
        const target = entry || page.selectedEntry;
        if (!target || actionProc.running)
            return;
        page.menuOpen = false;
        page.runAction("compress", [target.path + ".zip", target.path]);
    }

    function extractEntry(entry) {
        const target = entry || page.selectedEntry;
        if (!target || actionProc.running)
            return;
        page.menuOpen = false;
        page.runAction("extract", [target.path, page.dir]);
    }

    function installFont(fontPath) {
        const target = String(fontPath || page.selectedPath || "").trim();
        if (target === "")
            return;
        Quickshell.execDetached([
            "sh", "-c",
            "bash \"$1\" install-font \"$2\" >/dev/null 2>&1 || bash \"$1\" install_font \"$2\" >/dev/null 2>&1 || (mkdir -p \"$HOME/.local/share/fonts\" && cp -f \"$2\" \"$HOME/.local/share/fonts/\" && fc-cache -f \"$HOME/.local/share/fonts\" >/dev/null 2>&1)",
            "sh", page.scriptPath, target
        ]);
        page.statusText = "Шрифт установлен в ~/.local/share/fonts";
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
        const name = String(page.dialogText).trim();
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

    function startInspect(targetPath) {
        const path = String(targetPath || "").trim();
        if (path === "") {
            inspectProc.running = false;
            page.inspectLoading = false;
            page.inspectTarget = "";
            page.inspectData = null;
            return;
        }
        page.inspectTarget = path;
        page.inspectLoading = true;
        inspectProc.output = "";
        inspectProc.errorOutput = "";
        inspectProc.running = false;
        inspectProc.command = ["bash", page.scriptPath, "inspect", path];
        inspectProc.running = true;
    }

    function finishInspect(exitCode) {
        if (page.inspectTarget !== page.selectedPath)
            return;
        page.inspectLoading = false;
        if (exitCode === 0) {
            try {
                const parsed = JSON.parse(inspectProc.output.trim() || "{}");
                if (parsed && typeof parsed === "object") {
                    if (!parsed.kind && page.selectedEntry)
                        parsed.kind = page.entryKind(page.selectedEntry);
                    page.inspectData = parsed;
                    return;
                }
            } catch (e) {}
        }
        if (page.selectedEntry) {
            page.inspectData = {
                name: page.selectedEntry.name,
                path: page.selectedEntry.path,
                kind: page.entryKind(page.selectedEntry),
                size: page.selectedEntry.size,
                mtime: page.selectedEntry.mtime,
                mode: page.selectedEntry.mode || ""
            };
        } else {
            page.inspectData = null;
        }
    }

    onSelectedPathChanged: page.startInspect(page.selectedPath)
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
        id: inspectProc
        property string output: ""
        property string errorOutput: ""
        command: ["bash", page.scriptPath, "inspect", page.selectedPath]
        stdout: SplitParser {
            onRead: line => inspectProc.output += (inspectProc.output === "" ? "" : "\n") + line
        }
        stderr: SplitParser {
            onRead: line => inspectProc.errorOutput += line + "\n"
        }
        onExited: exitCode => page.finishInspect(exitCode)
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
            if (exitCode !== 0) {
                page.statusText = actionProc.errorOutput.trim() || "Операция не выполнена.";
            } else {
                page.statusText = "Готово";
                if (action === "move") {
                    page.clipboardPaths = [];
                    page.clipboardMode = "";
                }
            }
            actionProc.actionName = "";
            page.menuOpen = false;
            if (action === "trash")
                page.selectedPath = "";
            page.refreshAll();
        }
    }

    // ── 1. ПОЛОСА ВКЛАДОК ПАПОК + БУФЕР ОБМЕНА ──────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.dp(6)

        Flickable {
            id: tabsFlick
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.dp(32)
            contentWidth: tabsRow.implicitWidth
            contentHeight: height
            clip: true
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds

            Row {
                id: tabsRow
                height: parent.height
                spacing: Theme.dp(6)

                Repeater {
                    model: page.tabsModel
                    delegate: Rectangle {
                        id: tabPill
                        required property var modelData
                        required property int index
                        readonly property bool active: tabPill.index === page.activeTabIndex
                        height: Theme.dp(32)
                        width: Math.min(Theme.dp(200), Math.max(Theme.dp(92), tabInnerRow.implicitWidth + Theme.dp(20)))
                        radius: tabPill.active ? Theme.rad(10) : Theme.radiusPill
                        color: tabPill.active ? Theme.secondaryContainer : Theme.mHigh

                        StateLayer {
                            radius: tabPill.radius
                            tint: tabPill.active ? Theme.fgSecondaryContainer : Theme.text
                            onClicked: page.switchTab(tabPill.index)
                        }

                        RowLayout {
                            id: tabInnerRow
                            anchors.fill: parent
                            anchors.leftMargin: Theme.dp(10)
                            anchors.rightMargin: Theme.dp(8)
                            spacing: Theme.dp(6)

                            Icon {
                                name: tabPill.active ? "folder_open" : "folder"
                                size: Theme.dp(15)
                                color: tabPill.active ? Theme.fgSecondaryContainer : Theme.primary
                                fill: tabPill.active ? 1 : 0
                            }
                            LText {
                                Layout.fillWidth: true
                                text: tabPill.modelData.title || "/"
                                role: "labelMedium"
                                color: tabPill.active ? Theme.fgSecondaryContainer : Theme.text
                                elide: Text.ElideRight
                            }
                            Item {
                                visible: page.tabsModel.length > 1
                                Layout.preferredWidth: Theme.dp(18)
                                Layout.preferredHeight: Theme.dp(18)

                                Rectangle {
                                    anchors.fill: parent
                                    radius: Theme.radiusPill
                                    color: closeTabMouse.containsMouse ? Theme.alpha(Theme.text, 0.14) : "transparent"
                                }
                                Icon {
                                    anchors.centerIn: parent
                                    name: "close"
                                    size: Theme.dp(13)
                                    color: tabPill.active ? Theme.fgSecondaryContainer : Theme.subtext
                                }
                                MouseArea {
                                    id: closeTabMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: page.closeTab(tabPill.index)
                                }
                            }
                        }
                    }
                }
            }
        }

        IconButton {
            size: "xs"
            variant: "tonal"
            icon: "add"
            tooltip: "Новая вкладка"
            onClicked: page.addTab(page.dir)
        }

        Button {
            visible: page.clipboardPaths.length > 0
            size: "xs"
            variant: "filled"
            icon: "content_paste"
            text: "Вставить сюда (" + page.clipboardPaths.length + ")"
            disabled: actionProc.running
            onClicked: page.pasteClipboard()
        }
        IconButton {
            visible: page.clipboardPaths.length > 0
            size: "xs"
            icon: "close"
            tooltip: "Очистить буфер"
            onClicked: {
                page.clipboardPaths = [];
                page.clipboardMode = "";
                page.statusText = "Буфер очищен";
            }
        }
    }

    // ── 2. НАВИГАЦИЯ + ИНТЕРАКТИВНЫЕ ХЛЕБНЫЕ КРОШКИ + ФИЛЬТР + ВИДЫ ─────
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.dp(6)

        IconButton {
            size: "xs"
            icon: "arrow_back"
            tooltip: "Назад"
            disabled: !page.canGoBack || listProc.running
            onClicked: page.goBack()
        }
        IconButton {
            size: "xs"
            icon: "arrow_forward"
            tooltip: "Вперёд"
            disabled: !page.canGoForward || listProc.running
            onClicked: page.goForward()
        }
        IconButton {
            size: "xs"
            icon: "arrow_upward"
            tooltip: "Вверх"
            disabled: page.dir === "/" || page.dir === "" || listProc.running
            onClicked: page.goUp()
        }

        // Интерактивные хлебные крошки (по умолчанию)
        Rectangle {
            visible: !page.editingPath
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.dp(34)
            radius: Theme.radiusPill
            color: Theme.mHigh
            clip: true

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.dp(8)
                anchors.rightMargin: Theme.dp(4)
                spacing: Theme.dp(4)

                Flickable {
                    id: crumbsFlick
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentWidth: crumbsRow.implicitWidth
                    contentHeight: height
                    clip: true
                    flickableDirection: Flickable.HorizontalFlick
                    boundsBehavior: Flickable.StopAtBounds
                    onContentWidthChanged: {
                        if (contentWidth > width)
                            contentX = contentWidth - width;
                        else
                            contentX = 0;
                    }

                    Row {
                        id: crumbsRow
                        height: parent.height
                        spacing: Theme.dp(2)

                        Repeater {
                            model: page.breadcrumbs
                            delegate: Row {
                                id: crumbItem
                                required property var modelData
                                required property int index
                                height: crumbsRow.height
                                spacing: Theme.dp(2)

                                Icon {
                                    visible: crumbItem.index > 0
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: "chevron_right"
                                    size: Theme.dp(14)
                                    color: Theme.subtext
                                }

                                Rectangle {
                                    readonly property bool isLast: crumbItem.index === page.breadcrumbs.length - 1
                                    anchors.verticalCenter: parent.verticalCenter
                                    height: Theme.dp(24)
                                    width: crumbLabelRow.implicitWidth + Theme.dp(14)
                                    radius: Theme.radiusPill
                                    color: isLast ? Theme.secondaryContainer : (crumbMouse.containsMouse ? Theme.bgHover : "transparent")

                                    Row {
                                        id: crumbLabelRow
                                        anchors.centerIn: parent
                                        spacing: Theme.dp(4)

                                        Icon {
                                            visible: crumbItem.index === 0
                                            anchors.verticalCenter: parent.verticalCenter
                                            name: "hard_drive"
                                            size: Theme.dp(13)
                                            color: crumbItem.index === page.breadcrumbs.length - 1 ? Theme.fgSecondaryContainer : Theme.primary
                                        }
                                        LText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: crumbItem.modelData.label
                                            role: "labelMedium"
                                            color: crumbItem.index === page.breadcrumbs.length - 1 ? Theme.fgSecondaryContainer : Theme.text
                                        }
                                    }

                                    MouseArea {
                                        id: crumbMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: page.navigateTo(crumbItem.modelData.path)
                                    }
                                }
                            }
                        }
                    }
                }

                IconButton {
                    size: "xs"
                    icon: "edit"
                    tooltip: "Редактировать путь"
                    onClicked: {
                        pathInput.text = page.dir;
                        page.editingPath = true;
                        Qt.callLater(() => {
                            pathInput.forceActiveFocus();
                            pathInput.input.selectAll();
                        });
                    }
                }
            }
        }

        // Поле ручного ввода пути (при нажатии edit)
        RowLayout {
            visible: page.editingPath
            Layout.fillWidth: true
            spacing: Theme.dp(4)

            TextField {
                id: pathInput
                Layout.fillWidth: true
                variant: "search"
                icon: "folder_open"
                placeholder: "Путь к папке"
                text: page.dir
                enabled: !listProc.running
                onAccepted: {
                    page.editingPath = false;
                    page.navigateTo(text);
                }
                onEscaped: {
                    page.editingPath = false;
                    pathInput.text = page.dir;
                }
            }
            IconButton {
                size: "xs"
                variant: "tonal"
                icon: "check"
                tooltip: "Перейти"
                onClicked: {
                    page.editingPath = false;
                    page.navigateTo(pathInput.text);
                }
            }
            IconButton {
                size: "xs"
                icon: "close"
                tooltip: "Отмена"
                onClicked: {
                    page.editingPath = false;
                    pathInput.text = page.dir;
                }
            }
        }

        // Компактный мгновенный фильтр в папке
        Rectangle {
            Layout.preferredWidth: Theme.dp(170)
            Layout.preferredHeight: Theme.dp(34)
            radius: Theme.radiusPill
            color: Theme.mHigh

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.dp(10)
                anchors.rightMargin: Theme.dp(6)
                spacing: Theme.dp(6)

                Icon {
                    name: "search"
                    size: Theme.dp(16)
                    color: filterTextInput.activeFocus ? Theme.primary : Theme.subtext
                }
                TextInput {
                    id: filterTextInput
                    Layout.fillWidth: true
                    clip: true
                    color: Theme.text
                    selectionColor: Theme.alpha(Theme.primary, 0.35)
                    selectedTextColor: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.typeSize("bodySmall")
                    text: page.filterText
                    onTextEdited: {
                        page.filterText = text;
                        page.applySort();
                    }

                    LText {
                        visible: filterTextInput.text === ""
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Фильтр в папке…"
                        role: "bodySmall"
                        color: Theme.subtext
                        opacity: 0.8
                    }
                }
                Item {
                    visible: filterTextInput.text !== ""
                    Layout.preferredWidth: Theme.dp(18)
                    Layout.preferredHeight: Theme.dp(18)
                    Icon {
                        anchors.centerIn: parent
                        name: "close"
                        size: Theme.dp(14)
                        color: Theme.subtext
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            filterTextInput.text = "";
                            page.filterText = "";
                            page.applySort();
                        }
                    }
                }
            }
        }

        // Переключатели режима вида: Список / Плитка / Инспектор
        IconButton {
            size: "xs"
            icon: "list"
            tooltip: "Список"
            checkable: true
            checked: !page.gridMode
            variant: !page.gridMode ? "tonal" : "standard"
            onClicked: page.gridMode = false
        }
        IconButton {
            size: "xs"
            icon: "grid_view"
            tooltip: "Плитка (Grid)"
            checkable: true
            checked: page.gridMode
            variant: page.gridMode ? "tonal" : "standard"
            onClicked: page.gridMode = true
        }
        IconButton {
            size: "xs"
            icon: "preview"
            tooltip: "Инспектор (QuickLook)"
            checkable: true
            checked: page.inspectorOpen
            variant: page.inspectorOpen ? "tonal" : "standard"
            onClicked: page.inspectorOpen = !page.inspectorOpen
        }

        IconButton {
            size: "xs"
            icon: "refresh"
            tooltip: "Обновить"
            disabled: listProc.running
            onClicked: page.refreshAll()
        }
        IconButton {
            size: "xs"
            icon: "terminal"
            tooltip: "Открыть текущую папку в терминале островка"
            onClicked: if (page.win && page.win.shell) page.win.shell.openTerminal(page.currentPath)
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
            size: "xs"
            icon: "more_vert"
            tooltip: "Действия"
            disabled: actionProc.running
            onClicked: page.menuOpen = !page.menuOpen
        }
    }

    // ── КОНТЕКСТНАЯ ПАНЕЛЬ ДЕЙСТВИЙ И АРХИВОВ ───────────────────────────
    Flickable {
        visible: page.menuOpen && page.selectedEntry !== null
        Layout.fillWidth: true
        Layout.preferredHeight: Theme.dp(34)
        contentWidth: contextMenuRow.implicitWidth
        contentHeight: height
        clip: true
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds

        Row {
            id: contextMenuRow
            height: parent.height
            spacing: Theme.dp(4)

            Button {
                text: "Открыть"
                icon: "open_in_new"
                size: "xs"
                variant: "tonal"
                onClicked: {
                    if (page.selectedEntry)
                        page.activateEntry(page.selectedEntry);
                }
            }
            Button {
                visible: page.selectedMedia
                text: "Открыть в Студии"
                icon: "play_arrow"
                size: "xs"
                variant: "text"
                onClicked: page.openSelectedMedia()
            }
            Button {
                text: "Копировать"
                icon: "content_copy"
                size: "xs"
                variant: "text"
                onClicked: page.copyEntry(page.selectedEntry)
            }
            Button {
                text: "Вырезать"
                icon: "swap_horiz"
                size: "xs"
                variant: "text"
                onClicked: page.cutEntry(page.selectedEntry)
            }
            Button {
                text: "Упаковать в .zip"
                icon: "archive"
                size: "xs"
                variant: "text"
                disabled: actionProc.running
                onClicked: page.compressEntry(page.selectedEntry)
            }
            Button {
                visible: page.selectedEntry !== null && page.entryKind(page.selectedEntry) === "archive"
                text: "Распаковать сюда"
                icon: "folder_open"
                size: "xs"
                variant: "text"
                disabled: actionProc.running
                onClicked: page.extractEntry(page.selectedEntry)
            }
            Button {
                text: "Переименовать"
                icon: "edit"
                size: "xs"
                variant: "text"
                onClicked: page.beginRename()
            }
            Button {
                text: "Копировать путь"
                icon: "link"
                size: "xs"
                variant: "text"
                onClicked: page.copySelectedPath()
            }
            Button {
                text: "Открыть папку в терминале"
                icon: "terminal"
                size: "xs"
                variant: "text"
                onClicked: {
                    const targetDir = (page.selectedEntry && page.selectedEntry.dir) ? page.selectedEntry.path : page.currentPath;
                    page.menuOpen = false;
                    if (page.win && page.win.shell)
                        page.win.shell.openTerminal(targetDir);
                }
            }
            Button {
                visible: page.selectedEntry !== null && !page.selectedEntry.dir
                text: "Открыть во внешней программе (xdg-open)"
                icon: "open_in_new"
                size: "xs"
                variant: "text"
                onClicked: page.openExternal(page.selectedEntry)
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
    }

    // ── ДИАЛОГ СОЗДАНИЯ ПАПКИ / ПЕРЕИМЕНОВАНИЯ ──────────────────────────
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

    // ── 3-КОЛОНОЧНАЯ РАБОЧАЯ ОБЛАСТЬ (МЕСТА/ДИСКИ + ФАЙЛЫ + ИНСПЕКТОР) ──
    RowLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.preferredHeight: Theme.dp(420)
        Layout.minimumHeight: Theme.dp(320)
        spacing: Theme.dp(10)

        // Левая колонка: Места и Диски
        Rectangle {
            Layout.preferredWidth: Theme.dp(176)
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
                    spacing: Theme.dp(3)

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: Theme.dp(2)
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
                            id: placeBtn
                            required property var modelData
                            Layout.fillWidth: true
                            text: placeBtn.modelData.name
                            icon: page.placeIcon(placeBtn.modelData.name)
                            size: "xs"
                            variant: "text"
                            checkable: true
                            checked: page.dir === placeBtn.modelData.path
                            onClicked: page.navigateTo(placeBtn.modelData.path)
                        }
                    }
                    Button {
                        Layout.fillWidth: true
                        text: "Корзина (" + page.trashCount + ")"
                        icon: "delete"
                        size: "xs"
                        variant: "text"
                        checkable: true
                        checked: page.dir === page.trashFilesDir
                        onClicked: page.navigateTo(page.trashFilesDir)
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
                            id: diskRow
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: Theme.dp(4)

                            Item {
                                Layout.fillWidth: true
                                implicitHeight: diskLabelCol.implicitHeight

                                ColumnLayout {
                                    id: diskLabelCol
                                    width: parent.width
                                    spacing: Theme.dp(1)
                                    LText {
                                        Layout.fillWidth: true
                                        text: diskRow.modelData.label || diskRow.modelData.name
                                        role: "bodySmall"
                                        weight: 500
                                        elide: Text.ElideRight
                                    }
                                    LText {
                                        Layout.fillWidth: true
                                        text: diskRow.modelData.mounted ? diskRow.modelData.mountpoint : page.formatBytes(diskRow.modelData.size)
                                        role: "labelSmall"
                                        color: Theme.subtext
                                        elide: Text.ElideMiddle
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    enabled: Boolean(diskRow.modelData.mounted && diskRow.modelData.mountpoint)
                                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: if (diskRow.modelData.mountpoint) page.navigateTo(diskRow.modelData.mountpoint)
                                }
                            }
                            IconButton {
                                size: "xs"
                                icon: diskRow.modelData.mounted ? "logout" : "usb"
                                tooltip: diskRow.modelData.mounted ? "Извлечь" : "Подключить"
                                disabled: actionProc.running
                                onClicked: page.runAction(diskRow.modelData.mounted ? "eject" : "mount", [diskRow.modelData.path])
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

        // Центральная колонка: Список или 4-колоночная Плитка
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Theme.dp(4)

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.dp(8)
                Layout.rightMargin: Theme.dp(8)
                spacing: Theme.dp(8)

                Item {
                    Layout.preferredWidth: Theme.dp(18)
                    Layout.preferredHeight: Theme.dp(26)
                }
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.dp(26)
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
                    Layout.preferredWidth: Theme.dp(64)
                    Layout.preferredHeight: Theme.dp(26)
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
                    visible: !page.inspectorOpen
                    Layout.preferredWidth: Theme.dp(102)
                    Layout.preferredHeight: Theme.dp(26)
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
                    Layout.preferredHeight: Theme.dp(26)
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

                // Режим списка
                ListView {
                    id: filesList
                    visible: !page.gridMode
                    anchors.fill: parent
                    model: page.entries
                    clip: true
                    spacing: Theme.dp(2)
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Item {
                        id: rowItem
                        required property var modelData
                        readonly property bool isSelected: page.selectedPath === rowItem.modelData.path
                        readonly property bool inClipboard: page.clipboardPaths.includes(rowItem.modelData.path)
                        width: filesList.width
                        height: Theme.dp(40)
                        opacity: rowItem.inClipboard && page.clipboardMode === "cut" ? 0.55 : 1.0

                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.rad(10)
                            color: rowItem.isSelected
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
                                name: page.entryIcon(rowItem.modelData)
                                size: Theme.dp(18)
                                color: rowItem.isSelected ? Theme.fgSecondaryContainer : Theme.primary
                                fill: rowItem.modelData.dir ? 1 : 0
                            }
                            LText {
                                Layout.fillWidth: true
                                text: rowItem.modelData.name + (rowItem.modelData.isLink ? " ↗" : "")
                                role: "bodyMedium"
                                color: rowItem.isSelected ? Theme.fgSecondaryContainer : Theme.text
                                elide: Text.ElideRight
                            }
                            LText {
                                Layout.preferredWidth: Theme.dp(64)
                                text: rowItem.modelData.dir ? "—" : page.formatBytes(rowItem.modelData.size)
                                role: "bodySmall"
                                color: Theme.subtext
                                horizontalAlignment: Text.AlignRight
                                elide: Text.ElideRight
                            }
                            LText {
                                visible: !page.inspectorOpen
                                Layout.preferredWidth: Theme.dp(102)
                                text: page.formatDate(rowItem.modelData.mtime)
                                role: "bodySmall"
                                color: Theme.subtext
                                horizontalAlignment: Text.AlignRight
                            }
                            LText {
                                Layout.preferredWidth: Theme.dp(62)
                                text: page.typeLabel(rowItem.modelData)
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
                                page.selectedPath = rowItem.modelData.path;
                                page.menuOpen = mouse.button === Qt.RightButton;
                            }
                            onDoubleClicked: mouse => {
                                if (mouse.button === Qt.LeftButton)
                                    page.activateEntry(rowItem.modelData);
                            }
                        }
                    }
                }

                // Режим 4-колоночной плитки (Grid) с живыми миниатюрами
                GridView {
                    id: filesGrid
                    visible: page.gridMode
                    anchors.fill: parent
                    model: page.entries
                    clip: true
                    cellWidth: Math.floor(width / 4)
                    cellHeight: Theme.dp(122)
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Item {
                        id: gridCell
                        required property var modelData
                        readonly property bool isSelected: page.selectedPath === gridCell.modelData.path
                        readonly property string itemKind: page.entryKind(gridCell.modelData)
                        width: filesGrid.cellWidth
                        height: filesGrid.cellHeight

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: Theme.dp(4)
                            radius: Theme.rad(14)
                            color: gridCell.isSelected
                                ? Theme.secondaryContainer
                                : (cellMouse.containsMouse ? Theme.bgHover : Theme.mHigh)
                            clip: true

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: Theme.dp(6)
                                spacing: Theme.dp(4)

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    radius: Theme.rad(10)
                                    color: Theme.mContainer
                                    clip: true

                                    Image {
                                        anchors.fill: parent
                                        visible: gridCell.itemKind === "image"
                                        source: visible ? ("file://" + gridCell.modelData.path) : ""
                                        sourceSize: Qt.size(160, 120)
                                        fillMode: Image.PreserveAspectCrop
                                        asynchronous: true
                                        cache: true
                                    }

                                    Icon {
                                        visible: gridCell.itemKind !== "image"
                                        anchors.centerIn: parent
                                        name: page.kindIcon(gridCell.itemKind)
                                        size: Theme.dp(30)
                                        color: gridCell.isSelected ? Theme.fgSecondaryContainer : Theme.primary
                                        fill: gridCell.modelData.dir ? 1 : 0
                                    }

                                    Rectangle {
                                        visible: !gridCell.modelData.dir
                                        anchors.right: parent.right
                                        anchors.bottom: parent.bottom
                                        anchors.margins: Theme.dp(4)
                                        height: Theme.dp(16)
                                        width: extLabel.implicitWidth + Theme.dp(8)
                                        radius: Theme.radiusPill
                                        color: Theme.alpha(Theme.mLowest, 0.78)

                                        LText {
                                            id: extLabel
                                            anchors.centerIn: parent
                                            text: (page.extension(gridCell.modelData.name) || gridCell.itemKind).toUpperCase().slice(0, 5)
                                            role: "labelSmall"
                                            size: Theme.fs(9)
                                            color: Theme.text
                                        }
                                    }
                                }

                                LText {
                                    Layout.fillWidth: true
                                    text: gridCell.modelData.name
                                    role: "labelMedium"
                                    color: gridCell.isSelected ? Theme.fgSecondaryContainer : Theme.text
                                    horizontalAlignment: Text.AlignHCenter
                                    elide: Text.ElideMiddle
                                }

                                LText {
                                    Layout.fillWidth: true
                                    text: gridCell.modelData.dir ? "Папка" : page.formatBytes(gridCell.modelData.size)
                                    role: "labelSmall"
                                    color: Theme.subtext
                                    horizontalAlignment: Text.AlignHCenter
                                    elide: Text.ElideRight
                                }
                            }

                            MouseArea {
                                id: cellMouse
                                anchors.fill: parent
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                hoverEnabled: true
                                onClicked: mouse => {
                                    page.selectedPath = gridCell.modelData.path;
                                    page.menuOpen = mouse.button === Qt.RightButton;
                                }
                                onDoubleClicked: mouse => {
                                    if (mouse.button === Qt.LeftButton)
                                        page.activateEntry(gridCell.modelData);
                                }
                            }
                        }
                    }
                }

                // Пустое состояние / Ошибка
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
                            : (page.errorText !== "" ? page.errorText
                                : (page.filterText !== "" ? "Ничего не найдено по фильтру" : "Папка пуста"))
                        role: "bodyMedium"
                        color: page.errorText !== "" ? Theme.error : Theme.subtext
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }

        // ── 3. ПРАВАЯ КОЛОНКА: ЖИВОЙ ИНСПЕКТОР (QuickLook) ──────────────
        Rectangle {
            visible: page.inspectorOpen
            Layout.preferredWidth: Theme.dp(270)
            Layout.fillHeight: true
            radius: Theme.shapeLgInc
            color: Theme.mHigh
            clip: true

            // Состояние, когда файл не выбран — сводка текущей папки
            ColumnLayout {
                visible: page.selectedEntry === null
                anchors.fill: parent
                anchors.margins: Theme.dp(12)
                spacing: Theme.dp(10)

                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: Theme.dp(16)
                    width: Theme.dp(56)
                    height: Theme.dp(56)
                    radius: Theme.rad(16)
                    color: Theme.secondaryContainer

                    Icon {
                        anchors.centerIn: parent
                        name: "folder_open"
                        size: Theme.dp(28)
                        color: Theme.fgSecondaryContainer
                        fill: 1
                    }
                }

                LText {
                    Layout.fillWidth: true
                    text: page.tabTitleFor(page.dir)
                    role: "titleMedium"
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideMiddle
                }
                LText {
                    Layout.fillWidth: true
                    text: page.dir
                    role: "bodySmall"
                    color: Theme.subtext
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WrapAnywhere
                }

                Rectangle {
                    Layout.fillWidth: true
                    radius: Theme.rad(12)
                    color: Theme.mContainer
                    implicitHeight: folderStatsCol.implicitHeight + Theme.dp(16)

                    ColumnLayout {
                        id: folderStatsCol
                        anchors.fill: parent
                        anchors.margins: Theme.dp(8)
                        spacing: Theme.dp(4)

                        LText {
                            text: "Элементов в папке: " + page.rawEntries.length
                            role: "bodySmall"
                        }
                        LText {
                            text: "Папок: " + page.rawEntries.filter(e => e.dir).length
                                + " · Файлов: " + page.rawEntries.filter(e => !e.dir).length
                            role: "bodySmall"
                            color: Theme.subtext
                        }
                    }
                }

                LText {
                    Layout.fillWidth: true
                    text: "Выберите любой файл для мгновенного предпросмотра содержимого, метаданных и действий."
                    role: "bodySmall"
                    color: Theme.subtext
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }

                Item { Layout.fillHeight: true }
            }

            // Живой QuickLook-инспектор выбранного элемента
            Flickable {
                id: inspectorScroll
                visible: page.selectedEntry !== null
                anchors.fill: parent
                anchors.margins: Theme.dp(10)
                clip: true
                contentWidth: width
                contentHeight: inspectorCol.implicitHeight
                flickableDirection: Flickable.VerticalFlick
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: inspectorCol
                    width: inspectorScroll.width
                    spacing: Theme.dp(8)

                    // Шапка инспектора: Иконка + Имя + Бейдж типа + Размер + Права
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.dp(8)

                        Rectangle {
                            Layout.preferredWidth: Theme.dp(42)
                            Layout.preferredHeight: Theme.dp(42)
                            radius: Theme.rad(12)
                            color: Theme.secondaryContainer

                            Icon {
                                anchors.centerIn: parent
                                name: page.kindIcon(page.selectedKind)
                                size: Theme.dp(22)
                                color: Theme.fgSecondaryContainer
                                fill: 1
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Theme.dp(2)

                            LText {
                                Layout.fillWidth: true
                                text: page.selectedEntry ? page.selectedEntry.name : ""
                                role: "titleSmall"
                                elide: Text.ElideMiddle
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.dp(6)

                                Badge {
                                    text: page.kindLabel(page.selectedKind)
                                    tone: "accent"
                                }
                                LText {
                                    visible: page.selectedEntry !== null && !page.selectedEntry.dir
                                    text: page.formatBytes(page.inspectData && page.inspectData.size !== undefined
                                        ? page.inspectData.size
                                        : (page.selectedEntry ? page.selectedEntry.size : 0))
                                    role: "labelSmall"
                                    color: Theme.subtext
                                }
                            }
                        }
                    }

                    // Права доступа и дата изменения
                    Rectangle {
                        Layout.fillWidth: true
                        radius: Theme.rad(10)
                        color: Theme.mContainer
                        implicitHeight: metaHeaderRow.implicitHeight + Theme.dp(10)

                        RowLayout {
                            id: metaHeaderRow
                            anchors.fill: parent
                            anchors.margins: Theme.dp(6)
                            spacing: Theme.dp(6)

                            LText {
                                mono: true
                                role: "labelSmall"
                                color: Theme.primary
                                text: page.formatPerms(page.inspectData && (page.inspectData.mode || page.inspectData.permissions)
                                    ? (page.inspectData.mode || page.inspectData.permissions)
                                    : (page.selectedEntry ? page.selectedEntry.mode : "rwxr-xr-x"))
                            }
                            Item { Layout.fillWidth: true }
                            LText {
                                role: "labelSmall"
                                color: Theme.subtext
                                text: page.formatDate(page.selectedEntry ? page.selectedEntry.mtime : 0)
                            }
                        }
                    }

                    // ── ПРЕВЬЮ: IMAGE ─────────────────────────────────────
                    ColumnLayout {
                        visible: page.selectedKind === "image"
                        Layout.fillWidth: true
                        spacing: Theme.dp(6)

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: Theme.dp(156)
                            radius: Theme.rad(12)
                            color: Theme.mLowest
                            clip: true

                            Image {
                                id: inspectImagePreview
                                anchors.fill: parent
                                source: page.selectedKind === "image" && page.selectedPath !== ""
                                    ? page.localFileUrl(page.inspectData && page.inspectData.preview_image ? page.inspectData.preview_image : page.selectedPath)
                                    : ""
                                sourceSize: Qt.size(320, 240)
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: true
                            }

                            Rectangle {
                                visible: (page.inspectData && page.inspectData.width > 0 && page.inspectData.height > 0)
                                    || inspectImagePreview.implicitWidth > 0
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                anchors.margins: Theme.dp(6)
                                height: Theme.dp(20)
                                width: resLabel.implicitWidth + Theme.dp(12)
                                radius: Theme.radiusPill
                                color: Theme.alpha(Theme.mLowest, 0.82)

                                LText {
                                    id: resLabel
                                    anchors.centerIn: parent
                                    role: "labelSmall"
                                    text: page.inspectData && page.inspectData.width > 0 && page.inspectData.height > 0
                                        ? (page.inspectData.width + " × " + page.inspectData.height)
                                        : (inspectImagePreview.implicitWidth + " × " + inspectImagePreview.implicitHeight)
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.dp(6)

                            Button {
                                Layout.fillWidth: true
                                size: "xs"
                                variant: "filled"
                                icon: "open_in_new"
                                text: "Открыть в студии"
                                onClicked: if (win && win.shell) win.shell.openMedia(page.selectedPath)
                            }
                            Button {
                                Layout.fillWidth: true
                                size: "xs"
                                variant: "tonal"
                                icon: "wallpaper"
                                text: "Сделать обоями"
                                onClicked: {
                                    Wallpaper.apply(page.selectedPath, false);
                                    page.statusText = "Обои применены";
                                }
                            }
                        }
                    }

                    // ── ПРЕВЬЮ: VIDEO / AUDIO ─────────────────────────────
                    ColumnLayout {
                        visible: page.selectedKind === "video" || page.selectedKind === "audio"
                        Layout.fillWidth: true
                        spacing: Theme.dp(6)

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: Theme.dp(136)
                            radius: Theme.rad(12)
                            color: Theme.mLowest
                            clip: true

                            Image {
                                id: mediaThumbImg
                                anchors.fill: parent
                                readonly property string thumbPath: page.inspectData
                                    ? String(page.inspectData.preview_image || page.inspectData.thumbnail || page.inspectData.cover || "")
                                    : ""
                                visible: thumbPath !== ""
                                source: visible ? page.localFileUrl(thumbPath) : ""
                                sourceSize: Qt.size(320, 200)
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                            }

                            ColumnLayout {
                                visible: !mediaThumbImg.visible
                                anchors.centerIn: parent
                                spacing: Theme.dp(4)

                                Icon {
                                    Layout.alignment: Qt.AlignHCenter
                                    name: page.selectedKind === "video" ? "movie" : "music_note"
                                    size: Theme.dp(34)
                                    color: Theme.primary
                                }
                                LText {
                                    Layout.alignment: Qt.AlignHCenter
                                    role: "labelMedium"
                                    color: Theme.subtext
                                    text: page.selectedKind === "video" ? "Видеофайл" : "Аудиодорожка"
                                }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            radius: Theme.rad(10)
                            color: Theme.mContainer
                            implicitHeight: mediaMetaCol.implicitHeight + Theme.dp(12)

                            ColumnLayout {
                                id: mediaMetaCol
                                anchors.fill: parent
                                anchors.margins: Theme.dp(6)
                                spacing: Theme.dp(2)

                                LText {
                                    visible: Boolean(page.inspectData && (
                                        page.inspectData.title || page.inspectData.artist
                                        || (page.inspectData.media_info && (page.inspectData.media_info.title || page.inspectData.media_info.artist))
                                    ))
                                    Layout.fillWidth: true
                                    role: "labelMedium"
                                    elide: Text.ElideRight
                                    text: {
                                        if (!page.inspectData)
                                            return "";
                                        const mi = page.inspectData.media_info || {};
                                        return [mi.artist || page.inspectData.artist, mi.title || page.inspectData.title].filter(Boolean).join(" — ");
                                    }
                                }
                                LText {
                                    Layout.fillWidth: true
                                    role: "bodySmall"
                                    color: Theme.subtext
                                    wrapMode: Text.WordWrap
                                    text: {
                                        if (!page.inspectData)
                                            return "Метаданные медиа";
                                        const mi = page.inspectData.media_info || {};
                                        const parts = [];
                                        const dur = mi.duration || page.inspectData.duration || 0;
                                        const w = mi.width || page.inspectData.width || 0;
                                        const h = mi.height || page.inspectData.height || 0;
                                        const codec = mi.codec || page.inspectData.codec || "";
                                        const br = mi.bit_rate || mi.bitrate || page.inspectData.bit_rate || page.inspectData.bitrate || 0;
                                        if (page.inspectData.duration_text)
                                            parts.push(page.inspectData.duration_text);
                                        else if (dur > 0)
                                            parts.push(page.formatDuration(dur));
                                        if (w > 0 && h > 0)
                                            parts.push(w + "×" + h);
                                        if (codec)
                                            parts.push(String(codec));
                                        if (page.inspectData.bitrate_text)
                                            parts.push(String(page.inspectData.bitrate_text));
                                        else if (br > 0)
                                            parts.push(Math.round(Number(br) / 1000) + " кбит/с");
                                        return parts.length > 0 ? parts.join(" · ") : "Готово к воспроизведению";
                                    }
                                }
                            }
                        }

                        Button {
                            Layout.fillWidth: true
                            size: "xs"
                            variant: "filled"
                            icon: "play_arrow"
                            text: "Открыть в плеере"
                            onClicked: if (win && win.shell) win.shell.openMedia(page.selectedPath)
                        }
                    }

                    // ── ПРЕВЬЮ: PDF ───────────────────────────────────────
                    ColumnLayout {
                        visible: page.selectedKind === "pdf"
                        Layout.fillWidth: true
                        spacing: Theme.dp(6)

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: Theme.dp(156)
                            radius: Theme.rad(12)
                            color: Theme.mLowest
                            clip: true

                            Image {
                                id: pdfThumbImg
                                anchors.fill: parent
                                readonly property string previewPath: page.inspectData && page.inspectData.preview_image
                                    ? String(page.inspectData.preview_image) : ""
                                visible: previewPath !== ""
                                source: visible ? page.localFileUrl(previewPath) : ""
                                sourceSize: Qt.size(320, 240)
                                fillMode: Image.PreserveAspectFit
                                asynchronous: true
                            }

                            ColumnLayout {
                                visible: !pdfThumbImg.visible
                                anchors.centerIn: parent
                                spacing: Theme.dp(4)

                                Icon {
                                    Layout.alignment: Qt.AlignHCenter
                                    name: "description"
                                    size: Theme.dp(34)
                                    color: Theme.primary
                                }
                                LText {
                                    Layout.alignment: Qt.AlignHCenter
                                    role: "labelMedium"
                                    color: Theme.subtext
                                    text: "Документ PDF"
                                }
                            }

                            Rectangle {
                                visible: Boolean(page.inspectData && (page.inspectData.pdf_pages || page.inspectData.pages || page.inspectData.page_count))
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                anchors.margins: Theme.dp(6)
                                height: Theme.dp(20)
                                width: pdfPagesLabel.implicitWidth + Theme.dp(12)
                                radius: Theme.radiusPill
                                color: Theme.alpha(Theme.mLowest, 0.85)

                                LText {
                                    id: pdfPagesLabel
                                    anchors.centerIn: parent
                                    role: "labelSmall"
                                    text: (page.inspectData ? (page.inspectData.pdf_pages || page.inspectData.pages || page.inspectData.page_count || 1) : 1) + " стр."
                                }
                            }
                        }

                        Button {
                            Layout.fillWidth: true
                            size: "xs"
                            variant: "filled"
                            icon: "description"
                            text: "Читать PDF"
                            onClicked: if (win && win.shell) win.shell.openMedia(page.selectedPath)
                        }
                    }

                    // ── ПРЕВЬЮ: CODE / MARKDOWN / TEXT ────────────────────
                    ColumnLayout {
                        visible: page.selectedKind === "code" || page.selectedKind === "markdown" || page.selectedKind === "text"
                        Layout.fillWidth: true
                        spacing: Theme.dp(6)

                        RowLayout {
                            Layout.fillWidth: true
                            LText {
                                Layout.fillWidth: true
                                role: "labelSmall"
                                color: Theme.subtext
                                text: "Предпросмотр текста"
                            }
                            LText {
                                visible: Boolean(page.inspectData && (page.inspectData.line_count || page.inspectData.lines_count || page.inspectData.total_lines))
                                role: "labelSmall"
                                color: Theme.primary
                                text: (page.inspectData ? (page.inspectData.line_count || page.inspectData.lines_count || page.inspectData.total_lines || 0) : 0) + " строк"
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: Theme.dp(156)
                            radius: Theme.rad(10)
                            color: Theme.mLowest
                            clip: true

                            Flickable {
                                anchors.fill: parent
                                anchors.margins: Theme.dp(8)
                                contentWidth: width
                                contentHeight: codeSnippetText.implicitHeight
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds

                                LText {
                                    id: codeSnippetText
                                    width: parent.width
                                    mono: true
                                    role: "bodySmall"
                                    size: Theme.fs(10.5)
                                    color: Theme.text
                                    wrapMode: Text.WrapAnywhere
                                    text: {
                                        if (!page.inspectData)
                                            return page.inspectLoading ? "Чтение файла…" : "";
                                        const raw = page.inspectData.text_preview
                                            || page.inspectData.preview_text
                                            || page.inspectData.preview
                                            || page.inspectData.content
                                            || (Array.isArray(page.inspectData.lines) ? page.inspectData.lines.slice(0, 25).join("\n") : "");
                                        if (!raw)
                                            return page.inspectLoading ? "Чтение файла…" : "(Пустой файл)";
                                        return String(raw).split("\n").slice(0, 25).join("\n");
                                    }
                                }
                            }
                        }

                        Button {
                            Layout.fillWidth: true
                            size: "xs"
                            variant: "filled"
                            icon: "code"
                            text: "Открыть просмотр"
                            onClicked: if (win && win.shell) win.shell.openMedia(page.selectedPath)
                        }
                    }

                    // ── ПРЕВЬЮ: ARCHIVE ───────────────────────────────────
                    ColumnLayout {
                        visible: page.selectedKind === "archive"
                        Layout.fillWidth: true
                        spacing: Theme.dp(6)

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: Theme.dp(140)
                            radius: Theme.rad(10)
                            color: Theme.mLowest
                            clip: true

                            Flickable {
                                anchors.fill: parent
                                anchors.margins: Theme.dp(8)
                                contentWidth: width
                                contentHeight: archiveListCol.implicitHeight
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds

                                ColumnLayout {
                                    id: archiveListCol
                                    width: parent.width
                                    spacing: Theme.dp(3)

                                    Repeater {
                                        model: {
                                            if (!page.inspectData)
                                                return [];
                                            const arr = page.inspectData.archive_entries
                                                || page.inspectData.entries
                                                || page.inspectData.files
                                                || [];
                                            return Array.isArray(arr) ? arr.slice(0, 20) : [];
                                        }
                                        delegate: RowLayout {
                                            id: archEntryRow
                                            required property var modelData
                                            Layout.fillWidth: true
                                            spacing: Theme.dp(4)

                                            Icon {
                                                name: "description"
                                                size: Theme.dp(13)
                                                color: Theme.primary
                                            }
                                            LText {
                                                Layout.fillWidth: true
                                                mono: true
                                                role: "labelSmall"
                                                elide: Text.ElideMiddle
                                                text: typeof archEntryRow.modelData === "string"
                                                    ? archEntryRow.modelData
                                                    : String(archEntryRow.modelData.name || archEntryRow.modelData.path || "")
                                            }
                                        }
                                    }

                                    LText {
                                        visible: !page.inspectData || !(page.inspectData.archive_entries || page.inspectData.entries || page.inspectData.files || []).length
                                        role: "bodySmall"
                                        color: Theme.subtext
                                        text: page.inspectLoading ? "Чтение архива…" : "Архив готов к распаковке"
                                    }
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.dp(6)

                            Button {
                                Layout.fillWidth: true
                                size: "xs"
                                variant: "tonal"
                                icon: "folder_open"
                                text: "Распаковать"
                                disabled: actionProc.running
                                onClicked: page.extractEntry(page.selectedEntry)
                            }
                            Button {
                                Layout.fillWidth: true
                                size: "xs"
                                variant: "filled"
                                icon: "archive"
                                text: "Обзор архива"
                                onClicked: if (win && win.shell) win.shell.openMedia(page.selectedPath)
                            }
                        }
                    }

                    // ── ПРЕВЬЮ: TABLE / SQLITE ────────────────────────────
                    ColumnLayout {
                        visible: page.selectedKind === "table" || page.selectedKind === "sqlite"
                        Layout.fillWidth: true
                        spacing: Theme.dp(6)

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: Theme.dp(140)
                            radius: Theme.rad(10)
                            color: Theme.mLowest
                            clip: true

                            Flickable {
                                anchors.fill: parent
                                anchors.margins: Theme.dp(8)
                                contentWidth: width
                                contentHeight: tablePreviewCol.implicitHeight
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds

                                ColumnLayout {
                                    id: tablePreviewCol
                                    width: parent.width
                                    spacing: Theme.dp(4)

                                    LText {
                                        visible: Boolean(page.inspectData && page.inspectData.tables && page.inspectData.tables.length > 0)
                                        Layout.fillWidth: true
                                        role: "labelSmall"
                                        color: Theme.primary
                                        wrapMode: Text.WordWrap
                                        text: "Таблицы: " + (page.inspectData && Array.isArray(page.inspectData.tables)
                                            ? page.inspectData.tables.join(", ") : "")
                                    }

                                    LText {
                                        Layout.fillWidth: true
                                        mono: true
                                        role: "labelSmall"
                                        color: Theme.text
                                        wrapMode: Text.WrapAnywhere
                                        text: {
                                            if (!page.inspectData)
                                                return page.inspectLoading ? "Чтение таблицы…" : "";
                                            const cols = page.inspectData.columns
                                                || page.inspectData.headers
                                                || (page.inspectData.table_preview && page.inspectData.table_preview.columns)
                                                || [];
                                            const rows = page.inspectData.rows
                                                || page.inspectData.sample_rows
                                                || (page.inspectData.table_preview && page.inspectData.table_preview.rows)
                                                || [];
                                            const lines = [];
                                            if (Array.isArray(cols) && cols.length > 0)
                                                lines.push(cols.join(" | "));
                                            if (Array.isArray(rows)) {
                                                for (const r of rows.slice(0, 6))
                                                    lines.push(Array.isArray(r) ? r.join(" | ") : JSON.stringify(r));
                                            }
                                            if (lines.length === 0 && page.inspectData.text_preview)
                                                return String(page.inspectData.text_preview);
                                            return lines.length > 0 ? lines.join("\n") : "Таблица данных";
                                        }
                                    }
                                }
                            }
                        }

                        Button {
                            Layout.fillWidth: true
                            size: "xs"
                            variant: "filled"
                            icon: "grid_view"
                            text: "Открыть таблицу"
                            onClicked: if (win && win.shell) win.shell.openMedia(page.selectedPath)
                        }
                    }

                    // ── ПРЕВЬЮ: FONT ──────────────────────────────────────
                    ColumnLayout {
                        visible: page.selectedKind === "font"
                        Layout.fillWidth: true
                        spacing: Theme.dp(6)

                        Rectangle {
                            Layout.fillWidth: true
                            radius: Theme.rad(12)
                            color: Theme.mLowest
                            implicitHeight: fontSampleCol.implicitHeight + Theme.dp(16)

                            ColumnLayout {
                                id: fontSampleCol
                                anchors.fill: parent
                                anchors.margins: Theme.dp(8)
                                spacing: Theme.dp(4)

                                Text {
                                    Layout.fillWidth: true
                                    text: "АаБбВв 123"
                                    color: Theme.text
                                    font.family: inspectorFontLoader.status === FontLoader.Ready
                                        ? inspectorFontLoader.name : Theme.fontFamily
                                    font.pixelSize: Theme.dp(24)
                                    elide: Text.ElideRight
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: "Съешь же ещё этих мягких французских булок · ABC xyz 0123456789"
                                    color: Theme.subtext
                                    font.family: inspectorFontLoader.status === FontLoader.Ready
                                        ? inspectorFontLoader.name : Theme.fontFamily
                                    font.pixelSize: Theme.dp(12)
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.dp(6)

                            Button {
                                Layout.fillWidth: true
                                size: "xs"
                                variant: "tonal"
                                icon: "download"
                                text: "Установить шрифт"
                                onClicked: page.installFont(page.selectedPath)
                            }
                            Button {
                                Layout.fillWidth: true
                                size: "xs"
                                variant: "filled"
                                icon: "text_fields"
                                text: "Подробнее"
                                onClicked: if (win && win.shell) win.shell.openMedia(page.selectedPath)
                            }
                        }
                    }

                    // ── ПРЕВЬЮ: ПАПКА ─────────────────────────────────────
                    ColumnLayout {
                        visible: page.selectedKind === "dir"
                        Layout.fillWidth: true
                        spacing: Theme.dp(6)

                        Button {
                            Layout.fillWidth: true
                            size: "xs"
                            variant: "filled"
                            icon: "folder_open"
                            text: "Открыть папку"
                            onClicked: if (page.selectedEntry) page.navigateTo(page.selectedEntry.path)
                        }
                    }

                    // ── БЫСТРЫЕ ДЕЙСТВИЯ В ПОДВАЛЕ ИНСПЕКТОРА ────────────
                    Rectangle {
                        Layout.fillWidth: true
                        height: 1
                        color: Theme.divider
                    }

                    LText {
                        Layout.fillWidth: true
                        text: "Быстрые действия"
                        role: "labelSmall"
                        color: Theme.subtext
                    }

                    Button {
                        visible: page.selectedEntry !== null && !page.selectedEntry.dir
                        Layout.fillWidth: true
                        size: "xs"
                        variant: "tonal"
                        icon: "open_in_new"
                        text: "Открыть в Студии"
                        onClicked: if (win && win.shell) win.shell.openMedia(page.selectedPath)
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.dp(6)

                        Button {
                            Layout.fillWidth: true
                            size: "xs"
                            variant: "text"
                            icon: "content_copy"
                            text: "Копировать"
                            onClicked: page.copyEntry(page.selectedEntry)
                        }
                        Button {
                            Layout.fillWidth: true
                            size: "xs"
                            variant: "text"
                            icon: "swap_horiz"
                            text: "Вырезать"
                            onClicked: page.cutEntry(page.selectedEntry)
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.dp(6)

                        Button {
                            Layout.fillWidth: true
                            size: "xs"
                            variant: "text"
                            icon: "edit"
                            text: "Переименовать"
                            onClicked: page.beginRename()
                        }
                        Button {
                            Layout.fillWidth: true
                            size: "xs"
                            variant: "text"
                            danger: true
                            icon: "delete"
                            text: "В корзину"
                            disabled: actionProc.running
                            onClicked: if (page.selectedEntry) page.runAction("trash", [page.selectedEntry.path])
                        }
                    }
                }
            }
        }
    }

    // ── НИЖНЯЯ СТРОКА СТАТУСА И КОРЗИНЫ ─────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.dp(8)
        LText {
            Layout.fillWidth: true
            text: page.statusText !== "" ? page.statusText
                : (page.loading ? "Загрузка…" : page.entries.length + " элементов"
                    + (page.filterText !== "" ? " (фильтр)" : ""))
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
