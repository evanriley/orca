INSERT INTO files(id, recording_id, audio_format, codec, size_bytes, sample_rate, bit_depth, channels, duration_ms,
    quick_hash, audio_hash, content_hash, first_seen_at, last_scan_generation, content_hash_algorithm, audio_hash_tier) VALUES
    (5, 1, 1, 'flac', 5000, 44100, 16, 2, 180000, x'15', x'a5', x'c5', 1700005300, 2, 1, 1);
INSERT INTO locations(id, file_id, volume_id, root_id, uri, size_bytes, modified_ns, state, last_seen_generation) VALUES
    (6, 5, 1, 1, 'file:///music/alpha/dawn-live.flac', 5000, 1700000000000000020, 'unverified', 2),
    (7, 5, 1, 1, 'file:///music/alpha/dawn-live-copy.flac', 5000, 1700000000000000021, 'present', 2);
UPDATE locations SET state = 'missing', missing_since = 1700005301 WHERE id = 3;
INSERT INTO analysis_results(file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity, result, created_at) VALUES
    (5, 1, 'orca.audio-diagnostics', 4, x'A5D7A479D64C3952CA86E311AFFEBB0CFCA41DAF406C7AA159255961CF9145CE', x'c5',
        CAST(x'4F5241440200' || x'0100' || x'00002041' || zeroblob(60) AS BLOB), 1700005302);
INSERT INTO tracks(id, recording_id, release_id, title, album, album_artist, duration_ms, track_number, disc_number,
    created_at, artist, preferred_file_id, artist_id, track_total, disc_total, explicit) VALUES
    (14, 1, 3, 'Dawn (live)', 'Various Nights', 'Various Artists', 180000, 1, 1, 1700005303, 'Alpha Band', 5, 1, 1, 1, 0);
INSERT INTO track_genres(track_id, genre_id, ordinal, provenance) VALUES (14, 3, 0, 0), (14, 1, 1, 0);
UPDATE track_genres SET ordinal = 2 WHERE track_id = 10 AND genre_id = 2;
