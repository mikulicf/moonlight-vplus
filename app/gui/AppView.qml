// Leave QtQuick unversioned: HoverHandler requires QtQuick 2.15 / Qt 5.15.
// Importing 2.9 compiles with qmlcachegen but fails type resolution at runtime,
// preventing the app view from loading. Existing unversioned Controls imports
// already establish the same minimum version.
import QtQuick
import QtQuick.Controls
import QtQuick.Window 2.2

import AppModel 1.0
import ComputerManager 1.0
import SdlGamepadKeyNavigation 1.0
import StreamingPreferences 1.0

import "theme"

CenteredGridView {
    // This page provides its own wallpaper; main.qml must not add another layer.
    readonly property bool usesOwnBackground: true
    readonly property int nameRole: AppModel.NameRole
    readonly property int runningRole: AppModel.RunningRole
    readonly property int boxArtRole: AppModel.BoxArtRole
    readonly property int hiddenRole: AppModel.HiddenRole
    readonly property int appIdRole: AppModel.AppIdRole
    readonly property int directLaunchRole: AppModel.DirectLaunchRole
    readonly property int appCollectorGameRole: AppModel.AppCollectorGameRole

    property int computerIndex
    property AppModel appModel : createModel()
    property bool activated
    property bool showHiddenGames
    property bool showGames

    id: appGrid
    focus: true
    activeFocusOnTab: true
    topMargin: 72   // 56-pixel toolbar plus one spacing unit.
    bottomMargin: 5
    cellWidth: 230; cellHeight: 297;

    // Selected display UI ID: empty for none, vdd for VDD, otherwise a unique physical ID.
    property string selectedDisplayId: ""
    // Host display target is separate from the UI ID to distinguish duplicate display names.
    property string selectedDisplayTarget: ""
    // Whether the selected display is a VDD.
    property bool isVddSelected: selectedDisplayId === "vdd"
    // Physical display list.
    property var displayList: []
    // Whether multiple connection addresses are available.
    property bool hasMultipleAddresses: appModel.hasMultipleConnectionAddresses()
    // Current active address information.
    property var activeAddressInfo: appModel.getActiveAddressInfo()

    // Use AbstractButton so the only display/VDD selector participates in keyboard
    // and gamepad focus navigation; Rectangle plus MouseArea could not be reached.
    //
    // AppView uses normal gamepad navigation (uiNavMode false), with direction keys
    // rather than Tab. Handle horizontal chips and vertical entry to the combination selector.
    component DisplayChip: AbstractButton {
        id: chip

        property bool selected: false
        property color selectedFill: Theme.accent
        property color selectedBorder: Theme.accentStrong

        implicitWidth: chipLabel.implicitWidth + Theme.spaceXl
        implicitHeight: 32

        activeFocusOnTab: true
        hoverEnabled: true

        HoverHandler {
            cursorShape: Qt.PointingHandCursor
        }

        background: Rectangle {
            radius: 0
            color: chip.selected ? chip.selectedFill
                                 : (chip.hovered ? Theme.surface : Theme.surface2)
            border.color: chip.selected ? chip.selectedBorder : Theme.lineStrong
            border.width: 1

            // Selected chips use a solid accent fill, so show focus with the shared
            // external square ring rather than an invisible accent-on-accent border.
            FocusRing {
                visible: chip.visualFocus
            }

            Behavior on color {
                ColorAnimation { duration: Theme.durFast }
            }
        }

        contentItem: Text {
            id: chipLabel
            text: chip.text
            color: chip.selected ? Theme.ink : Theme.textDim
            font.family: Theme.fontSans
            font.pointSize: Theme.fontBody
            font.bold: chip.selected
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }

        // Explicit downward focus target: Flow's next focus item is horizontal.
        // An empty target consumes the key because there is no control below.
        property Item navDownItem: null

        function moveFocus(forward) {
            nextItemInFocusChain(forward).forceActiveFocus(Qt.TabFocusReason)
        }

        Keys.onReturnPressed: clicked()
        Keys.onEnterPressed: clicked()
        // Horizontal focus-chain order matches the Flow's visual order.
        Keys.onRightPressed: moveFocus(true)
        Keys.onLeftPressed: moveFocus(false)
        Keys.onDownPressed: if (navDownItem) navDownItem.forceActiveFocus(Qt.TabFocusReason)
        // Nothing above the chips accepts focus; consume upward navigation.
        Keys.onUpPressed: {}
    }

    // Load the display list.
    function loadDisplays() {
        var displays = appModel.getDisplayList()
        var selectedDisplayStillAvailable = selectedDisplayId === "" || selectedDisplayId === "vdd"
        displayList = displays
        displayListModel.clear()
        for (var i = 0; i < displays.length; i++) {
            displayListModel.append({
                "displayName": displays[i].name,
                "displayId": displays[i].id,
                "displayTarget": displays[i].target,
                "displayIndex": displays[i].index
            })

            if (selectedDisplayId === displays[i].id &&
                    selectedDisplayTarget === displays[i].target) {
                selectedDisplayStillAvailable = true
            }
        }

        if (!selectedDisplayStillAvailable) {
            selectedDisplayId = ""
            selectedDisplayTarget = ""
        }
    }

    // Display selection dialog.
    function openDisplayDialog() {
        loadDisplays()
        displayDialog.open()
    }

    // Address selection dialog.
    function openIpDialog() {
        ipDialog.addresses = appModel.getConnectionAddresses()
        ipDialog.open()
    }

    // NavigableDialog provides the square panel, dimming, title, and focus restoration.
    NavigableDialog {
        id: displayDialog

        title: qsTr("Display Settings")
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        // Set width explicitly to avoid a binding loop with the Column's availableWidth.
        width: Math.min(500, appGrid.width - 40)

        // Selection applies immediately; close with B, Escape, or an outside click.
        // Without standardButtons, NavigableDialog hides its footer.

        // Focus the selected display on opening so gamepad users immediately see selection.
        onOpened: focusInitialItem()

        // The base onClosed restores stackView focus; refine it to the app grid here.
        // QML handlers accumulate, so the base handler still runs.
        onClosed: appGrid.forceActiveFocus()

        function focusInitialItem() {
            for (var i = 0; i < displayChips.children.length; i++) {
                var chip = displayChips.children[i]
                // Repeater is also a child but has no selected property and is skipped.
                if (chip.selected) {
                    chip.forceActiveFocus(Qt.TabFocusReason)
                    return
                }
            }
            hostDefaultChip.forceActiveFocus(Qt.TabFocusReason)
        }

        Column {
            width: displayDialog.availableWidth
            spacing: Theme.spaceLg

            // NavigableDialog supplies the title and separator in its header.

            // Display selection area.
            MicroLabel {
                text: qsTr("Select Display:")
            }

            Flow {
                id: displayChips
                width: parent.width
                spacing: Theme.spaceSm

                DisplayChip {
                    id: hostDefaultChip
                    //: Display option that lets the host choose the display.
                    text: qsTr("Default", "display selection")
                    selected: selectedDisplayId === ""
                    navDownItem: combinationModeSelector.firstItem

                    onClicked: {
                        selectedDisplayId = ""
                        selectedDisplayTarget = ""
                    }
                }

                // Dynamically generated physical display buttons.
                Repeater {
                    model: ListModel { id: displayListModel }

                    DisplayChip {
                        text: model.displayName
                        selected: selectedDisplayId === model.displayId
                        navDownItem: combinationModeSelector.firstItem

                        onClicked: {
                            selectedDisplayId = model.displayId
                            selectedDisplayTarget = model.displayTarget
                        }
                    }
                }

                // VDD button.
                DisplayChip {
                    id: vddChip
                    text: qsTr("VDD Display")
                    selected: isVddSelected
                    selectedFill: Theme.acid
                    selectedBorder: Theme.acid
                    navDownItem: combinationModeSelector.firstItem

                    onClicked: {
                        selectedDisplayId = "vdd"
                        selectedDisplayTarget = "vdd"
                    }
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spaceSm

                Rectangle {
                    width: parent.width
                    height: 1
                    color: Theme.line
                }

                MicroLabel {
                    text: qsTr("Screen Combination Mode:")
                }

                ScreenCombinationModeSelector {
                    id: combinationModeSelector
                    width: parent.width
                    compact: true
                    saveOnSelection: true
                    navUpItem: vddChip
                }
            }
        }
    }

    function computerLost()
    {
        // Go back to the PC view on PC loss
        stackView.pop()
    }

    Component.onCompleted: {
        // Don't show any highlighted item until interacting with them.
        // We do this here instead of onActivated to avoid losing the user's
        // selection when backing out of a different page of the app.
        currentIndex = -1
    }

    // Re-syncs the "running" badge against the latest NvComputer state. The
    // polling thread can update currentGameId through a code path that
    // doesn't reach AppModel's slot (e.g. mDNS PendingAddTask folding under
    // contended locks), leaving the badge stale after we return from a
    // stream. We re-check on activation and again a few ticks later to cover
    // the case where the host hasn't finished tearing down the prior
    // session by the time onActivated fires.
    Timer {
        id: postActivationResyncTimer
        interval: 500
        repeat: true
        property int ticksLeft: 0
        onTriggered: {
            appModel.forceSyncCurrentGame()
            if (--ticksLeft <= 0) {
                stop()
            }
        }
        function kick() {
            ticksLeft = 4   // 0.5s, 1.0s, 1.5s, 2.0s
            restart()
        }
    }

    StackView.onActivated: {
        appModel.computerLost.connect(computerLost)
        activated = true

        // Load available displays from the host.
        loadDisplays()

        // Self-heal the running-game indicator in case our cached state
        // drifted from NvComputer's actual currentGameId while we were
        // on another page (typically during a streaming session).
        appModel.forceSyncCurrentGame()
        postActivationResyncTimer.kick()

        // Highlight the first item if a gamepad is connected
        if (currentIndex === -1 && SdlGamepadKeyNavigation.getConnectedGamepads() > 0) {
            currentIndex = 0
        }

        if (!showGames && !showHiddenGames) {
            // Check if there's a direct launch app
            var directLaunchAppIndex = model.getDirectLaunchAppIndex();
            if (directLaunchAppIndex >= 0) {
                // Start the direct launch app if nothing else is running
                currentIndex = directLaunchAppIndex
                currentItem.launchOrResumeSelectedApp(false)

                // Set showGames so we will not loop when the stream ends
                showGames = true
            }
        }
    }

    StackView.onDeactivating: {
        appModel.computerLost.disconnect(computerLost)
        activated = false
    }

    function createModel()
    {
        var model = Qt.createQmlObject('import AppModel 1.0; AppModel {}', parent, '')
        model.initialize(ComputerManager, computerIndex, showHiddenGames)
        return model
    }

    model: appModel

    delegate: NavigableItemDelegate {
        id: appTile

        width: 220; height: 287;
        grid: appGrid
        padding: 0

        property alias appContextMenu: appContextMenuLoader.item
        property alias appNameText: appNameTextLoader.item

        // Use the same visual treatment for hover, gamepad highlight, and keyboard focus.
        readonly property bool active: hovered || highlighted

        // Dim the app if it's hidden
        opacity: model.hidden ? 0.4 : 1.0

        // Share one lift animation value between Panel and the separate content layer
        // so the two cannot become misaligned.
        property real tileShift: active ? -3 : 0

        Behavior on tileShift {
            NumberAnimation { duration: Theme.durFast; easing.type: Theme.easing }
        }

        // Replace FluentWinUI3's rounded hover background with this square card.
        // Interactive content belongs in tileBody, not the background.
        background: Panel {
            lifted: appTile.active
            liftShift: appTile.tileShift
            fill: Theme.ink
            borderColor: appTile.active ? Theme.accent : Theme.line

            // Running apps have a lime accent bar, matching the LIVE badge.
            accentBarColor: Theme.acid
            accentBarWidth: model.running ? Theme.accentBarStrong : 0
        }

        // Keep cover art, information, badges, and Resume/Quit controls outside the background.
        //
        // Controls inside Panel's background could not receive clicks: Control assigns
        // background z = -1, and Qt tests nonnegative children, the control itself, then
        // negative children. ItemDelegate therefore consumed the click before those buttons.
        //
        // Follow Panel's three-pixel lift with the same tileShift to align art and border.
        Item {
            id: tileBody

            // Reserve space for the running-state accent bar on the left.
            readonly property int barInset: model.running ? Theme.accentBarStrong : 0

            x: appTile.tileShift + 1 + barInset   // Preserve Panel's one-pixel border.
            y: appTile.tileShift + 1
            width: appTile.width - 2 - barInset
            height: appTile.height - 2
            clip: true

            Image {
                property bool isPlaceholder: false
                readonly property real requestedDpr:
                    Window.window ? Window.window.devicePixelRatio : 1

                id: appIcon

                // Fill the tile with cover art instead of centering a fixed-size image.
                anchors.fill: parent
                source: model.boxart
                sourceSize: Qt.size(Math.max(1, Math.ceil(width * requestedDpr)),
                                    Math.max(1, Math.ceil(height * requestedDpr)))
                fillMode: Image.PreserveAspectCrop
                asynchronous: true

                onSourceChanged: {
                    // BoxArtManager normalizes host placeholders to this resource
                    // before display, so source-size decoding cannot break detection.
                    isPlaceholder = source.toString() === "qrc:/res/no_app_image.png"
                }

                // Display a tooltip with the full name if it's truncated
                ToolTip.text: model.name
                ToolTip.delay: 1000
                ToolTip.timeout: 5000
                ToolTip.visible: appTile.active &&
                                 (nameLabel.truncated || (appNameText && appNameText.truncated))
            }

            // Place the large placeholder title after the cover but below running-state
            // controls. The running overlay excludes placeholders, preserving title visibility.
            Loader {
                id: appNameTextLoader
                active: appIcon.isPlaceholder

                // This loader is not asynchronous to avoid noticeable differences
                // in the time in which the text loads for each game.

                anchors {
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                }
                height: model.running ? 175 : parent.height

                sourceComponent: Text {
                    id: appNameText
                    text: model.name
                    color: Theme.text
                    font.family: Theme.fontSans
                    font.pointSize: 20
                    font.weight: Font.ExtraBold
                    font.letterSpacing: Theme.trackingTight(20)
                    leftPadding: Theme.spaceLg
                    rightPadding: Theme.spaceLg
                    verticalAlignment: Text.AlignVCenter
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    elide: Text.ElideRight
                }
            }

            // The bottom bar makes names readable on real covers; placeholders retain
            // their large title instead.
            Rectangle {
                id: infoBar

                anchors {
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                }
                height: infoColumn.implicitHeight + Theme.spaceSm * 2
                color: Qt.rgba(Theme.ink.r, Theme.ink.g, Theme.ink.b, 0.92)
                visible: !appIcon.isPlaceholder

                Rectangle {
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    height: 1
                    color: Theme.line
                }

                Column {
                    id: infoColumn

                    anchors {
                        left: parent.left
                        right: parent.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: Theme.spaceSm
                        rightMargin: Theme.spaceSm
                    }
                    spacing: 2

                    Text {
                        id: nameLabel

                        width: parent.width
                        text: model.name
                        color: Theme.text
                        font.family: Theme.fontSans
                        font.pointSize: Theme.fontRowTitle
                        font.weight: Font.DemiBold
                        font.letterSpacing: Theme.trackingTight(Theme.fontRowTitle)
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }

                    MicroLabel {
                        width: parent.width
                        text: qsTr("Direct Launch")
                        color: Theme.accent
                        visible: model.directLaunch
                        height: visible ? implicitHeight : 0
                    }
                }
            }

            Loader {
                active: model.running
                asynchronous: true

                // Leave the information bar visible while the app is running.
                anchors.fill: parent
                anchors.bottomMargin: infoBar.visible ? infoBar.height : 0

                sourceComponent: Item {
                    // Dim cover art for readable buttons; flat placeholder art needs no dimming.
                    Rectangle {
                        anchors.fill: parent
                        color: Qt.rgba(Theme.ink.r, Theme.ink.g, Theme.ink.b, 0.55)
                        visible: !appIcon.isPlaceholder
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        // Move buttons above the large placeholder title.
                        anchors.verticalCenterOffset: appIcon.isPlaceholder ? -70 : 0
                        spacing: Theme.spaceMd

                        HardButton {
                            // Don't steal focus from the toolbar buttons
                            focusPolicy: Qt.NoFocus

                            width: 62; height: 62

                            icon.source: "qrc:/res/play_arrow_FILL1_wght700_GRAD200_opsz48.svg"
                            icon.width: 34
                            icon.height: 34
                            icon.color: Theme.text

                            onClicked: {
                                launchOrResumeSelectedApp(true)
                            }

                            ToolTip.text: qsTr("Resume Game")
                            ToolTip.delay: 1000
                            ToolTip.timeout: 3000
                            ToolTip.visible: hovered
                        }

                        HardButton {
                            // Don't steal focus from the toolbar buttons
                            focusPolicy: Qt.NoFocus

                            width: 62; height: 62

                            icon.source: "qrc:/res/stop_FILL1_wght700_GRAD200_opsz48.svg"
                            icon.width: 34
                            icon.height: 34
                            icon.color: Theme.danger

                            onClicked: {
                                doQuitGame()
                            }

                            ToolTip.text: qsTr("Quit Game")
                            ToolTip.delay: 1000
                            ToolTip.timeout: 3000
                            ToolTip.visible: hovered
                        }
                    }
                }
            }

            // Declare LIVE/HIDDEN badges last so the running overlay cannot dim them.
            // Status markers should remain the brightest part of the tile.
            //
            // Place the translucent lime glow below the badge without requiring QtGraphicalEffects.
            Rectangle {
                anchors.fill: liveBadge
                anchors.margins: -3
                color: Theme.acidGlow
                visible: liveBadge.visible
            }

            Rectangle {
                id: liveBadge

                anchors {
                    left: parent.left
                    top: parent.top
                    leftMargin: Theme.spaceSm
                    topMargin: Theme.spaceSm
                }
                width: liveText.implicitWidth + Theme.spaceSm * 2
                height: liveText.implicitHeight + Theme.spaceXs * 2
                color: Theme.acid
                visible: model.running

                MicroLabel {
                    id: liveText
                    anchors.centerIn: parent
                    text: "● " + qsTr("Live")
                    color: Theme.ink
                }
            }

            Rectangle {
                anchors {
                    right: parent.right
                    top: parent.top
                    rightMargin: Theme.spaceSm
                    topMargin: Theme.spaceSm
                }
                width: hiddenText.implicitWidth + Theme.spaceSm * 2
                height: hiddenText.implicitHeight + Theme.spaceXs * 2
                color: Theme.surface2
                border.width: 1
                border.color: Theme.lineStrong
                visible: model.hidden

                MicroLabel {
                    id: hiddenText
                    anchors.centerIn: parent
                    text: qsTr("Hidden")
                }
            }
        }

        function launchOrResumeSelectedApp(quitExistingApp)
        {
            var runningId = appModel.getRunningAppId()
            if (runningId !== 0 && runningId !== model.appid) {
                if (quitExistingApp) {
                    quitAppDialog.appName = appModel.getRunningAppName()
                    quitAppDialog.segueToStream = true
                    quitAppDialog.nextAppName = model.name
                    quitAppDialog.nextAppIndex = index
                    quitAppDialog.open()
                }

                return
            }

            var component = Qt.createComponent("StreamSegue.qml")
            var segue = component.createObject(stackView, {
                                                   "appName": model.name,
                                                   "boxArtUrl": model.boxart,
                                                   "session": appModel.createSessionForApp(index, selectedDisplayTarget),
                                                   "isResume": runningId === model.appid
                                               })
            stackView.push(segue)
        }

        onClicked: {
            // Only allow clicking on the box art for non-running games.
            // For running games, buttons will appear to resume or quit which
            // will handle starting the game and clicks on the box art will
            // be ignored.
            if (!model.running) {
                launchOrResumeSelectedApp(true)
            }
        }

        onPressAndHold: {
            // popup() ensures the menu appears under the mouse cursor
            if (appContextMenu.popup) {
                appContextMenu.popup()
            }
            else {
                // Qt 5.9 doesn't have popup()
                appContextMenu.open()
            }
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.RightButton;
            onClicked: {
                parent.pressAndHold()
            }
        }

        Keys.onReturnPressed: {
            // Open the app context menu if activated via the gamepad or keyboard
            // for running games. If the game isn't running, the above onClicked
            // method will handle the launch.
            if (model.running) {
                // This will be keyboard/gamepad driven so use
                // open() instead of popup()
                appContextMenu.open()
            }
        }

        Keys.onEnterPressed: {
            // Open the app context menu if activated via the gamepad or keyboard
            // for running games. If the game isn't running, the above onClicked
            // method will handle the launch.
            if (model.running) {
                // This will be keyboard/gamepad driven so use
                // open() instead of popup()
                appContextMenu.open()
            }
        }

        Keys.onMenuPressed: {
            // This will be keyboard/gamepad driven so use open() instead of popup()
            appContextMenu.open()
        }

        function doQuitGame() {
            quitAppDialog.appName = appModel.getRunningAppName()
            quitAppDialog.segueToStream = false
            quitAppDialog.open()
        }

        Loader {
            id: appContextMenuLoader
            asynchronous: true
            sourceComponent: NavigableMenu {
                id: appContextMenu
                initiator: appContextMenuLoader.parent
                NavigableMenuItem {
                    text: model.running ? qsTr("Resume Game") : qsTr("Launch Game")
                    onTriggered: launchOrResumeSelectedApp(true)
                }
                NavigableMenuItem {
                    text: qsTr("Quit Game")
                    onTriggered: doQuitGame()
                    visible: model.running
                }
                NavigableMenuItem {
                    checkable: true
                    checked: model.directLaunch
                    text: qsTr("Direct Launch")
                    onTriggered: appModel.setAppDirectLaunch(model.index, !model.directLaunch)
                    enabled: !model.hidden

                    ToolTip.text: qsTr("Launch this app immediately when the host is selected, bypassing the app selection grid.")
                    ToolTip.delay: 1000
                    ToolTip.timeout: 3000
                    ToolTip.visible: hovered
                }
                NavigableMenuItem {
                    checkable: true
                    checked: model.hidden
                    text: qsTr("Hide Game")
                    onTriggered: appModel.setAppHidden(model.index, !model.hidden)
                    enabled: model.hidden || (!model.running && !model.directLaunch)

                    ToolTip.text: qsTr("Hide this game from the app grid. To access hidden games, right-click on the host and choose %1.").arg(qsTr("View All Apps"))
                    ToolTip.delay: 1000
                    ToolTip.timeout: 5000
                    ToolTip.visible: hovered
                }
            }
        }
    }

    // Empty state: large Manrope 800 heading and dim DM Mono supporting text.
    Column {
        anchors.centerIn: parent
        width: Math.min(parent.width - Theme.spaceXl * 2, 520)
        spacing: Theme.spaceMd
        visible: appGrid.count === 0

        Text {
            width: parent.width
            text: qsTr("No Apps")
            color: Theme.text
            font.family: Theme.fontSans
            font.pointSize: 26
            font.weight: Font.ExtraBold
            font.capitalization: Font.AllUppercase
            font.letterSpacing: Theme.trackingTight(26)
            horizontalAlignment: Text.AlignHCenter
        }

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.line
        }

        Text {
            width: parent.width
            text: qsTr("This computer doesn't seem to have any applications or some applications are hidden")
            color: Theme.textDim
            font.family: Theme.fontMono
            font.pointSize: Theme.fontBody
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
        }
    }

    // Share PcView's address selector; only the prompt and Automatic option differ
    // when selecting an address for the current host from its app list.
    SelectAddressDialog {
        id: ipDialog

        promptText: qsTr("Select the IP address to connect to this PC:")

        onAddressSelected: function(address) {
            if (address.isAuto) {
                appModel.resetToAutomaticAddress()
            } else {
                appModel.setActiveAddress(address.address, address.port)
            }
            activeAddressInfo = appModel.getActiveAddressInfo()
        }

        onClosed: appGrid.forceActiveFocus()
    }

    NavigableMessageDialog {
        id: quitAppDialog
        property string appName : ""
        property bool segueToStream : false
        property string nextAppName: ""
        property int nextAppIndex: 0
        text:qsTr("Are you sure you want to quit %1? Any unsaved progress will be lost.").arg(appName)
        standardButtons: Dialog.Yes | Dialog.No

        function quitApp() {
            var component = Qt.createComponent("QuitSegue.qml")
            var params = {"appName": appName, "quitRunningAppFn": function() { appModel.quitRunningApp() }}
            if (segueToStream) {
                // Store the session and app name if we're going to stream after
                // successfully quitting the old app.
                params.nextAppName = nextAppName
                params.nextBoxArtUrl = appModel.data(appModel.index(nextAppIndex, 0), boxArtRole)
                params.nextSession = appModel.createSessionForApp(nextAppIndex, selectedDisplayTarget)
            }
            else {
                params.nextAppName = null
                params.nextBoxArtUrl = ""
                params.nextSession = null
            }

            stackView.push(component.createObject(stackView, params))
        }

        onAccepted: quitApp()
    }

    ScrollBar.vertical: ScrollBar {}

    // Wallpaper and dimming are siblings of the grid delegates. Give them negative z
    // because later declarations at equal z would cover and darken every tile.
    Image {
        id: backgroundImage
        anchors.fill: parent
        source: getBackgroundSource()
        // A darker wallpaper (0.18 instead of 0.3) makes square cards and hard shadows clearer.
        opacity: 0.18
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        z: -2
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Theme.ink.r, Theme.ink.g, Theme.ink.b, 0.55)
        z: -1
    }


    function getBackgroundSource() {
        // Prefer the running application's cover art.
        let runningAppId = appModel.getRunningAppId()
        if (runningAppId !== 0) {
            for (let i = 0; i < appModel.rowCount(); i++) {
                let appIndex = appModel.index(i, 0)
                let appId = appModel.data(appIndex, appIdRole)
                if (appId === runningAppId) {
                    let boxArt = appModel.data(appIndex, boxArtRole)
                    return boxArt || "qrc:/res/gura.png"
                }
            }
        }

        // Otherwise use the first application's cover art.
        if (appModel.rowCount() > 0) {
            let firstAppIndex = appModel.index(0, 0)
            let boxArt = appModel.data(firstAppIndex, boxArtRole)
            return boxArt || "qrc:/res/gura.png"
        }

        return "qrc:/res/gura.png"
    }

    // Observe model changes.
    Connections {
        target: appModel
        function onDataChanged() {
            // Coalesce repeated updates with Qt.callLater.
            Qt.callLater(function() {
                let newSource = getBackgroundSource()
                if (backgroundImage.source !== newSource) {
                    backgroundImage.source = newSource
                }
            })
        }
    }
}
