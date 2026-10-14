# The Library

A Library is one SQLite database file. It holds the roots Orca scans, every
Track, and state that exists nowhere else: Orca's metadata values and locks,
listens, ratings, loves, "Not for me" marks, playlists and match reviews.
Back it up like any other document.

## Files beside the database

| File | Purpose |
| --- | --- |
| `<database>-wal`, `<database>-shm` | SQLite's write-ahead log; part of the database while Orca runs |
| `<database>.orca-journal.lock` | one tag write, undo or relocation at a time; never delete it |
| `<database>.orca-scan.lock` | one scan or reconcile at a time; never delete it |
| `<database>.orca-backups/` | copies of files before a tag write, kept for undo |
| `<database>.pre-v<N>.sqlite` | the Library as it was before the last schema upgrade |

Orca never walks into these files, even when the database sits inside a root.

## Upgrades

Opening a Library made by an older Orca upgrades its schema in place. Before
the first change Orca copies the database to `<database>.pre-v<N>.sqlite`,
`<N>` being the old schema version, and fails the open without changing
anything when the copy cannot be written. One copy is kept.

To go back to the older Orca:

1. Close Orca.
2. Move the database and its `-wal` and `-shm` files aside.
3. Rename `<database>.pre-v<N>.sqlite` to the database's name.

Changes made after the upgrade are not in the copy. An Orca older than a
Library's schema refuses to open it.

## Roots and volumes

Each root is bound to the volume it is on: the filesystem UUID, or the
`.orca-volume-id` marker at the mount root when one exists. Orca reads the
marker and never writes it. Before every scan Orca checks that the root's path
still resolves to that volume; when it does not, as for an unmounted drive,
the scan changes nothing and the root is shown as unavailable.

A root on a mount with neither, such as NFS, SMB or tmpfs, is a volume of its
own. Two such roots on one share do not share storage identity, and a
different share mounted at the same path passes the check.

When a root moves on disk, or its marker is gone, rebind it with
`orca-cli relocate-root DATABASE ID PATH` or Locate Folder in `orca-gtk`. Its
Tracks keep their ids, ratings and history. `orca-cli scan` never rebinds a
root; `orca-cli add-root` binds a new one.

Symbolic links are not followed. A scan counts the links it passes over and
`orca-cli` prints `symlinks_skipped=N` when there are any.

## Watching for changes

On Linux, `orca-gtk` and `orca-cli watch` follow changes under each root with
inotify. Each watched directory counts against `fs.inotify.max_user_watches`
and each watched Library uses one of `fs.inotify.max_user_instances`. When the
watch limit is reached, the Library is marked degraded and the root is
rescanned whole at intervals instead; raise the limit to restore live
watching.

## Writing tags

Orca writes FLAC, MP3 and ADTS tags, only from a plan that has been approved.
M4A, Ogg, WAV, AIFF, and FLAC behind an ID3v2 tag are listed as skipped.

- A file that changed since the last scan, a read-only file, or a file in a
  folder Orca cannot write is skipped. Orca never changes file permissions.
- Each file is copied into `<database>.orca-backups/` before it is replaced.
  The backups use disk space until the write is undone or pruned with
  `orca-cli prune-backups DATABASE [--older-than=DAYS]`; a pruned write
  cannot be undone.
- The written file is a new file at the same path: other hard links keep the
  old contents, and extended attributes and ACL entries are not kept.
- Undo restores the backed-up files. A file changed by something else since
  the write is kept as it is and the write is marked for reconciliation
  rather than undone.
- A write interrupted by a crash is finished or rolled back the next time the
  Library opens.
