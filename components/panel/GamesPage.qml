import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../core"
import "../../ui"
import ".."

// Страница «Игры»: Игровой хаб Oberon —
// 1) Конструктор запуска Gamescope + Proton + GameMode + диагностика стека Arch
// 2) Менеджер параметров запуска установленных игр Steam (localconfig.vdf)
// 3) Настройка оверлея MangoHud (~/.config/MangoHud/MangoHud.conf)
ColumnLayout {
    id: gamesPage

    property var win: null
    property string subTab: "gamescope"

    // Статус копирования команды
    property bool copiedFeedback: false

    // Состояние Steam-библиотеки
    property bool steamLoading: false
    property bool steamRunning: false
    property string steamLocalConfig: ""
    property var steamGames: []
    property string steamStatusMsg: ""
    property string applyingAppId: ""

    // Состояние проверки игрового стека Arch
    property var sysStack: ({
        "gamescope": false,
        "gamemoded": false,
        "mangohud": false,
        "ntsync": false,
        "governor": "—"
    })

    visible: win !== null && win.mode === "panel" && win.page === "games"
    Layout.fillWidth: true
    spacing: Theme.pageSpacing

    // Реактивно собираемая строка параметров запуска Steam (%command%)
    readonly property string generatedCommand: {
        let parts = [];

        if (Prefs.gameProtonWayland)
            parts.push("PROTON_ENABLE_WAYLAND=1");
        if (Prefs.gameProtonNtsync)
            parts.push("PROTON_USE_NTSYNC=1");
        if (Prefs.gameProtonHdr)
            parts.push("PROTON_ENABLE_HDR=1");

        if (Prefs.gsEnabled) {
            let gs = ["gamescope"];
            if (Prefs.gsWindowMode === "fullscreen")
                gs.push("-f");
            else if (Prefs.gsWindowMode === "borderless")
                gs.push("-b");

            if (Prefs.gsOutRes !== "native") {
                const wh = String(Prefs.gsOutRes).split("x");
                if (wh.length === 2) {
                    gs.push("-W " + wh[0]);
                    gs.push("-H " + wh[1]);
                }
            }

            if (Prefs.gsInRes !== "same") {
                const wh = String(Prefs.gsInRes).split("x");
                if (wh.length === 2) {
                    gs.push("-w " + wh[0]);
                    gs.push("-h " + wh[1]);
                }
            }

            if (Prefs.gsFilter === "fsr") {
                gs.push("-F fsr");
                gs.push("--fsr-sharpness " + String(Prefs.gsSharpness));
            } else if (Prefs.gsFilter === "nis") {
                gs.push("-F nis");
                gs.push("--nis-sharpness " + String(Prefs.gsSharpness));
            } else if (Prefs.gsFilter === "pixel") {
                gs.push("-F pixel");
            }

            if (Prefs.gsFpsLimit > 0)
                gs.push("-r " + String(Prefs.gsFpsLimit));

            if (Prefs.gsAdaptiveSync)
                gs.push("--adaptive-sync");
            if (Prefs.gsHdr)
                gs.push("--hdr-enabled");
            if (Prefs.gsGrabCursor)
                gs.push("--force-grab-cursor");
            if (Prefs.gsMangoApp)
                gs.push("--mangoapp");

            gs.push("--");
            parts.push(gs.join(" "));
        }

        if (Prefs.gameGamemode)
            parts.push("gamemoderun");

        if (Prefs.mangohudEnabled && (!Prefs.gsEnabled || !Prefs.gsMangoApp))
            parts.push("mangohud");

        parts.push("%command%");
        return parts.join(" ");
    }

    onVisibleChanged: {
        if (visible) {
            gamesPage.probeSystemStack();
            gamesPage.refreshSteamGames();
        }
    }

    Component.onCompleted: {
        if (gamesPage.visible) {
            gamesPage.probeSystemStack();
            gamesPage.refreshSteamGames();
        }
    }

    // ── Процесс проверки игрового стека Arch ───────────────────────────
    Process {
        id: stackProbeProc
        command: [
            "sh", "-c",
            "gs=false; command -v gamescope >/dev/null 2>&1 && gs=true; " +
            "gm=false; command -v gamemoderun >/dev/null 2>&1 && gm=true; " +
            "mh=false; command -v mangohud >/dev/null 2>&1 && mh=true; " +
            "nt=false; [ -e /dev/ntsync ] && nt=true; " +
            "gov='—'; [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ] && gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor | tr -d '\\n'); " +
            "printf '{\"gamescope\":%s,\"gamemoded\":%s,\"mangohud\":%s,\"ntsync\":%s,\"governor\":\"%s\"}\\n' \"$gs\" \"$gm\" \"$mh\" \"$nt\" \"$gov\""
        ]
        stdout: SplitParser {
            onRead: (line) => {
                try {
                    gamesPage.sysStack = JSON.parse(line);
                } catch (e) {}
            }
        }
    }

    function probeSystemStack() {
        stackProbeProc.running = false;
        stackProbeProc.running = true;
    }

    // ── Процесс чтения списка игр Steam ────────────────────────────────
    Process {
        id: steamListProc
        command: ["python3", Quickshell.env("HOME") + "/oberon/tools/set-steam-launch.py", "--list"]
        onExited: gamesPage.steamLoading = false
        stdout: SplitParser {
            onRead: (line) => {
                try {
                    const data = JSON.parse(line);
                    gamesPage.steamRunning = !!data.steam_running;
                    gamesPage.steamLocalConfig = data.localconfig || "";
                    gamesPage.steamGames = data.games || [];
                } catch (e) {}
            }
        }
    }

    // ── Процесс записи параметров запуска для выбранной игры ───────────
    Process {
        id: steamSetProc
        property string targetAppId: ""
        property string targetOptions: ""
        command: [
            "python3",
            Quickshell.env("HOME") + "/oberon/tools/set-steam-launch.py",
            "--kill-steam",
            steamSetProc.targetAppId,
            steamSetProc.targetOptions
        ]
        onExited: (code) => {
            gamesPage.applyingAppId = "";
            if (code === 0) {
                gamesPage.steamStatusMsg = "Параметры сохранены для AppID " + steamSetProc.targetAppId;
                steamMsgTimer.restart();
            } else {
                gamesPage.steamStatusMsg = "Ошибка сохранения (код " + code + ")";
                steamMsgTimer.restart();
            }
            gamesPage.refreshSteamGames();
        }
    }

    Timer {
        id: steamMsgTimer
        interval: 3000
        onTriggered: gamesPage.steamStatusMsg = ""
    }

    Timer {
        id: copyResetTimer
        interval: 1800
        onTriggered: gamesPage.copiedFeedback = false
    }

    function refreshSteamGames() {
        gamesPage.steamLoading = true;
        steamListProc.running = false;
        steamListProc.running = true;
    }

    function applySteamLaunch(appid, optionsStr) {
        if (steamSetProc.running)
            return;
        gamesPage.applyingAppId = String(appid);
        steamSetProc.targetAppId = String(appid);
        steamSetProc.targetOptions = String(optionsStr);
        steamSetProc.running = true;
    }

    function copyLaunchCommand() {
        Quickshell.execDetached(["wl-copy", gamesPage.generatedCommand]);
        gamesPage.copiedFeedback = true;
        copyResetTimer.restart();
    }

    // ── Вкладки разделов ───────────────────────────────────────────────
    Tabs {
        Layout.fillWidth: true
        inline: true
        current: gamesPage.subTab
        options: [
            { key: "gamescope", label: "Gamescope и Proton", icon: "sports_esports" },
            { key: "steam", label: "Игры Steam", icon: "videogame_asset" },
            { key: "mangohud", label: "Оверлей MangoHud", icon: "monitoring" }
        ]
        onPicked: (k) => {
            gamesPage.subTab = k;
            if (k === "steam")
                gamesPage.refreshSteamGames();
            else if (k === "gamescope")
                gamesPage.probeSystemStack();
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // 1. ВКЛАДКА «GAMESCOPE И PROTON»
    // ══════════════════════════════════════════════════════════════════
    ColumnLayout {
        visible: gamesPage.subTab === "gamescope"
        Layout.fillWidth: true
        spacing: Theme.dp(12)

        // Карточка собранной команды запуска
        Card {
            Layout.fillWidth: true
            title: "Готовая строка параметров запуска Steam"

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.dp(10)

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: Math.max(Theme.dp(44), cmdText.implicitHeight + Theme.dp(16))
                    radius: Theme.radiusSm
                    color: Theme.bgTrack
                    border.width: 1
                    border.color: Theme.outline

                    LText {
                        id: cmdText
                        anchors.fill: parent
                        anchors.margins: Theme.dp(10)
                        role: "bodyMedium"
                        mono: true
                        color: Theme.primary
                        wrapMode: Text.WrapAnywhere
                        text: gamesPage.generatedCommand
                    }
                }

                Button {
                    variant: "filled"
                    size: "s"
                    icon: gamesPage.copiedFeedback ? "check" : "content_copy"
                    text: gamesPage.copiedFeedback ? "Скопировано!" : "Скопировать"
                    onClicked: gamesPage.copyLaunchCommand()
                }

                Button {
                    variant: "tonal"
                    size: "s"
                    icon: "arrow_forward"
                    text: "В Steam →"
                    onClicked: {
                        gamesPage.subTab = "steam";
                        gamesPage.refreshSteamGames();
                    }
                }
            }
        }

        // Двухколоночная сетка: слева Gamescope, справа Proton/GameMode + Статус стека
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            // ── ЛЕВАЯ КОЛОНКА: GAMESCOPE ───────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                Layout.alignment: Qt.AlignTop
                spacing: Theme.dp(12)

                Card {
                    Layout.fillWidth: true
                    title: "Микрокомпозитор Gamescope"

                    ToggleRow {
                        label: "Использовать Gamescope"
                        sub: "Запускать игру в изолированном Wayland-микрокомпозиторе Valve"
                        icon: "fullscreen"
                        checked: Prefs.gsEnabled
                        onToggled: (v) => Prefs.set("gsEnabled", v)
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        enabled: Prefs.gsEnabled
                        opacity: Prefs.gsEnabled ? 1.0 : Theme.disabledContent
                        spacing: Theme.dp(10)

                        // Режим окна
                        LText {
                            role: "labelSmall"
                            color: Theme.subtext
                            text: "РЕЖИМ ОКНА"
                            Layout.topMargin: Theme.dp(4)
                        }
                        ButtonGroup {
                            Layout.fillWidth: true
                            size: "xs"
                            current: Prefs.gsWindowMode
                            options: [
                                { key: "fullscreen", label: "Полный экран (-f)" },
                                { key: "borderless", label: "Без рамок (-b)" },
                                { key: "windowed", label: "В окне" }
                            ]
                            onPicked: (k) => Prefs.set("gsWindowMode", k)
                        }

                        // Разрешение вывода (-W / -H)
                        LText {
                            role: "labelSmall"
                            color: Theme.subtext
                            text: "РАЗРЕШЕНИЕ ВЫВОДА (-W / -H)"
                            Layout.topMargin: Theme.dp(4)
                        }
                        Flow {
                            Layout.fillWidth: true
                            spacing: Theme.dp(6)

                            Repeater {
                                model: [
                                    { key: "native", label: "Экран (Авто)" },
                                    { key: "3840x2160", label: "4K (2160p)" },
                                    { key: "2560x1440", label: "2K (1440p)" },
                                    { key: "1920x1080", label: "1080p" }
                                ]
                                delegate: Chip {
                                    required property var modelData
                                    size: "sm"
                                    label: modelData.label
                                    selected: Prefs.gsOutRes === modelData.key
                                    onClicked: Prefs.set("gsOutRes", modelData.key)
                                }
                            }
                        }

                        // Внутреннее разрешение игры (-w / -h)
                        LText {
                            role: "labelSmall"
                            color: Theme.subtext
                            text: "ВНУТРЕННЕЕ РАЗРЕШЕНИЕ ИГРЫ (-w / -h)"
                            Layout.topMargin: Theme.dp(4)
                        }
                        Flow {
                            Layout.fillWidth: true
                            spacing: Theme.dp(6)

                            Repeater {
                                model: [
                                    { key: "same", label: "Как вывод" },
                                    { key: "2560x1440", label: "1440p" },
                                    { key: "1920x1080", label: "1080p" },
                                    { key: "1600x900", label: "900p" },
                                    { key: "1280x720", label: "720p" }
                                ]
                                delegate: Chip {
                                    required property var modelData
                                    size: "sm"
                                    label: modelData.label
                                    selected: Prefs.gsInRes === modelData.key
                                    onClicked: Prefs.set("gsInRes", modelData.key)
                                }
                            }
                        }

                        // Апскейлер (-F)
                        LText {
                            role: "labelSmall"
                            color: Theme.subtext
                            text: "ФИЛЬТР МАСШТАБИРОВАНИЯ (-F)"
                            Layout.topMargin: Theme.dp(4)
                        }
                        ButtonGroup {
                            Layout.fillWidth: true
                            size: "xs"
                            current: Prefs.gsFilter
                            options: [
                                { key: "none", label: "Выкл" },
                                { key: "fsr", label: "AMD FSR" },
                                { key: "nis", label: "NVIDIA NIS" },
                                { key: "pixel", label: "Pixel" }
                            ]
                            onPicked: (k) => Prefs.set("gsFilter", k)
                        }

                        // Слайдер резкости (виден при fsr или nis)
                        RowLayout {
                            visible: Prefs.gsFilter === "fsr" || Prefs.gsFilter === "nis"
                            Layout.fillWidth: true
                            spacing: Theme.dp(8)

                            LText {
                                Layout.fillWidth: true
                                role: "bodyMedium"
                                color: Theme.text
                                text: "Резкость (Sharpness)"
                            }
                            LText {
                                role: "labelLarge"
                                tabular: true
                                color: Theme.primary
                                text: String(Prefs.gsSharpness)
                            }
                            Slider {
                                Layout.preferredWidth: Theme.dp(150)
                                from: 0
                                to: 20
                                stepSize: 1
                                showValue: false
                                value: Prefs.gsSharpness
                                onMoved: (v) => Prefs.set("gsSharpness", Math.round(v))
                            }
                        }

                        // Лимит FPS (-r)
                        LText {
                            role: "labelSmall"
                            color: Theme.subtext
                            text: "ЛИМИТ ЧАСТОТЫ КАДРОВ (-r)"
                            Layout.topMargin: Theme.dp(4)
                        }
                        Flow {
                            Layout.fillWidth: true
                            spacing: Theme.dp(6)

                            Repeater {
                                model: [
                                    { key: 0, label: "Без лимита" },
                                    { key: 60, label: "60" },
                                    { key: 120, label: "120" },
                                    { key: 144, label: "144" },
                                    { key: 165, label: "165" },
                                    { key: 240, label: "240" }
                                ]
                                delegate: Chip {
                                    required property var modelData
                                    size: "sm"
                                    label: modelData.label
                                    selected: Prefs.gsFpsLimit === modelData.key
                                    onClicked: Prefs.set("gsFpsLimit", modelData.key)
                                }
                            }
                        }

                        // Дополнительные флаги Gamescope
                        ToggleRow {
                            label: "Adaptive Sync (VRR)"
                            sub: "Переменная частота обновления (--adaptive-sync)"
                            checked: Prefs.gsAdaptiveSync
                            onToggled: (v) => Prefs.set("gsAdaptiveSync", v)
                        }
                        ToggleRow {
                            label: "HDR вывод"
                            sub: "Расширенный динамический диапазон (--hdr-enabled)"
                            checked: Prefs.gsHdr
                            onToggled: (v) => Prefs.set("gsHdr", v)
                        }
                        ToggleRow {
                            label: "Захват курсора"
                            sub: "Удерживать мышь внутри окна игры (--force-grab-cursor)"
                            checked: Prefs.gsGrabCursor
                            onToggled: (v) => Prefs.set("gsGrabCursor", v)
                        }
                        ToggleRow {
                            label: "Встроенный MangoApp"
                            sub: "Оверлей MangoHud на уровне композитора (--mangoapp)"
                            checked: Prefs.gsMangoApp
                            onToggled: (v) => Prefs.set("gsMangoApp", v)
                        }
                    }
                }
            }

            // ── ПРАВАЯ КОЛОНКА: PROTON, GAMEMODE И СТЕК ARCH ───────────
            ColumnLayout {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                Layout.alignment: Qt.AlignTop
                spacing: Theme.dp(12)

                Card {
                    Layout.fillWidth: true
                    title: "Окружение и Врапперы"

                    ToggleRow {
                        label: "Feral GameMode (gamemoderun)"
                        sub: "Переводит CPU governor в performance и повышает приоритет процесса"
                        icon: "bolt"
                        checked: Prefs.gameGamemode
                        onToggled: (v) => Prefs.set("gameGamemode", v)
                    }

                    ToggleRow {
                        label: "MangoHud враппер (mangohud)"
                        sub: "Используется, когда Gamescope или --mangoapp выключены"
                        icon: "monitoring"
                        checked: Prefs.mangohudEnabled
                        onToggled: (v) => {
                            Prefs.set("mangohudEnabled", v);
                            gamesPage.scheduleMangoHudApply();
                        }
                    }

                    ToggleRow {
                        label: "Proton Native Wayland"
                        sub: "PROTON_ENABLE_WAYLAND=1 — нативный вывод без Xwayland"
                        icon: "desktop_windows"
                        checked: Prefs.gameProtonWayland
                        onToggled: (v) => Prefs.set("gameProtonWayland", v)
                    }

                    ToggleRow {
                        label: "Proton NTSYNC"
                        sub: "PROTON_USE_NTSYNC=1 — быстрые примитивы синхронизации ядра Linux"
                        icon: "memory"
                        checked: Prefs.gameProtonNtsync
                        onToggled: (v) => Prefs.set("gameProtonNtsync", v)
                    }

                    ToggleRow {
                        label: "Proton HDR"
                        sub: "PROTON_ENABLE_HDR=1 — передача HDR-метаданных из игры"
                        icon: "hdr_on"
                        checked: Prefs.gameProtonHdr
                        onToggled: (v) => Prefs.set("gameProtonHdr", v)
                    }
                }

                Card {
                    Layout.fillWidth: true
                    title: "Статус игрового стека Arch"
                    actionIcon: "refresh"
                    onActionClicked: gamesPage.probeSystemStack()

                    Repeater {
                        model: [
                            {
                                label: "Gamescope",
                                sub: "Микрокомпозитор Valve",
                                ok: !!gamesPage.sysStack.gamescope,
                                okText: "Установлен",
                                errText: "Не найден"
                            },
                            {
                                label: "Feral GameMode",
                                sub: "Демон gamemoded / gamemoderun",
                                ok: !!gamesPage.sysStack.gamemoded,
                                okText: "Установлен",
                                errText: "Не найден"
                            },
                            {
                                label: "MangoHud",
                                sub: "Оверлей мониторинга Vulkan/OpenGL",
                                ok: !!gamesPage.sysStack.mangohud,
                                okText: "Установлен",
                                errText: "Не найден"
                            },
                            {
                                label: "Ядро NTSYNC (/dev/ntsync)",
                                sub: "Драйвер синхронизации Windows NT",
                                ok: !!gamesPage.sysStack.ntsync,
                                okText: "Активен",
                                errText: "Нет модуля"
                            }
                        ]

                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.topMargin: Theme.dp(4)
                            Layout.bottomMargin: Theme.dp(4)
                            spacing: Theme.dp(8)

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                LText {
                                    role: "bodyMedium"
                                    color: Theme.text
                                    text: modelData.label
                                }
                                LText {
                                    role: "bodySmall"
                                    color: Theme.subtext
                                    text: modelData.sub
                                }
                            }

                            Badge {
                                text: modelData.ok ? modelData.okText : modelData.errText
                                tone: modelData.ok ? "accent" : "neutral"
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: Theme.dp(4)
                        spacing: Theme.dp(8)

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            LText {
                                role: "bodyMedium"
                                color: Theme.text
                                text: "Регулятор частот CPU"
                            }
                            LText {
                                role: "bodySmall"
                                color: Theme.subtext
                                text: "scaling_governor (cpu0)"
                            }
                        }

                        Badge {
                            text: gamesPage.sysStack.governor || "—"
                            tone: gamesPage.sysStack.governor === "performance" ? "accent" : "neutral"
                        }
                    }
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // 2. ВКЛАДКА «ИГРЫ STEAM» (localconfig.vdf)
    // ══════════════════════════════════════════════════════════════════
    ColumnLayout {
        visible: gamesPage.subTab === "steam"
        Layout.fillWidth: true
        spacing: Theme.dp(12)

        Card {
            Layout.fillWidth: true

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.dp(10)

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(2)

                    RowLayout {
                        spacing: Theme.dp(8)
                        LText {
                            role: "titleSmall"
                            color: Theme.text
                            text: "Установленные игры Steam (" + gamesPage.steamGames.length + ")"
                        }
                        Badge {
                            text: gamesPage.steamRunning ? "Steam запущен" : "Steam закрыт"
                            tone: gamesPage.steamRunning ? "error" : "neutral"
                        }
                    }

                    LText {
                        role: "bodySmall"
                        color: gamesPage.steamStatusMsg !== "" ? Theme.primary : Theme.subtext
                        text: gamesPage.steamStatusMsg !== ""
                            ? gamesPage.steamStatusMsg
                            : (gamesPage.steamLocalConfig !== "" ? gamesPage.steamLocalConfig : "Конфигурация Steam (localconfig.vdf)")
                        elide: Text.ElideMiddle
                        Layout.fillWidth: true
                    }
                }

                Button {
                    variant: "tonal"
                    size: "s"
                    icon: "refresh"
                    text: "Обновить список"
                    disabled: gamesPage.steamLoading
                    onClicked: gamesPage.refreshSteamGames()
                }
            }

            // Предупреждение, если Steam сейчас запущен
            Rectangle {
                visible: gamesPage.steamRunning
                Layout.fillWidth: true
                Layout.topMargin: Theme.dp(6)
                implicitHeight: warnRow.implicitHeight + Theme.dp(16)
                radius: Theme.radiusSm
                color: Theme.errorContainer

                RowLayout {
                    id: warnRow
                    anchors.fill: parent
                    anchors.margins: Theme.dp(8)
                    spacing: Theme.dp(8)

                    Icon {
                        name: "info"
                        size: Theme.dp(18)
                        color: Theme.fgErrorContainer
                    }
                    LText {
                        Layout.fillWidth: true
                        role: "bodySmall"
                        color: Theme.fgErrorContainer
                        wrapMode: Text.WordWrap
                        text: "Steam сейчас запущен — при записи параметров он будет автоматически закрыт, чтобы не затереть localconfig.vdf"
                    }
                }
            }

            // Текущий активный пресет для быстрой сверки
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.dp(4)
                spacing: Theme.dp(8)

                LText {
                    role: "labelSmall"
                    color: Theme.subtext
                    text: "ТЕКУЩИЙ ПРЕСЕТ:"
                }
                LText {
                    Layout.fillWidth: true
                    role: "bodySmall"
                    mono: true
                    color: Theme.primary
                    elide: Text.ElideRight
                    text: gamesPage.generatedCommand
                }
            }
        }

        // Пустое состояние, если игры не найдены
        Card {
            visible: !gamesPage.steamLoading && gamesPage.steamGames.length === 0
            Layout.fillWidth: true

            ColumnLayout {
                Layout.fillWidth: true
                Layout.margins: Theme.dp(12)
                spacing: Theme.dp(6)

                LText {
                    role: "titleSmall"
                    color: Theme.text
                    text: "Установленные игры Steam не найдены"
                }
                LText {
                    Layout.fillWidth: true
                    role: "bodySmall"
                    color: Theme.subtext
                    wrapMode: Text.WordWrap
                    text: "Проверьте наличие манифестов ~/.local/share/Steam/steamapps/appmanifest_*.acf или скопируйте строку запуска вручную на вкладке «Gamescope и Proton»."
                }
            }
        }

        // Список установленных игр Steam
        Repeater {
            model: gamesPage.steamGames

            delegate: Card {
                required property var modelData
                Layout.fillWidth: true

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(10)

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.dp(4)

                        RowLayout {
                            spacing: Theme.dp(8)
                            LText {
                                role: "titleSmall"
                                color: Theme.text
                                text: modelData.name || ("App " + modelData.appid)
                                elide: Text.ElideRight
                            }
                            Badge {
                                text: "ID " + modelData.appid
                                tone: "neutral"
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: Math.max(Theme.dp(28), gameOptText.implicitHeight + Theme.dp(10))
                            radius: Theme.radiusXs
                            color: Theme.bgTrack

                            LText {
                                id: gameOptText
                                anchors.fill: parent
                                anchors.leftMargin: Theme.dp(8)
                                anchors.rightMargin: Theme.dp(8)
                                anchors.topMargin: Theme.dp(5)
                                anchors.bottomMargin: Theme.dp(5)
                                role: "bodySmall"
                                mono: true
                                color: modelData.options ? Theme.primary : Theme.subtext
                                wrapMode: Text.WrapAnywhere
                                text: modelData.options ? modelData.options : "Параметры запуска не заданы (по умолчанию)"
                            }
                        }
                    }

                    Button {
                        variant: modelData.options === gamesPage.generatedCommand ? "tonal" : "filled"
                        size: "xs"
                        icon: modelData.options === gamesPage.generatedCommand ? "check" : "bolt"
                        text: gamesPage.applyingAppId === modelData.appid
                            ? "Запись…"
                            : (modelData.options === gamesPage.generatedCommand ? "Применено" : "Применить пресет")
                        disabled: gamesPage.applyingAppId !== ""
                        onClicked: gamesPage.applySteamLaunch(modelData.appid, gamesPage.generatedCommand)
                    }

                    Button {
                        variant: "outlined"
                        size: "xs"
                        icon: "ink_eraser"
                        text: "Очистить"
                        disabled: !modelData.options || gamesPage.applyingAppId !== ""
                        onClicked: gamesPage.applySteamLaunch(modelData.appid, "")
                    }

                    IconButton {
                        variant: "tonal"
                        size: "xs"
                        icon: "play_arrow"
                        tooltip: "Запустить игру в Steam"
                        onClicked: Quickshell.execDetached(["xdg-open", "steam://rungameid/" + modelData.appid])
                    }
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // 3. ВКЛАДКА «ОВЕРЛЕЙ MANGOHUD»
    // ══════════════════════════════════════════════════════════════════
    ColumnLayout {
        visible: gamesPage.subTab === "mangohud"
        Layout.fillWidth: true
        spacing: Theme.dp(12)

        Card {
            Layout.fillWidth: true
            title: "Внешний вид и расположение"

            ToggleRow {
                label: "Включить MangoHud"
                sub: "Отображать оверлей с метриками производительности в играх"
                icon: "monitoring"
                checked: Prefs.mangohudEnabled
                onToggled: (v) => {
                    Prefs.set("mangohudEnabled", v);
                    gamesPage.scheduleMangoHudApply();
                }
            }

            // Позиция на экране
            LText {
                role: "labelSmall"
                color: Theme.subtext
                text: "ПОЗИЦИЯ НА ЭКРАНЕ"
                Layout.topMargin: Theme.dp(6)
            }
            Flow {
                Layout.fillWidth: true
                spacing: Theme.dp(6)

                Repeater {
                    model: [
                        { key: "top-left", label: "Верх-лево" },
                        { key: "top-right", label: "Верх-право" },
                        { key: "bottom-left", label: "Низ-лево" },
                        { key: "bottom-right", label: "Низ-право" },
                        { key: "top-center", label: "Сверху по центру" }
                    ]
                    delegate: Chip {
                        required property var modelData
                        size: "sm"
                        label: modelData.label
                        selected: Prefs.mangohudPosition === modelData.key
                        onClicked: {
                            Prefs.set("mangohudPosition", modelData.key);
                            gamesPage.scheduleMangoHudApply();
                        }
                    }
                }
            }

            ToggleRow {
                label: "Горизонтальная компактная панель"
                sub: "Выстраивать метрики в одну строчку вдоль края экрана (horizontal)"
                checked: Prefs.mangohudHorizontal
                onToggled: (v) => {
                    Prefs.set("mangohudHorizontal", v);
                    gamesPage.scheduleMangoHudApply();
                }
            }

            // Лимит FPS в MangoHud
            LText {
                role: "labelSmall"
                color: Theme.subtext
                text: "ЛИМИТ FPS В MANGOHUD"
                Layout.topMargin: Theme.dp(6)
            }
            Flow {
                Layout.fillWidth: true
                spacing: Theme.dp(6)

                Repeater {
                    model: [
                        { key: 0, label: "Без лимита" },
                        { key: 60, label: "60" },
                        { key: 120, label: "120" },
                        { key: 144, label: "144" },
                        { key: 165, label: "165" },
                        { key: 240, label: "240" }
                    ]
                    delegate: Chip {
                        required property var modelData
                        size: "sm"
                        label: modelData.label
                        selected: Prefs.mangohudFpsLimit === modelData.key
                        onClicked: {
                            Prefs.set("mangohudFpsLimit", modelData.key);
                            gamesPage.scheduleMangoHudApply();
                        }
                    }
                }
            }

            // Хоткей скрытия
            LText {
                role: "labelSmall"
                color: Theme.subtext
                text: "КЛАВИША СКРЫТИЯ ОВЕРЛЕЯ (TOGGLE_HUD)"
                Layout.topMargin: Theme.dp(6)
            }
            Flow {
                Layout.fillWidth: true
                spacing: Theme.dp(6)

                Repeater {
                    model: [
                        { key: "Shift_R+F12", label: "Shift_R+F12" },
                        { key: "F12", label: "F12" },
                        { key: "Home", label: "Home" },
                        { key: "Insert", label: "Insert" }
                    ]
                    delegate: Chip {
                        required property var modelData
                        size: "sm"
                        label: modelData.label
                        selected: Prefs.mangohudToggleKey === modelData.key
                        onClicked: {
                            Prefs.set("mangohudToggleKey", modelData.key);
                            gamesPage.scheduleMangoHudApply();
                        }
                    }
                }
            }

            // Слайдер прозрачности
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.dp(6)
                spacing: Theme.dp(8)

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    LText {
                        role: "bodyMedium"
                        color: Theme.text
                        text: "Прозрачность оверлея"
                    }
                    LText {
                        role: "bodySmall"
                        color: Theme.subtext
                        text: "0% — полностью прозрачный, 100% — непрозрачный"
                    }
                }
                LText {
                    role: "labelLarge"
                    tabular: true
                    color: Theme.text
                    text: Math.round(Prefs.mangohudHudAlpha * 100) + "%"
                }
                Slider {
                    id: hudAlphaSlider
                    Layout.preferredWidth: Theme.dp(180)
                    from: 0
                    to: 1
                    value: Prefs.mangohudHudAlpha
                    onMoved: (v) => {
                        const rounded = Math.round(v * 100) / 100;
                        Prefs.set("mangohudHudAlpha", rounded);
                    }
                    onCommitted: (v) => gamesPage.scheduleMangoHudApply()
                }
            }
        }

        // Двухколоночная сетка метрик MangoHud
        Card {
            Layout.fillWidth: true
            title: "Метрики оверлея"

            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: Theme.dp(12)
                rowSpacing: Theme.dp(4)

                ToggleRow {
                    Layout.fillWidth: true
                    label: "FPS"
                    sub: "Кадры в секунду"
                    checked: Prefs.mangohudFPS
                    onToggled: (v) => { Prefs.set("mangohudFPS", v); gamesPage.scheduleMangoHudApply(); }
                }
                ToggleRow {
                    Layout.fillWidth: true
                    label: "Время кадра"
                    sub: "График Frame time (мс)"
                    checked: Prefs.mangohudFrameTime
                    onToggled: (v) => { Prefs.set("mangohudFrameTime", v); gamesPage.scheduleMangoHudApply(); }
                }
                ToggleRow {
                    Layout.fillWidth: true
                    label: "CPU"
                    sub: "Загрузка процессора"
                    checked: Prefs.mangohudCPU
                    onToggled: (v) => { Prefs.set("mangohudCPU", v); gamesPage.scheduleMangoHudApply(); }
                }
                ToggleRow {
                    Layout.fillWidth: true
                    label: "GPU"
                    sub: "Загрузка видеокарты"
                    checked: Prefs.mangohudGPU
                    onToggled: (v) => { Prefs.set("mangohudGPU", v); gamesPage.scheduleMangoHudApply(); }
                }
                ToggleRow {
                    Layout.fillWidth: true
                    label: "RAM"
                    sub: "Оперативная память"
                    checked: Prefs.mangohudRAM
                    onToggled: (v) => { Prefs.set("mangohudRAM", v); gamesPage.scheduleMangoHudApply(); }
                }
                ToggleRow {
                    Layout.fillWidth: true
                    label: "VRAM"
                    sub: "Видеопамять"
                    checked: Prefs.mangohudVRAM
                    onToggled: (v) => { Prefs.set("mangohudVRAM", v); gamesPage.scheduleMangoHudApply(); }
                }
                ToggleRow {
                    Layout.fillWidth: true
                    label: "Движок"
                    sub: "Графический API (Vulkan/DXVK)"
                    checked: Prefs.mangohudEngine
                    onToggled: (v) => { Prefs.set("mangohudEngine", v); gamesPage.scheduleMangoHudApply(); }
                }
                ToggleRow {
                    Layout.fillWidth: true
                    label: "Ввод-вывод"
                    sub: "Дисковый I/O (чтение/запись)"
                    checked: Prefs.mangohudIO
                    onToggled: (v) => { Prefs.set("mangohudIO", v); gamesPage.scheduleMangoHudApply(); }
                }
                ToggleRow {
                    Layout.fillWidth: true
                    label: "Версия"
                    sub: "Версия MangoHud в углу"
                    checked: Prefs.mangohudVersion
                    onToggled: (v) => { Prefs.set("mangohudVersion", v); gamesPage.scheduleMangoHudApply(); }
                }
                ToggleRow {
                    Layout.fillWidth: true
                    label: "Медиа"
                    sub: "Текущий трек MPRIS"
                    checked: Prefs.mangohudMedia
                    onToggled: (v) => { Prefs.set("mangohudMedia", v); gamesPage.scheduleMangoHudApply(); }
                }
            }
        }
    }

    Timer {
        id: mangoHudApplyTimer
        interval: 400
        onTriggered: if (!hudAlphaSlider.dragging) gamesPage.applyMangoHud()
    }

    function scheduleMangoHudApply() {
        mangoHudApplyTimer.restart();
    }

    // Применить настройки MangoHud: записать конфиг в ~/.config/MangoHud/MangoHud.conf
    function applyMangoHud() {
        Quickshell.execDetached(["sh", Quickshell.env("HOME") + "/oberon/scripts/apply-mangohud.sh"]);
    }
}
