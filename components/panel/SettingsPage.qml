import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../core"
import "../../ui"
import "../settings"
import ".."

// Страница «Настройки»: слева группы разделов и поиск, справа — M3-вкладки
// группы, история переходов, шапка и содержимое выбранного раздела.
// Внешний вид и погода пишут в Prefs → ~/oberon/prefs.json.
//
// Анатомия Lucid: рейл — иконка + подпись, выбранная запись залита
// secondaryContainer-пилюлей и иконка наполнена; контент — заголовок секции
// (LText titleLarge) и группы-карточки ui/Card со строками 56–64dp
// (заголовок bodyLarge + supporting bodySmall, trailing-контрол). Числовые
// значения — tabular-цифрами. Дивайдеров нет — воздух вместо линий.
RowLayout {
    id: page

    property var win: null
    property string sectionId: "look"
    property string query: ""
    property var history: ["look"]
    property int historyAt: 0
    property bool resetArmed: false
    property bool resetDone: false
    property var machineInfo: ({})
    property bool systemInfoCopied: false

    // имя монитора, на котором открыта панель (для раздела «Экран»)
    readonly property string outputName: page.win && page.win.screen ? String(page.win.screen.name) : ""
    // текущие значения настроек Umbriel, прочитанные из umbriel-settings.py
    property var umb: ({})
    property string umbError: ""
    property bool umbReadPending: false
    property bool umbReadStarted: false
    // Список выходов и режимов берём из машинного интерфейса Umbriel.
    property var outputs: []
    property string outputsBuffer: ""
    property string outputsError: ""
    property bool outputsReadPending: false
    property bool outputsReadStarted: false
    property string machineError: ""
    property bool machineReadPending: false
    property bool machineReadStarted: false
    readonly property var rootDisk: {
        const disks = SysStats.disks || [];
        for (let i = 0; i < disks.length; i++)
            if (String(disks[i].mount) === "/") return disks[i];
        return null;
    }

    visible: win !== null && win.mode === "panel" && win.page === "settings"
    Layout.fillWidth: true
    Layout.minimumHeight: win ? Math.min(Theme.dp(620), win.panelMax - Theme.dp(72)) : Theme.dp(620)
    spacing: Theme.dp(16)

    // При каждом открытии берём id от shell; числовые номера старой версии
    // остаются совместимыми для IPC/тайлов и старых вызовов.
    onVisibleChanged: {
        if (visible) {
            const id = page.sectionIdFor(page.win && page.win.shell ? page.win.shell.settingsSection : "look");
            page.sectionId = id;
            page.history = [id];
            page.historyAt = 0;
            if (page.win && page.win.shell && page.win.shell.settingsSection !== id)
                page.win.shell.settingsSection = id;
            page.reloadUmb();
            if (id === "display")
                page.reloadOutputs();
        }
        page.syncSystemSection();
    }

    Connections {
        target: page.win ? page.win.shell : null
        function onSettingsSectionChanged() {
            if (page.visible && page.win && page.win.shell) {
                const id = page.sectionIdFor(page.win.shell.settingsSection);
                if (id !== page.sectionId)
                    page.go(id);
            }
        }
    }

    // При входе в разделы Umbriel перечитываем актуальные значения.
    onSectionIdChanged: {
        page.syncSystemSection();
        if (visible) {
            if (sectionId === "compositor" || sectionId === "display" || sectionId === "input")
                page.reloadUmb();
            if (sectionId === "display")
                page.reloadOutputs();
        }
    }

    Connections {
        target: page.win
        function onVisibleChanged() { page.syncSystemSection(); }
    }

    Component.onDestruction: {
        SysStats.settingsActive = false;
        machineRefreshTimer.stop();
        page.machineReadPending = false;
    }

    readonly property var sections: [
        { id: "bar", title: "Панель и остров", glyph: "widgets", page: "bar",
          sub: "Состав островка, чипы и их порядок.",
          keys: "bar island notch pill height width cpu gpu load temperature панель остров островок капсула вырез чипы нагрузка" },
        { id: "media", title: "Медиа", glyph: "music_note", page: "media",
          sub: "Вид медиапилюли и оформление текущего трека.",
          keys: "media player music cover disc звук плеер музыка обложка пластинка" },
        { id: "clock", title: "Часы и дата", glyph: "schedule", page: "clock",
          sub: "Формат времени, секунды, день недели и дата.",
          keys: "clock time date timezone часы дата время секунды 12 24 формат день неделя" },
        { id: "look", title: "Оформление", glyph: "colors", page: "look",
          sub: "Палитра, масштаб, поверхности, звуки и виджеты Oberon.",
          keys: "theme look appearance font size sounds audio widgets оформ оформление тема масштаб скругление цвет насыщенность стекло блюр размытие звук виджеты" },
        { id: "weather", title: "Погода", glyph: "public", page: "weather",
          sub: "Автоопределение или ручной выбор города.",
          keys: "weather temperature city openweather api key celsius fahrenheit погода температура город ключ цельсий фаренгейт" },
        { id: "motion", title: "Анимация", glyph: "animation", page: "motion",
          sub: "Насколько быстро оболочка движется — и движется ли вообще.",
          keys: "animation speed motion анимация скорость движение" },
        { id: "night", title: "Ночной свет", glyph: "bedtime", page: "night",
          sub: "Температура экрана, режим и окно времени.",
          keys: "night light gammastep schedule sunset ночной свет температура режим расписание закат" },
        { id: "cc", title: "Быстрые настройки", glyph: "tune", page: "cc",
          sub: "Редактор плиток быстрых настроек.",
          keys: "quick settings tiles layout wifi bluetooth плитки быстрые панель управления" },
        { id: "launch", title: "Лаунчер", glyph: "search", page: "launch",
          sub: "Поиск приложений и источники поиска.",
          keys: "launcher apps search запуск приложения поиск" },
        { id: "notif", title: "Уведомления", glyph: "notifications", page: "notif",
          sub: "Тосты и режим «не беспокоить».",
          keys: "notifications dnd toast preview timeout уведомления не беспокоить длительность предпросмотр" },
        { id: "games", title: "Игры", glyph: "sports_esports", page: "games",
          sub: "Gamescope, Proton, Steam и MangoHud.",
          keys: "games gamescope proton steam mangohud игры запуск оверлей" },
        { id: "display", title: "Экран", glyph: "desktop_windows", page: "display",
          sub: "Разрешение, частота и масштаб подключённого экрана.",
          keys: "display monitor resolution refresh scale transform vrr power экран монитор разрешение герцовка поворот масштаб частота питание" },
        { id: "input", title: "Ввод", glyph: "keyboard", page: "input",
          sub: "Мышь и клавиатура Umbriel.",
          keys: "mouse keyboard layouts xkb pointer sensitivity speed accel scroll natural left handed repeat rate delay options input мышь клавиатура раскладки указатель скорость чувствительность разгон прокрутка левша повторы" },
        { id: "keys", title: "Сочетания клавиш", glyph: "keyboard", page: "keys",
          sub: "Редактор сочетаний клавиш Umbriel.",
          keys: "keybinds hotkeys shortcuts keyboard сочетания клавиши бинды управление" },
        { id: "lock", title: "Экран блокировки", glyph: "lock", page: "lock",
           sub: "Блокировка и действия при бездействии.",
           keys: "lock screen blur idle блокировка экран размытие безопасность" },
        { id: "vault", title: "Пароли", glyph: "key", page: "vault",
          sub: "Зашифрованное хранилище паролей.",
          keys: "vault password passwords пароли пароль хранилище безопасность" },
        { id: "system", title: "Система", glyph: "settings", page: "system",
          sub: "Запись экрана и пользовательские настройки Oberon.",
          keys: "about system reset defaults record video recording экран запись сброс настройки по умолчанию" },
        { id: "power", title: "Питание", glyph: "power", page: "power",
          sub: "Что и когда делать при бездействии.",
          keys: "power idle suspend lock screen питание бездействие сон блокировка экран" },
        { id: "compositor", title: "Композитор", glyph: "dashboard", page: "compositor",
          sub: "Окна, раскладка, анимации и эффекты Umbriel.",
          keys: "compositor umbriel windows layout animation effects композитор окна раскладка анимации эффекты" },
        { id: "updates", title: "Обновления", glyph: "update", page: "updates",
          sub: "Проверка и установка компонентов Oberon.",
          keys: "updates update repository обновления обновить версии репозиторий" }
    ]

    readonly property var groups: [
        { id: "island", title: "Остров", glyph: "widgets", pages: ["bar", "media", "clock"] },
        { id: "appearance", title: "Оформление", glyph: "colors", pages: ["look", "weather", "motion", "night"] },
        { id: "controls", title: "Управление", glyph: "tune", pages: ["cc", "launch", "notif", "keys", "games"] },
        { id: "devices", title: "Устройства", glyph: "desktop_windows", pages: ["display", "input"] },
        { id: "security", title: "Безопасность", glyph: "lock", pages: ["lock", "vault"] },
        { id: "system", title: "Система", glyph: "settings", pages: ["system", "power", "compositor", "updates"] }
    ]

    function sectionIdFor(value) {
        const legacy = ["look", "bar", "power", "notif", "weather", "compositor", "input", "display", "keys", "night"];
        const id = String(value === undefined || value === null || value === "" ? "look" : value);
        if (/^\d+$/.test(id))
            return legacy[Number(id)] || "look";
        for (let i = 0; i < page.sections.length; i++)
            if (page.sections[i].id === id) return id;
        return "look";
    }
    function sectionForId(id) {
        for (let i = 0; i < page.sections.length; i++)
            if (page.sections[i].id === id) return page.sections[i];
        return null;
    }
    function groupForPage(id) {
        for (let i = 0; i < page.groups.length; i++)
            if (page.groups[i].pages.indexOf(id) >= 0) return page.groups[i];
        return page.groups[0];
    }
    function pagesForGroup(group) {
        const result = [];
        for (let i = 0; i < group.pages.length; i++) {
            const section = page.sectionForId(group.pages[i]);
            if (section) result.push({ key: section.id, label: section.title });
        }
        return result;
    }
    function matches(section) {
        if (!section) return false;
        const q = page.query.trim().toLowerCase();
        if (q === "") return true;
        return String(section.title).toLowerCase().indexOf(q) >= 0
            || String(section.keys).toLowerCase().indexOf(q) >= 0;
    }
    function groupMatches(group) {
        if (page.query.trim() === "") return true;
        for (let i = 0; i < group.pages.length; i++)
            if (page.matches(page.sectionForId(group.pages[i]))) return true;
        return false;
    }
    function go(id) {
        const next = page.sectionIdFor(id);
        if (next === page.sectionId) return;
        const nextHistory = page.history.slice(0, page.historyAt + 1);
        nextHistory.push(next);
        page.history = nextHistory;
        page.historyAt = nextHistory.length - 1;
        page.sectionId = next;
        if (page.win && page.win.shell && page.win.shell.settingsSection !== next)
            page.win.shell.settingsSection = next;
    }
    function goGroup(group) {
        for (let i = 0; i < group.pages.length; i++) {
            const id = group.pages[i];
            if (page.matches(page.sectionForId(id))) { page.go(id); return; }
        }
        if (group.pages.length) page.go(group.pages[0]);
    }
    function goToFirstMatch() {
        for (let i = 0; i < page.sections.length; i++)
            if (page.matches(page.sections[i])) { page.go(page.sections[i].id); return; }
    }
    function moveHistory(delta) {
        const next = page.historyAt + delta;
        if (next < 0 || next >= page.history.length) return;
        page.historyAt = next;
        page.sectionId = page.history[next];
        if (page.win && page.win.shell && page.win.shell.settingsSection !== page.sectionId)
            page.win.shell.settingsSection = page.sectionId;
    }

    function syncSystemSection() {
        const active = page.visible && page.win && page.win.visible && page.sectionId === "system";
        SysStats.settingsActive = active;
        if (active) {
            page.refreshMachineInfo();
            machineRefreshTimer.start();
        } else {
            machineRefreshTimer.stop();
            page.machineReadPending = false;
        }
    }

    function refreshMachineInfo() {
        if (!page.visible || !page.win || !page.win.visible || page.sectionId !== "system")
            return;
        if (machineProc.running) {
            page.machineReadPending = true;
            return;
        }
        page.machineReadPending = false;
        page.machineReadStarted = false;
        machineProc.running = true;
        machineWatchdog.restart();
    }

    function parseMachineLine(line) {
        const text = String(line);
        const separator = text.indexOf(" ");
        if (separator < 1)
            return;
        const fields = ({
            "OS": "os",
            "KERNEL": "kernel",
            "COMPOSITOR": "compositor",
            "CPU": "cpu",
            "GPU": "gpu",
            "HOST": "host"
        });
        const field = fields[text.slice(0, separator)];
        if (!field)
            return;
        const next = {};
        for (const key in page.machineInfo)
            next[key] = page.machineInfo[key];
        next[field] = text.slice(separator + 1).trim();
        page.machineInfo = next;
    }

    function machineValue(key, fallback) {
        const current = page.machineInfo && page.machineInfo[key] !== undefined
            ? String(page.machineInfo[key]).trim() : "";
        if (current !== "")
            return current;
        const backup = fallback === undefined || fallback === null ? "" : String(fallback).trim();
        return backup !== "" ? backup : "Не определено";
    }

    function percentText(fraction) {
        const value = Number(fraction);
        return Math.round(Math.max(0, Math.min(1, isFinite(value) ? value : 0)) * 100) + "%";
    }

    function temperatureText(value) {
        const temp = Number(value);
        return isFinite(temp) && temp >= 0 ? Math.round(temp) + " °C" : "Недоступна";
    }

    function usageText(used, total, fraction) {
        if (!(Number(total) > 0))
            return "Нет данных";
        return SysStats.formatBytes(used) + " / " + SysStats.formatBytes(total)
            + " · " + page.percentText(fraction);
    }

    function rootDiskUsageText() {
        const disk = page.rootDisk;
        return disk ? page.usageText(disk.used, disk.total, Number(disk.used) / Number(disk.total))
                    : "Нет данных";
    }

    function systemInfoText() {
        const disk = page.rootDisk;
        const gpuPower = Number(SysStats.gpuPowerW) > 0
            ? Number(SysStats.gpuPowerW).toFixed(1) + " Вт" : "Недоступно";
        return [
            "Машина",
            "ОС: " + page.machineValue("os", SysStats.distro),
            "Ядро: " + page.machineValue("kernel", SysStats.kernel),
            "Композитор: " + page.machineValue("compositor", ""),
            "CPU: " + page.machineValue("cpu", SysStats.cpuModel),
            "GPU: " + page.machineValue("gpu", SysStats.gpuModel),
            "Имя машины: " + page.machineValue("host", SysStats.host),
            "Аптайм: " + SysStats.formatUptime(SysStats.uptime),
            "",
            "Сейчас",
            "Память: " + page.usageText(SysStats.memUsed, SysStats.memTotal, SysStats.memFrac),
            "Swap: " + (SysStats.swapTotal > 0
                ? page.usageText(SysStats.swapUsed, SysStats.swapTotal, SysStats.swapFrac)
                : "Не используется"),
            "Диск /: " + (disk ? page.rootDiskUsageText() : "Нет данных"),
            "Нагрузка (1 / 5 / 15 мин): " + SysStats.load1.toFixed(2) + " / "
                + SysStats.load5.toFixed(2) + " / " + SysStats.load15.toFixed(2),
            "Процессы: " + SysStats.procCount,
            "Температура CPU: " + page.temperatureText(SysStats.tempC),
            "Температура GPU: " + page.temperatureText(SysStats.gpuTempC),
            "Загрузка GPU: " + (SysStats.gpuLoadAvailable ? SysStats.gpuUsage + "%" : "Недоступна"),
            "Питание GPU: " + gpuPower,
            "RSS Oberon: " + SysStats.formatBytes(SysStats.shellRss)
        ].join("\n");
    }

    function openTaskman() {
        const home = Quickshell.env("HOME");
        Quickshell.execDetached([home + "/oberon/build/prefix/bin/oberonqs",
                                 "-p", home + "/oberon", "ipc", "call", "oberon", "taskman"]);
    }

    function copySystemInfo() {
        Quickshell.clipboardText = page.systemInfoText();
        page.systemInfoCopied = true;
        systemInfoCopiedTimer.restart();
    }

    readonly property var section: page.sectionForId(page.sectionId) || page.sections[0]
    readonly property var activeGroup: page.groupForPage(page.sectionId)
    readonly property var groupPages: page.pagesForGroup(page.activeGroup)
    readonly property bool canBack: page.historyAt > 0
    readonly property bool canForward: page.historyAt < page.history.length - 1

    // чтение эффективных настроек Umbriel (один JSON в строке)
    Process {
        id: umbRead

        command: ["python3", Quickshell.env("HOME") + "/oberon/scripts/umbriel-settings.py", "read"]
        running: true
        stdout: SplitParser {
            onRead: (line) => {
                try { page.umb = JSON.parse(line); } catch (e) {}
            }
        }
        onStarted: {
            page.umbReadStarted = true;
            page.umbError = "";
        }
        onExited: (exitCode) => {
            umbReadWatchdog.stop();
            const started = page.umbReadStarted;
            page.umbReadStarted = false;
            if (started && exitCode !== 0)
                page.umbError = "Не удалось прочитать настройки Umbriel.";
            if (page.umbReadPending) {
                page.umbReadPending = false;
                umbReadRestartTimer.start();
            }
        }
    }

    // Выходы читаются отдельно, чтобы использовать полный outputs --json.
    Process {
        id: outputsRead

        command: ["umbriel", "outputs", "--json"]
        running: false
        stdout: SplitParser {
            onRead: (line) => page.outputsBuffer += line + "\n"
        }
        onStarted: {
            page.outputsReadStarted = true;
            page.outputsError = "";
        }
        onExited: (exitCode) => {
            outputsReadWatchdog.stop();
            const started = page.outputsReadStarted;
            page.outputsReadStarted = false;
            if (started && exitCode !== 0) {
                page.outputsError = "Не удалось прочитать список выходов Umbriel.";
            } else if (started) {
                try {
                    const list = JSON.parse(page.outputsBuffer);
                    if (!Array.isArray(list)) throw new Error("invalid output list");
                    page.outputs = list;
                } catch (e) {
                    page.outputsError = "Umbriel вернул некорректный список выходов.";
                }
            }
            if (page.outputsReadPending) {
                page.outputsReadPending = false;
                outputsReadRestartTimer.start();
            }
        }
    }

    // Статические сведения собираются только в разделе «Система» и редко.
    Process {
        id: machineProc

        running: false
        command: ["sh", "-c",
            "OS=$(. /etc/os-release 2>/dev/null; printf '%s' \"${PRETTY_NAME:-}\"); " +
            "printf 'OS %s\\n' \"${OS:-Не определена}\"; " +
            "printf 'KERNEL %s\\n' \"$(uname -r 2>/dev/null)\"; " +
            "if command -v umbriel >/dev/null 2>&1; then V=$(umbriel --version 2>&1 | head -n 1); else V=''; fi; " +
            "printf 'COMPOSITOR %s\\n' \"${V:-Не определён}\"; " +
            "awk -F: '/^model name/{sub(/^[[:space:]]+/, \"\", $2); printf \"CPU %s\\n\", $2; exit}' /proc/cpuinfo 2>/dev/null; " +
            "G=$(lspci 2>/dev/null | grep -iE 'vga|3d controller' | head -n 1 | cut -d: -f3- | sed 's/^ //'); " +
            "printf 'GPU %s\\n' \"${G:-}\"; " +
            "printf 'HOST %s\\n' \"$(uname -n 2>/dev/null)\""]
        stdout: SplitParser {
            onRead: line => page.parseMachineLine(line)
        }
        onStarted: {
            page.machineReadStarted = true;
            page.machineError = "";
        }
        onExited: (exitCode) => {
            machineWatchdog.stop();
            const started = page.machineReadStarted;
            page.machineReadStarted = false;
            if (started && exitCode !== 0)
                page.machineError = "Не удалось собрать сведения о системе.";
            if (page.machineReadPending) {
                page.machineReadPending = false;
                machineReadRestartTimer.start();
            }
        }
    }

    // Сторожевые таймеры: процесс мог не стартовать (нет бинарника/скрипта)
    // или зависнуть — сообщаем об этом вместо вечного «Загрузка…».
    Timer {
        id: umbReadWatchdog
        interval: 8000
        onTriggered: {
            if (umbRead.running)
                umbRead.running = false;
            page.umbReadStarted = false;
            page.umbReadPending = false;
            page.umbError = "Не удалось прочитать настройки Umbriel (нет ответа скрипта).";
        }
    }

    Timer {
        id: outputsReadWatchdog
        interval: 8000
        onTriggered: {
            if (outputsRead.running)
                outputsRead.running = false;
            page.outputsReadStarted = false;
            page.outputsReadPending = false;
            page.outputsError = "Не удалось прочитать список выходов (нет ответа Umbriel).";
        }
    }

    Timer {
        id: machineWatchdog
        interval: 8000
        onTriggered: {
            if (machineProc.running)
                machineProc.running = false;
            page.machineReadStarted = false;
            page.machineReadPending = false;
            page.machineError = "Системная команда не отвечает.";
        }
    }

    Timer {
        id: umbReadRestartTimer
        interval: 0
        onTriggered: page.reloadUmb()
    }

    Timer {
        id: outputsReadRestartTimer
        interval: 0
        onTriggered: page.reloadOutputs()
    }

    Timer {
        id: machineReadRestartTimer
        interval: 0
        onTriggered: page.refreshMachineInfo()
    }

    Timer {
        id: machineRefreshTimer

        interval: 30000
        repeat: true
        onTriggered: page.refreshMachineInfo()
    }

    Timer {
        id: systemInfoCopiedTimer

        interval: 1800
        onTriggered: page.systemInfoCopied = false
    }

    // Отложенный повторный опрос после записи (config-reload асинхронен).
    Timer {
        id: umbReloadTimer

        interval: 700
        onTriggered: {
            page.reloadUmb();
            page.reloadOutputs();
        }
    }


    // перезапустить чтение настроек Umbriel
    function reloadUmb() {
        if (umbRead.running) {
            page.umbReadPending = true;
            return;
        }
        page.umbReadPending = false;
        page.umbReadStarted = false;
        umbRead.running = true;
        umbReadWatchdog.restart();
    }

    function reloadOutputs() {
        if (outputsRead.running) {
            page.outputsReadPending = true;
            return;
        }
        page.outputsReadPending = false;
        page.outputsBuffer = "";
        page.outputsReadStarted = false;
        outputsRead.running = true;
        outputsReadWatchdog.restart();
    }

    function formatTomlNumber(key, value) {
        const number = Number(value);
        if (!isFinite(number)) return null;
        if (key === "repeat_rate" || key === "repeat_delay")
            return String(Math.round(number));
        if (key === "scale" || key === "sensitivity")
            return number.toFixed(2);
        return null;
    }

    // значение из прочитанных настроек Umbriel или запасное
    function umbVal(key, fallback) {
        const v = page.umb[key];
        if (v === undefined)
            return fallback;
        if (v === "off" && (key.indexOf("effects.") === 0 || key.endsWith(".screen_effect")))
            return "";
        return v;
    }

    // записать значение в конфиг Umbriel (file, section, key, tomlValue) и обновить
    function setUmb(file, section, key, tomlValue) {
        const formatted = page.formatTomlNumber(key, tomlValue);
        Quickshell.execDetached(["python3", Quickshell.env("HOME") + "/oberon/scripts/umbriel-settings.py",
                                 "set", file, section, key, formatted === null ? String(tomlValue) : formatted]);
        umbReloadTimer.restart();
    }

    function outputModes(output) {
        const modes = output ? output.modes : null;
        return modes && typeof modes.length === "number" ? modes : [];
    }

    function outputTitle(output) {
        if (!output) return "Экран";
        const description = String(output.description || "").trim();
        if (description !== "") return description;
        const model = [output.make, output.model].filter(value => String(value || "").trim() !== "").join(" ");
        return model !== "" ? model : String(output.name || "Экран");
    }

    function outputModeKey(mode) {
        if (!mode || !Number(mode.width) || !Number(mode.height) || !Number(mode.refresh_mhz))
            return "";
        const hz = (Number(mode.refresh_mhz) / 1000).toFixed(3).replace(/\.?0+$/, "");
        return Number(mode.width) + "x" + Number(mode.height) + "@" + hz;
    }

    function outputResolutionKey(mode) {
        if (!mode || !Number(mode.width) || !Number(mode.height)) return "";
        return Number(mode.width) + "x" + Number(mode.height);
    }

    function resolutionFromModeKey(mode) {
        const match = /^(\d+x\d+)@/.exec(String(mode));
        return match ? match[1] : "";
    }

    function currentOutputModeKey(output) {
        const modes = page.outputModes(output);
        for (let i = 0; i < modes.length; i++)
            if (modes[i].current) return page.outputModeKey(modes[i]);
        const configured = String(page.umbVal("output." + output.name + ".mode", ""));
        if (configured !== "") return configured;
        return modes.length ? page.outputModeKey(modes[0]) : "";
    }

    function currentOutputMode(output) {
        const key = page.currentOutputModeKey(output);
        const modes = page.outputModes(output);
        for (let i = 0; i < modes.length; i++)
            if (page.outputModeKey(modes[i]) === key) return modes[i];
        return null;
    }

    function currentOutputResolution(output) {
        const mode = page.currentOutputMode(output);
        if (mode) return page.outputResolutionKey(mode);
        return page.resolutionFromModeKey(page.currentOutputModeKey(output));
    }

    function outputResolutionOptions(output) {
        const modes = page.outputModes(output);
        const current = page.currentOutputResolution(output);
        const seen = ({});
        const options = [];
        for (let i = 0; i < modes.length; i++) {
            const key = page.outputResolutionKey(modes[i]);
            if (key === "" || seen[key]) continue;
            seen[key] = true;
            options.push({ key: key, label: key + (key === current ? " · сейчас" : "") });
        }
        options.sort((a, b) => {
            const ap = a.key.split("x").map(Number);
            const bp = b.key.split("x").map(Number);
            return (bp[0] * bp[1] - ap[0] * ap[1]) || (bp[0] - ap[0]) || (bp[1] - ap[1]);
        });
        return options;
    }

    function outputRateOptions(output, resolution) {
        const modes = page.outputModes(output);
        const current = page.currentOutputModeKey(output);
        const seen = ({});
        const options = [];
        for (let i = 0; i < modes.length; i++) {
            const mode = modes[i];
            if (page.outputResolutionKey(mode) !== resolution) continue;
            const key = page.outputModeKey(mode);
            if (key === "" || seen[key]) continue;
            seen[key] = true;
            const hz = (Number(mode.refresh_mhz) / 1000).toFixed(3).replace(/\.?0+$/, "");
            options.push({ key: key, rate: Number(mode.refresh_mhz), label: hz + " Hz" + (key === current ? " · сейчас" : "") });
        }
        options.sort((a, b) => b.rate - a.rate);
        return options;
    }

    function setOutputValue(output, key, value, currentValue) {
        if (String(currentValue) === String(value)) return;
        const formatted = page.formatTomlNumber(key, value);
        const tomlValue = formatted !== null ? formatted
            : (typeof value === "string" ? JSON.stringify(value) : String(value));
        page.setUmb("src/appearance.toml", "output:" + output.name, key, tomlValue);
    }

    function setOutputMode(output, mode) {
        const current = String(page.umbVal("output." + output.name + ".mode", page.currentOutputModeKey(output)));
        if (String(mode) === current || String(mode) === page.currentOutputModeKey(output)) return;
        page.setOutputValue(output, "mode", String(mode), current);
    }

    function setOutputResolution(output, resolution) {
        const liveMode = page.currentOutputMode(output);
        const currentKey = page.currentOutputModeKey(output);
        const configured = String(page.umbVal("output." + output.name + ".mode", currentKey));
        if (resolution === page.resolutionFromModeKey(currentKey)
                || resolution === page.resolutionFromModeKey(configured)) return;
        const candidates = page.outputModes(output).filter(mode => page.outputResolutionKey(mode) === resolution);
        candidates.sort((a, b) => Number(b.refresh_mhz) - Number(a.refresh_mhz));
        if (!candidates.length) return;
        let selected = candidates[0];
        if (liveMode) {
            for (let i = 0; i < candidates.length; i++) {
                if (Number(candidates[i].refresh_mhz) === Number(liveMode.refresh_mhz)) {
                    selected = candidates[i];
                    break;
                }
            }
        }
        page.setOutputMode(output, page.outputModeKey(selected));
    }

    function outputVrr(output) {
        const fallback = output && output.adaptive_sync === true ? "always" : "disabled";
        const value = String(page.umbVal("output." + output.name + ".vrr", fallback));
        return value !== "disabled" && value !== "off";
    }

    function outputVrrStatus(output) {
        if (output && output.adaptive_sync === true) return "Umbriel сообщает: VRR включён";
        if (output && output.adaptive_sync === false) return "Umbriel сообщает: VRR выключен";
        return page.outputVrr(output)
            ? "Состояние VRR неизвестно · в конфиге включено"
            : "Состояние VRR неизвестно · в конфиге выключено";
    }

    function setOutputVrr(output, enabled) {
        const current = String(page.umbVal("output." + output.name + ".vrr", "disabled"));
        if ((current !== "disabled" && current !== "off") === Boolean(enabled)) return;
        // Вкл. сохраняет безопасный режим VRR в полноэкранных окнах.
        page.setOutputValue(output, "vrr", enabled ? "fullscreen" : "disabled", current);
    }

    function outputMessage(action, name) {
        Quickshell.execDetached(["umbriel", "msg", action + ":" + String(name)]);
        umbReloadTimer.restart();
    }


    function setInputValue(section, key, value) {
        const path = section + "." + key;
        const current = page.umbVal(path, undefined);
        if (current !== undefined && String(current) === String(value)) return;
        const formatted = page.formatTomlNumber(key, value);
        const tomlValue = formatted !== null ? formatted
            : (typeof value === "string" ? JSON.stringify(value) : String(value));
        page.setUmb("src/input.toml", section, key, tomlValue);
    }

    function shellQuote(value) {
        return "'" + String(value).replace(/'/g, "'\\''") + "'";
    }

    function resetInputDefaults() {
        const defaults = [
            { key: "input.mouse.sensitivity", section: "input.mouse", name: "sensitivity", value: 0, toml: "0.00" },
            { key: "input.mouse.accel_profile", section: "input.mouse", name: "accel_profile", value: "adaptive", toml: "\"adaptive\"" },
            { key: "input.mouse.natural_scroll", section: "input.mouse", name: "natural_scroll", value: false, toml: "false" },
            { key: "input.mouse.left_handed", section: "input.mouse", name: "left_handed", value: false, toml: "false" }
        ];
        const script = Quickshell.env("HOME") + "/oberon/scripts/umbriel-settings.py";
        const commands = [];
        for (let i = 0; i < defaults.length; i++) {
            const item = defaults[i];
            const current = page.umbVal(item.key, item.value);
            if (String(current) === String(item.value)) continue;
            const args = ["set", "src/input.toml", item.section, item.name, item.toml];
            commands.push("python3 \"$1\" " + args.map(page.shellQuote).join(" "));
        }
        if (!commands.length) return;
        Quickshell.execDetached(["sh", "-c", commands.join(" && "), "oberon-input-reset", script]);
        umbReloadTimer.restart();
    }

    function applyCity() {
        Prefs.set("weatherCity", cityField.text.trim());
    }

    // Применить таймауты питания (oberonidle) — сразу после смены настроек.
    function applyIdle() {
        Quickshell.execDetached(["sh", Quickshell.env("HOME") + "/oberon/scripts/set-idle.sh",
                                 String(Prefs.idleScreenMin), String(Prefs.idleLockMin), String(Prefs.idleSuspendMin)]);
    }

    // Применение темы: смены scheme/mode/contrast сливаются дебаунсом 600 мс
    // в один вызов Wallpaper.applyThemeOnly() — реколор текущих обоев через
    // matugen (картинка не меняется). «Готово» — по факту обновления палитры
    // (colors.json пересобран → меняется Theme.primary), страховка — 3 с.
    property int themeApplyState: 0 // 0 — покой, 1 — «применяется…», 2 — «готово»

    function scheduleThemeApply() {
        page.themeApplyState = 1;
        themeApplyTimer.restart();
    }

    function finishThemeApply() {
        if (page.themeApplyState !== 1) return;
        page.themeApplyState = 2;
        themeAppliedTimer.restart();
    }

    Timer {
        id: themeApplyTimer

        interval: 600
        onTriggered: {
            Wallpaper.applyThemeOnly();
            themeApplyMaxTimer.restart();
        }
    }

    Timer {
        id: themeApplyMaxTimer

        interval: 3000 // палитра могла совпасть со старой — всё равно «готово»
        onTriggered: page.finishThemeApply()
    }

    Timer {
        id: themeAppliedTimer

        interval: 1800 // «готово» держится на экране полторы секунды
        onTriggered: if (page.themeApplyState === 2) page.themeApplyState = 0
    }

    // ── порядок чипов островка (islandOrder) ─────────────────────────
    // Список id согласован с IdlePill/Island: kb/weather/ws/clock/tray.
    readonly property var chipTitles: ({
        "kb": "Раскладка",
        "weather": "Погода",
        "ws": "Рабочие пространства",
        "clock": "Часы",
        "tray": "Трей"
    })
    readonly property var chipOrder: {
        const allowed = ["kb", "weather", "ws", "clock", "tray"];
        const raw = Prefs.islandOrder;
        const out = [];
        if (raw && typeof raw.length === "number") {
            for (let i = 0; i < raw.length; i++) {
                const id = raw[i];
                if (typeof id === "string" && allowed.includes(id) && !out.includes(id))
                    out.push(id);
            }
        }
        for (const id of allowed)
            if (!out.includes(id)) out.push(id);
        return out;
    }

    // Поднять/опустить чип в порядке островка (массив пишется целиком).
    function moveChip(i, delta) {
        const arr = page.chipOrder.slice();
        const j = i + delta;
        if (j < 0 || j >= arr.length) return;
        const t = arr[i];
        arr[i] = arr[j];
        arr[j] = t;
        Prefs.set("islandOrder", arr);
    }

    // ── локальные компоненты ──────────────────────────────────────────

    // заголовок раздела справа: titleLarge + пояснение
    component SectionHeader: ColumnLayout {
        id: sh

        property string title: ""
        property string caption: ""

        Layout.fillWidth: true
        Layout.bottomMargin: Theme.dp(4)
        spacing: Theme.dp(2)
        visible: false

        LText {
            Layout.fillWidth: true
            text: sh.title
            role: "titleLarge"
            weight: 560
            color: Theme.text
            elide: Text.ElideRight
        }

        LText {
            Layout.fillWidth: true
            visible: sh.caption !== ""
            text: sh.caption
            role: "bodySmall"
            color: Theme.subtext
            wrapMode: Text.WordWrap
        }
    }

    // пункт рейла Lucid: строка 50dp, выбранная запись — secondaryContainer
    // пилюлей, иконка 22 наполняется, подпись LText labelLarge, ховер —
    // StateLayer. Иконка слева, как в раскрытом рейле Lucid.
    component NavItem: Item {
        id: ni

        property string icon: ""
        property string label: ""
        property bool selected: false

        signal clicked()

        Layout.fillWidth: true
        implicitHeight: Theme.dp(50)

        Rectangle {
            id: bg

            anchors.fill: parent
            radius: Theme.pill(height)
            color: ni.selected ? Theme.secondaryContainer : "transparent"

            Behavior on color {
                ColorAnimation { duration: Theme.durShort }
            }
        }

        StateLayer {
            id: area

            anchors.fill: parent
            radius: Theme.pill(ni.height)
            tint: ni.selected ? Theme.fgSecondaryContainer : Theme.text
            onClicked: ni.clicked()
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.dp(14)
            anchors.rightMargin: Theme.dp(12)
            spacing: Theme.dp(12)

            Icon {
                Layout.alignment: Qt.AlignVCenter
                name: ni.icon
                size: Theme.dp(22)
                fill: ni.selected ? 1 : 0
                color: ni.selected ? Theme.fgSecondaryContainer
                                   : (area.containsMouse ? Theme.text : Theme.subtext)

                Behavior on color {
                    ColorAnimation { duration: Theme.durShort }
                }
            }

            LText {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                text: ni.label
                role: "labelLarge"
                color: ni.selected ? Theme.fgSecondaryContainer
                                   : (area.containsMouse ? Theme.text : Theme.subtext)
                elide: Text.ElideRight

                Behavior on color {
                    ColorAnimation { duration: Theme.durShort }
                }
            }
        }
    }

    // строка параметра: подпись + значение справа, ниже слайдер min..max.
    // Число — tabular, значение выровнено вправо. Слайдер работает в реальных
    // единицах (from/to); committed отдаёт уже готовое значение.
    component ParamRow: SSlider {
        property real min: 0
        property real max: 1
        property real displayMul: 100
        from: min
        to: max
        suffix: "%"
        valueText: (v) => Math.round(v * displayMul) + suffix
    }

    // Индикатор объёма, не интерактивный слайдер.
    component SystemMeter: ColumnLayout {
        id: meter

        property string label: ""
        property string value: ""
        property real fraction: 0

        Layout.fillWidth: true
        spacing: Theme.dp(5)

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            LText {
                Layout.fillWidth: true
                text: meter.label
                role: "bodySmall"
                color: Theme.subtext
                elide: Text.ElideRight
            }

            LText {
                text: meter.value
                role: "labelMedium"
                weight: 540
                color: Theme.text
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideRight
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: Theme.dp(6)
            radius: Theme.pill(height)
            color: Theme.mSurface
            clip: true

            Rectangle {
                width: parent.width * Math.max(0, Math.min(1,
                    isFinite(meter.fraction) ? meter.fraction : 0))
                height: parent.height
                radius: parent.radius
                color: Theme.primary

                Behavior on width {
                    NumberAnimation { duration: Theme.durShort }
                }
            }
        }
    }

    component SystemDatum: ColumnLayout {
        id: datum

        property string label: ""
        property string value: ""

        Layout.fillWidth: true
        spacing: Theme.dp(2)

        SLabel { text: datum.label }

        LText {
            Layout.fillWidth: true
            text: datum.value
            role: "bodyLarge"
            weight: 500
            color: Theme.text
            wrapMode: Text.WordWrap
        }
    }

    component SystemInfoRow: RowLayout {
        id: infoRow

        property string label: ""
        property string value: ""

        Layout.fillWidth: true
        spacing: Theme.dp(12)

        LText {
            Layout.preferredWidth: Theme.dp(112)
            text: infoRow.label
            role: "bodySmall"
            color: Theme.subtext
            verticalAlignment: Text.AlignVCenter
        }

        LText {
            Layout.fillWidth: true
            text: infoRow.value
            role: "bodyMedium"
            weight: 480
            color: Theme.text
            wrapMode: Text.WordWrap
        }
    }

    // строка выбора из набора значений. До 4 вариантов — связанная группа
    // ButtonGroup (выбранный сегмент primary); больше — Chip-потоком, чтобы
    // подписи не сжимались. committed отдаёт выбранный ключ.
    component ChoiceRow: SSelect {}

    // мелкая подпись-подгруппа внутри карточки (воздух вместо дивайдера)
    component GroupCaption: SLabel {
        Layout.fillWidth: true
        Layout.topMargin: Theme.dp(8)
        elide: Text.ElideRight
    }

    // Поле «ЧЧ:ММ» для расписаний (ночной свет, DND): пишет в Prefs-ключ
    // только валидное значение, при потере фокуса откатывается к текущему
    // префу. Внешние изменения префа подтягивает Connections внизу файла.
    component TimeField: TextField {
        id: tfield

        property string prefKey: ""

        function sync() {
            const v = Prefs[tfield.prefKey];
            if (typeof v === "string") tfield.text = v;
        }

        function commit() {
            const s = tfield.text.trim();
            if (/^([01]?\d|2[0-3]):[0-5]\d$/.test(s)) Prefs.set(tfield.prefKey, s);
            tfield.sync(); // невалидный ввод откатываем
        }

        onAccepted: tfield.commit()
        onActiveFocusChanged: if (!tfield.activeFocus) tfield.commit()
        Component.onCompleted: tfield.sync()
    }

    // Строка конфигурации Umbriel: пустые значения и TOML-кавычки запрещены.
    component UmbrielTextField: TextField {
        id: configField

        property string configKey: ""
        property string configSection: ""
        property string configName: ""
        property string fieldLabel: ""
        property string hint: ""
        property string invalidMessage: ""

        label: configField.fieldLabel
        placeholder: configField.hint
        supporting: configField.invalidMessage !== ""
            ? configField.invalidMessage
            : ""
        error: configField.invalidMessage !== ""
        text: String(page.umbVal(configField.configKey, ""))

        function sync() {
            if (configField.activeFocus) return;
            configField.text = String(page.umbVal(configField.configKey, ""));
            configField.invalidMessage = "";
        }

        function commit() {
            const value = configField.text.trim();
            if (value === "" || /['"\r\n]/.test(value)) {
                configField.invalidMessage = "Заполните поле без кавычек и переводов строк.";
                return;
            }
            const current = String(page.umbVal(configField.configKey, ""));
            configField.invalidMessage = "";
            if (value === current) return;
            page.setUmb("src/input.toml", configField.configSection,
                        configField.configName, JSON.stringify(value));
        }

        onAccepted: configField.commit()
        onActiveFocusChanged: if (!configField.activeFocus) configField.commit()
        Component.onCompleted: configField.sync()

        Connections {
            target: page
            function onUmbChanged() { configField.sync(); }
        }
    }

    // ── левая колонка: рейл разделов ──────────────────────────────────
    ColumnLayout {
        id: rail

        Layout.alignment: Qt.AlignTop
        Layout.preferredWidth: Theme.dp(196)
        Layout.minimumWidth: Theme.dp(196)
        Layout.maximumWidth: Theme.dp(196)
        Layout.fillHeight: true
        spacing: Theme.dp(8)

        TextField {
            id: searchInput

            Layout.fillWidth: true
            variant: "search"
            icon: "search"
            placeholder: "Поиск настроек"
            text: page.query
            onTextEdited: page.query = text
            onAccepted: page.goToFirstMatch()
            onEscaped: {
                page.query = "";
                searchInput.text = "";
            }
        }

        ListView {
            id: groupList

            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Theme.dp(4)
            model: page.groups

            delegate: NavItem {
                required property var modelData
                readonly property bool shown: page.groupMatches(modelData)

                width: groupList.width
                height: shown ? implicitHeight : 0
                visible: shown
                icon: modelData.glyph
                label: modelData.title
                selected: page.activeGroup.id === modelData.id
                onClicked: page.goGroup(modelData)
            }
        }
    }

    // ── правая колонка: содержимое выбранного раздела ─────────────────
    ColumnLayout {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignTop
        spacing: Theme.dp(12)

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(6)

            IconButton {
                icon: "arrow_back"
                tooltip: "Назад"
                disabled: !page.canBack
                onClicked: page.moveHistory(-1)
            }
            IconButton {
                icon: "arrow_forward"
                tooltip: "Вперёд"
                disabled: !page.canForward
                onClicked: page.moveHistory(1)
            }
            Item { Layout.fillWidth: true }
        }

        Flow {
            id: tabsFlow

            Layout.fillWidth: true
            Layout.preferredHeight: Math.max(Theme.dp(30), tabsFlow.implicitHeight)
            spacing: Theme.dp(6)

            Repeater {
                model: page.groupPages

                Chip {
                    required property var modelData
                    size: "sm"
                    text: modelData.label
                    selected: page.sectionId === modelData.key
                    onClicked: page.go(modelData.key)
                }
            }
        }

        SHeader {
            glyph: page.section.glyph
            title: page.section.title
            sub: page.section.sub
        }

        LText {
            Layout.fillWidth: true
            visible: page.umbError !== "" && ["compositor", "display", "input"].indexOf(page.sectionId) >= 0
            text: page.umbError
            role: "bodySmall"
            color: Theme.error
            wrapMode: Text.WordWrap
        }

        // 0. Шелл (интерфейс)
        ColumnLayout {
            visible: page.sectionId === "look"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SectionHeader {
                title: "Шелл"
                caption: "Оформление Oberon: масштаб, форма, движение и цвет"
            }

            Card { // масштаб
                Layout.fillWidth: true
                title: "Масштаб"

                ParamRow {
                    label: "Размер интерфейса"
                    min: 0.8
                    max: 1.25
                    value: Prefs.uiScale
                    onCommitted: (v) => Prefs.set("uiScale", v)
                }
                ParamRow {
                    label: "Скругления"
                    min: 0
                    max: 1.5
                    value: Prefs.cornerScale
                    onCommitted: (v) => Prefs.set("cornerScale", v)
                }
            }

            Card { // цвет и поверхности
                Layout.fillWidth: true
                title: "Цвет и поверхности"

                ParamRow {
                    label: "Насыщенность акцента"
                    min: 0.5
                    max: 1.5
                    value: Prefs.accentPunch
                    onCommitted: (v) => Prefs.set("accentPunch", v)
                }

                ParamRow {
                    label: "Размытие фона"
                    min: 0
                    max: 100
                    value: Prefs.blurAmount
                    displayMul: 1
                    suffix: "%"
                    sub: "Радиус размытия Umbriel; влияет и на окна. 0% — без размытия, 100% — максимум."
                    onCommitted: (v) => {
                        const r = Math.round(v);
                        Prefs.set("blurAmount", r);
                        Quickshell.execDetached(["sh", Quickshell.env("HOME") + "/oberon/scripts/set-blur.sh", String(r)]);
                    }
                }

                ParamRow {
                    label: "Затемнение поверхностей"
                    min: 0
                    max: 1.5
                    value: Math.max(0, Prefs.surfaceDarkness)
                    onCommitted: (v) => Prefs.set("surfaceDarkness", Math.round(v * 20) / 20)
                }
                ParamRow {
                    label: "Тонировка поверхностей"
                    min: 0
                    max: 1
                    value: Math.max(0, Prefs.surfaceTint)
                    onCommitted: (v) => Prefs.set("surfaceTint", Math.round(v * 20) / 20)
                }
            }

            Card { // звуки
                Layout.fillWidth: true
                title: "Звук"

                ToggleRow {
                    label: "Звуковые события"
                    sub: "Тапы, OSD, уведомления и заряд — файлы из assets/sounds."
                    checked: Prefs.soundsEnabled
                    onToggled: (v) => Prefs.set("soundsEnabled", v)
                }

                RowLayout { // превью звука уведомления
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.dp(6)
                    spacing: Theme.dp(12)

                    Button {
                        text: "Прослушать пример"
                        variant: "tonal"
                        disabled: !Prefs.soundsEnabled
                        onClicked: Sounds.play("alert")
                    }

                    LText {
                        Layout.fillWidth: true
                        text: "Проигрывает alert.oga — тот же звук, что при уведомлении."
                        role: "bodySmall"
                        color: Theme.subtextDim
                        wrapMode: Text.WordWrap
                    }
                }
            }

            Card { // виджеты рабочего стола
                Layout.fillWidth: true
                title: "Рабочий стол"

                ToggleRow {
                    label: "Виджеты на рабочем столе"
                    sub: "Часы, погода, система, медиаплеер и визуализатор поверх обоев."
                    checked: Prefs.widgetsEnabled
                    onToggled: (v) => Prefs.set("widgetsEnabled", v)
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.dp(6)
                    spacing: Theme.dp(12)

                    Button {
                        text: "Настроить расположение виджетов"
                        icon: "widgets"
                        variant: "tonal"
                        onClicked: {
                            if (page.win && page.win.shell)
                                page.win.shell.toggleWidgetsEditing();
                        }
                    }

                    LText {
                        Layout.fillWidth: true
                        text: "Перетаскивайте карточки мышью; правый клик завершает режим редактирования."
                        role: "bodySmall"
                        color: Theme.subtextDim
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }

        // 8. Тема (материал-палитра из обоев)
        ColumnLayout {
            visible: page.sectionId === "look"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SectionHeader {
                title: "Тема"
                caption: "Как строится палитра из обоев: схема, светимость и контраст"
            }

            Card {
                Layout.fillWidth: true

                ChoiceRow {
                    label: "Светимость интерфейса"
                    values: ["auto", "light", "dark"]
                    labels: ["Авто", "Светлая", "Тёмная"]
                    value: Prefs.themeMode
                    sub: "Авто — matugen решает по яркости обоев."
                    onCommitted: (v) => {
                        Prefs.set("themeMode", v);
                        page.scheduleThemeApply();
                    }
                }

                ChoiceRow {
                    label: "Схема"
                    values: ["auto", "tonalSpot", "content", "fidelity", "monochrome", "vibrant", "expressive", "neutral"]
                    labels: ["Авто (по обоям)", "Тональная", "От контента", "Точная", "Монохромная", "Яркая", "Экспрессивная", "Нейтральная"]
                    value: Prefs.themeScheme
                    sub: "Семь схем Material из одного цвета обоев; «Авто» выбирает осторожнее всего."
                    onCommitted: (v) => {
                        Prefs.set("themeScheme", v);
                        page.scheduleThemeApply();
                    }
                }

                ParamRow {
                    label: "Контраст"
                    min: -1
                    max: 1
                    value: Prefs.themeContrast
                    displayMul: 100
                    suffix: "%"
                    sub: "Контраст палитры Material: от −100% (мягче) до +100% (резче); 0 — как даёт схема."
                    onCommitted: (v) => {
                        Prefs.set("themeContrast", Math.round(v * 20) / 20);
                        page.scheduleThemeApply();
                    }
                }

                RowLayout { // подпись «применяется… → готово»
                    Layout.fillWidth: true
                    visible: page.themeApplyState !== 0
                    spacing: Theme.dp(6)

                    Icon {
                        name: page.themeApplyState === 2 ? "check_circle" : "sync"
                        size: Theme.dp(16)
                        color: page.themeApplyState === 2 ? Theme.subtext : Theme.primary
                    }

                    LText {
                        Layout.fillWidth: true
                        text: page.themeApplyState === 2 ? "Палитра обновлена" : "Перекрашиваю обои…"
                        role: "bodySmall"
                        color: page.themeApplyState === 2 ? Theme.subtext : Theme.primary
                    }
                }

                LText {
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.dp(4)
                    text: "Обои перекрашиваются их же источником: картинка не меняется, пересчитывается только палитра (matugen)."
                    role: "bodySmall"
                    color: Theme.subtextDim
                    wrapMode: Text.WordWrap
                }
            }
        }

        // 1. Островок
        ColumnLayout {
            visible: page.sectionId === "bar"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SectionHeader {
                title: "Островок"
                caption: "Что и как показывать в капсуле"
            }

            Card {
                Layout.fillWidth: true
                title: "Положение"

                SSelect {
                    label: "Край экрана"
                    values: ["top", "bottom", "left", "right"]
                    labels: ["Сверху", "Снизу", "Слева", "Справа"]
                    value: Prefs.islandPos
                    onCommitted: (v) => Prefs.set("islandPos", v)
                }
            }

            Card {
                Layout.fillWidth: true
                title: "Поведение"

                SToggle {
                    label: "Автоскрытие"
                    sub: "Капсула уезжает за край, возвращается при наведении на полоску."
                    checked: Prefs.islandAutoHide
                    onToggled: (v) => Prefs.set("islandAutoHide", v)
                }
                SToggle {
                    label: "Переносить капсулу мышью между краями"
                    checked: Prefs.islandDrag
                    onToggled: (v) => Prefs.set("islandDrag", v)
                }
                SToggle {
                    label: "Загрузка CPU/GPU в свёрнутой капсуле"
                    checked: Prefs.systemLoadOnIsland
                    onToggled: (v) => Prefs.set("systemLoadOnIsland", v)
                }
            }

            Card {
                Layout.fillWidth: true
                title: "Форма"

                SToggle {
                    label: "Режим выреза"
                    sub: "Вогнутые уголки у кромки."
                    checked: Prefs.notchMode
                    onToggled: (v) => Prefs.set("notchMode", v)
                }
                SSlider {
                    label: "Размер уголков"
                    sub: "Виден в режиме выреза."
                    from: 0
                    to: 32
                    step: 1
                    value: Prefs.notchFlare
                    valueText: (v) => Math.round(v) + " dp"
                    enabled: Prefs.notchMode
                    onCommitted: (v) => Prefs.set("notchFlare", Math.round(v))
                }
                SSlider {
                    label: "Отступ от края"
                    sub: "Используется у плавающей капсулы."
                    from: 0
                    to: 48
                    step: 1
                    value: Prefs.islandGap
                    valueText: (v) => Math.round(v) + " dp"
                    enabled: !Prefs.notchMode
                    onCommitted: (v) => Prefs.set("islandGap", Math.round(v))
                }
                SSlider {
                    label: "Скругление"
                    sub: "0 — радиус по высоте капсулы."
                    from: 0
                    to: 40
                    step: 1
                    value: Prefs.islandRadius
                    valueText: (v) => Math.round(v) === 0 ? "По высоте" : Math.round(v) + " dp"
                    onCommitted: (v) => Prefs.set("islandRadius", Math.round(v))
                }
            }

            Card {
                Layout.fillWidth: true
                title: "Размеры"

                SSlider {
                    label: "Высота капсулы"
                    from: 24
                    to: 72
                    step: 1
                    value: Prefs.islandHeight
                    valueText: (v) => Math.round(v) + " dp"
                    onCommitted: (v) => Prefs.set("islandHeight", Math.round(v))
                }
                SSlider {
                    label: "Минимальная ширина"
                    sub: "0 — без нижней границы; иначе 120–640 dp, шаг 4."
                    from: 0
                    to: 131
                    step: 1
                    value: Prefs.islandWidth <= 0 ? 0
                        : 1 + Math.round((Math.max(120, Math.min(640, Prefs.islandWidth)) - 120) / 4)
                    valueText: (v) => v < 0.5 ? "Без нижней границы"
                        : (120 + (Math.round(v) - 1) * 4) + " dp"
                    onCommitted: (v) => Prefs.set("islandWidth",
                        v < 0.5 ? 0 : 120 + (Math.round(v) - 1) * 4)
                }
                SSlider {
                    label: "Ширина раскрытой панели"
                    sub: "0 — по странице; иначе 380–900 dp, шаг 10."
                    from: 0
                    to: 53
                    step: 1
                    value: Prefs.islandExpandedWidth <= 0 ? 0
                        : 1 + Math.round((Math.max(380, Math.min(900, Prefs.islandExpandedWidth)) - 380) / 10)
                    valueText: (v) => v < 0.5 ? "По странице"
                        : (380 + (Math.round(v) - 1) * 10) + " dp"
                    onCommitted: (v) => Prefs.set("islandExpandedWidth",
                        v < 0.5 ? 0 : 380 + (Math.round(v) - 1) * 10)
                }
                SSlider {
                    label: "Высота раскрытой панели"
                    sub: "0 — автоматически; иначе 260–1000 dp, шаг 10."
                    from: 0
                    to: 75
                    step: 1
                    value: Prefs.islandExpandedHeight <= 0 ? 0
                        : 1 + Math.round((Math.max(260, Math.min(1000, Prefs.islandExpandedHeight)) - 260) / 10)
                    valueText: (v) => v < 0.5 ? "Авто"
                        : (260 + (Math.round(v) - 1) * 10) + " dp"
                    onCommitted: (v) => Prefs.set("islandExpandedHeight",
                        v < 0.5 ? 0 : 260 + (Math.round(v) - 1) * 10)
                }
            }

            Card {
                Layout.fillWidth: true

                ToggleRow {
                    label: "Показывать раскладку клавиатуры"
                    checked: Prefs.islandLayout
                    onToggled: (v) => Prefs.set("islandLayout", v)
                }
                ToggleRow {
                    label: "Показывать погоду"
                    checked: Prefs.islandWeather
                    onToggled: (v) => Prefs.set("islandWeather", v)
                }
                ToggleRow {
                    label: "Показывать часы"
                    checked: Prefs.islandClock
                    onToggled: (v) => Prefs.set("islandClock", v)
                }
                ToggleRow {
                    label: "Показывать воркспейсы"
                    checked: Prefs.islandWorkspaces
                    onToggled: (v) => Prefs.set("islandWorkspaces", v)
                }
                ToggleRow {
                    label: "Показывать трей"
                    checked: Prefs.islandTray
                    onToggled: (v) => Prefs.set("islandTray", v)
                }
                ToggleRow {
                    label: "Островок на всех мониторах"
                    sub: "Показывать капсулу и всплывающие тосты на всех подключённых экранах"
                    checked: Prefs.islandAllScreens
                    onToggled: (v) => Prefs.set("islandAllScreens", v)
                }
            }

            Card { // порядок чипов (islandOrder: kb/weather/ws/clock/tray)
                Layout.fillWidth: true
                title: "Порядок чипов"

                LText {
                    Layout.fillWidth: true
                    text: "Слева направо — как чипы стоят в капсуле. Стрелками меняйте порядок."
                    role: "bodySmall"
                    color: Theme.subtextDim
                    wrapMode: Text.WordWrap
                }

                Repeater {
                    model: page.chipOrder

                    delegate: RowLayout {
                        required property var modelData
                        required property int index

                        Layout.topMargin: Theme.dp(2)
                        spacing: Theme.dp(8)

                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            implicitWidth: Theme.dp(30)
                            implicitHeight: Theme.dp(30)
                            radius: Theme.rad(9)
                            color: Theme.bgTrack

                            Icon {
                                anchors.centerIn: parent
                                name: modelData === "kb" ? "keyboard"
                                    : modelData === "weather" ? "public"
                                    : modelData === "ws" ? "workspaces"
                                    : modelData === "clock" ? "schedule"
                                    : "toolbar"
                                size: Theme.dp(17)
                                color: Theme.subtext
                            }
                        }

                        LText {
                            Layout.fillWidth: true
                            text: page.chipTitles[modelData] !== undefined ? page.chipTitles[modelData] : String(modelData)
                            role: "bodyLarge"
                            weight: 480
                            color: Theme.text
                            elide: Text.ElideRight
                        }

                        IconButton {
                            Layout.alignment: Qt.AlignVCenter
                            icon: "expand_less"
                            tooltip: "Выше"
                            disabled: index === 0
                            onClicked: page.moveChip(index, -1)
                        }

                        IconButton {
                            Layout.alignment: Qt.AlignVCenter
                            icon: "expand_more"
                            tooltip: "Ниже"
                            disabled: index === page.chipOrder.length - 1
                            onClicked: page.moveChip(index, 1)
                        }
                    }
                }
            }
        }



        // 2. Питание
        ColumnLayout {
            visible: page.sectionId === "power"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SectionHeader {
                title: "Питание"
                caption: "Что и когда делать при бездействии"
            }

            Card {
                Layout.fillWidth: true

                ChoiceRow {
                    label: "Гасить экран через"
                    values: [0, 1, 2, 5, 10, 15, 30, 60]
                    labels: ["Никогда", "1 мин", "2 мин", "5 мин", "10 мин", "15 мин", "30 мин", "60 мин"]
                    value: Prefs.idleScreenMin
                    onCommitted: (v) => { Prefs.set("idleScreenMin", v); page.applyIdle() }
                }
                ChoiceRow {
                    label: "Блокировать через"
                    values: [0, 1, 2, 5, 10, 15, 30]
                    labels: ["Никогда", "1 мин", "2 мин", "5 мин", "10 мин", "15 мин", "30 мин"]
                    value: Prefs.idleLockMin
                    onCommitted: (v) => { Prefs.set("idleLockMin", v); page.applyIdle() }
                }
                ChoiceRow {
                    label: "Уходить в сон через"
                    values: [0, 15, 30, 60, 120, 180]
                    labels: ["Никогда", "15 мин", "30 мин", "60 мин", "2 часа", "3 часа"]
                    value: Prefs.idleSuspendMin
                    onCommitted: (v) => { Prefs.set("idleSuspendMin", v); page.applyIdle() }
                }

                LText {
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.dp(4)
                    text: "Работает через oberonidle (Umbriel): гашение — DPMS, блокировка — экран Oberon, сон — systemd. Если монитор гаснет раньше выбранного — это его собственный таймер в прошивке."
                    role: "bodySmall"
                    color: Theme.subtextDim
                    wrapMode: Text.WordWrap
                }
            }
        }

        // 3. Уведомления
        ColumnLayout {
            visible: page.sectionId === "notif"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SectionHeader {
                title: "Уведомления"
                caption: "Тосты и режим «не беспокоить»"
            }

            Card {
                Layout.fillWidth: true

                ToggleRow {
                    label: "Не беспокоить (DND)"
                    checked: Prefs.dnd
                    onToggled: (v) => Prefs.set("dnd", v)
                }
                ToggleRow {
                    label: "Расписание DND"
                    sub: "Включать «Не беспокоить» в этом окне времени автоматически."
                    checked: Prefs.dndScheduleEnabled
                    onToggled: (v) => Prefs.set("dndScheduleEnabled", v)
                }

                RowLayout { // окно расписания DND (ЧЧ:ММ, может пересекать полночь)
                    visible: Prefs.dndScheduleEnabled
                    Layout.fillWidth: true
                    spacing: Theme.dp(12)

                    TimeField {
                        id: dndFromField

                        prefKey: "dndFrom"
                        label: "С"
                        Layout.fillWidth: true
                    }

                    TimeField {
                        id: dndToField

                        prefKey: "dndTo"
                        label: "До"
                        Layout.fillWidth: true
                    }
                }

                ChoiceRow {
                    label: "Таймаут обычного уведомления"
                    values: [3, 5, 8, 10]
                    labels: ["3 сек", "5 сек", "8 сек", "10 сек"]
                    value: Prefs.notifTimeout
                    onCommitted: (v) => Prefs.set("notifTimeout", v)
                }
                ChoiceRow {
                    label: "Таймаут критического уведомления"
                    values: [0, 5, 10, 15]
                    labels: ["Не скрывать", "5 сек", "10 сек", "15 сек"]
                    value: Prefs.notifCritTimeout
                    onCommitted: (v) => Prefs.set("notifCritTimeout", v)
                }
                ToggleRow {
                    label: "Предпросмотр текста"
                    sub: "Если выключено, в тосте остаются только приложение и заголовок."
                    checked: Prefs.notifPreview
                    onToggled: (v) => Prefs.set("notifPreview", v)
                }
                LText {
                    Layout.fillWidth: true
                    role: "bodySmall"
                    color: Theme.subtextDim
                    wrapMode: Text.WordWrap
                    text: "Критическое уведомление с таймаутом 0 остаётся на экране до закрытия."
                }
            }
        }

        // 4. Погода
        ColumnLayout {
            visible: page.sectionId === "weather"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SectionHeader {
                title: "Погода"
                caption: "Автоопределение или ручной выбор города"
            }

            Card {
                Layout.fillWidth: true

                ToggleRow { // авто-определение города
                    label: "Определять город автоматически"
                    sub: Prefs.weatherAuto ? "По IP-адресу" : ""
                    checked: Prefs.weatherAuto
                    onToggled: (v) => Prefs.set("weatherAuto", v)
                }

                RowLayout { // ручной город
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.dp(6)
                    spacing: Theme.dp(8)

                    TextField {
                        id: cityField
                        Layout.fillWidth: true
                        variant: "filled"
                        enabled: !Prefs.weatherAuto
                        placeholder: "Например, Харьков"
                        text: Prefs.weatherCity
                        onAccepted: page.applyCity()
                    }

                    Button {
                        text: "Применить"
                        variant: "tonal"
                        disabled: !cityField.enabled || cityField.text.trim() === Prefs.weatherCity
                        onClicked: page.applyCity()
                    }
                }

                RowLayout { // текущее место
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.dp(6)
                    spacing: Theme.dp(12)

                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: Theme.dp(40)
                        implicitHeight: Theme.dp(40)
                        radius: Theme.rad(12)
                        color: Theme.bgTrack

                        Icon {
                            anchors.centerIn: parent
                            name: "public"
                            size: Theme.dp(22)
                            color: Theme.subtext
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: Theme.dp(2)

                        LText {
                            Layout.fillWidth: true
                            text: Prefs.weatherPlace !== "" ? Prefs.weatherPlace : "Место не определено"
                            role: "bodyLarge"
                            weight: 480
                            color: Theme.text
                            elide: Text.ElideRight
                        }

                        LText {
                            Layout.fillWidth: true
                            visible: Weather.loading
                            text: "Обновление…"
                            role: "bodySmall"
                            color: Theme.subtext
                        }

                        LText {
                            Layout.fillWidth: true
                            visible: Weather.error !== ""
                            text: Weather.error
                            role: "bodySmall"
                            color: Theme.error
                            elide: Text.ElideRight
                        }
                    }

                    IconButton {
                        Layout.alignment: Qt.AlignVCenter
                        icon: "refresh"
                        disabled: Weather.loading
                        onClicked: Weather.refresh()
                    }
                }
            }
        }

        // 9. Ночной свет (gammastep: темп / режим / расписание)
        ColumnLayout {
            visible: page.sectionId === "night"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SectionHeader {
                title: "Ночной свет"
                caption: "Тепло экрана gammastep'ом: температура, режим и окно времени"
            }

            Card {
                Layout.fillWidth: true

                ToggleRow {
                    label: "Ночной свет"
                    sub: NightLight.active ? "Работает: " + NightLight.temp + " К"
                                           : "Выключен"
                    checked: Prefs.nightLightEnabled
                    onToggled: (v) => Prefs.set("nightLightEnabled", v)
                }

                ParamRow {
                    label: "Тепло экрана"
                    min: 2500
                    max: 6500
                    value: Prefs.nightLightTemp
                    displayMul: 1
                    suffix: " К"
                    sub: "Слева теплее — 2500 К свечения; справа ближе к нейтральному белому — 6500 К."
                    onCommitted: (v) => Prefs.set("nightLightTemp", Math.round(v / 100) * 100)
                }

                ChoiceRow {
                    id: nlModeRow

                    label: "Режим"
                    values: ["manual", "schedule", "sunset"]
                    labels: ["Ручной", "Расписание", "Закат"]
                    value: Prefs.nightLightMode
                    sub: nlModeRow.modeSub
                    onCommitted: (v) => Prefs.set("nightLightMode", v)

                    readonly property string modeSub: {
                        if (Prefs.nightLightMode !== "sunset")
                            return "";
                        if (NightLight.geoOk)
                            return "Gammastep сам следит за закатом по координатам из раздела «Погода».";
                        return "Закату нужны координаты — добавьте город в разделе «Погода»; пока действует ручной режим.";
                    }
                }

                RowLayout { // окно расписания (ЧЧ:ММ), видно только в режиме «Расписание»
                    visible: Prefs.nightLightMode === "schedule"
                    Layout.fillWidth: true
                    spacing: Theme.dp(12)

                    TimeField {
                        id: nightFromField

                        prefKey: "nightLightFrom"
                        label: "С"
                        Layout.fillWidth: true
                    }

                    TimeField {
                        id: nightToField

                        prefKey: "nightLightTo"
                        label: "До"
                        Layout.fillWidth: true
                    }
                }
            }
        }

        // 5. Композитор (окна, раскладка, анимации, эффекты)
        // Прокрутку длинного раздела ведёт внешний Flickable в Island.qml:
        // вложенный Flickable не имеет implicitHeight и схлопывал страницу в 0
        ColumnLayout {
            visible: page.sectionId === "compositor"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SectionHeader {
                title: "Композитор"
                caption: "Окна, раскладка, анимации и эффекты Umbriel — применяется сразу"
            }

            Card { // окна
                Layout.fillWidth: true
                title: "Окна"

                ParamRow {
                    label: "Скругление окон"
                    min: 0
                    max: 40
                    value: page.umbVal("appearance.corner_radius", 18)
                    displayMul: 1
                    suffix: ""
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "appearance", "corner_radius", Math.round(v))
                }
                ParamRow {
                    label: "Толщина границы"
                    min: 0
                    max: 10
                    value: page.umbVal("appearance.border_width", 2)
                    displayMul: 1
                    suffix: ""
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "appearance", "border_width", Math.round(v))
                }
                ParamRow {
                    label: "Прозрачность при перетаскивании"
                    min: 30
                    max: 100
                    value: Math.round(page.umbVal("appearance.drag_opacity", 0.75) * 100)
                    displayMul: 1
                    suffix: "%"
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "appearance", "drag_opacity", v / 100)
                }
                ToggleRow {
                    label: "Непрозрачный фуллскрин"
                    checked: page.umbVal("appearance.opaque_fullscreen", false)
                    onToggled: (v) => page.setUmb("src/appearance.toml", "appearance", "opaque_fullscreen", v ? "true" : "false")
                }
                ChoiceRow {
                    label: "Режим раскладки"
                    values: ["scrolling", "dwindle", "master"]
                    labels: ["Прокрутка", "Двоичное", "Мастер"]
                    value: page.umbVal("layout.mode", "dwindle")
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "layout", "mode", "\"" + v + "\"")
                }
            }

            Card { // раскладка
                Layout.fillWidth: true
                title: "Раскладка"

                ParamRow {
                    label: "Зазор между окнами"
                    min: 0
                    max: 30
                    value: page.umbVal("layout.gap", 7)
                    displayMul: 1
                    suffix: ""
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "layout", "gap", Math.round(v))
                }
                ParamRow {
                    label: "Доля прокрутки по умолчанию"
                    min: 0.1
                    max: 1.0
                    value: page.umbVal("layout.scrolling.default_extent_fraction", 0.5)
                    displayMul: 100
                    suffix: "%"
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "layout.scrolling", "default_extent_fraction", Math.round(v * 100) / 100)
                }
                ChoiceRow {
                    label: "Центрирование активного"
                    values: ["never", "always", "on_overflow"]
                    labels: ["Никогда", "Всегда", "При переполнении"]
                    value: page.umbVal("layout.scrolling.center_focused", "never")
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "layout.scrolling", "center_focused", "\"" + v + "\"")
                }
                ToggleRow {
                    label: "Центрировать неполную полосу"
                    checked: page.umbVal("layout.scrolling.center_underfull_strip", true)
                    onToggled: (v) => page.setUmb("src/appearance.toml", "layout.scrolling", "center_underfull_strip", v ? "true" : "false")
                }
                ToggleRow {
                    label: "Новые окна выходят из фуллскрина"
                    checked: page.umbVal("layout.new_exits_fullscreen", false)
                    onToggled: (v) => page.setUmb("src/appearance.toml", "layout", "new_exits_fullscreen", v ? "true" : "false")
                }
                ToggleRow {
                    label: "Двоичное: новые к курсору"
                    checked: page.umbVal("layout.dwindle.new_toward_cursor", false)
                    onToggled: (v) => page.setUmb("src/appearance.toml", "layout.dwindle", "new_toward_cursor", v ? "true" : "false")
                }
                ToggleRow {
                    label: "Двоичное: сохранять разделение"
                    checked: page.umbVal("layout.dwindle.preserve_split", true)
                    onToggled: (v) => page.setUmb("src/appearance.toml", "layout.dwindle", "preserve_split", v ? "true" : "false")
                }
                ChoiceRow {
                    label: "Мастер: положение"
                    values: ["left", "right", "center"]
                    labels: ["Слева", "Справа", "По центру"]
                    value: page.umbVal("layout.master.position", "left")
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "layout.master", "position", "\"" + v + "\"")
                }
                ParamRow {
                    label: "Мастер: доля ширины"
                    min: 0.1
                    max: 0.9
                    value: page.umbVal("layout.master.default_width_fraction", 0.55)
                    displayMul: 100
                    suffix: "%"
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "layout.master", "default_width_fraction", Math.round(v * 100) / 100)
                }
                ToggleRow {
                    label: "Мастер: новые сверху"
                    checked: page.umbVal("layout.master.new_on_top", true)
                    onToggled: (v) => page.setUmb("src/appearance.toml", "layout.master", "new_on_top", v ? "true" : "false")
                }
                ToggleRow {
                    label: "Мастер: новые становятся мастером"
                    checked: page.umbVal("layout.master.new_becomes_master", false)
                    onToggled: (v) => page.setUmb("src/appearance.toml", "layout.master", "new_becomes_master", v ? "true" : "false")
                }
            }

            Card { // тени
                Layout.fillWidth: true
                title: "Тени"

                ToggleRow {
                    label: "Тени окон"
                    checked: page.umbVal("appearance.shadow.enabled", true)
                    onToggled: (v) => page.setUmb("src/appearance.toml", "appearance.shadow", "enabled", v ? "true" : "false")
                }
                ParamRow {
                    label: "Мягкость тени"
                    min: 0
                    max: 100
                    value: page.umbVal("appearance.shadow.softness", 50)
                    displayMul: 1
                    suffix: ""
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "appearance.shadow", "softness", Math.round(v))
                }
            }

            Card { // анимации
                Layout.fillWidth: true
                title: "Анимации"

                ToggleRow {
                    label: "Анимации окон"
                    checked: page.umbVal("animation.enabled", true)
                    onToggled: (v) => page.setUmb("src/general.toml", "animation", "enabled", v ? "true" : "false")
                }

                GroupCaption { text: "Окна (открытие)" }
                ParamRow {
                    label: "Длительность"
                    min: 50
                    max: 1000
                    value: page.umbVal("animation.windows_in.duration_ms", 220)
                    displayMul: 1
                    suffix: " мс"
                    onCommitted: (v) => page.setUmb("src/general.toml", "animation.windows_in", "duration_ms", Math.round(v))
                }
                ChoiceRow {
                    label: "Стиль"
                    values: ["popin", "zoom", "slide", "fade", "none"]
                    labels: ["Popin", "Zoom", "Slide", "Fade", "Нет"]
                    value: page.umbVal("animation.windows_in.style", "popin")
                    onCommitted: (v) => page.setUmb("src/general.toml", "animation.windows_in", "style", "\"" + v + "\"")
                }

                GroupCaption { text: "Окна (закрытие)" }
                ParamRow {
                    label: "Длительность"
                    min: 50
                    max: 1000
                    value: page.umbVal("animation.windows_out.duration_ms", 180)
                    displayMul: 1
                    suffix: " мс"
                    onCommitted: (v) => page.setUmb("src/general.toml", "animation.windows_out", "duration_ms", Math.round(v))
                }
                ChoiceRow {
                    label: "Стиль"
                    values: ["fade", "slide", "popin", "zoom"]
                    labels: ["Fade", "Slide", "Popin", "Zoom"]
                    value: page.umbVal("animation.windows_out.style", "fade")
                    onCommitted: (v) => page.setUmb("src/general.toml", "animation.windows_out", "style", "\"" + v + "\"")
                }

                GroupCaption { text: "Окна (перемещение)" }
                ParamRow {
                    label: "Длительность"
                    min: 50
                    max: 1000
                    value: page.umbVal("animation.windows_move.duration_ms", 250)
                    displayMul: 1
                    suffix: " мс"
                    onCommitted: (v) => page.setUmb("src/general.toml", "animation.windows_move", "duration_ms", Math.round(v))
                }

                GroupCaption { text: "Рабочие пространства" }
                ParamRow {
                    label: "Длительность"
                    min: 50
                    max: 1000
                    value: page.umbVal("animation.workspaces.duration_ms", 300)
                    displayMul: 1
                    suffix: " мс"
                    onCommitted: (v) => page.setUmb("src/general.toml", "animation.workspaces", "duration_ms", Math.round(v))
                }
                ChoiceRow {
                    label: "Стиль"
                    values: ["slide", "reveal"]
                    labels: ["Slide", "Reveal"]
                    value: page.umbVal("animation.workspaces.style", "slide")
                    onCommitted: (v) => page.setUmb("src/general.toml", "animation.workspaces", "style", "\"" + v + "\"")
                }

                GroupCaption { text: "Граница" }
                ParamRow {
                    label: "Длительность"
                    min: 50
                    max: 1000
                    value: page.umbVal("animation.border.duration_ms", 180)
                    displayMul: 1
                    suffix: " мс"
                    onCommitted: (v) => page.setUmb("src/general.toml", "animation.border", "duration_ms", Math.round(v))
                }

                GroupCaption { text: "Затемнение неактивных" }
                ToggleRow {
                    label: "Затемнять неактивные окна"
                    checked: page.umbVal("animation.dim_unfocused.enabled", true)
                    onToggled: (v) => page.setUmb("src/general.toml", "animation.dim_unfocused", "enabled", v ? "true" : "false")
                }
                ParamRow {
                    label: "Затемнение"
                    min: 0
                    max: 1
                    value: page.umbVal("animation.dim_unfocused.dim", 0.12)
                    displayMul: 100
                    suffix: "%"
                    onCommitted: (v) => page.setUmb("src/general.toml", "animation.dim_unfocused", "dim", Math.round(v * 100) / 100)
                }

                GroupCaption { text: "Scratchpad" }
                ToggleRow {
                    label: "Анимация scratchpad"
                    checked: page.umbVal("animation.scratchpad.enabled", false)
                    onToggled: (v) => page.setUmb("src/general.toml", "animation.scratchpad", "enabled", v ? "true" : "false")
                }
                ParamRow {
                    label: "Затемнение"
                    min: 0
                    max: 1
                    value: page.umbVal("animation.scratchpad.dim", 0.5)
                    displayMul: 100
                    suffix: "%"
                    onCommitted: (v) => page.setUmb("src/general.toml", "animation.scratchpad", "dim", Math.round(v * 100) / 100)
                }
                ToggleRow {
                    label: "Размытие"
                    checked: page.umbVal("animation.scratchpad.blur", true)
                    onToggled: (v) => page.setUmb("src/general.toml", "animation.scratchpad", "blur", v ? "true" : "false")
                }
                ParamRow {
                    label: "Масштаб"
                    min: 0
                    max: 1
                    value: page.umbVal("animation.scratchpad.scale", 0.0)
                    displayMul: 100
                    suffix: "%"
                    onCommitted: (v) => page.setUmb("src/general.toml", "animation.scratchpad", "scale", Math.round(v * 100) / 100)
                }

                GroupCaption { text: "Перетаскивание" }
                ToggleRow {
                    label: "Физика перетаскивания окон"
                    checked: page.umbVal("animation.windows_drag.physics", true)
                    onToggled: (v) => page.setUmb("src/general.toml", "animation.windows_drag", "physics", v ? "true" : "false")
                }
            }

            Card { // эффекты
                Layout.fillWidth: true
                title: "Эффекты"

                ToggleRow {
                    label: "Размытие фона"
                    checked: page.umbVal("appearance.blur.enabled", true)
                    onToggled: (v) => page.setUmb("src/appearance.toml", "appearance.blur", "enabled", v ? "true" : "false")
                }
                ChoiceRow {
                    label: "Граница"
                    values: ["", "pulse", "audio"]
                    labels: ["Выключено", "Pulse", "Audio"]
                    value: page.umbVal("effects.border", "")
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "effects", "border", "\"" + v + "\"")
                }
                ChoiceRow {
                    label: "Окно"
                    values: ["", "scanlines"]
                    labels: ["Выключено", "Сканлайны"]
                    value: page.umbVal("effects.window", "")
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "effects", "window", "\"" + v + "\"")
                }
                ChoiceRow {
                    label: "Экран"
                    values: ["", "vignette"]
                    labels: ["Выключено", "Виньетка"]
                    value: page.umbVal("effects.screen", "")
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "effects", "screen", "\"" + v + "\"")
                }
                ChoiceRow {
                    label: "Курсор"
                    values: ["", "glow", "trail", "trail-path"]
                    labels: ["Выключено", "Свечение", "Шлейф", "Шлейф-путь"]
                    value: page.umbVal("effects.cursor", "")
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "effects", "cursor", "\"" + v + "\"")
                }
                ParamRow {
                    label: "Максимум FPS эффектов"
                    min: 0
                    max: 240
                    value: page.umbVal("effects.max_fps", 60)
                    displayMul: 1
                    suffix: " fps"
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "effects", "max_fps", Math.round(v))
                }
            }

            Card { // рабочие пространства
                Layout.fillWidth: true
                title: "Рабочие пространства"

                ToggleRow {
                    label: "Переключение туда-обратно"
                    checked: page.umbVal("workspaces.back_and_forth", false)
                    onToggled: (v) => page.setUmb("src/general.toml", "workspaces", "back_and_forth", v ? "true" : "false")
                }
                ToggleRow {
                    label: "Пустое пространство сверху"
                    checked: page.umbVal("workspaces.empty_above", false)
                    onToggled: (v) => page.setUmb("src/general.toml", "workspaces", "empty_above", v ? "true" : "false")
                }
                ParamRow {
                    label: "Масштаб обзора"
                    min: 0.1
                    max: 0.75
                    value: page.umbVal("overview.zoom", 0.4)
                    displayMul: 100
                    suffix: "%"
                    onCommitted: (v) => page.setUmb("src/general.toml", "overview", "zoom", Math.round(v * 100) / 100)
                }
                ToggleRow {
                    label: "Размытие фона обзора"
                    checked: page.umbVal("overview.background_blur", true)
                    onToggled: (v) => page.setUmb("src/general.toml", "overview", "background_blur", v ? "true" : "false")
                }
                ToggleRow {
                    label: "Обои рабочего пространства"
                    checked: page.umbVal("overview.workspace_wallpaper", false)
                    onToggled: (v) => page.setUmb("src/general.toml", "overview", "workspace_wallpaper", v ? "true" : "false")
                }
                ToggleRow {
                    label: "Подсказки обзора"
                    checked: page.umbVal("overview.shortcuts", true)
                    onToggled: (v) => page.setUmb("src/general.toml", "overview", "shortcuts", v ? "true" : "false")
                }
            }

            Card { // горячие углы
                Layout.fillWidth: true
                title: "Горячие углы"

                GroupCaption { text: "Левый верхний" }
                ToggleRow {
                    label: "Включён"
                    checked: page.umbVal("hot_corners.top_left.enabled", false)
                    onToggled: (v) => page.setUmb("src/appearance.toml", "hot_corners.top_left", "enabled", v ? "true" : "false")
                }
                ChoiceRow {
                    label: "Действие"
                    values: ["overview-open", "overview-close", "overview-toggle"]
                    labels: ["Обзор", "Закрыть обзор", "Переключить обзор"]
                    value: page.umbVal("hot_corners.top_left.action", "overview-open")
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "hot_corners.top_left", "action", "\"" + v + "\"")
                }
                ParamRow {
                    label: "Задержка"
                    min: 0
                    max: 2000
                    value: page.umbVal("hot_corners.top_left.delay_ms", 500)
                    displayMul: 1
                    suffix: " мс"
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "hot_corners.top_left", "delay_ms", Math.round(v))
                }

                GroupCaption { text: "Правый верхний" }
                ToggleRow {
                    label: "Включён"
                    checked: page.umbVal("hot_corners.top_right.enabled", false)
                    onToggled: (v) => page.setUmb("src/appearance.toml", "hot_corners.top_right", "enabled", v ? "true" : "false")
                }
                ChoiceRow {
                    label: "Действие"
                    values: ["overview-open", "overview-close", "overview-toggle"]
                    labels: ["Обзор", "Закрыть обзор", "Переключить обзор"]
                    value: page.umbVal("hot_corners.top_right.action", "overview-open")
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "hot_corners.top_right", "action", "\"" + v + "\"")
                }
                ParamRow {
                    label: "Задержка"
                    min: 0
                    max: 2000
                    value: page.umbVal("hot_corners.top_right.delay_ms", 500)
                    displayMul: 1
                    suffix: " мс"
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "hot_corners.top_right", "delay_ms", Math.round(v))
                }

                GroupCaption { text: "Левый нижний" }
                ToggleRow {
                    label: "Включён"
                    checked: page.umbVal("hot_corners.bottom_left.enabled", false)
                    onToggled: (v) => page.setUmb("src/appearance.toml", "hot_corners.bottom_left", "enabled", v ? "true" : "false")
                }
                ChoiceRow {
                    label: "Действие"
                    values: ["overview-open", "overview-close", "overview-toggle"]
                    labels: ["Обзор", "Закрыть обзор", "Переключить обзор"]
                    value: page.umbVal("hot_corners.bottom_left.action", "overview-open")
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "hot_corners.bottom_left", "action", "\"" + v + "\"")
                }
                ParamRow {
                    label: "Задержка"
                    min: 0
                    max: 2000
                    value: page.umbVal("hot_corners.bottom_left.delay_ms", 500)
                    displayMul: 1
                    suffix: " мс"
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "hot_corners.bottom_left", "delay_ms", Math.round(v))
                }

                GroupCaption { text: "Правый нижний" }
                ToggleRow {
                    label: "Включён"
                    checked: page.umbVal("hot_corners.bottom_right.enabled", false)
                    onToggled: (v) => page.setUmb("src/appearance.toml", "hot_corners.bottom_right", "enabled", v ? "true" : "false")
                }
                ChoiceRow {
                    label: "Действие"
                    values: ["overview-open", "overview-close", "overview-toggle"]
                    labels: ["Обзор", "Закрыть обзор", "Переключить обзор"]
                    value: page.umbVal("hot_corners.bottom_right.action", "overview-open")
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "hot_corners.bottom_right", "action", "\"" + v + "\"")
                }
                ParamRow {
                    label: "Задержка"
                    min: 0
                    max: 2000
                    value: page.umbVal("hot_corners.bottom_right.delay_ms", 500)
                    displayMul: 1
                    suffix: " мс"
                    onCommitted: (v) => page.setUmb("src/appearance.toml", "hot_corners.bottom_right", "delay_ms", Math.round(v))
                }
            }
        }

        // 6. Ввод (мышь и клавиатура Umbriel)
        ColumnLayout {
            visible: page.sectionId === "input"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SectionHeader {
                title: "Ввод"
                caption: "Мышь и клавиатура — настройки Umbriel"
            }

            Card {
                Layout.fillWidth: true
                title: "Мышь"

                SSlider {
                    label: "Скорость указателя"
                    from: -1.0
                    to: 1.0
                    step: 0.05
                    value: page.umbVal("input.mouse.sensitivity", 0)
                    valueText: (v) => Number(v).toFixed(2)
                    onCommitted: (v) => page.setInputValue("input.mouse", "sensitivity", Math.round(v * 20) / 20)
                }
                SToggle {
                    label: "Прямой ввод (без разгона)"
                    checked: page.umbVal("input.mouse.accel_profile", "adaptive") === "flat"
                    onToggled: (v) => page.setInputValue("input.mouse", "accel_profile", v ? "flat" : "adaptive")
                }
                SToggle {
                    label: "Обратный скролл"
                    checked: page.umbVal("input.mouse.natural_scroll", false)
                    onToggled: (v) => page.setInputValue("input.mouse", "natural_scroll", v)
                }
                SToggle {
                    label: "Для левшей"
                    checked: page.umbVal("input.mouse.left_handed", false)
                    onToggled: (v) => page.setInputValue("input.mouse", "left_handed", v)
                }
            }

            Card {
                Layout.fillWidth: true
                title: "Клавиатура"

                UmbrielTextField {
                    configKey: "input.keyboard.layout"
                    configSection: "input.keyboard"
                    configName: "layout"
                    fieldLabel: "Раскладки"
                    hint: "Например, us,ru"
                }
                UmbrielTextField {
                    configKey: "input.keyboard.options"
                    configSection: "input.keyboard"
                    configName: "options"
                    fieldLabel: "Опции"
                    hint: "Например, grp:alt_shift_toggle"
                }
                SSlider {
                    label: "Частота повтора"
                    from: 10
                    to: 80
                    step: 1
                    value: page.umbVal("input.keyboard.repeat_rate", 25)
                    valueText: (v) => Math.round(v) + " /с"
                    onCommitted: (v) => page.setInputValue("input.keyboard", "repeat_rate", Math.round(v))
                }
                SSlider {
                    label: "Задержка повтора"
                    from: 100
                    to: 800
                    step: 10
                    value: page.umbVal("input.keyboard.repeat_delay", 600)
                    valueText: (v) => Math.round(v) + " мс"
                    onCommitted: (v) => page.setInputValue("input.keyboard", "repeat_delay", Math.round(v / 10) * 10)
                }
                Button {
                    Layout.topMargin: Theme.dp(4)
                    text: "Следующая раскладка"
                    icon: "keyboard"
                    variant: "tonal"
                    onClicked: Quickshell.execDetached(["umbriel", "msg", "keyboard-layout-next"])
                }
            }

            Card {
                Layout.fillWidth: true
                title: "Мышь · сброс"

                LText {
                    Layout.fillWidth: true
                    text: "Вернуть скорость и режим указателя, прокрутку и расположение мыши к заводским значениям."
                    role: "bodySmall"
                    color: Theme.subtextDim
                    wrapMode: Text.WordWrap
                }
                Button {
                    Layout.topMargin: Theme.dp(4)
                    text: "Вернуть заводские"
                    icon: "restart_alt"
                    variant: "tonal"
                    onClicked: page.resetInputDefaults()
                }
            }
        }

        // 7. Экран (карточка на каждый выход Umbriel)
        ColumnLayout {
            visible: page.sectionId === "display"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SectionHeader {
                title: "Экран"
                caption: "Настройки выходов Umbriel · панель на " + (page.outputName || "экране")
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.dp(8)

                Button {
                    text: "Обновить список"
                    icon: "sync"
                    variant: "tonal"
                    onClicked: {
                        page.reloadUmb();
                        page.reloadOutputs();
                    }
                }
                LText {
                    Layout.fillWidth: true
                    visible: page.outputsError !== ""
                    text: page.outputsError
                    role: "bodySmall"
                    color: Theme.error
                    wrapMode: Text.WordWrap
                }
            }

            Repeater {
                model: page.outputs

                delegate: Card {
                    id: outputCard
                    required property var modelData

                    Layout.fillWidth: true
                    title: page.outputTitle(outputCard.modelData)

                    RowLayout {
                        Layout.fillWidth: true
                        visible: Boolean(outputCard.modelData.active_workspace)
                            || Boolean(outputCard.modelData.focused)
                            || !Boolean(outputCard.modelData.enabled)
                        spacing: Theme.dp(6)

                        Badge {
                            visible: Boolean(outputCard.modelData.active_workspace)
                            text: "Активен"
                            tone: "neutral"
                        }
                        Badge {
                            visible: Boolean(outputCard.modelData.focused)
                            text: "В фокусе"
                            tone: "accent"
                        }
                        Badge {
                            visible: !Boolean(outputCard.modelData.enabled)
                            text: "Выключен"
                            tone: "error"
                        }
                    }

                    SPick {
                        label: "Разрешение"
                        options: page.outputResolutionOptions(outputCard.modelData)
                        value: page.currentOutputResolution(outputCard.modelData)
                        visible: options.length > 0
                        onPicked: (resolution) => page.setOutputResolution(outputCard.modelData, String(resolution))
                    }
                    SPick {
                        label: "Частота"
                        options: page.outputRateOptions(outputCard.modelData,
                            page.currentOutputResolution(outputCard.modelData))
                        value: page.currentOutputModeKey(outputCard.modelData)
                        visible: options.length > 0
                        onPicked: (mode) => page.setOutputMode(outputCard.modelData, String(mode))
                    }
                    SSlider {
                        label: "Масштаб"
                        from: 1.0
                        to: 3.0
                        step: 0.05
                        value: Number(page.umbVal("output." + outputCard.modelData.name + ".scale",
                                                   Number(outputCard.modelData.scale) || 1.0))
                        valueText: (v) => Number(v).toFixed(2)
                        onCommitted: (v) => {
                            const output = outputCard.modelData;
                            const key = "output." + output.name + ".scale";
                            const fallback = Number(output.scale) || 1.0;
                            const current = Number(page.umbVal(key, fallback));
                            const next = Math.round(v * 20) / 20;
                            if (Math.abs(current - next) < 0.001) return;
                            page.setOutputValue(output, "scale", next, current);
                        }
                    }
                    SSelect {
                        label: "Поворот"
                        values: ["normal", "90", "180", "270"]
                        labels: ["0°", "90°", "180°", "270°"]
                        value: page.umbVal("output." + outputCard.modelData.name + ".transform",
                                           outputCard.modelData.transform || "normal")
                        onCommitted: (transform) => {
                            const output = outputCard.modelData;
                            const key = "output." + output.name + ".transform";
                            const current = page.umbVal(key, output.transform || "normal");
                            page.setOutputValue(output, "transform", String(transform), current);
                        }
                    }
                    SToggle {
                        label: "VRR"
                        sub: page.outputVrrStatus(outputCard.modelData)
                        checked: page.outputVrr(outputCard.modelData)
                        onToggled: (enabled) => page.setOutputVrr(outputCard.modelData, enabled)
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: Theme.dp(4)
                        spacing: Theme.dp(8)

                        Button {
                            text: "Выключить экран"
                            icon: "bedtime"
                            variant: "tonal"
                            disabled: !outputCard.modelData.enabled
                            onClicked: page.outputMessage("dpms-off", outputCard.modelData.name)
                        }
                        Button {
                            text: "Включить экран"
                            icon: "power_settings_new"
                            variant: "tonal"
                            onClicked: page.outputMessage("dpms-on", outputCard.modelData.name)
                        }
                    }

                    LText {
                        Layout.fillWidth: true
                        Layout.topMargin: Theme.dp(2)
                        role: "labelSmall"
                        color: Theme.subtext
                        wrapMode: Text.WordWrap
                        text: "Отключение выхода выполняется самим композитором (Umbriel после этого убирает экран из списка и вернуть его из шелла нельзя). Пользуйтесь кнопками сна выше."
                    }

                    LText {
                        Layout.fillWidth: true
                        visible: outputCard.modelData.enabled
                            && String(outputCard.modelData.name) === page.outputName
                        text: "Отключение этого выхода скроет текущую панель; кнопка требует подтверждения."
                        role: "bodySmall"
                        color: Theme.subtextDim
                        wrapMode: Text.WordWrap
                    }
                }
            }

            Card {
                Layout.fillWidth: true
                visible: page.outputs.length === 0
                title: "Нет подключённых выходов"
                LText {
                    Layout.fillWidth: true
                    text: page.outputsError !== "" ? page.outputsError : "Обновите список выходов Umbriel."
                    role: "bodySmall"
                    color: page.outputsError !== "" ? Theme.error : Theme.subtextDim
                    wrapMode: Text.WordWrap
                }
            }
        }

        ColumnLayout {
            visible: page.sectionId === "media"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SCard {
                Layout.fillWidth: true
                title: "Медиапилюля"

                ChoiceRow {
                    label: "Стиль обложки"
                    values: ["cover", "disc"]
                    labels: ["Обложка", "Пластинка"]
                    value: Prefs.mediaStyle
                    sub: "Чем показать текущий трек в медиапилюле."
                    onCommitted: (v) => Prefs.set("mediaStyle", v)
                }
            }
        }

        ColumnLayout {
            visible: page.sectionId === "clock"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SCard {
                Layout.fillWidth: true
                title: "Время"

                SToggle {
                    label: "Секунды в часах"
                    checked: Prefs.clockSeconds
                    onToggled: (v) => Prefs.set("clockSeconds", v)
                }
                ChoiceRow {
                    label: "Формат времени"
                    values: [false, true]
                    labels: ["24 часа", "12 часов"]
                    value: Prefs.clock12
                    onCommitted: (v) => Prefs.set("clock12", v)
                }
            }

            SCard {
                Layout.fillWidth: true
                title: "Дата"

                SToggle {
                    label: "Показывать день недели"
                    checked: Prefs.clockWeekday
                    onToggled: (v) => Prefs.set("clockWeekday", v)
                }
                SPick {
                    label: "Формат даты"
                    options: [
                        { key: "d MMMM", label: "d MMMM · 18 октября" },
                        { key: "d MMM", label: "d MMM · 18 окт." },
                        { key: "dd.MM.yyyy", label: "dd.MM.yyyy · 18.10.2026" },
                        { key: "yyyy-MM-dd", label: "yyyy-MM-dd · 2026-10-18" }
                    ]
                    value: Prefs.clockDateFmt
                    onPicked: (v) => Prefs.set("clockDateFmt", v)
                }
                LText {
                    Layout.fillWidth: true
                    role: "bodySmall"
                    color: Theme.subtextDim
                    text: "Формат даты и 12/24-часовой режим применяются к часам островка и шапке панели."
                    wrapMode: Text.WordWrap
                }
            }
        }

        ColumnLayout {
            visible: page.sectionId === "motion"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SCard {
                Layout.fillWidth: true
                title: "Анимация Oberon"

                ParamRow {
                    label: "Скорость анимаций"
                    min: 0.5
                    max: 1.5
                    value: Prefs.motionScale
                    onCommitted: (v) => Prefs.set("motionScale", v)
                }
            }
        }

        ColumnLayout {
            visible: page.sectionId === "system"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SCard {
                Layout.fillWidth: true
                title: "Сейчас"

                SystemMeter {
                    label: "Память"
                    value: page.usageText(SysStats.memUsed, SysStats.memTotal, SysStats.memFrac)
                    fraction: SysStats.memFrac
                }
                SystemMeter {
                    label: "Swap"
                    value: SysStats.swapTotal > 0
                        ? page.usageText(SysStats.swapUsed, SysStats.swapTotal, SysStats.swapFrac)
                        : "Не используется"
                    fraction: SysStats.swapFrac
                }
                SystemMeter {
                    label: "Диск /"
                    value: page.rootDiskUsageText()
                    fraction: page.rootDisk && Number(page.rootDisk.total) > 0
                        ? Number(page.rootDisk.used) / Number(page.rootDisk.total) : 0
                }

                GridLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.dp(8)
                    columns: 3
                    rowSpacing: Theme.dp(12)
                    columnSpacing: Theme.dp(16)

                    SystemDatum {
                        label: "Средняя нагрузка · 1 / 5 / 15"
                        value: SysStats.load1.toFixed(2) + " / " + SysStats.load5.toFixed(2)
                            + " / " + SysStats.load15.toFixed(2)
                    }
                    SystemDatum {
                        label: "Процессы"
                        value: String(SysStats.procCount)
                    }
                    SystemDatum {
                        label: "Температура CPU"
                        value: page.temperatureText(SysStats.tempC)
                    }
                    SystemDatum {
                        label: "Температура GPU"
                        value: page.temperatureText(SysStats.gpuTempC)
                    }
                    SystemDatum {
                        label: "Загрузка GPU / питание"
                        value: (SysStats.gpuLoadAvailable ? SysStats.gpuUsage + "%" : "Нет данных")
                            + (SysStats.gpuPowerW > 0
                                ? " · " + Number(SysStats.gpuPowerW).toFixed(1) + " Вт" : "")
                    }
                    SystemDatum {
                        label: "Аптайм"
                        value: SysStats.formatUptime(SysStats.uptime)
                    }
                    SystemDatum {
                        label: "RSS оболочки"
                        value: SysStats.shellRss > 0
                            ? SysStats.formatBytes(SysStats.shellRss) : "Сбор данных…"
                    }
                }
            }

            SCard {
                Layout.fillWidth: true
                title: "Машина"

                LText {
                    Layout.fillWidth: true
                    visible: page.machineError !== ""
                    text: page.machineError
                    role: "bodySmall"
                    color: Theme.error
                    wrapMode: Text.WordWrap
                }

                SystemInfoRow {
                    label: "ОС"
                    value: page.machineValue("os", SysStats.distro)
                }
                SystemInfoRow {
                    label: "Ядро"
                    value: page.machineValue("kernel", SysStats.kernel)
                }
                SystemInfoRow {
                    label: "Композитор"
                    value: page.machineValue("compositor", "")
                }
                SystemInfoRow {
                    label: "CPU"
                    value: page.machineValue("cpu", SysStats.cpuModel)
                }
                SystemInfoRow {
                    label: "GPU"
                    value: page.machineValue("gpu", SysStats.gpuModel)
                }
                SystemInfoRow {
                    label: "Имя машины"
                    value: page.machineValue("host", SysStats.host)
                }
                SystemInfoRow {
                    label: "Аптайм"
                    value: SysStats.formatUptime(SysStats.uptime)
                }

                LText {
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.dp(4)
                    text: "Статические сведения обновляются при открытии раздела и раз в 30 секунд."
                    role: "bodySmall"
                    color: Theme.subtextDim
                    wrapMode: Text.WordWrap
                }
            }

            SCard {
                Layout.fillWidth: true
                title: "Инструменты"

                SButton {
                    text: "Открыть диспетчер задач"
                    icon: "memory"
                    variant: "tonal"
                    onClicked: page.openTaskman()
                }

                SButton {
                    text: page.systemInfoCopied ? "Сведения скопированы" : "Скопировать сведения"
                    icon: "content_copy"
                    variant: "tonal"
                    onClicked: page.copySystemInfo()
                }

                SButton {
                    text: "Запись экрана"
                    icon: "videocam"
                    variant: "tonal"
                    onClicked: if (page.win && page.win.shell) page.win.shell.setPage("record")
                }
            }

            SCard {
                Layout.fillWidth: true
                title: "Сброс настроек"

                LText {
                    Layout.fillWidth: true
                    role: "bodySmall"
                    color: Theme.subtext
                    wrapMode: Text.WordWrap
                    text: "Вернуть все параметры Oberon к значениям по умолчанию. Действие нужно подтвердить повторным нажатием."
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(8)

                    SButton {
                        danger: true
                        variant: page.resetArmed ? "filled" : "outlined"
                        icon: page.resetArmed ? "warning" : "restart_alt"
                        text: page.resetDone ? "Настройки сброшены"
                            : (page.resetArmed ? "Подтвердить сброс" : "Сбросить настройки")
                        disabled: page.resetDone
                        onClicked: {
                            if (!page.resetArmed) {
                                page.resetArmed = true;
                                resetArmTimer.restart();
                                return;
                            }
                            Prefs.reset();
                            page.applyIdle();
                            Quickshell.execDetached(["sh", Quickshell.env("HOME") + "/oberon/scripts/set-blur.sh", String(Prefs.blurAmount)]);
                            Quickshell.execDetached(["sh", Quickshell.env("HOME") + "/oberon/scripts/apply-mangohud.sh"]);
                            page.scheduleThemeApply();
                            page.resetArmed = false;
                            page.resetDone = true;
                            resetDoneTimer.restart();
                        }
                    }

                    Item { Layout.fillWidth: true }
                }

                LText {
                    Layout.fillWidth: true
                    visible: page.resetArmed
                    role: "bodySmall"
                    color: Theme.error
                    text: "Нажмите ещё раз в течение трёх секунд."
                }
                LText {
                    Layout.fillWidth: true
                    visible: page.resetDone
                    role: "bodySmall"
                    color: Theme.success
                    text: "Значения по умолчанию сохранены в prefs.json."
                }

                Timer {
                    id: resetArmTimer
                    interval: 3000
                    onTriggered: page.resetArmed = false
                }
                Timer {
                    id: resetDoneTimer
                    interval: 2500
                    onTriggered: page.resetDone = false
                }
            }
        }

        ColumnLayout {
            visible: page.sectionId === "cc"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SCard {
                Layout.fillWidth: true
                title: "Быстрые настройки"

                LText {
                    Layout.fillWidth: true
                    role: "bodySmall"
                    color: Theme.subtext
                    wrapMode: Text.WordWrap
                    text: "Плитки уже можно переставлять и скрывать: откройте главную панель и нажмите карандаш. Перетаскивание и настройка раскладки внутри этого раздела — следующая волна."
                }
                SButton {
                    text: "Открыть быстрые настройки"
                    icon: "tune"
                    variant: "tonal"
                    onClicked: if (page.win && page.win.shell) page.win.shell.setPage("")
                }
            }
        }

        ColumnLayout {
            visible: page.sectionId === "launch"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SCard {
                Layout.fillWidth: true
                title: "Лаунчер"

                LText {
                    Layout.fillWidth: true
                    role: "bodySmall"
                    color: Theme.subtext
                    wrapMode: Text.WordWrap
                    text: "В текущих настройках Oberon параметры поиска приложений не хранились в Prefs. Этот раздел оставлен в реестре для будущих настроек лаунчера."
                }
            }
        }

        ColumnLayout {
            visible: page.sectionId === "lock"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SCard {
                Layout.fillWidth: true
                title: "Экран блокировки"

                LText {
                    Layout.fillWidth: true
                    role: "bodySmall"
                    color: Theme.subtext
                    wrapMode: Text.WordWrap
                    text: "Время автоматической блокировки настраивается в разделе «Питание». Отдельных параметров экрана блокировки в старой странице настроек не было."
                }
            }
        }

        ColumnLayout {
            visible: page.sectionId === "vault"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SCard {
                Layout.fillWidth: true
                title: "Хранилище паролей"

                LText {
                    Layout.fillWidth: true
                    role: "bodySmall"
                    color: Theme.subtext
                    wrapMode: Text.WordWrap
                    text: "Записи шифруются мастер-паролем. При закрытии страницы или потере фокуса хранилище блокируется; время бездействия — 15 минут."
                }
                SButton {
                    text: "Открыть хранилище"
                    icon: "key"
                    variant: "tonal"
                    onClicked: if (page.win && page.win.shell) page.win.shell.openVault()
                }
            }
        }

        GamesPage {
            visible: page.sectionId === "games"
            Layout.fillWidth: true
            win: page.win
        }
        KeybindsPage {
            visible: page.visible && page.sectionId === "keys"
            Layout.fillWidth: true
            win: page.win
        }
        UpdatesPage {
            visible: page.sectionId === "updates"
            Layout.fillWidth: true
            win: page.win
        }
    }

    // Switch и TextInput ломают биндинг при ручном изменении — синхронизируем
    // состояние обратно при записи в Prefs. (Переключатели ToggleRow держат
    // привязку сами через Qt.binding, поэтому здесь остаётся поле города
    // и четыре поля ЧЧ:ММ.)
    Connections {
        target: Prefs

        function onWeatherCityChanged() { cityField.text = Prefs.weatherCity }

        // поля времени: не трогаем то, которое прямо сейчас редактируют
        function onDndFromChanged() { if (!dndFromField.activeFocus) dndFromField.sync() }
        function onDndToChanged() { if (!dndToField.activeFocus) dndToField.sync() }
        function onNightLightFromChanged() { if (!nightFromField.activeFocus) nightFromField.sync() }
        function onNightLightToChanged() { if (!nightToField.activeFocus) nightToField.sync() }
    }

    // Палитра пересчиталась (matugen перезаписал colors.json → Theme.primary
    // изменился) — подпись в разделе «Тема» переходит в «готово».
    Connections {
        target: Theme

        function onPrimaryChanged() { page.finishThemeApply() }
    }
}
