import QtQuick 2.9
import QtQuick.Controls
import "."

// Square switch with a rectangular track and thumb, moving without bounce.
Switch {
    id: control

    font.family: Theme.fontSans
    implicitWidth: 44
    implicitHeight: 22
    padding: 0
    spacing: 0

    // Replace FluentWinUI3's rounded focus rings with the square FocusRing below.
    readonly property Item __focusFrameTarget: null

    function commitPointerToggle() {
        if (!control.enabled) {
            return
        }

        var previousChecked = control.checked
        control.toggle()
        if (control.checked !== previousChecked) {
            control.toggled()
        }
    }

    indicator: Rectangle {
        id: track
        implicitWidth: 44
        implicitHeight: 22
        x: control.text ? control.leftPadding
                        : control.leftPadding + (control.availableWidth - width) / 2
        y: control.topPadding + (control.availableHeight - height) / 2

        radius: 0
        color: control.checked ? Theme.accent : Theme.surface2
        border.width: 1
        border.color: !control.enabled ? Theme.line
                    : control.checked ? Theme.accent
                    : (control.hovered ? Theme.accent : Theme.lineStrong)
        opacity: control.enabled ? 1.0 : 0.45

        // On-state accent fill and border already express state; use an external focus ring.
        FocusRing {
            visible: control.visualFocus
        }

        Behavior on color {
            ColorAnimation { duration: Theme.durFast }
        }

        Rectangle {
            id: handle
            y: 3
            x: 3 + (pointerArea.dragging ? pointerArea.dragPosition
                                         : control.visualPosition) * (parent.width - width - 6)
            width: 16
            height: parent.height - 6
            radius: 0
            color: control.checked ? Theme.ink : Theme.textDim

            Behavior on x {
                enabled: !pointerArea.pressed && !control.down
                NumberAnimation { duration: Theme.durFast; easing.type: Theme.easing }
            }
        }

        // Own the pointer gesture on the painted track. This avoids the
        // FluentWinUI3 Switch regression where a stationary release is ignored,
        // while retaining both tap-to-toggle and drag-to-select behavior.
        //
        // Pointer handling must change state and emit toggled() so ToggleRow saves it.
        // checkedChanged also fires during restoration and cannot replace user-only toggled().
        // Avoid AbstractButton.click(), which requires Qt 6.8 and breaks older toolchains.
        MouseArea {
            id: pointerArea
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            cursorShape: Qt.PointingHandCursor

            property real pressStartX: 0
            property real dragPosition: control.visualPosition
            property real dragOffset: 0
            property bool dragging: false

            onPressed: function(mouse) {
                pressStartX = mouse.x
                dragPosition = control.visualPosition
                var travel = width - handle.width - 6
                var handleCenter = 3 + handle.width / 2 + dragPosition * travel
                dragOffset = mouse.x - handleCenter
                dragging = false
                control.forceActiveFocus(Qt.MouseFocusReason)
            }
            onPositionChanged: function(mouse) {
                if (!pressed) {
                    return
                }
                if (Math.abs(mouse.x - pressStartX) >= 4) {
                    dragging = true
                }
                if (dragging) {
                    var travel = width - handle.width - 6
                    dragPosition = Math.max(0, Math.min(1,
                        (mouse.x - dragOffset - 3 - handle.width / 2) / travel))
                }
            }
            onReleased: function() {
                if (dragging) {
                    // Commit only if dragging changes sides; returning to the original side is a no-op.
                    var targetChecked = dragPosition >= 0.5
                    if (targetChecked !== control.checked) {
                        control.commitPointerToggle()
                    }
                } else {
                    control.commitPointerToggle()
                }
                dragging = false
            }
            onCanceled: dragging = false
        }
    }
}
