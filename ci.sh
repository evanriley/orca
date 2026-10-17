#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

cache_max_age_days=7
scratch=""

prepare_buildkite() {
  [ "${BUILDKITE:-}" = true ] || return 0

  if [ -z "${ZIG_LOCAL_CACHE_DIR:-}" ]; then
    : "${BUILDKITE_AGENT_NAME:?ci.sh: BUILDKITE_AGENT_NAME is unset; expected the Buildkite agent name to key the Zig cache}"
    local cache="${XDG_CACHE_HOME:-$HOME/.cache}/orca-ci/$BUILDKITE_AGENT_NAME"
    if [ -d "$cache" ] && [ -z "$(find "$cache/.stamp" -mtime "-$cache_max_age_days" 2>/dev/null)" ]; then
      rm -rf "$cache"
    fi
    mkdir -p "$cache"
    [ -e "$cache/.stamp" ] || touch "$cache/.stamp"
    export ZIG_LOCAL_CACHE_DIR="$cache"
  fi

  mkdir -p "$ZIG_LOCAL_CACHE_DIR"
  if [ "$(realpath -m "$ZIG_LOCAL_CACHE_DIR")" = "$(realpath -m .zig-cache)" ]; then
    echo "ci.sh: ZIG_LOCAL_CACHE_DIR resolves to $PWD/.zig-cache; expected a directory outside the checkout, because .zig-cache/tmp becomes a tmpfs symlink. Unset ZIG_LOCAL_CACHE_DIR or point it elsewhere." >&2
    exit 1
  fi

  scratch=$(mktemp -d /dev/shm/orca-test.XXXXXX)
  trap 'rm -rf "$scratch" .zig-cache/tmp' EXIT
  mkdir "$scratch/tmp" "$scratch/tmpdir"
  mkdir -p .zig-cache
  rm -rf .zig-cache/tmp
  ln -s "$scratch/tmp" .zig-cache/tmp
  export TMPDIR="$scratch/tmpdir"
}

case "${1:-}" in
  fmt)
    nix --accept-flake-config develop -c zig fmt --check liborca apps benchmarks tests build build.zig
    ;;
  test)
    prepare_buildkite
    nix --accept-flake-config develop -c scripts/headless-audio.sh zig build install test bench-build embed-example fuzz
    ;;
  package)
    prepare_buildkite
    nix --accept-flake-config develop -c zig build package-check
    ;;
  *)
    echo "unknown phase '$1': expected fmt, test or package" >&2
    exit 2
    ;;
esac
