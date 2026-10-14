# Zig API

The public Zig API of liborca is everything declared at the top level of the
`liborca` module (`liborca/root.zig`). `liborca.internal` is not part of it.
This page covers embedding, an index of the `Runtime` operations, the smart
playlist rule format, client identity, ownership and shutdown, and stability.

Behavior, errors and limits of each operation are in its doc comment in
`liborca/core/runtime.zig`. Non-Zig clients use the [C ABI](c-abi.md).

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

The process rules in [the C ABI's Embedding section](c-abi.md#embedding) apply
to Zig hosts too. On Linux, the first `Runtime.init` replaces SQLite's `fcntl`
with OFD locks for the whole process, once. A host creates the runtime before it
opens any SQLite connection of its own, or every `openLibrary` fails with
`error.SqliteLocksNotInstalled`. Every call on one `Runtime`, `deinit`
included, comes from the thread that created it.

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
values are owned by the caller and released with their `deinit`.

The index below groups the methods by area. A method named `library*` takes a
Library handle, `player*` a Player handle, `zone*` a Zone handle, `job*` a Job
handle, and `start*` returns a Job.

### Event loop

- `setWaker` installs the function liborca calls when the host's event loop
  should pump; call it right after `init`.
- `pump` runs submitted commands and publishes finished jobs.
- `nextPumpTimeoutMs` returns how long the loop may sleep.
- `processNextCommand` runs one queued command, and samples Players for
  listens.
- `shutdown` and `deinit` end the runtime; see
  [Runtime ownership and shutdown](#runtime-ownership-and-shutdown).

### Roots, availability and watching

- `libraryRootPage` lists roots with availability and track counts.
- `libraryRelocateRoot` moves a root on disk, keeping ids.
- `libraryMissingFileCount` counts Tracks with no present file.
- `libraryAvailability` re-checks every root; it can block on a hung mount, so
  a UI host calls it off its event loop.
- `libraryReleasesAvailable` answers per Release.
- `libraryWatch`, `libraryUnwatch` and `libraryWatchStatus` reconcile changed
  directories as they change (Linux).
- `libraryFolderPage` lists a root's subfolders, files and images.
- `playerPlayFolder` plays every Track below a folder.
- `estimateAudioFiles` counts a folder's audio files before it becomes a root.

### Jobs

- `jobQueuePage` lists running and waiting jobs.
- `pauseJob`, `resumeJob`, `cancelJob`, `pauseAll`, `resumeAll` and
  `libraryJobsPaused` control them.
- `jobScanStats` reports scan progress; `ScanRequest.reprobe_all` reads every
  file again.
- `jobHistoryPage` lists finished jobs and `jobRetry` starts a failed one again.
- `libraryMaintenance` and `libraryMaintenanceStatus` configure idle
  maintenance; `jobOrigin` and `jobReconcileRoot` describe a job.
- `startLibraryScan`, `startLibraryAnalysis`, `startLibraryProjection`,
  `startLibraryPropertyBackfill` and `startLibraryConsistencyPass` start
  library work.

### Library facts

- `openLibrary` opens a Library, upgrading an older one in place after writing
  a copy; `libraryUpgradeCopyPath` returns that copy's path.
- `libraryStats`, `libraryCacheSize` and `libraryClearCache` report and clear
  counts and fetched data.
- `providerSources` and `supported_formats` are constants for a credits page.
- `libraryHealthSummary` and `libraryHealthIssuePageOfKind` list Health issues.
- `libraryDuplicateGroupPage`, `libraryDuplicateGroupTotals`,
  `libraryDuplicateGroup`, `libraryKeepBoth`, `libraryIgnoreDuplicateGroup`,
  `libraryMergeDuplicateMetadata` and `libraryDuplicateCopyPlaylists` manage
  duplicate groups; none writes a file.
- `libraryUnanalyzedCount` and `libraryAnalysisCoverage` report what analysis
  would measure; `libraryBackfillPending` reports what a backfill would repair.
- `libraryMetadataIssueCount`, `libraryMetadataIssuePage`,
  `libraryApplyMetadataIssue`, `libraryApplyMetadataIssues`,
  `librarySkipMetadataIssue` and `libraryMetadataIssueStatus` act on
  consistency issues, writing locked Orca values and no file.

### Browsing

- `libraryTrackQuery`, `libraryTrackMatchCount`, `libraryTrackQueryTotals` and
  `libraryTrackQueryPlayableIds` page and count Tracks for a `TrackQuery`. A
  `text` query orders by relevance.
- `libraryReleasePage`, `libraryReleaseCountMatching`,
  `libraryReleaseQueryTotals` and `libraryReleaseLetterIndex` do the same for
  Releases.
- `libraryArtistPage`, `libraryArtistCountMatching` and `libraryArtistTotals`
  do the same for Artists.
- `libraryTrackDetails` returns one Track's file properties, tags, loudness,
  genres, feedback and rating.
- `libraryGenrePage`, `libraryGenreCount`, `libraryGenre`,
  `libraryTrackGenres`, `libraryReleaseGenres`, `libraryArtistGenres` and
  `libraryGenreArtwork` read genres; `librarySetTrackGenres` sets a Track's
  user genres.
- `librarySearch` returns hits grouped by kind, most relevant first.
- `libraryRequestBrowse`, `libraryTakeBrowse` and `libraryCancelBrowse` run
  browse queries on the Library's browse loader instead of the caller.

### Artwork

- `libraryTrackArtwork` and `libraryReleaseArtwork` read a cover on the
  caller's thread.
- `libraryRequestArtwork`, `libraryTakeArtwork` and `libraryCancelArtwork` do
  it on the artwork loader.
- `librarySetReleaseArtwork`, `libraryClearReleaseArtwork` and
  `libraryStoredReleaseArtwork` manage a chosen cover; no media file is
  written.
- `startReleaseCoverArtFetch` fetches a cover from the Cover Art Archive.
- `startCoverArtCandidates`, `libraryCoverArtCandidates` and
  `libraryUseCoverArtCandidate` list and choose archive images.
- `libraryArtworkProblem` returns the `artwork_problem` Health finding.

### Tag edits and write-back

- `libraryEditTracks` sets Orca's own values as the user's locked values.
- `libraryTrackFieldStates` reports the shared value of each field across
  Tracks.
- `planTagWrite` and `tagWriteGenres` build a reviewable plan of file tag
  changes; `isMusicBrainzId` validates a recording ID.
- `libraryTagWriteGroupPage` and `libraryTagWriteGroup` read the change
  history; `exportTagWriteHistory` writes it to a file.
- `startTrackLyrics`, `jobLyricsOutcome` and `jobTakeLyrics` read lyrics, with
  `LyricsOptions.fetch` also asking LRCLIB; `Lyrics.lineAt` finds the synced
  line at a position.

### Matching and Release review

- `startLibraryMatching` searches MusicBrainz and AcoustID for Tracks without
  a recording ID; `jobMatchStats` and `jobMatchRelease` report the result.
- `libraryMatchReviewPage`, `libraryMatchReviewCount`,
  `libraryUnidentifiedCount`, `libraryMatchProposals`, `libraryAcceptMatch`,
  `libraryDismissMatch`, `libraryConfidentMatchCount` and
  `libraryAcceptConfidentMatches` review and accept proposals.
- `libraryApplyRelease` and `libraryApplyMatchedRelease` store a candidate
  release's values as locked values.
- `libraryMarkReleaseReviewed`, `libraryUnmarkReleaseReviewed` and
  `libraryDismissReleaseCandidate` record review decisions.
- `libraryReleaseMatchPage`, `libraryReleaseMatchCounts` and
  `libraryReleaseMatchBucket` list Releases by match bucket.
- `libraryReleaseMatchEvidence` and `libraryReleaseMatchDiff` explain a
  candidate.
- `libraryReleaseAlignment`, `libraryPairReleaseTrack`,
  `libraryUnpairReleaseTrack` and `libraryReleaseTrackPairings` align and pair
  Tracks with a release's tracklist.
- `librarySimilarTracks` returns the Tracks whose audio embeddings are nearest.
- `libraryTrackAudioFeatures` returns tempo, key and energy estimates.
- `libraryTrackFingerprint` returns a Track's Chromaprint fingerprint.
- `startAcoustIdSubmission`, `jobSubmissionStats`,
  `libraryAcoustIdSubmittableCount`, `libraryAcoustIdSubmittablePage` and
  `libraryAcoustIdSubmittedCount` submit fingerprints to AcoustID.

### Providers

- `setListenBrainzServer`, `setMusicBrainzServer`, `setAcoustIdServer`,
  `setLrclibServer`, `setWikidataServer`, `setWikimediaCommonsServer`,
  `setWikipediaServer` and `setListenBrainzLabsServer` select another server:
  `https`, or `http` only to `127.0.0.1` or `localhost`.
- `setAcoustIdClientKey` sets the AcoustID application key.
- `setEmbeddingModelPath`, `embeddingModelState` and `embeddingModel` name the
  audio-embedding model file and report its state and which model it is.
- `startEmbeddingModelDownload` fetches a model to a path.
- `startArtistInfoFetch`, `jobArtistInfoOutcome` and `jobArtistInfoStores` run
  and report an artist-info fetch.
- `libraryArtistInfo`, `libraryArtistPhoto`, `libraryArtistLinks`,
  `libraryRelatedArtists`, `libraryRelatedArtistPhoto`,
  `libraryRelatedArtistPhotoInfo` and `libraryArtistElsewhere` read the stored
  result.
- `startReleaseInfoFetch`, `jobReleaseInfoOutcome` and `libraryReleaseInfo` do
  the same for a Release.
- `setGenreFill`, `libraryGenreFill` and `startGenreFill` control genre fill
  from MusicBrainz.

### Listening, love and ratings

- `librarySetListenPolicy`, `libraryListenPolicy`, `librarySetListenRecording`,
  `libraryListenRecording` and `libraryClearListens` control the play history.
- `libraryTrackPlayStats` reports a recording's play count and last play.
- `librarySetScrobbling`, `libraryScrobblerCredentialsChanged` and
  `libraryScrobblerStatus` control ListenBrainz submission; see
  [Listening from a host](#listening-from-a-host).
- `librarySetFeedback` and `libraryTrackFeedback` love and hate songs;
  `librarySetReleaseLove`, `librarySetArtistLove` and `libraryArtistLoved` love
  Releases and Artists, in the Library only.
- `librarySetRating` rates songs from 1 to 100, or clears the rating.

### Radio and discovery

- `libraryRadioPreview` ranks the Recordings a Radio would play, without a
  Player.
- `libraryDiscoverySettings` and `setLibraryDiscoverySettings` read and store
  the discovery settings.
- `libraryRecordingSummary` names a Recording.
- `playerStartRadio`, `playerStopRadio`, `playerSetRadioOptions`,
  `playerRadioLessLikeThis`, `playerRadioUndoFeedback`, `playerRadio` and
  `playerRadioPicks` run and report a Library Radio session.
- `startDailyMixes`, `libraryDailyMixes`, `libraryDailyMixEntries` and
  `librarySaveDailyMix` make, read and save Daily Mixes.
- `libraryNotForMe`, `libraryClearNotForMe` and `libraryResetRecommendations`
  hide Tracks from recommendations.

### Home

Each query reads the database alone and takes a `HomeLocalTime`.

- `libraryListeningWeek`, `libraryRecentReleases`, `libraryRediscover`,
  `libraryNeverPlayed`, `libraryDeepCuts`, `libraryUnplayedReleases`,
  `libraryReleaseAnniversaries`, `libraryTopArtists`, `libraryFormats`,
  `libraryOnThisDay` and `libraryHistoryAge` return the sections of the Home
  page.

### Playlists

- `libraryPlaylists`, `libraryPlaylistPage`, `libraryPlaylistCount` and
  `libraryPlaylist` list playlists.
- `libraryCreatePlaylist`, `libraryRenamePlaylist`, `libraryDeletePlaylist`,
  `libraryUpdatePlaylist`, `libraryPlaylistTags` and `libraryPlaylistFormats`
  manage a playlist.
- `libraryPlaylistEntries`, `libraryPlaylistInsert`, `libraryPlaylistRemove`
  and `libraryPlaylistMove` manage its entries.
- `libraryImportPlaylist` and `libraryExportPlaylist` read and write M3U files.
- `playerPlayPlaylist` plays a playlist and `playerSaveQueueAsPlaylist` saves
  the queue from the current entry.
- `libraryCreateSmartPlaylist`, `librarySetSmartPlaylistRules`,
  `librarySmartPlaylistRules`, `librarySmartPlaylistCount` and
  `librarySmartPlaylistPreview` manage smart playlists; the rule format is
  below. `libraryReshufflePlaylists` draws a new random seed.

The limits, errors and M3U rules are in
[the CLI reference](cli.md#playlists-and-ratings).

### Playback

- `playPlayer`, `playerNext`, `playerPrevious` and `playerDrained` drive the
  transport; `zoneCloseOutput` and `zoneRequestOutput` reopen a failed output.
- `playerQueueJump`, `playerQueueInsertNext`, `playerQueueRemove` and
  `playerQueueMove` edit the queue.
- `playerQueueTracks`, `playerQueueHistory`, `playerQueueHistoryTracks` and
  `playerClearQueueHistory` read the queue and its history.
- `playerSaveState` and `playerRestoreState` save and restore the queue and
  position; `playerSetLongTrackMemory` sets when a long Track remembers its
  position.
- `playerSetEqualizer`, `playerSetParametricEqualizer`, `playerSetCrossfeed`,
  `playerEqualizer` and `playerParametricEqualizer` set and read the sound
  processing. `ParametricEqualizer.response`, `parseEqualizerApo` and
  `writeEqualizerApo` need no Player.
- `playerSetReplayGainMode`, `playerSetReplayGainPreamp`,
  `playerSetReplayGainFallback`, `playerSetPeakProtection` and
  `playerReplayGainSettings` set and read ReplayGain.
- `playerSetStopAfterCurrent` and `playerStopAfterCurrent` arm and read a
  one-shot stop.
- `playerSignalPath` describes the path from source to output and whether it is
  bit-perfect.
- `enumerateOutputDevices` lists output devices.

## Listening from a host

A host that wants listening history and scrobbling calls:

- `Runtime.setCredentialStore` with a `CredentialStore` over the platform's
  secure storage. `get` receives the service and account
  (`listenbrainz_token_service`, `listenbrainz_token_account`) and returns an
  owned copy of the token, or null. It runs on a listen worker's thread and
  never prompts or blocks on user interaction: a locked keyring reads as no
  token.
- `Runtime.setClientIdentity` to name the host in submissions; see
  [Client identity](#client-identity).
- `Runtime.setListenBrainzServer` only to select a self-hosted or compatible
  server.
- `Runtime.librarySetScrobbling` (its last argument turns Now Playing on),
  `libraryScrobblerCredentialsChanged` after the token changes, and
  `libraryScrobblerStatus` for presentation.
- `Runtime.librarySetFeedback` and `libraryTrackFeedback` for love and hate;
  `librarySetReleaseLove` for album love, which is never sent.

The identity and the server are copied. The store's context is borrowed and
outlives the runtime. The setters may be called at any time and reach each
listen worker on its next pass; a host that sets them before binding a Player to
a Library avoids a first pass with the defaults. Listens are sampled inside
`processNextCommand`, so a host pumps it as it already does. The C ABI covers
the same steps with the credential callback, `orca_runtime_set_client_identity`,
`orca_runtime_set_provider_server`, `orca_library_set_scrobbling`,
`orca_library_scrobbler_credentials_changed`,
`orca_library_scrobbler_status`, `orca_library_set_feedback` and
`orca_library_set_release_love`; see [Credentials](c-abi.md#credentials).

## Smart playlist rules

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
  `startArtistInfoFetch`, `startReleaseInfoFetch`,
  `startEmbeddingModelDownload` and `librarySetScrobbling(library, true, ...)`
  return `error.ClientIdentityRequired`; turning scrobbling off and
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
  for the previous engine's acknowledgement and closes the output first.
- A Library a Player has been bound to, or that scrobbles, has a listen worker.
  Its ring, configuration and status belong to the Library and outlive the
  worker: a drain joins it, after it records everything in its ring, and the
  next listen, bind or scrobbling enable starts a new one.
- A watched Library has a watcher thread; the Library keeps its
  `WatchOptions`, and the watcher and its queued changes go on a drain.
- `destroyLibrary` drains every worker in the process, then restarts the
  scrobbling Library's listen worker, so its queue keeps its retry times, and a
  watcher for every other watched Library, whose roots are reconciled whole
  because the drain may have cancelled a reconcile or missed an event.
- Idle maintenance keeps its schedule on the Library's record, which survives a
  drain; a drain finalizes its unit and the next starts one interval later. A
  waiting host job holds a Library handle and a request, not a worker, and
  `destroyLibrary` finishes its Library's waiting jobs `cancelled`.
- The `CredentialStore` given to `setCredentialStore` is borrowed: its context
  must outlive the runtime, and `get` runs on a listen worker's thread.
  `setClientIdentity`, the server setters, `setAcoustIdClientKey` and
  `setEmbeddingModelPath` copy.
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
   position.
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
