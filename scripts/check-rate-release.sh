#!/usr/bin/env bash
#
# Check that a paused Player releases the graph rate: while Orca holds a
# 44.1 kHz stream paused, a 48 kHz stream starting on the same sink moves the
# graph to 48 kHz. While Orca plays, the graph stays at 44.1 kHz.
#
# The check creates a sink and changes the clock settings, so it runs only
# inside the private server that scripts/headless-audio.sh starts, and skips
# anywhere else:
#
#   scripts/headless-audio.sh scripts/check-rate-release.sh RATE_RELEASE_DRIVER SCRATCH_DIR
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 RATE_RELEASE_DRIVER SCRATCH_DIR" >&2
    exit 2
fi
driver=$1
scratch=$2

runtime=${XDG_RUNTIME_DIR:-}
if [[ -z "${ORCA_PRIVATE_AUDIO:-}" || "$ORCA_PRIVATE_AUDIO" != "$runtime" ||
    "$runtime" != /tmp/orca-audio.* || -n "${PIPEWIRE_REMOTE:-}" ]]; then
    echo "check-rate-release: skipped; run it under scripts/headless-audio.sh"
    exit 0
fi
[[ -S "$runtime/pipewire-0" ]] || {
    echo "check-rate-release: no private PipeWire socket in $runtime" >&2
    exit 1
}

sink=orca-rate-release
orca_rate=44100
other_rate=48000

fail() {
    echo "check-rate-release: $*" >&2
    exit 1
}

mkdir -p "$scratch"
python3 - "$scratch" "$orca_rate" "$other_rate" <<'EOF'
import sys, wave
scratch, orca_rate, other_rate = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
for rate, seconds in ((orca_rate, 60), (other_rate, 12)):
    with wave.open(f"{scratch}/silence-{rate}.wav", "wb") as out:
        out.setnchannels(2)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes(bytes(4 * rate * seconds))
EOF

node_state() {
    pw-dump 2>/dev/null | python3 -c '
import json, sys
for node in json.load(sys.stdin):
    info = node.get("info") or {}
    props = info.get("props") or {}
    if node.get("type") == "PipeWire:Interface:Node" and props.get("node.name") == sys.argv[1]:
        print(info.get("state"))
        break
' "$1"
}

graph_rate() {
    timeout 10 pw-top -b -n 2 2>/dev/null |
        awk -v sink="$sink" '$NF == sink { rate = $4 } END { print (rate == "" ? "-" : rate) }'
}

await_line() {
    local file=$1 want=$2
    for _ in $(seq 100); do
        grep -qx "$want" "$file" && return 0
        sleep 0.1
    done
    fail "the driver never printed '$want': $(cat "$file")"
}

pw-cli create-node adapter "{
    factory.name=support.null-audio-sink
    node.name=$sink
    node.description=$sink
    media.class=Audio/Sink
    object.linger=true
    audio.position=[FL,FR]
}" >/dev/null
for _ in $(seq 50); do
    [[ -n "$(node_state "$sink")" ]] && break
    sleep 0.1
done
[[ -n "$(node_state "$sink")" ]] || fail "sink $sink never appeared"
pw-metadata -n settings 0 clock.allowed-rates "[ $orca_rate $other_rate ]" >/dev/null

run_scenario() {
    local name=$1 pause=$2
    local out=$scratch/$name.out control=$scratch/$name.control status=0 driver_pid rate seen=""
    rm -f "$control"
    mkfifo "$control"
    timeout 60 "$driver" "$scratch/silence-$orca_rate.wav" "$sink" <"$control" >"$out" 2>&1 &
    driver_pid=$!
    exec 3>"$control"
    await_line "$out" playing
    rate=$(graph_rate)
    [[ "$rate" == "$orca_rate" ]] || fail "$name: graph ran at $rate while Orca played, expected $orca_rate"
    if [[ "$pause" == yes ]]; then
        echo pause >&3
        await_line "$out" paused
        for _ in $(seq 50); do
            [[ "$(node_state Orca)" == idle ]] && break
            sleep 0.1
        done
        [[ "$(node_state Orca)" == idle ]] || fail "$name: Orca's stream stayed $(node_state Orca) after pause"
    fi
    timeout 20 pw-play --target "$sink" --rate "$other_rate" "$scratch/silence-$other_rate.wav" >"$scratch/$name.pw-play" 2>&1 &
    local play_pid=$!
    for _ in $(seq 3); do
        seen="$seen $(graph_rate)"
    done
    wait "$play_pid" || fail "$name: pw-play failed: $(cat "$scratch/$name.pw-play")"
    exec 3>&-
    wait "$driver_pid" || status=$?
    [[ "$status" == 0 ]] || fail "$name: driver exited $status: $(cat "$out")"
    echo "$seen"
}

seen=$(run_scenario paused yes)
[[ "${seen##* }" == "$other_rate" ]] ||
    fail "paused: the graph stayed at ${seen##* } after a $other_rate Hz stream started; rates seen:$seen"
echo "check-rate-release: paused: ok, graph moved to $other_rate; rates seen:$seen"

seen=$(run_scenario playing no)
for rate in $seen; do
    [[ "$rate" == "$orca_rate" ]] ||
        fail "playing: the graph left $orca_rate while Orca played; rates seen:$seen"
done
echo "check-rate-release: playing: ok, graph held $orca_rate; rates seen:$seen"
