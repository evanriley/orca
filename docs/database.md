# Library persistence

Each `LibraryDatabase` owns one SQLite database and one serialized logical write
lane. Paths are copied at open time so the Library owns all state needed to open
independent read connections. `Runtime.openLibrary` associates that database
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

Removing a root is the one explicit path that forgets. In one transaction it
deletes the root's locations, the files that were located only under it (with
their tags, Orca values, analysis and health rows), the Tracks those files
backed, and the Releases and Artists nothing else references. Nothing on disk
is touched. A file also located under another root or volume survives, and
the projection is rerun over it. Undo journal rows keep their paths and lose
only their `file_id`, so a tag write can still be undone. Every Library job
writes rows keyed by `files.id`, so the removal fails with `LibraryJobRunning`
while any job on that Library runs.

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

Reprojecting a folder prunes what its files no longer back. A Track is a
position on a Release, so a file whose tags now place it on another Release or
position gets a new row; the row it backed before is deleted, and a Release or
Artist left with nothing referencing it goes with it. Only Tracks whose
preferred file is in the folder are candidates, found through
`tracks_by_preferred_file` (version 14), and only if the run did not just write
their position. Everything pruned is derived and is rebuilt by the next
projection, so an id handed out for a pruned row does not come back: a client
holding Track, Release or Artist ids across an edit or a rescan must look them
up again.

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

The library is *browsable* rather than merely listable: "what else is by this
artist" is an indexed relational query, not a scan over the denormalized
`tracks.artist` text.

`tracks.artist_id` and `releases.album_artist_id` are the relational links, and
`artists.sort_name` is the key an Artist listing orders by. All three are
written by `library/projection.zig`, and migration 9 backfills them for a
library created before version 9.

**One primary artist per Track, one album artist per Release, deliberately.**
The tag data is single-valued on ARTIST and ALBUMARTIST in essentially every
file, and splitting featured credits is a metadata problem — it needs a parser,
a provenance story and a user-visible review step — not a schema one. The
extension path is a `track_artists(track_id, artist_id, ordinal, role)` join
table *alongside* these columns, with `artist_id` staying as the primary artist
a listing files by.

`artists.sort_name` is a folded **sort key**, not a display name:
`database/text_key.zig` lowercases, collapses whitespace and drops a leading
English article, so "The Beatles" files under B and one plain index serves the
whole listing under a BINARY collation. Hosts display `artists.name`.

### Ordering and paging

`TrackRepository.page` takes a `TrackQuery`: a sort key (`id`, `artist`,
`album`, `title`, `track_number`, `duration`, `date_added`), a direction, and
relational filters on `artist_id` and `release_id`. `ArtistRepository.page` and
`ReleaseRepository.page` are the same shape for their own tables. All three
return bounded, caller-owned pages of at most `columns.max_page` (512) rows and
never expose a SQLite row or statement.

**Every generated ORDER BY ends in the row's own id.** This is not decoration.
Real libraries hold many Tracks that share a title, have no artist, or sit on
multi-disc Releases; without a unique tiebreaker a LIMIT/OFFSET walk over a
column with ties is free to return one row on two pages and skip a third,
because SQLite may order equal keys differently between two evaluations of the
same statement. A descending sort reverses *every* term including the
tiebreaker, which keeps the order total and lets SQLite walk the same index
backwards.

The `id` in an ORDER BY is never named in an index. `id` is `INTEGER PRIMARY
KEY`, so it *is* the rowid and SQLite already appends it to every index entry —
`ORDER BY title COLLATE NOCASE, tracks.id` is satisfied straight out of
`tracks(title COLLATE NOCASE)` with no temp B-tree.

Every unfiltered sort is an ordered index scan, and every Artist-filtered sort
but one is an indexed SEARCH. Two cases build a temp B-tree, both over a
bounded set and both deliberate: an Artist-filtered listing sorted by artist
*name* (bounded by that Artist's Tracks), and a Release-filtered listing sorted
by anything other than disc-and-track (bounded by one Release). Indexing those
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
executes rather than a reimplementation in SQL that would be free to drift. A
Track whose artist tag is empty gets no `artist_id`: an empty name is an absent
artist rather than an artist named "". Migrating and then reprojecting a library
produces byte-identical `artist_id`, `album_artist_id` and `sort_name` columns —
the convergence `library/projection.zig` asserts on a fixture and
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
the same identity an in-process check does. `backup_path` is NULL once pruning
has deleted the backup; `prunableBackups` and `clearBackupPath` select and
record that. See [metadata.md](metadata.md#pruning-backups).

Migration 18 forgets the files a scan made of tag-write stages and backups that
earlier versions kept beside the music. A file goes only when every one of its
locations is a journaled `stage_path`, `backup_path` or
`stage_path || '.recovery-displaced'`; its Tracks go with it, then the Releases
and Artists left without Tracks, and journal rows that named it keep their paths
with `file_id` set to NULL, as `remove-root` leaves them.

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

## Listens and the scrobble queue

`listens` (version 15) is the local play history: one row per completed
listen, kept forever. It is keyed on `files.id`, not on a Track. A Track id
changes when an edit reprojects it, and a play count keyed on the Track would
reset with it; the file identity survives, so `trackPlayStats` counts listens
of the Track's playing file (`preferred_file_id`, else the first file of its
Recording, as `playableLocation` resolves it). `UNIQUE(file_id, started_at)`
makes recording idempotent: the same file starting at the same second is one
listen.

A listen stores a snapshot of the title, artist, album, duration and
recording MBID that were heard, so history stays readable after the file is
gone. `remove-root` deletes the root's files, and `ON DELETE SET NULL` on
`file_id` (and `recording_id`) leaves the listen in place with a null file
rather than deleting it or failing the delete. Rows with a null `file_id` no
longer count towards any Track.

`ListenRepository.recordAndQueue` inserts the listen and its `scrobble_queue`
row in one transaction with `event_key = "listen:<listens.id>"`, so a listen is
never stored without its delivery or queued twice.

`scrobble_queue.state` is 0 pending, 1 leased, 2 delivered, 3 rejected.
`ScrobbleQueueRepository.lease` claims rows in one `UPDATE ... RETURNING`:
pending rows whose `next_attempt_at` has come, and leased rows whose
`lease_expires_at` has passed, so a worker that dies mid-submit strands nothing.
Every later mark (`markDelivered`, `markRetry`, `markRejected`, `release`)
applies only while `state = 1 AND lease_owner = owner`; a worker whose lease
expired and was reclaimed gets `StaleScrobbleEvent` instead of overwriting the
new owner's result. `release` returns a row to pending without counting an
attempt; the other marks count one. `nextAttemptAt` gives the earliest retry or
lease expiry for a worker to sleep until.

## Feedback

`feedback` (version 16) holds the user's love and hate. It is keyed on
`recordings.id`, so every file and Track of one song shares a row and a
reprojection that gives a Track a new id keeps it. `tracks.rating`, the unused
star rating, is a separate thing. Rows are removed with their recording
(`ON DELETE CASCADE`), which nothing does today.

`score` is what the user wants (`-1`, `0`, `1`) and `synced_score` what
ListenBrainz was last told, so `score IS NOT synced_score` is exactly the work
left. A row is kept until it is synced: feedback given while scrobbling is off
waits, and so does feedback on a Recording with no MusicBrainz recording id,
which is never sent. Score `0` with a `synced_score` of `1` or `-1` is a clear
waiting to be sent; `markSynced` deletes the row once it has been, and clearing
a change that was never sent deletes it at once. A change the service refused
for good sets `synced_score` to what was refused and records the reason in
`last_error`, so it is not sent again until the user changes it.

The MusicBrainz recording id is the one in effect for any file of the
Recording, preferring a file some Track plays: a locked Orca value, else the
file's tag, else an accepted match (see
[metadata.md](metadata.md#musicbrainz-recording-ids)). It is found after the
files are rescanned or retagged. Removing a root forgets its files but not
its recordings' feedback rows; rescanning the same folder creates new
recordings, so feedback given before the removal no longer shows on the
rescanned Tracks.

Version 16 also adds the index `files_by_recording ON files(recording_id)`,
which finds a Recording's files when looking for its MusicBrainz recording id.

`TrackSummary.feedback` comes from a `LEFT JOIN feedback` on
`tracks.recording_id` in the same statement as the page, never a query per row,
and the same statement selects `TrackSummary.recording_id` so a host can tell
which rows share a song. `FeedbackRepository.set` changes a bounded batch of
Tracks (`max_page`) in one write-lane transaction and skips, and counts, Tracks
without a Recording.

## Identification proposals

`identification_proposals` holds what the providers proposed for a file, keyed
on `files.id`: the providers that found the candidate (`musicbrainz`,
`acoustid` or `musicbrainz+acoustid`), its MusicBrainz recording id, Orca's
confidence from 0 to 1, and a JSON payload of what the providers said,
including each provider's confidence alone and AcoustID's score. `state` is 0
pending, 1 accepted, 2 dismissed. A file has one proposal per recording:
`IdentificationProposalRepository.recordSearch` finds an existing one by file
and recording id, whatever its provider, merges the new evidence into it and
keeps its state, so a dismissed proposal stays dismissed. A payload written
before per-provider confidences existed lends its row's confidence to the one
provider it names. Every payload field has a default, so payloads written
before a field existed still parse.

`identification_searches` (version 17) records which provider has answered
for which file, empty answers included: `(file_id, provider)` is its primary
key, `searched_at` is Unix seconds, and rows go with their file
(`ON DELETE CASCADE`). `recordSearch` writes the proposals and the search rows
of one search in one transaction, and only for providers that answered.
Migration 17 counts every file with a MusicBrainz proposal, in any state, as
searched by MusicBrainz, so no MusicBrainz search from before it is repeated.

`repository.unidentified_tracks` is the one definition of which Tracks the
matching job still has to search: those whose playing file has no recording
id in effect and lacks a search row for MusicBrainz, or for AcoustID when
AcoustID is in scope. The job's page and its count both use it, and every
lookup in it is by key: the three recording-id lookups and the two search-row
checks by primary key.

`acoustid_submissions` (version 17) records each fingerprint AcoustID
accepted: `(file_id, recording_mbid)` is its primary key, with the
`submission_id` AcoustID returned and `submitted_at`. Rows go with their file.
`repository.acoustid_submittable` selects the files a submission sends: an
Orca value for the recording id with `provider` or `user` provenance that is
the id in effect, is not the file's tag unless Orca wrote it there, and has
no row here for that id. Editing the id makes the file eligible again under
the new one.

`orca_metadata_values.written_at` (version 21) is when a tag write last put
the value into its file, or null. Changing the value clears it; undoing the
write does not. The submission query reads it to tell a tag Orca wrote from
one the file already had.

## Provider state

`provider_state` (version 19) holds each service's rate-limit block
(`blocked_until_ms`) and backoff (`backoff_ms`), keyed by service name, so
every process that opens the Library obeys one block. `provider_leases`
(version 19) records which process may talk to each service: `owner` is a
random id and `expires_at` is when the claim lapses. Both tables keep Unix
milliseconds. `ProviderStateRepository.claimLease` claims in one upsert that
applies only when the row is absent, expired or already the claimant's, so two
processes never both hold a service. See
[providers.md](providers.md#rules-toward-providers).

`provider_cache` keeps a provider's refusal of a query beside its answers: a
row whose `status` is not `200` is a refusal, which the provider clients
answer as refused until it expires and never use as an answer.

Version 19 also adds `identification_proposals.accepted_in_bulk`: 1 for a
proposal accepted by `acceptConfident`, 0 for one accepted on its own and for
every proposal accepted before version 19. AcoustID submission leaves out an
ID whose accepted proposal was found by AcoustID or accepted in bulk.

## Release artwork

`release_artwork` (version 20) holds a Release's front cover fetched from the
Cover Art Archive, one row per Release: `release_id` is its primary key and
references `releases(id)` with `ON DELETE CASCADE`, so a Release pruned or
reprojected under a new id loses its row. `musicbrainz_release_id` is the
release ID it was fetched for, `image` and `mime` the cover, and
`fetched_at` Unix seconds. A null `image` records that the archive had no
cover, which stands for 30 days. `ReleaseArtworkRepository.coverReleaseMbid`
chooses the release ID: the Release's tagged one, else the one most of its
accepted proposals name. See
[providers.md](providers.md#cover-art-archive).

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
