#include "overlaymanager.h"
#include "path.h"
#include <string>
#include <vector>
#include <regex>
#include <algorithm>

using namespace Overlay;

static void configureFontRendering(TTF_Font* font, bool isBold, bool isItalic)
{
    if (font == nullptr) {
        return;
    }

    int style = TTF_STYLE_NORMAL;
    if (isBold) {
        style |= TTF_STYLE_BOLD;
    }
    if (isItalic) {
        style |= TTF_STYLE_ITALIC;
    }
    TTF_SetFontStyle(font, style);

    TTF_SetFontHinting(font, TTF_HINTING_NORMAL);

    TTF_SetFontOutline(font, 0);

    if (TTF_GetFontKerning != nullptr) {
        TTF_SetFontKerning(font, 1);
    }

    TTF_SetFontWrappedAlign(font, TTF_WRAPPED_ALIGN_CENTER);
}

OverlayManager::OverlayManager() :
    m_Renderer(nullptr),
    m_FontData(Path::readDataFile("ModeSeven.ttf"))
{
    memset(m_Overlays, 0, sizeof(m_Overlays));

    // Keep overlay font sizes fixed. SDL_GetDisplayDPI() is not always reliable,
    // and runtime/platform DPI changes can otherwise alter overlay size unexpectedly.
    m_Overlays[OverlayType::OverlayDebug].color = {0xBD, 0xF9, 0xE7, 0xFF};
    m_Overlays[OverlayType::OverlayDebug].fontSize = 20;
    m_Overlays[OverlayType::OverlayDebug].bgcolor = {0x00, 0x00, 0x00, 0x66};
    m_Overlays[OverlayType::OverlayDebug].textAlignment = TextAlignment::AlignBottom;

    m_Overlays[OverlayType::OverlayStatusUpdate].color = {0xCC, 0x00, 0x00, 0xFF};
    m_Overlays[OverlayType::OverlayStatusUpdate].fontSize = 36;
    m_Overlays[OverlayType::OverlayStatusUpdate].textAlignment = TextAlignment::AlignCenter;

    // While TTF will usually not be initialized here, it is valid for that not to
    // be the case, since Session destruction is deferred and could overlap with
    // the lifetime of a new Session object.
    //SDL_assert(TTF_WasInit() == 0);

    if (TTF_Init() != 0) {
        SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                    "TTF_Init() failed: %s",
                    TTF_GetError());
        return;
    }

    // Request high-quality font scaling where supported.
    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "2"); // High-quality linear filtering.

    // Enable V-Sync to reduce text-rendering flicker.
    SDL_SetHint(SDL_HINT_RENDER_VSYNC, "1");
}

OverlayManager::~OverlayManager()
{
    for (int i = 0; i < OverlayType::OverlayMax; i++) {
        if (m_Overlays[i].surface != nullptr) {
            SDL_FreeSurface(m_Overlays[i].surface);
        }
        if (m_Overlays[i].font != nullptr) {
            TTF_CloseFont(m_Overlays[i].font);
        }
        if (m_Overlays[i].fontBold != nullptr) {
            TTF_CloseFont(m_Overlays[i].fontBold);
        }
        if (m_Overlays[i].fontItalic != nullptr) {
            TTF_CloseFont(m_Overlays[i].fontItalic);
        }
        if (m_Overlays[i].fontBoldItalic != nullptr) {
            TTF_CloseFont(m_Overlays[i].fontBoldItalic);
        }
    }

    TTF_Quit();

    // For similar reasons to the comment in the constructor, this will usually,
    // but not always, deinitialize TTF. In the cases where Session objects overlap
    // in lifetime, there may be an additional reference on TTF for the new Session
    // that means it will not be cleaned up here.
    //SDL_assert(TTF_WasInit() == 0);
}

bool OverlayManager::isOverlayEnabled(OverlayType type)
{
    return m_Overlays[type].enabled;
}

char* OverlayManager::getOverlayText(OverlayType type)
{
    return m_Overlays[type].text;
}

void OverlayManager::updateOverlayText(OverlayType type, const char* text)
{
    SDL_utf8strlcpy(m_Overlays[type].text, text, sizeof(m_Overlays[0].text));
    setOverlayTextUpdated(type);
}

int OverlayManager::getOverlayMaxTextLength()
{
    return sizeof(m_Overlays[0].text);
}

int OverlayManager::getOverlayFontSize(OverlayType type)
{
    return m_Overlays[type].fontSize;
}

SDL_Surface* OverlayManager::getUpdatedOverlaySurface(OverlayType type)
{
    // If a new surface is available, return it. If not, return nullptr.
    // Caller must free the surface on success.
    return (SDL_Surface*)SDL_AtomicSetPtr((void**)&m_Overlays[type].surface, nullptr);
}

void OverlayManager::setOverlayTextUpdated(OverlayType type)
{
    // Only update the overlay state if it's enabled. If it's not enabled,
    // the renderer has already been notified by setOverlayState().
    if (m_Overlays[type].enabled) {
        notifyOverlayUpdated(type);
    }
}

void OverlayManager::setOverlayState(OverlayType type, bool enabled)
{
    bool stateChanged = m_Overlays[type].enabled != enabled;

    m_Overlays[type].enabled = enabled;

    if (stateChanged) {
        if (!enabled) {
            // Set the text to empty string on disable
            m_Overlays[type].text[0] = 0;
        }

        notifyOverlayUpdated(type);
    }
}

SDL_Color OverlayManager::getOverlayColor(OverlayType type)
{
    return m_Overlays[type].color;
}

void OverlayManager::setOverlayRenderer(IOverlayRenderer* renderer)
{
    m_Renderer = renderer;
}

void OverlayManager::notifyOverlayUpdated(OverlayType type)
{
    if (m_Renderer == nullptr) {
        return;
    }

    // Construct the required font to render the overlay
    if (m_Overlays[type].font == nullptr) {
        if (m_FontData.isEmpty()) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                         "SDL overlay font failed to load");
            return;
        }

        // m_FontData must stay around until the font is closed
        m_Overlays[type].font = TTF_OpenFontRW(SDL_RWFromConstMem(m_FontData.constData(), m_FontData.size()),
                                               1,
                                               m_Overlays[type].fontSize);
        if (m_Overlays[type].font == nullptr) {
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                        "TTF_OpenFont() failed: %s",
                        TTF_GetError());

            // Can't proceed without a font
            return;
        }
    }

    SDL_Surface* oldSurface = (SDL_Surface*)SDL_AtomicSetPtr((void**)&m_Overlays[type].surface, nullptr);

    // Free the old surface
    if (oldSurface != nullptr) {
        SDL_FreeSurface(oldSurface);
    }

    if (m_Overlays[type].enabled && m_Overlays[type].text[0] != '\0') {
        // Parse formatted text.
        std::vector<TextSegment> segments = parseFormattedText(m_Overlays[type].text);

        // Render formatted text.
        SDL_Surface* formattedSurface = renderFormattedText(type, segments);

        if (formattedSurface != nullptr) {
            SDL_AtomicSetPtr((void **)&m_Overlays[type].surface, formattedSurface);
        } else {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "Failed to render formatted text");
        }
    }

    // Notify the renderer even if the enabled overlay has no text yet. Stats
    // text is populated asynchronously after the first measurement window.
    m_Renderer->notifyOverlayUpdated(type);
}

std::vector<OverlayManager::TextSegment> OverlayManager::parseFormattedText(const char* text)
{
    std::vector<TextSegment> segments;
    std::string input(text);

    // Supported markup:
    // ***bold italic***, **bold**, *italic*
    // {16} absolute size, {+2}/{-1} relative size; combine as {18}**large bold**.
    std::regex formatRegex(R"(\{([+-]?\d+)\}|(\*\*\*([^\*]+)\*\*\*)|(\*\*([^\*]+)\*\*)|(\*([^\*]+)\*))");
    std::sregex_iterator iter(input.begin(), input.end(), formatRegex);
    std::sregex_iterator end;

    size_t lastEnd = 0;
    int currentFontSize = -1; // -1 uses the default font size.
    bool isRelativeSize = false;

    for (; iter != end; ++iter) {
        const std::smatch& match = *iter;
        const size_t matchPosition = static_cast<size_t>(match.position());

        // Add plain text preceding the match.
        if (matchPosition > lastEnd) {
            std::string normalText = input.substr(lastEnd, matchPosition - lastEnd);
            if (!normalText.empty()) {
                segments.push_back({normalText, false, false, currentFontSize, isRelativeSize});
            }
        }

        // Check for a font-size marker.
        if (!match[1].str().empty()) {
            std::string sizeStr = match[1].str();
            try {
                int size = std::stoi(sizeStr);
                if (sizeStr[0] == '+' || sizeStr[0] == '-') {
                    // Relative size adjustment.
                    currentFontSize = size;
                    isRelativeSize = true;
                } else {
                    // Absolute font size.
                    currentFontSize = size;
                    isRelativeSize = false;
                }
            } catch (const std::exception&) {
                SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "Invalid font-size markup: %s",
                            sizeStr.c_str());
                currentFontSize = -1;
                isRelativeSize = false;
            }
        }
        // Check formatting markers.
        else {
            TextSegment segment;
            segment.fontSize = currentFontSize;
            segment.isRelativeSize = isRelativeSize;

            if (!match[3].str().empty()) {
                // ***bold italic***
                segment.text = match[3].str();
                segment.isBold = true;
                segment.isItalic = true;
            } else if (!match[5].str().empty()) {
                // **bold**
                segment.text = match[5].str();
                segment.isBold = true;
                segment.isItalic = false;
            } else if (!match[7].str().empty()) {
                // *italic*
                segment.text = match[7].str();
                segment.isBold = false;
                segment.isItalic = true;
            }

            segments.push_back(segment);
        }

        lastEnd = matchPosition + match.length();
    }

    // Append trailing plain text.
    if (lastEnd < input.length()) {
        std::string normalText = input.substr(lastEnd);
        if (!normalText.empty()) {
            segments.push_back({normalText, false, false, currentFontSize, isRelativeSize});
        }
    }

    // Without formatting markers, return the complete string as plain text.
    if (segments.empty()) {
        segments.push_back({input, false, false, -1, false});
    }

    return segments;
}

TTF_Font* OverlayManager::getFontForStyle(OverlayType type, bool isBold, bool isItalic)
{
    TTF_Font** targetFont;

    if (isBold && isItalic) {
        targetFont = &m_Overlays[type].fontBoldItalic;
    } else if (isBold) {
        targetFont = &m_Overlays[type].fontBold;
    } else if (isItalic) {
        targetFont = &m_Overlays[type].fontItalic;
    } else {
        targetFont = &m_Overlays[type].font;
    }

    // Create the font lazily.
    if (*targetFont == nullptr) {
        if (m_FontData.isEmpty()) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "SDL overlay font data is empty");
            return nullptr;
        }

        *targetFont = TTF_OpenFontRW(SDL_RWFromConstMem(m_FontData.constData(), m_FontData.size()),
                                     1,
                                     m_Overlays[type].fontSize);
        if (*targetFont == nullptr) {
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "TTF_OpenFont() failed: %s", TTF_GetError());
            return nullptr;
        }

        configureFontRendering(*targetFont, isBold, isItalic);
    }

    return *targetFont;
}

SDL_Surface* OverlayManager::renderFormattedText(OverlayType type, const std::vector<TextSegment>& segments)
{
    if (segments.empty()) {
        return nullptr;
    }

    // Use precise font metrics to measure text.
    int totalWidth, maxHeight, maxAscent, maxDescent;
    calculateSegmentMetrics(segments, type, totalWidth, maxHeight, maxAscent, maxDescent);

    if (totalWidth == 0 || maxHeight == 0) {
        return nullptr;
    }

    std::vector<SDL_Surface*> segmentSurfaces;
    std::vector<TTF_Font*> temporaryFonts; // Track fonts requiring cleanup.
    std::vector<int> segmentAscents;       // Retain each segment's ascent.

    // Render all text segments.
    for (const auto& segment : segments) {
        // Calculate the effective font size.
        int actualFontSize = calculateActualFontSize(type, segment.fontSize, segment.isRelativeSize);

        TTF_Font* font;
        bool isTemporaryFont = false;

        if (segment.fontSize == -1) {
            // Reuse the cached default font.
            font = getFontForStyle(type, segment.isBold, segment.isItalic);
        } else {
            // Create a temporary font at the requested size.
            font = getFontForStyleAndSize(type, segment.isBold, segment.isItalic, actualFontSize);
            isTemporaryFont = true;
        }

        if (font == nullptr) {
            continue;
        }

        if (isTemporaryFont) {
            temporaryFonts.push_back(font);
        }

        // Use the smooth text-rendering path.
        SDL_Surface* surface = renderSmoothTextSegment(font, segment.text,
                                                     m_Overlays[type].color,
                                                     m_Overlays[type].bgcolor);

        if (surface != nullptr) {
            segmentSurfaces.push_back(surface);
            segmentAscents.push_back(TTF_FontAscent(font));
        }
    }

    if (segmentSurfaces.empty()) {
        // Release temporary fonts.
        for (TTF_Font* font : temporaryFonts) {
            TTF_CloseFont(font);
        }
        return nullptr;
    }

    // Keep padding fixed so hardware DPI fluctuations do not change overlay spacing.
    int padding = 4;

    // Calculate height from both ascent and descent.
    int surfaceHeight = maxAscent + maxDescent;

    // Create the combined ARGB8888 surface expected by all renderers.
    SDL_Surface* combinedSurface = SDL_CreateRGBSurfaceWithFormat(
        0,
        totalWidth + padding * 2,
        surfaceHeight + padding * 2,
        32,
        SDL_PIXELFORMAT_ARGB8888
    );

    if (combinedSurface == nullptr) {
        // Release segment surfaces and temporary fonts.
        for (SDL_Surface* surface : segmentSurfaces) {
            SDL_FreeSurface(surface);
        }
        for (TTF_Font* font : temporaryFonts) {
            TTF_CloseFont(font);
        }
        return nullptr;
    }

    // Fill the combined surface with its background color.
    SDL_FillRect(combinedSurface, nullptr,
                SDL_MapRGBA(combinedSurface->format,
                           m_Overlays[type].bgcolor.r,
                           m_Overlays[type].bgcolor.g,
                           m_Overlays[type].bgcolor.b,
                           m_Overlays[type].bgcolor.a));

    // Copy each segment onto the combined surface with precise baseline alignment.
    int currentX = padding;
    for (size_t i = 0; i < segmentSurfaces.size(); ++i) {
        SDL_Surface* surface = segmentSurfaces[i];
        int segmentAscent = segmentAscents[i];

        // Calculate vertical offset for the selected alignment.
        int yOffset;
        switch (m_Overlays[type].textAlignment) {
            case TextAlignment::AlignTop:
                // Align the tops of all text segments.
                yOffset = padding;
                break;
            case TextAlignment::AlignCenter:
                // Center within the complete text area.
                yOffset = padding + (surfaceHeight - surface->h) / 2;
                break;
            case TextAlignment::AlignBottom:
            default:
                // Align baselines precisely using ascent metrics.
                yOffset = padding + (maxAscent - segmentAscent);
                break;
        }

        SDL_Rect destRect = {currentX, yOffset, surface->w, surface->h};

        // Enable alpha blending for smoother output.
        SDL_SetSurfaceBlendMode(surface, SDL_BLENDMODE_BLEND);
        SDL_BlitSurface(surface, nullptr, combinedSurface, &destRect);

        currentX += surface->w;
        SDL_FreeSurface(surface);
    }

    // Release temporary fonts.
    for (TTF_Font* font : temporaryFonts) {
        TTF_CloseFont(font);
    }

    return combinedSurface;
}

SDL_Surface* OverlayManager::renderSmoothTextSegment(TTF_Font* font, const std::string& text, SDL_Color color, SDL_Color bgcolor)
{
    if (font == nullptr || text.empty()) {
        return nullptr;
    }

    SDL_Surface* surface = nullptr;

    // Prefer the highest-quality available rendering method.

    // 1. Try Blended for the best antialiasing.
    surface = TTF_RenderUTF8_Blended(font, text.c_str(), color);

    if (surface != nullptr) {
        return surface;
    }

    // 2. Try Blended Wrapped, suitable for longer text.
    SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "Blended rendering failed; trying Blended Wrapped");

    surface = TTF_RenderUTF8_Blended_Wrapped(font, text.c_str(), color, 0);

    if (surface != nullptr) {
        return surface;
    }

    // 3. Fall back to Shaded rendering.
    SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "Blended Wrapped rendering failed; trying Shaded");

    surface = TTF_RenderUTF8_Shaded(font, text.c_str(), color, bgcolor);

    if (surface != nullptr) {
        return surface;
    }

    // 4. Use basic Solid rendering as the final fallback.
    SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "Shaded rendering failed; falling back to Solid");

    surface = TTF_RenderUTF8_Solid(font, text.c_str(), color);

    if (surface == nullptr) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "All text-rendering methods failed: %s",
                     TTF_GetError());
    }

    return surface;
}

int OverlayManager::calculateActualFontSize(OverlayType type, int requestedSize, bool isRelative)
{
    int baseFontSize = m_Overlays[type].fontSize;

    if (requestedSize == -1) {
        // Use the default font size.
        return baseFontSize;
    }

    if (isRelative) {
        // Relative size: base size plus adjustment.
        int newSize = baseFontSize + requestedSize;

        // Clamp the size to 8-128.
        if (newSize < 8) newSize = 8;
        if (newSize > 128) newSize = 128;

        return newSize;
    } else {
        // Use the requested absolute size, subject to the same bounds.
        if (requestedSize < 8) return 8;
        if (requestedSize > 128) return 128;

        return requestedSize;
    }
}

TTF_Font* OverlayManager::getFontForStyleAndSize(OverlayType type, bool isBold, bool isItalic, int fontSize)
{
    // fontSize == -1 uses the normal getFontForStyle() path.
    if (fontSize == -1) {
        return getFontForStyle(type, isBold, isItalic);
    }

    // Create temporary fonts for custom sizes; caching could be added later.
    if (m_FontData.isEmpty()) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "SDL overlay font data is empty");
        return nullptr;
    }

    TTF_Font* tempFont = TTF_OpenFontRW(SDL_RWFromConstMem(m_FontData.constData(), m_FontData.size()),
                                       1, fontSize);
    if (tempFont == nullptr) {
        SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "TTF_OpenFont() failed (size: %d): %s", fontSize,
                    TTF_GetError());
        // Fall back to the default font.
        return getFontForStyle(type, isBold, isItalic);
    }

    configureFontRendering(tempFont, isBold, isItalic);

    return tempFont;
}

void OverlayManager::setTextAlignment(OverlayType type, TextAlignment alignment)
{
    if (type >= OverlayMax) {
        return;
    }

    bool stateChanged = m_Overlays[type].textAlignment != alignment;
    m_Overlays[type].textAlignment = alignment;

    // Rerender an enabled overlay when alignment changes.
    if (stateChanged && m_Overlays[type].enabled) {
        notifyOverlayUpdated(type);
    }
}

TextAlignment OverlayManager::getTextAlignment(OverlayType type)
{
    if (type >= OverlayMax) {
        return TextAlignment::AlignBottom;
    }

    return m_Overlays[type].textAlignment;
}

int OverlayManager::calculateTextBaseline(TTF_Font* font)
{
    if (font == nullptr) {
        return 0;
    }

    // Read ascent: the distance from baseline to the font's top.
    return TTF_FontAscent(font);
}

void OverlayManager::calculateSegmentMetrics(const std::vector<TextSegment>& segments, OverlayType type,
                                           int& totalWidth, int& maxHeight, int& maxAscent, int& maxDescent)
{
    totalWidth = 0;
    maxHeight = 0;
    maxAscent = 0;
    maxDescent = 0;

    for (const auto& segment : segments) {
        // Calculate the effective font size.
        int actualFontSize = calculateActualFontSize(type, segment.fontSize, segment.isRelativeSize);

        TTF_Font* font;
        bool isTemporaryFont = false;

        if (segment.fontSize == -1) {
            font = getFontForStyle(type, segment.isBold, segment.isItalic);
        } else {
            font = getFontForStyleAndSize(type, segment.isBold, segment.isItalic, actualFontSize);
            isTemporaryFont = true;
        }

        if (font == nullptr) {
            continue;
        }

        // Measure text width and height.
        int textWidth, textHeight;
        if (TTF_SizeUTF8(font, segment.text.c_str(), &textWidth, &textHeight) == 0) {
            totalWidth += textWidth;

            // Read font metrics.
            int ascent = TTF_FontAscent(font);
            int descent = TTF_FontDescent(font);
            int height = TTF_FontHeight(font);

            maxHeight = std::max(maxHeight, height);
            maxAscent = std::max(maxAscent, ascent);
            maxDescent = std::max(maxDescent, std::abs(descent)); // Descent is usually negative.
        }

        if (isTemporaryFont) {
            TTF_CloseFont(font);
        }
    }
}
