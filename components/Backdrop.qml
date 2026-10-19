import QtQuick
import Quickshell
import Quickshell.Wayland
import "../core"

// Full-screen click-catcher: closes the island panel/launcher when clicking
// outside. Lives on the Top layer, below the Overlay island. Без затемнения:
// в Lucid панель и лончер парят над рабочим столом (scrim — только у свитчера).
PanelWindow {
    id: root
    required property var modelData
    property bool active: false
    property var shell: null

    screen: modelData
    visible: root.active && (!root.screen || Umbriel.activeOutput === ""
        || root.screen.name === Umbriel.activeOutput)
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "oberon-backdrop"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    Rectangle {
        anchors.fill: parent
        color: "transparent"
        opacity: root.active ? 1 : 0

        Behavior on opacity {
            NumberAnimation { duration: Theme.durShort }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: if (root.shell) root.shell.closeOverlays()
        }
    }
}
