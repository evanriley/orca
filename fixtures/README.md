# Test fixtures

Small redistributable media and pathological-input fixtures belong here. Large
or generated performance corpora must be produced on demand and remain outside
Git.

`audio/generated-reference.flac` is 480 stereo frames generated from a
deterministic 16-bit ramp and encoded with FFmpeg's FLAC encoder.
`audio/generated-reference.qoa` is a hand-built, single-channel 20-frame QOA
stream with zeroed predictor state. `audio/stereo-reference.qoa` is
`audio/generated-reference.wav` encoded with the reference `qoa.h` encoder:
two frames, 5,120 and 4,480 frames long, so seeks cross a frame boundary. Neither fixture contains third-party media.

`audio/id3-prefixed-reference.flac` and `audio/id3-footer-prefixed-reference.flac`
are `audio/generated-reference.flac` behind a synthetic ID3v2.4 tag — 210 bytes
without a footer, 220 with one. Some taggers staple an ID3v2 tag to the front of
a FLAC stream, and 104 files in the reference library do; these fixtures keep
that case covered without it. The tag is deliberately longer than the 64-byte
prefix container detection reads first, so resolving it requires the second read
rather than a longer one.

`audio/covered-reference.flac`, `audio/covered-reference.mp3` and
`audio/id3-covered-reference.flac` carry a 217-byte synthetic PNG — a 16x16
FFmpeg `testsrc` frame — as a front cover, in a FLAC `PICTURE` block, an ID3v2
`APIC` frame, and a `PICTURE` block behind an ID3v2 tag long enough to defeat
the 64-byte prefix read. `audio/covered-alternate-reference.flac` carries a
*different* 138-byte cover, so a test asserting which of a Release's tracks
supplied its artwork can tell them apart. No fixture contains third-party media.

`audio/tagged-reference.opus` is `audio/generated-reference.wav` encoded with
FFmpeg's libopus encoder at 64 kb/s, tagged with title, artist, album, track,
date and genre. `audio/tagged-reference.ogg` is `audio/tagged-reference.flac`
encoded with FFmpeg's libvorbis encoder at quality 3, carrying the FLAC file's
tags. Both are 200 ms long.

`audio/tagged-reference-alac.m4a` is `audio/tagged-reference.flac` encoded with
FFmpeg's ALAC encoder, carrying its tags. `audio/tagged-reference-aac.m4a` is
`audio/generated-reference.wav` encoded with FFmpeg's AAC encoder at 128 kb/s
with title, artist, album artist, album, track 2/5, disc 1/2, date and genre.
`audio/covered-reference.m4a` is the same audio carrying the 217-byte PNG cover
in a `covr` atom. `audio/chirp-reference-aac.m4a` is 200 ms of a stereo chirp,
`0.4 sin(2π(200t + 2000t²))` left and `0.4 sin(2π(300t + 1500t²))` right at
48 kHz, encoded at 192 kb/s; tests regenerate the source from the formula to
check alignment.

`audio/extensible-reference.wav` is `audio/generated-reference.flac` written by
FFmpeg as 24-bit PCM, which FFmpeg stores as `WAVE_FORMAT_EXTENSIBLE`.

`audio/tagged-reference.aiff` is `audio/tagged-reference.flac` written by FFmpeg
as 16-bit big-endian AIFF with its tags in an `ID3 ` chunk.
`audio/sowt-reference.aifc` and `audio/generated-reference-24.aiff` are
`audio/generated-reference.flac` as little-endian (`sowt`) AIFC and as 24-bit
AIFF.

`audio/tagged-reference.wav` is `audio/generated-reference.flac` as WAV with
FFmpeg's `LIST`/`INFO` tags. `audio/id3-tagged-reference.wav` is the same file
with the `ID3 ` chunk of `audio/tagged-reference.aiff` appended as an `id3 `
chunk, so it carries two different tags. `audio/covered-reference.aiff` carries
the 217-byte PNG cover in its `ID3 ` chunk.

`audio/covered-reference.opus` and `audio/covered-reference.ogg` are the tagged
Ogg fixtures with the 217-byte PNG cover added as a `METADATA_BLOCK_PICTURE`
comment, by `opustags --set-cover` and `vorbiscomment` respectively.

`audio/tagged-reference.aac` is the AAC frames of
`audio/chirp-reference-aac.m4a` remuxed by FFmpeg into ADTS behind an ID3v2
tag. ADTS keeps the 1,024 frames of priming the MP4's edit list trimmed.

`providers/musicbrainz-recording-search.json` is MusicBrainz's answer to the
recording search `recording:"Under Pressure" AND artist:"Queen"
release:"Hot Space"` (`limit=10`, `fmt=json`), trimmed to four recordings
with the artists' aliases removed. MusicBrainz data is CC0. It covers a joined
artist credit, a recording with no length, several releases per recording and
a track numbered `B6`.

`audio/chromaprint-test.mp3` and `audio/chromaprint-test.fpcalc.txt` are
`tests/data/test.mp3` and `tests/data/test.mp3.fpcalc.out` from Chromaprint
1.6.1, copied unchanged: 10 s of audio and `fpcalc -raw`'s fingerprint of it.
Chromaprint is MIT-licensed. The fingerprint parity test compares Orca's
fingerprint of the MP3 with the reference.

`playlists/relative.m3u8` is a UTF-8 extended M3U with relative paths, a
percent-encoded `file://` URI, an `http://` stream and `#EXTINF` lines.
`playlists/latin1.m3u` is Latin-1 with CRLF line ends, and
`playlists/bom.m3u8` starts with a UTF-8 byte order mark and uses CRLF. They
seed the M3U parser's tests and fuzz target; no path in them names a real file.
