# Storage capabilities

Decoders and analyzers consume `ReadableSource`, a small capability interface
for positional reads, total size, and stable observed identity. It deliberately
does not expose path strings or filesystem handles.

`LocalFileSource` is the desktop implementation. It owns an open file, captures
size/inode/modification identity at open time, and supports offset reads without
changing shared stream position. Provider, mobile, and permission-sensitive
sources can implement the same contract without pretending to be local paths.

Container sniffing uses source bytes rather than filename extensions. The first
registry recognizes WAV, AIFF, FLAC, MP3, MP4, Opus, Vorbis, and WavPack magic.

## Incremental scanning

The scanner recursively walks a configured root, opens candidate files through
`LocalFileSource`, and compares path plus storage identity against the
`observed_files` table. Unchanged files avoid format or metadata work. Changed
audio files commit in bounded transactions through the Library's shared write
lane; unsupported and transiently unreadable files are counted without
invalidating successful batches.

Cancellation is checked before filesystem work and between entries. A cancelled
or interrupted scan is resumable by restarting it: already committed unchanged
identities are skipped, so no traversal-order checkpoint is required. Filesystem
watchers will feed the same reconciliation path as hints rather than becoming an
authoritative source of state.

Platform watcher adapters submit root-scoped hints through a bounded channel.
Unread storms coalesce to one hint per root, including explicit overflow hints;
consumers respond with normal scanner reconciliation. No watcher event directly
inserts, removes, or mutates observed state.

The Linux adapter uses nonblocking inotify and translates native changes,
queue overflow, and root move/delete events into those hints. Watcher coverage
is an acceleration only; startup/manual reconciliation remains responsible for
discovering anything not represented by a delivered native event.
