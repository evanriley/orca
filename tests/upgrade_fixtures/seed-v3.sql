INSERT INTO daily_mixes(id, ordinal, kind, genre_id, decade, name, local_day, generated_at, signals, left_out_recent,
    left_out_not_for_me, left_out_hated, left_out_live, left_out_other_mix, left_out_diversity, favorite_count,
    rarely_played_count, never_played_count) VALUES
    (1, 0, 1, NULL, NULL, 'Rarely played', 20001, 1700004900, 5, 1, 2, 3, 4, 5, 6, 7, 8, 9),
    (2, 1, 2, 1, NULL, 'Rock mix', 20001, 1700004901, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
    (3, 2, 5, NULL, 1990, 'Nineties', 20001, 1700004902, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0);
INSERT INTO daily_mix_artists(mix_id, position, artist_id) VALUES (1, 0, 1), (1, 1, 2), (2, 0, 1), (3, 0, 3);
INSERT INTO daily_mix_entries(mix_id, position, recording_id, reason1_kind, reason1_a, reason1_b, reason2_kind, reason2_a, reason2_b) VALUES
    (1, 0, 1, 2, 3, 4, 5, 6, 7), (1, 1, 2, 0, 0, 0, NULL, 0, 0), (2, 0, 3, NULL, 0, 0, NULL, 0, 0), (3, 0, 4, 9, 1, 2, NULL, 0, 0);
