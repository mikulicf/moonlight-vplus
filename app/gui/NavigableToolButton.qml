import QtQuick 2.0
import QtQuick.Controls
import QtQuick.Layouts 1.3

import "theme"

ToolButton {
    id: control

    property string iconSource

    // Fluent 24 Regular toolbar icons match the category rail. Render at their intended
    // 24-pixel size; scaling line icons to 40 pixels looks thin and crowds the 56-pixel bar.
    property int iconSize: 24

    activeFocusOnTab: true

    // Replace FluentWinUI3's rounded white focus rings with the two-pixel accent border.
    // See theme/FocusRing.qml.
    readonly property Item __focusFrameTarget: null

    icon.source: iconSource
    icon.width: iconSize
    icon.height: iconSize

    // Tint icons consistently with textDim, brightening to text on hover or focus.
    icon.color: (control.hovered || control.visualFocus || control.down)
                ? Theme.text : Theme.textDim

    // Square background and border; pressed state uses accentSoft without scaling or blur.
    // No idle border, one-pixel accent on hover, and two-pixel accent on focus.
    background: Rectangle {
        radius: 0
        color: control.down ? Theme.accentSoft
                            : (control.hovered ? Theme.surface2 : "transparent")
        border.width: control.visualFocus ? 2 : (control.hovered ? 1 : 0)
        border.color: Theme.accent

        Behavior on color {
            ColorAnimation { duration: Theme.durFast }
        }
    }

    // This determines the size of the focus/hover highlight. We increase it
    // from the default because we use larger than normal icons for TV readability.
    Layout.preferredHeight: parent.height

    Keys.onReturnPressed: {
        clicked()
    }

    Keys.onEnterPressed: {
        clicked()
    }

    Keys.onRightPressed: {
        nextItemInFocusChain(true).forceActiveFocus(Qt.TabFocusReason)
    }

    Keys.onLeftPressed: {
        nextItemInFocusChain(false).forceActiveFocus(Qt.TabFocusReason)
    }
}
