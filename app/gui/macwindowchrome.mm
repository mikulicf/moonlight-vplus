#include "macwindowchrome.h"

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

namespace
{

// Left margin for native window controls. Keep main.qml's windowButtonInsetLeft
// synchronized with this margin, the 60-point control group, and its spacing.
const CGFloat kButtonLeftMargin = 20;
const void* kTitleBarObserverTokensKey = &kTitleBarObserverTokensKey;

void removeTitleBarObservers(NSWindow* window)
{
    NSArray* observerTokens = objc_getAssociatedObject(window, kTitleBarObserverTokensKey);
    NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
    for (id token in observerTokens) {
        [center removeObserver:token];
    }
    objc_setAssociatedObject(window, kTitleBarObserverTokensKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Extend the titlebar container to barHeight and center its controls vertically.
//
// Follow standardWindowButton's superviews: NSButton -> NSTitlebarView ->
// NSTitlebarContainerView -> frame view. This private hierarchy has been stable since
// macOS 10.10, but guard every step and leave the native layout unchanged if unavailable.
void applyTallTitleBar(NSWindow* window, CGFloat barHeight)
{
    if (window == nil) {
        return;
    }

    NSButton* buttons[] = {
        [window standardWindowButton:NSWindowCloseButton],
        [window standardWindowButton:NSWindowMiniaturizeButton],
        [window standardWindowButton:NSWindowZoomButton],
    };

    NSView* titleBarView = buttons[0].superview;
    if (titleBarView == nil) {
        return;
    }

    NSView* container = titleBarView.superview;
    if (container == nil) {
        return;
    }

    // Keep the container at the window's top edge by lowering its origin as height grows.
    NSRect containerFrame = container.frame;
    if (containerFrame.size.height < barHeight) {
        CGFloat delta = barHeight - containerFrame.size.height;
        containerFrame.size.height = barHeight;
        containerFrame.origin.y -= delta;
        container.frame = containerFrame;
    }

    // Match the inner NSTitlebarView to its container so later AppKit relayouts
    // do not depend on mismatched heights or version-specific behavior.
    NSRect titleBarFrame = titleBarView.frame;
    titleBarFrame.origin.y = 0;
    titleBarFrame.size.height = barHeight;
    titleBarView.frame = titleBarFrame;

    // Center all three buttons vertically and shift the group to kButtonLeftMargin.
    //
    // Native 14x14 controls start at x = 9/32/55 for a short titlebar. Shift the group
    // right to give the taller toolbar balanced horizontal margins.
    //
    // Unflipped NSView coordinates increase upward.
    CGFloat shiftX = kButtonLeftMargin - buttons[0].frame.origin.x;

    for (NSButton* button : buttons) {
        if (button == nil) {
            continue;
        }

        NSRect buttonFrame = button.frame;
        buttonFrame.origin.x += shiftX;
        buttonFrame.origin.y = (barHeight - buttonFrame.size.height) / 2.0;
        button.frame = buttonFrame;
    }
}

} // namespace

void MacWindowChrome::useTallTitleBar(QWindow* window, int barHeight)
{
    if (window == nullptr) {
        return;
    }

    // Create the native window before accessing its AppKit view hierarchy.
    window->create();

    NSView* view = reinterpret_cast<NSView*>(window->winId());
    NSWindow* nsWindow = view.window;
    if (nsWindow == nil) {
        return;
    }

    applyTallTitleBar(nsWindow, barHeight);

    // AppKit resets the title-bar layout after resizing and full-screen
    // transitions, so reapply it at each of these points. Notification-center
    // block observers must be removed explicitly; keep their tokens associated
    // with this window and tear them down when it closes.
    NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
    removeTitleBarObservers(nsWindow);

    NSMutableArray* observerTokens = [NSMutableArray array];
    NSArray<NSNotificationName>* names = @[
        NSWindowDidResizeNotification,
        NSWindowDidEndLiveResizeNotification,
        NSWindowDidEnterFullScreenNotification,
        NSWindowDidExitFullScreenNotification,
        NSWindowDidBecomeKeyNotification,
    ];

    for (NSNotificationName name in names) {
        id token = [center addObserverForName:name
                                      object:nsWindow
                                       queue:nil
                                  usingBlock:^(NSNotification* note) {
            applyTallTitleBar(static_cast<NSWindow*>(note.object), barHeight);
        }];
        [observerTokens addObject:token];
    }

    id closeToken = [center addObserverForName:NSWindowWillCloseNotification
                                        object:nsWindow
                                         queue:nil
                                    usingBlock:^(NSNotification* note) {
        removeTitleBarObservers(static_cast<NSWindow*>(note.object));
    }];
    [observerTokens addObject:closeToken];
    objc_setAssociatedObject(nsWindow,
                             kTitleBarObserverTokensKey,
                             observerTokens,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
