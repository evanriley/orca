set(ORCA_SANITIZER "" CACHE STRING "Sanitizer to enable: address, leak, undefined, thread or empty")
set_property(CACHE ORCA_SANITIZER PROPERTY STRINGS "" address leak undefined thread)

add_library(orca_sanitizers INTERFACE)

if(ORCA_SANITIZER STREQUAL "")
    # No sanitizer requested.
elseif(ORCA_SANITIZER STREQUAL "address")
    set(ORCA_SANITIZER_FLAGS -fsanitize=address -fno-omit-frame-pointer)
elseif(ORCA_SANITIZER STREQUAL "leak")
    set(ORCA_SANITIZER_FLAGS -fsanitize=leak -fno-omit-frame-pointer)
elseif(ORCA_SANITIZER STREQUAL "undefined")
    set(ORCA_SANITIZER_FLAGS -fsanitize=undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
elseif(ORCA_SANITIZER STREQUAL "thread")
    set(ORCA_SANITIZER_FLAGS -fsanitize=thread -fno-omit-frame-pointer)
else()
    message(FATAL_ERROR "Unknown ORCA_SANITIZER: '${ORCA_SANITIZER}'")
endif()

if(DEFINED ORCA_SANITIZER_FLAGS)
    target_compile_options(orca_sanitizers INTERFACE ${ORCA_SANITIZER_FLAGS})
    target_link_options(orca_sanitizers INTERFACE ${ORCA_SANITIZER_FLAGS})
endif()
