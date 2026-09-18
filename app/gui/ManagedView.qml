import QtQuick
import QtQuick.Controls

import ManagedBackend 1.0

import "theme"

Item {
    id: root

    readonly property bool usesOwnBackground: false
    property string localMessage: ""
    property real nowSeconds: Date.now() / 1000

    objectName: "Backend"
    focus: true
    activeFocusOnTab: true

    StackView.onActivated: {
        ManagedBackend.releaseConnections()
        Qt.callLater(function() { root.forceActiveFocus(Qt.TabFocusReason) })
    }
    StackView.onDeactivating: passwordField.clear()
    Component.onDestruction: ManagedBackend.releaseConnections()

    onActiveFocusChanged: {
        if (activeFocus) {
            if (ManagedBackend.loggedIn) {
                refreshButton.forceActiveFocus(Qt.TabFocusReason)
            } else {
                backendUrlField.forceActiveFocus(Qt.TabFocusReason)
            }
        }
    }

    function displayedMessage() {
        return localMessage !== "" ? localMessage : ManagedBackend.message
    }

    function isMachineOnline(machine) {
        return Number(machine.managed_protocol) === 1 &&
               Number(machine.last_seen) > nowSeconds - 30
    }

    function machineEndpoint(machine) {
        var address = String(machine.address || "")
        if (address === "") {
            return qsTr("Address unavailable")
        }
        if (address.indexOf(":") >= 0 && address.charAt(0) !== "[") {
            address = "[" + address + "]"
        }

        var httpsPort = Number(machine.https_port || 0)
        var httpPort = Number(machine.http_port || 0)
        if (httpsPort > 0) {
            return "https://" + address + ":" + httpsPort
        }
        if (httpPort > 0) {
            return "http://" + address + ":" + httpPort
        }
        return address
    }

    function focusMachine(startIndex, step) {
        for (var i = startIndex; i >= 0 && i < machineRepeater.count; i += step) {
            var item = machineRepeater.itemAt(i)
            if (item && item.connectButton.enabled) {
                item.connectButton.forceActiveFocus(Qt.TabFocusReason)
                return true
            }
        }
        return false
    }

    function submitSignIn() {
        var url = backendUrlField.text.trim()
        var username = usernameField.text.trim()
        var password = passwordField.text

        localMessage = ""
        if (!/^https:\/\/[^\s]+$/i.test(url)) {
            localMessage = qsTr("Enter a valid HTTPS backend URL.")
        } else if (username === "" || password === "") {
            localMessage = qsTr("Enter your username and password.")
        } else {
            ManagedBackend.signIn(url, username, password)
        }

        // The backend owns credentials and tokens after submission. Never retain
        // the password in the QML object longer than the submit operation.
        passwordField.clear()
    }

    function openMachine(computerIndex, computerName) {
        function fail(reason) {
            console.error("Failed to open AppView.qml: " + reason)
            ManagedBackend.releaseConnections()
            localMessage = qsTr("Unable to open the app list for %1.").arg(computerName)
        }

        var component = Qt.createComponent("AppView.qml")
        if (component.status !== Component.Ready) {
            fail(component.errorString())
            return
        }

        var appView = component.createObject(stackView, {
                                                 "computerIndex": computerIndex,
                                                 "objectName": computerName
                                             })
        if (!appView) {
            fail(component.errorString())
            return
        }

        stackView.push(appView)
    }

    Timer {
        interval: 5000
        repeat: true
        running: root.visible && ManagedBackend.loggedIn
        onTriggered: root.nowSeconds = Date.now() / 1000
    }

    Connections {
        target: ManagedBackend

        function onMachineReady(computerIndex, name) {
            root.localMessage = ""
            if (root.StackView.status === StackView.Active) {
                root.openMachine(computerIndex, name)
            } else {
                ManagedBackend.releaseConnections()
            }
        }

        function onChanged() {
            passwordField.clear()
            root.localMessage = ""
            if (!ManagedBackend.loggedIn) {
                backendUrlField.text = ManagedBackend.backendUrl
                usernameField.text = ManagedBackend.username
            }
        }

    }

    Component.onCompleted: {
        backendUrlField.text = ManagedBackend.backendUrl
        usernameField.text = ManagedBackend.username
    }

    Flickable {
        id: pageFlickable

        anchors {
            fill: parent
            topMargin: 72
            leftMargin: Theme.spaceXl
            rightMargin: Theme.spaceXl
            bottomMargin: Theme.spaceXl
        }
        contentWidth: width
        contentHeight: pageColumn.implicitHeight + Theme.spaceXl
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { }

        function revealItem(item) {
            var point = item.mapToItem(pageColumn, 0, 0)
            var itemTop = point.y
            var itemBottom = itemTop + item.height
            if (itemTop < contentY) {
                contentY = itemTop
            } else if (itemBottom > contentY + height) {
                contentY = Math.max(0, Math.min(contentHeight - height,
                                               itemBottom - height))
            }
        }

        Column {
            id: pageColumn

            width: Math.max(0, Math.min(pageFlickable.width - Theme.spaceSm, 900))
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spaceLg

            Column {
                width: parent.width
                spacing: Theme.spaceXs

                Text {
                    width: parent.width
                    text: qsTr("Managed computers")
                    color: Theme.text
                    font.family: Theme.fontSans
                    font.pointSize: 26
                    font.weight: Font.ExtraBold
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: Theme.trackingTight(26)
                    wrapMode: Text.Wrap
                }

                Text {
                    width: parent.width
                    text: ManagedBackend.loggedIn
                          ? qsTr("Choose a computer assigned to your account.")
                          : qsTr("Sign in to your organization's Moonlight backend.")
                    color: Theme.textDim
                    font.family: Theme.fontSans
                    font.pointSize: Theme.fontBody
                    wrapMode: Text.Wrap
                }
            }

            Panel {
                width: parent.width
                height: statusColumn.implicitHeight + Theme.spaceLg * 2
                visible: root.displayedMessage() !== "" || ManagedBackend.busy
                fill: Theme.surfaceLayer
                borderColor: Theme.lineStrong
                accentBarColor: root.localMessage !== "" ? Theme.danger : Theme.accent
                accentBarWidth: Theme.accentBar

                Column {
                    id: statusColumn
                    anchors {
                        left: parent.left
                        right: parent.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: Theme.spaceLg
                        rightMargin: Theme.spaceLg
                    }
                    spacing: Theme.spaceSm

                    MicroLabel {
                        width: parent.width
                        text: ManagedBackend.busy ? qsTr("Working") : qsTr("Backend status")
                        color: root.localMessage !== "" ? Theme.danger : Theme.accent
                    }

                    Text {
                        width: parent.width
                        visible: root.displayedMessage() !== ""
                        height: visible ? implicitHeight : 0
                        text: root.displayedMessage()
                        color: Theme.text
                        font.family: Theme.fontSans
                        font.pointSize: Theme.fontBody
                        wrapMode: Text.Wrap
                    }

                    HardProgress {
                        width: parent.width
                        visible: ManagedBackend.busy
                        height: visible ? implicitHeight : 0
                        running: visible
                    }
                }
            }

            Panel {
                width: parent.width
                height: signInColumn.implicitHeight + Theme.spaceXl * 2
                visible: !ManagedBackend.loggedIn
                fill: Theme.surfaceLayer
                borderColor: Theme.lineStrong
                accentBarColor: Theme.accent
                accentBarWidth: Theme.accentBar

                Column {
                    id: signInColumn
                    anchors {
                        left: parent.left
                        right: parent.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: Theme.spaceXl
                        rightMargin: Theme.spaceXl
                    }
                    spacing: Theme.spaceMd

                    MicroLabel {
                        text: qsTr("Backend URL")
                    }

                    HardTextField {
                        id: backendUrlField
                        width: parent.width
                        placeholderText: qsTr("HTTPS backend URL")
                        inputMethodHints: Qt.ImhUrlCharactersOnly | Qt.ImhNoAutoUppercase
                        enabled: !ManagedBackend.busy
                        onTextEdited: root.localMessage = ""
                        onActiveFocusChanged: if (activeFocus) pageFlickable.revealItem(this)
                        Keys.onDownPressed: usernameField.forceActiveFocus(Qt.TabFocusReason)
                        Keys.onReturnPressed: usernameField.forceActiveFocus(Qt.TabFocusReason)
                        Keys.onEnterPressed: usernameField.forceActiveFocus(Qt.TabFocusReason)
                    }

                    MicroLabel {
                        text: qsTr("Username")
                    }

                    HardTextField {
                        id: usernameField
                        width: parent.width
                        enabled: !ManagedBackend.busy
                        onTextEdited: root.localMessage = ""
                        onActiveFocusChanged: if (activeFocus) pageFlickable.revealItem(this)
                        Keys.onUpPressed: backendUrlField.forceActiveFocus(Qt.TabFocusReason)
                        Keys.onDownPressed: passwordField.forceActiveFocus(Qt.TabFocusReason)
                        Keys.onReturnPressed: passwordField.forceActiveFocus(Qt.TabFocusReason)
                        Keys.onEnterPressed: passwordField.forceActiveFocus(Qt.TabFocusReason)
                    }

                    MicroLabel {
                        text: qsTr("Password")
                    }

                    HardTextField {
                        id: passwordField
                        width: parent.width
                        echoMode: TextInput.Password
                        enabled: !ManagedBackend.busy
                        onTextEdited: root.localMessage = ""
                        onActiveFocusChanged: if (activeFocus) pageFlickable.revealItem(this)
                        Keys.onUpPressed: usernameField.forceActiveFocus(Qt.TabFocusReason)
                        Keys.onDownPressed: signInButton.forceActiveFocus(Qt.TabFocusReason)
                        Keys.onReturnPressed: root.submitSignIn()
                        Keys.onEnterPressed: root.submitSignIn()
                    }

                    HardButton {
                        id: signInButton
                        width: parent.width
                        height: 44
                        text: ManagedBackend.busy ? qsTr("Signing in…") : qsTr("Sign in")
                        primary: true
                        enabled: !ManagedBackend.busy
                        onClicked: root.submitSignIn()
                        onActiveFocusChanged: if (activeFocus) pageFlickable.revealItem(this)
                        Keys.onUpPressed: passwordField.forceActiveFocus(Qt.TabFocusReason)
                        Keys.onDownPressed: {}
                    }
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spaceLg
                visible: ManagedBackend.loggedIn

                Flow {
                    width: parent.width
                    spacing: Theme.spaceSm

                    HardButton {
                        id: refreshButton
                        text: ManagedBackend.busy ? qsTr("Refreshing…") : qsTr("Refresh")
                        enabled: !ManagedBackend.busy
                        onClicked: {
                            root.localMessage = ""
                            ManagedBackend.refresh()
                        }
                        Keys.onRightPressed: signOutButton.forceActiveFocus(Qt.TabFocusReason)
                        Keys.onDownPressed: root.focusMachine(0, 1)
                    }

                    HardButton {
                        id: signOutButton
                        text: qsTr("Sign out")
                        enabled: !ManagedBackend.busy
                        onClicked: {
                            passwordField.clear()
                            root.localMessage = ""
                            ManagedBackend.signOut()
                        }
                        Keys.onLeftPressed: refreshButton.forceActiveFocus(Qt.TabFocusReason)
                        Keys.onDownPressed: root.focusMachine(0, 1)
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spaceMd

                    Repeater {
                        id: machineRepeater
                        model: ManagedBackend.machines

                        Panel {
                            id: machineCard

                            property var machine: modelData
                            property bool online: root.isMachineOnline(machine)
                            property alias connectButton: machineConnectButton

                            width: machineRepeater.parent.width
                            height: machineColumn.implicitHeight + Theme.spaceLg * 2
                            fill: Theme.surfaceLayer
                            borderColor: online ? Theme.lineStrong : Theme.line
                            accentBarColor: online ? Theme.acid : Theme.textFaint
                            accentBarWidth: Theme.accentBar

                            Column {
                                id: machineColumn
                                anchors {
                                    left: parent.left
                                    right: parent.right
                                    verticalCenter: parent.verticalCenter
                                    leftMargin: Theme.spaceLg
                                    rightMargin: Theme.spaceLg
                                }
                                spacing: Theme.spaceSm

                                Row {
                                    width: parent.width
                                    spacing: Theme.spaceSm

                                    Rectangle {
                                        width: 9
                                        height: 9
                                        anchors.verticalCenter: parent.verticalCenter
                                        color: machineCard.online ? Theme.acid : Theme.textFaint
                                    }

                                    MicroLabel {
                                        width: parent.width - 9 - parent.spacing
                                        text: machineCard.online ? qsTr("Online") : qsTr("Offline")
                                        color: machineCard.online ? Theme.acid : Theme.textFaint
                                    }
                                }

                                Text {
                                    width: parent.width
                                    text: String(machineCard.machine.name || qsTr("Unnamed computer"))
                                    color: Theme.text
                                    font.family: Theme.fontSans
                                    font.pointSize: Theme.fontCardTitle
                                    font.weight: Font.Bold
                                    elide: Text.ElideRight
                                }

                                Text {
                                    width: parent.width
                                    text: root.machineEndpoint(machineCard.machine)
                                    color: Theme.textDim
                                    font.family: Theme.fontMono
                                    font.pointSize: Theme.fontCaption
                                    elide: Text.ElideMiddle
                                }

                                Text {
                                    width: parent.width
                                    visible: Number(machineCard.machine.managed_protocol) !== 1
                                    height: visible ? implicitHeight : 0
                                    text: qsTr("This computer does not support managed connections.")
                                    color: Theme.danger
                                    font.family: Theme.fontSans
                                    font.pointSize: Theme.fontBody
                                    wrapMode: Text.Wrap
                                }

                                HardButton {
                                    id: machineConnectButton
                                    width: parent.width
                                    height: 40
                                    primary: machineCard.online
                                    enabled: machineCard.online && !ManagedBackend.busy
                                    text: String(ManagedBackend.connectingMachine) === String(machineCard.machine.id)
                                          ? qsTr("Connecting…") : qsTr("Connect")
                                    onClicked: {
                                        root.localMessage = ""
                                        ManagedBackend.connectMachine(machineCard.machine.id)
                                    }
                                    onActiveFocusChanged: if (activeFocus) pageFlickable.revealItem(machineCard)
                                    Keys.onUpPressed: {
                                        if (!root.focusMachine(index - 1, -1)) {
                                            refreshButton.forceActiveFocus(Qt.TabFocusReason)
                                        }
                                    }
                                    Keys.onDownPressed: root.focusMachine(index + 1, 1)
                                }
                            }
                        }
                    }

                    Text {
                        width: parent.width
                        visible: machineRepeater.count === 0 && !ManagedBackend.busy
                        text: qsTr("No computers are assigned to this account.")
                        color: Theme.textDim
                        font.family: Theme.fontMono
                        font.pointSize: Theme.fontBody
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
    }
}
