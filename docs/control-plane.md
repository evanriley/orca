# Control plane

This file covers how a host drives the runtime: the command and event lanes,
the pump and the waker, and the job system with its waiting queue, pausing,
history and idle maintenance.

Hosts submit typed commands through a fixed-capacity (256), thread-safe queue.
The runtime's single logical control lane processes them and emits request-ID
correlated completion events. A host drives that lane with `processNextCommand`
or, in its event loop, with `pump`.

Completion events are lossless and bounded: when their channel fills, command
processing applies backpressure rather than mutating state without delivering a
completion. High-frequency telemetry uses a separate bounded channel (256
entries) that coalesces unread Player-position, Job-progress and
Library-changed hints by stable handle. Authoritative consumers query
snapshots instead of reconstructing state from events.

## Waking the host

A host sleeps in its own event loop and pumps only when liborca has something
for it. `Runtime.setWaker` installs a `HostWaker`
(`orca_runtime_set_wake_callback` in the C ABI). `Runtime.pump`
(`orca_runtime_pump`) runs these steps in order:

1. Execute the submitted commands, at most the command queue's capacity.
2. Join finished job workers and publish their progress.
3. Start the waiting host jobs whose turn has come.
4. Take what watchers reported and start their reconciles.
5. Start a due maintenance unit.
6. Save the Players whose resume state is due
   ([api.md](api.md#surface), `playerSaveState`).

`Runtime.nextPumpTimeoutMs` (`orca_runtime_pump_timeout`) says how long the
host may sleep. A host's loop pumps, drains events and telemetry, reads the
snapshots it shows, reads the timeout, then sleeps until the waker fires or the
timeout passes: 0 means pump again at once, null (`ORCA_PUMP_NO_TIMEOUT`) means
wait for the waker alone.

The waker is edge-triggered. The runtime holds one `pending` flag
(`control.HostSignal`): the first change after a pump sets it and calls the
waker, later changes find it set, and `processNextCommand` clears it before it
reads anything. The waker is called at most once between two pumps, though a
call raised just before a pump can still be running on one thread when one
raised just after it starts on another. Each producer publishes its change
before raising the flag, and the clear is a read-modify-write, so everything
raised before the clear is visible to the host's reads after it. A host whose
wake primitive does not count wakes reads the timeout immediately before
sleeping: a flag still set reads as 0, so a wake that arrived during the pump
is not lost.

These wake the host:

- `submit`, on the caller's thread, once the command is queued;
- a Player's engine, after it publishes a position hint, a Zone output state
  that differs from the previous one, or the end of its queue
  (`playerDrained` turning true);
- a job worker, after `finish`, so the next pump reaps it and publishes
  `job_finished`;
- an artwork loader or a browse loader, after it queues a result (a cancelled
  browse request queues nothing and wakes nobody);
- a Library's watcher, after it publishes changed directories, an unavailable
  root or the watch limit, and when it stops on an error;
- a listen worker, after it records or drops a listen, and after it publishes a
  scrobbler status that differs from the last.

These do not: a completion or `job_finished` event published during the host's
own pump, and anything the host changed itself with a direct call. The render
callback never raises the flag, and neither does the PipeWire backend: an
output state change wakes the engine, whose next pass publishes the Zone state
and raises it.

### Pump timeout

The timeout is 0 while the flag is set or the command, event or telemetry queue
holds anything. Otherwise it is the soonest of:

- For a playing Player bound to a Library, the remainder of one second since the
  last listen sample (0 before the first). Position hints normally wake the
  host sooner; the timeout covers a stalled output. Every pump samples listens
  at most every 100 ms. A paused Player needs nothing.
- While a job worker runs, `job_progress_interval_ms` (100 ms). Each pump
  publishes `job_progress` for every host Job whose units or state moved. A
  finished worker not yet reaped, or commands left queued by event
  backpressure, make it 0.
- 0 for a waiting Job that could start now or that the host cancelled. A Job
  behind a running worker waits on that worker's timeout; one held by
  `pauseAll` waits for `resumeAll`.
- 0 for published watcher changes, or waiting changes that could start a
  reconcile now. Changes held by a running job of their Library wait on that
  job's timeout.
- For a Library with idle maintenance enabled, what remains until its next unit
  is due, or 0 once due. A host job waiting behind a unit makes it 0 once the
  unit's worker has been joined.
- For a Player with resume state to save, what remains of the 30 second save
  interval, or 0 when a finished long Track waits to be forgotten.

A waker is read by worker threads without a lock, so `setWaker` is refused with
`error.WorkersRunning` (`ORCA_STATUS_INVALID_STATE`) once any worker thread
exists: a Player's engine, a job, a listen worker, an artwork loader, a browse
loader or a Library's watcher. Every such thread registers with `work.Registry`
before it is spawned, so the registry's count is the test. Hosts install the
waker right after creating the runtime. The waker is never called after
`shutdown` or `deinit` returns, because the registry's drain joins every thread
that raises it and `submit` refuses a runtime that is not running.

## Jobs

Jobs share one state, progress and cancellation representation across the
scanner, the projection, the property backfill, the library-wide analysis,
duplicate detection, consistency checks, metadata lookup, AcoustID submission,
tag write-back, and the lyrics, artist-info and release-info fetches. The C ABI
names the kinds `ORCA_JOB_KIND_*` (`orca.h`). The serialized control lane owns
job state; the worker publishes counters through atomics and is joined through
`work.Registry` before its terminal state is recorded and its lossless
`job_finished` completion is published.

A job worker's cancellation is requested in two places at once: the registry
flag, which shutdown observes, and the cooperative token the worker polls (a
scanner polls a `CancellationToken` deep inside a filesystem walk). Every path
that drains workers sets both before it blocks: shutdown, `destroyLibrary` and
Player destroy. A Library's listen worker has only the registry flag, which is
also its network gateway's cancel pointer, so a drain interrupts an in-flight
ListenBrainz request or rate-limit hold and wakes the worker from its sleep. A
Player engine and a Library's artwork and browse loaders sleep without a
timeout while idle, so each gives its registration a waker, set before its
thread starts, which the first cancellation request calls. The browse loader's
waker also interrupts the query on its read-only connection, which closes only
after the drain has joined the thread.

Progress with no honest denominator is a count, never a fraction. The property
backfill and the library-wide analysis count the rows that still owe work with
one indexed query before they start and report that total. A scan or reconcile
first counts the files its walk will reach, opening none, and reports that
count as its total from then on; a file added during the walk raises the total,
and a finished walk replaces it with the files it saw, so a succeeded scan ends
at 100%.

Cancellation is an ordinary way to end a job. The library-wide analysis polls
its token inside a decode, commits the batch already measured, and a later run
selects only what is left
([analysis.md](analysis.md#what-already-analyzed-means)).

### One Job per Library, and the waiting queue

A Library runs one host Job at a time. Lyrics, artist-info and per-Release
info fetches answer a page the host is showing, so they never wait and take no
slot; every other host Job holds its Library's slot from start until the pump
reaps it. A Job started while the slot is held, while an earlier Job of the
same Library waits, or while the Library is paused is created in state
`waiting` and appended to the runtime's waiting queue, `max_waiting_jobs` (32)
entries for all Libraries together. The 33rd is refused with
`error.JobQueueFull` (`ORCA_STATUS_BUSY`) and nothing is created.

The pump starts waiting Jobs after it has reaped finished workers, oldest
first, each once its Library's slot is free and no earlier entry of the same
Library waits. `cancelJob` on a waiting Job moves it to `cancelling`; the next
pump finishes it `cancelled` with one `job_finished`, even while its Library is
paused. `destroyLibrary` drops its Library's waiting Jobs and `shutdown` drops
all of them, finishing each `cancelled` without an event.
`jobQueuePage(library)` lists the Job holding the slot and then the waiting
ones, each naming the Job it waits `after`.

### Pausing

`pauseJob` holds a running Job at its worker's next cancellation poll
(`CancellationToken.checkpoint` sleeps in 50 ms steps while the token is paused
and not cancelled); `resumeJob` lets it carry on. The Job keeps its thread and
its slot, so nothing else can start in its Library. It pauses between provider
requests, and a request holds its service's lease only while it runs.

A projection, a tag write, a lyrics fetch and an artist-info fetch never poll,
so they are not pausable (`error.JobNotPausable`). A release-info fetch is
pausable only when it fills missing genres. A finished Job returns
`error.JobAlreadyFinished`.

`pauseAll(library)` pauses every pausable Job running in the Library, marks its
waiting Jobs `paused` in their snapshots, and holds the Library: Jobs started
later wait, the pump starts none of them, the watcher's reconciles stay held
back and idle maintenance skips it. `resumeAll` undoes all of that, and
`libraryJobsPaused` reports the flag.

Cancel wakes a paused Job within one poll. Every path that cancels sets the
token (`cancelJob`, `shutdown` and `destroyLibrary` directly, any other
cancellation request through the registration's waker,
`JobWorker.wakeFromPause`), so shutdown completes with paused and waiting Jobs
present: each paused worker returns from its checkpoint within 50 ms, and the
waiting Jobs, which own no thread, are dropped after the drain.

### Progress, ETA and current item

`jobSnapshotSynced` fills in what the control lane does not own.
`completed_units` come from the worker's atomic counters. `started_at` is the
wall-clock second the Job left `queued` or `waiting` for `running`.
`estimated_remaining_ms` is a rolling rate over the last 10 s of
`completed_units`, sampled on the monotonic clock at most every 500 ms; it is
null until 10 s of progress has been sampled, while paused, and for a Job with
no total. `current_item` is the path or title the worker is on, and `detail`
names a constraint shown beside it, such as "14 threads" or "rate-limited to 1
request a second".

### History

When a host Job holding a slot finishes, the control lane writes one row to the
Library's `job_history` table: kind, the request as JSON, start and finish
times, state, units, an error text, the undo group of a tag write and a summary.
A waiting Job that never ran gets a row too, with its state as the error text.
Rows past the newest 1,000 are pruned. [database.md](database.md) describes the
table. A worker's terminal state is recorded only after `work.Registry` has
joined its thread, so history never races a worker's last write.

`jobHistoryPage(library, filter, limit, offset)` reads rows newest first.
`jobRetry(library, history_id)` re-submits the stored request of a Job that did
not succeed through the same start function, which may queue it. It fails with
`error.JobNotRetryable` for a succeeded Job and for a request that is not
stored: a tag write is an approved plan, undone through its undo group. Jobs
that take no slot have no history row.

## Idle maintenance

`libraryMaintenance(library, MaintenanceOptions)` makes the pump verify a
Library's recording IDs a unit at a time while the process is otherwise idle
(`liborca/core/runtime_maintenance.zig`). A unit is a `metadata_lookup` job in
verify mode with origin `maintenance` (`jobOrigin`): one Release with a file to
verify, after the last one a unit took and wrapping to the first, or, once no
Release is left, at most 20 Tracks on no Release. Findings land in Health as
`recording_mismatch`. There is no scheduler thread: the record lives on the
Library, and the pump reads the runtime's sampling clock to decide when the
next unit is due.

A due Library starts a unit only when every check passes, in this order; any
other outcome puts it off one whole interval:

1. A client identity is set (`blocked = client_identity_required`).
2. AcoustID is in scope: an application key is set (`acoustid_required`).
3. Every Player is idle: stopped, paused, or with its queue played out. No
   other job runs, and no host job waits.
4. Neither AcoustID nor MusicBrainz has a block recorded in the Library
   (`provider_busy`), so a unit never sleeps through a backoff in its worker.
5. Something is left to verify. Otherwise the cursor goes back to the first
   Release.

At most one unit runs in the process. Each unit ends, however it ends,
`interval_ms` (default 5 minutes) before the next one is due. A unit that fails
because another Orca process held a service's lease past the unit's wait is
reported `provider_busy`. Starting playback never cancels a running unit; it
only keeps the next one from starting.

A unit gives way to the host:

- `libraryJobRunning` ignores units, so they never refuse a scan or a tag
  write. `libraryRemoveRoot` cancels the Library's unit without waiting, then
  removes the root; a unit whose files are forgotten under it either committed
  first, and the deletion cascades, or fails its commit and rolls back.
- `startLibraryMatching`, `startReleaseCoverArtFetch` and
  `startAcoustIdSubmission` called while a unit runs cancel the unit and return
  the new job's handle at once, in state `waiting`, with origin `host`. The
  unit's worker releases its provider leases before it finishes; the pump joins
  it and publishes its `job_finished` (waiting while the event channel is
  full); only then does a later step start the waiting job's worker. Two
  workers never share a lease or write `provider_state` together, and the
  unit's `job_finished` arrives before any progress of the host job. A second
  such start while one waits is refused as it would be beside a running job, as
  is `libraryRemoveRoot` on its Library (`LibraryJobRunning`).
- A waiting host job is cancelled and dropped as any waiting Job is (see
  [the waiting queue](#one-job-per-library-and-the-waiting-queue)).
