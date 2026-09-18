import QtQuick
import QtQuick.Controls
import QtQuick.Layouts 1.3
import QtQuick.Window 2.2
import QtQuick.Controls.Material as MaterialStyle

import ComputerManager 1.0
import AutoUpdateChecker 1.0
import StreamingPreferences 1.0
import SystemProperties 1.0
import SdlGamepadKeyNavigation 1.0
import WindowPlacement 1.0
import WindowsWindowChrome 1.0

import "theme"
import "Brand.js" as Brand

ApplicationWindow {
    property bool pollingActive: false
    property bool revealAfterFirstFrame: false
    property bool configurationChecksStarted: false
    property bool initialBackgroundChoiceHandled: false

    Timer {
        id: revealFallbackTimer
        interval: 1000
        repeat: false
        onTriggered: {
            window.revealAfterFirstFrame = false
            window.opacity = 1
        }
    }

    // Set by SettingsView to force the back operation to pop all
    // pages except the initial view. This is required when doing
    // a retranslate() because AppView breaks for some reason.
    property bool clearOnBack: false

    id: window
    // macOS's centered native title duplicates the toolbar brand. Clear it there;
    // Windows and Linux do not have this overlap.
    title: SystemProperties.isDarwin ? "" : Qt.application.displayName
    width: 1280
    height: 640

    WindowPlacement {
        id: windowPlacement
        window: window
        enabled: StreamingPreferences.rememberWindowPosition &&
                 SystemProperties.hasDesktopEnvironment &&
                 (!SystemProperties.isRunningWayland || SystemProperties.isRunningXWayland)
    }

    WindowsWindowChrome {
        id: windowsWindowChrome
        window: window
        titleBar: titleDragRegion
    }

    // WindowsWindowChrome customizes the nonclient area while preserving native
    // top-level state and commands. macOS/Linux retain their platform titlebar behavior.
    flags: Qt.platform.os === "windows"
           ? Qt.Window
           : Qt.Window | Qt.ExpandedClientAreaHint | Qt.NoTitleBarBackgroundHint

    // Expanded client-area flags reach the window top, but ApplicationWindow still
    // offsets contentItem by the titlebar safe area (32 points on macOS), leaving a gap.
    //
    // Undo that offset because our toolbar is the titlebar. The binding also follows
    // fullscreen, where contentItem.y returns to zero.
    readonly property real chromeInset: contentItem.y

    onFrameSwapped: {
        if (revealAfterFirstFrame) {
            revealAfterFirstFrame = false
            revealFallbackTimer.stop()
            opacity = 1
        }
    }

    // FluentWinUI3's ApplicationWindow is just "color: palette.window", and on macOS
    // that palette follows the system appearance regardless of the color scheme we
    // ask for. Pin it so pages we haven't given a background of their own (the
    // connection spinner, the quit page) are never white-on-white.
    color: Theme.ink

    // This function runs prior to creation of the initial StackView item
    function doEarlyInit() {
        // Override the background color to Material 2 colors for Qt 6.5+
        // in order to improve contrast between GFE's placeholder box art
        // and the background of the app grid.
        if (SystemProperties.usesMaterial3Theme) {
            MaterialStyle.Material.background = "#303030"
        }

        SdlGamepadKeyNavigation.enable()
    }

    function startConfigurationChecks() {
        if (configurationChecksStarted) {
            return
        }
        configurationChecksStarted = true

        if (!runConfigChecks) {
            return
        }

        if (SystemProperties.isWow64) {
            wow64Dialog.open()
        }

        // Hardware acceleration and unmapped gamepads are checked asynchronously.
        SystemProperties.hasHardwareAccelerationChanged.connect(hasHardwareAccelerationChanged)
        SystemProperties.unmappedGamepadsChanged.connect(hasUnmappedGamepadsChanged)
        SystemProperties.startAsyncLoad()
    }

    function commitInitialBackgroundSource(source) {
        if (initialBackgroundChoiceHandled) {
            return
        }

        initialBackgroundChoiceHandled = true
        StreamingPreferences.backgroundSource = source
        StreamingPreferences.save()
    }

    Component.onCompleted: {
        // Always fit the initial window to the current screen. When the preference
        // is enabled, restore the last normal window geometry before showing it.
        windowsWindowChrome.activate()
        var startMaximized = windowPlacement.restore(
                    StreamingPreferences.uiDisplayMode === StreamingPreferences.UI_MAXIMIZED)

        // Show the window according to the user's preferences
        if (SystemProperties.hasDesktopEnvironment) {
            if (StreamingPreferences.uiDisplayMode === StreamingPreferences.UI_FULLSCREEN) {
                window.showFullScreen()
            }
            else if (startMaximized) {
                if (Qt.platform.os === "windows") {
                    window.opacity = 0
                    window.revealAfterFirstFrame = true
                    revealFallbackTimer.start()
                }
                window.showMaximized()
            }
            else {
                window.show()
            }
        } else {
            window.showFullScreen()
        }

        // Let a fresh install choose its background before any other startup
        // warning is opened. Existing installs and CLI launches skip this step.
        if (runConfigChecks && !StreamingPreferences.backgroundSetupCompleted) {
            Qt.callLater(function() { backgroundSourceDialog.open() })
        }
        else {
            startConfigurationChecks()
        }
    }

    onClosing: windowPlacement.flush()

    function hasHardwareAccelerationChanged() {
        if (!SystemProperties.hasHardwareAcceleration && StreamingPreferences.videoDecoderSelection !== StreamingPreferences.VDS_FORCE_SOFTWARE) {
            if (SystemProperties.isRunningXWayland) {
                xWaylandDialog.open()
            }
            else {
                noHwDecoderDialog.open()
            }
        }
    }

    function hasUnmappedGamepadsChanged() {
        if (SystemProperties.unmappedGamepads) {
            unmappedGamepadDialog.unmappedGamepads = SystemProperties.unmappedGamepads
            unmappedGamepadDialog.open()
        }
    }

    // It would be better to use TextMetrics here, but it always lays out
    // the text slightly more compactly than real Text does in ToolTip,
    // causing unexpected line breaks to be inserted
    Text {
        id: tooltipTextLayoutHelper
        visible: false
        font: ToolTip.toolTip.font
        text: ToolTip.toolTip.text
    }

    function goBack() {
        if (clearOnBack) {
            // Pop all items except the first one
            stackView.pop(null)
            clearOnBack = false
        }
        else {
            stackView.pop()
        }
    }

    // PcView fetches and caches wallpaper, then shares it for pages without their own background.
    property string backgroundImageUrl: ""

    // PcView/AppView/SettingsView draw their own dimmed wallpaper. Do not duplicate
    // the full-size image behind them; this layer serves pages without a background.
    readonly property bool showGlobalBackground:
        !(stackView.currentItem && stackView.currentItem.usesOwnBackground === true)

    Image {
        anchors.fill: parent
        anchors.topMargin: -window.chromeInset
        source: window.backgroundImageUrl
        visible: source != "" && window.showGlobalBackground
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        z: -3
    }

    // Use the shared wallpaper opacity setting to keep foreground content readable.
    Rectangle {
        anchors.fill: parent
        anchors.topMargin: -window.chromeInset
        color: Qt.rgba(Theme.ink.r, Theme.ink.g, Theme.ink.b,
                       StreamingPreferences.backgroundOverlayOpacity / 100.0)
        visible: window.showGlobalBackground
        z: -2
    }

    StackView {
        id: stackView
        anchors.fill: parent
        // Each page reserves 72 pixels for the toolbar measured from the window top.
        anchors.topMargin: -window.chromeInset
        focus: true

        // Use a short mechanical transition: 12-pixel horizontal movement and fade,
        // 150 ms OutQuad, without scaling.
        pushEnter: Transition {
            ParallelAnimation {
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.durNormal; easing.type: Theme.easing }
                NumberAnimation { property: "x"; from: 12; to: 0; duration: Theme.durNormal; easing.type: Theme.easing }
            }
        }
        pushExit: Transition {
            ParallelAnimation {
                NumberAnimation { property: "opacity"; from: 1; to: 0; duration: Theme.durFast; easing.type: Easing.InQuad }
                NumberAnimation { property: "x"; from: 0; to: -12; duration: Theme.durFast; easing.type: Easing.InQuad }
            }
        }
        popEnter: Transition {
            ParallelAnimation {
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.durNormal; easing.type: Theme.easing }
                NumberAnimation { property: "x"; from: -12; to: 0; duration: Theme.durNormal; easing.type: Theme.easing }
            }
        }
        popExit: Transition {
            ParallelAnimation {
                NumberAnimation { property: "opacity"; from: 1; to: 0; duration: Theme.durFast; easing.type: Easing.InQuad }
                NumberAnimation { property: "x"; from: 0; to: 12; duration: Theme.durFast; easing.type: Easing.InQuad }
            }
        }

        // This configures the maximum width of the singleton attached QML ToolTip. If left unconstrained,
        // it will never insert a line break and just extend on forever.
        ToolTip.toolTip.contentWidth: Math.min(tooltipTextLayoutHelper.width, 400)
        ToolTip.toolTip.margins: 8

        ToolTip.toolTip.onVisibleChanged: {
            if (ToolTip.toolTip.visible) ToolTip.toolTip.y = toolBar.height - 5
        }

        Component.onCompleted: {
            // Perform our early initialization before constructing
            // the initial view and pushing it to the StackView
            doEarlyInit()
            push(initialView)
        }

        onCurrentItemChanged: {
            // Ensure focus travels to the next view when going back
            if (currentItem) {
                currentItem.forceActiveFocus()
            }
        }

        Keys.onEscapePressed: {
            if (depth > 1) {
                goBack()
            }
            else {
                quitConfirmationDialog.open()
            }
        }

        Keys.onBackPressed: {
            if (depth > 1) {
                goBack()
            }
            else {
                quitConfirmationDialog.open()
            }
        }

        Keys.onMenuPressed: {
            settingsButton.clicked()
        }

        // This is a keypress we've reserved for letting the
        // SdlGamepadKeyNavigation object tell us to show settings
        // when Menu is consumed by a focused control.
        Keys.onHangupPressed: {
            settingsButton.clicked()
        }
    }

    // This timer keeps us polling for 5 minutes of inactivity
    // to allow the user to work with Moonlight on a second display
    // while dealing with configuration issues. This will ensure
    // machines come online even if the input focus isn't on Moonlight.
    Timer {
        id: inactivityTimer
        interval: 5 * 60000
        onTriggered: {
            if (!active && pollingActive) {
                ComputerManager.stopPollingAsync()
                pollingActive = false
            }
        }
    }

    onVisibleChanged: {
        // When we become invisible while streaming is going on,
        // stop polling immediately.
        if (!visible) {
            inactivityTimer.stop()

            if (pollingActive) {
                ComputerManager.stopPollingAsync()
                pollingActive = false
            }
        }
        else if (active) {
            // When we become visible and active again, start polling
            inactivityTimer.stop()

            // Restart polling if it was stopped
            if (!pollingActive) {
                ComputerManager.startPolling()
                pollingActive = true
            }
        }

        // Poll for gamepad input only when the window is in focus
        SdlGamepadKeyNavigation.notifyWindowFocus(visible && active)
    }

    onActiveChanged: {
        if (active) {
            // Stop the inactivity timer
            inactivityTimer.stop()

            // Restart polling if it was stopped
            if (!pollingActive) {
                ComputerManager.startPolling()
                pollingActive = true
            }
        }
        else {
            // Start the inactivity timer to stop polling
            // if focus does not return within a few minutes.
            inactivityTimer.restart()
        }

        // Poll for gamepad input only when the window is in focus
        SdlGamepadKeyNavigation.notifyWindowFocus(visible && active)
    }

    function navigateTo(url, objectType)
    {
        var existingItem = stackView.find(function(item, index) {
            return item instanceof objectType
        })

        if (existingItem !== null) {
            // Pop to the existing item
            stackView.pop(existingItem)
        }
        else {
            // Create a new item
            stackView.push(url)
        }
    }

    // Toolbar overlay.
    ToolBar {
        id: toolBar

        // Segue pages change shown, allowing opacity to animate before visible becomes
        // false and rendering stops.
        property bool shown: true
        opacity: shown ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            NumberAnimation { duration: 220; easing.type: Easing.InOutQuad }
        }

        height: 56
        anchors.top: parent.top
        anchors.topMargin: -window.chromeInset
        anchors.left: parent.left
        anchors.right: parent.right
        z: 1

        // Qt 6.9 adds safe-area padding to Control, reducing usable toolbar height.
        // This toolbar intentionally replaces the titlebar, so zero all padding and
        // reserve native control space explicitly with windowButtonInsetLeft.
        topPadding: 0
        bottomPadding: 0
        leftPadding: 0
        rightPadding: 0

        // Qt's safe area reports titlebar height but not horizontal control occupancy.
        // Reserve space for native window buttons explicitly.
        //
        // macOS controls start at x=20 and span 60 points; add 20 points of spacing,
        // then subtract RowLayout's spaceLg(16): 84. Keep in sync with kButtonLeftMargin.
        //
        // Windows has three custom 44-pixel window buttons on the right.
        //
        // No side inset in fullscreen, where macOS hides window controls until hovered.
        readonly property bool windowChromeVisible: window.visibility !== Window.FullScreen
        readonly property int customWindowControlsWidth: 132
        readonly property int windowButtonInsetLeft:
            (SystemProperties.isDarwin && windowChromeVisible) ? 84 : 0
        readonly property int windowButtonInsetRight:
            (Qt.platform.os === "windows" && windowChromeVisible)
                ? customWindowControlsWidth : 0

        // Attach the toolbar to the top edge with a one-pixel bottom separator.
        // A partially transparent background connects it visually to the wallpaper
        // without blur or a detached floating appearance.
        background: Rectangle {
            color: Qt.rgba(Theme.ink.r, Theme.ink.g, Theme.ink.b, 0.55)

            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 1
                color: Theme.line
            }
        }

        RowLayout {
            spacing: Theme.spaceSm
            anchors.leftMargin: Theme.spaceLg + toolBar.windowButtonInsetLeft
            anchors.rightMargin: Theme.spaceLg + toolBar.windowButtonInsetRight
            anchors.fill: parent

            NavigableToolButton {
                // Only make the button visible if the user has navigated somewhere.
                visible: stackView.depth > 1

                iconSource: "qrc:/res/fluent/tb-back.svg"

                onClicked: goBack()

                Keys.onDownPressed: {
                    stackView.currentItem.forceActiveFocus(Qt.TabFocusReason)
                }
            }

            // The title fills non-button toolbar space. Windows uses it for native
            // hit testing, Linux uses MouseArea, and macOS delegates to AppKit.
            Item {
                id: titleDragRegion
                Layout.fillHeight: true
                Layout.fillWidth: true

                RowLayout {
                    anchors.fill: parent
                    spacing: Theme.spaceSm

                    Text {
                        id: wordmark
                        visible: toolBar.width > 700
                        text: "MOONLIGHT V+ FOR PC"
                        color: Theme.text
                        font.family: Theme.fontSans
                        font.pointSize: Theme.fontCardTitle
                        font.weight: Font.ExtraBold
                        font.letterSpacing: Theme.tracking(Theme.fontCardTitle, 0.1)
                        verticalAlignment: Text.AlignVCenter
                        Layout.fillHeight: true
                    }

                    Text {
                        visible: wordmark.visible
                        text: "/"
                        color: Theme.textFaint
                        font.family: Theme.fontMono
                        font.pointSize: Theme.fontCardTitle
                        verticalAlignment: Text.AlignVCenter
                        Layout.fillHeight: true
                        Layout.leftMargin: Theme.spaceXs
                        Layout.rightMargin: Theme.spaceXs
                    }

                    Text {
                        id: titleRowLabel
                        text: stackView.currentItem ? stackView.currentItem.objectName : ""
                        color: Theme.accent
                        font.family: Theme.fontSans
                        font.pointSize: Theme.fontRowTitle
                        font.weight: Font.Bold
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: Theme.tracking(Theme.fontRowTitle, 0.14)
                        elide: Text.ElideRight
                        verticalAlignment: Text.AlignVCenter
                        Layout.fillHeight: true
                        Layout.fillWidth: true
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    enabled: Qt.platform.os !== "windows" && !SystemProperties.isDarwin

                    property point pressPosition
                    property bool systemMoveStarted: false

                    onPressed: function(mouse) {
                        pressPosition = Qt.point(mouse.x, mouse.y)
                        systemMoveStarted = false
                    }
                    onPositionChanged: function(mouse) {
                        if (!pressed || systemMoveStarted) {
                            return
                        }

                        var deltaX = Math.abs(mouse.x - pressPosition.x)
                        var deltaY = Math.abs(mouse.y - pressPosition.y)
                        if (Math.max(deltaX, deltaY) >= Qt.styleHints.startDragDistance) {
                            systemMoveStarted = true
                            window.startSystemMove()
                        }
                    }
                    onDoubleClicked: {
                        if (window.visibility === Window.Maximized) {
                            window.showNormal()
                        }
                        else {
                            window.showMaximized()
                        }
                    }
                }
            }

            Text {
                id: versionLabel
                visible: stackView.currentItem instanceof SettingsView
                text: qsTr("Version %1").arg(SystemProperties.versionString)
                color: Theme.textDim
                font.family: Theme.fontMono
                font.pointSize: Theme.fontCaption
                horizontalAlignment: Qt.AlignRight
                verticalAlignment: Text.AlignVCenter
                Layout.fillHeight: true
                Layout.rightMargin: Theme.spaceSm
            }

            NavigableToolButton {
                id: addPcButton
                visible: stackView.currentItem instanceof PcView

                iconSource:  "qrc:/res/fluent/tb-add-pc.svg"

                ToolTip.delay: 1000
                ToolTip.timeout: 3000
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Add PC manually") + (newPcShortcut.nativeText ? (" ("+newPcShortcut.nativeText+")") : "")

                Shortcut {
                    id: newPcShortcut
                    sequence: StandardKey.New
                    onActivated: addPcButton.clicked()
                }

                onClicked: {
                    addPcDialog.open()
                }

                Keys.onDownPressed: {
                    stackView.currentItem.forceActiveFocus(Qt.TabFocusReason)
                }
            }

            NavigableToolButton {
                property string browserUrl: ""

                id: updateButton

                iconSource: "qrc:/res/fluent/tb-update.svg"

                ToolTip.delay: 1000
                ToolTip.timeout: 3000
                ToolTip.visible: hovered || visible

                // Invisible until we get a callback notifying us that
                // an update is available
                visible: false

                onClicked: {
                    if (AutoUpdateChecker.supportsInAppUpdate()) {
                        portableUpdateDialog.text = qsTr("Preparing update...")
                        portableUpdateDialog.open()
                        AutoUpdateChecker.installUpdate(browserUrl)
                    }
                    else if (SystemProperties.hasBrowser) {
                        Qt.openUrlExternally(browserUrl);
                    }
                }

                function updateAvailable(version, url)
                {
                    ToolTip.text = Brand.text(qsTr("Update available for Moonlight: Version %1")).arg(version)
                    updateButton.browserUrl = url
                    updateButton.visible = true
                }

                function portableUpdateStatusChanged(message)
                {
                    portableUpdateDialog.text = message
                    if (!portableUpdateDialog.visible) {
                        portableUpdateDialog.open()
                    }
                }

                function portableUpdateFailed(message)
                {
                    portableUpdateDialog.close()
                    portableUpdateErrorDialog.text = message
                    portableUpdateErrorDialog.open()
                }

                Component.onCompleted: {
                    AutoUpdateChecker.onUpdateAvailable.connect(updateAvailable)
                    AutoUpdateChecker.onPortableUpdateStatusChanged.connect(portableUpdateStatusChanged)
                    AutoUpdateChecker.onPortableUpdateFailed.connect(portableUpdateFailed)
                    if (StreamingPreferences.autoUpdateCheck) {
                        AutoUpdateChecker.start()
                    }
                }

                Keys.onDownPressed: {
                    stackView.currentItem.forceActiveFocus(Qt.TabFocusReason)
                }
            }

            NavigableToolButton {
                id: helpButton
                visible: SystemProperties.hasBrowser

                iconSource: "qrc:/res/fluent/tb-help.svg"

                ToolTip.delay: 1000
                ToolTip.timeout: 3000
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Help") + (helpShortcut.nativeText ? (" ("+helpShortcut.nativeText+")") : "")

                Shortcut {
                    id: helpShortcut
                    sequence: StandardKey.HelpContents
                    onActivated: helpButton.clicked()
                }

                // TODO need to make sure browser is brought to foreground.
                onClicked: Qt.openUrlExternally("https://github.com/moonlight-stream/moonlight-docs/wiki/Setup-Guide");

                Keys.onDownPressed: {
                    stackView.currentItem.forceActiveFocus(Qt.TabFocusReason)
                }
            }

            NavigableToolButton {
                // TODO: Implement gamepad mapping then unhide this button
                visible: false

                ToolTip.delay: 1000
                ToolTip.timeout: 3000
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Gamepad Mapper")

                iconSource: "qrc:/res/fluent/tb-gamepad.svg"

                onClicked: navigateTo("qrc:/gui/GamepadMapper.qml", GamepadMapper)

                Keys.onDownPressed: {
                    stackView.currentItem.forceActiveFocus(Qt.TabFocusReason)
                }
            }

            NavigableToolButton {
                id: ipSettingsButton
                visible: stackView.currentItem instanceof AppView &&
                         stackView.currentItem.hasMultipleAddresses

                iconSource: "qrc:/res/fluent/tb-network.svg"

                ToolTip.delay: 1000
                ToolTip.timeout: 3000
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Connection IP")

                onClicked: {
                    if (stackView.currentItem.openIpDialog) {
                        stackView.currentItem.openIpDialog()
                    }
                }

                Keys.onDownPressed: {
                    stackView.currentItem.forceActiveFocus(Qt.TabFocusReason)
                }
            }

            NavigableToolButton {
                id: displaySettingsButton
                visible: stackView.currentItem instanceof AppView

                iconSource: "qrc:/res/fluent/tb-display.svg"

                ToolTip.delay: 1000
                ToolTip.timeout: 3000
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Display Settings")

                onClicked: {
                    if (stackView.currentItem.openDisplayDialog) {
                        stackView.currentItem.openDisplayDialog()
                    }
                }

                Keys.onDownPressed: {
                    stackView.currentItem.forceActiveFocus(Qt.TabFocusReason)
                }
            }

            NavigableToolButton {
                id: settingsButton

                visible: !(stackView.currentItem instanceof SettingsView)

                iconSource:  "qrc:/res/fluent/tb-settings.svg"

                onClicked: navigateTo("qrc:/gui/SettingsView.qml", SettingsView)

                Keys.onDownPressed: {
                    stackView.currentItem.forceActiveFocus(Qt.TabFocusReason)
                }

                Shortcut {
                    id: settingsShortcut
                    sequence: StandardKey.Preferences
                    // Disable the shortcut while its settings entry is hidden to avoid duplicate pages.
                    enabled: settingsButton.visible
                    onActivated: settingsButton.clicked()
                }

                ToolTip.delay: 1000
                ToolTip.timeout: 3000
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Settings") + (settingsShortcut.nativeText ? (" ("+settingsShortcut.nativeText+")") : "")
            }
        }

        Row {
            id: windowControls
            visible: Qt.platform.os === "windows" && toolBar.windowChromeVisible
            anchors.top: parent.top
            anchors.right: parent.right
            height: parent.height
            z: 2

            WindowControlButton {
                controlType: "minimize"
                accessibleName: qsTr("Minimize")
                highlightColor: Theme.acid
                onClicked: windowsWindowChrome.minimize()
            }

            WindowControlButton {
                controlType: windowsWindowChrome.maximized ? "restore" : "maximize"
                accessibleName: windowsWindowChrome.maximized
                                ? qsTr("Restore") : qsTr("Maximize")
                highlightColor: Theme.accent
                onClicked: windowsWindowChrome.toggleMaximized()
            }

            WindowControlButton {
                controlType: "close"
                accessibleName: qsTr("Close")
                highlightColor: Theme.danger
                onClicked: windowsWindowChrome.close()
            }
        }
    }

    ErrorMessageDialog {
        id: noHwDecoderDialog
        text: Brand.text(qsTr("No functioning hardware accelerated video decoder was detected by Moonlight. " +
                              "Your streaming performance may be severely degraded in this configuration."))
        helpText: qsTr("Click the Help button for more information on solving this problem.")
        helpUrl: "https://github.com/moonlight-stream/moonlight-docs/wiki/Fixing-Hardware-Decoding-Problems"
    }

    NavigableMessageDialog {
        id: portableUpdateDialog
        standardButtons: Dialog.NoButton
        closePolicy: Popup.CloseOnEscape
        showSpinner: true
        text: qsTr("Preparing update...")
    }

    BackgroundSourceDialog {
        id: backgroundSourceDialog

        onSourceChosen: function(source) {
            window.commitInitialBackgroundSource(source)
        }

        Connections {
            target: backgroundSourceDialog
            function onClosed() {
                // Escape and window-manager close mean “decide later”: keep the
                // photography default, mark the picker handled, then continue startup.
                if (!window.initialBackgroundChoiceHandled) {
                    window.commitInitialBackgroundSource(StreamingPreferences.BGS_PHOTOGRAPHY)
                }
                window.startConfigurationChecks()
            }
        }
    }

    ErrorMessageDialog {
        id: portableUpdateErrorDialog
        text: ""
    }

    ErrorMessageDialog {
        id: xWaylandDialog
        text: qsTr("Hardware acceleration doesn't work on XWayland. Continuing on XWayland may result in poor streaming performance. " +
                   "Try running with QT_QPA_PLATFORM=wayland or switch to X11.")
        helpText: qsTr("Click the Help button for more information.")
        helpUrl: "https://github.com/moonlight-stream/moonlight-docs/wiki/Fixing-Hardware-Decoding-Problems"
    }

    NavigableMessageDialog {
        id: wow64Dialog
        standardButtons: Dialog.Ok | Dialog.Cancel
        text: Brand.text(qsTr("This version of Moonlight isn't optimized for your PC. Please download the '%1' version of Moonlight for the best streaming performance.")).arg(SystemProperties.friendlyNativeArchName)
        onAccepted: {
            Qt.openUrlExternally("https://github.com/mikulicf/moonlight-vplus/releases");
        }
    }

    ErrorMessageDialog {
        id: unmappedGamepadDialog
        property string unmappedGamepads : ""
        text: Brand.text(qsTr("Moonlight detected gamepads without a mapping:")) + "\n" + unmappedGamepads
        helpTextSeparator: "\n\n"
        helpText: qsTr("Click the Help button for information on how to map your gamepads.")
        helpUrl: "https://github.com/moonlight-stream/moonlight-docs/wiki/Gamepad-Mapping"
    }

    // This dialog appears when quitting via keyboard or gamepad button
    NavigableMessageDialog {
        id: quitConfirmationDialog
        standardButtons: Dialog.Yes | Dialog.No
        text: qsTr("Are you sure you want to quit?")
        // For keyboard/gamepad navigation
        onAccepted: Qt.quit()
    }

    // HACK: This belongs in StreamSegue but keeping a dialog around after the parent
    // dies can trigger bugs in Qt 5.12 that cause the app to crash. For now, we will
    // host this dialog in a QML component that is never destroyed.
    //
    // To repro: Start a stream, cut the network connection to trigger the "Connection
    // terminated" dialog, wait until the app grid times out back to the PC grid, then
    // try to dismiss the dialog.
    ErrorMessageDialog {
        id: streamSegueErrorDialog

        property bool quitAfter: false

        onClosed: {
            if (quitAfter) {
                Qt.quit()
            }

            // StreamSegue assumes its dialog will be re-created each time we
            // start streaming, so fake it by wiping out the text each time.
            text = ""
        }
    }

    NavigableDialog {
        id: addPcDialog
        property string label: qsTr("Enter the IP address of your host PC:")

        standardButtons: Dialog.Ok | Dialog.Cancel

        onOpened: {
            // Force keyboard focus on the textbox so keyboard navigation works
            editText.forceActiveFocus()
        }

        onClosed: {
            editText.clear()
        }

        onAccepted: {
            if (editText.text) {
                ComputerManager.addNewHostManually(editText.text.trim())
            }
        }

        ColumnLayout {
            spacing: Theme.spaceSm

            Text {
                text: addPcDialog.label
                color: Theme.text
                font.family: Theme.fontSans
                font.pointSize: Theme.fontRowTitle
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }

            HardTextField {
                id: editText
                placeholderText: "192.168.1.100"
                Layout.fillWidth: true
                Layout.minimumWidth: 260
                focus: true

                Keys.onReturnPressed: {
                    addPcDialog.accept()
                }

                Keys.onEnterPressed: {
                    addPcDialog.accept()
                }
            }


        }
    }
}
