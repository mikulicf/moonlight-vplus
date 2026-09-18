pragma ComponentBehavior: Bound
import QtQuick 2.9
import QtQuick.Controls
import "."
import "../theme"

Column {
    id: ecosystemPage
    signal aboutRequested()
    width: parent ? parent.width : 0
    spacing: Theme.spaceLg

    function openExternal(url) {
        if (!Qt.openUrlExternally(url)) {
            ToolTip.show(qsTranslate("AboutSettingsPage", "No external browser is available."), 3500)
        }
    }

    PlatformNavButton {
        width: Math.min(parent.width, 320)
        height: 44
        text: qsTr("About Moonlight V+")
        onClicked: ecosystemPage.aboutRequested()
    }

    SettingsCard {
        title: qsTr("Compatible hosts")
        subtitle: qsTr("Install a host on the PC you want to control. Available features depend on the capabilities advertised by that host.")
        SettingsRow {
            title: "Sunshine"
            description: qsTr("A self-hosted streaming server compatible with Moonlight clients.")
            HardLink {
                text: qsTr("Project and downloads")
                onClicked: ecosystemPage.openExternal("https://github.com/LizardByte/Sunshine")
            }
        }
        SettingsRow {
            title: "Apollo"
            description: qsTr("A Sunshine-based host with virtual display support.")
            HardLink {
                text: qsTr("Project and downloads")
                onClicked: ecosystemPage.openExternal("https://github.com/ClassicOldSong/Apollo")
            }
        }
        SettingsRow {
            title: "Foundation Sunshine"
            description: qsTr("A compatible host implementing additional clipboard, microphone, display, file mapping, and USB extensions. Extensions are enabled only when supported by the host.")
            HardLink {
                text: qsTr("Project and downloads")
                onClicked: ecosystemPage.openExternal("https://github.com/AlkaidLab/foundation-sunshine")
            }
        }
    }

    SettingsCard {
        title: qsTr("Other Moonlight clients")
        subtitle: qsTr("The Moonlight project provides clients for other computers and mobile devices.")
        HardLink {
            text: qsTr("Moonlight clients and documentation")
            onClicked: ecosystemPage.openExternal("https://moonlight-stream.org")
        }
    }
}
