const std = @import("std");
const sqlite = @import("sqlite.zig");
const repository = @import("repository.zig");
const text_key = @import("text_key.zig");
const genre_alias = @import("../metadata/genre_alias.zig");

pub const current_version = 58;

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

/// Version 9: the browse model.
///
/// Until this migration the only artist reachable from a Track was the
/// denormalized `tracks.artist` text, so nothing could ask "what else is by
/// this artist" without a full table scan and a string comparison. It adds the
/// two relational links a browse model needs, backfills them from the text
/// that is already there, gives every artist a sort key, and creates the
/// indexes the new queries order by.
///
/// **One artist per track, one album artist per release, deliberately.** The
/// tag data this targets is single-valued on ARTIST and ALBUMARTIST in
/// essentially every file, and splitting featured artists is a metadata
/// problem (it needs a parser, a provenance story and a user-visible review
/// step) rather than a schema one. The extension path, when that work happens,
/// is a `track_artists(track_id, artist_id, ordinal, role)` join table
/// alongside these columns: `artist_id` stays as the *primary* artist a
/// listing sorts and files by, and the join table carries the rest. Nothing
/// here has to be undone to get there.
///
/// The backfill runs the same two-step cascade `ArtistRepository.ensureLocked`
/// runs, in the same order, because anything else would file Tracks differently
/// from a fresh scan. A MusicBrainz artist id outranks the name — it is what
/// recognizes "Cosmo's Midnight feat. Wave Racer" as Cosmo's Midnight — so the
/// observed id on a Track's preferred file is tried first, and only what it
/// cannot answer falls back to `orca_artist_key`, which is
/// `text_key.normalizeKey`, the exact function `ArtistRepository` folds with. A
/// migrated database and a freshly scanned one therefore agree row for row,
/// which `library/projection.zig` asserts.
///
/// None of the new indexes names `id` explicitly. `id` is `INTEGER PRIMARY
/// KEY`, so it *is* the rowid and SQLite already appends it to every index
/// entry — which is why an `ORDER BY ... , tracks.id` that ends a listing's
/// total order is satisfied straight from `tracks(title COLLATE NOCASE)` with
/// no temp B-tree, and why spelling it out would only store the value twice.
const migration_9_columns =
    \\ALTER TABLE tracks ADD COLUMN artist_id INTEGER REFERENCES artists(id);
    \\ALTER TABLE releases ADD COLUMN album_artist_id INTEGER REFERENCES artists(id);
;

/// The backfill on its own, so a test can null the three columns out of a
/// freshly projected library, run exactly this, and prove the result is what
/// the projection wrote. That equivalence is the whole promise of the
/// migration; asserting it against the migration as a whole would also be
/// asserting `CREATE INDEX`, which proves nothing about who an artist is.
pub const artist_backfill =
    \\UPDATE artists SET sort_name = orca_artist_sort_key(name);
    \\UPDATE tracks SET artist_id = (
    \\    SELECT artists.id FROM artists
    \\    JOIN observed_file_tags ON observed_file_tags.musicbrainz_artist_id =
    \\        artists.musicbrainz_artist_id
    \\    WHERE observed_file_tags.file_id = tracks.preferred_file_id
    \\      AND COALESCE(observed_file_tags.musicbrainz_artist_id, '') <> ''
    \\    ORDER BY artists.id LIMIT 1
    \\) WHERE tracks.artist <> '';
    \\UPDATE tracks SET artist_id = (
    \\    SELECT artists.id FROM artists WHERE artists.key = orca_artist_key(tracks.artist)
    \\) WHERE tracks.artist_id IS NULL AND tracks.artist <> '';
    \\UPDATE releases SET album_artist_id = (
    \\    SELECT artists.id FROM artists
    \\    JOIN observed_file_tags ON observed_file_tags.musicbrainz_album_artist_id =
    \\        artists.musicbrainz_artist_id
    \\    JOIN tracks ON tracks.preferred_file_id = observed_file_tags.file_id
    \\    WHERE tracks.release_id = releases.id
    \\      AND COALESCE(observed_file_tags.musicbrainz_album_artist_id, '') <> ''
    \\    ORDER BY artists.id LIMIT 1
    \\) WHERE releases.album_artist <> '';
    \\UPDATE releases SET album_artist_id = (
    \\    SELECT artists.id FROM artists
    \\    WHERE artists.key = orca_artist_key(releases.album_artist)
    \\) WHERE releases.album_artist_id IS NULL AND releases.album_artist <> '';
;

const migration_9_indexes =
    \\CREATE INDEX artists_sort ON artists(sort_name);
    \\CREATE INDEX releases_by_artist
    \\    ON releases(album_artist_id, title COLLATE NOCASE);
    \\DROP INDEX tracks_album;
    \\CREATE INDEX tracks_sort_artist ON tracks(
    \\    artist COLLATE NOCASE, album COLLATE NOCASE,
    \\    COALESCE(disc_number, 1), COALESCE(track_number, 2147483647)
    \\);
    \\CREATE INDEX tracks_sort_album ON tracks(
    \\    album COLLATE NOCASE,
    \\    COALESCE(disc_number, 1), COALESCE(track_number, 2147483647)
    \\);
    \\CREATE INDEX tracks_sort_title ON tracks(title COLLATE NOCASE);
    \\CREATE INDEX tracks_sort_position ON tracks(
    \\    COALESCE(disc_number, 1), COALESCE(track_number, 2147483647)
    \\);
    \\CREATE INDEX tracks_sort_duration ON tracks(duration_ms);
    \\CREATE INDEX tracks_sort_added ON tracks(created_at);
    \\CREATE INDEX tracks_by_artist ON tracks(
    \\    artist_id, album COLLATE NOCASE,
    \\    COALESCE(disc_number, 1), COALESCE(track_number, 2147483647)
    \\);
    \\CREATE INDEX tracks_by_artist_title ON tracks(artist_id, title COLLATE NOCASE);
    \\CREATE INDEX tracks_by_artist_duration ON tracks(artist_id, duration_ms);
    \\CREATE INDEX tracks_by_artist_added ON tracks(artist_id, created_at);
    \\CREATE INDEX tracks_by_artist_position ON tracks(
    \\    artist_id, COALESCE(disc_number, 1), COALESCE(track_number, 2147483647)
    \\);
    \\CREATE INDEX tracks_by_release ON tracks(
    \\    release_id, COALESCE(disc_number, 1), COALESCE(track_number, 2147483647)
    \\);
    \\CREATE INDEX tracks_artist ON tracks(artist_id);
    \\CREATE INDEX tracks_release ON tracks(release_id);
;

const migration_9 = migration_9_columns ++ artist_backfill ++ migration_9_indexes;

/// Version 10: finding the files whose declared properties are still missing.
///
/// A library scanned before probing existed keeps null `duration_ms`,
/// `sample_rate` and `channels` for ever, because only a file whose *bytes*
/// change is ever re-probed and a music collection's bytes essentially never
/// change. The repair pass that fixes that needs to ask "which rows still owe
/// a probe" repeatedly, and asking it with a bare `WHERE ... IS NULL` would
/// scan every row of the largest table in the schema each time.
///
/// A **partial** index answers it instead, and it is the right shape here for
/// a reason that is not obvious: the index contains exactly the rows that are
/// still broken, so it starts small on a healthy library, shrinks as the pass
/// repairs rows, and reaches empty — at which point asking the question costs
/// one B-tree probe rather than 500,000 row reads. A full index on the same
/// columns would instead be largest precisely when there is nothing to do.
///
/// The predicate is `repository.incomplete_properties_predicate` verbatim.
/// SQLite matches a partial index against a query by expression rather than by
/// meaning, so the two must be the same string, which is why it has exactly
/// one definition and both sides import it.
const migration_10 =
    "CREATE INDEX files_incomplete_properties ON files(id) WHERE " ++
    repository.incomplete_properties_predicate ++ ";";

/// Re-key artists once the fold learned typographic punctuation, merging the
/// rows that were only ever distinct because of it.
///
/// This cannot be left to a reprojection. `ArtistRepository.ensure` upserts by
/// key, so reprojecting would file the tracks under the merged artist and
/// leave the old row behind as an orphan holding the releases -- the same
/// split, one row further along. The merge has to happen here, where both rows
/// are still visible.
///
/// Survivor choice is the row carrying a MusicBrainz artist id, falling back
/// to the lowest id. A MusicBrainz id is the strongest statement about who an
/// artist is that this library holds, and in the observed splits it is the
/// typographic spelling that carries one -- which is also the better display
/// name, since it is what a metadata service supplied rather than what
/// somebody typed.
///
/// The unique index is dropped for the duration because a row's *new* key can
/// equal another row's *old* key, which SQLite would reject row by row even
/// though the finished state is unique.
///
/// It then **re-runs migration 9's key join**, and that is not belt-and-braces.
/// Migration 9 linked tracks and releases to artists with
/// `artists.key = orca_artist_key(...)`: the *current* fold compared against a
/// key written by whichever fold was current when the row was projected. An
/// artist stored under a pre-fold spelling never matched, and the link was left
/// NULL. Re-keying here repairs the key and would otherwise walk away from the
/// links that key was supposed to make.
///
/// Anything that re-keys `artists` in future has to re-run the link in the same
/// migration. They are one operation, not two that happen to be adjacent.
const migration_11 =
    \\DROP INDEX IF EXISTS artists_key;
    \\CREATE TEMP TABLE artist_refold AS
    \\    SELECT id, orca_artist_key(name) AS folded FROM artists;
    \\CREATE TEMP TABLE artist_survivor AS
    \\    SELECT r.folded AS folded,
    \\           (SELECT a.id FROM artists a
    \\              JOIN artist_refold r2 ON r2.id = a.id
    \\             WHERE r2.folded = r.folded
    \\             ORDER BY (a.musicbrainz_artist_id IS NULL), a.id
    \\             LIMIT 1) AS keep_id
    \\      FROM artist_refold r GROUP BY r.folded;
    \\UPDATE tracks SET artist_id = (
    \\    SELECT s.keep_id FROM artist_refold r
    \\      JOIN artist_survivor s ON s.folded = r.folded
    \\     WHERE r.id = tracks.artist_id)
    \\  WHERE artist_id IS NOT NULL;
    \\UPDATE releases SET album_artist_id = (
    \\    SELECT s.keep_id FROM artist_refold r
    \\      JOIN artist_survivor s ON s.folded = r.folded
    \\     WHERE r.id = releases.album_artist_id)
    \\  WHERE album_artist_id IS NOT NULL;
    \\-- NOT EXISTS rather than NOT IN: a single NULL keep_id would make
    \\-- `NOT IN` evaluate to NULL for every row, delete nothing, and leave the
    \\-- duplicate keys for CREATE UNIQUE INDEX below to fail on. It cannot be
    \\-- NULL today; the trap is not worth keeping for the syntax.
    \\DELETE FROM artists WHERE NOT EXISTS (
    \\    SELECT 1 FROM artist_survivor WHERE artist_survivor.keep_id = artists.id);
    \\UPDATE artists
    \\   SET key = orca_artist_key(name), sort_name = orca_artist_sort_key(name);
    \\DROP TABLE artist_refold;
    \\DROP TABLE artist_survivor;
    \\CREATE UNIQUE INDEX artists_key ON artists(key);
    \\UPDATE tracks SET artist_id = (
    \\    SELECT artists.id FROM artists WHERE artists.key = orca_artist_key(tracks.artist)
    \\) WHERE tracks.artist_id IS NULL AND tracks.artist <> '';
    \\UPDATE releases SET album_artist_id = (
    \\    SELECT artists.id FROM artists
    \\    WHERE artists.key = orca_artist_key(releases.album_artist)
    \\) WHERE releases.album_artist_id IS NULL AND releases.album_artist <> '';
;

/// Re-key releases for the same reason as migration 11, which missed them.
///
/// `release_key` is folded text joined by 0x1f separators, so applying the
/// current fold to the *stored* key yields exactly what composing it afresh
/// would: the separators and a MusicBrainz id pass through untouched, and
/// folding already-folded case and whitespace is a no-op. Only the newly
/// folded punctuation moves.
///
/// A stale key corrupts the library: `ReleaseRepository.upsert` keys on
/// `release_key`, so the next projection of an already-projected library -- a
/// rescan, a metadata edit, or the property backfill's per-batch reprojection
/// -- matches nothing and builds a parallel release beside each stale one.
///
/// Unlike artists, colliding rows are skipped rather than merged. Two releases
/// that fold together are the same album spelled two ways, and their tracks
/// share track numbers, so repointing them would violate `tracks_position` and
/// fail the migration -- refusing to open the library over a duplicate album
/// is far worse than leaving two rows for a projection to reconcile.
///
/// The guard has to cover *both* shapes of collision. Rejecting a row whose
/// folded key already belongs to another row misses the case where **two** rows
/// both need folding and fold to the same value: both pass the guard, both
/// update, and the still-live `releases_key` unique index rejects the second,
/// failing the migration and leaving the library unopenable at its old version:
/// U+2019 and U+2018 both fold to an apostrophe.
const migration_12 =
    \\UPDATE releases
    \\   SET release_key = orca_release_key(release_key)
    \\ WHERE orca_release_key(release_key) <> release_key
    \\   AND NOT EXISTS (
    \\        SELECT 1 FROM releases other
    \\         WHERE other.id <> releases.id
    \\           AND (other.release_key = orca_release_key(releases.release_key)
    \\                OR orca_release_key(other.release_key) =
    \\                   orca_release_key(releases.release_key)));
;

/// The bucket key duplicate detection compares temporal fingerprints inside.
///
/// Two files can only be the same recording if they are the same length, so a
/// duration window is what makes a pairwise comparison affordable: it turns
/// "compare this file against the library" into "compare it against the
/// handful of files that could possibly match". Without an index that window
/// is a full scan of `files` per candidate, which is O(n^2) reads -- the exact
/// cost the indexed design exists to avoid.
///
/// `files_audio_hash` already serves the other bucket, exact decoded audio, so
/// only this one had to be added.
const migration_13 =
    "CREATE INDEX files_duration ON files(duration_ms, id);";

/// The lookup that finds a file's stale Tracks when a reprojection moves it to
/// another position. Without it each lookup is a full scan of `tracks`, once
/// per file in every reprojected folder.
const migration_14 =
    "CREATE INDEX tracks_by_preferred_file ON tracks(preferred_file_id);";

/// A listen is keyed on `files.id`, the identity that survives a reprojection
/// giving a Track a new id, and keeps a snapshot of what was heard so history
/// stays readable after `remove-root` forgets the file and nulls `file_id`.
const migration_15 =
    \\CREATE TABLE listens (
    \\    id INTEGER PRIMARY KEY,
    \\    file_id INTEGER REFERENCES files(id) ON DELETE SET NULL,
    \\    recording_id INTEGER REFERENCES recordings(id) ON DELETE SET NULL,
    \\    started_at INTEGER NOT NULL,
    \\    listened_ms INTEGER NOT NULL,
    \\    duration_ms INTEGER,
    \\    title TEXT NOT NULL,
    \\    artist TEXT NOT NULL,
    \\    album TEXT NOT NULL DEFAULT '',
    \\    recording_mbid TEXT,
    \\    player_client TEXT NOT NULL DEFAULT '',
    \\    UNIQUE(file_id, started_at)
    \\);
    \\CREATE INDEX listens_by_file ON listens(file_id, started_at);
    \\ALTER TABLE scrobble_queue ADD COLUMN lease_owner INTEGER;
    \\ALTER TABLE scrobble_queue ADD COLUMN lease_expires_at INTEGER;
    \\CREATE INDEX scrobble_queue_leased
    \\    ON scrobble_queue(lease_expires_at) WHERE state = 1;
;

/// A `score` of 0 beside a `synced_score` is a clear not yet sent; the row is deleted once it is.
const migration_16 =
    \\CREATE TABLE feedback (
    \\    recording_id INTEGER PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,
    \\    score INTEGER NOT NULL CHECK (score IN (-1, 0, 1)),
    \\    updated_at INTEGER NOT NULL,
    \\    synced_score INTEGER,
    \\    synced_at INTEGER,
    \\    last_error TEXT NOT NULL DEFAULT ''
    \\);
    \\CREATE INDEX files_by_recording ON files(recording_id);
;

/// A file counts as searched by a provider once that provider answered for
/// it, even with nothing, so no search is repeated. Files MusicBrainz proposed
/// something for before this version were searched by it.
const migration_17 =
    \\CREATE TABLE identification_searches (
    \\    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    \\    provider TEXT NOT NULL,
    \\    searched_at INTEGER NOT NULL,
    \\    PRIMARY KEY(file_id, provider)
    \\) WITHOUT ROWID;
    \\INSERT INTO identification_searches(file_id, provider, searched_at)
    \\    SELECT file_id, 'musicbrainz', max(updated_at) FROM identification_proposals
    \\    WHERE provider = 'musicbrainz' GROUP BY file_id;
    \\CREATE TABLE acoustid_submissions (
    \\    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    \\    recording_mbid TEXT NOT NULL,
    \\    submission_id INTEGER,
    \\    submitted_at INTEGER NOT NULL,
    \\    PRIMARY KEY(file_id, recording_mbid)
    \\) WITHOUT ROWID;
;

/// Forget the files a scan made of tag-write stages and backups kept beside the
/// music. Only a file whose every location is a path the journal names as a
/// stage, backup or recovery leftover goes; a file located anywhere else is
/// music, whatever else it shares.
const migration_18 =
    \\CREATE TEMP TABLE orca_temporaries(uri TEXT PRIMARY KEY);
    \\INSERT OR IGNORE INTO temp.orca_temporaries(uri)
    \\    SELECT stage_path FROM mutation_operations WHERE stage_path IS NOT NULL
    \\    UNION SELECT backup_path FROM mutation_operations WHERE backup_path IS NOT NULL
    \\    UNION SELECT stage_path || '.recovery-displaced' FROM mutation_operations
    \\          WHERE stage_path IS NOT NULL;
    \\CREATE TEMP TABLE ghost_files(id INTEGER PRIMARY KEY);
    \\INSERT INTO temp.ghost_files(id)
    \\    SELECT DISTINCT file_id FROM locations AS ghost
    \\    WHERE NOT EXISTS (
    \\        SELECT 1 FROM locations AS other
    \\        WHERE other.file_id = ghost.file_id
    \\          AND other.uri NOT IN (SELECT uri FROM temp.orca_temporaries));
    \\CREATE TEMP TABLE ghost_releases(id INTEGER PRIMARY KEY);
    \\INSERT OR IGNORE INTO temp.ghost_releases(id)
    \\    SELECT release_id FROM tracks
    \\    WHERE preferred_file_id IN (SELECT id FROM temp.ghost_files) AND release_id IS NOT NULL;
    \\CREATE TEMP TABLE ghost_artists(id INTEGER PRIMARY KEY);
    \\INSERT OR IGNORE INTO temp.ghost_artists(id)
    \\    SELECT artist_id FROM tracks
    \\    WHERE preferred_file_id IN (SELECT id FROM temp.ghost_files) AND artist_id IS NOT NULL;
    \\DELETE FROM tracks WHERE preferred_file_id IN (SELECT id FROM temp.ghost_files);
    \\INSERT OR IGNORE INTO temp.ghost_artists(id)
    \\    SELECT album_artist_id FROM releases
    \\    WHERE id IN (SELECT id FROM temp.ghost_releases) AND album_artist_id IS NOT NULL
    \\      AND NOT EXISTS (SELECT 1 FROM tracks WHERE tracks.release_id = releases.id);
    \\DELETE FROM releases
    \\    WHERE id IN (SELECT id FROM temp.ghost_releases)
    \\      AND NOT EXISTS (SELECT 1 FROM tracks WHERE tracks.release_id = releases.id);
    \\DELETE FROM artists
    \\    WHERE id IN (SELECT id FROM temp.ghost_artists)
    \\      AND NOT EXISTS (SELECT 1 FROM tracks WHERE tracks.artist_id = artists.id)
    \\      AND NOT EXISTS (SELECT 1 FROM releases WHERE releases.album_artist_id = artists.id);
    \\UPDATE mutation_operations SET file_id = NULL
    \\    WHERE file_id IN (SELECT id FROM temp.ghost_files);
    \\DELETE FROM locations WHERE file_id IN (SELECT id FROM temp.ghost_files);
    \\DELETE FROM files WHERE id IN (SELECT id FROM temp.ghost_files);
    \\DROP TABLE temp.ghost_artists;
    \\DROP TABLE temp.ghost_releases;
    \\DROP TABLE temp.ghost_files;
    \\DROP TABLE temp.orca_temporaries;
;

/// A service's rate-limit block and backoff, and the lease that lets one
/// process at a time talk to it, shared by every process that opens the
/// Library. Times are Unix milliseconds.
const migration_19 =
    \\CREATE TABLE provider_state (
    \\    service TEXT PRIMARY KEY,
    \\    blocked_until_ms INTEGER,
    \\    backoff_ms INTEGER NOT NULL DEFAULT 0
    \\) WITHOUT ROWID;
    \\CREATE TABLE provider_leases (
    \\    service TEXT PRIMARY KEY,
    \\    owner INTEGER NOT NULL,
    \\    expires_at INTEGER NOT NULL
    \\) WITHOUT ROWID;
    \\ALTER TABLE identification_proposals ADD COLUMN accepted_in_bulk INTEGER NOT NULL DEFAULT 0;
;

/// Front covers fetched from the Cover Art Archive, one per Release. A null
/// `image` records that the archive had none, as of `fetched_at` in Unix
/// seconds.
const migration_20 =
    \\CREATE TABLE release_artwork (
    \\    release_id INTEGER PRIMARY KEY REFERENCES releases(id) ON DELETE CASCADE,
    \\    musicbrainz_release_id TEXT NOT NULL,
    \\    image BLOB,
    \\    mime TEXT,
    \\    fetched_at INTEGER NOT NULL
    \\);
;

const migration_21 =
    \\ALTER TABLE orca_metadata_values ADD COLUMN written_at INTEGER;
;

const migration_22 =
    \\UPDATE locations SET modified_ns = -1
    \\WHERE state = 'present' AND file_id IN (
    \\    SELECT file_id FROM observed_file_tags AS observed
    \\    WHERE artwork_byte_size IS NOT NULL
    \\      AND title IS NULL AND artist IS NULL AND album IS NULL
    \\      AND album_artist IS NULL AND composer IS NULL
    \\      AND track_number IS NULL AND track_total IS NULL
    \\      AND disc_number IS NULL AND disc_total IS NULL
    \\      AND date IS NULL AND original_date IS NULL AND compilation IS NULL
    \\      AND label IS NULL AND media IS NULL AND isrc IS NULL
    \\      AND release_country IS NULL AND release_type IS NULL
    \\      AND release_status IS NULL
    \\      AND musicbrainz_recording_id IS NULL AND musicbrainz_release_id IS NULL
    \\      AND musicbrainz_release_group_id IS NULL
    \\      AND musicbrainz_release_track_id IS NULL
    \\      AND musicbrainz_artist_id IS NULL AND musicbrainz_album_artist_id IS NULL
    \\      AND NOT EXISTS (
    \\          SELECT 1 FROM observed_file_genres AS genre WHERE genre.file_id = observed.file_id
    \\      )
    \\);
;

const migration_23 =
    \\UPDATE files SET audio_hash = NULL
    \\WHERE audio_hash IS NOT NULL AND NOT EXISTS (
    \\    SELECT 1 FROM analysis_results AS fingerprint
    \\    WHERE fingerprint.file_id = files.id
    \\      AND fingerprint.kind = 2
    \\      AND fingerprint.algorithm_id = 'orca.temporal-fingerprint'
    \\      AND fingerprint.algorithm_version = 2
    \\      AND fingerprint.source_identity = files.quick_hash
    \\);
;

const migration_24 =
    \\ALTER TABLE provider_state ADD COLUMN next_request_ms INTEGER;
;

const migration_25 =
    \\UPDATE locations SET modified_ns = -1
    \\WHERE state = 'present' AND file_id IN (
    \\    SELECT file_id FROM locations WHERE state = 'present'
    \\    GROUP BY file_id HAVING count(*) > 1
    \\);
;

const migration_26 =
    \\UPDATE mutation_operations SET state = 6
    \\WHERE state = 2
    \\  AND group_id IN (SELECT group_id FROM mutation_operations WHERE state = 3)
    \\  AND group_id NOT IN (SELECT group_id FROM mutation_operations WHERE state IN (0, 1, 4, 5));
;

const migration_27 =
    \\CREATE TABLE ratings (
    \\    recording_id INTEGER PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,
    \\    rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 100),
    \\    updated_at INTEGER NOT NULL
    \\);
    \\INSERT INTO ratings SELECT recording_id, max(rating), unixepoch() FROM tracks
    \\    WHERE rating BETWEEN 1 AND 100 AND recording_id IS NOT NULL GROUP BY recording_id;
    \\DROP INDEX tracks_rating;
    \\ALTER TABLE tracks DROP COLUMN rating;
    \\CREATE INDEX tracks_by_recording ON tracks(recording_id);
    \\CREATE TABLE playlists (
    \\    id INTEGER PRIMARY KEY,
    \\    name TEXT NOT NULL UNIQUE,
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\CREATE TABLE playlist_entries (
    \\    playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    \\    position INTEGER NOT NULL,
    \\    recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
    \\    added_at INTEGER NOT NULL,
    \\    PRIMARY KEY(playlist_id, position)
    \\) WITHOUT ROWID;
    \\CREATE INDEX playlist_entries_by_recording ON playlist_entries(recording_id);
    \\CREATE INDEX locations_by_uri ON locations(uri);
;

const migration_28 =
    \\CREATE TABLE recording_verifications (
    \\    file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
    \\    quick_hash BLOB,
    \\    recording_mbid TEXT NOT NULL,
    \\    outcome INTEGER NOT NULL,
    \\    heard TEXT,
    \\    verified_at INTEGER NOT NULL
    \\);
    \\ALTER TABLE identification_proposals ADD COLUMN album_group INTEGER;
    \\CREATE INDEX identification_proposals_album_group
    \\    ON identification_proposals(album_group, state) WHERE album_group IS NOT NULL;
;

const migration_29 =
    \\CREATE TABLE health_dismissals (
    \\    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    \\    kind INTEGER NOT NULL,
    \\    quick_hash BLOB,
    \\    dismissed_at INTEGER NOT NULL,
    \\    PRIMARY KEY(file_id, kind)
    \\) WITHOUT ROWID;
    \\ALTER TABLE library_health_issues
    \\    ADD COLUMN related_file_id INTEGER REFERENCES files(id) ON DELETE SET NULL;
    \\CREATE INDEX library_health_by_related
    \\    ON library_health_issues(related_file_id) WHERE related_file_id IS NOT NULL;
;

const migration_30 =
    \\CREATE TABLE release_loves (
    \\    release_id INTEGER PRIMARY KEY REFERENCES releases(id) ON DELETE CASCADE,
    \\    loved_at INTEGER NOT NULL
    \\);
;

const migration_31 =
    \\CREATE TABLE track_lyrics (
    \\    track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
    \\    query_digest BLOB NOT NULL,
    \\    lrclib_id INTEGER,
    \\    synced TEXT,
    \\    plain TEXT,
    \\    instrumental INTEGER NOT NULL DEFAULT 0,
    \\    fetched_at INTEGER NOT NULL
    \\);
;

const migration_32 =
    \\CREATE TABLE recording_play_stats (
    \\    recording_id INTEGER PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,
    \\    play_count INTEGER NOT NULL,
    \\    last_played_at INTEGER NOT NULL
    \\);
    \\UPDATE listens SET recording_id = (SELECT recording_id FROM files WHERE files.id = listens.file_id)
    \\WHERE file_id IS NOT NULL;
    \\INSERT INTO recording_play_stats(recording_id, play_count, last_played_at)
    \\    SELECT recording_id, count(*), max(started_at) FROM listens
    \\    WHERE recording_id IS NOT NULL GROUP BY recording_id;
    \\CREATE INDEX recording_play_stats_by_count
    \\    ON recording_play_stats(play_count DESC, recording_id);
    \\CREATE INDEX recording_play_stats_by_last_played
    \\    ON recording_play_stats(last_played_at DESC, recording_id);
    \\CREATE INDEX listens_by_recording ON listens(recording_id, started_at);
    \\CREATE TRIGGER files_recording_moves_listens
    \\AFTER UPDATE OF recording_id ON files
    \\WHEN OLD.recording_id IS NOT NEW.recording_id
    \\    AND EXISTS (SELECT 1 FROM listens WHERE file_id = NEW.id)
    \\BEGIN
    \\    UPDATE listens SET recording_id = NEW.recording_id WHERE file_id = NEW.id;
    \\    DELETE FROM recording_play_stats WHERE recording_id IN (OLD.recording_id, NEW.recording_id);
    \\    INSERT INTO recording_play_stats(recording_id, play_count, last_played_at)
    \\        SELECT recording_id, count(*), max(started_at) FROM listens
    \\        WHERE recording_id IN (OLD.recording_id, NEW.recording_id) GROUP BY recording_id;
    \\END;
    \\ALTER TABLE observed_file_tags ADD COLUMN explicit INTEGER;
    \\ALTER TABLE tracks ADD COLUMN track_total INTEGER;
    \\ALTER TABLE tracks ADD COLUMN disc_total INTEGER;
    \\ALTER TABLE tracks ADD COLUMN explicit INTEGER NOT NULL DEFAULT 0;
    \\ALTER TABLE releases ADD COLUMN release_type TEXT;
    \\CREATE INDEX files_by_first_seen ON files(first_seen_at);
    \\CREATE INDEX ratings_by_rating ON ratings(rating);
    \\CREATE INDEX feedback_loved ON feedback(updated_at) WHERE score = 1;
    \\CREATE INDEX releases_by_year ON releases((
    \\    CASE WHEN substr(release_date, 1, 4) GLOB '[0-9][0-9][0-9][0-9]'
    \\    THEN CAST(substr(release_date, 1, 4) AS INTEGER) END));
    \\UPDATE tracks SET
    \\    track_total = COALESCE(
    \\        (SELECT track_total FROM observed_file_tags WHERE file_id = tracks.preferred_file_id
    \\         AND track_total > 0),
    \\        (SELECT member_tags.track_total FROM files AS member
    \\         JOIN observed_file_tags AS member_tags ON member_tags.file_id = member.id
    \\         WHERE member.recording_id = tracks.recording_id AND member_tags.track_total > 0
    \\         ORDER BY member.id LIMIT 1),
    \\        CASE WHEN tracks.release_id IS NOT NULL THEN
    \\            (SELECT max(count(*), COALESCE(max(sibling.track_number), 0)) FROM tracks AS sibling
    \\             WHERE sibling.release_id = tracks.release_id
    \\               AND COALESCE(sibling.disc_number, 1) = COALESCE(tracks.disc_number, 1))
    \\        END),
    \\    disc_total = COALESCE(
    \\        (SELECT disc_total FROM observed_file_tags WHERE file_id = tracks.preferred_file_id
    \\         AND disc_total > 0),
    \\        (SELECT member_tags.disc_total FROM files AS member
    \\         JOIN observed_file_tags AS member_tags ON member_tags.file_id = member.id
    \\         WHERE member.recording_id = tracks.recording_id AND member_tags.disc_total > 0
    \\         ORDER BY member.id LIMIT 1),
    \\        (SELECT disc_count FROM releases WHERE releases.id = tracks.release_id));
;

const migration_33 =
    \\CREATE TABLE genres (
    \\    id INTEGER PRIMARY KEY,
    \\    name TEXT NOT NULL,
    \\    key TEXT NOT NULL UNIQUE
    \\);
    \\CREATE TABLE track_genres (
    \\    track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    \\    genre_id INTEGER NOT NULL REFERENCES genres(id) ON DELETE CASCADE,
    \\    ordinal INTEGER NOT NULL,
    \\    provenance INTEGER NOT NULL,
    \\    PRIMARY KEY(track_id, ordinal)
    \\) WITHOUT ROWID;
    \\CREATE UNIQUE INDEX track_genres_by_genre ON track_genres(genre_id, track_id);
    \\CREATE TEMP TABLE genre_sources AS
    \\    SELECT tracks.id AS track_id, COALESCE(
    \\        (SELECT tracks.preferred_file_id WHERE EXISTS
    \\            (SELECT 1 FROM observed_file_genres WHERE file_id = tracks.preferred_file_id)),
    \\        (SELECT min(member.id) FROM files AS member
    \\         WHERE member.recording_id = tracks.recording_id
    \\           AND EXISTS (SELECT 1 FROM observed_file_genres WHERE file_id = member.id))) AS file_id
    \\    FROM tracks;
    \\DELETE FROM temp.genre_sources WHERE file_id IS NULL;
    \\CREATE TEMP TABLE genre_values AS
    \\    WITH RECURSIVE parts(track_id, ordinal, value, part_index, part) AS (
    \\        SELECT source.track_id, observed.ordinal, observed.value, 0, orca_genre_part(observed.value, 0)
    \\        FROM temp.genre_sources AS source
    \\        JOIN observed_file_genres AS observed ON observed.file_id = source.file_id
    \\        UNION ALL
    \\        SELECT track_id, ordinal, value, part_index + 1, orca_genre_part(value, part_index + 1)
    \\        FROM parts WHERE part IS NOT NULL)
    \\    SELECT track_id,
    \\           row_number() OVER (PARTITION BY track_id ORDER BY ordinal, part_index) AS position,
    \\           orca_genre_key(part) AS key, orca_genre_name(part) AS name
    \\    FROM parts WHERE part IS NOT NULL;
    \\DELETE FROM temp.genre_values WHERE key = '';
    \\INSERT INTO genres(name, key)
    \\    SELECT name, key FROM temp.genre_values WHERE true
    \\    ORDER BY track_id, position
    \\ON CONFLICT(key) DO NOTHING;
    \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance)
    \\    SELECT track_id, genre_id, row_number() OVER (PARTITION BY track_id ORDER BY first_position) - 1, 0
    \\    FROM (SELECT value.track_id, genres.id AS genre_id, min(value.position) AS first_position
    \\          FROM temp.genre_values AS value JOIN genres ON genres.key = value.key
    \\          GROUP BY value.track_id, genres.id);
    \\DROP TABLE temp.genre_values;
    \\DROP TABLE temp.genre_sources;
;

const migration_34 =
    \\CREATE TABLE artist_info (
    \\    artist_id INTEGER PRIMARY KEY REFERENCES artists(id) ON DELETE CASCADE,
    \\    musicbrainz_artist_id TEXT,
    \\    wikidata_id TEXT,
    \\    begin_year INTEGER,
    \\    end_year INTEGER,
    \\    ended INTEGER NOT NULL DEFAULT 0,
    \\    artist_type TEXT,
    \\    biography TEXT,
    \\    biography_source INTEGER,
    \\    biography_url TEXT,
    \\    biography_licence TEXT,
    \\    biography_language TEXT,
    \\    requested_language TEXT,
    \\    photo BLOB,
    \\    photo_mime TEXT,
    \\    photo_source INTEGER,
    \\    photo_url TEXT,
    \\    photo_licence TEXT,
    \\    photo_licence_url TEXT,
    \\    photo_credit TEXT,
    \\    listeners INTEGER,
    \\    listeners_fetched_at INTEGER,
    \\    fetched_at INTEGER NOT NULL,
    \\    outcome INTEGER NOT NULL
    \\);
    \\CREATE TABLE artist_links (
    \\    artist_id INTEGER NOT NULL REFERENCES artists(id) ON DELETE CASCADE,
    \\    kind INTEGER NOT NULL,
    \\    url TEXT NOT NULL,
    \\    PRIMARY KEY(artist_id, kind, url)
    \\) WITHOUT ROWID;
    \\CREATE TABLE artist_related (
    \\    artist_id INTEGER NOT NULL REFERENCES artists(id) ON DELETE CASCADE,
    \\    ordinal INTEGER NOT NULL,
    \\    related_mbid TEXT NOT NULL,
    \\    related_name TEXT NOT NULL,
    \\    score INTEGER NOT NULL,
    \\    PRIMARY KEY(artist_id, ordinal)
    \\) WITHOUT ROWID;
    \\CREATE TABLE artist_loves (
    \\    artist_id INTEGER PRIMARY KEY REFERENCES artists(id) ON DELETE CASCADE,
    \\    loved_at INTEGER NOT NULL
    \\);
    \\CREATE TABLE release_info (
    \\    release_id INTEGER PRIMARY KEY REFERENCES releases(id) ON DELETE CASCADE,
    \\    description TEXT,
    \\    description_source INTEGER,
    \\    description_url TEXT,
    \\    description_licence TEXT,
    \\    description_language TEXT,
    \\    requested_language TEXT,
    \\    musicbrainz_release_id TEXT,
    \\    musicbrainz_release_group_id TEXT,
    \\    fetched_at INTEGER NOT NULL,
    \\    outcome INTEGER NOT NULL
    \\);
    \\CREATE TABLE library_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
;

const migration_35 =
    \\ALTER TABLE playlists ADD COLUMN description TEXT NOT NULL DEFAULT '';
    \\ALTER TABLE playlists ADD COLUMN pinned_at INTEGER;
    \\ALTER TABLE playlists ADD COLUMN loved_at INTEGER;
    \\ALTER TABLE playlists ADD COLUMN kind INTEGER NOT NULL DEFAULT 0;
    \\ALTER TABLE playlists ADD COLUMN rules TEXT;
    \\ALTER TABLE playlists ADD COLUMN creator INTEGER NOT NULL DEFAULT 0;
    \\CREATE TABLE playlist_tags (
    \\    playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    \\    ordinal INTEGER NOT NULL,
    \\    tag TEXT NOT NULL,
    \\    PRIMARY KEY(playlist_id, ordinal)
    \\) WITHOUT ROWID;
;

const migration_37 =
    \\CREATE TABLE related_artist_photos (
    \\    musicbrainz_artist_id TEXT PRIMARY KEY COLLATE NOCASE,
    \\    photo BLOB,
    \\    photo_mime TEXT,
    \\    photo_source INTEGER,
    \\    photo_url TEXT,
    \\    photo_licence TEXT,
    \\    photo_licence_url TEXT,
    \\    photo_credit TEXT,
    \\    fetched_at INTEGER NOT NULL,
    \\    CHECK ((photo IS NULL) = (photo_mime IS NULL)),
    \\    CHECK ((photo IS NULL) = (photo_source IS NULL)),
    \\    CHECK (photo IS NOT NULL OR (photo_url IS NULL AND photo_licence IS NULL
    \\        AND photo_licence_url IS NULL AND photo_credit IS NULL))
    \\) WITHOUT ROWID;
;

const migration_38 =
    \\CREATE INDEX analysis_results_created ON analysis_results(created_at);
    \\DROP TRIGGER tracks_search_ai;
    \\DROP TRIGGER tracks_search_au;
    \\DROP TRIGGER tracks_search_ad;
    \\DELETE FROM search_index WHERE kind = 2;
    \\INSERT INTO search_index(search_index) VALUES ('rebuild');
    \\DROP TRIGGER tracks_au;
    \\CREATE TRIGGER tracks_au AFTER UPDATE OF id, title, artist, album, album_artist ON tracks
    \\WHEN old.id IS NOT new.id OR old.title IS NOT new.title OR old.artist IS NOT new.artist
    \\    OR old.album IS NOT new.album OR old.album_artist IS NOT new.album_artist BEGIN
    \\    INSERT INTO track_search(track_search, rowid, title, artist, album, album_artist)
    \\    VALUES ('delete', old.id, old.title, old.artist, old.album, old.album_artist);
    \\    INSERT INTO track_search(rowid, title, artist, album, album_artist)
    \\    VALUES (new.id, new.title, new.artist, new.album, new.album_artist);
    \\END;
    \\
++ genre_totals_schema;

const migration_39 =
    \\CREATE INDEX releases_artist_order ON releases((upper(substr((CASE WHEN album_artist LIKE 'the _%' THEN substr(album_artist, 5)
    \\      WHEN album_artist LIKE 'an _%' THEN substr(album_artist, 4)
    \\      WHEN album_artist LIKE 'a _%' THEN substr(album_artist, 3) ELSE album_artist END), 1, 1)) BETWEEN 'A' AND 'Z'), (CASE WHEN album_artist LIKE 'the _%' THEN substr(album_artist, 5)
    \\      WHEN album_artist LIKE 'an _%' THEN substr(album_artist, 4)
    \\      WHEN album_artist LIKE 'a _%' THEN substr(album_artist, 3) ELSE album_artist END) COLLATE NOCASE, release_date IS NULL, release_date, title COLLATE NOCASE, id);
    \\CREATE INDEX releases_title_order ON releases((upper(substr(title, 1, 1)) BETWEEN 'A' AND 'Z'), title COLLATE NOCASE, id);
    \\
;

const migration_40 =
    \\CREATE TABLE file_loudness (
    \\    file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
    \\    source_identity BLOB NOT NULL,
    \\    integrated_lufs REAL NOT NULL
    \\);
    \\CREATE INDEX file_loudness_by_lufs ON file_loudness(integrated_lufs);
    \\INSERT INTO file_loudness(file_id, source_identity, integrated_lufs)
    \\
++ loudnessRows(
    \\(SELECT analysis_results.file_id, analysis_results.source_identity, analysis_results.result
    \\     FROM analysis_results
    \\     JOIN files ON files.id = analysis_results.file_id AND files.quick_hash = analysis_results.source_identity
    \\
++ diagnosticsKey("WHERE", "analysis_results") ++ ")") ++
    \\;
    \\CREATE TRIGGER analysis_results_loudness_ai AFTER INSERT ON analysis_results
    \\
++ diagnosticsKey("WHEN", "new") ++ loudness_replace ++
    \\CREATE TRIGGER analysis_results_loudness_au AFTER UPDATE OF result ON analysis_results
    \\
++ diagnosticsKey("WHEN", "new") ++ loudness_replace ++
    \\CREATE TRIGGER analysis_results_loudness_ad AFTER DELETE ON analysis_results
    \\
++ diagnosticsKey("WHEN", "old") ++
    \\BEGIN
    \\    DELETE FROM file_loudness WHERE file_id = old.file_id AND source_identity = old.source_identity;
    \\END;
    \\CREATE INDEX files_by_bitrate ON files((size_bytes * 8 + duration_ms / 2) / duration_ms)
    \\    WHERE size_bytes > 0 AND duration_ms > 0;
    \\CREATE INDEX tracks_sort_album_artist ON tracks(
    \\    album_artist COLLATE NOCASE, album COLLATE NOCASE,
    \\    COALESCE(disc_number, 1), COALESCE(track_number, 2147483647)
    \\);
    \\CREATE INDEX genres_by_name ON genres(name COLLATE NOCASE);
    \\CREATE INDEX track_genres_first ON track_genres(genre_id, track_id) WHERE ordinal = 0;
    \\
;

const migration_41 =
    \\CREATE INDEX files_without_bitrate ON files(id) WHERE (size_bytes > 0 AND duration_ms > 0) IS NOT 1;
    \\
;

const migration_42 =
    \\ALTER TABLE artist_info ADD COLUMN origin TEXT;
    \\CREATE TABLE artist_release_groups (
    \\    artist_id INTEGER NOT NULL REFERENCES artists(id) ON DELETE CASCADE,
    \\    mbid TEXT NOT NULL,
    \\    title TEXT NOT NULL,
    \\    primary_type TEXT,
    \\    first_release_year INTEGER,
    \\    credited_with TEXT,
    \\    position INTEGER NOT NULL,
    \\    PRIMARY KEY (artist_id, mbid)
    \\);
    \\
;

const migration_43 =
    \\CREATE INDEX locations_held ON locations(file_id, state) WHERE state <> 'missing';
    \\
;

const migration_44 =
    \\CREATE TABLE release_group_covers (
    \\    mbid TEXT PRIMARY KEY,
    \\    image BLOB,
    \\    mime TEXT,
    \\    fetched_at INTEGER NOT NULL,
    \\    CHECK ((image IS NULL) = (mime IS NULL))
    \\);
    \\CREATE INDEX artist_release_groups_mbid ON artist_release_groups(mbid);
    \\CREATE TRIGGER artist_release_groups_cover_ad AFTER DELETE ON artist_release_groups
    \\WHEN NOT EXISTS (SELECT 1 FROM artist_release_groups WHERE mbid = old.mbid)
    \\BEGIN
    \\    DELETE FROM release_group_covers WHERE mbid = old.mbid;
    \\END;
    \\
;

const migration_45 =
    \\CREATE TABLE folder_images (
    \\    id INTEGER PRIMARY KEY,
    \\    volume_id INTEGER NOT NULL REFERENCES volumes(id),
    \\    root_id INTEGER REFERENCES library_roots(id) ON DELETE CASCADE,
    \\    uri TEXT NOT NULL,
    \\    mime TEXT NOT NULL,
    \\    role INTEGER NOT NULL CHECK (role BETWEEN 0 AND 3),
    \\    size_bytes INTEGER NOT NULL,
    \\    modified_ns INTEGER NOT NULL,
    \\    last_seen_generation INTEGER NOT NULL DEFAULT 0,
    \\    UNIQUE(volume_id, uri)
    \\);
    \\CREATE INDEX folder_images_sweep ON folder_images(root_id, last_seen_generation);
    \\CREATE INDEX folder_images_folder ON folder_images(volume_id, rtrim(uri, replace(uri, '/', '')), uri);
    \\CREATE TABLE folder_scans (
    \\    root_id INTEGER NOT NULL REFERENCES library_roots(id) ON DELETE CASCADE,
    \\    relative_path TEXT NOT NULL,
    \\    scanned_at INTEGER NOT NULL,
    \\    PRIMARY KEY (root_id, relative_path)
    \\) WITHOUT ROWID;
    \\
;

const migration_46 =
    \\ALTER TABLE releases ADD COLUMN has_folder_cover INTEGER NOT NULL DEFAULT 0;
    \\UPDATE releases SET has_folder_cover = 1 WHERE EXISTS (
    \\    SELECT 1 FROM folder_images AS cover_image WHERE cover_image.role = 0
    \\      AND (cover_image.volume_id, rtrim(cover_image.uri, replace(cover_image.uri, '/', ''))) = (
    \\        SELECT cover_location.volume_id, rtrim(cover_location.uri, replace(cover_location.uri, '/', ''))
    \\        FROM tracks AS cover_track
    \\        JOIN locations AS cover_location ON cover_location.file_id = cover_track.preferred_file_id
    \\        WHERE cover_track.release_id = releases.id AND cover_location.state <> 'missing'
    \\        GROUP BY 1, 2 ORDER BY count(DISTINCT cover_track.id) DESC, 2 LIMIT 1));
    \\
;

const migration_47 =
    \\CREATE TABLE job_history (
    \\    id INTEGER PRIMARY KEY,
    \\    kind TEXT NOT NULL,
    \\    request TEXT,
    \\    started_at INTEGER NOT NULL,
    \\    finished_at INTEGER NOT NULL,
    \\    state TEXT NOT NULL,
    \\    completed_units INTEGER NOT NULL,
    \\    total_units INTEGER,
    \\    error TEXT,
    \\    undo_group_id INTEGER,
    \\    retryable INTEGER NOT NULL DEFAULT 0,
    \\    summary TEXT NOT NULL DEFAULT ''
    \\);
    \\CREATE INDEX job_history_finished ON job_history(finished_at, id);
    \\
;

const migration_48 =
    \\ALTER TABLE listens ADD COLUMN syncable INTEGER NOT NULL DEFAULT 1;
    \\
;

const migration_49 =
    \\ALTER TABLE library_health_issues ADD COLUMN similarity REAL;
    \\
;

const migration_50 =
    \\ALTER TABLE observed_file_tags ADD COLUMN comment TEXT;
    \\UPDATE locations SET modified_ns = -1 WHERE state = 'present';
    \\
;

/// Until version 51 only the Cover Art Archive fetch wrote `release_artwork`,
/// so every row it holds is a fetched front cover (kind 0, source 2). Images
/// observed before it have no measurement; the property backfill measures the
/// rows the two partial indexes select, so no rescan is forced.
const migration_51 =
    \\CREATE TABLE release_artwork_v51 (
    \\    release_id INTEGER NOT NULL REFERENCES releases(id) ON DELETE CASCADE,
    \\    kind INTEGER NOT NULL DEFAULT 0 CHECK (kind BETWEEN 0 AND 2),
    \\    source INTEGER NOT NULL DEFAULT 2 CHECK (source BETWEEN 0 AND 3),
    \\    musicbrainz_release_id TEXT,
    \\    image BLOB,
    \\    mime TEXT,
    \\    width INTEGER,
    \\    height INTEGER,
    \\    fetched_at INTEGER NOT NULL,
    \\    PRIMARY KEY (release_id, kind)
    \\);
    \\INSERT INTO release_artwork_v51(release_id, kind, source, musicbrainz_release_id, image, mime, fetched_at)
    \\SELECT release_id, 0, 2, musicbrainz_release_id, image, mime, fetched_at FROM release_artwork;
    \\DROP TABLE release_artwork;
    \\ALTER TABLE release_artwork_v51 RENAME TO release_artwork;
    \\CREATE TABLE cover_art_candidates (
    \\    release_id INTEGER NOT NULL REFERENCES releases(id) ON DELETE CASCADE,
    \\    caa_id INTEGER NOT NULL,
    \\    musicbrainz_release_id TEXT NOT NULL,
    \\    kind INTEGER NOT NULL CHECK (kind BETWEEN 0 AND 4),
    \\    width INTEGER,
    \\    height INTEGER,
    \\    mime TEXT,
    \\    approved INTEGER NOT NULL DEFAULT 0 CHECK (approved IN (0, 1)),
    \\    thumbnail BLOB,
    \\    fetched_at INTEGER NOT NULL,
    \\    PRIMARY KEY (release_id, caa_id)
    \\);
    \\ALTER TABLE observed_file_tags ADD COLUMN artwork_width INTEGER;
    \\ALTER TABLE observed_file_tags ADD COLUMN artwork_height INTEGER;
    \\ALTER TABLE observed_file_tags ADD COLUMN artwork_hash INTEGER;
    \\CREATE INDEX observed_file_tags_artwork_unmeasured ON observed_file_tags(file_id)
    \\    WHERE artwork_byte_size > 0 AND artwork_hash IS NULL;
    \\ALTER TABLE folder_images ADD COLUMN width INTEGER;
    \\ALTER TABLE folder_images ADD COLUMN height INTEGER;
    \\ALTER TABLE folder_images ADD COLUMN hash INTEGER;
    \\CREATE INDEX folder_images_unmeasured ON folder_images(id) WHERE hash IS NULL;
    \\CREATE INDEX release_artwork_unmeasured ON release_artwork(release_id, kind)
    \\    WHERE image IS NOT NULL AND width IS NULL;
    \\
;

/// A MusicBrainz release the user said a Release is not ("Not This
/// Release"), so it is never its best candidate again.
const migration_52 =
    \\CREATE TABLE dismissed_release_candidates (
    \\    release_id INTEGER NOT NULL REFERENCES releases(id) ON DELETE CASCADE,
    \\    musicbrainz_release_id TEXT NOT NULL,
    \\    dismissed_at INTEGER NOT NULL,
    \\    PRIMARY KEY (release_id, musicbrainz_release_id)
    \\) WITHOUT ROWID;
    \\CREATE INDEX releases_match_order ON releases(album_artist COLLATE NOCASE, title COLLATE NOCASE);
    \\
;

/// The queue and position a Player resumes from, and where long Tracks were
/// left. Queue entries name a Track and its Recording, with no foreign key: a
/// restore resolves a Track that is gone through its Recording, or skips it.
const migration_53 =
    \\CREATE TABLE player_state (
    \\    id INTEGER PRIMARY KEY CHECK (id = 1),
    \\    cursor INTEGER NOT NULL CHECK (cursor >= 0),
    \\    position_ms INTEGER NOT NULL CHECK (position_ms >= 0),
    \\    repeat INTEGER NOT NULL CHECK (repeat BETWEEN 0 AND 2),
    \\    shuffle INTEGER NOT NULL CHECK (shuffle IN (0, 1)),
    \\    saved_at INTEGER NOT NULL
    \\);
    \\CREATE TABLE player_queue_entries (
    \\    position INTEGER PRIMARY KEY CHECK (position BETWEEN 0 AND 9999),
    \\    entry INTEGER NOT NULL CHECK (entry BETWEEN 0 AND 9999),
    \\    track_id INTEGER NOT NULL,
    \\    recording_id INTEGER
    \\);
    \\CREATE TABLE track_positions (
    \\    track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
    \\    position_ms INTEGER NOT NULL CHECK (position_ms > 0),
    \\    updated_at INTEGER NOT NULL
    \\);
    \\
;

const migration_54 =
    \\CREATE TABLE metadata_proposals (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    group_id INTEGER,
    \\    release_id INTEGER NOT NULL REFERENCES releases(id) ON DELETE CASCADE,
    \\    category INTEGER NOT NULL CHECK (category BETWEEN 0 AND 4),
    \\    field TEXT NOT NULL,
    \\    track_id INTEGER REFERENCES tracks(id) ON DELETE CASCADE,
    \\    current TEXT,
    \\    proposed TEXT,
    \\    reason TEXT,
    \\    option INTEGER CHECK (option IS NULL OR option >= 0),
    \\    state INTEGER NOT NULL DEFAULT 0 CHECK (state BETWEEN 0 AND 2),
    \\    fingerprint INTEGER NOT NULL,
    \\    created_at INTEGER NOT NULL
    \\);
    \\CREATE INDEX metadata_proposals_groups ON metadata_proposals(state, category, release_id, id)
    \\    WHERE id = group_id;
    \\CREATE INDEX metadata_proposals_members ON metadata_proposals(group_id, option, id);
    \\CREATE INDEX metadata_proposals_release ON metadata_proposals(release_id, state);
    \\CREATE INDEX metadata_proposals_track ON metadata_proposals(track_id) WHERE track_id IS NOT NULL;
    \\
;

const migration_55 =
    \\ALTER TABLE metadata_proposals ADD COLUMN tracks INTEGER CHECK (tracks IS NULL OR tracks >= 0);
    \\ALTER TABLE metadata_proposals ADD COLUMN gap INTEGER CHECK (gap IS NULL OR gap > 0);
    \\
;

const migration_56 =
    \\ALTER TABLE mutation_operations ADD COLUMN expected_content_hash BLOB;
    \\ALTER TABLE mutation_operations ADD COLUMN committed_content_hash BLOB;
    \\ALTER TABLE files ADD COLUMN content_hash_algorithm SMALLINT;
    \\CREATE INDEX files_content_hash ON files(content_hash);
    \\
;

const migration_57 =
    \\UPDATE files SET audio_hash = NULL WHERE audio_hash IS NOT NULL;
    \\ALTER TABLE files ADD COLUMN audio_hash_tier INTEGER CHECK (audio_hash_tier IN (1, 2));
    \\
;

const migration_58 =
    \\CREATE TABLE musicbrainz_releases (
    \\    musicbrainz_release_id TEXT PRIMARY KEY NOT NULL,
    \\    title TEXT NOT NULL,
    \\    artist_credit TEXT NOT NULL,
    \\    release_date TEXT,
    \\    release_group_id TEXT,
    \\    medium_count INTEGER NOT NULL CHECK (medium_count >= 0),
    \\    track_count INTEGER NOT NULL CHECK (track_count >= 0),
    \\    fetched_at INTEGER NOT NULL
    \\) WITHOUT ROWID;
    \\CREATE TABLE musicbrainz_release_tracks (
    \\    musicbrainz_release_id TEXT NOT NULL
    \\        REFERENCES musicbrainz_releases(musicbrainz_release_id) ON DELETE CASCADE,
    \\    disc INTEGER NOT NULL CHECK (disc >= 1),
    \\    position INTEGER NOT NULL CHECK (position >= 1),
    \\    title TEXT NOT NULL,
    \\    artist_credit TEXT NOT NULL,
    \\    length_ms INTEGER CHECK (length_ms IS NULL OR length_ms >= 0),
    \\    recording_id TEXT NOT NULL,
    \\    release_track_id TEXT NOT NULL,
    \\    PRIMARY KEY (musicbrainz_release_id, disc, position)
    \\) WITHOUT ROWID;
    \\
;

fn diagnosticsKey(comptime keyword: []const u8, comptime row: []const u8) []const u8 {
    return keyword ++ " " ++ row ++ ".kind = 1 AND " ++ row ++ ".algorithm_id = 'orca.audio-diagnostics'\n" ++
        "  AND " ++ row ++ ".algorithm_version = 4\n" ++
        "  AND " ++ row ++ ".parameter_hash = X'A5D7A479D64C3952CA86E311AFFEBB0CFCA41DAF406C7AA159255961CF9145CE'\n";
}

const loudness_replace =
    \\BEGIN
    \\    DELETE FROM file_loudness WHERE file_id = new.file_id;
    \\    INSERT INTO file_loudness(file_id, source_identity, integrated_lufs)
    \\
++ loudnessRows("(SELECT new.file_id AS file_id, new.source_identity AS source_identity, new.result AS result)") ++
    \\;
    \\END;
    \\
;

fn loudnessRows(comptime source: []const u8) []const u8 {
    return "SELECT file_id, source_identity,\n" ++
        "       CASE WHEN (bits & 2147483647) = 0 THEN 0.0\n" ++
        "            ELSE (CASE WHEN (bits >> 31) = 1 THEN -1.0 ELSE 1.0 END)\n" ++
        "                 * (1.0 + (bits & 8388607) / 8388608.0)\n" ++
        "                 * (CASE WHEN ((bits >> 23) & 255) >= 127 THEN (1 << (((bits >> 23) & 255) - 127))\n" ++
        "                         ELSE 1.0 / (1 << (127 - ((bits >> 23) & 255))) END)\n" ++
        "       END\n" ++
        "FROM (SELECT file_id, source_identity,\n" ++
        "           ((instr('0123456789ABCDEF', substr(digits, 1, 1)) - 1) << 4) + (instr('0123456789ABCDEF', substr(digits, 2, 1)) - 1) +\n" ++
        "           ((instr('0123456789ABCDEF', substr(digits, 3, 1)) - 1) << 12) + ((instr('0123456789ABCDEF', substr(digits, 4, 1)) - 1) << 8) +\n" ++
        "           ((instr('0123456789ABCDEF', substr(digits, 5, 1)) - 1) << 20) + ((instr('0123456789ABCDEF', substr(digits, 6, 1)) - 1) << 16) +\n" ++
        "           ((instr('0123456789ABCDEF', substr(digits, 7, 1)) - 1) << 28) + ((instr('0123456789ABCDEF', substr(digits, 8, 1)) - 1) << 24) AS bits\n" ++
        "      FROM (SELECT file_id, source_identity, hex(substr(result, 9, 4)) AS digits\n" ++
        "            FROM " ++ source ++ "\n" ++
        "            WHERE length(result) >= 72 AND substr(result, 1, 6) = X'4F5241440200'\n" ++
        "              AND instr('13579BDF', substr(hex(substr(result, 7, 1)), 2, 1)) > 0))\n" ++
        "WHERE (bits & 2147483647) = 0 OR ((bits >> 23) & 255) BETWEEN 65 AND 189";
}

const genre_totals_schema =
    \\CREATE TABLE genre_totals (
    \\    genre_id INTEGER PRIMARY KEY,
    \\    track_count INTEGER NOT NULL,
    \\    release_count INTEGER NOT NULL,
    \\    artist_count INTEGER NOT NULL,
    \\    duration_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE genre_release_tracks (
    \\    release_id INTEGER NOT NULL,
    \\    genre_id INTEGER NOT NULL,
    \\    tracks INTEGER NOT NULL,
    \\    PRIMARY KEY(release_id, genre_id)
    \\) WITHOUT ROWID;
    \\CREATE TABLE genre_artist_refs (
    \\    genre_id INTEGER NOT NULL,
    \\    artist_id INTEGER NOT NULL,
    \\    refs INTEGER NOT NULL,
    \\    PRIMARY KEY(genre_id, artist_id)
    \\) WITHOUT ROWID;
    \\INSERT INTO genre_release_tracks(release_id, genre_id, tracks)
    \\    SELECT tracks.release_id, track_genres.genre_id, count(*)
    \\    FROM track_genres CROSS JOIN tracks ON tracks.id = track_genres.track_id
    \\    WHERE tracks.release_id IS NOT NULL
    \\    GROUP BY tracks.release_id, track_genres.genre_id;
    \\INSERT INTO genre_artist_refs(genre_id, artist_id, refs)
    \\    SELECT genre_id, artist_id, count(*) FROM (
    \\        SELECT track_genres.genre_id AS genre_id, tracks.artist_id AS artist_id
    \\        FROM track_genres CROSS JOIN tracks ON tracks.id = track_genres.track_id
    \\        WHERE tracks.artist_id IS NOT NULL
    \\        UNION ALL
    \\        SELECT track_genres.genre_id, releases.album_artist_id
    \\        FROM track_genres CROSS JOIN tracks ON tracks.id = track_genres.track_id
    \\        CROSS JOIN releases ON releases.id = tracks.release_id
    \\        WHERE releases.album_artist_id IS NOT NULL)
    \\    GROUP BY genre_id, artist_id;
    \\INSERT INTO genre_totals(genre_id, track_count, release_count, artist_count, duration_ms)
    \\    SELECT track_genres.genre_id, count(*),
    \\        (SELECT count(*) FROM genre_release_tracks WHERE genre_release_tracks.genre_id = track_genres.genre_id),
    \\        (SELECT count(*) FROM genre_artist_refs WHERE genre_artist_refs.genre_id = track_genres.genre_id),
    \\        COALESCE(sum(tracks.duration_ms), 0)
    \\    FROM track_genres CROSS JOIN tracks ON tracks.id = track_genres.track_id
    \\    GROUP BY track_genres.genre_id;
    \\CREATE TRIGGER genre_totals_au AFTER UPDATE OF track_count ON genre_totals
    \\WHEN new.track_count = 0 BEGIN
    \\    DELETE FROM genre_totals WHERE genre_id = new.genre_id;
    \\END;
    \\CREATE TRIGGER genre_release_tracks_ai AFTER INSERT ON genre_release_tracks BEGIN
    \\    UPDATE genre_totals SET release_count = release_count + 1 WHERE genre_id = new.genre_id;
    \\END;
    \\CREATE TRIGGER genre_release_tracks_au AFTER UPDATE OF tracks ON genre_release_tracks
    \\WHEN new.tracks = 0 BEGIN
    \\    DELETE FROM genre_release_tracks WHERE release_id = new.release_id AND genre_id = new.genre_id;
    \\END;
    \\CREATE TRIGGER genre_release_tracks_ad AFTER DELETE ON genre_release_tracks BEGIN
    \\    UPDATE genre_totals SET release_count = release_count - 1 WHERE genre_id = old.genre_id;
    \\END;
    \\CREATE TRIGGER genre_artist_refs_ai AFTER INSERT ON genre_artist_refs BEGIN
    \\    UPDATE genre_totals SET artist_count = artist_count + 1 WHERE genre_id = new.genre_id;
    \\END;
    \\CREATE TRIGGER genre_artist_refs_au AFTER UPDATE OF refs ON genre_artist_refs
    \\WHEN new.refs = 0 BEGIN
    \\    DELETE FROM genre_artist_refs WHERE genre_id = new.genre_id AND artist_id = new.artist_id;
    \\END;
    \\CREATE TRIGGER genre_artist_refs_ad AFTER DELETE ON genre_artist_refs BEGIN
    \\    UPDATE genre_totals SET artist_count = artist_count - 1 WHERE genre_id = old.genre_id;
    \\END;
    \\CREATE TRIGGER track_genres_totals_ai AFTER INSERT ON track_genres BEGIN
    \\
++ addTrackGenre("new") ++
    \\END;
    \\CREATE TRIGGER track_genres_totals_ad AFTER DELETE ON track_genres BEGIN
    \\
++ removeTrackGenre("old") ++
    \\END;
    \\CREATE TRIGGER track_genres_totals_au AFTER UPDATE OF track_id, genre_id ON track_genres
    \\WHEN old.track_id IS NOT new.track_id OR old.genre_id IS NOT new.genre_id BEGIN
    \\
++ removeTrackGenre("old") ++ addTrackGenre("new") ++
    \\END;
    \\CREATE TRIGGER tracks_genre_totals_bd BEFORE DELETE ON tracks BEGIN
    \\    DELETE FROM track_genres WHERE track_id = old.id;
    \\END;
    \\CREATE TRIGGER tracks_genre_duration_au AFTER UPDATE OF duration_ms ON tracks
    \\WHEN old.duration_ms IS NOT new.duration_ms BEGIN
    \\    UPDATE genre_totals SET duration_ms = duration_ms - COALESCE(old.duration_ms, 0) + COALESCE(new.duration_ms, 0)
    \\    WHERE genre_id IN (SELECT genre_id FROM track_genres WHERE track_id = new.id);
    \\END;
    \\CREATE TRIGGER tracks_genre_artist_au AFTER UPDATE OF artist_id ON tracks
    \\WHEN old.artist_id IS NOT new.artist_id BEGIN
    \\    UPDATE genre_artist_refs SET refs = refs - 1
    \\    WHERE artist_id = old.artist_id AND genre_id IN (SELECT genre_id FROM track_genres WHERE track_id = new.id);
    \\    INSERT INTO genre_artist_refs(genre_id, artist_id, refs)
    \\    SELECT genre_id, new.artist_id, 1 FROM track_genres WHERE track_id = new.id AND new.artist_id IS NOT NULL
    \\    ON CONFLICT DO UPDATE SET refs = refs + 1;
    \\END;
    \\CREATE TRIGGER tracks_genre_release_au AFTER UPDATE OF release_id ON tracks
    \\WHEN old.release_id IS NOT new.release_id BEGIN
    \\    UPDATE genre_release_tracks SET tracks = tracks - 1
    \\    WHERE release_id = old.release_id AND genre_id IN (SELECT genre_id FROM track_genres WHERE track_id = new.id);
    \\    UPDATE genre_artist_refs SET refs = refs - 1
    \\    WHERE artist_id = (SELECT album_artist_id FROM releases WHERE id = old.release_id)
    \\        AND genre_id IN (SELECT genre_id FROM track_genres WHERE track_id = new.id);
    \\    INSERT INTO genre_release_tracks(release_id, genre_id, tracks)
    \\    SELECT new.release_id, genre_id, 1 FROM track_genres WHERE track_id = new.id AND new.release_id IS NOT NULL
    \\    ON CONFLICT DO UPDATE SET tracks = tracks + 1;
    \\    INSERT INTO genre_artist_refs(genre_id, artist_id, refs)
    \\    SELECT track_genres.genre_id, releases.album_artist_id, 1
    \\    FROM track_genres CROSS JOIN releases ON releases.id = new.release_id
    \\    WHERE track_genres.track_id = new.id AND releases.album_artist_id IS NOT NULL
    \\    ON CONFLICT DO UPDATE SET refs = refs + 1;
    \\END;
    \\CREATE TRIGGER releases_genre_artist_au AFTER UPDATE OF album_artist_id ON releases
    \\WHEN old.album_artist_id IS NOT new.album_artist_id BEGIN
    \\    UPDATE genre_artist_refs SET refs = refs - (SELECT tracks FROM genre_release_tracks
    \\        WHERE genre_release_tracks.release_id = new.id AND genre_release_tracks.genre_id = genre_artist_refs.genre_id)
    \\    WHERE artist_id = old.album_artist_id
    \\        AND genre_id IN (SELECT genre_id FROM genre_release_tracks WHERE release_id = new.id);
    \\    INSERT INTO genre_artist_refs(genre_id, artist_id, refs)
    \\    SELECT genre_id, new.album_artist_id, tracks FROM genre_release_tracks
    \\    WHERE release_id = new.id AND new.album_artist_id IS NOT NULL
    \\    ON CONFLICT DO UPDATE SET refs = refs + excluded.refs;
    \\END;
    \\
;

fn addTrackGenre(comptime row: []const u8) []const u8 {
    return "    INSERT INTO genre_totals(genre_id, track_count, release_count, artist_count, duration_ms)\n" ++
        "    VALUES (" ++ row ++ ".genre_id, 1, 0, 0, COALESCE((SELECT duration_ms FROM tracks WHERE id = " ++ row ++ ".track_id), 0))\n" ++
        "    ON CONFLICT(genre_id) DO UPDATE SET track_count = track_count + 1, duration_ms = duration_ms + excluded.duration_ms;\n" ++
        "    INSERT INTO genre_release_tracks(release_id, genre_id, tracks)\n" ++
        "    SELECT release_id, " ++ row ++ ".genre_id, 1 FROM tracks WHERE id = " ++ row ++ ".track_id AND release_id IS NOT NULL\n" ++
        "    ON CONFLICT DO UPDATE SET tracks = tracks + 1;\n" ++
        "    INSERT INTO genre_artist_refs(genre_id, artist_id, refs)\n" ++
        "    SELECT " ++ row ++ ".genre_id, artist_id, 1 FROM tracks WHERE id = " ++ row ++ ".track_id AND artist_id IS NOT NULL\n" ++
        "    ON CONFLICT DO UPDATE SET refs = refs + 1;\n" ++
        "    INSERT INTO genre_artist_refs(genre_id, artist_id, refs)\n" ++
        "    SELECT " ++ row ++ ".genre_id, releases.album_artist_id, 1\n" ++
        "    FROM tracks CROSS JOIN releases ON releases.id = tracks.release_id\n" ++
        "    WHERE tracks.id = " ++ row ++ ".track_id AND releases.album_artist_id IS NOT NULL\n" ++
        "    ON CONFLICT DO UPDATE SET refs = refs + 1;\n";
}

fn removeTrackGenre(comptime row: []const u8) []const u8 {
    return "    UPDATE genre_release_tracks SET tracks = tracks - 1\n" ++
        "    WHERE genre_id = " ++ row ++ ".genre_id AND release_id = (SELECT release_id FROM tracks WHERE id = " ++ row ++ ".track_id);\n" ++
        "    UPDATE genre_artist_refs SET refs = refs - 1\n" ++
        "    WHERE genre_id = " ++ row ++ ".genre_id AND artist_id = (SELECT artist_id FROM tracks WHERE id = " ++ row ++ ".track_id);\n" ++
        "    UPDATE genre_artist_refs SET refs = refs - 1\n" ++
        "    WHERE genre_id = " ++ row ++ ".genre_id AND artist_id = (SELECT releases.album_artist_id\n" ++
        "        FROM tracks CROSS JOIN releases ON releases.id = tracks.release_id WHERE tracks.id = " ++ row ++ ".track_id);\n" ++
        "    UPDATE genre_totals SET track_count = track_count - 1,\n" ++
        "        duration_ms = duration_ms - COALESCE((SELECT duration_ms FROM tracks WHERE id = " ++ row ++ ".track_id), 0)\n" ++
        "    WHERE genre_id = " ++ row ++ ".genre_id;\n";
}

pub const genre_totals_drift_sql =
    \\WITH fresh_releases(release_id, genre_id, tracks) AS (
    \\    SELECT tracks.release_id, track_genres.genre_id, count(*)
    \\    FROM track_genres JOIN tracks ON tracks.id = track_genres.track_id
    \\    WHERE tracks.release_id IS NOT NULL GROUP BY 1, 2
    \\), fresh_artists(genre_id, artist_id, refs) AS (
    \\    SELECT genre_id, artist_id, count(*) FROM (
    \\        SELECT track_genres.genre_id AS genre_id, tracks.artist_id AS artist_id
    \\        FROM track_genres JOIN tracks ON tracks.id = track_genres.track_id WHERE tracks.artist_id IS NOT NULL
    \\        UNION ALL SELECT track_genres.genre_id, releases.album_artist_id
    \\        FROM track_genres JOIN tracks ON tracks.id = track_genres.track_id
    \\        JOIN releases ON releases.id = tracks.release_id WHERE releases.album_artist_id IS NOT NULL)
    \\    GROUP BY 1, 2
    \\), fresh_totals(genre_id, track_count, release_count, artist_count, duration_ms) AS (
    \\    SELECT track_genres.genre_id, count(*), count(DISTINCT tracks.release_id),
    \\        (SELECT count(DISTINCT artist_id) FROM (
    \\            SELECT tracks.artist_id AS artist_id FROM track_genres AS inner_genres
    \\            JOIN tracks ON tracks.id = inner_genres.track_id WHERE inner_genres.genre_id = track_genres.genre_id
    \\            UNION SELECT releases.album_artist_id FROM track_genres AS inner_genres
    \\            JOIN tracks ON tracks.id = inner_genres.track_id JOIN releases ON releases.id = tracks.release_id
    \\            WHERE inner_genres.genre_id = track_genres.genre_id)),
    \\        COALESCE(sum(tracks.duration_ms), 0)
    \\    FROM track_genres JOIN tracks ON tracks.id = track_genres.track_id
    \\    GROUP BY track_genres.genre_id
    \\)
    \\SELECT (SELECT count(*) FROM (SELECT * FROM genre_totals EXCEPT SELECT * FROM fresh_totals))
    \\     + (SELECT count(*) FROM (SELECT * FROM fresh_totals EXCEPT SELECT * FROM genre_totals))
    \\     + (SELECT count(*) FROM (SELECT * FROM genre_release_tracks EXCEPT SELECT * FROM fresh_releases))
    \\     + (SELECT count(*) FROM (SELECT * FROM fresh_releases EXCEPT SELECT * FROM genre_release_tracks))
    \\     + (SELECT count(*) FROM (SELECT * FROM genre_artist_refs EXCEPT SELECT * FROM fresh_artists))
    \\     + (SELECT count(*) FROM (SELECT * FROM fresh_artists EXCEPT SELECT * FROM genre_artist_refs));
;

const migration_36 =
    \\CREATE VIRTUAL TABLE search_index USING fts5(
    \\    kind UNINDEXED, entity_id UNINDEXED, title, subtitle,
    \\    tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3'
    \\);
    \\INSERT INTO search_index(rowid, kind, entity_id, title, subtitle)
    \\    SELECT id * 8 + 0, 0, id, name, '' FROM artists;
    \\INSERT INTO search_index(rowid, kind, entity_id, title, subtitle)
    \\    SELECT id * 8 + 1, 1, id, title, album_artist FROM releases;
    \\INSERT INTO search_index(rowid, kind, entity_id, title, subtitle)
    \\    SELECT id * 8 + 2, 2, id, title, artist || ' ' || album FROM tracks;
    \\INSERT INTO search_index(rowid, kind, entity_id, title, subtitle)
    \\    SELECT id * 8 + 3, 3, id, name, description FROM playlists;
    \\INSERT INTO search_index(rowid, kind, entity_id, title, subtitle)
    \\    SELECT id * 8 + 4, 4, id, name, '' FROM genres;
    \\CREATE TRIGGER artists_search_ai AFTER INSERT ON artists BEGIN
    \\    INSERT OR REPLACE INTO search_index(rowid, kind, entity_id, title, subtitle)
    \\    VALUES (new.id * 8 + 0, 0, new.id, new.name, '');
    \\END;
    \\CREATE TRIGGER artists_search_au AFTER UPDATE OF id, name ON artists
    \\WHEN old.id IS NOT new.id OR old.name IS NOT new.name BEGIN
    \\    DELETE FROM search_index WHERE rowid = old.id * 8 + 0;
    \\    INSERT OR REPLACE INTO search_index(rowid, kind, entity_id, title, subtitle)
    \\    VALUES (new.id * 8 + 0, 0, new.id, new.name, '');
    \\END;
    \\CREATE TRIGGER artists_search_ad AFTER DELETE ON artists BEGIN
    \\    DELETE FROM search_index WHERE rowid = old.id * 8 + 0;
    \\END;
    \\CREATE TRIGGER releases_search_ai AFTER INSERT ON releases BEGIN
    \\    INSERT OR REPLACE INTO search_index(rowid, kind, entity_id, title, subtitle)
    \\    VALUES (new.id * 8 + 1, 1, new.id, new.title, new.album_artist);
    \\END;
    \\CREATE TRIGGER releases_search_au AFTER UPDATE OF id, title, album_artist ON releases
    \\WHEN old.id IS NOT new.id OR old.title IS NOT new.title OR old.album_artist IS NOT new.album_artist BEGIN
    \\    DELETE FROM search_index WHERE rowid = old.id * 8 + 1;
    \\    INSERT OR REPLACE INTO search_index(rowid, kind, entity_id, title, subtitle)
    \\    VALUES (new.id * 8 + 1, 1, new.id, new.title, new.album_artist);
    \\END;
    \\CREATE TRIGGER releases_search_ad AFTER DELETE ON releases BEGIN
    \\    DELETE FROM search_index WHERE rowid = old.id * 8 + 1;
    \\END;
    \\CREATE TRIGGER tracks_search_ai AFTER INSERT ON tracks BEGIN
    \\    INSERT OR REPLACE INTO search_index(rowid, kind, entity_id, title, subtitle)
    \\    VALUES (new.id * 8 + 2, 2, new.id, new.title, new.artist || ' ' || new.album);
    \\END;
    \\CREATE TRIGGER tracks_search_au AFTER UPDATE OF id, title, artist, album ON tracks
    \\WHEN old.id IS NOT new.id OR old.title IS NOT new.title OR old.artist IS NOT new.artist OR old.album IS NOT new.album BEGIN
    \\    DELETE FROM search_index WHERE rowid = old.id * 8 + 2;
    \\    INSERT OR REPLACE INTO search_index(rowid, kind, entity_id, title, subtitle)
    \\    VALUES (new.id * 8 + 2, 2, new.id, new.title, new.artist || ' ' || new.album);
    \\END;
    \\CREATE TRIGGER tracks_search_ad AFTER DELETE ON tracks BEGIN
    \\    DELETE FROM search_index WHERE rowid = old.id * 8 + 2;
    \\END;
    \\CREATE TRIGGER playlists_search_ai AFTER INSERT ON playlists BEGIN
    \\    INSERT OR REPLACE INTO search_index(rowid, kind, entity_id, title, subtitle)
    \\    VALUES (new.id * 8 + 3, 3, new.id, new.name, new.description);
    \\END;
    \\CREATE TRIGGER playlists_search_au AFTER UPDATE OF id, name, description ON playlists
    \\WHEN old.id IS NOT new.id OR old.name IS NOT new.name OR old.description IS NOT new.description BEGIN
    \\    DELETE FROM search_index WHERE rowid = old.id * 8 + 3;
    \\    INSERT OR REPLACE INTO search_index(rowid, kind, entity_id, title, subtitle)
    \\    VALUES (new.id * 8 + 3, 3, new.id, new.name, new.description);
    \\END;
    \\CREATE TRIGGER playlists_search_ad AFTER DELETE ON playlists BEGIN
    \\    DELETE FROM search_index WHERE rowid = old.id * 8 + 3;
    \\END;
    \\CREATE TRIGGER genres_search_ai AFTER INSERT ON genres BEGIN
    \\    INSERT OR REPLACE INTO search_index(rowid, kind, entity_id, title, subtitle)
    \\    VALUES (new.id * 8 + 4, 4, new.id, new.name, '');
    \\END;
    \\CREATE TRIGGER genres_search_au AFTER UPDATE OF id, name ON genres
    \\WHEN old.id IS NOT new.id OR old.name IS NOT new.name BEGIN
    \\    DELETE FROM search_index WHERE rowid = old.id * 8 + 4;
    \\    INSERT OR REPLACE INTO search_index(rowid, kind, entity_id, title, subtitle)
    \\    VALUES (new.id * 8 + 4, 4, new.id, new.name, '');
    \\END;
    \\CREATE TRIGGER genres_search_ad AFTER DELETE ON genres BEGIN
    \\    DELETE FROM search_index WHERE rowid = old.id * 8 + 4;
    \\END;
;

/// How much stack the key functions fold a name in.
///
/// The folding never grows its input — fullwidth forms shrink, case folding is
/// length-preserving — so this bounds the longest artist name the backfill can
/// see. Overflow raises a SQL error and rolls the migration back rather than
/// silently writing a truncated key, because a truncated key is an artist who
/// exists twice.
const key_scratch_bytes = 8 * 1024;

fn foldInto(
    context: ?*sqlite.c.sqlite3_context,
    argc: c_int,
    argv: [*c]?*sqlite.c.sqlite3_value,
    comptime fold: fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error![]const u8,
) void {
    if (argc != 1) return sqlite.resultError(context, "expected one argument");
    var buffer: [key_scratch_bytes]u8 = undefined;
    var scratch: std.heap.FixedBufferAllocator = .init(&buffer);
    const folded = fold(scratch.allocator(), sqlite.valueText(argv[0])) catch
        return sqlite.resultError(context, "artist name too long to fold");
    sqlite.resultText(context, folded);
}

fn artistKeyFunction(
    context: ?*sqlite.c.sqlite3_context,
    argc: c_int,
    argv: [*c]?*sqlite.c.sqlite3_value,
) callconv(.c) void {
    foldInto(context, argc, argv, text_key.normalizeKey);
}

fn artistSortKeyFunction(
    context: ?*sqlite.c.sqlite3_context,
    argc: c_int,
    argv: [*c]?*sqlite.c.sqlite3_value,
) callconv(.c) void {
    foldInto(context, argc, argv, text_key.sortKey);
}

/// Re-folds a stored `release_key`, and *only the parts of it that were ever
/// folded*.
///
/// `library/projection.zig` composes the key as
/// `normalizeKey(album) 0x1f normalizeKey(album_artist) 0x1f (mbid | year)`,
/// and appends `0x1f folder.path` **raw** when the album has no title. So the
/// first two segments are folded and the rest are not.
///
/// Folding the whole string looked equivalent and is not. It lowercases and
/// whitespace-collapses the folder path, so
/// `…^_2001^_/mnt/Media/Music/Loose  Tracks` becomes
/// `…^_2001^_/mnt/media/music/loose tracks`, the next projection composes the
/// original form, `ON CONFLICT(release_key)` matches nothing, and a parallel
/// release appears beside the first -- which is the exact corruption migration
/// 12 exists to repair, reintroduced for every untitled album. It would
/// lowercase an uppercase MusicBrainz id for the same reason.
fn releaseKeyFunction(
    context: ?*sqlite.c.sqlite3_context,
    argc: c_int,
    argv: [*c]?*sqlite.c.sqlite3_value,
) callconv(.c) void {
    if (argc != 1) return sqlite.resultError(context, "expected one argument");
    var buffer: [key_scratch_bytes]u8 = undefined;
    var scratch: std.heap.FixedBufferAllocator = .init(&buffer);
    const allocator = scratch.allocator();

    var out: std.ArrayList(u8) = .empty;
    var remaining = sqlite.valueText(argv[0]);
    var segment: usize = 0;
    while (true) {
        const separator = std.mem.indexOfScalar(u8, remaining, 0x1f);
        const piece = if (separator) |at| remaining[0..at] else remaining;
        if (segment < 2) {
            const folded = text_key.normalizeKey(allocator, piece) catch
                return sqlite.resultError(context, "release key too long to fold");
            out.appendSlice(allocator, folded) catch
                return sqlite.resultError(context, "release key too long to fold");
        } else {
            out.appendSlice(allocator, piece) catch
                return sqlite.resultError(context, "release key too long to fold");
        }
        const at = separator orelse break;
        out.append(allocator, 0x1f) catch
            return sqlite.resultError(context, "release key too long to fold");
        remaining = remaining[at + 1 ..];
        segment += 1;
    }
    sqlite.resultText(context, out.items);
}

fn genreKeyFunction(
    context: ?*sqlite.c.sqlite3_context,
    argc: c_int,
    argv: [*c]?*sqlite.c.sqlite3_value,
) callconv(.c) void {
    foldGenre(context, argc, argv, .key);
}

fn genreNameFunction(
    context: ?*sqlite.c.sqlite3_context,
    argc: c_int,
    argv: [*c]?*sqlite.c.sqlite3_value,
) callconv(.c) void {
    foldGenre(context, argc, argv, .name);
}

fn foldGenre(
    context: ?*sqlite.c.sqlite3_context,
    argc: c_int,
    argv: [*c]?*sqlite.c.sqlite3_value,
    comptime part: enum { key, name },
) void {
    if (argc != 1) return sqlite.resultError(context, "expected one argument");
    var buffer: [key_scratch_bytes]u8 = undefined;
    var scratch: std.heap.FixedBufferAllocator = .init(&buffer);
    const folded = genre_alias.fold(scratch.allocator(), sqlite.valueText(argv[0])) catch
        return sqlite.resultError(context, "genre too long to fold");
    sqlite.resultText(context, switch (part) {
        .key => folded.key,
        .name => folded.name,
    });
}

fn genrePartFunction(
    context: ?*sqlite.c.sqlite3_context,
    argc: c_int,
    argv: [*c]?*sqlite.c.sqlite3_value,
) callconv(.c) void {
    if (argc != 2) return sqlite.resultError(context, "expected two arguments");
    var remaining = sqlite.valueInt64(argv[1]);
    var parts = genre_alias.parts(sqlite.valueText(argv[0]));
    while (parts.next()) |part| : (remaining -= 1) {
        if (remaining == 0) return sqlite.resultText(context, part);
    }
    sqlite.resultNull(context);
}

/// Teach a connection the foldings, so a migration can match the text a
/// projection wrote without reimplementing the fold in SQL.
pub fn registerKeyFunctions(db: sqlite.Database) sqlite.Error!void {
    try db.createTextFunction("orca_artist_key", 1, null, artistKeyFunction);
    try db.createTextFunction("orca_artist_sort_key", 1, null, artistSortKeyFunction);
    try db.createTextFunction("orca_release_key", 1, null, releaseKeyFunction);
    try db.createTextFunction("orca_genre_part", 2, null, genrePartFunction);
    try db.createTextFunction("orca_genre_key", 1, null, genreKeyFunction);
    try db.createTextFunction("orca_genre_name", 1, null, genreNameFunction);
}

/// The schema version at which `mutation_operations` exists. Startup journal
/// recovery runs at exactly this point: the journal must be readable, and no
/// later migration may rewrite tables a nonterminal operation depends on before
/// that operation has reached a terminal state.
pub const journal_ready_version = 5;

pub fn apply(db: sqlite.Database) sqlite.Error!void {
    return applyThrough(db, current_version);
}

pub fn userVersion(db: sqlite.Database) sqlite.Error!i64 {
    var statement = try db.prepare("PRAGMA user_version;");
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    return statement.columnInt64(0);
}

pub fn applyThrough(db: sqlite.Database, target_version: i64) sqlite.Error!void {
    const version = try userVersion(db);
    if (version > current_version) return error.SchemaVersionTooNew;
    if (version >= target_version) return;
    try registerKeyFunctions(db);

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
    if (version < 9 and target_version >= 9) try db.exec(migration_9);
    if (version < 10 and target_version >= 10) try db.exec(migration_10);
    if (version < 11 and target_version >= 11) try db.exec(migration_11);
    if (version < 12 and target_version >= 12) try db.exec(migration_12);
    if (version < 13 and target_version >= 13) try db.exec(migration_13);
    if (version < 14 and target_version >= 14) try db.exec(migration_14);
    if (version < 15 and target_version >= 15) try db.exec(migration_15);
    if (version < 16 and target_version >= 16) try db.exec(migration_16);
    if (version < 17 and target_version >= 17) try db.exec(migration_17);
    if (version < 18 and target_version >= 18) try db.exec(migration_18);
    if (version < 19 and target_version >= 19) try db.exec(migration_19);
    if (version < 20 and target_version >= 20) try db.exec(migration_20);
    if (version < 21 and target_version >= 21) try db.exec(migration_21);
    if (version < 22 and target_version >= 22) try db.exec(migration_22);
    if (version < 23 and target_version >= 23) try db.exec(migration_23);
    if (version < 24 and target_version >= 24) try db.exec(migration_24);
    if (version < 25 and target_version >= 25) try db.exec(migration_25);
    if (version < 26 and target_version >= 26) try db.exec(migration_26);
    if (version < 27 and target_version >= 27) try db.exec(migration_27);
    if (version < 28 and target_version >= 28) try db.exec(migration_28);
    if (version < 29 and target_version >= 29) try db.exec(migration_29);
    if (version < 30 and target_version >= 30) try db.exec(migration_30);
    if (version < 31 and target_version >= 31) try db.exec(migration_31);
    if (version < 32 and target_version >= 32) try db.exec(migration_32);
    if (version < 33 and target_version >= 33) try db.exec(migration_33);
    if (version < 34 and target_version >= 34) try db.exec(migration_34);
    if (version < 35 and target_version >= 35) try db.exec(migration_35);
    if (version < 36 and target_version >= 36) try db.exec(migration_36);
    if (version < 37 and target_version >= 37) try db.exec(migration_37);
    if (version < 38 and target_version >= 38) try db.exec(migration_38);
    if (version < 39 and target_version >= 39) try db.exec(migration_39);
    if (version < 40 and target_version >= 40) try db.exec(migration_40);
    if (version < 41 and target_version >= 41) try db.exec(migration_41);
    if (version < 42 and target_version >= 42) try db.exec(migration_42);
    if (version < 43 and target_version >= 43) try db.exec(migration_43);
    if (version < 44 and target_version >= 44) try db.exec(migration_44);
    if (version < 45 and target_version >= 45) try db.exec(migration_45);
    if (version < 46 and target_version >= 46) try db.exec(migration_46);
    if (version < 47 and target_version >= 47) try db.exec(migration_47);
    if (version < 48 and target_version >= 48) try db.exec(migration_48);
    if (version < 49 and target_version >= 49) try db.exec(migration_49);
    if (version < 50 and target_version >= 50) try db.exec(migration_50);
    if (version < 51 and target_version >= 51) try db.exec(migration_51);
    if (version < 52 and target_version >= 52) try db.exec(migration_52);
    if (version < 53 and target_version >= 53) try db.exec(migration_53);
    if (version < 54 and target_version >= 54) try db.exec(migration_54);
    if (version < 55 and target_version >= 55) try db.exec(migration_55);
    if (version < 56 and target_version >= 56) try db.exec(migration_56);
    if (version < 57 and target_version >= 57) try db.exec(migration_57);
    if (version < 58 and target_version >= 58) try db.exec(migration_58);
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

const scalar = @import("columns.zig").scalar;

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

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
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
    try std.testing.expectEqual(
        @as(i64, 1),
        try scalar(db, "SELECT count(*) FROM scrobble_queue WHERE state=0 AND lease_owner IS NULL;"),
    );

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
    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
}

test "upgrading from version 14 keeps a queued scrobble pending and unleased" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v14.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 14);
    try db.exec(
        \\INSERT INTO scrobble_queue(service, event_key, payload, attempt_count, next_attempt_at)
        \\VALUES ('listenbrainz', 'legacy-1', x'7b7d', 2, 500);
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(
        @as(i64, 1),
        try scalar(db,
            \\SELECT count(*) FROM scrobble_queue
            \\WHERE state=0 AND attempt_count=2 AND next_attempt_at=500
            \\  AND lease_owner IS NULL AND lease_expires_at IS NULL;
        ),
    );
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM listens;"));
    try checkForeignKeys(db);
}

test "upgrading from version 15 adds an empty feedback table and keeps listens" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v15.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 15);
    try db.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'One');
        \\INSERT INTO files(id, audio_format, size_bytes, recording_id) VALUES (1, 1, 10, 1);
        \\INSERT INTO listens(file_id, recording_id, started_at, listened_ms, title, artist)
        \\VALUES (1, 1, 1700000000, 90000, 'One', 'Artist');
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM feedback;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM listens;"));
    try checkForeignKeys(db);
}

test "the migrated feedback table rejects other scores and follows its recording" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "feedback.db");
    defer std.testing.allocator.free(path);
    try copyFixture(std.testing.allocator, std.testing.io, path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try apply(db);
    try db.exec("INSERT INTO recordings(id, title) VALUES (900, 'Loved');");

    try std.testing.expectError(
        error.SqlFailed,
        db.exec("INSERT INTO feedback(recording_id, score, updated_at) VALUES (900, 2, 0);"),
    );
    try std.testing.expectError(
        error.SqlFailed,
        db.exec("INSERT INTO feedback(recording_id, score, updated_at) VALUES (901, 1, 0);"),
    );
    try db.exec("INSERT INTO feedback(recording_id, score, updated_at) VALUES (900, -1, 0);");
    try db.exec("DELETE FROM recordings WHERE id = 900;");
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM feedback;"));
}

test "upgrading from version 16 counts files with MusicBrainz proposals as searched and keeps the proposals" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v16.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 16);
    try db.exec(
        \\INSERT INTO files(id, audio_format, size_bytes) VALUES (1, 1, 10), (2, 1, 10), (3, 1, 10), (4, 1, 10);
        \\INSERT INTO identification_proposals(file_id, provider, provider_id, confidence, payload, state, updated_at)
        \\VALUES (1, 'musicbrainz', 'a', 0.9, x'7b7d', 0, 100),
        \\       (1, 'musicbrainz', 'b', 0.6, x'7b7d', 2, 200),
        \\       (2, 'musicbrainz', 'c', 0.9, x'7b7d', 1, 300),
        \\       (3, 'musicbrainz', 'd', 0.9, x'7b7d', 2, 400);
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 3), try scalar(db, "SELECT count(*) FROM identification_searches WHERE provider = 'musicbrainz';"));
    try std.testing.expectEqual(@as(i64, 200), try scalar(db, "SELECT searched_at FROM identification_searches WHERE file_id = 1;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM identification_searches WHERE file_id = 4;"));
    try std.testing.expectEqual(@as(i64, 4), try scalar(db, "SELECT count(*) FROM identification_proposals;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM acoustid_submissions;"));
    try db.exec("INSERT INTO acoustid_submissions(file_id, recording_mbid, submission_id, submitted_at) VALUES (2, 'c', 7, 500);");
    try db.exec("DELETE FROM files WHERE id = 2;");
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM acoustid_submissions;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM identification_searches;"));
    try checkForeignKeys(db);
}

test "upgrading from version 17 forgets the files scanned from tag-write temporaries and keeps the music" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v17.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 17);
    try db.exec(
        \\INSERT INTO artists(id, name, key) VALUES (1, 'Artist', 'artist'), (2, 'Old Artist', 'old artist');
        \\INSERT INTO releases(id, title, release_key, album_artist_id) VALUES (1, 'New Album', 'new', 1), (2, 'Old Album', 'old', 2);
        \\INSERT INTO files(id, audio_format, size_bytes) VALUES (1, 1, 10), (2, 1, 10), (3, 1, 10), (4, 1, 10), (5, 1, 10);
        \\INSERT INTO locations(file_id, volume_id, uri, state) VALUES
        \\    (1, 1, '/m/a/01.flac', 'present'),
        \\    (2, 1, '/m/a/01.flac.orca-backup-7-0', 'missing'),
        \\    (3, 1, '/m/a/01.flac.orca-stage-7-0', 'missing'),
        \\    (4, 1, '/m/a/01.flac.orca-stage-7-0.recovery-displaced', 'missing'),
        \\    (5, 1, '/m/a/02.flac.orca-backup-8-0', 'present'),
        \\    (5, 1, '/m/b/02.flac', 'present');
        \\INSERT INTO tracks(id, title, release_id, artist_id, track_number, preferred_file_id) VALUES
        \\    (1, 'Real', 1, 1, 1, 1),
        \\    (2, 'Ghost', 2, 2, 1, 2),
        \\    (3, 'Also real', 1, 1, 2, 5);
        \\INSERT INTO mutation_operations(
        \\    plan_id, group_id, action_index, kind, source_path, stage_path, backup_path,
        \\    expected_size, expected_modified_ns, state, file_id
        \\) VALUES
        \\    (7, 7, 0, 0, '/m/a/01.flac', '/m/a/01.flac.orca-stage-7-0', '/m/a/01.flac.orca-backup-7-0', 10, 1, 2, 2),
        \\    (8, 8, 0, 0, '/m/a/02.flac', '/m/a/02.flac.orca-stage-8-0', '/m/a/02.flac.orca-backup-8-0', 10, 1, 2, 5);
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM files;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM files WHERE id = 1;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM locations WHERE file_id = 5;"));
    try std.testing.expectEqual(@as(i64, 3), try scalar(db, "SELECT count(*) FROM locations;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM tracks;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT preferred_file_id FROM tracks WHERE title = 'Real';"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM releases WHERE id = 2;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM artists WHERE id = 2;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM releases;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM artists;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM mutation_operations WHERE file_id IS NULL;"));
    try std.testing.expectEqual(@as(i64, 5), try scalar(db, "SELECT file_id FROM mutation_operations WHERE plan_id = 8;"));
    try checkForeignKeys(db);
}

test "upgrading from version 18 adds empty provider state and leases and counts no proposal as accepted in bulk" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v18.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 18);
    try db.exec(
        \\INSERT INTO files(id, audio_format, size_bytes) VALUES (1, 1, 10);
        \\INSERT INTO identification_proposals(file_id, provider, provider_id, confidence, payload, state, updated_at)
        \\VALUES (1, 'musicbrainz', 'a', 0.9, x'7b7d', 1, 100);
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM provider_state;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM provider_leases;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT accepted_in_bulk FROM identification_proposals;"));
    try std.testing.expectError(
        error.SqlFailed,
        db.exec("INSERT INTO provider_leases(service, owner, expires_at) VALUES ('musicbrainz', NULL, 0);"),
    );
    try checkForeignKeys(db);
}

test "an empty database migrates straight to the current version" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "fresh.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try apply(db);
    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
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
    // Derived from current_version rather than written out, because hardcoding
    // it means this test silently stops testing anything the next time a
    // migration lands -- which is exactly what happened at version 11.
    try db.exec(std.fmt.comptimePrint(
        "PRAGMA user_version={d};",
        .{current_version + 1},
    ));
    try std.testing.expectError(error.SchemaVersionTooNew, apply(db));
}

test "artists split only by typographic punctuation merge when the fold learns it" {
    // The real shape this closes: the Release carries the typographic spelling
    // a metadata service supplied, along with a MusicBrainz id; the Tracks
    // carry what somebody typed. Under the version-10 fold they are two
    // artists, one holding every release and the other every track, so
    // browsing to either shows half the artist.
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "refold.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 10);
    try db.exec(
        \\INSERT INTO artists(id, name, key, sort_name, musicbrainz_artist_id)
        \\VALUES (1, 'El' || char(8208) || 'P', 'el' || char(8208) || 'p',
        \\           'el' || char(8208) || 'p', 'mbid-el-p'),
        \\       (2, 'El-P', 'el-p', 'el-p', NULL);
        \\INSERT INTO releases(id, title, album_artist, album_artist_id)
        \\VALUES (1, 'Fantastic Damage', 'El' || char(8208) || 'P', 1);
        \\INSERT INTO tracks(id, title, artist, artist_id, release_id, track_number)
        \\VALUES (1, 'Deep Space 9mm', 'El-P', 2, 1, 1);
    );

    try apply(db);

    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM artists;"));
    // The row carrying a MusicBrainz id survives, which is also the better
    // display name: supplied by a metadata service rather than typed.
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT id FROM artists;"));
    try std.testing.expectEqual(
        @as(i64, 1),
        try scalar(db, "SELECT artist_id FROM tracks WHERE id = 1;"),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try scalar(db, "SELECT album_artist_id FROM releases WHERE id = 1;"),
    );
    // The unique index is dropped and rebuilt across the re-key; it has to
    // come back, or the next projection could insert a duplicate artist.
    try std.testing.expectEqual(
        @as(i64, 1),
        try scalar(
            db,
            "SELECT count(*) FROM sqlite_master WHERE type='index' AND name='artists_key';",
        ),
    );
    try checkForeignKeys(db);
}

test "artists that merely look alike are left alone by the re-key" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "distinct.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 10);
    // Genuinely different artists, including the case the fold must not touch:
    // a featured credit is not a spelling of the headline act.
    try db.exec(
        \\INSERT INTO artists(id, name, key, sort_name)
        \\VALUES (1, 'Grayarea', 'grayarea', 'grayarea'),
        \\       (2, 'Grayarea feat. Erik Shepard', 'grayarea feat. erik shepard',
        \\           'grayarea feat. erik shepard'),
        \\       (3, 'Gray Area', 'gray area', 'gray area');
    );

    try apply(db);

    try std.testing.expectEqual(@as(i64, 3), try scalar(db, "SELECT count(*) FROM artists;"));
}

test "release keys are stable under the fold that is current" {
    // A stale release key is not cosmetic: ReleaseRepository.upsert keys on it,
    // so the next projection of an already-projected library builds a parallel
    // release beside every stale one.
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "rekey.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 11);
    // Keys as a pre-punctuation fold left them: the typographic apostrophe the
    // tag carried survived into the stored key.
    try db.exec(
        \\INSERT INTO releases(id, title, album_artist, release_key)
        \\VALUES (1, 'A Sailor''s Guide to Earth', 'Sturgill Simpson',
        \\        'a sailor' || char(8217) || 's guide to earth');
    );

    try apply(db);

    const stable = try scalar(
        db,
        "SELECT count(*) FROM releases WHERE release_key = orca_artist_key(release_key);",
    );
    try std.testing.expectEqual(@as(i64, 1), stable);
    try checkForeignKeys(db);
}

test "a release key that would collide on re-keying is left as it is" {
    // Two releases folding together are one album spelled two ways, and their
    // tracks share track numbers. Repointing them would violate
    // tracks_position and fail the migration -- refusing to open a library over
    // a duplicate album is far worse than leaving a projection to reconcile it.
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "collide.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 11);
    try db.exec(
        \\INSERT INTO releases(id, title, album_artist, release_key)
        \\VALUES (1, 'Ten', 'Pearl Jam', 'ten'),
        \\       (2, 'Ten', 'Pearl Jam', 'ten' || char(8217));
    );

    try apply(db);

    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM releases;"));
    try checkForeignKeys(db);
}

test "re-keying an artist relinks the rows its old key could not reach" {
    // Migration 9 linked tracks and releases with
    // `artists.key = orca_artist_key(...)`: the current fold compared against a
    // key written by whichever fold was current when the row was projected. An
    // artist stored under a pre-fold spelling never matched, so re-keying must
    // re-link.
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "relink.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 10);
    // `eli “paperboy” reed` is what the previous fold stored; the current fold
    // produces straight quotes, so the join in migration 9 found nothing.
    try db.exec(
        \\INSERT INTO artists(id, name, key, sort_name)
        \\VALUES (1, 'Eli ' || char(8220) || 'Paperboy' || char(8221) || ' Reed',
        \\        'eli ' || char(8220) || 'paperboy' || char(8221) || ' reed',
        \\        'eli ' || char(8220) || 'paperboy' || char(8221) || ' reed');
        \\INSERT INTO releases(id, title, album_artist, release_key)
        \\VALUES (1, 'Come and Get It',
        \\        'Eli ' || char(8220) || 'Paperboy' || char(8221) || ' Reed', 'come and get it');
        \\INSERT INTO tracks(id, title, artist, release_id, track_number)
        \\VALUES (1, 'Come and Get It',
        \\        'Eli ' || char(8220) || 'Paperboy' || char(8221) || ' Reed', 1, 1);
    );
    // Exactly the state migration 9 leaves behind for such a row.
    try std.testing.expectEqual(
        @as(i64, 0),
        try scalar(db, "SELECT count(*) FROM tracks WHERE artist_id IS NOT NULL;"),
    );

    try apply(db);

    try std.testing.expectEqual(
        @as(i64, 1),
        try scalar(db, "SELECT artist_id FROM tracks WHERE id = 1;"),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try scalar(db, "SELECT album_artist_id FROM releases WHERE id = 1;"),
    );
    try checkForeignKeys(db);
}

test "two release keys that fold onto each other are both left alone" {
    // The first guard only rejected a row whose folded key already belonged to
    // another row. Two rows that BOTH need folding and fold to the same value
    // both passed it, both updated, and the live unique index rejected the
    // second -- failing the migration and leaving the library unopenable at
    // its old version. U+2019 and U+2018 both fold to an apostrophe.
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "bothstale.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 11);
    try db.exec(
        \\INSERT INTO releases(id, title, album_artist, release_key)
        \\VALUES (1, 'Don''t Stop', 'X', 'don' || char(8217) || 't stop'),
        \\       (2, 'Don''t Stop', 'X', 'don' || char(8216) || 't stop');
    );

    // The migration must complete rather than failing on the unique index.
    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM releases;"));
    try checkForeignKeys(db);
}

test "an untitled album keeps the folder path its key was built from" {
    // The projection folds only the first two segments of a release key and
    // appends the folder path raw. Folding the whole string lowercased and
    // whitespace-collapsed that path, so the next projection composed the
    // original, matched nothing, and built a parallel release -- the exact
    // corruption this migration exists to repair.
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "untitled.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 11);
    // Typographic apostrophe in the album artist, so the row genuinely needs
    // re-keying; mixed case and a double space in the path, so any folding of
    // that segment shows up.
    try db.exec(
        \\INSERT INTO releases(id, title, album_artist, release_key)
        \\VALUES (1, '', 'Stray' || char(8217) || 's Files',
        \\        '' || char(31) || 'stray' || char(8217) || 's files' || char(31) ||
        \\        '2001' || char(31) || '/mnt/Media/Music/Loose  Tracks');
    );

    try apply(db);

    const stored = try text(std.testing.allocator, db, "SELECT release_key FROM releases;");
    defer std.testing.allocator.free(stored);
    // The apostrophe folded; the path did not.
    try std.testing.expect(std.mem.indexOf(u8, stored, "stray's files") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, stored, "/mnt/Media/Music/Loose  Tracks") != null,
    );
}

test "a version-19 library gains release artwork, whose row goes when its release does" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "artwork.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 19);
    try db.exec("INSERT INTO releases(id, title, release_key) VALUES (1, 'Ginger', 'ginger');");

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try db.exec(
        \\INSERT INTO release_artwork(release_id, musicbrainz_release_id, image, mime, fetched_at)
        \\VALUES (1, '2e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b', NULL, NULL, 1800000000);
    );
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM release_artwork;"));
    try db.exec("DELETE FROM releases WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM release_artwork;"));
    try checkForeignKeys(db);
}

test "a version-20 library gains a write time on Orca's values, unset for every existing value" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "written.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 20);
    try db.exec(
        \\INSERT INTO files(id, audio_format, size_bytes) VALUES (1, 1, 10);
        \\INSERT INTO orca_metadata_values(file_id, field, value, provenance, locked, updated_at)
        \\VALUES (1, 8, '8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a', 2, 0, 1800000000);
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM orca_metadata_values WHERE written_at IS NULL;"));
    try checkForeignKeys(db);
}

test "a version-21 library re-observes present files whose tags held only a cover" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "cover-only.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 21);
    try db.exec(
        \\INSERT INTO files(id, audio_format, size_bytes) VALUES (1, 1, 10), (2, 1, 10), (3, 1, 10), (4, 1, 10), (5, 1, 10);
        \\INSERT INTO locations(file_id, volume_id, uri, native_inode, size_bytes, modified_ns, state) VALUES
        \\    (1, 1, '/m/cover-only.mp3', 11, 10, 500, 'present'),
        \\    (2, 1, '/m/titled.mp3', 12, 10, 500, 'present'),
        \\    (3, 1, '/m/gone.mp3', 13, 10, 500, 'missing'),
        \\    (4, 1, '/m/genre.mp3', 14, 10, 500, 'present'),
        \\    (5, 1, '/m/untagged.mp3', 15, 10, 500, 'present');
        \\INSERT INTO observed_file_tags(file_id, title, artwork_mime_type, artwork_byte_size, artwork_kind) VALUES
        \\    (1, NULL, 'image/jpeg', 2048, 3),
        \\    (2, 'Song', 'image/jpeg', 2048, 3),
        \\    (3, NULL, 'image/jpeg', 2048, 3),
        \\    (4, NULL, 'image/jpeg', 2048, 3);
        \\INSERT INTO observed_file_genres(file_id, ordinal, value) VALUES (4, 0, 'Rock');
    );

    try applyThrough(db, 49);

    try std.testing.expectEqual(@as(i64, 49), try scalar(db, "PRAGMA user_version;"));
    var write_lane: repository.WriteLane = .{ .io = std.testing.io };
    const locations: repository.LocationRepository = .{ .db = db, .write_lane = &write_lane };
    const cases = [_]struct { uri: []const u8, inode: i64, unchanged: bool }{
        .{ .uri = "/m/cover-only.mp3", .inode = 11, .unchanged = false },
        .{ .uri = "/m/titled.mp3", .inode = 12, .unchanged = true },
        .{ .uri = "/m/genre.mp3", .inode = 14, .unchanged = true },
        .{ .uri = "/m/untagged.mp3", .inode = 15, .unchanged = true },
    };
    for (cases) |case| {
        const found = try locations.unchangedLocationId(1, case.uri, .{
            .volume_id = 1,
            .native_inode = case.inode,
            .size_bytes = 10,
            .modified_ns = 500,
        }, null);
        try std.testing.expectEqual(case.unchanged, found != null);
    }
    try std.testing.expectEqual(@as(i64, 500), try scalar(db, "SELECT modified_ns FROM locations WHERE file_id = 3;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM locations WHERE modified_ns <> 500;"));
    try std.testing.expectEqual(@as(i64, 4), try scalar(db, "SELECT count(*) FROM observed_file_tags;"));
    try checkForeignKeys(db);
}

test "a version-22 library keeps an audio hash only where a current fingerprint was measured from the file's bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "audio-hash.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 22);
    try db.exec(
        \\INSERT INTO files(id, audio_format, size_bytes, quick_hash, audio_hash) VALUES
        \\    (1, 1, 10, X'01', X'AA'),
        \\    (2, 1, 10, X'02', X'AA'),
        \\    (3, 1, 10, X'03', X'AA'),
        \\    (4, 1, 10, X'04', NULL),
        \\    (5, 1, 10, X'05', X'AA'),
        \\    (6, 1, 10, X'06', X'AA');
        \\INSERT INTO analysis_results(file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity, result) VALUES
        \\    (1, 2, 'orca.temporal-fingerprint', 2, X'00', X'01', X'00'),
        \\    (2, 2, 'orca.temporal-fingerprint', 2, X'00', X'01', X'00'),
        \\    (4, 2, 'orca.temporal-fingerprint', 2, X'00', X'04', X'00'),
        \\    (5, 2, 'orca.temporal-fingerprint', 1, X'00', X'05', X'00'),
        \\    (6, 1, 'orca.audio-diagnostics', 2, X'00', X'06', X'00');
    );

    try applyThrough(db, 56);

    try std.testing.expectEqual(@as(i64, 56), try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM files WHERE audio_hash IS NOT NULL;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM files WHERE id = 1 AND audio_hash = X'AA';"));
    try std.testing.expectEqual(@as(i64, 6), try scalar(db, "SELECT count(*) FROM files WHERE quick_hash IS NOT NULL;"));
    try std.testing.expectEqual(@as(i64, 5), try scalar(db, "SELECT count(*) FROM analysis_results;"));
    try checkForeignKeys(db);

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM files WHERE audio_hash IS NOT NULL;"));
    try std.testing.expectEqual(@as(i64, 5), try scalar(db, "SELECT count(*) FROM analysis_results;"));
}

test "a version-23 library keeps each service's block and backoff and gains no request time" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "next-request.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 23);
    try db.exec(
        \\INSERT INTO provider_state(service, blocked_until_ms, backoff_ms) VALUES
        \\    ('musicbrainz', 1800000600000, 60000),
        \\    ('acoustid', NULL, 0);
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM provider_state WHERE next_request_ms IS NULL;"));
    try std.testing.expectEqual(
        @as(i64, 1800000600000),
        try scalar(db, "SELECT blocked_until_ms FROM provider_state WHERE service = 'musicbrainz' AND backoff_ms = 60000;"),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try scalar(db, "SELECT count(*) FROM provider_state WHERE service = 'acoustid' AND blocked_until_ms IS NULL AND backoff_ms = 0;"),
    );
    try checkForeignKeys(db);
}

test "migration 25 re-observes every present location of a file held at more than one path and leaves single-location files alone" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "shared-copies.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 24);
    try db.exec(
        \\INSERT INTO files(id, audio_format, size_bytes, quick_hash) VALUES
        \\    (1, 1, 10, X'01'), (2, 1, 10, X'02'), (3, 1, 10, X'03'), (4, 1, 10, X'04');
        \\INSERT INTO locations(id, file_id, volume_id, uri, native_inode, size_bytes, modified_ns, state) VALUES
        \\    (1, 1, 1, '/m/a/shared.flac', 11, 10, 500, 'present'),
        \\    (2, 1, 1, '/m/b/shared.flac', 12, 10, 500, 'present'),
        \\    (3, 2, 1, '/m/single.flac', 13, 10, 500, 'present'),
        \\    (4, 3, 1, '/m/new/moved.flac', 14, 10, 500, 'present'),
        \\    (5, 3, 1, '/m/old/moved.flac', 14, 10, 500, 'missing'),
        \\    (6, 4, 1, '/m/a/three.flac', 15, 10, 500, 'present'),
        \\    (7, 4, 1, '/m/b/three.flac', 16, 10, 500, 'present'),
        \\    (8, 4, 1, '/m/c/three.flac', 17, 10, 500, 'missing');
    );

    try applyThrough(db, 49);

    try std.testing.expectEqual(@as(i64, 49), try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(
        @as(i64, 4),
        try scalar(db, "SELECT count(*) FROM locations WHERE modified_ns = -1 AND id IN (1, 2, 6, 7);"),
    );
    try std.testing.expectEqual(@as(i64, 4), try scalar(db, "SELECT count(*) FROM locations WHERE modified_ns = 500;"));
    try std.testing.expectEqual(@as(i64, 8), try scalar(db, "SELECT count(*) FROM locations WHERE file_id IN (1, 2, 3, 4);"));
    try std.testing.expectEqual(@as(i64, 4), try scalar(db, "SELECT count(*) FROM files WHERE quick_hash IS NOT NULL;"));
    try checkForeignKeys(db);
}

test "a version-25 library resumes an undo that was interrupted between files" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "half-undone.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 25);
    try db.exec(
        \\INSERT INTO mutation_operations(id, plan_id, group_id, action_index, kind, source_path, expected_size, expected_modified_ns, state) VALUES
        \\    (1, 1, 1, 0, 0, '/m/1a.flac', 1, 1, 2),
        \\    (2, 1, 1, 1, 0, '/m/1b.flac', 1, 1, 3),
        \\    (3, 1, 1, 2, 0, '/m/1c.flac', 1, 1, 2),
        \\    (4, 2, 2, 0, 0, '/m/2a.flac', 1, 1, 2),
        \\    (5, 2, 2, 1, 0, '/m/2b.flac', 1, 1, 2),
        \\    (6, 3, 3, 0, 0, '/m/3a.flac', 1, 1, 2),
        \\    (7, 3, 3, 1, 0, '/m/3b.flac', 1, 1, 3),
        \\    (8, 3, 3, 2, 0, '/m/3c.flac', 1, 1, 5),
        \\    (9, 4, 4, 0, 0, '/m/4a.flac', 1, 1, 2),
        \\    (10, 4, 4, 1, 0, '/m/4b.flac', 1, 1, 3),
        \\    (11, 4, 4, 2, 0, '/m/4c.flac', 1, 1, 1),
        \\    (12, 5, 5, 0, 0, '/m/5a.flac', 1, 1, 3);
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    const State = repository.MutationState;
    for ([_]struct { State, i64 }{
        .{ .planned, 0 }, .{ .staged, 1 },               .{ .committed, 2 }, .{ .rolled_back, 3 },
        .{ .failed, 4 },  .{ .needs_reconciliation, 5 }, .{ .undoing, 6 },
    }) |pair| try std.testing.expectEqual(pair[1], @as(i64, @backingInt(pair[0])));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM mutation_operations WHERE state = 6;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM mutation_operations WHERE state = 6 AND id IN (1, 3);"));
    try std.testing.expectEqual(@as(i64, 4), try scalar(db, "SELECT count(*) FROM mutation_operations WHERE state = 2 AND id IN (4, 5, 6, 9);"));
    try std.testing.expectEqual(@as(i64, 3), try scalar(db, "SELECT state FROM mutation_operations WHERE id = 12;"));
    try std.testing.expectEqual(@as(i64, 5), try scalar(db, "SELECT state FROM mutation_operations WHERE id = 8;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT state FROM mutation_operations WHERE id = 11;"));
}

test "upgrading from version 26 moves each recording's highest track rating into ratings and drops the column" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v26.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 26);
    try db.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'One'), (2, 'Two'), (3, 'Three');
        \\INSERT INTO tracks(id, recording_id, title, rating) VALUES
        \\    (1, 1, 'One', 60), (2, 1, 'One again', 80), (3, 2, 'Two', 0),
        \\    (4, 3, 'Three', NULL), (5, NULL, 'Loose', 100);
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM ratings;"));
    try std.testing.expectEqual(@as(i64, 80), try scalar(db, "SELECT rating FROM ratings WHERE recording_id = 1;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM pragma_table_info('tracks') WHERE name = 'rating';"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM sqlite_master WHERE name = 'tracks_rating';"));
    try std.testing.expectEqual(@as(i64, 5), try scalar(db, "SELECT count(*) FROM tracks;"));
    for ([_][:0]const u8{ "tracks_by_recording", "playlist_entries_by_recording", "locations_by_uri" }) |index| {
        var statement = try db.prepare("SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = ?1;");
        defer statement.deinit();
        try statement.bindText(1, index);
        try std.testing.expect(try statement.step() == .row);
        try std.testing.expectEqual(@as(i64, 1), statement.columnInt64(0));
    }
    try checkForeignKeys(db);
}

test "the migrated ratings and playlist tables reject invalid rows and follow their recording and playlist" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "playlists.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try apply(db);
    try db.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'One'), (2, 'Two');
        \\INSERT INTO playlists(id, name, created_at, updated_at) VALUES (1, 'Mix', 0, 0), (2, 'Other', 0, 0);
    );

    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO ratings VALUES (1, 0, 0);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO ratings VALUES (1, 101, 0);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO ratings VALUES (9, 50, 0);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO playlists(name, created_at, updated_at) VALUES ('Mix', 0, 0);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO playlist_entries VALUES (1, 0, 9, 0);"));
    try db.exec(
        \\INSERT INTO ratings VALUES (1, 100, 0), (2, 1, 0);
        \\INSERT INTO playlist_entries VALUES (1, 0, 1, 0), (1, 1, 2, 0), (1, 2, 1, 0), (2, 0, 2, 0);
    );
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO playlist_entries VALUES (1, 1, 1, 0);"));

    try db.exec("DELETE FROM recordings WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM ratings;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM playlist_entries;"));
    try db.exec("DELETE FROM playlists WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM playlist_entries;"));
}

test "upgrading from version 27 adds an empty verification table that follows its file, and leaves every proposal out of an album group" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v27.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 27);
    try db.exec(
        \\INSERT INTO files(id, audio_format, size_bytes, quick_hash) VALUES (1, 1, 10, x'01'), (2, 1, 10, NULL);
        \\INSERT INTO identification_proposals(file_id, provider, provider_id, confidence, payload, state, updated_at)
        \\VALUES (1, 'acoustid', 'a', 0.9, x'7b7d', 0, 100);
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM recording_verifications;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM identification_proposals WHERE album_group IS NULL;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'identification_proposals_album_group';"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO recording_verifications(file_id, recording_mbid, outcome, verified_at) VALUES (9, 'a', 0, 0);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO recording_verifications(file_id, outcome, verified_at) VALUES (1, 0, 0);"));
    try db.exec(
        \\INSERT INTO recording_verifications(file_id, quick_hash, recording_mbid, outcome, heard, verified_at)
        \\VALUES (1, x'01', 'a', 0, '[]', 0), (2, NULL, 'b', 3, NULL, 0);
        \\DELETE FROM files WHERE id = 1;
    );
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM recording_verifications;"));
    try checkForeignKeys(db);
}

test "upgrading from version 28 keeps every health issue with no related file and adds dismissals that follow their file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v28.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 28);
    try db.exec(
        \\INSERT INTO files(id, audio_format, size_bytes, quick_hash) VALUES (1, 1, 10, x'01'), (2, 1, 10, NULL);
        \\INSERT INTO library_health_issues(file_id, kind, severity, details) VALUES
        \\    (1, 5, 1, 'clipped'), (2, 9, 1, 'content also appears at /m/a.flac');
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM library_health_issues WHERE related_file_id IS NULL;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM health_dismissals;"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO health_dismissals VALUES (9, 5, NULL, 0);"));
    try std.testing.expectError(error.SqlFailed, db.exec("UPDATE library_health_issues SET related_file_id = 9 WHERE file_id = 2;"));
    try db.exec(
        \\UPDATE library_health_issues SET related_file_id = 1 WHERE file_id = 2;
        \\INSERT INTO health_dismissals VALUES (1, 5, x'01', 0), (2, 9, NULL, 0);
        \\DELETE FROM files WHERE id = 1;
    );
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM library_health_issues WHERE file_id = 2 AND related_file_id IS NULL;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM health_dismissals;"));
    try checkForeignKeys(db);
}

test "upgrading from version 29 adds an empty album love table that follows its Release" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v29.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 29);
    try db.exec("INSERT INTO releases(id, title, release_key) VALUES (1, 'Pink Moon', 'a'), (2, 'Bryter Layter', 'b');");

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM release_loves;"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO release_loves VALUES (9, 0);"));
    try db.exec(
        \\INSERT INTO release_loves VALUES (1, 100), (2, 200);
        \\DELETE FROM releases WHERE id = 1;
    );
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT release_id FROM release_loves;"));
    try checkForeignKeys(db);
}

test "upgrading from version 30 adds an empty lyrics cache that follows its Track" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v30.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 30);
    try db.exec("INSERT INTO tracks(id, title) VALUES (1, 'Pink Moon'), (2, 'Road');");

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM track_lyrics;"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO track_lyrics(track_id, query_digest, fetched_at) VALUES (9, x'00', 0);"));
    try db.exec(
        \\INSERT INTO track_lyrics(track_id, query_digest, synced, fetched_at) VALUES (1, x'01', '[00:01.00]a', 100);
        \\INSERT INTO track_lyrics(track_id, query_digest, fetched_at) VALUES (2, x'02', 200);
        \\DELETE FROM tracks WHERE id = 1;
    );
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT track_id FROM track_lyrics;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT instrumental FROM track_lyrics;"));
    try checkForeignKeys(db);
}

test "migration 32 counts each listen under its file's recording, and a file changing recording carries its plays" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v31.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 31);
    try db.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'Pink Moon'), (2, 'Road'), (3, 'Parasite');
        \\INSERT INTO files(id, recording_id) VALUES (10, 1), (11, 1), (12, 2);
        \\INSERT INTO listens(file_id, recording_id, started_at, listened_ms, title, artist) VALUES
        \\    (10, 1, 100, 1, 'Pink Moon', 'Nick Drake'),
        \\    (11, 1, 300, 1, 'Pink Moon', 'Nick Drake'),
        \\    (10, 1, 200, 1, 'Pink Moon', 'Nick Drake'),
        \\    (12, 3, 50, 1, 'Road', 'Nick Drake'),
        \\    (NULL, NULL, 400, 1, 'Gone', 'Nick Drake');
        \\INSERT INTO releases(id, title, disc_count) VALUES (5, 'Pink Moon', 1);
        \\INSERT INTO observed_file_tags(file_id, track_total) VALUES (10, 11);
        \\INSERT INTO tracks(id, title, recording_id, release_id, track_number, preferred_file_id) VALUES
        \\    (1, 'Pink Moon', 1, 5, 1, 10), (2, 'Road', 2, 5, 2, 12);
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db,
        \\SELECT count(*) FROM (
        \\    SELECT recording_id, play_count, last_played_at FROM recording_play_stats
        \\    EXCEPT
        \\    SELECT recording_id, count(*), max(started_at) FROM listens
        \\    WHERE recording_id IS NOT NULL GROUP BY recording_id);
    ));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM recording_play_stats;"));
    try std.testing.expectEqual(@as(i64, 3), try scalar(db, "SELECT play_count FROM recording_play_stats WHERE recording_id = 1;"));
    try std.testing.expectEqual(@as(i64, 300), try scalar(db, "SELECT last_played_at FROM recording_play_stats WHERE recording_id = 1;"));
    try std.testing.expectEqual(@as(i64, 11), try scalar(db, "SELECT track_total FROM tracks WHERE id = 1;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT track_total FROM tracks WHERE id = 2;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT disc_total FROM tracks WHERE id = 2;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT explicit FROM tracks WHERE id = 1;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT recording_id FROM listens WHERE file_id = 12;"));

    try db.exec("UPDATE files SET recording_id = 2 WHERE id = 11;");
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT recording_id FROM listens WHERE file_id = 11;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT play_count FROM recording_play_stats WHERE recording_id = 1;"));
    try std.testing.expectEqual(@as(i64, 200), try scalar(db, "SELECT last_played_at FROM recording_play_stats WHERE recording_id = 1;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT play_count FROM recording_play_stats WHERE recording_id = 2;"));
    try db.exec("UPDATE files SET recording_id = 2 WHERE id = 10;");
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM recording_play_stats WHERE recording_id = 1;"));
    try std.testing.expectEqual(@as(i64, 4), try scalar(db, "SELECT play_count FROM recording_play_stats WHERE recording_id = 2;"));
    try db.exec("DELETE FROM listens; DELETE FROM tracks; DELETE FROM files; DELETE FROM recordings WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM recording_play_stats;"));
    try checkForeignKeys(db);
}

test "migration 33 gives each Track the folded genres of its preferred file, else of its recording's lowest file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v32.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 32);
    try db.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'One'), (2, 'Two'), (3, 'Three'), (4, 'Four');
        \\INSERT INTO files(id, recording_id) VALUES (10, 1), (11, 2), (12, 2), (13, 3), (14, 4);
        \\INSERT INTO observed_file_genres(file_id, ordinal, value) VALUES
        \\    (10, 0, 'Hip-Hop/Rap'), (10, 1, 'hip hop'), (10, 2, 'R&B/Soul'), (10, 3, '  '),
        \\    (11, 0, 'Folk'), (12, 0, 'Rock'),
        \\    (13, 0, 'folk rock'), (13, 1, 'HipHop');
        \\INSERT INTO tracks(id, title, recording_id, preferred_file_id) VALUES
        \\    (1, 'One', 1, 10), (2, 'Two', 2, 12), (3, 'Three', 3, NULL), (4, 'Four', 4, 14);
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 4), try scalar(db, "SELECT count(*) FROM genres;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM genres WHERE name = 'Hip Hop' AND key = 'hiphop';"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM genres WHERE name = 'R&B/Soul' AND key = 'r&bsoul';"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM genres WHERE name = 'Folk Rock';"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db,
        \\SELECT count(*) FROM (
        \\    SELECT track_id, ordinal, name, provenance FROM track_genres JOIN genres ON genres.id = genre_id
        \\    EXCEPT
        \\    VALUES (1, 0, 'Hip Hop', 0), (1, 1, 'R&B/Soul', 0), (2, 0, 'Rock', 0),
        \\           (3, 0, 'Folk Rock', 0), (3, 1, 'Hip Hop', 0));
    ));
    try std.testing.expectEqual(@as(i64, 5), try scalar(db, "SELECT count(*) FROM track_genres;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM track_genres WHERE track_id = 4;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM genres WHERE name = 'Folk';"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO track_genres VALUES (9, 1, 0, 0);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO track_genres SELECT 2, id, 5, 0 FROM genres WHERE name = 'Rock';"));
    try db.exec("DELETE FROM tracks WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 3), try scalar(db, "SELECT count(*) FROM track_genres;"));
    try checkForeignKeys(db);
}

test "upgrading from version 33 adds empty artist info, release info and settings tables, the info following its Artist and Release" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v33.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 33);
    try db.exec(
        \\INSERT INTO artists(id, name, key) VALUES (1, 'Nick Drake', 'nickdrake'), (2, 'John Martyn', 'johnmartyn');
        \\INSERT INTO releases(id, title, release_key) VALUES (1, 'Pink Moon', 'a'), (2, 'Solid Air', 'b');
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    for ([_][:0]const u8{
        "SELECT count(*) FROM artist_info;",
        "SELECT count(*) FROM artist_links;",
        "SELECT count(*) FROM artist_related;",
        "SELECT count(*) FROM artist_loves;",
        "SELECT count(*) FROM release_info;",
        "SELECT count(*) FROM library_settings;",
    }) |query| try std.testing.expectEqual(@as(i64, 0), try scalar(db, query));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO artist_loves VALUES (9, 0);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO artist_info(artist_id, fetched_at, outcome) VALUES (9, 0, 0);"));
    try db.exec(
        \\INSERT INTO artist_info(artist_id, begin_year, fetched_at, outcome) VALUES (1, 1969, 100, 1), (2, 1967, 100, 1);
        \\INSERT INTO artist_links VALUES (1, 0, 'https://example.org'), (2, 0, 'https://example.com');
        \\INSERT INTO artist_related VALUES (1, 0, 'mbid', 'John Martyn', 90);
        \\INSERT INTO artist_loves VALUES (1, 100), (2, 200);
        \\INSERT INTO release_info(release_id, description, fetched_at, outcome) VALUES (1, 'x', 100, 1), (2, 'y', 100, 1);
        \\DELETE FROM artists WHERE id = 1;
        \\DELETE FROM releases WHERE id = 1;
    );
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT artist_id FROM artist_info;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT artist_id FROM artist_links;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM artist_related;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT artist_id FROM artist_loves;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT release_id FROM release_info;"));
    try checkForeignKeys(db);
}

test "migration 33 splits a stated genre list as the projection does and keeps the observed value whole" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v32-split.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 32);
    try db.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'One'), (2, 'Two');
        \\INSERT INTO files(id, recording_id) VALUES (10, 1), (11, 2);
        \\INSERT INTO observed_file_genres(file_id, ordinal, value) VALUES
        \\    (10, 0, 'Indie Rock, Rock, Alternative Rock'), (10, 1, 'rock; Hip-Hop/Rap ;, '),
        \\    (11, 0, 'Folk, World, & Country'), (11, 1, 'Folk;Jazz');
        \\INSERT INTO tracks(id, title, recording_id, preferred_file_id) VALUES
        \\    (1, 'One', 1, 10), (2, 'Two', 2, 11);
    );
    try db.exec("CREATE TEMP TABLE before_split AS SELECT * FROM observed_file_genres;");

    try apply(db);

    try std.testing.expectEqual(@as(i64, 0), try scalar(db,
        \\SELECT count(*) FROM (
        \\    SELECT track_id, ordinal, name FROM track_genres JOIN genres ON genres.id = genre_id
        \\    EXCEPT
        \\    VALUES (1, 0, 'Indie Rock'), (1, 1, 'Rock'), (1, 2, 'Alternative Rock'), (1, 3, 'Hip Hop'),
        \\           (2, 0, 'Folk, World, & Country'), (2, 1, 'Folk'), (2, 2, 'Jazz'));
    ));
    try std.testing.expectEqual(@as(i64, 7), try scalar(db, "SELECT count(*) FROM track_genres;"));
    try std.testing.expectEqual(@as(i64, 7), try scalar(db, "SELECT count(*) FROM genres;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM genres WHERE name LIKE '%;%' OR (name LIKE '%,%' AND name <> 'Folk, World, & Country');"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db,
        \\SELECT count(*) FROM (SELECT * FROM observed_file_genres EXCEPT SELECT * FROM temp.before_split);
    ));
    try checkForeignKeys(db);
}

test "a version-34 library keeps every playlist's entries in order and gains manual, user-made, untagged metadata" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v34.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 34);
    try db.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'One'), (2, 'Two'), (3, 'Three');
        \\INSERT INTO playlists(id, name, created_at, updated_at) VALUES (1, 'Mix', 10, 20), (2, 'Other', 30, 40);
        \\INSERT INTO playlist_entries VALUES (1, 0, 3, 0), (1, 1, 1, 0), (1, 2, 2, 0), (1, 3, 3, 0), (2, 0, 2, 0);
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db,
        \\SELECT group_concat(recording_id, ',') = '3,1,2,3' FROM
        \\(SELECT recording_id FROM playlist_entries WHERE playlist_id = 1 ORDER BY position);
    ));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT recording_id FROM playlist_entries WHERE playlist_id = 2;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db,
        \\SELECT count(*) FROM playlists WHERE description = '' AND pinned_at IS NULL AND loved_at IS NULL
        \\  AND kind = 0 AND rules IS NULL AND creator = 0;
    ));
    try std.testing.expectEqual(@as(i64, 20), try scalar(db, "SELECT updated_at FROM playlists WHERE id = 1;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM playlist_tags;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM library_settings;"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO playlist_tags VALUES (9, 0, 'x');"));
    try db.exec("INSERT INTO playlist_tags VALUES (1, 0, 'focus'), (1, 1, 'lofi'); DELETE FROM playlists WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM playlist_tags;"));
    try checkForeignKeys(db);
}

test "a version-35 library gains a search index holding every Artist, Release, Playlist and Genre it has, and keeps its Tracks in track_search" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v35.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 35);
    try db.exec(
        \\INSERT INTO artists(id, name, sort_name, key) VALUES (1, 'Sigur Rós', 'Sigur Rós', 'sigur ros'), (2, 'Aminé', 'Aminé', 'amine');
        \\INSERT INTO releases(id, title, album_artist, album_artist_id) VALUES (1, 'Ágætis byrjun', 'Sigur Rós', 1);
        \\INSERT INTO recordings(id, title) VALUES (1, 'Starálfur');
        \\INSERT INTO tracks(id, recording_id, release_id, title, artist, album, artist_id)
        \\    VALUES (1, 1, 1, 'Starálfur', 'Sigur Rós', 'Ágætis byrjun', 1);
        \\INSERT INTO playlists(id, name, description, created_at, updated_at) VALUES (1, 'Morning', 'Quiet', 0, 0);
        \\INSERT INTO genres(id, name, key) VALUES (1, 'Post-Rock', 'post rock');
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 5), try scalar(db, "SELECT count(*) FROM search_index;"));
    try std.testing.expectEqual(@as(i64, 5), try scalar(db,
        \\SELECT count(*) FROM search_index WHERE rowid = entity_id * 8 + kind AND
        \\    ((kind = 0 AND entity_id = 1 AND title = 'Sigur Rós' AND subtitle = '') OR
        \\     (kind = 0 AND entity_id = 2 AND title = 'Aminé' AND subtitle = '') OR
        \\     (kind = 1 AND title = 'Ágætis byrjun' AND subtitle = 'Sigur Rós') OR
        \\     (kind = 3 AND title = 'Morning' AND subtitle = 'Quiet') OR
        \\     (kind = 4 AND title = 'Post-Rock' AND subtitle = ''));
    ));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM search_index WHERE search_index MATCH '\"sigur\"* AND \"ros\"*';"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT entity_id FROM search_index WHERE search_index MATCH '\"amin\"*';"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT rowid FROM track_search WHERE track_search MATCH '\"staralfur\"';"));
    try db.exec("INSERT INTO search_index(search_index, rank) VALUES ('integrity-check', 0);");
    try checkForeignKeys(db);
}

test "a version-36 library keeps its artist info and gains an empty related artist photo table keyed by MusicBrainz artist ID, whose details need a photo" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v36.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 36);
    try db.exec(
        \\INSERT INTO artists(id, name, sort_name, key) VALUES (1, 'Aminé', 'Aminé', 'amine');
        \\INSERT INTO artist_info(artist_id, musicbrainz_artist_id, photo, photo_mime, fetched_at, outcome)
        \\    VALUES (1, 'c6b2b5ab-c4c6-4bd5-8d3c-e1b0a1e4c8a1', x'89504e47', 'image/png', 100, 1);
        \\INSERT INTO artist_related(artist_id, ordinal, related_mbid, related_name, score)
        \\    VALUES (1, 0, 'a0b1c2d3-e4f5-4a6b-8c7d-9e0f1a2b3c4d', 'Smino', 412);
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM artist_info WHERE photo = x'89504e47';"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM artist_related;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM related_artist_photos;"));
    try db.exec(
        \\INSERT INTO related_artist_photos VALUES ('A0B1C2D3-E4F5-4A6B-8C7D-9E0F1A2B3C4D', x'ffd8ff', 'image/jpeg',
        \\    1, 'https://commons.wikimedia.org/wiki/File:Smino.jpg', 'CC BY 2.0', 'https://creativecommons.org/licenses/by/2.0',
        \\    'A. Photographer', 200);
        \\INSERT INTO related_artist_photos VALUES ('b0b1c2d3-e4f5-4a6b-8c7d-9e0f1a2b3c4d', NULL, NULL, NULL, NULL, NULL, NULL, NULL, 200);
    );
    try std.testing.expectEqual(@as(i64, 1), try scalar(db,
        \\SELECT count(*) FROM related_artist_photos WHERE photo_licence = 'CC BY 2.0' AND photo_credit = 'A. Photographer';
    ));
    try std.testing.expectEqual(@as(i64, 200), try scalar(db,
        \\SELECT fetched_at FROM related_artist_photos WHERE musicbrainz_artist_id = 'a0b1c2d3-e4f5-4a6b-8c7d-9e0f1a2b3c4d';
    ));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO related_artist_photos VALUES ('a0b1c2d3-e4f5-4a6b-8c7d-9e0f1a2b3c4d', NULL, NULL, NULL, NULL, NULL, NULL, NULL, 300);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO related_artist_photos VALUES ('c', x'ff', NULL, 1, NULL, NULL, NULL, NULL, 300);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO related_artist_photos VALUES ('d', NULL, 'image/png', NULL, NULL, NULL, NULL, NULL, 300);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO related_artist_photos VALUES ('e', x'ff', 'image/png', NULL, NULL, NULL, NULL, NULL, 300);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO related_artist_photos VALUES ('f', NULL, NULL, NULL, NULL, NULL, NULL, 'A. Photographer', 300);"));
    try checkForeignKeys(db);
}

test "a version-37 library keeps its analysis results and gains an index that finds the latest by creation time" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v37.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 37);
    try db.exec(
        \\INSERT INTO files(id, size_bytes) VALUES (1, 100);
        \\INSERT INTO analysis_results(file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity, result, created_at)
        \\VALUES (1, 1, 'orca.diagnostics', 1, x'00', x'01', x'0a0b', 1700000000),
        \\       (1, 2, 'orca.temporal-fingerprint', 2, x'00', x'01', x'0c', 1700000300);
    );
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM sqlite_schema WHERE name = 'analysis_results_created';"));

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM analysis_results;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM analysis_results WHERE kind = 1 AND result = x'0a0b';"));
    try std.testing.expectEqual(@as(i64, 1700000300), try scalar(db, "SELECT max(created_at) FROM analysis_results;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db,
        \\SELECT count(*) FROM sqlite_schema
        \\WHERE type = 'index' AND name = 'analysis_results_created' AND tbl_name = 'analysis_results';
    ));
    try checkForeignKeys(db);
}

test "a version-39 library gains the loudness of each file's current default diagnostics, read from the stored result" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v39.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 39);
    try db.exec(
        \\INSERT INTO files(id, size_bytes, quick_hash) VALUES
        \\    (1, 100, x'01'), (2, 100, x'02'), (3, 100, x'03'), (4, 100, x'04'), (5, 100, x'05'), (6, 100, x'06');
        \\INSERT INTO analysis_results(file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity, result) VALUES
        \\    (1, 1, 'orca.audio-diagnostics', 4, x'A5D7A479D64C3952CA86E311AFFEBB0CFCA41DAF406C7AA159255961CF9145CE', x'01',
        \\        CAST(x'4F5241440200' || x'0100' || x'D7A334C1' || zeroblob(60) AS BLOB)),
        \\    (2, 1, 'orca.audio-diagnostics', 4, x'A5D7A479D64C3952CA86E311AFFEBB0CFCA41DAF406C7AA159255961CF9145CE', x'02',
        \\        CAST(x'4F5241440200' || x'0000' || x'D7A334C1' || zeroblob(60) AS BLOB)),
        \\    (3, 1, 'orca.audio-diagnostics', 4, x'A5D7A479D64C3952CA86E311AFFEBB0CFCA41DAF406C7AA159255961CF9145CE', x'ff',
        \\        CAST(x'4F5241440200' || x'0100' || x'D7A334C1' || zeroblob(60) AS BLOB)),
        \\    (4, 1, 'orca.audio-diagnostics', 4, x'00', x'04',
        \\        CAST(x'4F5241440200' || x'0100' || x'D7A334C1' || zeroblob(60) AS BLOB)),
        \\    (5, 1, 'orca.audio-diagnostics', 3, x'A5D7A479D64C3952CA86E311AFFEBB0CFCA41DAF406C7AA159255961CF9145CE', x'05',
        \\        CAST(x'4F5241440200' || x'0100' || x'D7A334C1' || zeroblob(60) AS BLOB)),
        \\    (6, 1, 'orca.audio-diagnostics', 4, x'A5D7A479D64C3952CA86E311AFFEBB0CFCA41DAF406C7AA159255961CF9145CE', x'06',
        \\        CAST(x'4F5241440200' || x'0100' || x'00008CC2' || zeroblob(60) AS BLOB));
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM file_loudness;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db,
        \\SELECT count(*) FROM file_loudness
        \\WHERE file_id = 1 AND source_identity = x'01' AND abs(integrated_lufs - -11.29) < 0.000001;
    ));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM file_loudness WHERE file_id = 6 AND integrated_lufs = -70.0;"));
    try checkForeignKeys(db);
}

test "a diagnostics result written, rewritten or removed keeps the file's loudness equal to its float, sign and exponent included" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "loudness.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try apply(db);
    try db.exec(
        \\INSERT INTO files(id, size_bytes, quick_hash) VALUES (1, 100, x'01'), (2, 100, x'02'), (3, 100, x'03'), (4, 100, x'04');
        \\INSERT INTO analysis_results(file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity, result) VALUES
        \\    (1, 1, 'orca.audio-diagnostics', 4, x'A5D7A479D64C3952CA86E311AFFEBB0CFCA41DAF406C7AA159255961CF9145CE', x'01',
        \\        CAST(x'4F5241440200' || x'0100' || x'000080BE' || zeroblob(60) AS BLOB)),
        \\    (2, 1, 'orca.audio-diagnostics', 4, x'A5D7A479D64C3952CA86E311AFFEBB0CFCA41DAF406C7AA159255961CF9145CE', x'02',
        \\        CAST(x'4F5241440200' || x'0100' || x'00006040' || zeroblob(60) AS BLOB)),
        \\    (3, 1, 'orca.audio-diagnostics', 4, x'A5D7A479D64C3952CA86E311AFFEBB0CFCA41DAF406C7AA159255961CF9145CE', x'03',
        \\        CAST(x'4F5241440200' || x'0100' || x'00000000' || zeroblob(60) AS BLOB)),
        \\    (4, 1, 'orca.audio-diagnostics', 4, x'A5D7A479D64C3952CA86E311AFFEBB0CFCA41DAF406C7AA159255961CF9145CE', x'04',
        \\        CAST(x'4F5241440200' || x'0100' || x'0000B8C1' || zeroblob(60) AS BLOB));
    );
    try std.testing.expectEqual(@as(i64, 4), try scalar(db,
        \\SELECT count(*) FROM file_loudness WHERE (file_id, integrated_lufs) IN
        \\    (VALUES (1, -0.25), (2, 3.5), (3, 0.0), (4, -23.0));
    ));

    try db.exec(
        \\INSERT INTO analysis_results(file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity, result) VALUES
        \\    (1, 1, 'orca.audio-diagnostics', 4, x'A5D7A479D64C3952CA86E311AFFEBB0CFCA41DAF406C7AA159255961CF9145CE', x'01',
        \\        CAST(x'4F5241440200' || x'0100' || x'00008CC2' || zeroblob(60) AS BLOB))
        \\ON CONFLICT DO UPDATE SET result = excluded.result;
        \\INSERT INTO analysis_results(file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity, result) VALUES
        \\    (2, 1, 'orca.audio-diagnostics', 4, x'A5D7A479D64C3952CA86E311AFFEBB0CFCA41DAF406C7AA159255961CF9145CE', x'2b',
        \\        CAST(x'4F5241440200' || x'0000' || x'00006040' || zeroblob(60) AS BLOB));
        \\DELETE FROM analysis_results WHERE file_id = 3;
        \\DELETE FROM analysis_results WHERE file_id = 4 AND source_identity = x'ff';
    );
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM file_loudness WHERE file_id = 1 AND integrated_lufs = -70.0;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM file_loudness WHERE file_id IN (2, 3);"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM file_loudness WHERE file_id = 4 AND integrated_lufs = -23.0;"));
    try db.exec("DELETE FROM analysis_results WHERE file_id = 4; DELETE FROM files WHERE id = 4;");
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM file_loudness;"));
    try db.exec("DELETE FROM analysis_results WHERE file_id = 1; DELETE FROM files WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM file_loudness;"));
}

const search_index_drift_sql =
    \\WITH source(rowid, kind, entity_id, title, subtitle) AS (
    \\    SELECT id * 8 + 0, 0, id, name, '' FROM artists
    \\    UNION ALL SELECT id * 8 + 1, 1, id, title, album_artist FROM releases
    \\    UNION ALL SELECT id * 8 + 3, 3, id, name, description FROM playlists
    \\    UNION ALL SELECT id * 8 + 4, 4, id, name, '' FROM genres
    \\), indexed AS (SELECT rowid, kind, entity_id, title, subtitle FROM search_index)
    \\SELECT (SELECT count(*) FROM (SELECT * FROM indexed EXCEPT SELECT * FROM source))
    \\     + (SELECT count(*) FROM (SELECT * FROM source EXCEPT SELECT * FROM indexed));
;

const track_index_changes_sql =
    \\SELECT (SELECT count(*) FROM (SELECT id, block FROM track_search_data EXCEPT SELECT id, block FROM indexed_blocks))
    \\     + (SELECT count(*) FROM (SELECT id, block FROM indexed_blocks EXCEPT SELECT id, block FROM track_search_data));
;

test "a version-37 library moves its Tracks from search_index to track_search, which reindexes a Track only when its text changes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v37-search.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 37);
    try db.exec(
        \\INSERT INTO artists(id, name, sort_name, key) VALUES (1, 'Sigur Rós', 'Sigur Rós', 'sigur ros');
        \\INSERT INTO releases(id, title, album_artist, album_artist_id) VALUES (1, 'Ágætis byrjun', 'Sigur Rós', 1);
        \\INSERT INTO tracks(id, release_id, title, artist, album, album_artist, artist_id) VALUES
        \\    (1, 1, 'Starálfur', 'Sigur Rós', 'Ágætis byrjun', 'Sigur Rós', 1),
        \\    (2, 1, 'Svefn-g-englar', 'Sigur Rós', 'Ágætis byrjun', 'Sigur Rós', 1);
        \\INSERT INTO playlists(id, name, description, created_at, updated_at) VALUES (1, 'Morning', 'Quiet', 0, 0);
        \\INSERT INTO genres(id, name, key) VALUES (1, 'Post-Rock', 'post rock');
    );
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM search_index WHERE kind = 2;"));

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM search_index WHERE kind = 2;"));
    try std.testing.expectEqual(@as(i64, 4), try scalar(db, "SELECT count(*) FROM search_index;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM sqlite_schema WHERE name LIKE 'tracks\\_search\\_%' ESCAPE '\\';"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, search_index_drift_sql));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM search_index WHERE search_index MATCH '\"staralfur\"';"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT rowid FROM track_search WHERE track_search MATCH '{title}: \"staralfur\"';"));
    try db.exec("INSERT INTO search_index(search_index, rank) VALUES ('integrity-check', 1);");
    try db.exec("INSERT INTO track_search(track_search, rank) VALUES ('integrity-check', 1);");

    try db.exec(
        \\CREATE TEMP TABLE indexed_blocks AS SELECT id, block FROM track_search_data;
        \\UPDATE tracks SET duration_ms = 1000, explicit = 1, title = title, album_artist = album_artist WHERE id = 1;
    );
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, track_index_changes_sql));
    try db.exec("UPDATE tracks SET title = 'Olsen Olsen' WHERE id = 1;");
    try std.testing.expect(try scalar(db, track_index_changes_sql) > 0);
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM track_search WHERE track_search MATCH '\"staralfur\"';"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT rowid FROM track_search WHERE track_search MATCH '\"olsen\"';"));
    try db.exec(
        \\UPDATE artists SET name = 'Jónsi' WHERE id = 1;
        \\DELETE FROM tracks WHERE id = 2;
        \\INSERT INTO track_search(track_search, rank) VALUES ('integrity-check', 1);
    );
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, search_index_drift_sql));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM search_index WHERE kind = 2;"));
    try checkForeignKeys(db);
}

test "a version-37 library gains genre totals equal to a count over its Tracks, which every later write keeps equal" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v37-genres.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 37);
    try db.exec(
        \\INSERT INTO artists(id, name, sort_name, key) VALUES
        \\    (1, 'Band', 'Band', 'band'), (2, 'Guest', 'Guest', 'guest'), (3, 'Other', 'Other', 'other');
        \\INSERT INTO releases(id, title, album_artist, album_artist_id) VALUES
        \\    (1, 'First', 'Band', 1), (2, 'Second', 'Other', 3), (3, 'Untitled', '', NULL);
        \\INSERT INTO tracks(id, release_id, title, artist_id, duration_ms) VALUES
        \\    (1, 1, 'a', 1, 1000), (2, 1, 'b', 2, 2000), (3, 2, 'c', 3, NULL), (4, NULL, 'd', 2, 4000),
        \\    (5, 3, 'e', NULL, 500);
        \\INSERT INTO genres(id, name, key) VALUES (1, 'Rock', 'rock'), (2, 'Jazz', 'jazz'), (3, 'Unused', 'unused');
        \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance) VALUES
        \\    (1, 1, 0, 0), (2, 1, 0, 0), (2, 2, 1, 0), (3, 2, 0, 0), (4, 1, 0, 0), (5, 2, 0, 0);
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, genre_totals_drift_sql));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM genre_totals;"));
    try std.testing.expectEqual(@as(i64, 3), try scalar(db, "SELECT track_count FROM genre_totals WHERE genre_id = 1;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT release_count FROM genre_totals WHERE genre_id = 1;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT artist_count FROM genre_totals WHERE genre_id = 1;"));
    try std.testing.expectEqual(@as(i64, 7000), try scalar(db, "SELECT duration_ms FROM genre_totals WHERE genre_id = 1;"));
    try std.testing.expectEqual(@as(i64, 3), try scalar(db, "SELECT release_count FROM genre_totals WHERE genre_id = 2;"));
    try std.testing.expectEqual(@as(i64, 3), try scalar(db, "SELECT artist_count FROM genre_totals WHERE genre_id = 2;"));
    try std.testing.expectEqual(@as(i64, 2500), try scalar(db, "SELECT duration_ms FROM genre_totals WHERE genre_id = 2;"));

    const steps = [_][:0]const u8{
        "UPDATE tracks SET duration_ms = 3000 WHERE id = 3;",
        "UPDATE tracks SET artist_id = 3 WHERE id = 1;",
        "UPDATE tracks SET release_id = 2 WHERE id = 4;",
        "UPDATE tracks SET release_id = NULL, artist_id = NULL WHERE id = 2;",
        "UPDATE releases SET album_artist_id = 2 WHERE id = 1;",
        "UPDATE releases SET album_artist_id = NULL WHERE id = 2;",
        "UPDATE track_genres SET genre_id = 3 WHERE track_id = 5;",
        "INSERT INTO track_genres(track_id, genre_id, ordinal, provenance) VALUES (1, 2, 1, 0);",
        "DELETE FROM track_genres WHERE track_id = 3;",
        "DELETE FROM tracks WHERE id = 1;",
        "DELETE FROM genres WHERE id = 3;",
    };
    for (steps) |step| {
        try db.exec(step);
        try std.testing.expectEqual(@as(i64, 0), try scalar(db, genre_totals_drift_sql));
    }
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM genre_totals WHERE genre_id = 3;"));
    try db.exec("DELETE FROM track_genres;");
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM genre_totals;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM genre_release_tracks;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM genre_artist_refs;"));
    try checkForeignKeys(db);
}

test "a version-43 library gains release group covers, which go when the last Artist credited with their group lets it go" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v43-covers.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 43);
    try db.exec(
        \\INSERT INTO artists(id, name, sort_name, key) VALUES (1, 'Host', 'Host', 'host'), (2, 'Guest', 'Guest', 'guest');
        \\INSERT INTO artist_release_groups(artist_id, mbid, title, position) VALUES
        \\    (1, 'shared', 'Together', 0), (2, 'shared', 'Together', 0), (1, 'own', 'Alone', 1);
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try db.exec(
        \\INSERT INTO release_group_covers(mbid, image, mime, fetched_at) VALUES
        \\    ('shared', X'FFD8FF', 'image/jpeg', 1), ('own', NULL, NULL, 1);
    );
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO release_group_covers(mbid, image, fetched_at) VALUES ('x', X'00', 1);"));
    try db.exec("DELETE FROM artist_release_groups WHERE artist_id = 1;");
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM release_group_covers WHERE mbid = 'shared';"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM release_group_covers WHERE mbid = 'own';"));
    try db.exec("DELETE FROM artist_release_groups WHERE artist_id = 2;");
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM release_group_covers;"));
}

test "a version-44 library gains empty folder image and folder scan tables, which go with their root" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v44-folders.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 44);
    try db.exec(
        \\INSERT INTO volumes(id, stable_key) VALUES (2, 'music');
        \\INSERT INTO library_roots(id, volume_id, path) VALUES (1, 2, '/m');
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM folder_images;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM folder_scans;"));
    try db.exec(
        \\INSERT INTO folder_images(volume_id, root_id, uri, mime, role, size_bytes, modified_ns) VALUES
        \\    (2, 1, '/m/A/cover.jpg', 'image/jpeg', 0, 10, 1);
        \\INSERT INTO folder_scans(root_id, relative_path, scanned_at) VALUES (1, 'A', 5), (1, '', 5);
    );
    try std.testing.expectError(error.SqlFailed, db.exec(
        "INSERT INTO folder_images(volume_id, root_id, uri, mime, role, size_bytes, modified_ns) VALUES (2, 1, '/m/x.png', 'image/png', 4, 1, 1);",
    ));
    try db.exec("DELETE FROM library_roots WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM folder_images;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM folder_scans;"));
}

test "a version-45 library records which Releases have a front image in the folder holding most of their Tracks" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v45-folder-covers.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 45);
    try db.exec(
        \\INSERT INTO volumes(id, stable_key) VALUES (2, 'music');
        \\INSERT INTO library_roots(id, volume_id, path) VALUES (1, 2, '/m');
        \\INSERT INTO releases(id, title) VALUES (1, 'Covered'), (2, 'Back only'), (3, 'Gone');
        \\INSERT INTO files(id, size_bytes, quick_hash) VALUES (1, 1, x'01'), (2, 1, x'02'), (3, 1, x'03');
        \\INSERT INTO tracks(id, release_id, title, preferred_file_id) VALUES (1, 1, 'a', 1), (2, 2, 'b', 2), (3, 3, 'c', 3);
        \\INSERT INTO locations(file_id, volume_id, root_id, uri, state) VALUES
        \\    (1, 2, 1, '/m/A/1.flac', 'present'), (2, 2, 1, '/m/B/1.flac', 'present'), (3, 2, 1, '/m/C/1.flac', 'missing');
        \\INSERT INTO folder_images(volume_id, root_id, uri, mime, role, size_bytes, modified_ns) VALUES
        \\    (2, 1, '/m/A/cover.jpg', 'image/jpeg', 0, 10, 1),
        \\    (2, 1, '/m/B/back.jpg', 'image/jpeg', 1, 10, 1),
        \\    (2, 1, '/m/C/cover.jpg', 'image/jpeg', 0, 10, 1);
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT has_folder_cover FROM releases WHERE id = 1;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM releases WHERE has_folder_cover = 1;"));
}

test "a version-47 library keeps its listens, each marked syncable, and a new listen may be stored as local only" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v47-listens.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 47);
    try db.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'One');
        \\INSERT INTO files(id, audio_format, size_bytes, recording_id) VALUES (1, 1, 10, 1);
        \\INSERT INTO listens(file_id, recording_id, started_at, listened_ms, title, artist)
        \\VALUES (1, 1, 1700000000, 90000, 'One', 'Artist');
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT syncable FROM listens;"));
    try db.exec(
        \\INSERT INTO listens(file_id, recording_id, started_at, listened_ms, title, artist, syncable)
        \\VALUES (1, 1, 1700000100, 31000, 'One', 'Artist', 0);
    );
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM listens WHERE syncable = 0;"));
}

test "a version-48 library keeps its duplicate issues, each with no stored similarity" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v48-similarity.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 48);
    try db.exec(
        \\INSERT INTO files(id, audio_format, size_bytes) VALUES (1, 1, 10), (2, 1, 10);
        \\INSERT INTO library_health_issues(file_id, kind, severity, details, related_file_id, updated_at)
        \\VALUES (1, 10, 0, 'audio resembles b (99.0% match)', 2, 0);
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM library_health_issues WHERE similarity IS NULL;"));
    try db.exec("UPDATE library_health_issues SET similarity = 0.99;");
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM library_health_issues WHERE similarity IS NULL;"));
}

test "a version-49 library gains an empty observed comment and re-observes every present file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v49-comment.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 49);
    try db.exec(
        \\INSERT INTO files(id, audio_format, size_bytes) VALUES (1, 1, 10), (2, 1, 10);
        \\INSERT INTO locations(file_id, volume_id, uri, native_inode, size_bytes, modified_ns, state) VALUES
        \\    (1, 1, '/m/song.flac', 11, 10, 500, 'present'),
        \\    (2, 1, '/m/gone.flac', 12, 10, 500, 'missing');
        \\INSERT INTO observed_file_tags(file_id, title, composer) VALUES (1, 'Song', 'Nick Drake');
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM observed_file_tags WHERE comment IS NULL AND composer = 'Nick Drake';"));
    try std.testing.expectEqual(@as(i64, -1), try scalar(db, "SELECT modified_ns FROM locations WHERE file_id = 1;"));
    try std.testing.expectEqual(@as(i64, 500), try scalar(db, "SELECT modified_ns FROM locations WHERE file_id = 2;"));
    try db.exec("UPDATE observed_file_tags SET comment = 'Ripped from vinyl';");
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM observed_file_tags WHERE comment = 'Ripped from vinyl';"));
    try checkForeignKeys(db);
}

test "a version-50 library keeps every fetched cover byte for byte as a fetched front" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v50-artwork.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 50);
    try db.exec(
        \\INSERT INTO releases(id, title, release_key) VALUES (1, 'One', 'one'), (2, 'Two', 'two'), (3, 'Three', 'three');
        \\INSERT INTO release_artwork(release_id, musicbrainz_release_id, image, mime, fetched_at) VALUES
        \\    (1, '2e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b', X'FFD8FFE000104A464946000100FFD9', 'image/jpeg', 1800000000),
        \\    (2, '3e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b', X'89504E470D0A1A0A0000000D49484452', 'image/png', 1800000001),
        \\    (3, '4e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b', NULL, NULL, 1800000002);
        \\INSERT INTO files(id, audio_format, size_bytes) VALUES (1, 1, 10), (2, 1, 10);
        \\INSERT INTO observed_file_tags(file_id, title, artwork_mime_type, artwork_byte_size, artwork_kind) VALUES
        \\    (1, 'Covered', 'image/jpeg', 2048, 0),
        \\    (2, 'Bare', NULL, NULL, NULL);
        \\INSERT INTO folder_images(volume_id, root_id, uri, mime, role, size_bytes, modified_ns, last_seen_generation)
        \\VALUES (1, NULL, '/m/a/cover.jpg', 'image/jpeg', 1, 4096, 7, 1);
    );
    const rows_sql = "SELECT group_concat(release_id || ':' || musicbrainz_release_id || ':' || " ++
        "COALESCE(hex(image), 'null') || ':' || COALESCE(mime, 'null') || ':' || fetched_at, ' ') " ++
        "FROM (SELECT * FROM release_artwork ORDER BY release_id);";
    const before = try text(std.testing.allocator, db, rows_sql);
    defer std.testing.allocator.free(before);

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    const after = try text(std.testing.allocator, db, rows_sql);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqual(@as(i64, 3), try scalar(db, "SELECT count(*) FROM release_artwork;"));
    try std.testing.expectEqual(@as(i64, 3), try scalar(db, "SELECT count(*) FROM release_artwork WHERE kind = 0 AND source = 2 AND width IS NULL AND height IS NULL;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM release_artwork WHERE image IS NULL;"));

    try db.exec(
        \\INSERT INTO release_artwork(release_id, kind, source, image, mime, width, height, fetched_at)
        \\VALUES (1, 1, 3, X'FFD8FF', 'image/jpeg', 1400, 1400, 1800000003);
        \\INSERT INTO cover_art_candidates(release_id, caa_id, musicbrainz_release_id, kind, width, height, mime, approved, thumbnail, fetched_at)
        \\VALUES (1, 1234, 'mbid', 0, 1200, 1200, 'image/jpeg', 1, X'FFD8FF', 1800000004);
    );
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM release_artwork WHERE release_id = 1;"));
    try std.testing.expectError(error.SqlFailed, db.exec(
        "INSERT INTO release_artwork(release_id, kind, source, fetched_at) VALUES (1, 0, 3, 0);",
    ));
    try db.exec("DELETE FROM releases WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM release_artwork WHERE release_id = 1;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM cover_art_candidates;"));

    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM observed_file_tags WHERE artwork_byte_size > 0 AND artwork_hash IS NULL;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM folder_images WHERE hash IS NULL;"));
    try std.testing.expectEqual(@as(i64, 7), try scalar(db, "SELECT modified_ns FROM folder_images;"));
    try checkForeignKeys(db);
}

test "a version-51 library keeps its releases and gains release candidate dismissals that go with their release" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v51-dismissals.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 51);
    try db.exec(
        \\INSERT INTO releases(id, title, album_artist, release_date, release_key, musicbrainz_release_id) VALUES
        \\    (1, 'ONEPOINTFIVE', 'Amine', '2018', 'one', '2e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b'),
        \\    (2, 'Limbo', 'Amine', '2020', 'two', NULL);
        \\INSERT INTO files(id, audio_format, size_bytes) VALUES (1, 1, 10);
        \\INSERT INTO identification_proposals(file_id, provider, provider_id, confidence, payload, state, updated_at)
        \\VALUES (1, 'musicbrainz', '3e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b', 0.9, X'7B7D', 0, 1);
    );
    const rows_sql = "SELECT group_concat(id || ':' || title || ':' || album_artist || ':' || COALESCE(release_date, '-') || ':' || " ++
        "COALESCE(musicbrainz_release_id, '-'), ' ') FROM (SELECT * FROM releases ORDER BY id);";
    const before = try text(std.testing.allocator, db, rows_sql);
    defer std.testing.allocator.free(before);

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    const after = try text(std.testing.allocator, db, rows_sql);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM identification_proposals WHERE state = 0;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM dismissed_release_candidates;"));

    try db.exec(
        \\INSERT INTO dismissed_release_candidates(release_id, musicbrainz_release_id, dismissed_at)
        \\VALUES (1, '4e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b', 1800000000), (2, '4e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b', 1800000000);
    );
    try std.testing.expectError(error.SqlFailed, db.exec(
        "INSERT INTO dismissed_release_candidates(release_id, musicbrainz_release_id, dismissed_at) VALUES (1, '4e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b', 0);",
    ));
    try db.exec("DELETE FROM releases WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM dismissed_release_candidates;"));
    try checkForeignKeys(db);
}

test "a version-52 library keeps its tracks and gains an empty saved queue and positions that go with their track" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v52-player-state.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 52);
    try db.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'One');
        \\INSERT INTO releases(id, title, release_key) VALUES (1, 'Mix', 'mix');
        \\INSERT INTO tracks(id, release_id, title, recording_id) VALUES (1, 1, 'One', 1), (2, 1, 'Two', NULL);
    );
    const rows_sql = "SELECT group_concat(id || ':' || title || ':' || COALESCE(recording_id, '-'), ' ') FROM (SELECT * FROM tracks ORDER BY id);";
    const before = try text(std.testing.allocator, db, rows_sql);
    defer std.testing.allocator.free(before);

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    const after = try text(std.testing.allocator, db, rows_sql);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM player_state;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM player_queue_entries;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM track_positions;"));

    try db.exec(
        \\INSERT INTO player_state(id, cursor, position_ms, repeat, shuffle, saved_at) VALUES (1, 1, 5000, 2, 1, 1800000000);
        \\INSERT INTO player_queue_entries(position, entry, track_id, recording_id) VALUES (0, 1, 2, NULL), (1, 0, 1, 1);
        \\INSERT INTO track_positions(track_id, position_ms, updated_at) VALUES (1, 1500000, 1800000000), (2, 1300000, 1800000000);
    );
    try std.testing.expectError(error.SqlFailed, db.exec(
        "INSERT INTO player_state(id, cursor, position_ms, repeat, shuffle, saved_at) VALUES (2, 0, 0, 0, 0, 0);",
    ));
    try std.testing.expectError(error.SqlFailed, db.exec(
        "INSERT INTO player_queue_entries(position, entry, track_id) VALUES (10000, 0, 1);",
    ));
    try std.testing.expectError(error.SqlFailed, db.exec(
        "INSERT INTO track_positions(track_id, position_ms, updated_at) VALUES (99, 1000, 0);",
    ));
    try db.exec("DELETE FROM tracks WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT track_id FROM track_positions;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM player_queue_entries;"));
    try checkForeignKeys(db);
}

test "a version-53 library keeps its releases and gains metadata proposals that go with their release and track" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v53-metadata-proposals.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 53);
    try db.exec(
        \\INSERT INTO releases(id, title, album_artist, release_key) VALUES (1, 'Blonde', 'Frank Ocean', 'blonde'), (2, 'Endless', 'Frank Ocean', 'endless');
        \\INSERT INTO tracks(id, release_id, title) VALUES (1, 1, 'Nikes'), (2, 2, 'Device Control');
    );
    const rows_sql = "SELECT group_concat(id || ':' || title || ':' || album_artist, ' ') FROM (SELECT * FROM releases ORDER BY id);";
    const before = try text(std.testing.allocator, db, rows_sql);
    defer std.testing.allocator.free(before);

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    const after = try text(std.testing.allocator, db, rows_sql);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM metadata_proposals;"));

    try db.exec(
        \\INSERT INTO metadata_proposals(id, group_id, release_id, category, field, fingerprint, created_at) VALUES (1, 1, 1, 0, 'album_artist', 7, 1800000000);
        \\INSERT INTO metadata_proposals(group_id, release_id, category, field, proposed, reason, option, fingerprint, created_at)
        \\VALUES (1, 1, 0, 'album_artist', 'Frank Ocean', '1 track', 0, 7, 1800000000);
        \\INSERT INTO metadata_proposals(group_id, release_id, category, field, track_id, current, proposed, fingerprint, created_at)
        \\VALUES (1, 1, 0, 'album_artist', 1, 'frank ocean', 'Frank Ocean', 7, 1800000000);
        \\INSERT INTO metadata_proposals(id, group_id, release_id, category, field, fingerprint, created_at) VALUES (4, 4, 2, 1, 'date', 9, 1800000000);
    );
    try std.testing.expectError(error.SqlFailed, db.exec(
        "INSERT INTO metadata_proposals(release_id, category, field, fingerprint, created_at) VALUES (1, 5, 'x', 0, 0);",
    ));
    try std.testing.expectError(error.SqlFailed, db.exec(
        "INSERT INTO metadata_proposals(release_id, category, field, state, fingerprint, created_at) VALUES (1, 0, 'x', 3, 0, 0);",
    ));
    try db.exec("DELETE FROM tracks WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 3), try scalar(db, "SELECT count(*) FROM metadata_proposals;"));
    try db.exec("DELETE FROM tracks WHERE id = 2; DELETE FROM releases WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 4), try scalar(db, "SELECT id FROM metadata_proposals;"));
    try checkForeignKeys(db);
}

test "a version-54 library keeps its metadata issues and gains option track counts and numbering gaps" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v54-metadata-proposal-counts.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 54);
    try db.exec(
        \\INSERT INTO releases(id, title, album_artist, release_key) VALUES (1, 'Room 25', 'Noname', 'room 25');
        \\INSERT INTO metadata_proposals(id, group_id, release_id, category, field, fingerprint, created_at) VALUES (1, 1, 1, 2, 'track_number', 7, 1800000000);
        \\INSERT INTO metadata_proposals(group_id, release_id, category, field, proposed, reason, option, fingerprint, created_at)
        \\VALUES (1, 1, 2, 'track_number', 'Next free numbers', '1 track renumbered', 0, 7, 1800000000);
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM metadata_proposals WHERE tracks IS NULL AND gap IS NULL;"));
    try db.exec("UPDATE metadata_proposals SET gap = 6 WHERE id = 1; UPDATE metadata_proposals SET tracks = 1 WHERE id = 2;");
    try std.testing.expectEqual(@as(i64, 7), try scalar(db, "SELECT sum(COALESCE(gap, 0) + COALESCE(tracks, 0)) FROM metadata_proposals;"));
    try std.testing.expectError(error.SqlFailed, db.exec("UPDATE metadata_proposals SET gap = 0 WHERE id = 1;"));
    try std.testing.expectError(error.SqlFailed, db.exec("UPDATE metadata_proposals SET tracks = -1 WHERE id = 2;"));
    try checkForeignKeys(db);
}

test "a version-55 library keeps its journal and files and gains content hash columns" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v55-content-hash.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 55);
    try db.exec(
        \\INSERT INTO files(id, audio_format, size_bytes, quick_hash) VALUES (1, 1, 10, zeroblob(32));
        \\INSERT INTO mutation_operations(id, plan_id, group_id, action_index, kind, source_path, expected_size, expected_modified_ns, state, expected_quick_hash, committed_quick_hash)
        \\VALUES (1, 1, 1, 0, 0, '/m/a.flac', 10, 1, 2, zeroblob(32), zeroblob(32));
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db,
        \\SELECT count(*) FROM mutation_operations
        \\WHERE expected_content_hash IS NULL AND committed_content_hash IS NULL
        \\  AND length(expected_quick_hash) = 32 AND state = 2;
    ));
    try std.testing.expectEqual(@as(i64, 1), try scalar(
        db,
        "SELECT count(*) FROM files WHERE content_hash IS NULL AND content_hash_algorithm IS NULL AND size_bytes = 10;",
    ));
    try std.testing.expectEqual(@as(i64, 1), try scalar(
        db,
        "SELECT count(*) FROM sqlite_schema WHERE type = 'index' AND name = 'files_content_hash' AND tbl_name = 'files';",
    ));
    try checkForeignKeys(db);
}

test "a version-56 library drops every audio hash, which had no tier, and gains a tier column" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(std.testing.allocator, &temporary.sub_path, "v56-audio-hash-tier.db");
    defer std.testing.allocator.free(path);
    const db = try sqlite.Database.open(path);
    defer db.close();
    try applyThrough(db, 56);
    try db.exec(
        \\INSERT INTO files(id, audio_format, size_bytes, quick_hash, audio_hash) VALUES
        \\    (1, 1, 10, X'01', X'AA'),
        \\    (2, 1, 10, X'02', NULL);
    );

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM files WHERE audio_hash IS NULL AND audio_hash_tier IS NULL;"));
    try db.exec("UPDATE files SET audio_hash = X'BB', audio_hash_tier = 1 WHERE id = 1;");
    try db.exec("UPDATE files SET audio_hash = X'CC', audio_hash_tier = 2 WHERE id = 2;");
    try std.testing.expectError(error.SqlFailed, db.exec("UPDATE files SET audio_hash_tier = 3 WHERE id = 1;"));
    try checkForeignKeys(db);
}
