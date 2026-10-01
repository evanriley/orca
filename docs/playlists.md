# Playlists and ratings

Playlists and star ratings are kept in the Library. Both belong to a
Recording, not to a Track or a file, for the reason love and hate do: an edit
that moves a Track to another Release or position gives it a new id, while
`projection.zig` keeps its Recording. See
[database.md](database.md#playlists-and-ratings) for the tables.

## Ratings

- A rating is 1 to 100; no rating is unrated. Frontends set whole stars,
  20 per star; the API accepts any value in range so that ratings read from
  other software keep their precision.
- `librarySetRating(library, track_ids, ?u8)` rates or clears the song behind
  each Track, at most 512 Tracks per call, and returns a `RatingChange`
  counting the Tracks changed and those skipped for having no Recording. A
  rating of 0 or above 100 is `error.InvalidRating` and writes nothing.
- `TrackSummary.rating` and `TrackDetails.rating` report it, and
  `TrackSort.rating` orders by it with unrated Tracks last in both
  directions.
- Ratings are not written to files and not sent to any service.

```sh
zig build run -- rate DATABASE IDS (--stars=1..5 | --rating=1..100 | --clear)
zig build run -- tracks DATABASE --sort rating --desc
```

## Playlists

A playlist is a name and an ordered list of entries. Each entry names a
Recording; one Recording may appear several times.

- Names are trimmed of whitespace, must not be empty
  (`error.InvalidPlaylistName`) and are unique (`error.PlaylistNameTaken`).
- Positions run from 0 to n − 1 without gaps. Inserting, removing and moving
  renumber the entries after them in one transaction.
- A playlist holds at most `max_playlist_entries` (10,000) entries, the
  capacity of the playback queue. An insert that would exceed it is
  `error.PlaylistFull` and inserts nothing. One call inserts at most 512
  Tracks (`error.PageOutOfRange`).
- An entry resolves to the Track of its Recording with the lowest id.
  An entry whose Recording has no Track, such as one whose files are gone, is
  listed with `track = null` and skipped by playback.
- `playerPlayPlaylist(player, library, io, playlist_id, start)` replaces the
  queue with the available entries; `start` indexes those. A playlist with
  no available entry is `error.PlaylistEmpty` and leaves the queue as it was.

```sh
zig build run -- playlists DATABASE
zig build run -- playlist DATABASE ID [--limit N] [--offset N]
zig build run -- playlist-create DATABASE NAME
zig build run -- playlist-add DATABASE ID IDS [--at=N]
zig build run -- playlist-move DATABASE ID FROM TO
zig build run -- playlist-remove DATABASE ID POSITIONS
zig build run -- play-tracks DATABASE --playlist=ID --device=ID
```

Removing a root and scanning the same folder again creates new Recordings, so
the entries of the old ones become unavailable.

## M3U import

`libraryImportPlaylist(library, io, path, name)` reads an `.m3u` or `.m3u8`
file and creates a new playlist from it in one transaction.

- The file is at most 4 MiB with at most 10,000 entries; a larger one is
  `error.PlaylistTooLarge` and creates nothing. A file with no entry is
  `error.PlaylistEmpty`.
- A leading UTF-8 byte order mark is dropped, and CRLF, LF and CR all end a
  line. A file that is not valid UTF-8 is read as Latin-1.
- Blank lines and `#` lines are skipped, except `#EXTINF:<seconds>,<text>`,
  which describes the entry on the next line.
- The name is `name`, else the file name without its extension. A taken name
  gets ` (2)`, ` (3)` and so on.

Each entry is matched in this order:

1. A `file://` URI with an empty host is percent-decoded to a path. Any other
   `scheme://` entry is unmatched. A relative path is resolved against the
   playlist file's folder. The path is normalised lexically; symbolic links
   are not followed.
2. A location whose path equals it, preferring `present`, then `unverified`,
   then `missing`. Its file gives the Recording.
3. Only if no location matched: the `#EXTINF` text, split at the first `" - "`
   into artist and title. It matches when exactly one Recording has a Track
   with that artist and title, compared after Unicode folding, and a length
   within 2 s of the stated one. An entry stating `-1` seconds matches on
   artist and title alone.
4. Otherwise the entry is unmatched and left out.

`PlaylistImport` counts the entries matched by path and by `#EXTINF`, and the
unmatched ones, and holds the first 50 unmatched lines. Import never scans:
a path the Library has not seen is unmatched.

```sh
zig build run -- playlist-import DATABASE FILE [--name=NAME]
```

## M3U export

`libraryExportPlaylist(library, io, playlist_id, path, options)` writes an
extended M3U file in UTF-8 with LF line endings:

```text
#EXTM3U
#EXTINF:226,ABBA - Intermezzo No. 1
/mnt/Media/Music/ABBA/ABBA (1975)/ABBA - ABBA - 09 - Intermezzo No. 1.flac
```

- Each available entry is written with its length in whole seconds (`-1` when
  unknown), `artist - title` (the title alone without an artist) and the path
  of the location playback would open. Line breaks in tags become spaces.
- `.paths = .relative` writes paths relative to the target's folder. Paths are
  never URI-encoded.
- Entries without a Track, and paths containing a line break, are skipped and
  counted in `PlaylistExport.skipped`.
- The file is written beside the target, synced, renamed over it and its
  folder synced, so a reader sees the old file or the new one. A failed
  export leaves no temporary file. An existing target is
  `error.PathAlreadyExists` unless `.replace` is set.

```sh
zig build run -- playlist-export DATABASE ID FILE [--relative] [--force]
```
