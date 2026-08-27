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
   Orca's own tag writes. Written by `library/analysis_pass.zig`, which is the
   only pass that decodes a whole file, and never by a scanner.

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
indexed lookup rather than a three-way join. Which encoding it names is decided
on declared properties: higher bit depth, then higher sample rate, then a
location a scan has confirmed, with the container ranking only as a tiebreak
between encodings that declare the same thing. A property the file does not
declare is *unknown*, never zero — so an MPEG file, which has no sample width to
state, loses to a real 16-bit encoding of the same song, and a file the scanner
could not open never outranks one it could.

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

## The browse model

Version 9 makes the library *browsable* rather than merely listable. Before it,
the only artist reachable from a Track was the denormalized `tracks.artist`
text, so "what else is by this artist" was a full table scan and a string
comparison, and no query could answer it at all through the public API.

`tracks.artist_id` and `releases.album_artist_id` are the relational links, and
`artists.sort_name` is the key an Artist listing orders by. All three are
written by `library/projection.zig` going forward and backfilled by migration 9
for a library that already exists.

**One primary artist per Track, one album artist per Release, deliberately.**
The tag data is single-valued on ARTIST and ALBUMARTIST in essentially every
file, and splitting featured credits is a metadata problem — it needs a parser,
a provenance story and a user-visible review step — not a schema one. The
extension path is a `track_artists(track_id, artist_id, ordinal, role)` join
table *alongside* these columns, with `artist_id` staying as the primary artist
a listing files by. Nothing in version 9 has to be undone to get there.

`artists.sort_name` is a folded **sort key**, not a display name:
`database/text_key.zig` lowercases, collapses whitespace and drops a leading
English article, so "The Beatles" files under B and one plain index serves the
whole listing under a BINARY collation. Hosts display `artists.name`.

### Ordering and paging

`TrackRepository.page` takes a `TrackQuery`: a sort key (`id`, `artist`,
`album`, `title`, `track_number`, `duration`, `date_added`), a direction, and
relational filters on `artist_id` and `release_id`. `ArtistRepository.page`
and `ReleaseRepository.page` are the same shape for their own tables. All
three return bounded, caller-owned pages of at most 512 rows and never expose a
SQLite row or statement.

**Every generated ORDER BY ends in the row's own id.** This is not decoration.
3,476 Tracks in the reference library share a title with another, 33 have no
artist and 43 Releases span more than one disc; without a unique tiebreaker a
LIMIT/OFFSET walk over a column with ties is free to return one row on two
pages and skip a third, because SQLite may order equal keys differently between
two evaluations of the same statement. A descending sort reverses *every* term
including the tiebreaker, which keeps the order total and lets SQLite walk the
same index backwards.

The `id` in an ORDER BY is never named in an index. `id` is `INTEGER PRIMARY
KEY`, so it *is* the rowid and SQLite already appends it to every index entry —
`ORDER BY title COLLATE NOCASE, tracks.id` is satisfied straight out of
`tracks(title COLLATE NOCASE)` with no temp B-tree.

Against the 22,060-Track reference library every unfiltered sort is an ordered
index scan, and every Artist-filtered sort but one is an indexed SEARCH. Two
cases still build a temp B-tree, both over a bounded set and both deliberate: an
Artist-filtered listing sorted by artist *name* (bounded by that Artist's
Tracks; 158 at most here), and a Release-filtered listing sorted by anything
other than disc-and-track (bounded by one Release; 81 at most). Indexing those
would cost seven more composite indexes on the largest table in the schema to
order at most a few dozen rows.

Per-artist and per-release counts are correlated scalar subqueries rather than
a GROUP BY join, because a join would have to aggregate the whole table before
the LIMIT could apply. Each is one covering range count over `tracks_artist`,
`tracks_release` or `releases_by_artist`.

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

`analysis_results` is `WITHOUT ROWID`, keyed on `(file_id, kind, algorithm_id,
algorithm_version, parameter_hash, source_identity)`. That key is load-bearing
beyond caching: it is also how the library-wide analysis decides which files
still owe work, because it already encodes every reason a stored measurement
stops describing a file. A marker column on `files` would be a second source of
truth free to disagree with the results it claims to describe.
`repository.unanalyzed_predicate` is the one definition of that question,
shared by the paged selection, the count that gives the job its denominator,
and the plan test that asserts neither is a table scan. See `docs/analysis.md`.

Migration 8 preserves paths that only ever appeared in `analysis_results` or
`library_health_issues` — an `orca-cli analyze` of a file no scan ever saw — by
synthesizing `files` and `locations` rows in the `unverified` state. Their old
size-and-mtime cache key is preserved as a distinguishable legacy
`source_identity` rather than being collapsed onto a hash nobody computed.
`fixtures/database/v7-library.db` is a checked-in version-7 database, generated
by `fixtures/database/v7-library.sql`, that the migration tests migrate and
assert row-for-row.

Migration 9 backfills `tracks.artist_id` and `releases.album_artist_id` by
running the *same two-step cascade* `ArtistRepository.ensureLocked` runs, in the
same order: a MusicBrainz artist id outranks the name, and only what it cannot
answer falls back to the folded key. `migrations.zig` registers
`orca_artist_key` and `orca_artist_sort_key` as SQLite functions over
`database/text_key.zig`, so the backfill executes the same Zig the projection
executes rather than a reimplementation in SQL that would be free to drift. On
the 22,060-Track reference library the migration takes about five seconds, and
22,027 Tracks get an `artist_id`; the 33 that do not are exactly the Tracks
whose artist tag is empty, and an empty name is an absent artist rather than an
artist named "". Migrating and then reprojecting that library produces
byte-identical `artist_id`, `album_artist_id` and `sort_name` columns — the
convergence `library/projection.zig` asserts on a fixture and
`migrations.artist_backfill` exists as a separate constant to make testable.

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

Migration 10 adds one partial index, `files_incomplete_properties`, over
`repository.incomplete_properties_predicate` — the rows whose declared audio
properties are still missing. It is partial rather than full for a reason worth
stating: the index contains exactly the rows that are broken, so it starts
small on a healthy library, shrinks as the property backfill repairs rows, and
reaches empty, at which point asking "what still needs probing" costs one
B-tree probe instead of 500,000 row reads. A full index on the same columns
would be largest precisely when there is nothing to do. The predicate has a
single definition shared by the index and the query, because SQLite decides
whether a partial index applies by comparing expressions rather than meanings.

Migration 13 adds `files_duration ON files(duration_ms, id)`, which is what
makes duplicate detection an indexed question rather than an O(n²) one. It is
full rather than partial, and that is the opposite choice to migration 10 for
the opposite reason: a duplicate scan asks its question of *every* file, and
the rows it asks about do not shrink as anything gets repaired. It covers both
columns so the bucket lookup reads the index alone. See `docs/analysis.md`.

`files.codec` is the **encoding**, not the container. `files.audio_format` is
the container a file was sniffed as, which decides who opens it; `codec` is a
stable lowercase identifier for what turned out to be inside — `pcm`,
`pcm_float`, `flac`, `qoa`, `mp1`, `mp2`, `mp3` — which decides what the bytes
cost. They coincide for FLAC and QOA and diverge wherever a container is a
wrapper. See `docs/codecs.md`.

## Concurrency

- The primary connection uses WAL and `synchronous=NORMAL`.
- One write lane serializes complete write transactions. It is a real
  futex-backed mutex (`std.Io.Mutex`), not a spinlock: a scan worker holds it
  across a bounded 256-row transaction while UI threads read.
- Read snapshots use independent read-only connections.
- Connections use SQLite's full-mutex mode and a five-second busy timeout.
- Prepared batch statements are reused within one transaction.

Automated coverage verifies that a migrated library files every Track exactly
where a fresh projection does, that an album returns in disc-then-track order,
that paging a sort with ties returns every Track exactly once, that reversing a
sort reverses the whole listing rather than only its first key, that an
out-of-range page is refused rather than clamped, and additionally independent
libraries and indexes, FTS paging, a
10,000-row transactional update, concurrent read access while four write
producers serialize, that a rename preserves file identity and everything
attached to it, and that migrating the checked-in version-7 fixture preserves
every path-keyed row. The executable benchmark generates 500,000 tracks without
involving a scanner and measures insertion, reopen, and search latency.
