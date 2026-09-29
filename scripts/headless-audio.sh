#!/usr/bin/env bash
#
# Run a command against a private PipeWire and WirePlumber.
#
# The C ABI smoke test opens a real output, so `zig build test` needs an audio
# server. CI has none, and a desktop's own server leads to real hardware. This
# script starts a throwaway PipeWire with WirePlumber in a fresh runtime
# directory, with every hardware monitor disabled, runs the command there and
# tears both down on exit. The user's audio server is never contacted.
#
# Usage:
#   scripts/headless-audio.sh zig build test
#
# WirePlumber is required: bare PipeWire accepts the stream but never links
# it, and the smoke test fails with its output active but silent.

set -euo pipefail

if [ "$#" -eq 0 ]; then
    echo "headless-audio: usage: $0 CMD [ARGS...]" >&2
    exit 2
fi

# PipeWire's socket path must fit in sockaddr_un's 108 bytes, and TMPDIR can be long.
runtime=$(mktemp -d /tmp/orca-audio.XXXXXX)
chmod 700 "$runtime"
pipewire_pid=""
wireplumber_pid=""

cleanup() {
    for pid in "$wireplumber_pid" "$pipewire_pid"; do
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    rm -rf "$runtime"
}
trap cleanup EXIT

export XDG_RUNTIME_DIR="$runtime"
export XDG_CONFIG_HOME="$runtime/config"
export XDG_STATE_HOME="$runtime/state"
unset PIPEWIRE_REMOTE DBUS_SESSION_BUS_ADDRESS

mkdir -p "$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d"
cat >"$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d/headless.conf" <<'EOF'
wireplumber.profiles = {
  main = {
    monitor.alsa = disabled
    monitor.alsa-midi = disabled
    monitor.bluez = disabled
    monitor.bluez-midi = disabled
    monitor.v4l2 = disabled
    monitor.libcamera = disabled
    support.dbus = disabled
    support.reserve-device = disabled
    support.portal-permissionstore = disabled
  }
}
EOF

fail() {
    echo "headless-audio: $1" >&2
    tail -n 20 "$2" >&2 || true
    exit 1
}

pipewire >"$runtime/pipewire.log" 2>&1 &
pipewire_pid=$!
for _ in $(seq 50); do
    [ -S "$XDG_RUNTIME_DIR/pipewire-0" ] && break
    sleep 0.1
done
[ -S "$XDG_RUNTIME_DIR/pipewire-0" ] \
    || fail "pipewire did not create its socket within 5 s; its log ends:" "$runtime/pipewire.log"

wireplumber_connected() {
    pw-dump 2>/dev/null | grep -q '"application.name": "WirePlumber"'
}

wireplumber >"$runtime/wireplumber.log" 2>&1 &
wireplumber_pid=$!
for _ in $(seq 50); do
    wireplumber_connected && break
    sleep 0.1
done
wireplumber_connected \
    || fail "wireplumber did not connect to pipewire within 5 s; its log ends:" "$runtime/wireplumber.log"

"$@"
