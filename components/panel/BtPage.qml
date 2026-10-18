import QtQuick
import QtQuick.Layouts
import "../../core"
import "../../ui"
import ".."

// Bluetooth в анатомии Lucid: карточка-переключатель радио (ToggleRow) и
// карточка найденных устройств на DeviceRow (групповые углы) с пустым
// состоянием. Логика прежняя: toggleBt/startBtScan.
ColumnLayout {
    id: btPage
    property var win: null
    visible: win !== null && win.mode === "panel" && win.page === "bluetooth"
    Layout.fillWidth: true
    spacing: Theme.pageSpacing

    // переключатель модуля
    Card {
        Layout.fillWidth: true
        pad: Theme.dp(4)

        ToggleRow {
            Layout.fillWidth: true
            icon: "bluetooth"
            label: "Bluetooth"
            sub: Sys.btEnabled ? "Включён" : "Выключен"
            active: Sys.btEnabled
            onToggled: (v) => { Sys.toggleBt(); if (!v) Sys.refreshBt(); }
        }
    }

    // устройства
    Card {
        Layout.fillWidth: true
        title: "Устройства"
        actionIcon: "refresh"
        onActionClicked: Sys.startBtScan()

        LText { // пустое состояние
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(4)
            Layout.bottomMargin: Theme.dp(4)
            visible: Sys.btDevices.length === 0
            role: "bodySmall"
            color: Theme.subtext
            text: !Sys.btEnabled ? "Bluetooth выключен"
                : (Sys.btDiscovering ? "Поиск…" : "Устройств не найдено")
        }

        Repeater {
            model: Sys.btDevices

            delegate: ColumnLayout {
                id: btWrap
                required property var modelData
                required property int index
                Layout.fillWidth: true
                spacing: 0

                readonly property int count: Sys.btDevices.length
                readonly property string pos: btWrap.count <= 1 ? "single"
                    : (btWrap.index === 0 ? "top"
                    : (btWrap.index === btWrap.count - 1 ? "bottom" : "middle"))
                readonly property string status: btWrap.modelData.connected ? "Подключено"
                    : (btWrap.modelData.pairing ? "Сопряжение…"
                    : (btWrap.modelData.paired ? "Сопряжено" : "Не сопряжено"))

                DeviceRow {
                    Layout.fillWidth: true
                    icon: "bluetooth"
                    devName: btWrap.modelData.name
                    sub: btWrap.status + (btWrap.modelData.mac ? " · " + btWrap.modelData.mac : "")
                    position: btWrap.pos
                    onClicked: {
                        const device = btWrap.modelData.device;
                        if (!device || device.pairing)
                            return;
                        if (device.connected)
                            device.disconnect();
                        else if (device.paired)
                            device.connect();
                        else
                            device.pair();
                    }
                }
            }
        }
    }
}
