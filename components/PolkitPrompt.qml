import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "../core"
import "../ui"

// Модальное окно аутентификации polkit. Активный flow приходит из shell.qml
// (PolkitAgent.flow). Поверхность — Overlay во весь экран, чтобы гарантированно
// перекрыть остров; анатомия — карточка аутентификации Lucid (badge + title +
// action + account + поле пароля + filled-кнопка).
PanelWindow {
    id: root

    property var flow: null
    // показываем, пока запрос активен и ещё не завершён
    readonly property bool active: flow !== null && !flow.isCompleted
    readonly property string account: Quickshell.env("USER") || ""

    visible: active
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "oberon-polkit"
    WlrLayershell.keyboardFocus: root.active ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    // Отправка ответа (пароля) в flow.
    function submit() {
        if (!root.flow) return;
        root.flow.submit(pwField.text);
        pwField.text = "";
        pwField.forceActiveFocus();
    }
    // Отмена запроса со стороны пользователя.
    function cancel() {
        if (!root.flow) return;
        root.flow.cancelAuthenticationRequest();
        pwField.text = "";
    }

    // Новый запрос (или смена flow) — очищаем поле и забираем фокус.
    onFlowChanged: {
        pwField.text = "";
        if (root.active) pwField.forceActiveFocus();
    }
    onActiveChanged: {
        if (root.active) {
            pwField.text = "";
            pwField.forceActiveFocus();
        }
    }

    // Escape отменяет запрос независимо от того, какой ребёнок в фокусе.
    Shortcut {
        sequence: "Escape"
        enabled: root.active
        onActivated: root.cancel()
    }

    // ── затемнение и перехват кликов (клик мимо — отмена, как в Lucid) ──
    Rectangle {
        anchors.fill: parent
        color: Theme.alpha(Theme.cShadow, Theme.blurPct > 0 ? 0.28 : 0.45)
        opacity: root.active ? 1 : 0

        Behavior on opacity {
            NumberAnimation { duration: Theme.durShort }
        }

        MouseArea {
            anchors.fill: parent
            // клик по самой карточке (её пустым местам) не должен отменять запрос
            onClicked: (mouse) => {
                const inside = mouse.x >= dialog.x && mouse.x <= dialog.x + dialog.width
                            && mouse.y >= dialog.y && mouse.y <= dialog.y + dialog.height;
                if (!inside) root.cancel();
            }
        }
    }

    // ── карточка диалога ──────────────────────────────────────────────
    Card {
        id: dialog
        anchors.centerIn: parent
        width: Theme.dp(420)
        pad: Theme.dp(20)
        scale: root.active ? 1 : 0.96
        opacity: root.active ? 1 : 0

        Behavior on scale {
            NumberAnimation {
                duration: Theme.durFastSpatial
                easing.type: Easing.Bezier
                easing.bezierCurve: Theme.curveDefaultSpatial
            }
        }
        Behavior on opacity {
            NumberAnimation { duration: Theme.durShort }
        }

        // header: badge + overline + title
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(12)

            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: Theme.dp(44)
                implicitHeight: Theme.dp(44)
                radius: Theme.shapeLgInc
                color: Theme.accentContainer

                Icon {
                    anchors.centerIn: parent
                    name: "lock"
                    size: Theme.dp(22)
                    color: Theme.fgAccentContainer
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 0

                LText {
                    Layout.fillWidth: true
                    text: "Требуется аутентификация"
                    role: "labelMedium"
                    color: Theme.accent
                    elide: Text.ElideRight
                }
                LText {
                    Layout.fillWidth: true
                    text: "Аутентификация"
                    role: "titleLarge"
                    color: Theme.text
                    elide: Text.ElideRight
                }
            }
        }

        // Основной текст запроса (например, «Authentication is required to …»).
        LText {
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(4)
            visible: text !== ""
            text: root.flow ? root.flow.message : ""
            role: "bodySmall"
            color: Theme.subtext
            wrapMode: Text.WordWrap
        }

        // Подсказка поля ввода, если polkit её задал.
        LText {
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(2)
            visible: text !== ""
            text: root.flow ? root.flow.inputPrompt : ""
            role: "bodySmall"
            color: Theme.subtextDim
            wrapMode: Text.WordWrap
        }

        // Кому принадлежит пароль.
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(6)
            spacing: Theme.dp(8)

            Icon {
                Layout.alignment: Qt.AlignVCenter
                name: "person"
                size: Theme.dp(18)
                color: Theme.subtextDim
            }
            LText {
                Layout.alignment: Qt.AlignVCenter
                role: "bodySmall"
                color: Theme.text
                text: "От имени " + root.account
            }
        }

        // Пароль. responseVisible=false → маскируем (обычный случай).
        TextField {
            id: pwField
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(6)
            visible: root.flow === null || root.flow.isResponseRequired
            placeholder: "Пароль"
            echoMode: (root.flow && root.flow.responseVisible) ? TextInput.Normal : TextInput.Password
            onAccepted: root.submit()
            Keys.onEscapePressed: root.cancel()
        }

        // Ошибка попытки / доп. сообщение (остаток попыток polkit кладёт сюда).
        LText {
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(4)
            readonly property string info: root.flow ? root.flow.supplementaryMessage : ""
            readonly property string fallback: (root.flow && root.flow.failed && info === "")
                ? "Неверный пароль. Попробуйте снова." : ""
            visible: info !== "" || fallback !== ""
            text: info !== "" ? info : fallback
            color: (root.flow && root.flow.supplementaryIsError) || fallback !== ""
                ? Theme.error : Theme.subtext
            role: "bodySmall"
            wrapMode: Text.WordWrap
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.dp(10)
            spacing: Theme.dp(8)

            Item { Layout.fillWidth: true }

            Button {
                text: "Отмена"
                variant: "text"
                size: "m"
                onClicked: root.cancel()
            }
            Button {
                text: "Подтвердить"
                variant: "filled"
                size: "m"
                onClicked: root.submit()
            }
        }
    }
}
