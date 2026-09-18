pragma ComponentBehavior: Bound
import QtQuick 2.9
import QtQuick.Controls
import "."
import "../theme"
import StreamingPreferences 1.0
import SystemProperties 1.0
import UsbForwardingEnvironment 1.0
import UsbForwardingBackend 1.0

// Peripherals manage physical USB devices forwarded to the host. Input and Gamepad
// categories instead configure how local input is mapped into a stream.
Column {
    id: peripheralsPage

    width: parent ? parent.width : 0
    spacing: Theme.spaceLg

    // Windows uses usbipd-win; macOS uses the bundled moonlight-usbd/usbipdcpp helper.
    readonly property bool isMac: SystemProperties.isDarwin

    SettingsCard {
        id: usbForwardingCard
        title: qsTr("USB Device Forwarding")
        subtitle: qsTr("Share local gamepads and other peripherals with the streaming host. Forwarding is confirmed per device during a stream and can be stopped at any time.")
        visible: SystemProperties.usbForwardingAvailable

        readonly property string usbipdUrl: "https://github.com/dorssel/usbipd-win/releases/latest"

        Component.onCompleted: {
            if (visible) {
                UsbForwardingEnvironment.refresh()
            }
        }
        onVisibleChanged: if (visible) UsbForwardingEnvironment.refresh()

        ToggleRow {
            title: qsTr("Enable USB device forwarding")
            description: qsTr("When off, streaming will not discover or start any USB forwarding service.")
            checked: StreamingPreferences.usbForwardingEnabled
            onToggled: function(value) { StreamingPreferences.usbForwardingEnabled = value }
        }

        SettingsRow {
            id: usbEnvRow

            title: peripheralsPage.isMac ? qsTr("USB sharing service") : "usbipd-win"
            description: {
                if (UsbForwardingEnvironment.checking) {
                    return qsTr("Checking environment…")
                }
                switch (UsbForwardingEnvironment.state) {
                case UsbForwardingEnvironment.Checking:
                    return qsTr("Checking environment…")
                case UsbForwardingEnvironment.DriverStopped:
                    return qsTr("USB driver not running. Start VBoxUSBMon as administrator, or restart Windows.")
                case UsbForwardingEnvironment.CheckFailed:
                    return peripheralsPage.isMac
                        ? qsTr("Could not verify the bundled USB sharing service. Reinstall Moonlight.")
                        : qsTr("Could not verify the USB service and driver. Check the usbipd-win installation.")
                case UsbForwardingEnvironment.Ready:
                    return peripheralsPage.isMac
                        ? qsTr("%1 · Ready").arg(UsbForwardingEnvironment.usbipdVersion)
                        : qsTr("v%1 · Service running")
                              .arg(UsbForwardingEnvironment.usbipdVersion)
                case UsbForwardingEnvironment.ServiceStopped:
                    return qsTr("Installed (v%1). The usbipd service is not running.")
                        .arg(UsbForwardingEnvironment.usbipdVersion)
                case UsbForwardingEnvironment.NotInstalled:
                default:
                    return peripheralsPage.isMac
                        ? qsTr("The bundled USB sharing service is missing. Reinstall Moonlight.")
                        : qsTr("Not installed. usbipd-win is required to share USB devices.")
                }
            }
            descriptionFontPointSize: Theme.fontSettingsSubtitle + 1

            Flow {
                width: Math.min(260, Math.max(0, usbEnvRow.width - Theme.spaceMd * 2))
                spacing: Theme.spaceSm

                HardButton {
                    text: qsTr("Refresh")
                    onClicked: UsbForwardingEnvironment.refresh()
                }

                HardLink {
                    visible: !peripheralsPage.isMac
                    text: qsTr("Install / Repair")
                    onClicked: peripheralsPage.openExternal(usbForwardingCard.usbipdUrl)
                }
            }
        }

        SettingsRow {
            title: qsTr("Shared devices")
            description: qsTr("Choose which devices can be forwarded to the streaming host. Sharing takes over the device on this computer.")

            Flow {
                width: Math.min(260, Math.max(0, usbEnvRow.width - Theme.spaceMd * 2))
                spacing: Theme.spaceSm

                HardButton {
                    text: qsTr("Manage devices…")
                    primary: true
                    onClicked: bindDialog.open()
                }
            }
        }

        // On macOS, devices held by system drivers (HID/storage/cameras) cannot be shared.
        SettingsRow {
            visible: peripheralsPage.isMac
            title: qsTr("Device availability")
            description: qsTr("Devices managed by macOS itself — keyboards, mice, storage, and cameras — are shown as \"In use by macOS\" and cannot be shared without administrator access.")
        }

        SettingsRow {
            title: qsTr("Voice input")
            description: qsTr("Microphone audio does not travel through USB forwarding. Use the in-stream microphone feature for voice.")
        }
    }

    UsbForwardingBindDialog {
        id: bindDialog
    }

    function openExternal(url) {
        if (!Qt.openUrlExternally(url)) {
            ToolTip.show(qsTr("No external browser is available."), 3500)
        }
    }
}
