import QtQuick

FocusScope {
    id: root

    property alias text: input.text
    property string placeholderText: "Пароль"
    property bool reveal: false
    property bool hasError: false
    signal accepted()

    implicitWidth: 340
    implicitHeight: 56
    width: implicitWidth
    height: implicitHeight

    function focusInput() {
        input.forceActiveFocus();
        input.cursorPosition = input.text.length;
    }

    function clear() {
        input.clear();
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.surfaceLow
        radius: Theme.radiusMd
        border.width: root.activeFocus || input.activeFocus ? 2 : 1
        border.color: root.hasError ? Theme.error
            : (root.activeFocus || input.activeFocus ? Theme.accent : Theme.outlineVariant)
        Behavior on border.color { ColorAnimation { duration: Theme.durShort } }
    }

    MouseArea {
        anchors.fill: parent
        z: 1
        onClicked: root.focusInput()
    }

    Text {
        anchors.left: parent.left
        anchors.leftMargin: 16
        anchors.right: toggle.left
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        text: root.placeholderText
        color: Theme.subtextDim
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontBodyLarge
        visible: input.text.length === 0 && !input.activeFocus
        elide: Text.ElideRight
        z: 2
    }

    TextInput {
        id: input
        anchors.left: parent.left
        anchors.leftMargin: 16
        anchors.right: toggle.left
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height - 8
        color: Theme.text
        selectionColor: Theme.accentContainer
        selectedTextColor: Theme.fgAccentContainer
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontBodyLarge
        echoMode: root.reveal ? TextInput.Normal : TextInput.Password
        passwordCharacter: "●"
        selectByMouse: true
        enabled: root.enabled
        inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
        z: 3
        onAccepted: root.accepted()
    }

    Item {
        id: toggle
        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        width: 40
        height: 40
        z: 4

        Icon {
            anchors.centerIn: parent
            name: root.reveal ? "visibility_off" : "visibility"
            size: 20
            color: Theme.subtext
        }

        MouseArea {
            anchors.fill: parent
            enabled: root.enabled
            hoverEnabled: true
            onClicked: {
                root.reveal = !root.reveal;
                root.focusInput();
            }
        }
    }
}
