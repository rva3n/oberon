import QtQuick
import QtQuick.Layouts
import "../../core"
import "../../ui"

// Страница «Погода»: Lucid-язык — герой-карточка, чипы-выделения, мини-карточки
// по часам и строки прогноза. Данные — из core/Weather.qml (Open-Meteo).
ColumnLayout {
    id: page

    property var win: null

    Layout.fillWidth: true
    spacing: Theme.pageSpacing
    visible: win !== null && win.mode === "panel" && win.page === "weather"

    // влажность/ветер могут отсутствовать (тогда приходит NaN) — чип пропускаем
    readonly property bool hasHumidity: !isNaN(Weather.humidity)
    readonly property bool hasWind: !isNaN(Weather.wind)

    // ── загрузка и ошибка ─────────────────────────────────────────────
    LText {
        visible: Weather.loading && !Weather.hasData
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
        role: "bodySmall"
        color: Theme.subtext
        text: "загрузка…"
    }

    Rectangle {
        visible: Weather.error !== ""
        Layout.fillWidth: true
        implicitHeight: errRow.implicitHeight + Theme.dp(20)
        radius: Theme.radiusXl
        color: Theme.errorContainer

        RowLayout {
            id: errRow

            anchors.fill: parent
            anchors.margins: Theme.dp(10)
            spacing: Theme.dp(10)

            Icon {
                Layout.alignment: Qt.AlignVCenter
                name: "error"
                size: Theme.dp(20)
                color: Theme.fgErrorContainer
            }

            LText {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                role: "bodySmall"
                color: Theme.fgErrorContainer
                elide: Text.ElideRight
                text: Weather.error
            }

            Button {
                Layout.alignment: Qt.AlignVCenter
                text: "Повторить"
                variant: "tonal"
                onClicked: Weather.refresh()
            }
        }
    }

    // ── Сейчас ────────────────────────────────────────────────────────
    Card {
        visible: Weather.hasData
        Layout.fillWidth: true
        title: "Сейчас"
        actionIcon: "refresh"
        onActionClicked: Weather.refresh()

        ColumnLayout { // герой и ряд чипов: ровный ритм 12 между блоками
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            RowLayout { // герой: фигура иконки + температура/описание/место
                Layout.fillWidth: true
                spacing: Theme.dp(14)

                Item {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: Theme.dp(72)
                    implicitHeight: Theme.dp(72)

                    MaterialShape {
                        anchors.fill: parent
                        shape: "cookie9"
                        color: Theme.accentContainer
                    }

                    Icon {
                        anchors.centerIn: parent
                        name: Weather.icon
                        size: Theme.dp(34)
                        color: Theme.fgAccentContainer
                    }
                }

                ColumnLayout { // температура, описание, место
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: Theme.dp(2)

                    LText {
                        role: "displayMedium"
                        tabular: true
                        text: Math.round(Weather.temp) + "°"
                    }

                    LText {
                        Layout.fillWidth: true
                        role: "bodyLarge"
                        color: Theme.subtext
                        elide: Text.ElideRight
                        text: Weather.desc
                    }

                    LText {
                        Layout.fillWidth: true
                        role: "labelMedium"
                        color: Theme.subtextDim
                        elide: Text.ElideRight
                        text: Weather.place
                    }
                }
            }

            RowLayout { // чипы-выделения: по содержимому, слева, без растяжки
                Layout.fillWidth: true
                spacing: Theme.dp(6)

                Chip {
                    size: "sm"
                    kind: "suggestion"
                    interactive: false
                    horizontalPadding: 10
                    contentSpacing: 4
                    iconSize: 13
                    backgroundColor: Theme.bgTrack
                    borderWidth: 0
                    customColors: true
                    foregroundColor: Theme.subtext
                    iconColor: Theme.subtext
                    icon: "device_thermostat"
                    label: "Ощущается " + Math.round(Weather.feels) + "°"
                }

                Chip {
                    size: "sm"
                    kind: "suggestion"
                    interactive: false
                    horizontalPadding: 10
                    contentSpacing: 4
                    iconSize: 13
                    backgroundColor: Theme.bgTrack
                    borderWidth: 0
                    customColors: true
                    foregroundColor: Theme.subtext
                    iconColor: Theme.subtext
                    visible: page.hasHumidity
                    icon: "water_drop"
                    label: Math.round(Weather.humidity) + "%"
                }

                Chip {
                    size: "sm"
                    kind: "suggestion"
                    interactive: false
                    horizontalPadding: 10
                    contentSpacing: 4
                    iconSize: 13
                    backgroundColor: Theme.bgTrack
                    borderWidth: 0
                    customColors: true
                    foregroundColor: Theme.subtext
                    iconColor: Theme.subtext
                    visible: page.hasWind
                    icon: "air"
                    label: Math.round(Weather.wind) + " м/с"
                }

                Item { Layout.fillWidth: true } // остаток ширины — справа от чипов
            }
        }
    }

    // ── По часам ──────────────────────────────────────────────────────
    Card {
        visible: Weather.hasData && Weather.hourly.length > 0
        Layout.fillWidth: true
        title: "По часам"

        RowLayout { // до 6 мини-карточек 52×76: 6×52 + 5×6 = 342 < 344 — без обрезки
            Layout.fillWidth: true
            spacing: Theme.dp(6)

            Repeater {
                model: Weather.hourly.slice(0, 6)

                delegate: Rectangle { // час — мини-карточка Lucid
                    id: hourCell

                    required property var modelData
                    // день/ночь по метке часа — для иконок прогноза
                    readonly property bool dayHour: {
                        const h = parseInt(modelData.label, 10);
                        return isNaN(h) ? Weather.isDay : (h >= 7 && h < 21);
                    }

                    Layout.preferredWidth: Theme.dp(52)
                    Layout.preferredHeight: Theme.dp(76)
                    radius: Theme.shapeLg
                    color: Theme.mHighest

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: Theme.dp(6)
                        spacing: Theme.dp(4)

                        LText {
                            Layout.alignment: Qt.AlignHCenter
                            role: "labelSmall"
                            color: Theme.subtext
                            text: hourCell.modelData.label
                        }

                        Icon {
                            Layout.alignment: Qt.AlignHCenter
                            name: Weather.wmoIcon(hourCell.modelData.code, hourCell.dayHour)
                            size: Theme.dp(16)
                            color: Theme.subtext
                        }

                        LText {
                            Layout.alignment: Qt.AlignHCenter
                            role: "bodyMedium"
                            tabular: true
                            text: hourCell.modelData.temp + "°"
                        }
                    }
                }
            }

            Item { Layout.fillWidth: true } // ряд прижат влево, ячейки не растягиваются
        }
    }

    // ── На 5 дней ─────────────────────────────────────────────────────
    Card {
        visible: Weather.hasData && Weather.daily.length > 0
        Layout.fillWidth: true
        title: "На 5 дней"

        ColumnLayout { // строки прогноза в анатомии ListItem (без собственного фона)
            Layout.fillWidth: true
            spacing: 0

            Repeater {
                model: Weather.daily.slice(0, 5)

                delegate: ListItem {
                    required property var modelData
                    required property int index

                    readonly property int count: Math.min(Weather.daily.length, 5)

                    Layout.fillWidth: true
                    implicitHeight: Theme.dp(44)
                    position: index === 0 ? (count === 1 ? "single" : "top")
                        : (index === count - 1 ? "bottom" : "middle")
                    clickable: false
                    containerColor: "transparent"
                    textStartMargin: 0
                    textTrailingSpacing: Theme.dp(12)
                    trailingMargin: 0
                    trailingSpacing: Theme.dp(12)
                    headline: modelData.day

                    trailing: Row {
                        spacing: Theme.dp(12)

                        Icon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: Weather.wmoIcon(modelData.code, true)
                            size: Theme.dp(18)
                            color: Theme.subtext
                        }

                        LText { // минимум — колонка вправо
                            width: Theme.dp(38)
                            anchors.verticalCenter: parent.verticalCenter
                            horizontalAlignment: Text.AlignRight
                            role: "bodyMedium"
                            tabular: true
                            color: Theme.subtext
                            text: Math.round(modelData.min) + "°"
                        }

                        LText { // максимум — фикс. ширина, вправо
                            width: Theme.dp(42)
                            anchors.verticalCenter: parent.verticalCenter
                            horizontalAlignment: Text.AlignRight
                            role: "bodyMedium"
                            tabular: true
                            color: Theme.text
                            text: Math.round(modelData.max) + "°"
                        }
                    }
                }
            }
        }
    }
}
