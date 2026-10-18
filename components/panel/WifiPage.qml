import QtQuick
import QtQuick.Layouts
import "../../core"
import "../../ui"
import ".."

// Wi-Fi в анатомии Lucid: карточка-переключатель радио (ToggleRow),
// карточка списка сетей на DeviceRow (групповые углы) и заполненное поле
// пароля с filled-кнопкой подключения. Логика прежняя: scan/connect/password.
ColumnLayout {
    id: wifiPage
    property var win: null
    visible: win !== null && win.mode === "panel" && win.page === "wifi"
    Layout.fillWidth: true
    spacing: Theme.pageSpacing

    // переключатель модуля
    Card {
        Layout.fillWidth: true
        pad: Theme.dp(4)

        ToggleRow {
            Layout.fillWidth: true
            icon: "wifi"
            label: "Wi-Fi"
            sub: Sys.wifiEnabled ? "Включён" : "Выключен"
            active: Sys.wifiEnabled
            onToggled: (v) => { Sys.toggleWifi(); if (!v) Sys.refreshWifi(); }
        }
    }

    // сети
    Card {
        Layout.fillWidth: true
        title: "Сети"
        actionIcon: "refresh"
        onActionClicked: Sys.refreshWifi()

        LText { // пустое состояние
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(4)
            Layout.bottomMargin: Theme.dp(4)
            visible: Sys.wifiNetworks.length === 0
            role: "bodySmall"
            color: Theme.subtext
            text: Sys.wifiEnabled ? "Поиск сетей…" : "Wi-Fi выключен"
        }

        Repeater {
            model: Sys.wifiNetworks

            delegate: ColumnLayout {
                id: netWrap
                required property var modelData
                required property int index
                Layout.fillWidth: true
                spacing: 0

                readonly property bool sel: !!(win && win.wifiSel === modelData.ssid)
                readonly property int count: Sys.wifiNetworks.length
                readonly property string pos: netWrap.count <= 1 ? "single"
                    : (netWrap.index === 0 ? "top"
                    : (netWrap.index === netWrap.count - 1 ? "bottom" : "middle"))
                readonly property bool secured: !!(modelData.security && modelData.security !== "--" && modelData.security !== "")

                DeviceRow {
                    id: netRow
                    Layout.fillWidth: true
                    icon: "wifi"
                    devName: netWrap.modelData.ssid
                    sub: netWrap.modelData.connected
                        ? "Подключено · " + netWrap.modelData.signal + "%"
                        : netWrap.modelData.signal + "%"
                    selected: netWrap.sel
                    position: netWrap.pos
                    onClicked: {
                        const sec = netWrap.modelData.security;
                        if (!sec || sec === "" || sec === "--") {
                            Sys.connectWifi(netWrap.modelData.ssid, "");
                            if (win.shell) win.shell.setPage("");
                        } else {
                            win.wifiSel = netWrap.modelData.ssid;
                            wifiPassInput.text = "";
                            wifiPassInput.forceActiveFocus();
                        }
                    }

                    trailing: Icon {
                        visible: netWrap.secured
                        name: "lock"
                        size: Theme.dp(16)
                        color: netRow.selected ? Theme.fgSecondaryContainer : Theme.subtextDim
                    }
                }
            }
        }

        // пароль выбранной сети
        RowLayout {
            visible: win !== null && win.wifiSel !== ""
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(6)
            spacing: Theme.dp(8)

            TextField {
                id: wifiPassInput
                Layout.fillWidth: true
                variant: "filled"
                label: win ? ("Пароль · " + win.wifiSel) : "Пароль"
                password: true
                onAccepted: if (win) win.submitWifi(text)
            }

            Button {
                Layout.alignment: Qt.AlignVCenter
                variant: "filled"
                text: "Подключить"
                onClicked: if (win) win.submitWifi(wifiPassInput.text)
            }
        }
    }
}
