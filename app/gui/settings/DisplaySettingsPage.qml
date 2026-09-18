import QtQuick 2.9
import "."
import "../theme"
import ".."

import StreamingPreferences 1.0
import SystemProperties 1.0

// Display settings: window mode, V-Sync, frame pacing, and HDR presentation.
//
// Keep presentation settings separate from stream resolution, frame rate, and bitrate.
// The large HDR card has its own space here rather than crowding Basic settings.
Column {
    id: displayPage

    // SettingsView forwards language changes so this page can rebuild window-mode labels.
    // Do not reference basicPage, which is outside this component's scope.
    signal languageChanged()

    width: parent ? parent.width : 0
    spacing: Theme.spaceLg

    SettingsCard {
        title: qsTr("Display")

        SettingsRow {
            applicable: SystemProperties.hasDesktopEnvironment
            title: qsTr("Display mode")
            description: qsTr("Fullscreen generally provides the best performance, but borderless windowed may work better with features like macOS Spaces, Alt+Tab, screenshot tools, on-screen overlays, etc.")

            AutoResizingComboBox {
                id: windowModeComboBox
                maximumWidth: 260
                textRole: "text"
                enabled: !SystemProperties.rendererAlwaysFullScreen
                hoverEnabled: true

                function createModel() {
                    var model = Qt.createQmlObject('import QtQuick 2.0; ListModel {}', windowModeComboBox, '')

                    model.append({
                                     text: qsTr("Fullscreen"),
                                     val: StreamingPreferences.WM_FULLSCREEN
                                 })

                    model.append({
                                     text: qsTr("Borderless windowed"),
                                     val: StreamingPreferences.WM_FULLSCREEN_DESKTOP
                                 })

                    model.append({
                                     text: qsTr("Windowed"),
                                     val: StreamingPreferences.WM_WINDOWED
                                 })

                    // Set the recommended option based on the OS
                    for (var i = 0; i < model.count; i++) {
                        var thisWm = model.get(i).val;
                        if (thisWm === StreamingPreferences.recommendedFullScreenMode) {
                            model.get(i).text += " " + qsTr("(Recommended)")
                            model.move(i, 0, 1)
                            break
                        }
                    }

                    return model
                }

                // This is used on initialization and upon retranslation
                function reinitialize() {
                    if (!SystemProperties.hasDesktopEnvironment) {
                        // Do nothing if the control won't even be visible
                        return
                    }

                    model = createModel()
                    currentIndex = 0

                    // Set the current value based on the saved preferences
                    var savedWm = StreamingPreferences.windowMode
                    for (var i = 0; i < model.count; i++) {
                         var thisWm = model.get(i).val;
                         if (savedWm === thisWm) {
                             currentIndex = i
                             break
                         }
                    }

                }

                Component.onCompleted: {
                    reinitialize()
                    displayPage.languageChanged.connect(reinitialize)
                }

                onActivated: {
                    StreamingPreferences.windowMode = model.get(currentIndex).val
                }
            }
        }

        ToggleRow {
            title: qsTr("Stretch presentation")
            description: qsTr("Ignores both client and host PC aspect ratios, which is required for displaying Half-SBS (Side-By-Side) 3D signals to AR/XR devices that only support Full-SBS (usually 1920x1080 per eye, meaning a total resolution of 3840x1080)")
            checked: StreamingPreferences.ignoreAspectRatio
            onToggled: function(value) { StreamingPreferences.ignoreAspectRatio = value }
        }

        ToggleRow {
            id: vsyncToggle
            title: qsTr("V-Sync")
            description: qsTr("Disabling V-Sync allows sub-frame rendering latency, but it can display visible tearing")
            checked: StreamingPreferences.enableVsync
            onToggled: function(value) { StreamingPreferences.enableVsync = value }
        }

        ToggleRow {
            title: qsTr("Frame pacing")
            description: qsTr("Frame pacing reduces micro-stutter by delaying frames that come in too early")
            controlEnabled: StreamingPreferences.enableVsync
            checked: StreamingPreferences.enableVsync && StreamingPreferences.framePacing
            onToggled: function(value) { StreamingPreferences.framePacing = value }
        }
    }

    // ================= HDR =================
    SettingsCard {
        title: qsTr("HDR")

        ToggleRow {
            title: qsTr("Enable HDR")
            description: SystemProperties.supportsHdr ?
                             qsTr("The stream will be HDR-capable, but some games may require an HDR monitor on your host PC to enable HDR mode.")
                           :
                             qsTr("HDR streaming is not supported on this PC.")
            controlEnabled: SystemProperties.supportsHdr
            checked: SystemProperties.supportsHdr && StreamingPreferences.enableHdr
            onToggled: function(value) { StreamingPreferences.enableHdr = value }
        }

        SettingsRow {
            id: hdrModeRow
            title: qsTr("HDR format")
            description: qsTr("HDR10 (PQ) is the standard HDR format. HLG offers better compatibility with SDR displays when HDR is not active on the host.")

            AutoResizingComboBox {
                id: hdrModeComboBox
                maximumWidth: 220
                textRole: "text"
                enabled: SystemProperties.supportsHdr && StreamingPreferences.enableHdr
                hoverEnabled: true

                model: ListModel {
                    id: hdrModeListModel
                    ListElement {
                        text: "HDR10 (PQ)"
                        val: 1
                    }
                    ListElement {
                        text: "HLG"
                        val: 2
                    }
                }

                Component.onCompleted: {
                    for (var i = 0; i < hdrModeListModel.count; i++) {
                        if (hdrModeListModel.get(i).val === StreamingPreferences.hdrMode) {
                            currentIndex = i
                            break
                        }
                    }
                }

                onActivated: {
                    if (enabled) {
                        StreamingPreferences.hdrMode = hdrModeListModel.get(currentIndex).val
                    }
                }
            }
        }

        // Keep the large HDR brightness card in its own component.
        Item {
            width: parent.width
            // Do not use visible here; see SettingsCard.hasVisibleContent.
            visible: hdrModeRow.applicable
            height: visible ? hdrCard.height : 0

            HdrBrightnessCard {
                id: hdrCard
                width: parent.width
            }
        }
    }
}
