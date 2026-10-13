INSERT INTO analysis_results(file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity, result, created_at) VALUES
    (1, 7, 'orca.audio-embedding', 1, x'6A89F6A7C38041025E72DD12DD1A8E325E07D94291F2FBCED4020ACC261AC5E7', x'c1',
        CAST(x'4F52454D0100' || x'01' || x'01' || x'01000000' || x'44' || zeroblob(767) AS BLOB), 1700005200),
    (4, 7, 'orca.audio-embedding', 1, x'6A89F6A7C38041025E72DD12DD1A8E325E07D94291F2FBCED4020ACC261AC5E7', x'c4',
        CAST(x'4F52454D0100' || x'01' || x'02' || x'01000000' || x'55' || zeroblob(767) AS BLOB), 1700005201);
