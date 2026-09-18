#pragma once

#include <QObject>
#include <QString>
#include <QVariantList>

// USB sharing orchestration with a common QML contract across platforms.
// Windows uses usbipd-win: enumerate JSON state and bind/unbind with elevated
// ShellExecuteW("runas"). usbipd persists bindings in its registry as PersistedGuid.
// macOS uses the bundled moonlight-usbd helper (usbipdcpp). Enumeration calls
// list --json; bind/unbind changes StreamingPreferences::usbForwardingBoundDevices
// without elevation. Session launches serve through UsbForwardingLocalServer as needed.
// UsbForwardingEnvironment checks versions and service state; this class manages devices.
//
// Each device is a QVariantMap with these keys:
//   busId         Windows: 1-2, IncompatibleHub, or empty when disconnected;
//                 macOS: topology paths such as 1-2 or 1-2.3 through a hub
//   description   Human-readable device description
//   instanceId    Windows USB instance ID; macOS serial number
//   vidPid        "xxxx:yyyy"
//   isBound       Windows: nonempty PersistedGuid; macOS: present in preferences
//   isConnected   Device is currently enumerated
//   isAttached    Device is used by a client (always false on macOS)
//   isSupported   Connected, valid bus ID; on macOS, also not occupied by the system
//   isForced      Windows-only flag
//   persistedGuid Windows-only persisted sharing GUID; empty on macOS
//   isOccupied    macOS system driver owns an interface, preventing sharing
class UsbForwardingBackend : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantList devices READ devices NOTIFY devicesChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)

public:
    static UsbForwardingBackend* get();

    // Parse macOS moonlight-usbd list --json output into refresh()'s device schema.
    // isBound starts false; the caller overlays preferences. On failure, set *error
    // and return an empty list. Exposed as a pure static function for process-free tests.
    static QVariantList parseHelperDevices(const QByteArray& helperJson, QString* error);

    Q_INVOKABLE void refresh();
    Q_INVOKABLE void bind(const QString &busId);
    Q_INVOKABLE void unbind(const QString &busId, const QString &persistedGuid);

    QVariantList devices() const { return m_Devices; }
    bool busy() const { return m_Busy; }
    QString error() const { return m_Error; }

signals:
    void devicesChanged();
    void busyChanged();
    void errorChanged();
    void operationFinished(bool success, const QString &message);

private:
    explicit UsbForwardingBackend(QObject *parent = nullptr);

    void setBusy(bool busy);
    void setError(const QString &error);
#ifdef Q_OS_DARWIN
    void refreshFromHelper();
#endif

    QVariantList m_Devices;
    bool m_Busy = false;
    QString m_Error;
};
