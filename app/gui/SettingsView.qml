import QtQuick 2.9
import QtQuick.Controls
import QtQuick.Window 2.2

import StreamingPreferences 1.0
import SdlGamepadKeyNavigation 1.0
import SystemProperties 1.0

import "settings"
import "theme"

// Settings shell: category rail on the left and card content on the right.
// Basic and Display have separate pages; six other groups retain LegacySettingsPage's
// translation context while using the same card/row components. Use FocusScope so
// toolbar forceActiveFocus() forwards to a real control instead of an invisible Item.
FocusScope {
    id: settingsPage
    // This page provides its own wallpaper; main.qml must not add another layer.
    readonly property bool usesOwnBackground: true
    objectName: qsTr("Settings")

    signal languageChanged()

    // Collapse the rail to horizontal tabs in narrow windows.
    readonly property bool compact: width < Theme.compactBreakpoint

    property string category: "basic"

    // Use MIT-licensed Microsoft Fluent UI System Icons for consistent cross-platform
    // size, weight, and color instead of platform-dependent emoji glyphs.
    readonly property var rawCategories: [
        { key: "basic",    icon: "qrc:/res/fluent/cat-basic.svg",    title: qsTr("Basic Settings") },
        { key: "display",  icon: "qrc:/res/fluent/cat-display.svg",  title: qsTr("Display Settings") },
        { key: "audio",    icon: "qrc:/res/fluent/cat-audio.svg",    title: qsTr("Audio Settings") },
        { key: "host",     icon: "qrc:/res/fluent/cat-host.svg",     title: qsTr("Host Settings") },
        { key: "input",    icon: "qrc:/res/fluent/cat-input.svg",    title: qsTr("Input Settings") },
        { key: "gamepad",  icon: "qrc:/res/fluent/cat-gamepad.svg",  title: qsTr("Gamepad Settings") },
        { key: "peripherals", icon: "qrc:/res/fluent/cat-peripherals.svg", title: qsTr("Peripherals Settings") },
        { key: "advanced", icon: "qrc:/res/fluent/cat-advanced.svg", title: qsTr("Advanced Settings") },
        { key: "ui",       icon: "qrc:/res/fluent/cat-ui.svg",       title: qsTr("Software Settings") },
        { key: "ecosystem",icon: "qrc:/res/fluent/cat-ecosystem.svg",title: qsTr("Hosts and Clients") },
        { key: "about",    icon: "qrc:/res/fluent/cat-about.svg",    title: qsTr("About") }
    ]

    // Show USB forwarding only where a local USB/IP backend exists (Windows/macOS).
    // Hide the category entirely elsewhere to avoid an empty page.
    readonly property var categories: rawCategories.filter(
        function(c) {
            return c.key !== "peripherals" || SystemProperties.usbForwardingAvailable
        })

    StackView.onActivated: {
        // This enables Tab and BackTab based navigation rather than arrow keys.
        // It is required to shift focus between controls on the settings page.
        SdlGamepadKeyNavigation.setUiNavMode(true)

        // Start gamepad focus on the selected category rather than the first content control.
        //
        // Starting on the resolution dropdown let the first horizontal input change its
        // value (issue #144). The retained category provides a visible, safe starting point.
        if (SdlGamepadKeyNavigation.getConnectedGamepads() > 0) {
            rail.focusCurrent()
        }
    }

    // B/Escape first returns from content to the rail. Only from the rail does it
    // propagate to main.qml and leave settings, avoiding accidental whole-page exits.
    Keys.onEscapePressed: function(event) {
        event.accepted = !rail.railFocused
        if (event.accepted) {
            rail.focusCurrent()
        }
    }

    // Focus the first available control in the content area.
    //
    // Follow the focus chain rather than naming a page-specific first control.
    // scrollArea follows the rail in declaration order, and Tab skips hidden categories.
    function focusContent() {
        var first = scrollArea.nextItemInFocusChain(true)
        if (first) {
            first.forceActiveFocus(Qt.TabFocusReason)
        }
    }

    StackView.onDeactivating: {
        SdlGamepadKeyNavigation.setUiNavMode(false)

        // Save the prefs so the Session can observe the changes
        StreamingPreferences.save()
    }

    Component.onDestruction: {
        // Also save preferences on destruction, since we won't get a
        // deactivating callback if the user just closes Moonlight
        StreamingPreferences.save()
    }

    // Forward focus from the shell to the category rail when arriving from the toolbar
    // or a StackView transition, avoiding an invisible focus stop.
    onActiveFocusChanged: {
        if (activeFocus && Window.window && Window.window.activeFocusItem === settingsPage) {
            rail.focusCurrent()
        }
    }

    // Gamepad LB/RB map to PageUp/PageDown for category switching.
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_PageUp) {
            rail.step(-1)
            // Restore rail focus after switching; the old content control is now hidden.
            rail.focusCurrent()
            event.accepted = true
        }
        else if (event.key === Qt.Key_PageDown) {
            rail.step(1)
            rail.focusCurrent()
            event.accepted = true
        }
    }

    // Reuse the background already owned by the application window. Creating a
    // hidden PcView here duplicated its model, network work, and scene graph.
    Image {
        anchors.fill: parent
        visible: StreamingPreferences.backgroundSource !== StreamingPreferences.BGS_NONE
        source: Window.window && Window.window.backgroundImageUrl !== ""
                ? Window.window.backgroundImageUrl
                : "qrc:/res/gura.png"
        fillMode: Image.PreserveAspectCrop
        z: -2
    }

    Rectangle {
        anchors.fill: parent
        visible: StreamingPreferences.backgroundSource !== StreamingPreferences.BGS_NONE
        color: Qt.rgba(Theme.ink.r, Theme.ink.g, Theme.ink.b,
                       StreamingPreferences.backgroundOverlayOpacity / 100.0)
        z: -1
    }

    Item {
        id: body

        anchors {
            fill: parent
            // Reserve the 56-pixel toolbar plus one spacing unit.
            topMargin: 72
            leftMargin: Theme.spaceLg
            rightMargin: Theme.spaceLg
            bottomMargin: Theme.spaceSm
        }

        Rectangle {
            id: railBackground

            anchors {
                left: parent.left
                top: parent.top
            }
            width: settingsPage.compact ? body.width : Theme.railWidth
            height: settingsPage.compact ? 52 : body.height

            // Square category backing with a one-pixel border. Omit a shadow because
            // it would crowd the content beside the window's left edge.
            radius: 0
            color: Theme.surfaceLayer
            border.width: 1
            border.color: Theme.line

            CategoryRail {
                id: rail
                anchors {
                    fill: parent
                    margins: Theme.spaceXs
                }
                compact: settingsPage.compact
                categories: settingsPage.categories
                currentCategory: settingsPage.category
                onCategoryPicked: function(category) {
                    settingsPage.category = category
                    scrollArea.contentY = 0
                }
                onContentRequested: settingsPage.focusContent()
            }
        }

        SettingsScrollArea {
            id: scrollArea

            anchors {
                top: settingsPage.compact ? railBackground.bottom : parent.top
                topMargin: settingsPage.compact ? Theme.spaceMd : 0
                left: settingsPage.compact ? parent.left : railBackground.right
                leftMargin: settingsPage.compact ? 0 : Theme.spaceLg
                right: parent.right
                bottom: parent.bottom
            }

            BasicSettingsPage {
                id: basicPage
                width: parent.width
                visible: settingsPage.category === "basic"
                height: visible ? implicitHeight : 0
            }

            DisplaySettingsPage {
                id: displayPage
                y: basicPage.height
                width: parent.width
                visible: settingsPage.category === "display"
                height: visible ? implicitHeight : 0
            }

            LegacySettingsPage {
                id: legacyPage
                // Hidden pages have zero height, so add the preceding page heights.
                y: basicPage.height + displayPage.height
                width: parent.width
                category: settingsPage.category

                onLanguageChanged: settingsPage.languageChanged()
                onBitratePreferenceChanged: basicPage.syncBitrateFromPreferences()
            }

            EcosystemSettingsPage {
                id: ecosystemPage
                y: basicPage.height + displayPage.height + legacyPage.height
                width: parent.width
                visible: settingsPage.category === "ecosystem"
                height: visible ? implicitHeight : 0
                onAboutRequested: {
                    settingsPage.category = "about"
                    rail.focusCurrent()
                    scrollArea.contentY = 0
                }
            }

            AboutSettingsPage {
                id: aboutPage
                y: basicPage.height + displayPage.height + legacyPage.height + ecosystemPage.height
                width: parent.width
                visible: settingsPage.category === "about"
                height: visible ? implicitHeight : 0
                onScrollToEndRequested: scrollArea.scrollToEnd()
            }

            PeripheralsSettingsPage {
                id: peripheralsPage
                y: basicPage.height + displayPage.height + legacyPage.height
                   + ecosystemPage.height + aboutPage.height
                width: parent.width
                visible: settingsPage.category === "peripherals"
                height: visible ? implicitHeight : 0
            }
        }
    }

    Component.onCompleted: {
        // Rebuild dropdown models after changing the language.
        settingsPage.languageChanged.connect(basicPage.languageChanged)
        settingsPage.languageChanged.connect(displayPage.languageChanged)
    }
}
