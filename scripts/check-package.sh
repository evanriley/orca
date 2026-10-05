#!/usr/bin/env bash
#
# Fail unless the Zig package that build.zig.zon's .paths describes builds on
# its own: examples/embed builds against it as a URL dependency, and a
# standalone install from it succeeds.
#
# Usage:
#   scripts/check-package.sh ZIG SOURCE_ROOT VERSION [SEED_PACKAGE...]
set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "usage: $0 ZIG SOURCE_ROOT VERSION [SEED_PACKAGE...]" >&2
    exit 2
fi
zig=$1
root=$2
version=$3
shift 3

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cache=$work/cache
mkdir -p "$cache/p"
for seed in "$@"; do
    if [[ -f $seed ]]; then
        cp "$seed" "$cache/p/"
    fi
done

if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "check-package: $root is not a git work tree; run from a git checkout" >&2
    exit 1
fi
git -C "$root" ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' file; do
        if [[ -e $root/$file ]]; then
            printf '%s\0' "$file"
        fi
    done >"$work/files"
tar -C "$root" --null -T "$work/files" --transform 's,^,orca/,' -czf "$work/orca.tar.gz"

consumer=$work/consumer
mkdir "$consumer"
cp "$root/examples/embed/build.zig" "$root/examples/embed/main.zig" "$consumer/"
sed '/\.orca = /d' "$root/examples/embed/build.zig.zon" >"$consumer/build.zig.zon"
(cd "$consumer" && "$zig" fetch --global-cache-dir "$cache" --save-exact=orca "file://$work/orca.tar.gz")
if grep -q '\.path = ' "$consumer/build.zig.zon"; then
    echo "check-package: examples/embed/build.zig.zon still has a path dependency after its .orca line was removed; update this script to match it" >&2
    exit 1
fi
rm -rf "$consumer/zig-pkg" "$cache/p"/orca-*
(cd "$consumer" && "$zig" build --global-cache-dir "$cache")

packages=("$consumer"/zig-pkg/orca-*)
if [[ ${#packages[@]} -ne 1 || ! -d ${packages[0]} ]]; then
    echo "check-package: expected one fetched orca package in $consumer/zig-pkg" >&2
    exit 1
fi
(cd "${packages[0]}" && "$zig" build --global-cache-dir "$cache" --prefix "$work/prefix")

reported=$("$work/prefix/bin/orca-cli" --version)
if [[ $reported != "orca-cli $version" ]]; then
    echo "check-package: orca-cli --version printed '$reported'; expected 'orca-cli $version'" >&2
    exit 1
fi
