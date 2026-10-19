pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "GoLimits.js" as Limits

// Расход лимитов OpenCode Go (план юзера). Данные — ЛОКАЛЬНО, без сети:
// БД ~/.local/share/opencode/opencode.db, таблица session_message
// (type='assistant', providerID='opencode-go', cost — доллары, time_created — мс).
// Окна 5ч/7д/30д считаются одним GROUP BY-запросом; 5ч = 20% месячного
// лимита модели, 7д = 50%, 30д (rolling месяц) = 100%; Go Plus = ×2.
// Обновление: раз в 5 минут + refresh() по требованию (страница OpenCode).
Singleton {
    id: usage

    readonly property string dbPath: Quickshell.env("HOME") + "/.local/share/opencode/opencode.db"

    property bool loading: false
    property bool ready: false          // было хотя бы одно успешное чтение
    property bool error: false          // последний прогон не удался (ms/gate)
    property date updatedAt: new Date(0)

    // Сырые строки DB: [{id, spent5, spent7, spent30, req5, req7, req30, lastMs}]
    property var raw: []

    // Модели по тарифу: расход до лимита, отсорт по худшему % (для страницы
    // «OpenCode»); unlimited — отдельно; в таблице, но без трат — unusedModels.
    property var models: []             // лимитированные с тратами
    property var freeModels: []         // unlimited с тратами
    property var unusedModels: []       // есть в таблице GoLimit — трат нет

    // Агрегат подписки по окнам (общий счётчик по всем моделям opencode-go):
    // {spent5, spent7, spent30, cap5, cap7, cap30, limit, pct5, pct7, pct30,
    //  req5, req7, req30, worstPct, worstKey}
    property var aggregate: ({
        "spent5": 0, "spent7": 0, "spent30": 0,
        "cap5": 12, "cap7": 30, "cap30": 60, "limit": 60,
        "pct5": 0, "pct7": 0, "pct30": 0,
        "req5": 0, "req7": 0, "req30": 0,
        "worstPct": 0, "worstKey": "5h"
    })
    readonly property var totals: usage.aggregate

    // Самый нагруженный (лимитированный) model: {name/id, pct5, pct7, pct30,
    // worstPct, worstKey} — для разбивки на странице; null, пока нет данных.
    property var worst: null

    readonly property string planLabel: Limits.planLabel(Prefs.goPlan)
    readonly property real planLimit: Limits.planLimit(Prefs.goPlan)
    // Дней до сброса месячного счётчика — до day-of-month Prefs.goRenewDom.
    readonly property int renewDays: usage._renewDays(Prefs.goRenewDom)

    // Последний сбой: текст для страницы, "" — ок
    property string errorText: ""

    /* ── конфиги OpenCode (локально, только чтение) ────────────────────── */
    // opencode.json — глобальный дефолт модели + inline-агенты (explore/general);
    // agents/*.md — frontmatter model: для md-агентов. Изменения следятся,
    // страница OpenCode подтверждает актуальный ref по этим данным.

    readonly property string ocConfigPath: Quickshell.env("HOME") + "/.config/opencode/opencode.json"
    readonly property string ctlScript: Quickshell.env("HOME") + "/oberon/scripts/opencode-ctl.py"
    readonly property var agentList: ["general", "explore", "scout", "tester", "reviewer"]

    property string defaultModelRef: ""     // "provider/id[#variant]" из opencode.json
    property var inlineAgents: ({})         // opencode.json agents.<nm>.model
    property var agentModels: ({})          // agents/<nm>.md frontmatter → ref
    property string configError: ""

    FileView {
        id: ocConfigFile
        path: usage.ocConfigPath
        watchChanges: true
        onFileChanged: reload()
        onLoadedChanged: if (loaded) usage._eatConfig(ocConfigFile.text())
    }

    component AgentFile: FileView {
        id: af

        // не readonly: присваивается при инстанцировании (AgentFile { agentName: ... })
        property string agentName: ""

        path: Quickshell.env("HOME") + "/.config/opencode/agents/" + agentName + ".md"
        watchChanges: true
        onFileChanged: af.reload()
        onLoadedChanged: {
            if (!af.loaded)
                return;
            const m = af.text().match(/^model:\s*(\S+)\s*$/m);
            const refs = Object.assign({}, usage.agentModels);
            if (m) {
                refs[af.agentName] = m[1];
                usage.agentModels = refs;
            }
            // нет файла — ключ не создаётся (agentCurrent уйдёт в inline/дефолт)
        }
    }
    AgentFile { agentName: "scout" }
    AgentFile { agentName: "tester" }
    AgentFile { agentName: "reviewer" }
    AgentFile { agentName: "orchestrator" }

    function _eatConfig(text) {
        try {
            const cfg = JSON.parse(text);
            usage.defaultModelRef = typeof cfg.model === "string" ? cfg.model : "";
            const inline = {};
            const ag = cfg.agents || {};
            for (const k of Object.keys(ag))
                if (ag[k] && typeof ag[k].model === "string")
                    inline[k] = ag[k].model;
            usage.inlineAgents = inline;
            usage.configError = "";
        } catch (e) {
            usage.configError = "opencode.json не читается";
        }
    }

    // Текущая модель агента: md-файл > inline (opencode.json) > глобальный дефолт.
    function agentCurrent(name) {
        const md = usage.agentModels[name];
        if (md !== undefined && md !== "")
            return md;
        const inl = usage.inlineAgents[name];
        if (inl !== undefined && inl !== "")
            return inl;
        return usage.defaultModelRef;
    }

    // Запустить scripts/opencode-ctl.py с аргументами; cb(out, isErr).
    // Один прогон за раз — страница показывает статус и не запускает второй.
    function runCtl(args, cb) {
        if (usage._ctlBusy)
            return false;
        usage._ctlOut = "";
        usage._ctlIsErr = false;
        usage._ctlCb = cb;
        cmdProc.command = ["python3", usage.ctlScript].concat(args);
        usage._ctlBusy = true;
        cmdProc.running = true;
        return true;
    }
    readonly property bool ctlBusy: _ctlBusy
    property bool _ctlBusy: false
    property string _ctlOut: ""
    property bool _ctlIsErr: false
    property var _ctlCb: null

    Process {
        id: cmdProc
        stdout: SplitParser { onRead: line => usage._ctlOut += line + "\n" }
        stderr: SplitParser { onRead: line => usage._ctlOut += line + "\n" }
        onExited: (code) => {
            usage._ctlBusy = false;
            usage._ctlIsErr = code !== 0;
            const cb = usage._ctlCb;
            usage._ctlCb = null;
            if (cb)
                cb(usage._ctlOut, code !== 0);
        }
    }

    Component.onCompleted: usage.refresh()

    Timer {
        interval: 5 * 60 * 1000
        running: true
        repeat: true
        triggeredOnStart: false
        onTriggered: usage.refresh()
    }

    // лимиты меняются с планом — пересобрать агрегаты
    Connections {
        target: Prefs
        function onGoPlanChanged() { usage._rebuild(); }
    }

    /* ── SQL ─────────────────────────────────────────────────────────── */

    function _sql(t5, t7, t30) {
        return "SELECT json_extract(data,'$.model.id')," +
            " printf('%.6f', SUM(CASE WHEN time_created > " + t5 + " THEN COALESCE(json_extract(data,'$.cost'),0) ELSE 0 END))," +
            " printf('%.6f', SUM(CASE WHEN time_created > " + t7 + " THEN COALESCE(json_extract(data,'$.cost'),0) ELSE 0 END))," +
            " printf('%.6f', SUM(CASE WHEN time_created > " + t30 + " THEN COALESCE(json_extract(data,'$.cost'),0) ELSE 0 END))," +
            " COUNT(CASE WHEN time_created > " + t5 + " THEN 1 END)," +
            " COUNT(CASE WHEN time_created > " + t7 + " THEN 1 END)," +
            " COUNT(CASE WHEN time_created > " + t30 + " THEN 1 END)," +
            " printf('%d', MAX(time_created))" +
            " FROM session_message" +
            " WHERE type='assistant'" +
            " AND json_extract(data,'$.model.providerID')='" + Limits.GO_PROVIDER + "'" +
            " AND time_created > " + t30 +
            " GROUP BY 1";
    }

    Process {
        id: dbProc
        stdout: SplitParser {
            // один TSV-проход → готовые срезы окна
            onRead: line => usage._row(line)
        }
        onExited: (code) => usage._finish(code === 0)
    }

    // Запросить свежие срезы (страничная кнопка/таймер). Один прогон за раз.
    readonly property bool busy: dbProc.running

    function refresh() {
        if (usage.busy)
            return;
        const now = Date.now();
        const t5 = now - Limits.WINDOWS["5h"].h;
        const t7 = now - Limits.WINDOWS["7d"].h;
        const t30 = now - Limits.WINDOWS["30d"].h;
        usage.raw = [];
        usage.error = false;
        usage.loading = true;
        dbProc.command = ["sqlite3", "-readonly", "-batch", "-noheader",
                          "-separator", "\t", usage.dbPath, usage._sql(t5, t7, t30)];
        // рестарт-идиома: возможна смена command внутри цикла таймера
        dbProc.running = false;
        dbProc.running = true;
    }

    function _row(line) {
        const f = line.split("\t");
        if (f.length < 8 || f[0] === "")
            return;
        usage.raw.push({
            "id": f[0],
            "spent5": parseFloat(f[1]) || 0,
            "spent7": parseFloat(f[2]) || 0,
            "spent30": parseFloat(f[3]) || 0,
            "req5": parseInt(f[4], 10) || 0,
            "req7": parseInt(f[5], 10) || 0,
            "req30": parseInt(f[6], 10) || 0,
            "lastMs": parseInt(f[7], 10) || 0
        });
    }

    function _finish(ok) {
        usage.loading = false;
        if (!ok && usage.raw.length === 0) {
            usage.error = true;
            usage.errorText = "БД не читается: " + usage.dbPath;
            return;
        }
        usage.error = false;
        usage.updatedAt = new Date();
        usage.ready = true;
        usage._rebuild();
    }

    /* ── агрегаты ────────────────────────────────────────────────────── */

    function _rebuild() {
        const plan = Prefs.goPlan;
        const metered = [];
        const free = [];
        const usedIds = {};

        const cap5 = Limits.planWindowCap(plan, "5h");
        const cap7 = Limits.planWindowCap(plan, "7d");
        const cap30 = Limits.planWindowCap(plan, "30d");

        let agg = {
            "spent5": 0, "spent7": 0, "spent30": 0,
            "cap5": cap5, "cap7": cap7, "cap30": cap30, "limit": cap30,
            "pct5": 0, "pct7": 0, "pct30": 0,
            "req5": 0, "req7": 0, "req30": 0,
            "worstPct": 0, "worstKey": "5h"
        };
        let norm5 = 0, norm7 = 0, norm30 = 0;
        let worstPct = -1;
        let worstItem = null;

        for (let i = 0; i < usage.raw.length; i++) {
            const r = usage.raw[i];
            const id = r.id;
            usedIds[id] = true;
            const limit = Limits.limitFor(id, plan);
            if (limit === 0) {
                free.push(usage._fmt(id, r, limit));
                agg.req5 += r.req5; agg.req7 += r.req7; agg.req30 += r.req30;
                continue;
            }
            const item = usage._fmt(id, r, limit);
            metered.push(item);
            agg.spent5 += r.spent5; agg.spent7 += r.spent7; agg.spent30 += r.spent30;
            agg.req5 += r.req5; agg.req7 += r.req7; agg.req30 += r.req30;
            norm5 += item.pct5;
            norm7 += item.pct7;
            norm30 += item.pct30;
            if (item.worstPct > worstPct || (item.worstPct === worstPct && worstItem && r.spent30 > worstItem.raw.spent30)) {
                worstPct = item.worstPct;
                worstItem = item;
            }
        }

        // Общий процент подписки: сумма нормализованных долей по всем моделям
        // (или фоллбэк от базового лимита плана $12 / $30 / $60).
        const rawPct5 = cap5 > 0 ? usage._pct(agg.spent5, cap5) : 0;
        const rawPct7 = cap7 > 0 ? usage._pct(agg.spent7, cap7) : 0;
        const rawPct30 = cap30 > 0 ? usage._pct(agg.spent30, cap30) : 0;
        agg.pct5 = Math.min(999, norm5 > 0 ? norm5 : rawPct5);
        agg.pct7 = Math.min(999, norm7 > 0 ? norm7 : rawPct7);
        agg.pct30 = Math.min(999, norm30 > 0 ? norm30 : rawPct30);

        let awp = agg.pct5, awk = "5h";
        if (agg.pct7 > awp) { awp = agg.pct7; awk = "7d"; }
        if (agg.pct30 > awp) { awp = agg.pct30; awk = "30d"; }
        agg.worstPct = awp;
        agg.worstKey = awk;

        metered.sort((a, b) => b.worstPct - a.worstPct || b.spent30 - a.spent30);
        free.sort((a, b) => b.lastMs - a.lastMs);

        // модели из таблицы без единого запроса за 30д — компактный список
        const unused = [];
        for (const id of Object.keys(Limits.GO_LIMITS))
            if (!usedIds[id])
                unused.push(id);
        unused.sort();

        usage.aggregate = agg;
        usage.models = metered;
        usage.freeModels = free;
        usage.unusedModels = unused;
        usage.worst = worstItem === null ? null : {
            "id": worstItem.id,
            "name": worstItem.name,
            "limit": worstItem.limit,
            "pct5": worstItem.pct5,
            "pct7": worstItem.pct7,
            "pct30": worstItem.pct30,
            "worstPct": worstItem.worstPct,
            "worstKey": worstItem.worstKey
        };
    }

    // Расчёт per-модели внутри окна: pct = потрачено / лимит_окна × 100
    function _fmt(id, r, limit) {
        const cap5 = limit > 0 ? limit * Limits.WINDOWS["5h"].frac : 0;
        const cap7 = limit > 0 ? limit * Limits.WINDOWS["7d"].frac : 0;
        const cap30 = limit > 0 ? limit : 0;
        const pct5 = cap5 > 0 ? usage._pct(r.spent5, cap5) : 0;
        const pct7 = cap7 > 0 ? usage._pct(r.spent7, cap7) : 0;
        const pct30 = cap30 > 0 ? usage._pct(r.spent30, cap30) : 0;
        let wp = pct5, wk = "5h";
        if (pct7 > wp) { wp = pct7; wk = "7d"; }
        if (pct30 > wp) { wp = pct30; wk = "30d"; }
        return {
            "id": id,
            "name": Limits.nameOf(id),
            "limit": limit,
            "noLimit": limit === 0,
            "unknown": limit === -1,
            "spent5": r.spent5, "spent7": r.spent7, "spent30": r.spent30,
            "req5": r.req5, "req7": r.req7, "req30": r.req30,
            "pct5": pct5, "pct7": pct7, "pct30": pct30,
            "worstPct": wp, "worstKey": wk,
            "lastMs": r.lastMs,
            "lastLabel": usage.timeOf(r.lastMs),
            "raw": r
        };
    }

    function _pct(spent, cap) { return Math.max(0, Math.min(999, spent / cap * 100)); }
    function _renewDays(dom) {
        const d = Math.max(1, Math.min(31, dom | 0));
        const now = new Date();
        if (now.getDate() < d)
            return d - now.getDate();
        const next = new Date(now.getFullYear(), now.getMonth() + 1, d);
        return Math.max(0, Math.round((next - new Date(now.getFullYear(), now.getMonth(), now.getDate())) / 86400000));
    }

    /* ── утилиты для UI ──────────────────────────────────────────────── */

    function money(x) { return "$" + (Math.round(x * 100) / 100).toFixed(2); }

    function timeOf(ms) {
        if (!ms)
            return "—";
        const d = new Date(ms);
        const now = new Date();
        return (d.toDateString() === now.toDateString())
            ? Qt.formatDateTime(d, "HH:mm")
            : Qt.formatDateTime(d, "dd MMM HH:mm");
    }

    // Тон по pct: accent < порога предупреждения < 85 → error.
    function toneKey(pct) {
        if (pct >= 85) return "error";
        if (pct >= Math.max(0, Math.min(100, Prefs.goWarnPct))) return "warn";
        return "ok";
    }

    // Лимит окна всей подписки в $ (подписи «из $…»).
    function planWindowCap(key) {
        return Limits.planWindowCap(Prefs.goPlan, key);
    }

    // Лимит окна в $ (подписи «из $…»).
    function windowCap(model, key) {
        if (!model || model.limit <= 0)
            return 0;
        return model.limit * Limits.WINDOWS[key].frac;
    }

    function windowLabel(key) { return Limits.WINDOWS[key].label; }
    function windowTitle(key) { return Limits.WINDOWS[key].title || Limits.WINDOWS[key].label; }
}
