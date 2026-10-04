#!/usr/bin/env bash
#
# Fail unless orca-cli writes standard output and standard error at the file's
# current offset, so output redirected to a file follows what is already there.
#
# Usage:
#   scripts/check-cli-stdio.sh zig-out/bin/orca-cli SCRATCH_DIR
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 ORCA_CLI SCRATCH_DIR" >&2
    exit 2
fi
cli=$1
scratch=$2
mkdir -p "$scratch"

expect() {
    local name=$1 file=$2 expected=$3
    if [[ "$(cat "$file")" != "$expected" ]]; then
        echo "$name: expected:" >&2
        printf '%s\n' "$expected" >&2
        echo "got:" >&2
        cat "$file" >&2
        exit 1
    fi
}

version=$("$cli" --version)

{ echo header; "$cli" --version; } >"$scratch/stdout"
expect "stdout after a header" "$scratch/stdout" "header
$version"

echo existing >"$scratch/append"
"$cli" --version >>"$scratch/append"
expect "stdout appended" "$scratch/append" "existing
$version"

{ echo header >&2; "$cli" stats "$scratch/missing/library.db" || true; } 2>"$scratch/stderr"
expect "stderr after a header" "$scratch/stderr" "header
orca-cli: could not open the database"
