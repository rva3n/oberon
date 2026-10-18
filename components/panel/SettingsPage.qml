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

    // имя монитора, на котором открыта панель (для раздела «Экран»)
    readonly property string outputName: page.win && page.win.screen ? String(page.win.screen.name) : ""
    // текущие значения настроек Umbriel, прочитанные из umbriel-settings.py
    property var umb: ({})

    visible: win !== null && win.mode === "panel" && win.page === "settings"
    Layout.fillWidth: true
    Layout.minimumHeight: win ? Math.min(Theme.dp(620), win.panelMax - Theme.dp(72)) : Theme.dp(620)
    spacing: Theme.dp(16)

    // При каждом открытии берём id от shell; числовые номера старой версии
    // остаются совместимыми для IPC/тайлов и старых вызовов.
    onVisibleChanged: if (visible) {
        const id = page.sectionIdFor(page.win && page.win.shell ? page.win.shell.settingsSection : "look");
        page.sectionId = id;
        page.history = [id];
        page.historyAt = 0;
        if (page.win && page.win.shell && page.win.shell.settingsSection !== id)
            page.win.shell.settingsSection = id;
        page.reloadUmb();
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

    // При возврате в «Композитор» перечитываем актуальные значения Umbriel.
    onSectionIdChanged: if (visible && sectionId === "compositor") page.reloadUmb()

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
        { id: "opencode", title: "OpenCode", glyph: "bolt", page: "opencode",
          sub: "Лимиты и настройки моделей OpenCode Go.",
          keys: "opencode go model лимиты модели агенты" },
        { id: "display", title: "Экран", glyph: "desktop_windows", page: "display",
          sub: "Разрешение, частота и масштаб подключённого экрана.",
          keys: "display monitor resolution refresh scale layout placement detect экран монитор разрешение герцовка раскладка расположение" },
        { id: "input", title: "Ввод", glyph: "keyboard", page: "input",
          sub: "Мышь, клавиатура, тачпад и фокус Umbriel.",
          keys: "mouse keyboard layouts xkb pointer cursor sensitivity speed accel input мышь клавиатура раскладки указатель курсор скорость чувствительность разгон" },
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
        { id: "controls", title: "Управление", glyph: "tune", pages: ["cc", "launch", "notif", "games", "opencode"] },
        { id: "devices", title: "Устройства", glyph: "desktop_windows", pages: ["display", "input"] },
        { id: "security", title: "Безопасность", glyph: "lock", pages: ["lock", "vault"] },
        { id: "system", title: "Система", glyph: "settings", pages: ["system", "power", "compositor", "updates"] }
    ]

    function sectionIdFor(value) {
        const legacy = ["look", "bar", "power", "notif", "weather", "compositor", "input", "display", "look", "night"];
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

    readonly property var section: page.sectionForId(page.sectionId) || page.sections[0]
    readonly property var activeGroup: page.groupForPage(page.sectionId)
    readonly property var groupPages: page.pagesForGroup(page.activeGroup)
    readonly property bool canBack: page.historyAt > 0
    readonly property bool canForward: page.historyAt < page.history.length - 1

    // однократное чтение настроек Umbriel (один JSON в строке)
    Process {
        id: umbRead

        command: ["python3", Quickshell.env("HOME") + "/oberon/scripts/umbriel-settings.py", "read"]
        running: true
        stdout: SplitParser {
            onRead: (line) => {
                try { page.umb = JSON.parse(line); } catch (e) {}
            }
        }
    }

    // отложенный повторный опрос после записи (config-reload асинхронен)
    Timer {
        id: umbReloadTimer

        interval: 600
        onTriggered: page.reloadUmb()
    }

    // перезапустить чтение настроек Umbriel
    function reloadUmb() {
        umbRead.running = false;
        umbRead.running = true;
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
        Quickshell.execDetached(["python3", Quickshell.env("HOME") + "/oberon/scripts/umbriel-settings.py",
                                 "set", file, section, key, String(tomlValue)]);
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
    // Список id согласован с IdlePill/Island: kb/weather/ws/clock/go/tray.
    readonly property var chipTitles: ({
        "kb": "Раскладка",
        "weather": "Погода",
        "ws": "Рабочие пространства",
        "clock": "Часы",
        "go": "OpenCode",
        "tray": "Трей"
    })
    readonly property var chipOrder: {
        const allowed = ["kb", "weather", "ws", "clock", "go", "tray"];
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
                    label: "Показывать чип OpenCode"
                    checked: Prefs.islandGo
                    onToggled: (v) => Prefs.set("islandGo", v)
                }
                ToggleRow {
                    label: "Островок на всех мониторах"
                    sub: "Показывать капсулу и всплывающие тосты на всех подключённых экранах"
                    checked: Prefs.islandAllScreens
                    onToggled: (v) => Prefs.set("islandAllScreens", v)
                }
            }


            Card { // форма капсулы
                Layout.fillWidth: true
                title: "Форма капсулы"

                ChoiceRow {
                    label: "Стиль островка"
                    values: ["island", "notch"]
                    labels: ["Плавающий", "Выемка"]
                    value: Prefs.barStyle
                    sub: "Плавающая капсула или прижатая к верхней кромке выемка (notch)."
                    onCommitted: (v) => Prefs.set("barStyle", v)
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
                                    : modelData === "go" ? "bolt"
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

        // 6. Ввод (мышь, клавиатура, фокус Umbriel)
        ColumnLayout {
            visible: page.sectionId === "input"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SectionHeader {
                title: "Ввод"
                caption: "Мышь, клавиатура, фокус Umbriel"
            }

            Card { // мышь
                Layout.fillWidth: true
                title: "Мышь"

                ParamRow {
                    label: "Чувствительность"
                    min: -1
                    max: 1
                    value: page.umbVal("input.mouse.sensitivity", 0)
                    displayMul: 100
                    suffix: "%"
                    onCommitted: (v) => page.setUmb("src/input.toml", "input.mouse", "sensitivity", Math.round(v * 100) / 100)
                }
                ToggleRow {
                    label: "Натуральная прокрутка"
                    checked: page.umbVal("input.mouse.natural_scroll", false)
                    onToggled: (v) => page.setUmb("src/input.toml", "input.mouse", "natural_scroll", v ? "true" : "false")
                }
                ChoiceRow {
                    label: "Ускорение курсора"
                    values: ["flat", "adaptive"]
                    labels: ["Выключено", "Адаптивное"]
                    value: page.umbVal("input.mouse.accel_profile", "flat")
                    onCommitted: (v) => page.setUmb("src/input.toml", "input.mouse", "accel_profile", "\"" + v + "\"")
                }
                ToggleRow {
                    label: "Левша"
                    checked: page.umbVal("input.mouse.left_handed", false)
                    onToggled: (v) => page.setUmb("src/input.toml", "input.mouse", "left_handed", v ? "true" : "false")
                }
                ParamRow {
                    label: "Шаг колеса прокрутки"
                    min: 10
                    max: 200
                    value: page.umbVal("input.mouse.scroll_wheel_step", 60)
                    displayMul: 1
                    suffix: ""
                    onCommitted: (v) => page.setUmb("src/input.toml", "input.mouse", "scroll_wheel_step", Math.round(v))
                }
                ToggleRow {
                    label: "Перетаскивание за клиентскую область"
                    checked: page.umbVal("input.client_window_drag", false)
                    onToggled: (v) => page.setUmb("src/input.toml", "input", "client_window_drag", v ? "true" : "false")
                }
                ChoiceRow {
                    label: "Перетаскивание переключает"
                    values: ["none", "floating", "pinned"]
                    labels: ["Ничего", "Плавающие", "Закреплённые"]
                    value: page.umbVal("input.window_drag_toggle", "none")
                    onCommitted: (v) => page.setUmb("src/input.toml", "input", "window_drag_toggle", "\"" + v + "\"")
                }
            }

            Card { // тачпад
                Layout.fillWidth: true
                title: "Тачпад"

                ToggleRow {
                    label: "Тап"
                    checked: page.umbVal("input.touchpad.tap", true)
                    onToggled: (v) => page.setUmb("src/input.toml", "input.touchpad", "tap", v ? "true" : "false")
                }
                ChoiceRow {
                    label: "Кнопки при тапе"
                    values: ["left_right_middle", "left_middle_right"]
                    labels: ["ЛКМ-ПКМ-СКМ", "ЛКМ-СКМ-ПКМ"]
                    value: page.umbVal("input.touchpad.tap_button_map", "left_right_middle")
                    onCommitted: (v) => page.setUmb("src/input.toml", "input.touchpad", "tap_button_map", "\"" + v + "\"")
                }
                ChoiceRow {
                    label: "Метод нажатия"
                    values: ["button_areas", "clickfinger"]
                    labels: ["Кнопки", "Отпечаток"]
                    value: page.umbVal("input.touchpad.click_method", "button_areas")
                    onCommitted: (v) => page.setUmb("src/input.toml", "input.touchpad", "click_method", "\"" + v + "\"")
                }
                ToggleRow {
                    label: "Левша"
                    checked: page.umbVal("input.touchpad.left_handed", false)
                    onToggled: (v) => page.setUmb("src/input.toml", "input.touchpad", "left_handed", v ? "true" : "false")
                }
                ToggleRow {
                    label: "Натуральная прокрутка"
                    checked: page.umbVal("input.touchpad.natural_scroll", true)
                    onToggled: (v) => page.setUmb("src/input.toml", "input.touchpad", "natural_scroll", v ? "true" : "false")
                }
                ToggleRow {
                    label: "Отключать при печати"
                    checked: page.umbVal("input.touchpad.disable_while_typing", true)
                    onToggled: (v) => page.setUmb("src/input.toml", "input.touchpad", "disable_while_typing", v ? "true" : "false")
                }
                ToggleRow {
                    label: "Отключать при внешней мыши"
                    checked: page.umbVal("input.touchpad.disable_on_external_mouse", false)
                    onToggled: (v) => page.setUmb("src/input.toml", "input.touchpad", "disable_on_external_mouse", v ? "true" : "false")
                }
            }

            Card { // клавиатура
                Layout.fillWidth: true
                title: "Клавиатура"

                ParamRow {
                    label: "Задержка повтора"
                    min: 150
                    max: 1000
                    value: page.umbVal("input.keyboard.repeat_delay", 600)
                    displayMul: 1
                    suffix: " мс"
                    onCommitted: (v) => page.setUmb("src/input.toml", "input.keyboard", "repeat_delay", Math.round(v))
                }
                ParamRow {
                    label: "Скорость повтора"
                    min: 10
                    max: 80
                    value: page.umbVal("input.keyboard.repeat_rate", 25)
                    displayMul: 1
                    suffix: " /с"
                    onCommitted: (v) => page.setUmb("src/input.toml", "input.keyboard", "repeat_rate", Math.round(v))
                }
                ChoiceRow {
                    label: "Переключение раскладок"
                    values: ["grp:alt_shift_toggle", "grp:win_space_toggle", "grp:caps_toggle", "grp:ctrl_shift_toggle"]
                    labels: ["Alt+Shift", "Super+Space", "Caps Lock", "Ctrl+Shift"]
                    value: page.umbVal("input.keyboard.options", "grp:alt_shift_toggle")
                    onCommitted: (v) => page.setUmb("src/input.toml", "input.keyboard", "options", "\"" + v + "\"")
                }
            }

            Card { // фокус
                Layout.fillWidth: true
                title: "Фокус"

                ToggleRow {
                    label: "Фокус следует за мышью"
                    checked: page.umbVal("input.focus.follows_mouse", true)
                    onToggled: (v) => page.setUmb("src/input.toml", "input.focus", "follows_mouse", v ? "true" : "false")
                }
                ParamRow {
                    label: "Максимум прокрутки при следовании"
                    min: 0
                    max: 100
                    value: page.umbVal("input.focus.follows_mouse_max_scroll", 0)
                    displayMul: 1
                    suffix: ""
                    onCommitted: (v) => page.setUmb("src/input.toml", "input.focus", "follows_mouse_max_scroll", Math.round(v))
                }
            }

            Card { // прочее
                Layout.fillWidth: true
                title: "Прочее"

                ToggleRow {
                    label: "Вставка средней кнопкой"
                    checked: page.umbVal("input.middle_click_paste", true)
                    onToggled: (v) => page.setUmb("src/input.toml", "input", "middle_click_paste", v ? "true" : "false")
                }
                ToggleRow {
                    label: "Прятать курсор при печати"
                    checked: page.umbVal("input.cursor.hide_when_typing", false)
                    onToggled: (v) => page.setUmb("src/input.toml", "input.cursor", "hide_when_typing", v ? "true" : "false")
                }
            }
        }

        // 7. Экран (монитор этого окна)
        ColumnLayout {
            visible: page.sectionId === "display"
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            SectionHeader {
                title: "Экран"
                caption: "Монитор этого окна: " + page.outputName
            }

            Card {
                Layout.fillWidth: true
                title: page.outputName !== "" ? page.outputName : "Экран"

                ParamRow {
                    label: "Масштаб"
                    min: 75
                    max: 200
                    value: Math.round(page.umbVal("output." + page.outputName + ".scale", 1.0) * 100)
                    displayMul: 1
                    suffix: "%"
                    onCommitted: (v) => {
                        if (page.outputName === "") return;
                        const rounded = Math.round(v / 5) * 5;
                        page.setUmb("src/appearance.toml", "output:" + page.outputName, "scale", rounded / 100);
                    }
                }
                ChoiceRow {
                    id: freqRow
                    label: "Частота"
                    values: page.umbVal("output." + page.outputName + ".modes", [])
                    labels: page.umbVal("output." + page.outputName + ".modes", [])
                    value: page.umbVal("output." + page.outputName + ".mode", "")
                    visible: freqRow.values.length > 0
                    onCommitted: (v) => {
                        if (page.outputName === "") return;
                        page.setUmb("src/appearance.toml", "output:" + page.outputName, "mode", "\"" + v + "\"");
                    }
                }
                ChoiceRow {
                    label: "VRR"
                    values: ["disabled", "always", "fullscreen"]
                    labels: ["Выключен", "Всегда", "В полный экран"]
                    value: page.umbVal("output." + page.outputName + ".vrr", "fullscreen")
                    onCommitted: (v) => {
                        if (page.outputName === "") return;
                        page.setUmb("src/appearance.toml", "output:" + page.outputName, "vrr", "\"" + v + "\"");
                    }
                }
                ChoiceRow {
                    label: "Поворот"
                    values: ["normal", "90", "180", "270"]
                    labels: ["Обычный", "90°", "180°", "270°"]
                    value: page.umbVal("output." + page.outputName + ".transform", "normal")
                    onCommitted: (v) => {
                        if (page.outputName === "") return;
                        page.setUmb("src/appearance.toml", "output:" + page.outputName, "transform", "\"" + v + "\"");
                    }
                }
                ToggleRow {
                    label: "Циклические рабочие пространства"
                    checked: page.umbVal("output." + page.outputName + ".cyclic_workspaces", true)
                    onToggled: (v) => {
                        if (page.outputName === "") return;
                        page.setUmb("src/appearance.toml", "output:" + page.outputName, "cyclic_workspaces", v ? "true" : "false");
                    }
                }
                ChoiceRow {
                    label: "Ось рабочих пространств"
                    values: ["vertical", "horizontal"]
                    labels: ["Вертикально", "Горизонтально"]
                    value: page.umbVal("output." + page.outputName + ".workspace_axis", "vertical")
                    onCommitted: (v) => {
                        if (page.outputName === "") return;
                        page.setUmb("src/appearance.toml", "output:" + page.outputName, "workspace_axis", "\"" + v + "\"");
                    }
                }
                ParamRow {
                    label: "Минимум рабочих пространств"
                    min: 1
                    max: 10
                    value: page.umbVal("output." + page.outputName + ".min_workspaces", 1)
                    displayMul: 1
                    suffix: ""
                    sub: "Требует workspaces = \"dynamic\" у этого вывода (иначе Umbriel игнорирует настройку)."
                    onCommitted: (v) => {
                        if (page.outputName === "") return;
                        page.setUmb("src/appearance.toml", "output:" + page.outputName, "min_workspaces", Math.round(v));
                    }
                }
                ChoiceRow {
                    label: "HDR"
                    values: ["off", "on", "auto", "fullscreen"]
                    labels: ["Выкл", "Вкл", "Авто", "В полный экран"]
                    value: page.umbVal("output." + page.outputName + ".hdr", "off")
                    onCommitted: (v) => {
                        if (page.outputName === "") return;
                        page.setUmb("src/appearance.toml", "output:" + page.outputName, "hdr", "\"" + v + "\"");
                    }
                }
                ChoiceRow {
                    label: "Глубина цвета"
                    values: [8, 10]
                    labels: ["8 бит", "10 бит"]
                    value: page.umbVal("output." + page.outputName + ".bit_depth", 8)
                    onCommitted: (v) => {
                        if (page.outputName === "") return;
                        page.setUmb("src/appearance.toml", "output:" + page.outputName, "bit_depth", v);
                    }
                }
                ParamRow {
                    label: "Яркость SDR-белого"
                    min: 80
                    max: 1000
                    value: page.umbVal("output." + page.outputName + ".sdr_white", 203)
                    displayMul: 1
                    suffix: " кд/м²"
                    onCommitted: (v) => {
                        if (page.outputName === "") return;
                        page.setUmb("src/appearance.toml", "output:" + page.outputName, "sdr_white", Math.round(v));
                    }
                }
                ToggleRow {
                    label: "Прямой вывод (direct scanout)"
                    checked: page.umbVal("output." + page.outputName + ".direct_scanout", false)
                    onToggled: (v) => {
                        if (page.outputName === "") return;
                        page.setUmb("src/appearance.toml", "output:" + page.outputName, "direct_scanout", v ? "true" : "false");
                    }
                }
                ToggleRow {
                    label: "Разрывы (tearing)"
                    checked: page.umbVal("output." + page.outputName + ".tearing", false)
                    onToggled: (v) => {
                        if (page.outputName === "") return;
                        page.setUmb("src/appearance.toml", "output:" + page.outputName, "tearing", v ? "true" : "false");
                    }
                }
                ChoiceRow {
                    label: "Экранный эффект"
                    values: ["", "vignette"]
                    labels: ["Выключено", "Виньетка"]
                    value: page.umbVal("output." + page.outputName + ".screen_effect", "")
                    onCommitted: (v) => {
                        if (page.outputName === "") return;
                        page.setUmb("src/appearance.toml", "output:" + page.outputName, "screen_effect", "\"" + v + "\"");
                    }
                }
                ToggleRow {
                    label: "Фокус при запуске"
                    checked: page.umbVal("output." + page.outputName + ".focus_at_startup", true)
                    onToggled: (v) => {
                        if (page.outputName === "") return;
                        page.setUmb("src/appearance.toml", "output:" + page.outputName, "focus_at_startup", v ? "true" : "false");
                    }
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
                title: "Инструменты"

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
        OpenCodePage {
            visible: page.sectionId === "opencode"
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
