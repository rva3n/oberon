import QtQuick
import QtQuick.Layouts
import "../../core"
import "../../ui"

// Страница «Календарь»: шапка месяца своя, сетка — ui/MonthView Lucid
// (пентагон «сегодня», выбранный день в тональном круге, точки напоминаний).
// Под сеткой — карточка выбранного дня: список напоминаний с тихим удалением
// и строка добавления (время «ЧЧ:ММ» + текст + «Добавить»).
ColumnLayout {
    id: cal

    property var win: null
    // { year, month, day } или null — выбранный день
    property var selected: null
    readonly property date selectedDate: cal.selected
        ? new Date(cal.selected.year, cal.selected.month, cal.selected.day) : new Date()
    // напоминания выбранного дня, по возрастанию времени
    readonly property var dayReminders: cal.selected
        ? Reminders.day(cal.selected.year, cal.selected.month, cal.selected.day) : []

    property string addError: ""

    visible: win !== null && win.mode === "panel" && win.page === "calendar"
    Layout.fillWidth: true
    spacing: Theme.pageSpacing

    // первый заход: выбранным делаем сегодня
    onVisibleChanged: if (visible && cal.selected === null) cal.goToday()

    readonly property string monthTitle: {
        // Именительный падеж: «Октябрь 2026». toLocaleDateString("MMMM yyyy")
        // в ru-локали даёт родительный («октября 2026»).
        const loc = Qt.locale("ru_RU");
        const s = loc.standaloneMonthName(mv.monthIndex, Locale.LongFormat) + " " + mv.year;
        return s.length > 0 ? s.charAt(0).toUpperCase() + s.slice(1) : s;
    }

    // «Пн, 12 октября» для заголовка карточки дня
    readonly property string dayTitle: cal.selectedDate.toLocaleDateString(Qt.locale("ru_RU"), "dddd, d MMMM")

    // «ЧЧ:ММ»; строгий парсер — часы 1-2 цифры, минуты ровно две
    readonly property var _timeRe: /^(2[0-3]|[0-1]?\d):[0-5]\d$/

    function validTime(s) { return cal._timeRe.test(String(s || "").trim()) }

    function goToday() {
        const n = new Date();
        mv.goToday();
        cal.selected = { "year": n.getFullYear(), "month": n.getMonth(), "day": n.getDate() };
    }

    function addReminder() {
        if (!cal.selected) return ;
        const text = textTf.text.trim();
        if (text === "") {
            textTf.forceActiveFocus();
            return ;
        }
        if (!cal.validTime(timeTf.text)) {
            cal.addError = "Формат ЧЧ:ММ";
            timeTf.forceActiveFocus();
            return ;
        }
        const parts = String(timeTf.text).trim().split(":");
        const hh = Number(parts[0]);
        const mm = Number(parts[1]);
        const ts = new Date(cal.selected.year, cal.selected.month, cal.selected.day, hh, mm).getTime();
        Reminders.add(text, ts);
        textTf.text = "";
        textTf.forceActiveFocus();
        cal.addError = "";
    }

    Card {
        Layout.fillWidth: true

        RowLayout { // шапка месяца — своя, сетке она чужая (showHeader: false)
            Layout.fillWidth: true
            spacing: Theme.dp(4)

            IconButton {
                icon: "chevron_left"
                onClicked: mv.page(-1)
            }

            LText {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.dp(4)
                role: "titleMedium"
                color: Theme.text
                elide: Text.ElideRight
                text: cal.monthTitle
            }

            Chip {
                label: "Сегодня"
                onClicked: cal.goToday()
            }

            IconButton {
                icon: "chevron_right"
                onClicked: mv.page(1)
            }
        }

        MonthView {
            id: mv

            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Theme.dp(8)
            showHeader: false
            showNav: false
            weekdayLabels: ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
            // точки-напоминания (месяц 0-based, как ожидает MonthView)
            marked: Reminders.marks
            selected: cal.selected
            onPicked: (y, m, d) => {
                cal.selected = { "year": y, "month": m, "day": d };
                if (m !== mv.monthIndex) // день соседнего месяца — перелистнуть
                    mv.page(y * 12 + m > mv.year * 12 + mv.monthIndex ? 1 : -1);
            }
        }
    }

    Card {
        Layout.fillWidth: true
        title: cal.dayTitle

        LText { // пустой день
            visible: cal.dayReminders.length === 0
            role: "bodySmall"
            color: Theme.subtextDim
            text: "Пока пусто — добавьте напоминание"
        }

        ColumnLayout { // строки: время + текст + тихое удаление
            visible: cal.dayReminders.length > 0
            Layout.fillWidth: true
            spacing: 0

            Repeater {
                model: cal.dayReminders

                delegate: RowLayout {
                    id: row

                    required property var modelData
                    required property int index

                    Layout.fillWidth: true
                    Layout.topMargin: row.index > 0 ? Theme.dp(3) : 0
                    spacing: Theme.dp(10)

                    Rectangle { // статус-точка: залита — ждёт, контур — прозвенело
                        Layout.alignment: Qt.AlignVCenter
                        Layout.preferredWidth: Theme.dp(8)
                        Layout.preferredHeight: Theme.dp(8)
                        radius: Theme.pill(width)
                        color: row.modelData.fired ? "transparent" : Theme.accent
                        border.width: 1
                        border.color: Theme.accent
                        opacity: row.modelData.fired ? 0.45 : 1
                    }

                    LText {
                        role: "labelMedium"
                        tabular: true
                        color: row.modelData.fired ? Theme.subtextDim : Theme.accent
                        text: Qt.formatDateTime(new Date(row.modelData.ts), "HH:mm")
                    }

                    LText {
                        Layout.fillWidth: true
                        role: "bodyMedium"
                        color: row.modelData.fired ? Theme.subtextDim : Theme.text
                        elide: Text.ElideRight
                        text: row.modelData.text
                    }

                    IconButton { // ghost-удаление: появляется на ховере строки
                        visible: rowHover.hovered
                        icon: "close"
                        size: "xs"
                        tooltip: "Удалить"
                        tintOverride: Theme.subtextDim
                        opacity: rowHover.hovered ? 1 : 0.9
                        onClicked: Reminders.remove(row.modelData.id)
                    }

                    // ховер строки без перехвата кликов: HoverHandler не Item,
                    // слот лейаута не занимает и кликам не мешает
                    HoverHandler {
                        id: rowHover
                    }
                }
            }
        }

        LText { // ошибка формата времени (высота зарезервирована)
            role: "bodySmall"
            color: Theme.error
            text: cal.addError
        }

        RowLayout { // строка добавления
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(4)
            spacing: Theme.dp(8)

            TextField {
                id: timeTf

                Layout.preferredWidth: Theme.dp(96)
                Layout.alignment: Qt.AlignVCenter
                error: timeTf.text !== "" && !cal.validTime(timeTf.text)
                placeholder: "ЧЧ:ММ"
                Component.onCompleted: {
                    const n = new Date(Date.now() + 3600000);
                    const p = x => (x < 10 ? "0" : "") + x;
                    timeTf.text = p(n.getHours()) + ":" + p(n.getMinutes());
                }
                onAccepted: textTf.forceActiveFocus()
            }

            TextField {
                id: textTf

                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                placeholder: "Напоминание"
                onAccepted: cal.addReminder()
            }

            Button {
                Layout.alignment: Qt.AlignVCenter
                icon: "add"
                text: "Добавить"
                variant: "filled"
                size: "m"
                disabled: textTf.text.trim() === ""
                onClicked: cal.addReminder()
            }
        }
    }
}
