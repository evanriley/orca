INSERT INTO daily_mixes(id, ordinal, kind, genre_id, name, local_day, generated_at) VALUES
    (1, 0, 1, NULL, 'Rarely played', 20000, 1700004800), (2, 1, 0, 1, 'Rock', 20000, 1700004801);
INSERT INTO daily_mix_artists(mix_id, position, artist_id) VALUES (1, 0, 1), (2, 0, 2);
INSERT INTO daily_mix_entries(mix_id, position, recording_id, reason1_kind, reason1_a, reason1_b) VALUES
    (1, 0, 1, 2, 3, 4), (2, 0, 2, NULL, 0, 0);
