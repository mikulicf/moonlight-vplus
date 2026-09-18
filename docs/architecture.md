# Architecture and directory guide

This guide explains the ownership and purpose of each directory. Preserve the layout inherited from Moonlight where practical: renaming or moving those files creates unnecessary conflicts when integrating either upstream. See [upstream-sync.md](upstream-sync.md).

## Layout inherited from Moonlight

| Directory or file | Purpose |
|---|---|
| `app/` | Client application: QML interface, streaming sessions, backend, settings, input, and renderers. V+ extends much of this code. |
| `moonlight-common-c/` | Protocol library submodule. V+ uses `qiin2333/moonlight-common-c`, whose `mic` branch provides the required extensions. Integrate library updates separately through review. |
| `qmdnsengine/`, `h264bitstream/`, `third-party/AMF` | Vendored libraries and submodules. |
| `AntiHooking/` | Upstream Windows library for protection against DLL injection. |
| `config.tests/` | qmake feature probes, including the SteamLink SDK and EGL. |
| `scripts/` | Build, packaging, and local development tools from Moonlight and V+. |
| `wix/`, `setup-deps.ps1`, `setup-deps.py` | Windows packaging and prebuilt dependency downloads. |
| `moonlight-qt.pro`, `globaldefs.pri` | Top-level subproject registration and shared build configuration. |

## Modules added by V+

These directories do not overlap the original Moonlight layout, although V+ updates can still modify them.

| Directory or file | Purpose |
|---|---|
| `clipboard-helper/` | Clipboard synchronization helper running in a separate process. |
| `usb-helper/` | macOS USB/IP backend, `moonlight-usbd`, built with C++23 and CMake and using its own `third_party` submodules. |
| `file-mapping/` | Host file sharing, divided into mount, protocol, and virtual-filesystem layers in the `FileMapping` namespace. `smoke/` contains manual smoke-test executables. |
| `tests/` | Tests; see the [coverage and conventions](../tests/README.md). |
| `docs/` | Design documents and development procedures. |
| `projects/` | Local business materials, deliberately excluded from Git; see [CONTRIBUTING.md](../CONTRIBUTING.md). |
| `scripts/run-test.bat` | Common Windows test runner for local development and CI. |

## Conventions

- Use qmake for new top-level modules and register them in `moonlight-qt.pro` under `SUBDIRS`. A separate CMake module is appropriate only when it is entirely new, has no upstream counterpart, and requires dependencies available only through CMake. `usb-helper/` is the existing example.
- The application uses C++17 to remain compatible with the SteamLink toolchain. The isolated USB helper uses C++23; avoid introducing another language-standard requirement.
- Linux source dependency pins live in `.github/workflows/build.yml`. Windows and macOS prebuilt dependency bundles are pinned by the version tag in `setup-deps`. Review both when updating dependencies; see [upstream-sync.md](upstream-sync.md).
- Keep build outputs, `libs/`, IDE files, and `.DS_Store` out of Git.

## History

The September 2026 cleanup removed empty inherited directories (`src/`, `streaming/`, `include/`, and `soundio/`) and accidentally tracked `.DS_Store` files. It moved file-mapping smoke tests under `file-mapping/smoke/` and DualSense probe scripts under `scripts/`.
