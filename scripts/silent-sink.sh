#!/usr/bin/env bash
#
# Print the orca device id of a silent PipeWire sink, creating it if needed.
#
# Playback tests need a real negotiated stream -- quantum negotiation, render
# callbacks, underrun accounting -- but they do not need to be audible, and
# this machine is somebody's desk. A support.null-audio-sink node is a real
# PipeWire sink that consumes audio in real time and discards it, so the whole
# render path is exercised faithfully and nothing reaches a speaker.
#
# Usage:
#   device=$(scripts/silent-sink.sh)
#   zig build run -- play fixtures/audio/generated-reference.flac "$device"
#
# Pass an index for a second, distinct silent sink. Multi-zone and device
# attach tests need two different outputs, and reaching for real hardware to
# get the second one is exactly what this script exists to avoid:
#
#   zone_a=$(scripts/silent-sink.sh 1)
#   zone_b=$(scripts/silent-sink.sh 2)
#
# The node is created with object.linger=true, so it survives this script and
# every later run reuses it. It does not survive a PipeWire restart or a
# reboot; this script simply recreates it when that happens.
#
# Note the id printed here is orca's device id, which is NOT the PipeWire node
# id -- liborca's enumeration numbers devices itself. Always resolve it through
# `orca-cli devices` (as this script does) rather than through pw-dump.

set -euo pipefail

index="${1:-1}"
case "$index" in
    1) suffix=""  ; label="" ;;
    [0-9]*) suffix="-$index"; label=" $index" ;;
    *) echo "silent-sink: index must be a number" >&2; exit 2 ;;
esac

sink_name="orca-null-sink${suffix}"
sink_description="Orca Silent Test Sink${label}"
orca_cli="${ORCA_CLI:-zig-out/bin/orca-cli}"

sink_node_exists() {
    pw-dump 2>/dev/null | python3 -c '
import json, sys
nodes = json.load(sys.stdin)
name = sys.argv[1]
sys.exit(0 if any(
    (((n.get("info") or {}).get("props") or {}).get("node.name") == name)
    for n in nodes
) else 1)
' "$sink_name"
}

if ! sink_node_exists; then
    pw-cli create-node adapter "{
        factory.name=support.null-audio-sink
        node.name=$sink_name
        node.description=\"$sink_description\"
        media.class=Audio/Sink
        object.linger=true
        audio.position=[FL,FR]
    }" >/dev/null
fi

if [ ! -x "$orca_cli" ]; then
    echo "silent-sink: $orca_cli not built -- run 'zig build' first" >&2
    exit 1
fi

# The node registers asynchronously, so give enumeration a few tries before
# declaring it absent.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    device_id=$("$orca_cli" devices 2>/dev/null \
        | awk -F'\t' -v want="$sink_description" '$2 == want { print $1; exit }')
    if [ -n "${device_id:-}" ]; then
        echo "$device_id"
        exit 0
    fi
    python3 -c 'import time; time.sleep(0.2)'
done

echo "silent-sink: created the sink but orca-cli devices never listed it" >&2
exit 1
