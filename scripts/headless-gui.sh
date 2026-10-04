#!/usr/bin/env bash
#
# Screenshot orca-gtk in a private, headless sway session.
#
# Usage:
#   scripts/headless-gui.sh PAGE OUT.png [STEP...]
#
# PAGE is albums, artists, tracks, genres, folders, loved, playlists,
# now-playing, queue, health, matches or settings. Each STEP runs in order
# after PAGE is shown:
#   key:SPEC     one key, with modifiers: key:Return, key:ctrl+k, key:alt+Left
#   type:TEXT    types TEXT
#   move:X,Y  click:X,Y  rclick:X,Y   the virtual pointer, in output pixels
#   scroll:N     N wheel steps, positive down
#   wait:MS      sleeps MS milliseconds
#   shot:PATH    saves a screenshot to PATH at once, without waiting to settle
#   tree:PATH    saves sway's window tree, with window titles, to PATH as JSON
#   log:PATH     copies orca-gtk's output so far to PATH; set ORCA_GTK_DEBUG
#                (art, frames, reveal) to add its debug reports
#
# The library is ORCA_LIBRARY, else fixtures/library/design.db, built by
# scripts/design-fixture.sh when missing; the app gets a copy. Settings
# start empty and are discarded, unless ORCA_HEADLESS_CONFIG names a
# directory to keep them in as XDG_CONFIG_HOME across runs. Output is
# pinned to scripts/silent-sink.sh 1. Nothing reaches the user's desktop:
# sway, D-Bus, the pointer and orca-gtk run with a private
# XDG_RUNTIME_DIR, and on exit the script stops only the processes it
# started.

set -euo pipefail

usage() {
    sed -n '5,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

fail() {
    echo "headless-gui: $1" >&2
    exit 1
}

[ "$#" -ge 2 ] || usage
page=$1
output=$2
shift 2
steps=("$@")

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
orca_cli="$repository/zig-out/bin/orca-cli"
orca_gtk="$repository/zig-out/bin/orca-gtk"
width=1440
height=900
application_id=org.orca_music.Orca

case "$page" in
    albums | artists | tracks | genres | folders | loved | playlists | now-playing | queue | health | matches | settings) ;;
    *) fail "unknown page '$page'; expected albums, artists, tracks, genres, folders, loved, playlists, now-playing, queue, health, matches or settings" ;;
esac
for step in "${steps[@]}"; do
    case "$step" in
        key:?* | type:?* | wait:[0-9]* | scroll:* | move:*,* | click:*,* | dclick:*,* | rclick:*,* | drag:*,*,*,* | shot:?*.png | tree:?* | log:?*) ;;
        *) fail "unknown step '$step'; see the usage in $0" ;;
    esac
done
case "$output" in
    *.png) ;;
    *) fail "OUT must end in .png, got '$output'" ;;
esac
mkdir -p "$(dirname "$output")"
output=$(cd "$(dirname "$output")" && pwd)/$(basename "$output")

[ -x "$orca_gtk" ] && [ -x "$orca_cli" ] || fail "orca-gtk or orca-cli not built; run 'zig build' first"

library=${ORCA_LIBRARY:-$repository/fixtures/library/design.db}
if [ ! -f "$library" ]; then
    [ -z "${ORCA_LIBRARY:-}" ] || fail "ORCA_LIBRARY names $library, which does not exist"
    "$repository/scripts/design-fixture.sh" "$library" >/dev/null
fi

user_runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
runtime=$(mktemp -d "${ORCA_HEADLESS_TMPDIR:-/tmp}/orca-gui.XXXXXX")
chmod 700 "$runtime"
case "$runtime" in
    "$user_runtime" | "$user_runtime"/* | /run/user/*)
        rmdir "$runtime"
        fail "private runtime dir $runtime is inside the user's $user_runtime"
        ;;
esac
if [ "${#runtime}" -gt 80 ]; then
    rmdir "$runtime"
    fail "runtime dir $runtime is too long for a Wayland socket path; set ORCA_HEADLESS_TMPDIR to a shorter directory"
fi

started_pids=()
finished=0

owned_by_session() {
    { tr '\0' '\n' <"/proc/$1/environ"; } 2>/dev/null | grep -qxF "XDG_RUNTIME_DIR=$runtime"
}

# Signals only PIDs recorded at launch whose environment carries this run's
# runtime dir: never a parent PID, never a process found by name.
stop_started() {
    local index pid alive
    for ((index = ${#started_pids[@]} - 1; index >= 0; index--)); do
        pid=${started_pids[$index]}
        if owned_by_session "$pid"; then kill -TERM "$pid" 2>/dev/null || true; fi
    done
    for _ in $(seq 30); do
        alive=0
        for pid in "${started_pids[@]}"; do
            if owned_by_session "$pid"; then alive=1; fi
        done
        [ "$alive" = 0 ] && break
        sleep 0.1
    done
    for pid in "${started_pids[@]}"; do
        if owned_by_session "$pid"; then kill -KILL "$pid" 2>/dev/null || true; fi
    done
    for pid in "${started_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
}

report_strays() {
    local entry pid strays=0
    for entry in /proc/[0-9]*; do
        pid=${entry#/proc/}
        owned_by_session "$pid" || continue
        echo "headless-gui: process $pid ($(cat "/proc/$pid/comm" 2>/dev/null)) outlived the session and was left running" >&2
        strays=1
    done
    return "$strays"
}

cleanup() {
    local status=$? log
    trap - EXIT INT TERM
    exec 4>&-
    [ "${#started_pids[@]}" = 0 ] || stop_started
    report_strays || status=1
    if [ "$finished" = 0 ]; then
        for log in "$runtime"/*.log; do
            [ -s "$log" ] || continue
            echo "--- $(basename "$log")" >&2
            tail -n 15 "$log" >&2
        done
        [ "$status" -ne 0 ] || status=1
    fi
    rm -rf "$runtime"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

provision_tools() {
    local revision system
    revision=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["nodes"]["nixpkgs"]["locked"]["rev"])' "$repository/flake.lock")
    system="$(uname -m)-linux"
    nix build --no-link --print-out-paths --expr "
        with (builtins.getFlake \"github:NixOS/nixpkgs/$revision\").legacyPackages.$system;
        buildEnv {
          name = \"orca-headless-gui\";
          paths = [ sway grim wtype dbus wlr-protocols wayland-scanner.out (python3.withPackages (p: [ p.pywayland ])) ];
          pathsToLink = [ \"/bin\" \"/share/wayland\" \"/share/wlr-protocols\" ];
        }" 2>"$runtime/nix.log" || fail "could not build sway, grim, wtype, dbus and pywayland from the flake's nixpkgs"
}

silent_device() {
    local device name='' kind='' factory
    device=$(cd "$repository" && scripts/silent-sink.sh 1) || fail "scripts/silent-sink.sh 1 failed"
    IFS=$'\t' read -r name kind < <("$orca_cli" devices | awk -F'\t' -v id="$device" '$1 == id { print $2 "\t" $3; exit }') || true
    [ "$name" = "Orca Silent Test Sink" ] && [ "$kind" = virtual ] \
        || fail "device $device is '$name' ($kind), not the virtual 'Orca Silent Test Sink'; refusing to pin it"
    factory=$(pw-dump | python3 -c '
import json, sys
for node in json.load(sys.stdin):
    props = (node.get("info") or {}).get("props") or {}
    if props.get("node.description") == "Orca Silent Test Sink":
        print(props.get("factory.name", ""))
        break
')
    [ "$factory" = support.null-audio-sink ] \
        || fail "the 'Orca Silent Test Sink' node comes from '$factory', not support.null-audio-sink; refusing to pin it"
    echo "$device"
}

tools=$(provision_tools)
device=$(silent_device)
pipewire_remote="$user_runtime/pipewire-0"

for variable in DISPLAY WAYLAND_DISPLAY WAYLAND_SOCKET DBUS_SESSION_BUS_ADDRESS DBUS_STARTER_ADDRESS \
    DBUS_STARTER_BUS_TYPE GNOME_KEYRING_CONTROL GNOME_KEYRING_PID SSH_AUTH_SOCK SWAYSOCK I3SOCK \
    XDG_SESSION_ID XDG_SESSION_TYPE XDG_SESSION_DESKTOP XDG_CURRENT_DESKTOP XDG_SEAT XDG_VTNR \
    GDK_BACKEND GTK_THEME DESKTOP_SESSION MANAGERPID INVOCATION_ID SYSTEMD_EXEC_PID; do
    unset "$variable"
done
export XDG_RUNTIME_DIR=$runtime
export HOME=$runtime/home XDG_CONFIG_HOME=${ORCA_HEADLESS_CONFIG:-$runtime/config} XDG_DATA_HOME=$runtime/data XDG_CACHE_HOME=$runtime/cache
export PATH="$tools/bin:$PATH"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$runtime/library" "$runtime/no-services"

cp "$library" "$runtime/library/library.db"
for suffix in -wal -shm; do
    if [ -f "$library$suffix" ]; then cp "$library$suffix" "$runtime/library/library.db$suffix"; fi
done

cat >"$runtime/sway.conf" <<EOF
output HEADLESS-1 resolution ${width}x${height} position 0 0
default_border none
default_floating_border none
xwayland disable
swaybg_command -
for_window [app_id=".*"] fullscreen enable
EOF

cat >"$runtime/bus.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=$runtime</listen>
  <servicedir>$runtime/no-services</servicedir>
  <policy context="default"><allow send_destination="*" eavesdrop="true"/><allow eavesdrop="true"/><allow own="*"/></policy>
</busconfig>
EOF

cat >"$runtime/pointer.py" <<'EOF'
import os, select, sys, time
sys.path.insert(0, sys.argv[1])
from pywayland.client import Display
from pywayland.protocol.wayland import WlSeat
from orca_protocols.wlr_virtual_pointer_unstable_v1 import ZwlrVirtualPointerManagerV1

width, height, fifo = int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
display = Display()
display.connect()
found = {}

def on_global(registry, name, interface, version):
    if interface == "zwlr_virtual_pointer_manager_v1":
        found["manager"] = registry.bind(name, ZwlrVirtualPointerManagerV1, min(version, 2))
    elif interface == "wl_seat" and "seat" not in found:
        found["seat"] = registry.bind(name, WlSeat, min(version, 5))

registry = display.get_registry()
registry.dispatcher["global"] = on_global
display.roundtrip()
pointer = found["manager"].create_virtual_pointer(found["seat"])
display.roundtrip()

def now():
    return int(time.monotonic() * 1000) & 0xFFFFFFFF

def button(code):
    pointer.button(now(), code, 1)
    pointer.frame()
    display.flush()
    time.sleep(0.08)
    pointer.button(now(), code, 0)
    pointer.frame()

commands = os.fdopen(os.open(fifo, os.O_RDWR), "r")
print("ready", flush=True)
while True:
    select.select([commands], [], [])
    words = commands.readline().split()
    if not words:
        continue
    if words[0] == "quit":
        break
    if words[0] == "move":
        pointer.motion_absolute(now(), int(words[1]), int(words[2]), width, height)
        pointer.frame()
    elif words[0] == "click":
        button(0x110)
    elif words[0] == "dclick":
        button(0x110)
        display.flush()
        time.sleep(0.05)
        button(0x110)
    elif words[0] == "rclick":
        button(0x111)
    elif words[0] == "press":
        pointer.button(now(), 0x110, 1)
        pointer.frame()
    elif words[0] == "release":
        pointer.button(now(), 0x110, 0)
        pointer.frame()
    elif words[0] == "scroll":
        steps = int(words[1])
        pointer.axis_discrete(now(), 0, steps * 15 * 256, steps)
        pointer.frame()
    display.flush()
    display.roundtrip()
pointer.destroy()
display.flush()
EOF

launch() {
    local log=$1
    shift
    "$@" >"$runtime/$log.log" 2>&1 &
    started_pids+=("$!")
}

wait_for() {
    local description=$1 tries=$2
    shift 2
    for _ in $(seq "$tries"); do
        if "$@"; then return 0; fi
        sleep 0.1
    done
    fail "timed out waiting for $description"
}

private_display() {
    [ -n "${WAYLAND_DISPLAY:-}" ] && [ -S "$runtime/$WAYLAND_DISPLAY" ] \
        || fail "refusing to run a Wayland client without the private compositor's socket"
}

launch dbus dbus-daemon --nofork --config-file="$runtime/bus.conf" --print-address=1
bus_ready() { grep -q '^unix:' "$runtime/dbus.log"; }
wait_for "dbus-daemon" 50 bus_ready
DBUS_SESSION_BUS_ADDRESS=$(grep -m 1 '^unix:' "$runtime/dbus.log")
export DBUS_SESSION_BUS_ADDRESS

WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
    launch sway sway --config "$runtime/sway.conf"
sway_pid=${started_pids[-1]}

sway_ready() {
    local socket
    for socket in "$runtime"/wayland-[0-9]; do
        [ -S "$socket" ] || continue
        WAYLAND_DISPLAY=$(basename "$socket")
    done
    for socket in "$runtime"/sway-ipc.*."$sway_pid".sock; do
        [ -S "$socket" ] || continue
        SWAYSOCK=$socket
    done
    [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${SWAYSOCK:-}" ]
}
wait_for "sway" 100 sway_ready
export WAYLAND_DISPLAY SWAYSOCK

private_display
python3 -m pywayland.scanner -o "$runtime/python/orca_protocols" \
    -i "$tools/share/wayland/wayland.xml" "$tools/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml" \
    >"$runtime/scanner.log" 2>&1
mkfifo "$runtime/pointer"
launch pointer python3 "$runtime/pointer.py" "$runtime/python" "$width" "$height" "$runtime/pointer"
pointer_ready() { grep -qx ready "$runtime/pointer.log"; }
wait_for "the virtual pointer" 100 pointer_ready
exec 4>"$runtime/pointer"
echo "move $((width - 1)) 0" >&4

ORCA_LIBRARY="$runtime/library/library.db" ORCA_OUTPUT_DEVICE=$device PIPEWIRE_REMOTE=$pipewire_remote \
    ORCA_LISTENBRAINZ_URL=http://127.0.0.1:9 ORCA_MUSICBRAINZ_URL=http://127.0.0.1:9 \
    ORCA_ACOUSTID_URL=http://127.0.0.1:9 ORCA_COVERARTARCHIVE_URL=http://127.0.0.1:9 \
    ORCA_LRCLIB_URL=http://127.0.0.1:9 ORCA_WIKIDATA_URL=http://127.0.0.1:9 \
    ORCA_WIKIMEDIA_URL=http://127.0.0.1:9 ORCA_WIKIPEDIA_URL=http://127.0.0.1:9 \
    ORCA_LISTENBRAINZ_LABS_URL=http://127.0.0.1:9 \
    ORCA_GTK_DEBUG=${ORCA_GTK_DEBUG:-} GSK_RENDERER=cairo GDK_BACKEND=wayland GDK_DEBUG=no-portals GTK_A11Y=none NO_AT_BRIDGE=1 \
    launch orca-gtk "$orca_gtk"
orca_pid=${started_pids[-1]}

window_ready() {
    [ -d "/proc/$orca_pid" ] || fail "orca-gtk exited before showing its window"
    swaymsg -t get_tree 2>/dev/null | grep -q "\"app_id\": \"$application_id\""
}
wait_for "the orca-gtk window" 300 window_ready
sleep 1.5

press() {
    local spec=$1 key arguments=() modifiers=() modifier parts=()
    IFS=+ read -r -a parts <<<"$spec"
    key=${parts[-1]}
    for modifier in "${parts[@]:0:${#parts[@]}-1}"; do
        case "$modifier" in
            ctrl | shift | alt | logo) ;;
            super) modifier=logo ;;
            *) fail "unknown modifier '$modifier' in key:$spec" ;;
        esac
        modifiers+=("$modifier")
    done
    for modifier in "${modifiers[@]}"; do arguments+=(-M "$modifier"); done
    arguments+=(-k "$key")
    for modifier in "${modifiers[@]}"; do arguments+=(-m "$modifier"); done
    private_display
    wtype -s 300 "${arguments[@]}" -s 200
}

type_text() {
    private_display
    wtype -s 300 -d 40 -- "$1"
}

pointer_command() {
    private_display
    echo "$*" >&4
}

shot() {
    private_display
    grim -o HEADLESS-1 "$1"
}

drag() {
    local x1=$1 y1=$2 x2=$3 y2=$4 step steps=12
    pointer_command move "$x1" "$y1"
    sleep 0.2
    pointer_command press
    sleep 0.2
    for step in $(seq 1 "$steps"); do
        pointer_command move $((x1 + (x2 - x1) * step / steps)) $((y1 + (y2 - y1) * step / steps))
        sleep 0.05
    done
    sleep 0.3
    pointer_command release
}

run_step() {
    local step=$1 value
    value=${step#*:}
    case "$step" in
        shot:*) shot "$value" ;;
        tree:*) swaymsg -t get_tree >"$value" ;;
        log:*) cp "$runtime/orca-gtk.log" "$value" ;;
        key:*) press "$value" ;;
        type:*) type_text "$value" ;;
        wait:*) sleep "$(awk -v ms="$value" 'BEGIN { print ms / 1000 }')" ;;
        move:*) pointer_command move "${value%,*}" "${value#*,}" ;;
        click:*) pointer_command move "${value%,*}" "${value#*,}" && sleep 0.1 && pointer_command click ;;
        dclick:*) pointer_command move "${value%,*}" "${value#*,}" && sleep 0.1 && pointer_command dclick ;;
        rclick:*) pointer_command move "${value%,*}" "${value#*,}" && sleep 0.1 && pointer_command rclick ;;
        scroll:*) pointer_command scroll "$value" ;;
        drag:*) drag ${value//,/ } ;;
    esac
    sleep 0.6
}

# Every page but Albums and Settings is reached through the command palette's
# "Show <page>" commands, typed after ">" (the palette's alias for "›"), so a
# change to the palette's command prefix or names must be mirrored here.
show_page() {
    local title
    case "$1" in
        albums) return 0 ;;
        settings)
            run_step key:ctrl+comma
            return 0
            ;;
        now-playing) title="Now Playing" ;;
        *) title="${1^}" ;;
    esac
    run_step key:ctrl+k
    run_step "type:>Show $title"
    run_step key:Return
}

show_page "$page"
for step in "${steps[@]}"; do
    run_step "$step"
done

previous="$runtime/shot-a.png"
current="$runtime/shot-b.png"
shot "$previous"
settled=0
for _ in $(seq 20); do
    sleep 0.5
    shot "$current"
    if cmp -s "$previous" "$current"; then
        settled=1
        break
    fi
    mv "$current" "$previous"
done
[ "$settled" = 1 ] || echo "headless-gui: the window was still changing after 10 s; saving the last frame" >&2
pointer_command quit
mv "$current" "$output"
finished=1
echo "$output"

