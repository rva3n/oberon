//@ pragma IconTheme Papirus
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import Quickshell.Services.Pipewire
import Quickshell.Services.Pam
import Quickshell.Services.Polkit
import "core"
import "components"

ShellRoot {
    id: root

    property string view: "idle"   // idle | panel | launcher | taskman | tray
    property string panelPage: ""
    property string mediaPath: ""
    property string filesStartPath: ""
    property string settingsSection: "look"
    property bool widgetsEditing: false
    property string launcherTab: "apps"    // apps | clipboard | emoji | packages (вкладки лончера)
    property int taskmanTab: 0             // вкладка диспетчера (0/1/2)
    property bool locked: false
    property string pamError: ""
    // Активный запрос polkit (AuthFlow) или null. Обновляется из PolkitAgent.
    property var polkitFlow: null

    PamContext {
        id: pam
        user: Quickshell.env("USER") || "user"
        config: "login"
        onCompleted: (result) => {
            if (result === PamResult.Success) { root.pamError = ""; root.locked = false; }
            else root.pamError = "Неверный пароль";
        }
        onError: (error) => { root.pamError = "Ошибка аутентификации"; }
    }

    onLockedChanged: {
        if (root.locked) { root.pamError = ""; pam.start(); }
        else { try { pam.abort(); } catch (e) {} }
    }

    // Polkit-агент: регистрируется в полките при загрузке шелла. Пока существует
    // ровно один экземпляр, двойной регистрации не будет.
    PolkitAgent {
        id: polkit

        // flow живёт в агенте; пробрасываем его в свойство шелла для UI.
        onAuthenticationRequestStarted: root.polkitFlow = polkit.flow
        onFlowChanged: root.polkitFlow = polkit.flow

        onIsRegisteredChanged: {
            if (polkit.isRegistered) console.log("Oberon: polkit agent registered")
            else console.warn("Oberon: polkit agent not registered");
        }
    }

    // Проверка после старта: регистрация в D-Bus асинхронная.
    Timer {
        interval: 2500
        running: true
        onTriggered: {
            if (!polkit.isRegistered)
                console.warn("Oberon: polkit agent failed to register (isRegistered=false)");
        }
    }

    // Bind PipeWire nodes so volume/mute changes are reactive in the UI.
    PwObjectTracker {
        objects: {
            const a = [];
            for (const n of Pipewire.nodes.values) a.push(n);
            return a;
        }
    }

    // Палитра читается самим Theme (FileView → ~/.cache/oberon/colors.json).
    // Прогреваем синглтоны, чтобы они поднялись вместе с шеллом (они ленивые).
    Component.onCompleted: {
        void Theme.paletteLoaded;
        void Prefs.ready;
        void Weather.place;
        void SysStats.cpu;
    }

    NotificationServer {
        id: notifServer
        keepOnReload: true
        onNotification: (n) => {
            const snap = { appName: n.appName, summary: n.summary, body: n.body, appIcon: n.appIcon, urgency: n.urgency, ts: Date.now(), raw: n };
            Notif.add(snap);
            if (!Notif.dnd && root.view === "idle" && !root.locked) Notif.toast(snap, Umbriel.activeOutput);
        }
    }

    // Таймер завершился: алерт в островке + запись в историю (сигнал finished()
    // раньше никто не слушал — таймер истекал молча). DND не глушит: это будильник.
    Connections {
        target: Chrono
        function onFinished() {
            const snap = { appName: "Oberon", summary: "Таймер завершён", body: "Время вышло" };
            Notif.add(snap);
            if (root.view === "idle" && !root.locked) Notif.toast(snap, Umbriel.activeOutput);
        }
    }

    // Backdrop first → below the island (Overlay layer).
    Variants {
        model: Quickshell.screens
        delegate: Backdrop { shell: root; active: root.view !== "idle" }
    }
    // Невидимая распорка под остров: резервирует полосу, чтобы окна не
    // заезжали под капсулу (сам остров зону не держит из-за бага Umbriel).
    Variants {
        model: Quickshell.screens
        delegate: Strut { modelData: modelData }
    }
    Variants {
        model: Quickshell.screens
        delegate: Island { shell: root; view: root.view }
    }
    Variants {
        model: Quickshell.screens
        delegate: MediaPill { modelData: modelData }
    }

    // Виджеты на рабочем столе (Bottom-слой, под окнами) — Prefs.widgetsEnabled.
    Variants {
        model: Quickshell.screens
        delegate: WidgetLayer { modelData: modelData; shell: root }
    }

    Lockscreen {
        locked: root.locked
        pam: pam
        errorText: root.pamError
    }

    // Переключатель окон (Alt+Tab-аналог). Overlay; создаётся ПЕРЕД polkit-промптом,
    // чтобы polkit при одновременной видимости оставался выше. LazyLoader — по той же
    // причине, что и polkit: components/qmldir не перечисляет Switcher (его трогать нельзя).
    LazyLoader {
        id: switcherLoader
        active: true
        source: "components/Switcher.qml"
    }

    // Обзор воркспейсов — отдельное overlay-окно, выше Switcher и ниже polkit.
    LazyLoader {
        id: overviewLoader
        active: true
        source: "components/Overview.qml"
    }

    // Модальный polkit-промпт поверх всего (Overlay). Создаётся после Lockscreen,
    // чтобы быть выше острова. LazyLoader нужен, т.к. components/qmldir не
    // перечисляет PolkitPrompt (его трогать нельзя), а LazyLoader умеет
    // подгружать не-Item (оконные) компоненты по source.
    LazyLoader {
        id: polkitLoader
        active: true
        source: "components/PolkitPrompt.qml"
    }

    Binding {
        target: polkitLoader.item
        property: "flow"
        value: root.polkitFlow
        when: polkitLoader.item !== null
    }

    // Оверлеи финальной волны: экран сессии, шпаргалка, скриншот-тулбар.
    // LazyLoader — components/qmldir их не перечисляет (как Switcher/PolkitPrompt).
    // SessionScreen'у шелл нужен для lock(): тот же путь, что `ipc call oberon
    // lock` (root.lock поднимает Lockscreen), пробрасывается Binding-ом, как flow.
    LazyLoader {
        id: sessionLoader
        active: true
        source: "components/SessionScreen.qml"
    }
    LazyLoader {
        id: cheatsheetLoader
        active: true
        source: "components/Cheatsheet.qml"
    }
    LazyLoader {
        id: shotLoader
        active: true
        source: "components/ScreenshotToolbar.qml"
    }

    Binding {
        target: sessionLoader.item
        property: "shell"
        value: root
        when: sessionLoader.item !== null
    }

    // ── Actions ──────────────────────────────────────────────────────
    function openPanel()      { root.view = "panel"; root.panelPage = ""; }
    function openLauncher(tab) { root.launcherTab = tab || "apps"; root.view = "launcher"; }
    function expandLocalPath(path) {
        const value = String(path || "").trim();
        const home = Quickshell.env("HOME") || "/";
        return value === "~" ? home : (value.indexOf("~/") === 0 ? home + value.slice(1) : value);
    }
    function parentDirOf(path) {
        const expanded = root.expandLocalPath(path).replace(/\/+$/, "");
        if (expanded === "" || expanded === "/")
            return "/";
        const slash = expanded.lastIndexOf("/");
        return slash <= 0 ? "/" : expanded.slice(0, slash);
    }
    function openMedia(path) {
        const expanded = root.expandLocalPath(path);
        root.mediaPath = "";
        root.mediaPath = expanded;
        root.view = "panel";
        root.panelPage = "media";
    }
    function openFiles(path) {
        const value = String(path || "").trim();
        const expanded = value === "" ? "" : root.expandLocalPath(value);
        root.filesStartPath = "";
        root.filesStartPath = expanded;
        root.view = "panel";
        root.panelPage = "files";
    }
    function openFilesAtParent(path) {
        root.openFiles(root.parentDirOf(path || root.mediaPath));
    }
    function backToFiles() {
        root.openFiles(root.parentDirOf(root.mediaPath));
    }
    function openVault() { root.view = "panel"; root.panelPage = "vault"; }
    function togglePanel()    { if (root.view === "panel") { root.view = "idle"; root.panelPage = ""; } else { root.openPanel(); } }
    function toggleLauncher() { if (root.view === "launcher") { root.view = "idle"; } else { root.openLauncher(root.launcherTab); } }
    function taskman()        { if (root.view === "taskman") { root.view = "idle"; } else { root.view = "taskman"; root.panelPage = ""; } }
    function toggleTaskman()  { root.taskman(); }
    function toggleTray()     { if (root.view === "tray") root.closeOverlays(); else { root.view = "tray"; root.panelPage = ""; } }
    function closeOverlays()  { root.view = "idle"; root.panelPage = ""; }
    function openShotToolbar(mode) {
        root.closeOverlays();
        if (!shotLoader.item) return;
        if (shotLoader.item.shown) shotLoader.item.close();
        else shotLoader.item.open(mode || "region");
    }
    function openCheatsheet() {
        root.closeOverlays();
        if (cheatsheetLoader.item) cheatsheetLoader.item.open();
    }
    function openSession() {
        root.closeOverlays();
        if (sessionLoader.item) sessionLoader.item.open();
    }
    function toggleWidgetsEditing() {
        if (!Prefs.widgetsEnabled)
            Prefs.set("widgetsEnabled", true);
        root.widgetsEditing = !root.widgetsEditing;
        if (root.widgetsEditing)
            root.closeOverlays();
    }
    // оверлеи-фуллскрин живут вне root.view — закрываем их же методами
    function closeAllOverlays() {
        root.closeOverlays();
        if (sessionLoader.item) sessionLoader.item.close();
        if (cheatsheetLoader.item) cheatsheetLoader.item.close();
        if (shotLoader.item) shotLoader.item.close();
        if (overviewLoader.item) overviewLoader.item.close();
    }

    function lock()           { root.view = "idle"; root.panelPage = ""; Quickshell.execDetached(["umbriel", "msg", "dpms-on"]); root.locked = true; }
    readonly property var legacySettingsSections: [
        "look", "bar", "power", "notif", "weather", "compositor", "input", "display", "look", "night"
    ]
    function settingsSectionId(section) {
        if (section === undefined || section === null || section === "")
            return "look";
        const value = String(section);
        if (/^\d+$/.test(value))
            return root.legacySettingsSections[Number(value)] || "look";
        return value;
    }
    function setPage(p, sec)  {
        if (p === "settings")
            root.settingsSection = root.settingsSectionId(sec);
        root.view = "panel";
        root.panelPage = p;
    }
    // Совместимость с чипами острова: weather — погода, calendar — календарь,
    // system — диспетчер, остальное — корень панели.
    function setTab(t) {
        if (t === "weather")
            root.togglePage("weather");
        else if (t === "calendar")
            root.togglePage("calendar");
        else if (t === "system")
            root.taskman();
        else
            root.openPanel();
    }
    function togglePage(p) {
        if (root.view === "panel" && root.panelPage === p) { root.view = "idle"; root.panelPage = ""; }
        else { root.view = "panel"; root.panelPage = p; }
    }

    function volumeStep(d) {
        const s = Pipewire.defaultAudioSink;
        if (!s) return;
        const nv = Math.max(0, Math.min(1, s.audio.volume + d));
        s.audio.volume = nv;
        if (root.view === "idle") Osd.show("volume", nv, s.audio.muted, Umbriel.activeOutput);
    }
    function volumeMute() {
        const s = Pipewire.defaultAudioSink;
        if (!s) return;
        s.audio.muted = !s.audio.muted;
        if (root.view === "idle") Osd.show("volume", s.audio.volume, s.audio.muted, Umbriel.activeOutput);
    }
    function brightnessStep(d) {
        const nv = Math.max(0, Math.min(1, Sys.brightnessFraction + d));
        Sys.setBrightnessPct(nv * 100);
        if (root.view === "idle") Osd.show("brightness", nv, false, Umbriel.activeOutput);
    }

    // ── IPC (compositor keybinds) ────────────────────────────────────
    IpcHandler {
        target: "oberon"
        // закрыть любой оверлей (панель/лончер/диспетчер/трей/сессию/шпаргалку/
        // тулбар) — для скриптов и агентов: безопаснее, чем слать Escape через wtype
        function closeAll() { root.closeAllOverlays(); }
        function launcher() { if (root.view === "launcher") { root.closeOverlays(); } else { root.openLauncher("apps"); } }
        function panel() { root.togglePanel() }
        function quicksettings() { root.togglePanel() }
        function tray() { root.toggleTray() }
        function page(name: string) {
            if (["wifi", "bluetooth", "volume", "brightness", "power", "wallpapers",
                 "clipboard", "weather", "system", "calendar", "timers", "emoji",
                 "games", "updates", "settings", "record", "media", "files", "vault"]
                    .indexOf(name) < 0)
                return;
            root.view = "panel";
            root.panelPage = name;
        }
        function pageRoot() { root.view = "panel"; root.panelPage = ""; }
        function pageWifi() { root.view = "panel"; root.panelPage = "wifi"; }
        function pageBluetooth() { root.view = "panel"; root.panelPage = "bluetooth"; }
        function pageVolume() { root.view = "panel"; root.panelPage = "volume"; }
        function pageBrightness() { root.view = "panel"; root.panelPage = "brightness"; }
        function pagePower() { root.view = "panel"; root.panelPage = "power"; }
        function pageWeather() { root.view = "panel"; root.panelPage = "weather"; }
        function pageRecord() { root.view = "panel"; root.panelPage = "record"; }
        function files(path: string) { root.openFiles(path); }
        function media(path: string) {
            root.openMedia(path);
        }
        function pageSystem() { root.view = "taskman"; root.panelPage = ""; }
        function taskman() { root.view = "taskman"; root.panelPage = ""; }
        function taskmanAt(i: int) { root.taskmanTab = i; root.view = "taskman"; root.panelPage = ""; }
        function tab(name: string) { root.setTab(name); }
        function overview() {
            if (!overviewLoader.item) return;
            if (overviewLoader.item.shown) {
                overviewLoader.item.close();
                return;
            }
            root.closeOverlays();
            if (switcherLoader.item) switcherLoader.item.close();
            if (sessionLoader.item) sessionLoader.item.close();
            if (cheatsheetLoader.item) cheatsheetLoader.item.close();
            if (shotLoader.item) shotLoader.item.close();
            overviewLoader.item.open();
        }
        function pageCalendar() { root.view = "panel"; root.panelPage = "calendar"; }
        function pageTimers() { root.view = "panel"; root.panelPage = "timers"; }
    function pageGames() { root.view = "panel"; root.panelPage = "games"; }
        function pageUpdates() { root.view = "panel"; root.panelPage = "updates"; }
        function vault() { root.openVault(); }
        function emoji() {
            if (root.view === "launcher" && root.launcherTab === "emoji")
                root.closeOverlays();
            else
                root.openLauncher("emoji");
        }
        function switcher() { if (switcherLoader.item) switcherLoader.item.summon(1) }
        function switcherBack() { if (switcherLoader.item) switcherLoader.item.summon(-1) }
        function switcherClose() { if (switcherLoader.item) switcherLoader.item.close() }
        function packages() {
            if (root.view === "launcher" && root.launcherTab === "packages")
                root.closeOverlays();
            else
                root.openLauncher("packages");
        }
        function pageSettings() { root.view = "panel"; root.panelPage = "settings"; }
        function pageSettingsAt(sec: string) { root.setPage("settings", sec); }
        function weatherRefresh() { Weather.refresh(); }
        function wallpapers() { root.togglePage("wallpapers"); }
        function clipboard() {
            if (root.view === "launcher" && root.launcherTab === "clipboard") {
                root.closeOverlays();
            } else {
                root.launcherTab = "clipboard";
                root.view = "launcher";
                Clip.refresh();
            }
        }
        function screenshotRegion() {
            // тулбар вместо немедленного снимка; повторный вызов закрывает его
            if (!shotLoader.item) return;
            if (shotLoader.item.shown) shotLoader.item.close();
            else shotLoader.item.open("region");
        }
        function screenshotFull() {
            // прежнее поведение: быстрый полный снимок
            Quickshell.execDetached(["sh", "-c",
                "mkdir -p \"$HOME/Pictures/Screenshots\"; f=\"$HOME/Pictures/Screenshots/$(date +%F_%H-%M-%S).png\"; " +
                "if grim \"$f\" 2>/dev/null; then wl-copy < \"$f\"; notify-send -a Oberon 'Скриншот' 'Весь экран сохранён и скопирован'; fi"]);
        }
        function session() { if (sessionLoader.item) sessionLoader.item.open(); }
        function cheatsheet() { if (cheatsheetLoader.item) cheatsheetLoader.item.open(); }
        function wpLocal() { root.view = "panel"; root.panelPage = "wallpapers"; Wallpaper.tab = "photos"; Wallpaper.refreshLocal(); }
        function wpVideos() { root.view = "panel"; root.panelPage = "wallpapers"; Wallpaper.tab = "videos"; Wallpaper.refreshLocal(); }
        function wpWallhaven() { root.view = "panel"; root.panelPage = "wallpapers"; Wallpaper.tab = "wallhaven"; Wallpaper.search(); }
        function wpMotion() { root.togglePage("wallpapers"); Wallpaper.tab = "motion"; Wallpaper.motionQuery = ""; Wallpaper.searchMotion(); }
        function wpMotionMore() { Wallpaper.loadMoreMotion(); }
        function wpApplyFirst() { if (Wallpaper.results.length > 0) Wallpaper.applyUrl(Wallpaper.results[0]); }
        function wpApplyVideo() { if (Wallpaper.videos.length > 0) Wallpaper.apply(Wallpaper.videos[0].path, true); }
        function wpApplyMotion() { if (Wallpaper.motionResults.length > 0) Wallpaper.applyVideoUrl(Wallpaper.motionResults[0].video); }
        function lock() { root.lock() }
        function volumeUp() { root.volumeStep(0.05) }
        function volumeDown() { root.volumeStep(-0.05) }
        function volumeMute() { root.volumeMute() }
        function brightnessUp() { root.brightnessStep(0.05) }
        function brightnessDown() { root.brightnessStep(-0.05) }
    }
}
