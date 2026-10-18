pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Notification history + transient toast state (history persisted).
Singleton {
    id: root

    property var history: []      // newest first
    property var current: null    // toast content
    property bool visible: false  // toast shown in the island
    property string showOn: ""
    property bool dnd: Prefs.dnd  // персистится в prefs.json (пишется через Prefs.set)
    property int currentTimeoutMs: 5000

    readonly property string statePath: Quickshell.stateDir + "/notifs.json"

    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }

    // Only serializable fields of history items are kept (raw is a live object).
    function serialize() {
        const out = [];
        for (const item of root.history) {
            if (!item) continue;
            out.push({
                appName: item.appName || "",
                summary: item.summary || "",
                body: item.body || "",
                appIcon: item.appIcon || "",
                ts: item.ts || 0
            });
        }
        return JSON.stringify(out);
    }

    function save() {
        const j = serialize();
        const tmp = root.statePath + ".tmp";
        Quickshell.execDetached(["sh", "-c",
            "mkdir -p " + shq(Quickshell.stateDir) + " && printf %s " + shq(j) + " > " + shq(tmp) + " && mv -f " + shq(tmp) + " " + shq(root.statePath)]);
    }
    // Debounced write: coalesces bursts of add/dismiss/clear.
    function scheduleSave() { saveTimer.restart(); }

    Timer {
        id: saveTimer
        interval: 400
        onTriggered: root.save()
    }

    Process {
        id: readProc
        command: ["sh", "-c", "cat " + shq(root.statePath) + " 2>/dev/null"]
        stdout: SplitParser {
            onRead: line => {
                try {
                    const j = JSON.parse(line);
                    if (Array.isArray(j)) root.history = j.slice(0, 12);
                } catch (e) {}
            }
        }
    }
    function load() { readProc.running = false; readProc.running = true; }

    Component.onCompleted: load()

    Timer {
        id: hideTimer
        interval: root.currentTimeoutMs
        onTriggered: root.visible = false
    }

    function timeoutFor(n) {
        const critical = n && Number(n.urgency) === 2;
        let seconds;
        if (critical) {
            seconds = Number(Prefs.notifCritTimeout);
            if (!isFinite(seconds) || seconds < 0) seconds = 0;
        } else {
            seconds = Number(Prefs.notifTimeout);
            if (Prefs.notifTimeout === undefined || Prefs.notifTimeout === null || !isFinite(seconds))
                seconds = Number(Prefs.toastSeconds);
            if (!isFinite(seconds) || seconds < 0) seconds = 0;
        }
        return Math.round(seconds * 1000);
    }

    function add(n) {
        const h = history.slice();
        h.unshift(n);
        root.history = h.slice(0, 12);
        scheduleSave();
    }
    function toast(n, output) {
        root.current = n;
        root.showOn = String(output || "");
        root.visible = true;
        root.currentTimeoutMs = root.timeoutFor(n);
        if (root.currentTimeoutMs > 0) hideTimer.restart();
        else hideTimer.stop();
        playNotifSound();
    }
    function push(n, output) { add(n); toast(n, output || ""); }
    function dismissAt(i) {
        const h = root.history.slice();
        if (i >= 0 && i < h.length) {
            const item = h[i];
            if (item && item.raw) { try { item.raw.dismiss(); } catch (e) {} }
            h.splice(i, 1);
            root.history = h;
            scheduleSave();
        }
    }
    function clearAll() {
        for (const item of root.history) if (item && item.raw) { try { item.raw.dismiss(); } catch (e) {} }
        root.history = [];
        root.visible = false;
        scheduleSave();
    }

    // ── Звук уведомлений ─────────────────────────────────────────────
    // Звучит на каждый показанный тост. DND-глушение выполняется на
    // отправителях: сервер уведомлений при DND не вызывает toast() вовсе
    // (см. shell.qml). Внутри тоста dnd не проверяем — иначе замолчал бы и
    // таймерный алерт, который сознательно обходит DND («это будильник»,
    // комментарий A4 в shell.qml). Sounds сам безопасен: нет плеера или
    // файла — тихо уйдёт; на всякий случай оборачиваем в try/catch.
    function playNotifSound() {
        try {
            if (!Sounds.enabled) return;
            Sounds.notify("notif");
        } catch (e) {}
    }

    // ── Расписание DND ───────────────────────────────────────────────
    // Тик раз в 30 с: вошли в окно From..To (может пересекать полночь,
    // From==To — окно не задаёт интервал) — dnd=true, вышли — false. Тиком
    // перезаписываем dnd только на пересечении границы окна, поэтому ручные
    // тумблеры сохраняются до ближайшей границы (и до перезагрузки шелла —
    // состояние персистится). Смена самих настроек расписания применяется
    // сразу — но записью, вынесенной из кадра нотификации (Qt.callLater):
    // writeAdapter внутри реакции на собственную же запись ловил
    // «binding loop» на dndFrom/dndTo в Prefs.
    property int dndWindowPrev: -1 // окно с прошлого тика: -1 не оценено / 0 вне / 1 внутри

    function hmToMin(s, dflt) {
        const m = /^(\d{1,2}):(\d{2})$/.exec(String(s));
        if (!m) return dflt;
        const h = parseInt(m[1], 10), mi = parseInt(m[2], 10);
        if (h < 0 || h > 23 || mi < 0 || mi > 59) return dflt;
        return h * 60 + mi;
    }

    // Текущее состояние окна расписания: -1 — Prefs не готовы, 0 — вне окна, 1 — внутри.
    function scheduleWindowNow() {
        if (!Prefs.ready) return -1;
        if (!Prefs.dndScheduleEnabled) return 0;
        const from = hmToMin(Prefs.dndFrom, 23 * 60), to = hmToMin(Prefs.dndTo, 7 * 60);
        if (from === to) return 0;
        const d = new Date(), nowMin = d.getHours() * 60 + d.getMinutes();
        return (from > to ? (nowMin >= from || nowMin < to) : (nowMin >= from && nowMin < to)) ? 1 : 0;
    }

    // Принять новое состояние окна. Тик (force=false) пишет только на
    // пересечении границы; смена настроек (force=true) — сразу. Гвард
    // «Prefs.dnd уже равен» делает запись идемпотентной — цикла не будет.
    function applyDndSchedule(force) {
        const st = scheduleWindowNow();
        if (st < 0) return; // Prefs ещё читаются — дождёмся onReadyChanged
        const prev = root.dndWindowPrev;
        root.dndWindowPrev = st;
        if (!Prefs.dndScheduleEnabled) return; // расписание выключено — ручной dnd не трогаем
        const crossing = prev >= 0 && prev !== st;
        if ((force || crossing) && Prefs.dnd !== (st === 1))
            Prefs.set("dnd", st === 1);
    }

    Timer {
        id: dndScheduleTimer

        interval: 30000
        repeat: true
        running: Prefs.ready
        onTriggered: root.applyDndSchedule(false)
    }

    Connections {
        target: Prefs

        // Внешние изменения ключей расписания (настройки, ручные правки в
        // prefs.json): синхронизируем состояние окна, запись — отложенно,
        // вне кадра, в котором Prefs перечитывает свой файл.
        function onDndScheduleEnabledChanged() { Qt.callLater(() => root.applyDndSchedule(true)) }
        function onDndFromChanged() { Qt.callLater(() => root.applyDndSchedule(true)) }
        function onDndToChanged() { Qt.callLater(() => root.applyDndSchedule(true)) }

        // Prefs читаются асинхронно — первая оценка после загрузки файла
        // (тихая: расписание возьмёт управление на ближайшей границе).
        function onReadyChanged() { if (Prefs.ready) root.applyDndSchedule(false) }
    }
}
