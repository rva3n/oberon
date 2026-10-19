pragma Singleton
import QtQuick

QtObject {
    // Самостоятельная копия тёмных M3-токенов Oberon: без Theme/Prefs и файлов
    // из домашнего каталога. Цвета взяты из тёмных значений core/Theme.qml.
    readonly property color background: "#111318"
    readonly property color surface: "#1d2024"
    readonly property color surfaceLow: "#191c20"
    readonly property color surfaceHigh: "#282a2f"
    readonly property color surfaceHighest: "#33353a"
    readonly property color text: "#e2e2e9"
    readonly property color subtext: "#c4c6d0"
    readonly property color subtextDim: "#8e9099"
    readonly property color outline: "#8e9099"
    readonly property color outlineVariant: "#44474f"
    readonly property color accent: "#a8c7fa"
    readonly property color fgAccent: "#062e6f"
    readonly property color accentContainer: "#0842a0"
    readonly property color fgAccentContainer: "#d3e3fd"
    readonly property color secondary: "#bec6dc"
    readonly property color fgSecondary: "#283141"
    readonly property color error: "#ffb4ab"
    readonly property color errorContainer: "#93000a"
    readonly property color fgErrorContainer: "#ffdad6"
    readonly property color scrim: "#000000"
    readonly property color card: "#282a2f"

    // core/Theme.qml использует Google Sans Flex, если он доступен, иначе Noto Sans.
    // В greetd нет пользовательского HOME с установленным шрифтом, поэтому здесь
    // сразу используется тот же системный fallback.
    readonly property string fontFamily: "Noto Sans"
    readonly property int fontLabel: 11
    readonly property int fontBody: 12
    readonly property int fontTitle: 13
    readonly property int fontHeadline: 15
    readonly property int fontDisplayLarge: 52
    readonly property int fontDisplayMedium: 42
    readonly property int fontDisplaySmall: 32
    readonly property int fontHeadlineLarge: 30
    readonly property int fontHeadlineMedium: 26
    readonly property int fontHeadlineSmall: 22
    readonly property int fontTitleLarge: 19
    readonly property int fontTitleMedium: 16
    readonly property int fontTitleSmall: 14
    readonly property int fontBodyLarge: 15
    readonly property int fontBodyMedium: 13
    readonly property int fontBodySmall: 12
    readonly property int fontLabelLarge: 13
    readonly property int fontLabelMedium: 12
    readonly property int fontLabelSmall: 11

    readonly property int weightBody: 420
    readonly property int weightLabel: 560
    readonly property int weightMedium: 500

    readonly property int radiusXs: 8
    readonly property int radiusSm: 12
    readonly property int radiusMd: 16
    readonly property int radiusLg: 20
    readonly property int radiusXl: 28
    readonly property int radiusXlInc: 32
    readonly property int radiusXxl: 48
    readonly property int radiusPill: 999

    readonly property int durQuick: 120
    readonly property int durShort: 180
    readonly property int durMedium: 280
    readonly property int durLong: 400
    readonly property int durEnter: 320
    readonly property int durExit: 190
    readonly property int easeStandard: Easing.OutCubic
    readonly property real stateHover: 0.08
    readonly property real stateFocus: 0.1
    readonly property real statePressed: 0.1
}
