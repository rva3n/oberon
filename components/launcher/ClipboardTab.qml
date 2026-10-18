pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../core"
import "../../ui"

// Вкладка «Буфер»: закреплённые сверху, затем история cliphist. Клик/Enter —
// копирование и (если есть wtype) вставка Ctrl+V в вернувшее фокус окно,
// pin/delete — как в ClipRow. Индексы: сначала pins, затем items.
// Единый ритм строк (как в AppsTab): строка 48, превью 44×32, divider с
// отступом от превью (52), кнопки справа у края (margin 4, spacing 4).
ColumnLayout {
    id: tab

    property string query: ""
    property int sel: 0
    property var shell: null
    property bool active: false
    // есть ли wtype в PATH — как в EmojiTab; без него просто копируем
    property bool haveWtype: false

    signal hovered(int index)
    signal selectionRequested(int index)

    // экранирование одинарных кавычек для sh
    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    // фильтр по тексту/превью, регистронезависимо
    function matches(it) {
        const q = tab.query.trim().toLowerCase();
        if (q === "") return true;
        const src = (it.text !== undefined && it.text !== "") ? it.text : (it.preview || "");
        return String(src).toLowerCase().indexOf(q) !== -1;
    }
    readonly property var fPins: Clip.pins.filter(tab.matches)
    readonly property var fItems: Clip.items.filter(tab.matches)
    readonly property int count: tab.fPins.length + tab.fItems.length

    spacing: Theme.dp(4)

    onActiveChanged: if (tab.active) Clip.refresh()
    onSelChanged: {
        if (tab.sel < tab.fPins.length)
            pinsView.positionViewAtIndex(tab.sel, ListView.Contain);
        else if (tab.sel < tab.count)
            itemsView.positionViewAtIndex(tab.sel - tab.fPins.length, ListView.Contain);
    }

    // вставка в приложение, которое вернёт фокус после закрытия оверлея:
    // Ctrl+V через wtype (как EmojiTab). Без wtype ничего не делаем — текст
    // уже в буфере, падения нет.
    function pasteInto() {
        if (!tab.haveWtype) return;
        Quickshell.execDetached(["sh", "-c", "setsid -f sh -c 'sleep 0.25; wtype -M ctrl v -m ctrl'"]);
    }

    function copyDirect(text) {
        Quickshell.execDetached(["sh", "-c", "printf %s " + tab.shq(String(text)) + " | wl-copy"]);
    }
    function openTarget(entry) {
        if (!entry) return;
        const target = entry.kind === "url" ? entry.url : entry.path;
        if (!target) return;
        if (tab.shell) tab.shell.closeOverlays();
        Quickshell.execDetached(["xdg-open", String(target)]);
    }
    function openMedia(entry) {
        if (entry && entry.path && tab.shell) tab.shell.openMedia(entry.path);
    }

    function activate(index) {
        if (index < tab.fPins.length) {
            const p = tab.fPins[index];
            if (p) Clip.copyPin(p);
        } else {
            const it = tab.fItems[index - tab.fPins.length];
            if (it) Clip.copy(it.id, it.type);
        }
        if (tab.shell) tab.shell.closeOverlays();
        tab.pasteInto();
    }

    function moveSel(delta) {
        if (tab.count > 0) tab.selectionRequested(tab.sel + delta);
    }

    // есть ли wtype в PATH (проба как в EmojiTab)
    Process {
        id: wtypeCheck
        command: ["sh", "-c", "command -v wtype >/dev/null 2>&1"]
        running: true
        onExited: (exitCode) => tab.haveWtype = exitCode === 0
    }

    // ── Закреплённые: заголовок группы с пином и правилом (Lucid) ────
    RowLayout {
        visible: tab.fPins.length > 0
        Layout.fillWidth: true
        Layout.leftMargin: Theme.dp(8)
        Layout.rightMargin: Theme.dp(8)
        Layout.bottomMargin: Theme.dp(2)
        spacing: Theme.dp(8)

        Icon {
            Layout.alignment: Qt.AlignVCenter
            name: "push_pin"
            size: Theme.dp(16)
            color: Theme.primary
        }

        LText {
            Layout.alignment: Qt.AlignVCenter
            role: "labelLarge"
            text: "Закреплённые"
            color: Theme.primary
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            implicitHeight: 1
            color: Theme.divider
        }
    }

    ListView { // пины прокручиваются отдельно от истории в общей рабочей области
        id: pinsView

        visible: tab.fPins.length > 0
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.minimumHeight: 0
        Layout.preferredHeight: Math.min(Theme.dp(220), contentHeight)
        model: tab.fPins
        clip: true
        spacing: Theme.dp(4)
        boundsBehavior: Flickable.StopAtBounds

        delegate: ClipRow {
            baseIndex: 0
            pinned: true
            selected: tab.sel === rowIndex
            onHovered: (i) => tab.hovered(i)
            onActivated: (i) => tab.activate(i)
        }
    }

    // ── История ───────────────────────────────────────────────────────
    ListView {
        id: itemsView

        visible: tab.fItems.length > 0
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.minimumHeight: 0
        // История занимает оставшееся место и скроллится внутри рабочей области.
        Layout.preferredHeight: Math.min(Theme.dp(340), contentHeight)
        model: tab.fItems
        clip: true
        spacing: Theme.dp(4)
        boundsBehavior: Flickable.StopAtBounds

        // последняя позиция скролла (не считая восстановление после сброса модели)
        property real _lastY: 0
        property bool _restoring: false
        onContentYChanged: if (!itemsView._restoring) itemsView._lastY = contentY

        delegate: ClipRow {
            baseIndex: tab.fPins.length
            selected: tab.sel === rowIndex
            onHovered: (i) => tab.hovered(i)
            onActivated: (i) => tab.activate(i)
        }
    }

    // fItems пересобирается при обновлении Clip.items — ListView сбрасывает
    // contentY в 0; запоминаем и возвращаем позицию (как ProcessesTab)
    Connections {
        target: Clip
        function onItemsChanged() {
            const y = itemsView._lastY;
            itemsView._restoring = true;
            Qt.callLater(function() {
                itemsView.contentY = Math.min(y, Math.max(0, itemsView.contentHeight - itemsView.height));
                itemsView._restoring = false;
            });
        }
    }

    Item { // пусто / нет результатов / загрузка
        visible: tab.count === 0
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.minimumHeight: 0
        Layout.preferredHeight: Theme.dp(220)

        LText {
            anchors.centerIn: parent
            text: tab.query.trim() !== "" ? "Ничего не найдено"
                : (Clip.loading ? "Загрузка…" : "Буфер пуст")
            role: "bodyMedium"
            color: Theme.subtext
        }
    }

    // ── Очистить историю: обычная строка-кнопка, тот же ритм ──────────
    Item {
        visible: Clip.items.length > 0
        Layout.fillWidth: true
        implicitHeight: Theme.dp(44)

        Rectangle {
            anchors.fill: parent
            radius: Theme.radiusMd
            color: wipeArea.pressed ? Theme.a(Theme.errorContainer, 0.3)
                 : (wipeArea.containsMouse ? Theme.a(Theme.errorContainer, 0.2) : "transparent")

            Behavior on color {
                ColorAnimation { duration: Theme.durQuick }
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.dp(4)
            anchors.rightMargin: Theme.dp(4)
            spacing: Theme.dp(4)

            Item { // слот превью — иконка в error-тоне по центру
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: Theme.dp(44)
                implicitHeight: Theme.dp(32)

                Icon {
                    anchors.centerIn: parent
                    name: "delete_sweep"
                    size: Theme.dp(16)
                    color: Theme.error
                }
            }

            LText {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                text: "Очистить историю"
                role: "bodySmall"
                color: Theme.error
                elide: Text.ElideRight
            }
        }

        MouseArea {
            id: wipeArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: Clip.wipe()
        }
    }

    // ── строка буфера: превью 44×32, текст, pin и delete справа ───────
    component ClipRow: ColumnLayout {
        id: ci

        required property var modelData
        required property int index

        property int baseIndex: 0
        property bool pinned: false
        property bool selected: false
        property bool hovering: false

        signal hovered(int rowIndex)
        signal activated(int rowIndex)

        readonly property int rowIndex: ci.baseIndex + ci.index
        readonly property bool isImage: !!ci.modelData && ci.modelData.type === "image"
        readonly property string kind: ci.modelData && ci.modelData.kind ? String(ci.modelData.kind) : ""
        readonly property bool showSmartActions: ci.hovering || ci.selected
        // в cliphist иногда попадает текст с NUL и управляющими байтами — чистим
        function clean(s) {
            return String(s === undefined || s === null ? "" : s)
                .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, "");
        }
        readonly property string label: {
            if (!ci.modelData) return "";
            if (ci.modelData.type === "image") return "Изображение";
            const t = ci.clean(ci.modelData.text);
            if (t !== "") return t;
            return ci.clean(ci.modelData.preview);
        }

        // в Column ширина задаётся позиционером, в ListView — вью
        width: parent ? parent.width : implicitWidth
        Layout.fillWidth: true
        spacing: 0

        ListItem {
            id: rowItem

            Layout.fillWidth: true
            implicitHeight: Theme.dp(52)
            headline: ci.label
            headlineRole: "bodySmall"
            headlineWeight: Theme.typeWeight("bodySmall")
            headlineLines: ci.pinned ? 1 : 2
            headlineWrapMode: ci.pinned ? Text.NoWrap : Text.Wrap
            selected: ci.selected
            clickable: true
            containerColor: "transparent"
            stateTint: ci.selected ? Theme.fgSecondaryContainer : Theme.text
            outerRadius: Theme.radiusMd
            innerRadius: Theme.radiusMd
            leadingMargin: Theme.dp(4)
            leadingTextSpacing: Theme.dp(8)
            textTrailingSpacing: Theme.dp(4)
            trailingMargin: Theme.dp(4)
            trailingSpacing: Theme.dp(4)
            onClicked: ci.activated(ci.rowIndex)

            leading: Item {
                anchors.fill: parent

                Item { // превью: картинка 44×32 либо иконка текста
                    width: Theme.dp(44)
                    height: Theme.dp(32)
                    anchors.verticalCenter: parent.verticalCenter

                    Rectangle {
                        anchors.fill: parent
                        visible: ci.isImage
                        radius: Theme.radiusSm
                        color: Theme.bgTile
                        clip: true

                        Image {
                            anchors.fill: parent
                            fillMode: Image.PreserveAspectCrop
                            // items кладут thumb (кэш по id), pins — file
                            source: ci.isImage && (ci.modelData.thumb || ci.modelData.file)
                                    ? "file://" + (ci.modelData.thumb || ci.modelData.file) : ""
                        }
                    }

                    Item { // текст: без контейнера, иконка по центру области 24
                        anchors.centerIn: parent
                        visible: !ci.isImage && ci.kind !== "color"
                        implicitWidth: Theme.dp(24)
                        implicitHeight: Theme.dp(24)

                        Icon {
                            anchors.centerIn: parent
                            name: ci.kind === "image-file" ? "image"
                                : (ci.kind === "url" ? "link" : "description")
                            size: Theme.dp(16)
                            color: Theme.subtext
                        }
                    }

                    Rectangle { // цветовой свотч для HEX-строки
                        visible: ci.kind === "color"
                        width: Theme.dp(22)
                        height: Theme.dp(22)
                        anchors.centerIn: parent
                        radius: width / 2
                        color: ci.modelData.swatch || Theme.bgTile
                        border.width: Theme.dp(1)
                        border.color: Theme.outline
                    }
                }
            }

            HoverHandler {
                onHoveredChanged: {
                    ci.hovering = hovered;
                    if (hovered) ci.hovered(ci.rowIndex);
                }
            }

            trailing: Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.dp(4)

                Button {
                    visible: ci.showSmartActions && ci.kind === "color"
                    size: "xs"
                    variant: "text"
                    text: "RGB"
                    onClicked: tab.copyDirect(ci.modelData.rgb)
                }

                Button {
                    visible: ci.showSmartActions && ci.kind === "color"
                    size: "xs"
                    variant: "text"
                    text: "HSL"
                    onClicked: tab.copyDirect(ci.modelData.hsl)
                }

                Button {
                    visible: ci.showSmartActions && (ci.kind === "url" || ci.kind === "file" || ci.kind === "image-file")
                    size: "xs"
                    variant: "text"
                    text: "Открыть"
                    onClicked: tab.openTarget(ci.modelData)
                }

                Button {
                    visible: ci.showSmartActions && ci.kind === "image-file"
                    size: "xs"
                    variant: "text"
                    text: "В Медиа"
                    onClicked: tab.openMedia(ci.modelData)
                }

                IconButton { // pin: закреплённая строка — filled
                    icon: "push_pin"
                    size: "xs"
                    variant: ci.pinned ? "filled" : "standard"
                    onClicked: ci.pinned ? Clip.unpin(ci.modelData.id) : Clip.pin(ci.modelData.id)
                }

                IconButton { // удалить: ghost-кнопка в error-тоне
                    visible: !ci.pinned
                    icon: "delete"
                    size: "xs"
                    tintOverride: Theme.error
                    onClicked: Clip.del(ci.modelData.id)
                }
            }
        }
    }
}
