#!/usr/bin/env bash
#
# Fail when a public Runtime method has no C ABI path and is not listed below
# with the reason it has none. A new Runtime method either gets an orca_*
# function in liborca/c_api.zig or an entry here; an entry for a method that
# is gone, or that c_api.zig now calls, fails as well. Only c_api.zig up to
# its first test counts, so test rigs do not cover anything. It also fails when
# an orca_* function that orca.h declares is never called by the C smoke test.
#
# Usage:
#   scripts/check-abi-coverage.sh liborca/core/runtime.zig liborca/c_api.zig \
#       liborca/orca.h tests/c_abi_smoke.c
set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "usage: $0 RUNTIME_ZIG C_API_ZIG ORCA_H C_ABI_SMOKE_C" >&2
    exit 2
fi
runtime=$1
c_api=$2
header=$3
smoke=$4

declare -A reasons=(
    [createLibrary]="orca_library_open opens a Library; an empty in-memory one has no use to a host"
    [shutdown]="orca_runtime_destroy deinitialises the runtime, which shuts it down"
    [playerPlayTrack]="the C ABI plays through the bound variants, which check the Player's Library"
    [playerPlayTracks]="the C ABI plays through the bound variants, which check the Player's Library"
    [playerEnqueueTracks]="the C ABI enqueues through playerEnqueueTracksBound"
    [playerPlayTrackBound]="reached through the command lane: orca_player_play_track submits .play_track"
    [playerSnapshot]="orca_player_status_get reads playerStatus"
    [playerQueueSnapshot]="orca_player_queue_stats and orca_player_query_queue_tracks cover it"
    [playerQueueHistory]="orca_player_query_queue_history reads playerQueueHistoryTracks, whose rows carry each entry's end time and reason"
    [zoneRequestOutput]="orca_zone_open_output and orca_zone_close_output cover it"
    [zoneOutputState]="orca_zone_status_get reports the output state"
    [reapFinishedJobs]="orca_runtime_pump reaps finished jobs through Runtime.pump"
    [processNextCommand]="orca_runtime_pump runs queued commands through Runtime.pump"
    [setOutputFactory]="later: a host-supplied audio output (docs/roadmap.md, Later)"
    [setZonePolicy]="later: Zone policy (docs/roadmap.md, Later)"
    [zoneRenderStrategy]="later: Zone render strategy (docs/roadmap.md, Later)"
    [playerLoadFile]="later: playing a file outside a Library (docs/roadmap.md, Later)"
    [playerDrained]="later: drain detection for hosts (docs/roadmap.md, Later)"
    [playerSeekToTail]="test and CLI aid for checking transitions; not for hosts"
    [libraryAnalyzeFile]="later: one-file analysis on the caller's thread (docs/roadmap.md, Later)"
    [libraryReanalyzeFile]="later: one-file re-analysis on the caller's thread (docs/roadmap.md, Later)"
    [libraryTrackFingerprint]="later: a Track's fingerprint (docs/roadmap.md, Later)"
    [libraryReleaseLetterIndex]="later: the Albums letter index (docs/roadmap.md, Later)"
    [libraryReleaseQueryTotals]="later: filtered Release totals (docs/roadmap.md, Later)"
    [libraryTrackQueryTotals]="later: filtered Track totals (docs/roadmap.md, Later)"
    [libraryTrackQueryPlayableIds]="later: playing a listing from a row (docs/roadmap.md, Later)"
    [libraryArtistElsewhere]="later: an Artist's release groups outside the library and their covers, the release_group artwork subject (docs/roadmap.md, Later)"
    [libraryRequestBrowse]="later: browse queries off the host thread (docs/roadmap.md, Later)"
    [libraryCancelBrowse]="later: browse queries off the host thread (docs/roadmap.md, Later)"
    [libraryTakeBrowse]="later: browse queries off the host thread (docs/roadmap.md, Later)"
    [libraryPlaylistFormats]="later: a playlist's codecs and analysis counts (docs/roadmap.md, Later)"
    [libraryReshufflePlaylists]="later: drawing new random smart playlist orders (docs/roadmap.md, Later)"
    [librarySmartPlaylistPreview]="later: a smart playlist preview with its length and a sample (docs/roadmap.md, Later)"
    [libraryReleasesAvailable]="later: offline roots and what they leave unable to play (docs/roadmap.md, Later)"
    [startCoverArtCandidates]="later: a Release's cover art candidates and chosen covers (docs/roadmap.md, Later)"
    [libraryCoverArtCandidates]="later: a Release's cover art candidates and chosen covers (docs/roadmap.md, Later)"
    [libraryUseCoverArtCandidate]="later: a Release's cover art candidates and chosen covers (docs/roadmap.md, Later)"
    [librarySetReleaseArtwork]="later: a Release's cover art candidates and chosen covers (docs/roadmap.md, Later)"
    [libraryStoredReleaseArtwork]="later: a Release's cover art candidates and chosen covers (docs/roadmap.md, Later)"
    [libraryClearReleaseArtwork]="later: a Release's cover art candidates and chosen covers (docs/roadmap.md, Later)"
    [libraryArtworkProblem]="later: what an artwork_problem issue found; its details text already crosses the ABI (docs/roadmap.md, Later)"
    [libraryArtworkProblemReleasePage]="later: the albums with artwork problems, for an Artwork Review page (docs/roadmap.md, Later)"
    [libraryArtworkProblemReleaseCount]="later: the albums with artwork problems, for an Artwork Review page (docs/roadmap.md, Later)"
    [libraryTrackFieldStates]="later: a selection's shared, mixed and edited field values and cover, for a metadata editor (docs/roadmap.md, Later)"
    [startLibraryConsistencyPass]="later: the metadata consistency pass and its issues, for a Metadata Issues page (docs/roadmap.md, Later)"
    [libraryMetadataIssueCount]="later: the metadata consistency pass and its issues, for a Metadata Issues page (docs/roadmap.md, Later)"
    [libraryMetadataIssuePage]="later: the metadata consistency pass and its issues, for a Metadata Issues page (docs/roadmap.md, Later)"
    [libraryApplyMetadataIssue]="later: the metadata consistency pass and its issues, for a Metadata Issues page (docs/roadmap.md, Later)"
    [librarySkipMetadataIssue]="later: the metadata consistency pass and its issues, for a Metadata Issues page (docs/roadmap.md, Later)"
    [libraryMetadataIssueStatus]="later: the metadata consistency pass and its issues, for a Metadata Issues page (docs/roadmap.md, Later)"
    [libraryApplyMetadataIssues]="later: the metadata consistency pass and its issues, for a Metadata Issues page (docs/roadmap.md, Later)"
)

methods=$(grep -oE '^    pub fn [A-Za-z0-9_]+' "$runtime" | awk '{ print $3 }' | sort -u)
called=$(awk '/^test "/ { exit } { print }' "$c_api" |
    grep -oE '\.[A-Za-z0-9_]+\(' | tr -d '.(' | sort -u)

uncovered=()
stale=()
for method in $methods; do
    if grep -qx "$method" <<<"$called"; then
        [[ -n ${reasons[$method]+set} ]] && stale+=("$method (c_api.zig calls it)")
    elif [[ -z ${reasons[$method]+set} ]]; then
        uncovered+=("$method")
    fi
done
for method in "${!reasons[@]}"; do
    grep -qx "$method" <<<"$methods" || stale+=("$method (not a Runtime method)")
done

if [[ ${#uncovered[@]} -gt 0 || ${#stale[@]} -gt 0 ]]; then
    if [[ ${#uncovered[@]} -gt 0 ]]; then
        echo "Runtime methods with no C ABI path (add an orca_* function, or a reason to $0):" >&2
        printf '  %s\n' "${uncovered[@]}" >&2
    fi
    if [[ ${#stale[@]} -gt 0 ]]; then
        echo "Entries in $0 to remove:" >&2
        printf '  %s\n' "${stale[@]}" >&2
    fi
    exit 1
fi

declared=$(grep -oE '^[A-Za-z_0-9 ]+[ *]orca_[a-z0-9_]+\(' "$header" |
    sed -E 's/.*[ *](orca_[a-z0-9_]+)\($/\1/' | sort -u)
smoke_called=$(grep -oE '\borca_[a-z0-9_]+\(' "$smoke" | tr -d '(' | sort -u)
never_called=$(comm -23 <(echo "$declared") <(echo "$smoke_called"))
if [[ -n $never_called ]]; then
    echo "Exports in $header that $smoke never calls (call each, with the real path or the documented refusal):" >&2
    sed 's/^/  /' <<<"$never_called" >&2
    exit 1
fi
