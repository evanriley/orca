if(ORCA_BUILD_TESTS)
    add_executable(orca_tests
        doctest_main.cpp
        base_test.cpp
        crypto_test.cpp
        json_test.cpp
        http_test.cpp
    )

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
