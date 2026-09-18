import QtQuick 2.9
import QtQuick.Controls
import "."
import "../theme"

// The caller writes preferences in onToggled. Avoid two-way checked binding that
// could overwrite saved values while initialization restores them.
SettingsRow {
    id: toggleRow

    property alias checked: control.checked
    property alias controlEnabled: control.enabled
    property alias tooltip: tip.text

    signal toggled(bool value)

    HardSwitch {
        id: control
        hoverEnabled: true
        // Report only user interaction. Restoring checked also emits checkedChanged,
        // whereas Switch.toggled() excludes initialization and programmatic changes.
        onToggled: toggleRow.toggled(checked)

        ToolTip {
            id: tip
            visible: text !== "" && control.hovered
            delay: 800
            timeout: 8000
        }
    }
}
