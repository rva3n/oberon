pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtMultimedia
import Quickshell
import Quickshell.Io
import "../../core"
import "../../ui"
import ".."

ColumnLayout {
    id: page

    property var win: null
    property real sourceWidth: 0
    property real sourceHeight: 0
    property real sourceDuration: 0
    property real sourceSize: 0
    property real sourceFps: 0
    property string sourceCodec: ""
    property string errorText: ""
    property string savedPath: ""
    property string busyText: ""
    property string probeTargetPath: ""
    property string probeOutput: ""
    property string probeError: ""
    property string operationOutput: ""
    property string operationError: ""
    property string operationPath: ""
    property real trimStart: 0
    property real trimEnd: 0
    property bool trimCustomized: false
    property string cropWidthText: "0"
    property string cropHeightText: "0"
    property string cropXText: "0"
    property string cropYText: "0"

    // Universal Studio inspection & interactive state
    property var inspectData: ({})
    property string inspectTargetPath: ""
    property string inspectExtraArg: ""
    property string inspectOutput: ""
    property string inspectError: ""

    property real zoomLevel: 1.0
    property real panX: 0
    property real panY: 0
    property real playbackRate: 1.0
    property bool pdfNightMode: false
    property string codeSearchQuery: ""
    property bool codeFilterLines: false
    property string ocrText: ""
    property bool ocrDrawerOpen: false
    property bool ocrBusy: false
    property string ocrOutput: ""
    property string ocrError: ""
    property real vinylAngle: 0

    readonly property string path: win && win.shell ? String(win.shell.mediaPath || "") : ""
    readonly property string filePath: page.path
    readonly property string parentDir: {
        const idx = page.path.lastIndexOf("/");
        return idx > 0 ? page.path.slice(0, idx) : "/";
    }
    readonly property string fileName: page.path.split("/").pop()
    readonly property string fileExt: {
        const name = page.fileName;
        const dot = name.lastIndexOf(".");
        return dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
    }
    readonly property string fallbackKind: page.classifyByExt(page.fileExt, page.fileName)
    readonly property string kind: (page.inspectData && page.inspectData.kind)
        ? String(page.inspectData.kind)
        : page.fallbackKind

    readonly property bool isVideo: page.kind === "video"
        || ["mp4", "mkv", "webm", "mov", "avi", "m4v", "wmv", "flv", "mpg", "mpeg", "ts"].indexOf(page.fileExt) >= 0
    readonly property bool isAudio: page.kind === "audio"
        || ["mp3", "flac", "ogg", "wav", "m4a", "aac", "opus", "wma", "aiff"].indexOf(page.fileExt) >= 0
    readonly property bool isAnimated: ["gif", "webp", "apng"].indexOf(page.fileExt) >= 0 && !page.isVideo && !page.isAudio
    readonly property bool isImage: (page.kind === "image" || page.fallbackKind === "image") && !page.isVideo && !page.isAudio
    readonly property bool isPdf: page.kind === "pdf"
    readonly property bool isTextLike: ["code", "markdown", "text"].indexOf(page.kind) >= 0
    readonly property bool isTableLike: ["table", "sqlite"].indexOf(page.kind) >= 0
    readonly property bool isArchive: page.kind === "archive"
    readonly property bool isFont: page.kind === "font"

    readonly property string scriptPath: Quickshell.env("HOME") + "/oberon/scripts/media.sh"
    readonly property string filesScriptPath: Quickshell.env("HOME") + "/oberon/scripts/files.sh"
    readonly property string cavaUid: "mediaview-audio"
    readonly property int cavaBars: 28

    readonly property real durationSeconds: player.duration > 0 ? player.duration / 1000 : page.sourceDuration
    readonly property real playbackSeconds: player.position > 0 ? player.position / 1000 : 0
    readonly property int cropWidth: page.numberOrZero(page.cropWidthText)
    readonly property int cropHeight: page.numberOrZero(page.cropHeightText)
    readonly property int cropX: page.numberOrZero(page.cropXText)
    readonly property int cropY: page.numberOrZero(page.cropYText)
    readonly property bool hasMetadata: page.sourceWidth > 0 && page.sourceHeight > 0
    readonly property bool cropValid: page.hasMetadata && page.cropWidth > 0 && page.cropHeight > 0
        && page.cropX >= 0 && page.cropY >= 0
        && page.cropX + page.cropWidth <= page.sourceWidth
        && page.cropY + page.cropHeight <= page.sourceHeight
    readonly property bool canTrim: (page.isVideo || page.isAudio) && page.durationSeconds > 0
        && page.trimEnd - page.trimStart >= 0.05

    readonly property var mediaInfo: (page.inspectData && page.inspectData.media_info && typeof page.inspectData.media_info === "object")
        ? page.inspectData.media_info
        : ({})
    readonly property string trackTitle: String(page.mediaInfo.title || page.inspectData.title || page.fileName || "Аудиозапись")
    readonly property string trackArtist: String(page.mediaInfo.artist || page.inspectData.artist || "Неизвестный исполнитель")
    readonly property string trackAlbum: String(page.mediaInfo.album || page.inspectData.album || "")
    readonly property string audioCodecText: String(page.mediaInfo.codec || page.sourceCodec || page.fileExt.toUpperCase() || "AUDIO")
    readonly property int audioSampleRate: Number(page.mediaInfo.sample_rate || page.inspectData.sample_rate || 0)
    readonly property int audioBitRate: Number(page.mediaInfo.bit_rate || page.inspectData.bit_rate || 0)
    readonly property string previewImagePath: String((page.inspectData && page.inspectData.preview_image) || "")

    readonly property var siblings: {
        const raw = (page.inspectData && Array.isArray(page.inspectData.siblings)) ? page.inspectData.siblings : [];
        const out = [];
        for (let i = 0; i < raw.length; i++) {
            const item = raw[i];
            if (typeof item === "string") {
                const name = item.split("/").pop();
                const dot = name.lastIndexOf(".");
                const ext = dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
                out.push({
                    path: item,
                    name: name,
                    kind: page.classifyByExt(ext, name),
                    size: 0
                });
            } else if (item && item.path) {
                const p = String(item.path);
                const name = String(item.name || p.split("/").pop());
                const dot = name.lastIndexOf(".");
                const ext = dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
                out.push({
                    path: p,
                    name: name,
                    kind: String(item.kind || page.classifyByExt(ext, name)),
                    size: Number(item.size) || 0
                });
            }
        }
        return out;
    }

    readonly property int siblingIndex: {
        for (let i = 0; i < page.siblings.length; i++) {
            if (page.siblings[i].path === page.path)
                return i;
        }
        return -1;
    }

    readonly property var audioSiblings: {
        const filtered = [];
        for (let i = 0; i < page.siblings.length; i++) {
            const s = page.siblings[i];
            if (s.kind === "audio")
                filtered.push(s);
        }
        return filtered.length > 0 ? filtered : page.siblings;
    }

    readonly property var imageSiblings: {
        const filtered = [];
        for (let i = 0; i < page.siblings.length; i++) {
            const s = page.siblings[i];
            if (s.kind === "image" || s.kind === "video")
                filtered.push(s);
        }
        return filtered;
    }

    readonly property int pdfPage: Math.max(1, Number((page.inspectData && page.inspectData.pdf_page) || 1))
    readonly property int pdfPages: Math.max(1, Number((page.inspectData && page.inspectData.pdf_pages) || 1))
    readonly property string textPreview: String((page.inspectData && page.inspectData.text_preview) || "")
    readonly property int totalLineCount: Number((page.inspectData && page.inspectData.line_count) || 0)

    readonly property var codeLines: {
        if (page.textPreview === "")
            return [];
        const rawLines = page.textPreview.split("\n");
        const q = page.codeSearchQuery.trim().toLowerCase();
        const result = [];
        for (let i = 0; i < rawLines.length; i++) {
            const text = rawLines[i];
            const matched = q !== "" && text.toLowerCase().indexOf(q) >= 0;
            if (page.codeFilterLines && q !== "" && !matched)
                continue;
            result.push({
                lineNumber: i + 1,
                text: text,
                matched: matched
            });
        }
        return result;
    }

    readonly property int codeMatchCount: {
        const q = page.codeSearchQuery.trim().toLowerCase();
        if (q === "" || page.textPreview === "")
            return 0;
        const rawLines = page.textPreview.split("\n");
        let count = 0;
        for (let i = 0; i < rawLines.length; i++) {
            if (rawLines[i].toLowerCase().indexOf(q) >= 0)
                count++;
        }
        return count;
    }

    readonly property var tableHeaders: (page.inspectData && Array.isArray(page.inspectData.headers))
        ? page.inspectData.headers
        : []
    readonly property var tableRows: (page.inspectData && Array.isArray(page.inspectData.rows))
        ? page.inspectData.rows
        : []
    readonly property var sqliteTables: (page.inspectData && Array.isArray(page.inspectData.tables))
        ? page.inspectData.tables
        : []
    readonly property string activeSqliteTable: String((page.inspectData && page.inspectData.active_table) || "")
    readonly property var archiveEntries: (page.inspectData && Array.isArray(page.inspectData.archive_entries))
        ? page.inspectData.archive_entries
        : []
    readonly property int archiveTotalEntries: Number((page.inspectData && page.inspectData.total_entries) || page.archiveEntries.length || 0)

    visible: win !== null && win.mode === "panel" && win.page === "media"
    focus: visible
    Layout.fillWidth: true
    spacing: Theme.pageSpacing

    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Left || event.key === Qt.Key_PageUp) {
            if (page.siblings.length > 1) {
                page.goSibling(-1);
                event.accepted = true;
            }
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_PageDown) {
            if (page.siblings.length > 1) {
                page.goSibling(1);
                event.accepted = true;
            }
        } else if (event.key === Qt.Key_Space && (page.isVideo || page.isAudio)) {
            if (player.playbackState === MediaPlayer.PlayingState)
                player.pause();
            else
                player.play();
            event.accepted = true;
        }
    }

    function classifyByExt(ext, name) {
        const e = String(ext || "").toLowerCase();
        const n = String(name || "").toLowerCase();
        if (["mp4", "mkv", "webm", "mov", "avi", "m4v", "wmv", "flv", "mpg", "mpeg", "ts"].indexOf(e) >= 0)
            return "video";
        if (["mp3", "flac", "ogg", "wav", "m4a", "aac", "opus", "wma", "aiff"].indexOf(e) >= 0)
            return "audio";
        if (["png", "jpg", "jpeg", "webp", "gif", "apng", "bmp", "svg", "ico", "tif", "tiff", "avif", "heic"].indexOf(e) >= 0)
            return "image";
        if (e === "pdf")
            return "pdf";
        if (["csv", "tsv"].indexOf(e) >= 0)
            return "table";
        if (["db", "sqlite", "sqlite3"].indexOf(e) >= 0)
            return "sqlite";
        if (["zip", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz", "zst", "7z", "rar"].indexOf(e) >= 0
            || n.endsWith(".tar.gz") || n.endsWith(".tar.xz") || n.endsWith(".tar.bz2") || n.endsWith(".tar.zst"))
            return "archive";
        if (["ttf", "otf", "woff", "woff2"].indexOf(e) >= 0)
            return "font";
        if (["md", "markdown"].indexOf(e) >= 0)
            return "markdown";
        if (["py", "sh", "bash", "zsh", "js", "ts", "jsx", "tsx", "qml", "json", "toml", "yaml", "yml",
             "ini", "conf", "cfg", "c", "cpp", "h", "hpp", "rs", "go", "java", "kt", "css", "scss",
             "html", "xml", "sql", "lua", "rb", "php"].indexOf(e) >= 0
            || n === "dockerfile" || n === "makefile")
            return "code";
        return "text";
    }

    function kindLabel(k) {
        switch (String(k || "")) {
        case "video": return "Видео";
        case "audio": return "Аудио";
        case "image": return "Изображение";
        case "pdf": return "PDF-документ";
        case "code": return "Код";
        case "markdown": return "Markdown";
        case "text": return "Текст / Лог";
        case "table": return "Таблица";
        case "sqlite": return "База SQLite";
        case "archive": return "Архив";
        case "font": return "Шрифт";
        default: return "Файл";
        }
    }

    function kindIcon(k) {
        switch (String(k || "")) {
        case "video": return "movie";
        case "audio": return "music_note";
        case "image": return "image";
        case "pdf": return "picture_as_pdf";
        case "code": return "code";
        case "markdown": return "article";
        case "text": return "description";
        case "table": return "table_chart";
        case "sqlite": return "storage";
        case "archive": return "folder_zip";
        case "font": return "font_download";
        default: return "insert_drive_file";
        }
    }

    function numberOrZero(value) {
        const result = parseInt(String(value), 10);
        return isFinite(result) ? Math.max(0, result) : 0;
    }

    function localFileUrl(value) {
        return "file://" + String(value || "").split("/").map(part => encodeURIComponent(part)).join("/");
    }

    function formatTime(seconds) {
        const total = Math.max(0, Math.floor(Number(seconds) || 0));
        const hours = Math.floor(total / 3600);
        const minutes = Math.floor(total / 60) % 60;
        const secs = total % 60;
        const mm = (minutes < 10 ? "0" : "") + minutes;
        const ss = (secs < 10 ? "0" : "") + secs;
        return hours > 0 ? hours + ":" + mm + ":" + ss : mm + ":" + ss;
    }

    function formatBytes(bytes) {
        let size = Math.max(0, Number(bytes) || 0);
        if (size < 1024) return size + " Б";
        const units = ["КиБ", "МиБ", "ГиБ"];
        let unit = -1;
        do {
            size /= 1024;
            unit++;
        } while (size >= 1024 && unit < units.length - 1);
        return size.toFixed(1) + " " + units[unit];
    }

    function outputPath(suffix) {
        const source = page.path;
        const slash = source.lastIndexOf("/");
        const dot = source.lastIndexOf(".");
        const base = dot > slash ? source.slice(0, dot) : source;
        const ext = dot > slash ? source.slice(dot) : "";
        return base + "-" + suffix + ext;
    }

    function outputPathWithExt(suffix, newExt) {
        const source = page.path;
        const slash = source.lastIndexOf("/");
        const dot = source.lastIndexOf(".");
        const base = dot > slash ? source.slice(0, dot) : source;
        const ext = String(newExt || "").indexOf(".") === 0 ? String(newExt) : "." + String(newExt || "");
        return base + (suffix ? "-" + suffix : "") + ext;
    }

    function openFileInStudio(targetPath) {
        const next = String(targetPath || "").trim();
        if (next === "" || !win || !win.shell)
            return;
        win.shell.openMedia(next);
    }

    function openInExplorer() {
        if (!win || !win.shell)
            return;
        if (typeof win.shell.openFiles === "function")
            win.shell.openFiles(page.parentDir);
        else if (typeof win.shell.setPage === "function")
            win.shell.setPage("files");
    }

    function goSibling(delta) {
        const list = page.siblings;
        if (list.length <= 1)
            return;
        const cur = page.siblingIndex >= 0 ? page.siblingIndex : 0;
        const nextIdx = (cur + delta + list.length) % list.length;
        if (list[nextIdx] && list[nextIdx].path)
            page.openFileInStudio(list[nextIdx].path);
    }

    function goNextAudioTrack(delta) {
        const list = page.audioSiblings;
        if (list.length <= 1)
            return;
        let cur = -1;
        for (let i = 0; i < list.length; i++) {
            if (list[i].path === page.path) {
                cur = i;
                break;
            }
        }
        const step = delta === undefined ? 1 : delta;
        const nextIdx = ((cur >= 0 ? cur : 0) + step + list.length) % list.length;
        if (list[nextIdx] && list[nextIdx].path)
            page.openFileInStudio(list[nextIdx].path);
    }

    function syncCava() {
        if (page.visible && page.isAudio)
            Cava.want(page.cavaUid, page.cavaBars);
        else
            Cava.drop(page.cavaUid);
    }

    function resetZoom() {
        page.zoomLevel = 1.0;
        page.panX = 0;
        page.panY = 0;
    }

    function adjustZoom(factor) {
        const next = Math.max(0.25, Math.min(8.0, Math.round(page.zoomLevel * factor * 100) / 100));
        page.zoomLevel = next;
        if (next <= 1.0) {
            page.panX = 0;
            page.panY = 0;
        }
    }

    function startProbe(target) {
        if (target === "" || target !== page.path) return;
        const k = page.classifyByExt(page.fileExt, page.fileName);
        if (k !== "video" && k !== "image" && k !== "audio")
            return;
        page.probeTargetPath = target;
        page.probeOutput = "";
        page.probeError = "";
        probeProc.command = ["bash", page.scriptPath, "probe", target];
        probeProc.running = true;
    }

    function startInspect(target, extraArg) {
        if (target === "" || target !== page.path) return;
        page.inspectTargetPath = target;
        page.inspectExtraArg = extraArg !== undefined && extraArg !== null ? String(extraArg) : "";
        page.inspectOutput = "";
        page.inspectError = "";
        const cmd = ["bash", page.filesScriptPath, "inspect", target];
        if (page.inspectExtraArg !== "")
            cmd.push(page.inspectExtraArg);
        inspectProc.command = cmd;
        inspectProc.running = true;
    }

    function loadPath() {
        const target = page.path.trim();
        player.stop();
        page.sourceWidth = 0;
        page.sourceHeight = 0;
        page.sourceDuration = 0;
        page.sourceSize = 0;
        page.sourceFps = 0;
        page.sourceCodec = "";
        page.errorText = "";
        page.savedPath = "";
        page.busyText = "";
        page.trimStart = 0;
        page.trimEnd = 0;
        page.trimCustomized = false;
        page.cropWidthText = "0";
        page.cropHeightText = "0";
        page.cropXText = "0";
        page.cropYText = "0";
        page.inspectData = ({});
        page.zoomLevel = 1.0;
        page.panX = 0;
        page.panY = 0;
        page.codeSearchQuery = "";
        page.ocrText = "";
        page.ocrDrawerOpen = false;
        page.ocrBusy = false;

        if (probeProc.running)
            probeProc.running = false;
        if (inspectProc.running)
            inspectProc.running = false;

        if (target !== "") {
            Qt.callLater(() => {
                page.startInspect(target, "");
                page.startProbe(target);
                page.syncCava();
            });
        } else {
            page.syncCava();
        }
    }

    function finishInspect(exitCode) {
        if (page.inspectTargetPath !== page.path)
            return;
        if (exitCode !== 0) {
            return;
        }
        try {
            const data = JSON.parse(page.inspectOutput.trim());
            page.inspectData = data || ({});
            if (Number(data.size) > 0 && page.sourceSize <= 0)
                page.sourceSize = Number(data.size);
            const mi = (data.media_info && typeof data.media_info === "object") ? data.media_info : data;
            if (Number(mi.duration) > 0 && page.sourceDuration <= 0) {
                page.sourceDuration = Number(mi.duration);
                if (!page.trimCustomized) {
                    page.trimStart = 0;
                    page.trimEnd = page.sourceDuration;
                }
            }
            if (Number(mi.width) > 0 && Number(mi.height) > 0 && page.sourceWidth <= 0) {
                page.sourceWidth = Math.floor(Number(mi.width));
                page.sourceHeight = Math.floor(Number(mi.height));
                page.cropWidthText = String(page.sourceWidth);
                page.cropHeightText = String(page.sourceHeight);
            }
            if (mi.codec && page.sourceCodec === "")
                page.sourceCodec = String(mi.codec);
            if (Number(mi.fps) > 0 && page.sourceFps <= 0)
                page.sourceFps = Number(mi.fps);
            page.syncCava();
        } catch (e) {
        }
    }

    function finishProbe(exitCode) {
        if (page.probeTargetPath !== page.path) return;
        if (exitCode !== 0) {
            if (page.isVideo || page.isImage)
                page.errorText = page.probeError.trim() || "Не удалось прочитать файл.";
            return;
        }
        try {
            const data = JSON.parse(page.probeOutput.trim());
            const width = Math.floor(Number(data.width) || 0);
            const height = Math.floor(Number(data.height) || 0);
            if (width > 0 && height > 0) {
                page.sourceWidth = width;
                page.sourceHeight = height;
                page.cropWidthText = String(width);
                page.cropHeightText = String(height);
                page.cropXText = "0";
                page.cropYText = "0";
            } else if (!page.isAudio) {
                throw new Error("empty dimensions");
            }
            page.sourceDuration = Math.max(0, Number(data.duration) || page.sourceDuration || 0);
            page.sourceSize = Math.max(0, Number(data.size) || page.sourceSize || 0);
            page.sourceFps = Math.max(0, Number(data.fps) || page.sourceFps || 0);
            page.sourceCodec = String(data.codec || page.sourceCodec || "Неизвестно");
            if (!page.trimCustomized && page.sourceDuration > 0) {
                page.trimStart = 0;
                page.trimEnd = page.sourceDuration;
            }
            page.errorText = "";
        } catch (e) {
            if (!page.isAudio)
                page.errorText = "Не удалось разобрать сведения о файле.";
        }
    }

    function seek(seconds) {
        const duration = page.durationSeconds;
        player.position = Math.round(Math.max(0, Math.min(duration, Number(seconds) || 0)) * 1000);
    }

    function setTrimStart(seconds) {
        const maxStart = Math.max(0, page.trimEnd - 0.05);
        page.trimStart = Math.max(0, Math.min(maxStart, Number(seconds) || 0));
        page.trimCustomized = true;
    }

    function setTrimEnd(seconds) {
        const duration = page.durationSeconds;
        if (duration <= 0) return;
        const gap = Math.min(0.05, duration / 2);
        const minEnd = Math.min(duration, page.trimStart + gap);
        page.trimEnd = Math.max(minEnd, Math.min(duration, Number(seconds) || 0));
        page.trimCustomized = true;
    }

    function runOperation(args, message) {
        if (editProc.running || page.path === "") return;
        page.errorText = "";
        page.savedPath = "";
        page.busyText = message;
        page.operationOutput = "";
        page.operationError = "";
        page.operationPath = page.path;
        editProc.command = ["bash", page.scriptPath].concat(args);
        editProc.running = true;
    }

    function runFilesOperation(args, message) {
        if (editProc.running || page.path === "") return;
        page.errorText = "";
        page.savedPath = "";
        page.busyText = message;
        page.operationOutput = "";
        page.operationError = "";
        page.operationPath = page.path;
        editProc.command = ["bash", page.filesScriptPath].concat(args);
        editProc.running = true;
    }

    function saveTrim() {
        if (!page.canTrim) return;
        page.runOperation(
            ["cut", page.path, page.trimStart.toFixed(3), page.trimEnd.toFixed(3), page.outputPath("trim")],
            page.isAudio ? "Обрезаю аудио…" : "Обрезаю видео…"
        );
    }

    function saveCrop() {
        if (!page.cropValid) return;
        const rect = page.cropWidth + ":" + page.cropHeight + ":" + page.cropX + ":" + page.cropY;
        page.runOperation(["crop", rect, page.path, page.outputPath("crop")], "Обрезаю кадр…");
    }

    function saveVideoFrame() {
        if (!page.isVideo || page.path === "") return;
        const outPng = page.outputPathWithExt("frame-" + Math.floor(page.playbackSeconds) + "s", ".png");
        page.runOperation(["frame", page.path, page.playbackSeconds.toFixed(3), outPng], "Сохраняю стоп-кадр в PNG…");
    }

    function rotateMedia90() {
        if (page.path === "") return;
        page.runOperation(["rotate", page.path, "90", page.outputPath("rot90")], "Поворачиваю на 90°…");
    }

    function convertImageTo(ext) {
        if (page.path === "") return;
        const out = page.outputPathWithExt("converted", "." + ext);
        page.runOperation(["convert", page.path, out], "Конвертирую в ." + ext + "…");
    }

    function runImageOcr() {
        if (ocrProc.running || page.path === "") return;
        page.ocrBusy = true;
        page.ocrOutput = "";
        page.ocrError = "";
        page.errorText = "";
        ocrProc.command = ["bash", page.scriptPath, "ocr", page.path];
        ocrProc.running = true;
    }

    function extractArchive() {
        if (page.path === "") return;
        page.runFilesOperation(["extract", page.path], "Распаковываю архив…");
    }

    function installFont() {
        if (page.path === "") return;
        page.runFilesOperation(["install-font", page.path], "Устанавливаю шрифт в систему…");
    }

    function copyToClipboard(text) {
        const val = String(text || "");
        if (val === "") return;
        Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" | wl-copy 2>/dev/null || true", "oberon-copy", val]);
    }

    function openInSystem() {
        if (page.path === "") return;
        Quickshell.execDetached(["xdg-open", page.path]);
    }

    function finishOperation(exitCode) {
        page.busyText = "";
        if (exitCode !== 0) {
            page.errorText = page.operationError.trim() || page.operationOutput.trim()
                || "Не удалось обработать файл.";
            return;
        }
        const lines = page.operationOutput.trim().split("\n").filter(line => line.trim() !== "");
        if (lines.length > 0) {
            const last = lines[lines.length - 1].trim();
            try {
                const parsed = JSON.parse(last);
                page.savedPath = String(parsed.output || parsed.path || parsed.dest || last);
            } catch (e) {
                page.savedPath = last;
            }
        } else {
            page.savedPath = "Готово";
        }
    }

    onPathChanged: page.loadPath()
    onVisibleChanged: {
        page.syncCava();
        if (!visible) player.pause();
        else if ((page.isVideo || page.isAudio) && player.mediaStatus === MediaPlayer.LoadedMedia) player.play();
    }
    Component.onCompleted: if (page.path !== "") page.loadPath()
    Component.onDestruction: Cava.drop(page.cavaUid)

    Process {
        id: probeProc
        stdout: SplitParser { onRead: line => page.probeOutput += line + "\n" }
        stderr: SplitParser { onRead: line => page.probeError += line + "\n" }
        onExited: (exitCode) => page.finishProbe(exitCode)
    }

    Process {
        id: inspectProc
        stdout: SplitParser { onRead: line => page.inspectOutput += line + "\n" }
        stderr: SplitParser { onRead: line => page.inspectError += line + "\n" }
        onExited: (exitCode) => page.finishInspect(exitCode)
    }

    Process {
        id: editProc
        stdout: SplitParser { onRead: line => page.operationOutput += line + "\n" }
        stderr: SplitParser { onRead: line => page.operationError += line + "\n" }
        onExited: (exitCode) => page.finishOperation(exitCode)
    }

    Process {
        id: ocrProc
        stdout: SplitParser { onRead: line => page.ocrOutput += line + "\n" }
        stderr: SplitParser { onRead: line => page.ocrError += line + "\n" }
        onExited: (exitCode) => {
            page.ocrBusy = false;
            if (exitCode !== 0) {
                page.errorText = page.ocrError.trim() || "Не удалось распознать текст (OCR).";
                return;
            }
            const recognized = page.ocrOutput.trim();
            page.ocrText = recognized !== "" ? recognized : "(Текст на изображении не обнаружен)";
            page.ocrDrawerOpen = true;
            if (recognized !== "")
                page.copyToClipboard(recognized);
        }
    }

    FontLoader {
        id: dynamicFontLoader
        source: page.isFont && page.filePath !== "" ? "file://" + page.filePath : ""
    }

    Timer {
        id: vinylSpinTimer
        interval: 33
        repeat: true
        running: page.visible && page.isAudio && player.playbackState === MediaPlayer.PlayingState
        onTriggered: page.vinylAngle = (page.vinylAngle + 1.8) % 360
    }

    MediaPlayer {
        id: player
        source: (page.isVideo || page.isAudio) && page.path !== "" ? page.localFileUrl(page.path) : ""
        videoOutput: videoOutput
        audioOutput: AudioOutput { volume: 0.85 }
        playbackRate: page.playbackRate
        onDurationChanged: {
            if (duration > 0 && !page.trimCustomized) {
                page.trimStart = 0;
                page.trimEnd = duration / 1000;
            }
        }
        onMediaStatusChanged: {
            if ((mediaStatus === MediaPlayer.LoadedMedia || mediaStatus === MediaPlayer.BufferedMedia) && page.visible) {
                play();
            } else if (mediaStatus === MediaPlayer.EndOfMedia && page.isAudio) {
                if (page.audioSiblings.length > 1)
                    Qt.callLater(() => page.goNextAudioTrack(1));
            } else if (mediaStatus === MediaPlayer.InvalidMedia) {
                page.errorText = errorString || (page.isAudio ? "Не удалось открыть аудиофайл." : "Не удалось открыть видео.");
            }
        }
        onErrorOccurred: (error, errorString) => {
            if (errorString !== "") page.errorText = errorString;
        }
    }

    // ── Empty State ────────────────────────────────────────────────────────
    Card {
        Layout.fillWidth: true
        visible: page.path === ""

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            Icon {
                Layout.alignment: Qt.AlignHCenter
                name: "perm_media"
                size: Theme.dp(32)
                color: Theme.subtext
            }
            LText {
                Layout.fillWidth: true
                role: "titleMedium"
                color: Theme.text
                horizontalAlignment: Text.AlignHCenter
                text: "Нет файла"
            }
            LText {
                Layout.fillWidth: true
                role: "bodySmall"
                color: Theme.subtext
                horizontalAlignment: Text.AlignHCenter
                text: "Откройте медиафайл, документ, таблицу, архив или шрифт через Проводник или IPC: oberon media <путь>"
                wrapMode: Text.WordWrap
            }
        }
    }

    // ── Universal Studio Top Navigation Bar ────────────────────────────────
    Card {
        Layout.fillWidth: true
        visible: page.path !== ""
        pad: Theme.dp(10)

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            Button {
                size: "xs"
                variant: "tonal"
                icon: "folder_open"
                text: "← В проводник"
                onClicked: page.openInExplorer()
            }

            Chip {
                size: "sm"
                kind: "assist"
                interactive: false
                icon: page.kindIcon(page.kind)
                label: page.kindLabel(page.kind)
                selected: true
            }

            LText {
                Layout.fillWidth: true
                role: "titleSmall"
                color: Theme.text
                text: page.fileName
                elide: Text.ElideMiddle
            }

            LText {
                visible: page.siblings.length > 1 && page.siblingIndex >= 0
                role: "labelSmall"
                color: Theme.subtext
                tabular: true
                text: (page.siblingIndex + 1) + " / " + page.siblings.length
            }

            Button {
                visible: page.siblings.length > 1
                size: "xs"
                variant: "outlined"
                text: "‹ Пред."
                onClicked: page.goSibling(-1)
            }

            Button {
                visible: page.siblings.length > 1
                size: "xs"
                variant: "outlined"
                text: "След. ›"
                onClicked: page.goSibling(1)
            }

            IconButton {
                size: "xs"
                variant: "standard"
                icon: "open_in_new"
                tooltip: "Открыть в системе"
                onClicked: page.openInSystem()
            }
        }

        LText {
            Layout.fillWidth: true
            visible: page.busyText !== ""
            role: "bodySmall"
            color: Theme.primary
            text: page.busyText
        }
        RowLayout {
            Layout.fillWidth: true
            visible: page.savedPath !== ""
            spacing: Theme.dp(8)

            LText {
                Layout.fillWidth: true
                role: "bodySmall"
                color: Theme.success
                text: "Сохранено: " + page.savedPath
                wrapMode: Text.WrapAnywhere
            }
            Button {
                visible: page.savedPath.indexOf("/") === 0
                size: "xs"
                variant: "tonal"
                icon: "visibility"
                text: "Открыть результат"
                onClicked: page.openFileInStudio(page.savedPath)
            }
        }
        LText {
            Layout.fillWidth: true
            visible: page.errorText !== ""
            role: "bodySmall"
            color: Theme.error
            text: page.errorText
            wrapMode: Text.WrapAnywhere
        }
    }

    // ── MODE 1: Audio Player & Studio (kind === "audio") ──────────────────
    Card {
        id: audioStageCard
        Layout.fillWidth: true
        visible: page.path !== "" && page.isAudio
        title: "Аудиостудия и спектр"

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(14)

            // Left / Center: Rotating Vinyl + Metadata + Live Cava Visualizer
            ColumnLayout {
                Layout.fillWidth: true
                Layout.preferredWidth: Theme.dp(320)
                spacing: Theme.dp(12)

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(14)

                    // Vinyl / Cover Art Disc
                    Item {
                        Layout.preferredWidth: Theme.dp(108)
                        Layout.preferredHeight: Theme.dp(108)

                        MaterialShape {
                            anchors.fill: parent
                            shape: "cookie12"
                            color: Theme.secondaryContainer
                            spin: page.vinylAngle
                        }

                        Rectangle {
                            anchors.centerIn: parent
                            width: Theme.dp(84)
                            height: Theme.dp(84)
                            radius: width / 2
                            color: Theme.mLowest
                            border.width: Theme.dp(2)
                            border.color: Theme.primary
                            clip: true

                            Image {
                                anchors.fill: parent
                                visible: page.previewImagePath !== ""
                                source: visible ? page.localFileUrl(page.previewImagePath) : ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                rotation: page.vinylAngle
                            }

                            Icon {
                                anchors.centerIn: parent
                                visible: page.previewImagePath === ""
                                name: "album"
                                size: Theme.dp(40)
                                color: Theme.primary
                                rotation: page.vinylAngle
                            }

                            Rectangle {
                                anchors.centerIn: parent
                                width: Theme.dp(16)
                                height: Theme.dp(16)
                                radius: width / 2
                                color: Theme.mHigh
                                border.width: Theme.dp(2)
                                border.color: Theme.outline
                            }
                        }
                    }

                    // Track Metadata & Audio Format Badges
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.dp(4)

                        LText {
                            Layout.fillWidth: true
                            role: "titleMedium"
                            color: Theme.text
                            text: page.trackTitle
                            elide: Text.ElideRight
                        }

                        LText {
                            Layout.fillWidth: true
                            role: "bodyMedium"
                            color: Theme.primary
                            text: page.trackArtist
                            elide: Text.ElideRight
                        }

                        LText {
                            Layout.fillWidth: true
                            visible: page.trackAlbum !== ""
                            role: "bodySmall"
                            color: Theme.subtext
                            text: page.trackAlbum
                            elide: Text.ElideRight
                        }

                        Flow {
                            Layout.fillWidth: true
                            Layout.topMargin: Theme.dp(4)
                            spacing: Theme.dp(6)

                            Chip {
                                size: "sm"
                                kind: "assist"
                                interactive: false
                                icon: "graphic_eq"
                                label: page.audioCodecText.toUpperCase()
                            }

                            Chip {
                                visible: page.audioSampleRate > 0
                                size: "sm"
                                kind: "assist"
                                interactive: false
                                label: page.audioSampleRate + " Hz"
                            }

                            Chip {
                                visible: page.audioBitRate > 0
                                size: "sm"
                                kind: "assist"
                                interactive: false
                                label: Math.round(page.audioBitRate / 1000 > 1 ? page.audioBitRate / 1000 : page.audioBitRate) + " kbps"
                            }
                        }
                    }
                }

                // Live Cava Audio Spectrum Visualizer
                Rectangle {
                    id: audioCavaBox
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.dp(68)
                    radius: Theme.rad(14)
                    color: Theme.mLowest
                    clip: true

                    Row {
                        id: cavaRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: Theme.dp(10)
                        height: parent.height - Theme.dp(20)
                        spacing: Theme.dp(3)

                        readonly property real barW: Math.max(Theme.dp(3), (cavaRow.width - (page.cavaBars - 1) * Theme.dp(3)) / page.cavaBars)

                        Repeater {
                            model: page.cavaBars

                            Rectangle {
                                required property int index

                                readonly property var cavaArr: Cava.values !== undefined ? Cava.values : Cava.levels
                                readonly property real rawLevel: (cavaArr && cavaArr[index] !== undefined) ? Number(cavaArr[index]) : 0
                                readonly property real level: player.playbackState === MediaPlayer.PlayingState
                                    ? Math.max(0.08, Math.min(1, rawLevel > 1 ? rawLevel / 100 : rawLevel))
                                    : 0.08

                                width: cavaRow.barW
                                height: Math.max(Theme.dp(5), level * cavaRow.height)
                                anchors.bottom: parent.bottom
                                radius: width / 2
                                color: level > 0.55 ? Theme.primary : (level > 0.25 ? Theme.secondary : Theme.secondaryContainer)

                                Behavior on height {
                                    NumberAnimation {
                                        duration: Theme.ms(65)
                                        easing.type: Easing.OutCubic
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Right: Folder Audio Playlist (when siblings.length > 1)
            Rectangle {
                visible: page.audioSiblings.length > 1
                Layout.preferredWidth: Theme.dp(220)
                Layout.fillHeight: true
                Layout.minimumHeight: Theme.dp(190)
                radius: Theme.rad(14)
                color: Theme.mLow
                clip: true

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Theme.dp(8)
                    spacing: Theme.dp(6)

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.dp(6)

                        Icon {
                            name: "queue_music"
                            size: Theme.dp(16)
                            color: Theme.primary
                        }
                        LText {
                            Layout.fillWidth: true
                            role: "labelMedium"
                            color: Theme.subtext
                            text: "Плейлист папки (" + page.audioSiblings.length + ")"
                            elide: Text.ElideRight
                        }
                    }

                    Flickable {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        contentWidth: width
                        contentHeight: playlistCol.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        ColumnLayout {
                            id: playlistCol
                            width: parent.width
                            spacing: Theme.dp(3)

                            Repeater {
                                model: page.audioSiblings

                                Rectangle {
                                    id: trackRow
                                    required property var modelData
                                    required property int index

                                    readonly property bool isCurrent: trackRow.modelData.path === page.path

                                    Layout.fillWidth: true
                                    implicitHeight: Theme.dp(30)
                                    radius: Theme.rad(8)
                                    color: trackRow.isCurrent ? Theme.secondaryContainer
                                        : (trackMouse.containsMouse ? Theme.mHighest : "transparent")

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: Theme.dp(8)
                                        anchors.rightMargin: Theme.dp(8)
                                        spacing: Theme.dp(6)

                                        Icon {
                                            name: trackRow.isCurrent
                                                ? (player.playbackState === MediaPlayer.PlayingState ? "equalizer" : "play_arrow")
                                                : "music_note"
                                            size: Theme.dp(15)
                                            color: trackRow.isCurrent ? Theme.fgSecondaryContainer : Theme.subtext
                                        }

                                        LText {
                                            Layout.fillWidth: true
                                            role: "labelMedium"
                                            color: trackRow.isCurrent ? Theme.fgSecondaryContainer : Theme.text
                                            text: (trackRow.index + 1) + ". " + trackRow.modelData.name
                                            elide: Text.ElideMiddle
                                        }
                                    }

                                    MouseArea {
                                        id: trackMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: page.openFileInStudio(trackRow.modelData.path)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ── MODE 2 & 3: Visual Stage for Video & Image (kind in ["video", "image"]) ──
    Card {
        id: previewCard
        Layout.fillWidth: true
        visible: page.path !== "" && (page.isVideo || page.isImage || page.isAnimated)
        title: page.fileName !== "" ? page.fileName : "Просмотр файла"

        Rectangle {
            id: stage
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.dp(340)
            radius: Theme.shapeLgInc
            color: "#000000"
            clip: true

            Item {
                id: zoomContainer
                width: stage.width
                height: stage.height
                x: (page.isImage || page.isAnimated) ? page.panX : 0
                y: (page.isImage || page.isAnimated) ? page.panY : 0
                scale: (page.isImage || page.isAnimated) ? page.zoomLevel : 1.0
                transformOrigin: Item.Center

                Behavior on scale {
                    NumberAnimation {
                        duration: Theme.durQuick
                        easing.type: Easing.OutCubic
                    }
                }

                Image {
                    id: stillImage
                    anchors.fill: parent
                    visible: page.path !== "" && !page.isVideo && !page.isAudio && !page.isAnimated && page.isImage
                    source: visible ? page.localFileUrl(page.path) : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    cache: false
                    smooth: true
                    sourceSize: Qt.size(Math.max(1, stage.width * 2), Math.max(1, stage.height * 2))
                    onStatusChanged: if (status === Image.Error) page.errorText = "Не удалось загрузить изображение."
                }

                AnimatedImage {
                    id: animatedImage
                    anchors.fill: parent
                    visible: page.path !== "" && !page.isVideo && !page.isAudio && page.isAnimated
                    source: visible ? page.localFileUrl(page.path) : ""
                    fillMode: Image.PreserveAspectFit
                    playing: visible
                    cache: false
                    sourceSize: Qt.size(Math.max(1, stage.width), Math.max(1, stage.height))
                    onStatusChanged: if (status === AnimatedImage.Error) page.errorText = "Не удалось загрузить анимацию."
                }
            }

            VideoOutput {
                id: videoOutput
                anchors.fill: parent
                visible: page.isVideo
                fillMode: VideoOutput.PreserveAspectFit
            }

            // Interactive Zoom & Pan MouseArea for Images
            MouseArea {
                id: imageZoomPanArea
                anchors.fill: parent
                visible: page.isImage || page.isAnimated
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                cursorShape: page.zoomLevel > 1.0
                    ? (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
                    : Qt.ArrowCursor

                property real lastX: 0
                property real lastY: 0

                onPressed: (mouse) => {
                    lastX = mouse.x;
                    lastY = mouse.y;
                }
                onPositionChanged: (mouse) => {
                    if (!pressed || page.zoomLevel <= 1.0)
                        return;
                    const maxPanX = (stage.width * (page.zoomLevel - 1)) / 2;
                    const maxPanY = (stage.height * (page.zoomLevel - 1)) / 2;
                    page.panX = Math.max(-maxPanX, Math.min(maxPanX, page.panX + (mouse.x - lastX)));
                    page.panY = Math.max(-maxPanY, Math.min(maxPanY, page.panY + (mouse.y - lastY)));
                    lastX = mouse.x;
                    lastY = mouse.y;
                }
                onDoubleClicked: {
                    if (Math.abs(page.zoomLevel - 1.0) > 0.01)
                        page.resetZoom();
                    else
                        page.zoomLevel = 2.0;
                }
                onWheel: (wheel) => {
                    const step = wheel.angleDelta.y > 0 ? 1.18 : (1 / 1.18);
                    page.adjustZoom(step);
                    wheel.accepted = true;
                }
            }

            // Floating Zoom Controls Overlay for Images
            Rectangle {
                visible: page.isImage || page.isAnimated
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: Theme.dp(10)
                radius: Theme.radiusPill
                color: Qt.rgba(0, 0, 0, 0.65)
                implicitWidth: zoomOverlayRow.implicitWidth + Theme.dp(12)
                implicitHeight: Theme.dp(32)
                z: 5

                RowLayout {
                    id: zoomOverlayRow
                    anchors.centerIn: parent
                    spacing: Theme.dp(4)

                    IconButton {
                        size: "xs"
                        icon: "remove"
                        onClicked: page.adjustZoom(0.8)
                    }
                    Chip {
                        size: "sm"
                        kind: "assist"
                        label: Math.round(page.zoomLevel * 100) + "% · Вписать"
                        selected: Math.abs(page.zoomLevel - 1.0) > 0.01
                        onClicked: page.resetZoom()
                    }
                    IconButton {
                        size: "xs"
                        icon: "add"
                        onClicked: page.adjustZoom(1.25)
                    }
                }
            }

            QtObject {
                id: frame
                readonly property real width: page.isVideo ? videoOutput.contentRect.width
                    : (page.isAnimated ? animatedImage.paintedWidth : stillImage.paintedWidth)
                readonly property real height: page.isVideo ? videoOutput.contentRect.height
                    : (page.isAnimated ? animatedImage.paintedHeight : stillImage.paintedHeight)
                readonly property real x: page.isVideo ? videoOutput.contentRect.x : (stage.width - width) / 2
                readonly property real y: page.isVideo ? videoOutput.contentRect.y : (stage.height - height) / 2
            }

            Item {
                id: cropOverlay
                anchors.fill: parent
                visible: page.cropValid && frame.width > 0 && frame.height > 0 && Math.abs(page.zoomLevel - 1.0) < 0.02
                readonly property real cropLeft: frame.x + page.cropX / page.sourceWidth * frame.width
                readonly property real cropTop: frame.y + page.cropY / page.sourceHeight * frame.height
                readonly property real cropWidth: page.cropWidth / page.sourceWidth * frame.width
                readonly property real cropHeight: page.cropHeight / page.sourceHeight * frame.height
                readonly property color shade: Qt.rgba(0, 0, 0, 0.55)

                Rectangle {
                    x: frame.x; y: frame.y; width: frame.width
                    height: Math.max(0, cropOverlay.cropTop - frame.y)
                    color: cropOverlay.shade
                }
                Rectangle {
                    x: frame.x; y: cropOverlay.cropTop
                    width: Math.max(0, cropOverlay.cropLeft - frame.x); height: cropOverlay.cropHeight
                    color: cropOverlay.shade
                }
                Rectangle {
                    x: cropOverlay.cropLeft + cropOverlay.cropWidth; y: cropOverlay.cropTop
                    width: Math.max(0, frame.x + frame.width - x); height: cropOverlay.cropHeight
                    color: cropOverlay.shade
                }
                Rectangle {
                    x: frame.x; y: cropOverlay.cropTop + cropOverlay.cropHeight; width: frame.width
                    height: Math.max(0, frame.y + frame.height - y)
                    color: cropOverlay.shade
                }
                Rectangle {
                    x: cropOverlay.cropLeft; y: cropOverlay.cropTop
                    width: cropOverlay.cropWidth; height: cropOverlay.cropHeight
                    color: "transparent"
                    border.width: Theme.dp(2)
                    border.color: Theme.primary
                }
            }

            LText {
                anchors.centerIn: parent
                visible: page.path !== "" && !page.hasMetadata && probeProc.running && page.errorText === ""
                role: "bodyMedium"
                color: "white"
                text: "Читаю файл…"
            }
        }

        // Folder Filmstrip for Images/Videos
        Flickable {
            visible: (page.isImage || page.isAnimated) && page.imageSiblings.length > 1
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(6)
            Layout.preferredHeight: Theme.dp(56)
            contentWidth: filmstripRow.implicitWidth
            contentHeight: height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.HorizontalFlick

            Row {
                id: filmstripRow
                height: parent.height
                spacing: Theme.dp(6)

                Repeater {
                    model: page.imageSiblings

                    Rectangle {
                        id: filmItem
                        required property var modelData
                        required property int index

                        readonly property bool activeItem: filmItem.modelData.path === page.path

                        width: Theme.dp(72)
                        height: Theme.dp(52)
                        radius: Theme.rad(8)
                        color: Theme.mLowest
                        border.width: filmItem.activeItem ? Theme.dp(2) : 1
                        border.color: filmItem.activeItem ? Theme.primary : Theme.outline
                        clip: true

                        Image {
                            anchors.fill: parent
                            anchors.margins: Theme.dp(2)
                            visible: filmItem.modelData.kind === "image"
                            source: visible ? page.localFileUrl(filmItem.modelData.path) : ""
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            sourceSize: Qt.size(128, 96)
                        }

                        Icon {
                            anchors.centerIn: parent
                            visible: filmItem.modelData.kind !== "image"
                            name: "movie"
                            size: Theme.dp(20)
                            color: Theme.subtext
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: page.openFileInStudio(filmItem.modelData.path)
                        }
                    }
                }
            }
        }
    }

    // ── Transport & Playback Controls (Video & Audio) ──────────────────────
    Card {
        Layout.fillWidth: true
        visible: (page.isVideo || page.isAudio) && page.path !== ""
        title: page.isAudio ? "Управление воспроизведением" : "Управление видео и студия"

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(6)

            IconButton {
                visible: page.siblings.length > 1
                size: "s"
                variant: "tonal"
                icon: "skip_previous"
                tooltip: "Предыдущий файл"
                onClicked: page.isAudio ? page.goNextAudioTrack(-1) : page.goSibling(-1)
            }

            Button {
                size: "s"
                variant: "filled"
                icon: player.playbackState === MediaPlayer.PlayingState ? "pause" : "play_arrow"
                text: player.playbackState === MediaPlayer.PlayingState ? "Пауза" : "Играть"
                disabled: page.errorText !== ""
                onClicked: player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play()
            }

            IconButton {
                visible: page.siblings.length > 1
                size: "s"
                variant: "tonal"
                icon: "skip_next"
                tooltip: "Следующий файл"
                onClicked: page.isAudio ? page.goNextAudioTrack(1) : page.goSibling(1)
            }

            Button {
                size: "xs"
                variant: "text"
                text: "−5 с"
                disabled: page.durationSeconds <= 0
                onClicked: page.seek(page.playbackSeconds - 5)
            }

            Slider {
                Layout.fillWidth: true
                from: 0
                to: Math.max(0, page.durationSeconds)
                value: page.playbackSeconds
                stepSize: 0.1
                showValue: false
                disabled: page.durationSeconds <= 0
                onMoved: value => page.seek(value)
            }

            Button {
                size: "xs"
                variant: "text"
                text: "+5 с"
                disabled: page.durationSeconds <= 0
                onClicked: page.seek(page.playbackSeconds + 5)
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            // Playback Rate Selector Chips
            LText {
                role: "labelSmall"
                color: Theme.subtext
                text: "Скорость:"
            }

            Repeater {
                model: [0.5, 1.0, 1.25, 1.5, 2.0]

                Chip {
                    required property var modelData
                    size: "sm"
                    kind: "filter"
                    label: modelData + "×"
                    selected: Math.abs(page.playbackRate - Number(modelData)) < 0.01
                    onClicked: page.playbackRate = Number(modelData)
                }
            }

            Item { Layout.fillWidth: true }

            LText {
                role: "labelMedium"
                color: Theme.subtext
                tabular: true
                text: page.formatTime(page.playbackSeconds) + " / " + page.formatTime(page.durationSeconds)
            }
        }

        // Video Studio Quick Actions (Frame Capture & Rotate 90°)
        RowLayout {
            visible: page.isVideo
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(4)
            spacing: Theme.dp(8)

            Button {
                size: "s"
                variant: "tonal"
                icon: "photo_camera"
                text: "Стоп-кадр в PNG"
                disabled: editProc.running
                onClicked: page.saveVideoFrame()
            }

            Button {
                size: "s"
                variant: "tonal"
                icon: "rotate_90_degrees_cw"
                text: "Повернуть 90°"
                disabled: editProc.running
                onClicked: page.rotateMedia90()
            }

            Item { Layout.fillWidth: true }
        }
    }

    // ── Image Studio Actions Bar (kind === "image") ────────────────────────
    Card {
        Layout.fillWidth: true
        visible: page.path !== "" && (page.isImage || page.isAnimated)
        title: "Студия изображений"

        Flow {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            Button {
                size: "s"
                variant: "tonal"
                icon: "rotate_90_degrees_cw"
                text: "Повернуть 90°"
                disabled: editProc.running
                onClicked: page.rotateMedia90()
            }

            Button {
                size: "s"
                variant: "tonal"
                icon: "document_scanner"
                text: page.ocrBusy ? "Распознаю…" : "OCR (Текст с фото)"
                disabled: page.ocrBusy || editProc.running
                onClicked: page.runImageOcr()
            }

            Button {
                size: "s"
                variant: "filled"
                icon: "wallpaper"
                text: "Сделать обоями"
                onClicked: {
                    Wallpaper.apply(page.filePath, false);
                    page.savedPath = "Обои рабочего стола и тема Matugen обновлены";
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(4)
            spacing: Theme.dp(8)

            LText {
                role: "labelMedium"
                color: Theme.subtext
                text: "Конвертировать:"
            }

            Repeater {
                model: ["png", "jpg", "webp"]

                Chip {
                    required property var modelData
                    size: "sm"
                    kind: "assist"
                    icon: "swap_horiz"
                    label: "." + modelData
                    disabled: editProc.running || page.fileExt === modelData
                    onClicked: page.convertImageTo(modelData)
                }
            }

            Item { Layout.fillWidth: true }
        }

        // OCR Recognized Text Drawer
        Rectangle {
            visible: page.ocrDrawerOpen
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(8)
            implicitHeight: ocrCol.implicitHeight + Theme.dp(20)
            radius: Theme.rad(12)
            color: Theme.mLowest
            border.width: 1
            border.color: Theme.outline

            ColumnLayout {
                id: ocrCol
                anchors.fill: parent
                anchors.margins: Theme.dp(10)
                spacing: Theme.dp(6)

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(8)

                    Icon {
                        name: "text_snippet"
                        size: Theme.dp(18)
                        color: Theme.primary
                    }
                    LText {
                        Layout.fillWidth: true
                        role: "labelLarge"
                        color: Theme.text
                        text: "Распознанный текст (скопирован в буфер)"
                    }
                    Button {
                        size: "xs"
                        variant: "tonal"
                        icon: "content_copy"
                        text: "Копировать"
                        onClicked: page.copyToClipboard(page.ocrText)
                    }
                    IconButton {
                        size: "xs"
                        icon: "close"
                        onClicked: page.ocrDrawerOpen = false
                    }
                }

                TextEdit {
                    Layout.fillWidth: true
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.WordWrap
                    color: Theme.text
                    selectionColor: Theme.alpha(Theme.primary, 0.35)
                    selectedTextColor: Theme.text
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.typeSize("bodyMedium")
                    text: page.ocrText
                }
            }
        }
    }

    // ── Time Trim Card (Video & Audio) ─────────────────────────────────────
    Card {
        Layout.fillWidth: true
        visible: (page.isVideo || page.isAudio) && page.path !== ""
        title: page.isAudio ? "Обрезка аудио (Trim)" : "Обрезка по времени"

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(10)
            LText {
                Layout.preferredWidth: Theme.dp(70)
                role: "labelLarge"
                color: Theme.subtext
                text: "Начало"
            }
            Slider {
                Layout.fillWidth: true
                from: 0
                to: Math.max(0, page.durationSeconds)
                value: page.trimStart
                stepSize: 0.05
                showValue: false
                disabled: page.durationSeconds <= 0 || editProc.running
                onMoved: value => page.setTrimStart(value)
            }
            LText {
                Layout.preferredWidth: Theme.dp(54)
                horizontalAlignment: Text.AlignRight
                role: "labelMedium"
                color: Theme.text
                tabular: true
                text: page.formatTime(page.trimStart)
            }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(10)
            LText {
                Layout.preferredWidth: Theme.dp(70)
                role: "labelLarge"
                color: Theme.subtext
                text: "Конец"
            }
            Slider {
                Layout.fillWidth: true
                from: 0
                to: Math.max(0, page.durationSeconds)
                value: page.trimEnd
                stepSize: 0.05
                showValue: false
                disabled: page.durationSeconds <= 0 || editProc.running
                onMoved: value => page.setTrimEnd(value)
            }
            LText {
                Layout.preferredWidth: Theme.dp(54)
                horizontalAlignment: Text.AlignRight
                role: "labelMedium"
                color: Theme.text
                tabular: true
                text: page.formatTime(page.trimEnd)
            }
        }
        RowLayout {
            Layout.fillWidth: true
            LText {
                Layout.fillWidth: true
                role: "bodySmall"
                color: Theme.subtext
                text: "Выбранный фрагмент: " + page.formatTime(page.trimStart) + " — " + page.formatTime(page.trimEnd)
            }
            Button {
                size: "m"
                icon: "content_cut"
                text: "Обрезать"
                disabled: !page.canTrim || editProc.running
                onClicked: page.saveTrim()
            }
        }
    }

    // ── Frame Crop Card (Video & Image) ────────────────────────────────────
    Card {
        Layout.fillWidth: true
        visible: page.hasMetadata && (page.isVideo || page.isImage || page.isAnimated)
        title: "Обрезать кадр"

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            TextField {
                id: cropWidthField
                Layout.fillWidth: true
                variant: "outlined"
                label: "W"
                text: page.cropWidthText
                input.validator: IntValidator { bottom: 0; top: Math.max(1, page.sourceWidth) }
                onTextEdited: page.cropWidthText = cropWidthField.text
            }
            TextField {
                id: cropHeightField
                Layout.fillWidth: true
                variant: "outlined"
                label: "H"
                text: page.cropHeightText
                input.validator: IntValidator { bottom: 0; top: Math.max(1, page.sourceHeight) }
                onTextEdited: page.cropHeightText = cropHeightField.text
            }
            TextField {
                id: cropXField
                Layout.fillWidth: true
                variant: "outlined"
                label: "X"
                text: page.cropXText
                input.validator: IntValidator { bottom: 0; top: Math.max(1, page.sourceWidth) }
                onTextEdited: page.cropXText = cropXField.text
            }
            TextField {
                id: cropYField
                Layout.fillWidth: true
                variant: "outlined"
                label: "Y"
                text: page.cropYText
                input.validator: IntValidator { bottom: 0; top: Math.max(1, page.sourceHeight) }
                onTextEdited: page.cropYText = cropYField.text
            }
        }

        RowLayout {
            Layout.fillWidth: true
            LText {
                Layout.fillWidth: true
                role: "bodySmall"
                color: page.cropValid ? Theme.subtext : Theme.error
                text: "Пиксели исходного кадра · " + page.sourceWidth + " × " + page.sourceHeight
            }
            Button {
                size: "m"
                icon: "crop"
                text: "Обрезать кадр"
                disabled: !page.cropValid || editProc.running
                onClicked: page.saveCrop()
            }
        }
    }

    // ── MODE 4A: PDF Document Viewer (kind === "pdf") ──────────────────────
    Card {
        Layout.fillWidth: true
        visible: page.path !== "" && page.isPdf
        title: "Просмотр PDF"

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            Button {
                size: "xs"
                variant: "tonal"
                text: "‹"
                disabled: page.pdfPage <= 1 || inspectProc.running
                onClicked: page.startInspect(page.path, page.pdfPage - 1)
            }

            LText {
                role: "labelLarge"
                color: Theme.text
                tabular: true
                text: "Стр. " + page.pdfPage + " из " + page.pdfPages
            }

            Button {
                size: "xs"
                variant: "tonal"
                text: "›"
                disabled: page.pdfPage >= page.pdfPages || inspectProc.running
                onClicked: page.startInspect(page.path, page.pdfPage + 1)
            }

            Item { Layout.fillWidth: true }

            IconButton {
                size: "xs"
                variant: "outlined"
                icon: "zoom_out"
                onClicked: page.adjustZoom(0.8)
            }
            Chip {
                size: "sm"
                kind: "assist"
                label: Math.round(page.zoomLevel * 100) + "%"
                onClicked: page.resetZoom()
            }
            IconButton {
                size: "xs"
                variant: "outlined"
                icon: "zoom_in"
                onClicked: page.adjustZoom(1.25)
            }

            Chip {
                size: "sm"
                kind: "filter"
                icon: "dark_mode"
                label: "Ночной режим"
                selected: page.pdfNightMode
                onClicked: page.pdfNightMode = !page.pdfNightMode
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.dp(380)
            radius: Theme.rad(14)
            color: page.pdfNightMode ? "#12141a" : "#f4f4f6"
            clip: true

            Flickable {
                id: pdfFlick
                anchors.fill: parent
                contentWidth: Math.max(width, width * page.zoomLevel)
                contentHeight: Math.max(height, height * page.zoomLevel)
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Image {
                    id: pdfPageImage
                    width: pdfFlick.contentWidth
                    height: pdfFlick.contentHeight
                    visible: page.previewImagePath !== ""
                    source: visible ? page.localFileUrl(page.previewImagePath) : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    cache: false
                    smooth: true
                }

                // Night Mode Warm Dark Tint Overlay for bright PDF pages
                Rectangle {
                    anchors.fill: pdfPageImage
                    visible: page.previewImagePath !== "" && page.pdfNightMode
                    color: "#222634"
                    opacity: 0.42
                }

                // Text fallback when preview_image is unavailable
                Flickable {
                    anchors.fill: parent
                    anchors.margins: Theme.dp(12)
                    visible: page.previewImagePath === "" && page.textPreview !== ""
                    contentWidth: width
                    contentHeight: pdfFallbackText.implicitHeight
                    clip: true

                    LText {
                        id: pdfFallbackText
                        width: parent.width
                        role: "bodySmall"
                        mono: true
                        color: page.pdfNightMode ? Theme.text : "#1b1c1f"
                        wrapMode: Text.WordWrap
                        text: page.textPreview
                    }
                }
            }
        }
    }

    // ── MODE 4B: Code / Markdown / Text / Logs Viewer ──────────────────────
    Card {
        Layout.fillWidth: true
        visible: page.path !== "" && page.isTextLike
        title: page.kindLabel(page.kind) + (page.totalLineCount > 0 ? " · " + page.totalLineCount + " строк" : "")

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            TextField {
                id: codeSearchField
                Layout.fillWidth: true
                variant: "search"
                placeholder: "Поиск в файле…"
                text: page.codeSearchQuery
                onTextEdited: page.codeSearchQuery = codeSearchField.text
            }

            Chip {
                visible: page.codeSearchQuery.trim() !== ""
                size: "sm"
                kind: "filter"
                icon: "filter_list"
                label: "Совпадений: " + page.codeMatchCount
                selected: page.codeFilterLines
                onClicked: page.codeFilterLines = !page.codeFilterLines
            }

            Button {
                size: "xs"
                variant: "tonal"
                icon: "content_copy"
                text: "Копировать всё"
                disabled: page.textPreview === ""
                onClicked: {
                    page.copyToClipboard(page.textPreview);
                    page.savedPath = "Содержимое файла скопировано в буфер обмена";
                }
            }

            Button {
                size: "xs"
                variant: "outlined"
                icon: "open_in_new"
                text: "Открыть в системе"
                onClicked: page.openInSystem()
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.dp(360)
            radius: Theme.rad(14)
            color: Theme.mLowest
            border.width: 1
            border.color: Theme.outline
            clip: true

            ListView {
                id: codeListView
                anchors.fill: parent
                anchors.margins: Theme.dp(6)
                model: page.codeLines
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    id: codeLineDelegate
                    required property var modelData
                    required property int index

                    width: codeListView.width
                    height: Math.max(Theme.dp(20), lineContentText.implicitHeight + Theme.dp(4))
                    radius: Theme.rad(4)
                    color: codeLineDelegate.modelData.matched
                        ? Theme.alpha(Theme.primary, 0.22)
                        : (codeLineDelegate.index % 2 === 1 ? Theme.alpha(Theme.mHigh, 0.35) : "transparent")

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.dp(6)
                        anchors.rightMargin: Theme.dp(6)
                        spacing: Theme.dp(10)

                        LText {
                            Layout.preferredWidth: Theme.dp(42)
                            Layout.alignment: Qt.AlignTop
                            horizontalAlignment: Text.AlignRight
                            role: "labelSmall"
                            mono: true
                            tabular: true
                            color: codeLineDelegate.modelData.matched ? Theme.primary : Theme.subtextDim
                            text: String(codeLineDelegate.modelData.lineNumber)
                        }

                        LText {
                            id: lineContentText
                            Layout.fillWidth: true
                            role: "bodySmall"
                            mono: true
                            color: codeLineDelegate.modelData.matched ? Theme.primary : Theme.text
                            wrapMode: Text.WrapAnywhere
                            text: String(codeLineDelegate.modelData.text || " ")
                        }
                    }
                }
            }
        }
    }

    // ── MODE 4C: CSV / TSV & SQLite Database Table Viewer ──────────────────
    Card {
        Layout.fillWidth: true
        visible: page.path !== "" && page.isTableLike
        title: page.kind === "sqlite" ? "База данных SQLite" : "Таблица данных"

        // SQLite Table Selector Chips
        Flow {
            visible: page.kind === "sqlite" && page.sqliteTables.length > 0
            Layout.fillWidth: true
            spacing: Theme.dp(6)

            Repeater {
                model: page.sqliteTables

                Chip {
                    required property var modelData
                    size: "sm"
                    kind: "filter"
                    icon: "table_rows"
                    label: String(modelData)
                    selected: String(modelData) === page.activeSqliteTable
                    onClicked: page.startInspect(page.path, String(modelData))
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.dp(340)
            radius: Theme.rad(14)
            color: Theme.mLowest
            border.width: 1
            border.color: Theme.outline
            clip: true

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                // Sticky Table Header Row
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: Theme.dp(34)
                    color: Theme.secondaryContainer

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.dp(10)
                        anchors.rightMargin: Theme.dp(10)
                        spacing: Theme.dp(8)

                        Repeater {
                            model: page.tableHeaders

                            LText {
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.preferredWidth: Theme.dp(100)
                                role: "labelMedium"
                                color: Theme.fgSecondaryContainer
                                elide: Text.ElideRight
                                text: String(modelData)
                            }
                        }
                    }
                }

                // Scrollable Data Rows with Alternating Tonal Backgrounds
                ListView {
                    id: tableRowsView
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    model: page.tableRows
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Rectangle {
                        id: dataRowItem
                        required property var modelData
                        required property int index

                        readonly property var cells: Array.isArray(dataRowItem.modelData) ? dataRowItem.modelData : []

                        width: tableRowsView.width
                        height: Theme.dp(30)
                        color: dataRowItem.index % 2 === 1 ? Theme.mLow : "transparent"

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Theme.dp(10)
                            anchors.rightMargin: Theme.dp(10)
                            spacing: Theme.dp(8)

                            Repeater {
                                model: dataRowItem.cells

                                LText {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.preferredWidth: Theme.dp(100)
                                    role: "bodySmall"
                                    mono: true
                                    color: Theme.text
                                    elide: Text.ElideRight
                                    text: String(modelData !== null && modelData !== undefined ? modelData : "")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ── MODE 4D: Archive Inspector & Extractor (kind === "archive") ────────
    Card {
        Layout.fillWidth: true
        visible: page.path !== "" && page.isArchive
        title: "Содержимое архива"

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(10)

            Chip {
                size: "sm"
                kind: "assist"
                interactive: false
                icon: "folder_zip"
                label: "Файлов: " + page.archiveTotalEntries
            }

            Chip {
                visible: page.sourceSize > 0
                size: "sm"
                kind: "assist"
                interactive: false
                label: page.formatBytes(page.sourceSize)
            }

            Item { Layout.fillWidth: true }

            Button {
                size: "s"
                variant: "filled"
                icon: "unarchive"
                text: "Распаковать в папку"
                disabled: editProc.running
                onClicked: page.extractArchive()
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.dp(300)
            radius: Theme.rad(14)
            color: Theme.mLowest
            border.width: 1
            border.color: Theme.outline
            clip: true

            ListView {
                id: archiveListView
                anchors.fill: parent
                anchors.margins: Theme.dp(6)
                model: page.archiveEntries
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    id: archiveEntryItem
                    required property var modelData
                    required property int index

                    readonly property string entryName: typeof archiveEntryItem.modelData === "string"
                        ? archiveEntryItem.modelData
                        : String(archiveEntryItem.modelData.name || archiveEntryItem.modelData.path || "")
                    readonly property bool entryIsDir: (typeof archiveEntryItem.modelData === "object" && archiveEntryItem.modelData.dir)
                        || archiveEntryItem.entryName.endsWith("/")
                    readonly property real entrySize: typeof archiveEntryItem.modelData === "object"
                        ? (Number(archiveEntryItem.modelData.size) || 0)
                        : 0

                    width: archiveListView.width
                    height: Theme.dp(30)
                    radius: Theme.rad(6)
                    color: archiveEntryItem.index % 2 === 1 ? Theme.mLow : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.dp(8)
                        anchors.rightMargin: Theme.dp(8)
                        spacing: Theme.dp(8)

                        Icon {
                            name: archiveEntryItem.entryIsDir ? "folder" : "insert_drive_file"
                            size: Theme.dp(16)
                            color: archiveEntryItem.entryIsDir ? Theme.primary : Theme.subtext
                        }

                        LText {
                            Layout.fillWidth: true
                            role: "bodySmall"
                            mono: true
                            color: Theme.text
                            elide: Text.ElideMiddle
                            text: archiveEntryItem.entryName
                        }

                        LText {
                            visible: !archiveEntryItem.entryIsDir && archiveEntryItem.entrySize > 0
                            role: "labelSmall"
                            color: Theme.subtext
                            tabular: true
                            text: page.formatBytes(archiveEntryItem.entrySize)
                        }
                    }
                }
            }
        }
    }

    // ── MODE 4E: Font Specimen & Installer (kind === "font") ───────────────
    Card {
        Layout.fillWidth: true
        visible: page.path !== "" && page.isFont
        title: "Образец шрифта · " + (dynamicFontLoader.name || page.fileName)

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(10)

            Chip {
                size: "sm"
                kind: "assist"
                interactive: false
                icon: "font_download"
                label: dynamicFontLoader.status === FontLoader.Ready ? dynamicFontLoader.name : page.fileExt.toUpperCase()
            }

            Item { Layout.fillWidth: true }

            Button {
                size: "s"
                variant: "filled"
                icon: "download"
                text: "Установить шрифт в систему"
                disabled: editProc.running
                onClicked: page.installFont()
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(6)
            spacing: Theme.dp(10)

            Repeater {
                model: [14, 20, 28, 40]

                Rectangle {
                    id: fontSampleBox
                    required property var modelData

                    Layout.fillWidth: true
                    implicitHeight: sampleCol.implicitHeight + Theme.dp(16)
                    radius: Theme.rad(12)
                    color: Theme.mLowest

                    ColumnLayout {
                        id: sampleCol
                        anchors.fill: parent
                        anchors.margins: Theme.dp(8)
                        spacing: Theme.dp(4)

                        LText {
                            role: "labelSmall"
                            color: Theme.primary
                            tabular: true
                            text: fontSampleBox.modelData + " px"
                        }

                        Text {
                            Layout.fillWidth: true
                            color: Theme.text
                            font.family: dynamicFontLoader.status === FontLoader.Ready ? dynamicFontLoader.name : Theme.fontFamily
                            font.pixelSize: Theme.dp(Number(fontSampleBox.modelData))
                            wrapMode: Text.WordWrap
                            text: "Съешь ещё этих мягких французских булок, да выпей чаю · The quick brown fox jumps over the lazy dog · 0123456789"
                        }
                    }
                }
            }
        }
    }

    // ── Universal File Metadata Card ───────────────────────────────────────
    Card {
        Layout.fillWidth: true
        visible: page.path !== ""
        title: "Информация"

        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: Theme.dp(16)
            rowSpacing: Theme.dp(6)

            LText { role: "bodySmall"; color: Theme.subtext; text: "Имя" }
            LText { Layout.fillWidth: true; role: "bodyMedium"; color: Theme.text; text: page.fileName; elide: Text.ElideMiddle }
            LText { role: "bodySmall"; color: Theme.subtext; text: "Тип" }
            LText { Layout.fillWidth: true; role: "bodyMedium"; color: Theme.text; text: page.kindLabel(page.kind) + (page.fileExt !== "" ? " (." + page.fileExt + ")" : "") }
            LText { role: "bodySmall"; color: Theme.subtext; text: "Размер" }
            LText { Layout.fillWidth: true; role: "bodyMedium"; color: Theme.text; text: page.sourceSize > 0 ? page.formatBytes(page.sourceSize) : "—" }
            LText { visible: page.hasMetadata; role: "bodySmall"; color: Theme.subtext; text: "Разрешение" }
            LText { visible: page.hasMetadata; Layout.fillWidth: true; role: "bodyMedium"; color: Theme.text; text: page.hasMetadata ? page.sourceWidth + " × " + page.sourceHeight : "—" }
            LText { visible: page.sourceDuration > 0; role: "bodySmall"; color: Theme.subtext; text: "Длительность" }
            LText { visible: page.sourceDuration > 0; Layout.fillWidth: true; role: "bodyMedium"; color: Theme.text; text: page.sourceDuration > 0 ? page.formatTime(page.sourceDuration) : "—" }
            LText { visible: page.sourceCodec !== ""; role: "bodySmall"; color: Theme.subtext; text: "Кодек" }
            LText { visible: page.sourceCodec !== ""; Layout.fillWidth: true; role: "bodyMedium"; color: Theme.text; text: page.sourceCodec || "—" }
            LText { visible: page.sourceFps > 0; role: "bodySmall"; color: Theme.subtext; text: "FPS" }
            LText { visible: page.sourceFps > 0; Layout.fillWidth: true; role: "bodyMedium"; color: Theme.text; text: page.sourceFps > 0 ? page.sourceFps.toFixed(2) : "—" }
            LText { visible: Boolean(page.inspectData && page.inspectData.permissions); role: "bodySmall"; color: Theme.subtext; text: "Права доступа" }
            LText { visible: Boolean(page.inspectData && page.inspectData.permissions); Layout.fillWidth: true; role: "bodyMedium"; mono: true; color: Theme.text; text: String((page.inspectData && page.inspectData.permissions) || "—") }
        }
    }
}
