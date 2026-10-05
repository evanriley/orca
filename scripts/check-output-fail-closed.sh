#!/usr/bin/env bash
#
# Check that an explicitly selected output device fails closed: when it is
# missing at open or disappears while playing, orca-cli reports the output as
# failed and its stream is never linked to any other sink. Device 0 must still
# follow the server default.
#
# The check creates and removes sinks, so it runs only inside the private
# server that scripts/headless-audio.sh starts, and skips anywhere else:
#
#   scripts/headless-audio.sh scripts/check-output-fail-closed.sh zig-out/bin/orca-cli SCRATCH_DIR
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 ORCA_CLI SCRATCH_DIR" >&2
    exit 2
fi
cli=$1
scratch=$2

runtime=${XDG_RUNTIME_DIR:-}
if [[ -z "${ORCA_PRIVATE_AUDIO:-}" || "$ORCA_PRIVATE_AUDIO" != "$runtime" ||
    "$runtime" != /tmp/orca-audio.* || -n "${PIPEWIRE_REMOTE:-}" ]]; then
    echo "check-output-fail-closed: skipped; run it under scripts/headless-audio.sh"
    exit 0
fi
[[ -S "$runtime/pipewire-0" ]] || {
    echo "check-output-fail-closed: no private PipeWire socket in $runtime" >&2
    exit 1
}

mkdir -p "$scratch"
audio=$scratch/silence.wav
python3 - "$audio" <<'EOF'
import sys, wave
with wave.open(sys.argv[1], "wb") as out:
    out.setnchannels(2)
    out.setsampwidth(2)
    out.setframerate(48000)
    out.writeframes(bytes(4 * 48000 * 4))
EOF

sink_a=orca-fail-closed-a
sink_b=orca-fail-closed-b
missing_id=999999999

fail() {
    echo "check-output-fail-closed: $*" >&2
    exit 1
}

node_id() {
    pw-dump 2>/dev/null | python3 -c '
import json, sys
for node in json.load(sys.stdin):
    props = (node.get("info") or {}).get("props") or {}
    if node.get("type") == "PipeWire:Interface:Node" and props.get("node.name") == sys.argv[1]:
        print(node["id"])
        break
' "$1"
}

create_sink() {
    pw-cli create-node adapter "{
        factory.name=support.null-audio-sink
        node.name=$1
        node.description=$1
        media.class=Audio/Sink
        object.linger=true
        audio.position=[FL,FR]
    }" >/dev/null
}

device_id() {
    "$cli" devices 2>/dev/null | awk -F'\t' -v want="$1" '$2 == want { print $1; exit }'
}

await_device() {
    local want=$1 present=$2 id
    for _ in $(seq 50); do
        id=$(device_id "$want")
        if [[ "$present" == yes && -n "$id" ]]; then
            echo "$id"
            return 0
        fi
        [[ "$present" == no && -z "$id" ]] && return 0
        sleep 0.1
    done
    fail "device $want never became present=$present"
}

remove_sink() {
    local id
    id=$(node_id "$1")
    [[ -n "$id" ]] || fail "sink $1 is not present to remove"
    pw-cli destroy "$id" >/dev/null
}

orca_links() {
    pw-dump 2>/dev/null | python3 -c '
import json, sys
objects = json.load(sys.stdin)
names = {}
for item in objects:
    if item.get("type") == "PipeWire:Interface:Node":
        names[item["id"]] = ((item.get("info") or {}).get("props") or {}).get("node.name")
orca = {id for id, name in names.items() if name == "Orca"}
for item in objects:
    if item.get("type") != "PipeWire:Interface:Link":
        continue
    info = item.get("info") or {}
    if info.get("output-node-id") in orca:
        print(names.get(info.get("input-node-id"), "?"))
'
}

samples=0
run_play() {
    local name=$1 device=$2 action=${3:-}
    local out=$scratch/$name.out seen=$scratch/$name.seen status=0 pid acted=no
    : >"$seen"
    samples=0
    timeout 30 "$cli" play "$audio" "$device" >"$out" 2>&1 &
    pid=$!
    while ps -p "$pid" >/dev/null; do
        orca_links >>"$seen"
        samples=$((samples + 1))
        if [[ -n "$action" && "$acted" == no ]] && grep -qx "$sink_b" "$seen"; then
            "$action"
            acted=yes
        fi
        sleep 0.05
    done
    wait "$pid" || status=$?
    echo "$status" >"$scratch/$name.status"
    if [[ -n "$action" && "$acted" == no ]]; then
        fail "$name: never saw Orca linked to $sink_b; play output: $(cat "$out")"
    fi
}

expect_failed_closed() {
    local name=$1 status
    status=$(cat "$scratch/$name.status")
    if grep -qx "$sink_a" "$scratch/$name.seen"; then
        fail "$name: Orca's stream was linked to the default sink $sink_a ($samples samples); play exited $status: $(cat "$scratch/$name.out")"
    fi
    [[ "$status" != 0 && "$status" != 124 ]] ||
        fail "$name: play exited $status instead of reporting the lost output: $(cat "$scratch/$name.out")"
    echo "check-output-fail-closed: $name: ok, exit $status after $samples link samples, never linked to $sink_a: $(tail -n 1 "$scratch/$name.out")"
}

create_sink "$sink_a"
create_sink "$sink_b"
await_device "$sink_a" yes >/dev/null
id_b=$(await_device "$sink_b" yes)
wpctl set-default "$(node_id "$sink_a")"

remove_sink "$sink_b"
await_device "$sink_b" no
run_play a-removed-before-open "$id_b"
expect_failed_closed a-removed-before-open

create_sink "$sink_b"
id_b=$(await_device "$sink_b" yes)
remove_b() { remove_sink "$sink_b"; }
run_play b-removed-while-playing "$id_b" remove_b
expect_failed_closed b-removed-while-playing

expect_played_on_a() {
    local name=$1 status
    status=$(cat "$scratch/$name.status")
    [[ "$status" == 0 ]] || fail "$name: play exited $status: $(cat "$scratch/$name.out")"
    grep -qx "$sink_a" "$scratch/$name.seen" ||
        fail "$name: Orca's stream was never linked to $sink_a"
    echo "check-output-fail-closed: $name: ok, linked to $sink_a: $(tail -n 1 "$scratch/$name.out")"
}

run_play c-default 0
expect_played_on_a c-default

run_play c-explicit-default "$(device_id "$sink_a")"
expect_played_on_a c-explicit-default

"$cli" devices | awk -F'\t' -v id="$missing_id" '$1 == id { exit 1 }' || fail "device $missing_id unexpectedly exists"
run_play d-never-existed "$missing_id"
expect_failed_closed d-never-existed
