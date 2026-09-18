#include "overlaytoast.h"
#include "uifont.h"

#include <QGuiApplication>
#include <QScreen>
#include <QFontMetrics>

namespace {

// Mirror app/gui/theme/Theme.qml tokens for QPainter, which cannot access the QML singleton.
// Keep both palettes synchronized.
const QColor kSurface(0x17, 0x1A, 0x20);   // Theme.surface
const QColor kLine(0x2B, 0x30, 0x38);      // Theme.line
const QColor kAccent(0x39, 0xC5, 0xBB);    // Theme.accent
const QColor kText(0xEE, 0xF0, 0xEC);      // Theme.text
const QColor kShadow(0, 0, 0, 0x8C);       // Theme.shadowColor

const int kShadowOffset = 6;               // Theme.shadowOffset
const int kAccentBar = 4;                  // Theme.accentBar

}

OverlayToast::OverlayToast(QWindow* parent)
    : QRasterWindow(parent),
      m_FadeAnimation(nullptr),
      m_ToastHeight(40),
      m_HorizPadding(16),
      m_VertPadding(10)
{
    setFlags(Qt::Tool | Qt::FramelessWindowHint | Qt::WindowStaysOnTopHint
             | Qt::WindowDoesNotAcceptFocus | Qt::WindowTransparentForInput);

    QSurfaceFormat fmt;
    fmt.setAlphaBufferSize(8);
    setFormat(fmt);

    // Match the application font rather than Windows-only Segoe UI. main.cpp
    // registers Manrope process-wide; platform CJK fallbacks provide missing
    // glyphs for translated notifications.
    m_Font.setFamilies(UiFont::familyChain(QStringLiteral("Manrope")));
    // Use a fixed logical pixel size. Point sizes are resolved through the
    // platform's font DPI, which is not the same thing as Qt's UI scale on
    // Linux and can make this standalone window unexpectedly large.
    m_Font.setPixelSize(15); // approximately equivalent to 11pt at 96 DPI
    m_Font.setWeight(QFont::DemiBold);
    m_Font.setStyleHint(QFont::SansSerif);

    m_FadeAnimation = new QPropertyAnimation(this, "opacity", this);
    // Match Theme's short fade duration.
    m_FadeAnimation->setDuration(240);
    m_FadeAnimation->setStartValue(1.0);
    m_FadeAnimation->setEndValue(0.0);
    connect(m_FadeAnimation, &QPropertyAnimation::finished,
            this, &OverlayToast::onFadeFinished);

    m_Clock.start();
}

OverlayToast::~OverlayToast()
{
    dismissImmediately();
}

bool OverlayToast::needsEventProcessing() const
{
    return m_EventState.needsEventProcessing(m_Clock.elapsed());
}

int OverlayToast::nextEventDelayMs() const
{
    return m_EventState.nextEventDelayMs(m_Clock.elapsed());
}

void OverlayToast::beginEventProcessing()
{
    if (m_EventState.beginEventProcessing(m_Clock.elapsed())) {
        startFadeOut();
    }
}

void OverlayToast::dismissImmediately()
{
    m_FadeAnimation->stop();
    m_EventState.cancel();
    hide();
    setOpacity(1.0);
}

void OverlayToast::showToast(int parentX, int parentY, int parentW, int parentH,
                             const QString& message, int durationMs)
{
    m_Message = message;

    // This is an independent top-level window, so make its font/rendering
    // context follow the stream window's monitor before measuring text.
    const QPoint parentCenter(parentX + parentW / 2, parentY + parentH / 2);
    QScreen* targetScreen = QGuiApplication::screenAt(parentCenter);
    if (targetScreen == nullptr) {
        targetScreen = QGuiApplication::primaryScreen();
    }
    if (targetScreen != nullptr && screen() != targetScreen) {
        setScreen(targetScreen);
    }

    // Stop any ongoing fade before replacing the toast. The state deadline is
    // reset below, so an expired older toast cannot dismiss the new message.
    m_FadeAnimation->stop();
    m_EventState.show(m_Clock.elapsed(), durationMs);
    setOpacity(1.0);

    // Calculate dimensions
    QFontMetrics fm(m_Font);
    int textWidth = fm.horizontalAdvance(m_Message) + m_HorizPadding * 2 + kAccentBar;
    int toastWidth = qMin(textWidth, 560);
    if (toastWidth < 160) toastWidth = 160;

    QRect textRect = fm.boundingRect(QRect(0, 0, toastWidth - m_HorizPadding * 2 - kAccentBar, 200),
                                     Qt::AlignLeft | Qt::AlignVCenter | Qt::TextWordWrap,
                                     m_Message);
    m_ToastHeight = qMin(qMax(textRect.height() + m_VertPadding * 2, 36), 140);

    int qpX = parentX;
    int qpY = parentY;
    int qpW = parentW;
    int qpH = parentH;

    // Position at bottom-center, 60px above the bottom.
    // Extend the window around the toast for its bottom-right hard shadow.
    int x = qpX + (qpW - toastWidth) / 2;
    int y = qpY + qpH - m_ToastHeight - 60;

    setGeometry(x, y, toastWidth + kShadowOffset, m_ToastHeight + kShadowOffset);
    show();
    raise();
    requestUpdate();
}

void OverlayToast::startFadeOut()
{
    if (!m_EventState.isFading()) {
        return;
    }
    m_FadeAnimation->start();
}

void OverlayToast::onFadeFinished()
{
    m_EventState.finishFade();
    hide();
    setOpacity(1.0);
}

void OverlayToast::paintEvent(QPaintEvent*)
{
    QPainter p(this);
    // Antialias text only. Integer-aligned square edges should remain sharp
    // without translucent fringe pixels.
    p.setRenderHint(QPainter::Antialiasing, false);
    p.setRenderHint(QPainter::TextAntialiasing, true);

    int w = width();
    int h = height();
    int bodyW = w - kShadowOffset;
    int bodyH = h - kShadowOffset;

    // Clear to transparent
    p.setCompositionMode(QPainter::CompositionMode_Source);
    p.fillRect(0, 0, w, h, Qt::transparent);
    p.setCompositionMode(QPainter::CompositionMode_SourceOver);

    // Solid offset rectangle supplies the hard shadow, matching QML Panel.
    p.fillRect(QRect(kShadowOffset, kShadowOffset, bodyW, bodyH), kShadow);

    // Square opaque body, matching the rest of the theme.
    QRect body(0, 0, bodyW, bodyH);
    p.fillRect(body, kSurface);

    p.setPen(QPen(kLine, 1.0));
    p.drawRect(QRect(body.left(), body.top(), body.width() - 1, body.height() - 1));

    // Left accent bar.
    p.fillRect(QRect(1, 1, kAccentBar, bodyH - 2), kAccent);

    // Left-align text, matching loading-page stage messages.
    p.setFont(m_Font);
    p.setPen(kText);
    p.drawText(QRect(kAccentBar + m_HorizPadding, m_VertPadding,
                     bodyW - kAccentBar - m_HorizPadding * 2, bodyH - m_VertPadding * 2),
               Qt::AlignLeft | Qt::AlignVCenter | Qt::TextWordWrap, m_Message);
}
