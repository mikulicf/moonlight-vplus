// Pure parser tests for moonlight-usbd list --json device maps. No helper is
// spawned, so Windows/Linux can test the parser for the macOS-only helper.
#include "../../app/backend/usbforwardingbackend.h"
#include <QCoreApplication>
#include <QDebug>
#include <QVariantMap>

// Stub wm.cpp to avoid SDL/X11 dependencies; non-Wayland implementations also return false.
#include "../../app/utils.h"
bool WMUtils::isRunningWayland() { return false; }
bool WMUtils::isGpuSlow() { return false; }

static QVariantMap firstDevice(const char* json)
{
    QString error;
    const QVariantList devices = UsbForwardingBackend::parseHelperDevices(json, &error);
    if (error.isEmpty() && devices.size() == 1) {
        return devices.first().toMap();
    }
    return {};
}

int main(int argc, char** argv)
{
    QCoreApplication application(argc, argv);

    // Complete device: dotted hub bus ID and claimable state imply support.
    {
        const QVariantMap device = firstDevice(
            "[{\"busId\":\"1-2.3\",\"vid\":1351,\"pid\":3302,\"vidPid\":\"054C:0CE6\","
            "\"serial\":\"0102030\",\"manufacturer\":\"Sony Interactive Entertainment\","
            "\"product\":\"DualSense Wireless Controller\",\"claimable\":true}]");
        if (device.isEmpty() || device.value("busId").toString() != "1-2.3" ||
            device.value("description").toString() != "DualSense Wireless Controller" ||
            device.value("instanceId").toString() != "0102030" ||
            device.value("vidPid").toString() != "054c:0ce6" ||
            device.value("isBound").toBool() // Parser defaults false; refresh overlays preferences.
            || !device.value("isConnected").toBool() || device.value("isAttached").toBool() ||
            !device.value("isSupported").toBool() || device.value("isOccupied").toBool() ||
            device.value("isForced").toBool() ||
            !device.value("persistedGuid").toString().isEmpty()) {
            qWarning() << "full device parse mismatch:" << device;
            return 1;
        }
    }

    // System-owned devices (claimable=false) cannot be shared.
    {
        const QVariantMap device = firstDevice(
            "[{\"busId\":\"2-1\",\"vid\":1,\"pid\":2,\"vidPid\":\"0001:0002\","
            "\"serial\":\"\",\"manufacturer\":\"\",\"product\":\"USB Keyboard\","
            "\"claimable\":false}]");
        if (device.isEmpty()
                || device.value("isSupported").toBool()
                || !device.value("isOccupied").toBool()) {
            qWarning() << "occupied device parse mismatch:" << device;
            return 2;
        }
    }

    // Invalid bus IDs remain unsupported even when claimable.
    {
        const QVariantMap device = firstDevice(
            "[{\"busId\":\"IncompatibleHub\",\"vid\":1,\"pid\":2,\"vidPid\":\"0001:0002\","
            "\"serial\":\"\",\"manufacturer\":\"\",\"product\":\"X\",\"claimable\":true}]");
        if (device.isEmpty() || device.value("isSupported").toBool()) {
            qWarning() << "bad busid should be unsupported:" << device;
            return 3;
        }
    }

    // Description fallback: product, then manufacturer, then vidPid.
    {
        const QVariantMap device = firstDevice(
            "[{\"busId\":\"3-1\",\"vid\":1027,\"pid\":24577,\"vidPid\":\"0403:6001\","
            "\"serial\":\"A\",\"manufacturer\":\"FTDI\",\"product\":\"\",\"claimable\":true}]");
        if (device.value("description").toString() != "FTDI") {
            qWarning() << "description fallback to manufacturer failed:" << device;
            return 4;
        }
        const QVariantMap bare = firstDevice(
            "[{\"busId\":\"3-2\",\"vid\":1027,\"pid\":24577,\"vidPid\":\"0403:6001\","
            "\"serial\":\"\",\"manufacturer\":\"\",\"product\":\"\",\"claimable\":true}]");
        if (bare.value("description").toString() != "0403:6001") {
            qWarning() << "description fallback to vidPid failed:" << bare;
            return 5;
        }
    }

    // Empty array: empty result without error.
    {
        QString error = QStringLiteral("stale");
        const QVariantList devices = UsbForwardingBackend::parseHelperDevices("[]", &error);
        if (!devices.isEmpty() || !error.isEmpty()) return 6;
    }

    // Invalid input: non-array, non-JSON, or truncated JSON.
    for (const char* invalid : {"{}", "not json", "[{\"busId\":", "42"}) {
        QString error;
        const QVariantList devices = UsbForwardingBackend::parseHelperDevices(invalid, &error);
        if (!devices.isEmpty() || error.isEmpty()) {
            qWarning() << "malformed input should set error:" << invalid;
            return 7;
        }
    }

    qInfo() << "PASS helper list parsing: dotted busid, occupied, fallbacks, empty, malformed";
    return 0;
}
