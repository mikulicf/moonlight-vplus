# moonlight-usbd

The macOS USB/IP export helper provides the local server for the [Remote USB reverse tunnel](../docs/remote-usb-reverse-tunnel.md). It statically links [usbipdcpp](https://github.com/yunsmall/usbipdcpp) (LGPL-3.0) and [libusb](https://github.com/libusb/libusb) (LGPL-2.1-or-later). See the design document for licensing notes and retain usbipdcpp attribution when distributing the helper; the application's About page includes it.

The helper builds only on macOS and requires C++23, CMake 3.24 or later, Xcode 16 or later, and `pkg-config` on `PATH`. GitHub's macOS runner provides `pkg-config`; local developers can install it with `brew install pkg-config`. The main qmake project does not include this directory. `scripts/generate-dmg.sh` builds the helper and places it in `Moonlight.app/Contents/MacOS/` during packaging.

## Dependencies

Four Git submodules under `third_party/` use the following revisions. `.gitmodules` records the intended tags; the Git submodule entries pin the actual commits.

| Submodule | Pin | License | Purpose |
|---|---|---|---|
| usbipdcpp | v1.0.9 | LGPL-3.0 | USB/IP server (`LibusbServer`). |
| libusb | v1.0.29 | LGPL-2.1-or-later | Static USB device access library. |
| asio | asio-1-36-0 | BSL-1.0 | Header-only asynchronous I/O. |
| spdlog | v1.15.3 | MIT | Header-only logging. |

The official Asio and spdlog CMake config packages normally exist only after installation. Minimal local packages under `cmake/packages/` point to the submodule sources instead. libusb requires `pkg-config`; the file generated from `cmake/libusb-1.0.pc.in` is made available through `PKG_CONFIG_PATH`.

## Build

```sh
git submodule update --init --recursive -- usb-helper/third_party
cmake -S usb-helper -B usb-helper/build -DCMAKE_BUILD_TYPE=Release
cmake --build usb-helper/build
```

For development, set `MOONLIGHT_USB_HELPER` to the helper executable's path. The client can then launch it without an application bundle.

## Command line

```text
moonlight-usbd --version
moonlight-usbd list --json
moonlight-usbd serve --bind <busid> [--bind <busid>...] --listen <host:port>
```

- `list --json` enumerates devices once and prints a JSON array on one stdout line. Each entry contains `busId` (the libusb topology path, such as `1-2` or `1-2.3` through a hub), `vid`, `pid`, `vidPid`, and the `serial`, `manufacturer`, and `product` string descriptors. Unreadable descriptors are empty. `claimable` comes from claiming and releasing each interface; devices held by macOS system drivers, including many HID, storage, and camera devices, report false.
- `serve` first prints `READY <port>\n`. Passing port `0` lets the operating system choose a port. On startup failure it prints `ERROR {json}\n` and exits with a nonzero status; error codes include `device_not_found`, `device_occupied`, `bind_failed`, and `listen_failed`. After `READY`, it never writes stdout again; all logs go to stderr. Closing the parent's stdin pipe or sending SIGTERM shuts it down gracefully.
- The bus ID algorithm must remain byte-for-byte compatible with usbipdcpp's `get_device_busid`, because `find_by_busid` locates devices by string matching. Update both implementations together if the algorithm changes.
