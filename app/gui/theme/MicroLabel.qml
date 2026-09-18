import QtQuick 2.9
import "."

// Uppercase micro-label with monospace text, 0.2em spacing, and secondary color
// complements the square industrial visual style.
Text {
    id: root

    // Tabular monospace digits prevent shifting.
    font.family: Theme.fontMono
    font.pointSize: Theme.fontCaption
    font.capitalization: Font.AllUppercase
    font.letterSpacing: Theme.trackingCaption
    color: Theme.textDim
    elide: Text.ElideRight
    verticalAlignment: Text.AlignVCenter
}
