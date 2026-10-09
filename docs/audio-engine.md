# Audio engine

This file covers the audio engine: the real-time render boundary, Player and
Zone ownership, the engine thread, the built-in DSP chain, ReplayGain, the
signal-path report, the PipeWire output, the playback queue, playback failures
and queue history.

## Real-time rule

The render callback never allocates, frees, locks, waits, performs I/O or
touches SQLite. Decoded and processed PCM uses preallocated `BlockPool`
storage. One producer passes block indices to one callback through a bounded
wait-free SPSC queue, and the callback returns consumed indices through a
second one for producer-side reclamation. Missing audio is zero-filled and
counted as an underrun.

A Player decodes canonical float32 PCM once for all attached outputs. Fanout
copies it into independently owned Zone pools and queues, so backpressure or
failure in one Zone cannot consume another Zone's render capacity. All
processing is Player-scope and runs on the engine thread before fanout; Zones
apply none. A processing node is a `processing.Processor`
(`audio/processing.zig`); it processes samples in place, declares its
algorithmic latency, lookahead, tail and real-time safety in `Metadata`, and
never allocates, locks, waits, performs I/O or retains the sample slice.

Each Zone's pool holds `zone_runtime.block_count` (32) blocks of
`zone_runtime.frames_per_block` (256) frames. The callback advances Player
position only for frames actually rendered.

### Latency and render-ahead

The Zone's policy sets how many blocks the producer fills ahead. The
interactive policy asks for a direct one-block handoff; the robust policy (1024
frames) and custom policies permit bounded render-ahead. The depth never falls
below twice the negotiated device quantum and never below two blocks: a
producer less than one callback's demand ahead underruns on every callback.
Latency state records requested frames, backend quantum, Orca render-ahead, DSP
algorithmic latency and optional hardware latency separately.

## Transport timeline

Player transport state is independent of physical output. A seek moves the
codec-neutral source, then publishes a new epoch and timeline frame; the
callback discards prepared blocks of older epochs. A paused Player writes
silence, consumes no prepared blocks, does not advance position and counts no
underrun.

A Player that is not playing (paused, stopped, or at the end of its queue with
every Zone drained) sets each of its active Zone outputs inactive once the
output's callback has run twice since the Player stopped playing. A PipeWire
stream delivers the quantum one callback writes in the next graph cycle and
keeps it across deactivation, so the second callback leaves silence as the held
quantum: playback that resumes after a stop or a seek starts with no audio from
the old position, and the last quantum of a queue is heard before the output
goes inactive. Until then the engine keeps passing instead of parking. An
inactive output's callback is not called. An output that never calls back stays
active. Playing again before the output goes inactive keeps it active; playing
after sets it active again in the next pass, with a fresh stall timeout. The
same applies to an output opened or reopened while the Player is not playing.

The callback compares only the epoch of a prepared block, never its track: a
gapless transition appends the successor's blocks under the same epoch, so a
track comparison would discard the audio gapless depends on. The successor
carries a new `entry_serial`, which the callback publishes and never compares.
A block holds frames of at most two entries. When the successor starts partway
through one, the block also carries the successor's serial and the block frame
of its first frame, and the callback publishes that serial and the entry anchor
at that frame, not at the block's first. The decode cursor leads the audible
cursor by the whole render-ahead depth, so identity, duration and position of
the audible entry all resolve from the published serial (identity through the
queue's serial records, duration through a serial-keyed ring of per-entry
timeline shapes, position through the entry anchor) and never from
`SourceQueue.current`. The serial is adopted only once the position published
with it belongs to the current epoch. Under a new epoch the callback publishes
serial 0 until it renders that epoch's first block, so it never pairs the
retired entry's serial with the new epoch.

### Rendered position

Rendered position is one `u64`: the high 16 bits are the epoch, the low 48 the
frames since that epoch. The callback writes it with one store and the control
lane reads it with one load, so a frame count is never paired with the wrong
epoch; a sample of another epoch is discarded.

A gapless auto-advance keeps one epoch, so the callback also publishes the
entry anchor: the frames-since-epoch value at which the entry now rendering
became audible, stamped with the low 16 bits of its serial. Position inside the
audible entry is `frames since epoch - entry anchor`, plus the seek base only
when the anchor is zero. The callback writes anchor and serial before releasing
the position and the control lane loads the position first; a stamp that
disagrees with the published serial, or an anchor ahead of the frame count,
marks a torn read and the sample is dropped. Nothing is locked.

The clock Zone is the first attached Zone with an active output. Promoting a
replacement re-seeks the Player to the position already heard, which stamps a
new epoch without skipping the audio decoded ahead. Position hints reach hosts
through the telemetry channel at roughly 10 Hz.

## Zones

A runtime Zone owns its whole private render path: `BlockPool`, `RenderPipe`,
`RenderContext` and `OutputSession`, plus every atomic the callback reads
(epoch, silence, packed position, rendered entry serial, entry anchor). None
leads back into a Player, because an output can outlive a Player detach and the
real-time thread cannot re-resolve a generational handle.

Epochs and serials are numbered per Player, so moving a Zone to another Player
is a hard discontinuity on the control lane: after the old engine acknowledges
a zone set without the Zone, the control lane closes its output, returns every
prepared block to its pool and forgets the published timeline; only then is the
Zone published to the new Player, whose engine reopens the output in its own
format. The Zone keeps its output request, device, policy and diagnostics.
Detaching a Zone and destroying its Player retire it the same way.

A Zone takes part in a drain while its output is requested and its recovery is
not exhausted. A format switch waits for every such Zone to hand back its
blocks, and a Player reports drained only once they all have. A Zone whose
recovery is exhausted does not take part, so it cannot stall the others. An
output that stops consuming while its Player plays is lost and recovered (see
[Recovery](#recovery)), so it cannot hold a drain open either.

A Player whose every requested output has failed cannot drain, because nothing
consumes its audio. Once the Player is playing with its queue not finished, at
least one attached Zone has its output requested and every such Zone reports
`failed` with its recovery attempts exhausted, the engine pauses the Player at
its current position and wakes the host. The Player then reports `paused` and
not drained. A host waiting for a drain also stops on this state: the Player
paused while its Zones report `failed`. Closing a Zone's output, requesting it
again once the Zone reports `closed`, and playing resumes from that position.

## Engine thread

One `PlayerEngine` thread per Player is the single decode producer, as the SPSC
queues require. It is spawned when a Player first receives a source and
registered with `work.Registry`, so `drain`, `destroyPlayer` and `shutdown`
join it. Each pass adopts a published zone set, reclaims consumed blocks,
decodes one canonical block per Zone budget, fans it out, services output
opening and bounded recovery, publishes position, and parks on a futex.

The Player's `SourceQueue` is plain state, so loading a source or seeking
quiesces the engine first. A quiesce that follows a release waits for one full
engine pass before suspending again, so back-to-back control calls cannot
starve it.

The engine never resolves a handle: `core/handle.zig` performs no locking, so a
generational handle does not protect a pointer a worker already dereferenced.
The control lane publishes an immutable `[]*ZoneRuntime` into an unclaimed slot
with one atomic store; the engine adopts it at a pass boundary and bumps an
acknowledgement counter; the control lane frees a Zone or closes its output
only after observing the acknowledgement.

### Parking and wakeups

A busy engine parks for 2 ms. An idle engine parks with no timeout and costs no
wakeups. It is idle when its next pass would do nothing: no seek or
format-switch successor is pending; the Player is not playing, or has its queue
decoded with every draining Zone drained and no entry left to open (a Player
whose requested outputs have all failed is paused, see [Zones](#zones)); the
clock Zone's position has been sent as a hint; and every attached Zone is
settled (output active in the decoded format and silenced or empty, or no
output and nothing to open one for). A Zone that is opening, lost or waiting
out its recovery backoff keeps the engine busy, as does a suspended engine.

Everything that can end idleness wakes the engine after the write it must act
on: `wakeUp` (play, pause and output requests), zone publication, `quiesce`,
`release`, the first cancellation request through the waker the engine gives its
`work.Registration`, and output state changes. The PipeWire backend calls the
output's waker from the stream's state-changed callback on its loop thread,
never from the process callback. An engine sets that waker on every output it
adopts or opens and clears it on every output it drops or leaves open at exit;
setting it takes the stream loop's lock, so an output that outlives its engine
never calls into a freed one. Telemetry cadence, recovery backoff and the stall
timeout use a monotonic clock.

## Player DSP

Every Player runs one chain, `PlayerDsp` in `audio/dsp.zig`: preamp, an
equalizer, stereo crossfeed, then volume gain. It runs on the engine thread
over canonical float32 PCM, after decoding and before fanout. With equalizers
and crossfeed off the chain is the volume gain alone. Crossfeed applies to
two-channel audio; other layouts pass through. `dsp-bench`
(`zig build -Doptimize=ReleaseFast dsp-bench`) times the vector kernels in
`audio/kernels.zig`.

### Equalizers

The equalizer is the ten-band graphic one or the parametric one, never both:
turning either on turns the other off.

The graphic equalizer has peaking filters at 31 Hz to 16 kHz, one octave apart,
with Q 1.41, up to 12 dB per band and a preamp of -24 to +12 dB.

The parametric equalizer (`ParametricEqualizer`) holds up to 16 filters, each a
peak, low shelf, high shelf, low pass, high pass or notch with its own
frequency (20 Hz to 20 kHz), gain (within 24 dB, on peaks and shelves) and Q
(0.1 to 20, or 0.3 to 2 on a shelf), and a preamp of -24 to +6 dB.

Every filter is an RBJ Audio EQ Cookbook biquad designed in f64
(`audio/equalizer.zig`) and run as one cascade. `audio/eq_text.zig` reads and
writes the EqualizerAPO text format (`Preamp:` and
`Filter N: ON PK Fc … Hz Gain … dB Q …` lines); it rejects lines and filter
types it cannot run rather than dropping them.

Before each pass the engine calls `prepare`, which rebuilds coefficients when
the settings or canonical rate changed. The rebuild omits disabled and
zero-gain filters and those too close to Nyquist to design (at or above
Nyquist for a graphic band, 0.45 of the rate for a parametric filter).
`prepare` clears filter history when the transport epoch or channel count
changed, so a seek never rings with old audio. History survives a change of
only a filter's gain, frequency or Q, or another filter's toggle, so a band
moved during playback does not click; it is keyed by the filter's index in the
setting, not its slot in the cascade.

The control lane writes settings only while the engine is quiesced. Queued
blocks are not discarded, so a change is gapless and takes effect a
render-ahead later.

## ReplayGain

Volume is one Player-scope ramped multiplier (`Gain`). Loudness correction
belongs to the audio and is applied by the `SourceSession` that decodes it,
from a figure attached when the entry was opened: a Player-level or per-block
correction is wrong during a gapless transition, when the pipe holds blocks of
two entries and one canonical block is filled from two decoders. Every path
that produces a session goes through one opener, so a hard load, an
auto-advance, a format switch and a seek re-open all carry the right
correction. [analysis.md](analysis.md#album-replaygain) covers how figures are
measured and chosen.

The Player's ReplayGain choices (mode, preamp, untagged fallback, peak
protection) are one packed 64-bit `ReplayGainSettings` word, loaded once per
decoded block and replaced with a compare-and-swap, so setters need no quiesce
and take effect a render-ahead later. Each session keeps its corrections
uncapped (`EntryReplayGain`: track and album gain, each with its peak), and
`EntryReplayGain.applied` resolves mode, preamp, peak cap and fallback per
decode. Host reads of the audible entry's corrections go through a seqlock the
engine thread writes when the audible entry changes.

`smart` mode needs `EntryReplayGain.shares_release`, decided by
`PlaybackQueue.sharesRelease` wherever an entry is opened. A reorder changes
neighbours without opening anything, so the control lane calls
`PlayerEngine.refreshSharedRelease` under its quiesce to re-decide every opened
session; audio already decoded keeps its gain.

## Resampling

Orca runs no resampler on the playback path. Each stream opens at the entry's
source rate, and a format change between entries reopens the output; PipeWire
may resample when the device runs at another rate. The only Orca resampler is
`resampler.SampleRate`, libsamplerate behind `audio/samplerate_shim.c`, which
brings audio to 11,025 Hz for AcoustID fingerprints; see
[analysis.md](analysis.md#acoustid-fingerprints).

## Signal path

Signal-path reports list the processing nodes, format, rate and layout
conversions, direct-RT eligibility and total algorithmic latency. They
distinguish source PCM from canonical float32 working PCM and conservatively
explain why a path is not bit-perfect. The reasons are:

- `sample_processing`: any ReplayGain, either equalizer, crossfeed, a volume
  that is not exactly 1, or audio processed under earlier settings that has
  not played yet;
- `sample_rate_conversion`: a stream rate that is not the source's, or a
  device rate that is not the stream's;
- `channel_layout_conversion`: a stream channel count that is not the
  source's, or a device channel count that is not the stream's;
- `sample_format_conversion`: a 32-bit integer or 64-bit float source, which
  float32 cannot hold exactly, or a device sample format that cannot hold the
  source's values: an integer device for a float or 32-bit integer source, or
  an integer device with fewer bits than an integer source;
- `lossy_source`: a lossy codec;
- `path_unknown`: the path cannot be confirmed because nothing is audible, the
  source declares no sample format, no output is open, or the device has not
  reported its rate or its format.

Widening an 8-, 16- or 24-bit integer source to float32 is exact, so it is not
a reason; the report marks it `widened_exactly`. For the same reason the
float32 stream reaching an integer device is not a reason by itself: a device
with at least the source's bits can carry every value float32 holds for it. A
path is eligible only when no reason applies, so only with a declared source
format, an open output, and a device that reported its rate, sample format and
channels (see [Device format](#device-format)). Eligibility covers the stream
Orca hands the backend and the device's format as PipeWire reports it; it does
not assert a bit-perfect native path.

The report describes the audio being heard, not only the settings that apply
to the next block. A setting takes effect a render-ahead later, so
`sample_processing` stays while any of the Player's Zones still holds audio a
gain or DSP stage changed: queued, being rendered, or rendered and not yet
reclaimed by the engine. Each Zone's block pool marks a block processed when
the engine fans it out and clears the mark when the engine reclaims the block;
the render callback never reads or writes the mark. The settings fields
(`replay_gain_db`, the equalizers, `crossfeed` and `volume`) always describe
the current settings, so the reason can stand while all of them read neutral.
The check is conservative: a processed block a seek made stale counts until
the engine reclaims it, and a setting that changes the samples is reported at
once, before the audio it changed is audible.

`Runtime.playerSignalPath` reports the live path of one Player: the audible
entry's source format, codec and applied ReplayGain (the track's, the album's
or the track's in place of a missing album figure, and for an album gain the
track gain it replaced); the equalizer and crossfeed; the volume the gain node
is applying, not its target; the format the clock Zone opened its stream with;
`device_quantum_frames`, the frames per period the device asks for (null until
the stream has run); and `output_kind`, how the device is attached. A decoder
that declares no source format, as lossy decoders do, leaves `source_declared`
false: `source` then holds the canonical format, and only its rate and channels
are meaningful.

## PipeWire output

On Linux, a narrow C shim (`audio/backends/pipewire_shim.c`) contains PipeWire
headers and native object lifetime. An `OutputSession` owns one autoconnected
float32 playback stream. PipeWire's RT process callback writes directly into
mapped backend buffers by calling an Orca-owned `RenderContext`; it performs
only queue operations, PCM copying, atomic diagnostics and silence filling.
Stream creation and destruction stay on the control side. Output requests
translate robust, interactive, custom or explicit latency targets into PipeWire
node latency. Timing snapshots report sample time, monotonic host time,
callback quantum, queued and converted frames, and non-negative graph and
device delay. `zig build pipewire-live-smoke -- ID` verifies a short silent stream
on the silent sink whose device id `scripts/silent-sink.sh` printed (or
`ORCA_TEST_DEVICE`); it refuses a missing, unknown or non-virtual device.
Normal tests need no live audio service.

### Stream rate

Each stream requests `node.rate` at the entry's source rate. PipeWire honours
it only when the graph's `clock.allowed-rates` permits it and no other stream
holds the device at another rate; otherwise it resamples. The device rate read
from the stream's timing is reported as `device_rate`. It adds
`sample_rate_conversion` when it differs from the stream's rate, and
`path_unknown` until it is known.

An inactive stream stays open and linked but holds no rate, so a paused or
stopped Player releases the device: another stream may then move the graph to
its own rate, and when no stream runs the sink suspends. Playing again requests
the source rate anew, which PipeWire honours only if no other stream now holds
the device. While the sink is suspended, `device_format` is unknown.
`scripts/check-rate-release.sh` checks this in `zig build test` under
`scripts/headless-audio.sh`, and skips outside that private server: with Orca
paused at 44.1 kHz, a 48 kHz stream moves the graph to 48 kHz; with Orca
playing, the graph stays at 44.1 kHz.

The check waits for Orca's streams to go idle before the 48 kHz stream joins.
On PipeWire 1.4.2, which the CI Debian 13 job runs, a stream that joins the
graph before then keeps the running rate; PipeWire 1.4.11 and 1.6.9 switch to
the new stream's rate.

### Device format

The device's own format is the format of the sink node the stream feeds. Once
the stream is paused or streaming, the shim follows the registry links out of
the stream's node and, on the PipeWire loop thread, reads the linked node's
`SPA_PARAM_Format` again whenever its params change. It packs sample format
(S16, S24, S24_32 or S32, little-endian or planar, or F32), rate and channels
into one atomic that the timing read loads; the render callback never touches
it. The Zone refreshes it on activation and every 16 engine passes, and the
signal path reports it as `device_format`.

A known format adds `sample_rate_conversion` when its rate is not the stream's,
`channel_layout_conversion` when its channel count is not the stream's, and
`sample_format_conversion` when it cannot hold the source's values (see
[Signal path](#signal-path)). Unknown is explicit, never guessed, and adds
`path_unknown`, so the path is never eligible while it lasts. The format is unknown
while the node is suspended, before PipeWire has answered, for a virtual sink
such as `support.null-audio-sink`, for any other sample format, and on a
backend other than PipeWire. A sink that is itself processing, such as a filter
chain, reports its own input format, not that of the hardware behind it.

### Recovery

A lost output is closed and reopened with bounded attempts while its Player
epoch and prepared render path remain intact. Recovery state belongs to each
Zone; another Zone stays active if reopening fails. Each reopen counts as one
attempt, whether it succeeds or not. The count returns to zero only once a
reopened output has handed back `zone_runtime.block_count` (32) blocks, or when
the host closes the output. When `zone_runtime.max_recovery_attempts` (3)
attempts are counted and the output is lost or fails to open again, the Zone
reports `failed` and returns every prepared block to its pool. A device that
reopens but never plays, such as device 0 following a default sink that does
not consume, therefore fails after its fourth loss. The Zone stays failed until
the host closes its output and, once the Zone reports `closed`, requests it
again, which starts a new set of attempts. When every requested output of a
playing Player has failed this way, the engine pauses the Player (see
[Zones](#zones)), and the host plays it again after requesting the outputs.

An output that stops consuming is handled in two stages. A pass counts as
stalled for a Zone when its Player is playing, the Zone holds prepared blocks
and its output handed none back since the previous pass. A block handed back,
a paused or stopped Player, or an empty Zone resets the count.

1. After `ZoneRuntime.stall_limit` (64) consecutive stalled passes, the Zone
   stops holding the shared decode cursor, so the other Zones keep playing. It
   rejoins once its output hands a block back.
2. Once the stall has also lasted `engine.stall_timeout_ns` (2 s) on the
   engine's monotonic clock, measured from the first stalled pass or from the
   output's latest open, whichever is later, the output is lost and recovered
   as above.

The pass count alone is not enough: control operations run many passes inside
one device quantum, and a sink resuming from suspend reports active before its
first callback.

### Device selection

Discovery returns bounded Orca-owned snapshots and uses PipeWire object serials
for stream targeting. Device ID zero delegates selection to the server, which
follows the default sink. Any other device ID fails closed: the stream sets
`target.object` with `node.dont-fallback` and `node.dont-reconnect`, so
WirePlumber errors the stream instead of linking it to the default sink when
the device is missing, and destroys it instead of moving it when the device is
removed. Opening such a stream waits up to 2 s for a link out of its node; an
error or no link in that time fails the open. A missing or removed device
therefore exhausts the Zone's recovery attempts and reports `failed`, and no
audio reaches a device the user did not choose.
`scripts/check-output-fail-closed.sh` checks this in `zig build test` under
`scripts/headless-audio.sh`, and skips outside that private server.

### Device discovery

Each snapshot carries a `DeviceKind`: `usb`, `pci`, `bluetooth`, `hdmi`,
`virtual` or `unknown`. A `support.null-audio-sink` node is virtual, a BlueZ
node or device is Bluetooth, an ALSA `hdmi:` path or HDMI profile is HDMI, and
otherwise `device.bus` decides. Only the first 64 sinks are bound; later ones,
and device zero, report `unknown`. A Zone resolves its device's kind with one
discovery when the engine thread opens its output, never in the render
callback; `playerSignalPath` only reads it.

`enumerateOutputDevices` also fills each snapshot's `DeviceCapabilities`: the
lowest and highest sample rate, the bit depths (16, 24 and 32, float32 counting
as 32), the most channels, the state and the bus. Discovery reads each bound
sink's `SPA_PARAM_EnumFormat` params; only `audio/raw` formats count, and a
range or step choice gives its bounds. The round is bounded at 500 ms; a node
that has not answered by then, or answered with no rate, reports
`capabilities` null. Node state `running` and `idle` are `active`, `suspended`
is `suspended`, and `error`, `creating` or no state are `unavailable`. Virtual
sinks report what PipeWire answers too. Discovery runs on the caller's thread
with its own `pw_loop`; every listener is removed and every proxy destroyed
before it returns, on the timeout path as well.

## Sources and codecs

A `SourceSession` performs bounded positional reads through its Decoder and
converts samples to canonical float32 on the producer lane. A bounded
`CodecRegistry` owns codec selection. Playback sees only the Orca `Decoder`
interface (source and canonical formats, optional frame count, read, seek and
lifetime); each codec reads an Orca `ReadableSource` behind its own adapter.
[The formats and codecs section](architecture.md#formats-and-codecs) records
which library each codec wraps.

`orca-cli play AUDIO [DEVICE_ID]` plays one file through this path and reports
played frames, underruns and backend quantum. Without a device ID it uses
device 0, the system default output, which is real hardware; tests pass a
device from `scripts/silent-sink.sh`. It exits with an error once the Zone's
output reports `failed` with its recovery attempts exhausted.

## Source queue and playback queue

A Player owns the active `SourceQueue`: one current SourceSession and one
prepared successor. When decoding reaches the current source's end, it appends
compatible successor blocks behind the current blocks already in the render
queue, then releases the exhausted decoder, so transitions are primed before
the audible end and need no callback-side source switch. A successor primed
before the current source's end, such as one kept through a seek back inside
the current entry, fills the rest of the block that holds the current source's
last frame. Transitions are gapless; there is no crossfade.

A `PlaybackQueue` sits above it: bounded track references, an audible cursor, a
decode cursor, repeat and shuffle. Only the control lane and the engine thread
mutate it, under the same `quiesce`/`release` handshake as `SourceQueue`.
Enqueueing past capacity applies backpressure. The entry count and both cursors
are atomics, so a host poll never stops the producer.

The audible cursor is derived from the published `entry_serial`, and every
user-facing operation resolves from it, so a skip during a gapless transition
advances one entry rather than two. Now-playing, `playerStatus` and listen
tracking take the audible Track from the serial through the queue's serial
records, never from the audible cursor, which trails the serial across a
gapless transition. A read whose serial moves while it resolves is retried,
then names no Track; serial 0 (nothing audible, as after a stop) names the
cursor's entry. A hard load sets the serial to 0, moves the cursor and adopts
the new serial only once the queue records it, so a host never reads a serial
the queue cannot name. Serials continue across a replaced `SourceQueue`,
because a repeated serial would resolve to the wrong entry.

### Seek

A seek resolves against the audible entry, not the decoded one: once the
producer has advanced onto the successor, the audible entry has no decoder to
seek. The control lane records the request against the audible serial, stamps
the new position and publishes the epoch, which retires the successor's
decode-ahead work. The engine completes the seek on its next pass by
re-opening the audible entry, seeking it and returning both cursors to it; the
transition into the following entry is primed again from there. A seek inside
the entry still being decoded re-opens nothing.

### Skip, previous, shuffle and repeat

A user skip is a hard switch: the epoch bump makes the callback discard
prepared audio. A hard load also makes its entry the audible one at once,
because the callback publishes no serial under the new epoch until that
entry's first block renders.
`previous` restarts the current entry past three seconds and otherwise moves
the cursor back. Shuffle generates a permutation and keeps the playing entry at
the cursor, so toggling it does not restart the song; toggling it moves each
serial record to its entry's new position, and removing an entry forgets its
record. `repeat_one` re-opens a fresh session for the same entry rather than
seeking the one still draining into the pipe.

`next`, `previous` and a queue jump open their target on the control lane,
under the quiesce, before anything moves. Only an opened entry ends the audible
one as `skipped` and is hard-loaded. `next` and `previous` step over an entry
that fails to open, recording it as an open failure, for at most
`max_consecutive_open_failures` (8) entries and never back onto the playing
one. The last entry stepped over is recorded again after the hard load, whose
own clear would otherwise erase it. When every candidate fails, the last open
error is returned and the cursor, the loaded sources, the epoch and the history
are untouched, so the playing entry keeps playing. A queue jump does not step.

### Moving entries

Moving an entry happens under one `quiesce`, and everything keyed by position
follows it: both cursors, the position of a successor held for a format switch,
and every serial record. Under shuffle only the permutation changes. The
entries the engine has committed to cannot move (the audible and decoding
entries while the Player holds audio, and a held successor), and nothing may
land after the audible entry and up to the last committed one. Both are refused
with `QueueEntryInUse`, as is removing a committed entry. Under `repeat_all` the
committed span can wrap past the end of the queue, and the refusal follows it.

### Auto-advance

At `current.eof` with no successor, the engine thread resolves the next entry,
opens it and primes it. A canonical format mismatch is not fatal: the successor
is held opened but unprimed until every draining Zone has drained, then the
outputs are reopened at the new format and it is hard-loaded. Transitions are
gapless when formats match and gapped when they do not. A decoder that fails
part-way ends its entry rather than stalling the queue, and an entry that
cannot be opened is stepped over, with consecutive failures bounded (8).

### Stop after current

`Runtime.playerSetStopAfterCurrent` arms a one-shot stop at the end of the
entry being heard. While armed the engine never primes a successor, so nothing
past the stop is decoded. Arming under the quiesce takes back what the engine
may have lined up: a held format-switch successor is released; a primed
successor not yet decoded is dropped; when decoding has crossed into the
successor, the audible entry is re-opened at the heard position through the
deferred seek, at the cost of a short gap. When the Player has drained with the
flag set, the engine clears it and stops the transport. The sources stay
loaded, so the queue history records the entry as finished and a later play
starts the entry after it.

## Playback failures

`PlayerStatus.last_failure` names the last queue entry that could not be
opened, as a `PlaybackFailure`: its Track id and a reason (`file_missing`,
`folder_unavailable`, `codec_unavailable`, `decode_error` or
`unsupported_channels`). `folder_unavailable` means the Track's root or volume
is gone, so its files are not marked missing; `file_missing` means the root is
there but the file is not.

Playback takes mono and stereo sources only. `LoadedSource.open` refuses a
decoder reporting more than two channels with `UnsupportedChannelCount` before
any output opens, so the check covers every open: a played or loaded file, a
queue cursor, the gapless next entry, a format switch and a seek. The reason is
`unsupported_channels`. A refused next entry is an ordinary open failure: the
entry before it plays to its end and the engine steps past the refused one.

The failure lives in `Player.open_failure`, an `OpenFailureSlot` readable from
any host thread. Three rules keep it from naming the wrong Track:

- One writer at a time, never the callback. The lane that owns `sources`
  writes it: the engine thread inside `pass`, the control lane under `quiesce`,
  or either before an engine exists.
- Track and error are written as one pair at the failure site, under a sequence
  counter that readers retry on. The failure is never derived from the cursor
  or decode position, which have moved on by the time a host looks.
- A clear never overtakes a newer failure. A successful open clears the failure
  only once that entry becomes audible: `loadQueueEntry` clears it directly,
  and a gapless prime stores the entry's serial as a pending clear that
  `publishPosition` applies once the rendered serial reaches it (the comparison
  wraps, because serials wrap and skip 0). Recording a failure resets the
  pending clear.

## Queue history

Each Player keeps the last `queue_history_capacity` (100) entries that stopped
playing, newest first, as `QueueHistoryEntry` values: the `TrackRef`,
`ended_at_ms` in Unix milliseconds, and a `QueueHistoryReason`.

- `finished`: the audible entry serial moved on by itself, or the Player
  drained. The control lane notices this when it samples Players, bound or not,
  at most every 100 ms while it processes commands, and before any history
  read.
- `skipped`: next, previous to another entry, or a queue jump.
- `replaced`: playing new Tracks, loading a file, or clearing the queue.

Stop records nothing, because the entry stays current and plays again from its
start; closing the Library a Player is bound to stops it the same way.
`previous` restarting the current entry records nothing. Each audible entry is
recorded at most once, and the 101st entry drops the oldest. An entry that
starts and ends between two samples is never seen. A serial with no queue entry
behind it, such as a file loaded with `playerLoadFile`, records nothing.

The history lives on the control lane in memory only; a new runtime starts
empty. It never records a listen: listens come only from the Player's
`ListenTracker`. `playerQueueHistory` reads raw entries,
`playerQueueHistoryTracks` reads them as rows carrying each entry's
`TrackSummary`, null for a Track that left its Library or a closed Library, and
`playerClearQueueHistory` empties the ring.
