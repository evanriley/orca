# Runtime ownership and shutdown

`Runtime` is liborca's process-level ownership root. The host supplies its
allocator and must call `deinit`; deinitialization is idempotent with respect to
an earlier explicit `shutdown`.

Runtime-visible objects use typed generational handles. Destroying an object or
shutting down its manager increments the slot generation, so a stale handle can
never resolve to a later object that reuses the same slot.

A runtime Player owns its transport, its `SourceQueue` and the one engine thread
that decodes for it. A runtime Zone owns its render path — pool, pipe, render
context, selected device, output session and output recovery state. Zones reach
their Player's engine only through an acknowledged published snapshot, never by
resolving a handle: `core/handle.zig` does no locking, so a worker thread must
never touch a Pool.

Shutdown follows dependency order:

1. Stop accepting commands and enter `shutting_down`.
2. Request cancellation of all registered work — Player engine threads included
   — and block until every worker has finished.
3. Invalidate Zones, which depend on Players and output resources.
4. Invalidate Players.
5. Invalidate Libraries.
6. Enter `stopped`; repeated shutdown calls are no-ops.

Subsystem-owned values must release nested resources before their manager pool
is deinitialized. The initial object values are resource-free manager skeletons;
later phases will add explicit subsystem teardown at the same boundaries.
