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

Jobs share one state/progress/cancellation representation across scanner,
projection, and future analysis, conversion, ripping, provider, artwork and
mutation workers. Job state remains owned by the serialized runtime control
lane; the worker publishes counters through atomics and is joined through
`work.Registry` before its terminal state is recorded and its lossless
`job_finished` completion is published.

A worker's cancellation is always requested in two places at once: the registry
flag, which shutdown observes, and the cooperative token the worker itself polls
(a scanner polls a `CancellationToken` deep inside a filesystem walk and would
never see the registry flag). Every runtime path that drains workers — shutdown,
Library close, Player destroy — sets both before it blocks.

Progress with no honest denominator is reported as a count, never as a fraction.
A filesystem scan does not know how many files it will find until it has found
them, so its snapshot carries `completed_units` and no total.
