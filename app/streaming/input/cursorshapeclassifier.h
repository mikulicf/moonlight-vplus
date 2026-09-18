#pragma once

#include <QByteArray>

// Hosts send raw BGRA cursor bitmaps and opaque shape IDs, without semantic types.
// Recognize standard shapes geometrically to use native system cursors with local
// styling and sharp high-DPI rendering.
//
// Use scale-independent bounds, fill, normalized hotspot, symmetry, and width profiles
// instead of pixel fingerprints. These survive Windows theme/DPI changes between
// common 32/48/64-pixel cursor sizes.
//
// Recognize only clearly distinguishable arrows, busy arrows, rings, I-beams, hands,
// and horizontal/vertical/diagonal resize cursors. Crosses and four-way arrows
// overlap geometrically and deliberately remain Unknown. Prefer bitmap fallback
// over substituting the wrong native shape.

enum class NativeCursorShape
{
    Unknown,
    Arrow,
    // IDC_APPSTARTING: arrow with a busy ring. SDL WAITARROW maps to macOS
    // HIServices' native busybutclickable cursor.
    AppStarting,
    // IDC_WAIT: a busy ring without an arrow.
    Wait,
    IBeam,
    Hand,
    SizeWE,
    SizeNS,
    SizeNWSE,
    SizeNESW,
};

// Expose classifier measurements for assertions and verbose diagnostics so observed
// misclassifications can guide threshold changes.
struct CursorShapeMetrics {
    bool valid = false;

    // Opaque-pixel bounding-box dimensions.
    int boxWidth = 0;
    int boxHeight = 0;
    // Opaque-pixel fraction within the bounding box.
    qreal fill = 0.0;
    // Normalized hotspot coordinates in [0,1], clamped when outside the bounds.
    qreal hotspotX = 0.0;
    qreal hotspotY = 0.0;
    // Symmetry scores in [0,1]: vertical reflection, horizontal reflection, and 180-degree
    // rotation.
    qreal symV = 0.0;
    qreal symH = 0.0;
    qreal symRot180 = 0.0;
    // Pearson correlation of opaque-pixel coordinates in [-1,1]. Positive means
    // top-left to bottom-right, negative the opposite, and near zero nondirectional.
    //
    // Diagonal transpose symmetry cannot distinguish the two diagonal cursors:
    // both diagonals map onto themselves under either diagonal reflection.
    // Use a signed measurement such as correlation to distinguish direction.
    qreal diagonalCorrelation = 0.0;
    // Opacity fraction in the central quarter-width/quarter-height region.
    // Rings are hollow; crosses and four-way arrows have solid intersecting arms.
    qreal centerFill = 0.0;
    // Average row width in the top 15% divided by median row width.
    qreal topWidthRatio = 0.0;
    // First-row width / maximum width. I-beam serifs are near 1; pointed resize
    // arrows are smaller. This separates otherwise similar tall, symmetric cursors
    // with centered hotspots. Hands and ordinary arrows also have pointed tops.
    qreal firstRowRatio = 0.0;
    // Normalized widest-row position. Hands widen in the lower half; I-beams are
    // widest at row zero; vertical resize arrows widen near the arrowhead base.
    qreal widestRowPosition = 0.0;
    // Number of narrowing steps in the upper half; a triangular arrowhead mostly widens.
    int topMonotoneViolations = 0;
};

CursorShapeMetrics measureCursorShape(int width,
                                      int height,
                                      int hotspotX,
                                      int hotspotY,
                                      const QByteArray& bgra);

NativeCursorShape classifyCursorShape(const CursorShapeMetrics& metrics);

// bgra is tightly packed BGRA8888 with exactly width * height * 4 bytes.
NativeCursorShape classifyCursorShape(int width,
                                      int height,
                                      int hotspotX,
                                      int hotspotY,
                                      const QByteArray& bgra);

const char* nativeCursorShapeName(NativeCursorShape shape);
