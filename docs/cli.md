# Command-line interface

This file covers `orca-cli`, the command-line client of liborca's public Zig
API: build and verification commands, every `orca-cli` command with its output
format, environment variables, playlist and rating commands, and how to verify
playback without real audio hardware. Running `orca-cli` with no command, an
unknown command or a wrong argument count prints the usage.

## Build and verification commands

Run these inside the dev shell (`nix develop`, or automatically with direnv).

```sh
nix build                     # package: orca-cli, orca-gtk, liborca, orca.h
nix flake check
nix fmt                       # formats Nix files
zig fmt --check liborca apps benchmarks tests build build.zig

zig build                     # static + shared liborca, orca-cli, headers; orca-gtk
zig build -Dgtk=false         # the same without orca-gtk and its files
zig build lib                 # static liborca and orca.h only; CI cross-builds it with -Dtarget=aarch64-macos
zig build test                # unit, integration, C ABI smoke and ABI checks and the PipeWire link smoke
zig build abi-compat          # orca.h keeps the layouts, values and functions of tests/abi/orca-0.1.0.h
zig build fuzz                # replay the parser fuzz targets' seeds
zig build fuzz --fuzz[=N]     # fuzz them; N iterations per target, unlimited opens the web UI
zig build package-check       # build examples/embed and an install from the fetched build.zig.zon package
scripts/headless-audio.sh zig build test   # tests against a private PipeWire and WirePlumber, as CI runs them
zig build run -- --version    # orca-cli
zig build bench               # 500k-track persistence benchmark
zig build -Doptimize=ReleaseFast dsp-bench   # scalar vs SIMD DSP kernels
```

## CLI commands

```sh
zig build run -- demo
zig build run -- devices   # id, name, kind (usb|pci|bluetooth|hdmi|virtual|unknown), then `rates=44100-384000 depths=16,24,32 channels=2 state=active|suspended|unavailable`, or `rates=- depths=- channels=- state=unknown` when PipeWire did not answer within 500 ms; the silent sink is virtual

# library
zig build run -- scan DATABASE ROOT [--reprobe]   # --reprobe reads every file again, skipping none; `progress stage=discover|read_tags|done files= total= albums= current=` lines, then the counters
zig build run -- estimate PATH   # audio_files=N truncated=no|yes; counts audio files by their bytes, up to 100000, without adding PATH
zig build run -- roots DATABASE   # id, enabled, path, available=yes|no tracks=N unavailable=N volume= last_seen_at=
zig build run -- availability DATABASE [RELEASE_ID...]   # offline_roots= unavailable_tracks= unavailable_releases=, an `offline` line per root, then release= available=yes|no
zig build run -- add-root DATABASE ROOT   # binds an existing root to the volume it is on; a relative ROOT is made absolute against the working directory
zig build run -- remove-root DATABASE ID   # forgets the root's files and tracks, and the recordings no other file holds with their loves, ratings, play counts and playlist entries; listens stay; nothing on disk
zig build run -- relocate-root DATABASE ID PATH   # moves a root that moved on disk, keeping its ids; a relative PATH is made absolute; binds the volume PATH is on, then reconciles
zig build run -- folders DATABASE [ROOT_ID [PATH]]   # roots with totals; or a `folder: release= tracks= images= last_scanned_at=` line, subfolders with recursive counts, files with track ids, then images; entries end kind= status=imported|unreadable, images role=
zig build run -- watch DATABASE [--quiet=MS] [--max-delay=MS] [--once] [--limit=MS] [--maintenance[=MS]] [--pause-after=MS] [--resume-after=MS]   # Linux; reconciles folders as they change; --maintenance also verifies recording IDs while idle; --pause-after/--resume-after pause and resume the Library's Jobs, printing `jobs: state=paused|running queue=N maintenance=STATE`
zig build run -- reconcile DATABASE ROOT_ID [DIR...]   # rescans the root or only DIRs under it; marks missing only under them
zig build run -- project DATABASE
zig build run -- backfill DATABASE [--force] [--cancel-after=MS]   # probes files missing properties, then measures covers observed before covers were measured
zig build run -- health DATABASE [OFFSET]   # file_id, severity, kind, action, path, details
zig build run -- health DATABASE --kind=KIND [OFFSET]   # the same lines, one kind only
zig build run -- health DATABASE --kind=artwork_problem --albums [OFFSET]   # one line per album by title: release id, worst problem, files=N, size=WxH|-, title; then `albums N`
zig build run -- health DATABASE --summary   # kind, highest severity, count, files, bytes per kind with an issue; duplicate bytes are the redundant copies only; then `missing_files N`, Tracks with no present file, and `metadata_issues N`, open consistency issues
zig build run -- formats   # each format Orca reads, `NAME<TAB>planned` for one recognized but not yet decoded
zig build run -- sources   # id, name, url, licence, supplies, then licence url when there is one; needs no database
zig build run -- stats DATABASE   # artists=, releases=, tracks=, files=, bytes=, duration_ms=, last_scan_finished_at=, last_analysis_at=, last_duplicate_scan_at= (- when none), listens=
zig build run -- cache DATABASE [--clear]   # artwork_bytes= photo_bytes= lyrics_bytes= info_bytes= of fetched provider data; --clear deletes it and prints what it held; embedded and folder art and local lyrics stay
zig build run -- health-dismiss DATABASE FILE_ID KIND   # hidden until the file's bytes change
zig build run -- health-restore DATABASE FILE_ID KIND
zig build run -- analyze DATABASE AUDIO
zig build run -- analyze-library DATABASE [--batch=N] [--threads=N] [--cancel-after=MS]
zig build run -- duplicates DATABASE [--batch=N] [--cancel-after=MS]   # examined= exact= (same bytes) identical= (same lossless audio, other bytes) likely= (fingerprints match) unique= unreadable= batches=, then uncomparable= comparisons= truncated_buckets=; one finding per file, the strongest
zig build run -- duplicates DATABASE --groups [--limit N] [--offset N]   # id, title, artist, copies= same_recording=yes|no similarity=0.99|- bytes_redundant= verdict=exact_duplicate|identical_audio|likely_duplicate, then `groups= bytes=`; a group's id is its lowest file id
zig build run -- duplicates DATABASE --group=ID   # group= same_recording= similarity= verdict=, then the copies, suggested first: file= track= keep=yes|no locations= playlists= codec= rate= depth= bytes= ... path=
zig build run -- merge-duplicate DATABASE KEEP_TRACK_ID FROM_TRACK_ID   # fills KEEP's missing Orca values, user genres, rating and feedback from FROM; KEEP's locks win; no file written
zig build run -- keep-both DATABASE FILE_ID FILE_ID   # dismisses both files' duplicate issues
zig build run -- consistency DATABASE [--batch=N] [--cancel-after=MS]   # finds where a Release's Tracks disagree; `releases= issues= batches= cancelled=`, then the open count per category and `open=`
zig build run -- issues DATABASE [--category=album_artist|dates|track_numbering|genre_variants|musicbrainz_differs] [--limit N] [--offset N]   # group= release= category= field= tracks= title= artist=, then `option=ID value= support=` and `proposal track= title= current= proposed=` lines, then `issues=N`
zig build run -- apply-issue DATABASE GROUP (--option=ID | --custom=TEXT) [--tracks=IDS]   # locked Orca values through the edit path, locks kept; --tracks changes only those of the issue's Tracks; prints changed=N; no file written
zig build run -- skip-issue DATABASE GROUP   # hidden until the Release's values change
zig build run -- ignore-duplicate DATABASE GROUP_ID   # dismisses the duplicate issues of the whole group
zig build run -- jobs DATABASE [--start=scan|analysis|duplicates|backfill|project|consistency]... [--pause-after=MS] [--resume-after=MS]   # one runtime: each after the first prints `waiting after=`; prints every state change until all finish
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
zig build run -- artwork DATABASE (--track=ID | --release=ID) [--out=PATH] [--kind=front|back|booklet] [--set=PATH | --clear]   # --kind, --set, --clear with --release; --set keeps a chosen cover, shown before any other
zig build run -- covers DATABASE [--limit N] [--offset N]   # a page of covers via the artwork loader
zig build run -- lyrics DATABASE TRACK_ID [--fetch]   # .lrc sidecar or embedded; synced before plain; prints source_name= (file name, embedded, LRCLIB) and offset_ms=; --fetch: see LRCLIB below
zig build run -- edit DATABASE IDS [--title=…] [--artist=…] [--album=…] [--album-artist=…] [--date=…] [--track=N] [--disc=N] [--compilation=0|1] [--recording-id=MBID] [--composer=…] [--comment=…] [--explicit=yes|no|clean] [--genre=A;B] [--clear=FIELD]…   # library only; no edits lists the values held; FIELD is a metadata field name such as album_artist or musicbrainz_recording_id, or genre
zig build run -- fields DATABASE IDS   # FIELD value= mixed=yes|no edited=yes|no per editable field, then disc_total= and `cover source=none|chosen|embedded|folder|fetched file= mime= tracks=N/M`
zig build run -- write-tags DATABASE IDS [--approve=DIGEST]   # preview, then write FLAC/MP3/ADTS
zig build run -- undo-tags DATABASE GROUP
zig build run -- prune-backups DATABASE [--older-than=DAYS]   # deletes backups; those writes cannot be undone
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
zig build run -- smart-playlist-count DATABASE RULES_FILE [--sample=N]   # count= and duration_ms= the rules match, then the first N Tracks; stores nothing

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
    [--save-state]   # at the end, saves the queue and position for resume; prints `saved-state entries= index= position_ms=`
    # records listens in the play history; never sends them
    # an entry that cannot be opened prints `failure=TRACK_ID:file_missing|folder_unavailable|codec_unavailable|decode_error|unsupported_channels` and play goes on to the next
zig build run -- play-folder DATABASE ROOT_ID PATH --device=ID [--shuffle] [--limit=MS]   # every Track below PATH, recursively in path order
zig build run -- resume DATABASE --device=ID [--play] [--limit=MS]   # restored entries= index= position_ms= skipped_missing=, the queue from the saved index, then `status transport= index= entries= track= position_ms= resumed_from_ms= repeat= shuffle=`; --play plays for MS (default 10 s); the Library keeps where it stopped
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
zig build run -- matches DATABASE --releases [--bucket=confident|needs_review|unmatched|reviewed] [--min-score=0.9] [--filter=TEXT] [--limit=N] [--offset=N]   # id, bucket, title, artist, tracks=, candidate= confidence= title= date= candidate_tracks=, placed= needs_pairing= (- without a tracklist snapshot), then `confident= needs_review= unmatched= reviewed=`
zig build run -- matches DATABASE --release=ID [--candidate=MBID] (--evidence | --diff | --dismiss=MBID)   # evidence: fingerprints=N/M durations_within_1s= date_agrees= artist_agrees= title_agrees=, then note=; diff: a line per field, then per Track with local_artist= candidate_artist=; dismiss: Not This Release
zig build run -- verify DATABASE [--track=ID | --release=ID] [--batch=N] [--limit=N] [--cancel-after=MS]   # recording IDs against AcoustID; proposes corrections
zig build run -- corrections DATABASE [--limit N] [--offset N]   # album groups of corrections
zig build run -- accept-correction DATABASE GROUP   # the whole group, locked, in the library only
zig build run -- dismiss-correction DATABASE GROUP
zig build run -- fingerprint DATABASE TRACK_ID   # fpcalc-style DURATION= and FINGERPRINT=
zig build run -- accept-match DATABASE PROPOSAL_ID   # recording ID, title, artist (and album values) in the library only; a correction locked
zig build run -- dismiss-match DATABASE PROPOSAL_ID
zig build run -- accept-matches DATABASE --min-score=0.9   # each file's best match that confident
zig build run -- apply-release DATABASE RELEASE_ID   # the album's values once every Track names one release
zig build run -- apply-release DATABASE RELEASE_ID --fields=album,album_artist,date,release_id,track_titles   # those fields of the best candidate's tracklist snapshot, locked: release values on every Track with a file, release-track values on placed Tracks; prints release= values_written= track_values= release_values_only= artist_ids=known|unknown reviewed=ID|- (the Release's ID after reprojection when the Apply left no Track alone and so marked it reviewed, whatever fields it chose and whatever still differs), then left_alone track= reason=not_placed|no_play_file title= lines
zig build run -- match DATABASE --release=ID [--accept-min-score=0.9] [--cover-art]   # Match Album; release= is the album's Release afterwards
zig build run -- release-alignment DATABASE RELEASE_ID [RELEASE_MBID]   # the release's tracklist snapshot (default: the best candidate) against the Tracks: a line per release track, DISC-POSITION status track= source= title_equal= length_close= position_equal= delta_ms=, then not_on_release lines, then unlisted_pairing lines for pairings whose release track the snapshot does not list
zig build run -- pair-track DATABASE RELEASE_ID TRACK_ID RELEASE_TRACK_MBID [RELEASE_MBID]   # pairs the Track with that release track of the release (default: the best candidate); its recording and release-track IDs become locked user values; prints origin=confirmed_suggestion or by_hand
zig build run -- unpair-track DATABASE RELEASE_ID TRACK_ID   # removes the Track's pairing and puts back the IDs it replaced where its files still hold the paired ones
zig build run -- mark-release-reviewed DATABASE RELEASE_ID [RELEASE_MBID]   # moves the Release to matches --releases --bucket=reviewed while it stays as reviewed, keeping its values even where they differ; refused unless every Track is placed
zig build run -- unmark-release-reviewed DATABASE RELEASE_ID   # forgets the Release's review so it returns to its own bucket; prints unreviewed release=ID

# Cover Art Archive -- server from ORCA_COVERARTARCHIVE_URL (https, or http to
# localhost); stores the cover in the library, never in a file
zig build run -- cover-art DATABASE RELEASE_ID   # prints source=chosen|embedded|folder|fetched|cached|cached-miss|not-found|no-release-id and bytes
zig build run -- cover-art DATABASE RELEASE_ID --candidates   # up to 8 archive images, release's then release group's fronts: candidate= kind= size=WxH|- mime= approved= thumbnail_bytes= release=; each full image fetched to measure, then dropped; source=partial when the group's index would not come
zig build run -- cover-art DATABASE RELEASE_ID --use=CAA_ID[:front|back|booklet]   # fetches a listed image again in full and keeps it as the chosen cover of that kind; prints source=chosen

# LRCLIB -- server from ORCA_LRCLIB_URL (https, or http to localhost); caches in
# the library, never writes a file
zig build run -- lyrics DATABASE TRACK_ID --fetch   # local synced, LRCLIB synced, local plain, LRCLIB plain; prints outcome=

# Artist and release info -- MusicBrainz, Wikidata, Wikimedia Commons, Wikipedia,
# ListenBrainz, ListenBrainz Labs and the Cover Art Archive, servers from
# ORCA_MUSICBRAINZ_URL, ORCA_WIKIDATA_URL, ORCA_WIKIMEDIA_URL, ORCA_WIKIPEDIA_URL,
# ORCA_LISTENBRAINZ_URL, ORCA_LISTENBRAINZ_LABS_URL and ORCA_COVERARTARCHIVE_URL
# (https, or http to localhost); kept in the library, never in a file
zig build run -- artist-info DATABASE ARTIST_ID [--fetch] [--force] [--offline] [--lang=xx] [--include-releases]   # totals (own releases, appearances apart), origin=, photo=, biography=, years=, links:, listeners=, related:, elsewhere: (albums and EPs the library lacks, cover=yes|no|-, with --include-releases), outcome=
zig build run -- artist-photo DATABASE ARTIST_ID --out=PATH
zig build run -- related DATABASE ARTIST_ID   # score, name, mbid, library=ID, photo=yes|no
zig build run -- related-photo DATABASE MBID --out=PATH   # a related artist's photo, kept by the artist-info fetch; prints source=, licence=, credit=
zig build run -- release-group-cover DATABASE MBID --out=PATH   # a release group's Cover Art Archive cover, kept by the artist-info fetch; prints source= and bytes
zig build run -- release-info DATABASE RELEASE_ID [--fetch] [--force] [--offline] [--lang=xx]   # description=, release-group=, outcome=

# AcoustID submission of recording IDs from accepted matches or edits -- user key
# from ORCA_ACOUSTID_USER_KEY; point ORCA_ACOUSTID_URL at a local mock when testing
zig build run -- submit-acoustid DATABASE [--dry-run]
```

## Environment variables

`orca-cli` and `orca-gtk` select provider servers from the environment so
tests and development runs use local mocks. Each server variable takes an
`https` URL, or `http` to localhost. `orca-cli` fails with `InvalidServerUrl`
on any other value; `orca-gtk` ignores it.

| Variable | Effect | Read by |
| --- | --- | --- |
| `ORCA_LISTENBRAINZ_URL` | ListenBrainz server | CLI, GTK |
| `ORCA_MUSICBRAINZ_URL` | MusicBrainz server | CLI, GTK |
| `ORCA_ACOUSTID_URL` | AcoustID server | CLI, GTK |
| `ORCA_COVERARTARCHIVE_URL` | Cover Art Archive server | CLI, GTK |
| `ORCA_LRCLIB_URL` | LRCLIB server | CLI, GTK |
| `ORCA_WIKIDATA_URL` | Wikidata server | CLI |
| `ORCA_WIKIMEDIA_URL` | Wikimedia Commons server | CLI |
| `ORCA_WIKIPEDIA_URL` | Wikipedia server | CLI |
| `ORCA_LISTENBRAINZ_LABS_URL` | ListenBrainz Labs server | CLI |
| `ORCA_LISTENBRAINZ_TOKEN` | ListenBrainz user token for `scrobble` | CLI |
| `ORCA_ACOUSTID_USER_KEY` | AcoustID user key for `submit-acoustid` | CLI |
| `ORCA_LIBRARY` | Library `orca-gtk` opens | GTK |
| `ORCA_OUTPUT_DEVICE` | Orca device id that overrides the output menu | GTK |
| `ORCA_GTK_DEBUG` | Debug topics `art`, `frames` and `reveal`, separated by commas or spaces | GTK |

The AcoustID application key is set at build time with
`-Dacoustid-key=KEY`; the default is `AqlfLksN1K`.

## Frontend launch commands

```sh
ORCA_LIBRARY=/path/to/library.db zig build run-linux   # GTK4 frontend

# Pin the output so an automated run cannot reach the speakers. Unset, the app
# uses the output menu, which defaults to the system default (device 0).
ORCA_LIBRARY=... ORCA_OUTPUT_DEVICE=$(scripts/silent-sink.sh 1) zig build run-linux
```

The app opens an output on first play, not at launch, so an idle window does
not hold the default sink.

`scripts/headless-gui.sh PAGE OUT.png [STEP...]` runs `orca-gtk` in a private
headless sway session, drives it and saves screenshots; it never opens a window
on the desktop.

Host-dependent checks excluded from the normal test run:

```sh
zig build dependency-smoke      # Linux foreign-library linking pattern
zig build pipewire-live-smoke   # opens a short silent stream on the user's PipeWire server
```

Unit and integration tests need no audio server. The C ABI smoke test
(`c-abi-smoke`, part of `zig build test`) opens an output, so on Linux
`zig build test` needs PipeWire: the build creates the sink of
`scripts/silent-sink.sh`, passes its device id to the test and fails rather
than fall back to the default output. `scripts/headless-audio.sh` provides a
private PipeWire and WirePlumber where no audio server runs, as in CI.

## Playlists and ratings

Playlists and ratings are kept in the Library and belong to a Recording, not
to a Track or a file. An edit that gives a Track a new id keeps its Recording,
so playlist entries and ratings follow it. The Zig and C contracts are in
[the API reference](api.md#playlists); the tables are in
[the database reference](database.md#playlists-and-ratings). Nothing here
writes a file or sends anything to a service.

### Ratings

A rating is 1 to 100; no rating is unrated. `--stars=N` stores `N * 20`.
`rate` rates or clears the song behind each Track, at most 512 Tracks per call,
and prints how many Tracks changed and how many were skipped for having no
Recording. A rating outside 1 to 100 is `InvalidRating`. `tracks --sort rating`
orders by rating with unrated Tracks last in both directions.

### Playlists

A playlist is a name and an ordered list of entries, each naming a Recording;
one Recording may appear several times.

- Names are trimmed, not empty (`InvalidPlaylistName`) and unique
  (`PlaylistNameTaken`).
- Positions run from 0 to n - 1. `playlist-add`, `playlist-remove` and
  `playlist-move` renumber the entries after them in one transaction.
- A playlist holds at most 10,000 entries (`PlaylistFull`, nothing inserted);
  one call inserts at most 512 Tracks.
- An entry resolves to the Track of its Recording with the lowest id. An entry
  whose Recording has no Track is listed as `unavailable` and skipped by
  playback and export.
- `play-tracks --playlist=ID` replaces the queue with the available entries
  and fails with `PlaylistEmpty` when there are none.
  `play-tracks --save-queue=NAME` saves the current entry and every entry after
  it as a playlist.
- A description is at most 4,096 bytes. A playlist has at most eight tags of 1
  to 64 bytes each after trimming; `--tags` replaces them, keeping the given
  order and dropping repeats.
- `playlists` filters by kind, pin, creator and a name substring, and sorts by
  name, last update, creation or entry count. Smart playlists sort after manual
  ones by entry count because their count is evaluated, not stored.
- Removing a root and scanning the folder again creates new Recordings, so the
  entries of the old ones become unavailable.

### Smart playlists

A smart playlist's entries are the Tracks its rules match when it is read, one
per Recording, in the rules' order and up to their limit. Adding, removing or
moving its entries fails with `PlaylistIsSmart`. `RULES_FILE` is version 1
rules JSON of at most 16 KiB, described in
[the API reference](api.md#smart-playlist-rules). `smart-playlist-rules` prints
a smart playlist's rules, or replaces them from `RULES_FILE` first.
`smart-playlist-count` stores nothing; `--sample=N` prints the first N matches,
at most 512. Playback and M3U export take the entries as they are at that
moment.

### M3U import

`playlist-import` reads an `.m3u` or `.m3u8` file and creates a playlist in one
transaction.

- The file is at most 4 MiB with at most 10,000 entries; a larger one fails
  with `PlaylistTooLarge` and creates nothing. A file with no entry fails with
  `PlaylistEmpty`.
- A leading UTF-8 byte order mark is dropped; CRLF, LF and CR end a line. A
  file that is not valid UTF-8 is read as Latin-1.
- Blank lines and `#` lines are skipped, except `#EXTINF:<seconds>,<text>`,
  which describes the entry on the next line.
- The playlist is named `--name`, else the file name without its extension; a
  taken name gets ` (2)`, ` (3)` and so on. It is marked imported.

Each entry is matched in this order:

1. A `file://` URI with an empty host is percent-decoded to a path; any other
   `scheme://` entry is unmatched. A relative path is resolved against the
   playlist file's folder. The path is normalised lexically; symbolic links
   are not followed.
2. A location whose path equals it, preferring `present`, then `unverified`,
   then `missing`. Its file gives the Recording.
3. When no location matched, the `#EXTINF` text split at the first `" - "` into
   artist and title. It matches when exactly one Recording has a Track with
   that artist and title, compared after Unicode folding, and a length within
   2 s of the stated one. An entry stating `-1` seconds matches on artist and
   title alone.
4. Otherwise the entry is unmatched and left out.

The command prints the counts matched by path and by `#EXTINF`, the unmatched
count and the first 50 unmatched lines. Import never scans: a path the Library
has not seen is unmatched.

### M3U export

`playlist-export` writes an extended M3U file in UTF-8 with LF line endings:

```text
#EXTM3U
#EXTINF:226,ABBA - Intermezzo No. 1
/mnt/Media/Music/ABBA/ABBA (1975)/ABBA - ABBA - 09 - Intermezzo No. 1.flac
```

- Each available entry is written with its length in whole seconds (`-1` when
  unknown), `artist - title` (the title alone without an artist) and the path
  of the location playback would open. Line breaks in tags become spaces.
- `--relative` writes paths relative to the target's folder. Paths are never
  URI-encoded.
- Entries without a Track, and paths containing a line break, are skipped and
  counted.
- The file is written beside the target, synced, renamed over it and its folder
  synced, so a reader sees the old file or the new one. A failed export leaves
  no temporary file. An existing target fails with `PathAlreadyExists` unless
  `--force` is given.

## Playback verification

Do not play test audio through real hardware. Create an idempotent null sink and
pass its Orca device id explicitly:

```sh
device=$(scripts/silent-sink.sh)
zig build run -- play fixtures/audio/tagged-reference.flac "$device"
```

The printed id belongs to Orca's enumeration, not PipeWire's node id. Resolve
it through the script or `orca-cli devices`, never `pw-dump`. The sink consumes
audio in real time, so callback timing, underruns, draining and negotiated
quantum remain representative. Pass indexes when a check needs distinct zones:

```sh
zone_a=$(scripts/silent-sink.sh 1)
zone_b=$(scripts/silent-sink.sh 2)
```

Omitting a device selects the system default output. A chosen device that is
missing or removed is never replaced by another: `play`, `play-tracks`,
`play-folder` and `resume --play` exit with an error once its output has
failed.

## Running tests

`zig build test` runs the full suite; `build.zig` does not expose a test filter.
When filtering is necessary, add `.filters` to the relevant `b.addTest` call.
Do not reconstruct a bare `zig test` invocation: the liborca test module needs
its translated SQLite bindings, Zig packages, codec libraries, libc, libc++ and
C shims. Tests run from the repository root and load fixtures by relative path.
