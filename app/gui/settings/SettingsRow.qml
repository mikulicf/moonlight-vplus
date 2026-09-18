import QtQuick 2.9
import QtQuick.Layouts 1.3
import "../theme"

// Settings row: title/description on the left and control on the right. FocusScope
// lets the row highlight whenever an internal control receives keyboard/gamepad focus.
FocusScope {
    id: row

    property string title: ""
    property string description: ""
    property real descriptionFontPointSize: Theme.fontSettingsSubtitle
    // Whether the row applies to this platform or feature configuration.
    property bool applicable: true
    readonly property bool stacked: width < Theme.settingsRowStackBreakpoint
    readonly property bool hoverable: controlSlot.children.length > 0

    default property alias controlContent: controlSlot.data

    width: parent ? parent.width : 0
    visible: applicable
    height: visible ? implicitHeight : 0
    implicitHeight: contentLayout.implicitHeight + Theme.spaceMd * 2

    // Square surface2 background on hover or focus; add a left accent bar for row focus.
    //
    // A row-wide border would nest with the control's own focus frame. Use a bar
    // to identify the focused row and a frame to identify the focused control.
    Rectangle {
        anchors.fill: parent
        radius: 0
        color: ((row.hoverable && hoverArea.containsMouse) || row.activeFocus)
               ? Theme.surface2 : "transparent"
        border.width: 0

        Rectangle {
            anchors {
                left: parent.left
                top: parent.top
                bottom: parent.bottom
            }
            width: row.activeFocus ? Theme.accentBar : 0
            visible: width > 0
            color: Theme.accent
        }

        Rectangle {
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            height: 1
            color: Theme.line
            // Separate rows with one-pixel lines, omitting the last to avoid a double card border.
            visible: row.parent && row.parent.children
                     && row.parent.children[row.parent.children.length - 1] !== row
        }

        Behavior on color {
            ColorAnimation { duration: Theme.durFast }
        }
    }

    MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
    }

    GridLayout {
        id: contentLayout

        anchors {
            fill: parent
            leftMargin: Theme.spaceMd
            rightMargin: Theme.spaceMd
            topMargin: Theme.spaceMd
            bottomMargin: Theme.spaceMd
        }
        columns: row.stacked ? 1 : 2
        columnSpacing: Theme.spaceLg
        rowSpacing: row.stacked ? Theme.spaceSm : 0

        Column {
            id: textColumn
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: Theme.spaceXs

            Text {
                width: parent.width
                text: row.title
                visible: text !== ""
                color: Theme.text
                font.family: Theme.fontSans
                font.pointSize: Theme.fontRowTitle
                font.weight: Font.DemiBold
                wrapMode: Text.Wrap
            }

            Text {
                width: parent.width
                text: row.description
                visible: text !== ""
                color: Theme.textSettingsSubtitle
                font.family: Theme.fontSans
                font.pointSize: row.descriptionFontPointSize
                font.weight: Font.Medium
                wrapMode: Text.Wrap
            }
        }

        Item {
            id: controlSlot
            Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
            Layout.preferredWidth: childrenRect.width
            implicitWidth: childrenRect.width
            implicitHeight: childrenRect.height
        }
    }
}
