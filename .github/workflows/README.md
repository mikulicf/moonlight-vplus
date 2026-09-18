# GitHub Actions workflows

GitHub Actions builds and tests this fork, compiles translation resources, and reports updates from both upstream projects.

## Main build: `build.yml`

Triggers are pushes and pull requests targeting `master` or `main`, published releases, and manual workflow dispatches.

| Platform | Build environment | Output |
|---|---|---|
| Windows x64 and ARM64 | Visual Studio 2022, Qt 6.11.1 | Portable packages and universal installer |
| macOS | macOS 15 runner, Xcode, Qt 6.11.1, Node.js/create-dmg | DMG |
| Linux x86_64 and aarch64 | Ubuntu runners, Qt 6.11.1 | AppImage |
| SteamLink | Valve SteamLink SDK cross-compilation | SteamLink package |

Artifact names contain the version derived by `scripts/derive-version.py`. Refer to the upload steps for exact names. Windows packaging also emits the historical `MoonlightPortable-*` and `MoonlightSetup-*` release aliases for clients upgrading across the V+ branding change.

The independent checks cover version derivation, both-upstream reporting, QML type resolution, and formatting of changed C++ lines. Platform jobs run the applicable tests listed in [tests/README.md](../../tests/README.md).

Windows deploys the Qt runtime dependencies and generates debugging symbols. macOS packaging also builds the USB forwarding helper. Linux builds pinned SDL3, sdl2-compat, SDL2_ttf, libva, dav1d, libplacebo, and FFmpeg dependencies before packaging the application. SteamLink uses its separate SDK and toolchain.

## Run and inspect builds

Open the repository's Actions tab, select **Build Moonlight V+ for PC**, and use **Run workflow** for a branch build. Pull requests and pushes to the configured branches trigger it automatically. Each run provides per-job logs and downloadable artifacts.

Publishing a release builds and uploads the platform packages. A manual dispatch can replace assets for an existing version tag when `publish_release` is enabled; review that option before using it. Release uploads use the repository's `GH_BOT_TOKEN` secret. Ordinary build and test jobs do not require that secret.

## Translation resources: `build-translate.yml`

Pushes to `master` and manual dispatches compile the language resources with the matching Windows Qt version. The workflow stages only `app/languages/*.qm`, commits updated catalogs when needed, and pushes them back. It requires repository contents-write permission. The interface defaults to English while retaining optional language packs.

## Upstream report: `upstream-status.yml`

This read-only workflow runs each Monday at 01:23 UTC and on manual dispatch. It tests the reporting script, fetches V+ and original Moonlight, and saves the report in the job summary and an artifact. It does not merge or publish code. See [the upstream procedure](../../docs/upstream-sync.md).

## Maintenance and troubleshooting

- **Windows timeouts:** inspect the logs for a waiting `Terminate batch job (Y/N)?` prompt. Build scripts clean conflicting environment variables and limit parallelism to control memory use.
- **Missing Linux packages:** check the selected runner's package names and optional Wayland support. A package name valid on another Ubuntu release may differ.
- **Qt installation failures:** keep the Qt version and required modules consistent between jobs. Windows uses the naqt installer path; the other jobs pin a compatible aqtinstall revision to read the Qt 6.11.1 repository metadata.
- **Dependency failures:** inspect the failing download or compile step and its pinned revision. Do not assume an optional dependency failure explains a later application error.
- **Formatting failures:** use clang-format 21.1.8 and format the changed lines. Avoid formatting the entire inherited source tree, which makes upstream merges harder.
- **QML failures:** check the independent type-resolution job even when native compilation succeeds; unresolved QML types can otherwise fail only at runtime.

Qt installations are cached where configured. Linux uses a bounded ccache across runs. The SteamLink SDK uses a weekly cache key and refreshes an older restored checkout before saving it. Dependency revisions remain explicitly pinned; caching does not select their versions.

To change Qt versions, update the matching installation steps and confirm all supported platforms still build. To add an architecture, extend the relevant matrix or job and its packaging steps. Use each platform's existing parallel-build controls rather than a fixed assumption about runner CPU count. Local builds require Git, network access for dependencies, and the compiler/SDK and Qt version appropriate to the platform.
