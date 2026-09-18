import QtQuick 2.9
import QtQuick.Controls
import "."

// Square slider: four-pixel track and rectangular handle with a short hard shadow.
Slider {
    id: control

    // Replace FluentWinUI3's rounded focus rings with a square ring around the handle.
    readonly property Item __focusFrameTarget: null

    background: Rectangle {
        x: control.leftPadding
        y: control.topPadding + (control.availableHeight - height) / 2
        implicitWidth: 200
        implicitHeight: 4
        width: control.availableWidth
        height: 4

        radius: 0
        color: Theme.surface2
        border.width: 1
        border.color: Theme.line

        Rectangle {
            width: control.visualPosition * parent.width
            height: parent.height
            radius: 0
            color: control.enabled ? Theme.accent : Theme.textFaint
        }
    }

    handle: Item {
        x: control.leftPadding + control.visualPosition * (control.availableWidth - width)
        y: control.topPadding + (control.availableHeight - height) / 2
        implicitWidth: 12
        implicitHeight: 26

        Rectangle {
            x: 2
            y: 2
            width: parent.width
            height: parent.height
            color: Theme.shadowColor
        }

        Rectangle {
            anchors.fill: parent
            radius: 0
            color: control.pressed ? Theme.accentStrong : Theme.accent
            border.width: 1
            border.color: Theme.ink
            opacity: control.enabled ? 1.0 : 0.45
        }

        // The solid accent handle's border separates it from the track. Use an external
        // focus ring, matching HardCheckBox and HardSwitch.
        FocusRing {
            visible: control.visualFocus
        }
    }
}
