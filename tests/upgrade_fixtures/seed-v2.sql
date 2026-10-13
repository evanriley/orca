INSERT INTO analysis_results(file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity, result, created_at) VALUES
    (1, 6, 'orca.audio-features', 1, x'8D91D6D7138EB255B30DD8F82BF8B042B0E78E5FE59C0A12EECD4861CB7D5C0E', x'c1',
        x'4F52414601000F00B4D6010090D0030002010000A0860100A0252600DDE31600400D030000000000', 1700004600),
    (2, 6, 'orca.audio-features', 1, x'8D91D6D7138EB255B30DD8F82BF8B042B0E78E5FE59C0A12EECD4861CB7D5C0E', x'c2',
        CAST(x'4F52414601000100' || x'40420F00' || x'00000000' || zeroblob(24) AS BLOB), 1700004601);
INSERT INTO recommendation_feedback(recording_id, created_at, expires_at) VALUES (3, 1700004700, 17000047000), (4, 1700004701, 17000047010);
