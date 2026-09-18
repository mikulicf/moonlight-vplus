import QtQuick 2.9
import Qt.labs.platform 1.1 as Platform

Item {
    id: root
    visible: false

    property string title: ""
    property var nameFilters: []
    property bool saveMode: false
    property string defaultSuffix: ""
    property string acceptLabel: ""
    property string rejectLabel: ""

    signal accepted(url fileUrl)

    function open() {
        dialog.open()
    }

    Platform.FileDialog {
        id: dialog
        title: root.title
        nameFilters: root.nameFilters
        defaultSuffix: root.defaultSuffix
        acceptLabel: root.acceptLabel
        rejectLabel: root.rejectLabel
        fileMode: root.saveMode ? Platform.FileDialog.SaveFile : Platform.FileDialog.OpenFile
        onAccepted: root.accepted(file)
    }
}
