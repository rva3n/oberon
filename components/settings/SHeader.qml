import QtQuick
import QtQuick.Layouts
import "../../core"
import "../../ui"

ColumnLayout {
    id: root

    property string glyph: ""
    property string title: ""
    property string sub: ""

    Layout.fillWidth: true
    Layout.bottomMargin: Theme.dp(4)
    spacing: Theme.dp(3)

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.dp(10)

        Icon {
            visible: root.glyph !== ""
            name: root.glyph
            size: Theme.dp(24)
            color: Theme.primary
        }

        LText {
            Layout.fillWidth: true
            text: root.title
            role: "titleLarge"
            weight: 560
            color: Theme.text
            elide: Text.ElideRight
        }
    }

    LText {
        Layout.fillWidth: true
        visible: root.sub !== ""
        text: root.sub
        role: "bodySmall"
        color: Theme.subtext
        wrapMode: Text.WordWrap
    }
}
