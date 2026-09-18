#include "portableupdateinstaller.h"
#include "path.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QEventLoop>
#include <QFileInfo>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QRegularExpression>
#include <QTemporaryFile>
#include <QStandardPaths>
#include <QStorageInfo>
#include <QTimer>
#include <QUrl>

PortableUpdateInstaller::PortableUpdateInstaller(QObject *parent) :
    QObject(parent),
    m_UpdateNam(nullptr),
    m_UpdateReply(nullptr),
    m_UpdateFile(nullptr),
    m_MetadataChecked(false)
{
}

bool PortableUpdateInstaller::supportsInAppUpdate() const
{
#if defined(Q_OS_WIN32)
    return isPortableInstall() &&
            !getPortableUpdaterExecutable().isEmpty();
#elif defined(Q_OS_DARWIN)
    // In-app updates require an .app bundle in a writable parent directory.
    // Fall back to browser downloads for root-owned locations or read-only DMG volumes.
    QString errorMessage;
    return isBundleInstall() &&
            !getPortableUpdaterExecutable().isEmpty() &&
            ensureWritableInstallDir(errorMessage);
#else
    return false;
#endif
}

void PortableUpdateInstaller::installUpdate(const QString& url, const QString& expectedDigest)
{
    if (!supportsInAppUpdate()) {
        emit onPortableUpdateFailed(tr("In-app update is not supported for this installation."));
        return;
    }

    if (m_UpdateReply != nullptr) {
        emit onPortableUpdateStatusChanged(tr("An update is already in progress."));
        return;
    }

    QUrl downloadUrl = QUrl::fromUserInput(url.trimmed());
    if (!downloadUrl.isValid() || downloadUrl.scheme().isEmpty()) {
        emit onPortableUpdateFailed(tr("The update URL is invalid."));
        return;
    }

    if (!downloadUrl.path().endsWith(getUpdateArchiveSuffix(), Qt::CaseInsensitive)) {
        emit onPortableUpdateFailed(tr("The update package was not found for this release."));
        return;
    }

    QString normalizedDigest = expectedDigest.trimmed();
    if (normalizedDigest.startsWith(QStringLiteral("sha256:"), Qt::CaseInsensitive)) {
        normalizedDigest.remove(0, 7);
    }

    static const QRegularExpression sha256Pattern(QStringLiteral("^[0-9a-fA-F]{64}$"));
#if defined(Q_OS_DARWIN)
    if (!sha256Pattern.match(normalizedDigest).hasMatch()) {
        emit onPortableUpdateFailed(tr("The update package has no valid integrity information. Please install the update manually."));
        return;
    }
#else
    if (!normalizedDigest.isEmpty() && !sha256Pattern.match(normalizedDigest).hasMatch()) {
        emit onPortableUpdateFailed(tr("The update package has invalid integrity information."));
        return;
    }
#endif

    QString errorMessage;
    if (!ensureWritableInstallDir(errorMessage)) {
        emit onPortableUpdateFailed(errorMessage);
        return;
    }

    QString workspace = createPortableUpdateWorkspace();
    if (workspace.isEmpty()) {
        emit onPortableUpdateFailed(tr("Unable to create a temporary folder for the update."));
        return;
    }

    resetPortableUpdateState(true);
    m_PortableUpdateWorkspace = workspace;
    m_PortableUpdateError.clear();
    m_ExpectedSha256 = normalizedDigest.toLatin1().toLower();
    m_MetadataChecked = false;

    if (m_UpdateNam == nullptr) {
        m_UpdateNam = new QNetworkAccessManager(this);
        m_UpdateNam->setStrictTransportSecurityEnabled(true);
        m_UpdateNam->setRedirectPolicy(QNetworkRequest::NoLessSafeRedirectPolicy);
    }

    QString archivePath = QDir(workspace).filePath(getUpdateArchiveName());
    m_UpdateFile = new QFile(archivePath, this);
    if (!m_UpdateFile->open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        m_PortableUpdateError = tr("Unable to create the update package on disk.");
        resetPortableUpdateState(true);
        emit onPortableUpdateFailed(m_PortableUpdateError);
        return;
    }

    QNetworkRequest request(downloadUrl);
    request.setHeader(QNetworkRequest::UserAgentHeader,
                      QString("Moonlight/%1").arg(VERSION_STR));
    request.setRawHeader("Accept", "application/octet-stream");

#if QT_VERSION >= QT_VERSION_CHECK(5, 15, 0)
    request.setAttribute(QNetworkRequest::Http2AllowedAttribute, true);
#else
    request.setAttribute(QNetworkRequest::HTTP2AllowedAttribute, true);
#endif

    m_UpdateReply = m_UpdateNam->get(request);
    connect(m_UpdateReply, &QNetworkReply::metaDataChanged,
            this, &PortableUpdateInstaller::handlePortableUpdateMetaDataChanged);
    connect(m_UpdateReply, &QNetworkReply::readyRead,
            this, &PortableUpdateInstaller::handlePortableUpdateDownloadReadyRead);
    connect(m_UpdateReply, &QNetworkReply::downloadProgress,
            this, &PortableUpdateInstaller::handlePortableUpdateDownloadProgress);
    connect(m_UpdateReply, &QNetworkReply::finished,
            this, &PortableUpdateInstaller::handlePortableUpdateDownloadFinished);

    emit onPortableUpdateStatusChanged(tr("Downloading update..."));
}

bool PortableUpdateInstaller::isPortableInstall() const
{
#if defined(Q_OS_WIN32)
    return QFile::exists(QDir(Path::getPortableRootDir()).filePath("portable.dat"));
#else
    return false;
#endif
}

bool PortableUpdateInstaller::isBundleInstall() const
{
    return !getInstalledBundlePath().isEmpty();
}

QString PortableUpdateInstaller::getInstalledBundlePath() const
{
#if defined(Q_OS_DARWIN)
    // The executable is Moonlight.app/Contents/MacOS/Moonlight; ascend to the bundle.
    QDir dir(QCoreApplication::applicationDirPath());
    if (!dir.cdUp() || !dir.cdUp()) {
        return QString();
    }

    QString path = dir.absolutePath();
    return path.endsWith(QLatin1String(".app")) ? path : QString();
#else
    return QString();
#endif
}

QString PortableUpdateInstaller::getUpdateArchiveSuffix() const
{
#if defined(Q_OS_DARWIN)
    return QStringLiteral(".dmg");
#else
    return QStringLiteral(".zip");
#endif
}

QString PortableUpdateInstaller::getUpdateArchiveName() const
{
#if defined(Q_OS_DARWIN)
    return QStringLiteral("MoonlightUpdate.dmg");
#else
    return QStringLiteral("MoonlightPortableUpdate.zip");
#endif
}

QString PortableUpdateInstaller::getUpdateStorageProbePath() const
{
#if defined(Q_OS_DARWIN)
    // Place the staging directory beside the installed bundle, not in the cache.
    //
    // Cache and /Applications may occupy different volumes, turning backup/replacement
    // moves into large recursive copies that can leave partial bundles if interrupted.
    // Same-volume moves are atomic renames. ensureWritableInstallDir() checks the parent,
    // and the space check therefore measures the actual destination volume.
    QString bundlePath = getInstalledBundlePath();
    if (!bundlePath.isEmpty()) {
        return QFileInfo(bundlePath).absolutePath();
    }

    return QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
#else
    return Path::getPortableRootDir();
#endif
}

QString PortableUpdateInstaller::getPortableUpdaterExecutable() const
{
#if defined(Q_OS_WIN32)
    QString executable = QStandardPaths::findExecutable(QStringLiteral("powershell.exe"));
    if (!executable.isEmpty()) {
        return executable;
    }

    return QStandardPaths::findExecutable(QStringLiteral("pwsh.exe"));
#elif defined(Q_OS_DARWIN)
    return QFile::exists(QStringLiteral("/bin/sh")) ? QStringLiteral("/bin/sh") : QString();
#else
    return QString();
#endif
}

bool PortableUpdateInstaller::ensureWritableInstallDir(QString& errorMessage) const
{
#if defined(Q_OS_WIN32)
    QTemporaryFile probeFile(QDir(Path::getPortableRootDir()).filePath("MoonlightUpdateWriteProbe-XXXXXX.tmp"));
    probeFile.setAutoRemove(true);

    if (!probeFile.open()) {
        errorMessage = tr("The current Moonlight folder is not writable. Move Moonlight to a writable location, run it with sufficient permissions, or download and install the update manually.");
        return false;
    }

    probeFile.close();
    return true;
#elif defined(Q_OS_DARWIN)
    QString bundlePath = getInstalledBundlePath();
    if (bundlePath.isEmpty()) {
        errorMessage = tr("In-app update requires running Moonlight from an app bundle.");
        return false;
    }

    // Replacing a bundle moves entries in its parent directory, so check the parent's
    // write permission rather than the bundle's own permission.
    QFileInfo bundleInfo(bundlePath);
    QTemporaryFile probeFile(QDir(bundleInfo.absolutePath())
                             .filePath(QStringLiteral(".MoonlightUpdateWriteProbe-XXXXXX")));
    probeFile.setAutoRemove(true);

    if (!probeFile.open()) {
        errorMessage = tr("Moonlight is installed in a folder you can't write to. Move it to your "
                          "Applications folder, or download and install the update manually.");
        return false;
    }

    probeFile.close();
    return true;
#else
    Q_UNUSED(errorMessage);
    return false;
#endif
}

QString PortableUpdateInstaller::createPortableUpdateWorkspace() const
{
#if defined(Q_OS_DARWIN)
    // Hide the staging directory beside /Applications from Finder with a dot prefix.
    static const QLatin1String kWorkspacePrefix(".MoonlightUpdate-");
#else
    static const QLatin1String kWorkspacePrefix("MoonlightPortableUpdate-");
#endif

    QString workspace = QDir(getUpdateStorageProbePath()).filePath(
                kWorkspacePrefix + QString("%1-%2")
                .arg(QCoreApplication::applicationPid())
                .arg(QDateTime::currentMSecsSinceEpoch()));

    if (!QDir().mkpath(workspace)) {
        return QString();
    }

    return workspace;
}

QString PortableUpdateInstaller::materializePortableUpdateScript(const QString& workspace) const
{
#if defined(Q_OS_DARWIN)
    static const QLatin1String kScriptName("install-dmg-update.sh");
#else
    static const QLatin1String kScriptName("install-portable-update.ps1");
#endif

    QFile resourceFile(QStringLiteral(":/data/") + kScriptName);
    if (!resourceFile.open(QIODevice::ReadOnly)) {
        return QString();
    }

    QString scriptPath = QDir(workspace).filePath(kScriptName);
    QFile scriptFile(scriptPath);
    if (!scriptFile.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        return QString();
    }

    QByteArray scriptContents = resourceFile.readAll();
    if (scriptFile.write(scriptContents) != scriptContents.size()) {
        return QString();
    }

    scriptFile.close();
    return scriptPath;
}

bool PortableUpdateInstaller::ensureSufficientDiskSpace(qint64 requiredBytes, QString& errorMessage) const
{
    if (requiredBytes <= 0) {
        return true;
    }

    QStorageInfo storage(getUpdateStorageProbePath());
    storage.refresh();

    if (!storage.isValid() || !storage.isReady()) {
        errorMessage = tr("Unable to determine free disk space for the update.");
        return false;
    }

    if (storage.bytesAvailable() < requiredBytes) {
        errorMessage = tr("Not enough free disk space for the update. Need about %1 MB free.")
                .arg(QString::number(requiredBytes / (1024.0 * 1024.0), 'f', 0));
        return false;
    }

    return true;
}

qint64 PortableUpdateInstaller::estimateRequiredWorkspaceBytes(qint64 archiveBytes) const
{
    if (archiveBytes <= 0) {
        return 0;
    }

    static const qint64 kSafetyMarginBytes = 64LL * 1024 * 1024;

    // Allow space for both the download and extracted content (ZIP/directory on Windows,
    // DMG/copied bundle on macOS), plus additional room for replacement.
    return archiveBytes * 3 + kSafetyMarginBytes;
}

bool PortableUpdateInstaller::verifyUpdateArchive(const QString& archivePath,
                                                   QString& errorMessage) const
{
    if (m_ExpectedSha256.isEmpty()) {
        return true;
    }

    QFile archive(archivePath);
    if (!archive.open(QIODevice::ReadOnly)) {
        errorMessage = tr("Unable to verify the downloaded update package.");
        return false;
    }

    QCryptographicHash hash(QCryptographicHash::Sha256);
    while (!archive.atEnd()) {
        QByteArray chunk = archive.read(1024 * 1024);
        if (chunk.isEmpty() && archive.error() != QFile::NoError) {
            errorMessage = tr("Unable to verify the downloaded update package.");
            return false;
        }
        hash.addData(chunk);
    }

    if (hash.result().toHex() != m_ExpectedSha256) {
        errorMessage = tr("The downloaded update package failed its integrity check.");
        return false;
    }

    return true;
}

bool PortableUpdateInstaller::runTool(const QString& program,
                                     const QStringList& arguments,
                                     int timeoutMs) const
{
    QProcess process;
    process.setProgram(program);
    process.setArguments(arguments);
    process.setProcessChannelMode(QProcess::MergedChannels);
    process.start();

    if (!process.waitForStarted(10000)) {
        qWarning() << "Failed to start" << program << process.errorString();
        return false;
    }

    // Wait with a local event loop, not waitForFinished(), to keep painting responsive
    // while hdiutil or ditto runs. ExcludeUserInputEvents prevents unrelated user actions
    // from interrupting installation while status text continues to repaint.
    if (process.state() != QProcess::NotRunning) {
        QEventLoop loop;
        QTimer timeoutTimer;
        bool timedOut = false;

        QObject::connect(&process, &QProcess::finished, &loop, &QEventLoop::quit);
        QObject::connect(&timeoutTimer, &QTimer::timeout, &loop, [&loop, &timedOut]() {
            timedOut = true;
            loop.quit();
        });

        timeoutTimer.setSingleShot(true);
        timeoutTimer.start(timeoutMs);
        loop.exec(QEventLoop::ExcludeUserInputEvents);

        if (timedOut) {
            qWarning() << program << "timed out";
            process.kill();
            process.waitForFinished(5000);
            return false;
        }
    }

    if (process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) {
        qWarning() << program << "failed with exit code" << process.exitCode()
                   << process.readAll().trimmed();
        return false;
    }

    return true;
}

bool PortableUpdateInstaller::stageMacUpdateBundle(const QString& archivePath,
                                                   QString& stagedBundlePath,
                                                   QString& errorMessage)
{
#if defined(Q_OS_DARWIN)
    // Prepare synchronously here so mount or missing-bundle errors can still be shown
    // in the application. The detached script runs after exit and cannot show this dialog.
    QString mountPoint = QDir(m_PortableUpdateWorkspace).filePath(QStringLiteral("mnt"));
    if (!QDir().mkpath(mountPoint)) {
        errorMessage = tr("Unable to create a temporary folder for the update.");
        return false;
    }

    // Mount privately with -nobrowse to hide the volume from Finder and avoid competing
    // with a manually mounted /Volumes/Moonlight volume.
    if (!runTool(QStringLiteral("/usr/bin/hdiutil"),
                 { QStringLiteral("attach"), archivePath,
                   QStringLiteral("-nobrowse"), QStringLiteral("-noautoopen"),
                   QStringLiteral("-readonly"),
                   QStringLiteral("-mountpoint"), mountPoint },
                 120000)) {
        errorMessage = tr("Unable to open the downloaded disk image.");
        return false;
    }

    bool staged = false;
    QString bundleInImage = QDir(mountPoint).filePath(QStringLiteral("Moonlight.app"));
    QString stagedBundle = QDir(m_PortableUpdateWorkspace).filePath(QStringLiteral("Moonlight.app"));

    if (!QFileInfo(bundleInImage).isDir()) {
        errorMessage = tr("The downloaded disk image does not contain Moonlight.");
    }
    // Use ditto to preserve extended attributes, symlinks, and bundle metadata
    // required for code-signature validity.
    else if (!runTool(QStringLiteral("/usr/bin/ditto"), { bundleInImage, stagedBundle }, 300000)) {
        errorMessage = tr("Unable to extract the update.");
    } else {
        staged = true;
    }

    // Unmount even after a preparation failure so no mount point is left behind.
    runTool(QStringLiteral("/usr/bin/hdiutil"),
            { QStringLiteral("detach"), mountPoint, QStringLiteral("-quiet") }, 60000);

    if (!staged) {
        return false;
    }

    // Downloaded bundles carry com.apple.quarantine. The existing update path removes
    // it to allow non-notarized builds to launch without Gatekeeper's damaged-app prompt.
    runTool(QStringLiteral("/usr/bin/xattr"),
            { QStringLiteral("-dr"), QStringLiteral("com.apple.quarantine"), stagedBundle }, 60000);

    // Check the bundle's ad-hoc signature for modification. Unsigned builds also fail
    // this check, so report it without rejecting the update; downloads already use TLS.
    if (!runTool(QStringLiteral("/usr/bin/codesign"),
                 { QStringLiteral("--verify"), QStringLiteral("--strict"), stagedBundle }, 120000)) {
        qWarning() << "Update bundle failed codesign verification; installing anyway";
    }

    stagedBundlePath = stagedBundle;
    return true;
#else
    Q_UNUSED(archivePath);
    Q_UNUSED(stagedBundlePath);
    Q_UNUSED(errorMessage);
    return false;
#endif
}

void PortableUpdateInstaller::resetPortableUpdateState(bool removeWorkspace)
{
    if (m_UpdateReply != nullptr) {
        m_UpdateReply->deleteLater();
        m_UpdateReply = nullptr;
    }

    if (m_UpdateFile != nullptr) {
        if (m_UpdateFile->isOpen()) {
            m_UpdateFile->close();
        }
        m_UpdateFile->deleteLater();
        m_UpdateFile = nullptr;
    }

    if (removeWorkspace && !m_PortableUpdateWorkspace.isEmpty()) {
        QDir(m_PortableUpdateWorkspace).removeRecursively();
    }

    if (removeWorkspace) {
        m_PortableUpdateWorkspace.clear();
        m_ExpectedSha256.clear();
    }

    m_MetadataChecked = false;
}

void PortableUpdateInstaller::handlePortableUpdateMetaDataChanged()
{
    if (m_UpdateReply == nullptr || m_MetadataChecked) {
        return;
    }

    m_MetadataChecked = true;

    bool ok = false;
    qint64 archiveBytes = m_UpdateReply->header(QNetworkRequest::ContentLengthHeader).toLongLong(&ok);
    if (!ok || archiveBytes <= 0) {
        return;
    }

    QString errorMessage;
    if (!ensureSufficientDiskSpace(estimateRequiredWorkspaceBytes(archiveBytes), errorMessage)) {
        m_PortableUpdateError = errorMessage;
        m_UpdateReply->abort();
    }
}

void PortableUpdateInstaller::handlePortableUpdateDownloadReadyRead()
{
    if (m_UpdateReply == nullptr || m_UpdateFile == nullptr) {
        return;
    }

    QByteArray data = m_UpdateReply->readAll();
    if (data.isEmpty()) {
        return;
    }

    if (m_UpdateFile->write(data) != data.size()) {
        m_PortableUpdateError = tr("Failed while writing the update package to disk.");
        m_UpdateReply->abort();
    }
}

void PortableUpdateInstaller::handlePortableUpdateDownloadProgress(qint64 bytesReceived, qint64 bytesTotal)
{
    if (bytesTotal > 0) {
        int progress = static_cast<int>((bytesReceived * 100) / bytesTotal);
        emit onPortableUpdateStatusChanged(tr("Downloading update... %1%").arg(progress));
    }
    else {
        emit onPortableUpdateStatusChanged(
                    tr("Downloading update... %1 MB")
                    .arg(QString::number(bytesReceived / (1024.0 * 1024.0), 'f', 1)));
    }
}

void PortableUpdateInstaller::handlePortableUpdateDownloadFinished()
{
    handlePortableUpdateDownloadReadyRead();

    QString failureMessage = m_PortableUpdateError;
    if (m_UpdateReply != nullptr && m_UpdateReply->error() != QNetworkReply::NoError) {
        if (failureMessage.isEmpty()) {
            failureMessage = tr("Failed to download the update: %1").arg(m_UpdateReply->errorString());
        }
    }

    if (m_UpdateFile != nullptr) {
        m_UpdateFile->flush();
        m_UpdateFile->close();
    }

    if (!failureMessage.isEmpty()) {
        m_PortableUpdateError.clear();
        resetPortableUpdateState(true);
        emit onPortableUpdateFailed(failureMessage);
        return;
    }

    QString archivePath = QDir(m_PortableUpdateWorkspace).filePath(getUpdateArchiveName());

    emit onPortableUpdateStatusChanged(tr("Verifying update..."));
    QString verificationError;
    if (!verifyUpdateArchive(archivePath, verificationError)) {
        resetPortableUpdateState(true);
        emit onPortableUpdateFailed(verificationError);
        return;
    }

#if defined(Q_OS_DARWIN)
    // Prepare the DMG bundle before exit so failures can still be reported in a dialog.
    QString stagedBundle;
    QString stageError;
    if (!stageMacUpdateBundle(archivePath, stagedBundle, stageError)) {
        resetPortableUpdateState(true);
        emit onPortableUpdateFailed(stageError);
        return;
    }
#endif

    QString scriptPath = materializePortableUpdateScript(m_PortableUpdateWorkspace);
    if (scriptPath.isEmpty()) {
        resetPortableUpdateState(true);
        emit onPortableUpdateFailed(tr("Unable to prepare the update installer."));
        return;
    }

    QString updaterExecutable = getPortableUpdaterExecutable();
    QStringList arguments;
    QString workingDirectory;

#if defined(Q_OS_DARWIN)
    // Pass our PID so the replacement script waits for this process to exit.
    arguments << scriptPath
              << m_PortableUpdateWorkspace
              << getInstalledBundlePath()
              << stagedBundle
              << QString::number(QCoreApplication::applicationPid());

    // The working directory must not be inside the bundle being replaced.
    workingDirectory = QDir::homePath();
#else
    QString installDir = QDir::toNativeSeparators(Path::getPortableRootDir());

    arguments << "-NoProfile"
              << "-ExecutionPolicy" << "Bypass"
              << "-WindowStyle" << "Hidden"
              << "-File" << QDir::toNativeSeparators(scriptPath)
              << "-WorkspaceDir" << QDir::toNativeSeparators(m_PortableUpdateWorkspace)
              << "-InstallDir" << installDir
              << "-ZipPath" << QDir::toNativeSeparators(archivePath)
              << "-ExePath" << QDir::toNativeSeparators(QCoreApplication::applicationFilePath());

    workingDirectory = installDir;
#endif

    if (updaterExecutable.isEmpty() ||
            !QProcess::startDetached(updaterExecutable, arguments, workingDirectory)) {
        resetPortableUpdateState(true);
        emit onPortableUpdateFailed(tr("Unable to launch the updater."));
        return;
    }

    emit onPortableUpdateStatusChanged(tr("Installing update and restarting Moonlight..."));

    if (m_UpdateReply != nullptr) {
        m_UpdateReply->deleteLater();
        m_UpdateReply = nullptr;
    }
    if (m_UpdateFile != nullptr) {
        if (m_UpdateFile->isOpen()) {
            m_UpdateFile->close();
        }
        m_UpdateFile->deleteLater();
        m_UpdateFile = nullptr;
    }

    // Do not call resetPortableUpdateState(true): staging contains the installer script,
    // replacement bundle, and backup. The script performs cleanup after completion.
    QTimer::singleShot(0, qApp, &QCoreApplication::quit);
}
