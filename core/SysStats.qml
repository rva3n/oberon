pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Системные метрики: CPU, память, диск, сеть, GPU, температуры, uptime и
// 60-точечные скользящие истории (0..1) для графиков вкладки «Производительность».
Singleton {
    id: s

    // ── Базовые метрики (совместимость с виджетами и панелями) ────────
    property real cpu: 0          // 0..1
    property real memUsed: 0      // байты
    property real memTotal: 0
    property real memAvailable: 0
    property real memFree: 0
    property real memCached: 0
    property real memBuffers: 0
    property real memDirty: 0
    property real memShared: 0

    property real diskUsed: 0
    property real diskTotal: 0
    property real diskReadRate: 0   // байт/с
    property real diskWriteRate: 0  // байт/с
    property real diskBusy: 0       // 0..1
    property real diskTotalRead: 0  // байты
    property real diskTotalWrite: 0 // байты
    property real diskScaleMax: 1048576

    property real tempC: -1
    property int uptime: 0        // секунды
    property string host: ""
    property string kernel: ""
    property real shellRss: 0     // байты

    // ── GPU (amdgpu / drm / hwmon) ────────────────────────────────────
    property real gpuBusy: 0      // 0..1
    property bool gpuLoadAvailable: false
    property real vramUsed: 0     // байты
    property real vramTotal: 0
    property real gpuTempC: -1
    property real gpuPowerW: -1
    property int gpuSclkMhz: 0
    property int gpuFanRpm: 0

    // ── Дополнительные метрики CPU и системы ──────────────────────────
    property real load1: 0
    property real load5: 0
    property real load15: 0
    property int procCount: 0
    property int cpuProcsRunning: 0
    property int cpuThreadsTotal: 0
    property real swapUsed: 0
    property real swapTotal: 0
    property int cpuCurMhz: 0
    property int cpuBaseMhz: 0
    property int cpuMaxMhz: 0
    property string cpuCacheL3: ""
    property string cpuVirt: "Включено"
    property int cores: 0
    property int physicalCores: 0
    property string cpuModel: ""
    property string gpuModel: ""
    property string distro: ""
    property var temps: []       // [{name, label, c}]
    property var disks: []       // [{mount, device, fstype, used, total, avail}]
    property var coreLoads: []   // загрузка по ядрам, 0..1
    property var coreMhz: []     // частота по ядрам, МГц

    // ── Сеть ──────────────────────────────────────────────────────────
    property real netRx: 0       // байт/с
    property real netTx: 0       // байт/с
    property real netTotalRx: 0  // байты всего
    property real netTotalTx: 0  // байты всего
    property string netIface: ""
    property string netIp: ""
    property real netScaleMax: 65536

    // ── 60-точечные скользящие истории (0..1) для графиков Canvas ─────
    property var cpuHistory: {
        const a = [];
        for (let i = 0; i < 60; i++) a.push(0);
        return a;
    }
    property var coreHistories: [] // массив на каждое ядро по 30 точек (0..1)
    property var memHistory: {
        const a = [];
        for (let i = 0; i < 60; i++) a.push(0);
        return a;
    }
    property var gpuHistory: {
        const a = [];
        for (let i = 0; i < 60; i++) a.push(0);
        return a;
    }
    property var netRxHistory: {
        const a = [];
        for (let i = 0; i < 60; i++) a.push(0);
        return a;
    }
    property var netTxHistory: {
        const a = [];
        for (let i = 0; i < 60; i++) a.push(0);
        return a;
    }
    property var diskIoHistory: {
        const a = [];
        for (let i = 0; i < 60; i++) a.push(0);
        return a;
    }
    property var diskReadHistory: {
        const a = [];
        for (let i = 0; i < 60; i++) a.push(0);
        return a;
    }
    property var diskWriteHistory: {
        const a = [];
        for (let i = 0; i < 60; i++) a.push(0);
        return a;
    }

    // ── Удобные вычисляемые свойства для диспетчера задач ─────────────
    readonly property real memFrac: memTotal > 0 ? memUsed / memTotal : 0
    readonly property real memPct: s.memFrac
    readonly property real diskFrac: diskTotal > 0 ? diskUsed / diskTotal : 0
    readonly property real vramFrac: vramTotal > 0 ? vramUsed / vramTotal : 0
    readonly property real swapFrac: swapTotal > 0 ? swapUsed / swapTotal : 0

    readonly property real cpuUsage: s.cpu
    readonly property int cpuPercent: Math.round(Math.max(0, Math.min(1, s.cpu || 0)) * 100)
    readonly property string cpuGhz: {
        const m = s.cpuCurMhz > 0 ? s.cpuCurMhz : (s.cpuBaseMhz > 0 ? s.cpuBaseMhz : s.cpuMaxMhz);
        return m > 0 ? (m / 1000).toFixed(2) : "0.00";
    }
    readonly property int gpuUsage: Math.round(Math.max(0, Math.min(1, s.gpuBusy || 0)) * 100)
    readonly property int gpuTemp: s.gpuTempC >= 0 && isFinite(s.gpuTempC) ? Math.round(s.gpuTempC) : 0
    readonly property string gpuName: s.gpuModel
    readonly property bool gpuAvailable: s.gpuTempC >= 0 || s.gpuPowerW > 0
                                         || s.gpuSclkMhz > 0 || s.gpuFanRpm > 0
                                         || s.vramTotal > 0 || s.gpuBusy > 0
                                         || s.gpuModel !== ""

    property bool taskmanActive: false
    property bool settingsActive: false
    // Метрики работают для диспетчера, системного виджета и раздела настроек.
    readonly property bool active: s.taskmanActive
        || s.settingsActive
        || (Prefs.widgetsEnabled && WidgetsStore.ready && WidgetsStore.isEnabled("system"))
        || Prefs.systemLoadOnIsland

    // ── Форматирование ────────────────────────────────────────────────
    function formatBytes(bytes) {
        if (!isFinite(bytes) || bytes <= 0)
            return "0 Б";
        if (bytes >= 1073741824)
            return (bytes / 1073741824).toFixed(1) + " ГБ";
        if (bytes >= 1048576)
            return Math.round(bytes / 1048576) + " МБ";
        if (bytes >= 1024)
            return Math.round(bytes / 1024) + " КБ";
        return Math.round(bytes) + " Б";
    }

    function formatRate(b) {
        if (!isFinite(b) || b <= 0)
            return "0 КБ/с";
        if (b >= 1073741824)
            return (b / 1073741824).toFixed(2) + " ГБ/с";
        if (b >= 1048576)
            return (b / 1048576).toFixed(1) + " МБ/с";
        if (b >= 1024)
            return (b / 1024).toFixed(1) + " КБ/с";
        return Math.round(b) + " Б/с";
    }

    function formatUptime(sec) {
        const total = Math.max(0, Math.floor(sec || 0));
        const d = Math.floor(total / 86400);
        const h = Math.floor((total % 86400) / 3600);
        const m = Math.floor((total % 3600) / 60);
        const rem = total % 60;
        const pad = n => String(n).padStart(2, "0");
        if (d > 0)
            return d + ":" + pad(h) + ":" + pad(m) + ":" + pad(rem);
        return pad(h) + ":" + pad(m) + ":" + pad(rem);
    }

    // ── Внутренние буферы дельт и историй ─────────────────────────────
    property var _prevCpu: null
    property var _prevCores: null
    property var _tempsBuf: []
    property var _coreLoadsBuf: []
    property bool _hadStatCpu: false
    property real _fallbackPcpuSum: 0

    property double _prevNetTime: 0
    property real _prevNetRx: 0
    property real _prevNetTx: 0

    property double _prevDiskTime: 0
    property real _prevDiskRead: 0
    property real _prevDiskWrite: 0
    property real _prevDiskTicks: 0

    property var _netRxRaw: {
        const a = [];
        for (let i = 0; i < 60; i++) a.push(0);
        return a;
    }
    property var _netTxRaw: {
        const a = [];
        for (let i = 0; i < 60; i++) a.push(0);
        return a;
    }
    property var _diskReadRaw: {
        const a = [];
        for (let i = 0; i < 60; i++) a.push(0);
        return a;
    }
    property var _diskWriteRaw: {
        const a = [];
        for (let i = 0; i < 60; i++) a.push(0);
        return a;
    }
    property var _diskBusyRaw: {
        const a = [];
        for (let i = 0; i < 60; i++) a.push(0);
        return a;
    }

    function _cpuTick(line) {
        // user nice system idle iowait irq softirq steal
        const v = line.split(/\s+/).filter(x => x !== "").slice(0, 8).map(Number);
        if (v.length < 8)
            return;

        s._hadStatCpu = true;
        const total = v.reduce((a, b) => a + b, 0);
        const idle = v[3] + (v[4] || 0);
        if (s._prevCpu) {
            const dt = total - s._prevCpu.total;
            const di = idle - s._prevCpu.idle;
            if (dt > 0)
                s.cpu = Math.max(0, Math.min(1, 1 - di / dt));
        }
        s._prevCpu = { total: total, idle: idle };
    }

    function _line(line) {
        if (line.startsWith("CPU ")) {
            s._cpuTick(line.slice(4));
        } else if (line.startsWith("MEM ")) {
            const p = line.split(/\s+/);
            const mt = (+p[1] || 0) * 1024;
            const ma = (+p[2] || 0) * 1024;
            s.memTotal = mt;
            s.memAvailable = ma;
            s.memUsed = Math.max(0, mt - ma);
            if (p.length >= 10) {
                s.memFree = (+p[3] || 0) * 1024;
                s.memBuffers = (+p[4] || 0) * 1024;
                s.memCached = (+p[5] || 0) * 1024;
                s.memDirty = (+p[6] || 0) * 1024;
                s.memShared = (+p[7] || 0) * 1024;
                const st = (+p[8] || 0) * 1024;
                const sf = (+p[9] || 0) * 1024;
                s.swapTotal = st;
                s.swapUsed = Math.max(0, st - sf);
            }
        } else if (line.startsWith("DISK ")) {
            const p = line.split(/\s+/);
            s.diskTotal = +p[1] || 0;
            s.diskUsed = +p[2] || 0;
        } else if (line.startsWith("DISKIO ")) {
            const p = line.split(/\s+/);
            const r = +p[1] || 0;
            const w = +p[2] || 0;
            const t = +p[3] || 0;
            const now = Date.now();
            if (s._prevDiskTime > 0) {
                const dt = (now - s._prevDiskTime) / 1000;
                if (dt > 0.2) {
                    s.diskReadRate = Math.max(0, (r - s._prevDiskRead) / dt);
                    s.diskWriteRate = Math.max(0, (w - s._prevDiskWrite) / dt);
                    s.diskBusy = Math.max(0, Math.min(1, (t - s._prevDiskTicks) / (dt * 1000)));
                }
            }
            s._prevDiskTime = now;
            s._prevDiskRead = r;
            s._prevDiskWrite = w;
            s._prevDiskTicks = t;
            s.diskTotalRead = r;
            s.diskTotalWrite = w;
        } else if (line.startsWith("TZ ")) {
            const t = +(line.slice(3));
            s.tempC = t > 1000 ? t / 1000 : (t > 0 ? t : -1);
        } else if (line.startsWith("GPUB ")) {
            s.gpuBusy = Math.max(0, Math.min(1, (+line.slice(5)) / 100));
            s.gpuLoadAvailable = true;
        } else if (line.startsWith("VRAM ")) {
            const p = line.split(/\s+/);
            s.vramUsed = +p[1] || 0;
            s.vramTotal = +p[2] || 0;
        } else if (line.startsWith("GTEMP ")) {
            const g = +(line.slice(6));
            s.gpuTempC = g > 1000 ? g / 1000 : (g > 0 ? g : -1);
        } else if (line.startsWith("GPOW ")) {
            const w = +(line.slice(5));
            s.gpuPowerW = w > 0 ? w / 1000000 : -1;
        } else if (line.startsWith("LOAD ")) {
            const p = line.slice(5).trim().split(/\s+/);
            if (p.length >= 3 && p[0] !== "") {
                s.load1 = +p[0] || 0;
                s.load5 = +p[1] || 0;
                s.load15 = +p[2] || 0;
                if (p[3] && p[3].indexOf("/") !== -1) {
                    const rt = p[3].split("/");
                    s.cpuProcsRunning = +rt[0] || 0;
                    s.cpuThreadsTotal = +rt[1] || 0;
                }
            }
        } else if (line.startsWith("PROCS ")) {
            const p = line.slice(6).trim().split(/\s+/);
            s.procCount = +p[0] || 0;
            if (p.length >= 3) {
                if (s.cpuProcsRunning <= 0 || (+p[1] > 0))
                    s.cpuProcsRunning = +p[1] || 0;
                if (s.cpuThreadsTotal <= 0 || (+p[2] > 0))
                    s.cpuThreadsTotal = +p[2] || 0;
            }
            if (p.length >= 4)
                s._fallbackPcpuSum = +p[3] || 0;
        } else if (line.startsWith("CPUF ")) {
            const p = line.slice(5).trim().split(/\s+/).filter(x => x !== "").map(Number);
            if (p.length >= 2) {
                const maxM = p[0] || 0;
                const baseM = p[1] || 0;
                const perCore = p.slice(2);
                if (maxM > 0)
                    s.cpuMaxMhz = maxM;
                if (baseM > 0)
                    s.cpuBaseMhz = baseM;
                else if (s.cpuBaseMhz <= 0 && maxM > 0)
                    s.cpuBaseMhz = maxM;
                if (perCore.length > 0) {
                    s.coreMhz = perCore;
                    let sum = 0;
                    let cnt = 0;
                    for (let i = 0; i < perCore.length; i++) {
                        if (perCore[i] > 0) {
                            sum += perCore[i];
                            cnt++;
                        }
                    }
                    if (cnt > 0)
                        s.cpuCurMhz = Math.round(sum / cnt);
                }
            }
        } else if (line.startsWith("GCLK ")) {
            s.gpuSclkMhz = +line.slice(5) || 0;
        } else if (line.startsWith("GFAN ")) {
            s.gpuFanRpm = +line.slice(5) || 0;
        } else if (line.startsWith("CORES ")) {
            const c = +line.slice(6) || 0;
            if (c > 0) {
                s.cores = c;
                if (s.physicalCores <= 0)
                    s.physicalCores = c;
            }
        } else if (line.startsWith("DISKS ")) {
            const chunks = line.slice(6).split("|");
            const out = [];
            for (const ch of chunks) {
                const f = ch.trim().split(/\s+/);
                if (f.length >= 6) {
                    out.push({
                        mount: f[0],
                        device: f[1],
                        fstype: f[2],
                        total: +f[3] || 0,
                        used: +f[4] || 0,
                        avail: +f[5] || 0
                    });
                } else if (f.length >= 3) {
                    const tot = +f[1] || 0;
                    const usd = +f[2] || 0;
                    out.push({
                        mount: f[0],
                        device: "",
                        fstype: "",
                        total: tot,
                        used: usd,
                        avail: Math.max(0, tot - usd)
                    });
                }
            }
            s.disks = out;
        } else if (line.startsWith("TEMP ")) {
            const p = line.slice(5).split("|");
            let v = +p[2];
            if (isNaN(v))
                return;
            if (v > 1000) v /= 1000;
            s._tempsBuf.push({ name: p[0] || "", label: p[1] || "", c: v });
        } else if (line.startsWith("CORE ")) {
            const v = line.slice(5).split(/\s+/).filter(x => x !== "").slice(0, 8).map(Number);
            if (v.length < 8)
                return;
            const total = v.reduce((a, b) => a + b, 0);
            const idle = v[3] + (v[4] || 0);
            const idx = s._coreLoadsBuf.length;
            const prev = s._prevCores ? s._prevCores[idx] : null;
            let load = 0;
            if (prev) {
                const dt = total - prev.total;
                const di = idle - prev.idle;
                if (dt > 0)
                    load = Math.max(0, Math.min(1, 1 - di / dt));
            }
            s._coreLoadsBuf.push(load);
            const pc = s._prevCores ? s._prevCores.slice() : [];
            pc[idx] = { total: total, idle: idle };
            s._prevCores = pc;
        } else if (line.startsWith("NET ")) {
            const p = line.trim().split(/\s+/);
            const rx = +p[1] || 0;
            const tx = +p[2] || 0;
            if (p[3] && s.netIface === "")
                s.netIface = p[3];
            const now = Date.now();
            if (s._prevNetTime > 0 && (rx >= s._prevNetRx) && (tx >= s._prevNetTx)) {
                const dt = (now - s._prevNetTime) / 1000;
                if (dt > 0.2) {
                    s.netRx = Math.max(0, (rx - s._prevNetRx) / dt);
                    s.netTx = Math.max(0, (tx - s._prevNetTx) / dt);
                }
            }
            s._prevNetTime = now;
            s._prevNetRx = rx;
            s._prevNetTx = tx;
            s.netTotalRx = rx;
            s.netTotalTx = tx;
        } else if (line.startsWith("NETIP ")) {
            const p = line.slice(6).trim().split(/\s+/);
            if (p[0])
                s.netIface = p[0];
            if (p[1])
                s.netIp = p[1];
        } else if (line.startsWith("UP ")) {
            const u = +line.slice(3);
            if (u > 0)
                s.uptime = u;
        } else if (line.startsWith("HOST ")) {
            s.host = line.slice(5).trim();
        } else if (line.startsWith("KERN ")) {
            s.kernel = line.slice(5).trim();
        } else if (line.startsWith("RSS ")) {
            s.shellRss = +line.slice(4) || 0;
        }
    }

    function _pushHistories() {
        // Если /proc/stat недоступен (например, в контейнере), оцениваем загрузку из ps pcpu
        if (!s._hadStatCpu && s.cores > 0) {
            s.cpu = Math.max(0, Math.min(1, s._fallbackPcpuSum / (s.cores * 100)));
        }

        let loads = s._coreLoadsBuf;
        if (loads.length === 0 && s.cores > 0) {
            const fallback = [];
            for (let i = 0; i < s.cores; i++) {
                const mhz = (s.coreMhz && i < s.coreMhz.length) ? s.coreMhz[i] : 0;
                const fRatio = (s.cpuMaxMhz > 0 && mhz > 0) ? (mhz / s.cpuMaxMhz) : s.cpu;
                fallback.push(Math.max(0, Math.min(1, s.cpu * 0.65 + fRatio * 0.35)));
            }
            loads = fallback;
        }
        s.coreLoads = loads;

        // 1. cpuHistory (60 точек 0..1)
        const ch = s.cpuHistory.length === 60 ? s.cpuHistory.slice(1) : new Array(59).fill(0);
        ch.push(Math.max(0, Math.min(1, s.cpu || 0)));
        s.cpuHistory = ch;

        // 2. coreHistories (по 30 точек 0..1 на логическое ядро)
        const nCores = Math.max(s.cores, loads.length);
        const nextCores = [];
        for (let i = 0; i < nCores; i++) {
            const prev = (s.coreHistories && s.coreHistories[i] && s.coreHistories[i].length === 30)
                ? s.coreHistories[i].slice(1)
                : new Array(29).fill(0);
            const lv = i < loads.length ? loads[i] : s.cpu;
            prev.push(Math.max(0, Math.min(1, lv || 0)));
            nextCores.push(prev);
        }
        s.coreHistories = nextCores;

        // 3. memHistory (60 точек 0..1)
        const mh = s.memHistory.length === 60 ? s.memHistory.slice(1) : new Array(59).fill(0);
        mh.push(Math.max(0, Math.min(1, s.memFrac || 0)));
        s.memHistory = mh;

        // 4. gpuHistory (60 точек 0..1)
        const gh = s.gpuHistory.length === 60 ? s.gpuHistory.slice(1) : new Array(59).fill(0);
        gh.push(Math.max(0, Math.min(1, s.gpuBusy || 0)));
        s.gpuHistory = gh;

        // 5. netRxHistory & netTxHistory (60 точек 0..1, нормированных по пику окна)
        const rxRaw = s._netRxRaw.length === 60 ? s._netRxRaw.slice(1) : new Array(59).fill(0);
        const txRaw = s._netTxRaw.length === 60 ? s._netTxRaw.slice(1) : new Array(59).fill(0);
        rxRaw.push(Math.max(0, s.netRx || 0));
        txRaw.push(Math.max(0, s.netTx || 0));
        s._netRxRaw = rxRaw;
        s._netTxRaw = txRaw;
        let maxNet = 65536; // минимум 64 КБ/с
        for (let i = 0; i < 60; i++) {
            if (rxRaw[i] > maxNet) maxNet = rxRaw[i];
            if (txRaw[i] > maxNet) maxNet = txRaw[i];
        }
        s.netScaleMax = maxNet;
        s.netRxHistory = rxRaw.map(v => Math.max(0, Math.min(1, v / maxNet)));
        s.netTxHistory = txRaw.map(v => Math.max(0, Math.min(1, v / maxNet)));

        // 6. diskIoHistory, diskReadHistory, diskWriteHistory (60 точек 0..1)
        const drRaw = s._diskReadRaw.length === 60 ? s._diskReadRaw.slice(1) : new Array(59).fill(0);
        const dwRaw = s._diskWriteRaw.length === 60 ? s._diskWriteRaw.slice(1) : new Array(59).fill(0);
        const dbRaw = s._diskBusyRaw.length === 60 ? s._diskBusyRaw.slice(1) : new Array(59).fill(0);
        drRaw.push(Math.max(0, s.diskReadRate || 0));
        dwRaw.push(Math.max(0, s.diskWriteRate || 0));
        dbRaw.push(Math.max(0, Math.min(1, s.diskBusy || 0)));
        s._diskReadRaw = drRaw;
        s._diskWriteRaw = dwRaw;
        s._diskBusyRaw = dbRaw;
        let maxDisk = 1048576; // минимум 1 МБ/с
        for (let i = 0; i < 60; i++) {
            if (drRaw[i] + dwRaw[i] > maxDisk) maxDisk = drRaw[i] + dwRaw[i];
        }
        s.diskScaleMax = maxDisk;
        s.diskReadHistory = drRaw.map(v => Math.max(0, Math.min(1, v / maxDisk)));
        s.diskWriteHistory = dwRaw.map(v => Math.max(0, Math.min(1, v / maxDisk)));
        const dio = [];
        for (let i = 0; i < 60; i++) {
            const rateFrac = Math.min(1, (drRaw[i] + dwRaw[i]) / maxDisk);
            dio.push(Math.max(dbRaw[i], rateFrac));
        }
        s.diskIoHistory = dio;
    }

    Process {
        id: proc
        command: ["sh", "-c",
            "echo \"CPU $(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat 2>/dev/null)\"; " +
            "awk '/^MemTotal:/{mt=$2}/^MemAvailable:/{ma=$2}/^MemFree:/{mf=$2}/^Buffers:/{mb=$2}/^Cached:/{mc=$2}/^Dirty:/{md=$2}/^Shmem:/{ms=$2}/^SwapTotal:/{st=$2}/^SwapFree:/{sf=$2}END{printf \"MEM %d %d %d %d %d %d %d %d %d\\n\", mt+0, ma+0, mf+0, mb+0, mc+0, md+0, ms+0, st+0, sf+0}' /proc/meminfo 2>/dev/null; " +
            "echo \"DISK $(df -B1 \"$HOME\" 2>/dev/null | awk 'NR==2{print $2,$3}')\"; " +
            "awk '$3 ~ /^(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+|hd[a-z]+|mmcblk[0-9]+|dm-[0-9]+)$/{r+=$6*512; w+=$10*512; t+=$13} END{printf \"DISKIO %d %d %d\\n\", r+0, w+0, t+0}' /proc/diskstats 2>/dev/null; " +
            "echo \"UP $(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)\"; " +
            "echo \"HOST $(uname -n 2>/dev/null)\"; " +
            "echo \"KERN $(uname -r 2>/dev/null)\"; " +
            "awk '/^VmRSS:/{print \"RSS\", $2 * 1024; exit}' /proc/$PPID/status 2>/dev/null; " +
            "T=$(for z in /sys/class/thermal/thermal_zone*/temp; do [ -r \"$z\" ] && cat \"$z\" && break; done); echo \"TZ ${T:-0}\"; " +
            "B=$(for f in /sys/class/drm/card[0-9]*/device/gpu_busy_percent; do [ -r \"$f\" ] && cat \"$f\" && break; done); [ -n \"$B\" ] && echo \"GPUB $B\"; " +
            "V=$(for f in /sys/class/drm/card[0-9]*/device/mem_info_vram_used; do [ -r \"$f\" ] && cat \"$f\" && break; done); " +
            "V2=$(for f in /sys/class/drm/card[0-9]*/device/mem_info_vram_total; do [ -r \"$f\" ] && cat \"$f\" && break; done); echo \"VRAM ${V:-0} ${V2:-0}\"; " +
            "GT=$(for f in /sys/class/drm/card[0-9]*/device/hwmon/hwmon*/temp1_input; do [ -r \"$f\" ] && cat \"$f\" && break; done); echo \"GTEMP ${GT:-0}\"; " +
            "GP=$(for f in /sys/class/drm/card[0-9]*/device/hwmon/hwmon*/power1_average /sys/class/drm/card[0-9]*/device/hwmon/hwmon*/power1_input; do [ -r \"$f\" ] && cat \"$f\" && break; done); echo \"GPOW ${GP:-0}\"; " +
            "L=$(cat /proc/loadavg 2>/dev/null); echo \"LOAD $L\"; " +
            "ps -eo nlwp=,stat=,pcpu= 2>/dev/null | awk '{t+=$1; if($2~/^[Rr]/) r++; n++; c+=$3} END{printf \"PROCS %d %d %d %.1f\\n\", n+0, r+0, t+0, c+0}'; " +
            "i=0; freqs=''; maxf=0; basef=0; while [ -d \"/sys/devices/system/cpu/cpu$i\" ]; do cf=$(cat \"/sys/devices/system/cpu/cpu$i/cpufreq/scaling_cur_freq\" 2>/dev/null || echo 0); mf=$(cat \"/sys/devices/system/cpu/cpu$i/cpufreq/cpuinfo_max_freq\" 2>/dev/null || echo 0); bf=$(cat \"/sys/devices/system/cpu/cpu$i/cpufreq/base_frequency\" 2>/dev/null || cat \"/sys/devices/system/cpu/cpu$i/cpufreq/bios_limit\" 2>/dev/null || echo 0); freqs=\"$freqs $((cf / 1000))\"; [ \"${mf:-0}\" -gt \"$maxf\" ] 2>/dev/null && maxf=\"$mf\"; [ \"${bf:-0}\" -gt \"$basef\" ] 2>/dev/null && basef=\"$bf\"; i=$((i + 1)); done; echo \"CPUF $((maxf / 1000)) $((basef / 1000))$freqs\"; " +
            "GS=$(for f in /sys/class/drm/card[0-9]*/device/pp_dpm_sclk; do [ -r \"$f\" ] && awk '/[*]/{print $2; exit}' \"$f\" && break; done | tr -dc 0-9); echo \"GCLK ${GS:-0}\"; " +
            "GF=$(for f in /sys/class/drm/card[0-9]*/device/hwmon/hwmon*/fan1_input; do [ -r \"$f\" ] && cat \"$f\" && break; done); echo \"GFAN ${GF:-0}\"; " +
            "echo \"CORES $(nproc 2>/dev/null || echo 0)\"; " +
            "echo \"DISKS $(df -B1 -x tmpfs -x devtmpfs -x squashfs -x efivarfs -x overlay -x bind --output=target,source,fstype,size,used,avail 2>/dev/null | tail -n +2 | grep '^/' | paste -sd'|' -)\"; " +
            "for d in /sys/class/hwmon/hwmon*; do n=$(cat \"$d/name\" 2>/dev/null); for f in \"$d\"/temp*_input; do [ -r \"$f\" ] || continue; l=\"${f%_input}_label\"; lab=''; [ -r \"$l\" ] && lab=$(cat \"$l\" 2>/dev/null); printf 'TEMP %s|%s|%s\\n' \"$n\" \"$lab\" \"$(cat \"$f\")\"; done; done; " +
            "awk '/^cpu[0-9]/{print \"CORE\", $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat 2>/dev/null; " +
            "awk 'NR>2 && $1 !~ /^lo:/{gsub(/:/, \"\", $1); rx+=$2; tx+=$10; if ($2 > brx || ifc == \"\") { brx=$2; ifc=$1 }} END{printf \"NET %d %d %s\\n\", rx+0, tx+0, ifc}' /proc/net/dev 2>/dev/null; " +
            "ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/\\/.*/, \"\", $4); printf \"NETIP %s %s\\n\", $2, $4; exit}'"]
        stdout: SplitParser {
            onRead: line => s._line(line)
        }
        onExited: {
            s.temps = s._tempsBuf;
            s._pushHistories();
        }
    }

    // Статичная информация о железе и системе
    Process {
        id: staticProc
        running: true
        command: ["sh", "-c",
            "echo \"DISTRO $(. /etc/os-release 2>/dev/null; printf '%s' \"$PRETTY_NAME\")\"; " +
            "M=$(awk -F: '/model name/{gsub(/^ +/,\"\",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null); " +
            "[ -z \"$M\" ] && M=$(lscpu 2>/dev/null | awk -F: '/Model name|Имя модели/{gsub(/^ +/,\"\",$2); if(o!=\"\") o=o \" / \"; o=o $2} END{print o}'); " +
            "echo \"CPU $M\"; " +
            "G=$(lspci 2>/dev/null | grep -iE 'vga|3d controller' | head -1 | cut -d: -f3- | sed 's/^ //'); echo \"GPU ${G:-}\"; " +
            "L3=$(cat /sys/devices/system/cpu/cpu0/cache/index3/size 2>/dev/null || cat /sys/devices/system/cpu/cpu0/cache/index2/size 2>/dev/null || awk -F: '/cache size/{gsub(/^ +/,\"\",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null); echo \"L3 ${L3:-}\"; " +
            "if grep -qiE '\\bvmx\\b' /proc/cpuinfo 2>/dev/null; then V='VT-x (Включено)'; " +
            "elif grep -qiE '\\bsvm\\b' /proc/cpuinfo 2>/dev/null; then V='AMD-V (Включено)'; " +
            "elif grep -qiE '\\bhypervisor\\b' /proc/cpuinfo 2>/dev/null; then V='Гипервизор'; " +
            "else V='Включено'; fi; echo \"VIRT $V\"; " +
            "PC=$(awk -F: '/^cpu cores/{gsub(/ /,\"\",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null); echo \"PCORES ${PC:-0}\""]
        stdout: SplitParser {
            onRead: line => s._staticLine(line)
        }
    }

    function _staticLine(line) {
        if (line.startsWith("DISTRO "))
            s.distro = line.slice(7).trim();
        else if (line.startsWith("CPU ")) {
            const m = line.slice(4).trim();
            if (m !== "")
                s.cpuModel = m;
        } else if (line.startsWith("GPU "))
            s.gpuModel = line.slice(4).trim();
        else if (line.startsWith("L3 "))
            s.cpuCacheL3 = line.slice(3).trim();
        else if (line.startsWith("VIRT "))
            s.cpuVirt = line.slice(5).trim();
        else if (line.startsWith("PCORES ")) {
            const pc = +line.slice(7) || 0;
            if (pc > 0)
                s.physicalCores = pc;
        }
    }

    Timer {
        interval: s.taskmanActive ? 1000 : (s.settingsActive ? 2000 : 3000)
        running: s.active
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!s.active || proc.running)
                return;
            if (s.uptime > 0)
                s.uptime += Math.round(interval / 1000);
            s._tempsBuf = [];
            s._coreLoadsBuf = [];
            s._hadStatCpu = false;
            s.gpuLoadAvailable = false;
            proc.running = true;
        }
    }
}
