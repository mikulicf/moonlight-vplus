import QtQuick 2.0
import QtQuick.Controls
import QtQuick.Window 2.2

import SdlGamepadKeyNavigation 1.0
import Session 1.0
import SystemProperties 1.0
import StreamingPreferences 1.0

import "theme"
import "Brand.js" as Brand

Item {
    property Session session
    property string appName

    // Use the launching game's cover during loading, falling back to the PC wallpaper.
    property string boxArtUrl: ""

    // This page provides its own background; omit the global wallpaper layer.
    readonly property bool usesOwnBackground: true
    property string stageText : isResume ? qsTr("Resuming %1...").arg(appName) :
                                           qsTr("Starting %1...").arg(appName)
    property bool isResume : false
    property bool quitAfter : false

    function stageStarting(stage)
    {
        // Update the spinner text
        stageText = qsTr("Starting %1...").arg(stage)
    }

    function stageFailed(stage, errorCode, failingPorts)
    {
        // Display the error dialog after Session::exec() returns
        streamSegueErrorDialog.text = qsTr("Starting %1 failed: Error %2").arg(stage).arg(errorCode)

        if (failingPorts) {
            streamSegueErrorDialog.text += "\n\n" + qsTr("Check your firewall and port forwarding rules for port(s): %1").arg(failingPorts)
        }
    }

    function hideForStreaming()
    {
        // Hide the UI contents so the user doesn't
        // see them briefly when we pop off the StackView
        stageSpinner.visible = false
        stageLabel.visible = false
        hintText.visible = false

        // Session::exec() hides the GUI after the stream enters fullscreen. Hiding it
        // earlier exposes the desktop during macOS's transition to a new Space.
    }

    function connectionStarted()
    {
        // Fade to black before Session::exec() creates the stream window to avoid flashing.
        backgroundZoomAnimation.stop()
        exitAnimation.start()
    }

    function displayLaunchError(text)
    {
        // Display the error dialog after Session::exec() returns
        streamSegueErrorDialog.text = text
        console.error(text)
    }

    function quitStarting()
    {
        // Avoid the push transition animation
        var component = Qt.createComponent("QuitSegue.qml")
        stackView.replace(stackView.currentItem, component.createObject(stackView, {"appName": appName}), StackView.Immediate)

        // Show the Qt window again to show quit segue
        window.visible = true
    }

    function sessionFinished(portTestResult)
    {
        if (portTestResult !== 0 && portTestResult !== -1 && streamSegueErrorDialog.text) {
            streamSegueErrorDialog.text += "\n\n" + Brand.text(qsTr("This PC's Internet connection is blocking Moonlight. Streaming over the Internet may not work while connected to this network."))
        }

        // Re-enable GUI gamepad usage now
        SdlGamepadKeyNavigation.enable()

        // Pop the StreamSegue off the stack if this is a GUI-based app launch
        if (!quitAfter) {
            stackView.pop()
        }

        if (quitAfter && !streamSegueErrorDialog.text) {
            // If this was a CLI launch without errors, exit now
            Qt.quit()
        }
        else {
            // Show the Qt window again after streaming
            window.visible = true

            // Display any launch errors. We do this after
            // the Qt UI is visible again to prevent losing
            // focus on the dialog which would impact gamepad
            // users.
            if (streamSegueErrorDialog.text) {
                streamSegueErrorDialog.quitAfter = quitAfter
                streamSegueErrorDialog.open()
            }
        }
    }

    function sessionReadyForDeletion()
    {
        // Garbage collect the Session object since it's pretty heavyweight
        // and keeps other libraries (like SDL_TTF) around until it is deleted.
        session = null
        gc()
    }

    StackView.onDeactivating: {
        // Show the toolbar again when popped off the stack
        toolBar.shown = true

        // Re-enable GUI gamepad usage now
        SdlGamepadKeyNavigation.enable()
    }

    StackView.onActivated: {
        // Hide the toolbar before we start loading
        toolBar.shown = false

        // Hook up our signals
        session.stageStarting.connect(stageStarting)
        session.stageFailed.connect(stageFailed)
        session.connectionStarted.connect(connectionStarted)
        session.displayLaunchError.connect(displayLaunchError)
        session.quitStarting.connect(quitStarting)
        session.sessionFinished.connect(sessionFinished)
        session.readyForDeletion.connect(sessionReadyForDeletion)

        // Ensure the SystemProperties async thread is finished,
        // since it may currently be using the SDL video subsystem
        SystemProperties.waitForAsyncLoad()

        enterAnimation.start()
        backgroundZoomAnimation.start()

        // Kick off the stream
        streamLoader.active = true
    }

    // Retain the app-list background beneath the fading-in cover for a continuous transition.
    Image {
        id: previousBackground

        anchors.fill: parent
        source: window.backgroundImageUrl
        visible: source != ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        opacity: 0.3
        z: -3
    }

    // Remember cover-load failure and use the PC wallpaper. A nonempty but invalid URL
    // otherwise leaves Image.Error and a permanently transparent layer instead of a fallback.
    property bool boxArtFailed: false

    onBoxArtUrlChanged: boxArtFailed = false

    Image {
        id: segueBackground

        anchors.fill: parent
        source: (boxArtUrl !== "" && !boxArtFailed)
                    ? boxArtUrl
                    : (window.backgroundImageUrl !== "" ? window.backgroundImageUrl
                                                        : "qrc:/res/gura.png")
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        z: -2

        // Bind opacity to load status instead of starting animation in onStatusChanged:
        // cached images can become Ready before the handler is connected.
        opacity: status === Image.Ready ? 1 : 0

        // Record errors through the event and check initial status for cached failures.
        onStatusChanged: if (status === Image.Error) boxArtFailed = true
        Component.onCompleted: if (status === Image.Error) boxArtFailed = true

        Behavior on opacity {
            NumberAnimation { duration: 700; easing.type: Easing.OutCubic }
        }

        // Slowly zoom while loading so the waiting screen is not static.
        transform: Scale {
            id: backgroundZoom
            origin.x: segueBackground.width / 2
            origin.y: segueBackground.height / 2
        }
    }

    ParallelAnimation {
        id: backgroundZoomAnimation
        NumberAnimation {
            target: backgroundZoom; property: "xScale"
            from: 1.0; to: 1.08; duration: 14000; easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: backgroundZoom; property: "yScale"
            from: 1.0; to: 1.08; duration: 14000; easing.type: Easing.InOutSine
        }
    }

    // Dim the cover enough to keep progress and text readable.
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Theme.ink.r, Theme.ink.g, Theme.ink.b,
                       StreamingPreferences.backgroundOverlayOpacity / 100.0)
        z: -1
    }

    // Fade a curtain over the GUI instead of hiding it abruptly in one frame.
    //
    // Match SDL's initial pure-black frame, not Theme.ink, so handover has no color jump.
    Rectangle {
        id: exitVeil
        anchors.fill: parent
        color: "black"
        opacity: 0
        visible: opacity > 0
        z: 10
    }

    ParallelAnimation {
        id: enterAnimation
        NumberAnimation {
            target: contentRoot; property: "opacity"
            from: 0; to: 1; duration: 420; easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: contentShift; property: "y"
            from: 14; to: 0; duration: 480; easing.type: Easing.OutCubic
        }
    }

    // Fade content, zoom slightly, and cover with black together when entering the stream.
    ParallelAnimation {
        id: exitAnimation

        NumberAnimation {
            target: contentRoot; property: "opacity"
            to: 0; duration: 260; easing.type: Easing.InCubic
        }
        NumberAnimation {
            target: backgroundZoom; property: "xScale"
            to: 1.14; duration: 340; easing.type: Easing.InOutQuad
        }
        NumberAnimation {
            target: backgroundZoom; property: "yScale"
            to: 1.14; duration: 340; easing.type: Easing.InOutQuad
        }
        SequentialAnimation {
            NumberAnimation {
                target: exitVeil; property: "opacity"
                to: 1; duration: 340; easing.type: Easing.InOutQuad
            }
            ScriptAction {
                script: hideForStreaming()
            }
        }
    }

    Timer {
        id: startSessionTimer
        onTriggered: {
            // Garbage collect QML stuff before we start streaming,
            // since we'll probably be streaming for a while and we
            // won't be able to GC during the stream.
            gc()

            // Run the streaming session to completion
            session.start()
        }
    }

    Loader {
        id: streamLoader
        active: false
        asynchronous: true

        onLoaded: {
            // Set the hint text. We do this here rather than
            // in the hintText control itself to synchronize
            // with Session.exec() which requires no concurrent
            // gamepad usage.
            hintText.text = qsTr("Tip:") + " " + qsTr("Press %1 to disconnect your session").arg(SdlGamepadKeyNavigation.getConnectedGamepads() > 0 ?
                                                  qsTr("Start+Select+L1+R1") : qsTr("Ctrl+Alt+Shift+Q"))

            // Stop GUI gamepad usage now
            SdlGamepadKeyNavigation.disable()

            // Initialize the session and probe for host/client capabilities
            if (!session.initialize(window)) {
                sessionFinished(0);
                sessionReadyForDeletion();
                return;
            }

            // This spinner is shown only after session.initialize() has completed
            // to prevent active animations from running during decoder probing,
            // which causes re-entrant event loop livelocks with libdecor-gtk.
            stageSpinner.visible = true

            // Don't wait unless we have toasts to display
            startSessionTimer.interval = 0

            // Display the toasts together in a vertical centered arrangement
            var yOffset = 0
            for (var i = 0; i < session.launchWarnings.length; i++) {
                var text = session.launchWarnings[i]
                console.warn(text)

                // Show the tooltip for 3 seconds
                var toast = Qt.createQmlObject('import QtQuick.Controls 2.2; ToolTip {}', parent, '')
                toast.timeout = 3000
                toast.text = text
                toast.y += yOffset
                toast.visible = true

                // Offset the next toast below the previous one
                yOffset = toast.y + toast.padding + toast.height

                // Allow an extra 500 ms for the tooltip's fade-out animation to finish
                startSessionTimer.interval = toast.timeout + 500;
            }

            // Start the timer to wait for toasts (or start the session immediately)
            startSessionTimer.start()
        }

        sourceComponent: Item {}
    }

    Item {
        id: contentRoot

        anchors.fill: parent
        opacity: 0

        // Rise slightly during the fade-in.
        transform: Translate {
            id: contentShift
            y: 14
        }

        // Use HardProgress with stage text. Preserve stageSpinner's ID and visible
        // semantics because spinnerTimer and hideForStreaming() depend on them.
        Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - Theme.spaceXl * 2, 620)
            spacing: Theme.spaceLg

            Text {
                id: stageLabel

                width: parent.width
                text: stageText
                color: Theme.text
                font.family: Theme.fontSans
                font.pointSize: 24
                font.weight: Font.ExtraBold
                font.letterSpacing: Theme.trackingTight(24)
                // Left alignment matches the toolbar, cards, and rows and keeps changing
                // stage messages from shifting sideways as their length changes.
                horizontalAlignment: Text.AlignLeft
                wrapMode: Text.Wrap
            }

            HardProgress {
                id: stageSpinner

                width: parent.width
                visible: false
            }
        }

        Text {
            id: hintText
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 50
            anchors.horizontalCenter: parent.horizontalCenter
            color: Theme.textDim
            font.family: Theme.fontMono
            font.pointSize: Theme.fontBody
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter

            wrapMode: Text.Wrap
        }
    }
}
