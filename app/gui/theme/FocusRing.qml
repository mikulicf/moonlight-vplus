import QtQuick 2.9
import "."

// Shared square, two-pixel accent focus ring, extending three pixels beyond its target.
//
// FluentWinUI3 normally adds a rounded white/black double focus frame. Its
// three-pixel outer and one-pixel inner rings conflict with the application's
// square borders and produce inconsistent focus treatments across controls.
//
// Disable it by shadowing the style's target properties with null:
//
//     readonly property Item __focusFrameTarget: null
//
// Qt's own FluentWinUI3/SearchField.qml uses this technique. We then provide focus as follows:
//
// Controls with a free border (buttons, ComboBox, TextField) use a two-pixel accent
// border, distinct from one-pixel hover. Controls whose borders already express
// state (checkbox, switch, slider) use this external ring instead.
Rectangle {
    // Distance between the target and the outer ring.
    property int inset: 3

    anchors.fill: parent
    anchors.margins: -inset

    z: 10
    radius: 0
    color: "transparent"
    border.width: 2
    border.color: Theme.accent

    // A one-pixel ink separator keeps the accent ring distinct from solid accent
    // or lime controls, including selected checkboxes, switches, and display chips.
    Rectangle {
        anchors.fill: parent
        anchors.margins: parent.border.width
        radius: 0
        color: "transparent"
        border.width: 1
        border.color: Theme.ink
    }
}
