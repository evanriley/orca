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
health issues attached to it. The exception is re-tagging one of several
byte-identical copies, which splits that copy off (below).

A scan re-finds a file through a cascade, cheapest first:

1. `locations(volume_id, uri)` — the same path on the same volume.
2. `locations(volume_id, native_inode, size_bytes, modified_ns)` — a rename or
   move within one filesystem.
3. `files.quick_hash` — BLAKE3 over (first 64 KiB ‖ last 64 KiB ‖ size), from
   `storage/quick_hash.zig`. Catches copies, cross-volume moves and restores.
4. `files.audio_hash` — over the decoded audio payload only, so a tag write
   does not change it. Written by `library/analysis_pass.zig`, which is the
   only pass that decodes a whole file, and never by a scanner. It holds for
   the bytes it was measured from: an update that records a different
   `quick_hash` clears it, and it stays NULL until the analysis pass decodes
   the new bytes.

**A file is one set of bytes.** Byte-identical copies are one file at several
locations: a new path holding bytes the Library already has joins that file
through tier 3. When a changed path resolves to a file that is still present at
another path and records a different `quick_hash`, the path has *diverged*:
the other path still holds the bytes the file describes, so the path gets a
file of its own instead of rewriting the shared one.
`FileRepository.resolveForBytes` decides this and `forkLocked` makes the new
file, in the scan batch's transaction, and `resolveOrCreateFile` applies the
same rule. The split moves the location to the new file, copies Orca's values
and locks to it with `written_at` cleared, and re-points journal rows that
name the path. The new file takes the bytes' properties and observed tags from
the read; analysis results, the audio hash, health issues, identification
proposals and searches, AcoustID submissions and listens stay with the file the
copy left. A scan reprojects both copies' folders. Only a `present` location
counts as the other path, because a `missing` one is usually what a move left
behind, and a location on the same volume with this path's inode does not
count, because a hard link cannot hold other bytes. A file with no quick hash,
or whose only present location is this path, is updated in place.

Not handled yet:

- A changed path whose new bytes equal another file's stays on its own file,
  so two files can share a `quick_hash`.
- Two copies changed in the same way end as two files with equal hashes.
- A tag write writes one location of a file, not every copy of it.

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
exists), runs mutation-journal recovery, applies the remaining migrations, and
recovers again, for the rows a migration made nonterminal. A nonterminal
staged file mutation must reach a terminal state before any migration rewrites
the tables it refers to, and a Library whose journal cannot be converged is not
opened at all — the same posture as an unknown newer schema version. Recovery
and the migrations after it run only under the journal lock; see
[Concurrency](#concurrency).

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

Migration 22 sets `modified_ns` to -1 on the present locations of files whose
`observed_file_tags` row holds artwork and nothing else, with no
`observed_file_genres` rows. No file has that modification time, so the next
scan, reconcile or watch pass re-observes them: an ID3v2 tag holding only a
cover was read in preference to the file's ID3v1 trailer or `LIST`/`INFO`
chunk, and now the cover is kept on those values. File rows, quick hashes and
Orca's values are left alone.

Migration 23 sets `files.audio_hash` to NULL unless the file has an
`orca.temporal-fingerprint` version 2 row in `analysis_results` whose
`source_identity` equals the file's current `quick_hash`. Before it, a rescan
of changed bytes kept the hash of the old audio, and the duplicate pass reported
files as exact duplicates of audio they no longer held. The analysis pass
measures the cleared files again.

Migration 24 adds `provider_state.next_request_ms`, the earliest Unix
millisecond a service may next be sent a request: the minimum interval after
the last request, or the end of a quota window a response announced with
`X-RateLimit-Remaining: 0`. Before it, both lived only in the Gateway that
received them, so the next job's Gateway could send inside the window or less
than a second after the previous job's last request. Existing rows keep their
block and backoff and start with the column NULL.

Migration 25 sets `modified_ns` to -1 on every present location of a file
with more than one present location, so the next scan, reconcile or watch pass
re-observes them, as after migration 22. Before it, a copy whose bytes changed
rewrote the file it shared with an untouched copy: both paths named a file
describing the changed bytes, the untouched copy's Track disappeared, later
scans skipped it, and the duplicate pass still reported the two as exact
copies. Re-observing applies the divergence rule, so the file keeps the copy
whose bytes it records and every other copy splits off into a file of its own.

Migration 26 sets a journal operation to `undoing` (6) when it is `committed`
(2) in a group that also holds a `rolled_back` (3) operation and no `planned`,
`staged`, `failed` or `needs_reconciliation` one (0, 1, 4, 5). Before it, an
undo rolled operations back one at a time, so a crash between two files left
the group half undone in states recovery never selected, and a retried undo
refused it as not committed. The recovery pass that follows the migrations in
`LibraryDatabase.open` finishes those undos. `MutationState` values are stored
by number, so new states are appended and never reordered.

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
reprojection that gives a Track a new id keeps it. Star ratings are a
separate thing (below). Rows are removed with their recording
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

## Playlists and ratings

Migration 27 (version 27) adds `ratings`, `playlists` and `playlist_entries`,
and drops `tracks.rating` with its index after copying each Recording's
highest rating into `ratings`. The column lived on a row whose id changes
when an edit reprojects a Track, so no rating could have survived there.

- `ratings` is keyed on `recordings.id`, like `feedback`, with `rating`
  between 1 and 100 and no row for unrated.
- `playlist_entries` is `WITHOUT ROWID`, keyed on `(playlist_id, position)`,
  and names a `recording_id`. Positions are contiguous from 0. A shift parks
  the moved range on negative positions before landing it, because SQLite
  checks the primary key row by row and an in-place shift collides with a
  neighbour that has not moved yet.
- Entries and ratings go with their Recording, and entries with their
  playlist (`ON DELETE CASCADE`).
- `tracks_by_recording ON tracks(recording_id)` resolves an entry or rating to
  its Tracks, and `locations_by_uri ON locations(uri)` finds the location an
  imported playlist names.

`TrackSort.rating` has no index; on 500,000 Tracks a page sorts in about
0.1 s. See [playlists.md](playlists.md) for the behaviour.

## Identification proposals

`identification_proposals` holds what the providers proposed for a file, keyed
on `files.id`: the providers that found the candidate (`musicbrainz`,
`acoustid` or `musicbrainz+acoustid`), its MusicBrainz recording id, Orca's
confidence from 0 to 1, and a JSON payload of what the providers said,
including each provider's confidence alone, AcoustID's score and the status,
date and track count of each release a search listed. `state` is 0
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
no row here for that id. A `provider` value also needs its accepted proposal
on the same file. Editing the id makes the file eligible again under the new
one.

`identification_proposals.album_group` (version 28) is null, or the integer
an [album correction](metadata.md#corrections) shares among its proposals,
one past the highest group in use when a verification forms it. A
verification unit first takes its files' proposals out of any group, so a
group holds the proposals of one unit. The partial index
`identification_proposals_album_group ON (album_group, state) WHERE
album_group IS NOT NULL` lists and finds groups. The review page and its
count leave grouped proposals out.

`health_dismissals` (version 29) holds one row per dismissed health issue,
keyed on `(file_id, kind)` and going with its file: the file's `quick_hash`
when it was dismissed, null for a file never hashed, and `dismissed_at` in
Unix seconds. The health page and count leave out an issue whose dismissal
`quick_hash IS files.quick_hash`, through the primary key. Version 29 also
adds `library_health_issues.related_file_id`, the other file of a duplicate,
set to null when that file is deleted, with the partial index
`library_health_by_related` the delete uses. See
[analysis.md](analysis.md#dismissals).

`recording_verifications` (version 28) holds each file's latest
[verification](providers.md#verification), keyed on `files.id` and going
with its file: the `quick_hash` the file had, the `recording_mbid` in effect,
the `outcome` (0 agrees, 1 disagrees, 2 unconfirmed, 3 no fingerprint), the
recordings heard as JSON (`[{"mbid","score"}]`, strongest first, at most
eight; null for no fingerprint), and `verified_at` in Unix seconds. Staleness
is computed, never stored: a row is stale when `quick_hash IS NOT
files.quick_hash` or `recording_mbid IS NOT` the recording ID in effect.
`repository.verifiable_*_sql` select the play files with a recording ID in
effect whose row is missing or stale, per Release, per Track or for Tracks
with no Release, through `tracks_release` and primary keys, and add a file
whose row `disagrees` when its Release has such a file or for one Track.
Each is built from the one `verifiable` definition, so the job's count and
its walk agree. A
correction AcoustID found is never submitted back to it: its accepted
proposal was not found by MusicBrainz alone.

`orca_metadata_values.written_at` (version 21) is when a tag write last put
the value into its file, or null. Changing the value clears it; undoing the
write does not. A tag write marks the file its path resolves to after the
write is observed, which is a new file when the path was one copy of a shared
file; the copy the write left keeps the value unmarked. The submission query
reads it to tell a tag Orca wrote from one the file already had. A copy split
off by a tag write has no `acoustid_submissions` row, so a recording id the
user edited is sent again for it.

## Provider state

`provider_state` (version 19) holds each service's rate-limit block
(`blocked_until_ms`), backoff (`backoff_ms`) and next request time
(`next_request_ms`, version 24), keyed by service name, so
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
ID whose accepted proposal was found by AcoustID or accepted in bulk, and an
ID a file holds without its accepted proposal, as a copy split off a shared
file does.

## Release artwork

`release_artwork` (version 20) holds a Release's front cover fetched from the
Cover Art Archive, one row per Release: `release_id` is its primary key and
references `releases(id)` with `ON DELETE CASCADE`, so a pruned Release loses
its row; one reprojected under a new id hands it over as
[Album love](#album-love) describes. `musicbrainz_release_id` is the
release ID it was fetched for, `image` and `mime` the cover, and
`fetched_at` Unix seconds. A null `image` records that the archive had no
cover, which stands for 30 days. `ReleaseArtworkRepository.coverReleaseMbid`
chooses the release ID: the Release's tagged one, else the one most of its
accepted proposals name. See
[providers.md](providers.md#cover-art-archive).

## Album love

`release_loves` (version 30) records the albums the user loves: one row per
loved Release, `release_id` its primary key referencing `releases(id)` with
`ON DELETE CASCADE`, and `loved_at` the Unix seconds it was loved. No row
means not loved. It is kept in the Library only: it is not `feedback`, which
belongs to a Recording and is sent to ListenBrainz, so loving an album
changes no song's feedback and is never sent.

A Release's id is not stable. An edit, an accepted match or a retag that
changes the album, album artist or release ID reprojects its Tracks under a
new Release and prunes the old one, which would cascade the love away. So,
like `release_artwork`, the projection hands the row over before pruning
(`carryReleaseState` in `library/projection.zig`): when a Release is no longer
used, its row goes to the Release that now holds most of its moved Tracks, a
tie going to the lower id, and only when that Release has no row of its own.
Two loved Releases merging into one therefore keep one love, and a split
album's love goes to the larger side. A Release removed outright, as
`remove-root` removes the Releases only its files used, takes its row with it.

`ReleaseLoveRepository.set` loves or clears a bounded batch of Releases
(`max_page`) in one write-lane transaction and skips, and counts, ids that
name no Release. Loving a loved Release keeps its `loved_at`.
`ReleaseSummary.loved` comes from a `LEFT JOIN release_loves` in the page's
own statement; `ReleaseQuery.loved_only` and `ReleaseSort.loved` (most
recently loved first) read the same table. It has no index on `loved_at`:
a filtered page reads the whole table, which holds one row per loved album,
and the unfiltered sort orders every Release however it is indexed.

`TrackQuery.loved_only` and `TrackSort.loved` read `feedback` instead: a
Track is loved when its Recording's `score` is `1`, so a clear still waiting
to be sent (`score` `0`) is not, and the sort orders by `feedback.updated_at`,
most recent first, with Tracks that are not loved last in either direction.

## Track lyrics

`track_lyrics` (version 31) keeps what LRCLIB answered for a Track, one row
per Track: `track_id` is its primary key and references `tracks(id)` with
`ON DELETE CASCADE`. `query_digest` is the BLAKE3 digest of the title,
artist, album and duration the Track was looked up with, `lrclib_id` the
record's id, `synced` and `plain` its texts as LRCLIB sent them, and
`instrumental` 1 for an instrumental. A row with neither text that is not
instrumental records a miss. `fetched_at` is Unix seconds.

A row stands only while its digest matches the Track's current values: an
edit or a rescan that changes any of them leaves the row in place but
unused, and the next fetch replaces it. A Track's id survives its edits, so
no row is handed over. `TrackLyricsRepository.put` replaces the row in one
write-lane transaction and stores nothing for a Track that no longer
exists. See [providers.md](providers.md#lrclib).

## Concurrency

- The primary connection uses WAL and `synchronous=NORMAL`.
- One write lane serializes complete write transactions. It is a real
  futex-backed mutex (`std.Io.Mutex`), not a spinlock: a scan worker holds it
  across a bounded 256-row transaction while UI threads read.
- Read snapshots use independent read-only connections.
- Connections use SQLite's full-mutex mode and a five-second busy timeout.
- One process at a time owns the mutation journal: the holder of an exclusive
  `flock` on `<database>.orca-journal.lock`, taken without waiting by open's
  recovery and by each tag write, undo and prune, which recover first. An open
  that cannot take it defers recovery to the next holder, and refuses with
  `error.MutationInProgress` when a migration is due. See [metadata.md](metadata.md#the-journal-lock).
- Prepared batch statements are reused within one transaction.
- On Linux, liborca switches SQLite's `unix` VFS from POSIX record locks to
  open file description (OFD) locks before its first connection opens. A
  POSIX lock belongs to the process, so any `close` of the database, `-wal`
  or `-shm` file anywhere in the process, such as a GTK file dialog browsing
  the folder, released it. A second Orca process then took itself for the
  last connection, check-pointed and deleted the WAL, and the first process's
  later writes went to an unlinked file and were lost. An OFD lock belongs to
  the open file and survives other closes. Caveats:
  - The override is process-wide: it applies to every SQLite connection in
    the process, the embedder's included.
  - An embedder's own multi-connection SQLite use in rollback-journal mode
    in the same process can see spurious `SQLITE_BUSY`.
  - An embedder must not open SQLite connections before liborca's first
    open: SQLite's system-call table must not change under open
    connections.
  - macOS has no OFD locks and keeps POSIX locks; see
    [roadmap.md](roadmap.md#known-issues).

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
