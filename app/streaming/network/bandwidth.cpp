#include "bandwidth.h"
#ifdef Q_OS_WIN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#endif

#ifdef Q_OS_DARWIN
#include <sys/types.h>
#include <sys/socket.h>
#include <ifaddrs.h>
#include <net/if.h>
#endif

#ifdef Q_OS_LINUX
#include <QTimer>
#include <QFile>
#include <QTextStream>
#include <QRegularExpression>
#endif

BandwidthCalculator *BandwidthCalculator::s_instance = nullptr;

BandwidthCalculator *BandwidthCalculator::instance()
{
    if (s_instance == nullptr)
    {
        s_instance = new BandwidthCalculator();
    }
    return s_instance;
}

class SystemNetworkStats
{
public:
    static bool getNetworkUsage(qint64 &bytesReceived, qint64 &bytesSent);

private:
#ifdef Q_OS_WIN
    static bool getWindowsNetworkUsage(qint64 &bytesReceived, qint64 &bytesSent);
#elif defined(Q_OS_LINUX)
    static bool getLinuxNetworkUsage(qint64 &bytesReceived, qint64 &bytesSent);
#elif defined(Q_OS_DARWIN)
    static bool getMacOSNetworkUsage(qint64 &bytesReceived, qint64 &bytesSent);
#endif
};

BandwidthCalculator::BandwidthCalculator() : m_bytesReceived(0),
                                             m_lastBytesReceived(0),
                                             m_currentBandwidthKbps(0),
                                             m_running(false)
{
    connect(&m_updateTimer, &QTimer::timeout,
            this, &BandwidthCalculator::updateBandwidth);
}

BandwidthCalculator::~BandwidthCalculator()
{
    stop();
}

void BandwidthCalculator::addBytes(qint64 bytes)
{
    if (m_running)
    {
        m_bytesReceived += bytes;
    }
}

int BandwidthCalculator::getCurrentBandwidthKbps()
{
    return m_currentBandwidthKbps.load();
}

void BandwidthCalculator::start()
{
    if (!m_running)
    {
        m_bytesReceived = 0;
        m_lastBytesReceived = 0;
        m_currentBandwidthKbps = 0;
        m_elapsedTimer.start();
        m_updateTimer.start(1000); // Update once per second.
        m_running = true;
    }
}

void BandwidthCalculator::stop()
{
    if (m_running)
    {
        m_updateTimer.stop();
        m_running = false;
    }
}

void BandwidthCalculator::updateBandwidth()
{
    qint64 currentBytes = 0;
    qint64 sentBytes = 0;

    // Read actual network usage from the operating system.
    if (SystemNetworkStats::getNetworkUsage(currentBytes, sentBytes))
    {
        m_bytesReceived = currentBytes;
    }
    else
    {
        // Fall back to manually calculated usage if the system query fails.
        currentBytes = m_bytesReceived.load();
    }

    qint64 bytesTransferred = currentBytes - m_lastBytesReceived;

    // Calculate bandwidth in bits per second.
    qint64 elapsedMs = m_elapsedTimer.restart();
    if (elapsedMs > 0)
    {
        // Convert bits per second to Kbps.
        m_currentBandwidthKbps = static_cast<int>((bytesTransferred * 8.0 * 1000) / elapsedMs / 1000);
    }

    m_lastBytesReceived = currentBytes;
}

// Platform network statistics implementations.
bool SystemNetworkStats::getNetworkUsage(qint64 &bytesReceived, qint64 &bytesSent)
{
#ifdef Q_OS_WIN
    return getWindowsNetworkUsage(bytesReceived, bytesSent);
#elif defined(Q_OS_LINUX)
    return getLinuxNetworkUsage(bytesReceived, bytesSent);
#elif defined(Q_OS_DARWIN)
    return getMacOSNetworkUsage(bytesReceived, bytesSent);
#else
    Q_UNUSED(bytesReceived);
    Q_UNUSED(bytesSent);
    return false;
#endif
}

#ifdef Q_OS_WIN
bool SystemNetworkStats::getWindowsNetworkUsage(qint64 &bytesReceived, qint64 &bytesSent)
{
    // Initialize counters.
    bytesReceived = 0;
    bytesSent = 0;

    PMIB_IF_TABLE2 pIfTable = NULL;
    ULONG error = GetIfTable2(&pIfTable);

    if (error != NO_ERROR)
    {
        return false;
    }

    // Sum traffic across eligible network interfaces.
    for (ULONG i = 0; i < pIfTable->NumEntries; i++)
    {
        MIB_IF_ROW2 row = pIfTable->Table[i];

        // Include active physical interfaces; exclude virtual adapters and tunnels.
        if (row.OperStatus == IfOperStatusUp &&
            row.MediaType != NdisMediumLoopback &&
            row.Type != IF_TYPE_SOFTWARE_LOOPBACK &&
            row.Type != IF_TYPE_TUNNEL &&
            !(row.InterfaceAndOperStatusFlags.FilterInterface) &&
            row.TransmitLinkSpeed > 0 && 
            row.ReceiveLinkSpeed > 0)
        {
            // Check that the interface is actually carrying traffic.
            if (row.InOctets > 0 || row.OutOctets > 0) {
                bytesReceived += row.InOctets;
                bytesSent += row.OutOctets;
            }
        }
    }

    // Release the interface table.
    FreeMibTable(pIfTable);

    return true;
}
#elif defined(Q_OS_LINUX)
bool SystemNetworkStats::getLinuxNetworkUsage(qint64 &bytesReceived, qint64 &bytesSent)
{
    // Linux: read /proc/net/dev.
    QFile file("/proc/net/dev");
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text))
        return false;

    bytesReceived = 0;
    bytesSent = 0;

    QTextStream in(&file);
    QString line = in.readLine(); // Skip the two header lines.
    line = in.readLine();

    while (!in.atEnd())
    {
        line = in.readLine();
        QStringList parts = line.trimmed().split(QRegularExpression("\\s+"));
        if (parts.size() >= 10)
        {
            // Interface row format: Interface: rx_bytes ... tx_bytes ...
            QString interface = parts[0].remove(":");
            if (interface != "lo") { // Ignore loopback.
                bytesReceived += parts[1].toLongLong();
                bytesSent += parts[9].toLongLong();
            }
        }
    }

    file.close();
    return true;
}
#elif defined(Q_OS_DARWIN)
bool SystemNetworkStats::getMacOSNetworkUsage(qint64 &bytesReceived, qint64 &bytesSent)
{
    struct ifaddrs *ifaddrs;
    bytesReceived = 0;
    bytesSent = 0;

    if (getifaddrs(&ifaddrs) == -1) {
        return false;
    }

    for (struct ifaddrs *ifa = ifaddrs; ifa != nullptr; ifa = ifa->ifa_next) {
        // Ignore non-network interfaces.
        if (ifa->ifa_addr == nullptr || ifa->ifa_addr->sa_family != AF_LINK) {
            continue;
        }

        // Ignore loopback interfaces.
        if (strncmp(ifa->ifa_name, "lo", 2) == 0) {
            continue;
        }

        // Read interface statistics.
        if (ifa->ifa_data != nullptr) {
            struct if_data *stats = (struct if_data *)ifa->ifa_data;
            bytesReceived += stats->ifi_ibytes;
            bytesSent += stats->ifi_obytes;
        }
    }

    freeifaddrs(ifaddrs);
    return true;
}
#endif
