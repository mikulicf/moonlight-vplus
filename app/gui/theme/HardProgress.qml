import QtQuick

import "."

// Indeterminate progress bar with advancing diagonal stripes.
//
// Uniformly spaced stripes move left to right to communicate forward progress
// more clearly than a bouncing block or battery-like segments.
//
// Keep stripes thin and translucent with a one-pixel baseline. A large opaque
// lime bar would dominate a loading page that is only a transitional state.
//
// Shear stripes with Matrix4x4 rather than rotating them: this creates exact
// parallelograms without angled endpoints or extra width compensation.
Item {
    id: root

    property color barColor: Theme.acid
    property color trackColor: Theme.line

    // When stopped, retain dim stripes to show an inactive instrument, as with mDNS disabled.
    property bool running: true

    property int stripeWidth: 10
    property int stripeGap: 8
    // Horizontal offset of the top edge relative to the bottom: slant * height.
    property real slant: 0.9

    readonly property int pitch: stripeWidth + stripeGap

    implicitHeight: 12

    // Track background.
    Rectangle {
        anchors.fill: parent
        color: root.trackColor
        opacity: 0.35
    }

    Item {
        id: viewport

        anchors.fill: parent
        clip: true

        // Animate one stripe pitch then wrap. Equal spacing makes the loop seamless.
        property real phase: 0

        NumberAnimation on phase {
            running: root.running && root.visible
            loops: Animation.Infinite
            from: 0
            to: root.pitch
            duration: 520
        }

        Repeater {
            // Add a stripe beyond each side so shear and movement never expose an empty edge.
            //
            // Use root.width/root.height; Repeater's own zero size would produce only two stripes.
            model: Math.ceil((root.width + root.slant * root.height) / root.pitch) + 2

            Rectangle {
                x: (index - 1) * root.pitch + viewport.phase
                width: root.stripeWidth
                height: viewport.height
                color: root.running ? root.barColor : root.trackColor
                opacity: root.running ? 0.9 : 0.45

                transform: Matrix4x4 {
                    // x' = x + slant * (height - y): fixed bottom, top shifted right
                    // in the direction of travel.
                    matrix: Qt.matrix4x4(1, -root.slant, 0, root.slant * viewport.height,
                                         0,  1,          0, 0,
                                         0,  0,          1, 0,
                                         0,  0,          0, 1)
                }
            }
        }
    }

    // Keep the track baseline visible even when progress is inactive.
    Rectangle {
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
        height: 1
        color: root.trackColor
    }
}
