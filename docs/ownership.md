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
never touch a Pool. Moving a Zone to another Player waits for the previous
engine's acknowledgement, then closes the output and resets the render path on
the control lane before the new engine is handed the Zone; see
[audio-engine.md](audio-engine.md).

Each Library that a Player has been bound to, or that scrobbles, has a listen
worker. Its bounded ring, configuration and published status belong to the
Library and outlive the worker: a full drain joins and releases the worker, and
the next listen, bind or scrobbling enable starts a new one. Closing a Library
restarts the scrobbling Library's worker at once, so its queue keeps its retry
times. A worker records everything in its ring before it finishes.

Each watched Library has a watcher thread; see
[storage.md](storage.md#watching-roots). The Library keeps whether it is
watched, and with which `WatchOptions`; the watcher, its queues and the
changes waiting for a reconcile belong to the watcher's record and go with
it. A full drain joins and releases every watcher. `destroyLibrary` drains
every worker in the process, so once the Library is gone it starts a watcher
again for every other Library still watched, and each of their roots is
reconciled whole, since the drain may have cancelled a reconcile or missed an
event. Destroying the watched Library itself leaves nothing to restart.

A Library with idle maintenance enabled keeps its schedule, its cursor and
the last unit's result on its own record, which holds no pointer and
survives a drain. Its unit is an ordinary job worker with origin
`maintenance` and goes with the other job workers; the drain finalizes it,
and the next unit starts one interval later. A waiting host job, behind a
unit or another job of its Library, holds a Library handle and a request, not
a worker. `destroyLibrary` finishes its Library's waiting jobs `cancelled`, so
no waiting job names a Library that is gone. See [control-plane.md](control-plane.md#idle-maintenance).

The `CredentialStore` passed to `setCredentialStore` is borrowed: its context
must outlive the runtime, because a worker may call it at any time.
`setClientIdentity`, the server setters and `setAcoustIdClientKey` copy their
strings into fixed buffers in the runtime, and each worker copies those by
value, so a later call never frees text a worker is reading. `CredentialStore.get` is called on a listen worker's
thread, never on the caller's.

Listen workers share one network `std.Io`, created with the first worker and
deinitialized by `deinit`. Creating it installs Zig's handlers for SIGIO and
SIGPIPE; deinitializing it restores the dispositions it found. A host sets its
own dispositions for those signals before creating the runtime and leaves them
unchanged while the runtime exists.

A host that replaces its open Library while the runtime lives, as
`orca-gtk` does when it switches libraries
([frontends.md](frontends.md#linux-gtk4)), opens the next Library before
it destroys the current one, so a failed open leaves the current Library
open and playing. Before `destroyLibrary` it joins its own threads that
hold the current Library's handle, because `destroyLibrary` drains only
liborca's workers, and it pauses the Player and saves its state into the
current Library. It clears the Player's queue only after `destroyLibrary`:
until then the Player is bound, and unbinding it saves the queue into the
Library again, so a queue cleared earlier would overwrite the one just
saved.

Shutdown (`Runtime.shutdown` in `core/runtime.zig`) follows dependency order,
work → Zones → Players → Libraries:

1. Stop accepting commands and enter `shutting_down`.
2. End open listens, stop every Player's engine thread, cancel job workers and
   all other registered work (listen workers, artwork and browse loaders,
   watchers), and block until every worker has finished. A paused job worker
   sees its cancelled token within one 50 ms poll, so pausing never holds
   this step. Then record each host job's history, release the drained
   workers, which closes each loader's read-only connection before its
   Library's database closes, discard tag write plans awaiting approval,
   finish every waiting host job `cancelled`, and cancel and drain Jobs.
   Last, with no worker left to hold a Library's write lane and every Player
   and Library still alive, save the queue and position of each Player
   whose state the host saved or restored, and where each Player's long
   Track was left ([api.md](api.md#surface)).
3. Destroy Zones, closing their output sessions; Zones depend on Players and
   output resources.
4. Free Players.
5. Close each Library's database and release its listen state.
6. Enter `stopped`; repeated shutdown calls are no-ops.

Each step releases an object's nested resources before its handle pool discards
the slot, and no object is freed while a worker that holds a pointer into it
can still run. The host's waker is never called once `shutdown` returns: every
thread that calls it is joined in step 2, and `submit` refuses a runtime that
is shutting down. `deinit` runs `shutdown`, then frees the handle pools, the work
registry and the network `std.Io`.
