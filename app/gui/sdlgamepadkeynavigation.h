#pragma once

#include <QTimer>
#include <QEvent>

#include "SDL_compat.h"

#include "settings/streamingpreferences.h"

class SdlGamepadKeyNavigation : public QObject
{
    Q_OBJECT

public:
    SdlGamepadKeyNavigation(StreamingPreferences* prefs);

    ~SdlGamepadKeyNavigation();

    Q_INVOKABLE void enable();

    Q_INVOKABLE void disable();

    Q_INVOKABLE void notifyWindowFocus(bool hasFocus);

    Q_INVOKABLE void setUiNavMode(bool settingsMode);

    // Temporarily borrow real direction keys while a popup is open. Use a count
    // instead of restoring a saved mode, which could overwrite a concurrent page change.
    // Callers must balance suspension and restoration.
    Q_INVOKABLE void suspendUiNavMode();

    Q_INVOKABLE void resumeUiNavMode();

    Q_INVOKABLE int getConnectedGamepads();

private:
    // Effective mode: enabled by the page and not currently suspended.
    bool uiNavModeActive() const;

    void sendKey(QEvent::Type type, Qt::Key key, Qt::KeyboardModifiers modifiers = Qt::NoModifier);

    void updateTimerState();

private slots:
    void onPollingTimerFired();

private:
    StreamingPreferences* m_Prefs;
    QTimer* m_PollingTimer;
    QList<SDL_GameController*> m_Gamepads;
    bool m_Enabled;
    bool m_UiNavMode;
    int m_UiNavSuspendCount;
    bool m_FirstPoll;
    bool m_HasFocus;
    Uint32 m_LastAxisNavigationEventTime;
};
