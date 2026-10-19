pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Пользовательские настройки Oberon: ~/oberon/prefs.json.
// Читаются реактивно, пишутся страницей «Настройки» (или руками).
Singleton {
    id: p

    readonly property string path: Quickshell.env("HOME") + "/oberon/prefs.json"
    readonly property bool ready: file.loaded

    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    readonly property string defaultsJson: JSON.stringify({
        uiScale: 1,
        cornerScale: 1,
        motionScale: 1,
        accentPunch: 1,
        surfaceDarkness: -1,
        surfaceTint: -1,
        blurAmount: 45,
        idleScreenMin: 10,
        idleLockMin: 0,
        idleSuspendMin: 60,
        islandLayout: true,
        islandWeather: true,
        islandClock: true,
        islandWorkspaces: true,
        islandTray: true,
        clockSeconds: true,
        clock12: false,
        clockWeekday: true,
        clockDateFmt: "d MMMM",
        toastSeconds: 5,
        notifTimeout: 5,
        notifCritTimeout: 0,
        notifPreview: true,
        weatherAuto: true,
        weatherCity: "",
        weatherLat: 0,
        weatherLon: 0,
        weatherPlace: "",
        dnd: false,
        themeScheme: "auto",
        themeContrast: 0,
        themeMode: "auto",
        islandOrder: ["kb", "weather", "ws", "clock", "tray"],
        islandAllScreens: false,
        barStyle: "island",
        islandPos: "top",
        islandHeight: 34,
        islandWidth: 0,
        islandExpandedWidth: 960,
        islandExpandedHeight: 0,
        islandGap: 6,
        islandRadius: 17,
        notchMode: false,
        notchFlare: 12,
        islandAutoHide: false,
        islandDrag: false,
        systemLoadOnIsland: false,
        mediaStyle: "cover",
        soundsEnabled: true,
        nightLightEnabled: false,
        nightLightTemp: 4500,
        nightLightMode: "manual",
        nightLightFrom: "22:00",
        nightLightTo: "07:00",
        dndScheduleEnabled: false,
        dndFrom: "23:00",
        dndTo: "07:00",
        recordFps: 60,
        recordDir: "~/Videos",
        recordAudio: true,
        recordMic: false,
        recordMicSource: "",
        tilesOrder: "",
        tilesHidden: "",
        widgetsEnabled: false,
        widgetsLayout: {},
        mangohudEnabled: false,
        mangohudFPS: true,
        mangohudCPU: true,
        mangohudGPU: true,
        mangohudRAM: true,
        mangohudVRAM: false,
        mangohudFrameTime: true,
        mangohudVersion: false,
        mangohudEngine: false,
        mangohudIO: false,
        mangohudMedia: false,
        mangohudHudAlpha: 1.0,
        mangohudPosition: "top-left",
        mangohudHorizontal: false,
        mangohudFpsLimit: 0,
        mangohudToggleKey: "Shift_R+F12",
        gsEnabled: true,
        gsWindowMode: "fullscreen",
        gsOutRes: "native",
        gsInRes: "same",
        gsFilter: "none",
        gsSharpness: 5,
        gsFpsLimit: 0,
        gsAdaptiveSync: true,
        gsHdr: false,
        gsGrabCursor: true,
        gsMangoApp: true,
        gameGamemode: true,
        gameProtonWayland: false,
        gameProtonHdr: false,
        gameProtonNtsync: true,
        termShell: "",
        termFontSize: 13,
        termRows: 24,
        termOpacity: 0.94,
        termCursorStyle: "block",
        termKeepAlive: true,
        termShowChips: true,
        islandTerminal: false,
        aiProvider: "opencode",
        aiModel: "gemini-4-argon-contributor",
        aiTemperature: 0.7,
        aiSystemPrompt: "Ты — умный и лаконичный ассистент в десктоп-оболочке Oberon на Arch Linux (Wayland композитор Umbriel). Отвечай по делу, форматируй команды и код в блоках markdown.",
        aiIncludeSysinfo: true,
        islandAi: true,
        umbrielAudioReactive: true
    })

    Process {
        id: seedProc
        command: ["sh", "-c",
            "test -f " + shq(p.path) + " || { mkdir -p \"$(dirname " + shq(p.path) + ")\"; printf %s " + shq(p.defaultsJson) + " > " + shq(p.path) + "; }"]
    }

    FileView {
        id: file
        path: p.path
        watchChanges: true
        onFileChanged: reload()
        onLoadFailed: seedProc.running = true
        onLoadedChanged: if (loaded) p.fillMissingDefaults()
        adapter: JsonAdapter {
            id: a
            property real uiScale: 1
            property real cornerScale: 1
            property real motionScale: 1
            property real accentPunch: 1
            property real surfaceDarkness: -1
            property real surfaceTint: -1
            property real blurAmount: 45
            property int idleScreenMin: 10
            property int idleLockMin: 0
            property int idleSuspendMin: 60
            property bool islandLayout: true
            property bool islandWeather: true
            property bool islandClock: true
            property bool islandWorkspaces: true
            property bool islandTray: true
            property bool clockSeconds: true
            property bool clock12: false
            property bool clockWeekday: true
            property string clockDateFmt: "d MMMM"
            property int toastSeconds: 5
            property int notifTimeout: 5
            property int notifCritTimeout: 0
            property bool notifPreview: true
            property bool weatherAuto: true
            property string weatherCity: ""
            property real weatherLat: 0
            property real weatherLon: 0
            property string weatherPlace: ""
            property bool dnd: false
            property string themeScheme: "auto"
            property real themeContrast: 0
            property string themeMode: "auto"
            property var islandOrder: ["kb", "weather", "ws", "clock", "tray"]
            property bool islandAllScreens: false
            property string barStyle: "island"
            property string islandPos: "top"
            property int islandHeight: 34
            property int islandWidth: 0
            property int islandExpandedWidth: 960
            property int islandExpandedHeight: 0
            property int islandGap: 6
            property int islandRadius: 17
            property bool notchMode: false
            property int notchFlare: 12
            property bool islandAutoHide: false
            property bool islandDrag: false
            property bool systemLoadOnIsland: false
            property string mediaStyle: "cover"
            property bool soundsEnabled: true
            property bool nightLightEnabled: false
            property int nightLightTemp: 4500
            property string nightLightMode: "manual"
            property string nightLightFrom: "22:00"
            property string nightLightTo: "07:00"
            property bool dndScheduleEnabled: false
            property string dndFrom: "23:00"
            property string dndTo: "07:00"
            property int recordFps: 60
            property string recordDir: "~/Videos"
            property bool recordAudio: true
            property bool recordMic: false
            property string recordMicSource: ""
            property string tilesOrder: ""
            property string tilesHidden: ""
            property bool widgetsEnabled: false
            property var widgetsLayout: ({})
            property bool mangohudEnabled: false
            property bool mangohudFPS: true
            property bool mangohudCPU: true
            property bool mangohudGPU: true
            property bool mangohudRAM: true
            property bool mangohudVRAM: false
            property bool mangohudFrameTime: true
            property bool mangohudVersion: false
            property bool mangohudEngine: false
            property bool mangohudIO: false
            property bool mangohudMedia: false
            property real mangohudHudAlpha: 1.0
            property string mangohudPosition: "top-left"
            property bool mangohudHorizontal: false
            property int mangohudFpsLimit: 0
            property string mangohudToggleKey: "Shift_R+F12"
            property bool gsEnabled: true
            property string gsWindowMode: "fullscreen"
            property string gsOutRes: "native"
            property string gsInRes: "same"
            property string gsFilter: "none"
            property int gsSharpness: 5
            property int gsFpsLimit: 0
            property bool gsAdaptiveSync: true
            property bool gsHdr: false
            property bool gsGrabCursor: true
            property bool gsMangoApp: true
            property bool gameGamemode: true
            property bool gameProtonWayland: false
            property bool gameProtonHdr: false
            property bool gameProtonNtsync: true
            property string termShell: ""
            property int termFontSize: 13
            property int termRows: 24
            property real termOpacity: 0.94
            property string termCursorStyle: "block"
            property bool termKeepAlive: true
            property bool termShowChips: true
            property bool islandTerminal: false
            property string aiProvider: "opencode"
            property string aiModel: "gemini-4-argon-contributor"
            property real aiTemperature: 0.7
            property string aiSystemPrompt: "Ты — умный и лаконичный ассистент в десктоп-оболочке Oberon на Arch Linux (Wayland композитор Umbriel). Отвечай по делу, форматируй команды и код в блоках markdown."
            property bool aiIncludeSysinfo: true
            property bool islandAi: true
            property bool umbrielAudioReactive: true
        }
    }

    Timer {
        id: saveTimer
        interval: 200
        onTriggered: file.writeAdapter()
    }

    readonly property real uiScale: a.uiScale
    readonly property real cornerScale: a.cornerScale
    readonly property real motionScale: a.motionScale
    readonly property real accentPunch: a.accentPunch
    readonly property real surfaceDarkness: a.surfaceDarkness
    readonly property real surfaceTint: a.surfaceTint
    readonly property real blurAmount: a.blurAmount
    readonly property int idleScreenMin: a.idleScreenMin
    readonly property int idleLockMin: a.idleLockMin
    readonly property int idleSuspendMin: a.idleSuspendMin
    readonly property bool islandLayout: a.islandLayout
    readonly property bool islandWeather: a.islandWeather
    readonly property bool islandClock: a.islandClock
    readonly property bool islandWorkspaces: a.islandWorkspaces
    readonly property bool islandTray: a.islandTray
    readonly property bool clockSeconds: a.clockSeconds
    readonly property bool clock12: a.clock12
    readonly property bool clockWeekday: a.clockWeekday
    readonly property string clockDateFmt: a.clockDateFmt
    readonly property int toastSeconds: a.toastSeconds
    readonly property int notifTimeout: a.notifTimeout
    readonly property int notifCritTimeout: a.notifCritTimeout
    readonly property bool notifPreview: a.notifPreview
    readonly property bool weatherAuto: a.weatherAuto
    readonly property string weatherCity: a.weatherCity
    readonly property real weatherLat: a.weatherLat
    readonly property real weatherLon: a.weatherLon
    readonly property string weatherPlace: a.weatherPlace
    readonly property bool dnd: a.dnd
    readonly property string themeScheme: a.themeScheme
    readonly property real themeContrast: a.themeContrast
    readonly property string themeMode: a.themeMode
    readonly property var islandOrder: a.islandOrder
    readonly property bool islandAllScreens: a.islandAllScreens
    readonly property string barStyle: a.barStyle
    readonly property string islandPos: a.islandPos
    readonly property int islandHeight: a.islandHeight
    readonly property int islandWidth: a.islandWidth
    readonly property int islandExpandedWidth: a.islandExpandedWidth
    readonly property int islandExpandedHeight: a.islandExpandedHeight
    readonly property int islandGap: a.islandGap
    readonly property int islandRadius: a.islandRadius
    readonly property bool notchMode: a.notchMode
    readonly property int notchFlare: a.notchFlare
    readonly property bool islandAutoHide: a.islandAutoHide
    readonly property bool islandDrag: a.islandDrag
    readonly property bool systemLoadOnIsland: a.systemLoadOnIsland
    readonly property string mediaStyle: a.mediaStyle
    readonly property bool soundsEnabled: a.soundsEnabled
    readonly property bool nightLightEnabled: a.nightLightEnabled
    readonly property int nightLightTemp: a.nightLightTemp
    readonly property string nightLightMode: a.nightLightMode
    readonly property string nightLightFrom: a.nightLightFrom
    readonly property string nightLightTo: a.nightLightTo
    readonly property bool dndScheduleEnabled: a.dndScheduleEnabled
    readonly property string dndFrom: a.dndFrom
    readonly property string dndTo: a.dndTo
    readonly property int recordFps: a.recordFps
    readonly property string recordDir: a.recordDir
    readonly property bool recordAudio: a.recordAudio
    readonly property bool recordMic: a.recordMic
    readonly property string recordMicSource: a.recordMicSource
    readonly property string tilesOrder: a.tilesOrder
    readonly property string tilesHidden: a.tilesHidden
    readonly property bool widgetsEnabled: a.widgetsEnabled
    readonly property var widgetsLayout: a.widgetsLayout
    readonly property bool mangohudEnabled: a.mangohudEnabled
    readonly property bool mangohudFPS: a.mangohudFPS
    readonly property bool mangohudCPU: a.mangohudCPU
    readonly property bool mangohudGPU: a.mangohudGPU
    readonly property bool mangohudRAM: a.mangohudRAM
    readonly property bool mangohudVRAM: a.mangohudVRAM
    readonly property bool mangohudFrameTime: a.mangohudFrameTime
    readonly property bool mangohudVersion: a.mangohudVersion
    readonly property bool mangohudEngine: a.mangohudEngine
    readonly property bool mangohudIO: a.mangohudIO
    readonly property bool mangohudMedia: a.mangohudMedia
    readonly property real mangohudHudAlpha: a.mangohudHudAlpha
    readonly property string mangohudPosition: a.mangohudPosition
    readonly property bool mangohudHorizontal: a.mangohudHorizontal
    readonly property int mangohudFpsLimit: a.mangohudFpsLimit
    readonly property string mangohudToggleKey: a.mangohudToggleKey
    readonly property bool gsEnabled: a.gsEnabled
    readonly property string gsWindowMode: a.gsWindowMode
    readonly property string gsOutRes: a.gsOutRes
    readonly property string gsInRes: a.gsInRes
    readonly property string gsFilter: a.gsFilter
    readonly property int gsSharpness: a.gsSharpness
    readonly property int gsFpsLimit: a.gsFpsLimit
    readonly property bool gsAdaptiveSync: a.gsAdaptiveSync
    readonly property bool gsHdr: a.gsHdr
    readonly property bool gsGrabCursor: a.gsGrabCursor
    readonly property bool gsMangoApp: a.gsMangoApp
    readonly property bool gameGamemode: a.gameGamemode
    readonly property bool gameProtonWayland: a.gameProtonWayland
    readonly property bool gameProtonHdr: a.gameProtonHdr
    readonly property bool gameProtonNtsync: a.gameProtonNtsync
    readonly property string termShell: a.termShell
    readonly property int termFontSize: a.termFontSize
    readonly property int termRows: a.termRows
    readonly property real termOpacity: a.termOpacity
    readonly property string termCursorStyle: a.termCursorStyle
    readonly property bool termKeepAlive: a.termKeepAlive
    readonly property bool termShowChips: a.termShowChips
    readonly property bool islandTerminal: a.islandTerminal
    readonly property string aiProvider: a.aiProvider
    readonly property string aiModel: a.aiModel
    readonly property real aiTemperature: a.aiTemperature
    readonly property string aiSystemPrompt: a.aiSystemPrompt
    readonly property bool aiIncludeSysinfo: a.aiIncludeSysinfo
    readonly property bool islandAi: a.islandAi
    readonly property bool umbrielAudioReactive: a.umbrielAudioReactive

    // Инстанцирование ленивых синглтонов: без ссылки на них QML их не создаёт,
    // и NightLight/Sounds никогда бы не отреагировали на эти префы.
    // (Сами они читают Prefs — зацикливания нет: это простые биндинги.)
    readonly property bool soundsHook: Sounds.enabled
    readonly property bool nightLightHook: NightLight.active

    // Добить ключи, которых нет в существующем файле: JsonAdapter оставляет
    // их неопределёнными — иначе ловим "Unable to assign [undefined] to bool".
    function fillMissingDefaults() {
        const d = JSON.parse(p.defaultsJson);
        // Сверяемся с фактическим JSON: свойства адаптера отдают дефолт из QML,
        // поэтому a[k] === undefined не ловит отсутствующий ключ.
        let cur = {};
        try { cur = JSON.parse(file.text() || "{}"); } catch (e) { cur = {}; }
        let fixed = false;
        // writeAdapter сериализует весь адаптер, а не только новые поля.
        // Сначала заносим уже существующие значения из JSON обратно в него,
        // чтобы добавление дефолтов не перезаписало legacy-настройки.
        for (const k of Object.keys(cur))
            if (k in d)
                a[k] = cur[k];
        for (const k of Object.keys(d)) {
            if (!(k in cur)) {
                // barStyle="notch" существовал до отдельного переключателя;
                // переносим его только при отсутствии нового ключа, не меняя
                // ни исходный barStyle, ни явно заданный notchMode.
                a[k] = k === "notchMode" && cur.barStyle === "notch" ? true : d[k];
                fixed = true;
            }
        }
        if (fixed) file.writeAdapter();
    }

    function reset() {
        const d = JSON.parse(p.defaultsJson);
        for (const k of Object.keys(d))
            a[k] = d[k];
        saveTimer.restart();
    }

    // Установить значение (ключ = имя свойства адаптера) и сохранить файл с debounce.
    function _sameValue(current, value) {
        if (current === value)
            return true;
        if (current === null || value === null || typeof current !== "object" || typeof value !== "object")
            return false;
        try { return JSON.stringify(current) === JSON.stringify(value); }
        catch (e) { return false; }
    }

    function set(key, value) {
        if (p._sameValue(a[key], value))
            return;
        a[key] = value;
        saveTimer.restart();
    }

    Component.onCompleted: {
        if (!file.loaded)
            seedProc.running = true;
        else
            fillMissingDefaults();
    }
}
