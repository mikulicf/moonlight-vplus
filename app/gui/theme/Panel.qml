import QtQuick 2.9
import "."

// Shared container: square corners, one-pixel border, hard offset shadow, and optional left bar.
//
// Simulate a hard shadow with an offset solid rectangle. Hover/focus lifts the
// panel three pixels up-left while lengthening its shadow, without scaling or blur.
Item {
    id: root

    property color fill: Theme.surface
    property color borderColor: Theme.line
    property int borderWidth: 1

    // Left accent bar; zero width disables it.
    property color accentBarColor: Theme.accent
    property int accentBarWidth: 0

    // Raised state moves the panel and lengthens the shadow.
    property bool lifted: false

    property real shadowDepth: lifted ? Theme.shadowOffsetLift : Theme.shadowOffset
    property real liftShift: lifted ? -3 : 0

    // Keep content to the right of the accent bar automatically.
    default property alias content: contentArea.data

    Behavior on shadowDepth {
        NumberAnimation { duration: Theme.durFast; easing.type: Theme.easing }
    }
    Behavior on liftShift {
        NumberAnimation { duration: Theme.durFast; easing.type: Theme.easing }
    }

    // Hard shadow: solid offset rectangle without blur.
    Rectangle {
        x: body.x + root.shadowDepth
        y: body.y + root.shadowDepth
        width: body.width
        height: body.height
        color: Theme.shadowColor
    }

    Rectangle {
        id: body

        x: root.liftShift
        y: root.liftShift
        width: root.width
        height: root.height

        radius: 0
        color: root.fill
        border.width: root.borderWidth
        border.color: root.borderColor

        Behavior on color {
            ColorAnimation { duration: Theme.durNormal }
        }
        Behavior on border.color {
            ColorAnimation { duration: Theme.durFast }
        }

        Rectangle {
            anchors {
                left: parent.left
                top: parent.top
                bottom: parent.bottom
            }
            width: root.accentBarWidth
            visible: width > 0
            color: root.accentBarColor
        }

        Item {
            id: contentArea
            anchors {
                fill: parent
                leftMargin: root.accentBarWidth
            }
        }
    }
}
