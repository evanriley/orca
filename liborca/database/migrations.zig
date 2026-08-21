const sqlite = @import("sqlite.zig");

pub const current_version = 7;

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

const migration_2 =
    \\CREATE TABLE library_roots (
    \\    id INTEGER PRIMARY KEY,
    \\    path TEXT NOT NULL UNIQUE,
    \\    enabled INTEGER NOT NULL DEFAULT 1
    \\);
    \\CREATE TABLE observed_files (
    \\    path TEXT PRIMARY KEY,
    \\    inode INTEGER NOT NULL,
    \\    size_bytes INTEGER NOT NULL,
    \\    modified_ns INTEGER NOT NULL,
    \\    audio_format INTEGER NOT NULL,
    \\    observed_at INTEGER NOT NULL DEFAULT (unixepoch())
    \\) WITHOUT ROWID;
    \\CREATE INDEX observed_files_identity
    \\    ON observed_files(inode, size_bytes, modified_ns);
;

const migration_3 =
    \\CREATE TABLE observed_file_metadata (
    \\    path TEXT PRIMARY KEY REFERENCES observed_files(path) ON DELETE CASCADE,
    \\    title TEXT,
    \\    artist TEXT,
    \\    album TEXT,
    \\    track_number INTEGER
    \\) WITHOUT ROWID;
;

const migration_4 =
    \\CREATE TABLE orca_metadata_values (
    \\    path TEXT NOT NULL REFERENCES observed_files(path) ON DELETE CASCADE,
    \\    field INTEGER NOT NULL,
    \\    value TEXT NOT NULL,
    \\    provenance INTEGER NOT NULL,
    \\    locked INTEGER NOT NULL DEFAULT 0 CHECK (locked IN (0, 1)),
    \\    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    PRIMARY KEY(path, field)
    \\) WITHOUT ROWID;
    \\CREATE INDEX orca_metadata_values_provenance
    \\    ON orca_metadata_values(provenance, locked);
;

const migration_5 =
    \\CREATE TABLE mutation_operations (
    \\    id INTEGER PRIMARY KEY,
    \\    plan_id INTEGER NOT NULL,
    \\    group_id INTEGER NOT NULL,
    \\    action_index INTEGER NOT NULL,
    \\    kind INTEGER NOT NULL,
    \\    source_path TEXT NOT NULL,
    \\    destination_path TEXT,
    \\    stage_path TEXT,
    \\    backup_path TEXT,
    \\    expected_size INTEGER NOT NULL,
    \\    expected_modified_ns INTEGER NOT NULL,
    \\    committed_size INTEGER,
    \\    committed_modified_ns INTEGER,
    \\    state INTEGER NOT NULL,
    \\    error TEXT,
    \\    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    UNIQUE(plan_id, action_index)
    \\);
    \\CREATE INDEX mutation_operations_recovery
    \\    ON mutation_operations(state, updated_at);
    \\CREATE INDEX mutation_operations_group
    \\    ON mutation_operations(group_id, action_index);
;

const migration_6 =
    \\CREATE TABLE analysis_results (
    \\    path TEXT NOT NULL,
    \\    kind INTEGER NOT NULL,
    \\    algorithm_id TEXT NOT NULL,
    \\    algorithm_version INTEGER NOT NULL,
    \\    parameter_hash BLOB NOT NULL,
    \\    source_size INTEGER NOT NULL,
    \\    source_modified_ns INTEGER NOT NULL,
    \\    result BLOB NOT NULL,
    \\    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    PRIMARY KEY(
    \\        path, kind, algorithm_id, algorithm_version, parameter_hash,
    \\        source_size, source_modified_ns
    \\    )
    \\) WITHOUT ROWID;
    \\CREATE INDEX analysis_results_current
    \\    ON analysis_results(path, kind, algorithm_id, algorithm_version);
    \\CREATE TABLE library_health_issues (
    \\    path TEXT NOT NULL,
    \\    kind INTEGER NOT NULL,
    \\    severity INTEGER NOT NULL,
    \\    details TEXT NOT NULL DEFAULT '',
    \\    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    PRIMARY KEY(path, kind)
    \\) WITHOUT ROWID;
    \\CREATE INDEX library_health_by_kind
    \\    ON library_health_issues(kind, severity, path);
;

const migration_7 =
    \\CREATE TABLE provider_cache (
    \\    provider TEXT NOT NULL,
    \\    request_key TEXT NOT NULL,
    \\    status INTEGER NOT NULL,
    \\    body BLOB NOT NULL,
    \\    expires_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    PRIMARY KEY(provider, request_key)
    \\) WITHOUT ROWID;
    \\CREATE INDEX provider_cache_expiry ON provider_cache(expires_at);
    \\CREATE TABLE identification_proposals (
    \\    id INTEGER PRIMARY KEY,
    \\    path TEXT NOT NULL,
    \\    provider TEXT NOT NULL,
    \\    provider_id TEXT NOT NULL,
    \\    confidence REAL NOT NULL,
    \\    payload BLOB NOT NULL,
    \\    state INTEGER NOT NULL DEFAULT 0,
    \\    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    UNIQUE(path, provider, provider_id)
    \\);
    \\CREATE INDEX identification_proposals_path
    \\    ON identification_proposals(path, state, confidence DESC);
    \\CREATE TABLE scrobble_queue (
    \\    id INTEGER PRIMARY KEY,
    \\    service TEXT NOT NULL,
    \\    event_key TEXT NOT NULL,
    \\    payload BLOB NOT NULL,
    \\    state INTEGER NOT NULL DEFAULT 0,
    \\    attempt_count INTEGER NOT NULL DEFAULT 0,
    \\    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    \\    last_error TEXT NOT NULL DEFAULT '',
    \\    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    UNIQUE(service, event_key)
    \\);
    \\CREATE INDEX scrobble_queue_ready
    \\    ON scrobble_queue(state, next_attempt_at, id);
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
    if (version < 2) try db.exec(migration_2);
    if (version < 3) try db.exec(migration_3);
    if (version < 4) try db.exec(migration_4);
    if (version < 5) try db.exec(migration_5);
    if (version < 6) try db.exec(migration_6);
    if (version < 7) try db.exec(migration_7);
    try db.exec("PRAGMA user_version=7; COMMIT;");
}
