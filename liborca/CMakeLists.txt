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
    metadata/artwork.cpp
    metadata/id3v1.cpp
    metadata/id3v2.cpp
    metadata/image_header.cpp
    metadata/lrc.cpp
    metadata/lyrics.cpp
    metadata/genre_alias.cpp
    metadata/model.cpp
    metadata/riff_tags.cpp
    metadata/mp4_tags.cpp
    metadata/ogg_comment.cpp
    metadata/vorbis_comment.cpp
    http/client.cpp
    http/curl_transport.cpp
    codec/aac.cpp
    codec/adts.cpp
    codec/aiff.cpp
    codec/alac.cpp
    codec/decoder.cpp
    codec/flac.cpp
    codec/mp3.cpp
    codec/mp4.cpp
    codec/opus.cpp
    codec/qoa.cpp
    codec/registry.cpp
    codec/vorbis.cpp
    codec/wav.cpp
    storage/content_hash.cpp
    storage/format.cpp
    storage/iso_bmff.cpp
    storage/quick_hash.cpp
    storage/source.cpp
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
        orca_aac_shim
        orca_alac_shim
        orca_flac_shim
        orca_mp3_shim
        orca_opus_shim
        orca_qoa_shim
        orca_vorbis_shim
        orca_warnings
        orca_sanitizers
        PkgConfig::LIBCURL
)
