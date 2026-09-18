import QtQuick 2.0
import QtQuick.Controls
import QtQuick.Dialogs 6.3
import QtQuick.Layouts 1.2

import "theme"

NavigableDialog {
    id: dialog

    property alias text: dialogLabel.dialogText
    property alias showSpinner: dialogSpinner.visible
    property alias imageSrc: dialogImage.source

    property string helpText
    property string helpUrl : "https://github.com/moonlight-stream/moonlight-docs/wiki/Troubleshooting"
    property string helpTextSeparator : " "

    onOpened: {
        // Force keyboard focus on the label so keyboard navigation works
        if (dialogButtonBox.count > 0) {
            dialogButtonBox.itemAt(dialogButtonBox.count - 1).forceActiveFocus(Qt.TabFocusReason)
        }
    }

    // Inherit NavigableDialog's square Panel, hard shadow, and accent bar.

    property QtObject messageButtonLabels: StandardButtonLabels {
        buttonBox: dialogButtonBox
        language: StreamingPreferences.language
        englishLanguage: StreamingPreferences.LANG_EN
    }

    RowLayout {
        spacing: Theme.spaceLg

        // Use sequential square indicators instead of a circular spinner.
        Row {
            id: dialogSpinner

            spacing: Theme.spaceXs
            visible: false

            Repeater {
                model: 3

                Rectangle {
                    width: 10; height: 10
                    color: Theme.accent

                    SequentialAnimation on opacity {
                        running: dialogSpinner.visible
                        loops: Animation.Infinite
                        PauseAnimation { duration: index * 160 }
                        NumberAnimation { to: 1.0; duration: 160 }
                        NumberAnimation { to: 0.2; duration: 160 }
                        PauseAnimation { duration: (2 - index) * 160 }
                    }
                }
            }
        }

        Image {
            id: dialogImage
            source: (standardButtons & Dialog.Yes) ?
                        "qrc:/res/baseline-help_outline-24px.svg" :
                        "qrc:/res/baseline-error_outline-24px.svg"
            sourceSize {
                // The icon should be square so use the height as the width too
                width: 40
                height: 40
            }
            visible: !showSpinner
        }

        Text {
            property string dialogText

            id: dialogLabel
            text: dialogText + ((helpText && (standardButtons & Dialog.Help)) ? (helpTextSeparator + helpText) : "")
            color: Theme.text
            font.family: Theme.fontSans
            font.pointSize: Theme.fontRowTitle
            lineHeight: 1.25
            wrapMode: Text.Wrap
            elide: Text.ElideRight

            // Cap the width so the dialog doesn't grow horizontally forever. This
            // will cause word wrap to kick in.
            Layout.maximumWidth: 400
            Layout.maximumHeight: 400
        }
    }

    footer: DialogButtonBox {
        id: dialogButtonBox
        standardButtons: dialog.standardButtons

        onStandardButtonsChanged: Qt.callLater(function() { messageButtonLabels.apply() })

        padding: Theme.spaceXl
        topPadding: 0
        spacing: Theme.spaceSm
        alignment: Qt.AlignRight

        // Remove FluentWinUI3's rounded DialogButtonBox backing so it sits directly on Panel.
        background: Item {}

        delegate: HardButton {
            Keys.onReturnPressed: clicked()
            Keys.onEnterPressed: clicked()
            Keys.onRightPressed: nextItemInFocusChain(true).forceActiveFocus(Qt.TabFocusReason)
            Keys.onLeftPressed: nextItemInFocusChain(false).forceActiveFocus(Qt.TabFocusReason)
        }

        onHelpRequested: {
            Qt.openUrlExternally(helpUrl)
            close()
        }
    }
}
