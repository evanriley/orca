#!/usr/bin/env bash
#
# Build fixtures/library/design.db, the library the redesign screenshots use.
#
# Usage:
#   scripts/design-fixture.sh [DATABASE]
#
# Scans and analyses fixtures/audio, regroups its Tracks into 26 albums by 8
# artists with library-only edits, and adds genres, loves, ratings and ten
# playlists (seven smart) through orca-cli. Covers and artist photos are
# generated with FFmpeg and stored with sqlite3, because no command stores a
# local image. Any existing DATABASE is replaced, so every run gives the same
# library.

set -euo pipefail

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
database="${1:-$repository/fixtures/library/design.db}"
orca_cli="${ORCA_CLI:-$repository/zig-out/bin/orca-cli}"
audio_root="$repository/fixtures/audio"

fail() {
    echo "design-fixture: $1" >&2
    exit 1
}

[ -x "$orca_cli" ] || fail "$orca_cli not built; run 'zig build' first"
for tool in sqlite3 ffmpeg; do
    command -v "$tool" >/dev/null || fail "$tool not found; run inside the dev shell (nix develop)"
done

# album artist|album|year|genre|cover colours
albums=(
    "Juniper Vale|Lanterns|2016|Indie Folk|0x1f3b4d 0xe3a857"
    "Juniper Vale|The Quiet Year|2018|Indie Folk|0x2e4a3f 0xd9c9a3"
    "Juniper Vale|Salt & Cedar|2021|Indie Folk|0x5a2e3a 0xf0b38a"
    "Juniper Vale|Afterlight|2024|Indie Folk|0x0f2740 0x86b6e0"
    "The Low Tides|Breakwater|2009|Indie Rock|0x1b1b2f 0xe94560"
    "The Low Tides|Undertow|2012|Indie Rock|0x16324f 0x4fb0c6"
    "The Low Tides|Harbour Lights|2015|Indie Rock|0x3d1e6d 0xf4a261"
    "The Low Tides|Riptide Hymns|2019|Indie Rock|0x0b3d2e 0xa7c957"
    "Mara Okafor|Gold Hour|2017|Soul|0x4a1c1c 0xf2c14e"
    "Mara Okafor|Velvet Static|2020|Soul|0x2d1b3d 0xd88c9a"
    "Mara Okafor|Honey & Iron|2023|Soul|0x3b2a1a 0xe0a458"
    "Glass Harbour|Prism Weather|2011|Electronic|0x0d0d2b 0x7b5cff"
    "Glass Harbour|Low Orbit|2014|Electronic|0x061a2b 0x2ec4b6"
    "Glass Harbour|Signal Bloom|2022|Electronic|0x1a0f2e 0xff6f91"
    "Pale Signal|Northern Static|2006|Ambient|0x10202a 0x9fb8c8"
    "Pale Signal|Distance Studies|2010|Ambient|0x22262e 0xc0c6cf"
    "Pale Signal|Thaw|2025|Ambient|0x1e2b24 0xb5d3c0"
    "Ostinato Quartet|Blue Hours|1998|Jazz|0x0a1f44 0x3e7cb1"
    "Ostinato Quartet|Live at the Lantern|2003|Jazz|0x2b1d0e 0xc98b3a"
    "Ostinato Quartet|Late Set|2013|Jazz|0x1c1c1c 0xd4af37"
    "Field Recordings Co.|Tidal Archive|2008|Field Recordings|0x2f3e46 0x84a98c"
    "Field Recordings Co.|Forest Floor|2016|Field Recordings|0x283618 0xdda15e"
    "Field Recordings Co.|City at 4 AM|2020|Field Recordings|0x111827 0x6b7280"
    "Neon Cartography|Grid Lines|2018|Synthwave|0x240046 0xff9e00"
    "Neon Cartography|Night Transit|2021|Synthwave|0x10002b 0x00f5d4"
    "Neon Cartography|Overpass|2024|Synthwave|0x3c096c 0xff5d8f"
)

# artist|photo colours
photographed_artists=(
    "Juniper Vale|0x3a5a40 0xf2e8cf"
    "The Low Tides|0x14213d 0xfca311"
    "Mara Okafor|0x6a040f 0xffba08"
)

cli() {
    "$orca_cli" "$@" >/dev/null
}

sql_quote() {
    printf "'%s'" "${1//\'/\'\'}"
}

generate_image() {
    local path=$1 colours=$2 seed=$3 first second
    read -r first second <<<"$colours"
    ffmpeg -hide_banner -loglevel error -f lavfi \
        -i "gradients=s=600x600:c0=$first:c1=$second:x0=0:y0=0:x1=600:y1=600:seed=$seed" \
        -frames:v 1 -q:v 3 -y "$path"
}

mkdir -p "$(dirname "$database")"
rm -f "$database" "$database-wal" "$database-shm" "$database-journal"
images=$(mktemp -d)
trap 'rm -rf "$images"' EXIT

cli scan "$database" "$audio_root"
cli analyze-library "$database"

track_of_file() {
    "$orca_cli" folders "$database" 1 | awk -F'\t' -v name="$1" '$1 == "file" && $4 == name { sub(/^track=/, "", $2); print $2 }'
}

mapfile -t track_files < <("$orca_cli" folders "$database" 1 | awk -F'\t' '$1 == "file" && $2 != "track=-" { print $4 }')
[ "${#track_files[@]}" -ge "${#albums[@]}" ] \
    || fail "fixtures/audio gave ${#track_files[@]} Tracks; ${#albums[@]} albums need at least that many"

# An edit can renumber the Tracks left behind, so each file's Track is looked up just before its edit.
declare -A next_track_number=()
for index in "${!track_files[@]}"; do
    album_index=$((index % ${#albums[@]}))
    IFS='|' read -r artist album year _ <<<"${albums[$album_index]}"
    track_number=$((${next_track_number[$album_index]:-0} + 1))
    next_track_number[$album_index]=$track_number
    cli edit "$database" "$(track_of_file "${track_files[$index]}")" \
        --title="$album $track_number" --artist="$artist" --album="$album" \
        --album-artist="$artist" --date="$year" --track="$track_number" --disc=1 \
        --compilation=0
done

track_ids=()
for file in "${track_files[@]}"; do
    track_ids+=("$(track_of_file "$file")")
done

for album_index in "${!albums[@]}"; do
    IFS='|' read -r _ _ _ genre _ <<<"${albums[$album_index]}"
    album_track_ids=()
    for ((index = album_index; index < ${#track_ids[@]}; index += ${#albums[@]})); do
        album_track_ids+=("${track_ids[$index]}")
    done
    cli edit "$database" "$(IFS=,; echo "${album_track_ids[*]}")" --genre="$genre"
done

release_id() {
    sqlite3 "$database" "SELECT id FROM releases WHERE title = $(sql_quote "$1");"
}

artist_id() {
    sqlite3 "$database" "SELECT id FROM artists WHERE name = $(sql_quote "$1");"
}

for index in "${!albums[@]}"; do
    IFS='|' read -r _ album _ _ colours <<<"${albums[$index]}"
    generate_image "$images/cover-$index.jpg" "$colours" "$index"
    id=$(release_id "$album")
    [ -n "$id" ] || fail "no Release titled '$album' after the edits"
    sqlite3 "$database" "INSERT OR REPLACE INTO release_artwork(release_id, musicbrainz_release_id, image, mime, fetched_at)
        VALUES ($id, '00000000-0000-0000-0000-000000000000', readfile('$images/cover-$index.jpg'), 'image/jpeg', unixepoch());"
done

for index in "${!photographed_artists[@]}"; do
    IFS='|' read -r artist colours <<<"${photographed_artists[$index]}"
    generate_image "$images/artist-$index.jpg" "$colours" "$((100 + index))"
    id=$(artist_id "$artist")
    [ -n "$id" ] || fail "no Artist named '$artist' after the edits"
    sqlite3 "$database" "INSERT OR REPLACE INTO artist_info(artist_id, photo, photo_mime, photo_source, fetched_at, outcome)
        VALUES ($id, readfile('$images/artist-$index.jpg'), 'image/jpeg', 0, unixepoch(), 3);"
done

cli love-release "$database" "$(release_id "Lanterns"),$(release_id "Gold Hour"),$(release_id "Blue Hours"),$(release_id "Low Orbit")"
cli love-artist "$database" "$(artist_id "Juniper Vale"),$(artist_id "Mara Okafor")"
cli feedback "$database" "${track_ids[0]},${track_ids[8]},${track_ids[17]}" --love
cli rate "$database" "${track_ids[0]},${track_ids[4]}" --stars=5
cli rate "$database" "${track_ids[8]},${track_ids[11]}" --stars=4

create_playlist() {
    "$orca_cli" playlist-create "$database" "$1" | sed -n 's/^playlist_id=//p'
}

late_night=$(create_playlist "Late Night Drive")
cli playlist-add "$database" "$late_night" "${track_ids[23]},${track_ids[24]},${track_ids[11]},${track_ids[12]},${track_ids[25]}"
cli playlist-update "$database" "$late_night" --description="Synths and city lights" --pin --love --tags=night,driving

sunday=$(create_playlist "Sunday Morning")
cli playlist-add "$database" "$sunday" "${track_ids[0]},${track_ids[1]},${track_ids[8]},${track_ids[9]},${track_ids[17]}"
cli playlist-update "$database" "$sunday" --description="Slow coffee, open windows" --tags=calm

focus=$(create_playlist "Deep Focus")
cli playlist-add "$database" "$focus" "${track_ids[14]},${track_ids[15]},${track_ids[16]},${track_ids[20]},${track_ids[21]}"
cli playlist-update "$database" "$focus" --pin

cat >"$images/jazz.json" <<'EOF'
{"v":1,"match":"all","rules":[{"field":"genre","op":"is","value":"Jazz"}],"sort":{"field":"year","descending":true}}
EOF
cli smart-playlist-create "$database" "Jazz Archive" "$images/jazz.json"

cat >"$images/favourites.json" <<'EOF'
{"v":1,"match":"any","rules":[{"field":"loved","op":"is","value":true},{"field":"rating","op":"gte","value":80}],"sort":{"field":"rating","descending":true},"limit":100}
EOF
cli smart-playlist-create "$database" "Favourites" "$images/favourites.json"

smart_playlist() {
    printf '%s\n' "$2" >"$images/smart.json"
    cli smart-playlist-create "$database" "$1" "$images/smart.json"
}

smart_playlist "Loved & Unplayed" '{"v":1,"match":"all","rules":[{"field":"loved","op":"is","value":true},{"field":"play_count","op":"is","value":0}]}'
smart_playlist "5 Stars" '{"v":1,"match":"all","rules":[{"field":"rating","op":"is","value":100}],"sort":{"field":"added_at","descending":true}}'
smart_playlist "Recently Added" '{"v":1,"match":"all","rules":[{"field":"added_at","op":"in_last_days","value":30}],"sort":{"field":"added_at","descending":true}}'
smart_playlist "Hi-Res" '{"v":1,"match":"all","rules":[{"field":"sample_rate","op":"gt","value":48000}]}'
smart_playlist "Not Played in a Year" '{"v":1,"match":"all","rules":[{"field":"last_played_at","op":"not_in_last_days","value":365}],"sort":{"field":"random"}}'

"$orca_cli" stats "$database"
