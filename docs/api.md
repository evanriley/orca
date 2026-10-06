# liborca Zig API

This file covers the public Zig API of liborca: embedding, the `Runtime`
operations, ownership and shutdown, the smart playlist rule format, client
identity and stability. The API is everything declared at the top level of the
`liborca` module (`liborca/root.zig`); `liborca.internal` is not part of it.

Non-Zig clients use the C ABI in `liborca/orca.h` instead; see
[frontends.md](frontends.md#c-abi).

## Embedding

Add Orca to the dependent project's `build.zig.zon`, by URL or by path:

```zig
.dependencies = .{
    .orca = .{ .path = "../orca" },
},
```

Import the module in its `build.zig`:

```zig
const orca = b.dependency("orca", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("liborca", orca.module("liborca"));
```

The module links its codec libraries and SQLite through the host's pkg-config
and compiles in the rest; see
[architecture.md](architecture.md#dependencies-and-licences).
[`examples/embed`](../examples/embed) is a complete project; `zig build test`
builds it.

## Surface

```zig
const orca = @import("liborca");

var runtime = orca.Runtime.init(allocator);
defer runtime.deinit();
const library = try runtime.openLibrary(io, "library.db");
var page = try runtime.libraryTrackQuery(library, "", .{ .limit = 50, .sort = .title });
defer page.deinit();
```

`Runtime` owns every library, player, zone and job, and shuts them down in
dependency order in `deinit`. Its methods are the operations, and every type
they take or return is exported beside it. Handles (`LibraryHandle`,
`PlayerHandle`, `ZoneHandle`, `JobHandle`) are generational. Pages and returned
values are owned by the caller and released with their `deinit`. Threading and
ordering rules are in
[Runtime ownership and shutdown](#runtime-ownership-and-shutdown) and
[control-plane.md](control-plane.md).

`setWaker(HostWaker)` installs the function liborca calls when a host's event
loop should pump. Call it right after `init`; it returns `error.WorkersRunning`
once a worker thread exists. `pump` executes the submitted commands and
publishes finished jobs. `nextPumpTimeoutMs` returns how long the loop may
sleep: 0 to pump now, null to wait for the waker alone. See
[control-plane.md](control-plane.md#waking-the-host).

### Roots, availability and watching

- `libraryRootPage` fills each `LibraryRoot` with `available` and track counts.
  `libraryRelocateRoot(library, io, root_id, path)` moves a root, keeping its id
  and every file and Track id, binds it to the new path's volume, rewrites the
  tag write journal's paths and returns the reconcile job it starts. Errors:
  `error.InvalidLibraryRoot`, `error.RootPathOverlaps`, `error.UnknownRoot`,
  `error.LibraryJobRunning`, `error.LibraryScanRunning`,
  `error.MutationInProgress` and `error.MutationNeedsReconciliation`.
- `libraryMissingFileCount` counts Tracks whose preferred file has no present
  location. `libraryAvailability(library, io)` re-checks every enabled root and
  returns a caller-owned `LibraryAvailability` (offline roots and the Tracks and
  Releases they leave unable to play); it can block on a hung mount, so a UI
  host calls it off its event loop with that thread's own `io`.
  `libraryReleasesAvailable` answers per Release. A scan or reconcile of a root
  on another volume than the one recorded ends `failed`.
- `libraryWatch(library, WatchOptions)` reconciles each directory that changes
  under a root, from `pump`, one reconcile at a time and never beside a scan,
  reconcile, projection or tag write of the Library (`error.AlreadyWatching`,
  `error.WatchingUnsupported` off Linux). `libraryUnwatch` stops it and
  `libraryWatchStatus` returns a `WatchStatus` (`WatchState`: `off`,
  `watching`, `degraded`, `unsupported`). `WatchOptions.degraded_rescan_ms` sets
  how often degraded roots are reconciled whole. A reconcile that recorded or
  marked missing a file publishes `Telemetry.library_changed`.
- `libraryFolderPage(library, root_id, relative_path, limit, offset)` returns a
  `FolderPage` of `FolderEntry` values: subfolders, then files, then images.
  The path is relative to the root, `""` for the root; a `.`, `..` or empty
  component, a leading or trailing `/` or a NUL is `error.InvalidFolderPath`, a
  limit outside 1 to 512 `error.InvalidLimit`. `playerPlayFolder` plays every
  Track below a folder in path order, at most `max_playlist_entries`
  (`error.FolderEmpty`). See [database.md](database.md#folder-browsing) and
  [storage.md](storage.md#unavailable-and-relocated-roots).
- `estimateAudioFiles(io, allocator, path, token, limit)` counts a folder's
  audio files as a `FolderEstimate` on the caller's thread, `error.Cancelled`
  once the `CancellationToken` is cancelled. See
  [storage.md](storage.md#estimating-a-folder-before-it-is-a-root).

### Jobs

- A Library runs one host job at a time. A job started while another holds the
  slot, or while the Library is paused, is returned `waiting` and started by
  `pump` in order. At most `max_waiting_jobs` (32) wait in the runtime, else
  `error.JobQueueFull`. Lyrics, artist and Release info fetches never wait.
- `jobQueuePage` returns the running and waiting `QueuedJob`s. `pauseJob` holds
  a running job at its next cancellation poll and `resumeJob` lets it carry on
  (`error.JobNotPausable` for a projection or tag write,
  `error.JobAlreadyFinished`). `pauseAll` also holds waiting jobs, watcher
  reconciles and idle maintenance until `resumeAll`; `libraryJobsPaused`
  reports it. `cancelJob` wakes a paused job within one 50 ms poll.
- `JobSnapshot` carries `started_at`, `paused`, `estimated_remaining_ms` (null
  until 10 s of progress, while paused and without a total), `current_item` and
  `detail`; `pump` publishes `Telemetry.job_progress` whenever they move.
  `jobScanStats` reports the `ScanStage`, `current_path` and `albums_found`.
  `ScanRequest.reprobe_all` reads every file again. See
  [storage.md](storage.md#incremental-scanning).
- `jobHistoryPage(library, allocator, filter, limit, offset)` returns finished
  jobs newest first, filtered by `JobHistoryFilter` (`all`, `scans`, `analysis`,
  `file_changes`, `problems`). `jobRetry(library, history_id)` starts a failed
  or cancelled job's request again (`error.JobNotRetryable`,
  `error.UnknownJobHistory`). See
  [control-plane.md](control-plane.md#history).
- `libraryMaintenance(library, MaintenanceOptions)` turns idle maintenance on or
  off (off by default). While every Player is idle and no other job runs,
  `pump` verifies one Release's recording IDs every `interval_ms`; a
  disagreement lands in Health as `recording_mismatch`. An interval of 0 is
  `error.InvalidMaintenanceOptions`. `libraryMaintenanceStatus` returns a
  `MaintenanceStatus`; `jobOrigin` returns a job's `JobOrigin` (`host`,
  `watcher`, `maintenance`) and `jobReconcileRoot` the root a reconcile walks.
  `startLibraryMatching`, `startReleaseCoverArtFetch` and
  `startAcoustIdSubmission` called while a unit runs cancel it and return a
  `waiting` job. See [control-plane.md](control-plane.md#idle-maintenance).

### Library facts

- `libraryStats(library)` returns `LibraryStats` (counts, files, bytes,
  duration, last scan, analysis and duplicate scan, `listens`); see
  [database.md](database.md#library-stats). `libraryCacheSize` returns a
  `CacheSize` of fetched artwork, photo, lyrics and info bytes and
  `libraryClearCache` deletes them; embedded and folder artwork and local
  lyrics are never touched. See [database.md](database.md#fetched-cache).
- `providerSources()` returns the `ProviderSource`s Orca takes data from, with
  their licences, and `supported_formats` the `SupportedFormat`s it reads;
  both are constants for a credits page.
- `libraryHealthSummary` returns a `HealthSummary` of `HealthKindSummary`s;
  `libraryHealthIssuePageOfKind` pages one kind. See
  [analysis.md](analysis.md#by-kind). Duplicates are groups:
  `libraryDuplicateGroupPage`, `libraryDuplicateGroupTotals`,
  `libraryDuplicateGroup` (the `DuplicateCopy`s, suggested copy first),
  `libraryKeepBoth`, `libraryIgnoreDuplicateGroup`,
  `libraryMergeDuplicateMetadata` and `libraryDuplicateCopyPlaylists` write no
  file; see [analysis.md](analysis.md#groups).
- `libraryBackfillPending` takes a `LibraryAvailability` and returns the `files`
  and `covers` that `startLibraryPropertyBackfill` can repair; a host starts the
  Job when either is non-zero, outside a scan.
- `startLibraryConsistencyPass` stores each Release's disagreements as open
  issues. `libraryMetadataIssueCount`, `libraryMetadataIssuePage`,
  `libraryApplyMetadataIssue`, `libraryApplyMetadataIssues` (checks all issues
  first), `librarySkipMetadataIssue` and `libraryMetadataIssueStatus` act on
  them, writing locked Orca values and no file. The C ABI has the Job kind and
  none of these calls. See [analysis.md](analysis.md#metadata-consistency).

### Browsing

- `TrackSummary` carries the ids (`release_id`, `artist_id`,
  `album_artist_id`, `recording_id`) and the facts a song list shows: `codec`,
  `sample_rate`, `bit_depth`, `lossy`, `added_at`, `play_count`,
  `last_played_at`, `explicit`, `track_total`, `disc_total`, `year`,
  `integrated_lufs` (null before an analysis), `bitrate_kbps` (null when size
  or duration is unknown), `feedback`, `rating` and `path` (a present location
  before an unverified one, empty when none).
- `TrackQuery` filters combine with AND: `year_min`/`year_max` (undated Tracks
  are left out), `lossless` (a Track with no probed codec matches neither
  value), `min_sample_rate`, `max_sample_rate`, `explicit_only`, `codec`
  (case-insensitive), `added_after`, `loved_only`, `genre_id` and `artist_id`.
  A Track with no value for the `TrackSort` sorts last either way.
  `libraryTrackMatchCount` and `libraryTrackQueryTotals` (`TrackTotals`) count
  what a page lists; `libraryTrackQueryPlayableIds` returns the playable Track
  ids among `limit` rows from `offset`, up to `max_track_id_window` (10,000), to
  queue a listing from any row.
- A `text` in `libraryTrackQuery` keeps every filter and orders by relevance,
  so `sort` and `direction` do not apply and `libraryTrackMatchCount` does not
  count a search. Each word must begin a word of the title, artist, album or
  album artist; no character is FTS5 syntax and wordless text matches nothing.
- `ReleaseSummary` carries `codec` (`mixed_codec` when Tracks differ),
  `max_sample_rate`, `max_bit_depth`, `lossless`, `release_type`, `explicit`,
  `loved` and `pending_reviews`. `ReleaseQuery` filters by
  `high_resolution_only` (above 48 kHz or 16 bits), `needs_review_only`,
  `lossless_only`, `year_min`/`year_max`, `has_artwork` (embedded, fetched or a
  front image in the folder), `added_after`, `loved_only`, `genre_id` and `text`
  (the word-prefix search of `librarySearch`). `ReleaseSort.most_played` and
  `.loved` are the other sorts. `libraryReleasePage` returns a page for a
  `ReleaseQuery` and `libraryReleaseCountMatching` counts what the query lists,
  ignoring its `limit` and `offset`.
- `release_type` is the lowercased primary type from the files' tags, else the
  release group's, which a release-info fetch or genre fill writes only while
  the Release has none. `ReleaseQuery.release_kind` (`album`, `ep_or_single`,
  `other`) filters by it; a Release with no type, and a compilation, is an
  `album`. `appearing_artist_id` keeps Releases with a Track credited to that
  Artist and filed under another album artist; `own_releases_only` with
  `album_artist_id` keeps only those filed under that Artist.
- `name_order` (`ignore_articles`, the default; `as_written`) on `ReleaseQuery`
  and `ArtistQuery` sets whether a sort by name skips a leading "The ", "A " or
  "An ". Names that do not start with an ASCII letter sort first.
- `libraryReleaseLetterIndex` returns `[]LetterBucket` (initial, `count`,
  `first_offset`; `'#'` for non-ASCII-letter initials) for a `ReleaseQuery`
  sorted by `title` or `artist` (`error.SortHasNoLetters` otherwise).
  `libraryReleaseQueryTotals` returns `ReleaseTotals`.
- `ArtistQuery` takes `ArtistSort` (`name`, `track_count`, `recently_loved`,
  `recently_added`), `loved_only`, `genre_id` and `role` (`all` or
  `album_artists`), applied to the page and `libraryArtistCountMatching`.
  `ArtistSummary` carries `loved`, `has_photo` and `cover_release_id`.
  `libraryArtistTotals` returns `ArtistTotals` or null for an unknown Artist.
- `libraryTrackDetails` returns `TrackDetails`: the file's properties and path,
  loudness, tags, the recording ID in effect with its `RecordingIdSource`
  (`tag`, `match`, `edit`), the first five `genres`, `feedback`, `rating` and
  `feedback_syncable`. The caller frees it with `deinit`.
- Genres: `libraryGenrePage` takes a `GenreQuery` and returns `GenreSummary`s;
  `libraryGenreCount`, `libraryGenre`, `libraryTrackGenres` (with their
  `Provenance`), `libraryReleaseGenres`, `libraryArtistGenres` and
  `libraryGenreArtwork` read them. `librarySetTrackGenres` gives Tracks up to
  `max_track_genres` (16) user genres, which outrank the files' tags until
  cleared with no names, and splits a name that lists several. It writes no file
  and returns `error.TooManyGenres`, `error.InvalidGenre` or
  `error.TrackNotFound`. See [database.md](database.md#genres).
- `librarySearch` returns `SearchResults`: `SearchHit`s grouped in `SearchKind`
  order (Artists, Releases, Tracks, Playlists, genres), most relevant first
  (lower `rank` is better), capped by `SearchLimits` (default 5, 5, 8, 4, 3;
  above `max_search_hits_per_kind`, 50, is `error.InvalidSearchLimits`). Each
  word must begin a word of the hit's title or subtitle, ignoring case and
  diacritics; quotes, operators and column filters match as text. Text over
  `max_search_text` (256 bytes) is `error.SearchTextTooLong`. The first Artist
  hit adds reason hits within its kind's cap (`tracks_by`, `main_genre_of`).
  `SearchResults.top` is the hit to feature, a copy not freed separately.
- `libraryRequestBrowse` queues a `BrowseRequest` (`track_page`, `track_totals`,
  `release_page`, `release_count`) on the Library's browse loader and returns
  its id; `libraryTakeBrowse` collects a finished `BrowseResult` (its `payload`
  is the synchronous method's result or error; `deinit` frees a page) and
  `libraryCancelBrowse` skips a request not started. Text and codec are copied
  (`error.SearchTextTooLong`, `error.CodecNameTooLong` over 32 bytes). At most 8
  requests are outstanding, else `error.BrowseQueueFull`. Results come in
  request order, read on a read-only connection and can predate a host's write;
  reload on `library_changed`. Destroying any Library drops every loader's
  requests and untaken results.

### Artwork

- `libraryTrackArtwork` and `libraryReleaseArtwork` read on the caller's thread
  and return, in order: the front cover a person chose, the front cover embedded
  in a file, a front image in the folder holding most of the Release's Tracks
  (stems `cover`, `front`, `folder`, then the largest), then the cover the Cover
  Art Archive fetch kept. A missing or non-image folder file falls through.
- `libraryRequestArtwork` queues a lookup on the Library's artwork loader (at
  most 64 outstanding), `libraryTakeArtwork` collects finished ones and
  `libraryCancelArtwork` skips one not started. `ArtworkSubject.artist` asks for
  the Artist's stored photo; `ArtworkSubject.release_group` (a lowercase
  MusicBrainz ID as `[36]u8`) asks for the cover an Artist fetch kept, with no
  image when none is. The C ABI has no such subject.
- A Release keeps at most one cover of each `ReleaseArtworkKind` (`front`,
  `back`, `booklet`); media files are never written.
  `librarySetReleaseArtwork` keeps bytes a person chose (the MIME type must be
  what the bytes sniff as; over `max_image_bytes` is `error.ArtworkTooLarge`),
  `libraryClearReleaseArtwork` returns false when none was kept and
  `libraryStoredReleaseArtwork` reads it without looking at files.
  `startReleaseCoverArtFetch` sends no request for a Release with a chosen,
  embedded or folder cover; see [providers.md](providers.md#cover-art-archive).
- `startCoverArtCandidates` lists the Cover Art Archive's images for a Release
  (and its release group's when its files name one), capped at
  `max_cover_art_candidates` (8); only the 250-pixel thumbnail is kept, and an
  unmeasurable image has a null size. When the release group's index will not
  come the Job succeeds with `CoverArtOutcome.partial`.
  `libraryCoverArtCandidates` reads the `CoverArtCandidate`s and
  `libraryUseCoverArtCandidate` fetches one again and keeps it as the chosen
  cover (`error.UnknownCoverArtCandidate`).
- The `artwork_problem` health issue names what is wrong with a front cover, in
  the order checked: `missing_front`, `conflicting` (embedded and folder covers
  differ by content hash) and `undersized` (the front in effect is under
  `minimum_cover_pixels`, 500, on a side). An unmeasured size or hash raises
  nothing. `libraryArtworkProblem` returns an `ArtworkFinding`.

### Tag edits and write-back

- `libraryEditTracks` sets Orca's own values as the user's locked values and
  returns `EditedTracks`. An edit that moves a track to another album or
  position keeps its id, even onto a position another Track held; that Track is
  pruned unless its own file moved in the same edit.
- `libraryTrackFieldStates` returns `TrackFieldStates` for up to 512 Tracks: per
  `EditableTrackField` the shared value and whether it is `mixed` or `edited`.
  It reads the database only.
- `planTagWrite` returns a `TagWritePlan`: each file's `TagWriteChange`s with
  the `Provenance` of Orca's value and `TagWriteFormat`, its `TagWriteGenres`,
  the `TagWriteConflict`s it leaves out because an unlocked value disagrees with
  the file's tag, and the files it skips. `tagWriteGenres` returns one file's
  `TagWriteGenres` from a held plan. `isMusicBrainzId` is the check
  `libraryEditTracks` applies to a recording ID.
- `libraryTagWriteGroupPage` returns finished tag writes newest first
  (`TagWriteGroup`: files, `TagWriteGroupState`, `can_undo`, `expired`) and
  `libraryTagWriteGroup(library, allocator, io, group_id)` a
  `TagWriteGroupDetail` of `TagWriteDiff`s, at most 512 rows with `more_files`.
  Both only read; see [metadata.md](metadata.md#change-history).
  `exportTagWriteHistory` writes every group's `orca-cli changes` line to a file
  atomically and refuses an existing file unless `replace` is set.
- Lyrics are read on a job: `startTrackLyrics`, with `LyricsOptions.fetch` also
  asking LRCLIB (needs the client identity). `jobLyricsOutcome` reports a
  `LyricsOutcome`, `jobTakeLyrics` moves the `Lyrics` to the caller once and
  `Lyrics.lineAt` gives the synced line at a position. See
  [metadata.md](metadata.md#lyrics) and [providers.md](providers.md#lrclib).

### Matching and Release review

Rules for scoring, accepting and applying live in
[metadata.md](metadata.md) and [providers.md](providers.md#matching); this
section lists the entry points, errors and limits.

- `startLibraryMatching(library, MatchRequest)` starts a `metadata_lookup` Job
  that searches MusicBrainz, and AcoustID by fingerprint, for Tracks without a
  recording ID and stores proposals. `MatchRequest.fingerprints` (default true)
  includes AcoustID when an application key is set; `track_id` and `release_id`
  narrow it. `jobMatchStats` returns `MatchStats`. One runs per runtime
  (`error.MatchingAlreadyRunning`), none beside an AcoustID submission
  (`error.AcoustIdBusy`). `jobMatchRelease(job)` returns the Release that holds
  most of an album's files once a Job started with `release_id` has finished, so
  a host can follow the album to its new id; null otherwise.
- Proposals: `libraryMatchReviewPage` (at most 512 `MatchReviewItem`s),
  `libraryMatchReviewCount`, `libraryUnidentifiedCount`,
  `libraryMatchProposals`, `libraryAcceptMatch` (a `MatchAcceptance`),
  `libraryDismissMatch`, `libraryConfidentMatchCount` and
  `libraryAcceptConfidentMatches`. Accepts reproject, so Track and Release ids
  can change; see [metadata.md](metadata.md#accepting-a-match).
- `libraryApplyRelease(library, allocator, release_id, fields)` stores the
  `ReleaseFieldSet` of the best candidate's tracklist snapshot as locked
  values and returns a `ReleaseApplyOutcome` (free with `deinit`):
  `values_written`, `track_values`, `release_values_only`, `artist_ids_unknown`,
  a `LeftAloneTrack` (`not_placed`, `no_play_file`) per Track given no
  release-track values and `reviewed_release_id`, set when nothing was left
  alone. Errors: `error.NoReleaseCandidate`, `error.NoReleaseTracklist`,
  `error.ReleaseTooLarge` (over 512 Tracks). `libraryApplyMatchedRelease`
  returns how many values it stored. See
  [metadata.md](metadata.md#applying-a-release).
- `libraryMarkReleaseReviewed(library, release_id, release_mbid)` marks a
  Release reviewed against `release_mbid` or the best candidate when null,
  whatever values differ (`error.ReleaseNotPlaced`), and
  `libraryUnmarkReleaseReviewed` forgets it (`error.UnknownRelease`,
  `error.ReleaseNotReviewed`); see
  [metadata.md](metadata.md#marking-a-release-as-reviewed).
  `libraryDismissReleaseCandidate` marks a release as not the Release.
- `libraryReleaseMatchPage(library, allocator, bucket, confident_at, filter,
  limit, offset)` returns at most 512 `ReleaseMatchItem`s of one
  `ReleaseMatchBucket` (`confident`, `needs_review`, `unmatched`, `reviewed`).
  `confident_at` is in (0, 1], else `error.InvalidMinimumConfidence`; a
  non-null `filter` is the word-prefix search of `librarySearch`
  (`error.SearchTextTooLong`). Each item with a candidate costs a Release view,
  snapshot and alignment. An item in the `reviewed` bucket that only its
  tags identify has `from_tags` set. `libraryReleaseMatchCounts` counts the
  buckets.
- `libraryReleaseMatchEvidence` returns a `MatchEvidence` and
  `libraryReleaseMatchDiff` a `ReleaseMatchDiff`, against `release_mbid` or the
  best candidate (`error.NoReleaseCandidate`); with a snapshot a field differs
  exactly when an Apply would change a value. See
  [metadata.md](metadata.md#match-review-diff).
- `libraryReleaseAlignment(library, allocator, release_id, release_mbid)`
  returns a `ReleaseAlignment` (free with `deinit`): the Release laid against
  the snapshot's tracklist as `ReleaseTrackPlacement`s with a `PlacementStatus`
  (`paired`, `automatic`, `suggested`, `not_in_files`), plus `not_on_release`.
  Errors: `error.NoReleaseTracklist` (Match Album writes one),
  `error.ReleaseTooLarge`, `error.NoReleaseCandidate`,
  `error.InvalidMusicBrainzId`. It reads only. See
  [metadata.md](metadata.md#release-alignment).
- `libraryPairReleaseTrack(library, release_id, release_mbid, track_id,
  release_track_mbid)` pairs a Track with a release track, replacing its earlier
  pairing, and returns a `PairingOrigin`; the files take its IDs as locked
  values. Errors: `error.TrackNotOnRelease`, `error.UnknownReleaseTrack`,
  `error.ReleaseTrackAlreadyPaired` and those of `libraryReleaseAlignment`.
  `libraryUnpairReleaseTrack` restores the replaced values
  (`error.TrackNotPaired`); `libraryReleaseTrackPairings` returns at most 512.
  See [metadata.md](metadata.md#pairing-a-track).
- `libraryTrackFingerprint(library, io, track_id)` returns a `TrackFingerprint`
  of the file a Track plays, decoding up to two minutes on the caller's thread
  when uncached; null without a present file.
- `startAcoustIdSubmission(library)` starts an `acoustid_submission` Job that
  sends fingerprints of files whose recording ID came from an accepted match or
  an edit, as the user whose key the `CredentialStore` holds under
  `acoustid_credential_service` / `acoustid_user_key_account`.
  `jobSubmissionStats` returns `SubmissionStats` and a `SubmissionOutcome`;
  `libraryAcoustIdSubmittableCount` and `libraryAcoustIdSubmittablePage` list
  `AcoustIdSubmittable`s. See [providers.md](providers.md#acoustid-submission).

### Providers

- Server setters (`setListenBrainzServer`, `setMusicBrainzServer`,
  `setAcoustIdServer`, `setLrclibServer`, `setWikidataServer`,
  `setWikimediaCommonsServer`, `setWikipediaServer`,
  `setListenBrainzLabsServer`) take `https`, or `http` only to `127.0.0.1` or
  `localhost` (`error.InvalidServerUrl`), apply from the next job or pass and
  may be called at any time. A null Wikipedia server asks each language's own
  wiki. `setAcoustIdClientKey(key)` copies the application key, or clears it
  when null; a `CredentialStore` value under `acoustid_credential_service` /
  `acoustid_client_key_account` overrides it.
- `startArtistInfoFetch(library, artist_id, ArtistInfoOptions)` starts an
  `artist_info` Job that gathers an Artist's photo, biography, years active and
  links, listeners and related artists, and fills genres. Options: `language`
  (default `en`), `force`, `offline`, `include_releases`. Errors:
  `error.ClientIdentityRequired`, `error.UnknownArtist`,
  `error.InvalidLanguage`. `jobArtistInfoOutcome` returns an
  `ArtistInfoOutcome` (`error.NotAnArtistInfoJob`); `jobArtistInfoStores`
  counts how often the running job stored part of what it found.
- `libraryArtistInfo` returns the stored `ArtistInfo` (null when none),
  `libraryArtistPhoto` an `EmbeddedImage`, `libraryArtistLinks` the links and
  `libraryRelatedArtists` at most `related_artists_max` `RelatedArtist`s. A
  fetch keeps photos of related artists outside the Library by MusicBrainz ID,
  at most `artist_info.related_photos_per_fetch` (8) per fetch, skipping those
  kept within 30 days unless `force`; `libraryRelatedArtistPhoto` and
  `libraryRelatedArtistPhotoInfo` read them.
- `libraryArtistElsewhere` returns the Artist's stored release groups of type
  Album or EP that the Library does not hold, newest first, as caller-owned
  `ElsewhereRelease`s (free each with `deinit`, then the slice). Request a kept
  cover with `libraryRequestArtwork` and `.{ .release_group = mbid }`. A group
  is held when its release-group MBID, without case, is in the `release_info`,
  file tags or Orca values of a Release filed under the Artist or one they
  appear on.
- `startReleaseInfoFetch(library, release_id, ReleaseInfoOptions)` keeps a
  Release's Wikipedia description and fills genres from its release group
  (errors as for artist info, with `error.UnknownRelease`).
  `jobReleaseInfoOutcome` (`error.NotAReleaseInfoJob`), `libraryReleaseInfo`.
- `setGenreFill(library, GenreFill)` turns automatic genre fill from MusicBrainz
  on or off (default on); `libraryGenreFill` reads it. `startGenreFill(library,
  GenreFillOptions)` fills the genres of up to `limit` Releases (1 to 512, else
  `error.InvalidLimit`) whatever the setting. See
  [providers.md](providers.md#release-info).

### Listening, love and ratings

- `processNextCommand` samples every Player bound to a Library at most every
  100 ms and records a play heard for half its length or four minutes on that
  Library's listen worker. `libraryTrackPlayStats` and `TrackDetails` report a
  recording's play count and last play through any of its files.
- `librarySetListenPolicy(library, ListenPolicy)` (`half_or_four_minutes`,
  `thirty_seconds`, `full_track`) sets how long a play must be heard;
  `libraryListenPolicy` reads it. A listen under a looser policy that falls
  short of ListenBrainz's rule is never sent.
  `librarySetListenRecording(library, false)` keeps none and
  `libraryListenRecording` reads it. `libraryClearListens`
  deletes the history, unsent listens and play counts, returns how many listens
  went and keeps ratings and loves.
- `librarySetScrobbling(library, enabled, offline, now_playing)` sends a
  Library's listens to ListenBrainz, for at most one Library per runtime. The
  token comes from the `CredentialStore` under `listenbrainz_token_service` /
  `listenbrainz_token_account`; `libraryScrobblerCredentialsChanged` has it
  validated once and `libraryScrobblerStatus` returns a `ScrobblerStatus`. See
  [providers.md](providers.md#listens) and
  [Listening from a host](frontends.md#listening-from-a-host).
- `librarySetFeedback(library, track_ids, Feedback)` (`none`, `loved`, `hated`)
  sets the feedback of the song behind each Track and returns a
  `FeedbackChange`. Feedback belongs to the Recording, shows on every Track of
  the song and is sent to ListenBrainz while the Library scrobbles when the song
  has a recording ID (`TrackDetails.feedback_syncable`). `libraryTrackFeedback`
  reads one Track's feedback. `librarySetReleaseLove` and `librarySetArtistLove`
  love Releases and Artists in the Library only, never sent;
  `libraryArtistLoved` reads an Artist's. `librarySetRating(library, track_ids,
  ?u8)` rates the song behind each Track from 1 to 100, or clears it.

### Playlists

`libraryPlaylists`, `libraryCreatePlaylist`, `libraryRenamePlaylist`,
`libraryDeletePlaylist`, `libraryPlaylistEntries`, `libraryPlaylistInsert`,
`libraryPlaylistRemove` and `libraryPlaylistMove` manage playlists;
`playerPlayPlaylist` plays one, `libraryImportPlaylist` and
`libraryExportPlaylist` read and write M3U files and `playerSaveQueueAsPlaylist`
saves the queue from the current entry. The limits, errors and M3U rules are
in [cli.md](cli.md#playlists-and-ratings).

- `libraryPlaylistPage(library, PlaylistQuery)` returns at most 512
  `PlaylistSummary`s; `libraryPlaylistCount` counts the query and
  `libraryPlaylist` returns one summary.
- `libraryPlaylistFormats` returns `PlaylistFormats` (up to 32 `CodecCount`s,
  free with `deinit(allocator)`); `libraryUpdatePlaylist` sets the description,
  pin, love or tags (at most `max_playlist_tags`); `libraryPlaylistTags` returns
  the tags alone.
- `libraryCreateSmartPlaylist(library, name, rules_json)`,
  `librarySetSmartPlaylistRules` and `librarySmartPlaylistRules` (null for a
  manual playlist) manage smart playlists. `librarySmartPlaylistCount` counts
  the Tracks rules match without storing anything and
  `librarySmartPlaylistPreview(library, allocator, rules_json, sample_limit)`
  returns a `SmartPlaylistPreview` from one evaluation: the count, `duration_ms`
  and the first `sample_limit` Tracks (at most 512, else
  `error.PageOutOfRange`). Rules are at most `max_smart_playlist_rules_bytes`,
  in the format under [Smart playlist rules](#smart-playlist-rules).

### Playback

- `PlayerStatus.last_failure` is the last queue entry that could not be opened,
  a `PlaybackFailure` with `track_id` and a `Reason`, cleared once an entry
  opened after it is heard. A Track whose root is unavailable fails with
  `error.TrackFolderUnavailable` and marks nothing missing. See
  [audio-engine.md](audio-engine.md#playback-failures).
- Queue edits: `playerQueueJump`, `playerQueueInsertNext`, `playerQueueRemove`
  and `playerQueueMove(player, from, to)`. The entry playing, and one already
  lined up after it, are refused with `error.QueueEntryInUse`, as is a move
  landing between them. Under shuffle a move changes only the shuffled order.
- `playerQueueHistory(player, offset, output)` fills `QueueHistoryEntry` values,
  newest first, with a `QueueHistoryReason` (`finished`, `skipped`,
  `replaced`); `playerQueueHistoryTracks` returns a `TrackPage` and
  `playerClearQueueHistory` empties it. The history holds
  `queue_history_capacity` (100) entries in memory and records no listen. See
  [audio-engine.md](audio-engine.md#queue-history).
- `playerSaveState(player, library)` saves the queue (at most 10,000 entries,
  those of other Libraries left out), the playing entry, its position, repeat
  and shuffle into the Player's Library. `playerRestoreState(player, library,
  mode)` replaces the queue with the saved one and, by `RestoreMode`, leaves it
  `paused`, starts `playing` or (`none`) changes nothing; it returns a
  `RestoreOutcome`. After either call the runtime saves the state every 30 s
  from `pump` while it plays, once on the tick after it pauses or stops, when
  the Player is destroyed or rebound or its Library destroyed, and in
  `shutdown`. A host calls `playerRestoreState` once at launch.
- `playerSetLongTrackMemory(player, threshold_ms)` sets how long a Track must be
  for the Player to remember where it was left (on pause, seek, stop or a skip
  away) and resume there; a Track that plays to its end forgets it. The default
  is 20 minutes; null turns it off. `PlayerStatus.resumed_from_ms` is where the
  audible entry resumed. See [database.md](database.md#saved-playback).
- `playerSetEqualizer` and `playerSetCrossfeed` set the ten-band `Equalizer` and
  stereo crossfeed. `playerSetParametricEqualizer` sets a `ParametricEqualizer`
  of up to `max_parametric_filters` (16) `ParametricFilter`s and a preamp
  (`validate` states the ranges); it and the ten-band equalizer are exclusive,
  turning one on turns the other off, and an invalid setting is rejected.
  `playerEqualizer` returns null while the parametric one runs and
  `playerParametricEqualizer` null while the ten-band one does.
  `ParametricEqualizer.response`, `parseEqualizerApo` and
  `writeEqualizerApo` need no Player.
- `playerSetReplayGainMode` takes a `ReplayGainMode` (`off`, `track`, `album`,
  `smart`: album while a neighbour in playback order shares the Release).
  `playerSetReplayGainPreamp` (dB, clamped to ±15),
  `playerSetReplayGainFallback` (`minus_6_db` or `as_is`, the default) and
  `playerSetPeakProtection` (default on) set the rest and
  `playerReplayGainSettings` reads them. `playerSetStopAfterCurrent` arms a
  one-shot stop after the entry heard; `playerStopAfterCurrent` reads it, false
  once it fired.
- `playerSignalPath` returns a `SignalPath`: the stages from source to output
  stream, `output_kind`, `device_format` (null when unknown) and why the path is
  or is not bit-perfect. `enumerateOutputDevices` fills `Device` snapshots with
  `capabilities`, null when the audio server did not report them within 500 ms;
  its `detail` parameter sets the cost: `.identity` asks no device for its
  formats, `.capabilities` waits up to 500 ms and belongs where they are shown.
  See [audio-engine.md](audio-engine.md).

### Smart playlist rules

A smart playlist stores a JSON document, version 1, and lists the Tracks it
matches each time it is read, one Track per Recording (the lowest id).

```json
{"v":1,"match":"all","rules":[
  {"field":"lossless","op":"is","value":true},
  {"match":"any","rules":[
    {"field":"year","op":"between","value":[1965,1979]},
    {"field":"title","op":"contains","value":"love"}]}
],"sort":{"field":"year","descending":true},"limit":25}
```

- `v` is required and must be 1. `match` is `all` (default) or `any`. `rules`
  holds rules and nested groups, at most four levels deep
  (`error.RuleNestingTooDeep`) and 32 rules in all (`error.TooManyRules`). An
  unknown key, or a document over 16 KiB, is `error.InvalidSmartPlaylistRules`.
- `sort.field` is a `TrackSort` name, `added_at`, `last_played_at`,
  `duration_ms` or `random`; `sort.descending` defaults to false. `random`
  orders by a hash of the Track id and a seed: a stored playlist's seed comes
  from the runtime's shuffle seed and its id, so its pages stay the same for the
  life of the runtime; rules read without a playlist use the shuffle seed
  itself. `libraryReshufflePlaylists()` draws a new random seed.
- `playlist_position` also takes `playlist`, a manual playlist's id, and orders
  Tracks by the first position of their Recording in it, Tracks it does not
  hold last. Without a positive integer `playlist` it is
  `error.InvalidRuleValue`; `playlist` on another sort is
  `error.InvalidSmartPlaylistRules`. Once that playlist is deleted the sort
  falls back to Track id order.
- `limit` is 1 to 10,000 (default 10,000). `limit_hours` (1 to 10,000) replaces
  it: the leading Tracks whose lengths add up to at most that many hours, a
  Track with no length counting as none. Both is
  `error.InvalidSmartPlaylistRules`.
- A rule is `field`, `op` and `value`. An unknown field is
  `error.UnknownRuleField`, an unknown operator `error.UnknownRuleOperator`,
  an operator the field's type does not take `error.RuleOperatorMismatch` and a
  value of the wrong shape `error.InvalidRuleValue`.

| Type | Fields | Operators |
| --- | --- | --- |
| text | `title`, `artist`, `album`, `album_artist`, `genre`, `codec`, `release_type` | `is`, `is_not`, `contains`, `starts_with`, `is_set`, `is_not_set` |
| integer | `year`, `play_count`, `rating`, `duration_ms`, `sample_rate`, `bit_depth` | `is`, `is_not`, `gt`, `gte`, `lt`, `lte`, `between`, `is_set`, `is_not_set` |
| date | `added_at`, `last_played_at` | `gt`, `gte`, `lt`, `lte`, `between`, `in_last_days`, `not_in_last_days`, `is_set`, `is_not_set` |
| boolean | `loved`, `lossless`, `explicit`, `has_artwork` | `is`, `is_not` |
| playlist | `in_playlist` | `is`, `is_not` |

Text values are 1 to 256 bytes and compare ignoring ASCII case; `genre` compares
the genre's folded key. Dates are Unix seconds; `in_last_days` and
`not_in_last_days` take 1 to 100,000 days counted back from now, and
`not_in_last_days` includes Tracks never played. `between` takes `[low, high]`
and includes both ends. `is_set` and `is_not_set` take no value. `in_playlist`
takes a manual playlist's id and matches the Tracks of the Recordings it holds;
saving or counting rules that name a smart playlist, itself included, or no
playlist is `error.InvalidRulePlaylist`, so membership never nests, and a stored
rule whose playlist is later deleted matches nothing. `has_artwork` matches a
Track whose file embeds a cover or whose Release has a fetched or a folder
cover, the test `TrackDetails.has_artwork` uses. Every value is bound as an
SQL parameter, never spliced into the query.

## Client identity

The host names itself to MusicBrainz, AcoustID and ListenBrainz before any
provider work; liborca has no identity of its own.

```zig
try runtime.setClientIdentity(.{
    .name = "MyPlayer",
    .version = "1.2.0",
    .contact = "https://myplayer.example",
});
```

- Until it is set, `startLibraryMatching`, `startAcoustIdSubmission`,
  `startArtistInfoFetch`, `startReleaseInfoFetch` and
  `librarySetScrobbling(library, true, ...)` return
  `error.ClientIdentityRequired`; turning scrobbling off and
  `libraryTrackFingerprint` need none.
- A later call replaces the identity; workers adopt it on their next pass.
- Each field must be non-empty, free of control characters and parentheses, and
  the three together at most 256 bytes, else
  `error.InvalidNetworkConfiguration`.
- The `User-Agent` is `Name/version ( contact ) liborca/<version>`; the suffix
  is left out only for the name `Orca` at liborca's own version, which is how
  `orca-cli` and `orca-gtk` identify themselves.

## Runtime ownership and shutdown

`Runtime` is the process-level ownership root. The host supplies its allocator
and calls `deinit`, which is idempotent after an explicit `shutdown`.
Runtime-visible objects use typed generational handles: destroying an object
increments the slot generation, so a stale handle never resolves.

- A Player owns its transport, `SourceQueue` and one engine thread; a Zone owns
  its render path, device and output session. Zones reach their Player's engine
  only through an acknowledged published snapshot, never by resolving a handle,
  so a worker never touches a handle pool. Moving a Zone to another Player waits
  for the previous engine's acknowledgement and closes the output first; see
  [audio-engine.md](audio-engine.md).
- A Library a Player has been bound to, or that scrobbles, has a listen worker.
  Its ring, configuration and status belong to the Library and outlive the
  worker: a drain joins it, after it records everything in its ring, and the
  next listen, bind or scrobbling enable starts a new one.
- A watched Library has a watcher thread
  ([storage.md](storage.md#watching-roots)); the Library keeps its
  `WatchOptions`, and the watcher and its queued changes go on a drain.
- `destroyLibrary` drains every worker in the process, then restarts the
  scrobbling Library's listen worker, so its queue keeps its retry times, and a
  watcher for every other watched Library, whose roots are reconciled whole
  because the drain may have cancelled a reconcile or missed an event.
- Idle maintenance keeps its schedule on the Library's record, which survives a
  drain; a drain finalizes its unit and the next starts one interval later. A
  waiting host job holds a Library handle and a request, not a worker, and
  `destroyLibrary` finishes its Library's waiting jobs `cancelled`. See
  [control-plane.md](control-plane.md#idle-maintenance).
- The `CredentialStore` given to `setCredentialStore` is borrowed: its context
  must outlive the runtime, and `get` runs on a listen worker's thread.
  `setClientIdentity`, the server setters and `setAcoustIdClientKey` copy.
- Listen workers share one network `std.Io`, created with the first worker and
  deinitialized by `deinit`. Creating it installs Zig's SIGIO and SIGPIPE
  handlers and deinitializing restores the dispositions found. A host sets its
  own dispositions before creating the runtime and leaves them unchanged while
  it exists.

### Replacing the open Library

A host that replaces its open Library while the runtime lives, as `orca-gtk`
does when it switches libraries, follows this order:

1. Open the next Library before destroying the current one, so a failed open
   leaves the current one open and playing.
2. Join the host's own threads that hold the current Library's handle;
   `destroyLibrary` drains only liborca's workers.
3. Pause the Player and save its state into the current Library.
4. Call `destroyLibrary`.
5. Clear the Player's queue. Until step 4 the Player is bound, and unbinding
   saves the queue into the Library again, so a queue cleared earlier would
   overwrite the one saved in step 3.

### Shutdown

`Runtime.shutdown` follows dependency order, work, Zones, Players, Libraries:

1. Stop accepting commands and enter `shutting_down`.
2. End open listens, stop every engine thread, cancel job workers and all other
   registered work and block until every worker has finished (a paused job
   worker sees its cancelled token within one 50 ms poll). Then, in order:
   record each host job's history; release the drained workers, closing each
   loader's read-only connection before its Library's database closes; discard
   tag write plans awaiting approval; finish every waiting host job
   `cancelled`; cancel and drain Jobs; save each Player's state and long Track
   position (see [Playback](#playback)).
3. Destroy Zones, closing their output sessions.
4. Free Players.
5. Close each Library's database and release its listen state.
6. Enter `stopped`; repeated shutdown calls are no-ops.

No object is freed while a worker holding a pointer into it can run. The host's
waker is never called once `shutdown` returns: every thread that
calls it is joined in step 2 and `submit` refuses a shutting-down runtime.
`deinit` runs `shutdown`, then frees the handle pools, work registry and
network `std.Io`.

## Stability

liborca is pre-1.0. The C ABI in `orca.h` is versioned by `ORCA_ABI_VERSION` and
the shared library's SONAME, `liborca.so.<ORCA_ABI_VERSION>`. Within one ABI
version functions and enum values are only added, never removed or changed, and
a reserved field gains a meaning only as an addition for which zero keeps the
old behaviour. The Zig API may break in any minor release; `CHANGELOG.md`
records each break.
