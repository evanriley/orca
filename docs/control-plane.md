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

Jobs share one state/progress/cancellation representation across future scanner,
analysis, conversion, ripping, provider, artwork, and mutation workers. Job
state remains owned by the serialized runtime control lane.
