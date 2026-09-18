import QtQuick 2.9
import QtQuick.Controls

import "."

// Square TextField with a one-pixel frame and accent focus border instead of
// FluentWinUI3's rounded background and thick underline.
//
// Monospaced tabular numbers suit numeric values and IP addresses without shifting while typing.
TextField {
    id: control

    color: Theme.text
    placeholderTextColor: Theme.textFaint
    selectByMouse: true

    font.family: Theme.fontMono
    font.pointSize: Theme.fontBody

    leftPadding: Theme.spaceSm
    rightPadding: Theme.spaceSm
    topPadding: Theme.spaceXs
    bottomPadding: Theme.spaceXs

    background: Rectangle {
        implicitWidth: 120
        implicitHeight: 32

        radius: 0
        color: Theme.ink
        // Use activeFocus, including mouse focus, because the caret identifies the active field.
        // Focus uses two-pixel accent; hover uses one-pixel lineStrong.
        border.width: control.activeFocus ? 2 : 1
        border.color: control.activeFocus ? Theme.accent
                                          : (control.hovered ? Theme.lineStrong : Theme.line)

        Behavior on border.color {
            ColorAnimation { duration: Theme.durFast }
        }
    }
}
