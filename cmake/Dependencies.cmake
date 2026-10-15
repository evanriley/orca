include(FetchContent)

find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBCURL REQUIRED IMPORTED_TARGET libcurl)

FetchContent_Declare(yyjson
    GIT_REPOSITORY https://github.com/ibireme/yyjson.git
    GIT_TAG 6447536015f3d600f3d65323b10976103b337ca7
    GIT_SHALLOW FALSE
    SOURCE_SUBDIR src
)

FetchContent_Declare(blake3
    GIT_REPOSITORY https://github.com/BLAKE3-team/BLAKE3.git
    GIT_TAG f3149ec5bb5449af877ba20377a11008ff499fa2
    GIT_SHALLOW FALSE
)

FetchContent_Declare(sha2
    GIT_REPOSITORY https://github.com/amosnier/sha-2.git
    GIT_TAG 565f65009bdd98267361b17d50cddd7c9beb3e6c
    GIT_SHALLOW FALSE
)

FetchContent_Declare(doctest
    GIT_REPOSITORY https://github.com/doctest/doctest.git
    GIT_TAG 2d0a9359a60c51affe2a9bebb1be1dca47868151
    GIT_SHALLOW FALSE
    SOURCE_SUBDIR doctest
)

FetchContent_MakeAvailable(yyjson blake3 sha2 doctest)

add_library(orca_yyjson STATIC "${yyjson_SOURCE_DIR}/src/yyjson.c")
target_compile_definitions(orca_yyjson PRIVATE YYJSON_DISABLE_FILE)
target_include_directories(orca_yyjson SYSTEM PUBLIC "${yyjson_SOURCE_DIR}/src")

add_library(orca_blake3 STATIC
    "${blake3_SOURCE_DIR}/c/blake3.c"
    "${blake3_SOURCE_DIR}/c/blake3_dispatch.c"
    "${blake3_SOURCE_DIR}/c/blake3_portable.c"
)
target_compile_definitions(orca_blake3 PRIVATE
    BLAKE3_USE_NEON=0
    BLAKE3_NO_SSE2
    BLAKE3_NO_SSE41
    BLAKE3_NO_AVX2
    BLAKE3_NO_AVX512
)
target_include_directories(orca_blake3 SYSTEM PUBLIC "${blake3_SOURCE_DIR}/c")

add_library(orca_sha256 STATIC "${sha2_SOURCE_DIR}/sha-256.c")
target_include_directories(orca_sha256 SYSTEM PUBLIC "${sha2_SOURCE_DIR}")

add_library(orca_doctest INTERFACE)
target_include_directories(orca_doctest SYSTEM INTERFACE "${doctest_SOURCE_DIR}")
