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

**Everything a transport shows resolves from that one serial.** Identity comes
from mapping it back to a queue position, duration from a small serial-keyed
ring of per-entry timeline shapes the Player records as it opens each entry, and
position from the entry anchor below. Deriving any of the three from
`SourceQueue.current` instead makes it describe the *next* track for the whole
lookahead window — measured at 163 ms on a 96 kHz FLAC boundary — so identity,
duration and position agree by construction rather than by coincidence. The
serial is adopted only once the position published with it proves to belong to
the current epoch: a serial published under a retired epoch describes audio a
hard switch already discarded.

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
Volume changes use frame ramps; metering publishes peak/RMS snapshots without
changing samples.

Every Player runs one built-in DSP chain, `PlayerDsp` in `audio/dsp.zig`:
preamp, a ten-band peaking equalizer (31 Hz to 16 kHz, one octave apart,
Q 1.41, up to 12 dB per band), stereo crossfeed, then the volume gain, in that
order. It runs on the engine thread over canonical float32 PCM, after decoding
and before fanout, never in the render callback. Before each pass the engine
calls `prepare`, which rebuilds the filter coefficients when the settings or
the canonical sample rate changed, leaving out bands at zero gain and bands at
or above Nyquist, and clears filter history when the transport epoch or
channel count changed, so a seek or a hard switch never rings with the old
audio. The control lane writes the settings only while the engine is
quiesced. Crossfeed applies to two-channel audio; other layouts pass through
unchanged. With the equalizer and crossfeed off the chain is the volume gain
and nothing else. The DC blocker, the ordered chains and the resampler are not
part of it.

User volume and loudness correction are applied in two different places
because they are two different kinds of thing. Volume is one Player-scope
ramped multiplier; the correction belongs to the *audio*, and is applied by the
`SourceSession` that decodes it, from a figure attached to that session when
the entry was opened. A Player-level correction cannot be right during a
gapless transition — the pipe then holds prepared blocks belonging to two
entries at once — and a per-block one cannot be right either, because one
canonical block is filled from two decoders across the boundary. Per decode it
always is. Every path that produces a session goes through one opener, so a
hard load, an auto-advance, a format switch and a seek re-open all carry the
right correction without any of them republishing anything. See
`docs/analysis.md`.

The resampler interface uses caller-owned input/output buffers and reports
partial consumption. Its current linear implementation is a streaming scalar
reference, not a production-quality band-limited resampler. Gain and metering
also have scalar references and tested Zig vector kernels; run
`zig build -Doptimize=ReleaseFast dsp-bench` for host-specific evidence.

Signal-path reports list Player and Zone nodes, format/rate/layout conversions,
direct-RT eligibility, and total algorithmic latency. They distinguish source
PCM from canonical float32 working PCM and conservatively explain why a path is
not bit-perfect. Eligibility is not an assertion that the current backend and
device negotiated a bit-perfect native output path. `Runtime.playerSignalPath`
reports the live path of one Player: the decoder's source format, the audible
entry's ReplayGain, the equalizer, crossfeed and volume, and the format the
clock Zone opened its stream with.

A runtime Zone owns its whole private render path: `BlockPool`, `RenderPipe`,
`RenderContext` and `OutputSession`, plus every atomic the render callback reads
— epoch, silence, packed position, rendered entry serial and entry anchor. None
of those pointers may lead back into a Player, because an output can outlive a
Player detach and the real-time thread cannot re-resolve a generational handle.
The producer publishes the Player's epoch into the Zone's own epoch atomic
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
the wrong epoch. A sample whose epoch does not match is discarded rather than
reported.

The epoch is the right anchor for the *timeline* and the wrong one for a
*per-entry* position: a gapless auto-advance deliberately keeps one epoch, so
frames-since-epoch runs straight through the whole queue. The callback therefore
publishes a second packed `u64`, the **entry anchor**: the frames-since-epoch
value at which the entry now being rendered became audible, stamped with the low
16 bits of that entry's serial. Position inside the audible entry is
`frames since epoch - entry anchor`, plus the seek base only when the anchor is
zero — an entry that began inside the current epoch started at its own frame
zero, while one that was already audible when the epoch was stamped carries the
base stamped with it. Consistency is checked, never locked: the callback writes
the anchor and the serial before releasing the position, the control lane loads
the position first and the other two after, and a stamp that disagrees with the
published serial or an anchor ahead of the frame count proves the pair came from
different moments, so the sample is dropped exactly as a mismatched epoch is.
Consecutive entries take consecutive serials, so a 16-bit stamp cannot alias
inside a torn read.

The clock Zone is the first attached Zone with an active output, and promoting a
replacement stamps a new epoch so the promoted Zone's counter starts from a known
base. Coalesced position hints reach hosts through the telemetry channel at
roughly 10 Hz.

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

Each stream requests `node.rate` at the entry's source rate, and a format
change between entries reopens it at the new one. PipeWire honours the request
only when the graph's `clock.allowed-rates` permits it and no other stream
holds the device at another rate; otherwise it resamples. The rate the device
runs at is read back from the stream's timing, published by the Zone, and
reported in the signal path as `device_rate`, which adds the
`sample_rate_conversion` reason when it differs from the stream's rate.

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

Every registered codec reads an Orca `ReadableSource` behind its own adapter;
`docs/codecs.md` records which library each one wraps and why.

Player owns the active `SourceQueue`: one current SourceSession and one prepared
successor. When decoding reaches the current source's end, it appends compatible
next-source blocks behind current blocks already in the render queue, then
releases the exhausted decoder. This primes transitions before audible end and
requires no callback-side source switch or queue mutation.

A `PlaybackQueue` sits above that decode queue: bounded track references, an
audible cursor, a decode cursor, repeat and shuffle. It is owned by the Player
and mutated only by the control lane and the engine thread — never by a render
callback — under the same `quiesce`/`release` handshake that protects
`SourceQueue`. Enqueueing past capacity applies backpressure rather than growing.
The three values a host polls (entry count, audible cursor, decode cursor) are
atomics, so reporting now-playing never has to stop the producer.

The two cursors are separate because the decode cursor leads the audible one by
the whole render-ahead depth. The audible cursor is derived from the
`entry_serial` the callback publishes, mapped back to a queue position, and
every user-facing operation resolves from it — so a skip during a gapless
transition advances one entry rather than two. Entry serials continue across a
replaced `SourceQueue`, because a serial that repeated would resolve to the
wrong entry.

A seek also resolves against the audible entry rather than the decoded one. Once
the producer has advanced onto the successor, the entry being heard no longer has
a decoder to seek, and applying the seek to what *is* loaded drops the listener
into the following song. The control lane therefore records the request against
the audible serial, stamps the new position and publishes the epoch immediately —
which is what retires the decode-ahead work for the successor — and the engine
completes it on its next pass by re-opening the audible entry on the lane that is
allowed to open files, seeking it, and returning both queue cursors to it. The
transition into the following entry is then primed again from there, so a seek in
the last moments of a track costs one re-open and one underrun rather than the
next track. A seek inside the entry still being decoded takes the ordinary path
and re-opens nothing.

A user skip is a hard switch: the epoch bump makes the callback discard prepared
audio, so it is immediate rather than waiting for the current entry to drain. A
hard load also makes the entry it loaded the audible one at once: the callback
republishes a serial only when the audible entry *changes*, so after the epoch
bump the last serial it published names audio that no longer exists.
`previous` restarts the current entry past three seconds and moves the cursor
back before it. Shuffle generates a permutation and keeps the playing entry at
the cursor, so toggling it does not restart the song and `previous` still has
real history; a random pick per advance would have neither property. `repeat_one`
re-opens a *fresh* session for the same entry rather than seeking the one still
draining into the pipe.

Auto-advance runs on the engine thread: at `current.eof` with no successor it
resolves the next entry, opens it, and primes it. A canonical format mismatch is
not fatal — the successor is held opened but unprimed until every Zone has
drained, then the outputs are reopened at the new format and it is hard-loaded.
Gapless when formats match, gapped-but-correct when they do not. A decoder that
fails part-way ends its entry rather than stalling the queue, and an entry that
cannot be opened is stepped over, with consecutive failures bounded.

Gapless transitions append compatible successor PCM directly. Optional
crossfade infrastructure provides a stateful linear envelope that operates on
caller-owned outgoing and incoming buffers, remains continuous across bounded
chunks, and performs no allocation in the processing path.
