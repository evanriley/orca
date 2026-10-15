set(ORCA_FUZZER_FLAGS -fsanitize=fuzzer,address -fno-omit-frame-pointer)

function(orca_add_fuzzer target source)
    if(NOT ORCA_BUILD_FUZZERS)
        return()
    endif()

    if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        message(FATAL_ERROR "ORCA_BUILD_FUZZERS requires Clang, got '${CMAKE_CXX_COMPILER_ID}'")
    endif()

    add_executable(${target} ${source})
    target_link_libraries(${target} PRIVATE orca orca_warnings)
    target_compile_options(${target} PRIVATE ${ORCA_FUZZER_FLAGS})
    target_link_options(${target} PRIVATE ${ORCA_FUZZER_FLAGS})
endfunction()
