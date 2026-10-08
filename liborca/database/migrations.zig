const std = @import("std");
const sqlite = @import("sqlite.zig");
const repository = @import("repository.zig");

pub const current_version = 3;

const baseline =
    \\CREATE TABLE volumes (
    \\    id INTEGER PRIMARY KEY,
    \\    stable_key TEXT NOT NULL UNIQUE,
    \\    label TEXT NOT NULL DEFAULT '',
    \\    last_seen_at INTEGER NOT NULL DEFAULT (unixepoch())
    \\);
    \\INSERT INTO volumes(id, stable_key, label) VALUES (1, 'legacy', 'Legacy library');
    \\
    \\CREATE TABLE library_roots (
    \\    id INTEGER PRIMARY KEY,
    \\    volume_id INTEGER NOT NULL REFERENCES volumes(id),
    \\    path TEXT NOT NULL UNIQUE,
    \\    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1))
    \\);
    \\CREATE INDEX library_roots_volume ON library_roots(volume_id);
    \\
    \\CREATE TABLE files (
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
    \\    content_hash_algorithm SMALLINT,
    \\    audio_hash_tier INTEGER CHECK (audio_hash_tier IN (1, 2))
    \\);
    \\CREATE INDEX files_quick_hash ON files(quick_hash);
    \\CREATE INDEX files_audio_hash ON files(audio_hash);
    \\CREATE INDEX files_content_hash ON files(content_hash);
    \\CREATE INDEX files_by_recording ON files(recording_id);
    \\CREATE INDEX files_by_first_seen ON files(first_seen_at);
    \\CREATE INDEX files_duration ON files(duration_ms, id);
    \\CREATE INDEX files_incomplete_properties ON files(id)
    \\    WHERE
++ " " ++ repository.incomplete_properties_predicate ++ ";\n" ++
    \\CREATE INDEX files_by_bitrate ON files((size_bytes * 8 + duration_ms / 2) / duration_ms)
    \\    WHERE size_bytes > 0 AND duration_ms > 0;
    \\CREATE INDEX files_without_bitrate ON files(id) WHERE (size_bytes > 0 AND duration_ms > 0) IS NOT 1;
    \\
    \\CREATE TABLE locations (
    \\    id INTEGER PRIMARY KEY,
    \\    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    \\    volume_id INTEGER NOT NULL REFERENCES volumes(id),
    \\    root_id INTEGER REFERENCES library_roots(id) ON DELETE SET NULL,
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
    \\CREATE INDEX locations_file ON locations(file_id);
    \\CREATE INDEX locations_identity ON locations(volume_id, native_inode, size_bytes, modified_ns);
    \\CREATE INDEX locations_sweep ON locations(root_id, last_seen_generation);
    \\CREATE INDEX locations_by_uri ON locations(uri);
    \\CREATE INDEX locations_held ON locations(file_id, state) WHERE state <> 'missing';
    \\
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
    \\CREATE INDEX scan_runs_root ON scan_runs(root_id, generation DESC);
    \\
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
    \\    width INTEGER,
    \\    height INTEGER,
    \\    hash INTEGER,
    \\    UNIQUE(volume_id, uri)
    \\);
    \\CREATE INDEX folder_images_sweep ON folder_images(root_id, last_seen_generation);
    \\CREATE INDEX folder_images_folder ON folder_images(volume_id, rtrim(uri, replace(uri, '/', '')), uri);
    \\CREATE INDEX folder_images_unmeasured ON folder_images(id) WHERE hash IS NULL;
    \\
    \\CREATE TABLE folder_scans (
    \\    root_id INTEGER NOT NULL REFERENCES library_roots(id) ON DELETE CASCADE,
    \\    relative_path TEXT NOT NULL,
    \\    scanned_at INTEGER NOT NULL,
    \\    PRIMARY KEY (root_id, relative_path)
    \\) WITHOUT ROWID;
    \\
    \\CREATE TABLE observed_file_tags (
    \\    file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
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
    \\    observed_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    explicit INTEGER,
    \\    comment TEXT,
    \\    artwork_width INTEGER,
    \\    artwork_height INTEGER,
    \\    artwork_hash INTEGER
    \\) WITHOUT ROWID;
    \\CREATE INDEX observed_file_tags_release ON observed_file_tags(musicbrainz_release_id);
    \\CREATE INDEX observed_file_tags_album
    \\    ON observed_file_tags(album COLLATE NOCASE, album_artist COLLATE NOCASE);
    \\CREATE INDEX observed_file_tags_artwork_unmeasured ON observed_file_tags(file_id)
    \\    WHERE artwork_byte_size > 0 AND artwork_hash IS NULL;
    \\
    \\CREATE TABLE observed_file_genres (
    \\    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    \\    ordinal INTEGER NOT NULL,
    \\    value TEXT NOT NULL,
    \\    PRIMARY KEY(file_id, ordinal)
    \\) WITHOUT ROWID;
    \\
    \\CREATE TABLE analysis_results (
    \\    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    \\    kind INTEGER NOT NULL,
    \\    algorithm_id TEXT NOT NULL,
    \\    algorithm_version INTEGER NOT NULL,
    \\    parameter_hash BLOB NOT NULL,
    \\    source_identity BLOB NOT NULL,
    \\    result BLOB NOT NULL,
    \\    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    PRIMARY KEY(file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity)
    \\) WITHOUT ROWID;
    \\CREATE INDEX analysis_results_current
    \\    ON analysis_results(file_id, kind, algorithm_id, algorithm_version);
    \\CREATE INDEX analysis_results_created ON analysis_results(created_at);
    \\
    \\CREATE TABLE file_loudness (
    \\    file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
    \\    source_identity BLOB NOT NULL,
    \\    integrated_lufs REAL NOT NULL
    \\);
    \\CREATE INDEX file_loudness_by_lufs ON file_loudness(integrated_lufs);
    \\CREATE TRIGGER analysis_results_loudness_ai AFTER INSERT ON analysis_results
    \\WHEN new.kind = 1 AND new.algorithm_id = 'orca.audio-diagnostics'
    \\  AND new.algorithm_version = 4
    \\  AND new.parameter_hash = X'A5D7A479D64C3952CA86E311AFFEBB0CFCA41DAF406C7AA159255961CF9145CE'
    \\BEGIN
    \\    DELETE FROM file_loudness WHERE file_id = new.file_id;
    \\    INSERT INTO file_loudness(file_id, source_identity, integrated_lufs)
    \\SELECT file_id, source_identity,
    \\       CASE WHEN (bits & 2147483647) = 0 THEN 0.0
    \\            ELSE (CASE WHEN (bits >> 31) = 1 THEN -1.0 ELSE 1.0 END)
    \\                 * (1.0 + (bits & 8388607) / 8388608.0)
    \\                 * (CASE WHEN ((bits >> 23) & 255) >= 127 THEN (1 << (((bits >> 23) & 255) - 127))
    \\                         ELSE 1.0 / (1 << (127 - ((bits >> 23) & 255))) END)
    \\       END
    \\FROM (SELECT file_id, source_identity,
    \\           ((instr('0123456789ABCDEF', substr(digits, 1, 1)) - 1) << 4) + (instr('0123456789ABCDEF', substr(digits, 2, 1)) - 1) +
    \\           ((instr('0123456789ABCDEF', substr(digits, 3, 1)) - 1) << 12) + ((instr('0123456789ABCDEF', substr(digits, 4, 1)) - 1) << 8) +
    \\           ((instr('0123456789ABCDEF', substr(digits, 5, 1)) - 1) << 20) + ((instr('0123456789ABCDEF', substr(digits, 6, 1)) - 1) << 16) +
    \\           ((instr('0123456789ABCDEF', substr(digits, 7, 1)) - 1) << 28) + ((instr('0123456789ABCDEF', substr(digits, 8, 1)) - 1) << 24) AS bits
    \\      FROM (SELECT file_id, source_identity, hex(substr(result, 9, 4)) AS digits
    \\            FROM (SELECT new.file_id AS file_id, new.source_identity AS source_identity, new.result AS result)
    \\            WHERE length(result) >= 72 AND substr(result, 1, 6) = X'4F5241440200'
    \\              AND instr('13579BDF', substr(hex(substr(result, 7, 1)), 2, 1)) > 0))
    \\WHERE (bits & 2147483647) = 0 OR ((bits >> 23) & 255) BETWEEN 65 AND 189;
    \\END;
    \\CREATE TRIGGER analysis_results_loudness_au AFTER UPDATE OF result ON analysis_results
    \\WHEN new.kind = 1 AND new.algorithm_id = 'orca.audio-diagnostics'
    \\  AND new.algorithm_version = 4
    \\  AND new.parameter_hash = X'A5D7A479D64C3952CA86E311AFFEBB0CFCA41DAF406C7AA159255961CF9145CE'
    \\BEGIN
    \\    DELETE FROM file_loudness WHERE file_id = new.file_id;
    \\    INSERT INTO file_loudness(file_id, source_identity, integrated_lufs)
    \\SELECT file_id, source_identity,
    \\       CASE WHEN (bits & 2147483647) = 0 THEN 0.0
    \\            ELSE (CASE WHEN (bits >> 31) = 1 THEN -1.0 ELSE 1.0 END)
    \\                 * (1.0 + (bits & 8388607) / 8388608.0)
    \\                 * (CASE WHEN ((bits >> 23) & 255) >= 127 THEN (1 << (((bits >> 23) & 255) - 127))
    \\                         ELSE 1.0 / (1 << (127 - ((bits >> 23) & 255))) END)
    \\       END
    \\FROM (SELECT file_id, source_identity,
    \\           ((instr('0123456789ABCDEF', substr(digits, 1, 1)) - 1) << 4) + (instr('0123456789ABCDEF', substr(digits, 2, 1)) - 1) +
    \\           ((instr('0123456789ABCDEF', substr(digits, 3, 1)) - 1) << 12) + ((instr('0123456789ABCDEF', substr(digits, 4, 1)) - 1) << 8) +
    \\           ((instr('0123456789ABCDEF', substr(digits, 5, 1)) - 1) << 20) + ((instr('0123456789ABCDEF', substr(digits, 6, 1)) - 1) << 16) +
    \\           ((instr('0123456789ABCDEF', substr(digits, 7, 1)) - 1) << 28) + ((instr('0123456789ABCDEF', substr(digits, 8, 1)) - 1) << 24) AS bits
    \\      FROM (SELECT file_id, source_identity, hex(substr(result, 9, 4)) AS digits
    \\            FROM (SELECT new.file_id AS file_id, new.source_identity AS source_identity, new.result AS result)
    \\            WHERE length(result) >= 72 AND substr(result, 1, 6) = X'4F5241440200'
    \\              AND instr('13579BDF', substr(hex(substr(result, 7, 1)), 2, 1)) > 0))
    \\WHERE (bits & 2147483647) = 0 OR ((bits >> 23) & 255) BETWEEN 65 AND 189;
    \\END;
    \\CREATE TRIGGER analysis_results_loudness_ad AFTER DELETE ON analysis_results
    \\WHEN old.kind = 1 AND old.algorithm_id = 'orca.audio-diagnostics'
    \\  AND old.algorithm_version = 4
    \\  AND old.parameter_hash = X'A5D7A479D64C3952CA86E311AFFEBB0CFCA41DAF406C7AA159255961CF9145CE'
    \\BEGIN
    \\    DELETE FROM file_loudness WHERE file_id = old.file_id AND source_identity = old.source_identity;
    \\END;
    \\
    \\CREATE TABLE library_health_issues (
    \\    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    \\    kind INTEGER NOT NULL,
    \\    severity INTEGER NOT NULL,
    \\    details TEXT NOT NULL DEFAULT '',
    \\    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    related_file_id INTEGER REFERENCES files(id) ON DELETE SET NULL,
    \\    similarity REAL,
    \\    PRIMARY KEY(file_id, kind)
    \\) WITHOUT ROWID;
    \\CREATE INDEX library_health_by_kind ON library_health_issues(kind, severity, file_id);
    \\CREATE INDEX library_health_by_related
    \\    ON library_health_issues(related_file_id) WHERE related_file_id IS NOT NULL;
    \\
    \\CREATE TABLE health_dismissals (
    \\    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    \\    kind INTEGER NOT NULL,
    \\    quick_hash BLOB,
    \\    dismissed_at INTEGER NOT NULL,
    \\    PRIMARY KEY(file_id, kind)
    \\) WITHOUT ROWID;
    \\
    \\CREATE TABLE artists (
    \\    id INTEGER PRIMARY KEY,
    \\    name TEXT NOT NULL,
    \\    sort_name TEXT,
    \\    key TEXT,
    \\    musicbrainz_artist_id TEXT
    \\);
    \\CREATE INDEX artists_name ON artists(name COLLATE NOCASE);
    \\CREATE INDEX artists_sort ON artists(sort_name);
    \\CREATE UNIQUE INDEX artists_key ON artists(key);
    \\
    \\CREATE TABLE releases (
    \\    id INTEGER PRIMARY KEY,
    \\    title TEXT NOT NULL,
    \\    album_artist TEXT NOT NULL DEFAULT '',
    \\    release_date TEXT,
    \\    is_compilation INTEGER NOT NULL DEFAULT 0
    \\        CHECK (is_compilation IN (0, 1)),
    \\    disc_count INTEGER,
    \\    release_key TEXT,
    \\    musicbrainz_release_id TEXT,
    \\    album_artist_id INTEGER REFERENCES artists(id),
    \\    release_type TEXT,
    \\    has_folder_cover INTEGER NOT NULL DEFAULT 0
    \\);
    \\CREATE INDEX releases_title ON releases(title COLLATE NOCASE);
    \\CREATE UNIQUE INDEX releases_key ON releases(release_key);
    \\CREATE INDEX releases_by_artist ON releases(album_artist_id, title COLLATE NOCASE);
    \\CREATE INDEX releases_by_year ON releases((
    \\    CASE WHEN substr(release_date, 1, 4) GLOB '[0-9][0-9][0-9][0-9]'
    \\    THEN CAST(substr(release_date, 1, 4) AS INTEGER) END));
    \\CREATE INDEX releases_artist_order ON releases((upper(substr((CASE WHEN album_artist LIKE 'the _%' THEN substr(album_artist, 5)
    \\      WHEN album_artist LIKE 'an _%' THEN substr(album_artist, 4)
    \\      WHEN album_artist LIKE 'a _%' THEN substr(album_artist, 3) ELSE album_artist END), 1, 1)) BETWEEN 'A' AND 'Z'), (CASE WHEN album_artist LIKE 'the _%' THEN substr(album_artist, 5)
    \\      WHEN album_artist LIKE 'an _%' THEN substr(album_artist, 4)
    \\      WHEN album_artist LIKE 'a _%' THEN substr(album_artist, 3) ELSE album_artist END) COLLATE NOCASE, release_date IS NULL, release_date, title COLLATE NOCASE, id);
    \\CREATE INDEX releases_title_order ON releases((upper(substr(title, 1, 1)) BETWEEN 'A' AND 'Z'), title COLLATE NOCASE, id);
    \\CREATE INDEX releases_match_order ON releases(album_artist COLLATE NOCASE, title COLLATE NOCASE);
    \\
    \\CREATE TABLE recordings (
    \\    id INTEGER PRIMARY KEY,
    \\    title TEXT NOT NULL,
    \\    duration_ms INTEGER
    \\);
    \\
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
    \\    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    artist TEXT NOT NULL DEFAULT '',
    \\    preferred_file_id INTEGER REFERENCES files(id),
    \\    artist_id INTEGER REFERENCES artists(id),
    \\    track_total INTEGER,
    \\    disc_total INTEGER,
    \\    explicit INTEGER NOT NULL DEFAULT 0
    \\);
    \\CREATE UNIQUE INDEX tracks_position
    \\    ON tracks(release_id, COALESCE(disc_number, 1), COALESCE(track_number, -id));
    \\CREATE INDEX tracks_artist ON tracks(artist_id);
    \\CREATE INDEX tracks_release ON tracks(release_id);
    \\CREATE INDEX tracks_by_recording ON tracks(recording_id);
    \\CREATE INDEX tracks_by_preferred_file ON tracks(preferred_file_id);
    \\CREATE INDEX tracks_by_release ON tracks(
    \\    release_id, COALESCE(disc_number, 1), COALESCE(track_number, 2147483647)
    \\);
    \\CREATE INDEX tracks_sort_artist ON tracks(
    \\    artist COLLATE NOCASE, album COLLATE NOCASE,
    \\    COALESCE(disc_number, 1), COALESCE(track_number, 2147483647)
    \\);
    \\CREATE INDEX tracks_sort_album_artist ON tracks(
    \\    album_artist COLLATE NOCASE, album COLLATE NOCASE,
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
    \\
    \\CREATE TABLE genres (
    \\    id INTEGER PRIMARY KEY,
    \\    name TEXT NOT NULL,
    \\    key TEXT NOT NULL UNIQUE
    \\);
    \\CREATE INDEX genres_by_name ON genres(name COLLATE NOCASE);
    \\
    \\CREATE TABLE track_genres (
    \\    track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    \\    genre_id INTEGER NOT NULL REFERENCES genres(id) ON DELETE CASCADE,
    \\    ordinal INTEGER NOT NULL,
    \\    provenance INTEGER NOT NULL,
    \\    PRIMARY KEY(track_id, ordinal)
    \\) WITHOUT ROWID;
    \\CREATE UNIQUE INDEX track_genres_by_genre ON track_genres(genre_id, track_id);
    \\CREATE INDEX track_genres_first ON track_genres(genre_id, track_id) WHERE ordinal = 0;
    \\
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
    \\CREATE TRIGGER tracks_au AFTER UPDATE OF id, title, artist, album, album_artist ON tracks
    \\WHEN old.id IS NOT new.id OR old.title IS NOT new.title OR old.artist IS NOT new.artist
    \\    OR old.album IS NOT new.album OR old.album_artist IS NOT new.album_artist BEGIN
    \\    INSERT INTO track_search(track_search, rowid, title, artist, album, album_artist)
    \\    VALUES ('delete', old.id, old.title, old.artist, old.album, old.album_artist);
    \\    INSERT INTO track_search(rowid, title, artist, album, album_artist)
    \\    VALUES (new.id, new.title, new.artist, new.album, new.album_artist);
    \\END;
    \\
    \\CREATE VIRTUAL TABLE search_index USING fts5(
    \\    kind UNINDEXED, entity_id UNINDEXED, title, subtitle,
    \\    tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3'
    \\);
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
    \\
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
    \\    INSERT INTO genre_totals(genre_id, track_count, release_count, artist_count, duration_ms)
    \\    VALUES (new.genre_id, 1, 0, 0, COALESCE((SELECT duration_ms FROM tracks WHERE id = new.track_id), 0))
    \\    ON CONFLICT(genre_id) DO UPDATE SET track_count = track_count + 1, duration_ms = duration_ms + excluded.duration_ms;
    \\    INSERT INTO genre_release_tracks(release_id, genre_id, tracks)
    \\    SELECT release_id, new.genre_id, 1 FROM tracks WHERE id = new.track_id AND release_id IS NOT NULL
    \\    ON CONFLICT DO UPDATE SET tracks = tracks + 1;
    \\    INSERT INTO genre_artist_refs(genre_id, artist_id, refs)
    \\    SELECT new.genre_id, artist_id, 1 FROM tracks WHERE id = new.track_id AND artist_id IS NOT NULL
    \\    ON CONFLICT DO UPDATE SET refs = refs + 1;
    \\    INSERT INTO genre_artist_refs(genre_id, artist_id, refs)
    \\    SELECT new.genre_id, releases.album_artist_id, 1
    \\    FROM tracks CROSS JOIN releases ON releases.id = tracks.release_id
    \\    WHERE tracks.id = new.track_id AND releases.album_artist_id IS NOT NULL
    \\    ON CONFLICT DO UPDATE SET refs = refs + 1;
    \\END;
    \\CREATE TRIGGER track_genres_totals_ad AFTER DELETE ON track_genres BEGIN
    \\    UPDATE genre_release_tracks SET tracks = tracks - 1
    \\    WHERE genre_id = old.genre_id AND release_id = (SELECT release_id FROM tracks WHERE id = old.track_id);
    \\    UPDATE genre_artist_refs SET refs = refs - 1
    \\    WHERE genre_id = old.genre_id AND artist_id = (SELECT artist_id FROM tracks WHERE id = old.track_id);
    \\    UPDATE genre_artist_refs SET refs = refs - 1
    \\    WHERE genre_id = old.genre_id AND artist_id = (SELECT releases.album_artist_id
    \\        FROM tracks CROSS JOIN releases ON releases.id = tracks.release_id WHERE tracks.id = old.track_id);
    \\    UPDATE genre_totals SET track_count = track_count - 1,
    \\        duration_ms = duration_ms - COALESCE((SELECT duration_ms FROM tracks WHERE id = old.track_id), 0)
    \\    WHERE genre_id = old.genre_id;
    \\END;
    \\CREATE TRIGGER track_genres_totals_au AFTER UPDATE OF track_id, genre_id ON track_genres
    \\WHEN old.track_id IS NOT new.track_id OR old.genre_id IS NOT new.genre_id BEGIN
    \\    UPDATE genre_release_tracks SET tracks = tracks - 1
    \\    WHERE genre_id = old.genre_id AND release_id = (SELECT release_id FROM tracks WHERE id = old.track_id);
    \\    UPDATE genre_artist_refs SET refs = refs - 1
    \\    WHERE genre_id = old.genre_id AND artist_id = (SELECT artist_id FROM tracks WHERE id = old.track_id);
    \\    UPDATE genre_artist_refs SET refs = refs - 1
    \\    WHERE genre_id = old.genre_id AND artist_id = (SELECT releases.album_artist_id
    \\        FROM tracks CROSS JOIN releases ON releases.id = tracks.release_id WHERE tracks.id = old.track_id);
    \\    UPDATE genre_totals SET track_count = track_count - 1,
    \\        duration_ms = duration_ms - COALESCE((SELECT duration_ms FROM tracks WHERE id = old.track_id), 0)
    \\    WHERE genre_id = old.genre_id;
    \\    INSERT INTO genre_totals(genre_id, track_count, release_count, artist_count, duration_ms)
    \\    VALUES (new.genre_id, 1, 0, 0, COALESCE((SELECT duration_ms FROM tracks WHERE id = new.track_id), 0))
    \\    ON CONFLICT(genre_id) DO UPDATE SET track_count = track_count + 1, duration_ms = duration_ms + excluded.duration_ms;
    \\    INSERT INTO genre_release_tracks(release_id, genre_id, tracks)
    \\    SELECT release_id, new.genre_id, 1 FROM tracks WHERE id = new.track_id AND release_id IS NOT NULL
    \\    ON CONFLICT DO UPDATE SET tracks = tracks + 1;
    \\    INSERT INTO genre_artist_refs(genre_id, artist_id, refs)
    \\    SELECT new.genre_id, artist_id, 1 FROM tracks WHERE id = new.track_id AND artist_id IS NOT NULL
    \\    ON CONFLICT DO UPDATE SET refs = refs + 1;
    \\    INSERT INTO genre_artist_refs(genre_id, artist_id, refs)
    \\    SELECT new.genre_id, releases.album_artist_id, 1
    \\    FROM tracks CROSS JOIN releases ON releases.id = tracks.release_id
    \\    WHERE tracks.id = new.track_id AND releases.album_artist_id IS NOT NULL
    \\    ON CONFLICT DO UPDATE SET refs = refs + 1;
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
    \\CREATE TABLE orca_metadata_values (
    \\    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    \\    field INTEGER NOT NULL,
    \\    value TEXT NOT NULL,
    \\    provenance INTEGER NOT NULL,
    \\    locked INTEGER NOT NULL DEFAULT 0 CHECK (locked IN (0, 1)),
    \\    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    written_at INTEGER,
    \\    PRIMARY KEY(file_id, field)
    \\) WITHOUT ROWID;
    \\CREATE INDEX orca_metadata_values_provenance ON orca_metadata_values(provenance, locked);
    \\CREATE INDEX orca_metadata_values_release ON orca_metadata_values(file_id)
    \\    WHERE field = 9 AND value > '';
    \\
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
    \\    created_at INTEGER NOT NULL,
    \\    tracks INTEGER CHECK (tracks IS NULL OR tracks >= 0),
    \\    gap INTEGER CHECK (gap IS NULL OR gap > 0)
    \\);
    \\CREATE INDEX metadata_proposals_groups ON metadata_proposals(state, category, release_id, id)
    \\    WHERE id = group_id;
    \\CREATE INDEX metadata_proposals_members ON metadata_proposals(group_id, option, id);
    \\CREATE INDEX metadata_proposals_release ON metadata_proposals(release_id, state);
    \\CREATE INDEX metadata_proposals_track ON metadata_proposals(track_id) WHERE track_id IS NOT NULL;
    \\
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
    \\    file_id INTEGER REFERENCES files(id),
    \\    expected_quick_hash BLOB,
    \\    committed_quick_hash BLOB,
    \\    expected_content_hash BLOB,
    \\    committed_content_hash BLOB,
    \\    UNIQUE(plan_id, action_index)
    \\);
    \\CREATE INDEX mutation_operations_recovery ON mutation_operations(state, updated_at);
    \\CREATE INDEX mutation_operations_group ON mutation_operations(group_id, action_index);
    \\
    \\CREATE TABLE identification_proposals (
    \\    id INTEGER PRIMARY KEY,
    \\    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    \\    recording_id INTEGER REFERENCES recordings(id),
    \\    provider TEXT NOT NULL,
    \\    provider_id TEXT NOT NULL,
    \\    confidence REAL NOT NULL,
    \\    payload BLOB NOT NULL,
    \\    state INTEGER NOT NULL DEFAULT 0,
    \\    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\    accepted_in_bulk INTEGER NOT NULL DEFAULT 0,
    \\    album_group INTEGER,
    \\    UNIQUE(file_id, provider, provider_id)
    \\);
    \\CREATE INDEX identification_proposals_file
    \\    ON identification_proposals(file_id, state, confidence DESC);
    \\CREATE INDEX identification_proposals_album_group
    \\    ON identification_proposals(album_group, state) WHERE album_group IS NOT NULL;
    \\
    \\CREATE TABLE identification_searches (
    \\    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    \\    provider TEXT NOT NULL,
    \\    searched_at INTEGER NOT NULL,
    \\    PRIMARY KEY(file_id, provider)
    \\) WITHOUT ROWID;
    \\
    \\CREATE TABLE recording_verifications (
    \\    file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
    \\    quick_hash BLOB,
    \\    recording_mbid TEXT NOT NULL,
    \\    outcome INTEGER NOT NULL,
    \\    heard TEXT,
    \\    verified_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE acoustid_submissions (
    \\    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    \\    recording_mbid TEXT NOT NULL,
    \\    submission_id INTEGER,
    \\    submitted_at INTEGER NOT NULL,
    \\    PRIMARY KEY(file_id, recording_mbid)
    \\) WITHOUT ROWID;
    \\
    \\CREATE TABLE musicbrainz_releases (
    \\    musicbrainz_release_id TEXT PRIMARY KEY NOT NULL,
    \\    title TEXT NOT NULL,
    \\    artist_credit TEXT NOT NULL,
    \\    release_date TEXT,
    \\    release_group_id TEXT,
    \\    medium_count INTEGER NOT NULL CHECK (medium_count >= 0),
    \\    track_count INTEGER NOT NULL CHECK (track_count >= 0),
    \\    fetched_at INTEGER NOT NULL,
    \\    artist_credit_ids TEXT
    \\) WITHOUT ROWID;
    \\
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
    \\CREATE TABLE release_track_pairings (
    \\    track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    \\    musicbrainz_release_id TEXT NOT NULL,
    \\    release_id INTEGER NOT NULL REFERENCES releases(id) ON DELETE CASCADE,
    \\    release_track_id TEXT NOT NULL,
    \\    recording_id TEXT NOT NULL,
    \\    origin INTEGER NOT NULL CHECK (origin IN (0, 1)),
    \\    created_at INTEGER NOT NULL,
    \\    PRIMARY KEY (track_id)
    \\) WITHOUT ROWID;
    \\CREATE UNIQUE INDEX release_track_pairings_release_track
    \\    ON release_track_pairings(release_id, musicbrainz_release_id, release_track_id);
    \\CREATE TRIGGER release_track_pairings_track_moved AFTER UPDATE OF release_id ON tracks
    \\WHEN old.release_id IS NOT new.release_id BEGIN
    \\    DELETE FROM release_track_pairings WHERE track_id = new.id AND new.release_id IS NULL;
    \\    DELETE FROM release_track_pairings
    \\    WHERE release_id = new.release_id AND track_id <> new.id
    \\        AND EXISTS (SELECT 1 FROM release_track_pairings AS moved WHERE moved.track_id = new.id
    \\            AND moved.musicbrainz_release_id = release_track_pairings.musicbrainz_release_id
    \\            AND moved.release_track_id = release_track_pairings.release_track_id);
    \\    UPDATE release_track_pairings SET release_id = new.release_id WHERE track_id = new.id;
    \\END;
    \\
    \\CREATE TABLE paired_metadata_values (
    \\    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    \\    field INTEGER NOT NULL,
    \\    value TEXT NOT NULL,
    \\    replaced_value TEXT,
    \\    replaced_provenance INTEGER,
    \\    replaced_locked INTEGER CHECK (replaced_locked IN (0, 1)),
    \\    replaced_written_at INTEGER,
    \\    PRIMARY KEY (file_id, field),
    \\    CHECK ((replaced_value IS NULL) = (replaced_provenance IS NULL)
    \\        AND (replaced_value IS NULL) = (replaced_locked IS NULL))
    \\) WITHOUT ROWID;
    \\
    \\CREATE TABLE reviewed_releases (
    \\    release_id INTEGER PRIMARY KEY NOT NULL REFERENCES releases(id) ON DELETE CASCADE,
    \\    musicbrainz_release_id TEXT NOT NULL,
    \\    digest BLOB NOT NULL CHECK (length(digest) = 32),
    \\    reviewed_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE dismissed_release_candidates (
    \\    release_id INTEGER NOT NULL REFERENCES releases(id) ON DELETE CASCADE,
    \\    musicbrainz_release_id TEXT NOT NULL,
    \\    dismissed_at INTEGER NOT NULL,
    \\    PRIMARY KEY (release_id, musicbrainz_release_id)
    \\) WITHOUT ROWID;
    \\
    \\CREATE TABLE release_artwork (
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
    \\CREATE INDEX release_artwork_unmeasured ON release_artwork(release_id, kind)
    \\    WHERE image IS NOT NULL AND width IS NULL;
    \\
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
    \\
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
    \\
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
    \\    outcome INTEGER NOT NULL,
    \\    origin TEXT
    \\);
    \\
    \\CREATE TABLE artist_links (
    \\    artist_id INTEGER NOT NULL REFERENCES artists(id) ON DELETE CASCADE,
    \\    kind INTEGER NOT NULL,
    \\    url TEXT NOT NULL,
    \\    PRIMARY KEY(artist_id, kind, url)
    \\) WITHOUT ROWID;
    \\
    \\CREATE TABLE artist_related (
    \\    artist_id INTEGER NOT NULL REFERENCES artists(id) ON DELETE CASCADE,
    \\    ordinal INTEGER NOT NULL,
    \\    related_mbid TEXT NOT NULL,
    \\    related_name TEXT NOT NULL,
    \\    score INTEGER NOT NULL,
    \\    PRIMARY KEY(artist_id, ordinal)
    \\) WITHOUT ROWID;
    \\
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
    \\
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
    \\CREATE INDEX artist_release_groups_mbid ON artist_release_groups(mbid);
    \\
    \\CREATE TABLE release_group_covers (
    \\    mbid TEXT PRIMARY KEY,
    \\    image BLOB,
    \\    mime TEXT,
    \\    fetched_at INTEGER NOT NULL,
    \\    CHECK ((image IS NULL) = (mime IS NULL))
    \\);
    \\CREATE TRIGGER artist_release_groups_cover_ad AFTER DELETE ON artist_release_groups
    \\WHEN NOT EXISTS (SELECT 1 FROM artist_release_groups WHERE mbid = old.mbid)
    \\BEGIN
    \\    DELETE FROM release_group_covers WHERE mbid = old.mbid;
    \\END;
    \\
    \\CREATE TABLE track_lyrics (
    \\    track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
    \\    query_digest BLOB NOT NULL,
    \\    lrclib_id INTEGER,
    \\    synced TEXT,
    \\    plain TEXT,
    \\    instrumental INTEGER NOT NULL DEFAULT 0,
    \\    fetched_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE ratings (
    \\    recording_id INTEGER PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,
    \\    rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 100),
    \\    updated_at INTEGER NOT NULL
    \\);
    \\CREATE INDEX ratings_by_rating ON ratings(rating);
    \\
    \\CREATE TABLE feedback (
    \\    recording_id INTEGER PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,
    \\    score INTEGER NOT NULL CHECK (score IN (-1, 0, 1)),
    \\    updated_at INTEGER NOT NULL,
    \\    synced_score INTEGER,
    \\    synced_at INTEGER,
    \\    last_error TEXT NOT NULL DEFAULT ''
    \\);
    \\CREATE INDEX feedback_loved ON feedback(updated_at) WHERE score = 1;
    \\
    \\CREATE TABLE release_loves (
    \\    release_id INTEGER PRIMARY KEY REFERENCES releases(id) ON DELETE CASCADE,
    \\    loved_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE artist_loves (
    \\    artist_id INTEGER PRIMARY KEY REFERENCES artists(id) ON DELETE CASCADE,
    \\    loved_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE playlists (
    \\    id INTEGER PRIMARY KEY,
    \\    name TEXT NOT NULL UNIQUE,
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL,
    \\    description TEXT NOT NULL DEFAULT '',
    \\    pinned_at INTEGER,
    \\    loved_at INTEGER,
    \\    kind INTEGER NOT NULL DEFAULT 0,
    \\    rules TEXT,
    \\    creator INTEGER NOT NULL DEFAULT 0
    \\);
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
    \\
    \\CREATE TABLE playlist_entries (
    \\    playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    \\    position INTEGER NOT NULL,
    \\    recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
    \\    added_at INTEGER NOT NULL,
    \\    PRIMARY KEY(playlist_id, position)
    \\) WITHOUT ROWID;
    \\CREATE INDEX playlist_entries_by_recording ON playlist_entries(recording_id);
    \\
    \\CREATE TABLE playlist_tags (
    \\    playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    \\    ordinal INTEGER NOT NULL,
    \\    tag TEXT NOT NULL,
    \\    PRIMARY KEY(playlist_id, ordinal)
    \\) WITHOUT ROWID;
    \\
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
    \\    syncable INTEGER NOT NULL DEFAULT 1,
    \\    UNIQUE(file_id, started_at)
    \\);
    \\CREATE INDEX listens_by_file ON listens(file_id, started_at);
    \\CREATE INDEX listens_by_recording ON listens(recording_id, started_at);
    \\
    \\CREATE TABLE recording_play_stats (
    \\    recording_id INTEGER PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,
    \\    play_count INTEGER NOT NULL,
    \\    last_played_at INTEGER NOT NULL
    \\);
    \\CREATE INDEX recording_play_stats_by_count
    \\    ON recording_play_stats(play_count DESC, recording_id);
    \\CREATE INDEX recording_play_stats_by_last_played
    \\    ON recording_play_stats(last_played_at DESC, recording_id);
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
    \\
    \\CREATE TABLE track_positions (
    \\    track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
    \\    position_ms INTEGER NOT NULL CHECK (position_ms > 0),
    \\    updated_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE player_state (
    \\    id INTEGER PRIMARY KEY CHECK (id = 1),
    \\    cursor INTEGER NOT NULL CHECK (cursor >= 0),
    \\    position_ms INTEGER NOT NULL CHECK (position_ms >= 0),
    \\    repeat INTEGER NOT NULL CHECK (repeat BETWEEN 0 AND 2),
    \\    shuffle INTEGER NOT NULL CHECK (shuffle IN (0, 1)),
    \\    saved_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE player_queue_entries (
    \\    position INTEGER PRIMARY KEY CHECK (position BETWEEN 0 AND 9999),
    \\    entry INTEGER NOT NULL CHECK (entry BETWEEN 0 AND 9999),
    \\    track_id INTEGER NOT NULL,
    \\    recording_id INTEGER
    \\);
    \\
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
    \\
    \\CREATE TABLE provider_state (
    \\    service TEXT PRIMARY KEY,
    \\    blocked_until_ms INTEGER,
    \\    backoff_ms INTEGER NOT NULL DEFAULT 0,
    \\    next_request_ms INTEGER
    \\) WITHOUT ROWID;
    \\
    \\CREATE TABLE provider_leases (
    \\    service TEXT PRIMARY KEY,
    \\    owner INTEGER NOT NULL,
    \\    expires_at INTEGER NOT NULL
    \\) WITHOUT ROWID;
    \\
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
    \\    lease_owner INTEGER,
    \\    lease_expires_at INTEGER,
    \\    UNIQUE(service, event_key)
    \\);
    \\CREATE INDEX scrobble_queue_ready ON scrobble_queue(state, next_attempt_at, id);
    \\CREATE INDEX scrobble_queue_leased ON scrobble_queue(lease_expires_at) WHERE state = 1;
    \\
    \\CREATE TABLE library_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
    \\
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
;

const v2 =
    \\CREATE INDEX listens_by_time ON listens(started_at);
    \\
    \\CREATE TABLE file_audio_features (
    \\    file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
    \\    source_identity BLOB NOT NULL,
    \\    tempo_bpm REAL,
    \\    tempo_confidence REAL,
    \\    key_pitch INTEGER CHECK (key_pitch IS NULL OR key_pitch BETWEEN 0 AND 11),
    \\    key_mode INTEGER CHECK (key_mode IS NULL OR key_mode IN (0, 1)),
    \\    key_confidence REAL,
    \\    onset_rate REAL,
    \\    centroid_hz REAL,
    \\    CHECK ((key_pitch IS NULL) = (key_mode IS NULL))
    \\);
    \\CREATE INDEX file_audio_features_by_tempo ON file_audio_features(tempo_bpm);
    \\CREATE INDEX file_audio_features_by_onset_rate ON file_audio_features(onset_rate);
    \\CREATE INDEX file_audio_features_by_centroid ON file_audio_features(centroid_hz);
    \\CREATE TRIGGER analysis_results_features_ai AFTER INSERT ON analysis_results
    \\WHEN new.kind = 6 AND new.algorithm_id = 'orca.audio-features'
    \\  AND new.algorithm_version = 1
    \\  AND new.parameter_hash = X'8D91D6D7138EB255B30DD8F82BF8B042B0E78E5FE59C0A12EECD4861CB7D5C0E'
    \\BEGIN
    \\    DELETE FROM file_audio_features WHERE file_id = new.file_id;
    \\    INSERT INTO file_audio_features(file_id, source_identity, tempo_bpm, tempo_confidence,
    \\        key_pitch, key_mode, key_confidence, onset_rate, centroid_hz)
    \\SELECT file_id, source_identity,
    \\       CASE WHEN present & 1 THEN tempo / 1000.0 END,
    \\       CASE WHEN present & 1 THEN tempo_confidence / 1000000.0 END,
    \\       CASE WHEN present & 2 THEN key_pitch END,
    \\       CASE WHEN present & 2 THEN key_mode END,
    \\       CASE WHEN present & 2 THEN key_confidence / 1000000.0 END,
    \\       CASE WHEN present & 4 THEN onset_rate / 1000000.0 END,
    \\       CASE WHEN present & 8 THEN centroid / 1000.0 END
    \\FROM (SELECT file_id, source_identity,
    \\           ((instr('0123456789ABCDEF', substr(digits, 13, 1)) - 1) << 4) + (instr('0123456789ABCDEF', substr(digits, 14, 1)) - 1) + ((instr('0123456789ABCDEF', substr(digits, 15, 1)) - 1) << 12) + ((instr('0123456789ABCDEF', substr(digits, 16, 1)) - 1) << 8) AS present,
    \\           ((instr('0123456789ABCDEF', substr(digits, 17, 1)) - 1) << 4) + ((instr('0123456789ABCDEF', substr(digits, 18, 1)) - 1) << 0) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 19, 1)) - 1) << 12) + ((instr('0123456789ABCDEF', substr(digits, 20, 1)) - 1) << 8) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 21, 1)) - 1) << 20) + ((instr('0123456789ABCDEF', substr(digits, 22, 1)) - 1) << 16) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 23, 1)) - 1) << 28) + ((instr('0123456789ABCDEF', substr(digits, 24, 1)) - 1) << 24) AS tempo,
    \\           ((instr('0123456789ABCDEF', substr(digits, 25, 1)) - 1) << 4) + ((instr('0123456789ABCDEF', substr(digits, 26, 1)) - 1) << 0) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 27, 1)) - 1) << 12) + ((instr('0123456789ABCDEF', substr(digits, 28, 1)) - 1) << 8) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 29, 1)) - 1) << 20) + ((instr('0123456789ABCDEF', substr(digits, 30, 1)) - 1) << 16) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 31, 1)) - 1) << 28) + ((instr('0123456789ABCDEF', substr(digits, 32, 1)) - 1) << 24) AS tempo_confidence,
    \\           ((instr('0123456789ABCDEF', substr(digits, 33, 1)) - 1) << 4) + (instr('0123456789ABCDEF', substr(digits, 34, 1)) - 1) AS key_pitch,
    \\           ((instr('0123456789ABCDEF', substr(digits, 35, 1)) - 1) << 4) + (instr('0123456789ABCDEF', substr(digits, 36, 1)) - 1) AS key_mode,
    \\           ((instr('0123456789ABCDEF', substr(digits, 41, 1)) - 1) << 4) + ((instr('0123456789ABCDEF', substr(digits, 42, 1)) - 1) << 0) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 43, 1)) - 1) << 12) + ((instr('0123456789ABCDEF', substr(digits, 44, 1)) - 1) << 8) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 45, 1)) - 1) << 20) + ((instr('0123456789ABCDEF', substr(digits, 46, 1)) - 1) << 16) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 47, 1)) - 1) << 28) + ((instr('0123456789ABCDEF', substr(digits, 48, 1)) - 1) << 24) AS key_confidence,
    \\           ((instr('0123456789ABCDEF', substr(digits, 49, 1)) - 1) << 4) + ((instr('0123456789ABCDEF', substr(digits, 50, 1)) - 1) << 0) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 51, 1)) - 1) << 12) + ((instr('0123456789ABCDEF', substr(digits, 52, 1)) - 1) << 8) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 53, 1)) - 1) << 20) + ((instr('0123456789ABCDEF', substr(digits, 54, 1)) - 1) << 16) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 55, 1)) - 1) << 28) + ((instr('0123456789ABCDEF', substr(digits, 56, 1)) - 1) << 24) AS onset_rate,
    \\           ((instr('0123456789ABCDEF', substr(digits, 57, 1)) - 1) << 4) + ((instr('0123456789ABCDEF', substr(digits, 58, 1)) - 1) << 0) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 59, 1)) - 1) << 12) + ((instr('0123456789ABCDEF', substr(digits, 60, 1)) - 1) << 8) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 61, 1)) - 1) << 20) + ((instr('0123456789ABCDEF', substr(digits, 62, 1)) - 1) << 16) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 63, 1)) - 1) << 28) + ((instr('0123456789ABCDEF', substr(digits, 64, 1)) - 1) << 24) AS centroid
    \\      FROM (SELECT new.file_id AS file_id, new.source_identity AS source_identity, hex(new.result) AS digits
    \\            WHERE length(new.result) = 40 AND substr(new.result, 1, 6) = X'4F5241460100'))
    \\WHERE present & ~15 = 0 AND key_pitch < 12 AND key_mode <= 1;
    \\END;
    \\CREATE TRIGGER analysis_results_features_au AFTER UPDATE OF result ON analysis_results
    \\WHEN new.kind = 6 AND new.algorithm_id = 'orca.audio-features'
    \\  AND new.algorithm_version = 1
    \\  AND new.parameter_hash = X'8D91D6D7138EB255B30DD8F82BF8B042B0E78E5FE59C0A12EECD4861CB7D5C0E'
    \\BEGIN
    \\    DELETE FROM file_audio_features WHERE file_id = new.file_id;
    \\    INSERT INTO file_audio_features(file_id, source_identity, tempo_bpm, tempo_confidence,
    \\        key_pitch, key_mode, key_confidence, onset_rate, centroid_hz)
    \\SELECT file_id, source_identity,
    \\       CASE WHEN present & 1 THEN tempo / 1000.0 END,
    \\       CASE WHEN present & 1 THEN tempo_confidence / 1000000.0 END,
    \\       CASE WHEN present & 2 THEN key_pitch END,
    \\       CASE WHEN present & 2 THEN key_mode END,
    \\       CASE WHEN present & 2 THEN key_confidence / 1000000.0 END,
    \\       CASE WHEN present & 4 THEN onset_rate / 1000000.0 END,
    \\       CASE WHEN present & 8 THEN centroid / 1000.0 END
    \\FROM (SELECT file_id, source_identity,
    \\           ((instr('0123456789ABCDEF', substr(digits, 13, 1)) - 1) << 4) + (instr('0123456789ABCDEF', substr(digits, 14, 1)) - 1) + ((instr('0123456789ABCDEF', substr(digits, 15, 1)) - 1) << 12) + ((instr('0123456789ABCDEF', substr(digits, 16, 1)) - 1) << 8) AS present,
    \\           ((instr('0123456789ABCDEF', substr(digits, 17, 1)) - 1) << 4) + ((instr('0123456789ABCDEF', substr(digits, 18, 1)) - 1) << 0) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 19, 1)) - 1) << 12) + ((instr('0123456789ABCDEF', substr(digits, 20, 1)) - 1) << 8) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 21, 1)) - 1) << 20) + ((instr('0123456789ABCDEF', substr(digits, 22, 1)) - 1) << 16) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 23, 1)) - 1) << 28) + ((instr('0123456789ABCDEF', substr(digits, 24, 1)) - 1) << 24) AS tempo,
    \\           ((instr('0123456789ABCDEF', substr(digits, 25, 1)) - 1) << 4) + ((instr('0123456789ABCDEF', substr(digits, 26, 1)) - 1) << 0) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 27, 1)) - 1) << 12) + ((instr('0123456789ABCDEF', substr(digits, 28, 1)) - 1) << 8) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 29, 1)) - 1) << 20) + ((instr('0123456789ABCDEF', substr(digits, 30, 1)) - 1) << 16) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 31, 1)) - 1) << 28) + ((instr('0123456789ABCDEF', substr(digits, 32, 1)) - 1) << 24) AS tempo_confidence,
    \\           ((instr('0123456789ABCDEF', substr(digits, 33, 1)) - 1) << 4) + (instr('0123456789ABCDEF', substr(digits, 34, 1)) - 1) AS key_pitch,
    \\           ((instr('0123456789ABCDEF', substr(digits, 35, 1)) - 1) << 4) + (instr('0123456789ABCDEF', substr(digits, 36, 1)) - 1) AS key_mode,
    \\           ((instr('0123456789ABCDEF', substr(digits, 41, 1)) - 1) << 4) + ((instr('0123456789ABCDEF', substr(digits, 42, 1)) - 1) << 0) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 43, 1)) - 1) << 12) + ((instr('0123456789ABCDEF', substr(digits, 44, 1)) - 1) << 8) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 45, 1)) - 1) << 20) + ((instr('0123456789ABCDEF', substr(digits, 46, 1)) - 1) << 16) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 47, 1)) - 1) << 28) + ((instr('0123456789ABCDEF', substr(digits, 48, 1)) - 1) << 24) AS key_confidence,
    \\           ((instr('0123456789ABCDEF', substr(digits, 49, 1)) - 1) << 4) + ((instr('0123456789ABCDEF', substr(digits, 50, 1)) - 1) << 0) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 51, 1)) - 1) << 12) + ((instr('0123456789ABCDEF', substr(digits, 52, 1)) - 1) << 8) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 53, 1)) - 1) << 20) + ((instr('0123456789ABCDEF', substr(digits, 54, 1)) - 1) << 16) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 55, 1)) - 1) << 28) + ((instr('0123456789ABCDEF', substr(digits, 56, 1)) - 1) << 24) AS onset_rate,
    \\           ((instr('0123456789ABCDEF', substr(digits, 57, 1)) - 1) << 4) + ((instr('0123456789ABCDEF', substr(digits, 58, 1)) - 1) << 0) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 59, 1)) - 1) << 12) + ((instr('0123456789ABCDEF', substr(digits, 60, 1)) - 1) << 8) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 61, 1)) - 1) << 20) + ((instr('0123456789ABCDEF', substr(digits, 62, 1)) - 1) << 16) +
    \\               ((instr('0123456789ABCDEF', substr(digits, 63, 1)) - 1) << 28) + ((instr('0123456789ABCDEF', substr(digits, 64, 1)) - 1) << 24) AS centroid
    \\      FROM (SELECT new.file_id AS file_id, new.source_identity AS source_identity, hex(new.result) AS digits
    \\            WHERE length(new.result) = 40 AND substr(new.result, 1, 6) = X'4F5241460100'))
    \\WHERE present & ~15 = 0 AND key_pitch < 12 AND key_mode <= 1;
    \\END;
    \\CREATE TRIGGER analysis_results_features_ad AFTER DELETE ON analysis_results
    \\WHEN old.kind = 6 AND old.algorithm_id = 'orca.audio-features'
    \\  AND old.algorithm_version = 1
    \\  AND old.parameter_hash = X'8D91D6D7138EB255B30DD8F82BF8B042B0E78E5FE59C0A12EECD4861CB7D5C0E'
    \\BEGIN
    \\    DELETE FROM file_audio_features WHERE file_id = old.file_id AND source_identity = old.source_identity;
    \\END;
    \\
    \\CREATE TABLE recommendation_feedback (
    \\    recording_id INTEGER PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,
    \\    created_at INTEGER NOT NULL,
    \\    expires_at INTEGER NOT NULL
    \\);
    \\CREATE INDEX recommendation_feedback_by_expiry ON recommendation_feedback(expires_at);
    \\
    \\CREATE TABLE daily_mixes (
    \\    id INTEGER PRIMARY KEY,
    \\    ordinal INTEGER NOT NULL UNIQUE CHECK (ordinal >= 0),
    \\    kind INTEGER NOT NULL CHECK (kind IN (0, 1)),
    \\    genre_id INTEGER REFERENCES genres(id) ON DELETE SET NULL,
    \\    name TEXT NOT NULL,
    \\    local_day INTEGER NOT NULL,
    \\    generated_at INTEGER NOT NULL,
    \\    signals INTEGER NOT NULL DEFAULT 0 CHECK (signals >= 0),
    \\    left_out_recent INTEGER NOT NULL DEFAULT 0 CHECK (left_out_recent >= 0),
    \\    left_out_not_for_me INTEGER NOT NULL DEFAULT 0 CHECK (left_out_not_for_me >= 0),
    \\    left_out_hated INTEGER NOT NULL DEFAULT 0 CHECK (left_out_hated >= 0),
    \\    left_out_live INTEGER NOT NULL DEFAULT 0 CHECK (left_out_live >= 0),
    \\    left_out_other_mix INTEGER NOT NULL DEFAULT 0 CHECK (left_out_other_mix >= 0),
    \\    left_out_diversity INTEGER NOT NULL DEFAULT 0 CHECK (left_out_diversity >= 0),
    \\    favorite_count INTEGER NOT NULL DEFAULT 0 CHECK (favorite_count >= 0),
    \\    rarely_played_count INTEGER NOT NULL DEFAULT 0 CHECK (rarely_played_count >= 0),
    \\    never_played_count INTEGER NOT NULL DEFAULT 0 CHECK (never_played_count >= 0)
    \\);
    \\
    \\CREATE TABLE daily_mix_artists (
    \\    mix_id INTEGER NOT NULL REFERENCES daily_mixes(id) ON DELETE CASCADE,
    \\    position INTEGER NOT NULL CHECK (position >= 0),
    \\    artist_id INTEGER NOT NULL REFERENCES artists(id) ON DELETE CASCADE,
    \\    PRIMARY KEY(mix_id, position)
    \\) WITHOUT ROWID;
    \\CREATE INDEX daily_mix_artists_by_artist ON daily_mix_artists(artist_id);
    \\
    \\CREATE TABLE daily_mix_entries (
    \\    mix_id INTEGER NOT NULL REFERENCES daily_mixes(id) ON DELETE CASCADE,
    \\    position INTEGER NOT NULL CHECK (position >= 0),
    \\    recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
    \\    reason1_kind INTEGER CHECK (reason1_kind IS NULL OR reason1_kind BETWEEN 0 AND 9),
    \\    reason1_a INTEGER NOT NULL DEFAULT 0,
    \\    reason1_b INTEGER NOT NULL DEFAULT 0,
    \\    reason2_kind INTEGER CHECK (reason2_kind IS NULL OR reason2_kind BETWEEN 0 AND 9),
    \\    reason2_a INTEGER NOT NULL DEFAULT 0,
    \\    reason2_b INTEGER NOT NULL DEFAULT 0,
    \\    CHECK (reason2_kind IS NULL OR reason1_kind IS NOT NULL),
    \\    PRIMARY KEY(mix_id, position)
    \\) WITHOUT ROWID;
    \\CREATE INDEX daily_mix_entries_by_recording ON daily_mix_entries(recording_id);
;

const v3 =
    \\DROP TABLE daily_mix_entries;
    \\DROP TABLE daily_mix_artists;
    \\DROP TABLE daily_mixes;
    \\
    \\CREATE TABLE daily_mixes (
    \\    id INTEGER PRIMARY KEY,
    \\    ordinal INTEGER NOT NULL UNIQUE CHECK (ordinal >= 0),
    \\    kind INTEGER NOT NULL CHECK (kind BETWEEN 0 AND 6),
    \\    genre_id INTEGER REFERENCES genres(id) ON DELETE SET NULL,
    \\    decade INTEGER CHECK (decade IS NULL OR (decade BETWEEN 0 AND 9990 AND decade % 10 = 0)),
    \\    name TEXT NOT NULL,
    \\    local_day INTEGER NOT NULL,
    \\    generated_at INTEGER NOT NULL,
    \\    signals INTEGER NOT NULL DEFAULT 0 CHECK (signals >= 0),
    \\    left_out_recent INTEGER NOT NULL DEFAULT 0 CHECK (left_out_recent >= 0),
    \\    left_out_not_for_me INTEGER NOT NULL DEFAULT 0 CHECK (left_out_not_for_me >= 0),
    \\    left_out_hated INTEGER NOT NULL DEFAULT 0 CHECK (left_out_hated >= 0),
    \\    left_out_live INTEGER NOT NULL DEFAULT 0 CHECK (left_out_live >= 0),
    \\    left_out_other_mix INTEGER NOT NULL DEFAULT 0 CHECK (left_out_other_mix >= 0),
    \\    left_out_diversity INTEGER NOT NULL DEFAULT 0 CHECK (left_out_diversity >= 0),
    \\    favorite_count INTEGER NOT NULL DEFAULT 0 CHECK (favorite_count >= 0),
    \\    rarely_played_count INTEGER NOT NULL DEFAULT 0 CHECK (rarely_played_count >= 0),
    \\    never_played_count INTEGER NOT NULL DEFAULT 0 CHECK (never_played_count >= 0)
    \\);
    \\
    \\CREATE TABLE daily_mix_artists (
    \\    mix_id INTEGER NOT NULL REFERENCES daily_mixes(id) ON DELETE CASCADE,
    \\    position INTEGER NOT NULL CHECK (position >= 0),
    \\    artist_id INTEGER NOT NULL REFERENCES artists(id) ON DELETE CASCADE,
    \\    PRIMARY KEY(mix_id, position)
    \\) WITHOUT ROWID;
    \\CREATE INDEX daily_mix_artists_by_artist ON daily_mix_artists(artist_id);
    \\
    \\CREATE TABLE daily_mix_entries (
    \\    mix_id INTEGER NOT NULL REFERENCES daily_mixes(id) ON DELETE CASCADE,
    \\    position INTEGER NOT NULL CHECK (position >= 0),
    \\    recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
    \\    reason1_kind INTEGER CHECK (reason1_kind IS NULL OR reason1_kind BETWEEN 0 AND 9),
    \\    reason1_a INTEGER NOT NULL DEFAULT 0,
    \\    reason1_b INTEGER NOT NULL DEFAULT 0,
    \\    reason2_kind INTEGER CHECK (reason2_kind IS NULL OR reason2_kind BETWEEN 0 AND 9),
    \\    reason2_a INTEGER NOT NULL DEFAULT 0,
    \\    reason2_b INTEGER NOT NULL DEFAULT 0,
    \\    CHECK (reason2_kind IS NULL OR reason1_kind IS NOT NULL),
    \\    PRIMARY KEY(mix_id, position)
    \\) WITHOUT ROWID;
    \\CREATE INDEX daily_mix_entries_by_recording ON daily_mix_entries(recording_id);
;

const steps = [_][:0]const u8{ baseline, v2, v3 };

comptime {
    std.debug.assert(steps.len == current_version);
}

pub fn apply(db: sqlite.Database) sqlite.Error!void {
    if (try pendingFrom(db) == null) return;
    try db.exec("BEGIN IMMEDIATE;");
    errdefer db.exec("ROLLBACK;") catch {};
    const version = try pendingFrom(db) orelse return db.exec("COMMIT;");
    for (steps[version..]) |step| try db.exec(step);
    try db.exec(std.fmt.comptimePrint("PRAGMA user_version={d}; COMMIT;", .{current_version}));
}

fn pendingFrom(db: sqlite.Database) sqlite.Error!?usize {
    const version = try userVersion(db);
    if (version == current_version) return null;
    if (version < 0 or version > current_version) return error.SchemaVersionTooNew;
    return @intCast(version);
}

pub fn userVersion(db: sqlite.Database) sqlite.Error!i64 {
    var statement = try db.prepare("PRAGMA user_version;");
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    return statement.columnInt64(0);
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

const scalar = @import("columns.zig").scalar;

fn fresh() !sqlite.Database {
    const db = try sqlite.Database.open(":memory:");
    errdefer db.close();
    try apply(db);
    return db;
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

test "an empty database gets the current schema and the fallback volume" {
    const db = try fresh();
    defer db.close();
    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM files;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM locations;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM volumes;"));
    try std.testing.expectEqual(
        @as(i64, 1),
        try scalar(db, "SELECT id FROM volumes WHERE stable_key='legacy';"),
    );
}

test "applying the schema to a database that already has it changes nothing" {
    const db = try fresh();
    defer db.close();
    try db.exec("INSERT INTO files(id, audio_format, size_bytes) VALUES (1, 1, 10);");
    const schema = try schemaObjects(std.testing.allocator, db);
    defer std.testing.allocator.free(schema);

    try apply(db);

    const schema_again = try schemaObjects(std.testing.allocator, db);
    defer std.testing.allocator.free(schema_again);
    try std.testing.expectEqualStrings(schema, schema_again);
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM files;"));
    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
}

test "an unknown newer schema version is refused rather than opened" {
    const db = try fresh();
    defer db.close();
    try db.exec(std.fmt.comptimePrint(
        "PRAGMA user_version={d};",
        .{current_version + 1},
    ));
    try std.testing.expectError(error.SchemaVersionTooNew, apply(db));
    try db.exec("PRAGMA user_version=-1;");
    try std.testing.expectError(error.SchemaVersionTooNew, apply(db));
}

test "the feedback table rejects other scores and follows its recording" {
    const db = try fresh();
    defer db.close();
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

test "an acoustid submission follows its file, a provider lease needs an owner, and no proposal starts accepted in bulk" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO files(id, audio_format, size_bytes) VALUES (1, 1, 10), (2, 1, 10);
        \\INSERT INTO identification_proposals(file_id, provider, provider_id, confidence, payload, state, updated_at)
        \\VALUES (1, 'musicbrainz', 'a', 0.9, x'7b7d', 1, 100);
        \\INSERT INTO identification_searches(file_id, provider, searched_at) VALUES (2, 'musicbrainz', 300);
        \\INSERT INTO acoustid_submissions(file_id, recording_mbid, submission_id, submitted_at) VALUES (2, 'c', 7, 500);
    );

    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT accepted_in_bulk FROM identification_proposals;"));
    try std.testing.expectError(
        error.SqlFailed,
        db.exec("INSERT INTO provider_leases(service, owner, expires_at) VALUES ('musicbrainz', NULL, 0);"),
    );
    try db.exec("DELETE FROM files WHERE id = 2;");
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM acoustid_submissions;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM identification_searches;"));
}

test "every mutation state keeps the number the journal stores" {
    const State = repository.MutationState;
    for ([_]struct { State, i64 }{
        .{ .planned, 0 }, .{ .staged, 1 },               .{ .committed, 2 }, .{ .rolled_back, 3 },
        .{ .failed, 4 },  .{ .needs_reconciliation, 5 }, .{ .undoing, 6 },
    }) |pair| try std.testing.expectEqual(pair[1], @as(i64, @backingInt(pair[0])));
}

test "release artwork goes when its release does" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO releases(id, title, release_key) VALUES (1, 'Ginger', 'ginger');
        \\INSERT INTO release_artwork(release_id, musicbrainz_release_id, image, mime, fetched_at)
        \\VALUES (1, '2e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b', NULL, NULL, 1800000000);
    );
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM release_artwork;"));
    try db.exec("DELETE FROM releases WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM release_artwork;"));
}

test "the ratings and playlist tables reject invalid rows and follow their recording and playlist" {
    const db = try fresh();
    defer db.close();
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

test "a recording verification needs a recording and follows its file, and a proposal starts outside an album group" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO files(id, audio_format, size_bytes, quick_hash) VALUES (1, 1, 10, x'01'), (2, 1, 10, NULL);
        \\INSERT INTO identification_proposals(file_id, provider, provider_id, confidence, payload, state, updated_at)
        \\VALUES (1, 'acoustid', 'a', 0.9, x'7b7d', 0, 100);
    );

    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM identification_proposals WHERE album_group IS NULL;"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO recording_verifications(file_id, recording_mbid, outcome, verified_at) VALUES (9, 'a', 0, 0);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO recording_verifications(file_id, outcome, verified_at) VALUES (1, 0, 0);"));
    try db.exec(
        \\INSERT INTO recording_verifications(file_id, quick_hash, recording_mbid, outcome, heard, verified_at)
        \\VALUES (1, x'01', 'a', 0, '[]', 0), (2, NULL, 'b', 3, NULL, 0);
        \\DELETE FROM files WHERE id = 1;
    );
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM recording_verifications;"));
}

test "a health issue's related file and its dismissals follow their file" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO files(id, audio_format, size_bytes, quick_hash) VALUES (1, 1, 10, x'01'), (2, 1, 10, NULL);
        \\INSERT INTO library_health_issues(file_id, kind, severity, details) VALUES
        \\    (1, 5, 1, 'clipped'), (2, 9, 1, 'content also appears at /m/a.flac');
    );

    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM library_health_issues WHERE related_file_id IS NULL AND similarity IS NULL;"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO health_dismissals VALUES (9, 5, NULL, 0);"));
    try std.testing.expectError(error.SqlFailed, db.exec("UPDATE library_health_issues SET related_file_id = 9 WHERE file_id = 2;"));
    try db.exec(
        \\UPDATE library_health_issues SET related_file_id = 1 WHERE file_id = 2;
        \\INSERT INTO health_dismissals VALUES (1, 5, x'01', 0), (2, 9, NULL, 0);
        \\DELETE FROM files WHERE id = 1;
    );
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM library_health_issues WHERE file_id = 2 AND related_file_id IS NULL;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM health_dismissals;"));
}

test "an album love follows its Release" {
    const db = try fresh();
    defer db.close();
    try db.exec("INSERT INTO releases(id, title, release_key) VALUES (1, 'Pink Moon', 'a'), (2, 'Bryter Layter', 'b');");

    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO release_loves VALUES (9, 0);"));
    try db.exec(
        \\INSERT INTO release_loves VALUES (1, 100), (2, 200);
        \\DELETE FROM releases WHERE id = 1;
    );
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT release_id FROM release_loves;"));
}

test "cached lyrics follow their Track and are not instrumental unless stated" {
    const db = try fresh();
    defer db.close();
    try db.exec("INSERT INTO tracks(id, title) VALUES (1, 'Pink Moon'), (2, 'Road');");

    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO track_lyrics(track_id, query_digest, fetched_at) VALUES (9, x'00', 0);"));
    try db.exec(
        \\INSERT INTO track_lyrics(track_id, query_digest, synced, fetched_at) VALUES (1, x'01', '[00:01.00]a', 100);
        \\INSERT INTO track_lyrics(track_id, query_digest, fetched_at) VALUES (2, x'02', 200);
        \\DELETE FROM tracks WHERE id = 1;
    );
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT track_id FROM track_lyrics;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT instrumental FROM track_lyrics;"));
}

test "a file changing recording carries its listens and its recordings' play counts" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'Pink Moon'), (2, 'Road');
        \\INSERT INTO files(id, recording_id) VALUES (10, 1), (11, 1), (12, 2);
        \\INSERT INTO listens(file_id, recording_id, started_at, listened_ms, title, artist) VALUES
        \\    (10, 1, 100, 1, 'Pink Moon', 'Nick Drake'),
        \\    (11, 1, 300, 1, 'Pink Moon', 'Nick Drake'),
        \\    (10, 1, 200, 1, 'Pink Moon', 'Nick Drake'),
        \\    (12, 2, 50, 1, 'Road', 'Nick Drake'),
        \\    (NULL, NULL, 400, 1, 'Gone', 'Nick Drake');
        \\INSERT INTO recording_play_stats(recording_id, play_count, last_played_at)
        \\    SELECT recording_id, count(*), max(started_at) FROM listens
        \\    WHERE recording_id IS NOT NULL GROUP BY recording_id;
    );

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
}

test "a track genre needs its Track and Genre, takes each ordinal once, and goes with its Track" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO tracks(id, title) VALUES (1, 'One'), (2, 'Two');
        \\INSERT INTO genres(id, name, key) VALUES (1, 'Rock', 'rock'), (2, 'Folk', 'folk');
        \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance) VALUES (1, 1, 0, 0), (1, 2, 1, 0), (2, 1, 0, 0);
    );

    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO track_genres VALUES (9, 1, 0, 0);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO track_genres VALUES (2, 9, 1, 0);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO track_genres VALUES (2, 2, 0, 0);"));
    try db.exec("DELETE FROM tracks WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM track_genres;"));
}

test "artist info, links, related artists, loves and release info follow their Artist and Release" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO artists(id, name, key) VALUES (1, 'Nick Drake', 'nickdrake'), (2, 'John Martyn', 'johnmartyn');
        \\INSERT INTO releases(id, title, release_key) VALUES (1, 'Pink Moon', 'a'), (2, 'Solid Air', 'b');
    );

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
}

test "a playlist starts manual, user-made and untagged, and its tags go with it" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'One'), (2, 'Two'), (3, 'Three');
        \\INSERT INTO playlists(id, name, created_at, updated_at) VALUES (1, 'Mix', 10, 20), (2, 'Other', 30, 40);
        \\INSERT INTO playlist_entries VALUES (1, 0, 3, 0), (1, 1, 1, 0), (1, 2, 2, 0), (1, 3, 3, 0), (2, 0, 2, 0);
    );

    try std.testing.expectEqual(@as(i64, 1), try scalar(db,
        \\SELECT group_concat(recording_id, ',') = '3,1,2,3' FROM
        \\(SELECT recording_id FROM playlist_entries WHERE playlist_id = 1 ORDER BY position);
    ));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db,
        \\SELECT count(*) FROM playlists WHERE description = '' AND pinned_at IS NULL AND loved_at IS NULL
        \\  AND kind = 0 AND rules IS NULL AND creator = 0;
    ));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO playlist_tags VALUES (9, 0, 'x');"));
    try db.exec("INSERT INTO playlist_tags VALUES (1, 0, 'focus'), (1, 1, 'lofi'); DELETE FROM playlists WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM playlist_tags;"));
}

test "the search index holds every Artist, Release, Playlist and Genre written, and track_search every Track" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO artists(id, name, sort_name, key) VALUES (1, 'Sigur Rós', 'Sigur Rós', 'sigur ros'), (2, 'Aminé', 'Aminé', 'amine');
        \\INSERT INTO releases(id, title, album_artist, album_artist_id) VALUES (1, 'Ágætis byrjun', 'Sigur Rós', 1);
        \\INSERT INTO recordings(id, title) VALUES (1, 'Starálfur');
        \\INSERT INTO tracks(id, recording_id, release_id, title, artist, album, artist_id)
        \\    VALUES (1, 1, 1, 'Starálfur', 'Sigur Rós', 'Ágætis byrjun', 1);
        \\INSERT INTO playlists(id, name, description, created_at, updated_at) VALUES (1, 'Morning', 'Quiet', 0, 0);
        \\INSERT INTO genres(id, name, key) VALUES (1, 'Post-Rock', 'post rock');
    );

    try std.testing.expectEqual(@as(i64, 5), try scalar(db, "SELECT count(*) FROM search_index;"));
    try std.testing.expectEqual(@as(i64, 5), try scalar(db,
        \\SELECT count(*) FROM search_index WHERE rowid = entity_id * 8 + kind AND
        \\    ((kind = 0 AND entity_id = 1 AND title = 'Sigur Rós' AND subtitle = '') OR
        \\     (kind = 0 AND entity_id = 2 AND title = 'Aminé' AND subtitle = '') OR
        \\     (kind = 1 AND title = 'Ágætis byrjun' AND subtitle = 'Sigur Rós') OR
        \\     (kind = 3 AND title = 'Morning' AND subtitle = 'Quiet') OR
        \\     (kind = 4 AND title = 'Post-Rock' AND subtitle = ''));
    ));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, search_index_drift_sql));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM search_index WHERE search_index MATCH '\"sigur\"* AND \"ros\"*';"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT entity_id FROM search_index WHERE search_index MATCH '\"amin\"*';"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT rowid FROM track_search WHERE track_search MATCH '\"staralfur\"';"));
    try db.exec("INSERT INTO search_index(search_index, rank) VALUES ('integrity-check', 0);");
}

test "a related artist photo is keyed by MusicBrainz artist ID and its details need a photo" {
    const db = try fresh();
    defer db.close();
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
}

test "a diagnostics result written, rewritten or removed keeps the file's loudness equal to its float, sign and exponent included" {
    const db = try fresh();
    defer db.close();
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

test "track_search reindexes a Track only when its text changes, and search_index never holds a Track" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO artists(id, name, sort_name, key) VALUES (1, 'Sigur Rós', 'Sigur Rós', 'sigur ros');
        \\INSERT INTO releases(id, title, album_artist, album_artist_id) VALUES (1, 'Ágætis byrjun', 'Sigur Rós', 1);
        \\INSERT INTO tracks(id, release_id, title, artist, album, album_artist, artist_id) VALUES
        \\    (1, 1, 'Starálfur', 'Sigur Rós', 'Ágætis byrjun', 'Sigur Rós', 1),
        \\    (2, 1, 'Svefn-g-englar', 'Sigur Rós', 'Ágætis byrjun', 'Sigur Rós', 1);
        \\INSERT INTO playlists(id, name, description, created_at, updated_at) VALUES (1, 'Morning', 'Quiet', 0, 0);
        \\INSERT INTO genres(id, name, key) VALUES (1, 'Post-Rock', 'post rock');
    );

    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM search_index WHERE kind = 2;"));
    try std.testing.expectEqual(@as(i64, 4), try scalar(db, "SELECT count(*) FROM search_index;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, search_index_drift_sql));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM search_index WHERE search_index MATCH '\"staralfur\"';"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT rowid FROM track_search WHERE track_search MATCH '{title}: \"staralfur\"';"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM track_search WHERE track_search MATCH 'artist:Sigur AND \"svefn\"';"));
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
}

test "genre totals equal a count over the Tracks after every write" {
    const db = try fresh();
    defer db.close();
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

    try std.testing.expectEqual(@as(i64, 0), try scalar(db, genre_totals_drift_sql));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM genre_totals;"));
    try std.testing.expectEqual(@as(i64, 3), try scalar(db, "SELECT track_count FROM genre_totals WHERE genre_id = 1;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT release_count FROM genre_totals WHERE genre_id = 1;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT artist_count FROM genre_totals WHERE genre_id = 1;"));
    try std.testing.expectEqual(@as(i64, 7000), try scalar(db, "SELECT duration_ms FROM genre_totals WHERE genre_id = 1;"));
    try std.testing.expectEqual(@as(i64, 3), try scalar(db, "SELECT release_count FROM genre_totals WHERE genre_id = 2;"));
    try std.testing.expectEqual(@as(i64, 3), try scalar(db, "SELECT artist_count FROM genre_totals WHERE genre_id = 2;"));
    try std.testing.expectEqual(@as(i64, 2500), try scalar(db, "SELECT duration_ms FROM genre_totals WHERE genre_id = 2;"));

    const writes = [_][:0]const u8{
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
    for (writes) |write| {
        try db.exec(write);
        try std.testing.expectEqual(@as(i64, 0), try scalar(db, genre_totals_drift_sql));
    }
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM genre_totals WHERE genre_id = 3;"));
    try db.exec("DELETE FROM track_genres;");
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM genre_totals;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM genre_release_tracks;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM genre_artist_refs;"));
}

test "a release group cover goes when the last Artist credited with its group lets it go" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO artists(id, name, sort_name, key) VALUES (1, 'Host', 'Host', 'host'), (2, 'Guest', 'Guest', 'guest');
        \\INSERT INTO artist_release_groups(artist_id, mbid, title, position) VALUES
        \\    (1, 'shared', 'Together', 0), (2, 'shared', 'Together', 0), (1, 'own', 'Alone', 1);
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

test "folder images and folder scans go with their root, and an image role is bounded" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO volumes(id, stable_key) VALUES (2, 'music');
        \\INSERT INTO library_roots(id, volume_id, path) VALUES (1, 2, '/m');
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

test "a listen is syncable unless stored as local only" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'One');
        \\INSERT INTO files(id, audio_format, size_bytes, recording_id) VALUES (1, 1, 10, 1);
        \\INSERT INTO listens(file_id, recording_id, started_at, listened_ms, title, artist)
        \\VALUES (1, 1, 1700000000, 90000, 'One', 'Artist');
        \\INSERT INTO listens(file_id, recording_id, started_at, listened_ms, title, artist, syncable)
        \\VALUES (1, 1, 1700000100, 31000, 'One', 'Artist', 0);
    );
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM listens WHERE syncable = 1 AND started_at = 1700000000;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM listens WHERE syncable = 0;"));
}

test "release artwork keeps one image per kind and source, which goes with its release along with its cover candidates" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO releases(id, title, release_key) VALUES (1, 'One', 'one');
        \\INSERT INTO release_artwork(release_id, musicbrainz_release_id, image, mime, fetched_at) VALUES
        \\    (1, '2e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b', X'FFD8FFE000104A464946000100FFD9', 'image/jpeg', 1800000000);
        \\INSERT INTO release_artwork(release_id, kind, source, image, mime, width, height, fetched_at)
        \\VALUES (1, 1, 3, X'FFD8FF', 'image/jpeg', 1400, 1400, 1800000003);
        \\INSERT INTO cover_art_candidates(release_id, caa_id, musicbrainz_release_id, kind, width, height, mime, approved, thumbnail, fetched_at)
        \\VALUES (1, 1234, 'mbid', 0, 1200, 1200, 'image/jpeg', 1, X'FFD8FF', 1800000004);
    );
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM release_artwork WHERE kind = 0 AND source = 2 AND width IS NULL AND height IS NULL;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM release_artwork WHERE release_id = 1;"));
    try std.testing.expectError(error.SqlFailed, db.exec(
        "INSERT INTO release_artwork(release_id, kind, source, fetched_at) VALUES (1, 0, 3, 0);",
    ));
    try db.exec("DELETE FROM releases WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM release_artwork;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM cover_art_candidates;"));
}

test "a dismissed release candidate is recorded once and goes with its release" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO releases(id, title, album_artist, release_date, release_key) VALUES
        \\    (1, 'ONEPOINTFIVE', 'Amine', '2018', 'one'), (2, 'Limbo', 'Amine', '2020', 'two');
        \\INSERT INTO dismissed_release_candidates(release_id, musicbrainz_release_id, dismissed_at)
        \\VALUES (1, '4e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b', 1800000000), (2, '4e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b', 1800000000);
    );
    try std.testing.expectError(error.SqlFailed, db.exec(
        "INSERT INTO dismissed_release_candidates(release_id, musicbrainz_release_id, dismissed_at) VALUES (1, '4e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b', 0);",
    ));
    try db.exec("DELETE FROM releases WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM dismissed_release_candidates;"));
}

test "the saved player state is one bounded row, and saved positions go with their track" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'One');
        \\INSERT INTO releases(id, title, release_key) VALUES (1, 'Mix', 'mix');
        \\INSERT INTO tracks(id, release_id, title, recording_id) VALUES (1, 1, 'One', 1), (2, 1, 'Two', NULL);
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
}

test "metadata proposals check their category, state, gap and track count, and go with their release and track" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO releases(id, title, album_artist, release_key) VALUES (1, 'Blonde', 'Frank Ocean', 'blonde'), (2, 'Endless', 'Frank Ocean', 'endless');
        \\INSERT INTO tracks(id, release_id, title) VALUES (1, 1, 'Nikes'), (2, 2, 'Device Control');
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
    try std.testing.expectEqual(@as(i64, 4), try scalar(db, "SELECT count(*) FROM metadata_proposals WHERE tracks IS NULL AND gap IS NULL;"));
    try db.exec("UPDATE metadata_proposals SET gap = 6 WHERE id = 1; UPDATE metadata_proposals SET tracks = 1 WHERE id = 2;");
    try std.testing.expectEqual(@as(i64, 7), try scalar(db, "SELECT sum(COALESCE(gap, 0) + COALESCE(tracks, 0)) FROM metadata_proposals;"));
    try std.testing.expectError(error.SqlFailed, db.exec("UPDATE metadata_proposals SET gap = 0 WHERE id = 1;"));
    try std.testing.expectError(error.SqlFailed, db.exec("UPDATE metadata_proposals SET tracks = -1 WHERE id = 2;"));

    try db.exec("DELETE FROM tracks WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 3), try scalar(db, "SELECT count(*) FROM metadata_proposals;"));
    try db.exec("DELETE FROM tracks WHERE id = 2; DELETE FROM releases WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 4), try scalar(db, "SELECT id FROM metadata_proposals;"));
}

test "an audio hash tier is 1 or 2" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO files(id, audio_format, size_bytes, quick_hash) VALUES (1, 1, 10, X'01'), (2, 1, 10, X'02');
        \\UPDATE files SET audio_hash = X'BB', audio_hash_tier = 1 WHERE id = 1;
        \\UPDATE files SET audio_hash = X'CC', audio_hash_tier = 2 WHERE id = 2;
    );
    try std.testing.expectError(error.SqlFailed, db.exec("UPDATE files SET audio_hash_tier = 3 WHERE id = 1;"));
}

fn atBaseline() !sqlite.Database {
    const db = try sqlite.Database.open(":memory:");
    errdefer db.close();
    try db.exec(baseline);
    try db.exec("PRAGMA user_version=1;");
    try db.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'One'), (2, 'Two');
        \\INSERT INTO files(id, recording_id, audio_format, size_bytes) VALUES (1, 1, 1, 10), (2, 2, 1, 10);
        \\INSERT INTO listens(file_id, recording_id, started_at, listened_ms, title, artist)
        \\VALUES (1, 1, 100, 1000, 'One', 'A'), (1, 1, 200, 1000, 'One', 'A'), (2, 2, 300, 1000, 'Two', 'B');
        \\INSERT INTO feedback(recording_id, score, updated_at) VALUES (1, 1, 0), (2, -1, 0);
        \\INSERT INTO ratings VALUES (1, 80, 0);
        \\INSERT INTO playlists(id, name, created_at, updated_at) VALUES (1, 'Mix', 0, 0);
        \\INSERT INTO playlist_entries VALUES (1, 0, 1, 0), (1, 1, 2, 0);
    );
    return db;
}

fn expectBaselineRowsKept(db: sqlite.Database) !void {
    try std.testing.expectEqual(@as(i64, 3), try scalar(db, "SELECT count(*) FROM listens;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM feedback;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM ratings;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM playlists;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM playlist_entries;"));
}

const v2_objects_count_sql =
    \\SELECT count(*) FROM sqlite_master WHERE name IN (
    \\    'listens_by_time', 'file_audio_features', 'file_audio_features_by_tempo',
    \\    'file_audio_features_by_onset_rate', 'file_audio_features_by_centroid',
    \\    'analysis_results_features_ai', 'analysis_results_features_au', 'analysis_results_features_ad',
    \\    'recommendation_feedback', 'recommendation_feedback_by_expiry', 'daily_mixes',
    \\    'daily_mix_artists', 'daily_mix_artists_by_artist', 'daily_mix_entries',
    \\    'daily_mix_entries_by_recording');
;

test "a version 1 library upgrades to the current version keeping its rows and gaining the recommendation tables" {
    const db = try atBaseline();
    defer db.close();

    try apply(db);

    try std.testing.expectEqual(current_version, try scalar(db, "PRAGMA user_version;"));
    try expectBaselineRowsKept(db);
    try std.testing.expectEqual(@as(i64, 15), try scalar(db, v2_objects_count_sql));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM pragma_foreign_key_check;"));
}

test "a failing version 2 step rolls back and leaves the library at version 1" {
    const db = try atBaseline();
    defer db.close();
    try db.exec("CREATE INDEX daily_mix_entries_by_recording ON listens(title);");

    try std.testing.expectError(error.SqlFailed, apply(db));

    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "PRAGMA user_version;"));
    try expectBaselineRowsKept(db);
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, v2_objects_count_sql));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM sqlite_master WHERE name = 'listens_by_time';"));
}

fn atVersion2() !sqlite.Database {
    const db = try atBaseline();
    errdefer db.close();
    try db.exec(v2);
    try db.exec(
        \\PRAGMA user_version=2;
        \\INSERT INTO artists(id, name) VALUES (1, 'A');
        \\INSERT INTO recommendation_feedback VALUES (1, 10, 100), (2, 20, 200);
        \\INSERT INTO daily_mixes(id, ordinal, kind, name, local_day, generated_at) VALUES (1, 0, 1, 'Rarely played', 20000, 0);
        \\INSERT INTO daily_mix_artists VALUES (1, 0, 1);
        \\INSERT INTO daily_mix_entries(mix_id, position, recording_id) VALUES (1, 0, 1);
    );
    return db;
}

test "a version 2 library upgrades to version 3 keeping Not for me and its other rows, with the fresh schema" {
    const db = try atVersion2();
    defer db.close();

    try apply(db);

    try std.testing.expectEqual(@as(i64, 3), try scalar(db, "PRAGMA user_version;"));
    try expectBaselineRowsKept(db);
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM recommendation_feedback WHERE created_at * 10 = expires_at;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM daily_mixes;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM daily_mix_artists;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM daily_mix_entries;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM pragma_foreign_key_check;"));
    const upgraded = try schemaObjects(std.testing.allocator, db);
    defer std.testing.allocator.free(upgraded);
    const created = try fresh();
    defer created.close();
    const fresh_schema = try schemaObjects(std.testing.allocator, created);
    defer std.testing.allocator.free(fresh_schema);
    try std.testing.expectEqualStrings(fresh_schema, upgraded);
}

test "a failing version 3 step rolls back and leaves the library at version 2 with its mixes" {
    const db = try atVersion2();
    defer db.close();
    try db.exec("CREATE TABLE fail_v3 (id INTEGER); DROP INDEX daily_mix_artists_by_artist; CREATE INDEX daily_mix_artists_by_artist ON fail_v3(id);");

    try std.testing.expectError(error.SqlFailed, apply(db));

    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM daily_mixes;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM daily_mix_entries;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(db, "SELECT count(*) FROM recommendation_feedback;"));
}

test "audio features need a known key and follow their file" {
    const db = try fresh();
    defer db.close();
    try db.exec("INSERT INTO files(id, audio_format, size_bytes) VALUES (1, 1, 10);");

    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO file_audio_features(file_id, source_identity, key_pitch, key_mode) VALUES (1, X'00', 12, 0);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO file_audio_features(file_id, source_identity, key_pitch, key_mode) VALUES (1, X'00', 0, 2);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO file_audio_features(file_id, source_identity, key_pitch) VALUES (1, X'00', 3);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO file_audio_features(file_id, source_identity) VALUES (2, X'00');"));
    try db.exec("INSERT INTO file_audio_features(file_id, source_identity, tempo_bpm, key_pitch, key_mode) VALUES (1, X'00', 120.0, 9, 1);");
    try db.exec("DELETE FROM files WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM file_audio_features;"));
}

fn expectFeatureRows(db: sqlite.Database, expected: []const u8) !void {
    var statement = try db.prepare(
        "SELECT group_concat(coalesce(row, ''), ';') FROM (SELECT file_id || ',' || source || ',' || " ++
            "coalesce(tempo_bpm, '-') || ',' || coalesce(tempo_confidence, '-') || ',' || " ++
            "coalesce(key_pitch, '-') || ',' || coalesce(key_mode, '-') || ',' || coalesce(key_confidence, '-') || ',' || " ++
            "coalesce(onset_rate, '-') || ',' || coalesce(centroid_hz, '-') AS row FROM (" ++
            "SELECT file_id, hex(source_identity) AS source, tempo_bpm, tempo_confidence, key_pitch, key_mode, " ++
            "key_confidence, onset_rate, centroid_hz FROM file_audio_features ORDER BY file_id));",
    );
    defer statement.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try statement.step());
    try std.testing.expectEqualStrings(expected, statement.columnText(0));
}

test "an audio features result written, rewritten or removed keeps the file's features row, and malformed or foreign results are ignored" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO files(id, size_bytes, quick_hash) VALUES
        \\    (1, 100, x'01'), (2, 100, x'02'), (3, 100, x'03'), (4, 100, x'04'),
        \\    (5, 100, x'05'), (6, 100, x'06'), (7, 100, x'07'), (8, 100, x'08');
        \\INSERT INTO analysis_results(file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity, result) VALUES
        \\    (1, 6, 'orca.audio-features', 1, x'8D91D6D7138EB255B30DD8F82BF8B042B0E78E5FE59C0A12EECD4861CB7D5C0E', x'01',
        \\        x'4F52414601000F00B4D6010090D0030002010000A0860100A0252600DDE31600400D030000000000'),
        \\    (2, 6, 'orca.audio-features', 1, x'8D91D6D7138EB255B30DD8F82BF8B042B0E78E5FE59C0A12EECD4861CB7D5C0E', x'02',
        \\        CAST(x'4F52414601000000' || zeroblob(32) AS BLOB)),
        \\    (3, 6, 'orca.audio-features', 1, x'8D91D6D7138EB255B30DD8F82BF8B042B0E78E5FE59C0A12EECD4861CB7D5C0E', x'03',
        \\        CAST(x'4F52414401000000' || zeroblob(32) AS BLOB)),
        \\    (4, 6, 'orca.audio-features', 1, x'8D91D6D7138EB255B30DD8F82BF8B042B0E78E5FE59C0A12EECD4861CB7D5C0E', x'04',
        \\        CAST(x'4F52414602000000' || zeroblob(32) AS BLOB)),
        \\    (5, 6, 'orca.audio-features', 1, x'8D91D6D7138EB255B30DD8F82BF8B042B0E78E5FE59C0A12EECD4861CB7D5C0E', x'05',
        \\        CAST(x'4F52414601000000' || zeroblob(31) AS BLOB)),
        \\    (6, 6, 'orca.audio-features', 1, zeroblob(32), x'06',
        \\        CAST(x'4F52414601000000' || zeroblob(32) AS BLOB)),
        \\    (7, 6, 'orca.audio-features', 1, x'8D91D6D7138EB255B30DD8F82BF8B042B0E78E5FE59C0A12EECD4861CB7D5C0E', x'07',
        \\        CAST(x'4F52414601001000' || zeroblob(32) AS BLOB)),
        \\    (8, 6, 'orca.audio-features', 1, x'8D91D6D7138EB255B30DD8F82BF8B042B0E78E5FE59C0A12EECD4861CB7D5C0E', x'08',
        \\        CAST(x'4F52414601000200' || zeroblob(8) || x'0C00' || zeroblob(22) AS BLOB));
    );
    try expectFeatureRows(db, "1,01,120.5,0.25,2,1,0.1,2.5,1500.125;2,02,-,-,-,-,-,-,-");

    try db.exec(
        \\INSERT INTO analysis_results(file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity, result) VALUES
        \\    (1, 6, 'orca.audio-features', 1, x'8D91D6D7138EB255B30DD8F82BF8B042B0E78E5FE59C0A12EECD4861CB7D5C0E', x'01',
        \\        x'4F5241460100040000000000000000000000000000000000605B030000000000400D030000000000')
        \\ON CONFLICT DO UPDATE SET result = excluded.result;
        \\INSERT INTO analysis_results(file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity, result) VALUES
        \\    (2, 6, 'orca.audio-features', 1, x'8D91D6D7138EB255B30DD8F82BF8B042B0E78E5FE59C0A12EECD4861CB7D5C0E', x'2b',
        \\        CAST(x'4F52414601000800' || zeroblob(20) || x'40420F00' || zeroblob(8) AS BLOB));
    );
    try expectFeatureRows(db, "1,01,-,-,-,-,-,0.22,-;2,2B,-,-,-,-,-,-,1000.0");

    try db.exec("DELETE FROM analysis_results WHERE file_id = 2 AND source_identity = x'02';");
    try expectFeatureRows(db, "1,01,-,-,-,-,-,0.22,-;2,2B,-,-,-,-,-,-,1000.0");
    try db.exec("DELETE FROM analysis_results WHERE file_id = 2;");
    try expectFeatureRows(db, "1,01,-,-,-,-,-,0.22,-");
    try db.exec("DELETE FROM analysis_results WHERE file_id = 1; DELETE FROM files WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM file_audio_features;"));
}

test "a daily mix keeps one row per ordinal, its artists and entries go with it, and an entry goes with its recording" {
    const db = try fresh();
    defer db.close();
    try db.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'One'), (2, 'Two');
        \\INSERT INTO artists(id, name) VALUES (1, 'A');
        \\INSERT INTO genres(id, name, key) VALUES (1, 'Hip Hop', 'hip hop');
        \\INSERT INTO daily_mixes(id, ordinal, kind, genre_id, name, local_day, generated_at) VALUES (1, 0, 0, 1, 'Hip Hop Mix', 20000, 0);
        \\INSERT INTO daily_mix_artists VALUES (1, 0, 1);
        \\INSERT INTO daily_mix_entries(mix_id, position, recording_id, reason1_kind, reason1_a, reason1_b) VALUES (1, 0, 1, 0, 42, 1700000000);
        \\INSERT INTO daily_mix_entries(mix_id, position, recording_id) VALUES (1, 1, 2);
        \\INSERT INTO recommendation_feedback VALUES (2, 0, 100);
    );

    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO daily_mixes(ordinal, kind, name, local_day, generated_at) VALUES (0, 1, 'Rarely played', 20000, 0);"));
    try db.exec("INSERT INTO daily_mixes(ordinal, kind, decade, name, local_day, generated_at) VALUES (1, 6, NULL, 'Wind down', 20000, 0), (2, 2, 1990, '1990s', 20000, 0);");
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO daily_mixes(ordinal, kind, name, local_day, generated_at) VALUES (3, 7, 'Other', 20000, 0);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO daily_mixes(ordinal, kind, decade, name, local_day, generated_at) VALUES (3, 2, 1995, '1990s', 20000, 0);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO daily_mix_entries(mix_id, position, recording_id, reason1_kind) VALUES (1, 2, 1, 10);"));
    try std.testing.expectError(error.SqlFailed, db.exec("INSERT INTO daily_mix_entries(mix_id, position, recording_id, reason2_kind) VALUES (1, 2, 1, 0);"));

    try db.exec("DELETE FROM genres WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM daily_mixes WHERE id = 1 AND genre_id IS NULL;"));
    try db.exec("DELETE FROM recordings WHERE id = 2;");
    try std.testing.expectEqual(@as(i64, 1), try scalar(db, "SELECT count(*) FROM daily_mix_entries;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM recommendation_feedback;"));
    try db.exec("DELETE FROM daily_mixes WHERE id = 1;");
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM daily_mix_entries;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(db, "SELECT count(*) FROM daily_mix_artists;"));
}
