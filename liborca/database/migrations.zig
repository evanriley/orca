const sqlite = @import("sqlite.zig");

pub const current_version = 1;

const migration_1 =
    \\CREATE TABLE artists (
    \\    id INTEGER PRIMARY KEY,
    \\    name TEXT NOT NULL,
    \\    sort_name TEXT
    \\);
    \\CREATE INDEX artists_name ON artists(name COLLATE NOCASE);
    \\CREATE TABLE releases (
    \\    id INTEGER PRIMARY KEY,
    \\    title TEXT NOT NULL,
    \\    album_artist TEXT NOT NULL DEFAULT '',
    \\    release_date TEXT
    \\);
    \\CREATE INDEX releases_title ON releases(title COLLATE NOCASE);
    \\CREATE TABLE recordings (
    \\    id INTEGER PRIMARY KEY,
    \\    title TEXT NOT NULL,
    \\    duration_ms INTEGER
    \\);
    \\CREATE TABLE tracks (
    \\    id INTEGER PRIMARY KEY,
    \\    recording_id INTEGER REFERENCES recordings(id),
    \\    release_id INTEGER REFERENCES releases(id),
    \\    title TEXT NOT NULL,
    \\    album TEXT NOT NULL DEFAULT '',
    \\    album_artist TEXT NOT NULL DEFAULT '',
    \\    duration_ms INTEGER,
    \\    track_number INTEGER,
    \\    disc_number INTEGER,
    \\    rating INTEGER CHECK (rating BETWEEN 0 AND 100),
    \\    created_at INTEGER NOT NULL DEFAULT (unixepoch())
    \\);
    \\CREATE INDEX tracks_album ON tracks(album COLLATE NOCASE, disc_number, track_number);
    \\CREATE INDEX tracks_rating ON tracks(rating);
    \\CREATE TABLE files (
    \\    id INTEGER PRIMARY KEY,
    \\    recording_id INTEGER REFERENCES recordings(id),
    \\    codec TEXT NOT NULL,
    \\    size_bytes INTEGER NOT NULL,
    \\    sample_rate INTEGER,
    \\    bit_depth INTEGER,
    \\    content_hash BLOB
    \\);
    \\CREATE TABLE locations (
    \\    id INTEGER PRIMARY KEY,
    \\    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    \\    device_id TEXT NOT NULL,
    \\    uri TEXT NOT NULL,
    \\    storage_identity BLOB,
    \\    UNIQUE(device_id, uri)
    \\);
    \\CREATE VIRTUAL TABLE track_search USING fts5(
    \\    title, album, album_artist,
    \\    content='tracks', content_rowid='id',
    \\    tokenize='unicode61 remove_diacritics 2'
    \\);
    \\CREATE TRIGGER tracks_ai AFTER INSERT ON tracks BEGIN
    \\    INSERT INTO track_search(rowid, title, album, album_artist)
    \\    VALUES (new.id, new.title, new.album, new.album_artist);
    \\END;
    \\CREATE TRIGGER tracks_ad AFTER DELETE ON tracks BEGIN
    \\    INSERT INTO track_search(track_search, rowid, title, album, album_artist)
    \\    VALUES ('delete', old.id, old.title, old.album, old.album_artist);
    \\END;
    \\CREATE TRIGGER tracks_au AFTER UPDATE ON tracks BEGIN
    \\    INSERT INTO track_search(track_search, rowid, title, album, album_artist)
    \\    VALUES ('delete', old.id, old.title, old.album, old.album_artist);
    \\    INSERT INTO track_search(rowid, title, album, album_artist)
    \\    VALUES (new.id, new.title, new.album, new.album_artist);
    \\END;
;

pub fn apply(db: sqlite.Database) sqlite.Error!void {
    const version = blk: {
        var statement = try db.prepare("PRAGMA user_version;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        break :blk statement.columnInt64(0);
    };
    if (version > current_version) return error.SchemaVersionTooNew;
    if (version == current_version) return;

    try db.exec("BEGIN IMMEDIATE;");
    errdefer db.exec("ROLLBACK;") catch {};
    if (version < 1) try db.exec(migration_1);
    try db.exec("PRAGMA user_version=1; COMMIT;");
}
