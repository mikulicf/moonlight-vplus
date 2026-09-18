#include "cursorshapeclassifier.h"

#include <QVector>

#include <algorithm>
#include <cmath>

namespace {

// Treat low-alpha antialiased edges as transparent so faint pixels do not inflate bounds.
constexpr int OpaqueAlphaThreshold = 32;

// Larger-than-normal cursors remain unknown and use bitmap rendering.
constexpr int MaxCursorDimension = 128;

qreal medianOf(QVector<int> values)
{
    if (values.isEmpty()) {
        return 0.0;
    }

    std::sort(values.begin(), values.end());
    const int mid = values.size() / 2;
    if (values.size() % 2 != 0) {
        return values[mid];
    }
    return (values[mid - 1] + values[mid]) / 2.0;
}

} // namespace

CursorShapeMetrics measureCursorShape(int width,
                                      int height,
                                      int hotspotX,
                                      int hotspotY,
                                      const QByteArray& bgra)
{
    CursorShapeMetrics metrics;

    if (width <= 0 || height <= 0 ||
        width > MaxCursorDimension || height > MaxCursorDimension) {
        return metrics;
    }

    if (bgra.size() != static_cast<qint64>(width) * height * 4) {
        return metrics;
    }

    const uchar* pixels = reinterpret_cast<const uchar*>(bgra.constData());

    int left = width;
    int top = height;
    int right = -1;
    int bottom = -1;
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            const int alphaIndex = (y * width + x) * 4 + 3;
            if (pixels[alphaIndex] <= OpaqueAlphaThreshold) {
                continue;
            }
            left = qMin(left, x);
            top = qMin(top, y);
            right = qMax(right, x);
            bottom = qMax(bottom, y);
        }
    }

    if (right < 0) {
        // A fully transparent bitmap may represent a hidden host cursor.
        return metrics;
    }

    const int boxWidth = right - left + 1;
    const int boxHeight = bottom - top + 1;

    QVector<quint8> box(boxWidth * boxHeight, 0);
    int opaqueCount = 0;
    for (int y = 0; y < boxHeight; y++) {
        for (int x = 0; x < boxWidth; x++) {
            const int alphaIndex = ((y + top) * width + (x + left)) * 4 + 3;
            if (pixels[alphaIndex] > OpaqueAlphaThreshold) {
                box[y * boxWidth + x] = 1;
                opaqueCount++;
            }
        }
    }

    metrics.boxWidth = boxWidth;
    metrics.boxHeight = boxHeight;
    metrics.fill = static_cast<qreal>(opaqueCount) / (boxWidth * boxHeight);
    metrics.hotspotX = boxWidth > 1
                           ? qBound(0.0,
                                    static_cast<qreal>(hotspotX - left) / (boxWidth - 1),
                                    1.0)
                           : 0.0;
    metrics.hotspotY = boxHeight > 1
                           ? qBound(0.0,
                                    static_cast<qreal>(hotspotY - top) / (boxHeight - 1),
                                    1.0)
                           : 0.0;

    int matchV = 0;
    int matchH = 0;
    int matchRot180 = 0;
    for (int y = 0; y < boxHeight; y++) {
        for (int x = 0; x < boxWidth; x++) {
            if (box[y * boxWidth + x] == box[y * boxWidth + (boxWidth - 1 - x)]) {
                matchV++;
            }
            if (box[y * boxWidth + x] == box[(boxHeight - 1 - y) * boxWidth + x]) {
                matchH++;
            }
            if (box[y * boxWidth + x] ==
                box[(boxHeight - 1 - y) * boxWidth + (boxWidth - 1 - x)]) {
                matchRot180++;
            }
        }
    }
    metrics.symV = static_cast<qreal>(matchV) / (boxWidth * boxHeight);
    metrics.symH = static_cast<qreal>(matchH) / (boxWidth * boxHeight);
    metrics.symRot180 = static_cast<qreal>(matchRot180) / (boxWidth * boxHeight);

    qreal sumX = 0.0;
    qreal sumY = 0.0;
    qreal sumXX = 0.0;
    qreal sumYY = 0.0;
    qreal sumXY = 0.0;
    for (int y = 0; y < boxHeight; y++) {
        for (int x = 0; x < boxWidth; x++) {
            if (box[y * boxWidth + x] == 0) {
                continue;
            }
            sumX += x;
            sumY += y;
            sumXX += static_cast<qreal>(x) * x;
            sumYY += static_cast<qreal>(y) * y;
            sumXY += static_cast<qreal>(x) * y;
        }
    }
    const qreal meanX = sumX / opaqueCount;
    const qreal meanY = sumY / opaqueCount;
    const qreal varX = sumXX / opaqueCount - meanX * meanX;
    const qreal varY = sumYY / opaqueCount - meanY * meanY;
    if (varX > 0.0 && varY > 0.0) {
        const qreal covXY = sumXY / opaqueCount - meanX * meanY;
        metrics.diagonalCorrelation =
            qBound(-1.0, covXY / std::sqrt(varX * varY), 1.0);
    }

    // Central opacity distinguishes hollow rings from solid intersecting arrow/cross arms.
    const int centerLeft = boxWidth * 3 / 8;
    const int centerTop = boxHeight * 3 / 8;
    const int centerWidth = qMax(1, boxWidth / 4);
    const int centerHeight = qMax(1, boxHeight / 4);
    int centerOpaque = 0;
    for (int y = centerTop; y < centerTop + centerHeight; y++) {
        for (int x = centerLeft; x < centerLeft + centerWidth; x++) {
            if (box[y * boxWidth + x] != 0) {
                centerOpaque++;
            }
        }
    }
    metrics.centerFill =
        static_cast<qreal>(centerOpaque) / (centerWidth * centerHeight);

    QVector<int> rowWidths(boxHeight, 0);
    for (int y = 0; y < boxHeight; y++) {
        for (int x = 0; x < boxWidth; x++) {
            if (box[y * boxWidth + x] != 0) {
                rowWidths[y]++;
            }
        }
    }

    const qreal medianRow = medianOf(rowWidths);
    const auto widestRow = std::max_element(rowWidths.cbegin(), rowWidths.cend());
    const int maxRow = *widestRow;
    const int widestRowIndex =
        static_cast<int>(std::distance(rowWidths.cbegin(), widestRow));

    const int topRows = qMax(1, boxHeight * 15 / 100);
    int topSum = 0;
    for (int y = 0; y < topRows; y++) {
        topSum += rowWidths[y];
    }
    if (medianRow > 0.0) {
        metrics.topWidthRatio = (static_cast<qreal>(topSum) / topRows) / medianRow;
    }
    if (maxRow > 0) {
        metrics.firstRowRatio = static_cast<qreal>(rowWidths[0]) / maxRow;
    }
    if (boxHeight > 1) {
        metrics.widestRowPosition =
            static_cast<qreal>(widestRowIndex) / (boxHeight - 1);
    }

    const int upperHalf = qMax(1, boxHeight / 2);
    for (int y = 0; y + 1 < upperHalf; y++) {
        if (rowWidths[y + 1] < rowWidths[y]) {
            metrics.topMonotoneViolations++;
        }
    }

    metrics.valid = true;
    return metrics;
}

NativeCursorShape classifyCursorShape(const CursorShapeMetrics& metrics)
{
    if (!metrics.valid) {
        return NativeCursorShape::Unknown;
    }

    // Values greater than one indicate a vertically elongated shape.
    const qreal tallness =
        static_cast<qreal>(metrics.boxHeight) / metrics.boxWidth;
    const bool centeredHotspot =
        metrics.hotspotX >= 0.30 && metrics.hotspotX <= 0.70 &&
        metrics.hotspotY >= 0.30 && metrics.hotspotY <= 0.70;
    const bool nearSquare = tallness >= 0.80 && tallness <= 1.25;

    // I-beam: narrow, vertically symmetric, centered hotspot, and a widest first-row serif.
    // The flat top distinguishes it from vertical resize arrows with pointed tips.
    //
    // Measured Windows 64x64 I-beam bounds are 21x36 (1.71 tallness).
    // A 1.8 threshold incorrectly rejected real cursors with relatively wide serifs.
    if (tallness >= 1.5 && metrics.fill <= 0.60 && metrics.symV >= 0.85 &&
        centeredHotspot &&
        metrics.firstRowRatio >= 0.90 && metrics.topWidthRatio >= 1.5) {
        return NativeCursorShape::IBeam;
    }

    // Arrow: top-left hotspot, pointed expanding triangular head, and clear asymmetry.
    if (metrics.hotspotX <= 0.20 && metrics.hotspotY <= 0.20 &&
        tallness >= 1.15 && tallness <= 2.6 &&
        metrics.symV <= 0.65 &&
        metrics.firstRowRatio <= 0.35 &&
        metrics.topMonotoneViolations <= 2) {
        return NativeCursorShape::Arrow;
    }

    // IDC_APPSTARTING adds a ring at the arrow's upper right. Its leftmost hotspot
    // remains at the tip, but the expanded bounds move hotspotY beyond the plain
    // arrow's <= 0.20 criterion, making these cases mutually exclusive.
    //
    // Windows 64x64 sample: bounds=44x53, fill=0.446, hotspot=(0.00,0.29),
    // symV=0.409, corr=-0.540. The left arrow and upper-right ring form separate
    // masses. Use stable bounds/hotspot constraints and only coarse correlation
    // limits because the animated ring changes frame-to-frame measurements.
    if (metrics.hotspotX <= 0.15 &&
        metrics.hotspotY > 0.20 && metrics.hotspotY <= 0.45 &&
        tallness >= 0.90 && tallness <= 1.60 &&
        metrics.fill >= 0.25 && metrics.fill <= 0.65 &&
        metrics.symV <= 0.70 &&
        metrics.diagonalCorrelation <= -0.25) {
        return NativeCursorShape::AppStarting;
    }

    // Hand: near-top central fingertip, narrow top expanding toward a wider lower fist.
    // Strict width-profile constraints reject arbitrary top-hotspot blobs. Vertical
    // symmetry only excludes fully symmetric shapes; a real thumb is asymmetric.
    if (tallness >= 0.85 && tallness <= 1.45 &&
        metrics.hotspotY <= 0.20 &&
        metrics.hotspotX >= 0.15 && metrics.hotspotX <= 0.60 &&
        metrics.fill >= 0.35 && metrics.fill <= 0.80 &&
        metrics.symV <= 0.90 &&
        metrics.firstRowRatio <= 0.50 &&
        metrics.widestRowPosition >= 0.40 &&
        metrics.topMonotoneViolations <= 2) {
        return NativeCursorShape::Hand;
    }

    // Remaining resize cursors have centered hotspots.
    if (!centeredHotspot) {
        return NativeCursorShape::Unknown;
    }

    // IDC_WAIT is a hollow ring.
    //
    // Windows 64x64 sample: bounds=40x40, fill=0.570, hotspot=(0.51,0.51),
    // symV=symH=symRot180=1.000, corr=0.000, widestRow=0.205. Brightness
    // animates but the alpha mask stays fixed, so measurements do not fluctuate.
    //
    // Crosses and four-way arrows share square bounds, symmetry, and a centered hotspot.
    // The ring has higher overall fill and an empty center, unlike their intersecting arms.
    if (nearSquare &&
        metrics.symV >= 0.90 && metrics.symH >= 0.90 &&
        metrics.symRot180 >= 0.90 &&
        metrics.fill >= 0.40 && metrics.fill <= 0.80 &&
        metrics.centerFill <= 0.15) {
        return NativeCursorShape::Wait;
    }

    // Horizontal resize arrow.
    if (tallness <= 1.0 / 1.8 && metrics.symV >= 0.85 && metrics.symH >= 0.80) {
        return NativeCursorShape::SizeWE;
    }

    // Vertical resize arrow: a low firstRowRatio identifies the tip and excludes I-beams.
    if (tallness >= 1.8 && metrics.symH >= 0.85 && metrics.symV >= 0.80 &&
        metrics.firstRowRatio <= 0.60) {
        return NativeCursorShape::SizeNS;
    }

    // Diagonal resize arrows concentrate mass along a diagonal; signed correlation
    // identifies direction. Nondirectional crosses, blocks, and four-way arrows
    // remain Unknown and safely fall back to the host bitmap.
    if (nearSquare && metrics.fill <= 0.45 && metrics.symRot180 >= 0.85) {
        if (metrics.diagonalCorrelation >= 0.70) {
            return NativeCursorShape::SizeNWSE;
        }
        if (metrics.diagonalCorrelation <= -0.70) {
            return NativeCursorShape::SizeNESW;
        }
    }

    return NativeCursorShape::Unknown;
}

NativeCursorShape classifyCursorShape(int width,
                                      int height,
                                      int hotspotX,
                                      int hotspotY,
                                      const QByteArray& bgra)
{
    return classifyCursorShape(
        measureCursorShape(width, height, hotspotX, hotspotY, bgra));
}

const char* nativeCursorShapeName(NativeCursorShape shape)
{
    switch (shape) {
    case NativeCursorShape::Arrow:    return "arrow";
    case NativeCursorShape::AppStarting: return "app-starting";
    case NativeCursorShape::Wait:     return "wait";
    case NativeCursorShape::IBeam:    return "ibeam";
    case NativeCursorShape::Hand:     return "hand";
    case NativeCursorShape::SizeWE:   return "size-we";
    case NativeCursorShape::SizeNS:   return "size-ns";
    case NativeCursorShape::SizeNWSE: return "size-nwse";
    case NativeCursorShape::SizeNESW: return "size-nesw";
    case NativeCursorShape::Unknown:  break;
    }
    return "unknown";
}
