import QtQuick
import Quickshell

ShellRoot {
    Variants {
        model: Quickshell.screens
        delegate: Greeter {
            screen: modelData
        }
    }
}
