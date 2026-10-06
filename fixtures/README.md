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

`providers/musicbrainz-release-lookup.json` is MusicBrainz's answer to
`/ws/2/release/047a4aae-27f8-4f2d-92fb-214fd8dc865a?fmt=json&inc=recordings+artist-credits+release-groups`
for the 2014 deluxe edition of Hot Space: two discs of 11 and 8 tracks, each
with its recording and artist credits. MusicBrainz data is CC0.

`providers/musicbrainz-artist-lookup.json`, `providers/wikidata-entity.json`,
`providers/wikimedia-commons-imageinfo.json` and
`providers/wikipedia-summary.json` are written by hand in the shape of the
answers to the requests artist info makes for Aminé: MusicBrainz's
`/ws/2/artist/12398bf3-1b99-47b7-930c-f3956773f35a?inc=url-rels+genres+artist-rels`
(born 1994, a person, Wikidata item `Q27830860`, an `image` relation to a
Commons file among 20 URL relations), Wikidata's `wbgetentities` for that item
(a P18 image, a P2031 work period starting 2014, and `enwiki` and `dewiki`
sitelinks), Commons' `imageinfo` for
the image (`CC BY 2.0`, an HTML author credit, an 800-pixel rendering on
`upload.wikimedia.org`), and Wikipedia's REST summary of the article. The
text is invented for the tests and is not copied from the services.

`providers/listenbrainz-popularity.json`,
`providers/listenbrainz-labs-similar-artists.json` and
`providers/musicbrainz-release-group-lookup.json` are written by hand in the
shape of ListenBrainz's `POST /1/popularity/artist` answer for Aminé (9,025
users), ListenBrainz Labs' `similar-artists/json` answer for Aminé (15
artists, one of them Aminé, out of score order), and MusicBrainz's
`/ws/2/release-group/3918b90b-340e-3779-9d7e-ba1593653498?inc=url-rels+genres`
for Hot Space (Wikidata, AllMusic and two Wikipedia relations, and six genres, two tied
for third). The counts and scores are invented for the tests.

`providers/musicbrainz-release-group-browse.json` is written by hand in the
shape of MusicBrainz's
`/ws/2/release-group?artist=12398bf3-1b99-47b7-930c-f3956773f35a&inc=artist-credits&limit=100&fmt=json`
answer for Aminé: a `release-group-count` of 7 and six groups, among them one
credited with another artist joined by ` & `, a single with a `feat.` guest,
and one with no primary type and an empty first release date. The IDs and
the counts are invented for the tests.

`audio/fingerprint-reference.mp3` is 10 seconds of generated mono audio at
44.1 kHz, encoded by FFmpeg's libmp3lame at 64 kb/s: a melody of tones that
change every 250 ms, an upward chirp, a downward chirp and seeded pink noise,
so its spectrum changes enough for a meaningful Chromaprint fingerprint. It
contains no third-party media. The command that made it, run from
`fixtures/audio` with FFmpeg 9.0.1:

```sh
ffmpeg -f lavfi -i "aevalsrc='0.3*sin(2*PI*(220*pow(2,mod(floor(t*4)*7,12)/12))*t)+0.25*sin(2*PI*(300*t+120*t*t))+0.15*sin(2*PI*(3000-250*t)*t)':s=44100:d=10" \
  -f lavfi -i "anoisesrc=color=pink:seed=7:amplitude=0.08:sample_rate=44100:duration=10" \
  -filter_complex "[0:a][1:a]amix=inputs=2:normalize=0,aformat=sample_fmts=s16:channel_layouts=mono" \
  -c:a libmp3lame -b:a 64k -ar 44100 -ac 1 fingerprint-reference.mp3
```

`audio/fingerprint-reference.fpcalc.txt` is the output of Chromaprint 1.6.1's
`fpcalc -raw -length 120 fingerprint-reference.mp3`: the duration and the raw
fingerprint. The fingerprint parity test compares Orca's fingerprint of the
MP3 with it. `audio/fingerprint-reference.lrc` is a synced sidecar for the MP3,
with lines at 1, 3, 5.5 and 8 seconds.

`audio/cbr-noxing-reference.mp3`, `audio/vbr-xing-reference.mp3` and
`audio/truncated-reference.mp3` are generated with FFmpeg's libmp3lame: a
constant-bit-rate stream with no VBR header, a variable-bit-rate stream with
Xing and LAME headers, and a stream cut mid-frame so decoding must fail
cleanly. None contains third-party media.

`audio/midside-reference.flac` is a FLAC stream built from the deterministic
integer sequence of `midSideProbeSample` in `liborca/codec/flac.zig`, with two
near-opposite channels whose side signal is odd in every
frame, so the encoder chooses mid-side stereo and a decoder that skips the
low-bit restoration is wrong on every sample (see `docs/codecs.md`). The
decoder test regenerates the expected samples from the same sequence. It
contains no third-party media.

`audio/lyrics-synced.flac` is `audio/generated-reference.flac` retagged with
synced LRC in a `LYRICS` comment:

```sh
printf '[ar:Orca Fixtures]\n[ti:Synced FLAC]\n[00:01.00]First line of the FLAC\n[00:02.50]Second line of the FLAC\n' > lyrics-synced.lrc
metaflac --remove-all-tags --set-tag=TITLE="Synced FLAC" \
  --set-tag=ARTIST="Orca Fixtures" --set-tag=ALBUM=Lyrics \
  --set-tag=TRACKNUMBER=1 --set-tag-from-file=LYRICS=lyrics-synced.lrc \
  lyrics-synced.flac
```

`audio/lyrics-sylt.mp3` is `audio/tagged-reference.mp3` with its ID3v2 tag
replaced by mutagen: a `USLT` frame holding one unsynced line, and a `SYLT`
frame (UTF-8, `eng`, millisecond timestamps, lyrics) with lines at 1 and
2.5 seconds. `audio/lyrics-plain.m4a` is `audio/tagged-reference-aac.m4a`
with its tags replaced by mutagen and two plain lines in `©lyr`.

`audio/explicit-reference.mp3` is `audio/tagged-reference.mp3` with its
ID3v2 tag replaced by mutagen: `TIT2` "Explicit MP3", `TPE1` "Orca
Fixtures", `TALB` "Explicit References", `TRCK` "1/2" and a `TXXX`
`ITUNESADVISORY` of `1`. `audio/explicit-reference.m4a` is
`audio/tagged-reference-aac.m4a` with its tags replaced by mutagen: `©nam`
"Explicit AAC", the same artist and album, `trkn` 2 of 2 and `rtng` 1. Both
read as explicit, and together they make a two-track album.

`playlists/relative.m3u8` is a UTF-8 extended M3U with relative paths, a
percent-encoded `file://` URI, an `http://` stream and `#EXTINF` lines.
`playlists/latin1.m3u` is Latin-1 with CRLF line ends, and
`playlists/bom.m3u8` starts with a UTF-8 byte order mark and uses CRLF. They
seed the M3U parser's tests and fuzz target; no path in them names a real file.

`fuzz/smart-playlist/*.json` are hand-written smart playlist rules that seed
the rules fuzz target: the documented example, every field type and operator
(with a hostile SQL string as a value), nesting to the deepest allowed level,
and an empty group.

`eq/hd650.txt` is a hand-written EqualizerAPO file shaped like a headphone
correction: a -3 dB preamp, a low shelf, two peaks and a high shelf. Its
values are made up, not taken from a measurement. The EqualizerAPO parser's
tests read it, and it is the file to pass to `orca-cli play-tracks --peq`,
`peq-check` and `peq-response`.
`fuzz/eq-apo/*.txt` are hand-written EqualizerAPO files that seed the
EqualizerAPO fuzz target: a longer correction, every filter type with a
`BW Oct` bandwidth and summed preamps, a CRLF file with a byte order mark,
lower case and stray spacing, and a file with a band pass filter and a
`Channel:` line that the parser rejects.
