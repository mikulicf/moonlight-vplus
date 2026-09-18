import QtQuick 2.0
import QtQuick.Controls

import ComputerManager 1.0

import "theme"

Item {
    function onSearchingComputer() {
        stageLabel.text = qsTr("Establishing connection to PC...")
    }

    function onPairing(pcName, pin) {
        stageLabel.text = qsTr("Pairing... Please enter '%1' on %2.").arg(pin).arg(pcName)
    }

    function onFailed(message) {
        stageIndicator.visible = false
        errorDialog.text = message
        errorDialog.open()
    }

    function onSuccess(appName) {
        stageIndicator.visible = false
        pairCompleteDialog.open()
    }

    // Allow user to back out of pairing
    Keys.onEscapePressed: {
        Qt.quit()
    }
    Keys.onBackPressed: {
        Qt.quit()
    }
    Keys.onCancelPressed: {
        Qt.quit()
    }

    StackView.onActivated: {
        if (!launcher.isExecuted()) {
            toolBar.shown = false

            launcher.searchingComputer.connect(onSearchingComputer)
            launcher.pairing.connect(onPairing)
            launcher.failed.connect(onFailed)
            launcher.success.connect(onSuccess)
            launcher.execute(ComputerManager)
        }
    }

    // Match stream loading/exit pages: left-aligned Manrope 800 stage text and a striped bar.
    Column {
        id: stageIndicator
        anchors.centerIn: parent
        width: Math.min(parent.width - Theme.spaceXl * 2, 620)
        spacing: Theme.spaceLg

        Text {
            id: stageLabel

            width: parent.width
            color: Theme.text
            font.family: Theme.fontSans
            font.pointSize: 24
            font.weight: Font.ExtraBold
            font.letterSpacing: Theme.trackingTight(24)
            horizontalAlignment: Text.AlignLeft
            wrapMode: Text.Wrap
        }

        HardProgress {
            id: stageSpinner

            width: parent.width
        }
    }

    ErrorMessageDialog {
        id: errorDialog

        onClosed: {
            Qt.quit();
        }
    }

    NavigableMessageDialog {
        id: pairCompleteDialog
        closePolicy: Popup.CloseOnEscape

        text:qsTr("Pairing completed successfully")
        standardButtons: Dialog.Ok
        onClosed: {
            Qt.quit()
        }
    }
}
