import QtQuick 2.0
import QtQuick.Controls

// Keep app-owned dialog captions in the selected application language. Qt's
// built-in captions otherwise follow the system-locale qt_*.qm catalog loaded
// by QQmlApplicationEngine, which may differ from the app language.
QtObject {
    id: labels

    property var buttonBox
    property int language
    property int englishLanguage

    readonly property bool explicitEnglish: language === englishLanguage
    readonly property string okText: translatedText("OK", "OK")
    readonly property string cancelText: translatedText("Cancel", "Cancel")
    // Close already has an app-owned translation context. Using it avoids
    // falling through to an unrelated system-locale QPlatformTheme catalog
    // when a selected language has no translated Close entry yet.
    readonly property string closeText: explicitEnglish
                                        ? "Close"
                                        : qsTranslate("main", "Close")
    readonly property string helpText: translatedText("Help", "Help")
    readonly property string yesText: translatedText("&Yes", "Yes")
    readonly property string noText: translatedText("&No", "No")
    readonly property string translationRevision: JSON.stringify([
        okText, cancelText, closeText, helpText, yesText, noText
    ])

    function removeMnemonics(text) {
        // Match QPlatformTheme::removeMnemonics(), including East Asian
        // translations such as "Yes(&Y)" and escaped ampersands.
        var withoutSuffix = text.replace(/\s*[\(\uff08]&[^&][\)\uff09]/g, "")
        return withoutSuffix.replace(/&&|&/g, function(match) {
            return match === "&&" ? "&" : ""
        })
    }

    function translatedText(sourceText, englishText) {
        if (explicitEnglish) {
            return englishText
        }
        return removeMnemonics(qsTranslate("QPlatformTheme", sourceText))
    }

    function setStandardButtonText(standardButton, text) {
        if (!buttonBox) {
            return
        }
        var button = buttonBox.standardButton(standardButton)
        if (button) {
            button.text = text
        }
    }

    function apply() {
        setStandardButtonText(DialogButtonBox.Ok, okText)
        setStandardButtonText(DialogButtonBox.Cancel, cancelText)
        setStandardButtonText(DialogButtonBox.Close, closeText)
        setStandardButtonText(DialogButtonBox.Help, helpText)
        setStandardButtonText(DialogButtonBox.Yes, yesText)
        setStandardButtonText(DialogButtonBox.No, noText)
    }

    onTranslationRevisionChanged: Qt.callLater(function() { labels.apply() })
    Component.onCompleted: Qt.callLater(function() { labels.apply() })
}
