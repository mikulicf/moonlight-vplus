import QtQuick 2.9
import QtQuick.Controls
import "../theme"

// Category rail; compact mode changes it into horizontal tabs for narrow windows.
//
// Each category joins the Tab focus chain used by gamepad up/down. Moving focus
// does not switch content; confirm with A/Space or the direction toward the content.
Item {
    id: rail

    property var categories: []
    property string currentCategory: ""
    property bool compact: false

    // ListView is a focus scope, so activeFocus includes any focused delegate.
    readonly property bool railFocused: list.activeFocus

    signal categoryPicked(string category)
    // The user confirmed a category and wants focus to enter its content.
    signal contentRequested()

    function step(delta) {
        var index = indexOf(currentCategory)
        if (index < 0) {
            return
        }
        var next = index + delta
        if (next < 0) {
            next = categories.length - 1
        }
        else if (next >= categories.length) {
            next = 0
        }
        categoryPicked(categories[next].key)
    }

    function indexOf(key) {
        for (var i = 0; i < categories.length; i++) {
            if (categories[i].key === key) {
                return i
            }
        }
        return -1
    }

    function ensureCurrentVisible() {
        var index = indexOf(currentCategory)
        if (index < 0) {
            return
        }

        list.currentIndex = index
        list.positionViewAtIndex(index, ListView.Contain)
    }

    onCurrentCategoryChanged: Qt.callLater(ensureCurrentVisible)
    onCompactChanged: Qt.callLater(ensureCurrentVisible)
    onCategoriesChanged: Qt.callLater(ensureCurrentVisible)

    // Focus the selected category when entering settings or returning with B.
    function focusCurrent() {
        var index = indexOf(currentCategory)
        if (index < 0) {
            index = 0
        }
        list.currentIndex = index
        list.positionViewAtIndex(index, ListView.Contain)

        if (!focusIndex(index)) {
            // Delegates may not be laid out yet; retry on the next event-loop turn.
            Qt.callLater(focusIndex, index)
        }
    }

    // Focus index and report success; the delegate might not exist yet.
    function focusIndex(index) {
        var item = list.itemAtIndex(index)
        if (item) {
            item.forceActiveFocus(Qt.TabFocusReason)
        }
        return !!item
    }

    implicitHeight: compact ? 46 : 0

    ListView {
        id: list
        anchors.fill: parent
        orientation: rail.compact ? ListView.Horizontal : ListView.Vertical
        spacing: Theme.spaceXs
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: rail.categories

        onWidthChanged: {
            if (rail.compact) {
                Qt.callLater(rail.ensureCurrentVisible)
            }
        }

        // Delegates handle orientation-aware direction keys; do not let ListView intercept them.
        keyNavigationEnabled: false

        delegate: ItemDelegate {
            id: item

            readonly property bool current: modelData.key === rail.currentCategory

            // Replace FluentWinUI3's rounded focus rings with the background's
            // two-pixel accent border. See theme/FocusRing.qml.
            readonly property Item __focusFrameTarget: null

            width: rail.compact ? Math.max(96, label.implicitWidth + Theme.spaceXl + Theme.spaceLg) : list.width
            height: rail.compact ? list.height : Math.max(44, label.implicitHeight + topPadding + bottomPadding)
            padding: Theme.spaceSm

            // StrongFocus enables Tab and mouse focus, unlike ItemDelegate's NoFocus.
            // Gamepad up/down uses Tab/Shift+Tab in settings. Control also enables
            // activeFocusOnTab）。
            focusPolicy: Qt.StrongFocus

            onClicked: rail.categoryPicked(modelData.key)

            // Follow focused items with currentIndex for highlighting without switching categories.
            onActiveFocusChanged: {
                if (activeFocus) {
                    list.currentIndex = index
                }
            }

            // Confirm this category and move focus to its content.
            function activate() {
                rail.categoryPicked(modelData.key)
                rail.contentRequested()
            }

            function moveFocus(forward) {
                nextItemInFocusChain(forward).forceActiveFocus(Qt.TabFocusReason)
            }

            Keys.onReturnPressed: activate()
            Keys.onEnterPressed: activate()
            // Gamepad A sends Space in UI navigation mode.
            Keys.onSpacePressed: activate()

            // Vertical rail: up/down selects, right enters content.
            // Horizontal tabs: left/right selects, down enters content.
            Keys.onUpPressed:    if (!rail.compact) moveFocus(false)
            Keys.onLeftPressed:  if (rail.compact)  moveFocus(false)
            Keys.onDownPressed:  rail.compact ? activate() : moveFocus(true)
            Keys.onRightPressed: rail.compact ? moveFocus(true) : activate()

            // Mark the selected category with a left bar, or a bottom bar for horizontal tabs.
            //
            // Selection and focus are distinct: bar/soft fill indicates the current category;
            // a bright border indicates keyboard/gamepad visualFocus, not a mouse click.
            //
            // Use the same two-pixel accent focus border throughout the application.
            background: Rectangle {
                radius: 0
                color: item.current ? Theme.accentSoft
                                    : (item.hovered || item.visualFocus ? Theme.surface2 : "transparent")
                border.width: item.visualFocus ? 2 : 0
                border.color: Theme.accent

                Rectangle {
                    anchors {
                        left: parent.left
                        top: parent.top
                        bottom: parent.bottom
                    }
                    width: (item.current && !rail.compact) ? Theme.accentBar : 0
                    visible: width > 0
                    color: Theme.accent
                }

                Rectangle {
                    anchors {
                        left: parent.left
                        right: parent.right
                        bottom: parent.bottom
                    }
                    height: (item.current && rail.compact) ? Theme.accentBar : 0
                    visible: height > 0
                    color: Theme.accent
                }

                Behavior on color {
                    ColorAnimation { duration: Theme.durFast }
                }
            }

            contentItem: Item {
                id: label
                implicitWidth: Theme.spaceMd + categoryIcon.width + Theme.spaceSm + categoryText.implicitWidth
                implicitHeight: Math.max(categoryIcon.height, categoryText.implicitHeight)

                Image {
                    id: categoryIcon
                    x: Theme.spaceMd
                    anchors.verticalCenter: parent.verticalCenter
                    source: modelData.icon
                    // Rasterize at 2x for sharp Retina rendering.
                    sourceSize.width: 18
                    sourceSize.height: 18
                    width: 18
                    height: 18
                    // White icons use opacity to distinguish selected state.
                    opacity: item.current ? 1.0 : 0.6

                    Behavior on opacity {
                        NumberAnimation { duration: Theme.durFast }
                    }
                }

                Text {
                    id: categoryText
                    x: categoryIcon.x + categoryIcon.width + Theme.spaceSm
                    width: Math.max(0, parent.width - x)
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.title
                    color: item.current ? Theme.text : Theme.textDim
                    font.family: Theme.fontSans
                    font.pointSize: Theme.fontRowTitle
                    font.weight: item.current ? Font.ExtraBold : Font.Medium
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: Theme.tracking(Theme.fontRowTitle, 0.06)
                    wrapMode: rail.compact ? Text.NoWrap : Text.Wrap
                    elide: Text.ElideRight
                }
            }
        }
    }
}
