import QtQuick
import Quickshell
import Quickshell.Wayland
import "../core"

// Невидимая распорка под остров: резервирует полосу у кромки через
// exclusiveZone, чтобы окна и колонки начинались ниже капсулы.
//
// Сам остров зону не запрашивает намеренно: Umbriel рисует layer-поверхность
// с непустым exclusiveZone дважды (содержимое дублируется со сдвигом на
// величину зоны). Прозрачная поверхность без содержимого и без области ввода
// дублируется незаметно, а место под остров всё равно резервируется.
PanelWindow {
    id: strut

    required property var modelData
    screen: modelData

    readonly property string pos: {
        const p = String(Prefs.islandPos || "top");
        return (p === "bottom" || p === "left" || p === "right") ? p : "top";
    }
    readonly property bool horizontal: strut.pos === "top" || strut.pos === "bottom"
    readonly property int reserve: Theme.dp(Math.max(1, Prefs.islandHeight))
        + Theme.dp(Math.max(0, Prefs.islandGap))
    // При автоскрытии полосу не держим: капсула уезжает за кромку.
    readonly property bool reserving: Prefs.islandAutoHide !== true
    // В fullscreen зону снимаем: Umbriel ставит полноэкранное окно внутрь
    // usable area и без этого игра уезжает вниз на величину зоны (низ обрезан).
    // Остров в fullscreen и так скрыт, место ему не нужно.
    readonly property bool fullscreenHere: strut.screen
        ? Umbriel.fullscreenFor(strut.screen.name) : false

    visible: strut.reserving
    anchors {
        top: strut.pos === "top"
        bottom: strut.pos === "bottom"
        left: strut.pos === "left" || strut.horizontal
        right: strut.pos === "right" || strut.horizontal
    }
    implicitWidth: strut.horizontal ? 0 : strut.reserve
    implicitHeight: strut.horizontal ? strut.reserve : 0
    color: "transparent"
    exclusiveZone: strut.reserving && !strut.fullscreenHere ? strut.reserve : -1
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "oberon-strut"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region { item: noInput }

    // Нулевой якорь области ввода: распорка не должна ловить клики.
    Item {
        id: noInput
        width: 0
        height: 0
    }
}
