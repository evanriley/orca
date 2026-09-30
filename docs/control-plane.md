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
submitted commands, joins finished jobs and starts the reconciles watchers
asked for; `Runtime.nextPumpTimeoutMs`
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
- While a job worker runs, the timeout is `job_progress_interval_ms` (100 ms),
  so a host showing progress rereads it. A finished worker not yet reaped, or
  commands left queued by event backpressure, make it 0.
- A watcher's published changes, or waiting changes that could start a
  reconcile now, make it 0. Changes held back by a running job of their
  Library wait on that job's timeout, and the pump that reaps the job starts
  their reconcile.

A waker installed with `setWaker` is read by worker threads without a lock, so
it is refused with `error.WorkersRunning` (`ORCA_STATUS_INVALID_STATE`) once any
worker thread exists: a Player's engine, a job, a listen worker, an artwork
loader or a Library's watcher. Every such thread is registered with
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
worker from its sleep. A Player engine and a Library's artwork loader sleep
without a timeout while idle, so each gives its registration a waker, set before
its thread starts, which the first cancellation request calls.

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
