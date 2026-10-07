#!/usr/bin/env bash
#
# Fail unless orca-cli prints usage to standard error and exits 2 for no
# command, an unknown command or a wrong argument count, and prints it to
# standard output and exits 0 for --help.
#
# Usage:
#   scripts/check-cli-usage.sh zig-out/bin/orca-cli SCRATCH_DIR
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 ORCA_CLI SCRATCH_DIR" >&2
    exit 2
fi
cli=$1
scratch=$2
mkdir -p "$scratch"

expect_usage_failure() {
    local name=$1
    shift
    local status=0
    "$cli" "$@" >"$scratch/stdout" 2>"$scratch/stderr" || status=$?
    if [[ $status -ne 2 ]]; then
        echo "$name: expected exit status 2, got $status" >&2
        exit 1
    fi
    if [[ -s "$scratch/stdout" ]]; then
        echo "$name: expected nothing on standard output" >&2
        exit 1
    fi
    if [[ "$(head -c 6 "$scratch/stderr")" != "Usage:" ]]; then
        echo "$name: expected usage on standard error, got:" >&2
        cat "$scratch/stderr" >&2
        exit 1
    fi
}

expect_usage_failure "no command"
expect_usage_failure "unknown command" no-such-command
expect_usage_failure "too few arguments" scan "$scratch/library.db"
expect_usage_failure "too many arguments" stats "$scratch/library.db" extra
expect_usage_failure "arguments for a command that takes none" sources extra

status=0
"$cli" --help >"$scratch/stdout" 2>"$scratch/stderr" || status=$?
if [[ $status -ne 0 || -s "$scratch/stderr" || "$(head -c 6 "$scratch/stdout")" != "Usage:" ]]; then
    echo "--help: expected usage on standard output and exit status 0, got status $status" >&2
    exit 1
fi
