import QtQuick
import QtQuick.Layouts
import "../../core"
import "../../ui"

ColumnLayout {
    id: root

    property string label: ""
    property string sub: ""
    property var values: []
    property var labels: []
    property var value: 0

    readonly property var options: {
        const result = [];
        for (let i = 0; i < root.values.length; i++)
            result.push({ key: root.values[i], label: root.labels[i] !== undefined ? root.labels[i] : String(root.values[i]) });
        return result;
    }
    readonly property bool useSegments: root.values.length >= 2 && root.values.length <= 4

    signal committed(var value)

    Layout.fillWidth: true
    Layout.topMargin: Theme.dp(4)
    Layout.bottomMargin: Theme.dp(4)
    spacing: Theme.dp(8)

    LText {
        Layout.fillWidth: true
        visible: root.label !== ""
        text: root.label
        role: "bodyLarge"
        weight: 480
        color: Theme.text
        elide: Text.ElideRight
    }

    ButtonGroup {
        visible: root.useSegments
        Layout.fillWidth: true
        options: root.options
        current: root.value
        equalWidth: true
        size: "s"
        onPicked: (key) => root.committed(key)
    }

    Flow {
        id: chipFlow

        visible: !root.useSegments
        Layout.fillWidth: true
        Layout.preferredHeight: Math.max(Theme.dp(30), chipFlow.implicitHeight)
        spacing: Theme.dp(6)

        Repeater {
            model: root.options

            Chip {
                required property var modelData
                text: modelData.label
                selected: root.value === modelData.key
                onClicked: root.committed(modelData.key)
            }
        }
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
