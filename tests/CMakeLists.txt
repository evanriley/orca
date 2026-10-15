if(ORCA_BUILD_TESTS)
    add_executable(orca_tests
        doctest_main.cpp
        base_test.cpp
        crypto_test.cpp
        json_test.cpp
        http_test.cpp
        storage_test.cpp
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
