#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

case "${1:-}" in
  fmt)
    nix --accept-flake-config develop -c zig fmt --check liborca apps benchmarks tests build build.zig
    ;;
  test)
    nix --accept-flake-config develop -c zig build
    nix --accept-flake-config develop -c scripts/headless-audio.sh zig build test bench-build embed-example
    nix --accept-flake-config develop -c zig build fuzz
    ;;
  package)
    nix --accept-flake-config develop -c zig build package-check
    ;;
  nix)
    nix --accept-flake-config flake check -L .
    ;;
  *)
    echo "unknown phase '$1': expected fmt, test, package or nix" >&2
    exit 2
    ;;
esac
