# Audio engine ownership and real-time boundary

Player transport state is independent of physical output. A seek first moves
the codec-neutral source, then publishes a new **epoch** and timeline frame;
prepared blocks from older epochs are discarded by the callback without queue
surgery.

Epoch and track identity are deliberately separate fields on a prepared block.
The callback compares **only** the epoch, because a gapless transition appends
the successor track's blocks under the *same* epoch — comparing track identity
there would discard exactly the audio gapless depends on. The successor instead
carries a new `entry_serial`, which the callback publishes (never compares) so
the control lane can report which queue entry is actually being rendered. The
decode cursor leads the audible cursor by the whole render-ahead depth, so
now-playing is derived from that published serial rather than from the decoder's
position.

A paused Player is honored inside the callback: it writes silence and returns
without consuming prepared blocks, without advancing position, and without
counting an underrun. Pausing therefore does not discard prepared audio.

Decoded/processed PCM uses preallocated `BlockPool` storage. One producer passes
block indices to one callback through a bounded wait-free SPSC queue. The
callback returns consumed indices through a second SPSC queue for producer-side
reclamation, so it never allocates, frees, locks, waits, performs I/O, or touches
SQLite. Missing audio is zero-filled and counted as an underrun.

Players decode canonical PCM once for all attached outputs. Fanout copies that
PCM into independently owned Zone pools and queues, so backpressure or failure
in one Zone cannot consume another Zone's render capacity. Player processing
runs before fanout; Zone processing runs on each private copy afterward. Both
scopes use fixed-capacity, allocation-free processing chains.

DSP nodes expose sample/rate/layout effects, algorithmic latency, lookahead,
tail and block constraints, reset behavior, and direct-RT safety. Prepared
ordered chains are triple-buffered: the control lane writes an unclaimed slot
and publishes it atomically, while the render lane adopts it only at a block
boundary. Acknowledged publication makes old node-context reclamation explicit.
Gain and ReplayGain changes use frame ramps; metering publishes peak/RMS
snapshots without changing samples. Built-in processing also includes peaking
parametric EQ, stereo crossfeed, and a resettable DC blocker.

The resampler interface uses caller-owned input/output buffers and reports
partial consumption. Its current linear implementation is a streaming scalar
reference, not a production-quality band-limited resampler. Gain and metering
also have scalar references and tested Zig vector kernels; run
`zig build -Doptimize=ReleaseFast dsp-bench` for host-specific evidence.

Signal-path reports list Player and Zone nodes, format/rate/layout conversions,
direct-RT eligibility, and total algorithmic latency. They distinguish source
PCM from canonical float32 working PCM and conservatively explain why a path is
not bit-perfect. Eligibility is not an assertion that the current backend and
device negotiated a bit-perfect native output path.

A runtime Zone owns its whole private render path: `BlockPool`, `RenderPipe`,
`RenderContext` and `OutputSession`, plus every atomic the render callback reads
— epoch, silence, packed position and rendered entry serial. None of those
pointers may lead back into a Player, because an output can outlive a Player
detach and the real-time thread cannot re-resolve a generational handle. The
producer publishes the Player's epoch into the Zone's own epoch atomic
immediately before submitting blocks under it.

One `PlayerEngine` thread per Player is the single decode producer: SPSC queues
require exactly one producer and fanout is one-producer-many-consumers. It is
spawned lazily when a Player first receives a source and registered with
`work.Registry`, so `drain`, `destroyPlayer` and `shutdown` join it rather than
abandoning it. Each pass adopts a published zone set, reclaims consumed blocks,
decodes one canonical block per Zone budget, fans it out, services output
opening and bounded recovery, publishes position, and parks briefly so
play/pause/seek take effect within a device quantum. The Player's `SourceQueue`
is plain state rather than an atomic, so loading a source or seeking quiesces the
engine first.

The engine thread never resolves a handle. `core/handle.zig` performs no locking,
so generational handles protect handles, not a pointer a worker already
dereferenced. The control lane writes an immutable `[]*ZoneRuntime` into an
unclaimed slot and publishes it with a single atomic store; the engine adopts it
at a pass boundary and bumps an acknowledgement counter; the control lane frees
a Zone or closes its output only after observing that acknowledgement. This is
the same acknowledged double-buffering used for prepared processing chains.

Rendered position is published as one `u64` — high 16 bits epoch, low 48 bits
frames since that epoch — written by the callback with a single store and read by
the control lane with a single load, so a frame count can never be paired with
the wrong epoch. Authoritative position is `epoch base frames + clock Zone frames
since epoch`; a sample whose epoch does not match is discarded rather than
reported. The clock Zone is the first attached Zone with an active output, and
promoting a replacement stamps a new epoch so the promoted Zone's counter starts
from a known base. Coalesced position hints reach hosts through the telemetry
channel at roughly 10 Hz.

Render-ahead depth follows the Zone's policy but never falls below the negotiated
device quantum: a producer that stays less than one callback's demand ahead
underruns on every callback regardless of how promptly it runs.

Zones hold render policy independently from Players. Interactive policy limits
the producer to a direct one-block handoff, while robust and custom policies
permit bounded render-ahead through the same Zone abstraction. Latency state
records requested frames, backend quantum, Orca render-ahead, DSP algorithmic
latency, and optional hardware latency as separate values rather than
presenting a literal zero-latency claim.

On Linux, a narrow C shim contains PipeWire headers and native object lifetime.
An `OutputSession` owns one autoconnected float32 playback stream. PipeWire's RT
process callback writes directly into mapped backend buffers by calling an
Orca-owned `RenderContext`; it performs only queue operations, PCM copying,
atomic diagnostics, and silence filling. Stream creation and destruction stay
on the control side. Run `zig build pipewire-live-smoke` to verify a short
silent stream against the current user's server; normal tests require no live
audio service.

PipeWire stream-state changes are translated into an atomic Orca status. A lost
output is closed and reopened with bounded attempts while its Player epoch and
prepared render path remain intact. Recovery state belongs to each Zone;
another Zone remains active if reopening ultimately fails.

Device discovery returns bounded Orca-owned snapshots and uses PipeWire object
serials for stream targeting; device ID zero delegates selection to the server.
Output requests validate the negotiated float32 contract and translate robust,
interactive, custom, or explicit latency targets into PipeWire node latency.
Timing snapshots report sample time, monotonic host time, callback quantum,
queued and converted frames, and non-negative graph/device delay. These values
remain distinct in Zone latency reporting rather than being collapsed into a
zero-latency claim.

The first vertical playback path uses a WAV `SourceSession` to perform bounded
positional reads and conversion of supported integer/float samples on the
producer lane. It primes eight preallocated blocks ahead for robust playback;
the callback advances Player position only for frames actually rendered. The
CLI exposes this architecture as `orca-cli play AUDIO [DEVICE_ID]`. The command
uses server-default output when no ID is supplied and reports played frames,
underruns, backend quantum, and device/graph delay after completion.

Codec selection is owned by a bounded `CodecRegistry`. Playback sees only an
Orca `Decoder` interface (source and canonical formats, optional frame count,
read, seek, and lifetime); WAV parser state and conversion scratch remain
private to its adapter. `SourceSession` therefore owns any registered Decoder
and primes the same pool/queue path without codec-specific types.

The built-in registry prioritizes pure Zig adapters: Orca pins
`audiophile/flac` 1.0.2 for lossless decoding and `audiophile/qoa` 1.0.0 for
the first lossy decoder. Both receive an Orca `ReadableSource` through a stable
buffered-reader bridge. FLAC keeps checksum validation enabled; QOA receives a
bounded whole-stream structural pass before its native decoder is entered.

Player owns the active `SourceQueue`: one current SourceSession and one prepared
successor. When decoding reaches the current source's end, it appends compatible
next-source blocks behind current blocks already in the render queue, then
releases the exhausted decoder. This primes transitions before audible end and
requires no callback-side source switch or queue mutation.

Gapless transitions append compatible successor PCM directly. Optional
crossfade infrastructure provides a stateful linear envelope that operates on
caller-owned outgoing and incoming buffers, remains continuous across bounded
chunks, and performs no allocation in the processing path.
