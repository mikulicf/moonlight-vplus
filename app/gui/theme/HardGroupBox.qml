import QtQuick 2.9
import QtQuick.Controls
import "."

// Square group: spaced uppercase accent title above a bordered surface with hard shadow and left bar.
//
// Preserve GroupBox's title-above-border layout to avoid style-dependent positioning.
// Use StyledText because legacy titles may contain bold/color markup.
GroupBox {
    id: control

    property font titleFont: Qt.font({
        family: Theme.fontSans,
        pointSize: Theme.fontCardTitle
    })

    topPadding: labelText.implicitHeight + Theme.spaceLg
    leftPadding: Theme.spaceLg
    rightPadding: Theme.spaceLg
    bottomPadding: Theme.spaceLg

    label: Text {
        id: labelText

        x: control.leftPadding
        width: control.availableWidth
        text: control.title
        textFormat: Text.StyledText
        color: Theme.accent
        font.family: control.titleFont.family
        font.pointSize: control.titleFont.pointSize
        font.weight: Font.ExtraBold
        font.capitalization: Font.AllUppercase
        font.letterSpacing: Theme.tracking(control.titleFont.pointSize, 0.08)
        elide: Text.ElideRight
    }

    background: Panel {
        fill: Theme.surfaceLayer
        y: control.topPadding - control.bottomPadding
        width: control.width
        height: control.height - control.topPadding + control.bottomPadding
        accentBarColor: Theme.accent
        accentBarWidth: Theme.accentBar
    }
}
