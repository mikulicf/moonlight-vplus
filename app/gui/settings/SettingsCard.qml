import QtQuick 2.9
import "../theme"

// Settings card: square panel, hard shadow, left accent bar, and spaced title; content is default.
//
// Replace the former translucent GlassCard and highlight gradient with an opaque square surface.
Item {
    id: card

    property string title: ""
    property string subtitle: ""
    default property alias cardContent: contentColumn.data

    // Hide the whole card when no applicable rows remain.
    //
    // Check explicit applicability, not effective visibility. Hiding a category makes
    // all child rows invisible; using visible here would then hide the card itself,
    // preventing those rows from becoming visible again when the category returns.
    readonly property bool hasVisibleContent: {
        for (var i = 0; i < contentColumn.children.length; i++) {
            var child = contentColumn.children[i]
            // Items without an applicable property, such as containers, count as content.
            if (child.applicable === undefined || child.applicable) {
                return true
            }
        }
        return false
    }

    width: parent ? parent.width : 0
    visible: hasVisibleContent
    height: visible ? implicitHeight : 0
    // Reserve shadow height so it cannot overlap the next card's top edge.
    implicitHeight: layout.implicitHeight + Theme.spaceLg * 2 + Theme.shadowOffset

    Panel {
        fill: Theme.surfaceLayer
        anchors {
            fill: parent
            // Keep the bottom-right shadow inside the scrolling area.
            rightMargin: Theme.shadowOffset
            bottomMargin: Theme.shadowOffset
        }

        accentBarColor: Theme.accent
        accentBarWidth: Theme.accentBar

        Column {
            id: layout
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: Theme.spaceLg
            }
            spacing: Theme.spaceMd

            Column {
                width: parent.width
                spacing: Theme.spaceXs
                visible: card.title !== ""

                Text {
                    text: card.title
                    color: Theme.accent
                    font.family: Theme.fontSans
                    font.pointSize: Theme.fontCardTitle
                    font.weight: Font.ExtraBold
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: Theme.tracking(Theme.fontCardTitle, 0.08)
                }

                Text {
                    width: parent.width
                    text: card.subtitle
                    visible: text !== ""
                    color: Theme.textSettingsSubtitle
                    font.family: Theme.fontSans
                    font.pointSize: Theme.fontSettingsSubtitle
                    font.weight: Font.Medium
                    wrapMode: Text.Wrap
                }
            }

            Column {
                id: contentColumn
                width: parent.width
                spacing: Theme.spaceSm
            }
        }
    }
}
