# Audio engine ownership and real-time boundary

Player transport state is independent of physical output. A seek first moves
the codec-neutral source, then publishes a new generation and timeline frame;
prepared blocks from older generations are discarded by the callback without
queue surgery.

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
output is closed and reopened with bounded attempts while its Player generation
and prepared render path remain intact. Recovery state belongs to each Zone;
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
Orca `Decoder` interface (canonical format, optional frame count, read, seek,
and lifetime); WAV parser state and conversion scratch remain private to its
adapter. `SourceSession` therefore owns any registered Decoder and primes the
same pool/queue path without codec-specific types.

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
