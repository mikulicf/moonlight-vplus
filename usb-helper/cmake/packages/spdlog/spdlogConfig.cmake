# Minimal header-only spdlog config for find_package(spdlog CONFIG).
# No linked library is needed without SPDLOG_COMPILED_LIB.
add_library(spdlog::spdlog INTERFACE IMPORTED)
set_target_properties(spdlog::spdlog PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_LIST_DIR}/../../../third_party/spdlog/include")
