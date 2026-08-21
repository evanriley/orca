# Audio engine ownership and real-time boundary

Player transport state is independent of physical output. A seek publishes a
new generation and timeline frame; prepared blocks from older generations are
discarded by the callback without queue surgery.

Decoded/processed PCM uses preallocated `BlockPool` storage. One producer passes
block indices to one callback through a bounded wait-free SPSC queue. The
callback returns consumed indices through a second SPSC queue for producer-side
reclamation, so it never allocates, frees, locks, waits, performs I/O, or touches
SQLite. Missing audio is zero-filled and counted as an underrun.

Zones hold render policy independently from Players. Latency state records
requested frames, backend quantum, Orca render-ahead, DSP algorithmic latency,
and optional hardware latency as separate values rather than presenting a
literal zero-latency claim.

On Linux, a narrow C shim contains PipeWire headers and native object lifetime.
An `OutputSession` owns one autoconnected float32 playback stream. PipeWire's RT
process callback writes directly into mapped backend buffers by calling an
Orca-owned `RenderContext`; it performs only queue operations, PCM copying,
atomic diagnostics, and silence filling. Stream creation and destruction stay
on the control side. Run `zig build pipewire-live-smoke` to verify a short
silent stream against the current user's server; normal tests require no live
audio service.
