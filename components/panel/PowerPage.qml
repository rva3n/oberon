import QtQuick
import QtQuick.Layouts
import "../../core"
import ".."
import "../../ui"

// Питание: одна Card, строки PowerRow с разделителями.
ColumnLayout {
    id: powerPage

    property var win: null
    property string armedAction: ""

    visible: win !== null && win.mode === "panel" && win.page === "power"
    Layout.fillWidth: true
    spacing: Theme.pageSpacing

    onVisibleChanged: if (!powerPage.visible) powerPage.clearConfirmation()

    function clearConfirmation() {
        powerPage.armedAction = "";
        confirmTimer.stop();
    }

    function activate(action) {
        if (action === "reboot" || action === "poweroff") {
            if (powerPage.armedAction !== action) {
                powerPage.armedAction = action;
                confirmTimer.restart();
                return;
            }
            powerPage.clearConfirmation();
            if (action === "reboot") Sys.reboot();
            else Sys.poweroff();
            return;
        }

        powerPage.clearConfirmation();
        if (action === "lock") {
            if (win.shell) win.shell.lock();
        } else if (action === "logout") {
            Sys.logout();
        } else if (action === "suspend") {
            Sys.suspend();
        }
    }

    Timer {
        id: confirmTimer
        interval: 4000
        onTriggered: powerPage.armedAction = ""
    }

    Card {
        Layout.fillWidth: true
        title: "Питание"

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(4)

            PowerRow { Layout.fillWidth: true; icon: "lock"; label: "Заблокировать"; onClicked: powerPage.activate("lock") }

            PowerRow { Layout.fillWidth: true; icon: "logout"; label: "Выйти"; onClicked: powerPage.activate("logout") }

            PowerRow { Layout.fillWidth: true; icon: "bedtime"; label: "Спящий режим"; onClicked: powerPage.activate("suspend") }

            PowerRow {
                Layout.fillWidth: true
                icon: "restart_alt"
                label: powerPage.armedAction === "reboot" ? "Ещё раз: перезагрузка" : "Перезагрузка"
                onClicked: powerPage.activate("reboot")

                HoverHandler {
                    onHoveredChanged: {
                        if (!hovered && powerPage.armedAction === "reboot")
                            powerPage.clearConfirmation();
                    }
                }
            }

            PowerRow {
                Layout.fillWidth: true
                icon: "power_settings_new"
                label: powerPage.armedAction === "poweroff" ? "Ещё раз: выключение" : "Выключение"
                danger: true
                onClicked: powerPage.activate("poweroff")

                HoverHandler {
                    onHoveredChanged: {
                        if (!hovered && powerPage.armedAction === "poweroff")
                            powerPage.clearConfirmation();
                    }
                }
            }
        }
    }
}
