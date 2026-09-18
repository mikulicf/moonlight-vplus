pragma ComponentBehavior: Bound
import QtQuick 2.9
import QtQuick.Controls
import "."
import "../theme"

// External links open only after an explicit user action.
Column {
    id: aboutPage
    signal scrollToEndRequested()
    width: parent ? parent.width : 0
    spacing: Theme.spaceLg

    function openExternal(url) {
        if (!Qt.openUrlExternally(url)) {
            ToolTip.show(qsTr("No external browser is available."), 3500)
        }
    }

    SettingsCard {
        title: qsTr("About")
        subtitle: qsTr("An independently maintained Moonlight V+ client for self-hosted desktop streaming.")
        SettingsRow {
            title: "Moonlight V+"
            description: qsTr("Maintained by mikulicf, based on Moonlight V+ by qiin2333 and AlkaidLab, and Moonlight Qt by the Moonlight contributors.")
            Column {
                spacing: Theme.spaceSm
                HardLink {
                    text: qsTr("Source code")
                    onClicked: aboutPage.openExternal("https://github.com/mikulicf/moonlight-vplus")
                }
                HardLink {
                    text: qsTr("Report an issue")
                    onClicked: aboutPage.openExternal("https://github.com/mikulicf/moonlight-vplus/issues")
                }
            }
        }
    }

    SettingsCard {
        title: qsTr("License and acknowledgements")
        subtitle: qsTr("Released under GNU GPLv3. Copyright and license notices from upstream projects are retained.")
        SettingsRow {
            title: "GNU GPL v3.0"
            Column {
                spacing: Theme.spaceSm
                HardLink {
                    text: qsTr("License")
                    onClicked: aboutPage.openExternal("https://github.com/mikulicf/moonlight-vplus/blob/master/LICENSE")
                }
                HardLink {
                    text: qsTr("Third-party notices")
                    onClicked: aboutPage.openExternal("https://github.com/mikulicf/moonlight-vplus/blob/master/NOTICE.md")
                }
            }
        }
        SettingsRow {
            title: "usbipdcpp (LGPL-3.0)"
            description: qsTr("This product uses usbipdcpp (https://github.com/yunsmall/usbipdcpp), licensed under LGPLv3.")
            HardLink {
                text: qsTr("Project")
                onClicked: aboutPage.openExternal("https://github.com/yunsmall/usbipdcpp")
            }
        }
    }
}
