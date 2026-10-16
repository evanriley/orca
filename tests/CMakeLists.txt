if(ORCA_BUILD_TESTS)
    add_executable(orca_tests
        doctest_main.cpp
        base_test.cpp
        crypto_test.cpp
        json_test.cpp
        http_test.cpp
        storage_test.cpp
        metadata_model_test.cpp
        metadata_id3v1_test.cpp
        metadata_id3v2_test.cpp
        metadata_vorbis_comment_test.cpp
        metadata_ogg_comment_test.cpp
        metadata_mp4_tags_test.cpp
        metadata_riff_tags_test.cpp
        metadata_genre_alias_test.cpp
        metadata_image_header_test.cpp
        metadata_lrc_test.cpp
        metadata_lyrics_test.cpp
        metadata_artwork_test.cpp
        codec_test.cpp
        codec_lib_test.cpp
        codec_mp4_test.cpp
    )

    target_compile_definitions(orca_tests PRIVATE ORCA_SOURCE_DIR="${PROJECT_SOURCE_DIR}")

    target_link_libraries(orca_tests
        PRIVATE
            orca
            orca_warnings
            orca_sanitizers
            orca_doctest
    )

    if(COMMAND doctest_discover_tests)
        doctest_discover_tests(orca_tests)
    else()
        add_test(NAME orca_tests COMMAND orca_tests)
    endif()
endif()

orca_add_fuzzer(orca_fuzz_checked fuzz/checked_fuzz.cpp)
orca_add_fuzzer(orca_fuzz_format fuzz/format_fuzz.cpp)
orca_add_fuzzer(orca_fuzz_iso_bmff fuzz/iso_bmff_fuzz.cpp)
orca_add_fuzzer(orca_fuzz_codec fuzz/codec_fuzz.cpp)
orca_add_fuzzer(orca_fuzz_flac_header fuzz/flac_header_fuzz.cpp)
orca_add_fuzzer(orca_fuzz_mp4 fuzz/mp4_fuzz.cpp)
orca_add_fuzzer(orca_fuzz_adts fuzz/adts_fuzz.cpp)
orca_add_fuzzer(orca_fuzz_id3v1 fuzz/id3v1_fuzz.cpp)
orca_add_fuzzer(orca_fuzz_id3v2 fuzz/id3v2_fuzz.cpp)
orca_add_fuzzer(orca_fuzz_vorbis_comment fuzz/vorbis_comment_fuzz.cpp)
orca_add_fuzzer(orca_fuzz_ogg_comment fuzz/ogg_comment_fuzz.cpp)
orca_add_fuzzer(orca_fuzz_lrc fuzz/lrc_fuzz.cpp)
orca_add_fuzzer(orca_fuzz_image_header fuzz/image_header_fuzz.cpp)
orca_add_fuzzer(orca_fuzz_mp4_tags fuzz/mp4_tags_fuzz.cpp)
orca_add_fuzzer(orca_fuzz_riff_tags fuzz/riff_tags_fuzz.cpp)
