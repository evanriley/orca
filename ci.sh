#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

case "${1:-}" in
  fmt)
    nix --accept-flake-config develop -c zig fmt --check liborca apps benchmarks tests build build.zig
    ;;
  test)
    nix --accept-flake-config develop -c scripts/headless-audio.sh zig build install test bench-build embed-example fuzz
    ;;
  package)
    nix --accept-flake-config develop -c zig build package-check
    ;;
  *)
    echo "unknown phase '$1': expected fmt, test or package" >&2
    exit 2
    ;;
esac
