# liborca Zig API

The public Zig API is everything declared at the top level of the `liborca`
module (`liborca/root.zig`). `liborca.internal` holds the subsystems behind it
for liborca's own tests and benchmarks; it is not part of the API and changes
without notice.

Non-Zig clients use the C ABI in `liborca/orca.h` instead; see
[frontends.md](frontends.md).

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

The module links SQLite, libFLAC, libopusfile, libvorbisfile and libsamplerate
through the host's pkg-config, plus PipeWire on Linux, and compiles in its ALAC,
AAC, MP3 and QOA decoders and Chromaprint. [`examples/embed`](../examples/embed)
is a complete project that does this; `zig build test` builds it, so these steps
stay correct.

## Surface

```zig
const orca = @import("liborca");

var runtime = orca.Runtime.init(allocator);
defer runtime.deinit();
const library = try runtime.openLibrary(io, "library.db");
var page = try runtime.libraryTrackQuery(library, "", .{ .limit = 50, .sort = .title });
defer page.deinit();
```

- `Runtime` owns every library, player, zone and job, and shuts them down in
  dependency order in `deinit`. Its methods are the operations: library
  queries and scans, playback and queue control, outputs, jobs, and the command
  and event lanes.
- Handles (`LibraryHandle`, `PlayerHandle`, `ZoneHandle`, `JobHandle`) are
  generational: a handle to a destroyed object never resolves again.
- Every type a `Runtime` method takes or returns is exported beside it: queries
  and pages (`TrackQuery`, `TrackPage`, `ArtistQuery`, ...), playback state
  (`PlayerStatus`, `RepeatMode`, `ReplayGainMode`, ...), outputs (`Device`,
  `ZoneStats`, ...), jobs (`ScanRequest`, `ReconcileRequest`, `JobSnapshot`,
  `ScanStats`, ...), tag
  write-back (`TagWritePlan`, `TagWriteConflict`, `TagWriteDigest`, ...),
  artwork
  (`ArtworkSubject`, `ArtworkResult`), watching (`WatchOptions`,
  `WatchStatus`, `WatchState`), idle maintenance (`MaintenanceOptions`,
  `MaintenanceStatus`, `JobOrigin`, ...) and the control lane (`Action`, `Event`,
  `Telemetry`, `Failure`, `HostWaker`).
- A host's event loop sleeps until liborca has something for it:
  `setWaker(HostWaker)`, called right after `init` and refused with
  `error.WorkersRunning` once a worker thread exists, installs the function
  liborca calls when the loop should pump;
  `pump` executes the submitted commands and publishes finished jobs; and
  `nextPumpTimeoutMs` returns how long the loop may sleep, 0 to pump now or
  null to wait for the waker alone. See
  [control-plane.md](control-plane.md#waking-the-host).
- `libraryWatch(library, WatchOptions)` watches the Library's roots and
  reconciles each directory that changes under one, from `pump`, one
  reconcile at a time and never beside a scan, reconcile, projection or tag
  write of the Library. It
  returns `error.AlreadyWatching` for a Library already watched and
  `error.WatchingUnsupported` off Linux. `libraryUnwatch` stops it, and
  `libraryWatchStatus` returns a `WatchStatus`: its `WatchState` (`off`,
  `watching`, `degraded` or `unsupported`), the roots and directories
  watched, the roots unavailable, the roots degraded by the watch limit,
  whether the watch limit was reached, and whether a reconcile waits or
  runs. `WatchOptions.degraded_rescan_ms` sets how often degraded roots are
  reconciled whole and unavailable roots tried again. A reconcile that
  recorded or marked missing a file publishes `Telemetry.library_changed`,
  and `jobReconcileRoot` names the root a reconcile job walks. See
  [storage.md](storage.md#watching-roots).
- `libraryMaintenance(library, MaintenanceOptions)` turns idle maintenance on
  or off. It is off until enabled. When on, `pump` verifies one Release's
  recording IDs (or at most 20 Tracks on no Release) every
  `interval_ms` while every Player is idle and no other job runs. A
  disagreement lands in Health as `recording_mismatch`.
  `error.InvalidMaintenanceOptions` refuses an interval of 0.
  `libraryMaintenanceStatus` returns a `MaintenanceStatus`: its
  `MaintenanceState` (`off`, `waiting`, `running` or `blocked`), the
  `MaintenanceBlock` (`client_identity_required`, `acoustid_required` or
  `provider_busy`), the time until the next unit, the units run and the
  last one as a `MaintenanceUnit`. `jobOrigin` returns a job's `JobOrigin`
  (`host`, `watcher` or `maintenance`). `startLibraryMatching`,
  `startReleaseCoverArtFetch` and `startAcoustIdSubmission` called while a
  unit runs cancel it and return a `queued` job, which `pump` starts once
  the unit has finished. See
  [control-plane.md](control-plane.md#idle-maintenance).
- A scan or reconcile of a root whose path now lies on another volume than
  the one recorded, as an unmounted drive's mount point does, walks and
  sweeps nothing and ends `failed`. See
  [storage.md](storage.md#volume-check-before-a-walk).
- `libraryFolderPage(library, root_id, relative_path, limit, offset)` returns
  a `FolderPage` of one folder's children as `FolderEntry` values: its
  subfolders first, each with `file_count`, `track_count` and
  `total_duration_ms` counted through every folder below it, then its files,
  each with its `file_id`, the `track_id` of the Track it is preferred for
  and its duration. `FolderEntryKind` is `folder` or `file`. The path is
  relative to the root, `""` being the root itself; a path with a `.`, `..`
  or empty component, a leading or trailing `/` or a NUL is
  `error.InvalidFolderPath`, an unknown root `error.UnknownRoot`, and a limit
  outside 1 to 512 `error.InvalidLimit`. Missing files are left out.
  `playerPlayFolder(player, library, io, root_id, relative_path, shuffle)`
  plays every Track below the folder, recursively in path order and at most
  `max_playlist_entries`, after setting shuffle; a folder with none is
  `error.FolderEmpty`. See [database.md](database.md#folder-browsing).
- `playerSetEqualizer` and `playerSetCrossfeed` (and their getters) set a
  Player's ten-band `Equalizer` (or an `EqualizerPreset`) and stereo crossfeed;
  `playerSignalPath` returns a `SignalPath`: the source, ReplayGain (applied
  gain, `ReplayGainSource` and the replaced track gain), DSP, volume
  and output stream, the device's period in frames (`device_quantum_frames`)
  and how it is attached (`output_kind`, a `DeviceKind`), and why the path is
  or is not bit-perfect. `equalizer_band_frequencies_hz` holds the ten bands'
  centre frequencies, in `Equalizer.gains_db` order.
- `enumerateOutputDevices` fills `Device` snapshots: id, name and `DeviceKind`
  (`usb`, `pci`, `bluetooth`, `hdmi`, `virtual` or `unknown`).
- `playerSetParametricEqualizer` sets a Player's `ParametricEqualizer`: up to
  `max_parametric_filters` (16) `ParametricFilter`s, each a
  `ParametricFilterKind` (peak, low or high shelf, low or high pass, notch)
  with a frequency, gain and Q, and a preamp; `validate` states the ranges.
  It and `playerSetEqualizer` are exclusive: turning one on turns the other
  off, so `playerEqualizer` returns null while the parametric equalizer runs,
  and `playerParametricEqualizer` returns null while the ten-band one does.
  An invalid setting is rejected and the previous one kept. `SignalPath`
  carries it as `parametric`. `ParametricEqualizer.response` gives the gain
  in dB at any frequencies for a sample rate, with no Player;
  `parseEqualizerApo` reads EqualizerAPO text (`Preamp:` and `Filter:`
  lines) into one and `writeEqualizerApo` writes one back.
- `libraryTrackDetails` returns `TrackDetails` for one Track: codec, sample
  rate, bit depth, channels, bitrate, duration, file size and path (or that
  the file is missing), loudness when measured, tags, and the MusicBrainz
  recording ID in effect with its `RecordingIdSource` (`tag`, `match` or
  `edit`), track and disc totals with `track_total_inferred` when the track
  total was counted rather than stated, the `Explicit` advisory, `added_at`
  and `modified_at`, and the first five `genres`. The caller frees it with
  `deinit`.
- Genres are browsable: `libraryGenrePage` takes a `GenreQuery` (a filter,
  `GenreSort.name` or `track_count`) and returns a `GenrePage` of
  `GenreSummary`s with Track, Release and Artist counts and total duration;
  `libraryGenreCount` and `libraryGenre` count and fetch them.
  `libraryTrackGenres` returns a Track's `GenreNames` in order with their
  `Provenance`; `libraryReleaseGenres` and `libraryArtistGenres` return
  `GenreCounts`, most Tracks first; `libraryGenreArtwork` returns the
  `ReleaseIds` of a genre's most played Releases that have a cover, as
  `ReleaseQuery.has_artwork` defines one. `TrackQuery`,
  `ReleaseQuery` and `ArtistQuery` take a `genre_id`, and `ArtistQuery` an
  `ArtistSort` (`name`, `track_count`, `recently_loved` or `recently_added`,
  the Artist whose newest Release, filed under them or appeared on, came
  latest). `librarySetTrackGenres` gives
  Tracks up to `max_track_genres` (16) user genres, which outrank their files'
  tags until cleared with no names, splitting a name that lists several
  (`Rock, Pop`); it writes no file itself and returns `error.TooManyGenres`,
  `error.InvalidGenre` for a blank name, or `error.TrackNotFound`. See
  [database.md](database.md#genres).
- `libraryEditTracks` returns `EditedTracks`: the Tracks the edited files
  back afterwards. An edit that moves a track to another album or position
  reprojects it under a new id.
- `planTagWrite` returns a `TagWritePlan`: each file's `TagWriteChange`s with
  the `Provenance` of Orca's value, its `TagWriteGenres` when the user's
  genres replace the file's, the `TagWriteConflict`s it leaves out
  because an unlocked value disagrees with the file's tag, and the files it
  skips. `tagWriteGenres` returns one file's `TagWriteGenres` from a held
  plan, for the C ABI, which reads them beside the plan's view.
  `isMusicBrainzId` is the check `libraryEditTracks` applies to a
  recording ID, for a client to validate input before saving.
- The queue can be edited in place: `playerQueueJump` plays an entry now,
  `playerQueueInsertNext` queues Tracks after the current one,
  `playerQueueRemove` removes an entry, and `playerQueueMove(player, from,
  to)` moves the entry at playback position `from` to `to`. The entry
  playing, and one the engine has already lined up after it, are refused
  with `error.QueueEntryInUse`, and so is a move that would land between
  them. Under shuffle a move changes only the shuffled order, so turning
  shuffle off restores list order.
- `playerQueueHistory(player, offset, output)` fills `output` with
  `QueueHistoryEntry` values, newest first: the Track, `ended_at_ms` and a
  `QueueHistoryReason` (`finished`, `skipped`, `replaced`).
  `playerQueueHistoryTracks(player, allocator, offset, limit)` returns them
  as a `TrackPage`, and `playerClearQueueHistory` empties it. The history
  holds `queue_history_capacity` (100) entries in memory only and never
  records a listen. See [audio-engine.md](audio-engine.md#queue-history).
- `playerSaveQueueAsPlaylist(player, library, name)` saves the current
  entry and those after it as a new playlist and returns its id; see
  [playlists.md](playlists.md#playlists).
- Health can be shown grouped by kind: `libraryHealthSummary` returns a
  `HealthSummary` of `HealthKindSummary`s, each kind's count, highest
  severity, `files` and `bytes`, and `libraryHealthIssuePageOfKind` pages
  one kind's issues. For `exact_duplicate` and `likely_duplicate`, `bytes`
  is what removing the redundant copies would free. See
  [analysis.md](analysis.md#by-kind).
- `libraryStats(library)` returns `LibraryStats`: the Artist, Release and
  Track counts the unfiltered listings show, the files with a location that
  is not missing and their bytes, the Tracks' summed `total_duration_ms`,
  and `last_scan_finished_at` and `last_analysis_at` in Unix seconds, null
  before the first completed scan or measurement. See
  [database.md](database.md#library-stats).
- `providerSources()` returns the `ProviderSource`s Orca takes data from, one
  per `ProviderSourceId` in its order: each one's `name`, `url`, what it
  `supplies`, its `licence`, and a `licence_url`, null when the licence has
  no single page. The list is fixed and needs no Library, so a frontend's
  credits read it rather than keeping their own. See
  [providers.md](providers.md).
- `TrackSummary` carries `release_id` and `artist_id`, so a host can link a
  Track to its Release and Artist without a second query, and the facts a
  song list shows: the playing file's `codec`, `sample_rate`, `bit_depth` and
  `lossy`, `added_at`, the recording's `play_count` and `last_played_at`,
  `explicit` (`Explicit`: `unknown`, `none`, `explicit`, `clean`),
  `track_total`, `disc_total` and `year`. `TrackSort` appends `play_count`,
  `last_played` and `year`; Tracks never played or undated sort last either
  way. `ReleaseSummary.explicit` is explicit when any of its Tracks is.
- `ReleaseSummary` carries the facts an album grid shows, read from the files
  its Tracks play: `codec` (`mixed_codec` when they differ, empty when none
  was probed), `max_sample_rate`, `max_bit_depth`, `lossless` (every Track
  plays a lossless file), `release_type`, and `pending_reviews`, the Tracks
  with a pending match outside an album group plus the album groups with a
  pending correction. `ReleaseQuery` filters by `high_resolution_only` (a
  file above 48 kHz or 16 bits, as `ReleaseSummary.isHighResolution`),
  `needs_review_only`, `lossless_only`, `year_min` and `year_max` (inclusive;
  undated Releases are left out) and `has_artwork`, a cover embedded in a
  Track's file or fetched. `ReleaseSort.most_played` orders by the listens of
  the Tracks' recordings.
- `release_type` is the lowercased primary type ("album", "ep", "single",
  "compilation", ...) the files' `RELEASETYPE` / `MusicBrainz Album Type`
  tags state, else the MusicBrainz release group's primary type, which a
  release-info fetch or genre fill writes only while the Release has none.
  `ReleaseQuery.release_kind` (`ReleaseKind`: `album`, `ep_or_single`,
  `other`) filters by it; a Release with no type counts as an `album`, as do
  compilations. `ReleaseQuery.appearing_artist_id` keeps the Releases with a
  Track credited to that Artist that are not filed under them as album
  artist. `ReleaseQuery.own_releases_only`, with `album_artist_id` set,
  narrows that filter to the Releases filed under the Artist as album
  artist, leaving out those they only appear on; without `album_artist_id`
  it does nothing. All combine with every other filter and sort.
- `libraryArtistTotals` returns an Artist's `ArtistTotals`, or null for an
  unknown Artist: `release_count`, the Releases `own_releases_only` lists,
  `track_count` as `ArtistSummary` counts it, `duration_ms` summed over
  the Tracks `TrackQuery.artist_id` lists (an unknown duration adds 0), and
  `appearance_count`, the Releases `appearing_artist_id` lists.
- `TrackQuery` filters by `year_min` and `year_max` (inclusive, read from the
  Release's date as `TrackSort.year` reads it; undated Tracks are left out),
  `lossless` (`true` for a lossless play file, `false` for a lossy one, a
  Track with no probed codec matching neither), `min_sample_rate` and
  `explicit_only` (`Explicit.explicit`). Every filter combines with AND, and
  `libraryTrackMatchCount` counts what the page lists. A text search in
  `libraryTrackQuery` keeps every filter of the query and orders the matches
  by relevance, so its `sort` and `direction` do not apply; a search has no
  count. Each word of its text must begin a word of the Track's title,
  artist, album or album artist, no character is FTS5 syntax, and text with
  no word matches nothing.
- `librarySearch` finds Artists, Releases, Tracks, Playlists and genres in
  one call and returns `SearchResults`: `SearchHit`s grouped in that
  `SearchKind` order, each kind most relevant first (lower `rank` is
  better: for a Track 0 when every word is whole in the title, 1 when every
  word begins a title word, 2 otherwise, ties by id; bm25 for other kinds)
  and capped by `SearchLimits` (default 5, 5, 8, 4, 3; above
  `max_search_hits_per_kind`, 50, is `error.InvalidSearchLimits`). Each
  word of the text must begin a word of the hit's title or subtitle,
  ignoring case and diacritics; quotes, operators and column filters are
  matched as text. Text longer than `max_search_text` (256 bytes) is
  `error.SearchTextTooLong`. `ReleaseQuery.text` keeps the Releases the
  same search finds, under every filter and sort, and
  `libraryReleaseCountMatching` counts them.
- Cover art is read either on the caller's thread (`libraryTrackArtwork`,
  `libraryReleaseArtwork`) or off it: `libraryRequestArtwork` queues a lookup
  on the Library's artwork loader, at most 64 outstanding, and
  `libraryTakeArtwork` collects finished ones. `libraryCancelArtwork` skips a
  request that has not started.
- Lyrics are read on a job: `startTrackLyrics` starts one for a Track, and
  with `LyricsOptions.fetch` also asks LRCLIB, which needs the client
  identity and can be pointed at another server with `setLrclibServer`.
  `jobLyricsOutcome` reports a `LyricsOutcome` once it finishes: `local`,
  `fetched`, `cached` (LRCLIB's earlier answer to the same query),
  `cached_miss`, `not_found` or `no_metadata` (no title or artist to ask
  with). `jobTakeLyrics` moves the `Lyrics` to the caller once, and
  `Lyrics.lineAt` gives the synced line at a playback position. See
  [metadata.md](metadata.md#lyrics) and [providers.md](providers.md#lrclib).
- Playback is recorded as local listening history. `processNextCommand`
  samples every Player bound to a Library at most every 100 ms; a play heard
  for half its length or four minutes (tracks of 30 s or more) is recorded on
  that Library's listen worker, credited to the Track the audible entry
  serial names. `libraryTrackPlayStats` and `TrackDetails` report the play
  count and last play of the Track's recording, through any of its files; a
  file that moves to another recording takes its plays along.
- `librarySetScrobbling` also sends a Library's listens to ListenBrainz, for
  at most one Library per runtime. The token comes from the `CredentialStore`
  given to `setCredentialStore`; `libraryScrobblerCredentialsChanged` has it
  validated once, and `libraryScrobblerStatus` returns a `ScrobblerStatus`.
  `setClientIdentity` names the host to every provider and in the listen
  history; see [Client identity](#client-identity).
  `setListenBrainzServer` points them at a compatible server: `https`, or
  `http` only to `127.0.0.1`, `[::1]` or `localhost`, and
  `error.InvalidServerUrl` otherwise. The three setters may be called at any
  time; each listen worker adopts the new values on its next pass.
  `listenbrainz_token_service` and `listenbrainz_token_account` name the
  secret a `CredentialStore` is asked for. See [providers.md](providers.md).
- `librarySetScrobbling(library, enabled, offline, now_playing)`: the last
  argument also announces the playing track to ListenBrainz, once per track
  heard for 10 s and never retried.
- `librarySetFeedback(library, track_ids, Feedback)` loves, hates or clears
  the song behind each Track and returns a `FeedbackChange` counting the
  Tracks changed and the ones skipped for having no Recording;
  `libraryTrackFeedback` reads one. `Feedback` is `none`, `loved` or `hated`.
  It belongs to the Recording, so it shows on every Track and file of the song
  as `TrackSummary.feedback` and `TrackDetails.feedback`; `TrackSummary.recording_id`
  names the song, so a host can repaint every row of it without a query. It is sent to
  ListenBrainz while the Library scrobbles when the song has a MusicBrainz
  recording id (`TrackDetails.feedback_syncable`). `ScrobblerStatus` reports
  the changes still waiting as `feedback_pending`, and the end of a
  ListenBrainz block the Library records as `blocked_until`.
- `librarySetReleaseLove(library, release_ids, loved)` loves or clears each
  Release and returns a `ReleaseLoveChange` counting the Releases changed and
  the ids that name no Release. It is kept in the Library only: it changes no
  song's feedback and is never sent to ListenBrainz. It shows as
  `ReleaseSummary.loved`; `ReleaseQuery.loved_only` lists only loved
  Releases and `ReleaseSort.loved` orders the most recently loved first.
  `TrackQuery.loved_only` lists only Tracks whose song is loved, and
  `TrackSort.loved` orders them most recently loved first, the rest last.
- `librarySetArtistLove(library, artist_ids, loved)` loves or clears each
  Artist and returns an `ArtistLoveChange` counting the Artists changed and
  the ids that name no Artist; `libraryArtistLoved` reads one. Like album
  love it is kept in the Library only and never sent. It shows as
  `ArtistSummary.loved`; `ArtistQuery.loved_only` lists only loved Artists
  and `ArtistSort.recently_loved` orders the most recently loved first.
- `startArtistInfoFetch(library, artist_id, ArtistInfoOptions)` starts an
  `artist_info` Job that gathers an Artist's photo, biography, years active
  and links from a local image, MusicBrainz, Wikidata, Wikimedia Commons and
  Wikipedia, its listeners and related artists from ListenBrainz, and fills
  genres from MusicBrainz. `ArtistInfoOptions` holds the biography's
  `language` (default `en`, falling back to English), `force`, `offline`
  and `include_releases`, which also fetches each of the Artist's Releases'
  release info. It returns
  `error.ClientIdentityRequired`, `error.UnknownArtist` or
  `error.InvalidLanguage`. `jobArtistInfoOutcome` returns its
  `ArtistInfoOutcome` (`error.NotAnArtistInfoJob` for another kind).
  `libraryArtistInfo` returns the stored `ArtistInfo`, whose
  `ArtistInfoRecord` holds the years active, type, IDs, biography with its
  `ArtistBiographySource`, URL, licence and language, the
  `requested_language` the fetch asked for, the photo's
  `ArtistPhotoSource`, page, licence and credit, `fetched_at` and the
  outcome; null when nothing was stored. `libraryArtistPhoto` returns the
  photo as an `EmbeddedImage`, and `libraryArtistLinks` the `ArtistLinks`,
  each an `ArtistLink` with its `ArtistLinkKind`, by kind and URL.
  `ArtistInfoRecord.listeners` is ListenBrainz's listener count, and
  `libraryRelatedArtists` returns the `RelatedArtists`, at most
  `related_artists_max` `RelatedArtist`s with name, MusicBrainz ID, score
  and the matching library Artist's id, if any, and `has_photo`: the
  library Artist's photo for a matched one, else a kept related artist
  photo. An Artist fetch also keeps photos for related artists outside the
  Library, by MusicBrainz artist ID, for at most
  `artist_info.related_photos_per_fetch` (8) of them per fetch: those with
  no kept photo or marker, or one older than `refresh_after_s` (30 days),
  or with `force` any. `libraryRelatedArtistPhoto(library, mbid)` returns
  that photo as an `EmbeddedImage`, or null when none is kept; the ID is
  matched without case. `libraryRelatedArtistPhotoInfo(library, mbid)`
  returns its attribution as a `RelatedArtistPhotoInfo` whose
  `RelatedArtistPhotoRecord` holds `source` (always `.commons`), `url` (the
  Commons page), `licence`, `licence_url`, `credit` and `fetched_at`, or
  null when no photo is kept; free it with `deinit`.
- `startReleaseInfoFetch(library, release_id, ReleaseInfoOptions)` starts a
  `release_info` Job that keeps a Release's Wikipedia description, found
  through its MusicBrainz release group and Wikidata, and fills genres from
  the release group. `ReleaseInfoOptions` holds `language`, `force` and
  `offline`; it returns `error.ClientIdentityRequired`,
  `error.UnknownRelease` or `error.InvalidLanguage`.
  `jobReleaseInfoOutcome` returns its `ReleaseInfoOutcome`
  (`error.NotAReleaseInfoJob` for another kind), and `libraryReleaseInfo`
  the stored `ReleaseInfo`, whose `ReleaseInfoRecord` holds the
  description with its `ReleaseDescriptionSource`, URL, licence and
  language, the MusicBrainz release and release group IDs, `fetched_at` and
  the outcome; null when nothing was stored.
- `setGenreFill(library, GenreFill)` turns automatic genre fill from
  MusicBrainz on or off for the Library (on by default), and
  `libraryGenreFill` reads it. `startGenreFill(library, GenreFillOptions)`
  starts a `release_info` Job that fills the genres of up to `limit`
  Releases with a Track without genres, whatever the setting
  (`error.InvalidLimit` outside 1 to 512). Such genres are shown with
  `musicbrainz_genre_licence`. `setListenBrainzLabsServer` selects another
  ListenBrainz Labs server. See [providers.md](providers.md#release-info).
  `setWikidataServer`, `setWikimediaCommonsServer` and `setWikipediaServer`
  select other servers under the same rules as `setListenBrainzServer`, from
  the next job; a null Wikipedia server asks each language's own wiki. See
  [providers.md](providers.md#artist-info).
- `librarySetRating(library, track_ids, ?u8)` rates the song behind each
  Track from 1 to 100, or clears it, and returns a `RatingChange`; it shows as
  `TrackSummary.rating` and `TrackDetails.rating`. Playlists are
  `libraryPlaylists`, `libraryCreatePlaylist`, `libraryRenamePlaylist`,
  `libraryDeletePlaylist`, `libraryPlaylistEntries`, `libraryPlaylistInsert`,
  `libraryPlaylistRemove` and `libraryPlaylistMove`, with
  `playerPlayPlaylist` to play one and `libraryImportPlaylist` and
  `libraryExportPlaylist` for M3U files. See [playlists.md](playlists.md).
  `libraryPlaylistPage(library, PlaylistQuery)` returns at most 512
  `PlaylistSummary`s, filtered by name, `PlaylistKind`, pin and
  `PlaylistCreator` and ordered by `PlaylistSort`; `libraryPlaylistCount`
  counts the same query and `libraryPlaylist` returns one summary, with its
  description, pin, love, tags, whether its entries name several Artists and
  its three most common genres. `libraryUpdatePlaylist(library, id,
  PlaylistUpdate)` sets the description, pin, love or tags (at most
  `max_playlist_tags`); `libraryPlaylistTags` returns the tags alone.
  `libraryCreateSmartPlaylist(library, name, rules_json)` creates a smart
  playlist, `librarySetSmartPlaylistRules` replaces its rules and
  `librarySmartPlaylistRules` returns them as stored, or null for a manual
  playlist. `librarySmartPlaylistCount(library, rules_json)` counts the Tracks
  rules match now without storing anything. Rules are at most
  `max_smart_playlist_rules_bytes`, in the format under
  [Smart playlist rules](#smart-playlist-rules).
- `startLibraryMatching(library, MatchRequest)` starts a `metadata_lookup`
  Job that searches MusicBrainz, and AcoustID by fingerprint, for the Tracks
  without a recording ID and stores proposals; its snapshot's total is the
  number of Tracks to search, and `jobMatchStats` reports its counters as
  `MatchStats`, `matched` included while it runs, whether AcoustID took
  part as `AcoustIdUse`, and, as `BusyService`, the service another Orca
  process held when the job failed for it. `MatchRequest.fingerprints`
  (default true) includes AcoustID when an application key is set. `MatchRequest.track_id` searches
  that Track alone, under the same rule: one already identified, or already
  answered for by every service in scope, is not searched, and the job
  succeeds with a total of 0. At most one runs per runtime
  (`error.MatchingAlreadyRunning`), and none while an AcoustID submission
  runs (`error.AcoustIdBusy`).
  `libraryMatchReviewPage(library, limit, offset)` returns a
  `MatchReviewPage` of at most 512 `MatchReviewItem`s: the Tracks with a
  pending proposal, by artist, album and position, each with its own title,
  artist, album and length, its number of proposals and its best one.
  `libraryMatchReviewCount` counts them, `libraryUnidentifiedCount` counts the
  Tracks a matching job would search, and
  `libraryConfidentMatchCount(library, minimum)` is the number
  `libraryAcceptConfidentMatches` would accept now.
  `libraryMatchProposals(library, track_id, limit)` returns a
  `MatchProposalPage` of the Track's pending `MatchProposal`s, each with its
  `provider` (`musicbrainz`, `acoustid` or `musicbrainz+acoustid`) and
  `acoustid_score`; `libraryAcceptMatch` accepts one and returns a
  `MatchAcceptance`, `libraryDismissMatch` dismisses one, and
  `libraryAcceptConfidentMatches(library, minimum)` accepts each file's best
  pending proposal at least that confident, chosen as
  [metadata.md](metadata.md#musicbrainz-recording-ids) describes, and
  returns a `ConfidentMatchAcceptance`. `libraryApplyMatchedRelease(library,
  release_id)` stores a Release's album values once its Tracks agree on one
  MusicBrainz release and returns how many it stored. Accepts reproject, so
  Track and Release ids can change; see
  [metadata.md](metadata.md#accepting-a-match).
  `setMusicBrainzServer` and `setAcoustIdServer` select other servers under
  the same rules as `setListenBrainzServer`, from the next job.
  `setAcoustIdClientKey(key)` copies the AcoustID application key, or clears
  it when null, and a `CredentialStore` value under
  `acoustid_credential_service` / `acoustid_client_key_account` overrides
  it. See [providers.md](providers.md#matching) and
  [metadata.md](metadata.md#musicbrainz-recording-ids).
- `libraryTrackFingerprint(library, io, track_id)` returns the
  `TrackFingerprint` of the file a Track plays: Chromaprint's compressed
  fingerprint, the file's length and whether it came from the Library's
  cache. It decodes up to two minutes of audio on the caller's thread when
  the cache has none, and returns null when the file has no present
  location.
- `startAcoustIdSubmission(library)` starts an `acoustid_submission` Job that
  sends AcoustID the fingerprints of files whose recording ID came from an
  accepted match or an edit, as the user whose key the `CredentialStore`
  holds under `acoustid_credential_service` / `acoustid_user_key_account`.
  `jobSubmissionStats` returns its `SubmissionStats`: the files examined
  while it runs, and every counter and the `SubmissionOutcome` once it has
  finished; `SubmissionOutcome.busy` means another Orca process held
  AcoustID. `libraryAcoustIdSubmittableCount` and
  `libraryAcoustIdSubmittablePage(library, cursor, limit)` list what it would
  send, as `AcoustIdSubmittable`s by file id after `cursor`;
  `AcoustIdSubmittable.sendsRecordingId(file_duration_ms)` says whether the
  recording ID or the file's metadata is sent. It cannot run beside matching
  or another submission (`error.AcoustIdBusy`). See
  [providers.md](providers.md#acoustid-submission).
- Pages and returned values are owned by the caller and released with their
  `deinit`.

Threading and ordering rules are the runtime's, documented in
[ownership.md](ownership.md) and [control-plane.md](control-plane.md).

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

- `v` is required and must be 1. `match` is `all` (default) or `any`.
  `rules` holds rules and nested groups (`match` and `rules`), at most four
  levels deep (`error.RuleNestingTooDeep`) and 32 rules in all
  (`error.TooManyRules`). An unknown key, or a document over 16 KiB, is
  `error.InvalidSmartPlaylistRules`.
- `sort.field` is a `TrackSort` name or `added_at`, `last_played_at` or
  `duration_ms`; `sort.descending` defaults to false. `limit` is 1 to 10,000
  and defaults to 10,000.
- A rule is `field`, `op` and `value`. An unknown field is
  `error.UnknownRuleField`, an unknown operator `error.UnknownRuleOperator`,
  an operator the field's type does not take `error.RuleOperatorMismatch`,
  and a value of the wrong shape `error.InvalidRuleValue`.

| Type | Fields | Operators |
| --- | --- | --- |
| text | `title`, `artist`, `album`, `album_artist`, `genre`, `codec`, `release_type` | `is`, `is_not`, `contains`, `starts_with`, `is_set`, `is_not_set` |
| integer | `year`, `play_count`, `rating`, `duration_ms`, `sample_rate`, `bit_depth` | `is`, `is_not`, `gt`, `gte`, `lt`, `lte`, `between`, `is_set`, `is_not_set` |
| date | `added_at`, `last_played_at` | `gt`, `gte`, `lt`, `lte`, `between`, `in_last_days`, `not_in_last_days`, `is_set`, `is_not_set` |
| boolean | `loved`, `lossless`, `explicit`, `has_artwork` | `is`, `is_not` |

Text values are 1 to 256 bytes and compare ignoring ASCII case; `genre`
compares the genre's folded key, the one `genres.key` stores. Dates are Unix seconds;
`in_last_days` and `not_in_last_days` take 1 to 100,000 days counted back from
now, and `not_in_last_days` includes Tracks never played. `between` takes
`[low, high]` and includes both ends. `is_set` and `is_not_set` take no value.
Every value is bound as an SQL parameter, never spliced into the query.

## Client identity

liborca has no identity of its own toward MusicBrainz, AcoustID and
ListenBrainz: the host names itself before any provider work.

```zig
try runtime.setClientIdentity(.{
    .name = "MyPlayer",
    .version = "1.2.0",
    .contact = "https://myplayer.example",
});
```

- Until it is set, `startLibraryMatching`, `startAcoustIdSubmission`,
  `startArtistInfoFetch` and `librarySetScrobbling(library, true, ...)` return
  `error.ClientIdentityRequired`. Turning scrobbling off, and
  `libraryTrackFingerprint`, need none.
- The three strings are copied, so the caller's buffers may be freed after the
  call. A later call replaces the identity; running workers adopt it on their
  next pass.
- Each field must be non-empty, free of control characters and parentheses,
  and the three together at most 256 bytes; otherwise the call returns
  `error.InvalidNetworkConfiguration`.
- The `User-Agent` is `Name/version ( contact ) liborca/<version>`. The suffix
  is left out only for the name `Orca` at liborca's own version, which is how
  `orca-cli` and `orca-gtk` identify themselves.

## Stability

liborca is pre-1.0. The C ABI in `orca.h` is versioned by `ORCA_ABI_VERSION`
and the shared library's SONAME, `liborca.so.<ORCA_ABI_VERSION>`. Within one
ABI version:

- functions are only added, never removed or changed;
- a reserved field gains a meaning only as an addition for which zero keeps
  the old behaviour;
- enum values are only added.

The Zig API may break in any minor release; `CHANGELOG.md` records each break.
