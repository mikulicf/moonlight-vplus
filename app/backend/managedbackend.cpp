#include "managedbackend.h"
#include "computermanager.h"
#include "identitymanager.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QNetworkReply>
#include <QRegularExpression>
#include <QSettings>
#include <QSslConfiguration>
#include <QSslSocket>

namespace {
bool validId(const QString& id)
{
    static const QRegularExpression pattern(QStringLiteral("^[a-f0-9]{32}$"));
    return pattern.match(id).hasMatch();
}
}

ManagedBackend::ManagedBackend(ComputerManager* computers, QObject* parent)
    : QObject(parent), m_Computers(computers)
{
    QSettings settings;
    m_BackendUrl = settings.value(QStringLiteral("managedBackend/url")).toString();
    m_Username = settings.value(QStringLiteral("managedBackend/username")).toString();
    m_RenewTimer.setInterval(25000);
    m_RefreshTimer.setInterval(15000);
    connect(&m_RenewTimer, &QTimer::timeout, this, &ManagedBackend::renewLeases);
    connect(&m_RefreshTimer, &QTimer::timeout, this, &ManagedBackend::refresh);
    connect(m_Computers, &ComputerManager::managedHostReady, this,
            [this](QString backend, QString requestId, QString uuid, QString error) {
                if (backend != m_BackendUrl || requestId != m_PendingLease || !loggedIn() ||
                    m_ConnectingMachine.isEmpty()) {
                    return;
                }
                m_Busy = false;
                m_ConnectingMachine.clear();
                m_PendingLease.clear();
                if (!error.isEmpty()) {
                    releaseConnections();
                    m_Message = error;
                    emit changed();
                    return;
                }
                const auto computers = m_Computers->getComputers();
                for (int i = 0; i < computers.size(); ++i) {
                    if (computers[i]->uuid == uuid) {
                        m_Message.clear();
                        emit changed();
                        emit machineReady(i, computers[i]->name);
                        return;
                    }
                }
                m_Message = tr("The host could not be added. Try connecting again.");
                releaseConnections();
                emit changed();
            });
}

void ManagedBackend::request(QByteArray method, QString path, QJsonObject body, Callback callback)
{
    QNetworkRequest request(QUrl(m_BackendUrl + path));
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::ManualRedirectPolicy);
    request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    request.setRawHeader("Accept", "application/json");
    request.setRawHeader("Cache-Control", "no-store");
    if (!m_Token.isEmpty()) {
        request.setRawHeader("Authorization", "Bearer " + m_Token);
    }
    auto ssl = QSslConfiguration::defaultConfiguration();
    ssl.setProtocol(QSsl::TlsV1_2OrLater);
    ssl.setPeerVerifyMode(QSslSocket::VerifyPeer);
    request.setSslConfiguration(ssl);
    auto reply = m_Network.sendCustomRequest(
        request, method,
        method == "GET" || method == "DELETE" ? QByteArray()
                                              : QJsonDocument(body).toJson(QJsonDocument::Compact));
    const auto generation = m_Generation;
    auto timeout = new QTimer(reply);
    timeout->setSingleShot(true);
    connect(timeout, &QTimer::timeout, reply, &QNetworkReply::abort);
    timeout->start(10000);
    connect(reply, &QNetworkReply::readyRead, reply, [reply]() {
        if (reply->bytesAvailable() > 1024 * 1024) {
            reply->abort();
        }
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, generation, callback]() {
        reply->deleteLater();
        if (generation != m_Generation) {
            return;
        }
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const auto bytes = reply->read(1024 * 1024 + 1);
        QJsonParseError parseError;
        const auto document = QJsonDocument::fromJson(bytes, &parseError);
        QString error;
        if (status >= 300 && status < 400) {
            error = tr("Backend redirects are not allowed. Enter its final HTTPS URL.");
        } else if (reply->error() != QNetworkReply::NoError || status < 200 || status >= 300) {
            error = document.object().value(QStringLiteral("error")).toString();
            if (error.isEmpty()) {
                error = tr("Cannot reach the backend securely. Check its address, certificate, and "
                           "connection.");
            }
        } else if (bytes.size() > 1024 * 1024 || parseError.error != QJsonParseError::NoError) {
            error = tr("The backend returned an invalid response.");
        }
        if (status == 401 && !m_Token.isEmpty()) {
            clearSession();
        }
        callback(document, error.left(500), status);
    });
}

void ManagedBackend::signIn(QString address, QString username, QString password)
{
    if (m_Busy || loggedIn()) {
        return;
    }
    QUrl url(address.trimmed(), QUrl::StrictMode);
    if (!url.isValid() || url.scheme() != QStringLiteral("https") || url.host().isEmpty() ||
        !url.userInfo().isEmpty() || url.hasQuery() || url.hasFragment() ||
        (!url.path().isEmpty() && url.path() != QStringLiteral("/"))) {
        m_Message =
            tr("Enter an HTTPS backend URL without a path, credentials, query, or fragment.");
        emit changed();
        return;
    }
    url.setPath(QString());
    ++m_Generation;
    m_BackendUrl = url.toString(QUrl::FullyEncoded);
    m_Username = username.trimmed();
    m_Busy = true;
    m_Message.clear();
    emit changed();
    request(
        "POST", QStringLiteral("/v1/login"),
        { { QStringLiteral("username"), m_Username }, { QStringLiteral("password"), password } },
        [this](QJsonDocument document, QString error, int) {
            m_Busy = false;
            auto token = document.object().value(QStringLiteral("token")).toString();
            static const QRegularExpression tokenPattern(QStringLiteral("^[a-f0-9]{64}$"));
            if (error.isEmpty() &&
                (!tokenPattern.match(token).hasMatch() ||
                 document.object().value(QStringLiteral("protocol")).toInt() != 1)) {
                error = tr("This server does not support the managed access protocol.");
            }
            if (!error.isEmpty()) {
                m_Message = error;
                emit changed();
                return;
            }
            m_Token = token.toUtf8();
            QSettings settings;
            settings.setValue(QStringLiteral("managedBackend/url"), m_BackendUrl);
            settings.setValue(QStringLiteral("managedBackend/username"), m_Username);
            m_RenewTimer.start();
            m_RefreshTimer.start();
            emit changed();
            refresh();
        });
}

void ManagedBackend::clearSession()
{
    m_Computers->cancelManagedRequest(m_BackendUrl, m_PendingLease);
    m_Computers->retireManagedHosts(m_BackendUrl);
    ++m_Generation;
    m_Token.fill('\0');
    m_Token.clear();
    m_Leases.clear();
    ++m_ConnectionGeneration;
    m_Machines.clear();
    m_ConnectingMachine.clear();
    m_PendingLease.clear();
    m_Busy = false;
    m_RenewTimer.stop();
    m_RefreshTimer.stop();
    emit changed();
}

void ManagedBackend::signOut()
{
    if (!loggedIn() || m_Busy) {
        return;
    }
    m_Busy = true;
    emit changed();
    request("POST", QStringLiteral("/v1/logout"), {}, [this](QJsonDocument, QString error, int) {
        clearSession();
        m_Message = error.isEmpty()
                        ? tr("Signed out.")
                        : tr("Signed out locally. Host access will expire within 90 seconds.");
        emit changed();
    });
}

void ManagedBackend::refresh()
{
    if (!loggedIn()) {
        return;
    }
    request("GET", QStringLiteral("/v1/machines"), {},
            [this](QJsonDocument document, QString error, int) {
                if (!error.isEmpty()) {
                    m_Message = error;
                } else if (document.isArray()) {
                    m_Machines = document.array().toVariantList();
                }
                emit changed();
            });
}

void ManagedBackend::connectMachine(QString id)
{
    if (!loggedIn() || m_Busy || !validId(id)) {
        return;
    }
    m_Busy = true;
    m_ConnectingMachine = id;
    m_Message = tr("Authorizing direct connection…");
    const auto operation = ++m_ConnectionGeneration;
    emit changed();
    request("POST", QStringLiteral("/v1/machines/%1/connections").arg(id),
            { { QStringLiteral("client_certificate"),
                QString::fromLatin1(IdentityManager::get()->getCertificate()) } },
            [this, id, operation](QJsonDocument document, QString error, int) {
                const auto object = document.object();
                const auto lease = object.value(QStringLiteral("lease_id")).toString();
                if (operation != m_ConnectionGeneration) {
                    if (validId(lease)) {
                        request("DELETE", QStringLiteral("/v1/connections/%1").arg(lease), {},
                                [](QJsonDocument, QString, int) {});
                    }
                    return;
                }
                const auto machine = object.value(QStringLiteral("machine")).toObject();
                const auto cert = QSslCertificate(
                    machine.value(QStringLiteral("server_certificate")).toString().toUtf8());
                const auto hostUuid = machine.value(QStringLiteral("host_uuid")).toString();
                const auto address = machine.value(QStringLiteral("address")).toString();
                const int httpPort = machine.value(QStringLiteral("http_port")).toInt();
                const int httpsPort = machine.value(QStringLiteral("https_port")).toInt();
                if (error.isEmpty() &&
                    (!validId(lease) || cert.isNull() || hostUuid.isEmpty() || address.isEmpty() ||
                     httpPort < 1 || httpPort > 65535 || httpsPort < 1 || httpsPort > 65535)) {
                    error = tr("The backend returned invalid host connection details.");
                }
                if (!error.isEmpty()) {
                    if (validId(lease)) {
                        request("DELETE", QStringLiteral("/v1/connections/%1").arg(lease), {},
                                [](QJsonDocument, QString, int) {});
                    }
                    m_Busy = false;
                    m_ConnectingMachine.clear();
                    m_Message = error;
                    emit changed();
                    return;
                }
                m_Leases[id] = lease;
                m_PendingLease = lease;
                m_Message = tr("Waiting for the host to authorize this device…");
                emit changed();
                m_Computers->addManagedHost(m_BackendUrl, lease, hostUuid,
                                            machine.value(QStringLiteral("name")).toString(),
                                            NvAddress(address, httpPort), httpsPort, cert);
            });
}

void ManagedBackend::renewLeases()
{
    if (!loggedIn()) {
        return;
    }
    const auto leases = m_Leases;
    for (auto it = leases.cbegin(); it != leases.cend(); ++it) {
        const auto id = it.key();
        request("POST", QStringLiteral("/v1/connections/%1/renew").arg(it.value()), {},
                [this, id](QJsonDocument, QString error, int status) {
                    if (!error.isEmpty()) {
                        if (status == 403 || status == 404) {
                            m_Leases.remove(id);
                        }
                        m_Message = error;
                        emit changed();
                    }
                });
    }
}

void ManagedBackend::releaseConnections()
{
    m_Computers->cancelManagedRequest(m_BackendUrl, m_PendingLease);
    m_Computers->retireManagedHosts(m_BackendUrl);
    ++m_ConnectionGeneration;
    m_PendingLease.clear();
    if (!m_ConnectingMachine.isEmpty()) {
        m_ConnectingMachine.clear();
        m_Busy = false;
    }
    const auto leases = m_Leases;
    m_Leases.clear();
    for (const auto& lease : leases) {
        request("DELETE", QStringLiteral("/v1/connections/%1").arg(lease), {},
                [](QJsonDocument, QString, int) {});
    }
    emit changed();
}
