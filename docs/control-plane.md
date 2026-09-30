# Control plane

Hosts submit typed commands through a fixed-capacity, thread-safe queue. The
runtime's single logical control lane processes commands and emits request-ID
correlated completion events. A host may currently drive that lane with
`processNextCommand`; a dedicated executor can replace that pump without
changing the public command contract.

Completion events are lossless and bounded. When their channel fills, command
processing applies backpressure rather than mutating state without delivering a
completion. High-frequency telemetry uses a separate bounded channel that
coalesces unread Player-position and Job-progress hints by stable handle.
Authoritative consumers query snapshots instead of reconstructing state from
events.

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
whole files, so a run is measured in hours and stopping it is the ordinary way
to use it: the token is polled inside a decode, the batch already measured is
still committed, and a later run selects only what is left. `docs/analysis.md`
covers what that resumption is keyed on.
