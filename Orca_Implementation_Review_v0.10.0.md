# Orca v0.10.0 Implementation Review

| Item | Value |
|---|---|
| Review target | `6d555d5` (`v0.10.0`) |
| Plan | `Orca_Full_Implementation_Plan_v1.0.md` |
| Reviewed scope | Phases 0–12, release notes, and commit history |
| Review date | August 21, 2026 |

## Executive verdict

Orca is **on the right track architecturally, but not in its current implementation and phase-gate discipline**.

The plan is unusually good: its ownership boundaries, stable-identity model, real-time rules, mutation guardrails, bounded-work requirements, and insistence on vertical slices are appropriate for this product. The repository also contains a substantial set of promising components: generational handles, typed SQLite repositories, codec adapters, bounded audio queues, a small PipeWire callback, mutation-journal primitives, provider adapters, and focused tests.

The central problem is that many releases declare a phase complete when the repository contains an interface, state model, or isolated unit test—not when the feature works through the authoritative runtime and frontend path. Several critical paths have parallel implementations that never meet:

```text
Runtime Player/Zone state ────────X──────── Native output playback
Job state model ─────────────────X──────── Scanner/analysis/network work
DSP/latency models ──────────────X──────── Live render path
Library rows/UI transport ───────X──────── Playable source selection
Fingerprint results ─────────────X──────── Indexed duplicate health state
Scrobble queue helpers ──────────X──────── Player events/runtime worker
```

This is not a reason to restart the project. Much of the component code is reusable. It is a reason to **stop before Phase 13, reopen the failed gates, and build one real end-to-end ownership path**. In its current state, Orca should be treated as a pre-alpha architecture prototype rather than a Phase-12-complete product.

## What is working well

- The plan's architectural laws and review guardrails correctly identify the project's hardest risks.
- PipeWire C types are contained behind a narrow shim, and codec-specific types are generally kept behind Orca-owned interfaces.
- The audio callback is small, bounded, allocation-free by inspection, and safely emits silence on underrun.
- SQLite migrations and repositories are explicit and testable; writes generally pass through a shared per-library lane.
- Public library and health queries are bounded, and callback-scoped C string lifetimes are stated.
- The CLI has a real registered-codec-to-PipeWire blocking playback path, even though it is not the runtime-owned path described by the architecture.
- File mutation follows a promising stage/backup/journal shape in the normal case.
- Provider responses remain proposals, locked values are respected by the normal acceptance path, and secrets are kept behind a credential capability.
- The configured build and tests pass, formatting is clean, and the release-mode SIMD gain benchmark is positive on this host.

These strengths make an integration-focused correction practical.

## Highest-priority findings

### P0 — Shutdown discards work registrations instead of draining workers

The Phase 1 exit criterion requires in-flight work to be safely cancelled and drained. [`Registry.drain`](liborca/core/work.zig#L45-L47) only invalidates every registration. [`OrcaRuntime.shutdown`](liborca/core/runtime.zig#L67-L94) then immediately destroys Zones, Players, and Library databases.

A worker can therefore register, begin using an owned object, receive a cancellation request, and still be executing when shutdown destroys that object. Once real workers are connected, this is a use-after-free/database-close race. The existing test proves only that a handle becomes stale, not that work has stopped.

**Required direction:** make a work registration represent live worker ownership; request cancellation, join/wait for completion acknowledgements, and only then destroy dependent objects. Add a test with a genuinely blocked worker proving shutdown cannot return early.

### P0 — Paths are the real identity, and scans never reconcile removals or moves

The plan's foundational rule says musical/file identity must not be a filesystem path. The schema initially creates `files` and `locations`, but scanning and all later metadata/analysis/provider work use a disconnected path-keyed model:

- [`observed_files.path` is the primary key](liborca/database/migrations.zig#L83-L92).
- [Observed metadata](liborca/database/migrations.zig#L95-L103) and [Orca metadata/locks](liborca/database/migrations.zig#L105-L116) are keyed by that path.
- Analysis, health, and proposals continue the same pattern.
- [`Scanner.scan`](liborca/library/scanner.zig#L59-L133) only upserts encountered files. It has no root membership, scan generation, or successful-scan sweep for missing entries.

Concrete result: scan `a.flac`, attach user metadata, rename it to `b.flac`, and rescan. The database retains stale `a.flac`, inserts `b.flac`, and leaves the user metadata and locks on the old path. Deletion has the same stale-row problem. The `library_roots` table is currently unused.

This blocks reliable scanning, mutation, provider acceptance, duplicate tracking, future sync, and managed-library operations.

**Required direction:** make `File`/`Location` IDs authoritative, associate observations with a persisted root, record device-scoped stable storage identity, and reconcile unseen locations only after a successful scan. Moves should update a Location while preserving File-attached metadata.

### P0 — The runtime-owned audio engine and the working playback path are separate systems

Runtime Players and Zones mostly hold state. [`createPlayer`/`createZone`](liborca/core/runtime.zig#L160-L197) allocate objects, and Zone attachment/recovery methods mutate flags, but no runtime Zone owns a device or `OutputSession` and no runtime API loads a playable source.

Actual playback instead constructs a stack-local Player, pool, pipe, render context, backend, and output session in [`playFileBlocking`](liborca/audio/backends/pipewire_playback.zig#L26-L136). The CLI calls this path directly. Runtime transport, Zone attachment, DSP chains, and the C ABI are not part of it.

Consequences:

- Multiple runtime Players/Zones do not produce multiple output pipelines.
- Zone failure isolation is a state-model test, not an output behavior.
- The C ABI and native apps create empty Players that can report `playing` without a source or output.
- Phase 7 cannot serve as the foundation for Phase 14 synchronization.

**Required direction:** choose one object graph. Runtime Player must own queue/source sessions and Player processing; runtime Zone must own its private render path, DSP, selected device, and output recovery. CLI, C ABI, GTK, and Swift should all drive that same graph.

### P0 — Mutation approval is not immutable

[`Plan.init`](liborca/metadata/mutation.zig#L52-L65) borrows caller-owned action, path, change, and value slices. Approval checks only the numeric plan ID in [`Plan.approve`](liborca/metadata/mutation.zig#L80-L89).

A caller can preview and approve a plan, mutate the aliased action memory, then execute different paths or values under the approved ID. `[]const` prevents mutation through the Plan's view; it does not prevent mutation through another alias. This directly contradicts the changelog's “immutable mutation previews” claim.

**Required direction:** deep-copy a canonical plan into plan-owned/persisted storage before preview, seal it, and approve a content digest/revision rather than only an ID.

### P0 — Mutation recovery is neither startup recovery nor power-loss-safe

There are good per-operation recovery primitives, but the product-level guarantee is incomplete:

1. [`LibraryDatabase.open`](liborca/database/library.zig#L22-L46) never enumerates nonterminal journal records or invokes [`recoverOperation`](liborca/metadata/executor.zig#L247-L304). Recovery currently runs only when tests call it directly.
2. Tag staging validates source identity before copying, but [`commitReplacement`](liborca/metadata/file_mutation.zig#L150-L161) does not revalidate immediately before renaming. An external edit between staging and commit can be silently replaced.
3. Files are synced, but parent directories are not fsynced after stage creation or rename boundaries. A power loss can therefore leave namespace state inconsistent with the committed SQLite journal.
4. Recovery can mark an operation rolled back when source and backup are both missing because [`finishRecoveryState`](liborca/metadata/executor.zig#L299-L327) does not first prove that the original source has been restored.
5. “Identity” is only size and mtime ([`FileIdentity`](liborca/metadata/mutation.zig#L4-L7)), so same-size edits with a preserved timestamp evade conflict checks.

This subsystem modifies user-owned assets; normal-case tests are not enough.

**Required direction:** run journal recovery before a Library becomes available, add crash/fault injection at every database/filesystem boundary, fsync containing directories, revalidate a stronger identity at the rename boundary, and enter reconciliation whenever the exact original/after-state cannot be proven.

## Other high-impact findings

### P1 — Pause does not pause rendered audio, and seek has a publication race

[`Player.pause`](liborca/audio/player.zig#L115-L126) only changes an atomic state. [`RenderContext.callback`](liborca/audio/backends/pipewire.zig#L173-L194) never reads that state, so queued audio continues to render while the Player reports paused.

Seek mutates decoder state, stores the new position, and only then increments generation ([`Player.seek`](liborca/audio/player.zig#L129-L133)). A callback can render an old-generation block between those operations and increment the newly stored position. A concurrent producer can also be inside decoder state while seek mutates it.

**Required direction:** publish transport/discontinuity commands at a render boundary, serialize decoder seek against production, tag timeline position by generation, and make pause emit silence without consuming queued timeline data.

### P1 — “Interactive” and robust playback use the same buffered strategy

Production playback always primes eight 1024-frame blocks ([constants and prime loop](liborca/audio/backends/pipewire_playback.zig#L12-L13), [initial prime](liborca/audio/backends/pipewire_playback.zig#L50-L63), [refill](liborca/audio/backends/pipewire_playback.zig#L118-L122)). Policy changes only the requested PipeWire node latency. The one-block interactive `ZoneSink` budget is not used by production playback.

The latency report then passes zero render-ahead and zero DSP latency ([report construction](liborca/audio/backends/pipewire_playback.zig#L130-L135)), despite those queued blocks.

**Required direction:** implement distinct, Zone-owned render strategies and derive latency from the live queue, active DSP chain, negotiated backend, and device timing.

### P1 — DSP, resampling, and signal-path reporting are isolated models

`PublishedChain`, the resampler, signal-path inspector, crossfade, and Player/Zone fanout have useful unit tests, but repository references show that the production playback function invokes none of them. The docs describe an integrated graph that does not exist in the live path.

The current signal-path inspector is correctly conservative in isolation, but it cannot report the active negotiated path because playback does not construct a report from live nodes/backend format. Every decoder and PipeWire output also canonicalizes to float32, so there is no native integer bit-perfect route today.

**Required direction:** integrate prepared chains and resampling into the authoritative Player/Zone graph, reset them on discontinuity, and produce the report from actual negotiated state—not a separately instantiated model.

### P1 — Jobs are state records, not executions

[`start_job`](liborca/core/runtime.zig#L324-L336) creates and starts a Job record but dispatches no work. Scanning is a synchronous CLI call with a separate cancellation token; analysis is another direct synchronous service; provider and scrobble helpers have no runtime executor.

This means cancellation, progress, priority, shutdown, and background-work isolation are not end-to-end properties. Calling `Thread.yield()` between analysis chunks ([analysis service](liborca/analysis/service.zig#L108-L120)) does not prove that analysis cannot starve playback under concurrent CPU and I/O load.

**Required direction:** add bounded runtime-owned executors, connect Job kinds to concrete operations, map cancellation/progress to those operations, and drain the executors during shutdown.

### P1 — The C ABI has no concurrency/lifetime contract or guard

[`orca_runtime_destroy`](liborca/c_api.zig#L63-L67) immediately deinitializes and frees the runtime. Query callbacks execute while pages and runtime objects remain live ([track query](liborca/c_api.zig#L101-L136)). The header describes string lifetime but does not define call serialization, reentrancy, concurrent destroy, or callback teardown rules ([public declarations](liborca/orca.h#L52-L124)).

A query racing runtime/library destruction, or a callback closing its own Library, can invalidate state still in use. This matters for GUI timers, OS media callbacks, and future worker completions.

**Required direction:** define the ABI threading contract and enforce it with a serialized call gate or in-flight guards/shutdown barriers. Either forbid reentrant teardown explicitly and detect it, or return independently owned result objects before invoking foreign code.

### P1 — Native frontend transport is presentation-only

The track ABI exposes title/album/artist but no playable source identity ([`TrackView`](liborca/c_api.zig#L34-L39)). GTK discards even the track ID while building strings ([callback](apps/linux/main.c#L25-L34)), has no row-activation playback action, and toggles an empty Player ([transport](apps/linux/main.c#L165-L169)). Swift behaves the same way ([track rows and playback](apps/macos/Sources/OrcaApp/main.swift#L8-L29), [toggle](apps/macos/Sources/OrcaApp/main.swift#L103-L123)).

MPRIS advertises methods but Next/Previous are accepted without behavior, metadata is empty, and position is always zero ([MPRIS methods/properties](apps/linux/mpris.c#L57-L124)). macOS Now Playing publishes the title “Orca” rather than a track.

The C smoke test actually codifies the wrong semantic by asserting that an empty Player can transition to `playing` ([test](tests/c_abi_smoke.c#L30-L37)).

**Required direction:** expose stable track/playable-source selection and queue operations, reject Play without a playable source/output, implement one GTK row-to-audio vertical slice, and then mirror real queue/track/capability state to MPRIS and Now Playing.

### P1 — Scrobbling is neither connected nor exactly idempotent

No Player event calls `enqueueEligible`, and no runtime-owned worker calls `dispatchReady`; references outside tests are absent. Even if connected, [`ready`](liborca/database/repository.zig#L870-L906) reads pending rows without claiming/leasing them, so concurrent dispatchers can submit the same event. A crash after remote acceptance but before [`markSucceeded`](liborca/providers/scrobble.zig#L62-L71) also causes a retry.

The database uniqueness key makes local enqueue idempotent, but delivery remains at-least-once unless a provider honors an idempotency key. The release notes should not imply stronger semantics.

**Required direction:** derive events from authoritative playback sessions, atomically lease queue rows, recover expired leases, serialize per-service dispatch, use provider idempotency support where available, and document unavoidable at-least-once behavior.

## Medium-priority correctness and scale findings

### P2 — Duplicate analysis is O(n²) and not persisted as queryable relationships

[`findDuplicates`](liborca/analysis/fingerprint.zig#L212-L235) compares every candidate pair in memory. Fingerprints/hashes are stored inside opaque per-path result blobs rather than indexed columns, and nothing automatically feeds duplicate facts into health evaluation.

At the 500,000-track target, all-pairs comparison is infeasible.

**Required direction:** persist normalized exact-file and decoded-audio hashes in indexed columns, bucket likely candidates, update duplicate relationships incrementally, and publish them into indexed health state.

### P2 — Loudness is only a partial EBU-style implementation

The analyzer has no channel-layout input and averages every channel equally ([energy accumulation](liborca/analysis/diagnostics.zig#L123-L160)). It therefore cannot exclude LFE or apply BS.1770 surround-channel weighting. It reports sample peak, not true peak.

This may be acceptable as an explicitly versioned stereo prototype, but it is not general EBU R128/ReplayGain evidence.

**Required direction:** carry channel layout through decoding/analysis, apply BS.1770 weights and LFE exclusion, validate against published conformance vectors, add true-peak analysis if claimed, and bump the cached algorithm version.

### P2 — Provider proposals are bound to path and caller-supplied payload

Proposal acceptance parses the caller's in-memory payload and passes independently constructed values to the repository ([workflow acceptance](liborca/providers/workflow.zig#L56-L90)). The transaction checks that the ID/path is pending but never loads or compares the persisted payload ([repository acceptance](liborca/database/repository.zig#L1018-L1059)). Proposals also contain no source identity/revision.

A stale or modified in-memory proposal can mark one row accepted while applying different metadata; a file replaced at the same path can receive an old proposal.

**Required direction:** load and parse the durable proposal inside the acceptance transaction (or verify a payload hash/revision), and reject acceptance when the current File/source identity differs from the proposal's identity.

### P2 — HTTP requests are bounded by bytes, not time

The central gateway has response-size bounds and retries, but [`Request`](liborca/network/client.zig#L10-L17) has no deadline or cancellation capability. The standard transport does not configure connect/read/overall timeouts, response headers are discarded, and [`awaitRateLimit`](liborca/network/client.zig#L114-L123) holds a spin mutex while sleeping. `Retry-After` therefore cannot be honored.

**Required direction:** add deadlines/cancellation to the transport, preserve relevant headers, honor bounded `Retry-After`, and use a queued per-service limiter that does not spin while another caller sleeps.

### P2 — The 500k benchmark is a harness, not a passed performance gate

The default benchmark is in-memory, sets open time to zero unless a path is explicitly supplied, uses identical synthetic rows, and measures one offset-zero FTS query ([benchmark](benchmarks/main.zig#L7-L50)). There are no performance budgets or representative deep browse/filter/concurrent workloads.

**Required direction:** add a durable generated corpus, cold/warm reopen, representative varied searches, indexed sorting/filtering, deep pagination strategy, concurrent read/write workload, and recorded regression budgets.

## Phase-gate assessment

| Phase | Assessment | Main reason |
|---|---|---|
| 0 — scaffolding | **Meets** | Unified build/test graph and foreign linking boundary exist. |
| 1 — runtime/ownership | **Does not meet** | Shutdown invalidates registrations without waiting for live work. |
| 2 — control plane/Jobs | **Partial** | Bounded command/event and Job state models exist; Jobs execute nothing. |
| 3 — SQLite/500k | **Partial** | Repositories, migrations, FTS, and transaction tests exist; the scale gate lacks representative durable evidence. |
| 4 — scanner/observed state | **Does not meet** | Roots are unused; deletions/moves are never reconciled; path is identity; cancellation is not a runtime Job. |
| 5 — native WAV output | **Partial** | A real blocking PipeWire path exists; latency and direct/buffered architecture are not accurate/integrated. |
| 6 — codecs/gapless prep | **Partial** | Registered codecs share decoder components; next-source preparation is an isolated same-format test, not a public playback path. |
| 7 — Player/Zone engine | **Does not meet** | Runtime ownership, production output, direct/buffered policy, multi-Zone recovery, and transport are disconnected. |
| 8 — DSP/signal path | **Does not meet** | Components and tests exist, but they are absent from production rendering and live latency/path reporting. |
| 9 — safe mutation | **Does not meet** | Approval is mutable; startup recovery is absent; commit has TOCTOU and durability gaps. |
| 10 — native frontends | **Does not meet** | Frontends cannot select/play a track; desktop controls mirror an empty state-only Player; macOS is uncompiled. |
| 11 — analysis/health | **Partial** | Versioned analysis and bounded health queries work; scheduling and scalable duplicate integration do not. |
| 12 — providers/scrobbling | **Partial** | Provider adapters/cache/proposals exist; runtime orchestration, source binding, and scrobble delivery semantics are incomplete. |

## Commit and release-history review

The early history generally uses clear conventional subjects and several good bodies that state intent, boundaries, and verification. Commit scope is mostly coherent.

However:

- The entire history from adding the plan (`11:49`) to tagging `v0.10.0` (`16:43`) spans about 4 hours 54 minutes. Speed is not itself a defect, but the resulting evidence shows the tags function as component checkpoints rather than validated phase completions.
- Of 70 non-release implementation/scaffold commits, 25 have no body. These are concentrated across the Phase 7/8 audio and DSP work and early mutation work—the areas where invariant and integration evidence matters most.
- `CHANGELOG.md` omits releases `0.3.0` through `0.6.0` entirely.
- Several release-note statements are contradicted by the implementation:
  - `0.7.0` says previews are immutable and startup recovery exists.
  - `0.8.0` calls MPRIS verified even though it controls an empty Player and publishes no track.
  - `0.9.0` says scheduler yields keep analysis subordinate to playback without a shared scheduler or workload test.
  - `0.10.0` describes an idempotent scrobble queue without distinguishing local enqueue idempotency from at-least-once remote delivery.

Future phase/release commits should include:

1. the specific plan exit criteria being closed;
2. the production entry point that exercises the feature;
3. the ownership/concurrency/durability invariant established;
4. the scenario or fault test proving it; and
5. explicit limitations that remain out of scope.

## Recommended recovery sequence

1. **Pause Phase 13 and new release tags.** Treat the current modules as prototypes until their owning vertical slices pass.
2. **Repair runtime lifetime first.** Add real executors, worker registration/join, atomic command acceptance during shutdown, and Job-backed scanner/analysis/network operations.
3. **Repair library identity before more metadata work.** Connect scanner observations to File/Location/root IDs, implement deletion/move reconciliation, and migrate path-keyed metadata/analysis/proposals.
4. **Unify audio ownership.** Move the working CLI playback resources into runtime Player/Zone ownership; then make pause, seek, queueing, policies, recovery, timing, and multi-Zone behavior real there.
5. **Requalify mutation safety.** Make plans immutable, add startup recovery and directory durability, strengthen identity, and run crash injection across every operation boundary.
6. **Prove one frontend vertical slice.** Select a stable track ID in GTK, load it through the ABI, render through a runtime Zone, pause/resume/seek it, and expose the real track/position/capabilities over MPRIS. Compile and run the same contract on macOS before calling Phase 10 closed.
7. **Integrate derived systems.** Run analysis as Jobs, persist indexed duplicate relations, generate health state automatically, and connect provider/scrobble workers to authoritative File and Player events.
8. **Replace milestone assertions with evidence.** Add durable 500k budgets, concurrent shutdown/ABI tests, fake-backend audio integration tests, mutation fault injection, provider timeout/lease tests, and platform CI.

## Verification performed during this review

- `zig fmt --check liborca apps benchmarks tests build.zig` — passed.
- `zig build test --summary all` — all configured unit, integration, platform-linking, and C ABI smoke steps passed.
- `zig build -Doptimize=ReleaseFast dsp-bench -- 100` — passed output equality; scalar 143 ps/sample, vector 39 ps/sample, 3.66× on this host.
- `zig build bench -- 1000` — completed; insert 9 ms, reported open 0 ms, search 0 ms. This was the default in-memory path and is not evidence for the 500k durable phase gate.

Not independently verified in this review: live audible PipeWire playback, device-loss recovery, a GTK interaction run, or any macOS build/run. The preceding implementation thread reports a live PipeWire smoke and explicitly reports that macOS was not compiled.

## Bottom line

Keep the architecture and most of the component work. Change the definition of progress: a subsystem is not complete until the same runtime-owned path is exercised by a real client and survives the failure modes named by the plan. The next best investment is not conversion; it is integration and requalification of Phases 1, 4, 7, 9, and 10.
