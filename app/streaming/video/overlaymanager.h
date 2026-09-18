#pragma once

#include <QString>
#include <string>
#include <vector>

#include "SDL_compat.h"
#include <SDL_ttf.h>

namespace Overlay {

enum OverlayType {
    OverlayDebug,
    OverlayStatusUpdate,
    OverlayMax
};

enum TextAlignment
{
    AlignTop,    // Top alignment.
    AlignCenter, // Center alignment.
    AlignBottom  // Bottom/baseline alignment (default).
};

class IOverlayRenderer
{
public:
    virtual ~IOverlayRenderer() = default;

    virtual void notifyOverlayUpdated(OverlayType type) = 0;
};

class OverlayManager
{
public:
    OverlayManager();
    ~OverlayManager();

    bool isOverlayEnabled(OverlayType type);
    char* getOverlayText(OverlayType type);
    void updateOverlayText(OverlayType type, const char* text);
    int getOverlayMaxTextLength();
    void setOverlayTextUpdated(OverlayType type);
    void setOverlayState(OverlayType type, bool enabled);
    SDL_Color getOverlayColor(OverlayType type);
    int getOverlayFontSize(OverlayType type);
    SDL_Surface* getUpdatedOverlaySurface(OverlayType type);
    void setTextAlignment(OverlayType type, TextAlignment alignment);
    TextAlignment getTextAlignment(OverlayType type);

    void setOverlayRenderer(IOverlayRenderer* renderer);

private:
    void notifyOverlayUpdated(OverlayType type);

    // Text-format parsing helpers.
    struct TextSegment {
        std::string text;
        bool isBold;
        bool isItalic;
        int fontSize;        // -1 selects the default size.
        bool isRelativeSize; // Whether this is a relative size adjustment.
    };

    std::vector<TextSegment> parseFormattedText(const char* text);
    SDL_Surface* renderFormattedText(OverlayType type, const std::vector<TextSegment>& segments);
    TTF_Font* getFontForStyle(OverlayType type, bool isBold, bool isItalic);
    TTF_Font* getFontForStyleAndSize(OverlayType type, bool isBold, bool isItalic, int fontSize);
    SDL_Surface* renderSmoothTextSegment(TTF_Font* font, const std::string& text, SDL_Color color, SDL_Color bgcolor);
    int calculateActualFontSize(OverlayType type, int requestedSize, bool isRelative);
    int calculateTextBaseline(TTF_Font* font);
    void calculateSegmentMetrics(const std::vector<TextSegment>& segments, OverlayType type,
                                int& totalWidth, int& maxHeight, int& maxAscent, int& maxDescent);

    struct {
        bool enabled;
        int fontSize;
        SDL_Color color;
        SDL_Color bgcolor;
        char text[1024];
        TextAlignment textAlignment; // Text alignment.

        TTF_Font* font;           // Regular.
        TTF_Font* fontBold;       // Bold.
        TTF_Font* fontItalic;     // Italic.
        TTF_Font* fontBoldItalic; // Bold italic.
        SDL_Surface* surface;
    } m_Overlays[OverlayMax];
    IOverlayRenderer* m_Renderer;
    QByteArray m_FontData;
};

}
