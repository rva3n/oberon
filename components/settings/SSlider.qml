import QtQuick
import QtQuick.Layouts
import "../../core"
import "../../ui"

ColumnLayout {
    id: root

    property string label: ""
    property string sub: ""
    property real from: 0
    property real to: 1
    property real step: 0
    property real value: 0
    property string suffix: ""
    property var valueText: null

    signal committed(real value)

    Layout.fillWidth: true
    Layout.topMargin: Theme.dp(4)
    Layout.bottomMargin: Theme.dp(4)
    spacing: Theme.dp(6)

    function format(v) {
        if (typeof root.valueText === "function")
            return root.valueText(v);
        if (root.valueText !== null && root.valueText !== undefined)
            return String(root.valueText);
        return Math.round(v) + root.suffix;
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.dp(8)

        LText {
            Layout.fillWidth: true
            text: root.label
            role: "bodyLarge"
            weight: 480
            color: Theme.text
            elide: Text.ElideRight
        }

        LText {
            text: root.format(root.value)
            role: "labelLarge"
            tabular: true
            color: Theme.subtext
        }
    }

    Slider {
        Layout.fillWidth: true
        size: "s"
        from: root.from
        to: root.to
        stepSize: root.step
        value: root.value
        valueText: (v) => root.format(v)
        onCommitted: (v) => root.committed(v)
    }

    LText {
        Layout.fillWidth: true
        visible: root.sub !== ""
        text: root.sub
        role: "bodySmall"
        color: Theme.subtextDim
        wrapMode: Text.WordWrap
    }
}
