pragma Singleton
import QtQuick 2.9

// Shared design tokens for the application's dark industrial theme.
//
// Square corners, hard shadows, neutral surfaces, one primary accent, geometric
// typography, monospaced data, and spaced uppercase labels. Centralize style changes here.
QtObject {
    // ---- Surfaces ----
    // Opaque cards keep wallpaper in the gaps rather than showing through each card.
    readonly property color ink: "#0F1115"       // Bottom layer.
    readonly property color surface: "#171A20"   // Cards and panels.
    readonly property color surface2: "#1F232B"  // Hover and input fields.
    readonly property color surfaceLayer: "#E0171A20"  // About 88% opaque.
    readonly property color surface2Layer: "#E01F232B" // Raised translucent surface.
    readonly property color line: "#2B3038"      // One-pixel borders.
    readonly property color lineStrong: "#3C434E" // Brighter control outlines.

    // ---- Text ----
    readonly property color text: "#EEF0EC"      // Warm off-white.
    readonly property color textDim: "#AEB3AB"   // Subtitles and descriptions.
    readonly property color textFaint: "#7E858E" // Disabled and secondary details.
    // Keep long descriptions brighter for high DPI and complex backgrounds.
    readonly property color textSettingsSubtitle: "#D7DBD5"

    // ---- Accents ----
    // Teal is the primary accent; reserve lime for prominent running/LIVE state markers.
    readonly property color accent: "#39C5BB"
    readonly property color accentStrong: "#5DD9D0"
    readonly property color accentDim: "#2BA39A"
    readonly property color accentSoft: "#2639C5BB"  // 15% accent selection fill.
    readonly property color acid: "#C8FF4D"          // --cend-acid
    readonly property color acidGlow: "#66C8FF4D"    // --cend-glow-acid
    readonly property color danger: "#FF876F"        // --cend-coral

    // ---- Shapes ----
    // Override each FluentWinUI3 control background to retain square corners.
    readonly property int radiusCard: 0
    readonly property int radiusControl: 0

    // Panel.qml simulates a solid, unblurred offset shadow using a backing rectangle.
    readonly property int shadowOffset: 6
    readonly property int shadowOffsetLift: 9     // Raised hover/focus shadow.
    readonly property color shadowColor: "#8C000000"

    // Left accent bars: four pixels for cards, five for status markers.
    readonly property int accentBar: 4
    readonly property int accentBarStrong: 5

    // ---- Fonts ----
    // Bundled in app/res/fonts and registered by main.cpp; system fonts supply missing glyphs.
    readonly property string fontSans: "Manrope"
    readonly property string fontMono: "DM Mono"

    // QML letterSpacing uses pixels, not em. Convert by font size: micro-labels
    // use approximately 0.18-0.24em and headings use -0.03em.
    function tracking(pointSize, em) { return pointSize * 1.333 * em }
    function trackingWide(pointSize) { return tracking(pointSize, 0.2) }
    function trackingTight(pointSize) { return tracking(pointSize, -0.03) }
    // Precomputed spacing for common sizes avoids repeated function calls in bindings.
    readonly property real trackingCaption: trackingWide(fontCaption)
    readonly property real trackingLabel: trackingWide(fontBody)

    // ---- Eight-point spacing grid ----
    readonly property int spaceXs: 4
    readonly property int spaceSm: 8
    readonly property int spaceMd: 12
    readonly property int spaceLg: 16
    readonly property int spaceXl: 24

    // ---- Font sizes ----
    readonly property int fontCardTitle: 13
    readonly property int fontHeroTitle: 18
    readonly property int fontRowTitle: 11
    readonly property int fontBody: 10
    readonly property int fontCaption: 9
    readonly property int fontSettingsSubtitle: fontBody

    // ---- Animation ----
    // Short, mechanical OutQuad transitions without bounce or long easing tails.
    readonly property int durFast: 120
    readonly property int durNormal: 150
    readonly property int easing: Easing.OutQuad

    // ---- Layout ----
    readonly property int railWidth: 208
    // Collapse the rail into horizontal tabs below this width.
    readonly property int compactBreakpoint: 860
    // Move row controls below descriptions when content is narrower than this threshold.
    readonly property int settingsRowStackBreakpoint: 520
}
