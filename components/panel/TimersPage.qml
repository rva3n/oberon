import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../core"
import "../../ui"
import ".."

// Страница «Таймеры»: чипы «Таймер / Помодоро / Секундомер», крупный счётчик
// в кольце CircularProgress, пресеты и управление. Таймер и секундомер живут в
// синглтоне Chrono; помодоро и мировые часы — локально на странице.
ColumnLayout {
    id: page

    property var win: null
    property string mode: "timer"   // timer | pomodoro | stopwatch

    // ── Помодоро (состояние — только здесь) ────────────────────────────
    property int pFocusMin: 25      // длительность фокуса, мин
    property int pBreakMin: 5       // длительность перерыва, мин
    property bool pCustom: false    // свой пресет
    property string pPhase: "focus" // focus | break
    property bool pRunning: false
    property int pLeft: 25 * 60     // осталось в текущей фазе, с
    property int pRounds: 0         // завершённых фокусов в сете
    property bool pAuto: true       // автостарт следующей фазы

    readonly property int pTotal: (page.pPhase === "break" ? page.pBreakMin : page.pFocusMin) * 60

    visible: win !== null && win.mode === "panel" && win.page === "timers"
    Layout.fillWidth: true
    spacing: Theme.pageSpacing

    Timer {
        interval: 1000
        repeat: true
        running: page.pRunning
        onTriggered: page.pTick()
    }

    // mm:ss
    function fmtTimer(sec) {
        const t = Math.max(0, Math.round(sec));
        const m = Math.floor(t / 60);
        const s = t % 60;
        return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s;
    }

    // mm:ss.d
    function fmtSw(v) {
        const tenths = Math.floor(Math.max(0, v) * 10 + 1e-6);
        const m = Math.floor(tenths / 600);
        const s = Math.floor(tenths / 10) % 60;
        const d = tenths % 10;
        return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s + "." + d;
    }

    // ── Помодоро: движок ───────────────────────────────────────────────
    function pResetPhase() { // держать отсчёт тонким: актуировать pLeft
        page.pLeft = Math.round(page.pTotal);
    }
    function pSetPreset(f, b) {
        pFocusMin = f; pBreakMin = b;
        pPhase = "focus"; pRunning = false;
        pLeft = f * 60;
        // поля «своего» пресета держим в курсе выбранного
        pfFocus.text = String(f);
        pfBreak.text = String(b);
    }
    // завершение фазы: счёт раунда, тост, переход (авто — сам)
    function pAdvance() {
        if (page.pPhase === "focus") {
            const arr = page.pRounds + 1;
            page.pRounds = arr;
            page.pPhase = "break";
            page.pLeft = page.pBreakMin * 60;
            Notif.push({ "appName": "Помодоро", "summary": "Фокус завершён",
                         "body": "Перерыв " + page.pBreakMin + " мин" });
        } else {
            page.pPhase = "focus";
            page.pLeft = page.pFocusMin * 60;
            Notif.push({ "appName": "Помодоро", "summary": "Перерыв окончен",
                         "body": "Раунд " + (page.pRounds % 4 + 1) + " — фокус " + page.pFocusMin + " мин" });
        }
        page.pRunning = page.pAuto;
    }
    function pTick() {
        page.pLeft = Math.max(0, page.pLeft - 1);
        if (page.pLeft === 0)
            page.pAdvance();
    }
    function pToggle() {
        if (page.pRunning) {
            page.pRunning = false;
        } else {
            if (page.pLeft <= 0)
                page.pLeft = Math.round(page.pTotal);
            page.pRunning = true;
        }
    }
    function pReset() {
        page.pRunning = false;
        page.pPhase = "focus";
        page.pLeft = page.pFocusMin * 60;
        page.pRounds = 0;
    }
    function pSkip() {
        page.pRunning = false;
        page.pAdvance();
    }

    // ── Мировые часы: города и зоны ───────────────────────────────────
    readonly property var _zones: [
        { "city": "Киев", "zone": "Europe/Kyiv" },
        { "city": "Варшава", "zone": "Europe/Warsaw" },
        { "city": "Лондон", "zone": "Europe/London" },
        { "city": "Нью-Йорк", "zone": "America/New_York" },
        { "city": "Токио", "zone": "Asia/Tokyo" },
        { "city": "Сидней", "zone": "Australia/Sydney" }
    ]
    // [{ city, time "ЧЧ:ММ", offset "+3 ч" }]
    property var cities: []

    Process {
        id: worldProc

        command: ["sh", "-c", _clockScript()]

        stdout: SplitParser {
            onRead: line => {
                if (line.indexOf("|") < 0) { // последняя строка — локальная зона
                    page._localOff = line.trim();
                    return ;
                }
                const i = line.indexOf("|");
                const zone = line.slice(0, i);
                const rest = line.slice(i + 1);
                const j = rest.indexOf("|");
                const hm = j >= 0 ? rest.slice(0, j) : rest;
                const zz = j >= 0 ? rest.slice(j + 1) : "";
                page._extra[zone] = { "hm": hm, "z": zz };
            }
        }

        onExited: {
            // сборка строк из уже собранных времен, чтобы ListView не дрожал
            const list = [];
            const local = page._parseTz(page._localOff);
            for (const c of page._zones) {
                const e = page._extra[c.zone] || { "hm": "--:--", "z": "" };
                const min = page._parseTz(e.z) - local;
                const sign = min < 0 ? "−" : "+";
                const abs = Math.abs(min);
                const hh = Math.floor(abs / 60);
                const mm = abs % 60;
                const off = min === 0 ? "местное"
                    : sign + hh + (mm !== 0 ? ":" + (mm < 10 ? "0" : "") + mm : "") + " ч";
                list.push({ "city": c.city, "zone": c.zone, "time": e.hm, "offset": off });
            }
            page.cities = list;
        }
    }

    // разовый сбор: зона|ЧЧ:ММ|±ЧЧММ для каждого города, затем локальная зона
    property var _extra: ({})
    property string _localOff: "0"

    function _clockScript() {
        let s = "for z in";
        for (const c of page._zones) s += " " + c.zone;
        s += "; do printf '%s|%s|%s\\n' \"$z\" \"$(TZ=$z date +%H:%M)\" \"$(TZ=$z date +%z)\"; done; date +%z";
        return s;
    }

    // ±ЧЧММ → минуты
    function _parseTz(s) {
        const m = /^([+-])(\d{2})(\d{2})$/.exec(String(s || ""));
        if (!m) return 0;
        return (m[1] === "-" ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3]));
    }

    function worldRefresh() {
        worldProc.running = false;
        worldProc.running = true;
    }

    Timer { // обновление мировых часов каждые 30с
        interval: 30000
        repeat: true
        running: true
        onTriggered: page.worldRefresh()
    }

    Component.onCompleted: page.worldRefresh()

    RowLayout { // режим
        Layout.fillWidth: true
        spacing: Theme.dp(8)

        Chip {
            label: "Таймер"
            selected: page.mode === "timer"
            onClicked: page.mode = "timer"
        }
        Chip {
            label: "Помодоро"
            selected: page.mode === "pomodoro"
            onClicked: page.mode = "pomodoro"
        }
        Chip {
            label: "Секундомер"
            selected: page.mode === "stopwatch"
            onClicked: page.mode = "stopwatch"
        }
        Item { Layout.fillWidth: true }
    }

    Card { // ── обратный отсчёт
        Layout.fillWidth: true
        visible: page.mode === "timer"
        title: "Таймер"

        Item { // кольцо с крупным счётчиком по центру
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.dp(196)

            CircularProgress {
                id: ring

                anchors.centerIn: parent
                width: Theme.dp(180)
                height: width
                thickness: Theme.dp(8)
                value: Chrono.totalSeconds > 0
                       ? Math.max(0, Math.min(1, Chrono.remaining / Chrono.totalSeconds))
                       : 0
                color: Chrono.timerDone ? Theme.error : Theme.accent
                trackColor: Theme.bgTrack
            }

            ColumnLayout {
                anchors.centerIn: parent
                spacing: Theme.dp(2)

                LText {
                    Layout.alignment: Qt.AlignHCenter
                    role: "displayMedium"
                    tabular: true
                    color: Chrono.timerDone ? Theme.error : Theme.text
                    text: page.fmtTimer(Chrono.remaining)
                }

                LText {
                    Layout.alignment: Qt.AlignHCenter
                    role: "labelMedium"
                    color: Theme.subtext
                    text: Chrono.timerDone ? "Время вышло"
                        : Chrono.running ? "Идёт"
                        : Chrono.remaining > 0 ? "Пауза"
                        : "Готов"
                }
            }
        }

        RowLayout { // пресеты
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Theme.dp(6)
            spacing: Theme.dp(8)

            Repeater {
                model: [1, 5, 10, 25]

                Chip {
                    required property int modelData
                    label: modelData + " мин"
                    selected: Chrono.totalSeconds === modelData * 60
                    onClicked: Chrono.start(modelData * 60)
                }
            }
        }

        RowLayout { // управление
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Theme.dp(6)
            spacing: Theme.dp(8)

            Button {
                icon: Chrono.running ? "pause" : "play_arrow"
                text: Chrono.running ? "Пауза" : (Chrono.remaining > 0 ? "Продолжить" : "Старт")
                variant: "filled"
                onClicked: {
                    if (Chrono.running)
                        Chrono.pause();
                    else if (Chrono.remaining > 0)
                        Chrono.resume();
                    else
                        Chrono.start(Chrono.totalSeconds > 0 ? Chrono.totalSeconds : 5 * 60);
                }
            }

            Button {
                icon: "add"
                text: "+1 мин"
                variant: "tonal"
                onClicked: Chrono.addMin(1)
            }

            Button {
                icon: "restart_alt"
                text: "Сброс"
                variant: "tonal"
                disabled: Chrono.totalSeconds === 0 && Chrono.remaining === 0
                onClicked: Chrono.reset()
            }
        }
    }

    Card { // ── помодоро (состояние локальное, вне Chrono) ──
        Layout.fillWidth: true
        visible: page.mode === "pomodoro"
        title: "Помодоро"

        Item { // кольцо с фазой по центру
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.dp(196)

            CircularProgress {
                anchors.centerIn: parent
                width: Theme.dp(180)
                height: width
                thickness: Theme.dp(8)
                value: page.pTotal > 0 ? Math.max(0, Math.min(1, page.pLeft / page.pTotal)) : 0
                color: page.pPhase === "break" ? Theme.success : Theme.accent
                trackColor: Theme.bgTrack
            }

            ColumnLayout {
                anchors.centerIn: parent
                spacing: Theme.dp(2)

                LText {
                    Layout.alignment: Qt.AlignHCenter
                    role: "displayMedium"
                    tabular: true
                    text: page.fmtTimer(page.pLeft)
                }

                LText { // фаза и раунд
                    Layout.alignment: Qt.AlignHCenter
                    role: "labelMedium"
                    color: page.pPhase === "break" ? Theme.success : Theme.subtext
                    text: (page.pPhase === "break" ? "Перерыв" : "Фокус")
                          + (page.pPhase === "focus"
                             ? " " + (page.pRounds % 4 + 1) + "/4"
                             : "")
                }
            }
        }

        RowLayout { // счётчик раундов точками
            Layout.alignment: Qt.AlignHCenter
            spacing: Theme.dp(6)

            Repeater {
                model: 4

                Rectangle {
                    id: dot

                    required property int index

                    Layout.alignment: Qt.AlignVCenter
                    width: Theme.dp(7)
                    height: Theme.dp(7)
                    radius: Theme.pill(width)
                    color: dot.index < page.pRounds % 4 ? Theme.accent : "transparent"
                    border.width: 1
                    border.color: Theme.accent
                    opacity: dot.index < page.pRounds % 4 ? 1 : 0.4
                }
            }

            LText {
                Layout.leftMargin: Theme.dp(6)
                role: "labelMedium"
                color: Theme.subtextDim
                // наборы по 4: заполненные точки — фокусы текущего набора
                text: "Набор " + (Math.floor(page.pRounds / 4) + 1)
            }
        }

        RowLayout { // пресеты
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Theme.dp(4)
            spacing: Theme.dp(8)

            Chip {
                label: "25/5"
                selected: !page.pCustom && page.pFocusMin === 25 && page.pBreakMin === 5
                onClicked: {
                    page.pCustom = false;
                    page.pSetPreset(25, 5);
                }
            }
            Chip {
                label: "50/10"
                selected: !page.pCustom && page.pFocusMin === 50 && page.pBreakMin === 10
                onClicked: {
                    page.pCustom = false;
                    page.pSetPreset(50, 10);
                }
            }
            Chip {
                label: "Своё"
                selected: page.pCustom
                onClicked: page.pCustom = true
            }
        }

        RowLayout { // свой пресет: минуты фокуса и перерыва
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Theme.dp(4)
            visible: page.pCustom
            spacing: Theme.dp(6)

            LText {
                role: "labelMedium"
                color: Theme.subtext
                text: "Фокус"
            }
            TextField {
                id: pfFocus

                text: String(page.pFocusMin)
                variant: "outlined"
                Layout.preferredWidth: Theme.dp(58)
            }
            LText {
                role: "labelMedium"
                color: Theme.subtext
                text: "·"
            }
            LText {
                role: "labelMedium"
                color: Theme.subtext
                text: "Перерыв"
            }
            TextField {
                id: pfBreak

                text: String(page.pBreakMin)
                variant: "outlined"
                Layout.preferredWidth: Theme.dp(58)
            }
            Button {
                text: "Применить"
                variant: "tonal"
                onClicked: {
                    const f = Math.max(1, Math.min(120, Number(pfFocus.text) || 0));
                    const b = Math.max(1, Math.min(60, Number(pfBreak.text) || 0));
                    page.pSetPreset(f, b);
                }
            }
        }

        RowLayout { // управление
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Theme.dp(6)
            spacing: Theme.dp(8)

            Button {
                icon: page.pRunning ? "pause" : "play_arrow"
                text: page.pRunning ? "Пауза" : "Старт"
                variant: "filled"
                onClicked: page.pToggle()
            }

            Button {
                icon: "skip_next"
                text: "Пропустить"
                variant: "tonal"
                onClicked: page.pSkip()
            }

            Button {
                icon: "restart_alt"
                text: "Сброс"
                variant: "tonal"
                onClicked: page.pReset()
            }
        }

        RowLayout { // автостарт следующей фазы
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Theme.dp(4)
            spacing: Theme.dp(8)

            Switch {
                id: psw

                checked: page.pAuto
                onToggled: (v) => page.pAuto = v
            }

            LText {
                role: "bodySmall"
                color: Theme.subtext
                text: "Автостарт: перерыв и новый фокус — сами"
            }
        }
    }

    Card { // ── секундомер
        Layout.fillWidth: true
        visible: page.mode === "stopwatch"
        title: "Секундомер"

        LText {
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(8)
            horizontalAlignment: Text.AlignHCenter
            role: "displayMedium"
            tabular: true
            text: page.fmtSw(Chrono.swElapsed)
        }

        RowLayout { // управление
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Theme.dp(8)
            spacing: Theme.dp(8)

            Button {
                icon: Chrono.swRunning ? "pause" : "play_arrow"
                text: Chrono.swRunning ? "Пауза" : "Старт"
                variant: "filled"
                onClicked: Chrono.swToggle()
            }

            Button {
                icon: "flag"
                text: "Круг"
                variant: "tonal"
                disabled: Chrono.swElapsed <= 0
                onClicked: Chrono.addLap()
            }

            Button {
                icon: "restart_alt"
                text: "Сброс"
                variant: "tonal"
                disabled: Chrono.swElapsed <= 0
                onClicked: Chrono.swReset()
            }
        }
    }

    Card { // ── круги
        Layout.fillWidth: true
        visible: page.mode === "stopwatch"
        title: "Круги"
        actionIcon: Chrono.laps.length > 0 ? "delete" : ""
        onActionClicked: Chrono.laps = []

        ListView {
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(4)
            Layout.preferredHeight: Chrono.laps.length === 0
                                 ? Theme.dp(36)
                                 : Math.min(Chrono.laps.length, 5) * Theme.dp(48)
            clip: true
            spacing: Theme.dp(4)
            // новые круги — сверху
            model: Chrono.laps.slice().reverse()

            delegate: RowLayout { // компактная строка круга
                required property var modelData
                required property int index

                width: ListView.view.width
                height: Theme.dp(44)
                spacing: Theme.dp(12)

                LText {
                    Layout.alignment: Qt.AlignVCenter
                    role: "labelMedium"
                    tabular: true
                    color: Theme.subtext
                    text: "Круг " + (Chrono.laps.length - index)
                }

                Item { Layout.fillWidth: true }

                LText {
                    Layout.alignment: Qt.AlignVCenter
                    role: "titleSmall"
                    tabular: true
                    color: Theme.text
                    text: page.fmtSw(modelData)
                }
            }
        }

        LText {
            Layout.fillWidth: true
            Layout.bottomMargin: Theme.dp(4)
            visible: Chrono.laps.length === 0
            role: "bodySmall"
            color: Theme.subtextDim
            text: "Пока пусто — отметьте первый круг"
        }
    }

    Card { // ── мировое время — на всех вкладках страницы
        Layout.fillWidth: true
        title: "Мировое время"

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(2)

            Repeater {
                model: page.cities

                delegate: RowLayout {
                    id: wrow

                    required property var modelData

                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.dp(34)
                    spacing: Theme.dp(10)

                    LText {
                        role: "bodyMedium"
                        color: Theme.text
                        text: wrow.modelData.city
                    }

                    LText {
                        role: "labelSmall"
                        color: Theme.subtextDim
                        text: wrow.modelData.offset
                    }

                    Item { Layout.fillWidth: true }

                    LText {
                        role: "titleMedium"
                        tabular: true
                        color: Theme.text
                        text: wrow.modelData.time
                    }
                }
            }

            LText {
                visible: page.cities.length === 0
                role: "bodySmall"
                color: Theme.subtextDim
                text: "Загружаем города…"
            }
        }
    }
}
