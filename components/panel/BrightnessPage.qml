import QtQuick
import QtQuick.Layouts
import "../../core"
import "../../ui"
import ".."

// Яркость: крупное значение на роли display со табличными цифрами и слайдер
// в карточке, отступы Lucid.
ColumnLayout {
    id: brightnessPage
    property var win: null
    visible: win !== null && win.mode === "panel" && win.page === "brightness"
    Layout.fillWidth: true
    spacing: Theme.pageSpacing

    Card {
        Layout.fillWidth: true

        LText {
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(10)
            Layout.bottomMargin: Theme.dp(2)
            horizontalAlignment: Text.AlignHCenter
            role: "displayLarge"
            tabular: true
            color: Theme.text
            text: Math.round(Sys.brightnessFraction * 100) + "%"
        }

        SliderRow {
            Layout.fillWidth: true
            icon: "brightness_6"
            value: Sys.brightnessFraction
            onMoved: (v) => { Sys.brightness = Math.round(v * Sys.brightnessMax); }
            onCommitted: (v) => { Sys.setBrightnessPct(v * 100); }
        }
    }
}
