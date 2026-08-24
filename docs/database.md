# Library persistence

Each `LibraryDatabase` owns one SQLite database and one serialized logical write
lane. Paths are copied at open time so the Library owns all state needed to open
independent read connections. `OrcaRuntime.openLibrary` associates that database
with a typed generational `LibraryHandle` and closes it during explicit removal
or ordered runtime shutdown.

## Identity

**`files.id` is identity.** A `file` is one encoding of some audio; a `location`
is one place that encoding can currently be found, on one `volume`. No table
outside `locations` and `mutation_operations` stores a path, so renaming, moving
or re-tagging a file never detaches the metadata, locks, analysis results or
health issues attached to it.

A scan re-finds a file through a cascade, cheapest first:

1. `locations(volume_id, uri)` — the same path on the same volume.
2. `locations(volume_id, native_inode, size_bytes, modified_ns)` — a rename or
   move within one filesystem.
3. `files.quick_hash` — BLAKE3 over (first 64 KiB ‖ last 64 KiB ‖ size), from
   `storage/quick_hash.zig`. Catches copies, cross-volume moves and restores.
4. `files.audio_hash` — over the decoded audio payload only, so it survives
   Orca's own tag writes. Computed by an analysis job, never by a scanner.

Volumes are identified by a `stable_key` the platform adapter resolves — a
filesystem UUID, else an identifier persisted at the mount root, else
`root:<library_roots.id>`. `st_dev` is *not* stable across reboots or remounts
and is kept only as `locations.native_device`, a hint. Resolution lives in
`platform/volume_*.zig`; neither the scanner nor a repository knows how a volume
is named.

`locations.state` is `present`, `missing` or `unverified`. A completed,
uncancelled scan run marks locations it did not reach as `missing`; nothing
deletes a location implicitly, because an unmounted drive must not empty a
library.

## Observation, Orca metadata, projection

`observed_file_tags` (plus `observed_file_genres`, since genre is multi-valued
in every container Orca reads) stores every field the tag readers can produce,
verbatim. `orca_metadata_values` stores preferred values, user edits, provider
proposals and locks. Neither is a Track.

**Scanner observations never update Track metadata.** A separate *projection*
fills `artists`, `releases`, `recordings` and `tracks`, and it reads
`EffectiveMetadata` — observation plus Orca overrides under an explicit policy —
not raw observations. That keeps the law intact and makes the projection
re-runnable after a user edit or a provider acceptance, not only after a scan.
`tracks.preferred_file_id` is a denormalized cache so starting playback is one
indexed lookup rather than a three-way join.

`library/projection.zig` resolves a whole `(containing folder, album key)` group
at once, because the album-artist cascade asks a question about a set — *do all
the files sharing this album in this folder name one artist?* — that no per-file
pass can answer. The folder is also the unit of incremental work: a scan batch
names a handful of folders, each is one range scan of `locations(volume_id,
uri)`, and a scan that changed nothing reprojects nothing. Missing locations are
projected too, so an unmounted drive greys a Track out rather than deleting it;
`has_playable_file` and `TrackRepository.playableLocation` answer reachability.

Two source-data defects are common enough that the projection must survive both
without losing a song. A file with no track number takes the lowest free
position on its disc and raises `missing_track_number`. A file whose stated
track number is already held by a *different* performance is re-seated the same
way and raises `technical_anomaly` — while a file at the same position that is
the *same* performance (a FLAC and an MP3 of one song, matched by MusicBrainz
recording id or folded title) shares the position and becomes one Track with two
files. Positions are never left null: `tracks_position` collapses a null onto
`-id`, so a null-positioned row has nothing to upsert against and every
reprojection would duplicate it.

Artist and release keys fold case, width and whitespace. That folding is not
full NFKC plus full Unicode case folding — it covers ASCII, Latin-1, Latin
Extended-A, Greek, Cyrillic and the halfwidth/fullwidth forms, and does not
canonically compose, so a precomposed `é` and a decomposed `e`+U+0301 remain
distinct keys.

## Schema and migrations

Schema changes are transactional and selected by `PRAGMA user_version`. Version
1 establishes separate Artist, Release, Recording, Track, File, and Location
tables; filesystem paths therefore never become musical identity. Version 8
completes that by removing the path-keyed tables that grew alongside them:
`observed_files` disappears into `files`, `locations` and `observed_file_tags`,
and analysis, health, Orca metadata and identification proposals all key on
`files.id`. Unknown newer schema versions are rejected rather than opened
destructively, and `PRAGMA foreign_key_check` runs inside the migration
transaction so a migration that would leave dangling rows rolls back instead.

Migration 8 preserves paths that only ever appeared in `analysis_results` or
`library_health_issues` — an `orca-cli analyze` of a file no scan ever saw — by
synthesizing `files` and `locations` rows in the `unverified` state. Their old
size-and-mtime cache key is preserved as a distinguishable legacy
`source_identity` rather than being collapsed onto a hash nobody computed.
`fixtures/database/v7-library.db` is a checked-in version-7 database, generated
by `fixtures/database/v7-library.sql`, that the migration tests migrate and
assert row-for-row.

`LibraryDatabase.open` applies migrations only as far as
`migrations.journal_ready_version` (the version at which `mutation_operations`
exists), runs mutation-journal recovery, and only then applies the remaining
migrations. A nonterminal staged file mutation must reach a terminal state
before any migration rewrites the tables it refers to, and a Library whose
journal cannot be converged is not opened at all — the same posture as an
unknown newer schema version.

`mutation_operations` keeps its paths: the subject of a filesystem operation
genuinely is a path. It also carries `file_id` and the full journaled
`FileIdentity` (size, modification time and quick hash), so recovery compares
the same identity an in-process check does.

Track full-text search uses an external-content FTS5 table over
`title, artist, album, album_artist`, maintained by SQLite triggers. Such tables
cannot be `ALTER`ed to gain a column, so migration 8 drops the triggers and the
virtual table, recreates both, and rebuilds the index. Repository APIs return
bounded, caller-owned pages and never expose SQLite rows or statements.

## Concurrency

- The primary connection uses WAL and `synchronous=NORMAL`.
- One write lane serializes complete write transactions. It is a real
  futex-backed mutex (`std.Io.Mutex`), not a spinlock: a scan worker holds it
  across a bounded 256-row transaction while UI threads read.
- Read snapshots use independent read-only connections.
- Connections use SQLite's full-mutex mode and a five-second busy timeout.
- Prepared batch statements are reused within one transaction.

Automated coverage verifies independent libraries and indexes, FTS paging, a
10,000-row transactional update, concurrent read access while four write
producers serialize, that a rename preserves file identity and everything
attached to it, and that migrating the checked-in version-7 fixture preserves
every path-keyed row. The executable benchmark generates 500,000 tracks without
involving a scanner and measures insertion, reopen, and search latency.
