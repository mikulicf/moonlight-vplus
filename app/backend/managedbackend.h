#pragma once

#include <QJsonDocument>
#include <QJsonObject>
#include <QMap>
#include <QNetworkAccessManager>
#include <QPointer>
#include <QTimer>
#include <QVariantList>
#include <functional>

class ComputerManager;

// Management credentials and connection grants stay in memory. Only the chosen
// backend URL and username are saved; a new installation has neither configured.
class ManagedBackend : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString backendUrl READ backendUrl NOTIFY changed)
    Q_PROPERTY(QString username READ username NOTIFY changed)
    Q_PROPERTY(bool loggedIn READ loggedIn NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(QString message READ message NOTIFY changed)
    Q_PROPERTY(QString connectingMachine READ connectingMachine NOTIFY changed)
    Q_PROPERTY(QVariantList machines READ machines NOTIFY changed)

public:
    explicit ManagedBackend(ComputerManager* computers, QObject* parent = nullptr);
    QString backendUrl() const { return m_BackendUrl; }
    QString username() const { return m_Username; }
    bool loggedIn() const { return !m_Token.isEmpty(); }
    bool busy() const { return m_Busy; }
    QString message() const { return m_Message; }
    QString connectingMachine() const { return m_ConnectingMachine; }
    QVariantList machines() const { return m_Machines; }

    Q_INVOKABLE void signIn(QString url, QString username, QString password);
    Q_INVOKABLE void signOut();
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void connectMachine(QString id);
    Q_INVOKABLE void releaseConnections();

signals:
    void changed();
    void machineReady(int computerIndex, QString name);

private:
    using Callback = std::function<void(QJsonDocument, QString, int)>;
    void request(QByteArray method, QString path, QJsonObject body, Callback callback);
    void renewLeases();
    void clearSession();

    ComputerManager* m_Computers;
    QNetworkAccessManager m_Network;
    QTimer m_RenewTimer;
    QTimer m_RefreshTimer;
    QString m_BackendUrl;
    QString m_Username;
    QByteArray m_Token;
    QString m_Message;
    QString m_ConnectingMachine;
    QString m_PendingLease;
    QVariantList m_Machines;
    QMap<QString, QString> m_Leases;
    quint64 m_Generation = 0;
    quint64 m_ConnectionGeneration = 0;
    bool m_Busy = false;
};
