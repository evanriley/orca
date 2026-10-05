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
lookahead window; resolving all three from the serial makes them agree by
construction rather than by coincidence. The serial is adopted only once the
position published with it proves to belong to the current epoch: a serial
published under a retired epoch describes audio a hard switch already discarded.

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
in one Zone cannot consume another Zone's render capacity. All processing is
Player-scope and runs on the engine thread before fanout; Zones apply none of
their own.

A processing node is a `processing.Processor` (`audio/processing.zig`): a
context and a function that process samples in place, with `Metadata`
declaring whether it changes samples, rate or layout, its algorithmic latency,
lookahead, tail, block constraint and real-time safety. A processor never
allocates, locks, waits, performs I/O or retains the sample slice. `Gain`
ramps volume changes over frames.

Every Player runs one built-in DSP chain, `PlayerDsp` in `audio/dsp.zig`:
preamp, an equalizer, stereo crossfeed, then the volume gain, in that order.
The equalizer is either the ten-band graphic one (peaking filters 31 Hz to
16 kHz, one octave apart, Q 1.41, up to 12 dB per band) or the parametric one,
never both: turning either on turns the other off. The parametric equalizer
(`ParametricEqualizer`) holds up to 16 filters, each a peak, low shelf, high
shelf, low pass, high pass or notch with its own frequency (20 Hz to 20 kHz),
gain (within 24 dB, on peaks and shelves) and Q (0.1 to 20, or 0.3 to 2 on a
shelf), and a preamp of -24 to +6 dB. Every filter is an RBJ Audio EQ Cookbook
biquad, designed in f64 in `audio/equalizer.zig` and run as one cascade.
`audio/eq_text.zig` reads and writes the EqualizerAPO text that headphone
correction tools publish (`Preamp:` and `Filter N: ON PK Fc … Hz Gain … dB
Q …` lines); it rejects lines and filter types it cannot run rather than
dropping them. The chain runs on the engine thread over canonical float32 PCM,
after decoding and before fanout, never in the render callback. Before each
pass the engine calls `prepare`, which rebuilds the filter coefficients when
the settings or the canonical sample rate changed, leaving out bands and
filters that leave samples unchanged (zero gain, or disabled) and those whose
frequency is too close to Nyquist to design (at or above Nyquist for a graphic
band, 0.45 of the rate for a parametric filter), and clears filter history
when the transport epoch or channel count changed, so a seek or a hard switch
never rings with the old audio. A rebuild clears a filter's history when
the filter is new or of another kind, or the other equalizer was in use, and
keeps it when only its gain, frequency or Q changed or another filter was
turned off or on, so a band moved during playback does not click. History is
keyed by the filter's index in the setting (the band for the ten-band
equalizer), not by its slot in the cascade. The control lane writes the
settings only while the engine is quiesced: the engine finishes its pass, the
setter validates and stores the new settings and bumps their generation, and
the engine's next `prepare` designs the coefficients before it processes
another block. Nothing already queued for the render callback is discarded,
so a change mid-track is gapless and takes effect a render-ahead later.
Crossfeed applies to two-channel audio; other layouts pass through unchanged.
With the equalizers and crossfeed off the chain is the volume gain and nothing
else. `nodes.DcBlocker` is not part of it.

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

The Player's ReplayGain choices — mode, preamp, untagged fallback and peak
protection — are one packed 64-bit `ReplayGainSettings` word. The decode lane
loads it once per block and passes it to `SourceSession.readFrames`, so it
always sees a consistent set; the setters replace the word with a
compare-and-swap and need no quiesce, and a change takes effect a render-ahead
later, as a mode change always has. Each session keeps its corrections
uncapped (`EntryReplayGain`: track and album gain, each with its peak) and
`EntryReplayGain.applied` resolves mode, preamp, peak cap and fallback per
decode. Host reads of the audible entry's corrections go through a seqlock the
engine thread writes when the audible entry changes.

`smart` needs to know whether a neighbour in playback order shares the
entry's Release. That is `EntryReplayGain.shares_release`, decided by
`PlaybackQueue.sharesRelease` through the opener's `release_fn` wherever an
entry is opened: a hard load, a cursor start, a gapless prime and a seek
re-open. A reorder (enqueue, insert, remove, move, shuffle) changes neighbours
without opening anything, so the control lane calls
`PlayerEngine.refreshSharedRelease` under its quiesce to re-decide every
opened session; audio already decoded keeps the gain it was decoded with.

**Orca runs no resampler on the playback path.** Each stream opens at the
entry's source rate, and a format change between entries reopens the output
(see below). PipeWire may resample when the device runs at another rate. The
only Orca resampler is `resampler.SampleRate`, libsamplerate behind
`audio/samplerate_shim.c`, which brings audio to 11,025 Hz for AcoustID
fingerprints; see [analysis.md](analysis.md#acoustid-fingerprints). Gain and
metering have scalar references and tested Zig vector kernels
(`audio/kernels.zig`); run `zig build -Doptimize=ReleaseFast dsp-bench` for
host-specific evidence. It also times a 256-frame stereo block through the
graphic equalizer with ten active bands and the parametric one with 16 filters.

Signal-path reports list the processing nodes, format/rate/layout conversions,
direct-RT eligibility, and total algorithmic latency. They distinguish source
PCM from canonical float32 working PCM and conservatively explain why a path is
not bit-perfect. Widening an 8-, 16- or 24-bit integer source to float32 is
exact, so it is not a reason; the report marks it `widened_exactly`. These are
reasons: a 32-bit integer or 64-bit float source, or the float32 stream
reaching an integer device (`sample_format_conversion`), a lossy codec
(`lossy_source`), any ReplayGain, either equalizer, crossfeed or volume that is
not exactly 1 (`sample_processing`), and a rate or channel layout that changes.
Eligibility covers the stream Orca hands the backend and only what PipeWire
reports of the device beyond it, its rate and format (below); it is not an
assertion that the device negotiated a bit-perfect native path. `Runtime.playerSignalPath`
reports the live path of one Player: the audible entry's source format, codec
and ReplayGain (the applied gain, whether it is the track's, the album's or
the track's in place of a missing album figure, and for an album gain the
track gain it replaced; see
[analysis.md](analysis.md#album-replaygain)), the equalizer or parametric
equalizer and crossfeed, the volume the gain node is applying (not the
target it ramps toward), the
format the clock Zone opened its stream with, the frames per period that
Zone's device asks for (`device_quantum_frames`, null until the stream has
run), and how that device is attached (`output_kind`). A decoder that declares no
source format, as lossy decoders do, leaves `source_declared` false: `source`
then holds the canonical format, and only its rate and channels are
meaningful.

A runtime Zone owns its whole private render path: `BlockPool`, `RenderPipe`,
`RenderContext` and `OutputSession`, plus every atomic the render callback reads
— epoch, silence, packed position, rendered entry serial and entry anchor. None
of those pointers may lead back into a Player, because an output can outlive a
Player detach and the real-time thread cannot re-resolve a generational handle.
The producer publishes the Player's epoch into the Zone's own epoch atomic
immediately before submitting blocks under it.

Epochs and entry serials are numbered per Player, so a Zone's render path
means nothing to another Player. Moving a Zone to another Player is a hard
discontinuity handled on the control lane: once the previous Player's engine
has acknowledged a zone set without the Zone, the control lane closes its
output, returns every prepared block to its pool and forgets the timeline its
callback published (epoch, position, rendered entry serial, entry anchor and
the callback's private copies of them). Only then is the Zone published to
the new Player, whose engine reopens the output in its own format. The Zone
keeps its output request, device, policy and diagnostics. Attaching a Zone to
the Player it is already on changes nothing. Detaching a Zone and destroying
its Player retire it the same way.

One `PlayerEngine` thread per Player is the single decode producer: SPSC queues
require exactly one producer and fanout is one-producer-many-consumers. It is
spawned lazily when a Player first receives a source and registered with
`work.Registry`, so `drain`, `destroyPlayer` and `shutdown` join it rather than
abandoning it. Each pass adopts a published zone set, reclaims consumed blocks,
decodes one canonical block per Zone budget, fans it out, services output
opening and bounded recovery, publishes position, and parks on a futex. The
Player's `SourceQueue` is plain state rather than an atomic, so loading a source
or seeking quiesces the engine first. A quiesce that follows a release waits for
one full engine pass before suspending it again, so back-to-back control calls
cannot starve the engine.

A busy engine parks for 2 ms, so decoding stays ahead of the device. An idle
engine parks with no timeout and costs no wakeups. The engine is idle when its
next pass would do nothing:

- no seek is waiting to be serviced and no format-switch successor is held;
- the Player is not playing, or it is playing with its queue decoded, every Zone
  taking part in the drain drained and no further entry to open;
- the clock Zone's position, when it has one in the current epoch, has been
  sent as a telemetry hint;
- every attached Zone is settled: its output is active in the format being
  decoded and is either silenced or holds no blocks, or it has no output and
  nothing to open one for (no source, or recovery attempts exhausted and every
  block handed back). A Zone that is opening, lost or waiting out its recovery
  backoff keeps the engine busy, and so does a suspended engine.

Everything that can end idleness wakes the engine, after the write it must act
on: `wakeUp` (play, pause and output requests call it), zone publication,
`quiesce`, `release`, the first cancellation request through the waker the
engine gives its `work.Registration`, and output state changes. The PipeWire
backend calls the output's waker from the stream's state-changed callback on its
loop thread, never from the process callback. An engine sets that waker on every
output it adopts or opens and clears it on every output it drops or leaves open
at exit; setting it takes the stream loop's lock, so an output that outlives its
engine never calls into a freed one. Telemetry cadence and recovery backoff are
measured on a monotonic clock, so a long idle park counts as its real length.

The engine thread never resolves a handle. `core/handle.zig` performs no locking,
so generational handles protect handles, not a pointer a worker already
dereferenced. The control lane writes an immutable `[]*ZoneRuntime` into an
unclaimed slot and publishes it with a single atomic store; the engine adopts it
at a pass boundary and bumps an acknowledgement counter; the control lane frees
a Zone or closes its output only after observing that acknowledgement.

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

The device's own format is the format of the sink node the stream feeds, which
PipeWire's adapter converts Orca's float32 stream into. Once the stream is
paused or streaming, the shim watches the registry for links out of the
stream's node, binds the node they lead to and, on the PipeWire loop thread,
reads its current `SPA_PARAM_Format`, again whenever the node's params change.
It packs the sample format (S16, S24, S24_32 or S32, little-endian or planar,
or F32), rate and channels into one atomic that the timing read loads; the
render callback never touches it. The Zone refreshes it with its latency, on
activation and every 16 engine passes, publishes it while its output is
active, and the signal path reports it as `device_format`. A known format adds
`sample_format_conversion` when it is an integer format and
`sample_rate_conversion` when its rate is not the stream's. Unknown is
explicit, never guessed: the format is null while the node is suspended (it
then holds no Format), before PipeWire has answered, for a virtual sink such
as `support.null-audio-sink`, for any other sample format, and on a backend
other than PipeWire. Null leaves the verdict as it is. A sink that is itself
processing, such as a filter chain, reports its own input format, not that of
the hardware behind it.

PipeWire stream-state changes are translated into an atomic Orca status. A lost
output is closed and reopened with bounded attempts while its Player epoch and
prepared render path remain intact. Recovery state belongs to each Zone;
another Zone remains active if reopening ultimately fails. Once
`zone_runtime.max_recovery_attempts` reopens have failed, the Zone reports
`failed` and returns every prepared block to its pool. It stays failed until
the host closes its output and, once the Zone reports `closed`, requests it
again, which opens it afresh with a new set of attempts.

A Zone takes part in a drain while its output is requested and its recovery
is not exhausted. A format switch waits for every such Zone to hand back its
blocks, and a Player reports drained only once they all have. Zones that are
opening, lost, recovering or silenced take part, bounded by the recovery
attempts; a Zone whose recovery is exhausted does not, so it cannot stall the
Zones that still play.

Device discovery returns bounded Orca-owned snapshots and uses PipeWire object
serials for stream targeting; device ID zero delegates selection to the server.
Each snapshot carries a `DeviceKind`: `usb`, `pci`, `bluetooth`, `hdmi`,
`virtual` or `unknown`. Registry globals carry only filtered properties, so
discovery binds each sink node and each `Audio/Device` and reads their info in
a second round trip: a `support.null-audio-sink` node is virtual, a BlueZ node
or device Bluetooth, an ALSA `hdmi:` path or HDMI profile HDMI, and otherwise
`device.bus` decides. Only the first 64 sinks are bound; later ones, and device
zero, report `unknown`. A Zone resolves its device's kind with one
discovery when the engine thread opens its output, never in the render
callback, and keeps it beside the open device ID; `playerSignalPath` only reads
it, so a signal path query never round-trips to the server.

`enumerateOutputDevices` also fills each snapshot's `DeviceCapabilities`: the
lowest and highest sample rate, the bit depths (16, 24 and 32, float32
counting as 32), the most channels, the state and the bus (the `DeviceKind`).
After the bound sinks' info arrives, discovery asks each one for its
`SPA_PARAM_EnumFormat` params and then syncs that node; the server answers a
node's later requests only after its pending enumeration, so the node's sync
reply means its formats are in. Only `audio/raw` formats count, and a range or
step choice gives its bounds. This round is bounded at 500 ms from its start;
a node that has not answered by then, or answered with no rate, reports
`capabilities` null. Node state `running` and `idle` are `active`,
`suspended` is `suspended`, and `error`, `creating` or no state are
`unavailable`. Every sink reports what PipeWire answers, virtual ones too: a
`support.null-audio-sink` accepts rates 1 to 2147483647 and float32 only.
Discovery runs on the caller's thread with its own `pw_loop`, so listeners fire
only inside its iterations and allocate nothing; every listener is removed and
every proxy destroyed before discovery returns, on the timeout path as well.
A Zone's kind lookup skips the format round.
Output requests validate the negotiated float32 contract and translate robust,
interactive, custom, or explicit latency targets into PipeWire node latency.
Timing snapshots report sample time, monotonic host time, callback quantum,
queued and converted frames, and non-negative graph/device delay. These values
remain distinct in Zone latency reporting rather than being collapsed into a
zero-latency claim.

A `SourceSession` performs bounded positional reads through its Decoder and
converts samples to canonical float32 on the producer lane. Each Zone's pool
holds `zone_runtime.block_count` (32) preallocated blocks of
`zone_runtime.frames_per_block` (256) frames; the Zone's policy sets how many
of them the producer fills ahead, never fewer than one device quantum's worth.
The callback advances Player position only for frames actually rendered.
`orca-cli play AUDIO [DEVICE_ID]` plays one file through this path and reports
played frames, underruns and backend quantum. Without a device ID it uses
device 0, the system default output, which is real hardware; tests pass a
device from `scripts/silent-sink.sh`.

Codec selection is owned by a bounded `CodecRegistry`. Playback sees only an
Orca `Decoder` interface (source and canonical formats, optional frame count,
read, seek, and lifetime); each codec's parser state and conversion scratch
remain private to its adapter. `SourceSession` therefore owns any registered
Decoder and primes the same pool/queue path without codec-specific types.

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
atomics, so reporting now-playing never has to stop the producer. Now-playing,
`playerStatus` and listen tracking take the audible Track from the audible
entry serial through the queue's serial records, never from the audible
cursor, which trails the serial across a gapless transition; a read whose
serial moves while it is resolved is retried, then names no Track, and serial
0 (nothing audible, as after a stop) names the cursor's entry. The serial
leaves an entry, and a hard load moves the cursor, before the next entry's
duration and gain are published, so a host reads those first and never pairs
an entry with its successor's figures. A hard load sets the serial to 0,
moves the cursor, and adopts the new serial only once the queue records it,
so a host never reads a serial the queue cannot name.

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
real history; a random pick per advance would have neither property. Toggling it
moves each serial record to the position its entry now has, and removing an
entry forgets its record, so a serial never names an entry it did not play.
`repeat_one` re-opens a *fresh* session for the same entry rather than seeking
the one still draining into the pipe.

Moving an entry to another position in playback order happens under one
`quiesce`, and everything keyed by position follows the entry it named: both
cursors, the position of a successor held for a format switch, and every serial
record, stored with release ordering after the move as a shuffle toggle stores
them. Under shuffle only the permutation changes, so turning shuffle off puts
entries back in list order. The entries the engine has committed to cannot
move: the audible and decoding entries while the Player holds audio, and a held
successor. Nothing may land after the audible entry and up to the last committed
one either, because the engine has already lined those up and would play past
the moved entry. Both are refused with `QueueEntryInUse`, as removing a
committed entry is. Moving into the played region, or past the committed
entries, is allowed; under `repeat_all` the committed span can wrap past the end
of the queue, and the refusal follows it.

Auto-advance runs on the engine thread: at `current.eof` with no successor it
resolves the next entry, opens it, and primes it. A canonical format mismatch is
not fatal — the successor is held opened but unprimed until every Zone taking
part in the drain has drained, then the outputs are reopened at the new format
and it is hard-loaded.
Gapless when formats match, gapped-but-correct when they do not. A decoder that
fails part-way ends its entry rather than stalling the queue, and an entry that
cannot be opened is stepped over, with consecutive failures bounded.

Gapless transitions append compatible successor PCM directly; there is no
crossfade.

### Stop after current

`Runtime.playerSetStopAfterCurrent` arms a one-shot stop at the end of the
entry being heard. While it is armed the engine never primes a successor, so
nothing past the stop is decoded. Arming under the quiesce takes back what the
engine may already have lined up: a held format-switch successor is released;
a primed successor not yet decoded is dropped and the decode position returns
to the audible entry; and when decoding has already crossed into the
successor, the audible entry is re-opened at the heard position through the
deferred seek, whose epoch bump discards the successor's audio at the cost of
a short gap. Gating priming, rather than letting the successor play and
stopping once it is heard, is what keeps a single note of the next entry from
reaching the device. When the Player has drained with the flag set, the engine
clears it and stops the transport. The sources stay loaded, so the queue
history records the entry as finished and a later play starts the entry after
it.

## Playback failures

`PlayerStatus.last_failure` names the last queue entry that could not be
opened, as a `PlaybackFailure`: its Track id and a reason (`file_missing`,
`folder_unavailable`, `codec_unavailable`, `decode_error` or
`unsupported_channels`). `folder_unavailable` means the Track's root or volume
is gone, so its files are not marked missing. `file_missing` means the root is
there but the file is not.

The failure lives in `Player.open_failure`, an `OpenFailureSlot`. Three rules
make it safe to read from any host thread without attributing it to the wrong
Track:

- **One writer at a time, never the callback.** The slot is written only by
  the lane that owns `sources`: the engine thread inside `pass`, or the control
  lane under `quiesce`, or before an engine exists. `quiesce` proves the engine
  is outside its pass, so the two writers never overlap. The render callback
  neither reads nor writes the slot.
- **Track and error are recorded together.** The Track id and the error are
  written as one pair at the failure site, under a sequence counter that
  readers retry on. The failure is never derived from `open_failures`, the
  cursor or the decode position, which have moved on to the next entry by the
  time a host looks. A stale failure therefore always names the Track that
  failed, never a later one.
- **A clear never overtakes a newer failure.** A successful open clears the
  failure only once that entry becomes audible. A hard load is audible at
  once, so `loadQueueEntry` clears the slot directly. A gapless prime is heard
  only after the entry before it drains, so the engine stores the primed
  entry's serial as a pending clear. `publishPosition` clears the slot, on the
  engine thread, once the serial the callback rendered reaches that serial.
  The comparison wraps, because serials wrap and skip 0. Recording a failure
  resets the pending clear, so an older entry becoming audible cannot clear a
  failure recorded after it.

Status snapshots read the slot through `playerStatus`, as they read every other
Player figure.

## Queue history

Each Player keeps the last `queue_history_capacity` (100) entries that
stopped playing, newest first, as `QueueHistoryEntry` values: the
`TrackRef`, `ended_at_ms` in Unix milliseconds, and a `QueueHistoryReason`.

- `finished`: the audible entry serial moved on by itself, or the Player
  drained. The control lane notices this when it samples Players, bound or
  not, at most every 100 ms while it processes commands, and before any
  history read.
- `skipped`: next, previous to another entry, or a queue jump.
- `replaced`: playing new Tracks, loading a file, or clearing the queue.

Stop records nothing, because the entry stays current and plays again from
its start. Closing the Library a Player is bound to stops it the same way.
`previous` restarting the current entry records nothing. Each audible entry
is recorded at most once. The 101st entry drops the oldest.

An entry's Track is resolved from the audible entry serial through the
queue's serial records, never from the audible cursor, which trails the
serial across a gapless transition. A sample whose serial moves while it is
being resolved is retried, then skipped. An entry that starts and ends between two
samples is never seen, so it is not recorded. A serial with no queue entry
behind it, such as a file loaded with `playerLoadFile`, records nothing.

The history lives on the control lane in memory only. It is never persisted,
so a new runtime starts empty, and it never records a listen: listens come
only from the Player's `ListenTracker`. `playerQueueHistory` reads raw
entries, `playerQueueHistoryTracks` reads them as `TrackSummary` rows, and
`playerClearQueueHistory` empties the ring.
