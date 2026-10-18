pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Clipboard history via cliphist + pinned items.
Singleton {
    id: c

    property var items: []
    property var pins: []
    property bool loading: false

    // накопитель текущего прогона cliphist — items меняется один раз за цикл,
    // иначе ListView пересобирается на каждой строке и список «дрожит»
    property var _buf: []

    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }

    function normalizeUrl(value) {
        const text = String(value || "").trim();
        return /^www\./i.test(text) ? "https://" + text : text;
    }
    function normalizePath(value) {
        let path = String(value || "").trim();
        if (/^file:\/\//i.test(path)) {
            path = path.slice(7);
            if (/^localhost\//i.test(path)) path = path.slice(9);
            if (path !== "" && path.charAt(0) !== "/") path = "/" + path;
            try { path = decodeURIComponent(path); } catch (e) {}
        }
        const home = Quickshell.env("HOME") || "";
        if (path === "~") return home;
        if (path.indexOf("~/") === 0) return home + path.slice(1);
        return path;
    }
    function describe(text) {
        const value = String(text || "").replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, "").trim();
        let kind = "text";
        let rgb = "", hsl = "", swatch = "", url = "", path = "";

        if (/^#(?:[0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(value)) {
            kind = "color";
            let hex = value.slice(1);
            if (hex.length === 3) hex = hex.charAt(0) + hex.charAt(0)
                + hex.charAt(1) + hex.charAt(1) + hex.charAt(2) + hex.charAt(2);
            const r = parseInt(hex.slice(0, 2), 16);
            const g = parseInt(hex.slice(2, 4), 16);
            const b = parseInt(hex.slice(4, 6), 16);
            const a = hex.length === 8 ? parseInt(hex.slice(6, 8), 16) : 255;
            rgb = "rgb(" + r + ", " + g + ", " + b + ")";

            const rn = r / 255, gn = g / 255, bn = b / 255;
            const max = Math.max(rn, gn, bn), min = Math.min(rn, gn, bn);
            let h = 0, s = 0;
            const l = (max + min) / 2;
            if (max !== min) {
                const d = max - min;
                s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
                switch (max) {
                case rn: h = (gn - bn) / d + (gn < bn ? 6 : 0); break;
                case gn: h = (bn - rn) / d + 2; break;
                case bn: h = (rn - gn) / d + 4; break;
                }
                h /= 6;
            }
            hsl = "hsl(" + Math.round(h * 360) + ", " + Math.round(s * 100)
                + "%, " + Math.round(l * 100) + "%)";
            swatch = Qt.rgba(rn, gn, bn, a / 255);
        } else if (/^(https?:\/\/[^\s]+|www\.[^\s]+)$/i.test(value)) {
            kind = "url";
            url = c.normalizeUrl(value);
        } else if (value.charAt(0) === "/" || value.indexOf("~/") === 0 || /^file:\/\//i.test(value)) {
            const filePath = /^file:\/\//i.test(value) ? value.replace(/[?#].*$/, "") : value;
            kind = /\.(?:png|jpe?g|gif|webp|bmp|svg)$/i.test(filePath) ? "image-file" : "file";
            path = c.normalizePath(filePath);
        }

        return { kind: kind, rgb: rgb, hsl: hsl, swatch: swatch, url: url, path: path };
    }

    // Keep capturing the clipboard.
    Process {
        id: storeProc
        command: ["sh", "-c", "wl-paste --watch cliphist store"]
        running: true
    }

    // List entries and decode image thumbnails.
    Process {
        id: scanProc
        command: ["sh", "-c",
            "C=\"$HOME/.cache/oberon/clip\"; mkdir -p \"$C\"; " +
            "cliphist list 2>/dev/null | head -60 | sed 's/\\t/|/' | while IFS='|' read -r id rest; do " +
            "case \"$rest\" in *\"binary data\"*) [ -s \"$C/$id.png\" ] || cliphist decode \"$id\" > \"$C/$id.png\" 2>/dev/null; printf '%s|image|%s\\n' \"$id\" \"$rest\";; " +
            "*) printf '%s|text|%s\\n' \"$id\" \"$rest\";; esac; done"]
        stdout: SplitParser { onRead: line => c.parseEntry(line) }
        onExited: {
            // slice(): гарантируем новый массив — присваивание того же
            // объекта не шлёт change-сигнал (refresh вызывается дважды)
            c.items = c._buf.slice();
            c.loading = false;
        }
    }
    function parseEntry(line) {
        const i = line.indexOf("|"); if (i < 0) return;
        const j = line.indexOf("|", i + 1); if (j < 0) return;
        const id = line.slice(0, i);
        const preview = line.slice(j + 1);
        const info = c.describe(preview);
        c._buf.push({
            id: id,
            type: line.slice(i + 1, j),
            preview: preview,
            thumb: Quickshell.env("HOME") + "/.cache/oberon/clip/" + id + ".png",
            kind: info.kind,
            rgb: info.rgb,
            hsl: info.hsl,
            swatch: info.swatch,
            url: info.url,
            path: info.path
        });
    }

    Process {
        id: pinsProc
        // jq -c: файл пишется многострочным, а SplitParser читает по строкам
        command: ["sh", "-c", "cat " + shq(Quickshell.env("HOME") + "/.local/state/oberon/pins.json") + " 2>/dev/null | jq -c . 2>/dev/null"]
        stdout: SplitParser { onRead: line => { try { c.pins = JSON.parse(line); } catch (e) { c.pins = []; } } }
    }
    function loadPins() { pinsProc.running = false; pinsProc.running = true; }

    // обновление: старый список остаётся на экране, пока не готов новый —
    // без «мигания» пустотой; items присваивается один раз в onExited
    function refresh() { c._buf = []; c.loading = true; scanProc.running = false; scanProc.running = true; c.loadPins(); }

    function copy(id, type) {
        const mime = (type === "image") ? " --type image/png" : "";
        Quickshell.execDetached(["sh", "-c", "cliphist decode " + shq(id) + " | wl-copy" + mime]);
    }
    // cliphist и jq пишут в фоне (execDetached не ждёт завершения), поэтому
    // после удаления/закрепления перечитываем списки спустя короткую паузу —
    // иначе UI показывает старое состояние до повторного открытия вкладки
    Timer {
        id: resync
        interval: 350
        onTriggered: c.refresh()
    }
    function refreshLater() { resync.restart() }

    // cliphist delete принимает строку из stdin и сверяет её с записью целиком
    // (id идёт первым полем), поэтому находим строку по id и передаём как есть;
    // строку из списка убираем сразу — UI не ждёт cliphist
    function del(id) {
        c.items = c.items.filter(function (it) { return String(it.id) !== String(id); });
        Quickshell.execDetached(["sh", "-c",
            "LINE=$(cliphist list 2>/dev/null | awk -F'\\t' -v id=" + shq(id)
            + " '$1 == id { print; exit }'); "
            + "[ -n \"$LINE\" ] && printf '%s' \"$LINE\" | cliphist delete"]);
        refreshLater();
    }
    function wipe() { Quickshell.execDetached(["sh", "-c", "cliphist wipe; rm -f \"$HOME/.cache/oberon/clip/\"*.png"]); c.items = []; }
    function pin(id) { Quickshell.execDetached(["sh", "-c", "bash " + shq(Quickshell.env("HOME") + "/oberon/scripts/clip-pin.sh") + " " + shq(id)]); refreshLater(); }
    function unpin(id) { Quickshell.execDetached(["sh", "-c", "bash " + shq(Quickshell.env("HOME") + "/oberon/scripts/clip-unpin.sh") + " " + shq(id)]); refreshLater(); }
    function copyPin(p) {
        if (p.type === "image") Quickshell.execDetached(["sh", "-c", "wl-copy --type image/png < " + shq(p.file)]);
        else Quickshell.execDetached(["sh", "-c", "printf %s " + shq(p.text) + " | wl-copy"]);
    }
}
