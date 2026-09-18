import QtQuick 2.9
import QtQuick.Controls

import "theme"

// Shared address selector for PcView and AppView. Both models expose address, port,
// display, type, isActive, and isTested. Parameterize the prompt and Automatic entry.
//
// Emit addressSelected and let each caller apply its own model's address-selection API.
NavigableDialog {
    id: control

    // Entries provide address/port/display/type/isActive. Missing isTested means verified;
    // isAuto marks a synthetic Automatic entry without a concrete address.
    property var addresses: []

    // Caller-supplied prompt above the list; PcView includes the hostname.
    property string promptText: ""

    signal addressSelected(var address)

    // Preselect the model's isActive entry: Automatic when unpinned, otherwise the pinned address.
    readonly property int activeIndex: {
        for (var i = 0; i < addresses.length; i++) {
            if (addresses[i].isActive) {
                return i
            }
        }
        return 0
    }

    readonly property var currentAddress:
        addressCombo.currentIndex >= 0 && addressCombo.currentIndex < addresses.length
            ? addresses[addressCombo.currentIndex]
            : null

    readonly property bool hasAutoEntry: {
        for (var i = 0; i < addresses.length; i++) {
            if (addresses[i].isAuto) {
                return true
            }
        }
        return false
    }

    title: qsTr("Select Connection IP")
    standardButtons: DialogButtonBox.Ok | DialogButtonBox.Cancel
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    // Set width explicitly to avoid a binding loop with the Column's availableWidth.
    width: Math.max(320, Math.min(560, parent ? parent.width - 80 : 480))

    onOpened: {
        addressCombo.currentIndex = activeIndex

        // The address dropdown is the only focusable content item. These pages send real
        // gamepad direction keys, so override up/down to reach the standard dialog buttons
        // instead of silently changing addresses. Resolve buttons after dialog creation.
        addressCombo.navDownItem = standardButton(DialogButtonBox.Ok)
        addressCombo.forceActiveFocus(Qt.TabFocusReason)
    }

    onAccepted: {
        if (control.currentAddress) {
            control.addressSelected(control.currentAddress)
        }
    }

    Column {
        width: control.availableWidth
        spacing: Theme.spaceMd

        Text {
            width: parent.width
            text: control.promptText
            color: Theme.text
            font.family: Theme.fontSans
            font.pointSize: Theme.fontRowTitle
            font.weight: Font.DemiBold
            wrapMode: Text.Wrap
        }

        // AutoResizingComboBox supplies the shared square control and popup styling.
        AutoResizingComboBox {
            id: addressCombo
            width: parent.width
            maximumWidth: parent.width
            popup.width: width
            model: control.addresses
            textRole: "display"
        }

        // Use monospace for address-type and verification status information.
        Text {
            width: parent.width
            visible: control.currentAddress !== null
            // Guard currentAddress directly. A visible binding may update after text,
            // allowing null access if it is used as an indirect guard.
            text: control.currentAddress ? qsTr("Type: %1").arg(control.currentAddress.type) : ""
            color: Theme.textDim
            font.family: Theme.fontMono
            font.pointSize: Theme.fontBody
            wrapMode: Text.Wrap
        }

        Text {
            width: parent.width
            // Treat missing isTested as verified so callers without the field show no warning.
            visible: control.currentAddress !== null
                     && !control.currentAddress.isAuto
                     && control.currentAddress.isTested === false
            text: qsTr("Warning: This address has not been verified by polling yet.")
            color: Theme.danger
            font.family: Theme.fontMono
            font.pointSize: Theme.fontCaption
            wrapMode: Text.Wrap
        }

        Text {
            width: parent.width
            visible: control.hasAutoEntry
            text: qsTr("\"Auto\" uses the default address selection with automatic fallback. Selecting a specific IP will pin the connection to that address.")
            color: Theme.textFaint
            font.family: Theme.fontMono
            font.pointSize: Theme.fontCaption
            wrapMode: Text.Wrap
        }
    }
}
