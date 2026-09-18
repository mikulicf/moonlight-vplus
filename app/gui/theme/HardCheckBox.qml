import QtQuick 2.9
import QtQuick.Controls
import "."

// Override only the checkbox indicator, preserving base text layout and wrapping
// for long descriptions in settings.
CheckBox {
    id: control

    font.family: Theme.fontSans

    // Replace FluentWinUI3's rounded focus rings with the square FocusRing below.
    readonly property Item __focusFrameTarget: null

    // Implement pointer toggling without AbstractButton.click(), introduced in Qt 6.8.
    // Older Qt toolchains, including Steam Link, cannot call it.
    //
    // Emit toggled() only when state changes, but always emit clicked(), matching
    // the base label-click path for current and future callers.
    function commitPointerToggle() {
        if (!control.enabled) {
            return
        }

        var previousChecked = control.checked
        control.toggle()
        if (control.checked !== previousChecked) {
            control.toggled()
        }
        control.clicked()
    }

    indicator: Rectangle {
        implicitWidth: 18
        implicitHeight: 18
        x: control.leftPadding
        y: control.topPadding + (control.availableHeight - height) / 2

        radius: 0
        color: control.checked ? Theme.accent : Theme.surface2
        border.width: 1
        border.color: !control.enabled ? Theme.line
                    : control.checked ? Theme.accent
                    : (control.hovered ? Theme.accent : Theme.lineStrong)
        opacity: control.enabled ? 1.0 : 0.45

        // Checked state already uses an accent border/fill, so show keyboard/gamepad
        // focus with an external ring. Mouse clicks should not display it.
        FocusRing {
            visible: control.visualFocus
        }

        // Own clicks on the painted box. FluentWinUI3 can ignore a stationary
        // release on a replaced indicator, which makes a normal click appear
        // to work only after several attempts. Keep the base CheckBox behavior
        // for its label, keyboard navigation, and accessibility.
        MouseArea {
            anchors.fill: parent
            anchors.margins: -6
            enabled: control.enabled
            acceptedButtons: Qt.LeftButton
            cursorShape: Qt.PointingHandCursor

            onPressed: control.forceActiveFocus(Qt.MouseFocusReason)
            onClicked: control.commitPointerToggle()
        }

        Behavior on color {
            ColorAnimation { duration: Theme.durFast }
        }

        // Construct the checkmark from rotated solid lines rather than a fallback-font
        // glyph or Canvas, whose repaint on visibility changes is not guaranteed.
        Item {
            anchors.fill: parent
            opacity: control.checked ? 1 : 0

            Behavior on opacity {
                NumberAnimation { duration: Theme.durFast; easing.type: Theme.easing }
            }

            Rectangle {
                x: parent.width * 0.26
                y: parent.height * 0.52
                width: parent.width * 0.30
                height: 2
                radius: 0
                color: Theme.ink
                transformOrigin: Item.Left
                rotation: 45
            }

            Rectangle {
                x: parent.width * 0.35
                y: parent.height * 0.68
                width: parent.width * 0.52
                height: 2
                radius: 0
                color: Theme.ink
                transformOrigin: Item.Left
                rotation: -50
            }
        }
    }
}
