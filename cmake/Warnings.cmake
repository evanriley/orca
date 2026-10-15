add_library(orca_warnings INTERFACE)

target_compile_options(orca_warnings INTERFACE
    -Wall
    -Wextra
    -Werror
    -Wshadow
    -Wconversion
    -Wcast-align
    -Wformat=2
)
