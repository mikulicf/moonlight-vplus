# Tests

Most subdirectories contain a standalone qmake test executable. Build with `qmake` and the platform's make tool, then run the executable; a nonzero exit status indicates failure. Python tests use `unittest` instead.

Windows CI and local development share `scripts/run-test.bat`. See its header for the calling convention. Register a new test in the appropriate `build.yml` step with `call scripts\run-test.bat <directory> <TARGET>`.

Existing assertion styles include accumulating `require` calls, `CHECK` macros that return a line number, and `qFatal`. Prefer the accumulating `require(bool, QString)` style demonstrated by `clipboard_payload_routing` for new tests. Keep `main()` short and compile the production source directly, as the existing `.pro` files do.

## CI coverage

The matrix is defined in `.github/workflows/build.yml`.

| Directory | Coverage | CI platform |
|---|---|---|
| `derive_version` | Version derivation in `scripts/derive-version.py`. | Ubuntu, Python unittest |
| `upstream_status` | Two-source reporting, shared-commit counting, cherry-pick provenance, review decisions, remote validation, and preservation of HEAD. | Ubuntu, Python unittest |
| `cursor_shape_classification` | Cursor bitmap-to-shape classification matrix. | Windows |
| `clipboard_payload_routing` | Inline/out-of-band payload thresholds and file-reference protection. | Windows |
| `overlay_button_position` | Normalized overlay coordinates and round trips across resolutions. | Windows |
| `file_mapping_websocket_framing` | WebSocket framing, final frames, fragmentation, and ping/pong handling. | Windows |
| `file_mapping_mirror_e2e` | End-to-end host file mirroring with `FakeRemoteVfs` and a mount provider. | Windows |
| `usb_forwarding_capability` | Capability JSON parsing, ports, tokens, and malformed input. | Windows |
| `usb_forwarding_environment` | Readiness state to error-message mapping; `--require-ready` performs a live probe. | Windows |
| `usb_forwarding_backend_list` | Device-list parsing from `moonlight-usbd list --json`. | Windows |
| `ds5_ir_renderer` | DualSense haptic intermediate-representation rendering. | Windows |
| `pen_history_selection` | Pen input history selection. | Windows |
| `stylus_replay` | Recorded stylus input replay. | Windows |
| `overlay_event_wake_state` | Overlay menu event wakeup state. | Windows |
| `overlay_button_native_wake` | Native overlay button wakeups. | Windows, macOS, Linux with Xvfb |
| `overlay_toast_event_state` | Overlay toast event state. | Windows |
| `overlay_menu_navigation` | Keyboard and mouse navigation using QTest events and the offscreen platform. | Windows |
| `settings_localization` | Optional Chinese `.qm` catalog and settings layout using `qmltestrunner`. | Windows |
| `linux_display_event_monitor` | Linux display-event wakeups. | Linux |

Run the Python suites without a Qt build:

```sh
python -m unittest discover -s tests/derive_version -v
python -m unittest discover -s tests/upstream_status -v
```

## Local and manual tests

| Directory | Requirements |
|---|---|
| `usb_forwarding_tunnel` | Manual USB/IP integration probe requiring ten command-line arguments and a real usbipd server. See the header of `main.cpp`. It does not run in CI. |
| `file-mapping/smoke/` | Manually built smoke-test executables that reuse the application sources. They intentionally stay out of the top-level `SUBDIRS`: linking the backend and OpenSSL into every platform build, including SteamLink, would add compatibility requirements without automatic test coverage. |

For stream overlay focus changes, also check a real streaming session: the moon button and panel should be available while the stream is active, disappear when switching to another application or minimizing the stream, and return when the stream regains focus. Opening or closing the panel must keep its controls usable and must not recapture the pointer in another application. Disconnecting should leave no overlay windows behind.

## Conventions

- Never commit Makefiles, object files, or executables. `.gitignore` covers `tests/*/{Makefile*,.qmake.stash,*.o,release,debug}`. Previously committed Linux build files broke Windows builds when MSVC qmake loaded their `.qmake.stash`.
- Use conditional `SOURCES` in the test's `.pro` file for platform-specific production code, such as the macOS clipboard implementation. Do not copy that logic into the test.
