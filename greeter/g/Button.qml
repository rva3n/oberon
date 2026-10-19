import QtQuick

Item {
    id: root

    property string text: ""
    property string iconName: ""
    property string trailingIcon: ""
    property string kind: "tonal" // filled | tonal | chip | plain
    property bool selected: false
    property int iconSize: 18
    signal clicked()

    readonly property color fillColor: {
        if (root.kind === "filled") return Theme.accent;
        if (root.kind === "chip") return root.selected ? Theme.accentContainer : Theme.surfaceHigh;
        if (root.kind === "plain") return mouse.containsMouse ? Theme.surfaceHighest : "transparent";
        return Theme.surfaceHighest;
    }
    readonly property color labelColor: {
        if (root.kind === "filled") return Theme.fgAccent;
        if (root.kind === "chip" && root.selected) return Theme.fgAccentContainer;
        if (root.kind === "plain") return Theme.subtext;
        return Theme.text;
    }

    implicitWidth: label.implicitWidth + (root.iconName.length ? root.iconSize + 8 : 0)
        + (root.trailingIcon.length ? root.iconSize + 8 : 0) + 32
    implicitHeight: root.kind === "chip" ? 36 : 48
    width: implicitWidth
    height: implicitHeight
    opacity: enabled ? 1 : 0.38

    Behavior on opacity {
        NumberAnimation { duration: Theme.durShort; easing.type: Theme.easeStandard }
    }

    Rectangle {
        anchors.fill: parent
        color: root.fillColor
        radius: root.kind === "chip" ? Theme.radiusPill : Theme.radiusLg
        border.width: root.kind === "chip" && root.selected ? 1 : 0
        border.color: root.kind === "chip" && root.selected ? Theme.accent : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.durShort } }
    }

    Row {
        anchors.centerIn: parent
        spacing: 8

        Icon {
            visible: root.iconName.length > 0
            name: root.iconName
            size: root.iconSize
            color: root.labelColor
        }

        Text {
            id: label
            text: root.text
            color: root.labelColor
            font.family: Theme.fontFamily
            font.pixelSize: root.kind === "chip" ? Theme.fontLabelMedium : Theme.fontLabelLarge
            font.weight: Theme.weightLabel
            elide: Text.ElideRight
            maximumLineCount: 1
        }

        Icon {
            visible: root.trailingIcon.length > 0
            name: root.trailingIcon
            size: root.iconSize
            color: root.labelColor
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        enabled: root.enabled
        hoverEnabled: true
        onClicked: {
            root.forceActiveFocus();
            root.clicked();
        }
    }
}
