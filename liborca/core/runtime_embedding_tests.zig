const std = @import("std");
const audio_embedding = @import("../analysis/audio_embedding.zig");
const job = @import("job.zig");
const runtime_module = @import("runtime.zig");
const runtime_tests = @import("runtime_tests.zig");

const LibraryHandle = runtime_module.LibraryHandle;
const OrcaRuntime = runtime_module.OrcaRuntime;
const EmbeddingModelState = runtime_module.EmbeddingModelState;

const testing = std.testing;
const fixture_files = 2;

fn scannedLibrary(runtime: *OrcaRuntime, temporary: *testing.TmpDir, name: [:0]const u8) !LibraryHandle {
    try runtime_tests.copyFixtureInto(temporary.dir, "fixtures/audio/fingerprint-reference.mp3", "song.mp3");
    try runtime_tests.copyFixtureInto(temporary.dir, "fixtures/audio/generated-reference.qoa", "blip.qoa");
    return runtime_tests.scannedTempFolder(runtime, temporary, name);
}

fn analyse(runtime: *OrcaRuntime, library: LibraryHandle) !runtime_module.ScanStats {
    const job_handle = try runtime.startLibraryAnalysis(library, .{ .threads = 1 });
    try testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(runtime, job_handle));
    return runtime.jobScanStats(job_handle);
}

fn storedEmbeddings(runtime: *OrcaRuntime, library: LibraryHandle) !i64 {
    var statement = try (try runtime_module.libraryDatabase(runtime, library)).database.prepare(
        "SELECT count(*) FROM analysis_results WHERE kind=?1;",
    );
    defer statement.deinit();
    try statement.bindInt64(1, audio_embedding.cache_kind);
    _ = try statement.step();
    return statement.columnInt64(0);
}

fn storedEmbeddingsOf(runtime: *OrcaRuntime, library: LibraryHandle, model: audio_embedding.ModelId) !i64 {
    var statement = try (try runtime_module.libraryDatabase(runtime, library)).database.prepare(
        "SELECT count(*) FROM analysis_results WHERE kind=?1 AND parameter_hash=?2 AND length(result)=?3;",
    );
    defer statement.deinit();
    try statement.bindInt64(1, audio_embedding.cache_kind);
    try statement.bindBlob(2, &audio_embedding.parameterHash(model));
    try statement.bindInt64(3, @intCast(model.spec().encodedSize()));
    _ = try statement.step();
    return statement.columnInt64(0);
}

fn libraryVectors(runtime: *OrcaRuntime, library: LibraryHandle, model: audio_embedding.ModelId) ![]u8 {
    var statement = try (try runtime_module.libraryDatabase(runtime, library)).database.prepare(
        "SELECT coalesce(group_concat(file_id || ':' || hex(source_identity) || ':' || hex(vector), ';'), '') " ++
            "FROM (SELECT * FROM file_audio_embeddings WHERE model = ?1 ORDER BY file_id);",
    );
    defer statement.deinit();
    try statement.bindInt64(1, @backingInt(model));
    _ = try statement.step();
    return testing.allocator.dupe(u8, statement.columnText(0));
}

fn temporaryPath(temporary: *testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ temporary.sub_path, name });
}

test "setEmbeddingModelPath_noFileAnotherFileAndTheModel_reportsMissingWrongFileAndReady" {
    const model_path = try audio_embedding.testModelPath(.clap_htsat_unfused);
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(testing.io, .{ .sub_path = "other.onnx", .data = "not the model" });
    const other = try temporaryPath(&temporary, "other.onnx");
    defer testing.allocator.free(other);
    const absent = try temporaryPath(&temporary, "absent.onnx");
    defer testing.allocator.free(absent);
    var runtime = OrcaRuntime.init(testing.allocator);
    defer runtime.deinit();

    try testing.expectEqual(EmbeddingModelState.missing, runtime.embeddingModelState());
    try testing.expectEqual(@as(?audio_embedding.ModelId, null), runtime.embeddingModel());
    try runtime.setEmbeddingModelPath(model_path);
    try testing.expectEqual(EmbeddingModelState.ready, runtime.embeddingModelState());
    try testing.expectEqual(@as(?audio_embedding.ModelId, .clap_htsat_unfused), runtime.embeddingModel());
    try runtime.setEmbeddingModelPath(absent);
    try testing.expectEqual(EmbeddingModelState.missing, runtime.embeddingModelState());
    try testing.expectEqual(@as(?audio_embedding.ModelId, null), runtime.embeddingModel());
    try runtime.setEmbeddingModelPath(other);
    try testing.expectEqual(EmbeddingModelState.wrong_file, runtime.embeddingModelState());
    try testing.expectEqual(@as(?audio_embedding.ModelId, null), runtime.embeddingModel());
    try runtime.setEmbeddingModelPath(model_path);
    try runtime.setEmbeddingModelPath(null);
    try testing.expectEqual(EmbeddingModelState.missing, runtime.embeddingModelState());
}

test "setEmbeddingModelPath_fileOfAModelsSizeWithAnotherDigest_isReadyUntilAnAnalysisRefusesIt" {
    if (!audio_embedding.enabled) return error.SkipZigTest;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var models = testing.tmpDir(.{});
    defer models.cleanup();
    {
        const file = try models.dir.createFile(testing.io, "model.onnx", .{});
        defer file.close(testing.io);
        try file.setLength(testing.io, audio_embedding.ModelId.clap_htsat_unfused.spec().size);
    }
    const impostor = try temporaryPath(&models, "model.onnx");
    defer testing.allocator.free(impostor);
    var runtime = OrcaRuntime.init(testing.allocator);
    defer runtime.deinit();
    const library = try scannedLibrary(&runtime, &temporary, "file:orca-runtime-embedding-impostor?mode=memory&cache=shared");

    try runtime.setEmbeddingModelPath(impostor);
    try testing.expectEqual(EmbeddingModelState.ready, runtime.embeddingModelState());
    try testing.expectEqual(@as(?audio_embedding.ModelId, .clap_htsat_unfused), runtime.embeddingModel());

    const stats = try analyse(&runtime, library);
    try testing.expectEqual(@as(u64, fixture_files), stats.files_seen);
    try testing.expectEqual(@as(i64, 0), try storedEmbeddings(&runtime, library));
    try testing.expectEqual(EmbeddingModelState.wrong_file, runtime.embeddingModelState());
    try testing.expectEqual(@as(?audio_embedding.ModelId, null), runtime.embeddingModel());
}

test "libraryAnalyzeFile_fileOfAModelsSizeWithAnotherDigest_storesNoEmbeddingAndReportsWrongFile" {
    if (!audio_embedding.enabled) return error.SkipZigTest;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try runtime_tests.copyFixtureInto(temporary.dir, "fixtures/audio/fingerprint-reference.mp3", "song.mp3");
    const song = try runtime_tests.absoluteTestPath(".zig-cache/tmp/{s}/song.mp3", .{temporary.sub_path});
    defer testing.allocator.free(song);
    {
        const file = try temporary.dir.createFile(testing.io, "model.onnx", .{});
        defer file.close(testing.io);
        try file.setLength(testing.io, audio_embedding.ModelId.discogs_maest.spec().size);
    }
    const impostor = try temporaryPath(&temporary, "model.onnx");
    defer testing.allocator.free(impostor);
    var runtime = OrcaRuntime.init(testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(testing.io, "file:orca-runtime-embedding-impostor-one-file?mode=memory&cache=shared");

    try runtime.setEmbeddingModelPath(impostor);
    const measured = try runtime.libraryAnalyzeFile(library, testing.io, song);
    defer measured.deinit();
    try testing.expect(measured.embedding == null);
    try testing.expectEqual(@as(i64, 0), try storedEmbeddings(&runtime, library));
    try testing.expectEqual(EmbeddingModelState.wrong_file, runtime.embeddingModelState());
}

test "setEmbeddingModelPath_builtWithoutEmbeddings_reportsBuiltWithout" {
    if (audio_embedding.enabled) return error.SkipZigTest;
    var runtime = OrcaRuntime.init(testing.allocator);
    defer runtime.deinit();
    try testing.expectEqual(EmbeddingModelState.built_without, runtime.embeddingModelState());
    try runtime.setEmbeddingModelPath("fixtures/audio/generated-reference.wav");
    try testing.expectEqual(EmbeddingModelState.built_without, runtime.embeddingModelState());
    try runtime.setEmbeddingModelPath(null);
    try testing.expectEqual(EmbeddingModelState.built_without, runtime.embeddingModelState());
}

test "startLibraryAnalysis_withModel_storesEmbeddingsAndSelectsNoFileAgain" {
    const model_path = try audio_embedding.testModelPath(.clap_htsat_unfused);
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var runtime = OrcaRuntime.init(testing.allocator);
    defer runtime.deinit();
    const library = try scannedLibrary(&runtime, &temporary, "file:orca-runtime-embedding-job?mode=memory&cache=shared");
    try runtime.setEmbeddingModelPath(model_path);

    const first = try analyse(&runtime, library);
    try testing.expectEqual(@as(u64, fixture_files), first.files_seen);
    try testing.expectEqual(@as(i64, fixture_files), try storedEmbeddings(&runtime, library));
    try testing.expectEqual(EmbeddingModelState.ready, runtime.embeddingModelState());
    try testing.expectEqual(@as(u64, 0), try runtime.libraryUnanalyzedCount(library));

    const second = try analyse(&runtime, library);
    try testing.expectEqual(@as(u64, 0), second.files_seen);
}

test "startLibraryAnalysis_withoutModel_storesNoEmbedding" {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var runtime = OrcaRuntime.init(testing.allocator);
    defer runtime.deinit();
    const library = try scannedLibrary(&runtime, &temporary, "file:orca-runtime-no-embedding-job?mode=memory&cache=shared");

    const stats = try analyse(&runtime, library);
    try testing.expectEqual(@as(u64, fixture_files), stats.files_seen);
    try testing.expectEqual(@as(i64, 0), try storedEmbeddings(&runtime, library));
    try testing.expectEqual(@as(u64, 0), try runtime.libraryUnanalyzedCount(library));
    const coverage = try runtime.libraryAnalysisCoverage(library);
    try testing.expectEqual(@as(u64, 0), coverage.outdated);
    try testing.expect(!coverage.missing.embedding);
}

test "setEmbeddingModelPath_onALibraryAnalysedWithoutModel_reportsTheEmbeddingMissingUntilAJobMeasuresIt" {
    const model_path = try audio_embedding.testModelPath(.clap_htsat_unfused);
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var runtime = OrcaRuntime.init(testing.allocator);
    defer runtime.deinit();
    const library = try scannedLibrary(&runtime, &temporary, "file:orca-runtime-embedding-backfill?mode=memory&cache=shared");
    _ = try analyse(&runtime, library);
    const without = try runtime.libraryAnalysisCoverage(library);

    try runtime.setEmbeddingModelPath(model_path);
    const owed = try runtime.libraryAnalysisCoverage(library);
    try testing.expectEqual(@as(u64, 0), owed.never_analyzed);
    try testing.expectEqual(@as(u64, fixture_files), owed.outdated);
    try testing.expectEqual(
        runtime_module.MissingMeasurements{ .embedding = true },
        owed.missing,
    );
    try testing.expect(owed.measurement_set != without.measurement_set);
    try testing.expectEqual(@as(u64, fixture_files), try runtime.libraryUnanalyzedCount(library));

    const stats = try analyse(&runtime, library);
    try testing.expectEqual(@as(u64, fixture_files), stats.files_seen);
    try testing.expectEqual(@as(i64, fixture_files), try storedEmbeddings(&runtime, library));
    const measured = try runtime.libraryAnalysisCoverage(library);
    try testing.expectEqual(@as(u64, 0), measured.outdated);
    try testing.expectEqual(runtime_module.MissingMeasurements{}, measured.missing);
    try testing.expectEqual(@as(u64, 0), try runtime.libraryUnanalyzedCount(library));

    try runtime.setEmbeddingModelPath(null);
    try testing.expectEqual(without.measurement_set, (try runtime.libraryAnalysisCoverage(library)).measurement_set);
    try testing.expectEqual(@as(u64, 0), try runtime.libraryUnanalyzedCount(library));
}

test "startLibraryAnalysis_modelReplacedAfterItWasSet_succeedsWithoutEmbeddingsAndReportsWrongFile" {
    const model_path = try audio_embedding.testModelPath(.clap_htsat_unfused);
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var models = testing.tmpDir(.{});
    defer models.cleanup();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        model_path,
        testing.allocator,
        .limited(audio_embedding.ModelId.clap_htsat_unfused.spec().size + 1),
    );
    defer testing.allocator.free(bytes);
    try models.dir.writeFile(testing.io, .{ .sub_path = "model.onnx", .data = bytes });
    const copy = try temporaryPath(&models, "model.onnx");
    defer testing.allocator.free(copy);
    var runtime = OrcaRuntime.init(testing.allocator);
    defer runtime.deinit();
    const library = try scannedLibrary(&runtime, &temporary, "file:orca-runtime-embedding-replaced?mode=memory&cache=shared");
    try runtime.setEmbeddingModelPath(copy);
    try testing.expectEqual(EmbeddingModelState.ready, runtime.embeddingModelState());
    try models.dir.writeFile(testing.io, .{ .sub_path = "model.onnx", .data = "not the model" });

    const stats = try analyse(&runtime, library);
    try testing.expectEqual(@as(u64, fixture_files), stats.files_seen);
    try testing.expectEqual(@as(i64, 0), try storedEmbeddings(&runtime, library));
    try testing.expectEqual(EmbeddingModelState.wrong_file, runtime.embeddingModelState());
    try testing.expectEqual(@as(u64, 0), try runtime.libraryUnanalyzedCount(library));
}

test "startLibraryAnalysis_maestAfterClap_measuresEachFileOnceAndKeepsBothModelsResults" {
    const clap_path = try audio_embedding.testModelPath(.clap_htsat_unfused);
    const maest_path = try audio_embedding.testModelPath(.discogs_maest);
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var runtime = OrcaRuntime.init(testing.allocator);
    defer runtime.deinit();
    const library = try scannedLibrary(&runtime, &temporary, "file:orca-runtime-embedding-two-models?mode=memory&cache=shared");

    try runtime.setEmbeddingModelPath(clap_path);
    _ = try analyse(&runtime, library);
    try testing.expectEqual(@as(i64, fixture_files), try storedEmbeddingsOf(&runtime, library, .clap_htsat_unfused));
    const with_clap = try runtime.libraryAnalysisCoverage(library);
    const vectors = try libraryVectors(&runtime, library, .clap_htsat_unfused);
    defer testing.allocator.free(vectors);
    try testing.expect(vectors.len != 0);

    try runtime.setEmbeddingModelPath(maest_path);
    try testing.expectEqual(@as(?audio_embedding.ModelId, .discogs_maest), runtime.embeddingModel());
    try testing.expectEqual(@as(u64, fixture_files), try runtime.libraryUnanalyzedCount(library));
    const owed = try runtime.libraryAnalysisCoverage(library);
    try testing.expectEqual(runtime_module.MissingMeasurements{ .embedding = true }, owed.missing);
    try testing.expect(owed.measurement_set != with_clap.measurement_set);

    const measured = try analyse(&runtime, library);
    try testing.expectEqual(@as(u64, fixture_files), measured.files_seen);
    try testing.expectEqual(@as(i64, fixture_files), try storedEmbeddingsOf(&runtime, library, .discogs_maest));
    try testing.expectEqual(@as(i64, fixture_files), try storedEmbeddingsOf(&runtime, library, .clap_htsat_unfused));
    try testing.expectEqual(@as(i64, 2 * fixture_files), try storedEmbeddings(&runtime, library));
    try testing.expectEqual(@as(u64, 0), try runtime.libraryUnanalyzedCount(library));
    try testing.expectEqual(@as(u64, 0), (try analyse(&runtime, library)).files_seen);

    try runtime.setEmbeddingModelPath(clap_path);
    try testing.expectEqual(@as(?audio_embedding.ModelId, .clap_htsat_unfused), runtime.embeddingModel());
    try testing.expectEqual(@as(u64, 0), try runtime.libraryUnanalyzedCount(library));
    try testing.expectEqual(with_clap.measurement_set, (try runtime.libraryAnalysisCoverage(library)).measurement_set);
    try testing.expectEqual(@as(u64, 0), (try analyse(&runtime, library)).files_seen);
    try testing.expectEqual(@as(i64, fixture_files), try storedEmbeddingsOf(&runtime, library, .discogs_maest));
    try testing.expectEqual(@as(i64, 2 * fixture_files), try storedEmbeddings(&runtime, library));
    const vectors_after = try libraryVectors(&runtime, library, .clap_htsat_unfused);
    defer testing.allocator.free(vectors_after);
    try testing.expectEqualStrings(vectors, vectors_after);
}

test "startLibraryAnalysis_modelFileSwappedForTheOtherModel_storesUnderTheOpenedModelAndNamesIt" {
    const clap_path = try audio_embedding.testModelPath(.clap_htsat_unfused);
    const maest_path = try audio_embedding.testModelPath(.discogs_maest);
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var models = testing.tmpDir(.{});
    defer models.cleanup();
    const cwd = std.Io.Dir.cwd();
    try cwd.copyFile(clap_path, models.dir, "model.onnx", testing.io, .{});
    const copy = try temporaryPath(&models, "model.onnx");
    defer testing.allocator.free(copy);
    var runtime = OrcaRuntime.init(testing.allocator);
    defer runtime.deinit();
    const library = try scannedLibrary(&runtime, &temporary, "file:orca-runtime-embedding-swapped?mode=memory&cache=shared");
    try runtime.setEmbeddingModelPath(copy);
    try testing.expectEqual(@as(?audio_embedding.ModelId, .clap_htsat_unfused), runtime.embeddingModel());
    try cwd.copyFile(maest_path, models.dir, "model.onnx", testing.io, .{});

    const stats = try analyse(&runtime, library);
    try testing.expectEqual(@as(u64, fixture_files), stats.files_seen);
    try testing.expectEqual(@as(i64, fixture_files), try storedEmbeddingsOf(&runtime, library, .discogs_maest));
    try testing.expectEqual(@as(i64, fixture_files), try storedEmbeddings(&runtime, library));
    try testing.expectEqual(@as(?audio_embedding.ModelId, .discogs_maest), runtime.embeddingModel());
    try testing.expectEqual(@as(u64, 0), try runtime.libraryUnanalyzedCount(library));
}

test "libraryAnalyzeFile_withModel_storesTheEmbedding" {
    const model_path = try audio_embedding.testModelPath(.clap_htsat_unfused);
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try runtime_tests.copyFixtureInto(temporary.dir, "fixtures/audio/fingerprint-reference.mp3", "song.mp3");
    const song = try runtime_tests.absoluteTestPath(".zig-cache/tmp/{s}/song.mp3", .{temporary.sub_path});
    defer testing.allocator.free(song);
    var runtime = OrcaRuntime.init(testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(testing.io, "file:orca-runtime-embedding-one-file?mode=memory&cache=shared");

    const without = try runtime.libraryAnalyzeFile(library, testing.io, song);
    defer without.deinit();
    try testing.expect(without.embedding == null);
    try testing.expectEqual(@as(i64, 0), try storedEmbeddings(&runtime, library));

    try runtime.setEmbeddingModelPath(model_path);
    const with = try runtime.libraryAnalyzeFile(library, testing.io, song);
    defer with.deinit();
    try testing.expect(with.embedding.? == .embedding);
    try testing.expectEqual(@as(i64, 1), try storedEmbeddings(&runtime, library));
}

test "librarySimilarTracks_seedUnknownTrackAndTrackWithoutEmbedding_returnsTheNearestAndNamesTheErrors" {
    var runtime = OrcaRuntime.init(testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(testing.io, "file:orca-runtime-similar-tracks?mode=memory&cache=shared");
    const library_database = try runtime_module.libraryDatabase(&runtime, library);
    try library_database.database.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'r'), (2, 'r'), (3, 'r'), (4, 'r');
        \\INSERT INTO files(id, recording_id, size_bytes, quick_hash, content_hash, content_hash_algorithm) VALUES
        \\    (1, 1, 1, x'01', x'01', 1), (2, 2, 1, x'01', x'01', 1), (3, 3, 1, x'01', x'01', 1), (4, 4, 1, x'01', x'01', 1);
        \\INSERT INTO tracks(id, recording_id, title) VALUES (11, 1, 'seed'), (12, 2, 'far'), (13, 3, 'near'), (14, 4, 'unmeasured');
    );
    var embedding = try library_database.database.prepare(
        "INSERT INTO file_audio_embeddings(model, file_id, source_identity, vector) VALUES (1, ?1, x'01', ?2);",
    );
    defer embedding.deinit();
    for ([_][2]i8{ .{ 100, 0 }, .{ 0, 100 }, .{ 80, 60 } }, 1..) |head, file_id| {
        var vector: [512]i8 = @splat(0);
        vector[0..2].* = head;
        try embedding.reset();
        try embedding.bindInt64(1, @intCast(file_id));
        try embedding.bindBlob(2, std.mem.asBytes(&vector));
        _ = try embedding.step();
    }

    var similar = try runtime.librarySimilarTracks(library, testing.allocator, 11, 10);
    defer similar.deinit();
    try testing.expectEqual(@as(usize, 2), similar.items.len);
    try testing.expectEqual(@as(i64, 13), similar.items[0].track_id);
    try testing.expectApproxEqAbs(@as(f32, 0.8), similar.items[0].similarity, 1e-6);
    try testing.expectEqual(@as(i64, 12), similar.items[1].track_id);
    try testing.expectApproxEqAbs(@as(f32, 0.0), similar.items[1].similarity, 1e-6);

    try testing.expectError(error.TrackNotFound, runtime.librarySimilarTracks(library, testing.allocator, 99, 10));
    try testing.expectError(error.NoAudioEmbedding, runtime.librarySimilarTracks(library, testing.allocator, 14, 10));
    try testing.expectError(
        error.SimilarLimitTooLarge,
        runtime.librarySimilarTracks(library, testing.allocator, 11, runtime_module.max_similar_tracks + 1),
    );
}

test "librarySimilarTracks_modelSwitchedBetweenClapAndMaest_ranksByTheActiveModelsVectorsAndByClapWithNone" {
    const clap_path = try audio_embedding.testModelPath(.clap_htsat_unfused);
    const maest_path = try audio_embedding.testModelPath(.discogs_maest);
    var runtime = OrcaRuntime.init(testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(testing.io, "file:orca-runtime-similar-by-model?mode=memory&cache=shared");
    const library_database = try runtime_module.libraryDatabase(&runtime, library);
    try library_database.database.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'r'), (2, 'r'), (3, 'r'), (4, 'r');
        \\INSERT INTO files(id, recording_id, size_bytes, quick_hash, content_hash, content_hash_algorithm) VALUES
        \\    (1, 1, 1, x'01', x'01', 1), (2, 2, 1, x'01', x'01', 1), (3, 3, 1, x'01', x'01', 1), (4, 4, 1, x'01', x'01', 1);
        \\INSERT INTO tracks(id, recording_id, title) VALUES (11, 1, 'seed'), (12, 2, 'a'), (13, 3, 'b'), (14, 4, 'clap only');
    );
    var embedding = try library_database.database.prepare(
        "INSERT INTO file_audio_embeddings(model, file_id, source_identity, vector) VALUES (?1, ?2, x'01', ?3);",
    );
    defer embedding.deinit();
    const Stored = struct { model: audio_embedding.ModelId, file_id: i64, head: [2]i8 };
    for ([_]Stored{
        .{ .model = .clap_htsat_unfused, .file_id = 1, .head = .{ 100, 0 } },
        .{ .model = .clap_htsat_unfused, .file_id = 2, .head = .{ 0, 100 } },
        .{ .model = .clap_htsat_unfused, .file_id = 3, .head = .{ 80, 60 } },
        .{ .model = .clap_htsat_unfused, .file_id = 4, .head = .{ 100, 0 } },
        .{ .model = .discogs_maest, .file_id = 1, .head = .{ 100, 0 } },
        .{ .model = .discogs_maest, .file_id = 2, .head = .{ 60, 80 } },
        .{ .model = .discogs_maest, .file_id = 3, .head = .{ 0, 100 } },
    }) |stored| {
        var vector: [audio_embedding.max_embedding_size]i8 = @splat(0);
        vector[0..2].* = stored.head;
        try embedding.reset();
        try embedding.bindInt64(1, @backingInt(stored.model));
        try embedding.bindInt64(2, stored.file_id);
        try embedding.bindBlob(3, std.mem.sliceAsBytes(vector[0..stored.model.spec().embedding_size]));
        _ = try embedding.step();
    }
    const by_clap = [_]runtime_module.SimilarTrack{
        .{ .track_id = 14, .similarity = 1.0 },
        .{ .track_id = 13, .similarity = 0.8 },
        .{ .track_id = 12, .similarity = 0.0 },
    };
    const by_maest = [_]runtime_module.SimilarTrack{
        .{ .track_id = 12, .similarity = 0.6 },
        .{ .track_id = 13, .similarity = 0.0 },
    };

    try testing.expectEqual(@as(?audio_embedding.ModelId, null), runtime.embeddingModel());
    try expectSimilar(&runtime, library, 11, &by_clap);

    try runtime.setEmbeddingModelPath(maest_path);
    try testing.expectEqual(@as(?audio_embedding.ModelId, .discogs_maest), runtime.embeddingModel());
    try expectSimilar(&runtime, library, 11, &by_maest);
    try testing.expectError(error.NoAudioEmbedding, runtime.librarySimilarTracks(library, testing.allocator, 14, 10));

    try runtime.setEmbeddingModelPath(clap_path);
    try expectSimilar(&runtime, library, 11, &by_clap);
    try runtime.setEmbeddingModelPath(null);
    try expectSimilar(&runtime, library, 11, &by_clap);
}

fn expectSimilar(
    runtime: *OrcaRuntime,
    library: LibraryHandle,
    track_id: i64,
    expected: []const runtime_module.SimilarTrack,
) !void {
    var similar = try runtime.librarySimilarTracks(library, testing.allocator, track_id, 10);
    defer similar.deinit();
    try testing.expectEqual(expected.len, similar.items.len);
    for (expected, similar.items) |want, got| {
        try testing.expectEqual(want.track_id, got.track_id);
        try testing.expectApproxEqAbs(want.similarity, got.similarity, 1e-6);
    }
}
