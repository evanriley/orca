# Control plane

Hosts submit typed commands through a fixed-capacity, thread-safe queue. The
runtime's single logical control lane processes commands and emits request-ID
correlated completion events. A host may currently drive that lane with
`processNextCommand`; a dedicated executor can replace that pump without
changing the public command contract.

Completion events are lossless and bounded. When their channel fills, command
processing applies backpressure rather than mutating state without delivering a
completion. High-frequency telemetry uses a separate bounded channel that
coalesces unread Player-position, Job-progress and Library-changed hints by
stable handle.
Authoritative consumers query snapshots instead of reconstructing state from
events.

## Waking the host

A host sleeps in its own event loop and pumps only when liborca has something
for it, rather than on a timer. `Runtime.setWaker` installs a `HostWaker`
(`orca_runtime_set_wake_callback` in the C ABI); `Runtime.pump` executes the
submitted commands, joins finished jobs, starts a host job that waited for a
maintenance unit, starts the reconciles watchers asked for, then starts a due
maintenance unit; `Runtime.nextPumpTimeoutMs`
(`orca_runtime_pump_timeout`) says how long the host may sleep. A host's loop:

1. Pump, then drain events and telemetry and read the snapshots it shows.
2. Read the pump timeout.
3. Sleep until the waker fires or the timeout passes: 0 means pump again at
   once, null (`ORCA_PUMP_NO_TIMEOUT`) means wait for the waker alone.

The waker is edge-triggered. The runtime holds one `pending` flag
(`control.HostSignal`): the first change after a pump sets it and calls the
waker, later changes find it set, and the next pump clears it before it reads
anything. The waker is therefore called at most once between two pumps,
though a call raised just before a pump can still be running on one thread
when one raised just after it starts on another. The flag carries no data:
each producer publishes its change first, then raises the flag, and the pump
clears the flag with a read-modify-write, so everything raised before the
clear is visible to the host's reads after it. A change that
lands between the clear and the host's reads is seen at once and costs one
spurious wake later. A host whose wake primitive does not count wakes reads the
timeout immediately before sleeping: a flag still set reads as 0, so a wake
that arrived while the host was pumping is not lost.

These wake the host:

- `submit`, on the caller's thread, once the command is queued;
- a Player's engine, after it publishes a position hint, a Zone output state
  that differs from the one published before, or the end of its queue
  (`playerDrained` turning true);
- a job worker, after `finish`, so the next pump reaps it and publishes
  `job_finished`;
- an artwork loader, after it queues a result;
- a browse loader, after it queues a result; a request it skips because it was
  cancelled queues nothing and wakes nobody;
- a Library's watcher, after it publishes changed directories, an unavailable
  root or the watch limit, and when it stops on an error;
- a listen worker, after it records or drops a listen, and after it publishes a
  scrobbler status that differs from the last one it published. The periodic
  recheck of an idle worker changes nothing and wakes nobody.

These do not: a completion or `job_finished` event published during the host's
own pump, and anything the host changed itself with a direct call. The render
callback never raises the flag, and the PipeWire backend does not either: an
output state change wakes the engine, whose next pass publishes the Zone state
and raises it.

Some work needs a clock rather than an event, and the pump timeout covers it:

- While a Player bound to a Library is playing, every pump samples its
  listens at most every 100 ms. Its position hints already wake the host
  about that often, so the timeout is only a fallback for a stalled output:
  what remains of one second since the last sample, or 0 before the first.
  A paused Player needs nothing. A Player whose queue has played
  out still reports playing and counts until a sample has ended its listen.
- While a job worker runs, the timeout is `job_progress_interval_ms` (100 ms).
  Each pump publishes `job_progress` for every host Job whose units or state
  moved since the last one, so a host showing progress hears of it without
  polling. A finished worker not yet reaped, or commands left queued by event
  backpressure, make it 0.
- A waiting Job that could start now, or that the host cancelled, makes it 0.
  One behind a running worker waits on that worker's timeout; one held by
  `pauseAll` waits for the `resumeAll` that frees it.
- A watcher's published changes, or waiting changes that could start a
  reconcile now, make it 0. Changes held back by a running job of their
  Library wait on that job's timeout, and the pump that reaps the job starts
  their reconcile.
- A Library with idle maintenance enabled makes it what remains until its
  next unit is due, or 0 once it is due. While a unit runs, its worker's
  timeout covers it. A host job waiting behind a unit makes it 0 once the
  unit's worker has been joined.

A waker installed with `setWaker` is read by worker threads without a lock, so
it is refused with `error.WorkersRunning` (`ORCA_STATUS_INVALID_STATE`) once any
worker thread exists: a Player's engine, a job, a listen worker, an artwork
loader, a browse loader or a Library's watcher. Every such thread is registered with
`work.Registry` before it is spawned, so the registry's count is the test;
hosts install the waker right after creating the runtime. The waker is never called after `shutdown` or
`deinit` returns, because every thread that raises is joined by the registry's
drain, and `submit` refuses a runtime that is not running. A job worker raises
after `finish`; the pump joins its thread, rather than only waiting for
`finish`, before freeing it.

## Jobs

Jobs share one state/progress/cancellation representation across the scanner,
the projection, the property backfill, the library-wide analysis, and future
conversion, ripping, provider, artwork and mutation workers. Job state remains
owned by the serialized runtime control lane; the worker publishes counters
through atomics and is joined through
`work.Registry` before its terminal state is recorded and its lossless
`job_finished` completion is published.

A worker's cancellation is always requested in two places at once: the registry
flag, which shutdown observes, and the cooperative token the worker itself polls
(a scanner polls a `CancellationToken` deep inside a filesystem walk and would
never see the registry flag). Every runtime path that drains workers — shutdown,
Library close, Player destroy — sets both before it blocks. A Library's listen
worker has only the one: its network gateway's cancel pointer is the
registration's own flag, so the flag every drain sets also interrupts an
in-flight ListenBrainz request or a rate-limit hold. The drain also wakes the
worker from its sleep. A Player engine and a Library's artwork and browse
loaders sleep without a timeout while idle, so each gives its registration a
waker, set before its thread starts, which the first cancellation request
calls. The browse loader's waker also interrupts the query running on its
read-only connection; the connection closes only after the drain has joined
the thread, so the interrupt never reaches a closed connection.

Progress with no honest denominator is reported as a count, never as a fraction.
A filesystem scan does not know how many files it will find until it has found
them, so its snapshot carries `completed_units` and no total. A pass keyed on
`files.id` does know: the property backfill and the library-wide analysis each
answer "how many rows still owe work" with one indexed count before they start,
so their snapshots carry a total and a host may show a fraction.

Cancellation is not only a shutdown path. The library-wide analysis decodes
whole files, so a library-wide run is long and stopping it is the ordinary way
to use it: the token is polled inside a decode, the batch already measured is
still committed, and a later run selects only what is left. `docs/analysis.md`
covers what that resumption is keyed on.

### One Job per Library, and the waiting queue

A Library runs one host Job at a time. Lyrics, artist info and per-Release
info fetches are answers to a page the host is showing, so they never wait;
every other host Job holds its Library's slot from start until the pump reaps
it. A Job started while the slot is held, while an earlier Job of the same
Library waits, or while the Library is paused is created in state `waiting`
and appended to the runtime's waiting queue, `max_waiting_jobs` (32) entries
for all Libraries together. The 33rd is refused with `error.JobQueueFull`
(`ORCA_STATUS_BUSY`) and nothing is created.

The pump starts waiting Jobs after it has reaped finished workers, oldest
first, each once its Library's slot is free and no earlier entry of the same
Library waits. A waiting Job's planned units are counted again when it starts.
`cancelJob` on a waiting Job moves it to `cancelling`; the next pump finishes
it `cancelled` with one `job_finished`, even while its Library is paused.
`destroyLibrary` drops its Library's waiting Jobs and `shutdown` drops all of
them, finishing each `cancelled` without an event. `jobQueuePage(library)` lists
the Job holding the slot and then the waiting ones, each naming the Job it
waits `after`.

### Pausing

`pauseJob` holds a running Job at its worker's next cancellation poll:
`CancellationToken.checkpoint` sleeps in 50 ms steps while the token is paused
and not cancelled. The Job keeps its thread, its place in the slot and any
provider lease it holds, so nothing else can start in its Library or take its
gateway lease while it is paused. `resumeJob` lets it carry on from that poll.
A projection and a tag write never poll while working, so they are not
pausable (`error.JobNotPausable`). A Job already finished returns
`error.JobAlreadyFinished`.

`pauseAll(library)` pauses every pausable Job running in the Library, marks
its waiting Jobs `paused` in their snapshots, and holds the Library: Jobs
started later wait, the pump starts none of them, the watcher's reconciles
stay held back and idle maintenance skips it. `resumeAll` undoes all of that.
`libraryJobsPaused` reports the flag.

Cancel wakes a paused Job within one poll. Every path that cancels sets the
token: `cancelJob`, `shutdown` and `destroyLibrary` directly, and any other
cancellation request on the worker's registration through its waker,
`JobWorker.wakeFromPause`. So shutdown completes with paused and waiting Jobs
present: it cancels every token before `work_registry.drain` joins, each
paused worker returns from its checkpoint within 50 ms, and the waiting Jobs,
which own no thread, are dropped after the drain.

### Progress, ETA and current item

`jobSnapshotSynced` fills in what the control lane does not own. Its
`completed_units` come from the worker's atomic counters. `started_at` is the
wall-clock second the Job left `queued` or `waiting` for `running`.
`estimated_remaining_ms` is a rolling rate over the last 10 s of
`completed_units`, sampled on the monotonic clock at most every 500 ms as the
pump syncs progress; it is null until 10 s of progress has been sampled, while
paused (the window restarts on resume), and for a Job with no total, such as a
scan. `current_item` is the path or title the worker is working on, and
`detail` names a constraint the host shows beside it, such as "14 threads" or
"rate-limited to 1 request a second".

### History

When a host Job holding a slot finishes, the control lane writes one row to
the Library's `job_history` table: kind, the request as JSON, start and finish
times, state, units, an error text, the undo group of a tag write and a
summary of what it did. A waiting Job that never ran gets a row too, with its
state as the error text. Rows past the newest 1,000 are pruned.
`jobHistoryPage(library, filter, limit, offset)` reads them newest first;
`jobRetry(library, history_id)` re-submits a failed or cancelled Job's request
through the same start function, which may queue it. A tag write's request is
an approved plan and is never retried; it is undone through its undo group.

### Who writes what

| State | Written by | Read by |
| --- | --- | --- |
| `job.Manager` (state, paused, units, rate window), `waiting_jobs`, `LibraryObject.jobs_paused`, a worker's `published` and `retired` | control lane | control lane |
| `CancellationToken.paused` | control lane (`pauseJob`, `pauseAll`, their resumes) | worker, in `checkpoint` |
| `CancellationToken.requested` | control lane (`cancelJob`, `cancelJobWorkers`), and any thread requesting the registration's cancellation, through its waker | worker, in `checkpoint` |
| progress counters | worker, atomically | control lane, in `syncJobProgress` |
| `current_item` | worker, under its spin lock | control lane, in `jobSnapshotSynced` |
| `job_history` rows | control lane, after the worker is joined and before its Library closes | control lane |

A waiting Job's request stays on the control lane until the pump spawns its
worker, and the worker's terminal state is recorded only after
`work.Registry` has joined its thread, so history never races a worker's last
write.

## Idle maintenance

`libraryMaintenance(library, MaintenanceOptions)` makes the pump verify a
Library's recording IDs a unit at a time while the process is otherwise
idle (`liborca/core/runtime_maintenance.zig`). A unit is a `metadata_lookup`
job in verify mode with origin `maintenance` (`jobOrigin`): one Release with a
file to verify, after the last one a unit took and wrapping to the first, or,
once no Release is left, at most 20 Tracks on no Release. Its findings land
in Health as `recording_mismatch`. There is no scheduler thread: the record
lives on the Library, and the pump reads the runtime's sampling clock (the
listen clock) to decide when the next unit is due.

A due Library starts a unit only when every check passes, in this order;
any other outcome puts it off one whole interval:

1. A client identity is set (`blocked = client_identity_required`).
2. AcoustID is in scope: an application key is set (`acoustid_required`).
3. Every Player is idle: stopped, paused, or with its queue played out. No
   other job runs, and no host job waits. Nothing is reported blocked.
4. Neither AcoustID nor MusicBrainz has a block recorded in the Library
   (`provider_busy`), so a unit never sleeps through a backoff inside its
   worker.
5. Something is left to verify. Otherwise the cursor goes back to the first
   Release.

At most one unit runs in the process. Each unit ends, however it ends,
`interval_ms` before the next one is due. A unit that fails because another
Orca process held a service's lease is reported `provider_busy`. Starting
playback never cancels a running unit; it only keeps the next one from
starting.

A unit gives way to the host:

- `libraryJobRunning` ignores units, so they never refuse a scan or a tag
  write. A unit can start before a new watcher's first reconcile spawns, and
  then runs beside it. `libraryRemoveRoot` cancels the Library's unit
  without waiting for it, then removes the root. A unit whose files are
  forgotten under it either committed first, and the deletion cascades, or
  fails its commit on the missing file and rolls the whole unit back.
- `startLibraryMatching`, `startReleaseCoverArtFetch` and
  `startAcoustIdSubmission` called while a unit runs cancel the unit and
  return the new job's handle at once, in state `waiting`, with default stats
  and origin `host`. The handoff has a fixed order. The unit's worker
  releases its provider leases before it finishes. The pump joins the worker
  and publishes its `job_finished`, which waits while the event channel is
  full. Only then does a later step of the pump start the waiting job's
  worker. So two workers never share a lease or write `provider_state`
  together, and the unit's `job_finished` arrives before any progress of the
  host job. A second such start while one waits is refused as it would be
  beside a running job, and so is `libraryRemoveRoot` on its Library
  (`LibraryJobRunning`).
- A waiting host job is cancelled and dropped as any waiting Job is (see
  [the waiting queue](#one-job-per-library-and-the-waiting-queue)).
