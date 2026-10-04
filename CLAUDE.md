# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Orca is a local-files-first music player and library-maintenance application,
written in Zig. `liborca/` is a reusable headless engine; `apps/` holds thin
native frontends that are *clients* of it.

`liborca` is the product, in the way libghostty is Ghostty's: GUIs, CLIs and
TUIs are built on it. `docs/architecture.md` is the overview,
`docs/roadmap.md` records what works, what is built but unreachable, and what
comes next, and the other files in `docs/` are per-subsystem contracts: the
fastest way to load a subsystem's invariants before editing it.

## Licence

Orca is MPL-2.0 (`LICENSE`): embedders may keep their own code closed and
changes to Orca's files stay open. Orca is open source and desktop-only; it is
not distributed through app stores.
`liborca`'s dependencies, and anything it vendors or links statically, must
be permissive (BSD, MIT, Apache-2.0, zlib, CC0, public domain): a GPL or LGPL
dependency there would bind every embedder. This is
why AAC comes from libxaac (Apache-2.0) rather than libfaad2 (GPL) or libfdk-aac
(FDK licence), and why Chromaprint is built without its bundled LGPL
resampler, with libsamplerate (BSD-2-Clause) resampling instead; a build step
fails if a compiled Chromaprint source carries a GPL or LGPL notice. A frontend dynamically linking its platform's own toolkit or
keyring, as `orca-gtk` does with LGPL GTK4 and libsecret, is outside that rule.
So are the fonts `orca-gtk` bundles, Newsreader, Geist and Geist Mono: they are under
the SIL Open Font License, ship only with the frontend, and keep their licence
texts beside them in `apps/linux/data/fonts`.

## Toolchain

Zig `0.16.0`, the stable release, provided by the flake's dev shell
(`nix develop`, or direnv via `.envrc`). Development snapshots are not pinned:
ziglang.org deletes old nightly tarballs, which is how the previous pin
(`0.17.0-dev.1770`) became unbuildable. This is a **`std.Io` Zig**:
`std.Io.File`, `std.Io.Dir`, `std.Io.Reader`/`Writer`, and an explicit
`io: std.Io` parameter threaded through I/O call sites (`std.testing.io` in
tests). Do not write code against the older `std.fs` / `std.io` APIs.

The dev shell supplies libFLAC, libopusfile, libvorbis, libsamplerate and
SQLite, plus PipeWire, GTK4 and libsecret on Linux. `sqlite3`, `FLAC`,
`opusfile`, `vorbisfile`, `samplerate`, GTK and libsecret (`orca-gtk` only)
are linked via pkg-config.
PipeWire's include paths come from `pkg-config --cflags-only-I`
(`pkgConfigIncludePaths` in `build.zig`) and its library is linked without
pkg-config, because the rest of its `--cflags` breaks Zig's pkg-config parser.
No path under `/usr` is assumed, so the same build works on NixOS and FHS
distributions. The Zig package dependencies are `alac`, `libxaac` and
`chromaprint` (built by `build/chromaprint.zig`);
`nix build` fetches them through `zig.fetchDeps`. When `build.zig.zon`
dependencies change, set that hash in `nix/package.nix` to `lib.fakeHash` and
rebuild to learn the new one: an unchanged hash makes Nix reuse the old
dependency directory, and the sandboxed build then fails trying to fetch the
new packages.

### Zig facts that cost time to rediscover

Each one was found the expensive way.

- **A by-value struct parameter is a copy.** A pointer to one of its fields
  dangles once the function returns. The old snapshot happened to pass large
  structs by reference, which hid exactly this: an SQLite `SQLITE_STATIC` blob
  bound from `&selector.parameter_hash` in a helper read freed stack memory, and
  the analysis pass re-measured every file. Take `*const T` when a pointer into
  the argument must outlive the call.
- **`std.Thread.Mutex`, `std.Thread.Condition` and `std.Thread.ResetEvent` do not
  exist.** Use atomics plus `std.Thread.join`. `std.Io.Mutex` and
  `std.Io.Condition` do exist, but need an `io` in scope.
- **`translate-C` (`b.addTranslateC` or `@cImport`) fails outright on GTK4's
  headers**, so GTK is bound by hand.
- **`std.Io.Dir` cannot fsync a directory.** Its `handle` is not an fsync-able fd
  (`EBADF` under `std.Io.Threaded`); open the directory *path as a file* instead.
  Durable renames depend on this.
- **`{d:0>2}` on a signed integer emits a sign**, so a duration of six seconds
  formats as `0:+6`. Convert to unsigned before formatting.
- **`@enumFromInt(@intCast(x))` has no result type** for the inner cast. Write
  `@enumFromInt(@as(std.meta.Tag(E), @intCast(x)))`.
- Sentinel formatting is `std.fmt.bufPrintSentinel` / `std.fmt.allocPrintSentinel`.
- `std.crypto.hash.Blake3` is available.

### Verifying a build

Never write `zig build 2>&1 | tail -3 && echo OK`. In a pipeline `$?` is the
status of `tail`, not of the compiler, so a failed build reports success and the
"verification" that follows runs a stale binary. This masked a real compile
failure for two rounds. Check `${PIPESTATUS[0]}`, or run `zig build` unpiped.

`zig build` also **reinstalls the Debug binary over `zig-out/bin/`**. A
ReleaseFast timing taken after any plain `zig build` is therefore silently
measuring Debug — it reported 8.7× slow once and looked plausible. Re-run
`zig build -Doptimize=ReleaseFast` immediately before timing anything, and
treat a suspiciously slow number as a stale binary before believing it.

## Commands

Run these inside the dev shell (`nix develop`, or automatically with direnv).

```sh
nix build                     # package: orca-cli, orca-gtk (Linux), liborca, orca.h
nix flake check
nix fmt                       # formats Nix files
zig fmt --check liborca apps benchmarks tests build.zig

zig build                     # static + shared liborca, orca-cli, headers; orca-gtk on Linux
zig build lib                 # static liborca and orca.h only; CI cross-builds it with -Dtarget=aarch64-macos
zig build test                # unit + integration + C ABI smoke (+ PipeWire link smoke on Linux)
zig build fuzz                # replay the parser fuzz targets' seeds
zig build fuzz --fuzz[=N]     # fuzz them; N iterations per target, unlimited opens the web UI
scripts/headless-audio.sh zig build test   # tests against a private PipeWire and WirePlumber, as CI runs them
zig build run -- --version    # orca-cli
zig build bench               # 500k-track persistence benchmark
zig build -Doptimize=ReleaseFast dsp-bench   # scalar vs SIMD DSP kernels
```

`orca-cli` surface:

```sh
zig build run -- demo
zig build run -- devices   # id, name, kind (usb|pci|bluetooth|hdmi|virtual|unknown), then `rates=44100-384000 depths=16,24,32 channels=2 state=active|suspended|unavailable`, or `rates=- depths=- channels=- state=unknown` when PipeWire did not answer within 500 ms; the silent sink is virtual

# library
zig build run -- scan DATABASE ROOT   # `progress stage=discover|read_tags|done files= total= albums= current=` lines, then the counters
zig build run -- estimate PATH   # audio_files=N truncated=no|yes; counts audio files by their bytes, up to 100000, without adding PATH
zig build run -- roots DATABASE   # id, enabled, path, available=yes|no tracks=N unavailable=N volume= last_seen_at=
zig build run -- availability DATABASE [RELEASE_ID...]   # offline_roots= unavailable_tracks= unavailable_releases=, an `offline` line per root, then release= available=yes|no
zig build run -- add-root DATABASE ROOT   # binds an existing root to the volume it is on now
zig build run -- remove-root DATABASE ID   # forgets the root's files and tracks; nothing on disk
zig build run -- relocate-root DATABASE ID PATH   # moves a root that moved on disk, keeping its ids; binds the volume PATH is on now, then reconciles
zig build run -- folders DATABASE [ROOT_ID [PATH]]   # roots with totals; or a `folder: release= tracks= images= last_scanned_at=` line, subfolders with recursive counts, files with track ids, then images; entries end kind= status=imported|unreadable, images role=
zig build run -- watch DATABASE [--quiet=MS] [--max-delay=MS] [--once] [--limit=MS] [--maintenance[=MS]] [--pause-after=MS] [--resume-after=MS]   # Linux; reconciles folders as they change; --maintenance also verifies recording IDs while idle; --pause-after/--resume-after pause and resume the Library's Jobs, printing `jobs: state=paused|running`
zig build run -- reconcile DATABASE ROOT_ID [DIR...]   # rescans the root or only DIRs under it; marks missing only under them
zig build run -- project DATABASE
zig build run -- backfill DATABASE [--force] [--cancel-after=MS]
zig build run -- health DATABASE [OFFSET]   # file_id, severity, kind, action, path, details
zig build run -- health DATABASE --kind=KIND [OFFSET]   # the same lines, one kind only
zig build run -- health DATABASE --summary   # kind, highest severity, count, files, bytes per kind with an issue; duplicate bytes are the redundant copies only; then `missing_files N`, Tracks with no present file
zig build run -- sources   # id, name, url, licence, supplies, then licence url when there is one; needs no database
zig build run -- stats DATABASE   # artists=, releases=, tracks=, files=, bytes=, duration_ms=, last_scan_finished_at=, last_analysis_at=, last_duplicate_scan_at= (- when none), listens=
zig build run -- cache DATABASE [--clear]   # artwork_bytes= photo_bytes= lyrics_bytes= info_bytes= of fetched provider data; --clear deletes it and prints what it held; embedded and folder art and local lyrics stay
zig build run -- health-dismiss DATABASE FILE_ID KIND   # hidden until the file's bytes change
zig build run -- health-restore DATABASE FILE_ID KIND
zig build run -- analyze DATABASE AUDIO
zig build run -- analyze-library DATABASE [--batch=N] [--threads=N] [--cancel-after=MS]
zig build run -- duplicates DATABASE [--batch=N] [--cancel-after=MS]
zig build run -- duplicates DATABASE --groups [--limit N] [--offset N]   # id, title, artist, copies= same_recording=yes|no similarity=0.99|- bytes_redundant=, then `groups= bytes=`; a group's id is its lowest file id
zig build run -- duplicates DATABASE --group=ID   # the copies, suggested first: file= track= keep=yes|no locations= playlists= codec= rate= depth= bytes= ... path=
zig build run -- merge-duplicate DATABASE KEEP_TRACK_ID FROM_TRACK_ID   # fills KEEP's missing Orca values, user genres, rating and feedback from FROM; KEEP's locks win; no file written
zig build run -- keep-both DATABASE FILE_ID FILE_ID   # dismisses both files' duplicate issues
zig build run -- ignore-duplicate DATABASE GROUP_ID   # dismisses the duplicate issues of the whole group
zig build run -- jobs DATABASE [--start=scan|analysis|duplicates|backfill|project]... [--pause-after=MS] [--resume-after=MS]   # one runtime: each after the first prints `waiting after=`; prints every state change until all finish
zig build run -- jobs DATABASE --history [--filter=all|scans|analysis|file_changes|problems] [--limit N] [--offset N]   # finished Jobs newest first: id, kind, state, started_at=, duration_s=, completed=, total=, retry=yes|no, summary=
zig build run -- retry-job DATABASE HISTORY_ID   # starts a failed or cancelled Job's request again and waits for it

# browse
zig build run -- artists DATABASE [--album-artists] [--filter TEXT] [--genre ID] [--loved] [--sort name|tracks|loved|recently_added] [--sort-as-written] [--limit N] [--offset N]   # a loved Artist ends in `loved`, then `photo` when its photo is stored; --album-artists: only Artists a Release is filed under; --sort-as-written keeps a leading "The", "A" or "An" in the name order
zig build run -- releases DATABASE [--filter TEXT] [--artist ID] [--genre ID] [--loved] [--high-resolution] [--needs-review] [--lossless] [--year-from Y] [--year-to Y] [--with-artwork | --without-artwork] [--type=album|ep-single|other] [--appears=ARTIST_ID] [--own] [--added-days=N] [--sort title|artist|year|recently_added|loved|most_played] [--sort-as-written] [--letters | --totals | --async] [--limit N] [--offset N]   # each line ends `format=FLAC 24/96`, `lossless`, `reviews=N`; --own needs --artist and leaves out appearances; --letters prints `letter count offset` (title or artist sort), --totals `count= artists= bytes=`; --async reads the page and count on the browse loader
zig build run -- tracks DATABASE [--filter TEXT] [--artist ID] [--release ID] [--genre ID] [--loved] [--year-from Y] [--year-to Y] [--lossless | --lossy] [--min-rate HZ] [--max-rate=HZ] [--codec=NAME] [--added-days=N] [--explicit] [--sort KEY] [--desc] [--totals] [--async] [--limit N] [--offset N]   # KEY includes rating, loved, play_count, last_played, year, loudness, bitrate, path, album_artist, genre; lines end `lufs= kbps= path=`; a search ranks by relevance; --totals prints `count= duration_ms=`, a search's with --filter; --async reads them on the browse loader
zig build run -- track DATABASE ID   # includes `composer:` and `comment:`, `-` when none
zig build run -- search DATABASE TEXT [--artists N] [--releases N] [--tracks N] [--playlists N] [--genres N]   # kind, id, title, subtitle, releases= tracks= year= duration_ms= artist= reason=name|tracks_by|main_genre_of count=, then `top KIND ID TITLE`; each word a word prefix, no syntax
zig build run -- genres DATABASE [--filter TEXT] [--sort name|tracks] [--limit N] [--offset N]
zig build run -- genre DATABASE ID   # counts, top artists, most played releases
zig build run -- genres DATABASE --fill-from-musicbrainz [--limit N] [--offline]   # provider genres on Tracks with none from a file or an edit
zig build run -- genre-fill DATABASE [on|off]   # automatic MusicBrainz genre fill in artist-info and release-info; on by default
zig build run -- artwork DATABASE (--track=ID | --release=ID) [--out=PATH]
zig build run -- covers DATABASE [--limit N] [--offset N]   # a page of covers via the artwork loader
zig build run -- lyrics DATABASE TRACK_ID [--fetch]   # .lrc sidecar or embedded; synced before plain; prints source_name= (file name, embedded, LRCLIB) and offset_ms=; --fetch: see LRCLIB below
zig build run -- edit DATABASE IDS [--title=…] [--artist=…] [--composer=…] [--comment=…] [--genre=A;B] [--clear=FIELD]…   # library only; FIELD includes composer and comment
zig build run -- write-tags DATABASE IDS [--approve=DIGEST]   # preview, then write FLAC/MP3/ADTS
zig build run -- undo-tags DATABASE GROUP
zig build run -- prune-backups DATABASE [--older-than=DAYS]   # deletes backups; those writes can no longer be undone
zig build run -- changes DATABASE [--limit N] [--offset N]   # tag writes newest first: group= written_at= files= state=applied|undoing|undone|rolled_back|failed|needs_reconciliation can_undo=yes|no expired=yes|no title=; reads the journal only
zig build run -- changes DATABASE GROUP   # the same line with fields= more_files=, then FILE<TAB>FIELD<TAB>RESTORES<TAB>CURRENT per changed tag; unknown when a backup is gone
zig build run -- changes DATABASE --export=FILE [--force]   # every list line into FILE, atomically; refuses an existing FILE without --force

# ratings and playlists -- kept per recording in the library; no file is written
zig build run -- rate DATABASE IDS (--stars=1..5 | --rating=1..100 | --clear)
zig build run -- playlists DATABASE [--smart|--manual] [--pinned] [--created-by-me|--imported] [--sort name|updated|created|entries] [--filter TEXT]   # kind, then imported/pinned/loved/tags= when they apply
zig build run -- playlist DATABASE ID [--limit N] [--offset N]   # a `playlist` line (kind, description, tags, genres), a `formats:` line (CODEC=N, analyzed=, unanalyzed=), then entries
zig build run -- playlist-create DATABASE NAME
zig build run -- playlist-rename DATABASE ID NAME
zig build run -- playlist-delete DATABASE ID
zig build run -- playlist-add DATABASE ID IDS [--at=N]   # appends, or inserts before position N
zig build run -- playlist-remove DATABASE ID POSITIONS
zig build run -- playlist-move DATABASE ID FROM TO
zig build run -- playlist-import DATABASE FILE [--name=NAME]   # M3U/M3U8; matches by path, then #EXTINF; never scans
zig build run -- playlist-export DATABASE ID FILE [--relative] [--force]   # atomic; refuses an existing FILE without --force
zig build run -- playlist-update DATABASE ID [--description=TEXT] [--pin|--unpin] [--love|--unlove] [--tags=A,B]   # at most 8 tags; replaces them
zig build run -- smart-playlist-create DATABASE NAME RULES_FILE   # version 1 rules JSON, see docs/api.md
zig build run -- smart-playlist-rules DATABASE ID [RULES_FILE]   # prints the rules, replacing them with RULES_FILE first
zig build run -- smart-playlist-count DATABASE RULES_FILE [--sample=N]   # count= and duration_ms= the rules match now, then the first N Tracks; stores nothing

# playback -- pass a device from scripts/silent-sink.sh, never the default
zig build run -- play AUDIO [DEVICE_ID]
zig build run -- play-tracks DATABASE (IDS | --playlist=ID) --device=ID [--start=N] [--repeat=off|one|all] [--shuffle]
    [--replay-gain=off|track|album|smart] [--preamp=DB] [--untagged=-6|as-is] [--no-peak-protection]
    [--stop-after-current]   # stops when the first entry heard ends; the signal line ends `replay_gain_source= preamp_db= peak_protection= untagged= peak_limited= device_format=S24_32LE device_bits=24 device_rate=96000`, or `device_format=-` when the device's own format is unknown (suspended, virtual, not yet reported, or not PipeWire)
    [--volume=LINEAR] [--set-volume=MS:LINEAR]
    [--eq=PRESET|G1,...,G10[:PREAMP] | --peq=FILE] [--crossfeed=0..1]   # prints a `signal:` line; FILE is EqualizerAPO text
    [--skip-after=MS] [--previous-after=MS] [--tail=MS] [--limit=MS]   # --limit defaults to 10 min
    [--lyrics]   # prints a `lyric at=` line as each synced line is heard
    [--move=MS:FROM:TO]...   # at MS, moves the entry at playback position FROM to TO; prints `move at= ... result=ok|in_use|out_of_range`
    [--print-history] [--save-queue=NAME]   # at the end: queue history newest first; the queue from the current entry as a playlist
    # records listens in the play history; never sends them
    # an entry that cannot be opened prints `failure=TRACK_ID:file_missing|folder_unavailable|codec_unavailable|decode_error|unsupported_channels` and play goes on to the next
zig build run -- play-folder DATABASE ROOT_ID PATH --device=ID [--shuffle] [--limit=MS]   # every Track below PATH, recursively in path order
zig build run -- peq-check FILE   # validates an EqualizerAPO file and prints it back normalised
zig build run -- peq-response FILE [--rate=HZ]   # HZ<TAB>DB at 32 log-spaced frequencies, preamp included; --rate defaults to 44100

# listening history and ListenBrainz -- token from ORCA_LISTENBRAINZ_TOKEN,
# server from ORCA_LISTENBRAINZ_URL (https, or http to localhost)
zig build run -- listens DATABASE [--policy=half|30s|full] [--record=on|off] [--clear]   # policy= record= listens=; a listen short of ListenBrainz's rule stays local; --clear prints cleared=N, deletes listens, queued listens and play counts, keeps ratings and loves
zig build run -- scrobble DATABASE [--status] [--timeout=MS]   # send queued listens and feedback (nothing queued: no request); --status sends nothing
zig build run -- feedback DATABASE IDS (--love | --hate | --clear)   # kept locally; scrobble syncs it to ListenBrainz
zig build run -- love-release DATABASE IDS [--clear]   # album love; kept in the library, never sent
zig build run -- love-artist DATABASE IDS [--clear]   # artist love; kept in the library, never sent

# MusicBrainz and AcoustID matching -- servers from ORCA_MUSICBRAINZ_URL and
# ORCA_ACOUSTID_URL (https, or http to localhost); AcoustID application key from
# -Dacoustid-key=KEY at build time (default AqlfLksN1K)
zig build run -- match DATABASE [--batch=N] [--limit=N] [--no-fingerprints] [--cancel-after=MS]   # each service once per file, 1 request/s
zig build run -- match DATABASE (--track=ID | --release=ID) --reidentify   # again, ignoring IDs and earlier searches; confirmed= counts IDs found again
zig build run -- matches DATABASE TRACK_ID   # source and AcoustID score per proposal; the replaced ID last
zig build run -- verify DATABASE [--track=ID | --release=ID] [--batch=N] [--limit=N] [--cancel-after=MS]   # recording IDs against AcoustID; proposes corrections
zig build run -- corrections DATABASE [--limit N] [--offset N]   # album groups of corrections
zig build run -- accept-correction DATABASE GROUP   # the whole group, locked, in the library only
zig build run -- dismiss-correction DATABASE GROUP
zig build run -- fingerprint DATABASE TRACK_ID   # fpcalc-style DURATION= and FINGERPRINT=
zig build run -- accept-match DATABASE PROPOSAL_ID   # recording ID, title, artist (and album values) in the library only; a correction locked
zig build run -- dismiss-match DATABASE PROPOSAL_ID
zig build run -- accept-matches DATABASE --min-score=0.9   # each file's best match that confident
zig build run -- apply-release DATABASE RELEASE_ID   # the album's values once every Track names one release
zig build run -- match DATABASE --release=ID [--accept-min-score=0.9] [--cover-art]   # Match Album; release= is the album's Release afterwards

# Cover Art Archive -- server from ORCA_COVERARTARCHIVE_URL (https, or http to
# localhost); stores the cover in the library, never in a file
zig build run -- cover-art DATABASE RELEASE_ID   # prints source=embedded|folder|fetched|cached|cached-miss|not-found|no-release-id and bytes

# LRCLIB -- server from ORCA_LRCLIB_URL (https, or http to localhost); caches in
# the library, never writes a file
zig build run -- lyrics DATABASE TRACK_ID --fetch   # local synced, LRCLIB synced, local plain, LRCLIB plain; prints outcome=

# Artist and release info -- MusicBrainz, Wikidata, Wikimedia Commons, Wikipedia,
# ListenBrainz, ListenBrainz Labs and the Cover Art Archive, servers from
# ORCA_MUSICBRAINZ_URL, ORCA_WIKIDATA_URL, ORCA_WIKIMEDIA_URL, ORCA_WIKIPEDIA_URL,
# ORCA_LISTENBRAINZ_URL, ORCA_LISTENBRAINZ_LABS_URL and ORCA_COVERARTARCHIVE_URL
# (https, or http to localhost); kept in the library, never in a file
zig build run -- artist-info DATABASE ARTIST_ID [--fetch] [--force] [--offline] [--lang=xx] [--include-releases]   # totals (own releases, appearances apart), origin=, photo=, biography=, years=, links:, listeners=, related:, elsewhere: (release groups the library lacks, cover=yes|no|-, with --include-releases), outcome=
zig build run -- artist-photo DATABASE ARTIST_ID --out=PATH
zig build run -- related DATABASE ARTIST_ID   # score, name, mbid, library=ID, photo=yes|no
zig build run -- related-photo DATABASE MBID --out=PATH   # a related artist's photo, kept by the artist-info fetch; prints source=, licence=, credit=
zig build run -- release-group-cover DATABASE MBID --out=PATH   # a release group's Cover Art Archive cover, kept by the artist-info fetch; prints source= and bytes
zig build run -- release-info DATABASE RELEASE_ID [--fetch] [--force] [--offline] [--lang=xx]   # description=, release-group=, outcome=

# AcoustID submission of recording IDs from accepted matches or edits -- user key
# from ORCA_ACOUSTID_USER_KEY; point ORCA_ACOUSTID_URL at a local mock when testing
zig build run -- submit-acoustid DATABASE [--dry-run]
```

Frontends:

```sh
ORCA_LIBRARY=/path/to/library.db zig build run-linux   # GTK4 frontend

# Pin the output so an automated run cannot reach the speakers. Unset, the app
# uses the output menu, which defaults to the system default -- device 0.
ORCA_LIBRARY=... ORCA_OUTPUT_DEVICE=$(scripts/silent-sink.sh 1) zig build run-linux

# Point ListenBrainz submission at a local mock instead of listenbrainz.org
ORCA_LISTENBRAINZ_URL=http://127.0.0.1:PORT zig build run-linux

# Point MusicBrainz matching at a local mock instead of musicbrainz.org
ORCA_MUSICBRAINZ_URL=http://127.0.0.1:PORT zig build run-linux

# Point AcoustID lookups and submissions at a local mock instead of acoustid.org
ORCA_ACOUSTID_URL=http://127.0.0.1:PORT zig build run-linux

# Point cover fetches at a local mock instead of coverartarchive.org
ORCA_COVERARTARCHIVE_URL=http://127.0.0.1:PORT zig build run-linux

# Point lyrics fetches at a local mock instead of lrclib.net
ORCA_LRCLIB_URL=http://127.0.0.1:PORT zig build run-linux

# Point artist info at local mocks instead of wikidata.org, commons.wikimedia.org
# and wikipedia.org; orca-cli artist-info and orca-gtk's Artist page read them
ORCA_WIKIDATA_URL=http://127.0.0.1:PORT ORCA_WIKIMEDIA_URL=http://127.0.0.1:PORT \
  ORCA_WIKIPEDIA_URL=http://127.0.0.1:PORT zig build run -- artist-info DATABASE ARTIST_ID --fetch

# Point related artists at a local mock instead of labs.api.listenbrainz.org;
# listeners follow ORCA_LISTENBRAINZ_URL
ORCA_LISTENBRAINZ_LABS_URL=http://127.0.0.1:PORT ORCA_LISTENBRAINZ_URL=http://127.0.0.1:PORT \
  zig build run -- artist-info DATABASE ARTIST_ID --fetch
```

The app opens an output on first play, not at launch, so an idle window does
not hold the user's default sink.

To look at the GUI without putting a window on the user's desktop, run it in a
headless sway session and screenshot it with `grim`; drive it with `wtype`,
which reaches GTK where transient virtual pointers do not. Use
`GSK_RENDERER=cairo` there. Pointer input needs one long-lived virtual pointer
(`zwlr_virtual_pointer_v1`): GTK does not bind a device that exists only for a
single command, as `wlrctl`'s do.

macOS: `zig build` first, then build `apps/macos` with SwiftPM — it links
`zig-out/lib/liborca` through a systemLibrary modulemap. The SwiftUI client is
not built or tested against the current C ABI, and liborca has no macOS audio
output (`docs/roadmap.md`, Later).

Live/host-dependent checks, excluded from the normal test run:

```sh
zig build dependency-smoke      # Linux foreign-library linking pattern
zig build pipewire-live-smoke   # opens a short silent stream on the user's PipeWire server
```

Unit and integration tests require no audio server. The C ABI smoke test (`c-abi-smoke`,
part of `zig build test`) opens an output, so on Linux `zig build test` needs
PipeWire: the build creates `scripts/silent-sink.sh`'s sink and passes its
device id to the test, and fails rather than fall back to the default output.
On the desktop it plays into that sink; `scripts/headless-audio.sh` gives it a
private PipeWire and WirePlumber where no audio server runs, as in CI.

### Testing playback without making noise

This project is developed on somebody's desk, and playback verification used to
mean audible test tones firing while they worked. Do not play test audio to real
hardware.

```sh
device=$(scripts/silent-sink.sh)
zig build run -- play fixtures/audio/tagged-reference.flac "$device"
```

`scripts/silent-sink.sh` creates (idempotently) a `support.null-audio-sink`
PipeWire node and prints its orca device id. It is a *real* sink: it consumes
audio in real time and discards it, so quantum negotiation, render callbacks,
epoch handling, position anchoring, underrun accounting and drain all behave
exactly as on hardware. Verified against `ffprobe` — frame counts match the
source exactly and the negotiated quantum tracks the sample rate (256 at 48 kHz,
235 at 44.1 kHz), so timing-sensitive measurement on it is trustworthy.

The id it prints is **orca's** device id, which is not the PipeWire node id —
liborca's enumeration numbers devices itself. Resolve it through the script or
`orca-cli devices`, never through `pw-dump`.

Pass an index for a second, distinct silent sink. Multi-zone and device-attach
tests need two different outputs, and reaching for real hardware to get the
second one defeats the purpose:

```sh
zone_a=$(scripts/silent-sink.sh 1)
zone_b=$(scripts/silent-sink.sh 2)
```

Note that **omitting the device argument is not silent**: device id 0 means the
system default sink, which is real hardware. Pass an explicit device on every
invocation, including throwaway checks.

### Running a single test

There is no test filter wired into `build.zig` — `zig build test` runs every
test (it is fast and heavily cached, so this is usually fine). If you need
filtering, add `.filters` to the relevant `b.addTest` call rather than trying
to invoke the test binary by hand; the `liborca` module needs translate-C
SQLite, the `alac`, `libxaac` and `chromaprint` packages, libFLAC,
libopusfile, libvorbisfile, libsamplerate, libc, libc++ and the C shims, which
is impractical to
reconstruct on a bare `zig test` command line.

Tests are run from the repository root and load fixtures by relative path
(`fixtures/audio/...`). Do not make test working-directory assumptions.

## Architecture

### The rule that matters most

**A capability is not done until it is reachable from `orca-cli` or the GUI
through the public runtime/ABI path.** No exit criterion may be closed by a
unit test against an isolated component.

This is not a style preference. It is the rule whose absence produced the state
this repository had to be recovered from: ~12,000 lines of well-tested,
genuinely good components, a tag claiming a working music player, and no way to
play music. Every subsystem was an island. The scanner wrote only
`observed_files`; the `tracks` table was empty in any real database; playback
existed solely as a stack-local path in one CLI subcommand; the GTK window had
no row-activation handler. Each piece had passing tests.

The same pattern keeps surfacing as the seams get built. `Gain.setReplayGain`
existed, was correct, and was called by nothing. `fingerprint.findDuplicates`
existed, was correct, was called by nothing, and was O(n²) over a slice that
cannot be constructed at the target scale. Both were found by asking "what
calls this?", which is the question a test never asks.

So: when you finish something, run it. Through `orca-cli`, against real data if
any exists, and look at the output. A green `zig build test` means the parts
work. It says nothing about whether they are connected, and this codebase's
characteristic defect lives exactly there.

### The non-negotiable boundary

`liborca` owns *all* music, library, audio, metadata, mutation, and job
behavior. Frontends own windows, widgets, accessibility, and event loops —
nothing else. When adding a feature, the semantics belong in `liborca` and only
the presentation belongs in `apps/`. A frontend must never grow its own notion
of transport state, library paging, or metadata resolution.

**Frontend language is Zig wherever the platform permits it.** The project is
Zig-first, and that applies to `apps/`, not only to `liborca`. `orca-cli` and
`orca-gtk` are Zig and consume liborca's **public Zig API** directly: the
top level of `liborca/root.zig`, never `liborca.internal` (see `docs/api.md`).
A frontend that needs something only `internal` has is missing a `Runtime`
method; add the method. C appears
in a frontend only where a platform genuinely forces it.

Non-Zig frontends reach the engine through `liborca/orca.h` (a C ABI of opaque
runtime ownership, generational handles, POD snapshots, and **callback-scoped**
query views). String views are valid only for the duration of their callback; no
SQLite row, Zig container, or internal layout crosses the ABI. All `orca_*` calls
for one runtime must come from a single thread (Debug builds return
`ORCA_STATUS_WRONG_THREAD`); see `docs/frontends.md`. The SwiftUI
client uses that ABI because AppKit requires Swift; `tests/c_abi_smoke.c`
exercises it end to end so it cannot rot while macOS is uncompiled.

GTK4 is bound with hand-written `extern fn` declarations rather than generated
bindings. `translate-C` fails on GTK4's headers (glib's `_Pragma` macros
produce thousands of errors), and `zig-gobject` did not build on the snapshot
this frontend was written against. Declare only the symbols the app
actually uses.

### Runtime ownership

`Runtime` (`core.OrcaRuntime` inside liborca) is the process-level root. It is
defined in `core/runtime.zig`; its methods delegate by area to
`core/runtime_*.zig` (jobs, listens, queue, roots, status, zones), and
`core/job_worker.zig` holds `JobWorker`, the thread behind each Job. Every
runtime-visible object is a typed generational handle (`handle.Pool`), so
destroying an object bumps its slot generation and a stale handle can never
resolve to a later occupant of the same slot. Shutdown is strictly
dependency-ordered — work → Zones → Players → Libraries — and `deinit` always
performs shutdown, idempotently. See `docs/ownership.md`.

Hosts drive a single logical control lane via a fixed-capacity command queue
with request-ID-correlated completions. Completion events are lossless and
apply backpressure when full; high-frequency telemetry uses a *separate*
channel that coalesces unread Player-position and Job-progress hints by handle.
Authoritative consumers query snapshots — never reconstruct state from events.
Jobs share one state/progress/cancellation representation across all worker
kinds. See `docs/control-plane.md`.

### Real-time audio boundary

This is the sharpest constraint in the codebase. The render callback must never
allocate, free, lock, wait, perform I/O, or touch SQLite. Decoded PCM lives in
a preallocated `BlockPool`; one producer hands block indices to the callback
over a wait-free SPSC queue, and the callback returns consumed indices over a
second SPSC queue for producer-side reclamation. Missing audio is zero-filled
and counted as an underrun.

Related invariants: transport state is independent of physical output (seeks
publish a new **epoch**, and stale-epoch blocks are discarded rather than
surgically removed from the queue). Track identity travels separately, as
`entry_serial`, because the two questions are incompatible: "is this audio stale
after a seek" must be compared, while "which track is this" must not be, or
gapless breaks. What is *audible* is resolved from the entry serial the render
callback publishes, never from the decode cursor, which runs a whole entry ahead
of the audio; Players decode canonical PCM once and fanout copies it into
independently owned Zone pools so one Zone's failure cannot starve another; the
Player's DSP chain runs on the engine thread before fanout, never in the
callback, and the control lane changes its settings only while the engine is
quiesced. On Linux, PipeWire headers and native object lifetime stay inside a
narrow C shim (`liborca/audio/backends/pipewire_shim.c`); stream
creation/destruction stays on the control side. Read `docs/audio-engine.md`
before touching anything under `liborca/audio/`.

### Persistence

Each `LibraryDatabase` owns one SQLite database and one serialized logical
write lane. Schema is selected by `PRAGMA user_version` with transactional
migrations; unknown newer versions are rejected rather than opened. Artist /
Release / Recording / Track / File / Location are separate tables so
**filesystem paths never become musical identity**. Track FTS uses an
external-content FTS5 table maintained by triggers. Repositories return
bounded, caller-owned pages — never SQLite rows or statements. WAL +
`synchronous=NORMAL`, full-mutex connections, five-second busy timeout, reads
on independent read-only connections. See `docs/database.md`.

### Storage, codecs, scanning

Decoders and analyzers consume `ReadableSource` — positional reads, size, and
stable observed identity, with **no path strings or filesystem handles
exposed**, so provider/mobile/permission-sensitive sources can implement it
honestly. Container detection sniffs bytes, never filename extensions.

Codec-specific state never escapes `liborca/codec/`; playback sees only the
Orca `Decoder` interface, and `SourceSession` owns the registered decoder.
Codec sourcing order: an existing, correct, licensed Zig package, then the
reference C library behind a narrow shim, and an Orca-written codec only when
neither exists. The project is not an exercise in writing codecs, and
correctness outranks purity. FLAC decodes through libFLAC
behind `codec/flac_shim.c` because the pure-Zig package that preceded it
reconstructed mid-side stereo one LSB low, which made a lossless format lossy;
see `docs/codecs.md`.

Scanning is incremental and restart-resumable: unchanged path + storage identity
skips all format/metadata work, commits are bounded, and cancellation is checked
before filesystem work and between entries. Because only changed bytes are
probed, a row written without a probe keeps null properties for ever;
`library/property_backfill.zig` repairs those rows by `files.id` with no walk,
selected through a partial index over exactly the rows that are incomplete, and
reprojects each batch it repairs. Filesystem watchers are an *acceleration only*
— they emit bounded, coalescing, root-scoped hints and never directly insert,
remove, or mutate observed state. See `docs/storage.md`.

### Metadata and file mutation

Three concepts stay strictly separate, and conflating them is the most likely
way to break this subsystem:

- `ObservedFileMetadata` — what the file currently says.
- `OrcaMetadata` — preferred values, user edits, locks, provider proposals.
- `EffectiveMetadata` — a resolved view under an explicit preference policy.

Every value carries provenance, and a user lock outranks automatic resolution.
Scanner observations never update Track metadata and never write a file.
Format-specific concerns (ID3v1 genre numbers, fixed-width fields, Vorbis
comment keys) terminate at the reader/writer and must not leak into the
canonical model.

File writes and moves execute **only** from an explicitly approved immutable
`MutationPlan`. Source identity and intended after-identity are journaled to
SQLite before the filesystem changes; tag writes stage-and-fsync a complete
same-filesystem copy and retain the exact original as a journaled backup.
Groups undo in reverse action order, startup recovery converges toward the
original state, and if a target changed externally Orca keeps every file,
records `needs_reconciliation`, and refuses to claim rollback succeeded. See
`docs/metadata.md`.

### Network and providers

`docs/providers.md` holds the rules Orca follows toward every provider:
identification, rate limits, backoff, credentials and listen eligibility.

All provider traffic passes through **one** rate-limited, retrying HTTP
boundary (`network.Gateway`) with bounded responses, service identification,
and an explicit offline mode. Do not add a second HTTP path. Credentials come
from platform secure-storage adapters, are never stored in an Orca library, and
must never enter durable cache keys. Provider matches remain reviewable
proposals with explicit confidence until accepted; acceptance is a transaction
into Orca metadata that preserves user locks and does **not** write media files.

## Conventions

- **Public API.** A new `Runtime` method's parameter and return types are
  exported at the top of `liborca/root.zig`; test-only hooks stay private.
- **Subsystem roots.** Each `liborca/<subsystem>/root.zig` re-exports every file
  as a `pub const` and mirrors that list in a `test { _ = @import(...); }`
  block. Add new files to both.
- **Interfaces are context+vtable structs** (`ReadableSource`, `Transport`,
  `Clock`, `Decoder`) rather than generics, which keeps the C ABI and platform
  adapters possible.
- **Inject time and I/O for determinism.** Provider and network tests supply
  `network.testing`'s `ScriptedTransport` and `TestClock`
  (`liborca/network/testing.zig`) through those vtables — no live network, no
  wall-clock sleeps. Follow that pattern for anything with retry or rate-limit
  behavior.
- **Platform code is contained.** `liborca/platform.zig` switches on
  `builtin.os.tag`; foreign headers and native object lifetimes live in the
  adapter (or C shim) for that platform and nowhere else.
- **Test names are behavioral sentences** describing the invariant being
  protected, e.g. `test "removed handles stay stale when their slot is reused"`.
- Bounded everything: fixed-capacity queues, 512-row query pages, bounded
  commits, bounded retries. Prefer rejecting or applying backpressure over
  unbounded growth.
- Every commit that adds, fixes, refactors or removes something adds its
  entry to the Unreleased section of `CHANGELOG.md` in the same commit.
  Versioning and the release steps are in
  [docs/roadmap.md](docs/roadmap.md#releases).
