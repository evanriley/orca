#!/usr/bin/env bash
# Build the libxaac AAC decoder and shim with AddressSanitizer and
# UndefinedBehaviorSanitizer, then decode every seed in fixtures/fuzz/aac/.
# Run inside `nix develop` so cc/c++ are on PATH. A clean exit means no seed
# produced a sanitizer report.
#
# libxaac is a CMake FetchContent dependency; its sources live under
# build/debug/_deps/libxaac-src after configure. The file list is taken from
# cmake/Dependencies.cmake so the two cannot drift. libxaac translation units
# build with UBSan disabled (the engine builds them the same way); the shim and
# harness build with both sanitizers.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
header_dir="$root/liborca/codec"
shim="$root/liborca/codec/aac_shim.c"
seeds="$root/fixtures/fuzz/aac"
harness="$root/tests/aac_sanitize_harness.c"

vendor="$root/build/debug/_deps/libxaac-src"
if [ ! -d "$vendor" ]; then
    (cd "$root" && cmake --preset debug >/dev/null)
fi
if [ ! -d "$vendor" ]; then
    echo "libxaac sources not found at $vendor" >&2
    exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

san="-fsanitize=address,undefined -fno-sanitize-recover=all"
includes="-I$vendor/common -I$vendor/decoder -I$vendor/decoder/drc_src -I$header_dir"
base="-g -O1 -DNDEBUG -DLOUDNESS_LEVELING_SUPPORT -fwrapv $includes"

# libxaac translation units: AddressSanitizer on, UBSan off, warnings silenced.
lib_flags="-std=gnu99 -w -fsanitize=address -fno-sanitize-recover=all $base"

objs=()
while IFS= read -r src; do
    obj="$work/$(echo "$src" | tr '/' '_').o"
    cc $lib_flags -c "$vendor/$src" -o "$obj"
    objs+=("$obj")
done < <(sed -n 's#.*"${libxaac_SOURCE_DIR}/\([^"]*\.c\)".*#\1#p' "$root/cmake/Dependencies.cmake")

if [ "${#objs[@]}" -eq 0 ]; then
    echo "no libxaac sources parsed from cmake/Dependencies.cmake" >&2
    exit 2
fi

cc -std=gnu99 $san $base -c "$shim" -o "$work/aac_shim.o"
objs+=("$work/aac_shim.o")

cc -std=c99 $san $base -c "$harness" -o "$work/harness.o"
objs+=("$work/harness.o")

cc -fsanitize=address,undefined "${objs[@]}" -o "$work/harness" -lm

status=0
for seed in "$seeds"/*.bin; do
    name="$(basename "$seed")"
    if out="$("$work/harness" "$seed" 2>&1)"; then
        printf '%-28s %s\n' "$name" "$out"
    else
        status=$?
        printf '%-28s REPORT (exit %d)\n%s\n' "$name" "$status" "$out"
    fi
done

exit "$status"
