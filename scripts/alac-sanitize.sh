#!/usr/bin/env bash
# Build the ALAC decoder and shim with AddressSanitizer and
# UndefinedBehaviorSanitizer, then decode every seed in fixtures/fuzz/alac/.
# Run inside `nix develop` so cc/c++ are on PATH. A clean exit means no seed
# produced a sanitizer report.
#
# The ALAC fork is a fetched zig dependency, so its sources are read from the
# package tarball in the zig global cache.
#
# Overrides, used to compare against the unmodified upstream sources:
#   ALAC_VENDOR_DIR  directory holding the *.c and ALACDecoder.cpp
#   ALAC_SHIM        path to alac_shim.cpp
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
shim="${ALAC_SHIM:-$root/liborca/codec/alac_shim.cpp}"
header_dir="$root/liborca/codec"
seeds="$root/fixtures/fuzz/alac"
harness="$root/tests/alac_sanitize_harness.c"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -z "${ALAC_VENDOR_DIR:-}" ]; then
    hash="$(sed -n '/\.alac = \.{/,/}/ s/.*\.hash = "\([^"]*\)".*/\1/p' "$root/build.zig.zon")"
    if [ -z "$hash" ]; then
        echo "could not read alac hash from build.zig.zon" >&2
        exit 2
    fi
    cache="$(zig env | sed -n 's/.*"global_cache_dir": "\([^"]*\)".*/\1/p')"
    if [ -z "$cache" ]; then
        cache="$(zig env | sed -n 's/.*\.global_cache_dir = "\([^"]*\)".*/\1/p')"
    fi
    tarball="$cache/p/$hash.tar.gz"
    if [ ! -f "$tarball" ]; then
        zig build --fetch >/dev/null 2>&1 || true
    fi
    if [ ! -f "$tarball" ]; then
        echo "alac package tarball not found at $tarball" >&2
        exit 2
    fi
    tar xzf "$tarball" -C "$work"
    ALAC_VENDOR_DIR="$work/$hash/codec"
fi
vendor="$ALAC_VENDOR_DIR"

san="-fsanitize=address,undefined -fno-sanitize=shift-base -fno-sanitize-recover=all"
common="-g -O1 -DNDEBUG -fwrapv $san -I$vendor -I$header_dir"

objs=()
for src in ag_dec.c ALACBitUtilities.c dp_dec.c EndianPortable.c matrix_dec.c; do
    obj="$work/${src%.c}.o"
    cc -std=c99 $common -c "$vendor/$src" -o "$obj"
    objs+=("$obj")
done

c++ -std=c++11 -fno-exceptions -fno-rtti $common -c "$vendor/ALACDecoder.cpp" -o "$work/ALACDecoder.o"
objs+=("$work/ALACDecoder.o")

c++ -std=c++11 -fno-exceptions -fno-rtti $common -c "$shim" -o "$work/alac_shim.o"
objs+=("$work/alac_shim.o")

cc -std=c99 $common -c "$harness" -o "$work/harness.o"
objs+=("$work/harness.o")

c++ -fsanitize=address,undefined "${objs[@]}" -o "$work/harness"

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
