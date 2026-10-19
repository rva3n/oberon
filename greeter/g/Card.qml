import QtQuick

Item {
    id: root

    property int padding: 28
    property int spacing: 16
    property int cornerRadius: Theme.radiusXl
    property color fill: Theme.card
    default property alias contentData: content.data

    implicitWidth: Math.max(320, content.implicitWidth + root.padding * 2)
    implicitHeight: content.implicitHeight + root.padding * 2

    Rectangle {
        anchors.fill: parent
        color: root.fill
        radius: root.cornerRadius
        border.width: 1
        border.color: Theme.outlineVariant
    }

    Column {
        id: content
        anchors.fill: parent
        anchors.margins: root.padding
        spacing: root.spacing
    }
}
