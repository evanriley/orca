const std = @import("std");
const sqlite = @import("sqlite.zig");

pub const current_version = 8;

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

/// Migration 8 replaces every path-keyed table with `files.id` identity.
///
/// Affected tables are recreated rather than extended: a clean end state costs
/// the same as accreting nullable columns at this size. `observed_files`
/// disappears — filesystem facts become `locations`, byte facts become `files`,
/// and tag facts become `observed_file_tags` (plus `observed_file_genres`,
/// because genres are multi-valued in every container Orca reads).
///
/// Paths that only ever appeared in `analysis_results`, `library_health_issues`,
/// `identification_proposals` or the mutation journal — an `orca-cli analyze`
/// against a file no scan ever saw — are not dropped. They gain synthesized
/// `files` and `locations` rows in the `unverified` state, so a cached analysis
/// survives the upgrade and the next scan can confirm or retire it.
///
/// `mutation_operations` keeps its paths: a filesystem operation's subject
/// genuinely is a path. It gains `file_id` so the journal can restore identity
/// after a move, and the quick-hash halves of `FileIdentity`.
///
/// FTS5 external-content tables cannot be `ALTER`ed to add a column, so the
/// three maintaining triggers and `track_search` are dropped, recreated with
/// the new `artist` column, and rebuilt from `tracks`.
const migration_8 =
    \\CREATE TABLE volumes (
    \\    id INTEGER PRIMARY KEY,
    \\    stable_key TEXT NOT NULL UNIQUE,
    \\    label TEXT NOT NULL DEFAULT '',
    \\    last_seen_at INTEGER NOT NULL DEFAULT (unixepoch())
    \\);
    \\INSERT INTO volumes(id, stable_key, label) VALUES (1, 'legacy', 'Legacy library');
    \\CREATE TABLE library_roots_v8 (
    \\    id INTEGER PRIMARY KEY,
    \\    volume_id INTEGER NOT NULL REFERENCES volumes(id),
    \\    path TEXT NOT NULL UNIQUE,
    \\    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1))
    \\);
    \\INSERT INTO library_roots_v8(id, volume_id, path, enabled)
    \\    SELECT id, 1, path, CASE WHEN enabled = 0 THEN 0 ELSE 1 END FROM library_roots;
    \\CREATE TABLE files_v8 (
    \\    id INTEGER PRIMARY KEY,
    \\    recording_id INTEGER REFERENCES recordings(id),
    \\    audio_format INTEGER NOT NULL DEFAULT 0,
    \\    codec TEXT NOT NULL DEFAULT '',
    \\    size_bytes INTEGER NOT NULL DEFAULT 0,
    \\    sample_rate INTEGER,
    \\    bit_depth INTEGER,
    \\    channels INTEGER,
    \\    duration_ms INTEGER,
    \\    quick_hash BLOB,
    \\    audio_hash BLOB,
    \\    content_hash BLOB,
    \\    first_seen_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    last_scan_generation INTEGER NOT NULL DEFAULT 0,
    \\    legacy_path TEXT
    \\);
    \\CREATE TABLE locations_v8 (
    \\    id INTEGER PRIMARY KEY,
    \\    file_id INTEGER NOT NULL REFERENCES files_v8(id) ON DELETE CASCADE,
    \\    volume_id INTEGER NOT NULL REFERENCES volumes(id),
    \\    root_id INTEGER REFERENCES library_roots_v8(id) ON DELETE SET NULL,
    \\    uri TEXT NOT NULL,
    \\    native_device INTEGER,
    \\    native_inode INTEGER,
    \\    size_bytes INTEGER NOT NULL DEFAULT 0,
    \\    modified_ns INTEGER NOT NULL DEFAULT 0,
    \\    state TEXT NOT NULL DEFAULT 'unverified'
    \\        CHECK (state IN ('present', 'missing', 'unverified')),
    \\    missing_since INTEGER,
    \\    last_seen_generation INTEGER NOT NULL DEFAULT 0,
    \\    UNIQUE(volume_id, uri)
    \\);
    \\INSERT INTO files_v8(
    \\    id, recording_id, codec, size_bytes, sample_rate, bit_depth, content_hash
    \\) SELECT id, recording_id, codec, size_bytes, sample_rate, bit_depth, content_hash
    \\  FROM files;
    \\INSERT OR IGNORE INTO locations_v8(id, file_id, volume_id, uri, state)
    \\    SELECT id, file_id, 1, uri, 'unverified' FROM locations;
    \\CREATE TEMP TABLE path_to_file(path TEXT PRIMARY KEY, file_id INTEGER NOT NULL);
    \\CREATE TEMP TABLE legacy_scanned(uri TEXT PRIMARY KEY);
    \\INSERT INTO temp.legacy_scanned(uri) SELECT path FROM observed_files;
    \\INSERT INTO temp.path_to_file(path, file_id)
    \\    SELECT uri, min(file_id) FROM locations_v8 WHERE volume_id = 1 GROUP BY uri;
    \\INSERT INTO files_v8(audio_format, size_bytes, first_seen_at, legacy_path)
    \\    SELECT audio_format, size_bytes, observed_at, path FROM observed_files
    \\    WHERE path NOT IN (SELECT path FROM temp.path_to_file);
    \\INSERT INTO temp.path_to_file(path, file_id)
    \\    SELECT legacy_path, id FROM files_v8 WHERE legacy_path IS NOT NULL;
    \\UPDATE files_v8 SET legacy_path = NULL WHERE legacy_path IS NOT NULL;
    \\INSERT INTO locations_v8(
    \\    file_id, volume_id, uri, native_inode, size_bytes, modified_ns, state
    \\) SELECT m.file_id, 1, o.path, o.inode, o.size_bytes, o.modified_ns, 'unverified'
    \\  FROM observed_files o JOIN temp.path_to_file m ON m.path = o.path
    \\  WHERE NOT EXISTS (
    \\      SELECT 1 FROM locations_v8 l WHERE l.volume_id = 1 AND l.uri = o.path
    \\  );
    \\UPDATE locations_v8 SET
    \\    native_inode = (SELECT inode FROM observed_files o WHERE o.path = locations_v8.uri),
    \\    size_bytes = (SELECT size_bytes FROM observed_files o WHERE o.path = locations_v8.uri),
    \\    modified_ns = (SELECT modified_ns FROM observed_files o WHERE o.path = locations_v8.uri)
    \\WHERE native_inode IS NULL
    \\  AND EXISTS (SELECT 1 FROM observed_files o WHERE o.path = locations_v8.uri);
    \\INSERT INTO files_v8(legacy_path)
    \\    SELECT path FROM (
    \\        SELECT path FROM analysis_results
    \\        UNION SELECT path FROM library_health_issues
    \\        UNION SELECT path FROM identification_proposals
    \\        UNION SELECT path FROM orca_metadata_values
    \\        UNION SELECT source_path FROM mutation_operations
    \\    ) WHERE path NOT IN (SELECT path FROM temp.path_to_file);
    \\INSERT INTO temp.path_to_file(path, file_id)
    \\    SELECT legacy_path, id FROM files_v8 WHERE legacy_path IS NOT NULL;
    \\UPDATE files_v8 SET legacy_path = NULL WHERE legacy_path IS NOT NULL;
    \\INSERT INTO locations_v8(file_id, volume_id, uri, state)
    \\    SELECT m.file_id, 1, m.path, 'unverified' FROM temp.path_to_file m
    \\    WHERE NOT EXISTS (
    \\        SELECT 1 FROM locations_v8 l WHERE l.volume_id = 1 AND l.uri = m.path
    \\    );
    \\CREATE TABLE observed_file_tags (
    \\    file_id INTEGER PRIMARY KEY REFERENCES files_v8(id) ON DELETE CASCADE,
    \\    title TEXT,
    \\    artist TEXT,
    \\    album TEXT,
    \\    album_artist TEXT,
    \\    composer TEXT,
    \\    track_number INTEGER,
    \\    track_total INTEGER,
    \\    disc_number INTEGER,
    \\    disc_total INTEGER,
    \\    date TEXT,
    \\    original_date TEXT,
    \\    compilation INTEGER CHECK (compilation IS NULL OR compilation IN (0, 1)),
    \\    label TEXT,
    \\    media TEXT,
    \\    isrc TEXT,
    \\    release_country TEXT,
    \\    release_type TEXT,
    \\    release_status TEXT,
    \\    musicbrainz_recording_id TEXT,
    \\    musicbrainz_release_id TEXT,
    \\    musicbrainz_release_group_id TEXT,
    \\    musicbrainz_release_track_id TEXT,
    \\    musicbrainz_artist_id TEXT,
    \\    musicbrainz_album_artist_id TEXT,
    \\    artwork_mime_type TEXT,
    \\    artwork_byte_size INTEGER,
    \\    artwork_kind INTEGER,
    \\    observed_at INTEGER NOT NULL DEFAULT (unixepoch())
    \\) WITHOUT ROWID;
    \\CREATE TABLE observed_file_genres (
    \\    file_id INTEGER NOT NULL REFERENCES files_v8(id) ON DELETE CASCADE,
    \\    ordinal INTEGER NOT NULL,
    \\    value TEXT NOT NULL,
    \\    PRIMARY KEY(file_id, ordinal)
    \\) WITHOUT ROWID;
    \\INSERT OR REPLACE INTO observed_file_tags(file_id, title, artist, album, track_number)
    \\    SELECT m.file_id, x.title, x.artist, x.album, x.track_number
    \\    FROM observed_file_metadata x JOIN temp.path_to_file m ON m.path = x.path;
    \\CREATE TABLE orca_metadata_values_v8 (
    \\    file_id INTEGER NOT NULL REFERENCES files_v8(id) ON DELETE CASCADE,
    \\    field INTEGER NOT NULL,
    \\    value TEXT NOT NULL,
    \\    provenance INTEGER NOT NULL,
    \\    locked INTEGER NOT NULL DEFAULT 0 CHECK (locked IN (0, 1)),
    \\    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    PRIMARY KEY(file_id, field)
    \\) WITHOUT ROWID;
    \\INSERT OR REPLACE INTO orca_metadata_values_v8(
    \\    file_id, field, value, provenance, locked, updated_at
    \\) SELECT m.file_id, o.field, o.value, o.provenance, o.locked, o.updated_at
    \\  FROM orca_metadata_values o JOIN temp.path_to_file m ON m.path = o.path;
    \\CREATE TABLE analysis_results_v8 (
    \\    file_id INTEGER NOT NULL REFERENCES files_v8(id) ON DELETE CASCADE,
    \\    kind INTEGER NOT NULL,
    \\    algorithm_id TEXT NOT NULL,
    \\    algorithm_version INTEGER NOT NULL,
    \\    parameter_hash BLOB NOT NULL,
    \\    source_identity BLOB NOT NULL,
    \\    result BLOB NOT NULL,
    \\    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    PRIMARY KEY(
    \\        file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity
    \\    )
    \\) WITHOUT ROWID;
    \\INSERT OR REPLACE INTO analysis_results_v8(
    \\    file_id, kind, algorithm_id, algorithm_version, parameter_hash,
    \\    source_identity, result, created_at
    \\) SELECT m.file_id, a.kind, a.algorithm_id, a.algorithm_version, a.parameter_hash,
    \\         CAST('v7:' || a.source_size || ':' || a.source_modified_ns AS BLOB),
    \\         a.result, a.created_at
    \\  FROM analysis_results a JOIN temp.path_to_file m ON m.path = a.path;
    \\CREATE TABLE library_health_issues_v8 (
    \\    file_id INTEGER NOT NULL REFERENCES files_v8(id) ON DELETE CASCADE,
    \\    kind INTEGER NOT NULL,
    \\    severity INTEGER NOT NULL,
    \\    details TEXT NOT NULL DEFAULT '',
    \\    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    PRIMARY KEY(file_id, kind)
    \\) WITHOUT ROWID;
    \\INSERT OR REPLACE INTO library_health_issues_v8(
    \\    file_id, kind, severity, details, updated_at
    \\) SELECT m.file_id, h.kind, h.severity, h.details, h.updated_at
    \\  FROM library_health_issues h JOIN temp.path_to_file m ON m.path = h.path;
    \\CREATE TABLE identification_proposals_v8 (
    \\    id INTEGER PRIMARY KEY,
    \\    file_id INTEGER NOT NULL REFERENCES files_v8(id) ON DELETE CASCADE,
    \\    recording_id INTEGER REFERENCES recordings(id),
    \\    provider TEXT NOT NULL,
    \\    provider_id TEXT NOT NULL,
    \\    confidence REAL NOT NULL,
    \\    payload BLOB NOT NULL,
    \\    state INTEGER NOT NULL DEFAULT 0,
    \\    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    UNIQUE(file_id, provider, provider_id)
    \\);
    \\INSERT OR REPLACE INTO identification_proposals_v8(
    \\    id, file_id, provider, provider_id, confidence, payload, state, created_at, updated_at
    \\) SELECT p.id, m.file_id, p.provider, p.provider_id, p.confidence, p.payload,
    \\         p.state, p.created_at, p.updated_at
    \\  FROM identification_proposals p JOIN temp.path_to_file m ON m.path = p.path;
    \\DROP TABLE observed_file_metadata;
    \\DROP TABLE orca_metadata_values;
    \\DROP TABLE analysis_results;
    \\DROP TABLE library_health_issues;
    \\DROP TABLE identification_proposals;
    \\DROP TABLE observed_files;
    \\DROP TABLE locations;
    \\DROP TABLE files;
    \\DROP TABLE library_roots;
    \\ALTER TABLE library_roots_v8 RENAME TO library_roots;
    \\ALTER TABLE files_v8 RENAME TO files;
    \\ALTER TABLE locations_v8 RENAME TO locations;
    \\ALTER TABLE orca_metadata_values_v8 RENAME TO orca_metadata_values;
    \\ALTER TABLE analysis_results_v8 RENAME TO analysis_results;
    \\ALTER TABLE library_health_issues_v8 RENAME TO library_health_issues;
    \\ALTER TABLE identification_proposals_v8 RENAME TO identification_proposals;
    \\ALTER TABLE files DROP COLUMN legacy_path;
    \\CREATE TABLE scan_runs (
    \\    id INTEGER PRIMARY KEY,
    \\    root_id INTEGER NOT NULL REFERENCES library_roots(id) ON DELETE CASCADE,
    \\    generation INTEGER NOT NULL,
    \\    started_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    finished_at INTEGER,
    \\    state TEXT NOT NULL DEFAULT 'running'
    \\        CHECK (state IN ('running', 'completed', 'cancelled', 'failed')),
    \\    files_seen INTEGER NOT NULL DEFAULT 0,
    \\    changed INTEGER NOT NULL DEFAULT 0,
    \\    unchanged INTEGER NOT NULL DEFAULT 0,
    \\    unsupported INTEGER NOT NULL DEFAULT 0,
    \\    errors INTEGER NOT NULL DEFAULT 0,
    \\    UNIQUE(root_id, generation)
    \\);
    \\ALTER TABLE tracks ADD COLUMN artist TEXT NOT NULL DEFAULT '';
    \\ALTER TABLE tracks ADD COLUMN preferred_file_id INTEGER REFERENCES files(id);
    \\ALTER TABLE releases ADD COLUMN is_compilation INTEGER NOT NULL DEFAULT 0
    \\    CHECK (is_compilation IN (0, 1));
    \\ALTER TABLE releases ADD COLUMN disc_count INTEGER;
    \\ALTER TABLE releases ADD COLUMN release_key TEXT;
    \\ALTER TABLE releases ADD COLUMN musicbrainz_release_id TEXT;
    \\ALTER TABLE artists ADD COLUMN key TEXT;
    \\ALTER TABLE artists ADD COLUMN musicbrainz_artist_id TEXT;
    \\ALTER TABLE mutation_operations ADD COLUMN file_id INTEGER REFERENCES files(id);
    \\ALTER TABLE mutation_operations ADD COLUMN expected_quick_hash BLOB;
    \\ALTER TABLE mutation_operations ADD COLUMN committed_quick_hash BLOB;
    \\UPDATE mutation_operations
    \\    SET file_id = (SELECT file_id FROM temp.path_to_file WHERE path = source_path);
    \\DROP TABLE temp.path_to_file;
    \\UPDATE locations SET root_id = (
    \\    SELECT id FROM library_roots r
    \\    WHERE locations.uri = r.path
    \\       OR substr(locations.uri, 1, length(r.path) + 1) = r.path || '/'
    \\    ORDER BY length(r.path) DESC LIMIT 1
    \\) WHERE root_id IS NULL;
    \\DROP TRIGGER tracks_ai;
    \\DROP TRIGGER tracks_ad;
    \\DROP TRIGGER tracks_au;
    \\DROP TABLE track_search;
    \\CREATE VIRTUAL TABLE track_search USING fts5(
    \\    title, artist, album, album_artist,
    \\    content='tracks', content_rowid='id',
    \\    tokenize='unicode61 remove_diacritics 2'
    \\);
    \\CREATE TRIGGER tracks_ai AFTER INSERT ON tracks BEGIN
    \\    INSERT INTO track_search(rowid, title, artist, album, album_artist)
    \\    VALUES (new.id, new.title, new.artist, new.album, new.album_artist);
    \\END;
    \\CREATE TRIGGER tracks_ad AFTER DELETE ON tracks BEGIN
    \\    INSERT INTO track_search(track_search, rowid, title, artist, album, album_artist)
    \\    VALUES ('delete', old.id, old.title, old.artist, old.album, old.album_artist);
    \\END;
    \\CREATE TRIGGER tracks_au AFTER UPDATE ON tracks BEGIN
    \\    INSERT INTO track_search(track_search, rowid, title, artist, album, album_artist)
    \\    VALUES ('delete', old.id, old.title, old.artist, old.album, old.album_artist);
    \\    INSERT INTO track_search(rowid, title, artist, album, album_artist)
    \\    VALUES (new.id, new.title, new.artist, new.album, new.album_artist);
    \\END;
    \\INSERT INTO track_search(track_search) VALUES('rebuild');
    \\CREATE INDEX library_roots_volume ON library_roots(volume_id);
    \\CREATE INDEX files_quick_hash ON files(quick_hash);
    \\CREATE INDEX files_audio_hash ON files(audio_hash);
    \\CREATE INDEX locations_file ON locations(file_id);
    \\CREATE INDEX locations_identity
    \\    ON locations(volume_id, native_inode, size_bytes, modified_ns);
    \\CREATE INDEX locations_sweep ON locations(root_id, last_seen_generation);
    \\CREATE INDEX observed_file_tags_release ON observed_file_tags(musicbrainz_release_id);
    \\CREATE INDEX observed_file_tags_album
    \\    ON observed_file_tags(album COLLATE NOCASE, album_artist COLLATE NOCASE);
    \\CREATE INDEX orca_metadata_values_provenance
    \\    ON orca_metadata_values(provenance, locked);
    \\CREATE INDEX analysis_results_current
    \\    ON analysis_results(file_id, kind, algorithm_id, algorithm_version);
    \\CREATE INDEX library_health_by_kind
    \\    ON library_health_issues(kind, severity, file_id);
    \\CREATE INDEX identification_proposals_file
    \\    ON identification_proposals(file_id, state, confidence DESC);
    \\CREATE INDEX scan_runs_root ON scan_runs(root_id, generation DESC);
    \\CREATE UNIQUE INDEX artists_key ON artists(key);
    \\CREATE UNIQUE INDEX releases_key ON releases(release_key);
    \\CREATE UNIQUE INDEX tracks_position
    \\    ON tracks(release_id, COALESCE(disc_number, 1), COALESCE(track_number, -id));
;

/// The schema version at which `mutation_operations` exists. Startup journal
/// recovery runs at exactly this point: the journal must be readable, and no
/// later migration may rewrite tables a nonterminal operation depends on before
/// that operation has reached a terminal state.
pub const journal_ready_version = 5;

pub fn apply(db: sqlite.Database) sqlite.Error!void {
    return applyThrough(db, current_version);
}

pub fn applyThrough(db: sqlite.Database, target_version: i64) sqlite.Error!void {
    const version = blk: {
        var statement = try db.prepare("PRAGMA user_version;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        break :blk statement.columnInt64(0);
    };
    if (version > current_version) return error.SchemaVersionTooNew;
    if (version >= target_version) return;

    try db.exec("BEGIN IMMEDIATE;");
    errdefer db.exec("ROLLBACK;") catch {};
    if (version < 1 and target_version >= 1) try db.exec(migration_1);
    if (version < 2 and target_version >= 2) try db.exec(migration_2);
    if (version < 3 and target_version >= 3) try db.exec(migration_3);
    if (version < 4 and target_version >= 4) try db.exec(migration_4);
    if (version < 5 and target_version >= 5) try db.exec(migration_5);
    if (version < 6 and target_version >= 6) try db.exec(migration_6);
    if (version < 7 and target_version >= 7) try db.exec(migration_7);
    if (version < 8 and target_version >= 8) {
        try db.exec(migration_8);
        try deriveLegacyRoot(db);
        try db.exec("DROP TABLE temp.legacy_scanned;");
    }
    try checkForeignKeys(db);
    var pragma_buffer: [64]u8 = undefined;
    const pragma = std.fmt.bufPrintSentinel(
        &pragma_buffer,
        "PRAGMA user_version={d}; COMMIT;",
        .{@min(target_version, current_version)},
        0,
    ) catch unreachable;
    try db.exec(pragma);
}

/// Give every migrated location a Library root to belong to.
///
/// A version-7 database recorded observations without ever writing
/// `library_roots`, so migrated locations would otherwise sit outside every
/// root-scoped sweep and outside the first scan's reconciliation. Any location
/// a version-7 root already covers keeps that root (migration 8 assigns those
/// in SQL); whatever is left gets one root derived from the longest common
/// directory prefix of the paths themselves, which for a real library is the
/// directory the user actually scanned.
fn deriveLegacyRoot(db: sqlite.Database) sqlite.Error!void {
    var prefix_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var prefix: ?[]const u8 = null;
    var shortest: usize = std.math.maxInt(usize);
    {
        var statement = try db.prepare(
            \\SELECT uri FROM locations
            \\WHERE root_id IS NULL AND uri IN (SELECT uri FROM temp.legacy_scanned);
        );
        defer statement.deinit();
        while (try statement.step() == .row) {
            const directory = parentDirectory(statement.columnText(0)) orelse return;
            shortest = @min(shortest, directory.len);
            if (prefix) |current| {
                prefix = current[0..commonPrefixLength(current, directory)];
            } else {
                if (directory.len > prefix_buffer.len) return;
                @memcpy(prefix_buffer[0..directory.len], directory);
                prefix = prefix_buffer[0..directory.len];
            }
            if (prefix.?.len == 0) return;
        }
    }
    const common = prefix orelse return;
    // A common byte prefix is only a directory when it is the whole of the
    // shortest directory seen; otherwise it stopped part way through a name
    // (`/music/ab` and `/music/ac` share `/music/a`, which names nothing).
    const root_path = if (common.len == shortest) common else trimToDirectory(common);
    if (root_path.len == 0) return;

    const root_id = blk: {
        var statement = try db.prepare(
            \\INSERT INTO library_roots(volume_id, path, enabled) VALUES (1, ?1, 1)
            \\ON CONFLICT(path) DO UPDATE SET path=excluded.path
            \\RETURNING id;
        );
        defer statement.deinit();
        try statement.bindText(1, root_path);
        if (try statement.step() != .row) return error.SqlFailed;
        break :blk statement.columnInt64(0);
    };
    var update = try db.prepare(
        \\UPDATE locations SET root_id=?1
        \\WHERE root_id IS NULL AND uri IN (SELECT uri FROM temp.legacy_scanned);
    );
    defer update.deinit();
    try update.bindInt64(1, root_id);
    if (try update.step() != .done) return error.SqlFailed;
}

fn parentDirectory(path: []const u8) ?[]const u8 {
    const separator = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    return path[0..separator];
}

fn commonPrefixLength(first: []const u8, second: []const u8) usize {
    const shared = @min(first.len, second.len);
    var index: usize = 0;
    while (index < shared and first[index] == second[index]) index += 1;
    return index;
}

fn trimToDirectory(prefix: []const u8) []const u8 {
    if (prefix.len == 0) return prefix;
    if (prefix.len == 1 and prefix[0] == '/') return "";
    const separator = std.mem.lastIndexOfScalar(u8, prefix, '/') orelse return prefix;
    if (separator == 0) return prefix;
    return prefix[0..separator];
}

/// A migration that recreates tables must never commit a database whose rows no
/// longer point at anything. This runs inside the migration transaction, so a
/// violation rolls the whole upgrade back instead of persisting it.
fn checkForeignKeys(db: sqlite.Database) sqlite.Error!void {
    var statement = try db.prepare("PRAGMA foreign_key_check;");
    defer statement.deinit();
    if (try statement.step() == .row) return error.ForeignKeyViolation;
}

fn copyFixture(allocator: std.mem.Allocator, io: std.Io, destination: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "fixtures/database/v7-library.db",
        allocator,
        .limited(8 * 1024 * 1024),
    );
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = destination, .data = bytes });
}

fn scalar(db: sqlite.Database, sql: [:0]const u8) !i64 {
    var statement = try db.prepare(sql);
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    return statement.columnInt64(0);
}

fn text(allocator: std.mem.Allocator, db: sqlite.Database, sql: [:0]const u8) ![]u8 {
    var statement = try db.prepare(sql);
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    return allocator.dupe(u8, statement.columnText(0));
}

fn schemaObjects(allocator: std.mem.Allocator, db: sqlite.Database) ![]u8 {
    var statement = try db.prepare(
        \\SELECT group_concat(name || '|' || COALESCE(sql, ''), char(10))
        \\FROM (SELECT name, sql FROM sqlite_master ORDER BY name);
    );
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    return allocator.dupe(u8, statement.columnText(0));
}

fn temporaryPath(
    allocator: std.mem.Allocator,
    directory: []const u8,
    name: []const u8,
) ![:0]u8 {
    return std.fmt.allocPrintSentinel(
        allocator,
        ".zig-cache/tmp/{s}/{s}",
        .{ directory, name },
        0,
    );
}

test "the checked-in version-7 fixture carries the schema its migrations produce" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const fixture_path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v7.db");
    defer std.testing.allocator.free(fixture_path);
    try copyFixture(std.testing.allocator, std.testing.io, fixture_path);
    const fixture = try sqlite.Database.open(fixture_path);
    defer fixture.close();

    const generated_path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v7-fresh.db");
    defer std.testing.allocator.free(generated_path);
    const generated = try sqlite.Database.open(generated_path);
    defer generated.close();
    try applyThrough(generated, 7);

    try std.testing.expectEqual(@as(i64, 7), try scalar(fixture, "PRAGMA user_version;"));
    const fixture_schema = try schemaObjects(std.testing.allocator, fixture);
    defer std.testing.allocator.free(fixture_schema);
    const generated_schema = try schemaObjects(std.testing.allocator, generated);
    defer std.testing.allocator.free(generated_schema);
    try std.testing.expectEqualStrings(generated_schema, fixture_schema);
}

test "migrating the version-7 fixture preserves every path-keyed row" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "migrated.db");
    defer std.testing.allocator.free(path);
    try copyFixture(std.testing.allocator, std.testing.io, path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try apply(db);

    try std.testing.expectEqual(@as(i64, 8), try scalar(db, "PRAGMA user_version;"));
    // Three scanned files plus the two orphan paths that only analysis and
    // health knew about.
    try std.testing.expectEqual(@as(i64, 5), try scalar(db, "SELECT count(*) FROM files;"));
    try std.testing.expectEqual(@as(i64, 5), try scalar(db, "SELECT count(*) FROM locations;"));
    try std.testing.expectEqual(
        @as(i64, 5),
        try scalar(db, "SELECT count(*) FROM locations WHERE state='unverified';"),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try scalar(db, "SELECT count(*) FROM volumes WHERE stable_key='legacy';"),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try scalar(db, "SELECT count(*) FROM library_roots WHERE path='/music' AND volume_id=1;"),
    );

    // Observed tags, Orca values, analysis, health and proposals all moved onto
    // the file their path resolved to.
    try std.testing.expectEqual(
        @as(i64, 2),
        try scalar(db, "SELECT count(*) FROM observed_file_tags;"),
    );
    const title = try text(std.testing.allocator, db,
        \\SELECT title FROM observed_file_tags
        \\JOIN locations ON locations.file_id = observed_file_tags.file_id
        \\WHERE locations.uri = '/music/drake/northern-sky.flac';
    );
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("Northern Sky", title);
    try std.testing.expectEqual(
        @as(i64, 2),
        try scalar(db, "SELECT count(*) FROM orca_metadata_values;"),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try scalar(db, "SELECT locked FROM orca_metadata_values WHERE field=0;"),
    );
    try std.testing.expectEqual(
        @as(i64, 3),
        try scalar(db, "SELECT count(*) FROM analysis_results;"),
    );
    try std.testing.expectEqual(
        @as(i64, 3),
        try scalar(db, "SELECT count(*) FROM library_health_issues;"),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try scalar(db, "SELECT count(*) FROM identification_proposals;"),
    );
    // Untouched tables keep their rows.
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM provider_cache;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM scrobble_queue;"));

    // The journal keeps its paths and gains the file it acted on.
    try std.testing.expectEqual(
        @as(i64, 1),
        try scalar(db,
            \\SELECT count(*) FROM mutation_operations
            \\JOIN locations ON locations.file_id = mutation_operations.file_id
            \\WHERE locations.uri = mutation_operations.source_path;
        ),
    );
    try checkForeignKeys(db);
}

test "analysis and health rows for never-scanned paths survive the migration" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "orphans.db");
    defer std.testing.allocator.free(path);
    try copyFixture(std.testing.allocator, std.testing.io, path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try apply(db);

    // Both orphans became unverified files with a location naming where they
    // were last claimed to be. Destroying a cached analysis during an upgrade
    // would be a silent data loss the user never asked for.
    try std.testing.expectEqual(
        @as(i64, 1),
        try scalar(db,
            \\SELECT count(*) FROM analysis_results
            \\JOIN locations ON locations.file_id = analysis_results.file_id
            \\WHERE locations.uri = '/orphan/analyzed-but-never-scanned.flac'
            \\  AND locations.state = 'unverified';
        ),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try scalar(db,
            \\SELECT count(*) FROM library_health_issues
            \\JOIN locations ON locations.file_id = library_health_issues.file_id
            \\WHERE locations.uri = '/orphan/health-only.mp3';
        ),
    );
    // The legacy analysis identity is preserved distinctly rather than being
    // collapsed onto a hash nobody computed.
    const identity = try text(std.testing.allocator, db,
        \\SELECT CAST(source_identity AS TEXT) FROM analysis_results
        \\JOIN locations ON locations.file_id = analysis_results.file_id
        \\WHERE locations.uri = '/orphan/analyzed-but-never-scanned.flac';
    );
    defer std.testing.allocator.free(identity);
    try std.testing.expectEqualStrings("v7:2048:1690000000000000000", identity);
}

test "the rebuilt full-text index searches the tracks it inherited" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "search.db");
    defer std.testing.allocator.free(path);
    try copyFixture(std.testing.allocator, std.testing.io, path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try apply(db);

    var statement = try db.prepare(
        \\SELECT tracks.title FROM track_search
        \\JOIN tracks ON tracks.id = track_search.rowid
        \\WHERE track_search MATCH 'Northern';
    );
    defer statement.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try statement.step());
    try std.testing.expectEqualStrings("Northern Sky", statement.columnText(0));
    try std.testing.expectEqual(sqlite.Step.done, try statement.step());

    // The fourth column is the point of the rebuild: an artist the old index
    // could not have matched.
    try db.exec(
        \\UPDATE tracks SET artist='Nick Drake' WHERE title='Hazey Jane II';
    );
    var by_artist = try db.prepare(
        \\SELECT count(*) FROM track_search WHERE track_search MATCH 'artist:Drake';
    );
    defer by_artist.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try by_artist.step());
    try std.testing.expectEqual(@as(i64, 1), by_artist.columnInt64(0));
}

test "migrating a database that is already current changes nothing" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "idempotent.db");
    defer std.testing.allocator.free(path);
    try copyFixture(std.testing.allocator, std.testing.io, path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try apply(db);
    const schema = try schemaObjects(std.testing.allocator, db);
    defer std.testing.allocator.free(schema);
    const files = try scalar(db, "SELECT count(*) FROM files;");

    try apply(db);
    const schema_again = try schemaObjects(std.testing.allocator, db);
    defer std.testing.allocator.free(schema_again);
    try std.testing.expectEqualStrings(schema, schema_again);
    try std.testing.expectEqual(files, try scalar(db, "SELECT count(*) FROM files;"));
    try std.testing.expectEqual(@as(i64, 8), try scalar(db, "PRAGMA user_version;"));
}

test "an empty database migrates straight to the current version" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "fresh.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try apply(db);
    try std.testing.expectEqual(@as(i64, 8), try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM files;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM locations;"));
    try std.testing.expectEqual(
        @as(i64, 1),
        try scalar(db, "SELECT count(*) FROM volumes WHERE stable_key='legacy';"),
    );
    try checkForeignKeys(db);
}

test "an unknown newer schema version is refused rather than opened" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "future.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try apply(db);
    try db.exec("PRAGMA user_version=9;");
    try std.testing.expectError(error.SchemaVersionTooNew, apply(db));
}
