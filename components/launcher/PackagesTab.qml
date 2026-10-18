import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../core"
import "../../ui"

// Вкладка «Пакеты» — полноценный мастер-детейл менеджер пакетов Arch & AUR:
//  • Верхняя панель навигации с 3 явными режимами:
//      1. «Установленные» (GUI-приложения или все явно установленные `pacman -Qe`)
//      2. «Поиск в репо» (официальные репозитории Arch + AUR через `paru -Ss` / `pacman -Ss`)
//      3. «Обновления» (`checkupdates` + `paru -Qua` со счётчиком и версиями старая → новая)
//  • Двухколоночный Master-Detail интерфейс:
//      Слева — быстрый список пакетов с бейджами репозитория, статуса и быстрой кнопкой действия.
//      Справа — постоянная карточка-инспектор с полными метаданными (`pacman -Qi` / `paru -Si`),
//      зависимостями, ссылками (ArchWeb, AUR, Сайт) и кнопками управления.
ColumnLayout {
    id: tab

    property string query: ""
    property int sel: 0
    property var shell: null
    property bool active: false
    property int workspaceHeight: Theme.dp(440)

    signal hovered(int index)
    signal selectionRequested(int index)

    // ── состояние навигации и фильтров ────────────────────────────────
    // "installed" | "repo" | "updates"
    property string subTab: "installed"
    // для вкладки "installed": "apps" (GUI DesktopEntries) | "all" (pacman -Qe)
    property string installedScope: "apps"
    // для вкладки "repo": "all" | "official" | "aur"
    property string repoFilter: "all"
    property bool onlyUninstalled: false

    // ── данные пакетов ────────────────────────────────────────────────
    property var results: []            // результаты поиска в репо
    property int repoUpdates: 0
    property int aurUpdates: 0
    property var updatesList: []        // [{pkg, oldVer, newVer, repo, aur}]
    property var aurList: []            // [{pkg, oldVer, newVer, repo, aur}]
    property string pending: ""         // пакет, ожидающий подтверждения удаления
    property bool searching: false
    property bool checkingRepoUpdates: false
    property bool checkingAurUpdates: false
    readonly property bool checkingUpdates: tab.checkingRepoUpdates || tab.checkingAurUpdates
    property int _cur: -1
    property string lastSearchedQuery: ""

    // ── базы установленных пакетов (загружаются пакетом при открытии) ─
    property var installedSet: ({})      // pkg → true (все установленные `pacman -Q`)
    property var installedVersions: ({}) // pkg → version
    property var explicitList: []        // [{pkg, version}] из `pacman -Qe`
    property var aurSet: ({})            // pkg → true из `pacman -Qm` + AUR RPC
    property var repoMap: ({})           // pkg → repo ("core"/"extra"/"multilib") из `pacman -Sl`

    property var _instSetAcc: ({})
    property var _instVerAcc: ({})
    property var _explicitAcc: []
    property var _aurSetAcc: ({})
    property bool _installedLoaded: false
    property bool _installedStarted: false

    // ── кэш деталей (`pacman -Qi` / `paru -Si`) и AUR RPC ─────────────
    property bool detailsOpen: tab.pending !== ""
    property var qiCache: ({})           // key ("qi:pkg" / "si:pkg") → {data: {...}, code: int}
    property var qiData: ({})
    property string qiKey: ""
    property string _qiField: ""
    property var aurGitCache: ({})       // pkg → homepage URL
    property string aurGitName: ""
    property bool _aurWantOpen: false

    readonly property int totalUpdates: tab.repoUpdates + tab.aurUpdates

    // ── индекс иконок и метаданных из DesktopEntries ──────────────────
    readonly property var desktopMetaIndex: {
        const byPkg = {};
        for (const e of DesktopEntries.applications.values) {
            const iconName = e.icon ? String(e.icon) : "";
            const title = String(e.name || "");
            const comment = String(e.genericName || e.comment || "");
            if (e.id) {
                let id = String(e.id);
                if (id.endsWith(".desktop")) id = id.slice(0, -8);
                if (id) {
                    const k = id.toLowerCase();
                    if (!byPkg[k]) byPkg[k] = { icon: iconName, title: title, comment: comment };
                }
            }
            const base = tab._cmdBasename(e);
            if (base) {
                const k = base.toLowerCase();
                if (!byPkg[k]) byPkg[k] = { icon: iconName, title: title, comment: comment };
            }
        }
        return byPkg;
    }

    function iconForPkg(name) {
        const k = String(name || "").toLowerCase();
        if (k === "") return "";
        const meta = tab.desktopMetaIndex[k];
        if (!meta || !meta.icon) return "";
        return Quickshell.iconPath(meta.icon, true) || "";
    }

    function commentForPkg(name) {
        const k = String(name || "").toLowerCase();
        if (k === "") return "";
        const meta = tab.desktopMetaIndex[k];
        return meta ? (meta.comment || meta.title || "") : "";
    }

    function _cmdBasename(e) {
        let first = "";
        if (Array.isArray(e.command) && e.command.length > 0) first = String(e.command[0]);
        else {
            const s = String(e.execString || e.command || "").trim();
            first = s.split(/\s+/)[0] || "";
        }
        if (first === "env") {
            const tok = String(e.execString || "").trim().split(/\s+/);
            for (let i = 1; i < tok.length; i++) {
                if (tok[i].indexOf("=") === -1) { first = tok[i]; break; }
            }
        }
        return first.split("/").pop();
    }

    function _pkgForEntry(e) {
        const inst = tab.installedSet;
        let id = "";
        if (e.id) {
            id = String(e.id);
            if (id.endsWith(".desktop")) id = id.slice(0, -8);
        }
        if (id !== "" && inst[id]) return id;
        if (id !== "" && inst[id.toLowerCase()]) return id.toLowerCase();
        const base = tab._cmdBasename(e);
        if (base && inst[base]) return base;
        if (base && inst[base.toLowerCase()]) return base.toLowerCase();
        return "";
    }

    // ── списки для каждого режима ─────────────────────────────────────
    // 1a. Установленные GUI-приложения
    readonly property var appsList: {
        const inst = tab.installedSet;
        const vers = tab.installedVersions;
        const aurs = tab.aurSet;
        const out = [];
        const seen = {};
        for (const e of DesktopEntries.applications.values) {
            const pkg = tab._pkgForEntry(e);
            if (!pkg || seen[pkg]) continue;
            seen[pkg] = true;
            const icon = e.icon ? (Quickshell.iconPath(String(e.icon), true) || "") : "";
            const isAur = aurs[pkg] === true;
            const desc = String(e.genericName || e.comment || pkg);
            out.push({
                pkg: pkg,
                title: String(e.name || pkg),
                subtitle: desc !== String(e.name || pkg) ? desc : pkg,
                repo: isAur ? "aur" : "installed",
                version: vers[pkg] || "",
                oldVer: "",
                newVer: "",
                installed: true,
                aur: isAur,
                hasUpdate: tab.updatesByPkg[pkg] !== undefined,
                icon: icon,
                votes: undefined,
                popularity: undefined
            });
        }
        out.sort((a, b) => a.title.localeCompare(b.title, "ru"));
        return out;
    }

    // 1b. Все явно установленные пакеты (`pacman -Qe`)
    readonly property var allInstalledList: {
        const aurs = tab.aurSet;
        const out = [];
        for (let i = 0; i < tab.explicitList.length; i++) {
            const item = tab.explicitList[i];
            const pkg = item.pkg;
            const isAur = aurs[pkg] === true;
            const meta = tab.desktopMetaIndex[pkg.toLowerCase()];
            const icon = meta && meta.icon ? (Quickshell.iconPath(meta.icon, true) || "") : "";
            const title = meta && meta.title ? (meta.title + " (" + pkg + ")") : pkg;
            const cachedQi = tab.qiCache["qi:" + pkg];
            const qiDesc = cachedQi && cachedQi.data ? String(cachedQi.data["Description"] || "") : "";
            const sub = qiDesc || (meta && meta.comment ? meta.comment : (isAur ? "Пакет из AUR" : "Установленный пакет"));
            out.push({
                pkg: pkg,
                title: title,
                subtitle: sub,
                repo: isAur ? "aur" : "local",
                version: item.version || tab.installedVersions[pkg] || "",
                oldVer: "",
                newVer: "",
                installed: true,
                aur: isAur,
                hasUpdate: tab.updatesByPkg[pkg] !== undefined,
                icon: icon,
                votes: undefined,
                popularity: undefined
            });
        }
        return out;
    }

    // Отфильтрованный список для вкладки "installed"
    readonly property var filteredInstalledList: {
        const base = tab.installedScope === "apps" ? tab.appsList : tab.allInstalledList;
        const q = tab.query.trim().toLowerCase();
        if (q === "") return base;
        return base.filter((it) => {
            return it.pkg.toLowerCase().indexOf(q) !== -1
                || it.title.toLowerCase().indexOf(q) !== -1
                || (it.subtitle && it.subtitle.toLowerCase().indexOf(q) !== -1);
        });
    }

    // 2. Отфильтрованный список для вкладки "repo"
    readonly property var filteredRepoList: {
        const out = [];
        for (let i = 0; i < tab.results.length; i++) {
            const r = tab.results[i];
            if (tab.repoFilter === "official" && r.aur) continue;
            if (tab.repoFilter === "aur" && !r.aur) continue;
            const isInst = r.installed || tab.installedSet[r.name] === true;
            if (tab.onlyUninstalled && isInst) continue;
            out.push({
                pkg: r.name,
                title: r.name,
                subtitle: r.desc || (r.aur ? "Пакет AUR" : "Пакет репозитория " + r.repo),
                repo: r.repo,
                version: r.version,
                oldVer: "",
                newVer: "",
                installed: isInst,
                aur: r.aur,
                hasUpdate: tab.updatesByPkg[r.name] !== undefined,
                icon: tab.iconForPkg(r.name),
                votes: r.votes,
                popularity: r.popularity
            });
        }
        return out;
    }

    // 3. Список обновлений (`checkupdates` + `paru -Qua`)
    readonly property var combinedUpdatesList: tab.updatesList.concat(tab.aurList)
    readonly property var updatesByPkg: {
        const map = {};
        for (let i = 0; i < tab.combinedUpdatesList.length; i++) {
            const u = tab.combinedUpdatesList[i];
            map[u.pkg] = u;
        }
        return map;
    }

    readonly property var filteredUpdatesList: {
        const q = tab.query.trim().toLowerCase();
        const out = [];
        for (let i = 0; i < tab.combinedUpdatesList.length; i++) {
            const u = tab.combinedUpdatesList[i];
            if (q !== "" && u.pkg.toLowerCase().indexOf(q) === -1) continue;
            const cachedQi = tab.qiCache["qi:" + u.pkg];
            const qiDesc = cachedQi && cachedQi.data ? String(cachedQi.data["Description"] || "") : "";
            out.push({
                pkg: u.pkg,
                title: u.pkg,
                subtitle: qiDesc || tab.commentForPkg(u.pkg) || ("Доступно обновление: " + u.oldVer + " → " + u.newVer),
                repo: u.aur ? "aur" : "repo",
                version: u.newVer,
                oldVer: u.oldVer,
                newVer: u.newVer,
                installed: true,
                aur: u.aur,
                hasUpdate: true,
                icon: tab.iconForPkg(u.pkg),
                votes: undefined,
                popularity: undefined
            });
        }
        return out;
    }

    // Единая модель текущего списка
    readonly property var currentList: {
        if (tab.subTab === "repo") return tab.filteredRepoList;
        if (tab.subTab === "updates") return tab.filteredUpdatesList;
        return tab.filteredInstalledList;
    }

    readonly property int count: tab.currentList.length
    readonly property var selectedItem: (tab.sel >= 0 && tab.sel < tab.currentList.length)
        ? tab.currentList[tab.sel] : null

    // ── данные инспектора для выбранного пакета ───────────────────────
    readonly property string selectedPkg: tab.selectedItem ? tab.selectedItem.pkg : ""
    readonly property bool selectedInstalled: tab.selectedItem ? tab.selectedItem.installed : false
    readonly property bool selectedAur: tab.selectedItem
        ? (tab.selectedItem.aur || tab.aurSet[tab.selectedItem.pkg] === true) : false

    readonly property var detailInfo: {
        if (!tab.selectedItem) return null;
        const pkg = tab.selectedItem.pkg;
        const qi = tab.qiCache["qi:" + pkg];
        if (qi && qi.data && Object.keys(qi.data).length > 0) return qi.data;
        const si = tab.qiCache["si:" + pkg];
        if (si && si.data && Object.keys(si.data).length > 0) return si.data;
        return null;
    }

    readonly property bool detailLoading: tab.selectedItem !== null && tab.detailInfo === null && qiProc.running
    readonly property string dDescription: {
        if (tab.detailInfo && tab.detailInfo["Description"])
            return String(tab.detailInfo["Description"]);
        return tab.selectedItem ? tab.selectedItem.subtitle : "";
    }
    readonly property string dVersion: {
        if (tab.selectedItem && tab.selectedItem.oldVer && tab.selectedItem.newVer)
            return tab.selectedItem.oldVer + " → " + tab.selectedItem.newVer;
        if (tab.detailInfo && tab.detailInfo["Version"])
            return String(tab.detailInfo["Version"]);
        return tab.selectedItem ? tab.selectedItem.version : "";
    }
    readonly property string dRepo: {
        if (tab.detailInfo && tab.detailInfo["Repository"])
            return String(tab.detailInfo["Repository"]);
        if (tab.selectedAur) return "aur";
        if (tab.selectedItem && tab.selectedItem.repo && tab.selectedItem.repo !== "installed" && tab.selectedItem.repo !== "local")
            return tab.selectedItem.repo;
        return "local";
    }
    readonly property string dUrl: {
        if (tab.detailInfo && tab.detailInfo["URL"] && tab.detailInfo["URL"] !== "None")
            return String(tab.detailInfo["URL"]).trim();
        if (tab.selectedPkg && tab.aurGitCache[tab.selectedPkg])
            return String(tab.aurGitCache[tab.selectedPkg]);
        return "";
    }
    readonly property string dSize: {
        if (!tab.detailInfo) return "";
        return String(tab.detailInfo["Installed Size"] || tab.detailInfo["Download Size"] || "");
    }
    readonly property string dDownloadSize: {
        if (!tab.detailInfo) return "";
        return String(tab.detailInfo["Download Size"] || "");
    }
    readonly property string dLicense: {
        if (!tab.detailInfo) return "";
        return String(tab.detailInfo["Licenses"] || "");
    }
    readonly property string dDate: {
        if (!tab.detailInfo) return "";
        return String(tab.detailInfo["Install Date"] || tab.detailInfo["Build Date"] || "");
    }
    readonly property string dPackager: {
        if (!tab.detailInfo) return "";
        return String(tab.detailInfo["Packager"] || tab.detailInfo["Maintainer"] || "");
    }
    readonly property var dDeps: tab.detailInfo ? tab._splitList(tab.detailInfo["Depends On"]) : []
    readonly property var dRequired: tab.detailInfo ? tab._splitList(tab.detailInfo["Required By"]) : []
    readonly property var dOptional: tab.detailInfo ? tab._splitOptional(tab.detailInfo["Optional Deps"]) : []

    function _splitList(v) {
        if (!v) return [];
        const s = String(v).trim();
        if (s === "" || s === "None" || s === "Нет") return [];
        return s.split(/\s+/).filter((x) => x !== "" && x !== "None" && x !== "Нет");
    }

    function _splitOptional(v) {
        if (!v) return [];
        return String(v).split("\n").map((s) => s.trim())
            .filter((s) => s !== "" && s !== "None" && s !== "Нет");
    }

    spacing: Theme.dp(8)

    // ── реактивные обработчики ────────────────────────────────────────
    onSelChanged: {
        tab.pending = "";
        if (tab.sel >= 0 && tab.sel < mainListView.count)
            mainListView.positionViewAtIndex(tab.sel, ListView.Contain);
        tab._ensureSelectedDetails();
    }

    onSelectedItemChanged: {
        tab._ensureSelectedDetails();
    }

    onSubTabChanged: {
        tab.pending = "";
        tab.selectionRequested(0);
        if (tab.subTab === "repo" && tab.query.trim().length >= 2 && tab.query.trim() !== tab.lastSearchedQuery) {
            searchTimer.stop();
            tab.doSearch();
        }
    }

    onQueryChanged: {
        tab.pending = "";
        const q = tab.query.trim();
        if (tab.subTab === "repo") {
            if (q.length < 2) {
                searchTimer.stop();
                if (searchProc.running) searchProc.running = false;
                tab.results = [];
                tab.searching = false;
                tab.lastSearchedQuery = "";
            } else {
                searchTimer.restart();
            }
        }
    }

    onActiveChanged: {
        if (!tab.active) return;
        tab.pending = "";
        tab.loadInstalled();
        tab.refreshUpdates();
        if (tab.subTab === "repo" && tab.query.trim().length >= 2) {
            searchTimer.stop();
            tab.doSearch();
        }
    }

    // ── запуск терминала с автоопределением ───────────────────────────
    function runInTerminal(args) {
        const script =
            'if command -v kitty >/dev/null 2>&1; then exec kitty -e "$@"; ' +
            'elif command -v ghostty >/dev/null 2>&1; then exec ghostty -e "$@"; ' +
            'elif command -v alacritty >/dev/null 2>&1; then exec alacritty -e "$@"; ' +
            'elif command -v foot >/dev/null 2>&1; then exec foot "$@"; ' +
            'elif command -v wezterm >/dev/null 2>&1; then exec wezterm start -- "$@"; ' +
            'elif command -v konsole >/dev/null 2>&1; then exec konsole -e "$@"; ' +
            'elif command -v xdg-terminal-exec >/dev/null 2>&1; then exec xdg-terminal-exec "$@"; ' +
            'fi';
        Quickshell.execDetached(["sh", "-c", script, "sh"].concat(args));
    }

    function openDetails() {
        tab.pending = "";
    }

    function closeDetails() {
        tab.pending = "";
    }

    function switchToRepoSearch() {
        tab.subTab = "repo";
        if (tab.query.trim().length >= 2) {
            searchTimer.stop();
            tab.doSearch();
        }
    }

    // ── загрузка базы установленных пакетов ───────────────────────────
    function loadInstalled(force) {
        if (!force && (tab._installedLoaded || tab._installedStarted)) return;
        tab._installedStarted = true;
        tab._instSetAcc = {};
        tab._instVerAcc = {};
        tab._explicitAcc = [];
        tab._aurSetAcc = {};
        listProc.running = false;
        listProc.running = true;
        explicitProc.running = false;
        explicitProc.running = true;
        foreignProc.running = false;
        foreignProc.running = true;
    }

    function _installedLine(line) {
        const m = String(line).trim().match(/^(\S+)\s+(\S+)/);
        if (!m) return;
        tab._instSetAcc[m[1]] = true;
        tab._instVerAcc[m[1]] = m[2];
    }

    function _installedExit(exitCode) {
        tab.installedSet = tab._instSetAcc;
        tab.installedVersions = tab._instVerAcc;
        tab._installedLoaded = (exitCode === 0);
        tab._installedStarted = false;
        tab._ensureSelectedDetails();
    }

    function _explicitLine(line) {
        const m = String(line).trim().match(/^(\S+)\s+(\S+)/);
        if (!m) return;
        tab._explicitAcc.push({ pkg: m[1], version: m[2] });
    }

    function _explicitExit() {
        tab.explicitList = tab._explicitAcc;
    }

    function _foreignLine(line) {
        const m = String(line).trim().match(/^(\S+)/);
        if (!m) return;
        tab._aurSetAcc[m[1]] = true;
    }

    function _foreignExit() {
        tab.aurSet = Object.assign({}, tab.aurSet, tab._aurSetAcc);
    }

    // ── загрузка деталей пакета (`pacman -Qi` или `paru/pacman -Si`) ──
    function _ensureSelectedDetails() {
        const it = tab.selectedItem;
        if (!it || !it.pkg) return;
        if (it.installed) {
            tab.ensurePkgInfo(it.pkg, true);
        } else {
            tab.ensurePkgInfo(it.pkg, false);
        }
    }

    function ensurePkgInfo(name, isInstalled) {
        if (!name) return;
        const key = (isInstalled ? "qi:" : "si:") + name;
        if (tab.qiCache[key] !== undefined) return;
        if (tab.qiKey === key && qiProc.running) return;
        tab.qiKey = key;
        tab.qiData = {};
        tab._qiField = "";
        if (isInstalled) {
            qiProc.command = ["env", "LC_ALL=C", "pacman", "-Qi", "--", name];
        } else {
            qiProc.command = [
                "sh", "-c",
                'if command -v paru >/dev/null 2>&1; then exec env LC_ALL=C paru -Si -- "$1"; else exec env LC_ALL=C pacman -Si -- "$1"; fi',
                "sh", name
            ];
        }
        qiProc.running = false;
        qiProc.running = true;
    }

    function _qiLine(line) {
        const m = String(line).match(/^([A-Z][A-Za-z ]*?)\s*:\s?(.*)$/);
        if (m) {
            tab._qiField = m[1].trim();
            tab.qiData[tab._qiField] = m[2];
            return;
        }
        if (tab._qiField !== "" && /^\s+\S/.test(line)) {
            tab.qiData[tab._qiField] = String(tab.qiData[tab._qiField] || "")
                + "\n" + String(line).trim();
        }
    }

    function _qiExit(exitCode) {
        const key = tab.qiKey;
        if (!key) return;
        const map = Object.assign({}, tab.qiCache);
        map[key] = { data: tab.qiData, code: exitCode };
        tab.qiCache = map;
    }

    // ── внешние ссылки ────────────────────────────────────────────────
    function openUrl(url) {
        if (!url) return;
        Quickshell.execDetached(["xdg-open", url]);
    }

    function openAur(name) {
        if (!name) return;
        Quickshell.execDetached(["xdg-open", "https://aur.archlinux.org/packages/" + name]);
    }

    function openArch(name) {
        if (!name) return;
        Quickshell.execDetached(["xdg-open", "https://archlinux.org/packages/?q=" + name]);
    }

    function ensureAurInfo(name, openWhenReady) {
        if (!name) return;
        const cached = tab.aurGitCache[name];
        if (cached !== undefined) {
            if (openWhenReady && cached) Quickshell.execDetached(["xdg-open", cached]);
            return;
        }
        if (tab.aurGitName === name && aurInfoProc.running) {
            tab._aurWantOpen = openWhenReady;
            return;
        }
        tab.aurGitName = name;
        tab._aurWantOpen = openWhenReady;
        aurInfoProc.command = ["curl", "-s", "--max-time", "15",
                               "https://aur.archlinux.org/rpc/v5/info?arg[]=" + name];
        aurInfoProc.running = false;
        aurInfoProc.running = true;
    }

    function _aurInfoDone(txt) {
        let url = "";
        let aur = false;
        try {
            const j = JSON.parse(String(txt || ""));
            if (j && j.results && j.results.length > 0) {
                aur = true;
                url = String(j.results[0].URL || "");
            }
        } catch (e) {}
        const name = tab.aurGitName;
        if (name) {
            const map = Object.assign({}, tab.aurGitCache);
            map[name] = url;
            tab.aurGitCache = map;
            const set = Object.assign({}, tab.aurSet);
            set[name] = aur;
            tab.aurSet = set;
        }
        if (url && tab._aurWantOpen) Quickshell.execDetached(["xdg-open", url]);
        tab._aurWantOpen = false;
    }

    // ── поиск в репозиториях и проверка обновлений ────────────────────
    function doSearch() {
        const q = tab.query.trim();
        if (q.length < 2) return;
        tab._cur = -1;
        tab.results = [];
        tab.searching = true;
        tab.lastSearchedQuery = q;
        searchProc.command = [
            "sh", "-c",
            'if command -v paru >/dev/null 2>&1; then exec env LC_ALL=C paru -Ss -- "$1"; else exec env LC_ALL=C pacman -Ss -- "$1"; fi',
            "sh", q
        ];
        searchProc.running = false;
        searchProc.running = true;
    }

    function refreshUpdates() {
        tab.updatesList = [];
        tab.aurList = [];
        tab.repoUpdates = 0;
        tab.aurUpdates = 0;
        tab.checkingRepoUpdates = true;
        tab.checkingAurUpdates = true;
        repoProc.running = false;
        repoProc.running = true;
        aurProc.running = false;
        aurProc.running = true;
    }

    // ── действия с пакетами (установка, обновление, удаление) ─────────
    function updateAll() {
        if (tab.shell) tab.shell.closeOverlays();
        tab._installedLoaded = false;
        tab.runInTerminal([
            "sh", "-c",
            'if command -v paru >/dev/null 2>&1; then exec paru -Syu; else exec sudo pacman -Syu; fi'
        ]);
    }

    function installPackage(pkg, isAur) {
        if (!pkg) return;
        if (tab.shell) tab.shell.closeOverlays();
        tab._installedLoaded = false;
        if (isAur) {
            tab.runInTerminal(["paru", "-S", "--", pkg]);
        } else {
            Quickshell.execDetached(["pkexec", "pacman", "-S", "--noconfirm", "--", pkg]);
        }
    }

    function updatePackage(pkg, isAur) {
        if (!pkg) return;
        if (tab.shell) tab.shell.closeOverlays();
        tab._installedLoaded = false;
        if (isAur) {
            tab.runInTerminal(["paru", "-S", "--", pkg]);
        } else {
            tab.runInTerminal([
                "sh", "-c",
                'if command -v paru >/dev/null 2>&1; then exec paru -S -- "$1"; else exec sudo pacman -S -- "$1"; fi',
                "sh", pkg
            ]);
        }
    }

    function removePackage(pkg, isAur) {
        if (!pkg) return;
        if (tab.pending !== pkg) {
            tab.pending = pkg;
            return;
        }
        if (tab.shell) tab.shell.closeOverlays();
        tab._installedLoaded = false;
        if (isAur) {
            tab.runInTerminal(["paru", "-Rns", "--", pkg]);
        } else {
            Quickshell.execDetached(["pkexec", "pacman", "-Rns", "--noconfirm", "--", pkg]);
        }
        tab.pending = "";
    }

    function removeDetail() {
        if (!tab.selectedItem) return;
        tab.removePackage(tab.selectedItem.pkg, tab.selectedAur);
    }

    function activate(index) {
        if (tab.subTab === "installed" && tab.currentList.length === 0 && tab.query.trim().length >= 2) {
            tab.switchToRepoSearch();
            return;
        }
        const it = tab.currentList[index];
        if (!it) return;
        tab.selectionRequested(index);
        if (tab.subTab === "updates" || it.hasUpdate) {
            tab.updatePackage(it.pkg, it.aur);
            return;
        }
        if (!it.installed) {
            tab.installPackage(it.pkg, it.aur);
            return;
        }
        tab.removePackage(it.pkg, it.aur || tab.aurSet[it.pkg] === true);
    }

    function moveSel(delta) {
        if (tab.count > 0) tab.selectionRequested(tab.sel + delta);
    }

    // ── разбор вывода процессов ───────────────────────────────────────
    function _installedVerFromHeader(line) {
        const m = line.match(/\[(?:Installed|Установлено)(?::\s*([^\]\[]+?))?\]/);
        return (m && m[1]) ? m[1].trim() : "";
    }

    function _aurStats(rest) {
        let votes;
        let popularity;
        const v = rest.match(/\+\s*(\d+)/);
        if (v) votes = parseInt(v[1], 10);
        const p = rest.match(/~\s*([0-9]+\.[0-9]+)/);
        if (p) popularity = parseFloat(p[1]);
        return { votes: votes, popularity: popularity };
    }

    function _searchLine(line) {
        if (tab.results.length >= 200) return;
        const m = line.match(/^([^\s/]+)\/(\S+)\s+(\S+)(.*)$/);
        if (m) {
            const repo = m[1];
            const aur = repo === "aur";
            const stats = aur ? tab._aurStats(m[4] || "") : {};
            const arr = tab.results.slice();
            arr.push({
                name: m[2],
                repo: repo,
                version: m[3],
                desc: "",
                installed: /\[(?:Installed|Установлено)[:\]]/.test(line) || tab.installedSet[m[2]] === true,
                aur: aur,
                installedVer: tab._installedVerFromHeader(line),
                votes: stats.votes,
                popularity: stats.popularity
            });
            tab.results = arr;
            tab._cur = arr.length - 1;
            return;
        }
        if (/^\s+\S/.test(line) && tab._cur >= 0 && tab._cur < tab.results.length) {
            const arr = tab.results.slice();
            if (arr[tab._cur].desc === "") {
                arr[tab._cur].desc = line.trim();
                tab.results = arr;
            }
        }
    }

    function _parseUpdateLine(line, isAur) {
        const t = String(line).trim();
        if (t === "") return null;
        // формат: pkg oldVer -> newVer
        const m = t.match(/^(\S+)\s+(\S+)\s+->\s+(\S+)/);
        if (m) {
            return { pkg: m[1], oldVer: m[2], newVer: m[3], repo: isAur ? "aur" : "repo", aur: isAur };
        }
        const parts = t.split(/\s+/);
        return { pkg: parts[0], oldVer: parts[1] || "", newVer: parts[2] || "", repo: isAur ? "aur" : "repo", aur: isAur };
    }

    function _repoLine(line) {
        const item = tab._parseUpdateLine(line, false);
        if (!item) return;
        const a = tab.updatesList.slice();
        a.push(item);
        tab.updatesList = a;
        tab.repoUpdates = a.length;
    }

    function _aurLine(line) {
        const item = tab._parseUpdateLine(line, true);
        if (!item) return;
        const a = tab.aurList.slice();
        a.push(item);
        tab.aurList = a;
        tab.aurUpdates = a.length;
    }

    // ── процессы ──────────────────────────────────────────────────────
    Process {
        id: searchProc
        command: ["sh", "-c", "true"]
        stdout: SplitParser {
            onRead: (line) => tab._searchLine(line)
        }
        onExited: () => {
            tab.searching = false;
            tab._ensureSelectedDetails();
        }
    }

    Process {
        id: repoProc
        command: ["checkupdates"]
        stdout: SplitParser {
            onRead: (line) => tab._repoLine(line)
        }
        onExited: () => {
            tab.repoUpdates = tab.updatesList.length;
            tab.checkingRepoUpdates = false;
        }
    }

    Process {
        id: aurProc
        command: ["paru", "-Qua"]
        stdout: SplitParser {
            onRead: (line) => tab._aurLine(line)
        }
        onExited: () => {
            tab.aurUpdates = tab.aurList.length;
            tab.checkingAurUpdates = false;
        }
    }

    Process {
        id: listProc
        command: ["pacman", "-Q"]
        stdout: SplitParser {
            onRead: (line) => tab._installedLine(line)
        }
        onExited: (exitCode) => tab._installedExit(exitCode)
    }

    Process {
        id: explicitProc
        command: ["pacman", "-Qe"]
        stdout: SplitParser {
            onRead: (line) => tab._explicitLine(line)
        }
        onExited: () => tab._explicitExit()
    }

    Process {
        id: foreignProc
        command: ["pacman", "-Qm"]
        stdout: SplitParser {
            onRead: (line) => tab._foreignLine(line)
        }
        onExited: () => tab._foreignExit()
    }

    Process {
        id: qiProc
        command: ["env", "LC_ALL=C", "pacman", "-Qi", "--", ""]
        stdout: SplitParser {
            onRead: (line) => tab._qiLine(line)
        }
        onExited: (exitCode) => tab._qiExit(exitCode)
    }

    Process {
        id: aurInfoProc
        command: ["curl", "-s", "--max-time", "15", "https://aur.archlinux.org/rpc/v5/info?arg[]="]
        stdout: StdioCollector {
            id: aurInfoOut
        }
        onExited: () => tab._aurInfoDone(aurInfoOut.text)
    }

    Timer {
        id: searchTimer
        interval: 350
        repeat: false
        onTriggered: tab.doSearch()
    }

    // ══════════════════════════════════════════════════════════════════
    // 1. ВЕРХНЯЯ ПАНЕЛЬ НАВИГАЦИИ И ФИЛЬТРОВ
    // ══════════════════════════════════════════════════════════════════
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.dp(6)

        // Вкладка 1: Установленные
        Chip {
            kind: "assist"
            icon: "inventory_2"
            label: "Установленные (" + (tab.installedScope === "apps" ? tab.appsList.length : tab.explicitList.length) + ")"
            selected: tab.subTab === "installed"
            onClicked: tab.subTab = "installed"
        }

        // Вкладка 2: Поиск в репозиториях Arch & AUR
        Chip {
            kind: "assist"
            icon: "travel_explore"
            label: tab.subTab === "repo" && tab.results.length > 0
                ? "Поиск в репо (" + tab.filteredRepoList.length + ")"
                : "Поиск в репо (Arch & AUR)"
            selected: tab.subTab === "repo"
            onClicked: tab.switchToRepoSearch()
        }

        // Вкладка 3: Обновления
        Chip {
            kind: "assist"
            icon: tab.totalUpdates > 0 ? "system_update_alt" : "check_circle"
            label: tab.checkingUpdates
                ? "Обновления (…)"
                : (tab.totalUpdates > 0 ? "Обновления (" + tab.totalUpdates + ")" : "Обновления (0)")
            selected: tab.subTab === "updates"
            customColors: tab.totalUpdates > 0 && tab.subTab !== "updates"
            backgroundColor: tab.totalUpdates > 0 && tab.subTab !== "updates" ? Theme.tertiaryContainer : "transparent"
            foregroundColor: tab.totalUpdates > 0 && tab.subTab !== "updates" ? Theme.fgTertiaryContainer : Theme.text
            iconColor: tab.totalUpdates > 0 && tab.subTab !== "updates" ? Theme.fgTertiaryContainer : Theme.primary
            borderWidth: tab.totalUpdates > 0 && tab.subTab !== "updates" ? 0 : -1
            onClicked: tab.subTab = "updates"
        }

        Item { Layout.fillWidth: true }

        // Быстрые переключатели для режима «Установленные»
        RowLayout {
            visible: tab.subTab === "installed"
            spacing: Theme.dp(4)

            Chip {
                size: "sm"
                kind: "filter"
                label: "Приложения"
                selected: tab.installedScope === "apps"
                onClicked: {
                    tab.installedScope = "apps";
                    tab.selectionRequested(0);
                }
            }

            Chip {
                size: "sm"
                kind: "filter"
                label: "Все пакеты (-Qe)"
                selected: tab.installedScope === "all"
                onClicked: {
                    tab.installedScope = "all";
                    tab.selectionRequested(0);
                }
            }
        }

        // Фильтры источников для режима «Поиск в репо»
        RowLayout {
            visible: tab.subTab === "repo"
            spacing: Theme.dp(4)

            Chip {
                size: "sm"
                kind: "filter"
                label: "Все"
                selected: tab.repoFilter === "all"
                onClicked: {
                    tab.repoFilter = "all";
                    tab.selectionRequested(0);
                }
            }

            Chip {
                size: "sm"
                kind: "filter"
                label: "Pacman"
                selected: tab.repoFilter === "official"
                onClicked: {
                    tab.repoFilter = "official";
                    tab.selectionRequested(0);
                }
            }

            Chip {
                size: "sm"
                kind: "filter"
                label: "AUR"
                selected: tab.repoFilter === "aur"
                onClicked: {
                    tab.repoFilter = "aur";
                    tab.selectionRequested(0);
                }
            }

            Chip {
                size: "sm"
                kind: "filter"
                label: "Не установленные"
                selected: tab.onlyUninstalled
                onClicked: {
                    tab.onlyUninstalled = !tab.onlyUninstalled;
                    tab.selectionRequested(0);
                }
            }
        }

        // Кнопки управления для режима «Обновления»
        RowLayout {
            visible: tab.subTab === "updates"
            spacing: Theme.dp(6)

            Button {
                variant: "tonal"
                size: "xs"
                icon: "refresh"
                text: tab.checkingUpdates ? "Проверка…" : "Проверить"
                disabled: tab.checkingUpdates
                onClicked: tab.refreshUpdates()
            }

            Button {
                visible: tab.totalUpdates > 0
                variant: "filled"
                size: "xs"
                icon: "system_update_alt"
                text: "Обновить всё (" + tab.totalUpdates + ")"
                onClicked: tab.updateAll()
            }
        }
    }

    // ── Баннер быстрого перехода к поиску в Arch & AUR при вводе в «Установленных» ──
    Rectangle {
        visible: tab.subTab === "installed" && tab.query.trim().length >= 2
        Layout.fillWidth: true
        implicitHeight: Theme.dp(36)
        radius: Theme.rad(12)
        color: Theme.secondaryContainer

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.dp(12)
            anchors.rightMargin: Theme.dp(8)
            spacing: Theme.dp(8)

            Icon {
                name: "travel_explore"
                size: Theme.dp(18)
                color: Theme.fgSecondaryContainer
            }

            LText {
                Layout.fillWidth: true
                role: "bodySmall"
                text: "Ищете новый пакет? Найти «" + tab.query.trim() + "» в репозиториях Arch и AUR"
                color: Theme.fgSecondaryContainer
                elide: Text.ElideRight
            }

            Button {
                variant: "filled"
                size: "xs"
                icon: "search"
                text: "Искать в Arch & AUR"
                onClicked: tab.switchToRepoSearch()
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // 2. MASTER-DETAIL SPLIT VIEW (СЛЕВА СПИСОК, СПРАВА ИНСПЕКТОР)
    // ══════════════════════════════════════════════════════════════════
    RowLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.minimumHeight: 0
        spacing: Theme.dp(10)

        // ── ЛЕВАЯ КОЛОНКА: СПИСОК ПАКЕТОВ ─────────────────────────────
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumWidth: Theme.dp(340)

            ListView {
                id: mainListView

                anchors.fill: parent
                model: tab.currentList
                clip: true
                spacing: Theme.dp(4)
                boundsBehavior: Flickable.StopAtBounds

                delegate: Item {
                    id: pkgRow

                    required property var modelData
                    required property int index

                    readonly property bool isSel: pkgRow.index === tab.sel
                    readonly property bool hasIcon: pkgRow.modelData.icon !== ""
                    readonly property bool pendingRemove: tab.pending === pkgRow.modelData.pkg

                    width: mainListView.width
                    height: Theme.dp(56)

                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.rad(14)
                        color: pkgRow.isSel ? Theme.secondaryContainer : Theme.bgSunken
                        border.width: pkgRow.pendingRemove ? Theme.dp(1) : (pkgRow.isSel ? Theme.dp(1) : 0)
                        border.color: pkgRow.pendingRemove ? Theme.error : Theme.alpha(Theme.primary, 0.35)

                        Behavior on color {
                            ColorAnimation { duration: Theme.durQuick }
                        }

                        StateLayer {
                            radius: parent.radius
                            tint: pkgRow.isSel ? Theme.fgSecondaryContainer : Theme.text
                            onClicked: tab.selectionRequested(pkgRow.index)
                        }
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.dp(12)
                        anchors.rightMargin: Theme.dp(10)
                        spacing: Theme.dp(10)

                        // Иконка приложения или бейдж пакета
                        Item {
                            Layout.alignment: Qt.AlignVCenter
                            implicitWidth: Theme.dp(38)
                            implicitHeight: Theme.dp(38)

                            Rectangle {
                                anchors.fill: parent
                                visible: !pkgRow.hasIcon
                                radius: Theme.rad(11)
                                color: pkgRow.modelData.aur
                                    ? Theme.alpha(Theme.tertiaryContainer, 0.85)
                                    : (pkgRow.isSel ? Theme.mHighest : Theme.bgTile)
                            }

                            AppIcon {
                                anchors.centerIn: parent
                                visible: pkgRow.hasIcon
                                source: pkgRow.modelData.icon
                                size: Theme.dp(34)
                            }

                            Icon {
                                anchors.centerIn: parent
                                visible: !pkgRow.hasIcon
                                name: pkgRow.modelData.hasUpdate ? "system_update_alt"
                                    : (pkgRow.modelData.aur ? "deployed_code" : "inventory_2")
                                size: Theme.dp(20)
                                color: pkgRow.modelData.aur
                                    ? Theme.fgTertiaryContainer
                                    : (pkgRow.isSel ? Theme.fgSecondaryContainer : Theme.subtext)
                            }
                        }

                        // Текстовый блок: имя + бейджи сверху, описание снизу
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: Theme.dp(2)

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.dp(6)

                                LText {
                                    Layout.fillWidth: false
                                    Layout.maximumWidth: Theme.dp(210)
                                    role: "titleSmall"
                                    text: pkgRow.modelData.title
                                    color: pkgRow.isSel ? Theme.fgSecondaryContainer : Theme.text
                                    elide: Text.ElideRight
                                }

                                // Бейдж репозитория (core / extra / multilib / AUR)
                                Rectangle {
                                    visible: pkgRow.modelData.repo !== "" && pkgRow.modelData.repo !== "installed" && pkgRow.modelData.repo !== "local"
                                    implicitWidth: repoBadgeLabel.implicitWidth + Theme.dp(10)
                                    implicitHeight: Theme.dp(18)
                                    radius: Theme.pill(height)
                                    color: pkgRow.modelData.aur ? Theme.tertiaryContainer : Theme.bgTile

                                    LText {
                                        id: repoBadgeLabel
                                        anchors.centerIn: parent
                                        role: "labelSmall"
                                        size: Theme.fs(10)
                                        text: pkgRow.modelData.aur ? "AUR" : pkgRow.modelData.repo
                                        color: pkgRow.modelData.aur ? Theme.fgTertiaryContainer : Theme.subtext
                                    }
                                }

                                // Бейдж статуса «Установлен» (в режиме поиска в репо)
                                Rectangle {
                                    visible: tab.subTab === "repo" && pkgRow.modelData.installed
                                    implicitWidth: instBadgeLabel.implicitWidth + Theme.dp(10)
                                    implicitHeight: Theme.dp(18)
                                    radius: Theme.pill(height)
                                    color: Theme.alpha(Theme.success, 0.2)

                                    LText {
                                        id: instBadgeLabel
                                        anchors.centerIn: parent
                                        role: "labelSmall"
                                        size: Theme.fs(10)
                                        text: "Установлен"
                                        color: Theme.success
                                    }
                                }

                                // Бейдж версии или перехода версий
                                LText {
                                    visible: pkgRow.modelData.version !== ""
                                    Layout.fillWidth: true
                                    role: "labelSmall"
                                    mono: true
                                    text: (pkgRow.modelData.oldVer !== "" && pkgRow.modelData.newVer !== "")
                                        ? (pkgRow.modelData.oldVer + " → " + pkgRow.modelData.newVer)
                                        : pkgRow.modelData.version
                                    color: pkgRow.modelData.hasUpdate
                                        ? Theme.primary
                                        : (pkgRow.isSel ? Theme.alpha(Theme.fgSecondaryContainer, 0.75) : Theme.subtextDim)
                                    elide: Text.ElideRight
                                }
                            }

                            LText {
                                Layout.fillWidth: true
                                role: "bodySmall"
                                text: pkgRow.modelData.subtitle
                                color: pkgRow.isSel ? Theme.alpha(Theme.fgSecondaryContainer, 0.85) : Theme.subtext
                                elide: Text.ElideRight
                            }
                        }

                        // Быстрое действие справа на строке
                        Button {
                            Layout.alignment: Qt.AlignVCenter
                            size: "xs"
                            variant: pkgRow.pendingRemove ? "filled"
                                : (!pkgRow.modelData.installed || pkgRow.modelData.hasUpdate ? "tonal" : "text")
                            danger: pkgRow.modelData.installed && !pkgRow.modelData.hasUpdate
                            icon: pkgRow.modelData.hasUpdate ? "system_update_alt"
                                : (!pkgRow.modelData.installed ? "download" : "delete")
                            text: pkgRow.modelData.hasUpdate ? "Обновить"
                                : (!pkgRow.modelData.installed ? "Установить"
                                    : (pkgRow.pendingRemove ? "Точно?" : ""))
                            onClicked: {
                                tab.selectionRequested(pkgRow.index);
                                if (pkgRow.modelData.hasUpdate) {
                                    tab.updatePackage(pkgRow.modelData.pkg, pkgRow.modelData.aur);
                                } else if (!pkgRow.modelData.installed) {
                                    tab.installPackage(pkgRow.modelData.pkg, pkgRow.modelData.aur);
                                } else {
                                    tab.removePackage(pkgRow.modelData.pkg, pkgRow.modelData.aur);
                                }
                            }
                        }
                    }

                    HoverHandler {
                        onHoveredChanged: if (hovered) tab.hovered(pkgRow.index)
                    }
                }
            }

            // ── Пустые состояния для каждого режима ───────────────────
            ColumnLayout {
                anchors.centerIn: parent
                width: Math.min(parent.width - Theme.dp(32), Theme.dp(320))
                visible: mainListView.count === 0
                spacing: Theme.dp(8)

                Icon {
                    Layout.alignment: Qt.AlignHCenter
                    name: tab.subTab === "updates" ? "verified"
                        : (tab.subTab === "repo" ? "travel_explore" : "inventory_2")
                    size: Theme.dp(36)
                    color: Theme.subtextDim
                }

                LText {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    role: "titleSmall"
                    color: Theme.text
                    text: {
                        if (tab.subTab === "repo") {
                            if (tab.searching) return "Поиск пакетов в Arch и AUR…";
                            if (tab.query.trim().length < 2) return "Введите минимум 2 символа в строку поиска сверху";
                            return "По запросу «" + tab.query.trim() + "» ничего не найдено";
                        }
                        if (tab.subTab === "updates") {
                            if (tab.checkingUpdates) return "Проверка обновлений репозиториев и AUR…";
                            return "Все пакеты актуальны 🎉";
                        }
                        if (!tab._installedLoaded) return "Загрузка списка пакетов…";
                        if (tab.query.trim() !== "") return "Среди установленных не найдено «" + tab.query.trim() + "»";
                        return "Список пакетов пуст";
                    }
                }

                LText {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    role: "bodySmall"
                    color: Theme.subtext
                    visible: tab.subTab === "repo" && tab.query.trim().length < 2
                    text: "Поиск выполняется одновременно по официальным репозиториям (core, extra, multilib) и пользовательскому репозиторию AUR."
                }

                Button {
                    Layout.alignment: Qt.AlignHCenter
                    visible: tab.subTab === "installed" && tab.query.trim().length >= 2
                    variant: "tonal"
                    size: "s"
                    icon: "travel_explore"
                    text: "Искать «" + tab.query.trim() + "» в Arch & AUR"
                    onClicked: tab.switchToRepoSearch()
                }
            }
        }

        // ── ПРАВАЯ КОЛОНКА: ПАНЕЛЬ-ИНСПЕКТОР ПАКЕТА ───────────────────
        Rectangle {
            id: inspectorCard

            visible: tab.selectedItem !== null
            Layout.preferredWidth: Theme.dp(295)
            Layout.minimumWidth: Theme.dp(270)
            Layout.maximumWidth: Theme.dp(310)
            Layout.fillHeight: true
            radius: Theme.shapeLgInc
            color: Theme.bgSunken
            border.width: 1
            border.color: Theme.divider
            clip: true

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.dp(14)
                spacing: Theme.dp(10)

                // Шапка инспектора: иконка + имя + пакет + бейджи
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(10)

                    Item {
                        Layout.alignment: Qt.AlignTop
                        implicitWidth: Theme.dp(44)
                        implicitHeight: Theme.dp(44)

                        Rectangle {
                            anchors.fill: parent
                            visible: !tab.selectedItem || tab.selectedItem.icon === ""
                            radius: Theme.rad(12)
                            color: tab.selectedAur ? Theme.tertiaryContainer : Theme.bgTile
                        }

                        AppIcon {
                            anchors.centerIn: parent
                            visible: tab.selectedItem !== null && tab.selectedItem.icon !== ""
                            source: tab.selectedItem ? tab.selectedItem.icon : ""
                            size: Theme.dp(40)
                        }

                        Icon {
                            anchors.centerIn: parent
                            visible: !tab.selectedItem || tab.selectedItem.icon === ""
                            name: tab.selectedAur ? "deployed_code" : "inventory_2"
                            size: Theme.dp(24)
                            color: tab.selectedAur ? Theme.fgTertiaryContainer : Theme.primary
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.dp(3)

                        LText {
                            Layout.fillWidth: true
                            role: "titleMedium"
                            text: tab.selectedItem ? tab.selectedItem.title : ""
                            color: Theme.text
                            elide: Text.ElideRight
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.dp(6)

                            // Репозиторий
                            Rectangle {
                                implicitWidth: inspRepoText.implicitWidth + Theme.dp(10)
                                implicitHeight: Theme.dp(18)
                                radius: Theme.pill(height)
                                color: tab.selectedAur ? Theme.tertiaryContainer : Theme.secondaryContainer

                                LText {
                                    id: inspRepoText
                                    anchors.centerIn: parent
                                    role: "labelSmall"
                                    size: Theme.fs(10)
                                    text: tab.selectedAur ? "AUR" : tab.dRepo
                                    color: tab.selectedAur ? Theme.fgTertiaryContainer : Theme.fgSecondaryContainer
                                }
                            }

                            // Статус установки
                            Rectangle {
                                implicitWidth: inspStatusText.implicitWidth + Theme.dp(10)
                                implicitHeight: Theme.dp(18)
                                radius: Theme.pill(height)
                                color: tab.selectedInstalled ? Theme.alpha(Theme.success, 0.2) : Theme.bgTile

                                LText {
                                    id: inspStatusText
                                    anchors.centerIn: parent
                                    role: "labelSmall"
                                    size: Theme.fs(10)
                                    text: tab.selectedInstalled ? "Установлен" : "Не установлен"
                                    color: tab.selectedInstalled ? Theme.success : Theme.subtext
                                }
                            }

                            // AUR голоса
                            LText {
                                visible: tab.selectedItem !== null && tab.selectedItem.votes !== undefined
                                role: "labelSmall"
                                text: "★ " + (tab.selectedItem ? tab.selectedItem.votes : "")
                                color: Theme.subtext
                            }
                        }
                    }
                }

                // Строка версии
                Rectangle {
                    visible: tab.dVersion !== ""
                    Layout.fillWidth: true
                    implicitHeight: Theme.dp(28)
                    radius: Theme.rad(8)
                    color: Theme.bgTile

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.dp(10)
                        anchors.rightMargin: Theme.dp(10)
                        spacing: Theme.dp(6)

                        Icon {
                            name: "sell"
                            size: Theme.dp(14)
                            color: Theme.subtext
                        }

                        LText {
                            role: "labelSmall"
                            text: "Версия:"
                            color: Theme.subtext
                        }

                        LText {
                            Layout.fillWidth: true
                            role: "labelSmall"
                            mono: true
                            text: tab.dVersion
                            color: Theme.text
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideRight
                        }
                    }
                }

                // Прокручиваемая область с описанием, метаданными и зависимостями
                Flickable {
                    id: inspectorFlick

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentWidth: width
                    contentHeight: inspectorCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    flickableDirection: Flickable.VerticalFlick

                    ColumnLayout {
                        id: inspectorCol

                        width: inspectorFlick.width
                        spacing: Theme.dp(8)

                        // Описание
                        LText {
                            Layout.fillWidth: true
                            visible: tab.dDescription !== ""
                            role: "bodySmall"
                            text: tab.dDescription
                            color: Theme.text
                            wrapMode: Text.WordWrap
                        }

                        // Сетка ключевых метаданных (Размер, Лицензия, Дата)
                        Rectangle {
                            visible: tab.dSize !== "" || tab.dLicense !== "" || tab.dDate !== ""
                            Layout.fillWidth: true
                            implicitHeight: metaGrid.implicitHeight + Theme.dp(16)
                            radius: Theme.rad(10)
                            color: Theme.bgTile

                            ColumnLayout {
                                id: metaGrid

                                anchors.fill: parent
                                anchors.margins: Theme.dp(8)
                                spacing: Theme.dp(4)

                                RowLayout {
                                    visible: tab.dSize !== ""
                                    Layout.fillWidth: true
                                    LText {
                                        role: "labelSmall"
                                        text: tab.selectedInstalled ? "Размер:" : "Загрузка / Уст.:"
                                        color: Theme.subtextDim
                                    }
                                    LText {
                                        Layout.fillWidth: true
                                        horizontalAlignment: Text.AlignRight
                                        role: "labelSmall"
                                        text: (!tab.selectedInstalled && tab.dDownloadSize !== "" && tab.dSize !== tab.dDownloadSize)
                                            ? (tab.dDownloadSize + " / " + tab.dSize) : tab.dSize
                                        color: Theme.text
                                        elide: Text.ElideRight
                                    }
                                }

                                RowLayout {
                                    visible: tab.dLicense !== ""
                                    Layout.fillWidth: true
                                    LText {
                                        role: "labelSmall"
                                        text: "Лицензия:"
                                        color: Theme.subtextDim
                                    }
                                    LText {
                                        Layout.fillWidth: true
                                        horizontalAlignment: Text.AlignRight
                                        role: "labelSmall"
                                        text: tab.dLicense
                                        color: Theme.text
                                        elide: Text.ElideRight
                                    }
                                }

                                RowLayout {
                                    visible: tab.dDate !== ""
                                    Layout.fillWidth: true
                                    LText {
                                        role: "labelSmall"
                                        text: tab.selectedInstalled ? "Установлен:" : "Сборка:"
                                        color: Theme.subtextDim
                                    }
                                    LText {
                                        Layout.fillWidth: true
                                        horizontalAlignment: Text.AlignRight
                                        role: "labelSmall"
                                        text: tab.dDate
                                        color: Theme.text
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }

                        // Зависимости (компактные чипы)
                        ColumnLayout {
                            visible: tab.dDeps.length > 0
                            Layout.fillWidth: true
                            spacing: Theme.dp(4)

                            LText {
                                role: "labelSmall"
                                text: "Зависимости (" + tab.dDeps.length + ")"
                                color: Theme.subtextDim
                            }

                            Flow {
                                Layout.fillWidth: true
                                spacing: Theme.dp(4)

                                Repeater {
                                    model: tab.dDeps.slice(0, 14)

                                    delegate: Rectangle {
                                        required property var modelData
                                        implicitWidth: depLabel.implicitWidth + Theme.dp(10)
                                        implicitHeight: Theme.dp(20)
                                        radius: Theme.rad(6)
                                        color: Theme.bgTile

                                        LText {
                                            id: depLabel
                                            anchors.centerIn: parent
                                            role: "labelSmall"
                                            size: Theme.fs(10)
                                            mono: true
                                            text: modelData
                                            color: Theme.subtext
                                        }
                                    }
                                }

                                LText {
                                    visible: tab.dDeps.length > 14
                                    role: "labelSmall"
                                    text: "+" + (tab.dDeps.length - 14)
                                    color: Theme.subtextDim
                                }
                            }
                        }

                        // Требуется для
                        ColumnLayout {
                            visible: tab.dRequired.length > 0
                            Layout.fillWidth: true
                            spacing: Theme.dp(4)

                            LText {
                                role: "labelSmall"
                                text: "Требуется для (" + tab.dRequired.length + ")"
                                color: Theme.subtextDim
                            }

                            LText {
                                Layout.fillWidth: true
                                role: "bodySmall"
                                text: tab.dRequired.slice(0, 10).join(", ")
                                    + (tab.dRequired.length > 10 ? " (+" + (tab.dRequired.length - 10) + ")" : "")
                                color: Theme.subtext
                                wrapMode: Text.WordWrap
                            }
                        }

                        LText {
                            visible: tab.detailLoading
                            Layout.fillWidth: true
                            role: "labelSmall"
                            text: "Загрузка метаданных пакета…"
                            color: Theme.subtextDim
                        }
                    }
                }

                // Ссылки (ArchWeb / AUR / Сайт проекта)
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(4)

                    Button {
                        visible: !tab.selectedAur
                        variant: "text"
                        size: "xs"
                        icon: "open_in_new"
                        text: "ArchWeb"
                        onClicked: tab.openArch(tab.selectedPkg)
                    }

                    Button {
                        visible: tab.selectedAur
                        variant: "text"
                        size: "xs"
                        icon: "open_in_new"
                        text: "AUR"
                        onClicked: tab.openAur(tab.selectedPkg)
                    }

                    Button {
                        visible: tab.dUrl !== ""
                        variant: "text"
                        size: "xs"
                        icon: "language"
                        text: "Сайт проекта"
                        onClicked: tab.openUrl(tab.dUrl)
                    }

                    Item { Layout.fillWidth: true }
                }

                // Главная кнопка действия внизу инспектора
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(6)

                    // Кнопка обновления (если для выбранного пакета есть обновление)
                    Button {
                        visible: tab.selectedItem !== null && tab.selectedItem.hasUpdate
                        Layout.fillWidth: true
                        variant: "filled"
                        size: "s"
                        icon: "system_update_alt"
                        text: "Обновить пакет"
                        onClicked: if (tab.selectedItem) tab.updatePackage(tab.selectedItem.pkg, tab.selectedAur)
                    }

                    // Кнопка установки (если пакет не установлен)
                    Button {
                        visible: tab.selectedItem !== null && !tab.selectedInstalled
                        Layout.fillWidth: true
                        variant: "filled"
                        size: "s"
                        icon: "download"
                        text: tab.selectedAur ? "Установить из AUR" : "Установить пакет"
                        onClicked: if (tab.selectedItem) tab.installPackage(tab.selectedItem.pkg, tab.selectedAur)
                    }

                    // Кнопка удаления с двухкликовым подтверждением (если пакет установлен)
                    Button {
                        readonly property bool armed: tab.selectedItem !== null
                            && tab.pending === tab.selectedItem.pkg

                        visible: tab.selectedItem !== null && tab.selectedInstalled
                        Layout.fillWidth: true
                        variant: armed ? "filled" : "tonal"
                        danger: true
                        size: "s"
                        icon: "delete"
                        text: armed ? "Подтвердить удаление (-Rns)?" : "Удалить пакет"
                        onClicked: tab.removeDetail()
                    }
                }
            }
        }
    }
}
