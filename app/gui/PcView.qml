import QtQuick 2.9
import QtQuick.Controls
import QtQuick.Layouts 1.3
import QtQuick.Window 2.2
import Qt.labs.platform 1.1
import QtCore

import ComputerModel 1.0

import ComputerManager 1.0
import StreamingPreferences 1.0
import SystemProperties 1.0
import SdlGamepadKeyNavigation 1.0
import ImageUtils 1.0

import "theme"
import "Brand.js" as Brand

CenteredGridView {
    // This page provides its own wallpaper; main.qml must not add another layer.
    readonly property bool usesOwnBackground: true
    property ComputerModel computerModel : createModel()
    readonly property string currentBgUrl: backgroundImage.currentImageUrl

    function reloadBackgroundFromPreferences(forceRefresh) {
        backgroundImage.reloadFromPreferences(forceRefresh === true)
    }

    function applyLocalBackgroundImage(fileUrl) {
        var validationError = imageUtils.validateLocalBackgroundImage(fileUrl)
        if (validationError !== "") {
            errorDialog.text = validationError
            errorDialog.open()
            return false
        }

        StreamingPreferences.backgroundImageLocalPath = fileUrl
        StreamingPreferences.save()
        return true
    }

    // PcView fetches and refreshes wallpaper, then shares it with ApplicationWindow
    // so loading, exit, and settings pages retain the background after navigation.
    onCurrentBgUrlChanged: {
        if (Window.window) {
            Window.window.backgroundImageUrl = currentBgUrl
        }
    }

    id: pcGrid
    focus: true
    activeFocusOnTab: true
    topMargin: 72   // 56-pixel toolbar plus one spacing unit.
    bottomMargin: 5
    cellWidth: 240; cellHeight: 280;
    objectName: qsTr("Computers")

    Component.onCompleted: {
        // Don't show any highlighted item until interacting with them.
        // We do this here instead of onActivated to avoid losing the user's
        // selection when backing out of a different page of the app.
        currentIndex = -1
    }

    // Note: Any initialization done here that is critical for streaming must
    // also be done in CliStartStreamSegue.qml, since this code does not run
    // for command-line initiated streams.
    StackView.onActivated: {
        // Setup signals on CM
        ComputerManager.computerAddCompleted.connect(addComplete)

        // Highlight the first item if a gamepad is connected
        if (currentIndex === -1 && SdlGamepadKeyNavigation.getConnectedGamepads() > 0) {
            currentIndex = 0
        }

        backgroundImage.reloadFromPreferences(false)
    }

    Connections {
        target: StreamingPreferences
        function onBackgroundConfigurationChanged() {
            pcGrid.reloadBackgroundFromPreferences(true)
        }
    }

    StackView.onDeactivating: {
        ComputerManager.computerAddCompleted.disconnect(addComplete)
    }

    function pairingComplete(error)
    {
        // Close the PIN dialog
        pairDialog.close()

        // Display a failed dialog if we got an error
        if (error !== undefined) {
            errorDialog.text = error
            errorDialog.helpText = ""
            errorDialog.open()
        }
    }

    function addComplete(success, detectedPortBlocking)
    {
        if (!success) {
            errorDialog.text = qsTr("Unable to connect to the specified PC.")

            if (detectedPortBlocking) {
                errorDialog.text += "\n\n" + Brand.text(qsTr("This PC's Internet connection is blocking Moonlight. Streaming over the Internet may not work while connected to this network."))
            }
            else {
                errorDialog.helpText = qsTr("Click the Help button for possible solutions.")
            }

            errorDialog.open()
        }
    }

    function createModel()
    {
        var model = Qt.createQmlObject('import ComputerModel 1.0; ComputerModel {}', parent, '')
        model.initialize(ComputerManager)
        model.pairingCompleted.connect(pairingComplete)
        model.connectionTestCompleted.connect(testConnectionDialog.connectionTestComplete)
        return model
    }

    function openAppView(computerIndex, computerName, showHiddenGames)
    {
        // Check both component status and createObject(): loading can succeed while
        // instantiation fails. Pushing null only logs 'nothing to push', leaving the
        // user with an apparently unresponsive click.
        function fail(reason) {
            console.error("Failed to open AppView.qml: " + reason)
            errorDialog.text = qsTr("Unable to open the app list for %1.").arg(computerName)
            errorDialog.helpText = reason
            errorDialog.open()
        }

        var component = Qt.createComponent("AppView.qml")
        if (component.status !== Component.Ready) {
            fail(component.errorString())
            return
        }

        var properties = {"computerIndex": computerIndex, "objectName": computerName}
        if (showHiddenGames === true) {
            properties.showHiddenGames = true
        }

        var appView = component.createObject(stackView, properties)
        if (!appView) {
            fail(component.errorString())
            return
        }

        stackView.push(appView)
    }

    function showAddressSelectionForComputer(computerIndex, computerName, openAppAfterSelection)
    {
        var addresses = computerModel.getConnectionAddressesForComputer(computerIndex)

        // Count real addresses, excluding the synthetic Automatic entry.
        var realAddressCount = 0
        for (var i = 0; i < addresses.length; i++) {
            if (!addresses[i].isAuto) {
                realAddressCount++
            }
        }

        if (realAddressCount === 0) {
            errorDialog.text = qsTr("No connection IP addresses are available for %1.").arg(computerName)
            errorDialog.helpText = ""
            errorDialog.open()
            return
        }

        if (realAddressCount === 1) {
            if (openAppAfterSelection === true) {
                openAppView(computerIndex, computerName, false)
            }
            return
        }

        // SelectAddressDialog derives its initial selection from isActive.
        selectAddressDialog.pcIndex = computerIndex
        selectAddressDialog.pcName = computerName
        selectAddressDialog.openAppAfterSelection = openAppAfterSelection === true
        selectAddressDialog.addresses = addresses
        selectAddressDialog.promptText = qsTr("Choose the IP address to connect to %1:").arg(computerName)
        selectAddressDialog.open()
    }

    // Search state: Manrope 800 heading, DM Mono detail, and striped progress bar
    // aligned to the same left edge.
    Column {
        anchors.centerIn: parent
        width: Math.min(parent.width - Theme.spaceXl * 2, 560)
        spacing: Theme.spaceMd
        visible: pcGrid.count === 0

        Text {
            width: parent.width
            text: StreamingPreferences.enableMdns ? qsTr("Searching") : qsTr("No Computers")
            color: Theme.text
            font.family: Theme.fontSans
            font.pointSize: 26
            font.weight: Font.ExtraBold
            font.capitalization: Font.AllUppercase
            font.letterSpacing: Theme.trackingTight(26)
            // Align text to the progress bar's left edge, matching loading and exit pages.
            horizontalAlignment: Text.AlignLeft
        }

        // With mDNS disabled, leave the progress bar inactive because no scan is running.
        HardProgress {
            width: parent.width
            running: StreamingPreferences.enableMdns
        }

        Text {
            width: parent.width
            text: StreamingPreferences.enableMdns ? qsTr("Searching for compatible hosts on your local network...")
                                                  : qsTr("Automatic PC discovery is disabled. Add your PC manually.")
            color: Theme.textDim
            font.family: Theme.fontMono
            font.pointSize: Theme.fontBody
            horizontalAlignment: Text.AlignLeft
            wrapMode: Text.Wrap
        }
    }

    model: computerModel

    // Preserve the floating moon avatars rather than enclosing them in square cards.
    // A card's hover background and shadow would compete with the avatar's visual emphasis.
    delegate: NavigableItemDelegate {
        width: 240; height: 240;
        grid: pcGrid

        property alias pcContextMenu : pcContextMenuLoader.item

        // The asynchronous context-menu Loader may still be null on the first click.
        // Remember the request and open when ready instead of throwing a TypeError.
        // 0 = none, 1 = open(), 2 = popup() at the pointer position.
        property int pendingMenuRequest: 0

        function openContextMenu(atCursor) {
            if (!pcContextMenuLoader.item) {
                pendingMenuRequest = atCursor ? 2 : 1
                return
            }

            pendingMenuRequest = 0
            if (atCursor && pcContextMenuLoader.item.popup) {
                pcContextMenuLoader.item.popup()
            }
            else {
                // Qt 5.9 lacks popup(); keyboard requests also open at the item, not the pointer.
                pcContextMenuLoader.item.open()
            }
        }

        Rectangle {
            id: pcIcon
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: 10
            width: 160
            height: 160
            radius: width / 2
            color: {
                // Derive a stable color from the PC name.
                var hash = 0;
                for (var i = 0; i < model.name.length; i++) {
                    hash = model.name.charCodeAt(i) + ((hash << 5) - hash);
                }
                var color = '#';
                for (var j = 0; j < 3; j++) {
                    var value = (hash >> (j * 8)) & 0xFF;
                    color += ('00' + value.toString(16)).substr(-2);
                }
                return color;
            }

            Image {
                id: moonMask
                anchors.fill: parent
                source: "qrc:/res/moon-mask.png"
                opacity: 0.7
                fillMode: Image.PreserveAspectFit

                // Derive the rotation angle from the PC name.
                property real rotationAngle: {
                    var hash = 0;
                    for (var i = 0; i < model.name.length; i++) {
                        hash = model.name.charCodeAt(i) + ((hash << 5) - hash);
                    }
                    return (hash % 180);
                }

                rotation: rotationAngle
            }

            Text {
                anchors.centerIn: parent
                text: model.name ? model.name.charAt(0).toUpperCase() : "?"
                font.pixelSize: parent.width * 0.6
                font.bold: true
                color: parent.color
            }
        }

        Image {
            // TODO: Tooltip
            id: stateIcon
            anchors {
                right: pcIcon.right
                bottom: pcIcon.bottom
                rightMargin: 5
                bottomMargin: 5
            }
            visible: !model.statusUnknown && (!model.online || !model.paired)
            source: !model.online ? "qrc:/res/warning_FILL1_wght300_GRAD200_opsz24.svg" : "qrc:/res/baseline-lock-24px.svg"
            sourceSize {
                width: !model.online ? 32 : 28
                height: !model.online ? 32 : 28
            }
            opacity: 0.8
        }

        Rectangle {
            id: statusUnknownSpinner
            anchors.horizontalCenter: pcIcon.horizontalCenter
            anchors.verticalCenter: pcIcon.verticalCenter
            anchors.verticalCenterOffset: 0
            width: 160
            height: 160
            color: "transparent"
            visible: model.statusUnknown

            Image {
                id: spinnerImage
                anchors.centerIn: parent
                width: 160
                height: 160
                source: "qrc:/res/loading.svg"

                RotationAnimation {
                    target: spinnerImage
                    property: "rotation"
                    from: 0
                    to: 360
                    duration: 1500
                    loops: Animation.Infinite
                    running: statusUnknownSpinner.visible
                }
            }
        }

        Label {
            id: pcNameText
            text: model.name

            width: parent.width
            anchors.top: pcIcon.bottom
            anchors.topMargin: 20
            anchors.bottom: parent.bottom
            font.pointSize: 16
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            elide: Text.ElideRight
        }

        Loader {
            id: pcContextMenuLoader
            asynchronous: true
            onLoaded: {
                // Fulfill a pending click only if this page is still current; otherwise
                // the menu could appear over a newly opened host or previous page.
                if (pcContextMenuLoader.parent.pendingMenuRequest !== 0) {
                    if (pcGrid.StackView.status === StackView.Active) {
                        pcContextMenuLoader.parent.openContextMenu(
                            pcContextMenuLoader.parent.pendingMenuRequest === 2)
                    }
                    else {
                        pcContextMenuLoader.parent.pendingMenuRequest = 0
                    }
                }
            }
            sourceComponent: NavigableMenu {
                id: pcContextMenu
                initiator: pcContextMenuLoader.parent
                MenuItem {
                    text: qsTr("PC Status: %1").arg(model.online ? qsTr("Online") : qsTr("Offline"))
                    font.bold: true
                    enabled: false
                }
                NavigableMenuItem {
                    text: qsTr("View All Apps")
                    onTriggered: {
                        openAppView(index, model.name, true)
                    }
                    visible: model.online && model.paired
                }
                NavigableMenuItem {
                    text: qsTr("Select Connection IP")
                    onTriggered: showAddressSelectionForComputer(index, model.name, false)
                    visible: model.online && model.paired && computerModel.hasMultipleConnectionAddresses(index)
                }
                NavigableMenuItem {
                    text: qsTr("Wake PC")
                    onTriggered: computerModel.wakeComputer(index)
                    visible: !model.online && model.wakeable
                }
                NavigableMenuItem {
                    text: qsTr("Test Network")
                    onTriggered: {
                        computerModel.testConnectionForComputer(index)
                        testConnectionDialog.open()
                    }
                }

                NavigableMenuItem {
                    text: qsTr("Rename PC")
                    onTriggered: {
                        renamePcDialog.pcIndex = index
                        renamePcDialog.originalName = model.name
                        renamePcDialog.open()
                    }
                }
                NavigableMenuItem {
                    text: qsTr("Delete PC")
                    onTriggered: {
                        deletePcDialog.pcIndex = index
                        deletePcDialog.pcName = model.name
                        deletePcDialog.open()
                    }
                }
                NavigableMenuItem {
                    text: qsTr("View Details")
                    onTriggered: {
                        showPcDetailsDialog.pcDetails = model.details
                        showPcDetailsDialog.open()
                    }
                }
            }
        }

        onClicked: {
            if (model.online) {
                if (!model.serverSupported) {
                    errorDialog.text = Brand.text(qsTr("The version of GeForce Experience on %1 is not supported by this build of Moonlight. You must update Moonlight to stream from %1.")).arg(model.name)
                    errorDialog.helpText = ""
                    errorDialog.open()
                }
                else if (model.paired) {
                    // Go directly to app view; IP can be changed from there
                    openAppView(index, model.name, false)
                }
                else {
                    var pin = computerModel.generatePinString()

                    // Kick off pairing in the background
                    computerModel.pairComputer(index, pin)

                    // Display the pairing dialog
                    pairDialog.pin = pin
                    pairDialog.open()
                }
            } else if (!model.online) {
                // Using open() here because it may be activated by keyboard
                openContextMenu(false)
            }
        }

        onPressAndHold: {
            // popup() ensures the menu appears under the mouse cursor
            openContextMenu(true)
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.RightButton;
            onClicked: {
                parent.pressAndHold()
            }
        }

        Keys.onMenuPressed: {
            // We must use open() here so the menu is positioned on
            // the ItemDelegate and not where the mouse cursor is
            openContextMenu(false)
        }

        Keys.onDeletePressed: {
            deletePcDialog.pcIndex = index
            deletePcDialog.pcName = model.name
            deletePcDialog.open()
        }
    }

    ErrorMessageDialog {
        id: errorDialog

        // Using Setup-Guide here instead of Troubleshooting because it's likely that users
        // will arrive here by forgetting to enable GameStream or not forwarding ports.
        helpUrl: "https://github.com/moonlight-stream/moonlight-docs/wiki/Setup-Guide"
    }

    NavigableMessageDialog {
        id: pairDialog
        closePolicy: Popup.CloseOnEscape

        // don't allow edits to the rest of the window while open
        property string pin : "0000"
        text:qsTr("Please enter %1 on your host PC. This dialog will close when pairing is completed.").arg(pin)+"\n\n"+
             qsTr("If your host PC is running Sunshine, navigate to the Sunshine web UI to enter the PIN.")
        standardButtons: DialogButtonBox.Cancel
        onRejected: {
            // FIXME: We should interrupt pairing here
        }
    }

    NavigableMessageDialog {
        id: deletePcDialog
        // don't allow edits to the rest of the window while open
        property int pcIndex : -1
        property string pcName : ""
        text: qsTr("Are you sure you want to remove '%1'?").arg(pcName)
        standardButtons: DialogButtonBox.Ok | DialogButtonBox.Cancel

        onAccepted: {
            computerModel.deleteComputer(pcIndex)
        }
    }

    NavigableMessageDialog {
        id: testConnectionDialog
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        standardButtons: DialogButtonBox.Ok

        onAboutToShow: {
            testConnectionDialog.text = Brand.text(qsTr("Moonlight is testing your network connection to determine if any required ports are blocked.")) + "\n\n" + qsTr("This may take a few seconds…")
            showSpinner = true
        }

        function connectionTestComplete(result, blockedPorts)
        {
            if (result === -1) {
                text = Brand.text(qsTr("The network test could not be performed because none of Moonlight's connection testing servers were reachable from this PC. Check your Internet connection or try again later."))
                imageSrc = "qrc:/res/baseline-warning-24px.svg"
            }
            else if (result === 0) {
                text = Brand.text(qsTr("This network does not appear to be blocking Moonlight. If you still have trouble connecting, check your PC's firewall settings.") + "\n\n" + qsTr("If you are trying to stream over the Internet, install the Moonlight Internet Hosting Tool on your gaming PC and run the included Internet Streaming Tester to check your gaming PC's Internet connection."))
                imageSrc = "qrc:/res/baseline-check_circle_outline-24px.svg"
            }
            else {
                text = Brand.text(qsTr("Your PC's current network connection seems to be blocking Moonlight. Streaming over the Internet may not work while connected to this network.")) + "\n\n" + qsTr("The following network ports were blocked:") + "\n"
                text += blockedPorts
                imageSrc = "qrc:/res/baseline-error_outline-24px.svg"
            }

            // Stop showing the spinner and show the image instead
            showSpinner = false
        }
    }

    NavigableDialog {
        id: renamePcDialog
        property string label: qsTr("Enter the new name for this PC:")
        property string originalName
        property int pcIndex : -1;

        standardButtons: DialogButtonBox.Ok | DialogButtonBox.Cancel

        onOpened: {
            // Force keyboard focus on the textbox so keyboard navigation works
            editText.forceActiveFocus()
        }

        onClosed: {
            editText.clear()
        }

        onAccepted: {
            if (editText.text) {
                computerModel.renameComputer(pcIndex, editText.text)
            }
        }

        ColumnLayout {
            Text {
                text: renamePcDialog.label
                color: Theme.text
                font.family: Theme.fontSans
                font.pointSize: Theme.fontRowTitle
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }

            HardTextField {
                id: editText
                placeholderText: renamePcDialog.originalName
                Layout.fillWidth: true
                focus: true

                Keys.onReturnPressed: {
                    renamePcDialog.accept()
                }

                Keys.onEnterPressed: {
                    renamePcDialog.accept()
                }
            }
        }
    }

    // Share AppView's address dialog with different prompt and application behavior.
    SelectAddressDialog {
        id: selectAddressDialog
        property int pcIndex: -1
        property string pcName: ""
        property bool openAppAfterSelection: false

        onAddressSelected: function(address) {
            var ok = address.isAuto
                    ? computerModel.resetToAutomaticAddressForComputer(pcIndex)
                    : computerModel.setActiveAddressForComputer(pcIndex, address.address, address.port)
            if (!ok) {
                errorDialog.text = qsTr("Unable to switch the connection IP for %1.").arg(pcName)
                errorDialog.helpText = ""
                errorDialog.open()
                return
            }

            if (openAppAfterSelection) {
                openAppView(pcIndex, pcName, false)
            }
        }

        onClosed: {
            addresses = []
            openAppAfterSelection = false
            pcIndex = -1
            pcName = ""
        }
    }

    NavigableMessageDialog {
        id: showPcDetailsDialog
        property string pcDetails : "";
        text: showPcDetailsDialog.pcDetails
        imageSrc: "qrc:/res/baseline-help_outline-24px.svg"
        standardButtons: DialogButtonBox.Ok
    }

    ScrollBar.vertical: ScrollBar {}

    Image {
        id: backgroundImage
        anchors.fill: parent
        source: ""
        fillMode: Image.PreserveAspectCrop
        z: -2
        property string currentImageUrl: ""
        property string activeRequestKey: ""
        property bool lastRequestWasBusy: false

        Settings {
            id: settings
            property string cachedImagePath: ""
            property string cachedSourceKey: ""
            property real lastRefreshTime: Date.now()
        }

        onStatusChanged: {
            if (status === Image.Loading) {
                loadingIndicator.visible = true
            } else if (status === Image.Ready) {
                loadingIndicator.visible = false
            } else if (status === Image.Error) {
                loadingIndicator.visible = false
                if (StreamingPreferences.backgroundSource === StreamingPreferences.BGS_LOCAL) {
                    errorDialog.text = qsTr("The local background could not be loaded. The background has been disabled.")
                    errorDialog.open()
                    clearInvalidLocalBackground()
                }
                else if (usesNetworkSource()) {
                    getBackgroundImage()
                }
            }
        }

        function usesNetworkSource() {
            return StreamingPreferences.backgroundSource !== StreamingPreferences.BGS_LOCAL &&
                   StreamingPreferences.backgroundSource !== StreamingPreferences.BGS_NONE
        }

        function configuredCacheKey() {
            switch (StreamingPreferences.backgroundSource) {
            case StreamingPreferences.BGS_PHOTOGRAPHY:
                return "photography:picsum"
            case StreamingPreferences.BGS_API:
                var apiUrl = StreamingPreferences.backgroundImageApi.trim()
                return apiUrl === "" ? "none" : "api:" + apiUrl
            case StreamingPreferences.BGS_LOCAL:
                return "local:" + StreamingPreferences.backgroundImageLocalPath
            case StreamingPreferences.BGS_NONE:
                return "none"
            default:
                return "none"
            }
        }

        function configuredNetworkUrl() {
            switch (StreamingPreferences.backgroundSource) {
            case StreamingPreferences.BGS_PHOTOGRAPHY:
                return "https://picsum.photos/1920/1080?random=" + Date.now()
            case StreamingPreferences.BGS_API:
                var apiUrl = StreamingPreferences.backgroundImageApi.trim()
                return apiUrl
            default:
                return ""
            }
        }

        function cacheFileUrl(cachePath) {
            return "file:///" + cachePath.replace(/\\/g, "/").replace(/^\/+/, "")
        }

        function showBackground(imageUrl) {
            source = imageUrl
            currentImageUrl = imageUrl
        }

        function clearBackground() {
            loadNewImageTimer.stop()
            loadingIndicator.visible = false
            source = ""
            currentImageUrl = ""
        }

        function clearInvalidLocalBackground() {
            clearBackground()
            // Clearing the local path also selects the offline BGS_NONE background.
            StreamingPreferences.backgroundImageLocalPath = ""
            StreamingPreferences.save()
        }

        function reloadFromPreferences(forceRefresh) {
            loadNewImageTimer.stop()

            if (!StreamingPreferences.backgroundSetupCompleted) {
                clearBackground()
                return
            }

            if (StreamingPreferences.backgroundSource === StreamingPreferences.BGS_NONE) {
                clearBackground()
                return
            }

            if (StreamingPreferences.backgroundSource === StreamingPreferences.BGS_LOCAL) {
                var localUrl = StreamingPreferences.backgroundImageLocalPath
                var validationError = imageUtils.validateLocalBackgroundImage(localUrl)
                if (localUrl !== "" && validationError === "") {
                    loadingIndicator.visible = false
                    showBackground(localUrl)
                    return
                }

                if (validationError !== "") {
                    errorDialog.text = validationError + "\n\n" + qsTr("The background has been disabled.")
                    errorDialog.open()
                }
                clearInvalidLocalBackground()
                return
            }

            var cacheKey = configuredCacheKey()
            if (!forceRefresh && settings.cachedImagePath &&
                    imageUtils.fileExists(settings.cachedImagePath) &&
                    settings.cachedSourceKey === cacheKey) {
                settings.cachedSourceKey = cacheKey
                showBackground(cacheFileUrl(settings.cachedImagePath))

                var oneWeek = 60 * 60 * 1000 * 24 * 7
                if (Date.now() - settings.lastRefreshTime > oneWeek) {
                    loadNewImageTimer.start()
                }
                return
            }

            getBackgroundImage()
        }

        function getBackgroundImage() {
            var requestUrl = configuredNetworkUrl()
            if (requestUrl === "") {
                reloadFromPreferences(false)
                return
            }

            loadingIndicator.visible = true
            var requestKey = configuredCacheKey()
            lastRequestWasBusy = false
            var requestStarted = imageUtils.fetchAndSaveRandomBackground(requestUrl)
            if (requestStarted || !lastRequestWasBusy) {
                activeRequestKey = requestKey
            }
        }

        function handleImageResponse(cachePath) {
            if (activeRequestKey !== configuredCacheKey()) {
                reloadFromPreferences(true)
                return
            }

            settings.cachedImagePath = cachePath
            settings.cachedSourceKey = activeRequestKey
            showBackground(cacheFileUrl(cachePath))
            settings.lastRefreshTime = Date.now()
        }

        function handleImageError(errorMessage) {
            console.error("Background image load failed:", errorMessage)
            if (activeRequestKey !== configuredCacheKey()) {
                reloadFromPreferences(true)
                return
            }

            var displayingActiveCache = settings.cachedImagePath !== "" &&
                    settings.cachedSourceKey === activeRequestKey &&
                    source.toString() === cacheFileUrl(settings.cachedImagePath)
            if (!displayingActiveCache) {
                source = "qrc:/res/gura.png"
                currentImageUrl = ""
            }
        }

        Timer {
            id: loadNewImageTimer
            interval: 1000 // Delay loading the next image by one second.
            repeat: false
            onTriggered: {
                backgroundImage.getBackgroundImage();
            }
        }
    }

    DropArea {
        anchors.fill: parent
        onEntered: function(drag) {
            if (drag.hasUrls) {
                drag.accept(Qt.LinkAction)
                dragBorder.visible = true
            }
        }
        onExited: dragBorder.visible = false
        onDropped: function(drop) {
            dragBorder.visible = false
            if (!drop.hasUrls || drop.urls.length !== 1) {
                errorDialog.text = qsTr("Drop one local image at a time.")
                errorDialog.open()
                return
            }

            pcGrid.applyLocalBackgroundImage(drop.urls[0].toString())
        }
    }

    // Drag-and-drop border feedback.
    Rectangle {
        id: dragBorder
        anchors.fill: parent
        color: "transparent"
        border.color: Theme.acid
        border.width: 4
        visible: false
        z: 1
    }

    // Drag-and-drop hint text.
    Column {
        anchors.centerIn: parent
        spacing: Theme.spaceSm
        visible: dragBorder.visible
        z: 1

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: qsTr("Drop To Set Wallpaper")
            color: Theme.acid
            font.family: Theme.fontSans
            font.pointSize: 22
            font.weight: Font.ExtraBold
            font.capitalization: Font.AllUppercase
            font.letterSpacing: Theme.tracking(22, 0.08)
        }

        MicroLabel {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "JPG / PNG / WEBP / BMP"
        }
    }

    // Background context-menu interaction.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        propagateComposedEvents: true
        z: -1  // Keep this MouseArea below PC items.

        onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton) {
                if (backgroundImage.currentImageUrl) {
                    console.log("Context menu requested")
                    backgroundContextMenu.popup()
                }
            }
        }
    }

    // Background context menu.
    NavigableMenu {
        id: backgroundContextMenu
        property real lastRefreshTime: 0  // Date.now() is a 13-digit millisecond timestamp

        NavigableMenuItem {
            parentMenu: backgroundContextMenu
            text: qsTr("Save wallpaper")
            onTriggered: {
                console.log("Background image download requested")
                saveFileDialog.open()
            }
        }

        NavigableMenuItem {
            parentMenu: backgroundContextMenu
            text: qsTr("Refresh wallpaper")
            onTriggered: {
                var currentTime = Date.now();
                if (currentTime - backgroundContextMenu.lastRefreshTime < 10000) {
                    saveNotification.text = qsTr("Please wait at least 10 seconds between refreshes.")
                    saveNotification.open()
                    return;
                }
                backgroundContextMenu.lastRefreshTime = currentTime;

                loadingIndicator.visible = true
                refreshTimer.start()
            }
        }
    }

    // Defer refresh to avoid overlapping calls.
    Timer {
        id: refreshTimer
        interval: 200  // Delay by 200 milliseconds.
        repeat: false
        onTriggered: {
            backgroundImage.reloadFromPreferences(true)
        }
    }

    // File save dialog.
    FileDialog {
        id: saveFileDialog
        title: qsTr("Choose where to save")
        nameFilters: [qsTr("Image files (*.jpg *.jpeg *.png *.webp)")]
        fileMode: FileDialog.SaveFile

        currentFile: {
            var timestamp = new Date().getTime()
            // Extract the file extension from the URL.
            var extension = ".jpg"
            if (backgroundImage.currentImageUrl) {
                var urlPath = backgroundImage.currentImageUrl.toString()
                var extMatch = urlPath.match(/\.(jpg|jpeg|png|webp)($|\?)/i)
                if (extMatch) {
                    extension = "." + extMatch[1].toLowerCase()
                }
            }
            return "file:///setu_" + timestamp + extension
        }

        onAccepted: {
            var finalPath = saveFileDialog.fileUrl || saveFileDialog.currentFile || saveFileDialog.file

            console.log("Original path: " + finalPath)

            if (finalPath) {
                var ext = finalPath.toString().split('.').pop().toLowerCase()
                if (["jpg", "jpeg", "png", "webp"].indexOf(ext) === -1) {
                    finalPath = finalPath + ".jpg"  // Add the default extension.
                }
                imageUtils.saveImageToFile(backgroundImage.currentImageUrl, finalPath)
            } else {
                var timestamp = new Date().getTime()
                finalPath = "file:///setu_" + timestamp + ".jpg"
                console.log("Using default path: " + finalPath)
                imageUtils.saveImageToFile(backgroundImage.currentImageUrl, finalPath)
            }
        }
    }

    // moonlight-dance
    AnimatedImage {
        id: loadingIndicator
        anchors {
            right: parent.right
            bottom: parent.bottom
            margins: 10
        }
        opacity: 0.4
        source: "qrc:/res/moonlight-dance.gif"
        width: 40
        height: 40
        playing: visible
        fillMode: Image.PreserveAspectFit
        visible: false
    }

    // Software settings control wallpaper dimming; the default remains 72%.
    Rectangle {
        anchors.fill: parent
        visible: StreamingPreferences.backgroundSource !== StreamingPreferences.BGS_NONE
        color: Qt.rgba(Theme.ink.r, Theme.ink.g, Theme.ink.b,
                       StreamingPreferences.backgroundOverlayOpacity / 100.0)
        z: -1
    }

    ImageUtils {
        id: imageUtils
        onBackgroundReady: function(filePath) {
            loadingIndicator.visible = false
            backgroundImage.handleImageResponse(filePath)
        }
        onBackgroundError: function(errorMessage) {
            loadingIndicator.visible = false
            backgroundImage.handleImageError(errorMessage)
        }
        onBackgroundBusy: backgroundImage.lastRequestWasBusy = true
        onSaveCompleted: function(success, message) {
            if (success) {
                saveNotification.text = qsTr("Image saved to: %1").arg(message)
                // Dismiss the notification automatically.
                autoCloseTimer.start()
            } else {
                saveNotification.text = qsTr("Save failed: %1").arg(message)
            }
            saveNotification.open()
        }
    }

    NavigableMessageDialog {
        id: saveNotification
        title: qsTr("Save result")
        standardButtons: DialogButtonBox.Ok

        // Automatic notification dismissal timer.
        Timer {
            id: autoCloseTimer
            interval: 3000 // Dismiss after three seconds.
            repeat: false
            onTriggered: {
                saveNotification.close()
            }
        }
    }
}
