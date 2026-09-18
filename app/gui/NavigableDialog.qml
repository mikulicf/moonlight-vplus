import QtQuick 2.0
import QtQuick.Controls
import StreamingPreferences 1.0

import "theme"

// Shared dialog shell: square Panel, hard shadow, left accent bar, and spaced uppercase title.
// Callers supply content and buttons.
Dialog {
    id: control

    modal: true
    anchors.centerIn: Overlay.overlay

    topPadding: Theme.spaceXl
    bottomPadding: Theme.spaceXl
    // Reserve extra left padding for the accent bar.
    leftPadding: Theme.spaceXl + Theme.accentBar
    rightPadding: Theme.spaceXl

    background: Panel {
        fill: Theme.surfaceLayer
        accentBarColor: Theme.accent
        accentBarWidth: Theme.accentBar
    }

    // Match wallpaper dimming with ink rather than default translucent black.
    Overlay.modal: Rectangle {
        color: Qt.rgba(Theme.ink.r, Theme.ink.g, Theme.ink.b, 0.66)
    }

    header: Item {
        // Untitled dialogs, including most message boxes, reserve no header height.
        visible: control.title !== ""
        implicitHeight: visible ? titleText.implicitHeight + Theme.spaceXl + Theme.spaceMd : 0

        Text {
            id: titleText

            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                leftMargin: control.leftPadding
                rightMargin: control.rightPadding
                topMargin: Theme.spaceLg
            }
            text: control.title
            color: Theme.text
            font.family: Theme.fontSans
            font.pointSize: Theme.fontCardTitle
            font.weight: Font.ExtraBold
            font.capitalization: Font.AllUppercase
            font.letterSpacing: Theme.tracking(Theme.fontCardTitle, 0.08)
            elide: Text.ElideRight
        }

        Rectangle {
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
                leftMargin: control.leftPadding
                rightMargin: control.rightPadding
            }
            height: 1
            color: Theme.line
            visible: parent.visible
        }
    }

    // Replace FluentWinUI3's rounded button-area background and pill buttons.
    // NavigableMessageDialog overrides this footer to support helpRequested.
    property QtObject standardButtonLabels: StandardButtonLabels {
        buttonBox: dialogButtonBox
        language: StreamingPreferences.language
        englishLanguage: StreamingPreferences.LANG_EN
    }

    footer: DialogButtonBox {
        id: dialogButtonBox

        visible: count > 0
        standardButtons: control.standardButtons

        onStandardButtonsChanged: Qt.callLater(function() { standardButtonLabels.apply() })

        padding: Theme.spaceXl
        topPadding: 0
        spacing: Theme.spaceSm
        alignment: Qt.AlignRight

        background: Item {}

        delegate: HardButton {
            Keys.onReturnPressed: clicked()
            Keys.onEnterPressed: clicked()
            Keys.onRightPressed: nextItemInFocusChain(true).forceActiveFocus(Qt.TabFocusReason)
            Keys.onLeftPressed: nextItemInFocusChain(false).forceActiveFocus(Qt.TabFocusReason)

            // Move upward only to a focusable item inside contentItem. Otherwise consume
            // the key, preventing message-box navigation from reaching behind the modal overlay.
            Keys.onUpPressed: {
                var prev = nextItemInFocusChain(false)
                for (var item = prev; item; item = item.parent) {
                    if (item === control.contentItem) {
                        prev.forceActiveFocus(Qt.TabFocusReason)
                        return
                    }
                }
            }
        }
    }

    onClosed: {
        // We must force focus back to the last item. If we don't,
        // gamepad and keyboard navigation will break after a
        // dialog appears.
        stackView.forceActiveFocus()
    }
}
