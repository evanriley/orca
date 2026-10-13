INSERT INTO analysis_results(file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity, result, created_at) VALUES
    (1, 7, 'orca.audio-embedding', 1, x'D9194D8DF5B32D7660AFFE47B3178383B538327B1FC5F1D654B626272D38D905', x'c1',
        CAST(x'4F52454D0100' || x'01' || x'01' || x'01000000' || x'11' || zeroblob(511) AS BLOB), 1700005000),
    (2, 7, 'orca.audio-embedding', 1, x'D9194D8DF5B32D7660AFFE47B3178383B538327B1FC5F1D654B626272D38D905', x'c2',
        CAST(x'4F52454D0100' || x'01' || x'02' || x'02000000' || x'22' || zeroblob(511) AS BLOB), 1700005001);
