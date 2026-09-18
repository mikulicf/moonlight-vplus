import QtQuick
import QtQuick.Controls
import QtTest
import "../../app/gui"
import "../../app/gui/settings"

TestCase {
    name: "SettingsLocalization"
    width: 760
    height: 640
    when: windowShown

    FontLoader { source: "../../app/res/fonts/Manrope-Regular.ttf" }
    FontLoader { source: "../../app/res/fonts/Manrope-ExtraBold.ttf" }

    Component {
        id: railComponent
        CategoryRail {
            height: 600
            categories: [
                { key: "gamepad", title: "Gamepad Settings", icon: "" },
                { key: "peripherals", title: "Peripherals Settings", icon: "" },
                { key: "software", title: "Software Settings", icon: "" },
                { key: "ecosystem", title: "AlkaidLab Ecosystem", icon: "" }
            ]
        }
    }

    DialogButtonBox {
        id: translatedButtonBox
        standardButtons: DialogButtonBox.Ok | DialogButtonBox.Cancel |
                         DialogButtonBox.Close | DialogButtonBox.Help |
                         DialogButtonBox.Yes | DialogButtonBox.No
    }

    StandardButtonLabels {
        id: translatedButtonLabels
        buttonBox: translatedButtonBox
        language: 0
        englishLanguage: 1
    }

    function test_compiledChinese() {
        compare(qsTranslate("SettingsView", "Settings"), "\u8bbe\u7f6e")
        compare(qsTranslate("SettingsView", "Software Settings"), "\u8f6f\u4ef6\u8bbe\u7f6e")
        compare(qsTranslate("LegacySettingsPage", "Language"), "\u8bed\u8a00")
        compare(qsTranslate("AboutSettingsPage", "About"), "\u5173\u4e8e")
        verify(qsTranslate("OverlayMenuPanel", "Connected — select to release") !== "Connected — select to release")
        verify(qsTranslate("StylusReplayTest", "Stylus replay stopped.") !== "Stylus replay stopped.")
    }

    function test_standardButtonsUseAppTranslation() {
        translatedButtonLabels.apply()
        compare(translatedButtonBox.standardButton(DialogButtonBox.Ok).text, "\u786e\u5b9a")
        compare(translatedButtonBox.standardButton(DialogButtonBox.Cancel).text, "\u53d6\u6d88")
        compare(translatedButtonBox.standardButton(DialogButtonBox.Close).text, "\u5173\u95ed")
        compare(translatedButtonBox.standardButton(DialogButtonBox.Help).text, "\u5e2e\u52a9")
        compare(translatedButtonBox.standardButton(DialogButtonBox.Yes).text, "\u662f")
        compare(translatedButtonBox.standardButton(DialogButtonBox.No).text, "\u5426")

        translatedButtonLabels.language = 1
        translatedButtonLabels.apply()
        compare(translatedButtonBox.standardButton(DialogButtonBox.Ok).text, "OK")
        compare(translatedButtonBox.standardButton(DialogButtonBox.Cancel).text, "Cancel")
        compare(translatedButtonBox.standardButton(DialogButtonBox.Close).text, "Close")
        compare(translatedButtonBox.standardButton(DialogButtonBox.Help).text, "Help")
        compare(translatedButtonBox.standardButton(DialogButtonBox.Yes).text, "Yes")
        compare(translatedButtonBox.standardButton(DialogButtonBox.No).text, "No")
    }

    function test_standardButtonMnemonicRemoval() {
        compare(translatedButtonLabels.removeMnemonics("&Yes"), "Yes")
        compare(translatedButtonLabels.removeMnemonics("Save && Close"), "Save & Close")
        compare(translatedButtonLabels.removeMnemonics("\u662f(&Y)"), "\u662f")
        compare(translatedButtonLabels.removeMnemonics("\u5426\uff08&N\uff09"), "\u5426")
    }

    function test_titlesFit_data() {
        return [
            { tag: "narrow-rail", railWidth: 168, compact: false },
            { tag: "standard-rail", railWidth: 200, compact: false },
            { tag: "horizontal-tabs", railWidth: 740, compact: true }
        ]
    }

    function test_titlesFit(data) {
        var rail = createTemporaryObject(railComponent, this, {
            width: data.railWidth, compact: data.compact,
            height: data.compact ? 46 : 600
        })
        verify(rail)
        var list = rail.children[0]
        for (var i = 0; i < rail.categories.length; ++i) {
            rail.currentCategory = rail.categories[i].key
            rail.ensureCurrentVisible()
            tryVerify(function() { return list.itemAtIndex(i) !== null })
            wait(50)
            var row = list.itemAtIndex(i)
            var label = row.contentItem.children[1]
            verify(!label.truncated, label.text + " is truncated")
            verify(label.contentWidth <= label.width + 1, label.text + " overflows horizontally")
            verify(label.height <= row.availableHeight + 1, label.text + " overflows vertically")
            verify(label.x + label.width <= row.contentItem.width + 1)
        }
    }
}
