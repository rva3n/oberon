import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import "../../core"
import "../../ui"

ColumnLayout {
    id: root

    property string label: ""
    property string sub: ""
    property var options: []
    property var value: ""
    property bool searchable: false
    property string placeholder: "Поиск"
    property string query: ""

    signal picked(var value)

    Layout.fillWidth: true
    spacing: Theme.dp(6)

    function optionKey(option) {
        return option && option.key !== undefined ? option.key : option;
    }
    function optionLabel(option) {
        return option && option.label !== undefined ? String(option.label) : String(option);
    }
    function selectedLabel() {
        for (let i = 0; i < root.options.length; i++)
            if (root.optionKey(root.options[i]) === root.value)
                return root.optionLabel(root.options[i]);
        return root.options.length ? root.optionLabel(root.options[0]) : "Выбрать";
    }
    readonly property var filteredOptions: {
        const result = [];
        const q = root.query.trim().toLowerCase();
        for (let i = 0; i < root.options.length; i++) {
            const option = root.options[i];
            const label = root.optionLabel(option).toLowerCase();
            const key = String(root.optionKey(option)).toLowerCase();
            if (q === "" || label.indexOf(q) >= 0 || key.indexOf(q) >= 0)
                result.push(option);
        }
        return result;
    }

    LText {
        Layout.fillWidth: true
        visible: root.label !== ""
        text: root.label
        role: "bodyLarge"
        weight: 480
        color: Theme.text
        elide: Text.ElideRight
    }

    Button {
        Layout.fillWidth: true
        variant: "tonal"
        icon: "expand_more"
        text: root.selectedLabel()
        onClicked: menu.open()
    }

    LText {
        Layout.fillWidth: true
        visible: root.sub !== ""
        text: root.sub
        role: "bodySmall"
        color: Theme.subtextDim
        wrapMode: Text.WordWrap
    }

    Controls.Popup {
        id: menu

        parent: Controls.Overlay.overlay ? Controls.Overlay.overlay : root
        x: root.mapToItem(parent, 0, root.height).x
        y: root.mapToItem(parent, 0, root.height).y + Theme.dp(4)
        width: Math.max(root.width, Theme.dp(180))
        height: Math.min(Theme.dp(root.searchable ? 320 : 260), popupColumn.implicitHeight + Theme.dp(16))
        padding: Theme.dp(8)
        modal: false
        focus: root.searchable
        closePolicy: Controls.Popup.CloseOnEscape | Controls.Popup.CloseOnPressOutside

        background: Rectangle {
            radius: Theme.rad(14)
            color: Theme.mHigh
            border.width: 1
            border.color: Theme.outline
        }

        ColumnLayout {
            id: popupColumn
            width: menu.availableWidth
            spacing: Theme.dp(6)

            TextField {
                visible: root.searchable
                Layout.fillWidth: true
                variant: "search"
                icon: "search"
                placeholder: root.placeholder
                text: root.query
                onTextEdited: root.query = text
                onEscaped: root.query = ""
            }

            ListView {
                id: optionList
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(Theme.dp(240), Math.max(Theme.dp(42), optionList.contentHeight))
                clip: true
                model: root.filteredOptions
                spacing: Theme.dp(2)

                delegate: Item {
                    id: optionItem
                    required property var modelData
                    readonly property var optionValue: root.optionKey(optionItem.modelData)
                    readonly property bool selected: optionItem.optionValue === root.value

                    width: optionList.width
                    height: Theme.dp(42)

                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.rad(10)
                        color: optionItem.selected ? Theme.secondaryContainer : "transparent"

                        StateLayer {
                            anchors.fill: parent
                            radius: parent.radius
                            tint: optionItem.selected ? Theme.fgSecondaryContainer : Theme.text
                            onClicked: {
                                root.picked(optionItem.optionValue);
                                root.query = "";
                                menu.close();
                            }
                        }
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.dp(12)
                        anchors.rightMargin: Theme.dp(12)
                        spacing: Theme.dp(8)

                        LText {
                            Layout.fillWidth: true
                            text: root.optionLabel(optionItem.modelData)
                            role: "bodyMedium"
                            color: optionItem.selected ? Theme.fgSecondaryContainer : Theme.text
                            elide: Text.ElideRight
                        }

                        Icon {
                            visible: optionItem.selected
                            name: "check"
                            size: Theme.dp(18)
                            color: Theme.fgSecondaryContainer
                        }
                    }
                }
            }
        }
    }
}
