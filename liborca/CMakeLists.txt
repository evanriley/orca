add_library(orca STATIC
    base/error.cpp
    base/logging.cpp
    base/path.cpp
    base/string.cpp
    base/time.cpp
    crypto/blake3.cpp
    crypto/sha256.cpp
    crypto/secure_zero.cpp
    json/json.cpp
    http/client.cpp
    http/curl_transport.cpp
)
add_library(orca::orca ALIAS orca)

target_compile_features(orca PUBLIC cxx_std_23)

target_include_directories(orca PUBLIC
    $<BUILD_INTERFACE:${PROJECT_SOURCE_DIR}>
)

target_compile_definitions(orca PRIVATE ORCA_VERSION_STRING="${ORCA_VERSION_STRING}")

target_link_libraries(orca
    PUBLIC
        orca_blake3
        orca_sha256
    PRIVATE
        orca_yyjson
        orca_warnings
        orca_sanitizers
        PkgConfig::LIBCURL
)
