import QtQuick
import QtQuick.Shapes
import QtQuick.Window
import "../core"
import "SymbolPaths.js" as Symbols
import "IconAliases.js" as Aliases

// Иконка Material Symbols, нарисованная векторными путями из SymbolPaths.js
// (google/material-design-icons). `fill` идёт 0..1 и плавно перетекает между
// контуром (outline) и заливкой (filled), поэтому смена состояния читается как
// «наполнение» глифа.
Item {
    id: icon

    property string name: ""
    // сохраняем прежний API (size/color/weight), но рендер теперь векторный
    property real size: 18
    property color color: Theme.subtext
    // у путей один вес; свойство оставлено, чтобы старые вызовы парсились
    property real weight: 400
    // 0 — контур, 1 — заливка
    property real fill: 0
    property bool animateFill: true
    property bool animateColor: true

    property real _fill: Math.max(0, Math.min(1, icon.fill))
    // алиас для имён, которых нет в наборе путей
    readonly property string _resolved: Aliases.alias[icon.name] !== undefined ? Aliases.alias[icon.name] : icon.name
    readonly property var paths: Symbols.p[icon._resolved] || null

    // все масштабы над иконкой — чтобы масштабированная карточка получила
    // текстуру нужного разрешения
    readonly property real _scale: {
        var k = 1;
        for (var p = icon.parent; p; p = p.parent)
            if (p.scale !== undefined)
                k *= p.scale;

        return k;
    }
    // кратно четверти, чтобы анимация ховера/нажатия не пересобирала текстуру
    readonly property real _zoom: icon._scale < 1.1 ? 1 : Math.ceil(icon._scale * 4) / 4

    implicitWidth: icon.size
    implicitHeight: icon.size
    width: icon.size
    height: icon.size

    // CurveRenderer рвёт глифы на малых размерах там, где угол встречает ребро,
    // поэтому рисуем через мультисэмплированный слой (без него на 1:1 — лесенки)
    layer.enabled: icon.paths !== null && icon.width > 0 && icon.height > 0
    layer.samples: 8
    // 1:1 попадает в пиксельную сетку, всё масштабированное — фильтруется
    layer.smooth: Math.abs(icon._scale - 1) > 0.001
    layer.textureSize: icon._zoom === 1 ? Qt.size(0, 0) : Qt.size(Math.ceil(icon.width * icon._zoom * Screen.devicePixelRatio), Math.ceil(icon.height * icon._zoom * Screen.devicePixelRatio))

    // неизвестное имя — рисуем пустоту, но один раз предупреждаем в лог
    onPathsChanged: {
        if (icon.paths === null && icon._resolved !== "")
            Aliases.warnUnknown(icon._resolved);
    }

    Behavior on _fill {
        enabled: icon.animateFill

        NumberAnimation {
            duration: Theme.durDefaultEffects
            easing.type: Easing.Bezier
            easing.bezierCurve: Theme.curveEffects
        }

    }

    Behavior on color {
        enabled: icon.animateColor

        ColorAnimation {
            duration: Theme.durFastEffects
        }

    }

    Shape {
        visible: icon.paths !== null
        // 24-юнитная сетка путей, масштабируем ниже
        width: 24
        height: 24
        preferredRendererType: Shape.GeometryRenderer
        transform: Scale {
            xScale: icon.width / 24
            yScale: icon.height / 24
        }

        ShapePath {
            strokeWidth: 0
            strokeColor: "transparent"
            fillColor: icon._fill >= 0.999 ? "transparent" : Qt.rgba(icon.color.r, icon.color.g, icon.color.b, icon.color.a * (1 - icon._fill))

            PathSvg {
                path: icon.paths ? icon.paths[0] : ""
            }

        }

        ShapePath {
            strokeWidth: 0
            strokeColor: "transparent"
            fillColor: icon._fill <= 0.001 ? "transparent" : Qt.rgba(icon.color.r, icon.color.g, icon.color.b, icon.color.a * icon._fill)

            PathSvg {
                path: icon.paths && icon._fill > 0.001 ? icon.paths[1] : ""
            }

        }

    }
}
