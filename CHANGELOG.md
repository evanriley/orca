# Changelog

## Unreleased

### Added

- **Radio and Daily Mixes limit how often one Artist repeats.** The new Library
  setting `discovery.artist_variety` (`ArtistVariety`, in
  `DiscoverySettings.artist_variety`) is `relaxed`, `balanced` (the default) or
  `strict`. At `balanced` a Radio session picks an Artist at most twice in any
  10 consecutive picks and never twice in a row, and a Daily Mix holds 1 entry
  per Artist, or 2 when no Track by an Artist not yet in the mix qualifies,
  with no two consecutive entries by the same Artist; at `strict` the limits
  are 1 in 10 and 1 per mix; `relaxed` keeps the previous picks. Radio relaxes
  the limit with the seed-Artist cap when nothing else fits, and a mix goes
  above its per-Artist limit only while it is under 60 minutes. `orca-gtk` has
  an Artist variety row in Settings › Listening that remakes the day's Daily
  Mixes on a change. `RadioOptions.artist_variety` and
  `DailyMixesRequest.artist_variety` replace the setting for one session or one
  generation, as `--artist-variety` does for `orca-cli radio` and `orca-cli
  mixes`. In the C ABI the field `artist_variety` of `orca_discovery_settings`
  (the first of its former reserved bytes; the struct keeps its size and
  `ORCA_ABI_VERSION`) reads the setting as an `orca_artist_variety` (1, 2 or
  3), and a write of 0 keeps the stored value.
- **`liborca` measures audio embeddings with either of two models.** The
  model file a host names is recognised by its size and SHA-256 as
  `clap_htsat_unfused` (512 values) or the new `discogs_maest`
  (`maest_audio_int8.onnx`, 80.4 MB, 16 kHz input, 768 values), and
  `Runtime.embeddingModel` returns which, or null unless
  `embeddingModelState` is `ready`. Analysis, `libraryUnanalyzedCount` and
  `libraryAnalysisCoverage` use that model: with `discogs_maest` named, every
  file without its embedding is measured once and the 780-byte result is
  stored in `analysis_results` under its own parameter hash, beside the
  file's `clap_htsat_unfused` result, which is kept. Naming the first model
  again measures nothing that is already stored. Radio, Daily Mixes and
  `librarySimilarTracks` compare the stored vectors of that model only, and
  those of `clap_htsat_unfused` when `embeddingModel` is null; vectors of two
  models are never compared, and a file with no vector of the model in use
  counts as one with no embedding. `orca-cli similar`, `radio`, `home` and
  `mixes` take `--embedding-model PATH` or `ORCA_EMBEDDING_MODEL` to name the
  model. Daily Mixes already stored for the mix day are kept when the model
  changes.
  Library schema version 6 keys `file_audio_embeddings` by model and file:
  opening a version 5 Library keeps every stored vector as
  `clap_htsat_unfused` and adds the `discogs_maest` vectors of the results
  already stored for unchanged files, and triggers keep both from then on.
  `Runtime.startEmbeddingModelDownload(.discogs_maest, destination)` fetches
  the new model in Zig, `orca-cli download-embedding-model PATH --model
  discogs_maest` fetches it, and a C host passes
  `ORCA_EMBEDDING_MODEL_DISCOGS_MAEST` (2) to
  `orca_runtime_start_embedding_model_download` and reads the model in use
  with `orca_runtime_embedding_model`, 0 unless the state is ready;
  `orca-gtk` downloads the model chosen in Settings. The new build option
  `-Dmaest-embedding-model=PATH` runs the tests that need the file.
- **`orca-gtk` chooses between the two audio-embedding models.** Settings ›
  Listening › Sound Similarity has a Model row with "Standard · 32.6 MB"
  (`clap_htsat_unfused`) and "Large · 80.4 MB · non-commercial licence"
  (`discogs_maest`). The choice is kept as `embedding_model` in the
  `[listening]` group of `settings.ini`, decides which file is looked up and
  named to liborca, and takes effect without a restart: the status row and
  Download then name that model's file and size, and the analysis banner asks
  for its embeddings. A file that is the other model is reported as that
  model, with Download for the chosen one. The row cannot be changed while a
  download runs, in a build without ONNX Runtime, or when
  `ORCA_EMBEDDING_MODEL` is set, when it shows the model that file is. Reset
  all settings returns the choice to Standard. `scripts/headless-gui.sh`
  keeps the directory in `ORCA_HEADLESS_DATA` as the session's
  `XDG_DATA_HOME`.
- **liborca downloads the audio-embedding model when a host asks.**
  `Runtime.startEmbeddingModelDownload(model, destination)` starts a
  `model_download` Job (`ORCA_JOB_KIND_MODEL_DOWNLOAD`, 14) that belongs to no
  Library, reports bytes, can be cancelled and cannot be paused. It writes
  `destination.part`, renames it onto `destination` only when the size and
  SHA-256 are the compiled-in ones, and then names the file to the runtime, so
  `embeddingModelState` reads `ready`. A redirect is followed only to `https`
  on `githubusercontent.com`; nothing is retried or resumed; a failed Job's
  snapshot `detail` holds the reason. `orca-cli download-embedding-model PATH`
  runs it, and a C host calls
  `orca_runtime_start_embedding_model_download(runtime, model, path, &job)`.
  `model` is an `EmbeddingModel` (`orca_embedding_model`):
  `clap_htsat_unfused` (`ORCA_EMBEDDING_MODEL_CLAP_HTSAT_UNFUSED`, 1) or
  `discogs_maest` (`ORCA_EMBEDDING_MODEL_DISCOGS_MAEST`, 2); any other value is
  `ORCA_STATUS_INVALID_ARGUMENT`.
- **`orca-gtk` downloads the audio-embedding model from Settings › Listening.**
  Download in the Sound Similarity card fetches the chosen model (32.6 or
  80.4 MB, from `github.com`) to the user data directory, shows the megabytes
  received and can be cancelled; a failure shows the Job's reason. The row
  names the size and the host before the button is pressed. Download is not
  offered when `ORCA_EMBEDDING_MODEL` is set.
- **Radio and Daily Mixes rank by how alike tracks sound.** A seed whose
  tracks have a stored audio embedding scores each candidate's Audio component
  by the cosine similarity of its vector to the seed's mean: 1 from the 10th
  nearest Recording up, 0.5 at the 300th, 0.3 without a vector. The 300
  nearest Recordings replace the tempo bucket among the candidates. A pick
  with a score of at least 0.5 and a similarity of at least 0.9 can carry
  `similar_sound` with the new flag `liborca.radio_sound_overall` (8) alone,
  which `orca-cli radio` prints as `Similar sound`; `orca.h` names
  it `ORCA_SOUND_OVERALL`. A seed without an embedding is ranked by tempo,
  key and energy as before.
- **`liborca` can run a pinned audio-embedding model through ONNX Runtime.**
  The new build option `-Dembeddings` (default `true`) compiles the binding
  and links `libonnxruntime`, 1.20 or newer, found through pkg-config;
  `-Dembeddings=false` builds without it. The model is one file checked by
  size and SHA-256 before it is loaded, and `scripts/embedding/` holds the
  scripts that export it and its test references.
- **One file's analysis can measure an audio embedding.** Given the model,
  the analysis decode also keeps up to three 10 s windows, embeds each with
  the CLAP audio model and stores their unit-length mean as 512 signed bytes
  and a scale, as `analysis_results` kind 7 (`orca.audio-embedding`). A file
  under 1 s or silent is stored as having none. `Runtime.libraryAnalyzeFile`
  and `libraryReanalyzeFile` measure it when the runtime's model is ready, and
  `orca-cli analyze` takes `--embedding-model PATH` or
  `ORCA_EMBEDDING_MODEL`. Without a model an analysis stores what it did
  before. `analysis-bench` takes a model to time the stages.
- **The library-wide analysis pass can measure audio embeddings.**
  `LibraryAnalysis.embedding_model` is null by default; with a model the pass
  selects files on four measurements, gives each measuring thread its own
  front end and stores the embedding beside the other results. A file that
  lacks only the embedding is decoded once and only that row is written.
  `AnalysisSelectors` carries the embedding as an optional fourth selector,
  `analysisSelectors` takes a `SelectionForm`, and
  `AnalysisCoverageCounts.missing` has a fourth entry. Without a model the
  selection, the coverage counts and the measurement set identifier are
  unchanged.
- **A host names the audio-embedding model and reads whether it is usable.**
  `Runtime.setEmbeddingModelPath` copies the model file's path and checks the
  file by size and SHA-256; `Runtime.embeddingModelState` returns
  `built_without`, `missing`, `wrong_file`, `unusable` or `ready`
  (`EmbeddingModelState`). While it is `ready`, `startLibraryAnalysis`,
  `libraryAnalyzeFile` and `libraryReanalyzeFile` measure the embedding,
  `libraryUnanalyzedCount` and `libraryAnalysisCoverage` count it, and
  `MissingMeasurements.embedding` flags it. A job that cannot load the model
  records why in the state and measures without it. `orca-cli analyze-library`
  and `stats` take `--embedding-model PATH` or `ORCA_EMBEDDING_MODEL`, and
  exit 1 with the reason when the model cannot be used. C hosts call
  `orca_runtime_set_embedding_model_path` and `orca_runtime_embedding_model_state`
  (`orca_embedding_model_state`), and `orca_library_analysis_coverage` reports
  the embedding as `ORCA_MEASUREMENT_EMBEDDING`.

- **The Library keeps each file's audio embedding in a table.** Library schema
  version 5 adds `file_audio_embeddings`, kept by triggers on
  `analysis_results` as `file_audio_features` is, and fills it from the kind 7
  results already stored for unchanged files. `AudioEmbeddingRepository`
  reads a file's vector or a page of them, only for the bytes the file holds
  now. A Library at version 5 cannot be opened by Orca 0.4.0 or earlier.
- **Orca finds the tracks that sound most like one.**
  `Runtime.librarySimilarTracks` returns up to 1,000 Tracks whose stored audio
  embeddings are nearest a Track's by cosine similarity, one per Recording and
  never the Track's own, nearest first. `orca-cli similar DATABASE TRACK_ID
  [--limit N]` prints them, 15 by default, and needs no model file. A Track
  whose file has no current embedding is `error.NoAudioEmbedding`. The search
  reads the vectors a page at a time and builds no index;
  `AudioEmbeddingRow` carries the file's Recording id. C hosts call
  `orca_library_similar_tracks`, which fills an array of
  `orca_similar_track_view` and answers `ORCA_STATUS_NOT_FOUND`,
  `ORCA_STATUS_INVALID_STATE` for a Track without an embedding or
  `ORCA_STATUS_INVALID_ARGUMENT` for a capacity above 1,000.

- **`orca-gtk` gives liborca the audio-embedding model and shows its state.**
  At startup it names the file `ORCA_EMBEDDING_MODEL` holds, else the chosen
  model's file from `$XDG_DATA_HOME/orca/models`, else from
  `share/orca/models` under the install prefix. Settings › Listening › Sound
  Similarity says whether the model is installed, where a missing file goes,
  and offers Check again, which looks the file up again without a restart; the
  command palette lists it as Sound similarity. The analysis banner asks for
  an analysis when the model is ready and files lack the embedding.
  `scripts/headless-gui.sh` passes `ORCA_HEADLESS_EMBEDDING_MODEL` to the app
  as `ORCA_EMBEDDING_MODEL`.

- **The Nix package installs the audio-embedding model.** It fetches
  `clap_audio_int8.onnx` by hash from the `model-clap-int8-1` release, links
  it at `share/orca/models` and does not set `ORCA_EMBEDDING_MODEL`:
  `orca-gtk` finds the file under its install prefix, and `orca-cli` takes
  `--embedding-model PATH` or the variable. The README gives the download
  command for other builds, [releasing.md](docs/releasing.md) the steps for a
  different model, and the dependency table in
  [architecture.md](docs/architecture.md#dependencies-and-licences) lists ONNX
  Runtime and the model's licence.
- **`network.Gateway` can stream a response body into a sink.**
  `Gateway.fetchInto` follows redirects as `fetch` does and writes the final
  `2xx` body to a `network.client.Sink` in pieces of at most 64 KiB instead of
  buffering it. Such a request asks for the identity encoding, is made once,
  is bounded by `max_response_bytes`, times out after `request_timeout_ms`
  without progress or at the Gateway's deadline, and reports a failed sink as
  `error.SinkFailed`. `network.testing.ScriptedTransport` delivers scripted
  bodies to a sink in chunks.

- **Orca copies a Library before it upgrades it.** When a Library made by an
  earlier release is opened, the engine first writes a complete copy of the
  database as `<database>.pre-v<N>.sqlite` beside it, where `N` is the schema
  version the Library had, and only then upgrades. One copy is kept; a later
  upgrade replaces it. The copy needs free space equal to the database. If it
  cannot be written the Library is not upgraded and the open fails with
  `error.PreUpgradeCopyFailed`, which `orca-cli` and `orca-gtk` report with the
  reason. A Library last opened by a newer Orca is now reported as such by both
  instead of as a generic failure. `liborca.libraryUpgradeCopyPath` returns the
  copy's path. The scanner and the folder watcher ignore the copy.

- **Every vendored decoder records its exact upstream commit.** New
  `ORCA-CHANGES` files beside the vendored minimp3 (lieff/minimp3 `ea99364f`,
  CC0) and QOA (phoboslab/qoa `bc058971`, MIT) sources record the upstream
  repository, commit, licence, compiled files and header SHA-256, both vendored
  unmodified, so a future advisory can be matched to Orca's copy.

- **The fuzz suite and CI now cover more untrusted-byte paths.** New fuzz
  targets feed bytes through the ID3v1, image-header, fingerprint, job-history
  retry and provider-response parsers; an AAC decoder sanitizer harness joins
  the ALAC one; and a CI job runs both decoders under AddressSanitizer and
  UndefinedBehaviorSanitizer and the test suite once under ReleaseSafe.

- **Upgrades are verified against real databases from each schema version, not
  against re-run step text.** `fixtures/library/upgrade/` holds a binary
  library for schema versions 1 to 7, with rows in every table, and the test
  suite opens each through `LibraryDatabase.open` and compares it with a
  database created at the current version from the same rows, table by table
  and row by row, including the genre totals, loudness, feature, embedding and
  sort columns that triggers maintain. Opening the current fixture leaves the
  file byte-identical. `zig build regenerate-upgrade-fixtures` rebuilds the
  fixtures deterministically from `tests/upgrade_fixtures`.

### Fixed

- **Pull-request CI no longer skips building after a docs-only follow-up push.**
  The `changes` job diffs a pull request against its base (`HEAD^1` of the merge
  commit) instead of the previous head, and treats the first push of a branch as
  a code change. The benchmark programs compile again
  (`library.health_issues.summary` takes an allocator), and the new `zig build
  bench-build` step, which `zig build test` depends on, compiles them without
  running them.

- **Downloading an embedding model no longer writes through a symlink at
  `<destination>.part`.** The download deletes whatever is at
  `<destination>.part` and creates the file exclusively, so a link placed there
  by another user of a shared model directory is replaced instead of followed;
  when the path cannot be replaced the download fails with `write_failed`.
  `liborca/core/model_download.zig` gains a test for each failure: short, long
  and wrong-digest bodies, a non-200 status, a transport error, a timeout and a
  cancellation mid-body, a refused redirect and an unwritable destination.

- **Writing a date to an ID3v2.3 file no longer deletes its TIME and TRDA
  frames.** A v2.3 date write now replaces only TYER and TDAT and keeps TIME
  and TRDA byte for byte. A `YYYY-MM` value still stores the year only, since
  TDAT is `DDMM`.

- **Out-of-range host input no longer aborts the host process.** A large
  `orca_player_seek_ms` value, a large `orca_player_seek` frame, a file that
  declares an enormous length, and out-of-range host clock values (`now_s`,
  `utc_offset_s`) are handled without an integer overflow. The clock values are
  rejected with `ORCA_STATUS_INVALID_ARGUMENT`; `orca.h` documents the bounds
  (`now_s` within 2^40 seconds of the epoch, `utc_offset_s` within 18 hours).
  `orca_library_start_reconcile` rejects more than 4096 directories.
  `orca_library_open` reports a missing file or directory as
  `ORCA_STATUS_NOT_FOUND`, a database written by a newer Orca as
  `ORCA_STATUS_UNSUPPORTED`, and a directory or a file that is not an SQLite
  database as `ORCA_STATUS_INVALID_ARGUMENT`.

- **A listen is no longer lost when the database is busy or full for a
  moment.** The listen worker keeps a listen whose write failed and tries it
  again at most every 5 s, in order, instead of dropping it. A listen that
  fails 12 tries in a row, or that is still failing when the Library closes, is
  dropped and counted in `dropped`, as are listens pushed while the 64-entry
  queue is full.

- **A song keeps its rating, love, Not for me and playlist entries when its
  file joins another song's position.** When two Recordings became one (a retag
  or move landing two files on one Release position), only listens and play
  counts followed; the rest stayed on a Recording nothing showed. They now move
  to the surviving Recording in the same transaction: the higher rating wins,
  loved or hated on the surviving song wins over the other's, playlist and
  saved-queue entries are re-pointed, and listens of files since removed follow
  too. Rows orphaned by earlier merges are left as they are, because the
  surviving Recording can no longer be identified.

- **`orca-cli` no longer prints control bytes from tags, paths and provider
  text.** A title holding an escape sequence could rewrite the terminal title.
  Every CLI print of text from files, tags, paths, provider responses and
  database rows now passes one filter that prints C0 controls, DEL, C1 controls
  and invalid UTF-8 as `\xNN`, keeps valid UTF-8, and keeps tab and newline
  only in lyrics, biographies and descriptions. Files the CLI writes (`changes
  --export`, `playlist-export`) keep their raw form.

- **Opening Orca with an audio-embedding model installed no longer reads and
  hashes the 32 to 80 MB file on the calling thread.** `setEmbeddingModelPath`
  and `orca_runtime_set_embedding_model_path` recognise the file by its size.
  Its SHA-256 is checked when an analysis opens it, on the bytes given to ONNX
  Runtime, so a file of a model's size with another SHA-256 reads `ready` until
  an analysis refuses it and `wrong_file` afterwards. A finished model download
  records the model its worker verified without reading the file again.

- **An Orca left running no longer writes to a Library that a newer Orca has
  upgraded.** Each write checks the Library's schema version under SQLite's
  write lock and is refused with `error.SchemaVersionTooNew`
  (`ORCA_STATUS_UNSUPPORTED` from C) when another process has migrated the
  file; nothing is stored, the Library stays open for reading, and a queued
  listen is dropped and counted instead of retried. `orca_library_open` now
  also returns `ORCA_STATUS_UNSUPPORTED`, not `ORCA_STATUS_INTERNAL`, for a
  Library a newer Orca wrote.

- **A focused Radio no longer loses its focus silently when memory runs out,
  and discarded engine and GTK errors now leave a log line.** `focusValues` in
  `liborca/library/discovery.zig` returns the allocation error to `pickRadio`
  instead of an empty filter. A prepared tag write that cannot be discarded, a
  shuffle setting that fails before playback, a setting that fails to reset, a
  job or model download whose completion cannot be recorded or published, and a
  Radio that cannot continue after the queue ends each log a warning with the
  error name.

- **Opening a Library no longer fails when another connection closes at the
  same instant, and a file Library that cannot use WAL is refused at open.**
  The schema check added in this release made its first read of `user_version`
  with no busy timeout; `SchemaGuard.install` now makes that read with the
  normal five-second timeout and returns `SchemaVersionTooNew` when the file is
  already at another version. `Library.open` checks that `PRAGMA
  journal_mode=WAL` answered `wal` and otherwise fails with `OpenFailed` and
  one logged line naming the mode, because in a rollback-journal mode the
  schema check would refuse large commits.

- **`orca.h` can be included from C++.** Three fields named `explicit`
  (`orca_release_view`, `orca_track_facts_view`,
  `orca_track_details_extra_view`) stopped a C++ compiler; under `__cplusplus`
  they are named `explicit_`. C sources and the struct layouts are unchanged.
  `zig build test` now compiles the header as C11 with `-Wall -Wextra -Werror
  -pedantic` and as C++17, checks it against the header of every release from
  0.1.0 to 0.4.0 (`tests/abi/orca-VERSION.h`), fails when a reserved field of a
  released header loses its name without being listed in
  `tests/abi/compat.zig`, and fails when the C smoke test does not call an
  export. The smoke test no longer exits 0 for a failed check numbered 256.

- **A crafted ALAC file can no longer make the decoder read or write outside
  its buffers or execute an undefined shift.** The vendored decoder bounds
  every packet- and cookie-declared size against its buffers, rejects a
  zero-run Golomb parameter that would shift by 32 or more, and validates the
  magic cookie before decoding; `alac_shim.cpp` zero-pads each packet. The ALAC
  files compile with UndefinedBehaviorSanitizer enabled, and
  `scripts/alac-sanitize.sh` replays crafted seeds under AddressSanitizer and
  UndefinedBehaviorSanitizer. Valid files decode to identical samples.

- **Sorted and filtered track listings are now fast at any scroll depth.**
  Paging a library by play count, last played, rating, loved, year, date added,
  or within a genre past the first pages no longer rebuilds a full sort for
  every page; the first page of a given sort fills a per-connection snapshot
  and every later page reads from it, so a deep scroll costs a few milliseconds
  instead of hundreds.

- **Sorting tracks by file path, loudness, or genre is now fast at any scroll
  depth.** Loudness and genre read the version 7 columns `files.sort_lufs` and
  `tracks.first_genre_id`, which triggers keep current, instead of running a
  subquery per row, and their pages are chosen by walking the covering indexes
  `files_by_sort_lufs` and `tracks_by_first_genre` (with their `_without_`
  counterparts). File path keeps its per-row best-location subquery; its
  shallow page reads the files without a held location only when the located
  window leaves part of the page unfilled, so a library whose files all have a
  location no longer scans the whole file table on every page. For all three,
  deep offsets are served from the sorted snapshot like the other value sorts.

### Changed

- **Radio and Daily Mixes count a shared genre by how rare it is.** A genre
  on few Tracks in the Library now weighs more than one on many: a rarity from
  1 for a genre on at most a hundredth of the Tracks down to 0.5 for one on a
  tenth or more scales both the Genre component, now a cosine over the
  profile's and the candidate's genres, and the choice of the 8 genres that
  draw candidates and of the genre a pick's `shared_genre` reason names; of
  two genres that weigh the same, the rarer is chosen. A `genre` seed's own
  genre and a Daily Mix cluster's genre always have rarity 1.

- **`orca-gtk` describes Radio's sound signal as how tracks sound.** The Radio
  panel's note, the Daily Mix signal line and the descriptions of Analyze no
  longer name only tempo, key and energy.

- **Radio's Stay close to Explore dial changes which tracks are picked.**
  `RadioOptions.explore` sets how far down the closeness ranking Radio may
  reach (12 candidates at 0, 600 of 2,000 at 100), how random the draw within
  that reach is (the Explore weights lean on jitter), and how much of the
  seed's own Artist is played (at most 6 in any 10 at 0–20 down to 1 at
  71–100). In Radio a candidate needs 2 distinct seed listens before
  co-listening counts. Daily Mixes rank as before. `orca-cli radio` takes
  `--seed N`, and `orca-gtk` describes the dial in new words.

- **A C host that passes `orca_radio_options.familiarity` must now add one to
  the dial, or pass 0.** The field is 0 for the Library's `radio.familiarity`
  setting and 1 to 101 for the dial at one less; any other value, including the
  former 255, is `ORCA_STATUS_INVALID_ARGUMENT`. A host built against the 0.4.0
  header that passed 0 to 100 or 255 must add one or pass 0. A host built
  against 0.3.0 or earlier, which zeroed the then-reserved byte, forced the dial
  to 0 under 0.4.0 and reads the setting again, as the header promises for a
  reserved byte. `orca_radio_status_view.options.familiarity` reports the
  options as given, 0 when the session reads the setting. `ORCA_ABI_VERSION`
  stays 0, the struct layout is unchanged, and the Zig
  `RadioOptions.familiarity` is unchanged.

- **A provider's `Retry-After` can no longer disable a service for more than 24
  hours.** Both the delay-seconds and HTTP-date forms are cut to 24 hours from
  receipt in `network.Gateway`, and a longer block or next-request time already
  stored in `provider_state` by an earlier version is cut to 24 hours from the
  time it is loaded. This replaces the earlier rule that honoured any value.
  Delays up to 24 hours, the 401/403/429 backoff schedule and the 1-hour
  `X-RateLimit-Reset-In` bound are unchanged.

- **The ALAC decoder is vendored in the source tree.** Apple's reference
  decoder sources (Apache-2.0, `macosforge/alac` at `c38887c`) live in
  `liborca/codec/vendor/alac/` instead of being fetched through
  `build.zig.zon`. `ORCA-CHANGES` beside them records the upstream commit and
  the bounds and undefined-behaviour patches Orca applies; valid files decode
  to identical samples.

- **Library analysis hashes decoded audio faster.** The audio-content hash
  gives Blake3 each decoded chunk whole instead of 256 samples at a time, which
  cut the analysis of a 5-minute stereo WAV without audio features from 554 ms
  to 433 ms. Hash values are unchanged.

- **The `bench` step measures the audio-similarity search.** `zig build
  -Doptimize=ReleaseFast bench` ends with a section that, for each embedding
  model, seeds a vector for up to 100,000 files and times the search one Radio
  top-up runs (the nearest 300 Recordings with the similarities map) five
  times.

- **Opening a window, switching Library or finishing a job no longer freezes
  orca-gtk while Library stats and the health summary are read.**
  `BrowseRequest` gains `library_stats` and `health_summary`, answered on the
  browse loader's reader thread. The sidebar counts, Library Health, Audio
  Problems, the first-run screens, the Libraries list and the Settings About
  and duplicate-scan rows keep their last numbers until the new ones arrive.
  The C ABI still has only the synchronous calls.

- **libxaac is pinned to a newer upstream commit for decoder security fixes.**
  `build.zig.zon` moves libxaac from tag v0.1.13 to `main` commit
  2fbadd57bca46693b7a077bcf1513131106d960c, which lands six AAC-decoder
  hardening fixes, including OSV-2026-1043 in the loudness-levelling path Orca
  builds with `-DLOUDNESS_LEVELING_SUPPORT`. The Nix `fetchDeps` hash is
  updated to match. No encoder code is compiled, so the encoder-side advisories
  do not apply.

- **A Library opened by this version upgrades to schema v7 and cannot then be
  opened by an older Orca.** v7 adds the trigger-maintained sort columns
  `files.sort_lufs` and `tracks.first_genre_id` with their indexes, backfilled
  during the one-transaction migration. The loudness trigger fires only when a
  file's `content_hash`, `content_hash_algorithm` or `channels` changes value,
  so a rescan that rewrites the same values does not churn the sort indexes.

## 0.4.0 - 2026-10-11

Ships Library schema version 4; opening a 0.3.0 Library upgrades it in
place, and 0.3.0 cannot open it afterwards. The C ABI only adds.

### Added

- **Home can list unplayed albums and release anniversaries.**
  `libraryUnplayedReleases` (C ABI `orca_library_unplayed_releases`) returns
  Releases with no listen, one per album Artist, albums before Releases of
  unknown type before EPs and singles, shuffled once per local day.
  `libraryReleaseAnniversaries` (`orca_library_release_anniversaries`) returns
  Releases whose full release date falls within 3 days of today's month and
  day, round anniversaries first, each with its day offset.
- **Daily Mixes have themes.** Besides genre mixes and Rarely played, Daily
  Mixes include a decade mix (the decade most listened to in 30 days, else
  the one with the most Tracks), New to you (Releases never played by Artists
  heard in 90 days), Deep cuts (Home's deep cuts), Upbeat and Wind down (the
  top and bottom thirds of energy). A theme qualifies with at least 40
  candidates. One slot is kept for a theme, which rotates daily; genre mixes
  fill the others, further themes fill slots left empty, and Rarely played
  stays last. `DailyMixKind` and the C ABI's `orca_daily_mix_kind` gain
  `decade`, `new_to_you`, `deep_cuts`, `upbeat` and `wind_down`, and a mix
  carries its `decade`.
- **`orca-gtk`'s Home shows unplayed albums, release anniversaries and theme
  mixes.** Albums you haven't played is one row of covers under Jump back in.
  This week in music lists up to four Releases released this week in an
  earlier year, with how many years ago and the weekday, and the Release most
  played a year ago. Daily Mix tiles and pages describe decade, New to you,
  Deep cuts, Upbeat and Wind down mixes.
- **Orca says when an update adds an analysis measurement.**
  `libraryAnalysisCoverage` (C ABI `orca_library_analysis_coverage`) splits
  the files analysis would measure into never analyzed and outdated, names
  the measurements the outdated files lack, and identifies the current
  measurement set; `orca-cli stats` prints it. When analyzed files lack a
  measurement, `orca-gtk` shows a banner naming it with Analyze and a close
  control; a dismissed banner returns only when the measurement set changes.
- **`orca-gtk` shows ratings and love on every track row.** Queue now, next,
  history and radio picks; Now Playing's Up Next; artist and genre Top
  Tracks; Home's Daily Mix rows; and the inspector's track view all carry the
  five-star rating and the heart, hidden for a track that left the library.
  A rating or love change repaints every open surface.
- **A Play history dial steers Radio and Daily Mixes.** The `radio.familiarity`
  setting (0 to 100, default 0) caps never-played picks at one in 2, 3 or 4
  as it rises and adds a small score tilt toward played Recordings, up to
  0.15. `RadioOptions.familiarity` overrides it per session, `orca-cli radio`
  takes `--familiarity N`, and `orca-gtk` shows the dial in the Radio picker
  and in Settings › Radio & Daily Mixes. The `orca_radio_options` C ABI
  struct consumes its reserved byte for it; 255 reads the Library's setting.
  `orca_discovery_settings` gains `has_familiarity` and `familiarity`, so a C
  client that leaves `has_familiarity` 0 keeps the stored dial.

### Fixed

- **A saved queue entry follows its Track and Recording.** `player_queue_entries`
  now carries `track_id` and `recording_id` foreign keys with `ON DELETE SET
  NULL` and indexes on both, so removing a root no longer leaves a saved entry
  pointing at an id a later scan reuses. A restore skips the cleared entry
  instead of playing whatever took the id, a Recording kept by another Track
  still resolves through the fallback, and a save whose queue holds a Track
  already gone stores a null entry that keeps its position, so the saved cursor
  stays aligned.
- **Match Review's Release ID row says why it is ticked.** The field covers
  the release-group, album-artist, release-track and recording IDs and the
  disc and track numbers, so the row can tick while both columns show the
  same MusicBrainz release ID. `ReleaseFieldDiff` now carries a
  `ReleaseIdentity`, per-category Track counts from the same dry run that
  sets `differs`, and `orca-gtk` appends them to the local value with a
  tooltip for the full text. The C ABI's `orca_release_field_diff_view`
  fills six bytes that were reserved for the counts; zero keeps the old
  behaviour.
- **A read on a thread without the write lane sees only committed rows.**
  Every Library opens a read-only connection beside its write connection, and
  the database layer routes each call by write-lane ownership: a lane holder
  reads and writes its own transaction, and every other thread reads committed
  state. Home, Daily Mixes, the metadata-issue surface, radio previews, and
  the runtime's query surface no longer see rows a scan batch has not
  committed, nor rows a rollback removes. Open-time setup and raw-SQL writes
  keep the write connection.
- **The C ABI smoke suite does not assume the default cache exists.**
  `tests/c_abi_smoke.c` creates `.zig-cache` and `.zig-cache/tmp` before its
  fixtures, as the Zig tests' `tmpDir` does, so it runs in a fresh tree or
  one built with `--cache-dir` elsewhere instead of `watch_smoke` returning
  210.
- **`libraryStats.last_analysis_at` counts measurements only.** The stat takes
  the newest diagnostics, temporal-fingerprint or audio-features row, so an
  AcoustID fingerprint stored by matching or submission, an undecodable
  verdict or an unfingerprintable note no longer moves it.
- **The SQLite lock install detects open connections by their database
  file.** The install no longer reads SQLite's memory accounting, which is
  absent on builds without memory statistics and nonzero for a host that
  merely holds SQLite memory. It scans `/proc/self/fd` for the SQLite
  database magic instead: a file-backed connection is refused, while raw
  `sqlite3_malloc` memory and in-memory connections do not refuse it.
- **Recovery refuses a read-only file instead of replacing it.** Finishing an
  interrupted undo or rolling back an interrupted write checks the file is
  writable before restoring it, exactly as a fresh undo does. The Library
  stays closed with `error.FileReadOnly` (C ABI
  `ORCA_STATUS_INVALID_STATE`) until
  the file is writable again, then the next open finishes the recovery.
- **A pause keeps an output's stall count.** Resuming preserves the count a
  Zone had earned, so an output that was already stuck when the Player paused
  stays out of the shared decode cursor instead of blocking the other Zones
  again for up to 128 ms; each resume still gives it a fresh 2 s loss timeout.
- **A paused or stopped Player releases the output's rate.** When a Player
  is paused or stopped, or has played its queue to the end, its PipeWire
  streams go inactive, so another application can move the device to its own
  rate and the sink can suspend. Playing makes the streams active again.
- **`orca-gtk` shows what's playing on Daily Mixes.** A Daily Mix page marks
  the playing Track's row, and the mix's tile on Home and in the mixes grid
  shows the playing badge.
- **`orca-gtk`'s right-hand panels share one width.** The Radio options
  panel, Now Playing (every tab) and the Daily Mix "How this mix was made"
  aside are 388 px wide like the inspector, so the page beside them no longer
  shifts between panels or tabs.
- **`orca-gtk` says when Radio has nothing left.** When Radio runs out of
  picks under its options, the Radio panel says so; with an Energy focus on a
  Library that has files without tempo, key and energy it says Energy needs
  analyzed music and offers Analyze music, or says the music is being analyzed
  while that runs.
- **Home's never-played share rounds down.** `onThisDay`'s
  `never_played_percent` reads 100 only when no Track has been played, and
  `orca-gtk`'s Collection panel hides formats with no Tracks.
- **The scanner, folder estimate and watcher resolve a directory entry whose
  type the filesystem does not report.** On a filesystem that returns
  `DT_UNKNOWN` from `getdents64`, an entry is stat'ed following no symbolic
  link and handled as if the filesystem had reported its kind: files are
  counted and examined, directories are entered and watched, and symbolic
  links are counted skipped. An entry that cannot be stat'ed is skipped as
  before.
- **Fingerprinting refuses a file with more than two channels.** The
  standalone AcoustID fingerprinter now calls the decoder's channel check
  before decoding, as playback and the analysis pass already do, so a
  multichannel file fails with `UnsupportedChannelCount` instead of
  storing a kind 3 fingerprint of its mono downmix beside the verdict that
  records no measurement. With a `file_id`, the refusal is recorded as a
  kind 5 failure under the file's quick hash, so matching selects it no
  more while the quick hash holds; `libraryTrackFingerprint` returns
  `ORCA_STATUS_UNSUPPORTED` for it.
- **`orca-gtk` fits a narrow window.** The window content's minimum width is
  350 px: the first-run flow no longer floors every window, the player bar
  reports only its gaps and squeezes its own controls, the inspector and
  Radio panels fold, and the pages that held fixed widths (Genres, Folders,
  Health, Matches, the header search and Match tabs) collapse at the 760 px
  breakpoint. The adaptive layout engages under a tiling window manager, and
  the scrolled-window adjustment readers guard a missing adjustment.

### Changed

- **Radio no longer caps never-played picks by default.** `radio.familiarity`
  defaults to 0, so picks rank by how well they match the seed with no
  structural preference for played Recordings. Setting it above 0 restores a
  cap, and 76 to 100 with the tilt is slightly more history-steered than the
  old 1-in-4 rule.
- **Starting Radio replaces the upcoming queue.** `playerStartRadio` removes
  every entry queued after the playing one, and an idle Player's whole queue,
  so a mid-album Player's picks follow the playing entry instead of the rest
  of the album. Entries enqueued during a session still land before the first
  pick not yet committed to.
- Library schema version 4. Opening an older Library upgrades it in place
  in one transaction, rebuilding `player_queue_entries` to add its foreign
  keys and, from version 2, the Daily Mix tables (their mixes are made again
  on the next run), and keeping every other row. An upgraded Library cannot
  be opened by 0.3.0.
- **`orca-gtk`'s Home drops the Never played list and the On this day
  facts.** Albums you haven't played replaces the list, and This week in
  music replaces the Added this week, Added this year and Never played facts.
- **`orca-gtk` says what analysis measures.** The task is named Analyze music
  in Settings › Maintenance, Library Health, Activity, the command palette,
  Audio Problems and First Run, and describes all four things it does:
  loudness for ReplayGain, clipping and damage checks, fingerprints for
  duplicates, and tempo, key and energy for Radio and Daily Mixes. Library
  Health calls the row Not analyzed.

## 0.3.0 - 2026-10-08

Ships Library schema version 2; opening a 0.2.0 Library upgrades it in
place, and 0.2.0 cannot open it afterwards. The C ABI only adds.

### Added

- `orca-gtk` opens on Home: Daily Mixes with a grid of every mix, Start
  Radio from what is playing, an Artist, a genre, a decade or loved tracks,
  This week's listening chart, Jump back in, Rediscover, Never played, Deep
  cuts, Top artists, the Collection's formats and On this day. A Daily Mix
  page plays, shuffles or saves the mix, says why each Track is in it and
  removes a Track with Not for me, undone from its toast. Settings ›
  Listening adds Reset recommendations.
- Home queries: `libraryListeningWeek`, `libraryRecentReleases`,
  `libraryRediscover`, `libraryNeverPlayed`, `libraryDeepCuts`,
  `libraryTopArtists`, `libraryFormats`, `libraryOnThisDay`,
  `libraryHistoryAge`, their `orca_library_*` C ABI counterparts and
  `orca-cli home` give every number and list of the Home page as bounded,
  read-only queries taking the time and UTC offset.
- Daily Mixes: `startDailyMixes` (Job kind `daily_mixes`),
  `libraryDailyMixes`, `libraryDailyMixEntries`, `libraryNotForMe`,
  `libraryClearNotForMe`, `libraryResetRecommendations`,
  `librarySaveDailyMix`, their `orca_library_*` C ABI counterparts and
  `orca-cli mixes` make up to five genre mixes from the Artists played in the
  last 30 days and a Rarely played mix once a mix day (from 04:00 local),
  each 25 tracks within 90 minutes with true reasons, no repeats across mixes
  and counts of what was left out. Not for me hides a Recording for 90 days
  and can be undone in place; a mix saves as a playlist.
- Audio features: analysis estimates each file's tempo, key, onset rate and
  spectral centroid, and `libraryTrackAudioFeatures`,
  `orca_library_track_audio_features` and `orca-cli features` read them for a
  Track with an energy figure ranked within the Library. The next analysis run
  decodes every file once to measure them and reuses its other stored results.
  Tempo comes from a mean-removed onset autocorrelation tempogram and key from
  a harmonic pitch-salience chroma matched against the Albrecht–Shanahan
  profiles. `zig build analysis-bench` times one file's analysis.
- Radio preview: `libraryRadioPreview`, `orca_library_radio_preview` and
  `orca-cli radio` rank the Recordings a Radio from a Track, Release, Artist,
  genre, decade or loved seed would play, with true reasons and each scoring
  component, without a Player. Scoring weighs Artist, genre, tempo, key and
  energy, co-listening, era, taste and jitter, moving from close to the seed
  to exploring as `explore` rises. One pick in four at most is a Recording
  never played while played ones remain; after that never-played Recordings
  fill the rest, so a Library with little history still returns full lists.
- Library Radio: `playerStartRadio` and `orca_player_start_radio` play from a
  seed and keep 8 picks queued after the user's entries, topped up from a
  worker as tracks finish. Options can change mid-session; "less like this",
  skips within 30 seconds and undo steer the session; `playerRadio` and
  `playerRadioPicks` report its state and why each queued pick was chosen.
  With `radio.continue` on, a queue that runs out continues as a Radio from
  recent listening.
- `libraryRecordingSummary` and `orca_library_recording_get` read a
  Recording's title and artist credit; `orca-cli radio` names the Recording
  an `often_after` reason cites.
- orca-gtk Library Radio: Start Radio in the Track, album, artist and Queue
  row menus and a Radio button in the player bar; the Queue page shows the
  Radio's status, its picks with their reasons, Play next and Less like this;
  a Radio panel steers explore, focus filters, unplayed, recent-play and live
  picks and undoes feedback. Settings › Listening gains Radio & Daily Mixes
  and Show listening stats on Home.
- `scripts/headless-gui.sh` takes the output size from `ORCA_HEADLESS_SIZE`.
- Discovery settings: `libraryDiscoverySettings`,
  `setLibraryDiscoverySettings` and their C ABI counterparts read and store
  Radio auto-continue, unplayed picks, the recent-play avoid window and the
  Daily Mix count.

### Changed

- Library schema version 2. Opening a version 1 Library upgrades it in place
  in one transaction, keeping every row, and adds an index on listen time and
  tables for audio features, "Not for me" feedback and Daily Mixes. An
  upgraded Library cannot be opened by 0.2.0.

### Fixed

- A Job or query reading the Library no longer fails with an aborted
  statement when another Job runs the first missing-location sweep, cache
  clear or root removal: the scratch tables those use now exist from open
  instead of being created on the shared connection mid-read.
- The test output backend's `close` waits for a render callback in progress,
  as real backends do, so a test can no longer release an audio block twice
  when its output reopens for a new format.
- A skip, jump or other hard load no longer reports the entry it left as
  audible for one output callback. A `next` or `jump` in that window now ends
  the entry being heard in queue history, and now-playing no longer briefly
  names no Track.
- `radio.continue` no longer starts Radio after the queue it followed was
  replaced, stopped or moved off its last entry before the runtime pumped.
- A Zone whose render-ahead fills its whole block pool (a custom target above
  7936 frames, or a device quantum above 3968 frames) no longer skips audio.
  While the output held a partly played block, the engine decoded up to 8192
  frames it had no free block for and dropped them, cutting entries short and
  skipping short ones entirely.

## 0.2.0 - 2026-10-06

Ships Library schema version 1, unchanged from 0.1.0. Breaking for the Zig
API: `TagWriteFailure.file` is optional. `orca-cli` exits 2 instead of 0 on a
usage error. The C ABI only adds.

### Added

- A binary cache at [orca.cachix.org](https://orca.cachix.org) for the flake's
  package, named in the flake's `nixConfig` and filled by CI from `main`.
- `libraryAcoustIdSubmittedCount` and `orca_library_acoustid_submitted_count`
  return how many files and recording IDs AcoustID has accepted from a
  Library. Settings › Matching shows it under the AcoustID status row, and
  `orca-cli submit-acoustid` prints `submitted_total=`.

### Changed

- The application icon is a white "O" on the window's dark background.
- Embedding rules are specified and enforced. The first runtime installs the
  process-wide SQLite OFD lock replacement once and thread-safely; when SQLite
  connections were already open, or the replacement was later undone, Library
  opens fail with `ORCA_STATUS_INVALID_STATE` instead of running on POSIX
  locks. A Debug build refuses `orca_runtime_destroy` from another thread. An
  AcoustID job keeps the application key it resolved when it began.

### Fixed

- An AIFF whose COMM frame count exceeds its SSND data plays the frames
  present and is reported as `corrupt_audio` by analysis; an AIFF with no SSND
  chunk fails to open instead of decoding as an empty track.
- An 8-bit AIFF reports its samples as signed 8-bit (`signed_8`,
  `ORCA_SAMPLE_FORMAT_SIGNED_8`), not unsigned.
- A WAV whose data chunk ends inside a frame is reported as `corrupt_audio` by
  analysis.
- FLAC frame errors, a short final block and an MD5 mismatch are reported as
  `corrupt_audio` by analysis while playback still tolerates them.
- A Zone attached, detached, moved or destroyed while its Player's engine
  thread starts no longer returns before that engine adopts the change.
- A release ID tag alone no longer counts as a confident match. Until Orca
  reads the release a tag names and places the Track on it, the album is in
  Needs Review with no percentage, its candidate titled from the album tag, and
  Matches and Match Review say it is not yet read from MusicBrainz. Find
  Matches reads every release the tags name, including on partially tagged
  albums, and reads a release ID tag written in uppercase as the lowercase
  MusicBrainz ID. `ReleaseCandidate.confidence` is optional and
  `orca_release_match_view_v2` gains `candidate_unread`.
- A file with more than two channels is refused for playback with
  `UnsupportedChannelCount` before any output opens, including as the gapless
  next entry, and is not measured by analysis, which raises `missing_analysis`
  naming the channel count instead of storing a loudness from unweighted
  surround channels. Results a Library already stored for such a file are
  ignored for album gain and discarded by the next analysis pass.
- A search no longer reports "Found a match to review" when its proposals form
  no release candidate and the album stays Unmatched. A search of one album or
  Track names the album and the Matches tab it is ready to review in, with a
  Review button that opens it, or says "No album match found"; Find Matches
  names how many albums are ready to review. `MatchStats` gains
  `releases_to_review` (`orca_job_match_stats_v2`), and
  `libraryReleaseMatchBucket` (`orca_library_release_match_bucket`) gives one
  Release's bucket.
- Next and previous open the target entry before moving the queue. An entry
  that fails to open is stepped over, at most 8 in a row; when none opens, the
  open error is returned and the playing entry keeps playing with now-playing
  and the queue history unchanged. A queue jump to an entry that fails to open
  changes nothing.
- An output that stops consuming while its Player plays leaves the shared
  decoder after 64 engine passes, and after 2 s is lost and goes through the
  same bounded recovery as any other lost output.
- A tag write no longer replaces a read-only file. `planTagWrite` skips it
  with `file_read_only` (`ORCA_TAG_WRITE_SKIP_FILE_READ_ONLY`); a file made
  read-only after planning fails the write with `FileReadOnly`, reported as
  `file_read_only` (`ORCA_TAG_WRITE_FAILURE_FILE_READ_ONLY`), before any file
  changes; and undo refuses, changing nothing, while a file to restore is
  read-only. A rewritten or restored file keeps its exact permission bits
  instead of losing those the umask removes, such as group write.
- A lost output that reopens counts each reopen as a recovery attempt until it
  has played 32 blocks, or until the host closes it. A device-0 output, which
  always reopens on the default sink, now ends `failed` after its fourth loss
  without a stable interval instead of retrying without end, so its Player
  drains.
- A playing Player whose every requested output has failed with its recovery
  attempts used is paused at its position and wakes the host, instead of
  never draining while its engine woke every 2 ms. It reports `paused` and not
  drained; closing and requesting the output again, then playing, resumes it.
- When no Library opens, `orca-gtk` shows the failure in place of every page
  but Settings, instead of the empty-library welcome: the Library's name, the
  reason, with the newer-version sentence when it applies, and buttons to
  choose or create a Library. Add Music Folder, Scan Library and the
  palette's library commands are unavailable instead of answering "No
  library is open".
- A queue entry whose Track was removed from the Library keeps its row in queue
  pages, so row `n` is queue position `offset + n`. `playerQueueTracks` returns
  a `QueueTrackPage` whose rows carry the position, the Track id and a summary
  that is null for a removed Track; `orca_player_query_queue_tracks` passes such
  an entry as an `orca_track_view` with `removed` set and only `id` filled. The
  Queue page and Now Playing show it as "Removed from library", and it can be
  removed from the queue.
- A gapless successor that was primed before its predecessor's last block was
  decoded, as after a seek back inside the predecessor, becomes the
  now-playing entry at its first frame, with position counted from there, even
  when that frame falls partway through a 256-frame block. Before, the whole
  block holding the predecessor's last frame was reported as the successor's,
  so identity changed and the successor's position started counting up to one
  block early.
- The signal path reports the audio being heard. A path is bit-perfect
  eligible only when the source declares its sample format, an output is open
  and the device has reported its rate and format; otherwise it carries the
  new reason `path_unknown` (`ORCA_SIGNAL_REASON_PATH_UNKNOWN`), and
  `orca-gtk` calls it unconfirmed instead of bit-perfect. A device with a
  different channel count adds `channel_layout_conversion`. The float32 stream
  on an integer device adds `sample_format_conversion` only when the device
  cannot hold the source's values, so a 16- or 24-bit source on a 24-bit
  device stays eligible. `sample_processing` stays until audio processed under
  earlier settings has played, instead of clearing while that audio is still
  queued.
- A file that leaves a Release keeps its Track id, with its queue entries,
  lyrics and user genres, when another folder of that Release projects first
  and one of its files now states the leaving file's old position. That folder
  parks the Track instead of deleting it, and the projection run then projects
  the leaving file's folder, even when the run's scope did not include it,
  which seats the Track where the file now lands.
- A `technical_anomaly` Health issue for a displaced track position is cleared
  by the next projection that no longer displaces the file, as after a retag to
  a free number or to another album, or that finds the file unreadable,
  instead of staying until dismissed.
- `orca-cli` exits with status 2 and prints the usage to standard error when
  given no command, an unknown command or a wrong argument count, instead of
  exiting 0. `orca-cli --help` prints the usage to standard output and exits 0.
- `orca-cli` runs every command's runtime on the general-purpose allocator
  instead of the process arena, so a cold scan no longer holds memory for
  every file until it exits. In a Debug build the allocator reports leaks at
  exit.
- Every failed tag write reports a `TagWriteFailure`, including one that fails
  before reaching a file. `TagWriteFailure.file` (a `TagWriteFailureFile`) is
  null then, and `orca_tag_write_failure` has `file_id` and `action_index` 0.
  New reasons `backup_exists` (`ORCA_TAG_WRITE_FAILURE_BACKUP_EXISTS`) for a
  backup directory another write created after planning, and
  `recovery_failed` (`ORCA_TAG_WRITE_FAILURE_RECOVERY_FAILED`) for an earlier
  interrupted write that could not be finished first; a file whose format
  stopped being writable after planning reports `changed_since_plan` at that
  file. `orca-cli write-tags` prints `failed - REASON -` and `orca-gtk` names
  the reason.
- Among duplicate copies of equal format, sample rate, bit depth and size,
  Duplicates ranks and suggests keeping by location (library root path,
  volume, then path) instead of the order the scanner found them, so the
  suggestion and the copy order no longer depend on the order the filesystem
  lists a folder. The duplicate bytes of the health summary free the same
  copies, where they counted the lowest-numbered file of a group as kept.
- Seeking to or past the end of a stream no longer fails for FLAC, Ogg
  Vorbis, Opus, AIFF, QOA, MP3 and MP4 (AAC and ALAC); every decoder clamps the
  target to the stream length, as WAV does, and the next read is end of stream.
  Seeking to the end of a FLAC track, which the Player does when a seek lands
  on the last frame, no longer fails as a decode error.
- Results stored for a file with no recorded channel count no longer feed
  album gain or count as a finished measurement. The next analysis pass
  measures the file again and records its channel count, or, at more than two
  channels, discards the results and raises `missing_analysis`.
- On the Match Review page, the Best candidate and confidence columns now
  start at the same position on every row. Every row's action buttons share one
  width, so a long "Review · 3 tracks need pairing" button no longer shifts the
  columns of its row.
- Queue history keeps an entry whose Track left the Library in its place.
  `playerQueueHistoryTracks` returns a `QueueHistoryTrackPage` whose rows carry
  the position, Track id, end time, reason and a summary that is null for a
  removed Track, and `orca_player_query_queue_history` passes such an entry
  with `removed` set and only `id` filled instead of skipping it. The Queue
  page's History shows it dimmed as "Removed from library".
- Queue and history pages read each entry from the Library it was queued
  from. A Player bound to another Library keeps the earlier Library's entries,
  which were looked up in the new Library and showed another Track or none;
  an entry of a closed Library reads as removed.
- `orca-gtk` offers only Remove from Queue and Save Queue as Playlist… for an
  Up Next entry whose Track left the Library, and no menu for such an entry
  in History or as the playing row. Play Next, Play Later, Love and the album
  and artist links are gone from it, and Shift+Return and L do nothing on it.
- A Track whose file is recorded with more than two channels, or with no
  channel count, shows no loudness even when results are stored for it: the
  loudness column is empty, the loudness sort places it with the unmeasured
  Tracks, the Track details carry no loudness, and a playlist's formats count
  it as not analyzed.
- A MusicBrainz search finds a Track whose artist tag joins several artists
  with commas, such as "Pa Salieu, Black Sherif". When the whole tag finds
  nothing, the search is asked once more for a recording credited to any of
  the first eight names; an artist whose name holds commas, such as "Earth,
  Wind & Fire", still matches on the whole name in one request.
- `zig build pipewire-live-smoke` opens only the silent sink whose device id
  is given (`-- ID` or `ORCA_TEST_DEVICE`, from `scripts/silent-sink.sh`) and
  refuses a missing, unknown or non-virtual device instead of opening the
  first device on the PipeWire server.
- When the clock Zone's output is lost and another Zone takes over, playback
  resumes at the position already heard. It previously skipped the audio
  decoded ahead, which could drop the end of a track and its gapless
  transition.
- Listens and now-playing updates sent to ListenBrainz name the media player
  and its version (`media_player`, `media_player_version`), taken from the
  client identity, as well as the submission client.
- `orca-gtk` draws the cover-tinted backdrop on Now Playing even when the
  cover cache drops the cover before the backdrop is composed, which a large
  library could do at start-up, and redraws a backdrop dropped from the cache
  when its page is shown again.
- Library analysis no longer reads a file no decoder can decode, such as
  WavPack or APE, a damaged file, or a file with more than two channels, on
  every run. The verdict is stored against the file's content hash and the
  decoders that refused it, so the file is examined again only when its bytes
  change or a decoder for it is added. Such files no longer count towards the
  files left to analyze. A file that could not be read is still examined again
  on the next run.
- A scan or reconcile counts the symbolic links its walk passes over, to a
  file, a directory or nothing, in `ScanStats.symlinks_skipped`; it still does
  not follow them. `orca-cli scan`, `reconcile` and `watch` print
  `symlinks_skipped=N` and the Job's Activity summary reads "N symbolic links
  skipped" when it is not zero. C hosts read it through
  `orca_library_scan_stats_v3`.
- Matching no longer examines a Track without a title or an artist again on
  every run, or decodes again a file whose bytes could not be fingerprinted.
  The Track is passed over until its title and artist are both set, and is
  still counted in `insufficient_evidence`. The file is not offered to
  AcoustID until its bytes change. Re-identify searches and fingerprints both
  again. A file that could not be opened or read is still tried on the next
  run.
- A library match run no longer selects, counts and looks up from the cache,
  on every run, a tagged release ID that MusicBrainz does not have. The
  release is passed over while its refusal is cached for 7 days, and is asked
  again once the refusal expires, the release ID changes or its Release is
  re-identified. A lookup that failed with an outage or timeout is still
  retried on the next run.
- Adding or relocating a root on a mount with no filesystem UUID, such as NFS,
  SMB or tmpfs, no longer writes `.orca-volume-id` at the mount point. The root
  binds to its own `root:<id>` volume. A root bound to an existing marker keeps
  its volume; once the marker is gone, relocating the root to its own path
  rebinds it to `root:<id>`.
- The NixOS and Home Manager modules build the default `programs.orca.package`
  against the system's nixpkgs when it provides `zig_0_17`, so the GPU drivers
  under `/run/opengl-driver` meet a glibc at least as new as their own and
  `orca-gtk` keeps its Vulkan device. The README documents
  `inputs.orca.inputs.nixpkgs.follows` and nixGL for `nix run` outside NixOS.
- An AcoustID submission whose user key cannot be read from the credential
  store, or is too large for the C ABI's buffer, fails with the new outcome
  `credential_unavailable` (`ORCA_SUBMISSION_OUTCOME_CREDENTIAL_UNAVAILABLE`)
  instead of `needs_user_key`. `orca-gtk` and `orca-cli` report it.
- A matching or verify job that cannot reach the network no longer stops at
  the first Track without a cached answer. It sends no further request,
  matches every Track its cache answers, leaves the rest eligible for the next
  run, and ends `failed` with `unavailable` set. An outage that gives up after
  its retries still stops the job.
- `orca-gtk` says "Paused because the output device stopped working" when the
  engine pauses a Player after every output failed, and Play then requests the
  output again instead of staying paused on the failed one. Match Album with no
  match says "No album match found" instead of "No release ID to fetch its
  cover". `scripts/headless-gui.sh` points MusicBrainz and AcoustID at
  `ORCA_HEADLESS_MUSICBRAINZ_URL` and `ORCA_HEADLESS_ACOUSTID_URL` when they
  are set.
- A match candidate without a title or artist scores below one whose title
  and artist match a tagged Track, instead of being judged on its length and
  fingerprint alone. An AcoustID recording named in part under one
  fingerprint takes its title, artists, length and release groups from where
  the same answer names it in full, so recordings sharing a fingerprint rank
  on all their evidence rather than on their artist credit. AcoustID answers
  cached before this, which may lack those fields, are asked again.
- Re-identifying a Release keeps its pending album correction whole. A search
  that finds a grouped recording again leaves its proposal in the group with
  the release, positions and release values the group was formed on, and
  Match Album's release vote leaves a grouped proposal on that release, so no
  correction of the group can be accepted alone.
- Verification decides once per Release, before its first page, whether the
  Release's files that still disagree are verified again: they are when it
  has a stale or unverified file then. A Release of more than 512 Tracks
  verifies them on every page, so `verified` reaches the `total_units` the job
  counted.

## 0.1.0 - 2026-10-06

The first public release. Ships Library schema version 1.
[What works today](docs/roadmap.md#what-works) has the full list.

### Added

- `liborca`, the engine: a Zig library with a public Zig API
  ([api.md](docs/api.md)) and a C ABI (`orca.h`, `liborca.so.0`, `orca.pc`;
  [frontends.md](docs/frontends.md)).
- `orca-cli`, a command-line client of the whole engine
  ([cli.md](docs/cli.md)).
- `orca-gtk`, a GTK4 and libadwaita player for Linux.
- A Library in SQLite: incremental, resumable scanning of music folders,
  identity that survives moves and unmounted drives, filesystem watching,
  folder browsing, search, genres, stats and Health issues with an action
  for each.
- Decoding of FLAC, MP3, ALAC and AAC in MP4, ADTS AAC, Ogg Opus, Ogg Vorbis,
  WAV, AIFF and QOA, and reading of their tags and cover art.
- Gapless PipeWire playback at each source's sample rate, with a queue,
  ReplayGain, a graphic and a parametric equalizer, crossfeed, output device
  selection and a signal-path report.
- Tag writes to FLAC, MP3 and ADTS through an approved, journaled plan, with
  undo and crash recovery.
- Analysis: loudness, peaks, silence, waveforms, Chromaprint fingerprints and
  duplicate detection.
- Identification: MusicBrainz and AcoustID matching with review, Match Album
  and Match Review, verification and corrections, re-identification, Cover
  Art Archive covers and AcoustID submission.
- Listening: a local play history, ratings, love for songs, albums and
  artists, playlists and smart playlists with M3U import and export, lyrics
  from tags, `.lrc` files and LRCLIB, and ListenBrainz scrobbling and Now
  Playing.
- Artist and release info from MusicBrainz, Wikidata, Wikimedia Commons,
  Wikipedia and ListenBrainz.
- Builds with Zig 0.17 against system libraries found through pkg-config
  (`-Dgtk=false` leaves out `orca-gtk`), and a Nix flake for x86_64 Linux
  with a package, a NixOS module, a Home Manager module and an overlay.
