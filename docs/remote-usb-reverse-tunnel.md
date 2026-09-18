# Remote USB reverse tunnel

Moonlight forwards the client's local USB/IP server to Sunshine through a reverse TLS tunnel. Sunshine launches usbip-win2 to import the device on the streaming host. Both tunnel endpoints forward bytes without parsing USB/IP. This path does not use a RUSB broker, additional framing, a Rust core, or a separate usb-agent.

```text
USB device -> usbipd-win -> Moonlight Tunnel -> TLS -> Sunshine reverse_tunnel_service -> usbip-win2 -> Windows device
```

## Current support

- Windows clients: `UsbForwardingBackend` manages usbipd-win device sharing and enumeration.
- Windows hosts: `usbip_host_controller` invokes usbip-win2.
- macOS clients: the bundled `moonlight-usbd` helper uses usbipdcpp v1.0.9 and libusb v1.0.29; see `usb-helper/` and the next section.
- The separate Android Moonlight V+ project implements its own USB/IP export backend using the same capability API and tunnel protocol. This Qt project has no Linux client USB backend.
- The Linux host controller currently reports unsupported.

## macOS client: moonlight-usbd

macOS has no persistent USB/IP service in this implementation. The application bundles `Contents/MacOS/moonlight-usbd`, built from `usb-helper/` with CMake separately from the main qmake project. Developers can override its path with `MOONLIGHT_USB_HELPER`.

The helper statically links usbipdcpp's `LibusbServer` (LGPL-3.0) and vendored libusb v1.0.29 (LGPL-2.1-or-later), compiling libusb from source. The upstream integration uses the LGPL-3.0 provisions for conveying the combined work under GPL-3.0, matching Moonlight Qt's license. Retain the component licenses and distribution obligations. The usbipdcpp README requests prominent attribution, which is included on the About page.

Differences from the Windows backend:

- **Enumeration:** `moonlight-usbd list --json` produces one result containing `busId`, `vid`, `pid`, `vidPid`, `serial`, `manufacturer`, `product`, and `claimable`. The macOS branch of `UsbForwardingBackend::refresh()` parses it through `parseHelperDevices`, covered by `tests/usb_forwarding_backend_list`. A bus ID is a libusb topology path such as `1-2`, or `1-2.3` through a hub. Its generation must exactly match usbipdcpp's `find_by_busid` convention.
- **Persistent bindings:** Moonlight stores the bus ID list in the `usbforwardingbound` preference; Windows uses usbipd's registry state. Binding and unbinding need no elevation. A bus ID identifies a physical topology position, so reconnecting a device to a different USB port makes the saved binding appear missing. This is a known limitation of the first version.
- **Local server:** `Session` uses `UsbForwardingLocalServer` to launch `moonlight-usbd serve --bind <busid> --listen 127.0.0.1:0`. It reads the `READY <port>` stdout line and sets `TunnelConfig.localPort` to that temporary port. Closing stdin or sending SIGTERM stops the helper gracefully. The tunnel, capability API, and certificate verification are otherwise identical to Windows.
- **Platform limitations:** libusb cannot claim interfaces held by macOS system drivers, including many HID controllers, keyboards, storage devices, and cameras. The helper probes occupancy by claiming and releasing interfaces. Occupied devices appear as “In use by macOS” and cannot be shared. Supporting these devices would require a privileged helper, potentially using SMAppService and the Darwin detach support in libusb 1.0.27 or later. That is outside the current implementation.

## Authentication and configuration

Moonlight uses the client certificate and private key saved during pairing and verifies that Sunshine presents exactly the pinned host certificate. When connecting by IP, the certificate's common name need not match the IP, but any different certificate is rejected. Sunshine requires a paired client certificate and validates the shared token in the JSON handshake.

Qt and Android obtain credentials through `GET /api/v1/usb-forwarding` over paired HTTPS with host-certificate pinning; they no longer read the port or token from environment variables. The API is version 1 and limits responses to 4096 bytes. Responses include `enabled`, `available`, and `reason`. Only an available service returns `port` (an integer from 1 to 65535) and `token` (64 hexadecimal characters).

`available` indicates that the host tunnel service can accept a connection, not that a driver has successfully imported a device. Verify device usability after import. The capability request has a five-second timeout and does not follow redirects. Even a certificate trusted by the system's certificate authorities must exactly match the pairing pin.

Forwarding is disabled by default on Sunshine. Enable `usb_forwarding_enabled` on the web settings Input page, save, and restart. `usb_forwarding_port` defaults to `0`, meaning the main port plus seven, normally `47996`. An explicit value from 1024 to 65535 overrides it; clients always use the port advertised by the capability API. The host needs usbip-win2 and its matching driver. Connections across networks also require the corresponding TCP port to be allowed or forwarded; the application does not configure the router automatically.

In Qt, enable USB forwarding in settings and share, or bind, the desired peripheral through device management. After streaming starts, explicitly selecting a device in the USB menu retrieves credentials and starts the tunnel. Releasing the device or ending the stream releases the import. An outstanding credential request must not restart sharing after cancellation. Selecting a device again after a host restart retrieves fresh credentials.

The token stays in memory and is generated and rotated with the host process; it is not a per-stream token. The capability API requires the client to remain paired and returns `Cache-Control: no-store`. The tunnel checks both the paired certificate and token again. Never log or commit tokens, private keys, or user pairing state. This feature trusts paired clients authorized to forward devices; it does not guarantee that every USB device class will work safely or reliably.

## Connection establishment

The Windows client performs a read-only Service Control Manager query in settings and before each connection to check both the `usbipd` service and the `VBoxUSBMon` driver. It does not start the tunnel if the query fails or either component is stopped. This is a necessary condition, not proof that import will succeed. Service readiness, sharing, tunnel readiness, and successful device import are distinct states.

### Historical retest: September 9, 2026 — acceptance incomplete

The upstream retest verified normal PIN pairing, persistence after restarting Qt, runtime capability retrieval, and K380 import. The host reported hub port 1 and eleven healthy related PnP nodes. Actual keystrokes, release, reconnection, and exit cleanup were not yet accepted in that round of the normal configuration flow. Overlay menu closing and interaction problems also remained under investigation.

The test environment lacked the `usbipd` service dependency on `VBoxUSBMon`, causing driver startup and `CreateFile` failures. Native attach timeouts, host exit timeouts, and service startup file-locking problems followed. Import succeeded after rebooting, restoring the dependency, and starting the driver. The client does not perform those environment repairs automatically, and the result does not establish that every earlier timeout had the same cause. The client changes added only read-only preflight checks and accurate failure messages.

### Protocol sequence

1. Moonlight connects to the local USB/IP server, normally `127.0.0.1:3240`, and Sunshine's TLS port.
2. After verifying the paired certificate, it sends one JSON line: `{"op":"forward","token":"<token>","busid":"1-2"}\n`.
3. Sunshine validates the certificate, token, and bus ID, reserves the device slot, and listens on a temporary loopback port.
4. Sunshine starts an asynchronous accept before launching `usbip --tcp-port <port> attach --remote 127.0.0.1 --bus-id <busid> --once --terse`.
5. When the helper connects, Sunshine replies with `{"op":"ready"}\n` and immediately begins bidirectional forwarding. **Ready means the byte tunnel is established, not that device import is complete.** usbip-win2 must finish USB/IP import through this tunnel before reporting successful attach.
6. When the helper returns a hub port, Sunshine records the binding and cancels the startup timeout.

Before ready, rejection is a single `{"op":"error","reason":"..."}` line. After ready, every byte belongs to USB/IP: an attach failure must close the connection rather than inject JSON into the stream.

## Lifecycle and resource limits

- Sunshine permits one active tunnel per bus ID and rejects duplicates. The Moonlight client currently permits one active tunnel globally.
- Client startup times out after 15 seconds, covering the complete 12-second host startup window. Host attach also remains subject to the controller's timeout.
- The JSON handshake line is limited to 4 KiB. Bytes read beyond the handshake must still be forwarded.
- The client uses a 4 MiB read-buffer/write-queue high-water mark. The host performs asynchronous 64 KiB reads and writes in each direction and relies on TCP backpressure.
- Releasing a device, ending the stream, or disconnecting either socket closes both local connections. The host cancels pending attach work and detaches accepted bindings.
- The controller generates a local `binding_id` for each attach. It prevents an old detach from removing a new device after temporary or hub port reuse. This identifier is not transmitted in the tunnel protocol and does not depend on a client RUSB token.
- Sunshine uses Asio's certificate-verification callback API; it must not overwrite the `SSL_CTX` app data owned by Asio.

## Implementation and validation entry points

- Client: `app/backend/usbforwardingtunnel.{h,cpp}`; `Session` manages the interface and streaming lifecycle.
- Host implementation: [Sunshine PR #1034](https://github.com/AlkaidLab/foundation-sunshine/pull/1034).
- Client implementation: [Moonlight Qt PR #209](https://github.com/qiin2333/moonlight-qt/pull/209).
- `tests/usb_forwarding_tunnel/usb_forwarding_tunnel.pro` builds a driver that uses the production `Tunnel` class without a video session.
- Sunshine's `reverse_tunnel_probe` and `tests/tools/test_reverse_tunnel.py` cover TLS/token rejection, forwarding before attach completion, disconnect/reconnect, and paired endpoint tests. Synthetic helpers do not establish real-device end-to-end compatibility.
- The host's existing `loopback_usbip_bridge` serves the virtual touchscreen proof of concept and is not part of this reverse tunnel.

## Historical Windows hardware validation: September 6, 2026

The upstream test exported a real Android phone from Windows through usbipd-win 5.3.0. The production Qt `Tunnel` connected through an SSH port forward to the production Sunshine `reverse_tunnel_service` in a Windows 10 Hyper-V VM, where usbip-win2 0.9.7.8 imported the device.

- Standard WinUSB control requests read and verified the device VID/PID and serial number without requiring phone authorization. Each round completed twenty `GET_STATUS` requests.
- Two import/control-transfer/release cycles passed, with the second reusing hub port 1. Imported ports were empty after each release, and local ADB access returned at the end.
- Both the initial test and the parameterized rerun passed two cycles. Reproduction tools are Sunshine's `tests/tools/run_usb_control_vm_e2e.py` and `usb_control_probe.cpp`; see its `tests/tools/README-remote-usb.md`.
- These results cover real USB control transfers and reconnection. ADB inside the VM still required phone authorization. The tests did not cover ADB shell, sustained bulk or isochronous throughput, other device classes, or the complete video/UI lifecycle.

### Combined validation with video streaming

A subsequent upstream test used the complete Moonlight client and Sunshine host for two consecutive sessions. The 1024×768 H.264 desktop was visible, and the actual streaming USB menu imported the phone. Each session checked the serial number, performed twenty WinUSB `GET_STATUS` requests, and then exited the stream directly. Both exits automatically cleared the imported ports, and a new stream could import the phone again. Local ADB access returned at the end.

Receive/decode/presentation rates were 30.0/30.0/30.0 FPS and 30.1/30.1/30.0 FPS, with 0% observed network frame loss. These sessions used the application itself, not the standalone tunnel probe, and USB and video connected directly to the same VM.

The working configuration used WGC capture within the logged-in session, Sunshine software encoding, and Moonlight software decoding. Hardware decoding in that environment failed to initialize the hardware-frame context with error `-22`, and the VM had no audio endpoint. Hardware decoding, audio, gamepads, and USB bulk/isochronous throughput were therefore outside the validated scope.

The deployment required usbip-win2 0.9.7.8 tools and matching DLLs for the VM's driver. Initial command-line pairing registered the client on the host but left the client's host pin empty. Before the successful historical test, the host certificate was obtained through authenticated SSH and pinned for that test host. Fresh-pairing pin persistence still required separate validation at that point. Sunshine's `tests/tools/README-remote-usb.md` records the procedure and evidence.
