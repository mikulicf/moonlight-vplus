// moonlight-usbd: macOS USB/IP export helper.
//
// Local USB/IP server for docs/remote-usb-reverse-tunnel.md. Moonlight starts it
// on demand to export selected local devices through usbipdcpp, then forwards
// the port's byte stream to the Sunshine host.
//
// Parent-process contract (Session/UsbForwardingLocalServer):
// - stdout emits one READY <port> or ERROR {json} line, then remains silent.
//   All logging, including usbipdcpp's spdlog output, goes to stderr.
// - stdin EOF or SIGTERM/SIGINT requests graceful shutdown.
// - Exit codes: 0 clean; 1 usage/internal error; 2 device missing/bind failure;
//   3 listen failure; 4 device occupied by the system.
//
// Three subcommands:
//   moonlight-usbd --version
//   moonlight-usbd list --json
//   moonlight-usbd serve --bind <busid> [--bind <busid>...] --listen <host:port>

#include <asio.hpp>
#include <spdlog/sinks/stdout_color_sinks.h>
#include <spdlog/spdlog.h>
#include <libusb-1.0/libusb.h>

#include "usbipdcpp/LibusbHandler/LibusbServer.h"

#include <cstdint>
#include <cstdio>
#include <csignal>
#include <iostream>
#include <string>
#include <string_view>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {

sigset_t kTerminationSignals;

// Escape JSON strings per RFC 8259, preserving non-ASCII UTF-8 descriptor text.
std::string jsonEscape(const std::string& value)
{
    std::string escaped;
    escaped.reserve(value.size());
    for (const char c : value) {
        switch (c) {
        case '"': escaped += "\\\""; break;
        case '\\': escaped += "\\\\"; break;
        case '\b': escaped += "\\b"; break;
        case '\f': escaped += "\\f"; break;
        case '\n': escaped += "\\n"; break;
        case '\r': escaped += "\\r"; break;
        case '\t': escaped += "\\t"; break;
        default:
            if (static_cast<unsigned char>(c) < 0x20) {
                char buffer[8];
                std::snprintf(buffer, sizeof(buffer), "\\u%04x", c);
                escaped += buffer;
            } else {
                escaped += c;
            }
        }
    }
    return escaped;
}

// Emit the protocol's single-line ERROR response on stdout.
void printErrorLine(std::string_view error, std::string_view busId = {},
                    int code = 0, const std::string& detail = {})
{
    std::cout << "ERROR {\"error\":\"" << error << '"';
    if (!busId.empty()) {
        std::cout << ",\"busid\":\"" << jsonEscape(std::string(busId)) << '"';
    }
    if (code != 0) {
        std::cout << ",\"code\":" << code;
    }
    if (!detail.empty()) {
        std::cout << ",\"detail\":\"" << jsonEscape(detail) << '"';
    }
    std::cout << "}\n" << std::flush;
}

// Match usbipdcpp::get_device_busid byte-for-byte. find_by_busid compares strings,
// so a differing algorithm would make listed devices impossible to serve.
std::string deviceBusId(libusb_device* device)
{
    uint8_t ports[8];
    const int count = libusb_get_port_numbers(device, ports, 8);
    std::string busid = std::to_string(libusb_get_bus_number(device));
    if (count > 0) {
        for (int i = 0; i < count; i++) {
            busid += (i == 0 ? "-" : ".");
            busid += std::to_string(ports[i]);
        }
    } else {
        busid += "-" + std::to_string(libusb_get_device_address(device))
              + ":" + std::to_string(libusb_get_port_number(device));
    }
    return busid;
}

std::string stringDescriptor(libusb_device_handle* handle, uint8_t index)
{
    if (index == 0 || handle == nullptr) {
        return {};
    }
    char buffer[256];
    const int length = libusb_get_string_descriptor_ascii(
                handle, index, reinterpret_cast<unsigned char*>(buffer),
                sizeof(buffer) - 1);
    if (length <= 0) {
        return {};
    }
    return std::string(buffer, static_cast<size_t>(length));
}

// Claim/release each active interface to detect occupancy. System drivers or
// other processes can return LIBUSB_ERROR_BUSY; any claim failure means occupied.
// Never detach kernel drivers here: Darwin requires a privileged helper for that.
bool interfacesClaimable(libusb_device* device, libusb_device_handle* handle)
{
    libusb_config_descriptor* config = nullptr;
    if (libusb_get_active_config_descriptor(device, &config) != LIBUSB_SUCCESS) {
        return false;
    }

    bool claimable = true;
    for (int i = 0; i < config->bNumInterfaces && claimable; i++) {
        // libusb wants bInterfaceNumber from the descriptor, not the array
        // index: interfaces are not guaranteed to be numbered contiguously.
        const uint8_t interfaceNumber = config->interface[i].altsetting->bInterfaceNumber;
        if (libusb_claim_interface(handle, interfaceNumber) == LIBUSB_SUCCESS) {
            libusb_release_interface(handle, interfaceNumber);
        } else {
            claimable = false;
        }
    }

    libusb_free_config_descriptor(config);
    return claimable;
}

// Independent occupancy probe when no other handle is held, including serve's early check.
bool deviceClaimable(libusb_device* device)
{
    libusb_device_handle* handle = nullptr;
    if (libusb_open(device, &handle) != LIBUSB_SUCCESS) {
        return false;
    }
    const bool claimable = interfacesClaimable(device, handle);
    libusb_close(handle);
    return claimable;
}

int runList()
{
    libusb_device** devices = nullptr;
    const ssize_t count = libusb_get_device_list(nullptr, &devices);
    if (count < 0) {
        printErrorLine("enumerate_failed", {}, 0,
                       libusb_error_name(static_cast<int>(count)));
        return 1;
    }

    std::string json = "[";
    bool first = true;
    for (ssize_t i = 0; i < count; i++) {
        libusb_device* device = devices[i];
        libusb_device_descriptor descriptor;
        if (libusb_get_device_descriptor(device, &descriptor) != LIBUSB_SUCCESS) {
            continue;
        }
        // Do not export hubs, matching usbipdcpp's skip_hub behavior.
        if (descriptor.bDeviceClass == LIBUSB_CLASS_HUB) {
            continue;
        }

        const std::string busId = deviceBusId(device);
        std::string serial, manufacturer, product;
        bool claimable = false;
        libusb_device_handle* handle = nullptr;
        if (libusb_open(device, &handle) == LIBUSB_SUCCESS) {
            serial = stringDescriptor(handle, descriptor.iSerialNumber);
            manufacturer = stringDescriptor(handle, descriptor.iManufacturer);
            product = stringDescriptor(handle, descriptor.iProduct);
            claimable = interfacesClaimable(device, handle);
            libusb_close(handle);
        }

        char vidPid[12];
        std::snprintf(vidPid, sizeof(vidPid), "%04x:%04x",
                      descriptor.idVendor, descriptor.idProduct);

        if (!first) {
            json += ",";
        }
        first = false;
        json += "{\"busId\":\"" + jsonEscape(busId) + "\"";
        json += ",\"vid\":" + std::to_string(descriptor.idVendor);
        json += ",\"pid\":" + std::to_string(descriptor.idProduct);
        json += ",\"vidPid\":\"";
        json += vidPid; // Generated %04x:%04x text needs no escaping.
        json += "\"";
        json += ",\"serial\":\"" + jsonEscape(serial) + "\"";
        json += ",\"manufacturer\":\"" + jsonEscape(manufacturer) + "\"";
        json += ",\"product\":\"" + jsonEscape(product) + "\"";
        json += ",\"claimable\":" + std::string(claimable ? "true" : "false");
        json += "}";
    }
    libusb_free_device_list(devices, 1);

    json += "]";
    std::cout << json << "\n" << std::flush;
    return 0;
}

int runServe(const std::vector<std::string>& bindBusIds,
             const std::string& listenHost, uint16_t listenPort)
{
    // Defaults are appropriate: skip_hub=true and auto_bind_hotplug=false.
    // Hotplug still cleans up disconnected bindings without automatically adding devices.
    usbipdcpp::LibusbServerConfig config;
    usbipdcpp::LibusbServer server(config);

    for (const std::string& busId : bindBusIds) {
        // bind_host_device takes ownership of find_by_busid's reference.
        // Do not unref afterward, matching upstream's libusb_server example.
        libusb_device* device = usbipdcpp::LibusbServer::find_by_busid(busId);
        if (device == nullptr) {
            printErrorLine("device_not_found", busId);
            return 2;
        }
        // Reject occupied devices before READY, since client attachment would fail.
        // bind_host_device has not taken ownership yet, so release our reference here.
        if (!deviceClaimable(device)) {
            libusb_unref_device(device);
            printErrorLine("device_occupied", busId);
            return 4;
        }
        const auto result = server.bind_host_device(device);
        if (result != usbipdcpp::DeviceOperationResult::Success) {
            printErrorLine("bind_failed", busId, static_cast<int>(result));
            return 2;
        }
    }

    const asio::ip::tcp::endpoint endpoint(asio::ip::make_address(listenHost),
                                           listenPort);
    const usbipdcpp::error_code error = server.start(endpoint);
    if (error) {
        printErrorLine("listen_failed", {}, 0, error.message());
        return 3;
    }

    // Port zero lets the OS select a port; query it after start().
    std::cout << "READY " << server.get_server().endpoint().port() << std::endl;

    // Stop on stdin EOF or SIGTERM/SIGINT. The detached stdin watcher sends
    // kill(getpid(), SIGTERM) to wake the main thread's sigwait. Do not join it:
    // a signal may arrive first while read remains blocked. Use kill, not raise,
    // because a thread-directed signal would never reach the main thread's sigwait.
    std::thread stdinWatcher([] {
        std::string line;
        while (std::getline(std::cin, line)) {
        }
        kill(getpid(), SIGTERM);
    });
    stdinWatcher.detach();

    int signalNumber = 0;
    sigwait(&kTerminationSignals, &signalNumber);
    server.stop();
    return 0;
}

void usage()
{
    std::fprintf(stderr,
                 "usage: moonlight-usbd --version\n"
                 "       moonlight-usbd list --json\n"
                 "       moonlight-usbd serve --bind <busid> [--bind <busid>...]"
                 " --listen <host:port>\n");
}

} // namespace

int main(int argc, char** argv)
{
    // Redirect spdlog's default stdout logger to stderr before any work.
    // stdout is reserved for the parent process's line protocol.
    spdlog::set_default_logger(spdlog::stderr_color_mt("moonlight-usbd"));
    spdlog::set_level(spdlog::level::info);

    std::signal(SIGPIPE, SIG_IGN);
    sigemptyset(&kTerminationSignals);
    sigaddset(&kTerminationSignals, SIGINT);
    sigaddset(&kTerminationSignals, SIGTERM);
    pthread_sigmask(SIG_BLOCK, &kTerminationSignals, nullptr);

    if (argc == 2 && std::string_view(argv[1]) == "--version") {
        std::cout << "moonlight-usbd " << MOONLIGHT_USB_HELPER_VERSION
                  << " (usbipdcpp v" << USBIPDCPP_PINNED_VERSION << ")"
                  << std::endl;
        return 0;
    }

    if (argc >= 2 && std::string_view(argv[1]) == "list") {
        if (argc != 3 || std::string_view(argv[2]) != "--json") {
            usage();
            return 1;
        }
        if (libusb_init(nullptr) != LIBUSB_SUCCESS) {
            printErrorLine("init_failed");
            return 1;
        }
        const int result = runList();
        libusb_exit(nullptr);
        return result;
    }

    if (argc >= 2 && std::string_view(argv[1]) == "serve") {
        std::vector<std::string> bindBusIds;
        std::string listen = "127.0.0.1:0";
        for (int i = 2; i < argc; i++) {
            const std::string_view argument(argv[i]);
            if (argument == "--bind" && i + 1 < argc) {
                bindBusIds.emplace_back(argv[++i]);
            } else if (argument == "--listen" && i + 1 < argc) {
                listen = argv[++i];
            } else {
                usage();
                return 1;
            }
        }
        if (bindBusIds.empty()) {
            usage();
            return 1;
        }

        const auto colon = listen.rfind(':');
        if (colon == std::string::npos || colon == 0 || colon + 1 == listen.size()) {
            usage();
            return 1;
        }
        const std::string host = listen.substr(0, colon);
        const std::string portText = listen.substr(colon + 1);
        unsigned long portValue = 0;
        try {
            portValue = std::stoul(portText);
        } catch (const std::exception&) {
            usage();
            return 1;
        }
        if (portValue > 65535) {
            usage();
            return 1;
        }

        if (libusb_init(nullptr) != LIBUSB_SUCCESS) {
            printErrorLine("init_failed");
            return 1;
        }
        const int result = runServe(bindBusIds, host, static_cast<uint16_t>(portValue));
        libusb_exit(nullptr);
        return result;
    }

    usage();
    return 1;
}
