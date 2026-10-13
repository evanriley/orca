#include "orca.h"

static_assert(sizeof(orca_handle) == 8, "orca_handle is a 64-bit id");

extern "C" int orca_cpp_header_smoke(void) {
    orca_radio_options options{};
    orca_release_view release{};
    orca_status status = ORCA_STATUS_OK;
    return static_cast<int>(options.familiarity) + static_cast<int>(release.explicit_) +
           static_cast<int>(status) +
           static_cast<int>(orca_version()[0]);
}
