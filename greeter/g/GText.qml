import QtQuick

Text {
    id: root

    property string role: "body"
    property color roleColor: Theme.text

    color: roleColor
    font.family: Theme.fontFamily
    font.pixelSize: {
        switch (root.role) {
        case "display": return Theme.fontDisplayLarge;
        case "headline": return Theme.fontHeadlineLarge;
        case "title": return Theme.fontTitleLarge;
        case "label": return Theme.fontLabelLarge;
        case "bodySmall": return Theme.fontBodySmall;
        default: return Theme.fontBodyLarge;
        }
    }
    font.weight: root.role === "label" ? Theme.weightLabel
        : (root.role === "bodySmall" ? Theme.weightBody : Theme.weightMedium)
    wrapMode: Text.Wrap
}
