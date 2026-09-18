#pragma once

#include <QWindow>

// macOS window-chrome adjustments.
//
// ExpandedClientAreaHint and NoTitleBarBackgroundHint extend content to the top, but
// NSTitlebarContainerView remains 28-32 points high. Window controls and AppKit's
// drag/double-click region would otherwise occupy only the top of our 56-pixel toolbar.
//
// Extend the native titlebar to the toolbar height and center its controls vertically.
// AppKit then handles dragging and double-click zoom across the whole bar.
namespace MacWindowChrome
{
// Keep barHeight aligned with main.qml. Observers reapply the layout after resize
// and fullscreen transitions, so callers need only configure it once after creation.
void useTallTitleBar(QWindow* window, int barHeight);
}
