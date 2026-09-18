# Moonlight V+ for PC

This is the independently maintained [mikulicf fork](https://github.com/mikulicf/moonlight-vplus) of [Moonlight V+](https://github.com/qiin2333/moonlight-qt), built on [Moonlight Qt](https://github.com/moonlight-stream/moonlight-qt). The interface defaults to English, background downloads are opt-in, and streaming controls follow the active stream window. Optional language packs remain available.

See [external services and dependencies](docs/external-services.md) and [tracking both upstreams](docs/upstream-sync.md).

## Self-hosted managed access

The optional [managed backend and host agent](control/README.md) provide username/password sign-in and per-user computer assignments. Open **Backend sign-in** in the client and enter your deployment's HTTPS URL. The URL starts empty; no deployment address, account, or credential is built in. Linux Docker deployment files and a browser administration page are included.

Managed connections require [Apollo Managed](https://github.com/mikulicf/apollo-managed), which enforces expiring client-certificate grants at the host. Video, audio, and input connect directly to the host. The backend does not relay streams or automatically traverse routers; configure reachability for each deployment. Regular paired hosts remain available separately.

For hosts offering Desktop and Virtual Display, the connection page presents a display choice. **Existing display** shares the host desktop; **Virtual display** asks Apollo to create a software monitor for the stream. Neither option creates a separate Windows login or isolates users sharing that desktop.

[Documentation](docs/architecture.md)

[![Build](https://img.shields.io/github/actions/workflow/status/mikulicf/moonlight-vplus/build.yml?branch=master)](https://github.com/mikulicf/moonlight-vplus/actions/workflows/build.yml?query=branch%3Amaster)
[![Downloads](https://img.shields.io/github/downloads/mikulicf/moonlight-vplus/total)](https://github.com/mikulicf/moonlight-vplus/releases)

Moonlight V+ for PC is an enhanced desktop client based on [moonlight-stream/moonlight-qt](https://github.com/moonlight-stream/moonlight-qt), designed to work closely with [Foundation Sunshine](https://github.com/qiin2333/Sunshine).

It remains compatible with upstream Moonlight and standard Sunshine hosts, while improving the Foundation Sunshine desktop experience with clearer capability negotiation, finer quality/performance controls, and more efficient in-stream actions.

## Downloads

Download Windows, macOS, Linux AppImage, and Steam Link builds from [GitHub Releases](https://github.com/mikulicf/moonlight-vplus/releases).

> **macOS currently ships Apple Silicon (arm64) builds only**, named like `Moonlight-VPlus-<version>-arm64.dmg`.
> Intel Mac users need to build from source using the instructions below.
>
> **Linux AppImages are available for x86_64 and aarch64**, named like `Moonlight-VPlus-<version>-x86_64.AppImage` and `Moonlight-VPlus-<version>-aarch64.AppImage`.
> The x86_64 package is built on Ubuntu 22.04 and requires glibc 2.35 or later. The aarch64 package is built on Ubuntu 24.04 and requires glibc 2.39 or later, so Debian 12 and Raspberry Pi OS Bookworm cannot run it; use Trixie or a newer compatible distribution.

For upstream Moonlight distribution channels, mobile clients, Flatpak, Snap, or distro packages, see the [Moonlight website](https://moonlight-stream.org) and the [upstream repository](https://github.com/moonlight-stream/moonlight-qt). Those builds may not include the Foundation Sunshine extensions maintained in Moonlight V+ for PC.

## Foundation Sunshine Integration

Foundation Sunshine is the primary server counterpart for Moonlight V+ for PC. The client probes host capabilities during connection setup; enhanced protocols are enabled only when the server advertises support, and standard Moonlight / Sunshine behavior is used otherwise.

You can use it like a regular Moonlight client, or pair it with a Foundation Sunshine host for richer clipboard, audio input, display control, bitrate control, and folder-mapping behavior. When an extension is unavailable, the client falls back to standard compatible behavior.

## Key Enhancements

### Protocol And Streaming

- **Bidirectional clipboard sync**: supports text and PNG image sync between the client and Foundation Sunshine host, including common browser and native clipboard formats.
- **High-quality microphone forwarding**: uses the microphone extension in `moonlight-common-c` for continuous audio input and multichannel scenarios.
- **Remote resolution decoupling**: stream resolution can be independent from the local display resolution, with custom remote resolution and frame-rate controls.
- **AppView display control**: supports target display selection, virtual display groups, remote resolution, and remote frame-rate preferences so the client and Foundation Sunshine share the same display intent.
- **Folder mapping / host file access**: exposes Foundation Sunshine folder-mapping features in the client, including in-stream access to shared host files and cross-platform mount support.

### Quality And Performance

- **Sunshine ABR**: when supported by the host, Foundation Sunshine can adjust session bitrate dynamically from client feedback, balancing clarity and stability more effectively.
- **High-bitrate LAN streaming**: keeps Sunshine-oriented high-bitrate controls for wired LAN, desktop streaming, and high-resolution sessions.
- **Hardware decoding and modern video formats**: inherits upstream Moonlight hardware decoding support, including H.264, HEVC, AV1, HDR, and YUV 4:4:4 combinations depending on the client GPU and host encoder.
- **Frame pacing and latency controls**: keeps V-Sync, frame pacing, fullscreen, and borderless-window choices for tuning latency, smoothness, and desktop workflows.
- **Performance overlay**: exposes real-time stream metrics with additional render-time visibility, making stream tuning more measurable.

### Client Experience

- **Windows 11 style floating menu** with animation, icons, and an optional floating moon button.
- **Floating menu quick controls** for fullscreen, performance stats, mouse mode, cursor visibility, microphone, host file access, and other common in-stream actions.
- **Gamepad improvements** including configurable quit combos, instant gamepad/mouse switching, and context-aware settings visibility to reduce unrelated settings noise.
- **Remote desktop mouse mode** alongside game-style pointer capture, covering games, desktop work, and quick maintenance sessions.
- **Automatic IME suppression while streaming** on Windows via Win32 IMM hooks to improve keyboard input stability.
- **AppView presentation** for running state and display options, making it clearer where a session will launch.

### Automation And Releases

- **Fork-specific update checks** using GitHub Releases from `mikulicf/moonlight-vplus`.
- **Git tag based versioning** through `scripts/derive-version.py`, keeping CI and local artifact names consistent.
- **Automated translation build** via `.github/workflows/build-translate.yml` for `.ts` / `.qm` resources.
- **CI build matrix** for Windows, macOS, Linux AppImage, and Steam Link artifacts.

## Compatibility

- The standard Moonlight / Sunshine protocol remains compatible, so regular hosts do not need extra setup.
- When connected to standard Sunshine or another upstream-compatible host, Foundation extensions such as image clipboard, HQ Mic, ABR, and folder mapping gracefully downgrade or stay disabled.
- NVIDIA GameStream compatibility is inherited from upstream Moonlight, but new development in Moonlight V+ for PC is primarily focused on the Sunshine ecosystem.

## Building

### Common Setup

```powershell
git submodule update --init --recursive
```

Windows and macOS builds also need prebuilt dependencies:

```powershell
.\setup-deps.ps1
```

On macOS, use:

```bash
python3 setup-deps.py
```

### Windows

Requirements:

- Qt 6 SDK, preferably close to the Qt 6.11.x version used by CI.
- Visual Studio 2022 with the MSVC toolchain.
- 7-Zip when building user-facing installers.
- Windows Graphics Tools when debugging DirectX-related issues.

Common release build scripts:

```cmd
scripts\build-arch.bat release x64
scripts\generate-bundle.bat
```

### macOS

Requirements:

- Qt 6 SDK, preferably close to the Qt 6.11.x version used by CI.
- Xcode 14 or later.
- `create-dmg` when producing DMG artifacts.

DMG packaging also builds the USB helper, which requires Xcode 16 or later, CMake 3.24 or later, and `pkg-config`; see [usb-helper/README.md](usb-helper/README.md).

Common build commands:

```bash
qmake6 moonlight-qt.pro
make release
scripts/generate-dmg.sh
```

### Linux

Requirements:

- Qt 6 is recommended; Qt 5.12 or later remains supported.
- GCC or Clang.
- FFmpeg 4.0 or later.
- The Vulkan renderer requires `libplacebo` v7.349.0 or later, and FFmpeg 6.1 or later is recommended.

Example Debian / Ubuntu dependencies:

```bash
sudo apt install libegl1-mesa-dev libgl1-mesa-dev libopus-dev libsdl2-dev libsdl2-ttf-dev libssl-dev libavcodec-dev libavformat-dev libswscale-dev libva-dev libvdpau-dev libxkbcommon-dev wayland-protocols libdrm-dev qt6-base-dev qt6-declarative-dev libqt6svg6-dev qt6-wayland
```

Development build:

```bash
qmake6 moonlight-qt.pro
make debug
```

### Steam Link

Requirements:

- Clone the [Steam Link SDK](https://github.com/ValveSoftware/steamlink-sdk).
- Set the `STEAMLINK_SDK_PATH` environment variable.

Build:

```bash
scripts/build-steamlink-app.sh
```

Original Steam Link hardware limits:

- Maximum resolution: 1080p.
- Maximum frame rate: 60 FPS.
- Maximum video bitrate: 40 Mbps.
- HDR streaming is not supported.

## Contributing

Moonlight V+ for PC prioritizes Foundation Sunshine integration, desktop client experience, English documentation, and cross-platform build stability.

When opening an issue or pull request, please include:

- Client operating system and version.
- Foundation Sunshine or standard Sunshine version.
- Whether you are using a Moonlight V+ for PC release build.
- Whether the report involves an extension such as clipboard sync, HQ Mic, ABR, folder mapping, or remote resolution handling.

## Upstream And License

This project is based on [Moonlight Qt](https://github.com/moonlight-stream/moonlight-qt) and follows the [GPLv3 License](LICENSE) included in this repository.

Upstream Moonlight links:

- [Moonlight website](https://moonlight-stream.org)
- [Moonlight Qt](https://github.com/moonlight-stream/moonlight-qt)
- [Moonlight documentation](https://github.com/moonlight-stream/moonlight-docs/wiki)
- [Moonlight Discord](https://moonlight-stream.org/discord)
- [Moonlight Weblate](https://hosted.weblate.org/projects/moonlight/moonlight-qt/)

Thanks to the Moonlight, Sunshine, and related open-source dependency maintainers.
