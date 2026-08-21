# Orca - Full Implementation Plan

*Master product, architecture, subsystem, and execution plan for Orca and liborca*

| **Area**              | **Plan**                                                                                                            |
|-----------------------|---------------------------------------------------------------------------------------------------------------------|
| **Document role**     | Authoritative planning document for the complete implementation. This is not a tutorial or learning guide.          |
| **Version**           | 1.0                                                                                                                 |
| **Date**              | August 21, 2026                                                                                                     |
| **Core language**     | Zig-first implementation, with contained bindings to mature external libraries and platform APIs where appropriate. |
| **Initial platforms** | Linux and macOS.                                                                                                    |
| **Later platforms**   | Windows, then iOS and Android.                                                                                      |
| **Primary product**   | A local-files-first music player and library-maintenance application backed by the reusable liborca engine.         |
| **Scale target**      | Approximately 500,000 tracks per library as an ordinary supported workload.                                         |

This document describes what must be built and in what order. The separate learning handbook remains the implementation-learning companion.

# Contents

| **Section** | **Subject**                                                      |
|-------------|------------------------------------------------------------------|
| **1**       | Product definition and goals                                     |
| **2**       | Architecture principles and settled decisions                    |
| **3**       | liborca / native application boundary                            |
| **4**       | Core domain and library model                                    |
| **5**       | Persistence, search, and multiple libraries                      |
| **6**       | Storage and filesystem model                                     |
| **7**       | Metadata, provenance, tagging, and mutation safety               |
| **8**       | Codec and format subsystem                                       |
| **9**       | Audio engine, latency, Players, Zones, and native output         |
| **10**      | DSP, signal path, numerical precision, and bit-perfect reporting |
| **11**      | Jobs, threading, commands/events, and public API/ABI             |
| **12**      | Analysis, Library Health, fingerprints, and duplicates           |
| **13**      | Metadata services and identification                             |
| **14**      | Conversion and transcoding                                       |
| **15**      | Multi-zone synchronization                                       |
| **16**      | CD ripping                                                       |
| **17**      | Native frontends and desktop integration                         |
| **18**      | Performance, testing, recovery, and resilience                   |
| **19**      | Repository/source organization                                   |
| **20**      | Implementation program and phase gates                           |
| **21**      | Full-product completion criteria                                 |
| **22**      | Deferred/future work                                             |
| **23**      | Risks and architectural guardrails                               |

# 1. Product definition and goals

Orca is a cross-platform music system designed around a reusable core, liborca. The first-party application should be both an excellent listening environment and a serious workstation for maintaining a large digital music collection. liborca should also be reusable by headless tools and timing-sensitive audio applications without requiring the first-party Orca product to become a DAW or general-purpose plugin host.

## 1.1 Product goals

- Local-files-first playback with extremely high playback quality and transparent output behavior.

- Powerful library organization, metadata management, search, playlists, ratings, history, and maintenance workflows.

- Safe, previewable, reversible file and tag operations.

- Rich analysis and Library Health tooling suitable for very large collections.

- Picard-like automatic identification and metadata suggestion while preserving user authority.

- Reusable audio and library subsystems through liborca.

- Multiple libraries, multiple Players, multiple output Zones, and synchronized multi-zone playback.

- Dedicated high-quality CD ripping and conversion workflows.

- Native platform applications rather than a lowest-common-denominator cross-platform GUI.

- A Zig-first codebase that can progressively replace external implementations when doing so is justified.

## 1.2 Non-goals for the first complete product

- Supporting every media container or obscure codec merely because a general multimedia framework can decode it.

- Building a DAW, MIDI sequencer, multitrack recorder, or arbitrary audio-plugin host.

- Building a first-party server product simply because liborca is headless-capable.

- Making streaming-service integration a prerequisite for the local player/library.

- Writing a custom database engine, TLS stack, or cryptographic implementation.

- Making every feature pluggable; the first-party application remains opinionated and cohesive.

# 2. Architecture principles and settled decisions

| **Item**               | **Status** | **Decision**                                                                                                                              |
|------------------------|------------|-------------------------------------------------------------------------------------------------------------------------------------------|
| Core/application split | Locked     | liborca owns essentially all non-GUI music behavior. Native applications present UI and platform-facing interaction.                      |
| Language               | Locked     | Zig-first. External C/system libraries are acceptable where they are the responsible engineering tradeoff.                                |
| Foreign boundary       | Locked     | Idiomatic Zig internally/publicly plus a controlled C-compatible ABI for Swift and other non-Zig frontends.                               |
| Libraries              | Locked     | Multiple independent library databases are first-class.                                                                                   |
| Database               | Locked     | SQLite + FTS5 behind a Zig-owned repository/query layer.                                                                                  |
| File identity          | Locked     | Musical entities are not identified by filesystem paths.                                                                                  |
| File mutation          | Locked     | User files are external assets. Mutation requires explicit intent, preview, journaled execution, and recovery/undo where possible.        |
| Internal metadata      | Locked     | Orca may freely maintain/display preferred metadata without rewriting source files.                                                       |
| Audio I/O              | Locked     | liborca owns native audio output and device management.                                                                                   |
| Latency                | Locked     | liborca supports direct low-latency rendering and buffered high-resilience rendering. Decode/read-ahead is independent of output latency. |
| DSP topology           | Locked     | Configurable ordered chains initially; arbitrary branching graphs are deferred.                                                           |
| DSP scope              | Locked     | Player-level DSP for timeline-wide processing; Zone-level DSP for output/environment processing.                                          |
| Players/Zones          | Locked     | Multiple Player and Zone instances are core-capable.                                                                                      |
| Codecs                 | Locked     | Use mature Zig implementations/packages when available; otherwise focused bindings. No required FFmpeg dependency.                        |
| Analysis               | Locked     | Derived results are cached/versioned by algorithm, parameters, and source identity.                                                       |
| CD ripping             | Locked     | Dedicated secure/verified ripping subsystem.                                                                                              |
| Headless use           | Locked     | liborca does not assume a GUI. A first-party server app is not required.                                                                  |
| Mobile                 | Locked     | Not early, but abstractions must not make iOS/Android impossible.                                                                         |
| Sync                   | Open       | Future cross-device synchronization is desired; exact implementation is deferred.                                                         |
| Streaming              | Deferred   | Leave clean source/provider extension points, but implement local files first.                                                            |

## 2.1 Architectural laws

1. liborca remains useful without a GUI.
2. The frontend never becomes the authoritative implementation of library, playback, metadata, mutation, or analysis behavior.
3. Track, Recording, File, and Location remain distinct concepts.
4. Playback never requires database membership.
5. The hard real-time path never depends on SQLite, networking, ordinary filesystem I/O, or GUI execution.
6. Output latency is a policy/capability decision rather than a fixed prerender delay baked into liborca.
7. Every DSP stage permitted in a low-latency path explicitly satisfies a real-time-safety contract.
8. Every external mutation is planned and recorded before user assets change.
9. Large libraries use indexing, pagination, incremental work, and resumable jobs rather than full materialization.
10. External libraries remain behind Orca-owned interfaces so they can be replaced without rewriting the domain layer.

# 3. liborca / native application boundary

| **Area**                 | **Plan**                                                                                                                                                                                                                                                         |
|--------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Native frontend owns** | Window lifecycle, menus, native dialogs, drag/drop presentation, accessibility presentation, permission UX, visual navigation, native notifications, UI event loop, and platform media-control presentation.                                                     |
| **liborca owns**         | Runtime, libraries, database access, search, scanning, metadata resolution, mutation plans/history, codecs, Players, queues, Zones, DSP, audio devices/output, analysis, conversion, ripping, provider/scrobbling logic, Jobs, and authoritative state machines. |
| **Shared adapters**      | Credential/keychain access, platform app-data/cache locations, permission-sensitive handles, media-session registration, and capabilities requiring native host cooperation.                                                                                     |

## 3.1 Public object model

| **Area**          | **Plan**                                                                                                                  |
|-------------------|---------------------------------------------------------------------------------------------------------------------------|
| **OrcaRuntime**   | Root liborca context. Owns process-level managers/executors and ordered shutdown.                                         |
| **Library**       | One independently openable/closable logical library backed by its own SQLite database.                                    |
| **Player**        | Transport/timeline/queue. Not permanently tied to a physical output.                                                      |
| **SourceSession** | One opened playable source plus decoder state, source format, decode-ahead buffers, generation, and timeline mapping.     |
| **Zone**          | Output environment: selected device, OutputSession, Zone DSP, render policy, latency/timing state, and Player attachment. |
| **Device**        | Discovered output capability descriptor.                                                                                  |
| **OutputSession** | Currently opened native audio stream plus negotiated format, timing, callback, and backend state.                         |
| **Job**           | Centralized long-running operation with progress, state, cancellation, and errors.                                        |

## 3.2 Stable handles

- Cross-subsystem and ABI-visible references use typed opaque handles/IDs.

- Generational handles are preferred for runtime objects so stale handles cannot accidentally refer to reused slots.

- Short-lived internal pointers are allowed when owner and lifetime are clear.

- Foreign-language frontends never depend on internal Zig struct layout.

# 4. Core domain and library model

The library model separates musical identity from physical encoded files and storage locations.

| **Area**      | **Plan**                                                                                                                                     |
|---------------|----------------------------------------------------------------------------------------------------------------------------------------------|
| **Artist**    | Person/group/entity participating in music metadata with roles such as album artist, performer, composer, conductor, producer, remixer, etc. |
| **Release**   | A particular album/release/edition with release-level metadata, disc structure, artwork, identifiers, and relationships.                     |
| **Track**     | A Recording's appearance at a specific position/context on a Release.                                                                        |
| **Recording** | Logical recorded performance/audio identity, permitting several encoded Files for the same recording.                                        |
| **File**      | Concrete encoded audio object: codec/container/size/sample rate/bit depth/hash/embedded metadata.                                            |
| **Location**  | Where a File is accessible on a specific device/storage provider. A path is one kind of Location.                                            |
| **Playlist**  | Ordered/selectable references to playable/library entities independent of filesystem organization.                                           |

## 4.1 Managed and referenced libraries

- Referenced mode indexes and manages metadata for files wherever the user placed them.

- Managed mode can organize a configured root using user-defined naming/folder templates.

- Both modes share the same logical identity model.

## 4.2 Future identity requirements

- Stable IDs survive moves/renames.

- Per-device Locations permit different local paths for the same logical item.

- The model permits future sync of metadata/playlists/history independently from optional file transfer.

- Works/compositions/movements for classical metadata remain extensible even if not fully modeled in the first schema.

# 5. Persistence, search, and multiple libraries

## 5.1 SQLite layout

- One SQLite database per independent Library.

- A small global application store/configuration records known libraries and application-level state as needed.

- FTS5 backs full-text search.

- All SQL stays behind typed Zig repository/query APIs.

- Schema migrations are explicit and versioned.

## 5.2 Concurrency model

- Each Library has one serialized logical write lane.

- A logical write lane does not require a dedicated OS thread; shared DB workers may execute ordered per-library tasks.

- Read connections/snapshots may run concurrently.

- WAL is the default candidate and must be validated under realistic concurrent workloads.

## 5.3 Required query behavior

- Paged/windowed artist, album, track, playlist, history, and search results.

- Indexed filtering/sorting for common technical and metadata fields.

- Interactive search at 500,000 tracks.

- No full database scan simply to open the application.

- No public/UI API that dumps the entire library across the ABI.

# 6. Storage and filesystem model

## 6.1 Source/destination abstractions

- Decoders and analysis consume a small ReadableSource capability interface rather than hard-coded path strings.

- LocalFileSource is the normal desktop implementation.

- Seek, read-at-offset, size, and stable storage identity are explicit capabilities rather than assumptions.

- WritableDestination or equivalent is used for conversion/staged output where needed.

- The abstraction remains small enough that ordinary local desktop code stays readable.

## 6.2 Scanning and change detection

- Incremental scanner Jobs discover/import/reconcile file state.

- Filesystem watchers are hints, not the sole source of truth.

- Scanner work is resumable/cancellable and commits in batches.

- Startup never waits for a complete rescan.

- External file changes update ObservedFileMetadata without automatically overwriting OrcaMetadata.

# 7. Metadata, provenance, tagging, and mutation safety

## 7.1 Metadata layers

| **Area**                 | **Plan**                                                                                       |
|--------------------------|------------------------------------------------------------------------------------------------|
| **ObservedFileMetadata** | What the external file currently contains.                                                     |
| **OrcaMetadata**         | Preferred/corrected metadata held by Orca, including user edits and selected provider results. |
| **EffectiveMetadata**    | What Orca currently displays, produced by metadata resolution policy.                          |

## 7.2 Resolution policies

- Prefer file metadata.

- Prefer Orca metadata.

- Review meaningful conflicts when both sides contain intentional changes.

- User-locked values outrank automatic provider refreshes.

- Provenance is retained for important values where useful: user, file, provider, inference, analysis, etc.

## 7.3 Portable tagging

- Canonical metadata maps to ID3, Vorbis-style comments, MP4 metadata, and other format-specific tagging models.

- Format-specific conventions never define Orca's canonical metadata model.

- Orca-only state remains internal unless the user explicitly requests a sensible portable mapping.

## 7.4 Mutation planning/journal

- All external writes are represented by immutable MutationPlans before execution.

- Plans record targets, expected current state, proposed new state, conflicts/collisions, reversibility, and affected files.

- Execution is journaled through durable states including Prepared, In Progress, Committed, Rolled Back, Failed Recoverable, and Needs Reconciliation.

- Tag rewrites prefer temporary-output-and-replace behavior when practical.

- Rename/move operations validate collisions and external state before committing.

- Deletion defaults to recoverable trash/quarantine semantics when possible.

## 7.5 Undo requirements

- Undo operates on recorded operations rather than a transient UI-only stack.

- Bulk operations are grouped logically.

- Undo validates that external state still matches the operation's expected after-state.

- If exact reversal is unsafe, Orca enters reconciliation instead of pretending success.

- Startup recovery inspects unfinished operation records and staged filesystem state.

# 8. Codec and format subsystem

## 8.1 Format scope

- Prioritize FLAC, WAV, AIFF, ALAC, MP3, AAC/M4A, Opus, Vorbis, and WavPack.

- Consider APE, DSD, and additional formats based on real demand.

- Avoid a foundational FFmpeg dependency.

## 8.2 Codec registry

- All decoders/encoders implement Orca-owned interfaces and register through a CodecRegistry.

- Playback/conversion/analysis cannot depend on codec-specific handles or types.

- Use mature Zig codec implementations/packages when available and reliable.

- Use focused bindings when necessary; libFLAC/libopus/mpg123-class dependencies are acceptable.

- Potential Zig-native rewrites are late-stage improvements after the broader application is functional and tested.

## 8.3 Shared PCM pipeline

- Decode into a common PCM-facing pipeline reused by playback, analysis, conversion, and ripping output.

- Preserve a direct/native PCM path where practical for bit-perfect output.

- Processed audio uses canonical working forms selected by algorithm needs.

# 9. Audio engine, latency, Players, Zones, and native output

## 9.1 Native backends

- Linux: PipeWire primary backend; lower-level alternatives only when a concrete requirement justifies them.

- macOS: Core Audio native backend.

- Windows: WASAPI backend later.

- Backends expose device discovery, capabilities, format negotiation, timing, latency, device loss, and stream lifecycle through one Orca-owned contract.

## 9.2 Latency model

liborca separates source preparation from output latency. Decode/read-ahead may be aggressive because prepared future PCM does not itself delay playback. The amount of already-rendered/device-ready audio is policy-driven.

| **Area**                      | **Plan**                                                                                                                                     |
|-------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------|
| **Robust playback**           | Buffered rendering prepares multiple periods ahead for resilience. This is an appropriate default candidate for the first-party Orca player. |
| **Interactive / low latency** | DSP/rendering occurs in the native RT callback or a tightly coordinated RT path with the smallest reliable buffering/quantum.                |
| **Custom**                    | Caller specifies latency/buffering constraints or target policy within backend and graph capability limits.                                  |

## 9.3 Latency/timing reporting

- Report requested vs achieved latency.

- Track backend/device period or quantum.

- Track Orca queueing/render-ahead.

- Track DSP algorithmic/lookahead latency.

- Track estimated hardware/backend output latency when available.

- Represent positions primarily in frames/sample-time with mapping to monotonic host time.

- Keep latency, jitter, scheduling precision, and inter-zone synchronization error conceptually distinct.

## 9.4 Player / SourceSession

- Player owns queue/timeline/transport state, current/next SourceSessions, Player-level DSP, and generation/discontinuity state.

- SourceSession owns source, decoder, format state, decode-ahead pools/queues, source generation, and timeline mapping.

- Next SourceSession is opened/primed before the current track ends for gapless playback.

- Crossfade may consume current and next sessions simultaneously at Player processing scope.

## 9.5 Zone / OutputSession

- Zone owns selected Device, output-specific DSP, render policy, timing/clock state, and an OutputSession.

- Zone refers to Player by stable handle; neither permanently owns the other.

- A Zone can survive device loss while its OutputSession is recreated.

- One Player may feed several Zones; independent Players may feed different Zones.

## 9.6 Buffer ownership

- Steady-state audio uses preallocated bounded pools/queues.

- No emergency allocation on the hard real-time path.

- Initial multi-zone fanout copies PCM into independently owned Zone pipelines rather than shared reference-counted blocks.

- Generation numbers invalidate stale buffered data after seeks, source changes, and structural render changes.

- The hard callback never waits for producers; underruns output silence/diagnostics and return immediately.

## 9.7 Real-time safety

- No allocation/free, SQLite, ordinary file I/O, networking, UI callbacks, unbounded logging, or blocking synchronization on the hard RT path.

- DSP nodes intended for direct RT rendering explicitly declare and satisfy real-time safety.

- Control-side graph/state changes are prepared outside RT and published immutably at safe block boundaries.

# 10. DSP, signal path, numerical precision, and bit-perfect reporting

## 10.1 Ordered DSP chains

| **Area**         | **Plan**                                                                                                                                              |
|------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Player-level** | ReplayGain/track gain, crossfade, source mixing/transitions, and timeline-wide processing.                                                            |
| **Zone-level**   | Speaker/headphone EQ, room correction, crossfeed, convolution, channel mapping, resampling, output conversion/dither, and device-specific processing. |

## 10.2 Node contract

- Prepare/configure outside RT and allocate scratch memory in advance.

- Report whether the node changes samples, sample rate, or channel layout.

- Report algorithmic latency, lookahead, tail frames, preferred/fixed block constraints, and real-time safety.

- Support reset/discontinuity semantics.

- Support smooth parameter ramps where instantaneous changes would click.

## 10.3 Numerical policy

- Default processed PCM working buffers are f32 unless a specific path justifies otherwise.

- Individual algorithms may use f64 coefficients, state, accumulators, or reference implementations where numerical behavior benefits.

- Precision decisions are algorithm-specific, not engine-wide ideology.

## 10.4 Bit-perfect/direct reporting

- Bit-perfect and low-latency are separate concepts.

- A path can be low latency but processed, or buffered but bit-perfect.

- Any sample-changing DSP, gain, mixing, or resampling removes the bit-perfect claim.

- Orca reports source format, output format, active nodes/conversions, and the reason a path is or is not bit-perfect.

## 10.5 SIMD

- Use Zig vector operations where they produce measurable benefit.

- High-value targets include gain, peak/RMS, mixing/crossfade, PCM conversion, waveform reduction, FFT/fingerprinting, and resampling.

- Maintain scalar/reference implementations for correctness and benchmarks where useful.

- Do not retain SIMD complexity without measurable improvement.

# 11. Jobs, threading, commands/events, and public API/ABI

## 11.1 Execution contexts

| **Area**                            | **Plan**                                                                              |
|-------------------------------------|---------------------------------------------------------------------------------------|
| **Host/UI thread**                  | Owned by frontend; submits commands and consumes events/snapshots.                    |
| **Runtime control executor**        | Single logical authority for high-level state transitions and lifecycle coordination. |
| **Audio decode pool**               | Priority-isolated workers for active SourceSessions.                                  |
| **Player render lane**              | Timeline processing/fanout where required by rendering policy.                        |
| **Zone render lane**                | Buffered-mode Zone DSP/output preparation where required.                             |
| **Native audio callback/workgroup** | Hard real-time direct rendering/output consumption.                                   |
| **General worker pool**             | Scanning, analysis, artwork, conversion, file operations.                             |
| **Library write lanes**             | One serialized logical FIFO per Library.                                              |
| **Database reads**                  | Concurrent bounded queries/snapshots.                                                 |
| **Network executor**                | Provider/scrobbling activity.                                                         |
| **Ripping workers**                 | Dedicated long-running optical extraction work.                                       |

## 11.2 Job system

- Common job representation for scanning, analysis, conversion, ripping, metadata lookup, artwork, and mutation execution.

- Jobs expose state, progress, errors, cancellation, priority, dependencies, and resumability where meaningful.

- Playback execution cannot be starved by background work.

## 11.3 Commands/events/snapshots

- Frontends send thread-safe commands to liborca.

- Long-running operations return Job/Request handles rather than blocking UI calls.

- liborca emits bounded/coalesced events and exposes authoritative snapshots/queries.

- High-frequency playback position is sampled/snapshotted rather than emitted thousands of times per second.

- Foreign frontends are never called directly from arbitrary internal worker threads.

## 11.4 C ABI

- Opaque runtime/library/player/zone/job handles.

- Simple primitive/POD values and explicit ownership/lifetime rules.

- No borrowed internal containers or SQLite rows across the ABI.

- ABI is designed cleanly early but not frozen as stable 1.0 until liborca matures.

# 12. Analysis, Library Health, fingerprints, and duplicates

## 12.1 Analysis types

- Loudness / ReplayGain-related measurements.

- Peak and clipping diagnostics.

- Silence detection.

- Waveform summaries.

- Spectrum/FFT-derived features where useful.

- Acoustic fingerprints.

- Exact-content hashes and duplicate assistance.

- Technical-property anomaly detection and corruption/error reporting where available.

## 12.2 Versioned cache model

- Analysis identity includes kind, algorithm ID, algorithm version, parameter hash, and source-audio identity.

- Unchanged valid results are reused.

- Algorithm changes selectively invalidate affected results rather than rescanning the whole collection.

## 12.3 Library Health

- Missing/inconsistent metadata.

- Missing track/disc numbers and album-artist anomalies.

- Artwork problems.

- Missing ReplayGain/loudness analysis.

- Clipping/silence/technical anomalies.

- Exact duplicates and likely same-recording duplicates.

- Missing/untracked files and stale Locations.

# 13. Metadata services and identification

## 13.1 Service adapters

- MusicBrainz metadata provider.

- AcoustID lookup using Chromaprint-style fingerprints.

- Last.fm / ListenBrainz scrobbling adapters.

- Lyrics and future metadata providers behind common interfaces.

## 13.2 Identification workflow

- Collect existing tags, filename tokens, duration, fingerprints, and embedded provider IDs.

- Query/cache external candidates.

- Score candidate recordings/releases using several evidence sources.

- Return best candidate plus alternatives and confidence rather than silently applying.

- Accepted results update OrcaMetadata/provenance first.

- Writing accepted metadata to files remains a separate explicit mutation.

## 13.3 Networking

- Central liborca HTTP/networking layer.

- Rate limiting, retry/backoff, caching, service identification, and offline tolerance.

- Credentials accessed through secure platform storage adapters.

- Network failure never blocks playback or corrupts local state.

# 14. Conversion and transcoding

- Encoder registry parallels decoder registry.

- Pipeline reuses decode, PCM transform, resampler, channel mapping, bit-depth conversion/dither, and encoder components.

- Preserve/correct metadata and artwork according to explicit conversion rules.

- Output is written to a staged destination, validated, then finalized.

- Originals are not overwritten by default.

- Conversion presets are data/configuration, not separate hard-coded implementations.

- Nominal format conversion must not silently normalize/apply DSP unless the preset explicitly requests it.

# 15. Multi-zone synchronization

Multi-zone synchronization is a timing and clock-control problem, not merely starting multiple outputs simultaneously.

- Player owns a logical musical timeline.

- Each Zone tracks device sample time, monotonic host time, reported output latency, and estimated audible timeline position.

- Outputs align to a common logical start target where the platform allows.

- Independent DAC clocks are expected to drift.

- Small ongoing drift is corrected gradually using adaptive resampling on follower Zones.

- Large lag/error triggers a controlled re-prime/resynchronization at a defined timeline point.

- A lagging/broken Zone never indefinitely stalls healthy Zones.

- Relative synchronization error, correction state, and effective latency are inspectable.

# 16. CD ripping

- Dedicated DiscDrive/Disc/TOC/RipPlan domain rather than treating a CD as an ordinary ReadableSource.

- Drive discovery and capability/identity handling.

- Disc/track-layout identification and metadata matching.

- Secure extraction strategy with rereads/error detection.

- Drive offset handling.

- AccurateRip-style or equivalent verification integration where feasible.

- Detailed ripping logs including settings, retries/errors, verification results, and output hashes.

- Extracted PCM feeds the standard encoder/tagging/import pipeline.

- Bad/unverifiable reads are surfaced clearly rather than silently treated as perfect.

# 17. Native frontends and desktop integration

## 17.1 Linux

- Native GTK4-oriented frontend using liborca's Zig-facing API.

- Virtualized large-library browsing.

- MPRIS integration reflects/controls authoritative liborca Player state.

- Native file dialogs, drag/drop, notifications, shortcuts, accessibility, and desktop integration.

## 17.2 macOS

- Swift + AppKit/SwiftUI frontend through a thin wrapper over liborca's C ABI.

- MPNowPlayingInfoCenter / MPRemoteCommandCenter integration mirrors liborca Player state.

- Native menuing, media keys, dialogs, accessibility, drag/drop, notifications, and keychain integration.

## 17.3 Windows and mobile

- Windows frontend/backend follows after Linux/macOS validate the core boundary.

- iOS/Android later use the same domain while providing storage/audio/lifecycle adapters.

- Mobile readiness requires avoiding assumptions of unrestricted filesystem enumeration or permanently running desktop processes.

# 18. Performance, testing, recovery, and resilience

## 18.1 Performance requirements

- 500,000-track libraries open without mandatory scanning.

- Search remains interactive.

- UI result sets remain bounded/virtualized.

- Scanning, analysis, and conversion do not destabilize playback.

- Artwork is lazy/cached.

- Analysis is resumable/cached.

- Single-file changes remain incremental.

## 18.2 Test layers

- Unit tests for domain logic, parsers, metadata resolution, operation planning, DSP, and query building.

- Golden/reference tests for codecs, tag round-trips, DSP, resampling, analysis, and format mappings.

- Fuzz/property tests for malformed external data and binary parsers.

- Integration tests with real temporary filesystems and SQLite databases.

- Crash-injection/restart tests at every mutation state transition.

- Audio real-time safety/underrun stress tests.

- Multi-zone clock/drift simulations and hardware integration tests.

- Large-library performance regressions with repeatable synthetic corpora.

## 18.3 Pathological fixture library

- Malformed/truncated metadata and unusual encodings.

- Missing or contradictory fields.

- Large/bad artwork.

- Read-only files/directories.

- Files modified/moved during scans.

- Exact duplicates and multiple encodes of one recording.

- Multi-disc/compilation/Various Artists cases.

- Gapless albums.

- Sample-rate/bit-depth/channel-layout changes between tracks.

- Interrupted conversions and incomplete mutation operations.

# 19. Repository/source organization

| **Area**               | **Plan**                                                                               |
|------------------------|----------------------------------------------------------------------------------------|
| **liborca/core**       | Runtime, IDs/handles, errors, events, Jobs, configuration, common infrastructure.      |
| **liborca/storage**    | ReadableSource/WritableDestination/local storage implementations.                      |
| **liborca/database**   | SQLite wrapper, migrations, repositories, search/FTS.                                  |
| **liborca/library**    | Domain entities, scanners, playlists, organization.                                    |
| **liborca/metadata**   | Canonical metadata, tag mapping, provenance, resolver.                                 |
| **liborca/mutation**   | Plans, journal, execution, recovery, undo.                                             |
| **liborca/codec**      | Decoder/encoder interfaces and registry.                                               |
| **liborca/audio**      | AudioSystem, Player, Zone, devices, output backends, clocks, render policies.          |
| **liborca/dsp**        | DSP node contracts and built-in processing.                                            |
| **liborca/analysis**   | Loudness, peaks, waveform, fingerprinting, duplicate helpers.                          |
| **liborca/conversion** | Transcode presets/pipelines.                                                           |
| **liborca/ripping**    | Optical-drive/disc/extraction/verification.                                            |
| **liborca/services**   | MusicBrainz, AcoustID, scrobbling, lyrics/provider adapters.                           |
| **liborca/c_api**      | Foreign-language stable-ish API boundary.                                              |
| **apps**               | Linux, macOS, Windows later, CLI/headless architectural test client.                   |
| **tests**              | Fixtures, integration, audio, recovery, performance, fuzz targets.                     |
| **docs**               | Architecture decisions, format notes, schema decisions, signal path, public API notes. |

# 20. Implementation program and phase gates

Implementation proceeds as vertical slices. A phase ends when its exit criteria pass; it does not wait for every future feature in that subsystem.

## Phase 0 - Repository and core scaffolding

**Objective.** Establish a reproducible Zig project and empty liborca/application boundaries

### Required deliverables

- Build graph for liborca, CLI/test client, tests, benchmarks, and platform modules.

- Dependency-linking pattern for C/system libraries.

- Basic test/benchmark commands and fixture directories.

### Phase exit / definition of done

- liborca and orca-cli build on the initial development platform.

- Unit tests run from one standard command.

- One foreign-library/linking smoke test proves the dependency pattern.

## Phase 1 - Runtime, ownership, handles, and shutdown

**Objective.** Implement the root lifetime model before feature subsystems depend on it

**Depends on.** Phase 0

### Required deliverables

- OrcaRuntime and manager skeletons.

- Typed IDs/generational runtime handles.

- Explicit allocator/ownership conventions.

- Ordered shutdown/cancellation rules.

### Phase exit / definition of done

- Stale handles are detected reliably.

- Runtime can start/stop repeatedly under tests without leaks/use-after-free.

- Dummy in-flight work is safely cancelled/drained at shutdown.

## Phase 2 - Commands, events, snapshots, Jobs, and CLI

**Objective.** Create the host-independent control plane before any GUI

**Depends on.** Phase 1

### Required deliverables

- Thread-safe command submission.

- Bounded/coalesced event channel.

- Snapshot/query model for high-frequency state.

- Common Job representation/cancellation.

- orca-cli as an actual liborca client.

### Phase exit / definition of done

- CLI can open runtime objects and observe async completion through public interfaces.

- Slow event consumers cannot grow memory without bound.

- No worker thread calls UI-specific code.

## Phase 3 - SQLite libraries, schema, FTS, and 500k benchmark

**Objective.** Lock persistence and multiple-library foundations early

**Depends on.** Phase 2

### Required deliverables

- One database per Library.

- Schema migrations.

- Typed repositories/prepared statements.

- FTS5 search.

- Serialized write lanes and read connections.

- Synthetic 500k-track corpus/benchmark.

### Phase exit / definition of done

- 500k library opens without scanning.

- Representative search/browse queries are interactive.

- 10k batch updates are transactional.

- Concurrent normal reads and writes behave correctly.

## Phase 4 - Storage abstraction, scanner, and observed metadata

**Objective.** Connect real files without hard-coding path assumptions into codecs

**Depends on.** Phase 3

### Required deliverables

- ReadableSource and LocalFileSource.

- Library roots and incremental scanner.

- Initial format sniffing/tag reading.

- Observed file state/reconciliation.

- Filesystem watcher integration as advisory signals.

### Phase exit / definition of done

- Large scans are cancellable/resumable.

- Unchanged files are skipped incrementally.

- Scanner commits in bounded batches.

- Observed metadata stays distinct from Orca metadata.

## Phase 5 - First native audio output and WAV vertical slice

**Objective.** Get correct audible output through the real audio architecture with the simplest codec

**Depends on.** Phases 1-4

### Required deliverables

- Minimal Zig PCM WAV reader.

- PipeWire backend on Linux.

- Device discovery/OutputSession.

- Player, Zone, pools, and initial timing/latency reporting.

- Direct low-latency path plus buffered-policy skeleton.

### Phase exit / definition of done

- Known WAV fixtures play correctly.

- Hard RT path performs no forbidden work.

- Underruns are safe/observable.

- Requested/achieved latency and backend quantum are inspectable.

## Phase 6 - Codec registry, SourceSession, and gapless preparation

**Objective.** Generalize source decoding while preserving Orca-owned interfaces

**Depends on.** Phase 5

### Required deliverables

- CodecRegistry and Decoder interface.

- FLAC adapter and at least one lossy adapter.

- SourceSession lifecycle/decode-ahead pools.

- Next-session priming.

### Phase exit / definition of done

- Several codecs play through identical Player/Zone APIs.

- Codec-specific types remain contained.

- Malformed input fails cleanly.

- Next track primes before current track ends.

## Phase 7 - Full Player/Zone engine and latency policies

**Objective.** Implement the definitive audio ownership, render-policy, discontinuity, and gapless model

**Depends on.** Phase 6

### Required deliverables

- Multiple Players/Zones.

- Generation-based seeks/discontinuities.

- Player-level and Zone-level processing scopes.

- Direct RT and buffered render strategies.

- Device loss/recovery.

- Gapless/crossfade infrastructure.

### Phase exit / definition of done

- Seek needs no unsafe queue surgery.

- One failed Zone does not stop another.

- Robust and low-latency policies use the same Zone abstraction.

- Gapless works where backend/device constraints permit.

## Phase 8 - DSP, precision, resampling, SIMD, and signal-path reporting

**Objective.** Build the serious processed-audio engine and transparent direct/bit-perfect reporting

**Depends on.** Phase 7

### Required deliverables

- DSP node contract including RT safety/latency metadata.

- Gain/ReplayGain and metering.

- Parametric EQ.

- Curated additional nodes.

- Resampler boundary.

- Scalar/reference + SIMD kernels.

- Signal-path inspector.

### Phase exit / definition of done

- DSP changes publish safely without RT allocation/locks.

- Bit-perfect eligibility is explained correctly.

- Node algorithmic latency enters achieved-latency reporting.

- SIMD paths have benchmark/correctness evidence.

## Phase 9 - Canonical metadata and safe file mutation

**Objective.** Turn Orca into a library-maintenance tool without weakening user ownership

**Depends on.** Phases 3-4

### Required deliverables

- Observed/Orca/Effective layers.

- Provenance/locks.

- Initial portable tag writers.

- MutationPlan/preview.

- Operation journal/recovery.

- Rename/move and grouped undo.

### Phase exit / definition of done

- Internal edits never touch files automatically.

- External writes require approved plans.

- Crash injection recovers to allowed states.

- Undo detects incompatible external edits.

## Phase 10 - Native Linux/macOS frontends and desktop media integration

**Objective.** Make first-party applications thin native clients of liborca

**Depends on.** Phases 2-9

### Required deliverables

- GTK4 Linux UI.

- Swift/AppKit/SwiftUI macOS UI over C ABI.

- Virtualized huge-library views.

- MPRIS integration.

- Now Playing/remote-command integration.

- Native dialogs/drag-drop/notifications/accessibility/shortcuts.

### Phase exit / definition of done

- CLI and GUI share core semantics.

- Frontends do not import internal DB/codec/audio structs.

- Large views remain virtualized.

- Desktop media controls mirror Player state.

## Phase 11 - Analysis and Library Health

**Objective.** Add cached, versioned audio/library diagnostics

**Depends on.** Phases 3, 6-8

### Required deliverables

- Loudness/ReplayGain.

- Peak/clipping/silence.

- Waveform cache.

- Fingerprint integration.

- Duplicate analysis.

- Library Health queries/UI support.

### Phase exit / definition of done

- Unchanged analysis is reused.

- Algorithm-version changes selectively invalidate.

- Background analysis cannot starve playback.

- Health queries use indexed/cached state.

## Phase 12 - Provider-assisted identification and scrobbling

**Objective.** Add MusicBrainz/AcoustID-style matching and online service adapters

**Depends on.** Phases 9 and 11

### Required deliverables

- Central HTTP layer.

- Provider interface.

- Fingerprint lookup.

- Candidate scoring/confidence/provenance.

- Provider cache/rate limiting/retry.

- Scrobbling adapters.

### Phase exit / definition of done

- Local operation remains functional offline.

- Provider results become proposals, not file writes.

- User locks survive refreshes.

- Rate limits/retries are centrally enforced.

## Phase 13 - Conversion and encoding

**Objective.** Reuse the audio pipeline for safe transcoding

**Depends on.** Phases 6, 8, 9

### Required deliverables

- Encoder registry.

- Conversion presets.

- Optional resampling/channel/bit-depth processing.

- Metadata/artwork preservation.

- Staged output validation/finalization.

### Phase exit / definition of done

- Representative lossless/lossy conversions work.

- Cancel/failure leaves no misleading final file.

- Originals are not overwritten by default.

- No implicit DSP absent from preset.

## Phase 14 - Synchronized multi-zone playback

**Objective.** Turn the multi-Zone object model into clock-correct synchronized playback

**Depends on.** Phases 7-8

### Required deliverables

- Player timeline clock.

- Backend device clock/timing snapshots.

- Latency accounting.

- Aligned starts.

- Drift measurement.

- Adaptive follower resampling.

- Hard re-prime/rejoin strategy.

### Phase exit / definition of done

- Multiple outputs align to a common target.

- Long-running device clocks remain synchronized within defined tolerance.

- Lagging Zones recover without pausing healthy Zones.

- Clock/latency/sync state is inspectable.

## Phase 15 - Secure/verified CD ripping

**Objective.** Implement the dedicated optical-media acquisition subsystem

**Depends on.** Phases 9, 12, 13

### Required deliverables

- Drive/Disc/TOC models.

- Disc identification/metadata lookup.

- Secure extraction/rereads.

- Drive-offset handling.

- Verification integration.

- Detailed logs.

- Encoder/tag/import handoff.

### Phase exit / definition of done

- Uncertain reads are surfaced.

- Verification state is trustworthy/logged.

- Rips enter the normal library pipeline.

- Cancellation/retry does not corrupt the library.

## Phase 16 - Scale, resilience, fuzzing, and release hardening

**Objective.** Make the complete system reliable against ugly real-world inputs and workload combinations

**Depends on.** All prior phases

### Required deliverables

- 500k regression suite.

- Parser fuzzing.

- Crash/fault injection.

- Concurrent playback/scan/analysis/conversion soak tests.

- Hotplug/device-loss stress.

- DB backup/recovery strategy.

- Performance budgets/regression tracking.

### Phase exit / definition of done

- No known mutation crash point silently corrupts user state.

- Malformed external data is handled safely.

- Playback stays within reliability budgets under background load.

- Performance regressions are measured before release.

## Phase 17 - Windows and mobile/sync readiness

**Objective.** Expand platforms only after Linux/macOS validate the architecture

**Depends on.** Phase 16

### Required deliverables

- WASAPI backend.

- Windows native frontend.

- Mobile storage/audio/lifecycle adapters.

- Formal cross-device synchronization design.

- Optional metadata/library-state sync separate from file transfer.

### Phase exit / definition of done

- New backends fit existing liborca contracts.

- No core entity assumes a desktop path or GUI.

- Sync uses stable logical identity rather than path names.

# 21. Full-product completion criteria

The first full implementation of the planned Orca vision is complete when all of the following are true.

| **Area**           | **Plan**                                                                                                                                                                                           |
|--------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Core/library**   | Multiple independent libraries, 500k-scale browsing/search, incremental scanning, playlists/history/ratings, stable identity, and robust external-change reconciliation are production-ready.      |
| **Playback**       | Gapless playback, queue/transport, direct/bit-perfect path, processed path, device selection, native output, latency policies/reporting, and device-loss recovery are reliable on Linux and macOS. |
| **DSP**            | Curated Player/Zone DSP chains, EQ, gain/ReplayGain, resampling, signal-path inspection, precision/latency metadata, and tested SIMD optimizations are available.                                  |
| **Maintenance**    | Canonical metadata, provenance, batch editing, tag writing, artwork operations, rename/move/organize, mutation preview, history, recovery, and undo are production-ready.                          |
| **Analysis**       | Loudness, waveform, clipping/silence, fingerprints, duplicate assistance, and Library Health operate incrementally from versioned caches.                                                          |
| **Identification** | MusicBrainz/AcoustID-style assisted identification and metadata proposals work without overriding user authority.                                                                                  |
| **Conversion**     | Common target formats can be converted safely with controlled transforms and metadata preservation.                                                                                                |
| **Multi-zone**     | Core supports independent Players and genuinely synchronized multi-Zone playback with drift correction.                                                                                            |
| **Ripping**        | Secure/verified CD ripping produces trustworthy logs and feeds the normal library/encoding/metadata workflow.                                                                                      |
| **Native apps**    | Linux and macOS frontends are native, performant, accessible, virtualized for huge libraries, and integrate with OS media controls.                                                                |
| **Reliability**    | Crash recovery, malformed input, large-library performance, concurrent workloads, and hotplug/device-loss scenarios have automated regression coverage.                                            |

# 22. Deferred and future work

| **Item**                      | **Status** | **Decision**                                                                                                                                                |
|-------------------------------|------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Streaming services            | Deferred   | Do not build until local playback/library architecture is mature. Future sources use service-backed playable-source adapters.                               |
| Cross-device sync             | Open       | Desired for metadata/playlists/history and optionally files; exact protocol/conflict semantics require separate design after local history/identity mature. |
| Arbitrary DSP graph           | Deferred   | Ordered chains are sufficient for first-party Orca. Branching/mix graphs may be revisited later.                                                            |
| Plugin host                   | Deferred   | First-party Orca remains curated. liborca is the primary extensibility path.                                                                                |
| First-party server            | Deferred   | Headless liborca is supported; a server application is optional future product work.                                                                        |
| Native codec rewrites         | Deferred   | Replace focused dependencies only after the application is broadly complete and conformance tests exist.                                                    |
| Native resampler              | Deferred   | Potential advanced Zig/SIMD project after mature reference behavior is established.                                                                         |
| Classical work/movement model | Open       | Schema remains extensible; deepen once real collection workflows require it.                                                                                |

# 23. Risks and architectural guardrails

## 23.1 Major project risks

| **Area**                | **Plan**                                                                                                                                                      |
|-------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Scope expansion**     | Orca spans player, library manager, tagger, analyzer, converter, ripping tool, and provider client. Control scope through strict phase gates/vertical slices. |
| **Audio complexity**    | Low latency, bit-perfect playback, DSP, device negotiation, and multi-zone timing interact. Keep timing/latency explicit and test backends independently.     |
| **Mutation safety**     | Filesystem and SQLite cannot share one atomic transaction. The journal/recovery model is mandatory.                                                           |
| **Metadata complexity** | File tags, provider data, user preference, release identity, and duplicate encodes conflict. Keep layers/provenance separate.                                 |
| **Performance**         | 500k tracks punishes full materialization and accidental O(n) work. Performance fixtures must exist early.                                                    |
| **Dependency leakage**  | External library models can silently take over the architecture. Convert at adapter boundaries.                                                               |
| **Platform divergence** | Native apps may tempt duplicate semantics. Treat CLI and second frontend as architectural tests of liborca.                                                   |

## 23.2 Review guardrails

1. Reject any feature whose only implementation lives in a GUI when it belongs in liborca.
2. Reject any hot-path audio change that introduces unbounded work or uncertain blocking into RT execution.
3. Reject any file-writing feature without a MutationPlan, recovery semantics, and explicit user intent.
4. Reject any query/UI design that assumes the entire 500k-track library is materialized in memory.
5. Reject dependency integrations that expose foreign types across the rest of liborca.
6. Reject a bit-perfect claim unless the active signal path can prove no sample-changing processing occurred.
7. Reject literal zero-latency claims; report achievable measured/estimated latency and timing limits.
8. Reject multi-zone designs that assume nominal sample rates imply identical physical clocks.
9. Reject future sync designs that use paths as logical identity.

**End of Orca Full Implementation Plan v1.0**
