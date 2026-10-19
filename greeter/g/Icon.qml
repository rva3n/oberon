import QtQuick
import QtQuick.Shapes

Item {
    id: icon

    property string name: ""
    property real size: 20
    property color color: Theme.subtext

    readonly property var paths: ({
        "person": "M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z",
        "visibility": "M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5s9.27-3.11 11-7.5c-1.73-4.39-6-7.5-11-7.5zm0 13a5.5 5.5 0 1 1 0-11 5.5 5.5 0 0 1 0 11zm0-2a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7z",
        "visibility_off": "M2 3.27 3.27 2l18.73 18.73L20.73 22l-3.14-3.14A12.8 12.8 0 0 1 12 20c-5 0-9.27-3.11-11-7.5a12.4 12.4 0 0 1 3.55-4.65L2 3.27zm7.55 7.55a3.5 3.5 0 0 0 4.96 4.96l-4.96-4.96zM12 4.5c5 0 9.27 3.11 11 7.5a12.5 12.5 0 0 1-3.3 4.46l-1.43-1.43A10.2 10.2 0 0 0 20.8 12c-1.62-3.16-4.77-5.5-8.8-5.5-.8 0-1.57.11-2.31.3L8.1 5.2A12.3 12.3 0 0 1 12 4.5z",
        "expand_more": "M7.41 8.59 12 13.17l4.59-4.58L18 10l-6 6-6-6z",
        "power": "M13 3h-2v10h2V3zm4.83 2.17-1.42 1.42A7 7 0 1 1 7.59 6.59L6.17 5.17A9 9 0 1 0 17.83 5.17z",
        "reboot": "M12 5V2L7 7l5 5V8c2.76 0 5 2.24 5 5 0 1.01-.3 1.95-.81 2.73l1.46 1.46A6.97 6.97 0 0 0 19 13c0-3.87-3.13-7-7-7zm-5 8c0-1.01.3-1.95.81-2.73L6.35 8.81A6.97 6.97 0 0 0 5 13c0 3.87 3.13 7 7 7v3l5-5-5-5v3c-2.76 0-5-2.24-5-5z",
        "bedtime": "M12 2a10 10 0 1 0 10 10c-5.52 0-10-4.48-10-10zm-1.2 3.1A7 7 0 0 0 17 18.4 8 8 0 0 1 10.8 5.1z",
        "login": "M10 17l5-5-5-5v3H3v4h7v3zm8-13H6a2 2 0 0 0-2 2v2h2V6h12v12H6v-2H4v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2z",
        "check": "M9 16.17 4.83 12 3.41 13.41 9 19l12-12-1.41-1.41z",
        "close": "M19 6.41 17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"
    })
    readonly property string path: icon.paths[icon.name] || ""

    implicitWidth: icon.size
    implicitHeight: icon.size
    width: icon.size
    height: icon.size

    // Локальные Material Symbols-пути рендерятся в MSAA-слое, как у ui/Icon.
    layer.enabled: icon.path.length > 0 && icon.width > 0 && icon.height > 0
    layer.samples: 8
    layer.smooth: true

    Shape {
        anchors.centerIn: parent
        width: 24
        height: 24
        scale: Math.min(icon.width, icon.height) / 24
        preferredRendererType: Shape.GeometryRenderer

        ShapePath {
            strokeWidth: 0
            strokeColor: "transparent"
            fillColor: icon.color

            PathSvg {
                path: icon.path
            }
        }
    }
}
