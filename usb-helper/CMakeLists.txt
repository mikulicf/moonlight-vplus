cmake_minimum_required(VERSION 3.24)
project(moonlight-usbd VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# --- Vendored dependencies: four Git submodules with pinned commits. ---
#
# asio/spdlog provide CMake configs only after installation. Supply minimal
# configs in cmake/packages for source-tree find_package calls.
# Build libusb/usbipdcpp statically through add_subdirectory.
list(APPEND CMAKE_PREFIX_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake/packages")

# libusb 1.0.29 has no CMake build. Compile the Darwin/POSIX sources from Makefile.am
# directly using a config based on Xcode/config.h, avoiding an autotools dependency.
# Generate a libusb-1.0/libusb.h shim for usbipdcpp's Homebrew-style include layout.
set(LIBUSB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/libusb/libusb")
add_library(usb-1.0 STATIC
    "${LIBUSB_DIR}/core.c"
    "${LIBUSB_DIR}/descriptor.c"
    "${LIBUSB_DIR}/hotplug.c"
    "${LIBUSB_DIR}/io.c"
    "${LIBUSB_DIR}/strerror.c"
    "${LIBUSB_DIR}/sync.c"
    "${LIBUSB_DIR}/os/events_posix.c"
    "${LIBUSB_DIR}/os/threads_posix.c"
    "${LIBUSB_DIR}/os/darwin_usb.c")
set_target_properties(usb-1.0 PROPERTIES
    ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
target_include_directories(usb-1.0 PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/third_party/libusb/libusb")
target_include_directories(usb-1.0 PRIVATE "${CMAKE_BINARY_DIR}/libusb-config")
target_compile_options(usb-1.0 PRIVATE -fvisibility=hidden)
target_link_libraries(usb-1.0 PRIVATE objc)
target_link_options(usb-1.0 INTERFACE
    "-framework" "IOKit" "-framework" "CoreFoundation" "-framework" "Security")

configure_file(cmake/libusb-config.h.in
               "${CMAKE_BINARY_DIR}/libusb-config/config.h" COPYONLY)
set(LIBUSB_HEADER_PATH "${LIBUSB_DIR}/libusb.h")
configure_file(cmake/libusb-1.0.h.in
               "${CMAKE_BINARY_DIR}/libusb-shim/libusb-1.0/libusb.h" @ONLY)

# usbipdcpp always discovers libusb through pkg-config. Generate a .pc for our static
# build and isolate discovery with PKG_CONFIG_LIBDIR; PATH ordering alone can still
# select Homebrew's identical-version dylib. Use the archive's absolute path in Libs
# so -lusb-1.0 cannot resolve to a dynamic library elsewhere.
configure_file(cmake/libusb-1.0.pc.in
               "${CMAKE_BINARY_DIR}/pkgconfig/libusb-1.0.pc" @ONLY)
set(ENV{PKG_CONFIG_LIBDIR} "${CMAKE_BINARY_DIR}/pkgconfig")
set(ENV{PKG_CONFIG_PATH} "${CMAKE_BINARY_DIR}/pkgconfig")

set(USBIPDCPP_BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(USBIPDCPP_BUILD_VIRTUAL_DEVICE OFF CACHE BOOL "" FORCE)
set(USBIPDCPP_BUILD_LIBUSB_COMPONENTS ON CACHE BOOL "" FORCE)
set(USBIPDCPP_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(USBIPDCPP_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(third_party/usbipdcpp EXCLUDE_FROM_ALL)

add_executable(moonlight-usbd main.cpp)
target_compile_definitions(moonlight-usbd PRIVATE
    MOONLIGHT_USB_HELPER_VERSION="${PROJECT_VERSION}"
    USBIPDCPP_PINNED_VERSION="1.0.9")
target_link_libraries(moonlight-usbd PRIVATE usbipdcpp_libusb)
