cmake_minimum_required(VERSION 3.28)

project(orca
    VERSION 0.5.0
    DESCRIPTION "Local-files-first music library and player"
    LANGUAGES C CXX
)

set(ORCA_VERSION_STRING "0.5.0-dev")

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_CXX_SCAN_FOR_MODULES OFF)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

option(ORCA_BUILD_TESTS "Build the test suite" ON)
option(ORCA_BUILD_FUZZERS "Build libFuzzer targets (requires Clang)" OFF)
option(ORCA_EMBEDDINGS "Build with ONNX Runtime embedding support" ON)

include(Warnings)
include(Sanitizers)
include(Fuzzing)
include(Dependencies)

add_subdirectory(liborca)

if(ORCA_BUILD_TESTS)
    enable_testing()
endif()

add_subdirectory(tests)
