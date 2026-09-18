# Interface fonts

The interface uses Manrope for body text and headings, and DM Mono for numbers, status badges, and letter-spaced labels. Both are distributed under the SIL Open Font License 1.1. These unmodified static font files come from [Google Fonts](https://fonts.google.com/).

| File | Family and weight | Upstream |
|---|---|---|
| `Manrope-Regular.ttf` | Manrope 400 | [sharanda/manrope](https://github.com/sharanda/manrope) |
| `Manrope-SemiBold.ttf` | Manrope 600 | [sharanda/manrope](https://github.com/sharanda/manrope) |
| `Manrope-ExtraBold.ttf` | Manrope 800 | [sharanda/manrope](https://github.com/sharanda/manrope) |
| `DMMono-Regular.ttf` | DM Mono 400 | [googlefonts/dm-mono](https://github.com/googlefonts/dm-mono) |

The complete licenses are in `OFL-Manrope.txt` and `OFL-DMMono.txt`.

Static instances make weight selection predictable after registration with `QFontDatabase::addApplicationFont()`. The upstream Manrope source is a variable font, `Manrope[wght].ttf`. The three static files carry typographic family information in name IDs 16/17, so Qt groups weights 400, 600, and 800 under `Manrope`, selectable through QML's `font.weight`.

No CJK font is bundled. Manrope and DM Mono do not contain CJK glyphs; the `QFont::setFamilies()` fallback chain in `app/main.cpp` uses system fonts such as PingFang SC on macOS and Microsoft YaHei UI on Windows. This also avoids adding several megabytes for a bundled font such as Noto Sans SC.
