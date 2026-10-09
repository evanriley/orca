# Library persistence

This file covers the Library's SQLite database: its file, locking and
concurrency contracts, file identity, projection into Tracks, paging, and what
each table is for. The schema in `liborca/database/migrations.zig` is the source
for columns, types, constraints and indexes; this file names only the columns
that carry identity or a contract.

## The Library file

A Library is one SQLite database file at a path the caller gives
`Runtime.openLibrary`; `orca-gtk` uses `$XDG_DATA_HOME/orca/library.db` unless
`ORCA_LIBRARY` names another. Each `LibraryDatabase` owns one write connection,
one serialized write lane and independent read-only connections for snapshots.
The path is copied at open. `Runtime.openLibrary` associates the database with a
typed generational `LibraryHandle`; explicit removal or ordered runtime shutdown
closes it.

Files beside the database, named from its path: `-wal` and `-shm` (SQLite WAL
state), `.orca-journal.lock` (mutation-journal ownership), `.orca-scan.lock`
(one walk at a time) and `.orca-backups/` (tag-write backups,
[metadata.md](metadata.md#tag-write-files)). A Library with no file (in-memory)
has none of them.

`PRAGMA user_version` selects the schema. The current version is 3. Each
version has one step in `migrations.steps`: `baseline` creates version 1, `v2`
adds to it without rebuilding any table, and `v3` drops and recreates the Daily
Mix tables, whose rows are made again on the next run. `migrations.apply` runs
every step after the database's version, and sets the new version, in one
transaction, so a failed step leaves the database at its old version. A
database at version 0 gets the whole schema, versions 1 and 2 are upgraded in
place, version 3 opens unchanged, and any other `user_version`, negative or
newer, is refused with `error.SchemaVersionTooNew` and left untouched. A
Library at version 3 cannot be opened by Orca 0.3.0 or earlier.
`LibraryDatabase.open` then runs mutation-journal recovery under the journal
lock; when another process holds it, recovery is deferred to the next holder.

## Concurrency

- The primary connection uses WAL and `synchronous=NORMAL`. Every connection
  sets `foreign_keys=ON`, a five-second busy timeout and SQLite's full-mutex
  mode.
- The primary connection creates the scratch TEMP tables of sweeps, cache
  clears and root removal when it opens, and those paths only empty and fill
  them. A TEMP schema change on a connection expires every statement prepared
  on it, which aborts a read in progress on another thread.
- One write lane (`std.Io.Mutex`, futex-backed, not a spinlock) serializes
  complete write transactions. A scan holds it across one bounded 256-row
  transaction while UI threads read.
- One process at a time owns the mutation journal: the holder of an exclusive
  `flock` on `<database>.orca-journal.lock`, taken without waiting by open's
  recovery and by each tag write, undo and prune
  ([metadata.md](metadata.md#the-journal-lock)).
- One scan or reconcile at a time walks a Library, across processes: the holder
  of an exclusive `flock` on `<database>.orca-scan.lock`. A walk that cannot
  take it is refused with `error.LibraryScanRunning`
  ([storage.md](storage.md#one-walk-at-a-time)).

### Process-wide lock replacement

On Linux, `liborca/database/sqlite_locks.zig` replaces the `fcntl` system call
of SQLite's `unix` VFS so it takes open file description (OFD) locks instead of
POSIX record locks, before the first connection opens. A POSIX lock belongs to
the process, so any `close` of the database, `-wal` or `-shm` file anywhere in
it (a GTK file dialog browsing the folder) releases the lock; a second Orca
process then takes itself for the last connection, checkpoints and deletes the
WAL, and the first process's later writes go to an unlinked file and are lost.
An OFD lock belongs to the open file and survives other closes.

- The override is process-wide and applies to every SQLite connection in the
  process, the embedder's included.
- The first `Runtime.init`, or else the first database open, installs it once
  per process; concurrent first calls install it once and all see the result.
  Nothing removes it.
- SQLite's system-call table must not change under open connections, so the
  install is refused when an open file descriptor of an SQLite database file
  exists in the process, found by scanning `/proc/self/fd` for the database
  magic. A connection to an in-memory database takes no file locks and does
  not refuse the install, and a database file that has never been written has
  no magic and holds no locks, so it does not refuse the install either.
  Detection no longer depends on SQLite's memory statistics. It is decided
  once: after a refusal, or when the `fcntl` in effect is no longer the
  replacement, every database open fails with
  `error.SqliteLocksNotInstalled`.
- An embedder's own multi-connection SQLite use in rollback-journal mode in the
  same process can see spurious `SQLITE_BUSY`.
- macOS has no OFD locks and keeps POSIX locks
  ([roadmap.md](roadmap.md#known-issues)).

## Bounds

Pages are at most `columns.max_page` (512) rows, and an out-of-range page
request is refused, not clamped. Batched writes take at most `max_page` ids per
transaction. `max_playlist_entries` and `max_saved_entries` are 10,000, and job
history keeps the newest 1,000 rows.

## Identity

`files.id` is identity. A file is one encoding of some audio; a location is one
place that encoding can currently be found, on one volume. No table outside
`locations` and `mutation_operations` stores a path, so renaming, moving or
re-tagging a file never detaches the metadata, locks, analysis results or health
issues attached to it. Artists, Releases, Recordings and Tracks are separate
from files and locations, so paths never become musical identity.

A scan re-finds a file through a cascade, cheapest first:

1. `locations(volume_id, uri)`: the same path on the same volume.
2. `locations(volume_id, native_inode, size_bytes, modified_ns)`: a rename or
   move within one filesystem.
3. `files.quick_hash` (BLAKE3 over the first 64 KiB, last 64 KiB and size,
   `storage/quick_hash.zig`) nominates; `files.content_hash` (BLAKE3-256 over
   every byte, `storage/content_hash.zig`; `content_hash_algorithm` 1) confirms.
   This catches copies, cross-volume moves and restores.
4. `files.audio_hash`, over the decoded audio only, so a tag write does not
   change it. Only `library/analysis_pass.zig` writes it; an update that records
   a different `quick_hash` clears it. `audio_hash_tier` is 1 for a lossless
   source's integer samples, 2 for decoded float samples; only equal tier-1
   hashes are the same audio ([analysis.md](analysis.md#the-audio-hash)).

The duplicate pass claims only what each rung proves: `exact_duplicate` for a
second present location or equal content hash, `identical_audio` for equal
tier-1 audio hashes in different bytes, `likely_duplicate` for equal tier-2
hashes or matching fingerprints
([analysis.md](analysis.md#what-the-three-findings-mean)).

### Tier 3 joins

A quick hash alone never joins a path to a file, because files with the same
size, head and tail can differ in the middle. A nominee is joined when it
records an equal content hash, or records none and the bytes at one of its other
`present` or `unverified` locations, still with the inode, size and mtime
recorded, hash the same. A nominee that cannot be decided this way (its
locations cannot be read as recorded, it is past the eighth for one quick hash,
or it has no content hash and more than four other locations) is never joined;
the path becomes a file of its own unless another nominee confirms. A nominee
with no content hash and no readable location left (a cross-volume move or
restore whose old path is gone) is joined on the quick hash alone when no other
nominee confirms, which keeps Orca's values and locks across the move.

Only a path that reaches tier 3, shares a quick hash with another path in its
batch, or changed while its file is present elsewhere is hashed whole. Hashes
are taken before the batch's transaction, because nothing under the write lane
reads a file, and written in the transaction that records their paths, so a
cancelled batch leaves none. `FileRepository.contentQuestion` and
`content_measurements` take the measurements and
`FileRepository.resolveForBytes` re-checks inside the transaction. A path
re-found through tier 1 or 2 is not hashed, so a file re-found at an identity
none of its locations records forgets its content hash.

### Divergence

Byte-identical copies are one file at several locations. A path re-found through
tier 1 or 2 whose file is still present at another path stays on that file only
when its bytes are proven to be the other path's: its location is `present` and
still records the inode, size and mtime read; or it changed or returned from
`missing` or `unverified`, the file records the same `quick_hash`, and the
path's content hash equals the file's recorded one (or that of the first other
copy read with its recorded identity, when the file records none). Otherwise the
path has diverged and gets a file of its own: a file is never shared without
proof. A middle-only edit, which keeps the quick hash, therefore splits the
edited copy off.

`FileRepository.resolveForBytes` decides and `forkLocked` makes the new file in
the batch's transaction; `resolveOrCreateFile` applies the same rule, so a scan,
a reconcile, a watcher pass, the re-observation after a tag write and `orca-cli
analyze PATH` agree. The split moves the location, copies Orca's values and
locks with `written_at` cleared, and re-points journal rows naming the path.
Analysis results, the audio hash, health issues, identification proposals and
searches, AcoustID submissions and listens stay with the file the copy left.
Only a `present` location counts as the other path, because a `missing` one is
usually what a move left behind, and a same-volume location with this path's
inode does not, because a hard link cannot hold other bytes.

### Limits of identity

Two files can share a `quick_hash`; a tag write writes one location of a file,
not every copy; an edit that keeps a path's inode, size and mtime is not seen;
and a copy edited while the file's other copies are `missing` keeps the file,
while a missing copy that returns with other bytes splits off.

### Volumes, locations and roots

A volume has a `stable_key` the platform adapter resolves
(`platform/volume_*.zig`): a filesystem UUID, else the identifier in an existing
`.orca-volume-id` at the mount root, else `root:<library_roots.id>`. Orca never
creates that file. `st_dev` is not stable across reboots and is kept only as the
hint `locations.native_device`.
`locations.state` is `present`, `missing` or `unverified`. A completed,
uncancelled scan marks unreached locations `missing`; nothing deletes a location
implicitly, because an unmounted drive must not empty a library. A root's path
is absolute: `ensureRoot` and `relocate` refuse a relative one with
`error.InvalidLibraryRoot`.

Removing a root is the one explicit path that forgets. One transaction deletes
the root's locations, the files located only under it (with their tags, Orca
values, analysis and health rows), the Tracks those files backed, the Releases
and Artists nothing else references, and each Recording no remaining Track or
file holds, which cascades to its feedback, rating, playlist entries and play
stats. Listens keep their rows with `recording_id` NULL. Nothing on disk is
touched. A file also located under another root survives and is reprojected.
Undo journal rows keep their paths and lose only `file_id`, so a tag write can
still be undone. The removal fails with `LibraryJobRunning` while any job on the
Library runs, because every job writes rows keyed by `files.id`.

## Observation, Orca metadata and projection

`observed_file_tags` and `observed_file_genres` store every field the tag
readers produce, verbatim. `orca_metadata_values` stores preferred values, user
edits, provider proposals and locks; `written_at` is when a tag write last put
the value into its file (a changed value clears it, undoing the write does not).
Neither is a Track.

Scanner observations never update Track metadata. `library/projection.zig` fills
`artists`, `releases`, `recordings` and `tracks` from `EffectiveMetadata`
(observation plus Orca overrides), so projection also runs after a user edit or
provider acceptance. It resolves a whole `(containing folder, album key)` group
at once, because the album-artist cascade asks a question about a set. The
folder is the unit of incremental work: a scan that changed nothing reprojects
nothing. Missing locations are projected too, so an unmounted drive greys a
Track out instead of deleting it (`has_playable_file`,
`TrackRepository.playableLocation`). A file with an `unreadable_file` issue is
not projected.

Invariants of a run:

- A Track keeps its id. Each position written matches a Track whose preferred
  file is one of the position's files, else a Track on the same Release
  presenting the same recording, else a new row. Files claim before recordings
  across the folder, and a Track is claimed once per run. A Track whose file
  projects elsewhere moves and keeps its id (`Result.tracks_moved`), so a queue,
  saved player state, lyrics, user genres, a pending proposal or a frontend
  holding the id still resolve. Ratings, feedback, playlist entries and listens
  follow the Recording.
- A row at a target position no file claimed is pruned (`Result.tracks_pruned`),
  handing its user genres to the Track its file backs, and a Release or Artist
  left unreferenced goes with it. Pruned ids do not come back: clients holding a
  Release, Artist or pruned Track id must look it up again.
- A row at a target position whose preferred file lies in a folder the run has
  not yet projected is parked instead of pruned, and the run queues that folder
  even when its scope did not name it. That folder claims the row by file, so a
  file leaving a Release keeps its Track whichever folder projects first.
- Positions are never null once a run ends. `tracks_position` is unique; rows
  changing position are parked with a null track number (collapsed onto `-id`)
  and then written by id, so swaps and rotations never collide. A row parked
  for a later folder keeps a null track number between that run's folder
  transactions.
- A file with no track number takes the lowest free position on its disc and
  raises `missing_track_number`; one whose number is held by a different
  performance is re-seated and raises `technical_anomaly`, which the next run
  that does not re-seat it clears; one at a position with the same performance
  (same MusicBrainz recording id or folded title) shares it as a second file of
  one Track.
- A Release whose files sit in several folders is positioned as one group, so
  the result does not depend on which folder projects first. When files at a
  position disagree on recording, the Track keeps the one it presents.
- `tracks.preferred_file_id` caches the encoding to play: higher declared bit
  depth, then higher sample rate, then a scan-confirmed location, with the
  container only a tiebreak. An undeclared property is unknown, never zero.
- Artist and release keys fold case, width and whitespace (ASCII, Latin-1, Latin
  Extended-A, Greek, Cyrillic, halfwidth and fullwidth forms). Folding does not
  compose, so a precomposed `é` and `e` plus U+0301 are distinct keys.

`tracks.track_total`, `disc_total` and `explicit` are written from the Track's
files: the preferred file's stated total, else any member file's, else a counted
total (`TrackFileFacts.track_total_inferred`). `releases.release_type` is the
primary type the tags agree on; a provider fills it only while it is NULL or
empty. `files.codec` is the encoding (`pcm`, `pcm_float`, `flac`, `qoa`, `mp1`,
`mp2`, `mp3`) and `files.audio_format` the container it was sniffed as
([architecture.md](architecture.md#formats-and-codecs)).

## Browsing and paging

`tracks.artist_id` and `releases.album_artist_id` are the relational links: each
Track has one primary artist and each Release one album artist.
`artists.sort_name` is a folded key (`database/text_key.zig`: lowercase,
collapsed whitespace, leading English article dropped) that one binary index
serves; hosts display `artists.name`.

`TrackRepository.page`, `ArtistRepository.page` and `ReleaseRepository.page`
take a query (`TrackQuery`, `ArtistQuery`, `ReleaseQuery`) with a sort, a
direction, relational filters and value filters; the fields are the contract.
Filters are bound parameters, each true when unset, and `countMatching` and
full-text search read the same predicate text.

- Every generated ORDER BY ends in the row's own id, and a descending sort
  reverses every term including it. Without a unique tiebreaker a LIMIT/OFFSET
  walk over ties can return a row on two pages and skip another.
- Release sorts by title or artist lead with whether the name starts with an
  ASCII letter, so each initial is one contiguous run.
  `ReleaseRepository.letterIndex` counts per initial (`'#'` for the rest) so
  each bucket's `first_offset` is the `offset` at which `page` reaches it. The
  artist key strips a leading "The ", "A " or "An " unless
  `ReleaseQuery.name_order` is `as_written`.
- `releases_artist_order` and `releases_title_order` are expression indexes;
  SQLite uses them only when ORDER BY repeats their expressions exactly, so a
  change to `ReleaseSort.terms` requires rebuilding the index.
- A page selects its ids first with only the join its sort needs, then joins the
  columns of the summary. `TrackSummary.feedback` and `recording_id` come from
  the same statement, never a query per row.
- Date added orders by `files.first_seen_at` of the playing file, not
  `tracks.created_at`, which a reprojection resets. A Track is loved when its
  Recording's `feedback.score` is `1`; a Release is loved through
  `release_loves`.

## Schema

The tables by purpose; keys are those that carry identity or a contract.

### Files and scanning

- `volumes`, `library_roots`: volume `stable_key` and the roots bound to
  volumes.
- `files`: `id`, `quick_hash`, `content_hash`, `content_hash_algorithm` (1 or
  NULL; cleared with `audio_hash` when `quick_hash` changes), `audio_hash`,
  `audio_hash_tier`, `first_seen_at` and declared audio properties.
- `locations`: `UNIQUE(volume_id, uri)`, `state`, inode, size and modification
  time.
- `scan_runs`: one row per walk with its generation and end state.
- `folder_images`: images beside the music, unique on `(volume_id, uri)`, never
  `files` rows, so they never reach projection, analysis or stats. `role` is
  front for a name stem of `cover`, `front` or `folder` (compared without case),
  then back, booklet, other. Sweeps delete unreached rows rather than marking
  them missing.
- `folder_scans`: `(root_id, relative_path)` and when a walk last finished that
  folder; `""` is the root.
- `observed_file_tags.comment` is nullable; while null for a file, a tag write
  is refused as `changed_since_scan`.

### Music model

- `artists`, `releases`, `recordings`, `tracks`: written only by projection.
  `releases.has_folder_cover` is stored because `ReleaseQuery.has_artwork` reads
  it for every Release; `locations.releaseHasFolderCoverSql` is its one
  definition, and projection, the scanner, post-run sweeps and root removal
  write it. A sweep does not raise `artwork_problem`; the next projection of the
  folder does.
- `genres`, `track_genres`, `genre_totals`, `genre_release_tracks`,
  `genre_artist_refs`: [Genres](#genres).
- `track_search` (external-content FTS5 over title, artist, album and album
  artist, kept by triggers) and `search_index`: [Search](#search).

### Analysis and health

- `analysis_results` (`WITHOUT ROWID`): keyed on `(file_id, kind, algorithm_id,
  algorithm_version, parameter_hash, source_identity)`, which encodes every
  reason a stored measurement stops describing a file and so also decides which
  files owe analysis ([analysis.md](analysis.md#what-already-analyzed-means)).
  `source_identity` is the content hash of the bytes decoded; a result counts
  only while it equals `files.content_hash` with algorithm 1, so a scan that
  sees a path change without hashing it leaves results stale. The pass records
  the hash it read in the transaction that writes results, only while the file
  still records the quick hash it read and either records that content hash or
  has the read location still recording the identity read. Kind 4 holds no
  measurement: it records that the registered decoders refused the bytes with
  that content hash, keyed on a hash of the decoder set, so the pass skips the
  file until its bytes or the decoders change. Kind 5 holds no measurement
  either: it records bytes that could not be fingerprinted, its
  `source_identity` is the file's quick hash, and it counts only while it equals
  `files.quick_hash` ([analysis.md](analysis.md#acoustid-fingerprints)).
- `file_loudness`: integrated loudness of the default `orca.audio-diagnostics`
  result, kept by triggers on `analysis_results` and counted only while its
  `source_identity` equals the file's content hash and the file records at most
  two channels.
- `file_audio_features`: one row per file of tempo (`tempo_bpm`,
  `tempo_confidence`), key (`key_pitch` 0–11 with C as 0, `key_mode` 0 major or
  1 minor, `key_confidence`) and the energy inputs `onset_rate` and
  `centroid_hz`, with the `source_identity` of the bytes measured. A NULL tempo
  or key is an estimate below its confidence floor; `key_pitch` and `key_mode`
  are NULL together. Triggers on `analysis_results` keep it: a kind 6
  `orca.audio-features` version 1 result under the default parameter hash,
  inserted or with its result updated, replaces the file's row with the decoded
  fields, and deleting the result deletes the row with the same
  `source_identity`. A result that is not 40 bytes, lacks the `ORAF` version 1
  header, sets an unknown flag or holds a pitch above 11 or a mode above 1
  leaves the file without a row; a valid result with no estimates stores a row
  of NULLs. The row counts only while its `source_identity` equals the file's
  content hash and the file records at most two channels. Energy is computed
  from it at read time ([analysis.md](analysis.md#audio-features));
  `file_audio_features_by_onset_rate`, `file_audio_features_by_centroid` and
  `file_loudness_by_lufs` count the ranks it needs.
- `library_health_issues`: issues keyed by file and kind. `related_file_id` is
  the other file of a duplicate and `similarity` the fingerprint score behind a
  `likely_duplicate`. `health_dismissals` `(file_id, kind)` stores the
  `quick_hash` at dismissal and holds only while it equals the file's
  ([analysis.md](analysis.md#dismissals)).
- `metadata_proposals`: the consistency pass's issues
  ([analysis.md](analysis.md#metadata-consistency)) as header, option and
  proposal rows; `id` is `AUTOINCREMENT` so a replaced issue's id never names a
  later one.
- `files_incomplete_properties` is a partial index over
  `repository.incomplete_properties_predicate`; `files_duration` serves
  duplicate detection.

### Mutation journal

`mutation_operations` keeps paths, because a filesystem operation's subject is a
path. It also carries `file_id` and the journaled `FileIdentity` (size,
modification time, quick hash, content hash): `expected_*` is the file the plan
approved, `committed_*` the stage once built and then the file once the write
commits. A NULL content hash is compared by the other three parts; a stored
value that is not 32 bytes fails the read rather than weakening the check.
`backup_path` is NULL once pruning deletes the backup. `MutationState` values
are stored by number, so new states are appended and never reordered
([metadata.md](metadata.md)).

### Identification and providers

- `identification_proposals`: keyed on `files.id`, one per recording.
  `recordSearch` merges new evidence into an existing one and keeps its state,
  so a dismissed proposal stays dismissed. `album_group` shares an [album
  correction](metadata.md#corrections) among proposals; `accepted_in_bulk` marks
  `acceptConfident`.
- `identification_searches` `(file_id, provider)`: which provider has answered
  for which file, empty answers included. `repository.unidentified_tracks` is
  the one definition of what the matching job still searches.
- `acoustid_submissions` `(file_id, recording_mbid)`.
  `repository.acoustid_submittable` selects files whose recording id is an Orca
  value with `provider` or `user` provenance, is in effect, is not the file's
  own tag unless Orca wrote it (`written_at`), and has no row here; a `provider`
  value also needs its accepted proposal on the same file, and a proposal found
  by AcoustID or accepted in bulk is not submitted back.
- `recording_verifications`: each file's latest
  [verification](providers.md#verification) with the `quick_hash` and recording
  id it was made for; staleness is computed, never stored.
- `musicbrainz_releases`, `musicbrainz_release_tracks`: tracklist snapshots
  keyed by MusicBrainz ID, never by Release id.
  `ReleaseTracklistRepository.replace` refuses more than 512 media or tracks
  (`error.ReleaseTracklistTooLarge`).
- `release_track_pairings` (primary key `track_id`) and `paired_metadata_values`
  (`(file_id, field)`): pairings of Tracks to release tracks and the values they
  set, with the replaced Orca row so unpairing restores it. The trigger
  `release_track_pairings_track_moved` follows a Track's `release_id`
  ([metadata.md](metadata.md#pairing-a-track)).
- `reviewed_releases`, `dismissed_release_candidates`: a person's review of a
  Release and the MusicBrainz releases it was marked not to be, handed over as
  [Album love](#album-love) describes. A review holds only while its release is
  the best candidate and `digest` equals the Release's.
- `provider_state`: per service `blocked_until_ms`, `backoff_ms` and
  `next_request_ms`, keyed by service name so every process opening the Library
  obeys one block. `provider_leases`: which Gateway may send the request in
  flight; `claimLease` upserts only when the row is absent, expired or the
  claimant's, so two Gateways never hold a service. Both keep Unix milliseconds
  ([providers.md](providers.md#rules-toward-providers)).
- `provider_cache`: a row whose `status` is not `200` is a refusal, answered as
  refused until it expires and never used as an answer.

### Recommendations

- `recommendation_feedback`: "Not for me", one row per Recording with
  `created_at` and `expires_at`; `recommendation_feedback_by_expiry` serves
  pruning of expired rows.
- `daily_mixes`: one row per mix of the current day, `ordinal` unique and from
  0. `kind` is 0 for a genre mix built around `genre_id` (NULL once that Genre
  is gone), 1 for the rarely-played mix, 2 for a decade mix of the decade
  starting at `decade` (a multiple of 10, NULL for other kinds), 3 for New to
  you, 4 for Deep cuts, 5 for Upbeat and 6 for Wind down. `local_day` is the local day the mix
  was made for and `generated_at` the Unix time it was made. The explanation is
  `signals` (a bit set of the scoring signals used) and the `left_out_*` counts
  of candidates left out by reason (`recent`, `not_for_me`, `hated`, `live`,
  `other_mix`, `diversity`); the makeup is `favorite_count`,
  `rarely_played_count` and `never_played_count`.
- `daily_mix_artists` (`WITHOUT ROWID`): a mix's top Artists by `position`,
  going with the mix or the Artist.
- `daily_mix_entries` (`WITHOUT ROWID`): a mix's Recordings by `position`,
  going with the mix or the Recording; `daily_mix_entries_by_recording` serves
  both cascades and removing a Recording from the day's mixes. Each entry has
  up to two reason parts, `reason1_*` and `reason2_*`, each a `kind` and two
  integer arguments `a` and `b`; a NULL kind is no part, and the second part
  needs the first. Kinds are stored by number, so new kinds are appended and
  never reordered:

  | Kind | Reason | `a` | `b` |
  | --- | --- | --- | --- |
  | 0 | played | play count | last played, Unix seconds |
  | 1 | loved | | |
  | 2 | same artist | | |
  | 3 | related artist | | |
  | 4 | shared genre | Genre id | |
  | 5 | often after | Recording or Artist id | 0 Recording, 1 Artist |
  | 6 | similar sound | flags: 1 tempo, 2 key, 4 energy | |
  | 7 | never played | | |
  | 8 | rarely played | play count | |
  | 9 | added | added at, Unix seconds | |

### Settings and history

- `library_settings` (`WITHOUT ROWID`): the Library's own settings, never
  credentials: `listens.policy`, `listens.record`, `genre_fill.musicbrainz`
  (`0` disables; absent is on), the discovery settings
  ([discovery.md](discovery.md#settings)) and `mixes.generated_day`, the mix
  day the stored Daily Mixes were made for
  ([discovery.md](discovery.md#mix-day)).
- `job_history`: one row per finished host Job
  ([control-plane.md](control-plane.md#history)).

## Listens and the scrobble queue

`listens` is the local play history, kept forever and keyed on `files.id`,
because a Track id changes when an edit reprojects it. `UNIQUE(file_id,
started_at)` makes recording idempotent. A listen snapshots the title, artist,
album, duration and recording MBID heard, and `ON DELETE SET NULL` on `file_id`
and `recording_id` keeps it when its file or Recording goes. `listens_by_time`
orders listens by `started_at` across files.

`recording_play_stats` holds each Recording's play count and latest
`started_at`, keyed on `recordings.id` so plays follow the song. Two invariants
hold after every write: the table equals a `GROUP BY recording_id` over
`listens` with a non-null `recording_id`, and every listen with a non-null
`file_id` has its file's `recording_id`. `ListenRepository.insertLocked` takes
the Recording from the file and updates the row in the same transaction. The
trigger `files_recording_moves_listens` sits on `files.recording_id`, so any
writer is covered: when a file with listens changes Recording, the listens move
and both Recordings' rows are recomputed in the same statement. A path that
deletes listens must subtract them here.

`ListenRepository.recordAndQueue` inserts the listen and its `scrobble_queue`
row (`event_key = "listen:<listens.id>"`) in one transaction; the payload is a
snapshot taken then. `finishSyncable` sets `listens.syncable` and queues the
listen at most once. `ListenRepository.clear` deletes every `listen:` queue row
(delivered included), every listen and every `recording_play_stats` row, keeping
feedback, ratings and loves; listen ids restart at 1, so a surviving delivered
row would share its key with a new listen and the new one would never be queued.

`scrobble_queue.state` is 0 pending, 1 leased, 2 delivered, 3 rejected.
`ScrobbleQueueRepository.lease` claims pending rows whose `next_attempt_at` has
come and leased rows whose `lease_expires_at` has passed, so a dead worker
strands nothing. Every later mark (`markDelivered`, `markRetry`, `markRejected`,
`release`) applies only while `state = 1 AND lease_owner = owner`; a stale
worker gets `StaleScrobbleEvent`.

## Feedback

`feedback` holds love and hate, keyed on `recordings.id`, so every file and
Track of one song shares a row and reprojection keeps it. `score` is what the
user wants (`-1`, `0`, `1`) and `synced_score` what ListenBrainz was last told;
`score IS NOT synced_score` is the work left. A row is kept until synced,
including feedback on a Recording with no MusicBrainz recording id, which is
never sent. `markSynced` deletes a synced clear, and clearing a never-sent
change deletes the row at once. A change the service refused for good sets
`synced_score` to the refused value and records `last_error`, so it is not
resent until the user changes it. `FeedbackRepository.set` skips and counts
Tracks without a Recording.

## Playlists and ratings

`ratings` is keyed on `recordings.id`, `rating` 1 to 100, no row for unrated.
`playlist_entries` is `WITHOUT ROWID`, keyed on `(playlist_id, position)`, names
a `recording_id`, and has contiguous positions from 0. A shift parks the moved
range on negative positions before landing it, because SQLite checks the primary
key row by row. Entries and ratings go with their Recording, entries with their
playlist. `playlists.kind` is 0 manual or 1 smart; a smart playlist stores
`rules` JSON and no entries, and its entries are the Tracks the rules match when
read, under the caller's `now`. `creator` is 0 for the user and 1 for
`libraryImportPlaylist`. See [cli.md](cli.md#playlists-and-ratings).

## Search

`track_search` serves Track search. `search_index` is a plain FTS5 table with
one row per Artist (kind 0), Release (1), Playlist (3) and genre (4), rowid
`entity_id * 8 + kind`, kept by triggers. `SearchRepository.find` turns text
into a match expression in which no character is syntax: each word with a letter
or digit is quoted, given a trailing `*` and ANDed. Non-Track kinds rank by
`bm25`. Tracks rank by tier (every word is a whole title word, then begins a
title word, then begins a word of title, artist or album), then Track id; a
hit's `rank` is its tier. An FTS5 `optimize` merges the `track_search` segments
that many retitles leave.

## Genres

`genres` has one row per genre: `name` is shown and `key` is the folded form two
spellings share (unique). `track_genres` is keyed `(track_id, ordinal)` and
unique on `(genre_id, track_id)`, so a Track carries a genre once; `provenance`
is 0 for a file's tags, 1 for a user's edit, 2 for a provider's genres.
`metadata/genre_alias.zig` folds a value (`text_key.normalizeKey` without
spaces, hyphens, underscores, dots, slashes and apostrophes, then an alias
table); `parts` splits on commas and semicolons, never slashes, and
`unsplit_names` lists names that contain a comma. `observed_file_genres` keeps
values as stored; the split happens where genres are written to `track_genres`.

Projection writes a Track's genres from its preferred file (else the
lowest-numbered file at that position with any), replacing its file rows each
run and never touching a Track with user rows. `GenreRepository.setTrackGenres`
replaces a Track's rows with user rows; with no names it restores the file rows.
`fillFromProvider` writes provenance-2 rows only on Release Tracks that have no
file or user rows, or on an Artist's Tracks with no rows at all, so an Artist's
genres never displace a Release's
([providers.md](providers.md#genres-from-musicbrainz)). Genres no Track carries
are pruned.

`genre_totals` (Track, Release and artist counts and summed duration per genre)
is kept exact by triggers over the reference-count tables `genre_release_tracks`
and `genre_artist_refs`, firing on every `track_genres` change and on a Track's
`duration_ms`, `artist_id` or `release_id` and a Release's `album_artist_id`, so
a genre is listed exactly while a Track carries it. `tracks_genre_totals_bd`
deletes a Track's `track_genres` rows before the Track, because the cascade runs
after the Track is gone. `migrations.genre_totals_drift_sql` counts rows
differing from a fresh `GROUP BY`; tests assert 0.

## Release artwork

`release_artwork` is keyed `(release_id, kind)` (0 front, 1 back, 2 booklet) and
cascades with its Release. `source` is 2 for a Cover Art Archive cover and 3 for
one a person chose; embedded and folder covers are read from their files and
never stored. A fetched cover never replaces a chosen one. `width` and `height`
are measured when stored, -1 (`unreadable_cover_side`) when the header does not
read, and NULL only while unmeasured. A NULL `image` records that the archive
had no front cover, which stands for 30 days
([providers.md](providers.md#cover-art-archive)). `cover_art_candidates`
`(release_id, caa_id)` holds at most `max_cover_art_candidates` (8) images from
the last candidate request. `release_group_covers` is keyed by MusicBrainz group
ID, so Artists on one group share a cover, and the trigger
`artist_release_groups_cover_ad` deletes it once no `artist_release_groups` row
names its group.

`artwork_problem` health issues are settled from the database alone, never from
image bytes. The scanner records each local cover's size and hash
(`observed_file_tags.artwork_width`, `artwork_height`, `artwork_hash`;
`folder_images.width`, `height`, `hash`). `hash` is the first 8 bytes of the
BLAKE3 digest as a little-endian signed integer, 0 when the bytes would not
read; a readable image's hash is never 0. A Release's front cover in effect is
the chosen one, else an embedded one, else a front folder image, else the
fetched one. A file carries at most one problem: `missing_front` when none
exists, `conflicting` when the embedded cover and the folder's front image have
different hashes, `undersized` when the front in effect is under
`minimum_cover_pixels` (500) on either side. An unmeasured cover raises nothing.
`ArtworkBackfill` (`library/artwork_backfill.zig`) measures unmeasured covers
through the partial indexes `observed_file_tags_artwork_unmeasured`,
`folder_images_unmeasured` and `release_artwork_unmeasured`, and settles each
batch's Releases in its own commit
([storage.md](storage.md#repairing-properties-without-a-walk)).

## Album love

`release_loves` has one row per loved Release (`release_id`, `loved_at`); no row
means not loved. `artist_loves` is the same for Artists. Both stay in the
Library and are never sent; neither is `feedback`.

A Release's id is not stable. A retag that changes the album, album artist or
release ID of all of a Release's Tracks re-keys the row in place when no Release
holds the new key; otherwise its Tracks move and the old Release is pruned,
which would cascade its rows away. So the projection hands the Release's loves,
artwork, candidates, dismissed candidates and reviews over before pruning
(`carryReleaseState` in `library/projection.zig`): to the Release that holds
most of its moved Tracks (a tie goes to the lower id), and only when that
Release has no row of its own. A Release removed outright, as root removal does,
takes its rows with it. Artists are keyed by name: a renamed or pruned Artist
loses its rows with its id, and nothing is handed over.

## Track lyrics

`track_lyrics` keeps what LRCLIB answered, one row per Track (`track_id`,
cascading). `query_digest` is the BLAKE3 digest of the title, artist, album and
duration looked up; the row stands only while it matches the Track's current
values, and an edit leaves it unused until the next fetch replaces it. A row
with neither text that is not `instrumental` records a miss
([providers.md](providers.md#lrclib)).

## Artist info

`artist_info`, `artist_links`, `artist_related`, `release_info` and
`artist_release_groups` are keyed by their owner's id with `ON DELETE CASCADE`.
They hold fetched information with its attribution (source, URL, licence,
language, credit); photo details are written only with the photo's bytes, so a
credit never describes another image. `requested_language` is what the fetch
asked for and what reuse compares. `ArtistInfoRepository.store` writes the row
and links in one transaction. `artist_links` holds at most 64 per Artist and
`artist_related` at most 12; a fetch that reached MusicBrainz replaces links and
one that did not keeps them. `artist_release_groups` keeps at most
`max_release_groups` (200) groups, replaced so a group in both old and new
answers keeps its row. `related_artist_photos` is keyed by MusicBrainz artist
ID, so every Artist it is related to shares a photo
([providers.md](providers.md#artist-info)).

## Folder browsing

`LocationRepository.folderPage` lists one folder of a root from `locations`
alone, using `UNIQUE(volume_id, uri)`. A location's `uri` is the root's path, a
`/` and the path below, so a folder is the half-open range `[prefix, upper)` on
that index, `prefix` being the folder path plus `/` and `upper` that with the
final `/` replaced by `0`. The range is compared bytewise, so `[`, `*`, `?`, `%`
and `_` in a name match only themselves; no `GLOB` or `LIKE` is used. Children
are found by skip scan, one seek per child, skipping a folder's whole subtree.

- Folders come first, ordered bytewise by `name/`, then files by name, then
  images; `offset` counts in that order.
- Every statement filters `state <> 'missing'` and `+root_id`; the unary `+`
  keeps the planner off `locations_sweep`, which would read the whole root.
- A file's `status` is `unreadable` while it has an `unreadable_file` issue,
  else `imported`. The page carries `image_count`, `last_scanned_at` and the
  Release directly in the folder when every present Track preferred for a file
  there belongs to one Release (null otherwise, or when the folder has more than
  512 children). A folder holding only images is not a subfolder.
- `folderTrackIds` returns the folder's Tracks by `uri` then Track id, each
  once, at most `max_playlist_entries`.

## Library stats

`LibraryStatsRepository.stats` (`Runtime.libraryStats`, `orca-cli stats`) reads
one row: counts of `artists`, `releases` and `tracks`; `files` and `total_bytes`
for files with at least one location whose state is not `missing`, each counted
once; `total_duration_ms`, the sum of `tracks.duration_ms` with null or negative
as zero; `last_scan_finished_at` over `completed` runs only; `last_analysis_at`
over the measurement kinds only (1 diagnostics, 2 temporal fingerprint, 6 audio
features), so an AcoustID fingerprint stored by matching or submission, an
undecodable verdict and an unfingerprintable note do not count;
`last_duplicate_scan_at` from `job_history` (host Jobs only and the newest 1,000
rows, so a scan run by itself or pruned away does not count); and the `listens`
count.

## Fetched cache

`FetchedCacheRepository` (`Runtime.libraryCacheSize`,
`Runtime.libraryClearCache`, `orca-cli cache`) measures and deletes provider
data that can be fetched again: fetched covers (`release_artwork` with `source =
2`, candidate thumbnails, `release_group_covers`), fetched photos, lyrics, and
the text of `artist_info`, `release_info`, `artist_links`, `artist_related` and
`artist_release_groups`. Clearing runs in one transaction under the write lane.
A chosen cover, an `artist_info` photo from the Artist's folder (`photo_source =
0`; the row keeps it with every fetched field nulled and `fetched_at = 0`),
`provider_cache` and the tracklist snapshots Match Review needs are neither
counted nor cleared.

## Saved playback

`PlayerStateRepository` keeps one saved queue per Library. A save replaces
`player_state` (one row: cursor, position, repeat, shuffle) and every
`player_queue_entries` row in one transaction, at most 10,000 entries in
playback order; `entry` is the index in the unshuffled list, so a shuffled queue
restores in the same order. Each row stores the Track id and Recording id it had
when saved, with no foreign key to either. A load resolves each row to the saved
Track while it still has the saved Recording, else to the lowest Track id of
that Recording, else skips it, so reprojection keeps the queue.
`track_positions` keeps where a long Track was left, cascading with its Track; a
position of zero or a gone Track deletes the row ([api.md](api.md)).

## Backups and maintenance

The Library file holds state that exists nowhere else: Orca values and locks,
listens, ratings, feedback, "Not for me", playlists and loves. Everything
derived (projection, analysis results, fetched provider data) is rebuilt by a
scan, the analysis pass and provider jobs. Tag-write backups under
`<database>.orca-backups` are pruned through `prunableBackups` and
`clearBackupPath` ([metadata.md](metadata.md#pruning-backups)).

## Tests and benchmarks

Repository tests live beside their modules under `liborca/database/` and
`liborca/library/`. `zig build bench` generates 500,000 Tracks without a scanner
and measures insertion, reopen and search latency.
