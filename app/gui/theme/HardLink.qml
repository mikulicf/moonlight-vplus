import QtQuick 2.9
import QtQuick.Controls
import "."

// Monospaced accent navigation link in brackets, brighter and underlined on hover.
// Keep actual actions as HardButton; matching 34-pixel heights align mixed rows.
Button {
    id: control

    readonly property Item __focusFrameTarget: null
    property bool prominent: false

    implicitHeight: 34
    padding: Theme.spaceXs
    spacing: 0

    opacity: control.enabled ? 1.0 : 0.45

    contentItem: Text {
        text: "[ " + control.text + " ]"
        color: control.hovered || control.visualFocus ? Theme.accentStrong : Theme.accent
        font.family: Theme.fontMono
        font.pointSize: Theme.fontBody + (control.prominent ? 1 : 0)
        font.underline: control.prominent || control.hovered || control.visualFocus
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    background: Rectangle {
        radius: 0
        color: "transparent"
        border.width: control.visualFocus ? 2 : 0
        border.color: Theme.accent
    }

    // Change only the pointer cursor; Button continues handling clicks.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        cursorShape: Qt.PointingHandCursor
    }
}
