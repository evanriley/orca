-- Orca version-7 library fixture.
--
-- Regenerate the binary fixture from this script:
--
--     rm -f fixtures/database/v7-library.db
--     sqlite3 fixtures/database/v7-library.db < fixtures/database/v7-library.sql
--
-- The schema below is exactly what migrations 1-7 in
-- `liborca/database/migrations.zig` produce; the migration test asserts that,
-- so drift between the two fails the build rather than silently weakening the
-- coverage. The data deliberately includes an analysis row and a health issue
-- for paths no scan ever observed, because migration 8 must preserve those by
-- synthesizing `unverified` file and location rows rather than dropping them.

CREATE TABLE artists (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    sort_name TEXT
);
CREATE INDEX artists_name ON artists(name COLLATE NOCASE);
CREATE TABLE releases (
    id INTEGER PRIMARY KEY,
    title TEXT NOT NULL,
    album_artist TEXT NOT NULL DEFAULT '',
    release_date TEXT
);
CREATE INDEX releases_title ON releases(title COLLATE NOCASE);
CREATE TABLE recordings (
    id INTEGER PRIMARY KEY,
    title TEXT NOT NULL,
    duration_ms INTEGER
);
CREATE TABLE tracks (
    id INTEGER PRIMARY KEY,
    recording_id INTEGER REFERENCES recordings(id),
    release_id INTEGER REFERENCES releases(id),
    title TEXT NOT NULL,
    album TEXT NOT NULL DEFAULT '',
    album_artist TEXT NOT NULL DEFAULT '',
    duration_ms INTEGER,
    track_number INTEGER,
    disc_number INTEGER,
    rating INTEGER CHECK (rating BETWEEN 0 AND 100),
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX tracks_album ON tracks(album COLLATE NOCASE, disc_number, track_number);
CREATE INDEX tracks_rating ON tracks(rating);
CREATE TABLE files (
    id INTEGER PRIMARY KEY,
    recording_id INTEGER REFERENCES recordings(id),
    codec TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    sample_rate INTEGER,
    bit_depth INTEGER,
    content_hash BLOB
);
CREATE TABLE locations (
    id INTEGER PRIMARY KEY,
    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    uri TEXT NOT NULL,
    storage_identity BLOB,
    UNIQUE(device_id, uri)
);
CREATE VIRTUAL TABLE track_search USING fts5(
    title, album, album_artist,
    content='tracks', content_rowid='id',
    tokenize='unicode61 remove_diacritics 2'
);
CREATE TRIGGER tracks_ai AFTER INSERT ON tracks BEGIN
    INSERT INTO track_search(rowid, title, album, album_artist)
    VALUES (new.id, new.title, new.album, new.album_artist);
END;
CREATE TRIGGER tracks_ad AFTER DELETE ON tracks BEGIN
    INSERT INTO track_search(track_search, rowid, title, album, album_artist)
    VALUES ('delete', old.id, old.title, old.album, old.album_artist);
END;
CREATE TRIGGER tracks_au AFTER UPDATE ON tracks BEGIN
    INSERT INTO track_search(track_search, rowid, title, album, album_artist)
    VALUES ('delete', old.id, old.title, old.album, old.album_artist);
    INSERT INTO track_search(rowid, title, album, album_artist)
    VALUES (new.id, new.title, new.album, new.album_artist);
END;
CREATE TABLE library_roots (
    id INTEGER PRIMARY KEY,
    path TEXT NOT NULL UNIQUE,
    enabled INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE observed_files (
    path TEXT PRIMARY KEY,
    inode INTEGER NOT NULL,
    size_bytes INTEGER NOT NULL,
    modified_ns INTEGER NOT NULL,
    audio_format INTEGER NOT NULL,
    observed_at INTEGER NOT NULL DEFAULT (unixepoch())
) WITHOUT ROWID;
CREATE INDEX observed_files_identity
    ON observed_files(inode, size_bytes, modified_ns);
CREATE TABLE observed_file_metadata (
    path TEXT PRIMARY KEY REFERENCES observed_files(path) ON DELETE CASCADE,
    title TEXT,
    artist TEXT,
    album TEXT,
    track_number INTEGER
) WITHOUT ROWID;
CREATE TABLE orca_metadata_values (
    path TEXT NOT NULL REFERENCES observed_files(path) ON DELETE CASCADE,
    field INTEGER NOT NULL,
    value TEXT NOT NULL,
    provenance INTEGER NOT NULL,
    locked INTEGER NOT NULL DEFAULT 0 CHECK (locked IN (0, 1)),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(path, field)
) WITHOUT ROWID;
CREATE INDEX orca_metadata_values_provenance
    ON orca_metadata_values(provenance, locked);
CREATE TABLE mutation_operations (
    id INTEGER PRIMARY KEY,
    plan_id INTEGER NOT NULL,
    group_id INTEGER NOT NULL,
    action_index INTEGER NOT NULL,
    kind INTEGER NOT NULL,
    source_path TEXT NOT NULL,
    destination_path TEXT,
    stage_path TEXT,
    backup_path TEXT,
    expected_size INTEGER NOT NULL,
    expected_modified_ns INTEGER NOT NULL,
    committed_size INTEGER,
    committed_modified_ns INTEGER,
    state INTEGER NOT NULL,
    error TEXT,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    UNIQUE(plan_id, action_index)
);
CREATE INDEX mutation_operations_recovery
    ON mutation_operations(state, updated_at);
CREATE INDEX mutation_operations_group
    ON mutation_operations(group_id, action_index);
CREATE TABLE analysis_results (
    path TEXT NOT NULL,
    kind INTEGER NOT NULL,
    algorithm_id TEXT NOT NULL,
    algorithm_version INTEGER NOT NULL,
    parameter_hash BLOB NOT NULL,
    source_size INTEGER NOT NULL,
    source_modified_ns INTEGER NOT NULL,
    result BLOB NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(
        path, kind, algorithm_id, algorithm_version, parameter_hash,
        source_size, source_modified_ns
    )
) WITHOUT ROWID;
CREATE INDEX analysis_results_current
    ON analysis_results(path, kind, algorithm_id, algorithm_version);
CREATE TABLE library_health_issues (
    path TEXT NOT NULL,
    kind INTEGER NOT NULL,
    severity INTEGER NOT NULL,
    details TEXT NOT NULL DEFAULT '',
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(path, kind)
) WITHOUT ROWID;
CREATE INDEX library_health_by_kind
    ON library_health_issues(kind, severity, path);
CREATE TABLE provider_cache (
    provider TEXT NOT NULL,
    request_key TEXT NOT NULL,
    status INTEGER NOT NULL,
    body BLOB NOT NULL,
    expires_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(provider, request_key)
) WITHOUT ROWID;
CREATE INDEX provider_cache_expiry ON provider_cache(expires_at);
CREATE TABLE identification_proposals (
    id INTEGER PRIMARY KEY,
    path TEXT NOT NULL,
    provider TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    confidence REAL NOT NULL,
    payload BLOB NOT NULL,
    state INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    UNIQUE(path, provider, provider_id)
);
CREATE INDEX identification_proposals_path
    ON identification_proposals(path, state, confidence DESC);
CREATE TABLE scrobble_queue (
    id INTEGER PRIMARY KEY,
    service TEXT NOT NULL,
    event_key TEXT NOT NULL,
    payload BLOB NOT NULL,
    state INTEGER NOT NULL DEFAULT 0,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    last_error TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    UNIQUE(service, event_key)
);
CREATE INDEX scrobble_queue_ready
    ON scrobble_queue(state, next_attempt_at, id);
-- Musical entities, so the FTS rebuild has something to index.
INSERT INTO recordings(id, title, duration_ms) VALUES
    (1, 'Northern Sky', 217000),
    (2, 'Hazey Jane II', 224000);
INSERT INTO releases(id, title, album_artist, release_date) VALUES
    (1, 'Bryter Layter', 'Nick Drake', '1971');
INSERT INTO artists(id, name, sort_name) VALUES
    (1, 'Nick Drake', 'Drake, Nick');
INSERT INTO tracks(
    id, recording_id, release_id, title, album, album_artist,
    duration_ms, track_number, disc_number, rating, created_at
) VALUES
    (1, 1, 1, 'Northern Sky', 'Bryter Layter', 'Nick Drake', 217000, 8, 1, 90, 1000),
    (2, 2, 1, 'Hazey Jane II', 'Bryter Layter', 'Nick Drake', 224000, 2, 1, NULL, 1001);

-- Filesystem observations.
INSERT INTO library_roots(id, path, enabled) VALUES (1, '/music', 1);
INSERT INTO observed_files(path, inode, size_bytes, modified_ns, audio_format, observed_at) VALUES
    ('/music/drake/northern-sky.flac', 101, 40960, 1700000000000000000, 1, 1700),
    ('/music/drake/hazey-jane-ii.flac', 102, 51200, 1700000000000000001, 1, 1701),
    ('/music/misc/untagged.mp3', 103, 8192, 1700000000000000002, 2, 1702);
INSERT INTO observed_file_metadata(path, title, artist, album, track_number) VALUES
    ('/music/drake/northern-sky.flac', 'Northern Sky', 'Nick Drake', 'Bryter Layter', 8),
    ('/music/drake/hazey-jane-ii.flac', 'Hazey Jane II', 'Nick Drake', 'Bryter Layter', 2);

-- Orca metadata: one locked user value and one provider value.
INSERT INTO orca_metadata_values(path, field, value, provenance, locked, updated_at) VALUES
    ('/music/misc/untagged.mp3', 0, 'Curated title', 1, 1, 1800),
    ('/music/misc/untagged.mp3', 1, 'Provider artist', 2, 0, 1801);

-- Analysis cache, including one orphan path never seen by a scan.
INSERT INTO analysis_results(
    path, kind, algorithm_id, algorithm_version, parameter_hash,
    source_size, source_modified_ns, result, created_at
) VALUES
    ('/music/drake/northern-sky.flac', 1, 'orca.audio-diagnostics', 1, x'0102', 40960, 1700000000000000000, x'aabb', 1900),
    ('/music/drake/northern-sky.flac', 2, 'orca.temporal-fingerprint', 1, x'00', 40960, 1700000000000000000, x'ccdd', 1901),
    ('/orphan/analyzed-but-never-scanned.flac', 1, 'orca.audio-diagnostics', 1, x'0102', 2048, 1690000000000000000, x'eeff', 1902);

-- Health issues, including one orphan path never seen by a scan.
INSERT INTO library_health_issues(path, kind, severity, details, updated_at) VALUES
    ('/music/misc/untagged.mp3', 0, 1, 'no title', 2000),
    ('/music/misc/untagged.mp3', 1, 1, 'no track number', 2001),
    ('/orphan/health-only.mp3', 5, 1, '3 clipped samples', 2002);

-- Provider state.
INSERT INTO provider_cache(provider, request_key, status, body, expires_at, updated_at) VALUES
    ('musicbrainz', 'recording:northern-sky', 200, x'7b7d', 99999, 2100);
INSERT INTO identification_proposals(
    id, path, provider, provider_id, confidence, payload, state, created_at, updated_at
) VALUES
    (1, '/music/misc/untagged.mp3', 'musicbrainz', 'recording-1', 0.94, x'7b7d', 0, 2200, 2201);
INSERT INTO scrobble_queue(
    id, service, event_key, payload, state, attempt_count, next_attempt_at, last_error, created_at, updated_at
) VALUES
    (1, 'listenbrainz', 'listen:1', x'7b7d', 0, 0, 0, '', 2300, 2301);

-- A terminal journal record: startup recovery must leave it alone.
INSERT INTO mutation_operations(
    id, plan_id, group_id, action_index, kind, source_path, destination_path,
    stage_path, backup_path, expected_size, expected_modified_ns,
    committed_size, committed_modified_ns, state, error, created_at, updated_at
) VALUES
    (1, 7, 3, 0, 0, '/music/drake/northern-sky.flac', NULL, NULL, NULL,
     40960, 1700000000000000000, 40970, 1700000000000000005, 2, NULL, 2400, 2401);
PRAGMA user_version=7;
VACUUM;
