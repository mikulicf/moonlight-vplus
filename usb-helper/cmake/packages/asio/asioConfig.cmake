# Minimal asio config for source-tree use. ASIO_STANDALONE avoids Boost;
# an INTERFACE IMPORTED target satisfies usbipdcpp's find_package(asio CONFIG).
add_library(asio::asio INTERFACE IMPORTED)
set_target_properties(asio::asio PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_LIST_DIR}/../../../third_party/asio/asio/include"
    INTERFACE_COMPILE_DEFINITIONS "ASIO_STANDALONE")
