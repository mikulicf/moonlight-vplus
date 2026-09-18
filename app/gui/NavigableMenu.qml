import QtQuick 2.0
import QtQuick.Controls

import "theme"

Menu {
    id: control

    property var initiator

    padding: Theme.spaceXs

    // Square border and hard shadow, without a left bar competing with item hover emphasis.
    background: Panel {
        implicitWidth: 200
        fill: Theme.surfaceLayer
    }

    onOpened: {
        // If the initiating object currently has keyboard focus,
        // give focus to the first visible and enabled menu item
        if (initiator && initiator.focus) {
            for (var i = 0; i < count; i++) {
                var item = itemAt(i)
                if (item.visible && item.enabled) {
                    item.forceActiveFocus(Qt.TabFocusReason)
                    break
                }
            }
        }
    }
}
