#!/usr/bin/env bash
#
# Fail unless the shared liborca exports exactly the functions orca.h declares.
#
# Usage:
#   scripts/check-exports.sh zig-out/lib/liborca.so liborca/orca.h
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 LIBORCA_SO ORCA_H" >&2
    exit 2
fi
library=$1
header=$2

exported=$(nm -D --defined-only --extern-only "$library" | awk '{ print $NF }' | sort -u)
declared=$(grep -E '^[A-Za-z_]' "$header" | grep -v '^typedef' |
    grep -oE '\borca_[A-Za-z0-9_]+\(' | tr -d '(' | sort -u)

undeclared=$(comm -23 <(printf '%s\n' "$exported") <(printf '%s\n' "$declared"))
missing=$(comm -13 <(printf '%s\n' "$exported") <(printf '%s\n' "$declared"))

if [[ -n $undeclared || -n $missing ]]; then
    echo "$library does not export exactly the functions $header declares." >&2
    if [[ -n $undeclared ]]; then
        echo "Exported but not declared (add them to orca.h or stop exporting them):" >&2
        printf '  %s\n' $undeclared >&2
    fi
    if [[ -n $missing ]]; then
        echo "Declared but not exported (implement them in liborca/c_api.zig):" >&2
        printf '  %s\n' $missing >&2
    fi
    exit 1
fi
