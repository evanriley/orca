#!/usr/bin/env bash
# Build the libxaac AAC decoder and shim with AddressSanitizer and
# UndefinedBehaviorSanitizer, then decode every seed in fixtures/fuzz/aac/.
# Run inside `nix develop` so cc/c++ and zig are on PATH. A clean exit means no
# seed produced a sanitizer report.
#
# libxaac is a fetched zig dependency rather than a vendored tree, so its
# sources are read from the package tarball in the zig global cache. The file
# list, include paths and base flags are taken from build/libxaac.zig so the two
# cannot drift. libxaac translation units build with UBSan disabled (the engine
# builds them the same way); the shim and harness build with both sanitizers.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
header_dir="$root/liborca/codec"
shim="$root/liborca/codec/aac_shim.c"
seeds="$root/fixtures/fuzz/aac"
harness="$root/tests/aac_sanitize_harness.c"
libxaac_zig="$root/build/libxaac.zig"

hash="$(sed -n '/\.libxaac = \.{/,/}/ s/.*\.hash = "\([^"]*\)".*/\1/p' "$root/build.zig.zon")"
if [ -z "$hash" ]; then
    echo "could not read libxaac hash from build.zig.zon" >&2
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
    echo "libxaac package tarball not found at $tarball" >&2
    exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

tar xzf "$tarball" -C "$work"
vendor="$work/$hash"

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
done < <(sed -n 's/^[[:space:]]*"\(\(common\|decoder\)\/[^"]*\.c\)",.*/\1/p' "$libxaac_zig")

if [ "${#objs[@]}" -eq 0 ]; then
    echo "no libxaac sources parsed from build/libxaac.zig" >&2
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
