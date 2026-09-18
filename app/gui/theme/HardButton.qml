import QtQuick 2.9
import QtQuick.Controls
import "."

// Square button with hard shadow. Override only the background, preserving the
// base contentItem's icon and text layout.
Button {
    id: control

    property bool primary: false

    font.family: Theme.fontSans
    font.bold: true
    palette.buttonText: primary ? Theme.ink : Theme.text

    // Replace FluentWinUI3's rounded focus rings with the two-pixel accent border.
    // See FocusRing.qml.
    readonly property Item __focusFrameTarget: null

    background: Panel {
        implicitWidth: 96
        implicitHeight: 34

        fill: control.primary
              ? (control.down ? Theme.accentDim
                              : (control.hovered ? Theme.accentStrong : Theme.accent))
              : (control.down ? Theme.accentDim
                              : (control.hovered ? Theme.surface2 : Theme.surface))
        // Distinguish hover/press with a one-pixel accent border and focus with two pixels.
        borderColor: control.primary
                     ? Theme.ink
                     : (control.down || control.hovered || control.visualFocus
                        ? Theme.accent : Theme.lineStrong)
        borderWidth: control.visualFocus ? 2 : 1
        // Smaller buttons need shallower shadows to avoid merging into dark blocks.
        shadowDepth: control.down ? 2 : (control.hovered || control.visualFocus ? 6 : 4)
        liftShift: control.down ? 1 : 0
        opacity: control.enabled ? 1.0 : 0.45
    }
}
