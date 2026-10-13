UPDATE volumes SET last_seen_at = 1700000000 WHERE id = 1;
INSERT INTO volumes(id, stable_key, label, last_seen_at) VALUES (2, 'uuid-1111', 'Music disk', 1700000001);
INSERT INTO library_roots(id, volume_id, path, enabled) VALUES (1, 1, '/music', 1), (2, 2, '/mnt/disk/music', 0);

INSERT INTO artists(id, name, sort_name, key, musicbrainz_artist_id) VALUES
    (1, 'Alpha Band', 'Alpha Band', 'alpha band', '11111111-1111-4111-8111-111111111111'),
    (2, 'Beta Singer', 'Singer, Beta', 'beta singer', NULL),
    (3, 'Gamma Trio', 'Gamma Trio', 'gamma trio', '33333333-3333-4333-8333-333333333333');
INSERT INTO releases(id, title, album_artist, release_date, is_compilation, disc_count, release_key,
    musicbrainz_release_id, album_artist_id, release_type, has_folder_cover) VALUES
    (1, 'First Light', 'Alpha Band', '2001-05-01', 0, 1, 'alpha band|first light', 'aaaaaaaa-0000-4000-8000-000000000001', 1, 'album', 1),
    (2, 'Second Wind', 'Beta Singer', '1999', 0, 1, 'beta singer|second wind', NULL, 2, 'ep', 0),
    (3, 'Various Nights', 'Various Artists', NULL, 1, NULL, 'various artists|various nights', NULL, NULL, NULL, 0);
INSERT INTO recordings(id, title, duration_ms) VALUES (1, 'Dawn', 180000), (2, 'Noon', 200000), (3, 'Dusk', 220000), (4, 'Night', 240000);
INSERT INTO files(id, recording_id, audio_format, codec, size_bytes, sample_rate, bit_depth, channels, duration_ms,
    quick_hash, audio_hash, content_hash, first_seen_at, last_scan_generation, content_hash_algorithm, audio_hash_tier) VALUES
    (1, 1, 1, 'flac', 1000, 44100, 16, 2, 180000, x'11', x'a1', x'c1', 1700000100, 1, 1, 1),
    (2, 2, 1, 'flac', 2000, 44100, 16, 2, 200000, x'12', x'a2', x'c2', 1700000101, 1, 1, 2),
    (3, 3, 2, 'mp3', 3000, 48000, NULL, 2, 220000, x'13', NULL, x'c3', 1700000102, 1, 2, NULL),
    (4, 4, 1, 'flac', 4000, 96000, 24, 6, 240000, x'14', x'a4', x'c4', 1700000103, 1, 1, 1);
INSERT INTO tracks(id, recording_id, release_id, title, album, album_artist, duration_ms, track_number, disc_number,
    created_at, artist, preferred_file_id, artist_id, track_total, disc_total, explicit) VALUES
    (10, 1, 1, 'Dawn', 'First Light', 'Alpha Band', 180000, 1, 1, 1700000200, 'Alpha Band', 1, 1, 2, 1, 0),
    (11, 2, 1, 'Noon', 'First Light', 'Alpha Band', 200000, 2, 1, 1700000201, 'Alpha Band', 2, 1, 2, 1, 1),
    (12, 3, 2, 'Dusk', 'Second Wind', 'Beta Singer', 220000, 1, 1, 1700000202, 'Beta Singer', 3, 2, 1, 1, 0),
    (13, 4, NULL, 'Night', '', '', 240000, NULL, NULL, 1700000203, 'Gamma Trio', 4, 3, NULL, NULL, 0);
INSERT INTO locations(id, file_id, volume_id, root_id, uri, native_device, native_inode, size_bytes, modified_ns,
    state, missing_since, last_seen_generation) VALUES
    (1, 1, 1, 1, 'file:///music/alpha/dawn.flac', 64769, 1001, 1000, 1700000000000000000, 'present', NULL, 1),
    (2, 1, 1, 1, 'file:///music/alpha/old/dawn.flac', 64769, 1002, 1000, 1700000000000000001, 'missing', 1700000300, 0),
    (3, 2, 1, 1, 'file:///music/alpha/noon.flac', 64769, 1003, 2000, 1700000000000000002, 'unverified', NULL, 0),
    (4, 3, 2, 2, 'file:///mnt/disk/music/beta/dusk.mp3', 2049, 2001, 3000, 1700000000000000003, 'present', NULL, 1),
    (5, 4, 1, NULL, 'file:///elsewhere/night.flac', NULL, NULL, 4000, 1700000000000000004, 'missing', 1700000301, 0);
INSERT INTO scan_runs(id, root_id, generation, started_at, finished_at, state, files_seen, changed, unchanged, unsupported, errors) VALUES
    (1, 1, 1, 1700000100, 1700000160, 'completed', 3, 3, 0, 1, 0),
    (2, 2, 1, 1700000170, NULL, 'running', 1, 1, 0, 0, 0);
INSERT INTO folder_images(id, volume_id, root_id, uri, mime, role, size_bytes, modified_ns, last_seen_generation, width, height, hash) VALUES
    (1, 1, 1, 'file:///music/alpha/cover.jpg', 'image/jpeg', 0, 5000, 1700000000000000010, 1, 500, 500, 123456789),
    (2, 1, 1, 'file:///music/alpha/back.png', 'image/png', 1, 6000, 1700000000000000011, 1, NULL, NULL, NULL);
INSERT INTO folder_scans(root_id, relative_path, scanned_at) VALUES (1, 'alpha', 1700000160), (2, '', 1700000180);
INSERT INTO observed_file_tags(file_id, title, artist, album, album_artist, composer, track_number, track_total, disc_number,
    disc_total, date, original_date, compilation, label, media, isrc, release_country, release_type, release_status,
    musicbrainz_recording_id, musicbrainz_release_id, musicbrainz_release_group_id, musicbrainz_release_track_id,
    musicbrainz_artist_id, musicbrainz_album_artist_id, artwork_mime_type, artwork_byte_size, artwork_kind, observed_at,
    explicit, comment, artwork_width, artwork_height, artwork_hash) VALUES
    (1, 'Dawn', 'Alpha Band', 'First Light', 'Alpha Band', 'A. Composer', 1, 2, 1, 1, '2001-05-01', '2001', 0, 'Label', 'CD',
     'GBAAA0100001', 'GB', 'album', 'official', 'rec-1', 'aaaaaaaa-0000-4000-8000-000000000001', 'rg-1', 'rt-1',
     '11111111-1111-4111-8111-111111111111', '11111111-1111-4111-8111-111111111111', 'image/png', 217, 3, 1700000100,
     0, 'comment', 16, 16, 42),
    (2, 'Noon', 'Alpha Band', 'First Light', 'Alpha Band', NULL, 2, 2, 1, 1, '2001-05-01', NULL, NULL, NULL, NULL,
     NULL, NULL, NULL, NULL, NULL, 'aaaaaaaa-0000-4000-8000-000000000001', NULL, NULL, NULL, NULL, NULL, 100, NULL,
     1700000101, 1, NULL, NULL, NULL, NULL);
INSERT INTO observed_file_genres(file_id, ordinal, value) VALUES (1, 0, 'Rock'), (1, 1, 'Jazz'), (2, 0, 'Rock');
INSERT INTO analysis_results(file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity, result, created_at) VALUES
    (1, 1, 'orca.audio-diagnostics', 4, x'A5D7A479D64C3952CA86E311AFFEBB0CFCA41DAF406C7AA159255961CF9145CE', x'c1',
        CAST(x'4F5241440200' || x'0100' || x'0000B8C1' || zeroblob(60) AS BLOB), 1700000400),
    (2, 1, 'orca.audio-diagnostics', 4, x'A5D7A479D64C3952CA86E311AFFEBB0CFCA41DAF406C7AA159255961CF9145CE', x'c2',
        CAST(x'4F5241440200' || x'0100' || x'000060C1' || zeroblob(60) AS BLOB), 1700000401),
    (4, 1, 'orca.audio-diagnostics', 4, x'A5D7A479D64C3952CA86E311AFFEBB0CFCA41DAF406C7AA159255961CF9145CE', x'c4',
        CAST(x'4F5241440200' || x'0100' || x'0000A0C1' || zeroblob(60) AS BLOB), 1700000402),
    (3, 3, 'orca.example', 1, x'01', x'c3', x'DEADBEEF', 1700000403);
INSERT INTO library_health_issues(file_id, kind, severity, details, updated_at, related_file_id, similarity) VALUES
    (1, 1, 1, 'possible duplicate', 1700000500, 2, 0.97), (3, 2, 2, 'low bitrate', 1700000501, NULL, NULL);
INSERT INTO health_dismissals(file_id, kind, quick_hash, dismissed_at) VALUES (3, 2, x'13', 1700000600);

INSERT INTO genres(id, name, key) VALUES (1, 'Rock', 'rock'), (2, 'Jazz', 'jazz'), (3, 'Folk', 'folk');
INSERT INTO track_genres(track_id, genre_id, ordinal, provenance) VALUES
    (10, 1, 0, 0), (10, 2, 1, 0), (11, 1, 0, 1), (12, 2, 0, 0), (13, 3, 0, 2);

INSERT INTO orca_metadata_values(file_id, field, value, provenance, locked, updated_at, written_at) VALUES
    (1, 9, 'rel-1', 1, 1, 1700000700, 1700000710), (2, 3, 'Noon (edited)', 2, 0, 1700000701, NULL);
INSERT INTO metadata_proposals(id, group_id, release_id, category, field, track_id, current, proposed, reason, option,
    state, fingerprint, created_at, tracks, gap) VALUES
    (1, 1, 1, 0, 'title', 10, 'Dawn', 'Dawn (Remaster)', 'musicbrainz', 0, 0, 111, 1700000800, 2, 1),
    (2, 1, 1, 0, 'title', 11, 'Noon', 'Noon (Remaster)', 'musicbrainz', 0, 1, 112, 1700000801, NULL, NULL);
INSERT INTO mutation_operations(id, plan_id, group_id, action_index, kind, source_path, destination_path, stage_path,
    backup_path, expected_size, expected_modified_ns, committed_size, committed_modified_ns, state, error, created_at,
    updated_at, file_id, expected_quick_hash, committed_quick_hash, expected_content_hash, committed_content_hash) VALUES
    (1, 1, 1, 0, 0, '/music/alpha/dawn.flac', NULL, '/music/alpha/.dawn.stage', '/music/alpha/.dawn.bak', 1000,
     1700000000000000000, 1010, 1700000000000000100, 2, NULL, 1700000900, 1700000901, 1, x'11', x'21', x'c1', x'd1'),
    (2, 1, 1, 1, 1, '/music/alpha/noon.flac', '/music/alpha/noon-2.flac', NULL, NULL, 2000, 1700000000000000002,
     NULL, NULL, 3, 'rolled back', 1700000902, 1700000903, NULL, NULL, NULL, NULL, NULL);
INSERT INTO identification_proposals(id, file_id, recording_id, provider, provider_id, confidence, payload, state,
    created_at, updated_at, accepted_in_bulk, album_group) VALUES
    (1, 3, 3, 'acoustid', 'rec-3', 0.91, x'7B7D', 0, 1700001000, 1700001001, 0, 7),
    (2, 3, NULL, 'musicbrainz', 'rec-3b', 0.5, x'5B5D', 1, 1700001002, 1700001003, 1, NULL);
INSERT INTO identification_searches(file_id, provider, searched_at) VALUES (3, 'acoustid', 1700001100);
INSERT INTO recording_verifications(file_id, quick_hash, recording_mbid, outcome, heard, verified_at) VALUES
    (1, x'11', 'rec-1', 1, 'Dawn', 1700001200);
INSERT INTO acoustid_submissions(file_id, recording_mbid, submission_id, submitted_at) VALUES (1, 'rec-1', 99, 1700001300);
INSERT INTO musicbrainz_releases(musicbrainz_release_id, title, artist_credit, release_date, release_group_id,
    medium_count, track_count, fetched_at, artist_credit_ids) VALUES
    ('aaaaaaaa-0000-4000-8000-000000000001', 'First Light', 'Alpha Band', '2001-05-01', 'rg-1', 1, 2, 1700001400,
     '11111111-1111-4111-8111-111111111111');
INSERT INTO musicbrainz_release_tracks(musicbrainz_release_id, disc, position, title, artist_credit, length_ms,
    recording_id, release_track_id) VALUES
    ('aaaaaaaa-0000-4000-8000-000000000001', 1, 1, 'Dawn', 'Alpha Band', 180000, 'rec-1', 'rt-1'),
    ('aaaaaaaa-0000-4000-8000-000000000001', 1, 2, 'Noon', 'Alpha Band', NULL, 'rec-2', 'rt-2');
INSERT INTO release_track_pairings(track_id, musicbrainz_release_id, release_id, release_track_id, recording_id,
    origin, created_at) VALUES
    (10, 'aaaaaaaa-0000-4000-8000-000000000001', 1, 'rt-1', 'rec-1', 0, 1700001500),
    (11, 'aaaaaaaa-0000-4000-8000-000000000001', 1, 'rt-2', 'rec-2', 1, 1700001501);
INSERT INTO paired_metadata_values(file_id, field, value, replaced_value, replaced_provenance, replaced_locked,
    replaced_written_at) VALUES
    (1, 3, 'Dawn', 'dawn', 1, 0, 1700001600), (2, 3, 'Noon', NULL, NULL, NULL, NULL);
INSERT INTO reviewed_releases(release_id, musicbrainz_release_id, digest, reviewed_at) VALUES
    (1, 'aaaaaaaa-0000-4000-8000-000000000001', zeroblob(32), 1700001700);
INSERT INTO dismissed_release_candidates(release_id, musicbrainz_release_id, dismissed_at) VALUES
    (2, 'bbbbbbbb-0000-4000-8000-000000000002', 1700001800);
INSERT INTO release_artwork(release_id, kind, source, musicbrainz_release_id, image, mime, width, height, fetched_at) VALUES
    (1, 0, 1, 'aaaaaaaa-0000-4000-8000-000000000001', x'89504E470D0A1A0A', 'image/png', 16, 16, 1700001900),
    (1, 1, 2, NULL, x'FFD8FFE0', 'image/jpeg', NULL, NULL, 1700001901);
INSERT INTO cover_art_candidates(release_id, caa_id, musicbrainz_release_id, kind, width, height, mime, approved,
    thumbnail, fetched_at) VALUES
    (1, 5001, 'aaaaaaaa-0000-4000-8000-000000000001', 0, 1200, 1200, 'image/jpeg', 1, x'FFD8FFE0', 1700002000),
    (2, 5002, 'bbbbbbbb-0000-4000-8000-000000000002', 2, NULL, NULL, NULL, 0, NULL, 1700002001);
INSERT INTO release_info(release_id, description, description_source, description_url, description_licence,
    description_language, requested_language, musicbrainz_release_id, musicbrainz_release_group_id, fetched_at, outcome) VALUES
    (1, 'A debut album.', 1, 'https://example.org/first-light', 'CC BY-SA', 'en', 'en',
     'aaaaaaaa-0000-4000-8000-000000000001', 'rg-1', 1700002100, 1);
INSERT INTO artist_info(artist_id, musicbrainz_artist_id, wikidata_id, begin_year, end_year, ended, artist_type, biography,
    biography_source, biography_url, biography_licence, biography_language, requested_language, photo, photo_mime,
    photo_source, photo_url, photo_licence, photo_licence_url, photo_credit, listeners, listeners_fetched_at, fetched_at,
    outcome, origin) VALUES
    (1, '11111111-1111-4111-8111-111111111111', 'Q1', 1995, NULL, 0, 'Group', 'A band.', 1, 'https://example.org/alpha',
     'CC BY-SA', 'en', 'en', x'89504E47', 'image/png', 1, 'https://example.org/alpha.png', 'CC0', NULL, 'Photographer',
     12345, 1700002200, 1700002201, 1, 'GB');
INSERT INTO artist_links(artist_id, kind, url) VALUES (1, 0, 'https://example.org/alpha'), (1, 1, 'https://example.org/alpha/wiki');
INSERT INTO artist_related(artist_id, ordinal, related_mbid, related_name, score) VALUES
    (1, 0, '22222222-2222-4222-8222-222222222222', 'Beta Singer', 90);
INSERT INTO related_artist_photos(musicbrainz_artist_id, photo, photo_mime, photo_source, photo_url, photo_licence,
    photo_licence_url, photo_credit, fetched_at) VALUES
    ('22222222-2222-4222-8222-222222222222', x'89504E47', 'image/png', 1, 'https://example.org/beta.png', 'CC0', NULL, 'Someone', 1700002300),
    ('44444444-4444-4444-8444-444444444444', NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1700002301);
INSERT INTO artist_release_groups(artist_id, mbid, title, primary_type, first_release_year, credited_with, position) VALUES
    (1, 'rg-1', 'First Light', 'Album', 2001, NULL, 0), (2, 'rg-1', 'First Light', 'Album', 2001, 'Alpha Band', 0);
INSERT INTO release_group_covers(mbid, image, mime, fetched_at) VALUES ('rg-1', x'FFD8FFE0', 'image/jpeg', 1700002400);
INSERT INTO track_lyrics(track_id, query_digest, lrclib_id, synced, plain, instrumental, fetched_at) VALUES
    (10, zeroblob(32), 700, '[00:01.00] Hello', 'Hello', 0, 1700002500), (11, x'01', NULL, NULL, NULL, 1, 1700002501);

INSERT INTO ratings(recording_id, rating, updated_at) VALUES (1, 80, 1700002600), (3, 20, 1700002601);
INSERT INTO feedback(recording_id, score, updated_at, synced_score, synced_at, last_error) VALUES
    (1, 1, 1700002700, 1, 1700002701, ''), (2, -1, 1700002702, NULL, NULL, 'rate limited');
INSERT INTO release_loves(release_id, loved_at) VALUES (1, 1700002800);
INSERT INTO artist_loves(artist_id, loved_at) VALUES (2, 1700002900);
INSERT INTO playlists(id, name, created_at, updated_at, description, pinned_at, loved_at, kind, rules, creator) VALUES
    (1, 'Morning', 1700003000, 1700003001, 'Easy start', 1700003002, NULL, 0, NULL, 0),
    (2, 'Rock only', 1700003003, 1700003004, '', NULL, 1700003005, 1, '{"genre":"Rock"}', 1);
INSERT INTO playlist_entries(playlist_id, position, recording_id, added_at) VALUES
    (1, 0, 1, 1700003100), (1, 1, 2, 1700003101), (1, 2, 3, 1700003102);
INSERT INTO playlist_tags(playlist_id, ordinal, tag) VALUES (1, 0, 'calm'), (1, 1, 'morning');
INSERT INTO listens(id, file_id, recording_id, started_at, listened_ms, duration_ms, title, artist, album, recording_mbid,
    player_client, syncable) VALUES
    (1, 1, 1, 1700003200, 180000, 180000, 'Dawn', 'Alpha Band', 'First Light', 'rec-1', 'orca-cli', 1),
    (2, 1, 1, 1700003500, 90000, 180000, 'Dawn', 'Alpha Band', 'First Light', 'rec-1', 'orca-gtk', 1),
    (3, 2, 2, 1700003600, 200000, 200000, 'Noon', 'Alpha Band', 'First Light', NULL, '', 0);
INSERT INTO recording_play_stats(recording_id, play_count, last_played_at) VALUES (1, 2, 1700003500), (2, 1, 1700003600);
INSERT INTO track_positions(track_id, position_ms, updated_at) VALUES (10, 61000, 1700003700);
INSERT INTO player_state(id, cursor, position_ms, repeat, shuffle, saved_at) VALUES (1, 1, 5000, 1, 0, 1700003800);
INSERT INTO player_queue_entries(position, entry, track_id, recording_id) VALUES (0, 0, 10, 1), (1, 1, 11, 2), (2, 2, 12, 3);
INSERT INTO provider_cache(provider, request_key, status, body, expires_at, updated_at) VALUES
    ('musicbrainz', 'release/1', 200, x'7B7D', 1800000000, 1700003900);
INSERT INTO provider_state(service, blocked_until_ms, backoff_ms, next_request_ms) VALUES
    ('musicbrainz', NULL, 0, 1700003900000), ('lastfm', 1700004000000, 5000, NULL);
INSERT INTO provider_leases(service, owner, expires_at) VALUES ('musicbrainz', 4242, 1800000000);
INSERT INTO scrobble_queue(id, service, event_key, payload, state, attempt_count, next_attempt_at, last_error, created_at,
    updated_at, lease_owner, lease_expires_at) VALUES
    (1, 'listenbrainz', 'listen-1', x'7B7D', 0, 0, 0, '', 1700004100, 1700004100, NULL, NULL),
    (2, 'lastfm', 'listen-2', x'5B5D', 1, 2, 1700004200, 'timeout', 1700004101, 1700004102, 4242, 1700004300);
INSERT INTO library_settings(key, value) VALUES ('example.setting', 'value'), ('example.other', '2');
INSERT INTO job_history(id, kind, request, started_at, finished_at, state, completed_units, total_units, error,
    undo_group_id, retryable, summary) VALUES
    (1, 'scan', '{"root":1}', 1700004400, 1700004460, 'completed', 3, 3, NULL, NULL, 0, '3 files'),
    (2, 'genre-fill', NULL, 1700004500, 1700004501, 'failed', 0, NULL, 'no network', 5, 1, '');
