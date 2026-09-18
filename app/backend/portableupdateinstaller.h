#pragma once

#include <QObject>
#include <QNetworkAccessManager>

class QFile;
class QNetworkReply;

// Download and install application updates.
//
// The historical Portable name comes from the Windows-only implementation. macOS .app
// updates now share the download/verify/detached-replace/restart sequence with platform-
// specific steps. Existing signal names and QML call sites retain the original naming.
class PortableUpdateInstaller : public QObject
{
    Q_OBJECT
public:
    explicit PortableUpdateInstaller(QObject *parent = nullptr);

    bool supportsInAppUpdate() const;
    void installUpdate(const QString& url, const QString& expectedDigest = QString());

signals:
    void onPortableUpdateStatusChanged(QString message);
    void onPortableUpdateFailed(QString message);

private slots:
    void handlePortableUpdateMetaDataChanged();
    void handlePortableUpdateDownloadReadyRead();
    void handlePortableUpdateDownloadProgress(qint64 bytesReceived, qint64 bytesTotal);
    void handlePortableUpdateDownloadFinished();

private:
    bool isPortableInstall() const;
    bool isBundleInstall() const;
    // macOS: current Moonlight.app path, or empty when not running inside a bundle.
    QString getInstalledBundlePath() const;
    QString getUpdateArchiveName() const;
    QString getUpdateArchiveSuffix() const;
    // Volume used for space checks and staging: the installation's parent directory.
    QString getUpdateStorageProbePath() const;
    QString getPortableUpdaterExecutable() const;
    bool ensureWritableInstallDir(QString& errorMessage) const;
    QString createPortableUpdateWorkspace() const;
    QString materializePortableUpdateScript(const QString& workspace) const;
    // macOS: mount the DMG, copy Moonlight.app into staging, and prepare its attributes.
    bool stageMacUpdateBundle(const QString& archivePath,
                              QString& stagedBundlePath,
                              QString& errorMessage);
    bool runTool(const QString& program, const QStringList& arguments, int timeoutMs) const;
    bool ensureSufficientDiskSpace(qint64 requiredBytes, QString& errorMessage) const;
    bool verifyUpdateArchive(const QString& archivePath, QString& errorMessage) const;
    qint64 estimateRequiredWorkspaceBytes(qint64 archiveBytes) const;
    void resetPortableUpdateState(bool removeWorkspace);

    QNetworkAccessManager* m_UpdateNam;
    QNetworkReply* m_UpdateReply;
    QFile* m_UpdateFile;
    QString m_PortableUpdateWorkspace;
    QString m_PortableUpdateError;
    QByteArray m_ExpectedSha256;
    bool m_MetadataChecked;
};
