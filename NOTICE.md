# Acknowledgements and third-party notices

This fork is based on [Moonlight V+ by qiin2333 and AlkaidLab](https://github.com/qiin2333/moonlight-qt), which is based on [Moonlight Qt](https://github.com/moonlight-stream/moonlight-qt). Their contributors retain copyright in their work. The application is distributed under the [GNU GPLv3](LICENSE).

Source submodules are pinned to the commits recorded by Git. Their own license files govern their use:

- `moonlight-common-c/moonlight-common-c`: the Moonlight streaming library and V+ protocol extensions.
- `qmdnsengine/qmdnsengine`: local network service discovery.
- `app/SDL_GameControllerDB`: controller mappings.
- `third-party/AMF`: AMD media interfaces.
- `usb-helper/third_party/usbipdcpp`, `libusb`, `asio`, and `spdlog`: optional USB forwarding components.

This product uses usbipdcpp (https://github.com/yunsmall/usbipdcpp), licensed under LGPLv3. The helper's source and build instructions are in [usb-helper](usb-helper/README.md).

Bundled Manrope and DM Mono fonts retain their SIL Open Font License files in `app/res/fonts`. Fluent icons retain their MIT license in `app/res/fluent`. Prebuilt dependencies from Moonlight's dependency releases include their upstream license notices; packaging must retain them. This list does not replace the licenses distributed with each component.
