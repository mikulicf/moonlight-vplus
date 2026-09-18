import QtQuick
import QtQuick.Dialogs as Dialogs

import StreamingPreferences 1.0

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

    Dialogs.FileDialog {
        id: dialog
        title: root.title
        nameFilters: root.nameFilters
        defaultSuffix: root.defaultSuffix
        acceptLabel: root.acceptLabel
        rejectLabel: root.rejectLabel
        fileMode: root.saveMode ? Dialogs.FileDialog.SaveFile : Dialogs.FileDialog.OpenFile
        options: StreamingPreferences.language === StreamingPreferences.LANG_EN
                 ? Dialogs.FileDialog.DontUseNativeDialog : 0
        onAccepted: root.accepted(selectedFile)
    }
}
