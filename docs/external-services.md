# External services and dependencies

The streaming connection goes to the host selected by the user. A hosted account, hosted relay, community website, or wallpaper service is not required for streaming.

## Runtime requests

| Destination | Purpose | When used |
| --- | --- | --- |
| Selected host address | Pairing, discovery, video, audio, input, and supported host extensions | When discovering or connecting to hosts |
| `api.github.com` and GitHub release asset hosts | Check and download releases from `mikulicf/moonlight-vplus` | Update checks and user-approved downloads |
| `moonlight-stream.org` | Controller mappings and compatibility information inherited from Moonlight | Existing mapping and compatibility refreshes |
| `picsum.photos` and its image delivery hosts | Optional photography backgrounds | Only when the Photography background is selected |
| User-entered image URL | Optional custom background | Only when that URL is configured |
| Local Discord client | Optional rich presence | When enabled and Discord is running |

The default background is offline. The retired built-in wallpaper provider migrates to No background without changing the numeric IDs of other saved settings. Empty custom image URLs, missing local images, and resetting background settings also select No background.

Community chat, video site, regional app store, external documentation portal, and cloud-host advertising links have been removed from the interface. Project, documentation, license, and supported-host links open in the external browser only when clicked.

## Build dependencies

The dependency setup scripts download pinned release `v15` from `moonlight-stream/moonlight-qt-deps` on GitHub. Qt comes from the Qt project's distribution infrastructure. Source dependencies are Git submodules listed in `.gitmodules`; Git pins their revisions. Platform workflows also use GitHub, VideoLAN, LunarG, and platform package managers.

The V+ fork of `moonlight-common-c` is retained because the client uses its protocol extensions. Replacing it with upstream Moonlight's library without adapting the client would remove features or break the build. Its code is fetched from GitHub and compiled into the application; it is not a hosted streaming service. The same distinction applies to the optional USB helper libraries.

This inventory covers first-party runtime URLs, dependency setup, submodule declarations, and build workflows. It is not a full audit of every third-party library or a guarantee about all network traffic. Licenses and acknowledgements are retained in [NOTICE.md](../NOTICE.md).
