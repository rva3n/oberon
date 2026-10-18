import QtQuick
import QtQuick.Layouts
import "../core"
import "../ui"

// Тост уведомления в капсуле острова. Анатомия lucidnotif (NotifPopupCard +
// NotifCard): аватар dp(28), строка приложения (subtextDim), summary
// (titleSmall/DemiBold), тело в N строк цветом subtext со ссылками tint;
// краткая вспышка акцента при появлении. API прежний: current. Авто-скрытие
// остаётся за Notif.qml; видимость тела настраивается через Prefs.notifPreview.
Item {
    id: notifRow
    property var current: null
    // сколько строк тела показывать (в Lucid — Prefs.toastBodyLines)
    property int bodyLines: 2

    readonly property var cur: notifRow.current
    readonly property color tint: Theme.accent

    implicitWidth: content.implicitWidth
    implicitHeight: content.implicitHeight

    // ── вспышка акцента при появлении нового уведомления ───────────────
    Rectangle {
        id: glow
        anchors.fill: parent
        radius: height / 2
        color: notifRow.tint
        opacity: 0
    }

    SequentialAnimation {
        id: arrivalGlow
        NumberAnimation {
            target: glow
            property: "opacity"
            to: 0.16
            duration: Theme.durShort
            easing.type: Easing.Bezier
            easing.bezierCurve: Theme.easeEmphasizedDecel
        }
        NumberAnimation {
            target: glow
            property: "opacity"
            to: 0
            duration: Theme.durMedium
            easing.type: Easing.Bezier
            easing.bezierCurve: Theme.easeEmphasizedAccel
        }
    }

    onCurrentChanged: if (notifRow.current) arrivalGlow.restart()

    // действие по умолчанию (identifier "default") — «перейти к сообщению»,
    // как в Lucid/GNOME. Нет действия — просто закрыть.
    function invokeDefault() {
        const raw = notifRow.cur && (notifRow.cur.raw || notifRow.cur);
        if (!raw || !raw.actions)
            return false;

        for (let i = 0; i < raw.actions.length; i++) {
            const a = raw.actions[i];
            if (a && a.identifier === "default") {
                try { a.invoke(); } catch (e) {}
                return true;
            }
        }
        return false;
    }

    // клик по тосту — перейти к сообщению, затем свернуть тост
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            notifRow.invokeDefault();
            Notif.visible = false;
        }
    }

    RowLayout {
        id: content
        x: 0
        y: 0
        spacing: Theme.dp(12)

        // аватар dp(28) — как в NotifCard
        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            implicitWidth: Theme.dp(28)
            implicitHeight: Theme.dp(28)
            radius: Theme.radiusPill
            color: Theme.accentContainer

            Icon {
                anchors.centerIn: parent
                name: "notifications"
                size: Theme.dp(15)
                color: Theme.fgAccentContainer
            }
        }

        ColumnLayout {
            Layout.alignment: Qt.AlignVCenter
            Layout.fillWidth: true
            Layout.maximumWidth: Theme.dp(420)
            spacing: Theme.dp(2)

            // приложение (subtextDim, labelSmall)
            LText {
                Layout.fillWidth: true
                visible: text !== ""
                role: "labelSmall"
                color: Theme.subtextDim
                text: notifRow.cur ? (notifRow.cur.appName || "") : ""
                elide: Text.ElideRight
            }

            // summary (titleSmall / DemiBold)
            LText {
                Layout.fillWidth: true
                visible: text !== ""
                role: "titleSmall"
                color: Theme.text
                text: notifRow.cur ? (notifRow.cur.summary || "") : ""
                elide: Text.ElideRight
            }

            // тело (subtext, N строк, ссылки цветом tint)
            LText {
                Layout.fillWidth: true
                visible: Prefs.notifPreview && text !== ""
                role: "bodySmall"
                color: Theme.subtext
                textFormat: Text.StyledText
                linkColor: notifRow.tint
                wrapMode: Text.WordWrap
                maximumLineCount: notifRow.bodyLines
                elide: Text.ElideRight
                text: notifRow.cur ? (notifRow.cur.body || "") : ""
            }
        }

        // закрытие — ghost-кнопка Lucid
        IconButton {
            Layout.alignment: Qt.AlignVCenter
            icon: "close"
            size: "xs"
            onClicked: Notif.visible = false
        }
    }
}
