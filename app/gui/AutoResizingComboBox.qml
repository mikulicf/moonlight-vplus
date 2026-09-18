import QtQuick 2.9
// Overlay is used to measure available popup height and requires QtQuick.Controls 2.3+.
import QtQuick.Controls
import QtQuick.Window 2.2

import SdlGamepadKeyNavigation 1.0

import "theme"

// https://stackoverflow.com/questions/45029968/how-do-i-set-the-combobox-width-to-fit-the-largest-item
ComboBox {
    id: control

    // Replace FluentWinUI3's rounded white focus rings with the two-pixel accent border.
    // See theme/FocusRing.qml.
    readonly property Item __focusFrameTarget: null

    property int textWidth

    // Include control padding, arrow width, and contentItem's own padding when measuring.
    // Omitting TextField padding clips labels near the width boundary. Always reserve
    // arrow space: FluentWinUI3's indicator visibility changes during binding evaluation,
    // making rightPadding alone unreliable.
    property int desiredWidth: textWidth + leftPadding + rightPadding + indicator.width
                               + (contentItem ? contentItem.leftPadding + contentItem.rightPadding : 0)
    property int maximumWidth : parent.width

    implicitWidth: desiredWidth < maximumWidth ? desiredWidth : maximumWidth

    // Observe model and font changes directly. Measuring only on activation left hidden
    // settings categories at zero width when their initialization handlers returned early.
    // Callers no longer need to trigger activation just to establish width.
    onCountChanged: recalculateWidth()
    onFontChanged: recalculateWidth()

    TextMetrics {
        id: popupMetrics
    }

    TextMetrics {
        id: textMetrics
    }

    function recalculateWidth() {
        textMetrics.font = font
        popupMetrics.font = popup.font
        textWidth = 0
        for (var i = 0; i < count; i++){
            textMetrics.text = textAt(i)
            popupMetrics.text = textAt(i)
            textWidth = Math.max(textMetrics.width, textWidth)
            textWidth = Math.max(popupMetrics.width, textWidth)
        }
    }

    // We call this every time the options change (and init)
    // so we can adjust the combo box width here too
    onActivated: recalculateWidth()

    // Up/down focus targets while the popup is closed.
    //
    // Default up/down selection can trap focus and silently change values in dialogs.
    // If either target is configured, both directions navigate instead: move to a target
    // when present and consume the key at a boundary.
    //
    // With neither target, preserve normal keyboard value changes. Settings gamepad
    // navigation generates Tab/Shift+Tab, so it does not reach these direction handlers.
    property Item navUpItem: null
    property Item navDownItem: null

    readonly property bool arrowNavigation: navUpItem !== null || navDownItem !== null

    // When expanded, pass up/down to ComboBox's list navigation.
    Keys.onUpPressed: function(event) {
        if (popup.opened || !arrowNavigation) {
            event.accepted = false
            return
        }
        if (navUpItem) {
            navUpItem.forceActiveFocus(Qt.TabFocusReason)
        }
    }

    Keys.onDownPressed: function(event) {
        if (popup.opened || !arrowNavigation) {
            event.accepted = false
            return
        }
        if (navDownItem) {
            navDownItem.forceActiveFocus(Qt.TabFocusReason)
        }
    }

    // Left/right must not silently change the selected value.
    //
    // Require an explicit gamepad selection: A opens the list, up/down selects,
    // A confirms, and B cancels. This prevents horizontal settings navigation from
    // changing resolution or codec (issue #144). Keyboard up/down remains available.
    //
    // Consume left/right in an open vertical list. Otherwise pass them upward for focus
    // navigation; QML key handlers accept events by default unless explicitly released.
    Keys.onLeftPressed: function(event) {
        event.accepted = popup.opened
    }

    Keys.onRightPressed: function(event) {
        event.accepted = popup.opened
    }

    // Replace FluentWinUI3's rounded background for all settings ComboBoxes.
    //
    // Keep contentItem and indicator intact: desiredWidth depends on their padding and size.
    background: Rectangle {
        implicitWidth: 120
        implicitHeight: 34

        radius: 0
        color: control.pressed ? Theme.surface : Theme.surface2
        // Distinguish hover (one-pixel strong line) from focus (two-pixel accent).
        border.width: control.visualFocus ? 2 : 1
        border.color: control.visualFocus ? Theme.accent
                                          : (control.hovered ? Theme.accent : Theme.lineStrong)

        Behavior on border.color {
            ColorAnimation { duration: Theme.durFast }
        }
    }

    // Compute popup height from item count and row height. Lazy ListView delegates
    // make contentHeight incomplete during aboutToShow, causing undersized short lists.
    readonly property int popupItemHeight: 34

    // Replace FluentWinUI3's rounded translucent popup and capsule selection markers.
    //
    // Use Panel's square border and hard shadow, with an accent border to show elevation.
    delegate: ItemDelegate {
        id: comboItem

        width: ListView.view ? ListView.view.width : control.width
        height: control.popupItemHeight
        highlighted: control.highlightedIndex === index

        // Let ComboBox resolve textRole consistently for JS arrays, QVariantList,
        // and ListModel without relying on their QML wrapper types.
        readonly property string itemText: control.textAt(index)

        contentItem: Text {
            leftPadding: Theme.spaceSm
            rightPadding: Theme.spaceSm
            text: comboItem.itemText
            // Match the font used by recalculateWidth(); changing it here would clip long labels.
            font: control.font
            color: comboItem.highlighted ? Theme.text : Theme.textDim
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }

        background: Rectangle {
            radius: 0
            color: comboItem.highlighted ? Theme.surface2 : "transparent"

            // Use a thick accent bar for the current item, matching the category rail.
            Rectangle {
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                width: control.currentIndex === index ? Theme.accentBar : 0
                visible: width > 0
                color: Theme.accent
            }
        }
    }

    popup: Popup {
        id: comboPopup

        // Recalculate available height on every opening because the settings page scrolls.
        // A binding alone may retain coordinates from before scrolling.
        property real maxHeight: 320
        // Use item-count height regardless of layout progress, then allow a larger
        // actual contentHeight in case a delegate exceeds the standard row height.
        readonly property real wantedHeight:
            Math.max(control.count * control.popupItemHeight,
                     contentItem ? contentItem.contentHeight : 0) + topPadding + bottomPadding

        y: control.height
        width: control.width
        implicitHeight: Math.min(wantedHeight, maxHeight)

        // Set every padding and inset explicitly: FluentWinUI3's individual values
        // override grouped padding and can shrink content or misalign the Panel.
        topPadding: 1
        bottomPadding: 1
        leftPadding: 1
        rightPadding: 1
        topInset: 0
        bottomInset: 0
        leftInset: 0
        rightInset: 0

        // Suspend UI navigation while open so gamepad up/down sends actual direction
        // keys rather than Tab/Shift+Tab, which cannot navigate the dropdown list.
        //
        // Use a suspension count rather than restoring a saved mode. PcView/AppView
        // use normal navigation, and settings-page transitions can change mode while
        // a popup is closing. A count borrows direction keys without overwriting
        // the page's current navigation policy.
        onAboutToShow: {
            SdlGamepadKeyNavigation.suspendUiNavMode()

            // Obtain coordinates and window height through Overlay. Accessing
            // control.Window.height from JS throws TypeError and leaves stale sizing.
            var overlay = Overlay.overlay
            var winHeight = overlay ? overlay.height : 720
            var scenePos = control.mapToItem(overlay, 0, 0)

            var below = winHeight - scenePos.y - control.height - Theme.spaceSm
            var above = scenePos.y - Theme.spaceSm

            // Open below when it fits, or above when more space is available there.
            // Scroll only when neither side can fit the complete list.
            if (wantedHeight <= below || below >= above) {
                maxHeight = Math.max(below, control.popupItemHeight * 3)
                y = control.height
            }
            else {
                maxHeight = Math.max(above, control.popupItemHeight * 3)
                y = -Math.min(wantedHeight, maxHeight)
            }
        }

        onAboutToHide: {
            SdlGamepadKeyNavigation.resumeUiNavMode()
        }

        // Allow the hard shadow to extend beyond the popup onto the page.
        background: Panel {
            fill: Theme.surfaceLayer
            borderColor: Theme.accent
        }

        contentItem: ListView {
            clip: true
            implicitHeight: contentHeight
            model: control.delegateModel
            currentIndex: control.highlightedIndex

            ScrollIndicator.vertical: ScrollIndicator {}
        }
    }
}
