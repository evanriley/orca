const std = @import("std");
const build_options = @import("build_options");
const liborca = @import("liborca");

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        var stderr_buffer: [256]u8 = undefined;
        var stderr_file_writer: std.Io.File.Writer = .initStreaming(.stderr(), init.io, &stderr_buffer);
        const stderr = &stderr_file_writer.interface;
        if (err == error.Usage) {
            writeHelp(stderr) catch {};
            stderr.flush() catch {};
            std.process.exit(usage_exit_status);
        }
        stderr.print("orca-cli: {s}\n", .{describe(err)}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.TrackNotFound => "no track with that id",
        error.UnknownRoot => "no folder with that id",
        error.RootPathOverlaps => "PATH is inside or holds another root, files of another root, or the root's old folder while that still exists",
        error.RootVolumeChanged => "the folder is not on the drive it was added from, so nothing was scanned; mount that drive, or run add-root to accept the drive it is on now",
        error.OpenFailed => "could not open the database",
        error.InvalidCharacter, error.Overflow => "expected a number",
        error.InvalidThreadCount => "--threads must be at least 1",
        error.UnknownOption => "unknown option",
        error.LibraryJobRunning => "a job is running on this library",
        error.LibraryScanRunning => "a scan is already running on this library; wait for it to finish",
        error.InvalidReconcileDirectory => "each DIR must be a path relative to the root, with no '.', '..', empty or trailing component",
        error.InvalidFolderPath => "PATH must be relative to the root, with no '.', '..', empty or trailing component",
        error.FolderEmpty => "no track below that folder",
        error.MissingDevice => "play-folder needs --device=ID; scripts/silent-sink.sh prints a silent one",
        error.OutputFailed => "the output device could not be opened or was lost, and reopening it failed; a chosen device is never replaced by another",
        error.WatchingUnsupported => "watching folders needs Linux",
        error.InvalidWatchOptions => "--quiet must be at least 1 and --max-delay at least --quiet",
        error.InvalidMaintenanceOptions => "--maintenance must be at least 1",
        error.WatchInstanceLimit => "too many inotify instances are open; raise fs.inotify.max_user_instances",
        error.WatcherStopped => "the watcher stopped on an error it could not recover from",
        error.InvalidToken => "ListenBrainz does not accept the token in ORCA_LISTENBRAINZ_TOKEN",
        error.NeedsToken => "set ORCA_LISTENBRAINZ_TOKEN to a ListenBrainz user token",
        error.InvalidServerUrl => "ORCA_LISTENBRAINZ_URL, ORCA_MUSICBRAINZ_URL, ORCA_ACOUSTID_URL, ORCA_COVERARTARCHIVE_URL, ORCA_LRCLIB_URL, ORCA_WIKIDATA_URL, ORCA_WIKIMEDIA_URL, ORCA_WIKIPEDIA_URL and ORCA_LISTENBRAINZ_LABS_URL must be https, or http to localhost",
        error.UnknownArtist => "no artist with that id",
        error.UnknownDailyMix => "no Daily Mix with that number; run mixes to list them",
        error.InvalidLanguage => "--lang must be a Wikipedia language code such as en or pt-br",
        error.NoArtistPhoto => "the artist has no photo; run artist-info --fetch first",
        error.NoReleaseGroupCover => "the release group has no cover; run artist-info --fetch --include-releases first",
        error.InvalidMusicBrainzId => "MBID must be a MusicBrainz ID such as 0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e01",
        error.OwnNeedsArtist => "--own needs --artist",
        error.InvalidMatchRequest => "--accept-min-score and --cover-art need --release; --reidentify needs --track or --release and takes no --accept-min-score; --track and --release do not go together",
        error.UnknownRelease => "no release with that id",
        error.NoReleaseCandidate => "no MusicBrainz release is proposed for that release; run match --release=ID first, or name a candidate release ID",
        error.NoReleaseTracklist => "MusicBrainz has not been asked for that release's tracklist yet; run match --release=ID first",
        error.ReleaseTooLarge => "a release of more than 512 tracks has no alignment",
        error.TrackNotOnRelease => "that track is not on that release",
        error.UnknownReleaseTrack => "the release's tracklist has no track with that MBID; run release-alignment for its release track MBIDs",
        error.ReleaseTrackAlreadyPaired => "another track is paired with that release track; run unpair-track on it first",
        error.TrackNotPaired => "that track is not paired on that release",
        error.ReleaseNotPlaced => "every track must have a file and be placed on the release first; run release-alignment, then pair-track",
        error.ReleaseNotReviewed => "that release has no review to forget; one its tags identify returns when a file's release ID tag is removed or changed",
        error.MissingReleaseAction => "--release=ID needs --evidence, --diff or --dismiss=MBID",
        error.UnknownReleaseField => "--fields takes album, album_artist, date, release_id and track_titles, comma-separated",
        error.CoverArtRefused => "the Cover Art Archive's answer was refused: a redirect off archive.org, a refusal, or not a JPEG or PNG of at most 4 MiB",
        error.CoverArtUnavailable => "the Cover Art Archive could not be reached; try again later",
        error.CoverArtArchiveInUse => "the Cover Art Archive is in use by another Orca process; try again once it finishes",
        error.MatchingStopped => "matching stopped early: MusicBrainz or AcoustID could not be reached or kept refusing requests; run match again to continue",
        error.AcoustIdBusy => "another job is using AcoustID; wait for it to finish",
        error.MusicBrainzInUse => "MusicBrainz is in use by another Orca process; run match again once it finishes",
        error.AcoustIdInUse => "AcoustID is in use by another Orca process; try again once it finishes",
        error.ListenBrainzInUse => "ListenBrainz is in use by another Orca process; try again once it finishes",
        error.InvalidAcoustIdKey => "the AcoustID application key is empty, too long or contains spaces; rebuild with -Dacoustid-key=KEY",
        error.NeedsAcoustIdUserKey => "set ORCA_ACOUSTID_USER_KEY to your AcoustID user key (https://acoustid.org/api-key)",
        error.AcoustIdUserKeyUnreadable => "the AcoustID user key could not be read from the credential store",
        error.InvalidAcoustIdUserKey => "AcoustID does not accept the user key in ORCA_ACOUSTID_USER_KEY",
        error.InvalidAcoustIdClientKey => "AcoustID does not accept the application key; rebuild with -Dacoustid-key=KEY",
        error.SubmissionStopped => "submission stopped early: AcoustID could not be reached or kept refusing requests; run submit-acoustid again to continue",
        error.NoPresentFile => "the track's file is not where the library last saw it; rescan its folder",
        error.AcoustIdRequired => "verify needs AcoustID: set an AcoustID application key (rebuild with -Dacoustid-key=KEY) and keep fingerprints on",
        error.VerificationStopped => "verification stopped early: AcoustID or MusicBrainz could not be reached or kept refusing requests; run verify again to continue",
        error.ProposalInGroup => "that match belongs to an album correction; list it with corrections, then accept or dismiss the whole group with accept-correction or dismiss-correction",
        error.UnknownCorrectionGroup => "no correction group with that id",
        error.StaleCorrectionGroup => "that correction group was already accepted or dismissed",
        error.UnknownIdentificationProposal => "no match with that id",
        error.StaleIdentificationProposal => "that match was already accepted or dismissed",
        error.InvalidProposalPayload => "that match cannot be read; dismiss it",
        error.InvalidMinimumConfidence => "--min-score must be above 0 and at most 1",
        error.TagWriteBackupPruned => "the backups for this write were pruned, so it cannot be undone",
        error.FileReadOnly => "a file of this write is read-only, and Orca does not change a file made read-only; nothing was restored. Make it writable and run undo-tags again",
        error.UnknownTagWriteGroup => "no finished tag write with that group",
        error.TagTargetUnavailable => "a file an interrupted tag write changed is in a folder that is not there; mount it and try again",
        error.NoBackupDirectory => "this library has no database file, so a tag write has nowhere to keep the originals",
        error.InvalidRating => "a rating must be 1 to 100, or 1 to 5 stars",
        error.UnknownPlaylist => "no playlist with that id",
        error.InvalidPlaylistName => "a playlist name must not be empty",
        error.PlaylistNameTaken => "a playlist with that name already exists",
        error.PlaylistFull => "a playlist holds at most 10000 entries; nothing was added",
        error.PositionOutOfRange => "that position is past the end of the playlist; positions start at 0",
        error.PlaylistEmpty => "the playlist has no entry with a track to play, or the playlist file lists no entries",
        error.PlaylistTooLarge => "a playlist file may be at most 4 MiB and 10000 entries; nothing was imported",
        error.PathAlreadyExists => "that file already exists; pass --force to replace it",
        error.PlaylistIsSmart => "a smart playlist's entries come from its rules; change them with smart-playlist-rules",
        error.PlaylistIsManual => "that playlist is not a smart playlist",
        error.InvalidPlaylistTag => "a tag must not be empty and may be at most 64 bytes",
        error.TooManyPlaylistTags => "a playlist has at most 8 tags",
        error.PlaylistDescriptionTooLong => "a description may be at most 4096 bytes",
        error.NoPlaylistUpdate => "give at least one of --description, --pin, --unpin, --love, --unlove or --tags",
        error.InvalidSmartPlaylistRules => "the rules are not valid smart playlist JSON (version 1, at most 16 KiB); see docs/api.md",
        error.UnknownRuleField => "a rule names a field smart playlists do not know (UnknownRuleField)",
        error.UnknownRuleOperator => "a rule names an operator smart playlists do not know (UnknownRuleOperator)",
        error.RuleOperatorMismatch => "a rule's operator does not apply to its field (RuleOperatorMismatch)",
        error.InvalidRuleValue => "a rule's value does not fit its field and operator (InvalidRuleValue)",
        error.RuleNestingTooDeep => "rules nest at most 4 groups deep (RuleNestingTooDeep)",
        error.TooManyRules => "a smart playlist has at most 32 rules (TooManyRules)",
        error.InvalidRulePlaylist => "an in_playlist rule must name an existing manual playlist (InvalidRulePlaylist)",
        error.InvalidEqualizerApo => "the file is not EqualizerAPO text Orca reads: Preamp: and Filter: lines, blank lines and # comments only, at most 64 KiB",
        error.UnsupportedFilterType => "a filter type Orca does not run; it runs PK, PEQ, LS, LSC, HS, HSC, LP, HP and NO, with no dB slope",
        error.TooManyFilters => "a parametric equalizer has at most 16 filters",
        error.FilterFrequencyOutOfRange => "a filter's Fc must be 20 to 20000 Hz",
        error.FilterGainOutOfRange => "a filter's Gain must be within 24 dB",
        error.FilterQOutOfRange => "a filter's Q must be 0.1 to 20, or 0.3 to 2 on a shelf",
        error.ParametricPreampOutOfRange => "the Preamp lines must add up to -24 to +6 dB",
        error.EqualizerAndParametric => "give either --eq or --peq, not both",
        error.InvalidSampleRate => "--rate must be a sample rate above 0",
        error.PageOutOfRange => "at most 512 ids at a time, and --limit must be 1 to 512",
        error.TracksAndPlaylist => "give either IDS or --playlist=ID, not both",
        error.UnknownHealthKind => "KIND must be the kind health prints, such as clipping, exact_duplicate, identical_audio or likely_duplicate",
        error.SummaryWithPage => "--summary lists every kind at once; give it no --kind or OFFSET",
        error.LosslessAndLossy => "give either --lossless or --lossy, not both",
        error.SortHasNoLetters => "--letters needs --sort title or --sort artist",
        error.LettersAndTotals => "give either --letters or --totals, not both",
        error.AsyncListingOnly => "--async lists a page and its count; give it no --letters or --totals",
        error.UnknownFile => "no file with that id",
        error.UnsupportedChannelCount => "the file has more than two channels; Orca plays and analyses mono and stereo only until multichannel support lands",
        error.UnknownJobKind => "--start takes scan, analysis, duplicates, backfill, project or consistency",
        error.UnknownIssueCategory => "--category takes album_artist, dates, track_numbering, genre_variants or musicbrainz_differs",
        error.IssueNotFound => "no metadata issue with that group id; list them with issues DATABASE",
        error.IssueNotOpen => "that metadata issue was already applied or skipped",
        error.IssueOutOfDate => "the release's values changed since the issue was found; run consistency DATABASE again",
        error.UnknownIssueOption => "the issue has no option with that id",
        error.CustomValueNotAllowed => "a track_numbering issue takes --option=0 only",
        error.GenreDoesNotMatchIssue => "the custom genre must be a spelling of the issue's genre",
        error.IssueChoiceRequired => "give either --option=ID or --custom=TEXT",
        error.TrackNotInIssue => "--tracks names a track the issue does not cover",
        error.NoTracksChosen => "--tracks needs at least one track id",
        error.UnknownHistoryFilter => "--filter takes all, scans, analysis, file_changes or problems",
        error.JobsNeedStartOrHistory => "give either --start=KIND or --history",
        error.JobQueueFull => "32 jobs are already waiting; start this one when one has finished",
        error.UnknownJobHistory => "no finished job with that id; list them with jobs DATABASE --history",
        error.JobNotRetryable => "that job succeeded, or its request cannot be repeated",
        error.SchemaVersionTooNew => "the Library's schema is not one this version of Orca can open; create a new Library",
        else => @errorName(err),
    };
}

const usage_exit_status = 2;

fn run(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        try writeHelp(stdout);
        try stdout.flush();
        return;
    }

    const command = if (args.len > 1) findCommand(args[1], args.len - 2) else null;
    if (command) |found| {
        try found.run(.{
            .allocator = allocator,
            .gpa = init.gpa,
            .io = init.io,
            .environ = init.environ_map,
            .stdout = stdout,
            .arguments = args[2..],
        });
    } else return error.Usage;

    try stdout.flush();
}

const Context = struct {
    allocator: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    stdout: *std.Io.Writer,
    arguments: []const []const u8,
};

const Command = struct {
    name: []const u8,
    usage: []const u8,
    min_arguments: usize,
    max_arguments: ?usize,
    run: *const fn (Context) anyerror!void,
    shares_usage_line: bool = false,
};

const usage_indent = "                 ";

const commands = [_]Command{
    .{ .name = "--version", .usage = "--version", .min_arguments = 0, .max_arguments = null, .run = printVersion },
    .{ .name = "demo", .usage = "demo", .min_arguments = 0, .max_arguments = null, .run = runDemo, .shares_usage_line = true },
    .{ .name = "scan", .usage = "scan DATABASE ROOT [--reprobe]", .min_arguments = 2, .max_arguments = 3, .run = scanRoot, .shares_usage_line = true },
    .{ .name = "estimate", .usage = "estimate PATH", .min_arguments = 1, .max_arguments = 1, .run = estimateFolder, .shares_usage_line = true },
    .{ .name = "reconcile", .usage = "reconcile DATABASE ROOT_ID [DIR...]", .min_arguments = 2, .max_arguments = null, .run = reconcileRoot },
    .{
        .name = "watch",
        .usage = "watch DATABASE [--quiet=MS] [--max-delay=MS] [--once]\n" ++ usage_indent ++ "  [--limit=MS] [--maintenance[=MS]] [--pause-after=MS] [--resume-after=MS]",
        .min_arguments = 1,
        .max_arguments = null,
        .run = watchLibrary,
    },
    .{ .name = "project", .usage = "project DATABASE", .min_arguments = 1, .max_arguments = 1, .run = projectLibrary, .shares_usage_line = true },
    .{ .name = "backfill", .usage = "backfill DATABASE [--force] [--cancel-after=MS]", .min_arguments = 1, .max_arguments = null, .run = backfillProperties },
    .{ .name = "analyze", .usage = "analyze DATABASE AUDIO", .min_arguments = 2, .max_arguments = 2, .run = analyzeFile },
    .{
        .name = "analyze-library",
        .usage = "analyze-library DATABASE [--batch=N] [--threads=N]\n" ++ usage_indent ++ "  [--cancel-after=MS]",
        .min_arguments = 1,
        .max_arguments = null,
        .run = analyzeLibrary,
    },
    .{
        .name = "duplicates",
        .usage = "duplicates DATABASE [--batch=N] [--cancel-after=MS]\n" ++ usage_indent ++
            "  | --groups [--limit N] [--offset N] | --group=ID",
        .min_arguments = 1,
        .max_arguments = null,
        .run = findDuplicates,
    },
    .{ .name = "consistency", .usage = "consistency DATABASE [--batch=N] [--cancel-after=MS]", .min_arguments = 1, .max_arguments = null, .run = checkConsistency },
    .{
        .name = "issues",
        .usage = "issues DATABASE [--category=album_artist|dates|track_numbering|genre_variants|musicbrainz_differs]\n" ++
            usage_indent ++ "  [--limit N] [--offset N]",
        .min_arguments = 1,
        .max_arguments = null,
        .run = listMetadataIssues,
    },
    .{ .name = "apply-issue", .usage = "apply-issue DATABASE GROUP (--option=ID | --custom=TEXT) [--tracks=IDS]", .min_arguments = 3, .max_arguments = 4, .run = applyMetadataIssue },
    .{ .name = "skip-issue", .usage = "skip-issue DATABASE GROUP", .min_arguments = 2, .max_arguments = 2, .run = skipMetadataIssue, .shares_usage_line = true },
    .{ .name = "merge-duplicate", .usage = "merge-duplicate DATABASE KEEP_TRACK_ID FROM_TRACK_ID", .min_arguments = 3, .max_arguments = 3, .run = mergeDuplicate },
    .{ .name = "keep-both", .usage = "keep-both DATABASE FILE_ID FILE_ID", .min_arguments = 3, .max_arguments = 3, .run = keepBothDuplicates, .shares_usage_line = true },
    .{ .name = "ignore-duplicate", .usage = "ignore-duplicate DATABASE GROUP_ID", .min_arguments = 2, .max_arguments = 2, .run = ignoreDuplicateGroup, .shares_usage_line = true },
    .{
        .name = "jobs",
        .usage = "jobs DATABASE [--start=KIND]... [--pause-after=MS] [--resume-after=MS]\n" ++ usage_indent ++
            "  | --history [--filter=FILTER] [--limit N] [--offset N]",
        .min_arguments = 1,
        .max_arguments = null,
        .run = runJobs,
    },
    .{ .name = "retry-job", .usage = "retry-job DATABASE HISTORY_ID", .min_arguments = 2, .max_arguments = 2, .run = retryJob },
    .{ .name = "roots", .usage = "roots DATABASE", .min_arguments = 1, .max_arguments = 1, .run = listRoots },
    .{ .name = "add-root", .usage = "add-root DATABASE ROOT", .min_arguments = 2, .max_arguments = 2, .run = addRoot, .shares_usage_line = true },
    .{ .name = "remove-root", .usage = "remove-root DATABASE ID", .min_arguments = 2, .max_arguments = 2, .run = removeRoot, .shares_usage_line = true },
    .{ .name = "relocate-root", .usage = "relocate-root DATABASE ID PATH", .min_arguments = 3, .max_arguments = 3, .run = relocateRoot },
    .{ .name = "availability", .usage = "availability DATABASE [RELEASE_ID...]", .min_arguments = 1, .max_arguments = null, .run = showAvailability },
    .{ .name = "folders", .usage = "folders DATABASE [ROOT_ID [PATH]]", .min_arguments = 1, .max_arguments = 3, .run = listFolders },
    .{ .name = "health", .usage = "health DATABASE [--summary | --kind=KIND [--albums]] [OFFSET]", .min_arguments = 1, .max_arguments = 4, .run = listHealthIssues },
    .{ .name = "stats", .usage = "stats DATABASE", .min_arguments = 1, .max_arguments = 1, .run = printLibraryStats },
    .{ .name = "listens", .usage = "listens DATABASE [--policy=half|30s|full] [--record=on|off] [--clear]", .min_arguments = 1, .max_arguments = 4, .run = listenSettings },
    .{ .name = "cache", .usage = "cache DATABASE [--clear]", .min_arguments = 1, .max_arguments = 2, .run = providerCache },
    .{ .name = "sources", .usage = "sources", .min_arguments = 0, .max_arguments = 0, .run = listProviderSources, .shares_usage_line = true },
    .{ .name = "formats", .usage = "formats", .min_arguments = 0, .max_arguments = 0, .run = listSupportedFormats, .shares_usage_line = true },
    .{ .name = "devices", .usage = "devices", .min_arguments = 0, .max_arguments = 0, .run = listDevices, .shares_usage_line = true },
    .{ .name = "play", .usage = "play AUDIO [DEVICE_ID]", .min_arguments = 1, .max_arguments = 2, .run = playFile, .shares_usage_line = true },
    .{ .name = "peq-check", .usage = "peq-check FILE", .min_arguments = 1, .max_arguments = 1, .run = checkEqualizerApo },
    .{ .name = "peq-response", .usage = "peq-response FILE [--rate=HZ]", .min_arguments = 1, .max_arguments = 2, .run = printEqualizerResponse, .shares_usage_line = true },
    .{ .name = "health-dismiss", .usage = "health-dismiss DATABASE FILE_ID KIND", .min_arguments = 3, .max_arguments = 3, .run = dismissHealthIssue },
    .{ .name = "health-restore", .usage = "health-restore DATABASE FILE_ID KIND", .min_arguments = 3, .max_arguments = 3, .run = restoreHealthIssue, .shares_usage_line = true },
    .{ .name = "play-tracks", .usage = "play-tracks DATABASE (IDS | --playlist=ID) [OPTIONS]", .min_arguments = 2, .max_arguments = null, .run = playTracks },
    .{ .name = "play-folder", .usage = "play-folder DATABASE ROOT_ID PATH --device=ID [--shuffle] [--limit=MS]", .min_arguments = 4, .max_arguments = 6, .run = playFolder },
    .{ .name = "resume", .usage = "resume DATABASE --device=ID [--play] [--limit=MS]", .min_arguments = 2, .max_arguments = 4, .run = resumePlayback },
    .{ .name = "scrobble", .usage = "scrobble DATABASE [--status] [--timeout=MS]", .min_arguments = 1, .max_arguments = null, .run = scrobble },
    .{ .name = "feedback", .usage = "feedback DATABASE IDS (--love | --hate | --clear)", .min_arguments = 3, .max_arguments = 3, .run = setFeedback },
    .{ .name = "rate", .usage = "rate DATABASE IDS (--stars=1..5 | --rating=1..100 | --clear)", .min_arguments = 3, .max_arguments = 3, .run = setRating },
    .{ .name = "love-release", .usage = "love-release DATABASE IDS [--clear]", .min_arguments = 2, .max_arguments = 3, .run = setReleaseLove },
    .{ .name = "love-artist", .usage = "love-artist DATABASE IDS [--clear]", .min_arguments = 2, .max_arguments = 3, .run = setArtistLove, .shares_usage_line = true },
    .{ .name = "playlists", .usage = "playlists DATABASE [--smart|--manual] [--pinned] [--created-by-me|--imported] [--sort name|updated|created|entries] [--filter TEXT]", .min_arguments = 1, .max_arguments = 9, .run = listPlaylists },
    .{ .name = "playlist", .usage = "playlist DATABASE ID [--limit N] [--offset N]", .min_arguments = 2, .max_arguments = 6, .run = showPlaylist },
    .{ .name = "playlist-create", .usage = "playlist-create DATABASE NAME", .min_arguments = 2, .max_arguments = 2, .run = createPlaylist },
    .{ .name = "playlist-rename", .usage = "playlist-rename DATABASE ID NAME", .min_arguments = 3, .max_arguments = 3, .run = renamePlaylist, .shares_usage_line = true },
    .{ .name = "playlist-delete", .usage = "playlist-delete DATABASE ID", .min_arguments = 2, .max_arguments = 2, .run = deletePlaylist },
    .{ .name = "playlist-add", .usage = "playlist-add DATABASE ID IDS [--at=N]", .min_arguments = 3, .max_arguments = 4, .run = addToPlaylist },
    .{ .name = "playlist-remove", .usage = "playlist-remove DATABASE ID POSITIONS", .min_arguments = 3, .max_arguments = 3, .run = removeFromPlaylist, .shares_usage_line = true },
    .{ .name = "playlist-move", .usage = "playlist-move DATABASE ID FROM TO", .min_arguments = 4, .max_arguments = 4, .run = moveInPlaylist },
    .{ .name = "playlist-import", .usage = "playlist-import DATABASE FILE [--name=NAME]", .min_arguments = 2, .max_arguments = 3, .run = importPlaylist },
    .{ .name = "playlist-export", .usage = "playlist-export DATABASE ID FILE [--relative] [--force]", .min_arguments = 3, .max_arguments = 5, .run = exportPlaylist },
    .{ .name = "playlist-update", .usage = "playlist-update DATABASE ID [--description=TEXT] [--pin|--unpin] [--love|--unlove] [--tags=A,B]", .min_arguments = 3, .max_arguments = 6, .run = updatePlaylist },
    .{ .name = "smart-playlist-create", .usage = "smart-playlist-create DATABASE NAME RULES_FILE", .min_arguments = 3, .max_arguments = 3, .run = createSmartPlaylist },
    .{ .name = "smart-playlist-rules", .usage = "smart-playlist-rules DATABASE ID [RULES_FILE]", .min_arguments = 2, .max_arguments = 3, .run = smartPlaylistRules },
    .{ .name = "smart-playlist-count", .usage = "smart-playlist-count DATABASE RULES_FILE [--sample=N]", .min_arguments = 2, .max_arguments = 3, .run = smartPlaylistCount },
    .{
        .name = "match",
        .usage = "match DATABASE [--batch=N] [--limit=N] [--no-fingerprints]\n" ++ usage_indent ++
            "  [--cancel-after=MS] [--release=ID [--accept-min-score=SCORE] [--cover-art]]\n" ++ usage_indent ++
            "  [--track=ID] [--reidentify (with --track or --release)]",
        .min_arguments = 1,
        .max_arguments = null,
        .run = matchLibrary,
    },
    .{
        .name = "matches",
        .usage = "matches DATABASE (TRACK_ID | --releases [--bucket=confident|needs_review|unmatched|reviewed]\n" ++ usage_indent ++
            "  [--min-score=SCORE] [--filter=TEXT] [--limit=N] [--offset=N] | --release=ID [--candidate=MBID]\n" ++ usage_indent ++
            "  (--evidence | --diff | --dismiss=MBID))",
        .min_arguments = 2,
        .max_arguments = 7,
        .run = listMatches,
    },
    .{ .name = "cover-art", .usage = "cover-art DATABASE RELEASE_ID [--candidates | --use=CAA_ID[:front|back|booklet]]", .min_arguments = 2, .max_arguments = 3, .run = fetchCoverArt },
    .{
        .name = "verify",
        .usage = "verify DATABASE [--track=ID | --release=ID] [--batch=N] [--limit=N]\n" ++ usage_indent ++
            "  [--cancel-after=MS]",
        .min_arguments = 1,
        .max_arguments = null,
        .run = verifyLibrary,
    },
    .{ .name = "corrections", .usage = "corrections DATABASE [--limit N] [--offset N]", .min_arguments = 1, .max_arguments = 5, .run = listCorrections },
    .{ .name = "accept-correction", .usage = "accept-correction DATABASE GROUP", .min_arguments = 2, .max_arguments = 2, .run = acceptCorrection },
    .{ .name = "dismiss-correction", .usage = "dismiss-correction DATABASE GROUP", .min_arguments = 2, .max_arguments = 2, .run = dismissCorrection, .shares_usage_line = true },
    .{ .name = "fingerprint", .usage = "fingerprint DATABASE TRACK_ID", .min_arguments = 2, .max_arguments = 2, .run = printFingerprint },
    .{ .name = "submit-acoustid", .usage = "submit-acoustid DATABASE [--dry-run]", .min_arguments = 1, .max_arguments = null, .run = submitAcoustId },
    .{ .name = "accept-match", .usage = "accept-match DATABASE ID", .min_arguments = 2, .max_arguments = 2, .run = acceptMatch },
    .{ .name = "dismiss-match", .usage = "dismiss-match DATABASE ID", .min_arguments = 2, .max_arguments = 2, .run = dismissMatch, .shares_usage_line = true },
    .{ .name = "accept-matches", .usage = "accept-matches DATABASE --min-score=SCORE", .min_arguments = 2, .max_arguments = 2, .run = acceptConfidentMatches },
    .{ .name = "apply-release", .usage = "apply-release DATABASE RELEASE_ID [--fields=FIELD,...]", .min_arguments = 2, .max_arguments = 3, .run = applyMatchedRelease, .shares_usage_line = true },
    .{ .name = "release-alignment", .usage = "release-alignment DATABASE RELEASE_ID [RELEASE_MBID]", .min_arguments = 2, .max_arguments = 3, .run = printReleaseAlignment, .shares_usage_line = true },
    .{ .name = "pair-track", .usage = "pair-track DATABASE RELEASE_ID TRACK_ID RELEASE_TRACK_MBID [RELEASE_MBID]", .min_arguments = 4, .max_arguments = 5, .run = pairTrack, .shares_usage_line = true },
    .{ .name = "unpair-track", .usage = "unpair-track DATABASE RELEASE_ID TRACK_ID", .min_arguments = 3, .max_arguments = 3, .run = unpairTrack, .shares_usage_line = true },
    .{ .name = "mark-release-reviewed", .usage = "mark-release-reviewed DATABASE RELEASE_ID [RELEASE_MBID]", .min_arguments = 2, .max_arguments = 3, .run = markReleaseReviewed, .shares_usage_line = true },
    .{ .name = "unmark-release-reviewed", .usage = "unmark-release-reviewed DATABASE RELEASE_ID", .min_arguments = 2, .max_arguments = 2, .run = unmarkReleaseReviewed, .shares_usage_line = true },
    .{ .name = "genres", .usage = "genres DATABASE ([--filter TEXT] [--sort name|tracks] [--offset N] | --fill-from-musicbrainz [--offline]) [--limit N]", .min_arguments = 1, .max_arguments = null, .run = listGenres },
    .{ .name = "genre-fill", .usage = "genre-fill DATABASE [on|off]", .min_arguments = 1, .max_arguments = 2, .run = genreFill, .shares_usage_line = true },
    .{ .name = "genre", .usage = "genre DATABASE ID", .min_arguments = 2, .max_arguments = 2, .run = showGenre, .shares_usage_line = true },
    .{ .name = "artists", .usage = "artists DATABASE [--album-artists] [--sort-as-written] [OPTIONS]", .min_arguments = 1, .max_arguments = null, .run = listArtists },
    .{ .name = "releases", .usage = "releases DATABASE [--filter TEXT] [--artist ID] [--genre ID] [--high-resolution] [--needs-review] [--lossless] [--year-from Y] [--year-to Y] [--with-artwork | --without-artwork] [--type=album|ep-single|other] [--appears=ARTIST_ID] [--own] [--added-days=N] [--sort title|artist|year|recently_added|loved|most_played] [--sort-as-written] [--letters | --totals | --async] [OPTIONS]", .min_arguments = 1, .max_arguments = null, .run = listReleases },
    .{ .name = "tracks", .usage = "tracks DATABASE [--filter TEXT] [--artist ID] [--release ID] [--genre ID] [--loved] [--year-from Y] [--year-to Y] [--lossless | --lossy] [--min-rate HZ] [--max-rate=HZ] [--codec=NAME] [--added-days=N] [--explicit] [--sort KEY] [--desc] [--totals] [--async] [OPTIONS]", .min_arguments = 1, .max_arguments = null, .run = listTracks },
    .{ .name = "track", .usage = "track DATABASE ID", .min_arguments = 2, .max_arguments = 2, .run = showTrack },
    .{ .name = "features", .usage = "features DATABASE TRACK_ID", .min_arguments = 2, .max_arguments = 2, .run = showAudioFeatures },
    .{ .name = "radio", .usage = "radio DATABASE (--track ID | --release ID | --artist ID | --genre ID | --decade YEAR | --loved) [--explore N] [--limit N] [--explain]", .min_arguments = 2, .max_arguments = 8, .run = previewRadio },
    .{ .name = "mixes", .usage = "mixes DATABASE [--refresh] [--mix N]", .min_arguments = 1, .max_arguments = 4, .run = showDailyMixes },
    .{ .name = "search", .usage = "search DATABASE TEXT [--artists N] [--releases N] [--tracks N] [--playlists N] [--genres N]", .min_arguments = 2, .max_arguments = 12, .run = searchLibrary },
    .{
        .name = "artwork",
        .usage = "artwork DATABASE (--track=ID | --release=ID) [--out=PATH]\n" ++ usage_indent ++
            "  [--kind=front|back|booklet] [--set=PATH | --clear] (--kind, --set, --clear with --release)",
        .min_arguments = 1,
        .max_arguments = null,
        .run = showArtwork,
    },
    .{ .name = "covers", .usage = "covers DATABASE [--limit N] [--offset N]", .min_arguments = 1, .max_arguments = null, .run = loadCovers },
    .{ .name = "lyrics", .usage = "lyrics DATABASE TRACK_ID [--fetch]", .min_arguments = 2, .max_arguments = 3, .run = showLyrics, .shares_usage_line = true },
    .{
        .name = "artist-info",
        .usage = "artist-info DATABASE ARTIST_ID [--fetch] [--force] [--lang=CODE] [--offline] [--include-releases]",
        .min_arguments = 2,
        .max_arguments = 7,
        .run = showArtistInfo,
    },
    .{ .name = "related", .usage = "related DATABASE ARTIST_ID", .min_arguments = 2, .max_arguments = 2, .run = showRelatedArtists },
    .{
        .name = "release-info",
        .usage = "release-info DATABASE RELEASE_ID [--fetch] [--force] [--lang=CODE] [--offline]",
        .min_arguments = 2,
        .max_arguments = 6,
        .run = showReleaseInfo,
        .shares_usage_line = true,
    },
    .{ .name = "artist-photo", .usage = "artist-photo DATABASE ARTIST_ID --out=PATH", .min_arguments = 3, .max_arguments = 3, .run = saveArtistPhoto },
    .{ .name = "related-photo", .usage = "related-photo DATABASE MBID --out=PATH", .min_arguments = 3, .max_arguments = 3, .run = saveRelatedArtistPhoto },
    .{ .name = "release-group-cover", .usage = "release-group-cover DATABASE MBID --out=PATH", .min_arguments = 3, .max_arguments = 3, .run = saveReleaseGroupCover },
    .{ .name = "edit", .usage = "edit DATABASE IDS [EDITS]", .min_arguments = 2, .max_arguments = null, .run = editTracks },
    .{ .name = "fields", .usage = "fields DATABASE IDS", .min_arguments = 2, .max_arguments = 2, .run = showTrackFields },
    .{ .name = "write-tags", .usage = "write-tags DATABASE IDS [--approve=DIGEST]", .min_arguments = 2, .max_arguments = 3, .run = writeTags },
    .{ .name = "undo-tags", .usage = "undo-tags DATABASE GROUP", .min_arguments = 2, .max_arguments = 2, .run = undoTagWrite },
    .{ .name = "prune-backups", .usage = "prune-backups DATABASE [--older-than=DAYS]", .min_arguments = 1, .max_arguments = 2, .run = pruneBackups },
    .{
        .name = "changes",
        .usage = "changes DATABASE ([--limit N] [--offset N] | GROUP | --export=FILE [--force])",
        .min_arguments = 1,
        .max_arguments = 5,
        .run = showChanges,
    },
};

fn findCommand(name: []const u8, argument_count: usize) ?*const Command {
    for (&commands) |*command| {
        if (!std.mem.eql(u8, command.name, name)) continue;
        if (argument_count < command.min_arguments) return null;
        if (command.max_arguments) |maximum| if (argument_count > maximum) return null;
        return command;
    }
    return null;
}

fn writeHelp(stdout: *std.Io.Writer) !void {
    try stdout.writeAll("Usage: orca-cli [");
    for (commands, 0..) |command, index| {
        if (index != 0) try stdout.writeAll(if (command.shares_usage_line) " | " else "\n" ++ usage_indent ++ "| ");
        try stdout.writeAll(command.usage);
    }
    try stdout.writeAll("]\n\n");
    try stdout.writeAll(help_details);
}

const help_details =
    \\scan prints a `progress` line each time the stage changes and every
    \\half second: stage=discover|read_tags|done, files= read so far,
    \\total= the files the walk will reach (- while they are counted),
    \\albums= distinct Releases written, and current= the file being read.
    \\
    \\estimate counts the audio files under PATH, by their bytes, without
    \\adding it to a Library; truncated=yes when it stopped at 100000.
    \\
    \\reconcile walks the registered root ROOT_ID (see roots) again, or with
    \\DIRs only those directories under it, given relative to the root, and
    \\marks missing only files under what it walked. A directory that is gone
    \\has everything under it marked missing; one that cannot be read is left
    \\as it was and the command fails. missing= counts the files marked.
    \\
    \\watch watches every registered root and reconciles each folder that
    \\changes under one, until --limit=MS of wall clock passes (default
    \\600000). Arming a root reconciles it whole first. It prints `watching`
    \\once every root is armed, with how long arming took; one `reconcile`
    \\line per reconcile, with the counters scan prints; and `library-changed`
    \\when a reconcile recorded or marked missing a file. A root's changes are
    \\reconciled once it has been quiet for --quiet=MS (default 2000), or
    \\--max-delay=MS (default 30000) after its first change. --once exits after
    \\the first reconcile that recorded or marked missing a file, the arming
    \\one included. A root that is deleted, moved or unmounted is reported as
    \\unavailable and never marked missing. Linux only.
    \\
    \\watch --maintenance also verifies recording IDs, as verify does, while
    \\nothing plays and no other job runs: one Release per unit, or at most 20
    \\Tracks on no Release once every Release is verified, with each unit
    \\starting --maintenance=MS (default 300000) after the last one ended. It
    \\prints a `maintenance:` line per unit; a disagreement lands in health
    \\as a recording_mismatch. `maintenance: blocked=REASON` reports a
    \\missing AcoustID key, or a provider that is backing off or in use by
    \\another Orca process; `blocked=none` follows once that clears.
    \\
    \\roots lists the registered folders. add-root and relocate-root make a
    \\relative path absolute against the working directory. remove-root
    \\forgets one and every file, Track, Release and Artist that exists only
    \\under it, and every Recording no file elsewhere holds, with its loves,
    \\ratings, play counts and playlist entries; listens stay in the
    \\history. A file also located under another root stays. Files on disk
    \\are not touched.
    \\
    \\folders lists each root with its file and Track counts and duration.
    \\With ROOT_ID it lists the root's subfolders, each with the same totals
    \\counted through every folder below it, then its audio files with their
    \\Track ids, then its images with their MIME type; with PATH, relative to
    \\the root, it lists that folder instead. A `folder:` line comes first:
    \\the Release every Track in the folder belongs to, the folder's Track
    \\and image counts, and when a scan last finished it, in Unix seconds.
    \\Each entry ends kind=folder|file|image and status=imported|unreadable,
    \\an image also role=front|back|booklet|other; a file is unreadable once
    \\backfill could not decode it. Missing files are left out.
    \\
    \\edit sets Orca's own values for a comma-separated list of Track ids;
    \\the files are not written. With no edits it lists the values held.
    \\  --title= --artist= --album= --album-artist= --date=
    \\  --composer= --comment=
    \\  --track=N --disc=N --compilation=0|1 --recording-id=MBID
    \\  --explicit=yes|no|clean
    \\  --genre=A;B        the Tracks' genres, which outrank their files' tags
    \\                     from then on; --clear=genre restores the tags'
    \\  --clear=FIELD      drop Orca's value so the file's tag applies again
    \\                     (title|artist|album|album_artist|track_number|
    \\                      disc_number|date|compilation|
    \\                      musicbrainz_recording_id|musicbrainz_release_id|
    \\                      musicbrainz_release_group_id|
    \\                      musicbrainz_release_track_id|
    \\                      musicbrainz_album_artist_id|explicit|composer|
    \\                      comment|genre)
    \\
    \\fields prints, for a comma-separated list of Track ids, each editable
    \\field's shared value, - when none, and mixed=yes when the Tracks
    \\disagree; edited=yes when Orca's value differs from a file's tag. Then
    \\the shared disc total and the cover the first Track shows, with how
    \\many of the Tracks show the same one.
    \\
    \\write-tags writes Orca's values for the Tracks into their files: an edit
    \\or an accepted correction wherever it differs from the file's tag, a
    \\match only where the file has no tag for its field. Each change is
    \\labelled edit or match. A match the
    \\file's tag disagrees with is printed as a conflict and not written; edit
    \\the field to lock your choice, then write again. Without
    \\--approve it prints the plan and its digest and writes nothing; run it
    \\again with --approve=DIGEST to write exactly that plan. A digest from a
    \\plan that no longer matches the library is refused. It prints the group
    \\to pass to undo-tags, which restores the files' previous bytes. A write
    \\that fails is rolled back and prints the file it stopped at and why.
    \\
    \\Each write keeps the files' previous bytes in DATABASE.orca-backups until
    \\they are undone or pruned. prune-backups deletes the backups of every
    \\write whose files all committed, or with --older-than=DAYS only of writes
    \\at least that old, and prints how many it deleted and their size. A
    \\pruned write cannot be undone.
    \\
    \\changes lists finished tag writes newest first, 50 at a time: group=,
    \\written_at= in Unix seconds, files=, state=applied|undoing|undone|
    \\rolled_back|failed|needs_reconciliation, can_undo=yes when undo-tags
    \\would run it, expired=yes when its backups were pruned, then title=, the
    \\Release its files share. It reads only the journal, so undo-tags can
    \\still refuse a file changed since. changes DATABASE GROUP reads each
    \\file and its backup and prints the same line with fields=N, every
    \\changed tag, and more_files=N, the files past the first 512 rows; then
    \\one FILE FIELD RESTORES CURRENT line per changed tag, RESTORES being
    \\what undo-tags puts back. FIELD is unknown when the backup was pruned or
    \\undone. --export=FILE writes every group's line to FILE, refusing an
    \\existing FILE unless --force is given.
    \\
    \\Browsing. artists lists Artists in sort order, with --album-artists only
    \\those a Release is filed under; releases lists Releases, optionally one
    \\Artist's; tracks lists Tracks in a named order, optionally scoped to
    \\one Artist or one Release. Options:
    \\  --artist ID        only this Artist
    \\  --release ID       only this Release (tracks only)
    \\  --genre ID         only Tracks with this genre, Releases with such a
    \\                     Track, or Artists credited on one
    \\  --loved            only loved Artists or Releases, or Tracks whose
    \\                     recording is loved
    \\  --sort KEY         id|artist|album|title|track|duration|added|rating|
    \\                     loved|play_count|last_played|year|loudness|
    \\                     bitrate|path|album_artist|genre (tracks; a Track
    \\                     without the value sorts last either way; loved
    \\                     is most recently loved first), or
    \\                     name|tracks|loved|recently_added (artists; tracks
    \\                     is most Tracks first, loved most recently loved
    \\                     first, recently_added newest Release first)
    \\  --desc             reverse the order
    \\  --limit N          page size, 1 to 512 (default 50)
    \\  --offset N         rows to skip
    \\
    \\genres lists the genres some Track carries, by name or with --sort
    \\tracks most Tracks first; --filter keeps those whose name contains the
    \\text, ignoring case, spaces, hyphens, slashes and dots. A file's genre
    \\tags are folded so that spellings of one genre (Hip-Hop, hip hop, Hip
    \\Hop/Rap) are one. genre prints one genre's counts, its Artists with the
    \\most Tracks and its most played Releases.
    \\
    \\genres --fill-from-musicbrainz asks MusicBrainz for the genres of up to
    \\--limit (default 512) Releases that have a MusicBrainz release ID and a
    \\Track with no genre, and puts the release group's three most voted
    \\genres, with any tied with the third and at most five, on the Release's
    \\Tracks with no genre from a file or an edit (provenance=provider in
    \\track). It prints `genre-fill: releases=N outcome=OUTCOME`. Genres from
    \\MusicBrainz are CC BY-NC-SA 3.0. artist-info --fetch and
    \\release-info --fetch fill them the same way unless genre-fill off was
    \\set; genre-fill prints the setting, or sets it to on or off.
    \\
    \\search lists the Artists, Releases, Tracks, Playlists and genres where
    \\every word of TEXT begins a word of the name or subtitle, ignoring case
    \\and diacritics, one `kind<TAB>id<TAB>title<TAB>subtitle` line each,
    \\grouped in that kind order and most relevant first. The subtitle is a
    \\Release's album artist, a Track's artist and album, or a Playlist's
    \\description. --artists, --releases, --tracks, --playlists and --genres
    \\cap each kind (default 5, 5, 8, 4, 3; at most 50). No character of TEXT
    \\is query syntax. releases --filter TEXT keeps the Releases search would
    \\find for it, under every other filter and sort.
    \\
    \\track prints what the Library recorded about one Track and its file: tags,
    \\format, size, path, stored loudness, whether the file carries a cover,
    \\the rating, and the file's last verification. It opens no file.
    \\
    \\lyrics prints one Track's lyrics: a `.lrc` file beside its file with
    \\the same name, or the lyrics in the file's tags, synced before plain and
    \\the `.lrc` first. The first line is `lyrics: source=sidecar|embedded|lrclib
    \\kind=synced|plain|instrumental lines=N outcome=OUTCOME source_name=NAME
    \\offset_ms=N`, then one
    \\line per lyric, synced ones led by `[mm:ss.xx]`. A Track with none prints
    \\`lyrics: outcome=OUTCOME`. Without --fetch it uses only what the
    \\Library already keeps from LRCLIB. With --fetch, a Track without synced
    \\lyrics of its own is looked up on LRCLIB by title, artist, album and
    \\duration; the outcome is then what the lookup came to (fetched, cached,
    \\cached_miss, not_found, no_metadata, refused, unavailable or busy),
    \\also when the Track's own plain lyrics are printed. LRCLIB's answer is
    \\kept in the Library, never in a file, and a Track it has nothing for
    \\is not asked about again for 7 days unless its values change.
    \\ORCA_LRCLIB_URL selects another server (https, or http to localhost
    \\only).
    \\
    \\artist-info prints what the Library keeps about one Artist: `photo=`
    \\with its source (local or commons), size, licence and credit,
    \\`biography=` with its source, article and licence, `years=`, the
    \\`origin=` (MusicBrainz's begin area, else area), the MusicBrainz and
    \\Wikidata IDs, `links:` with one line per link, the biography's text
    \\and `outcome=`. With --fetch it first looks for an image in the
    \\Artist's folder, then asks MusicBrainz for the Artist's MusicBrainz ID
    \\and for up to 100 of its release groups, Wikidata for its image,
    \\article and links, Wikimedia
    \\Commons for the image and its licence, and Wikipedia for the article's
    \\lead, in --lang (default en). Info fetched in the last 30 days is kept
    \\(outcome=cached) unless --force. --offline makes no request and uses
    \\only what is cached. It also asks ListenBrainz how many users listened
    \\to the Artist (`listeners=N (ListenBrainz)`) and ListenBrainz Labs for
    \\related artists (`related: N`, then one `score name mbid library=ID`
    \\line each), at most weekly. --include-releases then fetches each of the
    \\Artist's Releases as release-info does, and prints one `elsewhere:
    \\mbid<TAB>title<TAB>year<TAB>type<TAB>cover=yes|no|-[<TAB>with NAMES]`
    \\line per album or EP none of the Artist's Releases in the Library
    \\belongs to, newest first; NAMES are the credit's other artists. The
    \\fetch asks the Cover Art Archive for the front cover of each of those
    \\it has not asked about yet: `cover=yes` is a kept cover, `no`
    \\a group without one (asked again after 30 days), `-` one not asked
    \\about. The origin is the area followed by the subdivision it is in,
    \\such as `Portland, Oregon`. ORCA_MUSICBRAINZ_URL,
    \\ORCA_COVERARTARCHIVE_URL, ORCA_WIKIDATA_URL, ORCA_WIKIMEDIA_URL,
    \\ORCA_WIKIPEDIA_URL, ORCA_LISTENBRAINZ_URL and
    \\ORCA_LISTENBRAINZ_LABS_URL select other servers (https, or http to
    \\localhost only). artist-photo writes the photo to PATH. related
    \\prints the kept related artists alone. related-photo writes the photo
    \\kept for a related artist outside the Library to PATH, then prints its
    \\source, licence, credit and pages. release-group-cover writes the
    \\cover kept for a release group to PATH.
    \\
    \\release-info prints what the Library keeps about one Release:
    \\`description=` with its source, article, language and licence, the
    \\MusicBrainz release and release group IDs, the text and `outcome=`.
    \\With --fetch it asks MusicBrainz for the release group, Wikidata or the
    \\group's Wikipedia link for the article, and Wikipedia for its lead, in
    \\--lang (default en); --force and --offline work as for artist-info.
    \\
    \\play-tracks plays a comma-separated list of Track ids, or with
    \\--playlist=ID the playlist's entries that have a Track, as a playback
    \\queue. Options:
    \\  --device=ID        output device (0 = server default)
    \\  --volume=LINEAR    volume as a linear gain, 0 to 4 (default 1)
    \\  --set-volume=MS:LINEAR  set the volume to LINEAR once, MS after
    \\                     playback starts
    \\  --move=MS:FROM:TO  MS after playback starts, move the queue entry at
    \\                     position FROM to position TO and print a `move` line
    \\                     with result=ok|in_use|out_of_range; repeatable, at
    \\                     most 8 times
    \\  --replay-gain=off|track|album|smart   loudness correction per entry
    \\                     (default track); album uses the Release's, or the
    \\                     track's when the Release is not fully measured;
    \\                     smart uses album while the entry before or after
    \\                     it in playback order has the same Release
    \\  --preamp=DB        added to every measured correction, -15 to 15
    \\  --untagged=-6|as-is  level of an entry with no measurement (default
    \\                     as-is)
    \\  --no-peak-protection  let a correction push a peak past full scale
    \\  --stop-after-current  stop when the first entry heard ends
    \\  --eq=PRESET        equalizer preset: flat|bass|treble|vocal|loudness
    \\  --eq=G1,...,G10[:PREAMP]   ten band gains in dB (31 Hz to 16 kHz, each
    \\                     within 12) and a preamp in dB (default: minus the
    \\                     largest boost)
    \\  --crossfeed=AMOUNT stereo crossfeed for headphones, 0 to 1
    \\  --peq=FILE         parametric equalizer from an EqualizerAPO file, read
    \\                     as peq-check reads it; not with --eq
    \\  --start=N          queue position to begin at
    \\  --repeat=off|all|one
    \\  --shuffle
    \\  --tail=MS          on each new entry, seek to MS before its end
    \\  --skip-after=MS    issue next MS after each entry becomes audible
    \\  --previous-after=MS  issue previous once, MS after playback starts
    \\  --limit=MS         stop after MS of wall clock
    \\  --lyrics           read each audible Track's lyrics as lyrics does, and
    \\                     print a `lyric` line as each synced line is reached
    \\  --print-history    at the end, print the queue history newest first:
    \\                     one `history` line per entry with ended_at (Unix ms),
    \\                     reason (finished|skipped|replaced), track and title
    \\  --save-queue=NAME  at the end, save the current entry and those after
    \\                     it as playlist NAME and print its id and entry count
    \\  --save-state       at the end, save the queue and position for resume and
    \\                     print a `saved-state` line with entries, index and
    \\                     position_ms
    \\
    \\play-tracks prints one `signal:` line once playback is a second in: the
    \\source, each stage that changes the samples, the output stream,
    \\whether the path could be bit-perfect, and the ReplayGain source and
    \\settings as replay_gain_source=none|track|album|track_fallback
    \\preamp_db= peak_protection= untagged= peak_limited=, then the format the
    \\output device itself runs at as device_format=S16LE|S24LE|S24_32LE|S32LE|F32LE
    \\device_bits= device_rate=, or device_format=- when it is unknown (the device
    \\is suspended, virtual or not yet reported, or the backend is not PipeWire).
    \\It records listens in the Library's play history under the policy and
    \\recording setting `listens` keeps, and never sends them anywhere.
    \\
    \\play-folder plays every Track below PATH (relative to root ROOT_ID; ""
    \\is the root itself), recursively in path order, at most 10000. It
    \\prints the queue, then a `now-playing` line as each entry is heard.
    \\--device=ID is required; --shuffle shuffles the queue after its first
    \\entry; --limit=MS stops after MS of wall clock (default 10 minutes).
    \\
    \\resume loads the queue last saved into the Library, as by play-tracks
    \\--save-state, and prints `restored entries= index= position_ms=
    \\skipped_missing=`, where skipped_missing counts saved entries whose
    \\Track and Recording are both gone, then the queue from the saved index
    \\and a `status` line. It leaves the queue paused at the saved position;
    \\--play plays it for --limit=MS (default 10 seconds) and prints the
    \\`status` line again. The Library keeps where it stopped. --device=ID is
    \\required.
    \\
    \\peq-check reads an EqualizerAPO file and prints it back normalised: the
    \\Preamp, then one Filter line per filter, shelves as LSC and HSC, Gain on
    \\peaks and shelves, and Q on every filter. It reads Preamp lines, which
    \\add up, and at most 16 Filter lines of type PK, PEQ, LS, LSC, HS, HSC,
    \\LP, HP or NO with Fc 20 to 20000 Hz, Gain within 24 dB, and Q 0.1 to 20
    \\(0.3 to 2 on a shelf) or BW Oct; the Preamp must add up to -24 to +6 dB.
    \\peq-response prints the gain in dB the file applies at 32 frequencies
    \\from 20 Hz to 20 kHz, Preamp included, one `HZ<TAB>DB` line each, at the
    \\sample rate --rate gives (default 44100), stopping below half the rate;
    \\a filter at or above 0.45 of the rate is left out, as playback leaves it
    \\out.
    \\
    \\scrobble sends the listens and the love/hate changes queued for
    \\ListenBrainz. The token comes from ORCA_LISTENBRAINZ_TOKEN;
    \\ORCA_LISTENBRAINZ_URL selects another server (https, or http to
    \\localhost only). It works until both queues are empty, the scrobbler
    \\needs attention, or --timeout=MS passes (default 120000), prints one
    \\`scrobble:` line, and exits non-zero when the token is missing or
    \\rejected. --status prints the queue counts and makes no request.
    \\Listens are queued only while scrobbling is enabled, which the GTK
    \\app's preferences do; play-tracks never enables it.
    \\
    \\feedback loves, dislikes or clears the Tracks' recordings, and prints how
    \\many Tracks changed and how many were skipped. It is kept in the Library;
    \\scrobble sends it for recordings with a MusicBrainz ID.
    \\
    \\love-release loves the Releases, or clears their love, and prints how
    \\many changed and how many were skipped as unknown. Album love is kept
    \\in the Library only; scrobble never sends it. love-artist does the
    \\same for Artists.
    \\
    \\rate rates the Tracks' recordings in whole stars (--stars=N stores N*20)
    \\or 1 to 100, or clears the rating, and prints how many Tracks changed and
    \\how many were skipped for having no recording. Ratings are kept in the
    \\Library only; no file is written.
    \\
    \\Playlists are ordered lists of recordings, kept in the Library. playlists
    \\lists them by name: id, name, entries, entries with a Track, length and
    \\kind (manual or smart), then `imported`, `pinned`, `loved` and tags= when
    \\they apply. --smart, --manual, --pinned, --created-by-me and --imported
    \\keep only those playlists; --filter keeps names containing TEXT.
    \\playlist prints a `playlist` line with the kind, description, tags and
    \\most common genres, then the entries from position 0: the Track each
    \\plays (the lowest Track id of its recording), or `unavailable` when its
    \\recording has none. playlist-add appends the Tracks' recordings, or
    \\inserts them before position --at=N; playlist-remove removes a
    \\comma-separated list of positions; playlist-move moves the entry at FROM
    \\to TO. A playlist holds at most 10000 entries. playlist-update sets the
    \\description, pin, love or tags (at most 8, replacing the old ones) and
    \\prints the playlist's line.
    \\
    \\A smart playlist's entries are the Tracks its rules match whenever it is
    \\read, one per recording; its entries cannot be added, removed or moved.
    \\RULES_FILE is version 1 rules JSON, described in docs/api.md.
    \\smart-playlist-create creates one; smart-playlist-rules prints its rules,
    \\or replaces them with RULES_FILE first; smart-playlist-count prints how
    \\many Tracks RULES_FILE matches now and their total length, storing
    \\nothing, then with --sample=N the first N of them (at most 512) in the
    \\rules' order. playlist prints a formats: line, each codec's entry count
    \\and how many entries are analyzed.
    \\
    \\playlist-import creates a playlist from an M3U or M3U8 file, named after
    \\the file or --name=NAME, with " (2)" and so on added if that is taken.
    \\Each entry matches the library file at its path, relative to the playlist
    \\file or a file:// URI, or else the one Track with the artist, title and
    \\length (within 2 s) of its #EXTINF line. It prints the counts and the
    \\first 50 entries that matched nothing; no folder is scanned.
    \\playlist-export writes a playlist's entries that have a Track as UTF-8
    \\M3U with absolute paths, or with --relative paths relative to FILE's
    \\folder. It refuses to replace an existing FILE without --force.
    \\
    \\match searches MusicBrainz for every Track whose file has no MusicBrainz
    \\recording ID, and fingerprints its file and looks it up on AcoustID, once
    \\per service: a Track either service has answered for is not asked again.
    \\It keeps what it finds as matches to review. Each service is asked at most
    \\once a second, AcoustID about up to 20 fingerprints at a time, and answers
    \\are cached. --limit=N searches at most N Tracks; --no-fingerprints leaves
    \\AcoustID out. ORCA_MUSICBRAINZ_URL and ORCA_ACOUSTID_URL select other
    \\servers (https, or http to localhost only). matches lists a Track's
    \\matches, most confident first: id, confidence (0 to 1), MusicBrainz's
    \\score, source (musicbrainz, acoustid or both), AcoustID's score, recording
    \\ID, title, artist, album, track, length and release ID, then what that
    \\release says once it has been looked up: its title, artist and date, the
    \\disc, the track's title and artist, the release-track ID, and the
    \\recording ID the match would replace. A field not known is `-`.
    \\accept-match records one match in the Library only:
    \\its recording ID for the Track's file, its title and artist for every
    \\file of the Track, and dismisses the file's other matches; dismiss-match
    \\drops one. A match that would replace the file's recording ID is a
    \\correction: accepting it stores those values locked, so they outrank
    \\the file's tags, keeping a title or artist you set with edit; bulk
    \\acceptance never takes one. When every Track of the Release then names one MusicBrainz
    \\release, by an accepted match looked up on it or by the file's tag, the
    \\files of the Tracks accepted on it also get its album, album artist,
    \\date, disc and track numbers and release, release-group, release-track
    \\and album-artist IDs. A value you set with edit is kept. Both print how
    \\many values they stored. apply-release stores those release values for
    \\a Release that came to agree without an accept, as after an edit moved
    \\a stray file out of it. Releases can get new ids as albums regroup.
    \\apply-release --fields stores those fields of the best candidate's
    \\tracklist, locked: the release's album, album artist, date and IDs on
    \\every Track with a file, and each release track's title, artist,
    \\numbers and IDs on the Track release-alignment places on it. It prints
    \\release=, values_written=, track_values= and release_values_only= (how
    \\many Tracks took each), artist_ids=unknown when the tracklist predates
    \\Orca keeping the release's artist IDs (the album artist ID and
    \\compilation flag are then left alone until match --release=ID looks
    \\the release up again), and a left_alone line for each Track given no
    \\release-track values, with reason not_placed or no_play_file. An Apply
    \\that leaves no Track alone marks the Release as reviewed, whichever
    \\fields it stored, and prints its ID after reprojection as reviewed=,
    \\else -.
    \\mark-release-reviewed moves a Release to the reviewed bucket while its
    \\best candidate, tracklist, Tracks and their values stay as they are;
    \\every Track must be placed, and values that still differ stay as they
    \\are. A Release whose files all carry a release ID tag naming its best
    \\candidate, with every Track placed on that release's tracklist, is in
    \\the reviewed bucket without a review and prints from_tags; removing or
    \\changing one file's release ID tag returns it to its bucket.
    \\matches --releases --bucket=reviewed lists the reviewed Releases, and
    \\unmark-release-reviewed forgets a person's review so the Release
    \\returns to its bucket. matches --releases prints placed= and
    \\needs_pairing= for each Release with a tracklist, and reviewed= in its
    \\totals. matches --release=ID --diff prints each Track's title and
    \\artist credit beside the release track's.
    \\accept-matches accepts each file's best match at least as confident as
    \\--min-score. A match AcoustID found with a fingerprint score of at least
    \\0.9 comes first; among those, the higher percent, then the Track's own
    \\track number, then one MusicBrainz found too, the higher MusicBrainz
    \\score, the closer length and the lowest recording ID. Without one, the
    \\most confident match is accepted only when no other match of the file
    \\has as high a percent.
    \\
    \\match --release=ID searches only that Release's Tracks, then looks up
    \\the MusicBrainz release most of their matches list and points every
    \\match listing it at it. With
    \\--accept-min-score=SCORE it then accepts the Release's matches as
    \\accept-matches would, and with --cover-art it then fetches the Release's
    \\cover as cover-art does. It prints accepted=, cover_art= and release=,
    \\the Release the album's files are on afterwards.
    \\
    \\verify checks the recording ID of every identified Track's file against
    \\what AcoustID hears in its fingerprint, a Release at a time, and needs
    \\AcoustID. A file agrees when AcoustID lists its ID at a score of at least
    \\0.5; it disagrees when AcoustID does not and lists another recording at
    \\0.9 or more, which is then proposed as a correction; otherwise it is
    \\unconfirmed. A recording ID you set with edit is checked and never
    \\corrected. A file is verified again once its bytes or its recording ID
    \\change; one that disagrees only beside such a file of its Release, or
    \\with --track=ID. When the Release has a
    \\MusicBrainz release ID, the corrections of its files whose recording is
    \\on that release form one album correction, with their positions on it.
    \\--track=ID or --release=ID verifies only that Track or Release, and
    \\--limit=N at most N Tracks. It prints verified=, agreed=, disagreed=,
    \\unconfirmed=, skipped= (files never hashed, which it cannot check),
    \\correction_groups= and proposals=. track prints a Track's outcome.
    \\
    \\corrections lists the album corrections: group id, album and album
    \\artist, then one line per Track: its id, its title and disc-track
    \\position as it is and as the correction makes it, the recording ID and
    \\the one it replaces. accept-correction accepts a whole group as
    \\corrections, with each file's track and disc numbers and release-track
    \\ID, and dismiss-correction drops it; a match in a group is never
    \\accepted or dismissed alone. edit --clear=FIELD undoes a correction.
    \\
    \\cover-art fetches a Release's front cover from the Cover Art Archive into
    \\the Library, unless one of its files carries a cover or its folder holds a
    \\cover.jpg, front.jpg or folder.jpg, under the release ID its tags give or
    \\most of its accepted matches name. It prints where the cover comes from
    \\(chosen, embedded, folder, fetched, cached, cached-miss, not-found or
    \\no-release-id) and its size; artwork --release=ID then reads it. A
    \\release the archive has no cover for is not asked again for 30 days.
    \\--candidates lists the archive's images for the Release instead, its
    \\release's and its release group's fronts when its files name one group,
    \\up to 8: candidate=, kind=, size= (- when the full image would not
    \\come), mime=, approved=, thumbnail_bytes=, release=. Each full image is
    \\fetched to measure it and dropped; only a thumbnail is kept. The last
    \\line says source=partial when the release group's index would not come
    \\and only the release's own images were kept.
    \\--use=CAA_ID[:front|back|booklet] fetches a listed image again in full
    \\and keeps it as the Release's chosen cover of that kind, front by
    \\default, printing source=chosen; a chosen front is shown before any
    \\other. artwork --release=ID
    \\--set=PATH keeps a PNG, JPEG, GIF, WebP or BMP file as a chosen cover,
    \\--clear forgets the kept cover of --kind, and --kind=back|booklet
    \\reads those covers.
    \\Media files are never written. ORCA_COVERARTARCHIVE_URL selects another
    \\server (https, or http to localhost only).
    \\
    \\fingerprint prints a Track's AcoustID fingerprint and length, in fpcalc's
    \\format, decoding the first two minutes of its file unless the Library
    \\already holds it.
    \\
    \\submit-acoustid sends AcoustID the fingerprints of files whose recording
    \\ID came from an accepted match or an edit, once per file and ID, as the
    \\user whose key is in ORCA_ACOUSTID_USER_KEY. A file whose length is more
    \\than 30 s from its recording's is sent with its title, artist and album
    \\instead of the ID. --dry-run lists what would be sent and makes no
    \\request.
    \\
    \\analyze-library decodes every file the Library has not measured yet and
    \\stores its loudness, peak, clipping, silence, fingerprint and AcoustID
    \\fingerprint. That measurement is what ReplayGain on playback reads;
    \\without it every track plays at unity. It decodes whole files, so it is
    \\slow, and it is meant to be stopped and restarted: --cancel-after=MS
    \\interrupts it inside a file, the batch already measured is still
    \\committed, and the next run selects only what is left. --threads=N
    \\decodes up to N files of a batch at once (--batch=N, default 32); the
    \\default is one fewer than the machine's processors.
    \\
    \\duplicates reports every file whose audio the Library also holds
    \\somewhere else, as health issues that `health` then lists, one per file
    \\and the strongest that holds: exact_duplicate when the same bytes are
    \\stored twice (a second location, or another file with the same content
    \\hash), identical_audio when different bytes decode to the same lossless
    \\audio, and likely_duplicate when fingerprints match or two lossy
    \\decodes hash alike. It compares what analyze-library measured -- it
    \\opens no files -- so it is fast, and it is only as complete as that
    \\analysis: the uncomparable count is how many files it could say nothing
    \\about, and a zero-finding run over a library with a large uncomparable
    \\count means "not measured", not "no duplicates".
    \\
    \\health prints one issue per line: file id, severity, kind, the action
    \\that resolves it (match_or_edit, fetch_cover_art, compare_duplicate,
    \\review_correction or reveal_file), path and details. --kind=KIND lists
    \\only issues of that kind, in the same order. --summary prints one line
    \\per kind with an issue: kind, highest severity, count, files and bytes;
    \\for exact_duplicate, identical_audio and likely_duplicate, bytes counts
    \\only the copies beyond the one kept. --kind=artwork_problem --albums prints one line per
    \\album instead: release id, its worst problem, files=N with one,
    \\size=WIDTHxHEIGHT or size=- and the title, then albums and their count.
    \\health-dismiss hides an issue of a file until the file's bytes change;
    \\health-restore shows it again. KIND is the kind health prints.
    \\
    \\stats prints key=value lines: artists, releases, tracks, files (those
    \\with a location that is not missing), bytes, duration_ms,
    \\last_scan_finished_at, last_analysis_at and last_duplicate_scan_at, in
    \\Unix seconds, or - when no scan has completed, nothing is analysed or no
    \\duplicate scan has succeeded, then listens, the local play history.
    \\
    \\listens prints policy=, record= and listens=. --policy=half keeps a play
    \\heard for half the track or four minutes, ListenBrainz's rule; 30s keeps
    \\one heard for 30 seconds and full one heard to the end. A listen kept
    \\under 30s that falls short of ListenBrainz's rule stays local and is
    \\never sent. --record=off keeps no listens at all. --clear deletes every
    \\listen, every listen waiting to be sent and every play count, prints
    \\cleared=N and keeps ratings and loves.
    \\
    \\cache prints the bytes of fetched provider data: artwork_bytes (Cover
    \\Art Archive covers), photo_bytes (artist photos), lyrics_bytes (LRCLIB)
    \\and info_bytes (artist and release info). --clear deletes them and
    \\prints what they held; embedded and folder artwork and local lyrics stay.
    \\
    \\backfill re-reads the headers of files whose declared audio properties
    \\are missing and reprojects the Tracks derived from them, without walking
    \\a filesystem. --force also re-probes rows that already declare
    \\properties, which is for a probe implementation that improved rather
    \\than for ordinary use. It then measures the embedded covers and folder
    \\images a scan observed before Orca measured covers, and settles their
    \\artwork problems; their counts join the files'. --cancel-after=MS
    \\interrupts the job cooperatively once it has run that long; a later run
    \\resumes what it did not finish.
    \\
    \\The host-independent Orca control client.
    \\
;

fn printVersion(context: Context) !void {
    try context.stdout.print("orca-cli {f}\n", .{liborca.version});
}

fn runDemo(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();

    const request_id = try runtime.submit(.create_player);
    _ = runtime.processNextCommand();
    const event = runtime.pollEvent() orelse return error.MissingCompletionEvent;
    if (event.request_id != request_id) return error.UnexpectedCompletionEvent;
    switch (event.outcome) {
        .player_created => |player| try context.stdout.print(
            "created Player handle {d}:{d}\n",
            .{ player.index, player.generation },
        ),
        else => return error.PlayerCreationFailed,
    }
}

/// The same path the C ABI exposes: register the root unless it already is,
/// start the scan as a runtime job on a registered worker, and poll it. The
/// scan projects as it commits, which is why there is no separate projection
/// step here.
fn scanRoot(context: Context) !void {
    const stdout = context.stdout;
    if (context.arguments.len == 3 and !std.mem.eql(u8, context.arguments[2], "--reprobe")) return error.UnknownOption;
    const reprobe_all = context.arguments.len == 3;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library_handle = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    // Re-adding a registered root would rebind it to whatever volume its path
    // is on now, so an unmounted drive's empty mount point would pass the
    // volume check and the scan would mark every file under it missing.
    const root_path = try absolutePath(context, context.arguments[1]);
    const root_id = try registeredRootId(&runtime, library_handle, root_path) orelse
        (try bindRoot(&runtime, library_handle, context, root_path)).root_id;
    const job_handle = try runtime.startLibraryScan(library_handle, .{ .root_id = root_id, .reprobe_all = reprobe_all });
    awaitScan(&runtime, stdout, job_handle) catch |err| {
        if (err == error.JobFailed and (try runtime.jobScanStats(job_handle)).volume_changed)
            return error.RootVolumeChanged;
        return err;
    };
    try printScanStats(stdout, try runtime.jobScanStats(job_handle));
}

const scan_progress_interval_ms = 500;

fn awaitScan(runtime: *liborca.Runtime, stdout: *std.Io.Writer, job_handle: liborca.JobHandle) !void {
    var printed_stage: ?liborca.ScanStage = null;
    var since_printed_ms: u64 = 0;
    while (true) {
        runtime.pump();
        while (runtime.pollEvent()) |_| {}
        while (runtime.pollTelemetry()) |_| {}
        const snapshot = try runtime.jobSnapshotSynced(job_handle);
        const stats = try runtime.jobScanStats(job_handle);
        if (printed_stage != stats.stage or since_printed_ms >= scan_progress_interval_ms) {
            const current = stats.current_path.slice();
            try stdout.print("progress stage={t} files={d} total=", .{ stats.stage, stats.files_seen });
            if (snapshot.total_units) |total| try stdout.print("{d}", .{total}) else try stdout.writeAll("-");
            try stdout.print(" albums={d} current={s}\n", .{
                stats.albums_found,
                if (current.len == 0) "-" else current,
            });
            try stdout.flush();
            printed_stage = stats.stage;
            since_printed_ms = 0;
        }
        switch (snapshot.state) {
            .succeeded => return,
            .failed => return error.JobFailed,
            .cancelled => {
                try stdout.print("cancelled after {d} files\n", .{snapshot.completed_units});
                return;
            },
            else => {},
        }
        sleepMilliseconds(20);
        since_printed_ms += 20;
    }
}

fn estimateFolder(context: Context) !void {
    var token: liborca.CancellationToken = .{};
    const estimate = try liborca.estimateAudioFiles(
        context.io,
        context.allocator,
        context.arguments[0],
        &token,
        liborca.estimate_default_limit,
    );
    try context.stdout.print("audio_files={d} truncated={s}\n", .{
        estimate.audio_files,
        if (estimate.truncated) "yes" else "no",
    });
}

fn addRoot(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library_handle = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const binding = try bindRoot(&runtime, library_handle, context, try absolutePath(context, context.arguments[1]));
    try context.stdout.print("root {d} on volume {d}\n", .{ binding.root_id, binding.volume_id });
}

fn absolutePath(context: Context, path: []const u8) ![]const u8 {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return path;
    const working_directory = try std.process.currentPathAlloc(context.io, context.allocator);
    return std.fs.path.resolve(context.allocator, &.{ working_directory, path });
}

/// Adding a root is an explicit user action, so this is the one path allowed
/// to write a volume identifier to a mount root that has no filesystem UUID
/// of its own, and to bind an existing root to the volume it is on now.
fn bindRoot(
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    context: Context,
    path: []const u8,
) !liborca.RootBinding {
    const binding = try runtime.libraryAddRoot(library, context.io, path);
    if (binding.claimed_locations != 0) try context.stdout.print(
        "claimed {d} locations for volume {d}\n",
        .{ binding.claimed_locations, binding.volume_id },
    );
    return binding;
}

fn registeredRootId(runtime: *liborca.Runtime, library: liborca.LibraryHandle, path: []const u8) !?i64 {
    var page = try runtime.libraryRootPage(library, 512, 0);
    defer page.deinit();
    for (page.items) |root| {
        if (std.mem.eql(u8, root.path, path)) return root.id;
    }
    return null;
}

/// Walks a registered root, or only the given directories under it, and marks
/// missing only the files under what it walked.
fn reconcileRoot(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library_handle = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const directories = context.arguments[2..];
    const job_handle = try runtime.startLibraryReconcile(library_handle, .{
        .root_id = try std.fmt.parseInt(i64, context.arguments[1], 10),
        .scope = if (directories.len == 0) .whole_root else .{ .subtrees = directories },
    });
    try awaitJob(&runtime, context.stdout, job_handle, null);
    try printScanStats(context.stdout, try runtime.jobScanStats(job_handle));
}

fn watchLibrary(context: Context) !void {
    const stdout = context.stdout;
    const options = try parseJobOptions(context.arguments[1..], &.{ .quiet, .max_delay, .once, .limit, .maintenance, .pause_after, .resume_after });
    const limit_ms: u64 = options.limit orelse 10 * 60 * 1000;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    if (options.maintenance_ms != null) {
        try identifyOrca(&runtime);
        if (context.environ.get("ORCA_MUSICBRAINZ_URL")) |url| {
            if (url.len > 0) try runtime.setMusicBrainzServer(try context.allocator.dupe(u8, url));
        }
        try configureAcoustId(context.allocator, &runtime, context.environ);
    }
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const root_count = try enabledRootCount(&runtime, library);
    const started_ms = monotonicMs(context.io);
    try runtime.libraryWatch(library, .{
        .quiet_ms = options.quiet_ms orelse 2000,
        .max_delay_ms = options.max_delay_ms orelse 30_000,
    });
    if (options.maintenance_ms) |interval_ms| {
        try runtime.libraryMaintenance(library, .{ .enabled = true, .interval_ms = interval_ms });
    }
    var armed = false;
    var unavailable: u32 = 0;
    var limit_reported = false;
    var maintenance_blocked: ?liborca.MaintenanceBlock = null;
    var pause: PauseSchedule = .{ .pause_after_ms = options.pause_after_ms, .resume_after_ms = options.resume_after_ms };
    while (monotonicMs(context.io) - started_ms < limit_ms) {
        switch (pause.due(monotonicMs(context.io) - started_ms)) {
            .pause => {
                try runtime.pauseAll(library);
                try printLibraryJobsState(context.allocator, &runtime, stdout, library);
            },
            .resume_jobs => {
                try runtime.resumeAll(library);
                try printLibraryJobsState(context.allocator, &runtime, stdout, library);
            },
            .none => {},
        }
        runtime.pump();
        var changed = false;
        while (runtime.pollEvent()) |event| switch (event.outcome) {
            .job_finished => |finished| {
                if (try runtime.jobOrigin(finished.job) == .maintenance) {
                    const unit = (try runtime.libraryMaintenanceStatus(library)).last orelse continue;
                    try stdout.print("maintenance: release={?d} state={t} verified={d} disagreed={d} corrections={d}\n", .{
                        unit.release_id,
                        unit.state,
                        unit.stats.verified,
                        unit.stats.disagreed,
                        unit.stats.proposals_stored,
                    });
                    continue;
                }
                const root_id = try runtime.jobReconcileRoot(finished.job) orelse continue;
                const stats = try runtime.jobScanStats(finished.job);
                try stdout.print("reconcile root={d} state={t} ", .{ root_id, finished.state });
                try printScanCounters(stdout, stats);
                changed = changed or stats.changed + stats.marked_missing != 0;
            },
            else => {},
        };
        while (runtime.pollTelemetry()) |telemetry| switch (telemetry) {
            .library_changed => try stdout.writeAll("library-changed\n"),
            else => {},
        };
        const status = try runtime.libraryWatchStatus(library);
        if (status.state == .off) return error.WatcherStopped;
        if (!armed and status.roots_watched + status.roots_unavailable >= root_count) {
            armed = true;
            try stdout.print("watching roots={d} unavailable={d} directories={d} armed_in={d}ms\n", .{
                status.roots_watched,
                status.roots_unavailable,
                status.directories_watched,
                monotonicMs(context.io) - started_ms,
            });
        }
        if (armed and status.roots_unavailable != unavailable) {
            unavailable = status.roots_unavailable;
            try stdout.print("unavailable roots={d}\n", .{unavailable});
        }
        if (status.watch_limit_reached and !limit_reported) {
            limit_reported = true;
            try stdout.print("watch-limit roots={d} directories={d}; raise fs.inotify.max_user_watches\n", .{
                status.roots_degraded,
                status.directories_watched,
            });
        }
        if (options.maintenance_ms != null) {
            const maintenance = try runtime.libraryMaintenanceStatus(library);
            if (maintenance.blocked != maintenance_blocked) {
                maintenance_blocked = maintenance.blocked;
                if (maintenance.blocked) |blocked| {
                    try stdout.print("maintenance: blocked={t}\n", .{blocked});
                } else {
                    try stdout.writeAll("maintenance: blocked=none\n");
                }
            }
        }
        try stdout.flush();
        if (options.once and changed) return;
        sleepMilliseconds(@intCast(@min(runtime.nextPumpTimeoutMs() orelse 50, 50)));
    }
}

fn enabledRootCount(runtime: *liborca.Runtime, library: liborca.LibraryHandle) !u32 {
    var roots = try runtime.libraryRootPage(library, 512, 0);
    defer roots.deinit();
    var count: u32 = 0;
    for (roots.items) |root| {
        if (root.enabled) count += 1;
    }
    return count;
}

fn monotonicMs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).toMilliseconds());
}

const PauseSchedule = struct {
    pause_after_ms: ?u64,
    resume_after_ms: ?u64,
    paused: bool = false,
    resumed: bool = false,

    const Step = enum { none, pause, resume_jobs };

    fn due(self: *PauseSchedule, elapsed_ms: u64) Step {
        const pause_ms = self.pause_after_ms orelse return .none;
        if (!self.paused) {
            if (elapsed_ms < pause_ms) return .none;
            self.paused = true;
            return .pause;
        }
        const resume_ms = self.resume_after_ms orelse return .none;
        if (self.resumed or elapsed_ms < resume_ms) return .none;
        self.resumed = true;
        return .resume_jobs;
    }
};

fn printLibraryJobsState(
    allocator: std.mem.Allocator,
    runtime: *liborca.Runtime,
    stdout: *std.Io.Writer,
    library: liborca.LibraryHandle,
) !void {
    const queued = try runtime.jobQueuePage(library, allocator);
    defer allocator.free(queued);
    const maintenance = try runtime.libraryMaintenanceStatus(library);
    try stdout.print("jobs: state={s} queue={d} maintenance={t}\n", .{
        if (try runtime.libraryJobsPaused(library)) "paused" else "running",
        queued.len,
        maintenance.state,
    });
    try stdout.flush();
}

const StartableJob = enum { scan, analysis, duplicates, backfill, project, consistency };

fn startListedJob(runtime: *liborca.Runtime, library: liborca.LibraryHandle, kind: StartableJob) !liborca.JobHandle {
    return switch (kind) {
        .scan => runtime.startLibraryScan(library, .{}),
        .analysis => runtime.startLibraryAnalysis(library, .{}),
        .duplicates => runtime.startLibraryDuplicateScan(library, .{}),
        .backfill => runtime.startLibraryPropertyBackfill(library, .{}),
        .project => runtime.startLibraryProjection(library),
        .consistency => runtime.startLibraryConsistencyPass(library, .{}),
    };
}

/// `orca-cli jobs DATABASE [--start=KIND]... [--pause-after=MS]
/// [--resume-after=MS]` starts the Jobs in one runtime, so each after the
/// first waits for the Library's slot, pauses and resumes the first, and
/// prints each state change until all have finished. `--history` lists
/// the Library's finished Jobs instead.
fn runJobs(context: Context) !void {
    const allocator = context.allocator;
    var starts: std.ArrayList(StartableJob) = .empty;
    var history = false;
    var filter: liborca.JobHistoryFilter = .all;
    var limit: u32 = 50;
    var offset: u32 = 0;
    var pause: PauseSchedule = .{ .pause_after_ms = null, .resume_after_ms = null };
    var index: usize = 1;
    while (index < context.arguments.len) : (index += 1) {
        const argument = context.arguments[index];
        if (std.mem.startsWith(u8, argument, "--start=")) {
            const kind = std.meta.stringToEnum(StartableJob, argument["--start=".len..]) orelse return error.UnknownJobKind;
            try starts.append(allocator, kind);
        } else if (std.mem.eql(u8, argument, "--history")) {
            history = true;
        } else if (std.mem.startsWith(u8, argument, "--filter=")) {
            filter = std.meta.stringToEnum(liborca.JobHistoryFilter, argument["--filter=".len..]) orelse return error.UnknownHistoryFilter;
        } else if (std.mem.startsWith(u8, argument, "--pause-after=")) {
            pause.pause_after_ms = try std.fmt.parseInt(u64, argument["--pause-after=".len..], 10);
        } else if (std.mem.startsWith(u8, argument, "--resume-after=")) {
            pause.resume_after_ms = try std.fmt.parseInt(u64, argument["--resume-after=".len..], 10);
        } else if (std.mem.eql(u8, argument, "--limit") or std.mem.eql(u8, argument, "--offset")) {
            index += 1;
            if (index == context.arguments.len) return error.MissingOptionValue;
            const value = try std.fmt.parseInt(u32, context.arguments[index], 10);
            if (argument[2] == 'l') limit = value else offset = value;
        } else return error.UnknownOption;
    }
    if (history == (starts.items.len != 0)) return error.JobsNeedStartOrHistory;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    if (history) return printJobHistory(allocator, &runtime, context.stdout, library, filter, limit, offset);

    const handles = try allocator.alloc(liborca.JobHandle, starts.items.len);
    for (starts.items, handles) |kind, *job_handle| job_handle.* = try startListedJob(&runtime, library, kind);
    const queued = try runtime.jobQueuePage(library, allocator);
    for (handles, starts.items, 0..) |job_handle, kind, position| {
        const snapshot = try runtime.jobSnapshotSynced(job_handle);
        try context.stdout.print("job={d} kind={t} state={t}", .{ position + 1, kind, snapshot.state });
        for (queued) |entry| {
            if (!entry.job.eql(job_handle)) continue;
            const after = entry.after orelse break;
            try context.stdout.print(" after={d}", .{jobPosition(handles, after)});
        }
        try context.stdout.writeByte('\n');
    }
    try context.stdout.flush();
    try followJobs(context, &runtime, handles, &pause);
}

fn jobPosition(handles: []const liborca.JobHandle, job_handle: liborca.JobHandle) usize {
    for (handles, 1..) |candidate, position| {
        if (candidate.eql(job_handle)) return position;
    }
    return 0;
}

fn followJobs(context: Context, runtime: *liborca.Runtime, handles: []const liborca.JobHandle, pause: *PauseSchedule) !void {
    const stdout = context.stdout;
    const states = try context.allocator.alloc(liborca.JobState, handles.len);
    for (handles, states) |job_handle, *state| state.* = (try runtime.jobSnapshotSynced(job_handle)).state;
    const started_ms = monotonicMs(context.io);
    while (true) {
        const step = pause.due(monotonicMs(context.io) - started_ms);
        if (step != .none) for (handles, states) |job_handle, state| {
            if (state != .running and state != .paused) continue;
            if (step == .pause) runtime.pauseJob(job_handle) catch continue else runtime.resumeJob(job_handle) catch continue;
            break;
        };
        runtime.pump();
        while (runtime.pollEvent()) |_| {}
        while (runtime.pollTelemetry()) |_| {}
        var live = false;
        for (handles, states, 1..) |job_handle, *state, position| {
            const snapshot = try runtime.jobSnapshotSynced(job_handle);
            if (snapshot.state != state.*) {
                state.* = snapshot.state;
                try stdout.print("job={d} state={t} completed={d}", .{ position, snapshot.state, snapshot.completed_units });
                if (snapshot.total_units) |total| try stdout.print(" total={d}", .{total});
                try stdout.writeByte('\n');
                try stdout.flush();
            }
            switch (snapshot.state) {
                .succeeded, .failed, .cancelled => {},
                else => live = true,
            }
        }
        if (!live) return;
        sleepMilliseconds(20);
    }
}

fn printJobHistory(
    allocator: std.mem.Allocator,
    runtime: *liborca.Runtime,
    stdout: *std.Io.Writer,
    library: liborca.LibraryHandle,
    filter: liborca.JobHistoryFilter,
    limit: u32,
    offset: u32,
) !void {
    const entries = try runtime.jobHistoryPage(library, allocator, filter, limit, offset);
    defer allocator.free(entries);
    for (entries) |entry| {
        try stdout.print("{d}\t{t}\t{t}\tstarted_at={d}\tduration_s={d}\tcompleted={d}", .{
            entry.id,
            entry.kind,
            entry.state,
            entry.started_at,
            @max(entry.finished_at - entry.started_at, 0),
            entry.completed_units,
        });
        if (entry.total_units) |total| try stdout.print("\ttotal={d}", .{total});
        if (entry.undo_group_id) |group| try stdout.print("\tundo={d}", .{group});
        if (entry.error_text.len != 0) try stdout.print("\terror={s}", .{entry.error_text.slice()});
        try stdout.print("\tretry={s}\tsummary={s}\n", .{ if (entry.retryable) "yes" else "no", entry.summary.slice() });
    }
}

/// `orca-cli retry-job DATABASE HISTORY_ID`
fn retryJob(context: Context) !void {
    const history_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    try identifyOrca(&runtime);
    try configureArtistInfo(context.allocator, &runtime, context.environ);
    try configureAcoustId(context.allocator, &runtime, context.environ);
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const job_handle = try runtime.jobRetry(library, history_id);
    const snapshot = try runtime.jobSnapshotSynced(job_handle);
    try context.stdout.print("job=1 kind={t} state={t}\n", .{ snapshot.kind, snapshot.state });
    try context.stdout.flush();
    var pause: PauseSchedule = .{ .pause_after_ms = null, .resume_after_ms = null };
    try followJobs(context, &runtime, &.{job_handle}, &pause);
}

/// Reprojection without a filesystem walk: this is what refreshes the library
/// after a metadata edit or a provider acceptance, and it is why the
/// projection is a pass of its own rather than part of the scanner.
fn projectLibrary(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library_handle = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const job_handle = try runtime.startLibraryProjection(library_handle);
    try awaitJob(&runtime, context.stdout, job_handle, null);
    try printScanStats(context.stdout, try runtime.jobScanStats(job_handle));
}

const JobOption = enum {
    batch,
    limit,
    threads,
    cancel_after,
    force,
    no_fingerprints,
    status,
    timeout,
    dry_run,
    quiet,
    max_delay,
    once,
    release,
    track,
    accept_min_score,
    cover_art,
    reidentify,
    maintenance,
    fetch,
    pause_after,
    resume_after,

    fn spelling(self: JobOption) []const u8 {
        return switch (self) {
            .batch => "--batch=",
            .limit => "--limit=",
            .threads => "--threads=",
            .cancel_after => "--cancel-after=",
            .force => "--force",
            .no_fingerprints => "--no-fingerprints",
            .status => "--status",
            .timeout => "--timeout=",
            .dry_run => "--dry-run",
            .quiet => "--quiet=",
            .max_delay => "--max-delay=",
            .once => "--once",
            .release => "--release=",
            .track => "--track=",
            .accept_min_score => "--accept-min-score=",
            .cover_art => "--cover-art",
            .reidentify => "--reidentify",
            .maintenance => "--maintenance",
            .fetch => "--fetch",
            .pause_after => "--pause-after=",
            .resume_after => "--resume-after=",
        };
    }
};

const JobOptions = struct {
    batch_size: ?usize = null,
    limit: ?u32 = null,
    threads: ?u16 = null,
    cancel_after_ms: ?u64 = null,
    force: bool = false,
    no_fingerprints: bool = false,
    status: bool = false,
    timeout_ms: ?u64 = null,
    dry_run: bool = false,
    quiet_ms: ?u32 = null,
    max_delay_ms: ?u32 = null,
    once: bool = false,
    release_id: ?i64 = null,
    track_id: ?i64 = null,
    accept_min_score: ?f32 = null,
    cover_art: bool = false,
    reidentify: bool = false,
    maintenance_ms: ?u32 = null,
    fetch: bool = false,
    pause_after_ms: ?u64 = null,
    resume_after_ms: ?u64 = null,
};

fn parseJobOptions(arguments: []const []const u8, comptime accepted: []const JobOption) !JobOptions {
    var options: JobOptions = .{};
    next_argument: for (arguments) |argument| {
        if (comptime std.mem.indexOfScalar(JobOption, accepted, .maintenance) != null) {
            if (std.mem.startsWith(u8, argument, "--maintenance=")) {
                options.maintenance_ms = try std.fmt.parseInt(u32, argument["--maintenance=".len..], 10);
                continue;
            }
        }
        inline for (accepted) |option| {
            const spelling = comptime option.spelling();
            const takes_value = comptime std.mem.endsWith(u8, spelling, "=");
            const matches = if (takes_value)
                std.mem.startsWith(u8, argument, spelling)
            else
                std.mem.eql(u8, argument, spelling);
            if (matches) {
                const value = argument[spelling.len..];
                switch (option) {
                    .batch => options.batch_size = try std.fmt.parseInt(usize, value, 10),
                    .limit => options.limit = try std.fmt.parseInt(u32, value, 10),
                    .threads => options.threads = try parseThreads(value),
                    .cancel_after => options.cancel_after_ms = try std.fmt.parseInt(u64, value, 10),
                    .force => options.force = true,
                    .no_fingerprints => options.no_fingerprints = true,
                    .status => options.status = true,
                    .timeout => options.timeout_ms = try std.fmt.parseInt(u64, value, 10),
                    .dry_run => options.dry_run = true,
                    .quiet => options.quiet_ms = try std.fmt.parseInt(u32, value, 10),
                    .max_delay => options.max_delay_ms = try std.fmt.parseInt(u32, value, 10),
                    .once => options.once = true,
                    .release => options.release_id = try std.fmt.parseInt(i64, value, 10),
                    .track => options.track_id = try std.fmt.parseInt(i64, value, 10),
                    .accept_min_score => options.accept_min_score = try std.fmt.parseFloat(f32, value),
                    .cover_art => options.cover_art = true,
                    .reidentify => options.reidentify = true,
                    .maintenance => options.maintenance_ms = (liborca.MaintenanceOptions{ .enabled = true }).interval_ms,
                    .fetch => options.fetch = true,
                    .pause_after => options.pause_after_ms = try std.fmt.parseInt(u64, value, 10),
                    .resume_after => options.resume_after_ms = try std.fmt.parseInt(u64, value, 10),
                }
                continue :next_argument;
            }
        }
        return error.UnknownOption;
    }
    return options;
}

fn parseThreads(text: []const u8) !u16 {
    const threads = try std.fmt.parseInt(u16, text, 10);
    if (threads == 0) return error.InvalidThreadCount;
    return threads;
}

/// Repairs `files` rows whose declared audio properties are missing, and
/// measures covers observed before Orca measured covers, with no filesystem
/// walk. The job reprojects each repaired batch itself, which is
/// why there is no `project` step after this one. `--cancel-after=MS` is the
/// same kind of affordance `play-tracks` carries: the CLI is the
/// architectural test client, and a cooperative cancellation nothing outside
/// a unit test can trigger is not one a host can rely on.
fn backfillProperties(context: Context) !void {
    const stdout = context.stdout;
    const options = try parseJobOptions(context.arguments[1..], &.{ .force, .cancel_after });
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library_handle = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const job_handle = try runtime.startLibraryPropertyBackfill(library_handle, .{
        .force = options.force,
    });
    const planned = try runtime.jobSnapshotSynced(job_handle);
    try stdout.print("{d} files and covers to probe\n", .{planned.total_units orelse 0});
    try stdout.flush();
    try awaitJob(&runtime, stdout, job_handle, options.cancel_after_ms);
    try printBackfillStats(stdout, try runtime.jobScanStats(job_handle));
}

/// The library-wide half of `analyze`. It decodes whole files, so a real run
/// is measured in hours and `--cancel-after=MS` is not a test affordance but
/// the ordinary way to use it: stop it, start it again, and it selects only
/// what is left.
fn analyzeLibrary(context: Context) !void {
    const stdout = context.stdout;
    const options = try parseJobOptions(context.arguments[1..], &.{ .batch, .threads, .cancel_after });
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library_handle = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    var request: liborca.AnalysisRequest = .{ .threads = options.threads };
    if (options.batch_size) |batch_size| if (batch_size != 0) {
        request.batch_size = batch_size;
    };
    const job_handle = try runtime.startLibraryAnalysis(library_handle, request);
    const planned = try runtime.jobSnapshotSynced(job_handle);
    try stdout.print("{d} files to analyze\n", .{planned.total_units orelse 0});
    try stdout.flush();
    try awaitJob(&runtime, stdout, job_handle, options.cancel_after_ms);
    try printAnalysisStats(stdout, try runtime.jobScanStats(job_handle));
    try stdout.print("{d} files still to analyze\n", .{
        try runtime.libraryUnanalyzedCount(library_handle),
    });
}

/// The question the analysis exists to answer, asked over the stored
/// measurements rather than over the files. It opens nothing, so a run is
/// seconds where the analysis behind it is hours.
fn findDuplicates(context: Context) !void {
    for (context.arguments[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--groups")) return listDuplicateGroups(context);
        if (std.mem.startsWith(u8, argument, "--group=")) {
            if (context.arguments.len != 2) return error.UnknownOption;
            return showDuplicateGroup(context, try std.fmt.parseInt(i64, argument["--group=".len..], 10));
        }
    }
    const stdout = context.stdout;
    const options = try parseJobOptions(context.arguments[1..], &.{ .batch, .cancel_after });
    const database_path = try context.allocator.dupeSentinel(u8, context.arguments[0], 0);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library_handle = try runtime.openLibrary(context.io, database_path);
    var request: liborca.DuplicateScanRequest = .{};
    if (options.batch_size) |batch_size| if (batch_size != 0) {
        request.batch_size = batch_size;
    };
    const job_handle = try runtime.startLibraryDuplicateScan(library_handle, request);
    const planned = try runtime.jobSnapshotSynced(job_handle);
    try stdout.print("{d} files to examine\n", .{planned.total_units orelse 0});
    try stdout.flush();
    try awaitJob(&runtime, stdout, job_handle, options.cancel_after_ms);
    try printDuplicateStats(stdout, try runtime.jobScanStats(job_handle));
}

fn checkConsistency(context: Context) !void {
    const stdout = context.stdout;
    const options = try parseJobOptions(context.arguments[1..], &.{ .batch, .cancel_after });
    const database_path = try context.allocator.dupeSentinel(u8, context.arguments[0], 0);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library_handle = try runtime.openLibrary(context.io, database_path);
    var request: liborca.ConsistencyRequest = .{};
    if (options.batch_size) |batch_size| if (batch_size != 0) {
        request.batch_size = batch_size;
    };
    const job_handle = try runtime.startLibraryConsistencyPass(library_handle, request);
    const planned = try runtime.jobSnapshotSynced(job_handle);
    try stdout.print("{d} releases to examine\n", .{planned.total_units orelse 0});
    try stdout.flush();
    try awaitJob(&runtime, stdout, job_handle, options.cancel_after_ms);
    const stats = try runtime.jobScanStats(job_handle);
    try stdout.print("releases={d} issues={d} batches={d} cancelled={s}\n", .{
        stats.files_seen,
        stats.changed,
        stats.batches_committed,
        if (stats.cancelled) "yes" else "no",
    });
    inline for (@typeInfo(liborca.IssueCategory).@"enum".field_names) |name| {
        const category = @field(liborca.IssueCategory, name);
        try stdout.print("{s}={d} ", .{ name, try runtime.libraryMetadataIssueCount(library_handle, category) });
    }
    try stdout.print("open={d}\n", .{try runtime.libraryMetadataIssueCount(library_handle, null)});
}

fn listMetadataIssues(context: Context) !void {
    var category: ?liborca.IssueCategory = null;
    var limit: u32 = 256;
    var offset: u32 = 0;
    var index: usize = 1;
    while (index < context.arguments.len) : (index += 1) {
        const argument = context.arguments[index];
        if (std.mem.startsWith(u8, argument, "--category=")) {
            category = std.meta.stringToEnum(liborca.IssueCategory, argument["--category=".len..]) orelse
                return error.UnknownIssueCategory;
        } else if (std.mem.eql(u8, argument, "--limit") or std.mem.eql(u8, argument, "--offset")) {
            index += 1;
            if (index == context.arguments.len) return error.MissingOptionValue;
            const value = try std.fmt.parseInt(u32, context.arguments[index], 10);
            if (std.mem.eql(u8, argument, "--limit")) limit = value else offset = value;
        } else return error.UnknownOption;
    }
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    var page = try runtime.libraryMetadataIssuePage(library, context.allocator, category, limit, offset);
    defer page.deinit();
    const stdout = context.stdout;
    for (page.items) |group| {
        try stdout.print("group={d} release={d} category={t} field={t} tracks={d} title={s} artist={s}\n", .{
            group.id,
            group.release_id,
            group.category,
            group.field,
            group.track_count,
            group.title,
            group.artist,
        });
        for (group.options) |option| try stdout.print("  option={d} value={s} support={s}\n", .{
            option.id,
            option.value,
            option.support.slice(),
        });
        for (group.proposals) |proposal| try stdout.print("  proposal track={d} title={s} current={s} proposed={s}\n", .{
            proposal.track_id,
            proposal.title,
            proposal.current orelse "-",
            proposal.proposed,
        });
    }
    try stdout.print("issues={d}\n", .{try runtime.libraryMetadataIssueCount(library, category)});
}

fn applyMetadataIssue(context: Context) !void {
    const group_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    var choice: ?liborca.MetadataIssueChoice = null;
    var tracks: ?std.ArrayList(i64) = null;
    defer if (tracks) |*ids| ids.deinit(context.allocator);
    for (context.arguments[2..]) |argument| {
        if (std.mem.startsWith(u8, argument, "--option=")) {
            if (choice != null) return error.IssueChoiceRequired;
            choice = .{ .option = try std.fmt.parseInt(u32, argument["--option=".len..], 10) };
        } else if (std.mem.startsWith(u8, argument, "--custom=")) {
            if (choice != null) return error.IssueChoiceRequired;
            choice = .{ .custom = argument["--custom=".len..] };
        } else if (std.mem.startsWith(u8, argument, "--tracks=") and tracks == null) {
            tracks = try parseTrackIds(context.allocator, argument["--tracks=".len..]);
        } else return error.UnknownOption;
    }
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const changed = try runtime.libraryApplyMetadataIssues(library, &.{.{
        .group_id = group_id,
        .choice = choice orelse return error.IssueChoiceRequired,
        .tracks = if (tracks) |ids| ids.items else null,
    }});
    try context.stdout.print("changed={d}\n", .{changed});
}

fn skipMetadataIssue(context: Context) !void {
    const group_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    try runtime.librarySkipMetadataIssue(library, group_id);
    try context.stdout.print("skipped={d}\n", .{group_id});
}

fn listDuplicateGroups(context: Context) !void {
    var limit: u32 = 256;
    var offset: u32 = 0;
    var index: usize = 1;
    while (index < context.arguments.len) : (index += 1) {
        const argument = context.arguments[index];
        if (std.mem.eql(u8, argument, "--groups")) continue;
        if (std.mem.eql(u8, argument, "--limit") or std.mem.eql(u8, argument, "--offset")) {
            index += 1;
            if (index == context.arguments.len) return error.MissingOptionValue;
            const value = try std.fmt.parseInt(u32, context.arguments[index], 10);
            if (std.mem.eql(u8, argument, "--limit")) limit = value else offset = value;
        } else return error.UnknownOption;
    }
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    var page = try runtime.libraryDuplicateGroupPage(library, context.allocator, limit, offset);
    defer page.deinit();
    for (page.items) |group| {
        try context.stdout.print("{d}\t{s}\t{s}\tcopies={d} same_recording={s} similarity=", .{
            group.id,
            group.title,
            group.artist,
            group.copies,
            if (group.same_recording) "yes" else "no",
        });
        if (group.similarity) |similarity| try context.stdout.print("{d:.2}", .{similarity}) else try context.stdout.writeByte('-');
        try context.stdout.print(" bytes_redundant={d} verdict={t}\n", .{ group.bytes_redundant, group.verdict });
    }
    const totals = try runtime.libraryDuplicateGroupTotals(library);
    try context.stdout.print("groups={d} bytes={d}\n", .{ totals.groups, totals.bytes });
}

fn showDuplicateGroup(context: Context, group_id: i64) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    var copies = try runtime.libraryDuplicateGroup(library, context.allocator, group_id);
    defer copies.deinit();
    try context.stdout.print("group={d} same_recording={s} similarity=", .{ group_id, if (copies.same_recording) "yes" else "no" });
    if (copies.similarity) |similarity| try context.stdout.print("{d:.2}", .{similarity}) else try context.stdout.writeByte('-');
    try context.stdout.print(" verdict={t}\n", .{copies.verdict});
    for (copies.items) |copy| {
        try context.stdout.print("file={d} track=", .{copy.file_id});
        if (copy.track_id) |track_id| try context.stdout.print("{d}", .{track_id}) else try context.stdout.writeByte('-');
        try context.stdout.print(" keep={s} locations={d} playlists={d}", .{
            if (copy.suggested_keep) "yes" else "no",
            copy.locations,
            copy.playlist_count,
        });
        if (copy.details) |details| {
            try context.stdout.print(" codec={s} rate={d} depth={d} bytes={d} duration_ms={d} plays={d} rating=", .{
                details.codec,
                details.sample_rate orelse 0,
                details.bit_depth orelse 0,
                details.size_bytes orelse 0,
                details.duration_ms orelse 0,
                details.play_count,
            });
            if (details.rating) |rating| try context.stdout.print("{d}", .{rating}) else try context.stdout.writeByte('-');
            try context.stdout.print(" lufs=", .{});
            if (details.loudness) |loudness| try context.stdout.print("{d:.1}", .{loudness.integrated_lufs}) else try context.stdout.writeByte('-');
            try context.stdout.print(" album={s} title={s} path={s}", .{ details.album, details.title, details.path orelse "-" });
        }
        try context.stdout.writeByte('\n');
    }
}

fn mergeDuplicate(context: Context) !void {
    const keep = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const from = try std.fmt.parseInt(i64, context.arguments[2], 10);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const merged = try runtime.libraryMergeDuplicateMetadata(library, keep, from);
    try context.stdout.print("track={d} values={d} genres={s} rating={s} feedback={s}\n", .{
        merged.track_id,
        merged.values,
        if (merged.genres) "copied" else "kept",
        if (merged.rating) "copied" else "kept",
        if (merged.feedback) "copied" else "kept",
    });
}

fn keepBothDuplicates(context: Context) !void {
    const file_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const other_file_id = try std.fmt.parseInt(i64, context.arguments[2], 10);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    try runtime.libraryKeepBoth(library, file_id, other_file_id);
    try context.stdout.print("kept files {d} and {d}\n", .{ file_id, other_file_id });
}

fn ignoreDuplicateGroup(context: Context) !void {
    const group_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    try runtime.libraryIgnoreDuplicateGroup(library, group_id);
    try context.stdout.print("ignored group {d}\n", .{group_id});
}

fn analyzeFile(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library_handle = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const result = try runtime.libraryAnalyzeFile(library_handle, context.io, try absolutePath(context, context.arguments[1]));
    defer result.deinit();
    try context.stdout.print(
        "cache={s} peak={d:.6} rms={d:.6} clipped={d} silent={d} fingerprint_blocks={d} chromaprint={s}\n",
        .{
            if (result.cache_hit) "hit" else "miss",
            result.diagnostics.sample_peak,
            result.diagnostics.rms,
            result.diagnostics.clipped_samples,
            result.diagnostics.silent_frames,
            result.fingerprint.signatures.len,
            if (result.chromaprint != null) "yes" else "no",
        },
    );
    if (result.diagnostics.integrated_lufs) |loudness| try context.stdout.print(
        "loudness={d:.2} LUFS replay_gain={d:.2} dB\n",
        .{ loudness, result.diagnostics.replay_gain_db.? },
    );
}

fn listHealthIssues(context: Context) !void {
    const database_path = try context.allocator.dupeSentinel(u8, context.arguments[0], 0);
    var summary = false;
    var albums = false;
    var kind: ?liborca.HealthIssueKind = null;
    var offset: ?u32 = null;
    for (context.arguments[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--summary")) {
            summary = true;
        } else if (std.mem.eql(u8, argument, "--albums")) {
            albums = true;
        } else if (std.mem.startsWith(u8, argument, "--kind=")) {
            kind = std.meta.stringToEnum(liborca.HealthIssueKind, argument["--kind=".len..]) orelse
                return error.UnknownHealthKind;
        } else if (std.mem.startsWith(u8, argument, "--")) {
            return error.UnknownOption;
        } else {
            offset = try std.fmt.parseInt(u32, argument, 10);
        }
    }
    if (summary and (kind != null or offset != null)) return error.SummaryWithPage;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library_handle = try runtime.openLibrary(context.io, database_path);
    if (albums) {
        if (kind != .artwork_problem) return error.AlbumsNeedArtworkProblemKind;
        const releases = try runtime.libraryArtworkProblemReleasePage(library_handle, 256, offset orelse 0);
        defer releases.deinit();
        for (releases.items) |album| {
            const release = try runtime.libraryRelease(library_handle, album.release_id);
            defer if (release) |summary_row| summary_row.deinit(runtime.allocator);
            try context.stdout.print("{d}\t{s}\tfiles={d}\t", .{ album.release_id, @tagName(album.finding.problem), album.files });
            if (album.finding.width != null and album.finding.height != null)
                try context.stdout.print("size={d}x{d}", .{ album.finding.width.?, album.finding.height.? })
            else
                try context.stdout.writeAll("size=-");
            try context.stdout.print("\t{s}\n", .{if (release) |summary_row| summary_row.title else "-"});
        }
        try context.stdout.print("albums\t{d}\n", .{try runtime.libraryArtworkProblemReleaseCount(library_handle)});
        return;
    }
    if (summary) {
        const kinds = try runtime.libraryHealthSummary(library_handle);
        for (kinds.items()) |entry| try context.stdout.print(
            "{s}\t{s}\t{d}\t{d}\t{d}\n",
            .{ @tagName(entry.kind), @tagName(entry.severity), entry.count, entry.files, entry.bytes },
        );
        try context.stdout.print("missing_files\t{d}\n", .{try runtime.libraryMissingFileCount(library_handle)});
        try context.stdout.print("metadata_issues\t{d}\n", .{try runtime.libraryMetadataIssueCount(library_handle, null)});
        return;
    }
    var page = if (kind) |only|
        try runtime.libraryHealthIssuePageOfKind(library_handle, only, 256, offset orelse 0)
    else
        try runtime.libraryHealthIssuePage(library_handle, 256, offset orelse 0);
    defer page.deinit();
    for (page.items) |issue| try context.stdout.print(
        "{d}\t{s}\t{s}\t{s}\t{s}\t{s}\n",
        .{ issue.file_id, @tagName(issue.severity), @tagName(issue.kind), @tagName(issue.action), issue.path, issue.details },
    );
}

fn printLibraryStats(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library_handle = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const stats = try runtime.libraryStats(library_handle);
    try context.stdout.print(
        "artists={d}\nreleases={d}\ntracks={d}\nfiles={d}\nbytes={d}\nduration_ms={d}\n",
        .{ stats.artists, stats.releases, stats.tracks, stats.files, stats.total_bytes, stats.total_duration_ms },
    );
    try printOptionalStat(context.stdout, "last_scan_finished_at", stats.last_scan_finished_at);
    try printOptionalStat(context.stdout, "last_analysis_at", stats.last_analysis_at);
    try printOptionalStat(context.stdout, "last_duplicate_scan_at", stats.last_duplicate_scan_at);
    try context.stdout.print("listens={d}\n", .{stats.listens});
}

fn listenSettings(context: Context) !void {
    var policy: ?liborca.ListenPolicy = null;
    var record: ?bool = null;
    var clear = false;
    for (context.arguments[1..]) |argument| {
        if (std.mem.startsWith(u8, argument, "--policy=")) {
            const value = argument["--policy=".len..];
            policy = if (std.mem.eql(u8, value, "half"))
                .half_or_four_minutes
            else if (std.mem.eql(u8, value, "30s"))
                .thirty_seconds
            else if (std.mem.eql(u8, value, "full"))
                .full_track
            else
                return error.UnknownOption;
        } else if (std.mem.startsWith(u8, argument, "--record=")) {
            const value = argument["--record=".len..];
            record = if (std.mem.eql(u8, value, "on")) true else if (std.mem.eql(u8, value, "off")) false else return error.UnknownOption;
        } else if (std.mem.eql(u8, argument, "--clear")) {
            clear = true;
        } else return error.UnknownOption;
    }
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    if (policy) |value| try runtime.librarySetListenPolicy(library, value);
    if (record) |value| try runtime.librarySetListenRecording(library, value);
    if (clear) try context.stdout.print("cleared={d}\n", .{try runtime.libraryClearListens(library)});
    const current = try runtime.libraryListenPolicy(library);
    const recording = try runtime.libraryListenRecording(library);
    const stats = try runtime.libraryStats(library);
    try context.stdout.print("policy={s}\nrecord={s}\nlistens={d}\n", .{
        switch (current) {
            .half_or_four_minutes => "half",
            .thirty_seconds => "30s",
            .full_track => "full",
        },
        if (recording) "on" else "off",
        stats.listens,
    });
}

fn providerCache(context: Context) !void {
    const clear = if (context.arguments.len == 2)
        (if (std.mem.eql(u8, context.arguments[1], "--clear")) true else return error.UnknownOption)
    else
        false;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const size = if (clear) try runtime.libraryClearCache(library) else try runtime.libraryCacheSize(library);
    try context.stdout.print("artwork_bytes={d}\nphoto_bytes={d}\nlyrics_bytes={d}\ninfo_bytes={d}\n", .{
        size.artwork_bytes,
        size.photo_bytes,
        size.lyrics_bytes,
        size.info_bytes,
    });
}

fn listProviderSources(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    for (runtime.providerSources()) |source| {
        try context.stdout.print("{s}\t{s}\t{s}\t{s}\t{s}", .{ @tagName(source.id), source.name, source.url, source.licence, source.supplies });
        if (source.licence_url) |licence_url| try context.stdout.print("\t{s}", .{licence_url});
        try context.stdout.writeAll("\n");
    }
}

fn listSupportedFormats(context: Context) !void {
    for (liborca.supported_formats) |format|
        try context.stdout.print("{s}{s}\n", .{ format.name, if (format.planned) "\tplanned" else "" });
}

fn printOptionalStat(stdout: *std.Io.Writer, key: []const u8, value: ?i64) !void {
    if (value) |seconds|
        try stdout.print("{s}={d}\n", .{ key, seconds })
    else
        try stdout.print("{s}=-\n", .{key});
}

fn dismissHealthIssue(context: Context) !void {
    const file_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const kind = std.meta.stringToEnum(liborca.HealthIssueKind, context.arguments[2]) orelse return error.UnknownHealthKind;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    try runtime.libraryDismissHealthIssue(library, file_id, kind);
    try context.stdout.print("dismissed {s} for file {d}\n", .{ @tagName(kind), file_id });
}

fn restoreHealthIssue(context: Context) !void {
    const file_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const kind = std.meta.stringToEnum(liborca.HealthIssueKind, context.arguments[2]) orelse return error.UnknownHealthKind;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    try runtime.libraryRestoreHealthIssue(library, file_id, kind);
    try context.stdout.print("restored {s} for file {d}\n", .{ @tagName(kind), file_id });
}

fn listRoots(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library_handle = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    var page = try runtime.libraryRootPage(library_handle, 512, 0);
    defer page.deinit();
    for (page.items) |root| try printRoot(context.stdout, root);
}

fn printRoot(stdout: *std.Io.Writer, root: liborca.LibraryRoot) !void {
    try stdout.print(
        "{d}\t{s}\t{s}\tavailable={s}\ttracks={d}\tunavailable={d}\tvolume={s}\tlast_seen_at=",
        .{
            root.id,
            if (root.enabled) "enabled" else "disabled",
            root.path,
            if (root.available) "yes" else "no",
            root.track_count,
            root.unavailable_tracks,
            if (root.volume.len != 0) root.volume else "-",
        },
    );
    if (root.last_seen_at) |seen| try stdout.print("{d}\n", .{seen}) else try stdout.writeAll("-\n");
}

/// `orca-cli availability DATABASE [RELEASE_ID...]`: the roots offline now,
/// what they leave unable to play, and whether each Release named can play.
fn showAvailability(context: Context) !void {
    const stdout = context.stdout;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const availability = try runtime.libraryAvailability(library, context.io);
    defer availability.deinit();
    try stdout.print("offline_roots={d} unavailable_tracks={d} unavailable_releases={d}\n", .{
        availability.offline_roots.len,
        availability.unavailable_tracks,
        availability.unavailable_releases,
    });
    for (availability.offline_roots) |root| {
        try stdout.writeAll("offline\t");
        try printRoot(stdout, root);
    }
    for (context.arguments[1..]) |argument| {
        const release_id = [1]i64{try std.fmt.parseInt(i64, argument, 10)};
        var available: [1]bool = undefined;
        try runtime.libraryReleasesAvailable(library, &availability, &release_id, &available);
        try stdout.print("release={d} available={s}\n", .{ release_id[0], if (available[0]) "yes" else "no" });
    }
}

/// `orca-cli folders DATABASE [ROOT_ID [PATH]]`: the roots with their totals,
/// or one folder's subfolders with their totals and then its files.
fn listFolders(context: Context) !void {
    const stdout = context.stdout;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    if (context.arguments.len == 1) {
        const roots = try runtime.libraryRootPage(library, 512, 0);
        defer roots.deinit();
        for (roots.items) |root| {
            var files: u64 = 0;
            var tracks: u64 = 0;
            var duration_ms: i64 = 0;
            var offset: u32 = 0;
            while (true) {
                const page = try runtime.libraryFolderPage(library, root.id, "", 512, offset);
                defer page.deinit();
                for (page.items) |entry| {
                    files += entry.file_count;
                    tracks += entry.track_count;
                    duration_ms += entry.total_duration_ms;
                }
                if (page.items.len < 512) break;
                offset += 512;
            }
            try stdout.print("{d}\t{s}\t{d} files\t{d} tracks\t", .{
                root.id,
                if (root.enabled) "enabled" else "disabled",
                files,
                tracks,
            });
            try writeDuration(stdout, duration_ms);
            try stdout.print("\t{s}\n", .{root.path});
        }
        return;
    }
    const root_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const path = if (context.arguments.len == 3) context.arguments[2] else "";
    var tracks: u64 = 0;
    var offset: u32 = 0;
    while (true) {
        const page = try runtime.libraryFolderPage(library, root_id, path, 512, offset);
        defer page.deinit();
        for (page.items) |entry| {
            if (entry.kind == .file) tracks += entry.track_count;
        }
        if (page.items.len == 512) {
            offset += 512;
            continue;
        }
        try stdout.writeAll("folder: release=");
        if (page.release_id) |id| try stdout.print("{d}", .{id}) else try stdout.writeAll("-");
        try stdout.print(" tracks={d} images={d} last_scanned_at=", .{ tracks, page.image_count });
        if (page.last_scanned_at) |seconds| try stdout.print("{d}", .{seconds}) else try stdout.writeAll("-");
        try stdout.writeAll("\n");
        break;
    }
    offset = 0;
    while (true) {
        const page = try runtime.libraryFolderPage(library, root_id, path, 512, offset);
        defer page.deinit();
        for (page.items) |entry| {
            switch (entry.kind) {
                .folder => {
                    try stdout.print("folder\t{d} files\t{d} tracks\t", .{ entry.file_count, entry.track_count });
                    try writeDuration(stdout, entry.total_duration_ms);
                },
                .file => {
                    if (entry.track_id) |track_id|
                        try stdout.print("file\ttrack={d}\t", .{track_id})
                    else
                        try stdout.writeAll("file\ttrack=-\t");
                    try writeDuration(stdout, entry.total_duration_ms);
                },
                .image => try stdout.print("image\t{s}\t-", .{entry.mime orelse "-"}),
            }
            try stdout.print("\t{s}\tkind={t}\tstatus={t}", .{ entry.name, entry.kind, entry.status });
            if (entry.artwork_role) |role| try stdout.print("\trole={t}", .{role});
            try stdout.writeAll("\n");
        }
        if (page.items.len < 512) break;
        offset += 512;
    }
}

/// `orca-cli play-folder`: every Track below a folder, recursively in path
/// order, as the playback queue.
fn playFolder(context: Context) !void {
    const io = context.io;
    const stdout = context.stdout;
    const root_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const path = context.arguments[2];
    var device: ?u64 = null;
    var shuffle = false;
    var limit_ms: u64 = 10 * 60 * 1000;
    for (context.arguments[3..]) |argument| {
        if (std.mem.eql(u8, argument, "--shuffle")) {
            shuffle = true;
        } else if (std.mem.startsWith(u8, argument, "--device=")) {
            device = try std.fmt.parseInt(u64, argument["--device=".len..], 10);
        } else if (std.mem.startsWith(u8, argument, "--limit=")) {
            limit_ms = try std.fmt.parseInt(u64, argument["--limit=".len..], 10);
        } else return error.UnknownOption;
    }

    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    try identifyOrca(&runtime);
    const library = try openBrowseLibrary(context.allocator, io, &runtime, context.arguments[0]);
    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneRequestOutput(zone, device orelse return error.MissingDevice);
    try runtime.playerPlayFolder(player, library, io, root_id, path, shuffle);

    var refs: [64]liborca.TrackRef = undefined;
    var position: u32 = 0;
    while (true) {
        const count = try runtime.playerQueuePage(player, position, &refs);
        for (refs[0..count]) |ref| {
            const details = try runtime.libraryTrackDetails(library, ref.track_id);
            defer if (details) |value| value.deinit();
            try stdout.print("queue position={d} track={d} title={s}\n", .{
                position,
                ref.track_id,
                if (details) |value| value.title else "",
            });
            position += 1;
        }
        if (count < refs.len) break;
    }
    try stdout.flush();

    var elapsed_ms: u64 = 0;
    var last_cursor: ?u32 = null;
    while (elapsed_ms < limit_ms) {
        _ = runtime.processNextCommand();
        const snapshot = try runtime.playerQueueSnapshot(player);
        if (last_cursor == null or last_cursor.? != snapshot.cursor) {
            last_cursor = snapshot.cursor;
            const now_playing = try runtime.playerNowPlaying(player);
            try stdout.print("now-playing at={d}ms position={d} track={?d}\n", .{
                elapsed_ms,
                snapshot.cursor,
                if (now_playing) |ref| ref.track_id else null,
            });
            try stdout.flush();
        }
        try requireOutput(&runtime, zone);
        if (try runtime.playerDrained(player)) break;
        sleepMilliseconds(10);
        elapsed_ms += 10;
    }
    try runtime.pausePlayer(player);
    const snapshot = try runtime.playerQueueSnapshot(player);
    try stdout.print("queue entries={d} cursor={d}\n", .{ snapshot.entries, snapshot.cursor });
}

fn removeRoot(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library_handle = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const root_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const removed = try runtime.libraryRemoveRoot(library_handle, root_id);
    try context.stdout.print(
        "removed root {d}: {d} files, {d} tracks, {d} recordings\n",
        .{ root_id, removed.files_forgotten, removed.tracks_removed, removed.recordings_forgotten },
    );
}

fn relocateRoot(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library_handle = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const root_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const path = try absolutePath(context, context.arguments[2]);
    const job_handle = try runtime.libraryRelocateRoot(library_handle, context.io, root_id, path);
    try context.stdout.print("relocated root {d} to {s}\n", .{ root_id, path });
    try awaitJob(&runtime, context.stdout, job_handle, null);
    try printScanStats(context.stdout, try runtime.jobScanStats(job_handle));
}

fn undoTagWrite(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const group = try std.fmt.parseInt(u64, context.arguments[1], 10);
    runtime.undoTagWrite(library, context.io, group) catch |err| switch (err) {
        error.MutationGroupAlreadyUndone => return context.stdout.print("group {d} was already undone\n", .{group}),
        else => return err,
    };
    try context.stdout.print("undid group {d}\n", .{group});
}

fn pruneBackups(context: Context) !void {
    const older_than_days = if (context.arguments.len == 2) days: {
        const option = context.arguments[1];
        if (!std.mem.startsWith(u8, option, "--older-than=")) return error.UnknownOption;
        break :days try std.fmt.parseInt(u64, option["--older-than=".len..], 10);
    } else 0;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const pruned = try runtime.pruneTagWriteBackups(
        library,
        context.io,
        try std.math.mul(u64, older_than_days, std.time.s_per_day),
    );
    try context.stdout.print("pruned {d} backups ({d} bytes)\n", .{ pruned.backups, pruned.bytes });
}

fn showChanges(context: Context) !void {
    var limit: u32 = 50;
    var offset: u32 = 0;
    var group_id: ?u64 = null;
    var export_path: ?[]const u8 = null;
    var force = false;
    var paged = false;
    var index: usize = 1;
    while (index < context.arguments.len) : (index += 1) {
        const argument = context.arguments[index];
        if (std.mem.eql(u8, argument, "--limit") or std.mem.eql(u8, argument, "--offset")) {
            index += 1;
            if (index == context.arguments.len) return error.MissingOptionValue;
            const value = try std.fmt.parseInt(u32, context.arguments[index], 10);
            if (std.mem.eql(u8, argument, "--limit")) limit = value else offset = value;
            paged = true;
        } else if (std.mem.startsWith(u8, argument, "--export=")) {
            export_path = argument["--export=".len..];
        } else if (std.mem.eql(u8, argument, "--force")) {
            force = true;
        } else if (group_id == null and !std.mem.startsWith(u8, argument, "--")) {
            group_id = try std.fmt.parseInt(u64, argument, 10);
        } else return error.UnknownOption;
    }
    const forms = @as(u8, @intFromBool(paged)) + @intFromBool(group_id != null) + @intFromBool(export_path != null);
    if (forms > 1 or (force and export_path == null)) return error.UnknownOption;
    if (limit == 0 or limit > 512) return error.PageOutOfRange;

    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    if (group_id) |id| return printChangeDetail(context, &runtime, library, id);
    if (export_path) |path| return exportChanges(context, &runtime, library, path, force);
    const page = try runtime.libraryTagWriteGroupPage(library, context.allocator, limit, offset);
    defer page.deinit();
    for (page.items) |*group| {
        try group.writeLine(context.stdout, null);
        try context.stdout.writeByte('\n');
    }
}

fn printChangeDetail(context: Context, runtime: *liborca.Runtime, library: liborca.LibraryHandle, group_id: u64) !void {
    const detail = try runtime.libraryTagWriteGroup(library, context.allocator, context.io, group_id);
    defer detail.deinit();
    const stdout = context.stdout;
    try detail.group.writeLine(stdout, &detail);
    try stdout.writeByte('\n');
    for (detail.diffs) |diff| {
        try stdout.print("{s}\t", .{diff.file});
        switch (diff.subject) {
            .field => |field| try stdout.print("{t}\t{s}\t{s}\n", .{ field, noneIfEmpty(diff.restores), noneIfEmpty(diff.current) }),
            .genres => try stdout.print("genres\t{s}\t{s}\n", .{ noneIfEmpty(diff.restores), noneIfEmpty(diff.current) }),
            .unknown => try stdout.writeAll("unknown\t-\t-\n"),
        }
    }
}

fn noneIfEmpty(value: []const u8) []const u8 {
    return if (value.len == 0) "(none)" else value;
}

fn exportChanges(context: Context, runtime: *liborca.Runtime, library: liborca.LibraryHandle, path: []const u8, force: bool) !void {
    const exported = try runtime.exportTagWriteHistory(library, context.io, path, .{ .replace = force });
    try context.stdout.print("exported={d}\n", .{exported.groups});
}

fn listDevices(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    var devices: [32]liborca.Device = undefined;
    const count = try runtime.enumerateOutputDevices(&devices, .capabilities);
    for (devices[0..count]) |device| {
        try context.stdout.print("{d}\t{s}\t{t}\t", .{ device.id, device.nameSlice(), device.kind });
        try writeDeviceCapabilities(context.stdout, device.capabilities);
        try context.stdout.writeAll("\n");
    }
}

fn writeDeviceCapabilities(stdout: *std.Io.Writer, known: ?liborca.DeviceCapabilities) !void {
    const capabilities = known orelse
        return stdout.writeAll("rates=- depths=- channels=- state=unknown");
    try stdout.print("rates={d}-{d} depths=", .{ capabilities.rate_min, capabilities.rate_max });
    const depths = [_]struct { bit: u8, bits: u8 }{
        .{ .bit = liborca.DeviceCapabilities.bit_depth_16, .bits = 16 },
        .{ .bit = liborca.DeviceCapabilities.bit_depth_24, .bits = 24 },
        .{ .bit = liborca.DeviceCapabilities.bit_depth_32, .bits = 32 },
    };
    var written: usize = 0;
    for (depths) |depth| {
        if (capabilities.bit_depths & depth.bit == 0) continue;
        if (written != 0) try stdout.writeAll(",");
        try stdout.print("{d}", .{depth.bits});
        written += 1;
    }
    if (written == 0) try stdout.writeAll("-");
    try stdout.writeAll(" channels=");
    if (capabilities.channels_max == 0)
        try stdout.writeAll("-")
    else
        try stdout.print("{d}", .{capabilities.channels_max});
    try stdout.print(" state={t}", .{capabilities.state});
}

/// The one object graph: a runtime Player owns the source and the single
/// decode producer, and a runtime Zone owns the pool, pipe, render context and
/// OutputSession. Nothing about playback lives in this frame.
fn playFile(context: Context) !void {
    const device_id = if (context.arguments.len == 2)
        try std.fmt.parseInt(u64, context.arguments[1], 10)
    else
        0;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.playerLoadFile(player, context.io, context.arguments[0]);
    try runtime.zoneRequestOutput(zone, device_id);
    try runtime.playPlayer(player);

    var elapsed_ms: u64 = 0;
    while (!try runtime.playerDrained(player)) {
        try requireOutput(&runtime, zone);
        if (elapsed_ms >= 30 * std.time.ms_per_s) return error.PlaybackStalled;
        sleepMilliseconds(10);
        elapsed_ms += 10;
    }
    // Every prepared block has been handed to the device. Pausing stops the
    // now-empty render path from counting the tail as missing audio, and the
    // short wait lets the device drain what it already holds.
    try runtime.pausePlayer(player);
    sleepMilliseconds(200);

    const snapshot = try runtime.playerSnapshot(player);
    const stats = try runtime.zoneStats(zone);
    try context.stdout.print(
        "played={d} underruns={d} state={s} recoveries={d} quantum={d}\n",
        .{
            snapshot.position_frames,
            stats.underruns,
            @tagName(stats.output_state),
            stats.recovery_attempts,
            stats.backend_quantum_frames,
        },
    );
}

fn requireOutput(runtime: *liborca.Runtime, zone: liborca.ZoneHandle) !void {
    const stats = try runtime.zoneStats(zone);
    if (stats.output_state == .failed and
        stats.recovery_attempts >= liborca.max_output_recovery_attempts)
        return error.OutputFailed;
}

fn acceptMatch(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const proposal_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const acceptance = try runtime.libraryAcceptMatch(library, proposal_id);
    try context.stdout.print("accepted match {d}: values_written={d}\n", .{ proposal_id, acceptance.values_written });
}

fn applyMatchedRelease(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const release_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    if (context.arguments.len == 2) {
        const values_written = try runtime.libraryApplyMatchedRelease(library, release_id, null);
        return context.stdout.print("values_written={d}\n", .{values_written});
    }
    const fields = try parseReleaseFields(context.arguments[2]);
    const outcome = try runtime.libraryApplyRelease(library, context.allocator, release_id, fields);
    defer outcome.deinit();
    try context.stdout.print("release={s}\tvalues_written={d}\ttrack_values={d}\trelease_values_only={d}\tartist_ids={s}", .{
        outcome.release_mbid,
        outcome.values_written,
        outcome.track_values,
        outcome.release_values_only,
        if (outcome.artist_ids_unknown) "unknown" else "known",
    });
    if (outcome.reviewed_release_id) |reviewed| {
        try context.stdout.print("\treviewed={d}\n", .{reviewed});
    } else try context.stdout.writeAll("\treviewed=-\n");
    for (outcome.left_alone) |track| {
        try context.stdout.print("left_alone\ttrack={d}\treason={s}\ttitle={s}\n", .{ track.track_id, @tagName(track.reason), track.title });
    }
}

fn markReleaseReviewed(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const release_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const release_mbid: ?[]const u8 = if (context.arguments.len == 3) context.arguments[2] else null;
    try runtime.libraryMarkReleaseReviewed(library, release_id, release_mbid);
    try context.stdout.print("reviewed\trelease={d}\n", .{release_id});
}

fn unmarkReleaseReviewed(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const release_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    try runtime.libraryUnmarkReleaseReviewed(library, release_id);
    try context.stdout.print("unreviewed\trelease={d}\n", .{release_id});
}

fn printReleaseAlignment(context: Context) !void {
    const stdout = context.stdout;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const release_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const release_mbid: ?[]const u8 = if (context.arguments.len == 3) context.arguments[2] else null;
    const alignment = try runtime.libraryReleaseAlignment(library, context.allocator, release_id, release_mbid);
    defer alignment.deinit();
    try stdout.print("release={s}\tmedia={d}\ttracks={d}\tfetched_at={d}\ttitle={s}\tartist={s}\n", .{
        alignment.release_mbid, alignment.medium_count, alignment.rows.len, alignment.fetched_at, alignment.title, alignment.artist_credit,
    });
    for (alignment.rows) |row| {
        try stdout.print("{d}-{d}\t{s}\ttrack=", .{ row.disc, row.position, @tagName(row.status) });
        if (row.track) |track| try stdout.print("{d}", .{track.track_id}) else try stdout.writeAll("-");
        const evidence = row.evidence;
        try stdout.print("\tsource={s}\ttitle_equal={s}\tlength_close={s}\tposition_equal={s}\tdelta_ms=", .{
            if (evidence.recording_source) |source| @tagName(source) else "-",
            flag(evidence.title_equal),
            flag(evidence.length_close),
            flag(evidence.position_equal),
        });
        if (evidence.length_delta_ms) |delta| try stdout.print("{d}", .{delta}) else try stdout.writeAll("-");
        try stdout.print("\trecording={s}\trelease_title={s}\tlocal_title={s}\n", .{
            row.recording_mbid,
            row.title,
            if (row.track) |track| track.title else "",
        });
    }
    for (alignment.not_on_release) |track| {
        try stdout.print("not_on_release\ttrack={d}\tlocal_title={s}\n", .{ track.track_id, track.title });
    }
    var pairings = try runtime.libraryReleaseTrackPairings(library, context.allocator, release_id);
    defer pairings.deinit();
    for (pairings.items) |pairing| {
        if (pairing.in_snapshot or !std.mem.eql(u8, pairing.release_mbid, alignment.release_mbid)) continue;
        try stdout.print("unlisted_pairing\ttrack={d}\trelease_track={s}\trecording={s}\n", .{
            pairing.track_id, pairing.release_track_mbid, pairing.recording_mbid,
        });
    }
}

fn pairTrack(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const release_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const track_id = try std.fmt.parseInt(i64, context.arguments[2], 10);
    const release_mbid: ?[]const u8 = if (context.arguments.len == 5) context.arguments[4] else null;
    const origin = try runtime.libraryPairReleaseTrack(library, release_id, release_mbid, track_id, context.arguments[3]);
    try context.stdout.print("paired\ttrack={d}\torigin={s}\n", .{ track_id, @tagName(origin) });
}

fn unpairTrack(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const release_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const track_id = try std.fmt.parseInt(i64, context.arguments[2], 10);
    try runtime.libraryUnpairReleaseTrack(library, release_id, track_id);
    try context.stdout.print("unpaired\ttrack={d}\n", .{track_id});
}

fn parseReleaseFields(argument: []const u8) !liborca.ReleaseFieldSet {
    if (!std.mem.startsWith(u8, argument, "--fields=")) return error.UnknownOption;
    var fields: liborca.ReleaseFieldSet = .empty;
    var names = std.mem.splitScalar(u8, argument["--fields=".len..], ',');
    while (names.next()) |name| {
        const field = std.meta.stringToEnum(liborca.ReleaseField, name) orelse
            if (std.mem.eql(u8, name, "date")) liborca.ReleaseField.release_date else return error.UnknownReleaseField;
        fields.insert(field);
    }
    return fields;
}

fn dismissMatch(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const proposal_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    try runtime.libraryDismissMatch(library, proposal_id);
    try context.stdout.print("dismissed match {d}\n", .{proposal_id});
}

fn acceptConfidentMatches(context: Context) !void {
    const option = context.arguments[1];
    if (!std.mem.startsWith(u8, option, "--min-score=")) return error.UnknownOption;
    const minimum = try std.fmt.parseFloat(f32, option["--min-score=".len..]);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const acceptance = try runtime.libraryAcceptConfidentMatches(library, minimum);
    try context.stdout.print("accepted {d} matches: values_written={d}\n", .{ acceptance.accepted, acceptance.values_written });
}

/// A volume change scheduled mid-run. Exists so the independence of user
/// volume and loudness correction is observable from outside: changing one
/// while a track plays must leave the other exactly where it was.
const ScheduledVolume = struct {
    at_ms: u64,
    linear: f32,
};

const ScheduledMove = struct {
    at_ms: u64,
    from: u32,
    to: u32,
};

const max_scheduled_moves = 8;

const PlayTracksOptions = struct {
    device: u64 = 0,
    volume: f32 = 1,
    set_volume: ?ScheduledVolume = null,
    moves: [max_scheduled_moves]ScheduledMove = undefined,
    move_count: usize = 0,
    replay_gain: liborca.ReplayGainMode = .track,
    preamp_db: f32 = 0,
    untagged: liborca.UntaggedFallback = .as_is,
    peak_protection: bool = true,
    stop_after_current: bool = false,
    equalizer: ?liborca.Equalizer = null,
    parametric_path: ?[]const u8 = null,
    crossfeed: ?f32 = null,
    start: u32 = 0,
    repeat: liborca.RepeatMode = .off,
    shuffle: bool = false,
    tail_ms: ?u64 = null,
    skip_after_ms: ?u64 = null,
    previous_after_ms: ?u64 = null,
    limit_ms: u64 = 10 * 60 * 1000,
    playlist_id: ?i64 = null,
    lyrics: bool = false,
    print_history: bool = false,
    save_queue: ?[]const u8 = null,
    save_state: bool = false,
};

fn parseOption(options: *PlayTracksOptions, argument: []const u8) !void {
    if (std.mem.eql(u8, argument, "--shuffle")) {
        options.shuffle = true;
        return;
    }
    if (std.mem.eql(u8, argument, "--lyrics")) {
        options.lyrics = true;
        return;
    }
    if (std.mem.eql(u8, argument, "--print-history")) {
        options.print_history = true;
        return;
    }
    if (std.mem.eql(u8, argument, "--no-peak-protection")) {
        options.peak_protection = false;
        return;
    }
    if (std.mem.eql(u8, argument, "--stop-after-current")) {
        options.stop_after_current = true;
        return;
    }
    if (std.mem.eql(u8, argument, "--save-state")) {
        options.save_state = true;
        return;
    }
    const split = std.mem.indexOfScalar(u8, argument, '=') orelse return error.UnknownOption;
    const name = argument[0..split];
    const value = argument[split + 1 ..];
    if (std.mem.eql(u8, name, "--device")) {
        options.device = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--volume")) {
        options.volume = try std.fmt.parseFloat(f32, value);
    } else if (std.mem.eql(u8, name, "--set-volume")) {
        const separator = std.mem.indexOfScalar(u8, value, ':') orelse
            return error.MalformedScheduledVolume;
        options.set_volume = .{
            .at_ms = try std.fmt.parseInt(u64, value[0..separator], 10),
            .linear = try std.fmt.parseFloat(f32, value[separator + 1 ..]),
        };
    } else if (std.mem.eql(u8, name, "--move")) {
        if (options.move_count == max_scheduled_moves) return error.TooManyScheduledMoves;
        var fields = std.mem.splitScalar(u8, value, ':');
        const at_ms = fields.next().?;
        const from = fields.next() orelse return error.MalformedScheduledMove;
        const to = fields.next() orelse return error.MalformedScheduledMove;
        if (fields.next() != null) return error.MalformedScheduledMove;
        options.moves[options.move_count] = .{
            .at_ms = try std.fmt.parseInt(u64, at_ms, 10),
            .from = try std.fmt.parseInt(u32, from, 10),
            .to = try std.fmt.parseInt(u32, to, 10),
        };
        options.move_count += 1;
    } else if (std.mem.eql(u8, name, "--start")) {
        options.start = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--replay-gain")) {
        options.replay_gain = if (std.mem.eql(u8, value, "off"))
            .off
        else if (std.mem.eql(u8, value, "track"))
            .track
        else if (std.mem.eql(u8, value, "album"))
            .album
        else if (std.mem.eql(u8, value, "smart"))
            .smart
        else
            return error.UnknownReplayGainMode;
    } else if (std.mem.eql(u8, name, "--preamp")) {
        options.preamp_db = try std.fmt.parseFloat(f32, value);
    } else if (std.mem.eql(u8, name, "--untagged")) {
        options.untagged = if (std.mem.eql(u8, value, "-6"))
            .minus_6_db
        else if (std.mem.eql(u8, value, "as-is"))
            .as_is
        else
            return error.UnknownUntaggedFallback;
    } else if (std.mem.eql(u8, name, "--eq")) {
        options.equalizer = try parseEqualizer(value);
    } else if (std.mem.eql(u8, name, "--peq")) {
        options.parametric_path = value;
    } else if (std.mem.eql(u8, name, "--crossfeed")) {
        options.crossfeed = try std.fmt.parseFloat(f32, value);
    } else if (std.mem.eql(u8, name, "--repeat")) {
        options.repeat = if (std.mem.eql(u8, value, "all"))
            .all
        else if (std.mem.eql(u8, value, "one"))
            .one
        else if (std.mem.eql(u8, value, "off"))
            .off
        else
            return error.UnknownRepeatMode;
    } else if (std.mem.eql(u8, name, "--tail")) {
        options.tail_ms = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--skip-after")) {
        options.skip_after_ms = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--previous-after")) {
        options.previous_after_ms = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--limit")) {
        options.limit_ms = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--playlist")) {
        options.playlist_id = try std.fmt.parseInt(i64, value, 10);
    } else if (std.mem.eql(u8, name, "--save-queue")) {
        options.save_queue = value;
    } else return error.UnknownOption;
}

/// A preset name, or ten comma-separated band gains in dB with an optional
/// `:PREAMP`. The preamp defaults to what the largest boost needs, so a bare
/// list of gains cannot clip on its own.
fn parseEqualizer(value: []const u8) !liborca.Equalizer {
    if (std.meta.stringToEnum(liborca.EqualizerPreset, value)) |preset|
        return .preset(preset);
    var equalizer: liborca.Equalizer = .{};
    const preamp_separator = std.mem.indexOfScalar(u8, value, ':');
    const gain_list = value[0 .. preamp_separator orelse value.len];
    var gains = std.mem.splitScalar(u8, gain_list, ',');
    for (&equalizer.gains_db) |*gain_db| {
        const text = gains.next() orelse return error.EqualizerNeedsTenGains;
        gain_db.* = try std.fmt.parseFloat(f32, text);
    }
    if (gains.next() != null) return error.EqualizerNeedsTenGains;
    equalizer.preamp_db = if (preamp_separator) |separator|
        try std.fmt.parseFloat(f32, value[separator + 1 ..])
    else
        liborca.Equalizer.defaultPreamp(equalizer.gains_db);
    return equalizer;
}

const max_equalizer_apo_bytes = 64 * 1024;
const response_points = 32;

fn readEqualizerApo(context: Context, path: []const u8) !liborca.ParametricEqualizer {
    const text = std.Io.Dir.cwd().readFileAlloc(context.io, path, context.allocator, .limited(max_equalizer_apo_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return error.InvalidEqualizerApo,
        else => return err,
    };
    return liborca.parseEqualizerApo(text);
}

fn checkEqualizerApo(context: Context) !void {
    try liborca.writeEqualizerApo(context.stdout, try readEqualizerApo(context, context.arguments[0]));
}

fn printEqualizerResponse(context: Context) !void {
    var sample_rate: u32 = 44_100;
    if (context.arguments.len == 2) {
        const option = context.arguments[1];
        if (!std.mem.startsWith(u8, option, "--rate=")) return error.UnknownOption;
        sample_rate = try std.fmt.parseInt(u32, option["--rate=".len..], 10);
        if (sample_rate == 0) return error.InvalidSampleRate;
    }
    const equalizer = try readEqualizerApo(context, context.arguments[0]);
    var frequencies: [response_points]f32 = undefined;
    for (&frequencies, 0..) |*frequency_hz, index| {
        const fraction = @as(f32, @floatFromInt(index)) / (response_points - 1);
        frequency_hz.* = 20 * std.math.pow(f32, 1000, fraction);
    }
    var gains: [response_points]f32 = undefined;
    equalizer.response(sample_rate, &frequencies, &gains);
    for (frequencies, gains) |frequency_hz, gain_db| {
        if (frequency_hz * 2 >= @as(f32, @floatFromInt(sample_rate))) break;
        try context.stdout.print("{d:.1}\t{d:.2}\n", .{ frequency_hz, gain_db });
    }
}

fn printSignalPath(stdout: *std.Io.Writer, path: liborca.SignalPath) !void {
    try stdout.writeAll("signal: ");
    if (path.source) |source| {
        if (path.codec) |codec| {
            var upper: [16]u8 = undefined;
            const name = if (codec.len <= upper.len) std.ascii.upperString(&upper, codec) else codec;
            try stdout.print("{s} ", .{name});
        }
        if (path.source_declared) try stdout.print("{d}-bit ", .{source.bits_per_sample});
        try stdout.print("{d} Hz {d} ch", .{ source.sample_rate, source.channels });
    } else try stdout.writeAll("no source");
    if (path.replay_gain_db) |decibels| {
        try stdout.print(" -> replay gain {d:.1} dB ({s}", .{ decibels, switch (path.replay_gain_source) {
            .none, .track => "track",
            .album => "album",
            .track_fallback => "track, no album gain",
        } });
        if (path.replay_gain_track_db) |track| try stdout.print(", track {d:.1} dB", .{track});
        try stdout.writeByte(')');
    }
    if (path.equalizer != null) try stdout.writeAll(" -> eq");
    if (path.parametric) |parametric| try stdout.print(
        " -> parametric {d} {s} preamp {d:.1} dB",
        .{ parametric.count, if (parametric.count == 1) "filter" else "filters", parametric.preamp_db },
    );
    if (path.crossfeed) |amount| try stdout.print(" -> crossfeed {d:.2}", .{amount});
    try stdout.print(" -> volume {d:.2}", .{path.volume});
    if (path.output) |output| {
        try stdout.print(
            " -> output {s} {d} Hz {d} ch",
            .{ formatName(output.sample_format), output.sample_rate, output.channels },
        );
        if (path.widened_exactly) try stdout.writeAll(" (exact)");
        if (path.device_rate) |device_rate| {
            try stdout.print(" -> device {d} Hz", .{device_rate});
            if (device_rate != output.sample_rate) try stdout.writeAll(" (PipeWire resamples)");
        }
    } else try stdout.writeAll(" -> no output");
    try stdout.print("; bit-perfect: {s}", .{if (path.bit_perfect_eligible) "yes" else "no"});
    for (path.reasonList(), 0..) |reason, index| {
        try stdout.writeAll(if (index == 0) " (" else ", ");
        for (@tagName(reason)) |character|
            try stdout.writeByte(if (character == '_') ' ' else character);
    }
    if (path.reasonList().len > 0) try stdout.writeByte(')');
    try stdout.print(
        "; replay_gain_source={s} preamp_db={d:.1} peak_protection={s} untagged={s} peak_limited={s}",
        .{
            @tagName(path.replay_gain_source),
            path.preamp_db,
            if (path.peak_protection) "on" else "off",
            switch (path.fallback) {
                .minus_6_db => "-6",
                .as_is => "as-is",
            },
            if (path.peak_limited) "yes" else "no",
        },
    );
    if (path.device_format) |device| {
        try stdout.print(" device_format={s} device_bits={d} device_rate={d}\n", .{
            deviceFormatName(device.sample_format),
            device.sample_format.bitsPerSample(),
            device.sample_rate,
        });
    } else try stdout.writeAll(" device_format=-\n");
}

fn deviceFormatName(sample_format: liborca.DeviceSampleFormat) []const u8 {
    return switch (sample_format) {
        .signed_16 => "S16LE",
        .signed_24 => "S24LE",
        .signed_24_32 => "S24_32LE",
        .signed_32 => "S32LE",
        .float_32 => "F32LE",
    };
}

fn formatName(sample_format: liborca.SampleFormat) []const u8 {
    return switch (sample_format) {
        .unsigned_8 => "uint8",
        .signed_8 => "int8",
        .signed_16 => "int16",
        .signed_24 => "int24",
        .signed_32 => "int32",
        .float_32 => "float32",
        .float_64 => "float64",
    };
}

/// The queue driven from the outside, exactly as a frontend would drive it.
///
/// Everything here is presentation: parse ids, call the runtime, print what it
/// reports. No transport state, no notion of "which track is next", and no
/// decoding — those all live in `liborca`, which is the whole point of using
/// the CLI as the architectural test client.
fn playTracks(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const database_path_argument = context.arguments[0];
    const id_list: ?[]const u8 = if (std.mem.startsWith(u8, context.arguments[1], "--")) null else context.arguments[1];
    const option_arguments = context.arguments[if (id_list == null) 1 else 2..];
    var options: PlayTracksOptions = .{};
    for (option_arguments) |argument| try parseOption(&options, argument);
    if (id_list != null and options.playlist_id != null) return error.TracksAndPlaylist;
    if (options.equalizer != null and options.parametric_path != null) return error.EqualizerAndParametric;
    const parametric = if (options.parametric_path) |path| try readEqualizerApo(context, path) else null;

    var ids: std.ArrayList(i64) = if (id_list) |list| try parseTrackIds(allocator, list) else .empty;
    defer ids.deinit(allocator);
    if (id_list == null and options.playlist_id == null) return error.NoTrackIds;

    const database_path = try allocator.dupeSentinel(u8, database_path_argument, 0);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    try identifyOrca(&runtime);
    const library = try runtime.openLibrary(io, database_path);
    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneRequestOutput(zone, options.device);

    try runtime.playerSetVolume(player, options.volume);
    try runtime.playerSetReplayGainMode(player, options.replay_gain);
    try runtime.playerSetReplayGainPreamp(player, options.preamp_db);
    try runtime.playerSetReplayGainFallback(player, options.untagged);
    try runtime.playerSetPeakProtection(player, options.peak_protection);
    try runtime.playerSetStopAfterCurrent(player, options.stop_after_current);
    try runtime.playerSetEqualizer(player, options.equalizer);
    try runtime.playerSetParametricEqualizer(player, parametric);
    try runtime.playerSetCrossfeed(player, options.crossfeed);
    try runtime.playerSetRepeat(player, options.repeat);
    if (options.shuffle) try runtime.playerSetShuffle(player, true);
    var failures: FailureReporter = .{ .runtime = &runtime, .player = player };
    var start = options.start;
    while (true) {
        const started = if (options.playlist_id) |playlist_id|
            runtime.playerPlayPlaylist(player, library, io, playlist_id, start)
        else
            runtime.playerPlayTracks(player, library, io, ids.items, start);
        started catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.PositionOutOfRange => return if (start == options.start) err else error.NothingPlayable,
            else => {
                if (!try failures.poll(stdout)) return err;
                start += 1;
                continue;
            },
        };
        break;
    }

    var elapsed_ms: u64 = 0;
    var entry_elapsed_ms: u64 = 0;
    var last_cursor: ?u32 = null;
    var took_previous = options.previous_after_ms == null;
    var set_volume = options.set_volume == null;
    var moves_made: [max_scheduled_moves]bool = @splat(false);
    var printed_signal_path = false;
    // How often the producer was observed a whole entry ahead of the audio.
    // Nonzero is the proof that now-playing is derived from rendered audio
    // rather than from the decode cursor.
    var decode_lead_polls: u64 = 0;
    var lyrics: LyricsFollower = .{ .runtime = &runtime, .library = library };
    defer lyrics.deinit();
    while (elapsed_ms < options.limit_ms) {
        _ = runtime.processNextCommand();
        if (options.lyrics) try lyrics.poll(stdout, player, elapsed_ms);
        _ = try failures.poll(stdout);
        const snapshot = try runtime.playerQueueSnapshot(player);
        if (snapshot.decode_position != snapshot.cursor) decode_lead_polls += 1;
        if (last_cursor == null or last_cursor.? != snapshot.cursor) {
            last_cursor = snapshot.cursor;
            entry_elapsed_ms = 0;
            const now_playing = try runtime.playerNowPlaying(player);
            // volume and gain differing is what a loudness correction looks
            // like from outside: `gain` is what the audible entry's samples
            // are being multiplied by, and `volume` is only what the user
            // asked for.
            try stdout.print(
                "now-playing at={d}ms position={d} decode_position={d} track={?d} " ++
                    "volume={d:.6} gain={d:.6}\n",
                .{
                    elapsed_ms,
                    snapshot.cursor,
                    snapshot.decode_position,
                    if (now_playing) |ref| ref.track_id else null,
                    try runtime.playerVolume(player),
                    try runtime.playerEffectiveGain(player),
                },
            );
            try stdout.flush();
            if (options.tail_ms) |tail| _ = try runtime.playerSeekToTail(player, tail);
        }
        if (!set_volume and elapsed_ms >= options.set_volume.?.at_ms) {
            set_volume = true;
            try runtime.playerSetVolume(player, options.set_volume.?.linear);
            // Printed as a pair on purpose: a volume change that disturbed the
            // loudness correction, or a correction that moved the volume,
            // would show up here as the other number moving.
            try stdout.print(
                "set-volume at={d}ms volume={d:.6} gain={d:.6}\n",
                .{
                    elapsed_ms,
                    try runtime.playerVolume(player),
                    try runtime.playerEffectiveGain(player),
                },
            );
            try stdout.flush();
        }
        for (options.moves[0..options.move_count], moves_made[0..options.move_count]) |scheduled, *made| {
            if (made.* or elapsed_ms < scheduled.at_ms) continue;
            made.* = true;
            const cursor_before = (try runtime.playerQueueSnapshot(player)).cursor;
            const result: []const u8 = if (runtime.playerQueueMove(player, scheduled.from, scheduled.to)) |_|
                "ok"
            else |err| switch (err) {
                error.QueueEntryInUse => "in_use",
                error.PositionOutOfRange => "out_of_range",
                else => return err,
            };
            if (last_cursor == cursor_before) last_cursor = (try runtime.playerQueueSnapshot(player)).cursor;
            try stdout.print("move at={d}ms from={d} to={d} result={s}\n", .{
                elapsed_ms,
                scheduled.from,
                scheduled.to,
                result,
            });
            try stdout.flush();
        }
        if (!took_previous and elapsed_ms >= options.previous_after_ms.?) {
            took_previous = true;
            const moved = runtime.playerPrevious(player) catch |err| moved: {
                if (!try failures.poll(stdout)) return err;
                break :moved true;
            };
            try stdout.print("previous at={d}ms moved={}\n", .{ elapsed_ms, moved });
            try stdout.flush();
            last_cursor = null;
        }
        if (options.skip_after_ms) |after| {
            if (entry_elapsed_ms >= after) {
                const moved = runtime.playerNext(player) catch |err| moved: {
                    if (!try failures.poll(stdout)) return err;
                    break :moved true;
                };
                try stdout.print("next at={d}ms moved={}\n", .{ elapsed_ms, moved });
                try stdout.flush();
                if (!moved) break;
                last_cursor = null;
                continue;
            }
        }
        if (!printed_signal_path and elapsed_ms >= 1000) {
            const path = try runtime.playerSignalPath(player);
            if (path.output != null) {
                printed_signal_path = true;
                try printSignalPath(stdout, path);
                try stdout.flush();
            }
        }
        try requireOutput(&runtime, zone);
        if (try runtime.playerDrained(player)) break;
        sleepMilliseconds(10);
        elapsed_ms += 10;
        entry_elapsed_ms += 10;
    }

    _ = try failures.poll(stdout);
    try runtime.pausePlayer(player);
    sleepMilliseconds(200);
    const snapshot = try runtime.playerQueueSnapshot(player);
    const stats = try runtime.playerQueueStats(player);
    const zone_stats = try runtime.zoneStats(zone);
    try stdout.print(
        "queue entries={d} cursor={d} started={d} gapless={d} format_switch={d} " ++
            "open_failures={d} decode_errors={d} decode_lead_polls={d} " ++
            "underruns={d} quantum={d} state={s}\n",
        .{
            snapshot.entries,
            snapshot.cursor,
            stats.entries_started,
            stats.gapless_transitions,
            stats.format_switch_transitions,
            stats.open_failures,
            stats.decode_errors,
            decode_lead_polls,
            zone_stats.underruns,
            zone_stats.backend_quantum_frames,
            @tagName(zone_stats.output_state),
        },
    );
    if (options.print_history) try printQueueHistory(&runtime, stdout, player, library);
    if (options.save_queue) |name| {
        const playlist_id = try runtime.playerSaveQueueAsPlaylist(player, library, name);
        const playlist = try runtime.libraryPlaylist(library, playlist_id);
        defer playlist.deinit(runtime.allocator);
        try stdout.print("saved-queue playlist_id={d} entries={d}\n", .{ playlist_id, playlist.entries });
    }
    if (options.save_state) {
        try runtime.playerSaveState(player, library);
        const status = try runtime.playerStatus(player);
        try stdout.print("saved-state entries={d} index={d} position_ms={d}\n", .{
            status.queue_length,
            status.queue_index,
            status.position_ms,
        });
    }
}

fn resumePlayback(context: Context) !void {
    const io = context.io;
    const stdout = context.stdout;
    var device: ?u64 = null;
    var play = false;
    var limit_ms: u64 = 10 * 1000;
    for (context.arguments[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--play")) {
            play = true;
        } else if (std.mem.startsWith(u8, argument, "--device=")) {
            device = try std.fmt.parseInt(u64, argument["--device=".len..], 10);
        } else if (std.mem.startsWith(u8, argument, "--limit=")) {
            limit_ms = try std.fmt.parseInt(u64, argument["--limit=".len..], 10);
        } else return error.UnknownOption;
    }

    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    try identifyOrca(&runtime);
    const library = try openBrowseLibrary(context.allocator, io, &runtime, context.arguments[0]);
    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneRequestOutput(zone, device orelse return error.MissingDevice);
    try runtime.playerBindLibrary(player, library, io);
    const outcome = try runtime.playerRestoreState(player, library, if (play) .playing else .paused);
    try stdout.print("restored entries={d} index={d} position_ms={d} skipped_missing={d}\n", .{
        outcome.entries,
        outcome.index,
        outcome.position_ms,
        outcome.skipped_missing,
    });

    var refs: [64]liborca.TrackRef = undefined;
    var position = outcome.index;
    while (outcome.entries > 0) {
        const count = try runtime.playerQueuePage(player, position, &refs);
        for (refs[0..count]) |ref| {
            const details = try runtime.libraryTrackDetails(library, ref.track_id);
            defer if (details) |value| value.deinit();
            try stdout.print("queue position={d} track={d} title={s}\n", .{
                position,
                ref.track_id,
                if (details) |value| value.title else "",
            });
            position += 1;
        }
        if (count < refs.len) break;
    }
    try printResumeStatus(&runtime, stdout, player);
    if (!play) return;

    var elapsed_ms: u64 = 0;
    while (elapsed_ms < limit_ms) {
        _ = runtime.processNextCommand();
        try requireOutput(&runtime, zone);
        if (try runtime.playerDrained(player)) break;
        sleepMilliseconds(10);
        elapsed_ms += 10;
    }
    try runtime.pausePlayer(player);
    try printResumeStatus(&runtime, stdout, player);
}

fn printResumeStatus(runtime: *liborca.Runtime, stdout: *std.Io.Writer, player: liborca.PlayerHandle) !void {
    const status = try runtime.playerStatus(player);
    try stdout.print(
        "status transport={t} index={d} entries={d} track={?d} position_ms={d} resumed_from_ms={?d} repeat={t} shuffle={}\n",
        .{
            status.transport,
            status.queue_index,
            status.queue_length,
            status.track_id,
            status.position_ms,
            status.resumed_from_ms,
            status.repeat,
            status.shuffle,
        },
    );
    try stdout.flush();
}

fn printQueueHistory(
    runtime: *liborca.Runtime,
    stdout: *std.Io.Writer,
    player: liborca.PlayerHandle,
    library: liborca.LibraryHandle,
) !void {
    var entries: [liborca.queue_history_capacity]liborca.QueueHistoryEntry = undefined;
    const count = try runtime.playerQueueHistory(player, 0, &entries);
    for (entries[0..count]) |entry| {
        const details = try runtime.libraryTrackDetails(library, entry.track.track_id);
        defer if (details) |value| value.deinit();
        try stdout.print("history ended_at={d} reason={t} track={d} title={s}\n", .{
            entry.ended_at_ms,
            entry.reason,
            entry.track.track_id,
            if (details) |value| value.title else "",
        });
    }
}

const FailureReporter = struct {
    runtime: *liborca.Runtime,
    player: liborca.PlayerHandle,
    printed: ?liborca.PlaybackFailure = null,

    fn poll(self: *FailureReporter, stdout: *std.Io.Writer) !bool {
        const failure = (try self.runtime.playerStatus(self.player)).last_failure;
        defer self.printed = failure;
        const current = failure orelse return false;
        if (self.printed) |printed| if (std.meta.eql(printed, current)) return true;
        try stdout.print("failure={d}:{t}\n", .{ current.track_id, current.reason });
        try stdout.flush();
        return true;
    }
};

/// play-tracks --lyrics: resolves the audible Track's lyrics on a job, so the
/// playback loop never waits on a file, and prints each synced line reached.
const LyricsFollower = struct {
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    track_id: ?i64 = null,
    entry_serial: u32 = 0,
    job: ?liborca.JobHandle = null,
    lyrics: ?liborca.Lyrics = null,
    line: ?usize = null,

    fn deinit(self: *LyricsFollower) void {
        if (self.lyrics) |owned| owned.deinit();
        self.lyrics = null;
    }

    fn poll(self: *LyricsFollower, stdout: *std.Io.Writer, player: liborca.PlayerHandle, elapsed_ms: u64) !void {
        self.runtime.reapFinishedJobs();
        while (self.runtime.pollEvent()) |_| {}
        const status = try self.runtime.playerStatus(player);
        if (status.entry_serial != self.entry_serial) {
            self.entry_serial = status.entry_serial;
            self.line = null;
            if (status.track_id != self.track_id) try self.follow(status.track_id);
        }
        if (self.job) |job_handle| {
            const snapshot = try self.runtime.jobSnapshotSynced(job_handle);
            switch (snapshot.state) {
                .succeeded, .failed, .cancelled => {
                    self.job = null;
                    self.lyrics = try self.runtime.jobTakeLyrics(job_handle);
                    const outcome = try self.runtime.jobLyricsOutcome(job_handle);
                    try stdout.print("lyrics at={d}ms track={?d} outcome={s}", .{ elapsed_ms, self.track_id, @tagName(outcome) });
                    if (self.lyrics) |found| try stdout.print(" source={s} kind={s} lines={d}", .{
                        @tagName(found.source),
                        @tagName(found.kind),
                        found.lines.len,
                    });
                    try stdout.writeAll("\n");
                    try stdout.flush();
                },
                else => {},
            }
        }
        const found = self.lyrics orelse return;
        const line = found.lineAt(status.position_ms);
        if (line == self.line) return;
        self.line = line;
        const index = line orelse return;
        try stdout.print("lyric at={d}ms track={?d} line={d} text={s}\n", .{
            elapsed_ms,
            self.track_id,
            index,
            found.lines[index].text,
        });
        try stdout.flush();
    }

    fn follow(self: *LyricsFollower, track_id: ?i64) !void {
        self.deinit();
        if (self.job) |stale| self.runtime.cancelJob(stale) catch {};
        self.job = null;
        self.track_id = track_id;
        const id = track_id orelse return;
        self.job = try self.runtime.startTrackLyrics(self.library, id, .{});
    }
};

const BrowseOptions = struct {
    artist_id: ?i64 = null,
    /// Free text: for `artists`, folded the way artist keys are folded, so
    /// `--filter el-p` finds the one spelled with a U+2010 hyphen; for
    /// `tracks`, a full-text search ranked by relevance; for `releases`, words
    /// each beginning a word of the title or album artist.
    filter: []const u8 = "",
    release_id: ?i64 = null,
    genre_id: ?i64 = null,
    loved_only: bool = false,
    /// Parsed by the verb, since each verb sorts by different keys.
    sort: ?[]const u8 = null,
    descending: bool = false,
    limit: u32 = 50,
    offset: u32 = 0,
};

/// `--name value` pairs, matching the shape the rest of this file already
/// parses. A flag this verb does not understand is an error rather than
/// something quietly ignored: a mistyped `--sort` that silently listed
/// insertion order would look like a liborca bug.
fn parseBrowseOptions(arguments: []const []const u8) !BrowseOptions {
    var options: BrowseOptions = .{};
    var index: usize = 0;
    while (index < arguments.len) {
        const name = arguments[index];
        if (std.mem.eql(u8, name, "--desc")) {
            options.descending = true;
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, name, "--loved")) {
            options.loved_only = true;
            index += 1;
            continue;
        }
        if (index + 1 >= arguments.len) return error.MissingOptionValue;
        const value = arguments[index + 1];
        index += 2;
        if (std.mem.eql(u8, name, "--artist")) {
            options.artist_id = try std.fmt.parseInt(i64, value, 10);
        } else if (std.mem.eql(u8, name, "--filter")) {
            options.filter = value;
        } else if (std.mem.eql(u8, name, "--release")) {
            options.release_id = try std.fmt.parseInt(i64, value, 10);
        } else if (std.mem.eql(u8, name, "--genre")) {
            options.genre_id = try std.fmt.parseInt(i64, value, 10);
        } else if (std.mem.eql(u8, name, "--limit")) {
            options.limit = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, name, "--offset")) {
            options.offset = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, name, "--sort")) {
            options.sort = value;
        } else return error.UnknownOption;
    }
    return options;
}

fn parseTrackSort(key: ?[]const u8) !liborca.TrackSort {
    const value = key orelse return .id;
    return if (std.mem.eql(u8, value, "id"))
        .id
    else if (std.mem.eql(u8, value, "artist"))
        .artist
    else if (std.mem.eql(u8, value, "album"))
        .album
    else if (std.mem.eql(u8, value, "title"))
        .title
    else if (std.mem.eql(u8, value, "track"))
        .track_number
    else if (std.mem.eql(u8, value, "duration"))
        .duration
    else if (std.mem.eql(u8, value, "added"))
        .date_added
    else if (std.mem.eql(u8, value, "rating"))
        .rating
    else if (std.mem.eql(u8, value, "loved"))
        .loved
    else if (std.mem.eql(u8, value, "play_count"))
        .play_count
    else if (std.mem.eql(u8, value, "last_played"))
        .last_played
    else if (std.mem.eql(u8, value, "year"))
        .year
    else if (std.mem.eql(u8, value, "loudness"))
        .loudness
    else if (std.mem.eql(u8, value, "bitrate"))
        .bitrate
    else if (std.mem.eql(u8, value, "path"))
        .path
    else if (std.mem.eql(u8, value, "album_artist"))
        .album_artist
    else if (std.mem.eql(u8, value, "genre"))
        .genre
    else
        error.UnknownSortKey;
}

/// `name` or `tracks`, the two orders artists and genres come in.
fn parseCountSort(key: ?[]const u8) !enum { name, track_count } {
    const value = key orelse return .name;
    if (std.mem.eql(u8, value, "name")) return .name;
    if (std.mem.eql(u8, value, "tracks")) return .track_count;
    return error.UnknownSortKey;
}

/// `mm:ss` from a duration liborca reports in milliseconds.
///
/// The cast to unsigned is not cosmetic: `{d:0>2}` on a signed integer emits a
/// sign, so a signed seconds value prints `4:+07`.
fn writeDuration(stdout: *std.Io.Writer, duration_ms: ?i64) !void {
    const milliseconds = duration_ms orelse {
        try stdout.writeAll("-:--");
        return;
    };
    const total_seconds: u64 = @intCast(@divTrunc(@max(milliseconds, 0), 1000));
    try stdout.print("{d}:{d:0>2}", .{ total_seconds / 60, total_seconds % 60 });
}

fn openBrowseLibrary(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: *liborca.Runtime,
    database_path_argument: []const u8,
) !liborca.LibraryHandle {
    const database_path = try allocator.dupeSentinel(u8, database_path_argument, 0);
    return runtime.openLibrary(io, database_path);
}

fn parseTrackIds(allocator: std.mem.Allocator, id_list: []const u8) !std.ArrayList(i64) {
    var ids: std.ArrayList(i64) = .empty;
    errdefer ids.deinit(allocator);
    var walk = std.mem.splitScalar(u8, id_list, ',');
    while (walk.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " ");
        if (trimmed.len == 0) continue;
        try ids.append(allocator, try std.fmt.parseInt(i64, trimmed, 10));
    }
    if (ids.items.len == 0) return error.NoTrackIds;
    return ids;
}

const edit_options = [_]struct { flag: []const u8, field: liborca.MetadataField }{
    .{ .flag = "--title", .field = .title },
    .{ .flag = "--artist", .field = .artist },
    .{ .flag = "--album", .field = .album },
    .{ .flag = "--album-artist", .field = .album_artist },
    .{ .flag = "--track", .field = .track_number },
    .{ .flag = "--disc", .field = .disc_number },
    .{ .flag = "--date", .field = .date },
    .{ .flag = "--compilation", .field = .compilation },
    .{ .flag = "--recording-id", .field = .musicbrainz_recording_id },
    .{ .flag = "--composer", .field = .composer },
    .{ .flag = "--comment", .field = .comment },
};

/// Library-only edits: Orca's own values, never written to the files.
fn editTracks(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const database_path_argument = context.arguments[0];
    const id_list = context.arguments[1];
    const option_arguments = context.arguments[2..];
    var ids = try parseTrackIds(allocator, id_list);
    defer ids.deinit(allocator);
    var edits: std.ArrayList(liborca.TrackEdit) = .empty;
    defer edits.deinit(allocator);
    var genres: ?std.ArrayList([]const u8) = null;
    defer if (genres) |*names| names.deinit(allocator);
    for (option_arguments) |argument| {
        const split = std.mem.indexOfScalar(u8, argument, '=') orelse return error.UnknownOption;
        const name = argument[0..split];
        const value = argument[split + 1 ..];
        if (std.mem.eql(u8, name, "--genre") or
            (std.mem.eql(u8, name, "--clear") and std.mem.eql(u8, value, "genre")))
        {
            if (genres) |*names| names.clearRetainingCapacity() else genres = .empty;
            if (std.mem.eql(u8, name, "--clear")) continue;
            var walk = std.mem.splitScalar(u8, value, ';');
            while (walk.next()) |genre| try genres.?.append(allocator, genre);
            continue;
        }
        if (std.mem.eql(u8, name, "--clear")) {
            const field = std.meta.stringToEnum(liborca.MetadataField, value) orelse
                return error.UnknownField;
            try edits.append(allocator, .{ .field = field, .value = null });
            continue;
        }
        if (std.mem.eql(u8, name, "--explicit")) {
            const advisory: liborca.Explicit = if (std.mem.eql(u8, value, "yes"))
                .explicit
            else if (std.mem.eql(u8, value, "no"))
                .none
            else if (std.mem.eql(u8, value, "clean"))
                .clean
            else
                return error.InvalidEditValue;
            try edits.append(allocator, .{ .field = .explicit, .value = advisory.advisoryText() });
            continue;
        }
        for (edit_options) |option| {
            if (std.mem.eql(u8, name, option.flag)) {
                try edits.append(allocator, .{ .field = option.field, .value = value });
                break;
            }
        } else return error.UnknownOption;
    }

    const database_path = try allocator.dupeSentinel(u8, database_path_argument, 0);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try runtime.openLibrary(io, database_path);
    if (genres) |names| {
        try runtime.librarySetTrackGenres(library, ids.items, names.items);
        try stdout.print("set genres of {d} tracks\n", .{ids.items.len});
    }
    if (edits.items.len > 0) {
        const edited = try runtime.libraryEditTracks(library, ids.items, edits.items);
        defer edited.deinit();
        try stdout.print("edited {d} tracks, now", .{ids.items.len});
        for (edited.ids, 0..) |id, index| try stdout.print("{s}{d}", .{ if (index == 0) " " else ",", id });
        try stdout.writeAll("\n");
        return;
    }
    if (genres != null) return;
    for (ids.items) |track_id| {
        var page = try runtime.libraryTrackEdits(library, track_id);
        defer page.deinit();
        for (page.items) |value| try stdout.print(
            "{d}\t{t}\t{s}\t{t}{s}\n",
            .{ track_id, value.field, value.text, value.provenance, if (value.locked) "\tlocked" else "" },
        );
    }
}

/// `orca-cli fields DATABASE IDS`: what a metadata editor shows for them.
fn showTrackFields(context: Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout;
    var ids = try parseTrackIds(allocator, context.arguments[1]);
    defer ids.deinit(allocator);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    const states = try runtime.libraryTrackFieldStates(library, ids.items);
    defer states.deinit();
    for (std.enums.values(liborca.EditableTrackField)) |field| {
        const state = states.fields.get(field);
        try stdout.print("{t}\tvalue={s}\tmixed={s}\tedited={s}\n", .{
            field,
            state.value orelse "-",
            if (state.mixed) "yes" else "no",
            if (state.edited) "yes" else "no",
        });
    }
    if (states.disc_total) |total| try stdout.print("disc_total={d}\n", .{total}) else try stdout.writeAll("disc_total=-\n");
    try stdout.print("cover\tsource={t}\tfile={s}\tmime={s}\ttracks={d}/{d}\n", .{
        states.cover.source,
        states.cover.file_name orelse "-",
        states.cover.mime_type orelse "-",
        states.cover.tracks,
        states.track_count,
    });
}

/// Tag write-back through the runtime's plan, approve and undo path.
fn writeTags(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const database_path_argument = context.arguments[0];
    const id_list = context.arguments[1];
    const option_arguments = context.arguments[2..];
    var ids = try parseTrackIds(allocator, id_list);
    defer ids.deinit(allocator);
    var approved: ?liborca.TagWriteDigest = null;
    for (option_arguments) |argument| {
        if (!std.mem.startsWith(u8, argument, "--approve=")) return error.UnknownOption;
        var digest: liborca.TagWriteDigest = undefined;
        const hex = argument["--approve=".len..];
        if (hex.len != digest.len * 2) return error.InvalidDigest;
        _ = std.fmt.hexToBytes(&digest, hex) catch return error.InvalidDigest;
        approved = digest;
    }

    const database_path = try allocator.dupeSentinel(u8, database_path_argument, 0);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try runtime.openLibrary(io, database_path);
    const plan = try runtime.planTagWrite(library, io, ids.items);
    defer plan.deinit();
    for (plan.skipped) |skip| try stdout.print("skip\t{d}\t{t}\t{s}\n", .{ skip.file_id, skip.reason, skip.path });
    for (plan.files) |file| {
        try stdout.print("file\t{d}\t{s}\n", .{ file.file_id, file.path });
        for (file.changes) |change| try stdout.print(
            "\t{t}\t{s} -> {s}\t{s}\n",
            .{ change.field, change.before orelse "(none)", change.after orelse "(none)", provenanceLabel(change.provenance) },
        );
        if (file.genres) |genres| {
            try stdout.writeAll("\tgenres\t");
            try writeGenreList(stdout, genres.before);
            try stdout.writeAll(" -> ");
            try writeGenreList(stdout, genres.after);
            try stdout.writeAll("\tedit\n");
        }
    }
    for (plan.conflicts) |conflict| try stdout.print(
        "conflict\t{d}\t{t}\tfile {s}\torca {s}\t{s}\t{s}\n",
        .{ conflict.file_id, conflict.field, conflict.file_value, conflict.orca_value, provenanceLabel(conflict.provenance), conflict.path },
    );
    if (plan.files.len == 0) {
        try stdout.print("nothing to write\n", .{});
        return;
    }
    const digest = approved orelse {
        try stdout.print("digest {x}\n", .{&plan.digest});
        return;
    };
    const job_handle = try runtime.startTagWrite(library, plan.plan_id, digest);
    awaitJob(&runtime, stdout, job_handle, null) catch |err| {
        if (err == error.JobFailed) if (try runtime.jobTagWriteFailure(job_handle)) |failure| {
            if (failure.file) |file| {
                try stdout.print("failed\t{d}\t{t}\t{s}\n", .{ file.file_id, failure.reason, plan.files[file.action_index].path });
            } else {
                try stdout.print("failed\t-\t{t}\t-\n", .{failure.reason});
            }
            try stdout.flush();
        };
        return err;
    };
    const stats = try runtime.jobScanStats(job_handle);
    try stdout.print("wrote {d} files as group {d}\n", .{ stats.changed, plan.plan_id });
}

fn writeGenreList(stdout: *std.Io.Writer, genres: []const []const u8) !void {
    if (genres.len == 0) return stdout.writeAll("(none)");
    for (genres, 0..) |genre, index| try stdout.print("{s}{s}", .{ if (index == 0) "" else "; ", genre });
}

fn provenanceLabel(provenance: liborca.Provenance) []const u8 {
    return switch (provenance) {
        .user => "edit",
        .provider => "match",
        else => @tagName(provenance),
    };
}

/// `orca-cli track DATABASE ID`: the details view's query, printed.
fn showTrack(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const database_path_argument = context.arguments[0];
    const id_argument = context.arguments[1];
    const track_id = try std.fmt.parseInt(i64, id_argument, 10);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    const details = (try runtime.libraryTrackDetails(library, track_id)) orelse
        return error.TrackNotFound;
    defer details.deinit();

    try printDetail(stdout, "title", "{s}", .{details.title});
    try printDetail(stdout, "artist", "{s}", .{details.artist});
    try printDetail(stdout, "album", "{s}", .{details.album});
    try printDetail(stdout, "album artist", "{s}", .{details.album_artist});
    try printOptionalDetail(stdout, "date", "{s}", details.date);
    try printOptionalDetail(stdout, "composer", "{s}", details.composer);
    try printOptionalDetail(stdout, "comment", "{s}", details.comment);
    try writeDetailKey(stdout, "genres");
    for (details.genres, 0..) |genre, index| try stdout.print("{s}{s}", .{ if (index == 0) "" else "; ", genre });
    if (details.genres.len == 0) try stdout.writeAll("-\n") else {
        const genres = try runtime.libraryTrackGenres(library, track_id);
        defer genres.deinit();
        try stdout.print(" provenance={s}\n", .{if (genres.items.len == 0) "-" else @tagName(genres.items[0].provenance)});
    }
    try writeDetailKey(stdout, "track");
    try writeOfTotal(stdout, details.track_number, details.track_total);
    try stdout.writeAll(if (details.track_total_inferred) " (counted)\n" else "\n");
    try writeDetailKey(stdout, "disc");
    try writeOfTotal(stdout, details.disc_number, details.disc_total);
    try stdout.writeAll("\n");
    try printDetail(stdout, "explicit", "{s}", .{explicitName(details.explicit)});
    try printDetail(stdout, "codec", "{s}", .{if (details.codec.len == 0) "-" else details.codec});
    try printOptionalDetail(stdout, "sample rate", "{d} Hz", details.sample_rate);
    if (!details.lossy) try printOptionalDetail(stdout, "bit depth", "{d}-bit", details.bit_depth);
    try printOptionalDetail(stdout, "channels", "{d}", details.channels);
    try printOptionalDetail(stdout, "bitrate", "{d} kbps", details.bitrate_kbps);
    try writeDetailKey(stdout, "duration");
    try writeDuration(stdout, details.duration_ms);
    try stdout.writeAll("\n");
    try printOptionalDetail(stdout, "size", "{d} bytes", details.size_bytes);
    if (details.path) |path| {
        try printDetail(stdout, "path", "{s}", .{path});
    } else try printDetail(stdout, "path", "{s}", .{"(file missing)"});
    try writeDetailKey(stdout, "added");
    if (details.added_at) |seconds| try writeIsoUtc(stdout, seconds) else try stdout.writeAll("-");
    try stdout.writeAll("\n");
    try writeDetailKey(stdout, "modified");
    if (details.modified_at) |seconds| try writeIsoUtc(stdout, seconds) else try stdout.writeAll("-");
    try stdout.writeAll("\n");
    if (details.loudness) |loudness| {
        try printDetail(
            stdout,
            "loudness",
            "{d:.1} LUFS, peak {d:.1} dBFS, ReplayGain {d:.1} dB",
            .{ loudness.integrated_lufs, 20 * @log10(loudness.sample_peak), loudness.replay_gain_db },
        );
    } else try printDetail(stdout, "loudness", "{s}", .{"not measured"});
    try printDetail(stdout, "artwork", "{s}", .{if (details.has_artwork) "yes" else "no"});
    try printDetail(stdout, "feedback", "{s}", .{switch (details.feedback) {
        .none => "none",
        .loved => "loved",
        .hated => "hated",
    }});
    try stdout.print("feedback sync: {s}\n", .{
        if (details.feedback_syncable) "yes" else "no (no MusicBrainz recording ID)",
    });
    if (details.rating) |rating| {
        try printDetail(stdout, "rating", "{d}", .{rating});
    } else try printDetail(stdout, "rating", "{s}", .{"none"});
    try printMusicBrainzId(stdout, "recording id", details.musicbrainz_recording_id, details.musicbrainz_recording_id_source);
    try printMusicBrainzId(stdout, "release id", details.musicbrainz_release_id, details.musicbrainz_release_id_source);
    try printMusicBrainzId(stdout, "release group", details.musicbrainz_release_group_id, details.musicbrainz_release_group_id_source);
    try printMusicBrainzId(stdout, "release track", details.musicbrainz_release_track_id, details.musicbrainz_release_track_id_source);
    try printMusicBrainzId(stdout, "album artist id", details.musicbrainz_album_artist_id, details.musicbrainz_album_artist_id_source);
    try printVerification(stdout, try runtime.libraryTrackVerification(library, allocator, track_id));
    try printDetail(stdout, "plays", "{d}", .{details.play_count});
    try writeDetailKey(stdout, "last played");
    if (details.last_played_at) |seconds| {
        try writeIsoUtc(stdout, seconds);
    } else try stdout.writeAll("never");
    try stdout.writeAll("\n");
}

fn printVerification(stdout: *std.Io.Writer, stored: ?liborca.TrackVerification) !void {
    const verification = stored orelse return printDetail(stdout, "verification", "{s}", .{"not verified"});
    defer verification.deinit();
    try printDetail(stdout, "verification", "{s}{s}", .{
        switch (verification.outcome) {
            .agrees => "agrees",
            .disagrees => "disagrees",
            .unconfirmed => "unconfirmed",
            .no_fingerprint => "no fingerprint",
        },
        if (verification.stale) " (stale)" else "",
    });
    if (verification.outcome != .disagrees) return;
    try writeDetailKey(stdout, "heard");
    for (verification.heard, 0..) |recording, index| {
        if (index != 0) try stdout.writeAll(", ");
        try stdout.print("{s} ({d:.2})", .{ recording.mbid, recording.score });
    }
    try stdout.writeAll("\n");
    if (verification.dismissed) try printDetail(stdout, "proposal", "{s}", .{"dismissed"});
}

fn printMusicBrainzId(
    stdout: *std.Io.Writer,
    comptime key: []const u8,
    id: ?[]const u8,
    source: ?liborca.RecordingIdSource,
) !void {
    const present = id orelse return printDetail(stdout, key, "{s}", .{"-"});
    try printDetail(stdout, key, "{s} ({s})", .{ present, @tagName(source.?) });
}

fn writeIsoUtc(stdout: *std.Io.Writer, unix_seconds: i64) !void {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(unix_seconds, 0)) };
    const month_day = epoch.getEpochDay().calculateYearDay().calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    try stdout.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        epoch.getEpochDay().calculateYearDay().year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

/// The ListenBrainz token and the AcoustID user key from the process
/// environment, read once at startup because the environment map is not safe
/// to read from a worker's thread.
const EnvironmentCredentials = struct {
    token: ?[]u8,
    acoustid_user_key: ?[]u8,

    fn init(allocator: std.mem.Allocator, environ: *std.process.Environ.Map) !EnvironmentCredentials {
        const token = try copyVariable(allocator, environ, "ORCA_LISTENBRAINZ_TOKEN");
        errdefer if (token) |value| wipe(allocator, value);
        return .{
            .token = token,
            .acoustid_user_key = try copyVariable(allocator, environ, "ORCA_ACOUSTID_USER_KEY"),
        };
    }

    fn copyVariable(allocator: std.mem.Allocator, environ: *std.process.Environ.Map, name: []const u8) !?[]u8 {
        const value = environ.get(name) orelse return null;
        if (value.len == 0) return null;
        return try allocator.dupe(u8, value);
    }

    fn wipe(allocator: std.mem.Allocator, value: []u8) void {
        std.crypto.secureZero(u8, value);
        allocator.free(value);
    }

    fn deinit(self: *EnvironmentCredentials, allocator: std.mem.Allocator) void {
        if (self.token) |token| wipe(allocator, token);
        if (self.acoustid_user_key) |key| wipe(allocator, key);
        self.* = undefined;
    }

    fn store(self: *EnvironmentCredentials) liborca.CredentialStore {
        return .{ .context = self, .get_fn = get };
    }

    fn get(context: *anyopaque, allocator: std.mem.Allocator, service: []const u8, account: []const u8) anyerror!?[]u8 {
        const self: *EnvironmentCredentials = @ptrCast(@alignCast(context));
        const secret = if (std.mem.eql(u8, service, liborca.listenbrainz_token_service) and
            std.mem.eql(u8, account, liborca.listenbrainz_token_account))
            self.token
        else if (std.mem.eql(u8, service, liborca.acoustid_credential_service) and
            std.mem.eql(u8, account, liborca.acoustid_user_key_account))
            self.acoustid_user_key
        else
            null;
        return if (secret) |value| try allocator.dupe(u8, value) else null;
    }
};

fn printScrobbleLine(
    stdout: *std.Io.Writer,
    state: liborca.ScrobblerState,
    delivered: u64,
    pending: u64,
    feedback_pending: u64,
    user_name: []const u8,
    last_error: []const u8,
    blocked_until: ?i64,
) !void {
    try stdout.print(
        "scrobble: state={s} delivered={d} pending={d} feedback_pending={d}",
        .{ @tagName(state), delivered, pending, feedback_pending },
    );
    if (user_name.len != 0) try stdout.print(" user={s}", .{user_name});
    try writeBlockedUntil(stdout, blocked_until);
    try stdout.print(" last_error={s}\n", .{if (last_error.len == 0) "-" else last_error});
}

const latest_iso_utc_seconds: i64 = 253_402_300_799;

fn writeBlockedUntil(stdout: *std.Io.Writer, blocked_until: ?i64) !void {
    const until = blocked_until orelse return;
    try stdout.writeAll(" blocked_until=");
    if (until > latest_iso_utc_seconds) return stdout.print("unix:{d}", .{until});
    try writeIsoUtc(stdout, until);
}

fn awaitScrobblerState(
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    deadline_ms: u64,
    elapsed_ms: *u64,
    settled: *const fn (liborca.ScrobblerStatus) bool,
) !liborca.ScrobblerStatus {
    while (true) {
        _ = runtime.processNextCommand();
        const status = try runtime.libraryScrobblerStatus(library);
        if (settled(status) or elapsed_ms.* >= deadline_ms) return status;
        sleepMilliseconds(20);
        elapsed_ms.* += 20;
    }
}

fn isOffline(status: liborca.ScrobblerStatus) bool {
    return status.state == .offline;
}

fn hasLeftOffline(status: liborca.ScrobblerStatus) bool {
    return status.state != .offline;
}

fn needsAttention(status: liborca.ScrobblerStatus) bool {
    return switch (status.state) {
        .needs_token, .invalid_token, .rate_limited, .backing_off, .busy => true,
        .idle => status.pending == 0 and status.feedback_pending == 0,
        .disabled, .offline, .validating, .submitting => false,
    };
}

/// With nothing queued it makes no request and looks up no token, and the
/// token is never validated up front: a bad one shows as a refused delivery.
/// The worker publishes its status only at the end of a pass, and an
/// unpublished status reads as an empty idle queue. The worker therefore
/// starts offline, where its first pass makes no request and reports the
/// queue; going online afterwards leaves `offline` only when a pass with
/// requests allowed has finished. `--status` starts no worker: it reports the
/// queue as the database holds it.
fn scrobble(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const environ = context.environ;
    const stdout = context.stdout;
    const database_path_argument = context.arguments[0];
    const option_arguments = context.arguments[1..];
    const options = try parseJobOptions(option_arguments, &.{ .status, .timeout });
    const timeout_ms = options.timeout_ms orelse 120_000;
    var credentials: EnvironmentCredentials = try .init(allocator, environ);
    defer credentials.deinit(allocator);

    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    try identifyOrca(&runtime);
    try runtime.setCredentialStore(credentials.store());
    if (environ.get("ORCA_LISTENBRAINZ_URL")) |url| {
        if (url.len > 0) try runtime.setListenBrainzServer(try allocator.dupe(u8, url));
    }
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);

    if (options.status) {
        const stored = try runtime.libraryScrobblerStatus(library);
        try stdout.print(
            "scrobble: status state={s} pending={d} feedback_pending={d} delivered={d} token={s}",
            .{
                @tagName(stored.state),
                stored.pending,
                stored.feedback_pending,
                stored.delivered_total,
                if (credentials.token != null) "set" else "unset",
            },
        );
        try writeBlockedUntil(stdout, stored.blocked_until);
        try stdout.writeAll("\n");
        return;
    }

    const waiting = try runtime.libraryScrobblerStatus(library);
    if (waiting.pending == 0 and waiting.feedback_pending == 0) {
        try printScrobbleLine(stdout, .idle, 0, 0, 0, "", "", null);
        return;
    }

    var elapsed_ms: u64 = 0;
    try runtime.librarySetScrobbling(library, true, true, false);
    const queued = try awaitScrobblerState(&runtime, library, 5_000, &elapsed_ms, isOffline);

    elapsed_ms = 0;
    try runtime.librarySetScrobbling(library, true, false, false);
    _ = try awaitScrobblerState(&runtime, library, timeout_ms, &elapsed_ms, hasLeftOffline);
    const status = try awaitScrobblerState(&runtime, library, timeout_ms, &elapsed_ms, needsAttention);
    try printScrobbleLine(
        stdout,
        status.state,
        status.delivered_total -| queued.delivered_total,
        status.pending,
        status.feedback_pending,
        status.user_name.slice(),
        status.last_error.slice(),
        status.blocked_until,
    );
    try stdout.flush();
    switch (status.state) {
        .invalid_token => return error.InvalidToken,
        .needs_token => return error.NeedsToken,
        .busy => return error.ListenBrainzInUse,
        else => {},
    }
}

fn setFeedback(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const database_path_argument = context.arguments[0];
    const id_list = context.arguments[1];
    const option_argument = context.arguments[2];
    const feedback: liborca.Feedback = if (std.mem.eql(u8, option_argument, "--love"))
        .loved
    else if (std.mem.eql(u8, option_argument, "--hate"))
        .hated
    else if (std.mem.eql(u8, option_argument, "--clear"))
        .none
    else
        return error.UnknownOption;
    var ids = try parseTrackIds(allocator, id_list);
    defer ids.deinit(allocator);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    const change = try runtime.librarySetFeedback(library, ids.items, feedback);
    try stdout.print("feedback: updated={d} skipped={d}\n", .{ change.updated, change.skipped });
}

fn setRating(context: Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout;
    const option_argument = context.arguments[2];
    const rating: ?u8 = if (std.mem.eql(u8, option_argument, "--clear"))
        null
    else if (std.mem.startsWith(u8, option_argument, "--stars=")) blk: {
        const stars = try std.fmt.parseInt(u8, option_argument["--stars=".len..], 10);
        if (stars == 0 or stars > 5) return error.InvalidRating;
        break :blk stars * 20;
    } else if (std.mem.startsWith(u8, option_argument, "--rating="))
        try std.fmt.parseInt(u8, option_argument["--rating=".len..], 10)
    else
        return error.UnknownOption;
    var ids = try parseTrackIds(allocator, context.arguments[1]);
    defer ids.deinit(allocator);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    const change = try runtime.librarySetRating(library, ids.items, rating);
    try stdout.print("rating: updated={d} skipped={d}\n", .{ change.updated, change.skipped });
}

fn setReleaseLove(context: Context) !void {
    const allocator = context.allocator;
    const loved = if (context.arguments.len == 2)
        true
    else if (std.mem.eql(u8, context.arguments[2], "--clear"))
        false
    else
        return error.UnknownOption;
    var ids = try parseTrackIds(allocator, context.arguments[1]);
    defer ids.deinit(allocator);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    const change = try runtime.librarySetReleaseLove(library, ids.items, loved);
    try context.stdout.print("release-love: updated={d} skipped={d}\n", .{ change.updated, change.skipped });
}

fn setArtistLove(context: Context) !void {
    const allocator = context.allocator;
    const loved = if (context.arguments.len == 2)
        true
    else if (std.mem.eql(u8, context.arguments[2], "--clear"))
        false
    else
        return error.UnknownOption;
    var ids = try parseTrackIds(allocator, context.arguments[1]);
    defer ids.deinit(allocator);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    const change = try runtime.librarySetArtistLove(library, ids.items, loved);
    try context.stdout.print("artist-love: updated={d} skipped={d}\n", .{ change.updated, change.skipped });
}

fn listPlaylists(context: Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout;
    var query: liborca.PlaylistQuery = .{ .sort = .name };
    var index: usize = 1;
    while (index < context.arguments.len) : (index += 1) {
        const argument = context.arguments[index];
        if (std.mem.eql(u8, argument, "--smart")) {
            query.kind = .smart;
        } else if (std.mem.eql(u8, argument, "--manual")) {
            query.kind = .manual;
        } else if (std.mem.eql(u8, argument, "--pinned")) {
            query.pinned_only = true;
        } else if (std.mem.eql(u8, argument, "--created-by-me")) {
            query.created_by = .user;
        } else if (std.mem.eql(u8, argument, "--imported")) {
            query.created_by = .imported;
        } else if (std.mem.eql(u8, argument, "--sort") or std.mem.eql(u8, argument, "--filter")) {
            index += 1;
            if (index == context.arguments.len) return error.MissingOptionValue;
            const value = context.arguments[index];
            if (std.mem.eql(u8, argument, "--filter")) {
                query.filter = value;
            } else {
                query.sort = try parsePlaylistSort(value);
            }
        } else return error.UnknownOption;
    }
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    while (true) {
        var page = try runtime.libraryPlaylistPage(library, query);
        defer page.deinit();
        for (page.items) |playlist| try writePlaylistLine(stdout, playlist);
        if (page.items.len < query.limit) break;
        query.offset += query.limit;
    }
}

fn parsePlaylistSort(value: []const u8) !liborca.PlaylistSort {
    return if (std.mem.eql(u8, value, "name"))
        .name
    else if (std.mem.eql(u8, value, "updated"))
        .recently_updated
    else if (std.mem.eql(u8, value, "created"))
        .created
    else if (std.mem.eql(u8, value, "entries"))
        .entries
    else
        error.UnknownSortKey;
}

fn writePlaylistLine(stdout: *std.Io.Writer, playlist: liborca.PlaylistSummary) !void {
    try stdout.print("{d}\t{s}\t{d}\t{d}\t", .{ playlist.id, playlist.name, playlist.entries, playlist.available });
    try writeDuration(stdout, playlist.duration_ms);
    try stdout.print("\t{t}", .{playlist.kind});
    if (playlist.creator == .imported) try stdout.writeAll("\timported");
    if (playlist.pinned) try stdout.writeAll("\tpinned");
    if (playlist.loved) try stdout.writeAll("\tloved");
    if (playlist.tags.len != 0) {
        try stdout.writeAll("\ttags=");
        try writeJoined(stdout, playlist.tags, ",");
    }
    try stdout.writeAll("\n");
}

fn writeJoined(stdout: *std.Io.Writer, values: []const []const u8, separator: []const u8) !void {
    for (values, 0..) |value, index| {
        if (index != 0) try stdout.writeAll(separator);
        try stdout.writeAll(value);
    }
}

fn showPlaylist(context: Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout;
    const playlist_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const options = try parseBrowseOptions(context.arguments[2..]);
    if (options.artist_id != null or options.release_id != null or options.filter.len != 0 or
        options.genre_id != null or options.descending or options.sort != null) return error.UnknownOption;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    const playlist = try runtime.libraryPlaylist(library, playlist_id);
    defer playlist.deinit(runtime.allocator);
    try stdout.print("playlist\t{d}\t{s}\t{t}\tdescription={s}\ttags=", .{ playlist.id, playlist.name, playlist.kind, playlist.description });
    try writeJoined(stdout, playlist.tags, ",");
    try stdout.writeAll("\tgenres=");
    try writeJoined(stdout, playlist.top_genres, "; ");
    try stdout.writeAll("\n");
    const formats = try runtime.libraryPlaylistFormats(library, allocator, playlist_id);
    defer formats.deinit(allocator);
    try stdout.writeAll("formats:");
    for (formats.codecs) |item| {
        try stdout.writeByte(' ');
        for (item.codec) |byte| try stdout.writeByte(std.ascii.toUpper(byte));
        try stdout.print("={d}", .{item.count});
    }
    try stdout.print(" analyzed={d} unanalyzed={d}\n", .{ formats.analyzed, formats.unanalyzed });
    var page = try runtime.libraryPlaylistEntries(library, playlist_id, options.limit, options.offset);
    defer page.deinit();
    for (page.items) |entry| {
        const track = entry.track orelse {
            try stdout.print("{d}\tunavailable\trecording={d}\n", .{ entry.position, entry.recording_id });
            continue;
        };
        try stdout.print("{d}\t{d}\t{s}\t{s}\t{s}\t", .{ entry.position, track.id, track.title, track.artist, track.album });
        try writeDuration(stdout, track.duration_ms);
        try stdout.writeAll("\n");
    }
}

fn updatePlaylist(context: Context) !void {
    const allocator = context.allocator;
    const playlist_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    var update: liborca.PlaylistUpdate = .{};
    var tags: std.ArrayList([]const u8) = .empty;
    defer tags.deinit(allocator);
    var tags_given = false;
    for (context.arguments[2..]) |argument| {
        if (std.mem.startsWith(u8, argument, "--description=")) {
            update.description = argument["--description=".len..];
        } else if (std.mem.eql(u8, argument, "--pin")) {
            update.pinned = true;
        } else if (std.mem.eql(u8, argument, "--unpin")) {
            update.pinned = false;
        } else if (std.mem.eql(u8, argument, "--love")) {
            update.loved = true;
        } else if (std.mem.eql(u8, argument, "--unlove")) {
            update.loved = false;
        } else if (std.mem.startsWith(u8, argument, "--tags=")) {
            tags_given = true;
            tags.clearRetainingCapacity();
            var walk = std.mem.splitScalar(u8, argument["--tags=".len..], ',');
            while (walk.next()) |tag| {
                if (std.mem.trim(u8, tag, " ").len != 0) try tags.append(allocator, tag);
            }
        } else return error.UnknownOption;
    }
    if (tags_given) update.tags = tags.items;
    if (update.description == null and update.pinned == null and update.loved == null and update.tags == null)
        return error.NoPlaylistUpdate;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    try runtime.libraryUpdatePlaylist(library, playlist_id, update);
    const playlist = try runtime.libraryPlaylist(library, playlist_id);
    defer playlist.deinit(runtime.allocator);
    try writePlaylistLine(context.stdout, playlist);
}

fn readRulesFile(context: Context, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(context.io, path, context.allocator, .limited(liborca.max_smart_playlist_rules_bytes)) catch |err| switch (err) {
        error.StreamTooLong => error.InvalidSmartPlaylistRules,
        else => err,
    };
}

fn createSmartPlaylist(context: Context) !void {
    const allocator = context.allocator;
    const rules = try readRulesFile(context, context.arguments[2]);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    const playlist_id = try runtime.libraryCreateSmartPlaylist(library, context.arguments[1], rules);
    try context.stdout.print("playlist_id={d}\n", .{playlist_id});
}

fn smartPlaylistRules(context: Context) !void {
    const allocator = context.allocator;
    const playlist_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const replacement = if (context.arguments.len == 3) try readRulesFile(context, context.arguments[2]) else null;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    if (replacement) |rules| try runtime.librarySetSmartPlaylistRules(library, playlist_id, rules);
    const stored = (try runtime.librarySmartPlaylistRules(library, playlist_id)) orelse return error.PlaylistIsManual;
    defer runtime.allocator.free(stored);
    try context.stdout.writeAll(stored);
    if (!std.mem.endsWith(u8, stored, "\n")) try context.stdout.writeAll("\n");
}

fn smartPlaylistCount(context: Context) !void {
    const allocator = context.allocator;
    var sample_limit: u32 = 0;
    if (context.arguments.len == 3) {
        const argument = context.arguments[2];
        if (!std.mem.startsWith(u8, argument, "--sample=")) return error.UnknownOption;
        sample_limit = try std.fmt.parseInt(u32, argument["--sample=".len..], 10);
    }
    const rules = try readRulesFile(context, context.arguments[1]);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    const preview = try runtime.librarySmartPlaylistPreview(library, allocator, rules, sample_limit);
    defer preview.deinit(allocator);
    try context.stdout.print("count={d}\tduration_ms={d}\n", .{ preview.count, preview.duration_ms });
    for (preview.sample) |track| {
        try context.stdout.print("{d}\t{s}\t{s}\t", .{ track.id, track.title, track.artist });
        try writeDuration(context.stdout, track.duration_ms);
        try context.stdout.writeAll("\n");
    }
}

fn createPlaylist(context: Context) !void {
    const allocator = context.allocator;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    const playlist_id = try runtime.libraryCreatePlaylist(library, context.arguments[1]);
    try context.stdout.print("playlist_id={d}\n", .{playlist_id});
}

fn renamePlaylist(context: Context) !void {
    const allocator = context.allocator;
    const playlist_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    try runtime.libraryRenamePlaylist(library, playlist_id, context.arguments[2]);
}

fn deletePlaylist(context: Context) !void {
    const allocator = context.allocator;
    const playlist_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    try runtime.libraryDeletePlaylist(library, playlist_id);
}

fn addToPlaylist(context: Context) !void {
    const allocator = context.allocator;
    const playlist_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    var ids = try parseTrackIds(allocator, context.arguments[2]);
    defer ids.deinit(allocator);
    var at: ?u32 = null;
    for (context.arguments[3..]) |argument| {
        if (!std.mem.startsWith(u8, argument, "--at=")) return error.UnknownOption;
        at = try std.fmt.parseInt(u32, argument["--at=".len..], 10);
    }
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    const insertion = try runtime.libraryPlaylistInsert(library, playlist_id, ids.items, at);
    try context.stdout.print("added={d} skipped={d}\n", .{ insertion.added, insertion.skipped });
}

fn removeFromPlaylist(context: Context) !void {
    const allocator = context.allocator;
    const playlist_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    var positions: std.ArrayList(u32) = .empty;
    defer positions.deinit(allocator);
    var walk = std.mem.splitScalar(u8, context.arguments[2], ',');
    while (walk.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " ");
        if (trimmed.len == 0) continue;
        try positions.append(allocator, try std.fmt.parseInt(u32, trimmed, 10));
    }
    if (positions.items.len == 0) return error.NoPositions;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    const removed = try runtime.libraryPlaylistRemove(library, playlist_id, positions.items);
    try context.stdout.print("removed={d}\n", .{removed});
}

fn moveInPlaylist(context: Context) !void {
    const allocator = context.allocator;
    const playlist_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const from = try std.fmt.parseInt(u32, context.arguments[2], 10);
    const to = try std.fmt.parseInt(u32, context.arguments[3], 10);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    try runtime.libraryPlaylistMove(library, playlist_id, from, to);
}

fn importPlaylist(context: Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout;
    var name: ?[]const u8 = null;
    for (context.arguments[2..]) |argument| {
        if (!std.mem.startsWith(u8, argument, "--name=")) return error.UnknownOption;
        name = argument["--name=".len..];
    }
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    const imported = try runtime.libraryImportPlaylist(library, context.io, context.arguments[1], name);
    defer imported.deinit();
    try stdout.print("playlist_id={d} matched_by_path={d} matched_by_info={d} unmatched={d}\n", .{
        imported.playlist_id,
        imported.matched_by_path,
        imported.matched_by_info,
        imported.unmatched,
    });
    for (imported.unmatched_lines) |line| try stdout.print("unmatched: {s}\n", .{line});
}

fn exportPlaylist(context: Context) !void {
    const allocator = context.allocator;
    const playlist_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    var options: liborca.PlaylistExportOptions = .{ .paths = .absolute, .replace = false };
    for (context.arguments[3..]) |argument| {
        if (std.mem.eql(u8, argument, "--relative")) {
            options.paths = .relative;
        } else if (std.mem.eql(u8, argument, "--force")) {
            options.replace = true;
        } else return error.UnknownOption;
    }
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    const exported = try runtime.libraryExportPlaylist(library, context.io, playlist_id, context.arguments[2], options);
    try context.stdout.print("written={d} skipped={d}\n", .{ exported.written, exported.skipped });
}

/// Names orca-cli to MusicBrainz, AcoustID and ListenBrainz and in the listen
/// history.
fn identifyOrca(runtime: *liborca.Runtime) !void {
    try runtime.setClientIdentity(.{
        .name = "Orca",
        .version = std.fmt.comptimePrint("{f}", .{liborca.version}),
        .contact = build_options.provider_contact,
    });
}

/// Sets the application key and any other AcoustID server, as `match` and
/// `submit-acoustid` both need.
fn configureAcoustId(allocator: std.mem.Allocator, runtime: *liborca.Runtime, environ: *std.process.Environ.Map) !void {
    try runtime.setAcoustIdClientKey(build_options.acoustid_key);
    if (environ.get("ORCA_ACOUSTID_URL")) |url| {
        if (url.len > 0) try runtime.setAcoustIdServer(try allocator.dupe(u8, url));
    }
}

fn matchLibrary(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const environ = context.environ;
    const stdout = context.stdout;
    const database_path_argument = context.arguments[0];
    const option_arguments = context.arguments[1..];
    const options = try parseJobOptions(option_arguments, &.{
        .batch,
        .limit,
        .no_fingerprints,
        .cancel_after,
        .release,
        .track,
        .accept_min_score,
        .cover_art,
        .reidentify,
    });
    var request: liborca.MatchRequest = .{
        .mode = if (options.reidentify) .reidentify else .search,
        .track_id = options.track_id,
        .release_id = options.release_id,
        .accept_minimum_confidence = options.accept_min_score,
        .cover_art = options.cover_art,
    };
    if (options.batch_size) |batch_size| request.batch_size = batch_size;
    if (options.limit) |limit| request.limit = limit;
    if (options.no_fingerprints) request.fingerprints = false;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    try identifyOrca(&runtime);
    if (environ.get("ORCA_MUSICBRAINZ_URL")) |url| {
        if (url.len > 0) try runtime.setMusicBrainzServer(try allocator.dupe(u8, url));
    }
    try configureAcoustId(allocator, &runtime, environ);
    try configureCoverArtArchive(allocator, &runtime, environ);
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    const job_handle = try runtime.startLibraryMatching(library, request);
    const planned = try runtime.jobSnapshotSynced(job_handle);
    try stdout.print("{d} tracks to match\n", .{planned.total_units orelse 0});
    try stdout.flush();
    const release_steps = request.accept_minimum_confidence != null or request.cover_art;
    awaitJob(&runtime, stdout, job_handle, options.cancel_after_ms) catch |err| {
        const stats = try runtime.jobMatchStats(job_handle);
        try printMatchStats(stdout, request.mode, stats);
        if (release_steps) try printReleaseSteps(stdout, stats);
        try stdout.flush();
        if (err != error.JobFailed) return err;
        if (coverArtError(stats.cover_art)) |cover_error| return cover_error;
        return switch (stats.busy) {
            .none => error.MatchingStopped,
            .musicbrainz => error.MusicBrainzInUse,
            .acoustid => error.AcoustIdInUse,
        };
    };
    const stats = try runtime.jobMatchStats(job_handle);
    try printMatchStats(stdout, request.mode, stats);
    if (release_steps) try printReleaseSteps(stdout, stats);
    if (try runtime.jobMatchRelease(job_handle)) |release_id| try stdout.print("release={d}\n", .{release_id});
    if (stats.cover_art == .no_release_id) try stdout.writeAll(no_release_id_hint);
}

const no_release_id_hint = "no release ID: review matches, then run cover-art\n";

fn configureCoverArtArchive(allocator: std.mem.Allocator, runtime: *liborca.Runtime, environ: *std.process.Environ.Map) !void {
    if (environ.get("ORCA_COVERARTARCHIVE_URL")) |url| {
        if (url.len > 0) try runtime.setCoverArtArchiveServer(try allocator.dupe(u8, url));
    }
}

fn configureLrclib(allocator: std.mem.Allocator, runtime: *liborca.Runtime, environ: *std.process.Environ.Map) !void {
    if (environ.get("ORCA_LRCLIB_URL")) |url| {
        if (url.len > 0) try runtime.setLrclibServer(try allocator.dupe(u8, url));
    }
}

fn printReleaseSteps(stdout: *std.Io.Writer, stats: liborca.MatchStats) !void {
    try stdout.print("accepted={d} cover_art={s}\n", .{ stats.accepted, coverArtSource(stats.cover_art) });
}

fn coverArtSource(outcome: liborca.CoverArtOutcome) []const u8 {
    return switch (outcome) {
        .not_requested => "not-requested",
        .embedded => "embedded",
        .fetched => "fetched",
        .cached => "cached",
        .cached_miss => "cached-miss",
        .not_found => "not-found",
        .no_release_id => "no-release-id",
        .refused => "refused",
        .unavailable => "unavailable",
        .busy => "busy",
        .cancelled => "cancelled",
        .folder => "folder",
        .chosen => "chosen",
        .partial => "partial",
    };
}

fn coverArtError(outcome: liborca.CoverArtOutcome) ?anyerror {
    return switch (outcome) {
        .refused => error.CoverArtRefused,
        .unavailable => error.CoverArtUnavailable,
        .busy => error.CoverArtArchiveInUse,
        .not_requested, .embedded, .fetched, .cached, .cached_miss, .not_found, .no_release_id, .cancelled, .folder, .chosen, .partial => null,
    };
}

const CoverArtCommand = union(enum) {
    front,
    candidates,
    use: struct { caa_id: i64, kind: liborca.ReleaseArtworkKind },

    fn parse(arguments: []const []const u8) !CoverArtCommand {
        if (arguments.len == 0) return .front;
        const argument = arguments[0];
        if (std.mem.eql(u8, argument, "--candidates")) return .candidates;
        if (!std.mem.startsWith(u8, argument, "--use=")) return error.UnknownOption;
        const value = argument["--use=".len..];
        const colon = std.mem.indexOfScalar(u8, value, ':');
        return .{ .use = .{
            .caa_id = try std.fmt.parseInt(i64, value[0 .. colon orelse value.len], 10),
            .kind = if (colon) |at| try parseArtworkKind(value[at + 1 ..]) else .front,
        } };
    }
};

fn parseArtworkKind(text: []const u8) !liborca.ReleaseArtworkKind {
    return std.meta.stringToEnum(liborca.ReleaseArtworkKind, text) orelse error.InvalidArtworkKind;
}

/// `orca-cli cover-art DATABASE RELEASE_ID [--candidates | --use=CAA_ID[:KIND]]`:
/// the Release's cover from the Cover Art Archive, through the job the GTK
/// app's Fetch Cover Art starts; or the archive's images for it, or one of
/// them used as its front, back or booklet cover.
fn fetchCoverArt(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const release_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const command = try CoverArtCommand.parse(context.arguments[2..]);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    try identifyOrca(&runtime);
    try configureCoverArtArchive(allocator, &runtime, context.environ);
    const library = try openBrowseLibrary(allocator, io, &runtime, context.arguments[0]);
    const job_handle = switch (command) {
        .front => try runtime.startReleaseCoverArtFetch(library, release_id),
        .candidates => try runtime.startCoverArtCandidates(library, release_id),
        .use => |use| try runtime.libraryUseCoverArtCandidate(library, release_id, use.caa_id, use.kind),
    };
    const failed = if (awaitJob(&runtime, stdout, job_handle, null)) false else |err| switch (err) {
        error.JobFailed => true,
        else => return err,
    };
    const stats = try runtime.jobMatchStats(job_handle);
    const outcome = stats.cover_art;
    switch (command) {
        .front => {
            const image = try runtime.libraryReleaseArtwork(library, io, release_id);
            defer if (image) |present| present.deinit();
            const bytes: usize = switch (outcome) {
                .embedded, .fetched, .cached, .folder, .chosen => if (image) |present| present.bytes.len else 0,
                else => 0,
            };
            try stdout.print("cover-art: source={s} bytes={d}\n", .{ coverArtSource(outcome), bytes });
        },
        .candidates => {
            const candidates = try runtime.libraryCoverArtCandidates(library, allocator, release_id);
            defer {
                for (candidates) |candidate| candidate.deinit(allocator);
                allocator.free(candidates);
            }
            for (candidates) |candidate| try printCoverArtCandidate(stdout, candidate);
            try stdout.print("cover-art: source={s} candidates={d} unmeasured={d}\n", .{
                coverArtSource(outcome),
                candidates.len,
                stats.cover_art_candidates_unmeasured,
            });
        },
        .use => |use| {
            const image = try runtime.libraryStoredReleaseArtwork(library, release_id, use.kind);
            defer if (image) |present| present.deinit();
            const bytes: usize = if (outcome == .fetched) if (image) |present| present.bytes.len else 0 else 0;
            const source = if (outcome == .fetched) "chosen" else coverArtSource(outcome);
            try stdout.print("cover-art: source={s} kind={t} bytes={d}\n", .{ source, use.kind, bytes });
        },
    }
    if (outcome == .no_release_id) try stdout.writeAll(no_release_id_hint);
    if (failed) {
        try stdout.flush();
        return coverArtError(outcome) orelse error.JobFailed;
    }
}

fn printCoverArtCandidate(stdout: *std.Io.Writer, candidate: liborca.CoverArtCandidate) !void {
    try stdout.print("candidate={d} kind={t} size=", .{ candidate.caa_id, candidate.kind });
    if (candidate.width != null and candidate.height != null)
        try stdout.print("{d}x{d}", .{ candidate.width.?, candidate.height.? })
    else
        try stdout.writeAll("-");
    try stdout.print(" mime={s} approved={s} thumbnail_bytes={d} release={s}\n", .{
        candidate.mime orelse "-",
        if (candidate.approved) "yes" else "no",
        if (candidate.thumbnail) |thumbnail| thumbnail.len else 0,
        &candidate.musicbrainz_release_id,
    });
}

fn configureArtistInfo(allocator: std.mem.Allocator, runtime: *liborca.Runtime, environ: *std.process.Environ.Map) !void {
    if (environ.get("ORCA_MUSICBRAINZ_URL")) |url| {
        if (url.len > 0) try runtime.setMusicBrainzServer(try allocator.dupe(u8, url));
    }
    if (environ.get("ORCA_WIKIDATA_URL")) |url| {
        if (url.len > 0) try runtime.setWikidataServer(try allocator.dupe(u8, url));
    }
    if (environ.get("ORCA_WIKIMEDIA_URL")) |url| {
        if (url.len > 0) try runtime.setWikimediaCommonsServer(try allocator.dupe(u8, url));
    }
    if (environ.get("ORCA_WIKIPEDIA_URL")) |url| {
        if (url.len > 0) try runtime.setWikipediaServer(try allocator.dupe(u8, url));
    }
    if (environ.get("ORCA_LISTENBRAINZ_URL")) |url| {
        if (url.len > 0) try runtime.setListenBrainzServer(try allocator.dupe(u8, url));
    }
    if (environ.get("ORCA_LISTENBRAINZ_LABS_URL")) |url| {
        if (url.len > 0) try runtime.setListenBrainzLabsServer(try allocator.dupe(u8, url));
    }
    try configureCoverArtArchive(allocator, runtime, environ);
}

/// `orca-cli artist-info DATABASE ARTIST_ID [--fetch]`: what an artist page
/// shows, fetched first on the job the GTK app starts.
fn showArtistInfo(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const artist_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    var fetch = false;
    var options: liborca.ArtistInfoOptions = .{};
    for (context.arguments[2..]) |argument| {
        if (std.mem.eql(u8, argument, "--fetch")) {
            fetch = true;
        } else if (std.mem.eql(u8, argument, "--force")) {
            options.force = true;
        } else if (std.mem.eql(u8, argument, "--offline")) {
            options.offline = true;
        } else if (std.mem.eql(u8, argument, "--include-releases")) {
            options.include_releases = true;
        } else if (std.mem.startsWith(u8, argument, "--lang=")) {
            options.language = argument["--lang=".len..];
        } else return error.UnknownOption;
    }
    if (!fetch and (options.force or options.offline or options.include_releases)) return error.UnknownOption;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    if (fetch) {
        try identifyOrca(&runtime);
        try configureArtistInfo(allocator, &runtime, context.environ);
    }
    const library = try openBrowseLibrary(allocator, io, &runtime, context.arguments[0]);
    var outcome: ?liborca.ArtistInfoOutcome = null;
    if (fetch) {
        const job_handle = try runtime.startArtistInfoFetch(library, artist_id, options);
        try awaitArtistInfo(&runtime, io, stdout, job_handle);
        outcome = try runtime.jobArtistInfoOutcome(job_handle);
    }
    if (try runtime.libraryArtistTotals(library, artist_id)) |totals| try stdout.print(
        "totals releases={d} tracks={d} duration_ms={d} appearances={d}\n",
        .{ totals.release_count, totals.track_count, totals.duration_ms, totals.appearance_count },
    );
    var info = (try runtime.libraryArtistInfo(library, artist_id)) orelse {
        try stdout.print("artist-info: outcome={s}\n", .{if (outcome) |known| @tagName(known) else "none"});
        return;
    };
    defer info.deinit();
    const record = &info.record;
    if (record.photo_source) |source| {
        const photo = try runtime.libraryArtistPhoto(library, artist_id);
        defer if (photo) |image| image.deinit();
        try stdout.print("photo={s} bytes={d}", .{ @tagName(source), if (photo) |image| image.bytes.len else 0 });
        if (record.photo_licence) |licence| try stdout.print(" licence=\"{s}\"", .{licence});
        if (record.photo_credit) |credit| try stdout.print(" credit=\"{s}\"", .{credit});
        try stdout.writeAll("\n");
        if (record.photo_url) |url| try stdout.print("photo-url={s}\n", .{url});
        if (record.photo_licence_url) |url| try stdout.print("photo-licence-url={s}\n", .{url});
    } else try stdout.writeAll("photo=none\n");
    if (record.biography_source) |source| {
        try stdout.print("biography={s} url={s} language={s} licence=\"{s}\"\n", .{
            @tagName(source),
            record.biography_url orelse "-",
            record.biography_language orelse "-",
            record.biography_licence orelse "",
        });
    } else try stdout.writeAll("biography=none\n");
    if (record.begin_year) |begin| {
        try stdout.print("years={d}\u{2013}", .{begin});
        if (record.end_year) |end|
            try stdout.print("{d}\n", .{end})
        else
            try stdout.writeAll(if (record.ended) "?\n" else "present\n");
    }
    if (record.artist_type) |kind| try stdout.print("type={s}\n", .{kind});
    if (record.origin) |origin| try stdout.print("origin={s}\n", .{origin});
    if (record.musicbrainz_artist_id) |id| try stdout.print("musicbrainz={s}\n", .{id});
    if (record.wikidata_id) |id| try stdout.print("wikidata={s}\n", .{id});
    var links = try runtime.libraryArtistLinks(library, artist_id);
    defer links.deinit();
    try stdout.print("links: {d}\n", .{links.items.len});
    for (links.items) |link| try stdout.print("{s}\t{s}\n", .{ @tagName(link.kind), link.url });
    if (record.listeners) |count| try stdout.print("listeners={d} (ListenBrainz)\n", .{count});
    try writeRelatedArtists(&runtime, stdout, library, artist_id);
    if (options.include_releases) {
        const elsewhere = try runtime.libraryArtistElsewhere(library, allocator, artist_id);
        defer {
            for (elsewhere) |group| group.deinit(allocator);
            allocator.free(elsewhere);
        }
        for (elsewhere) |group| {
            try stdout.print("elsewhere: {s}\t{s}\t", .{ group.mbid, group.title });
            if (group.year) |year| try stdout.print("{d}", .{year}) else try stdout.writeAll("-");
            try stdout.print("\t{s}", .{group.primary_type orelse "-"});
            try stdout.print("\tcover={s}", .{switch (group.cover) {
                .kept => "yes",
                .none => "no",
                .not_fetched => "-",
            }});
            if (group.credited_with) |names| try stdout.print("\twith {s}", .{names});
            try stdout.writeAll("\n");
        }
    }
    if (record.biography) |text| try stdout.print("{s}\n", .{text});
    const reported: liborca.ArtistInfoOutcome = outcome orelse
        std.enums.fromInt(liborca.ArtistInfoOutcome, record.outcome) orelse .not_requested;
    try stdout.print("outcome={s}\n", .{@tagName(reported)});
}

fn writeRelatedArtists(runtime: *liborca.Runtime, stdout: *std.Io.Writer, library: liborca.LibraryHandle, artist_id: i64) !void {
    var related = try runtime.libraryRelatedArtists(library, artist_id);
    defer related.deinit();
    try stdout.print("related: {d}\n", .{related.items.len});
    for (related.items) |artist| {
        try stdout.print("{d}\t{s}\t{s}\t", .{ artist.score, artist.name, artist.mbid });
        if (artist.library_artist_id) |id| try stdout.print("library={d}", .{id}) else try stdout.writeAll("library=-");
        try stdout.print("\tphoto={s}\n", .{if (artist.has_photo) "yes" else "no"});
    }
}

/// `orca-cli related DATABASE ARTIST_ID`
fn showRelatedArtists(context: Context) !void {
    const artist_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    try writeRelatedArtists(&runtime, context.stdout, library, artist_id);
}

/// `orca-cli release-info DATABASE RELEASE_ID [--fetch]`
fn showReleaseInfo(context: Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout;
    const release_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    var fetch = false;
    var options: liborca.ReleaseInfoOptions = .{};
    for (context.arguments[2..]) |argument| {
        if (std.mem.eql(u8, argument, "--fetch")) {
            fetch = true;
        } else if (std.mem.eql(u8, argument, "--force")) {
            options.force = true;
        } else if (std.mem.eql(u8, argument, "--offline")) {
            options.offline = true;
        } else if (std.mem.startsWith(u8, argument, "--lang=")) {
            options.language = argument["--lang=".len..];
        } else return error.UnknownOption;
    }
    if (!fetch and (options.force or options.offline)) return error.UnknownOption;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    if (fetch) {
        try identifyOrca(&runtime);
        try configureArtistInfo(allocator, &runtime, context.environ);
    }
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    var outcome: ?liborca.ReleaseInfoOutcome = null;
    if (fetch) {
        const job_handle = try runtime.startReleaseInfoFetch(library, release_id, options);
        try awaitJob(&runtime, stdout, job_handle, null);
        outcome = try runtime.jobReleaseInfoOutcome(job_handle);
    }
    var info = (try runtime.libraryReleaseInfo(library, release_id)) orelse {
        try stdout.print("release-info: outcome={s}\n", .{if (outcome) |known| @tagName(known) else "none"});
        return;
    };
    defer info.deinit();
    const record = &info.record;
    if (record.description_source) |source| {
        try stdout.print("description={s} url={s} language={s} licence=\"{s}\"\n", .{
            @tagName(source),
            record.description_url orelse "-",
            record.description_language orelse "-",
            record.description_licence orelse "",
        });
    } else try stdout.writeAll("description=none\n");
    if (record.musicbrainz_release_id) |id| try stdout.print("musicbrainz={s}\n", .{id});
    if (record.musicbrainz_release_group_id) |id| try stdout.print("release-group={s}\n", .{id});
    if (record.description) |text| try stdout.print("{s}\n", .{text});
    const reported: liborca.ReleaseInfoOutcome = outcome orelse
        std.enums.fromInt(liborca.ReleaseInfoOutcome, record.outcome) orelse .not_requested;
    try stdout.print("outcome={s}\n", .{@tagName(reported)});
}

/// `orca-cli genre-fill DATABASE [on|off]`
fn genreFill(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    if (context.arguments.len == 2) {
        const value = context.arguments[1];
        const musicbrainz = if (std.mem.eql(u8, value, "on")) true else if (std.mem.eql(u8, value, "off")) false else return error.UnknownOption;
        try runtime.setGenreFill(library, .{ .musicbrainz = musicbrainz });
    }
    const fill = try runtime.libraryGenreFill(library);
    try context.stdout.print("genre-fill: musicbrainz={s} licence=\"{s}\"\n", .{
        if (fill.musicbrainz) "on" else "off",
        liborca.musicbrainz_genre_licence,
    });
}

/// `orca-cli genres DATABASE --fill-from-musicbrainz [--limit N] [--offline]`
fn fillGenres(context: Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout;
    var options: liborca.GenreFillOptions = .{};
    var index: usize = 1;
    while (index < context.arguments.len) : (index += 1) {
        const argument = context.arguments[index];
        if (std.mem.eql(u8, argument, "--fill-from-musicbrainz")) continue;
        if (std.mem.eql(u8, argument, "--offline")) {
            options.offline = true;
        } else if (std.mem.eql(u8, argument, "--limit")) {
            index += 1;
            if (index == context.arguments.len) return error.MissingOptionValue;
            options.limit = try std.fmt.parseInt(u32, context.arguments[index], 10);
        } else return error.UnknownOption;
    }
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    try identifyOrca(&runtime);
    try configureArtistInfo(allocator, &runtime, context.environ);
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    const job_handle = try runtime.startGenreFill(library, options);
    try awaitJob(&runtime, stdout, job_handle, null);
    const snapshot = try runtime.jobSnapshotSynced(job_handle);
    try stdout.print("genre-fill: releases={d} outcome={s}\n", .{
        snapshot.completed_units,
        @tagName(try runtime.jobReleaseInfoOutcome(job_handle)),
    });
}

/// `orca-cli artist-photo DATABASE ARTIST_ID --out=PATH`
fn saveArtistPhoto(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const artist_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const argument = context.arguments[2];
    if (!std.mem.startsWith(u8, argument, "--out=")) return error.UnknownOption;
    const path = argument["--out=".len..];
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, context.arguments[0]);
    const photo = (try runtime.libraryArtistPhoto(library, artist_id)) orelse return error.NoArtistPhoto;
    defer photo.deinit();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = photo.bytes });
    try context.stdout.print("{s}\t{d} bytes\twrote {s}\n", .{ photo.mime_type, photo.bytes.len, path });
}

/// `orca-cli related-photo DATABASE MBID --out=PATH`: the photo an
/// `artist-info --fetch` kept for a related artist outside the Library.
fn saveRelatedArtistPhoto(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const argument = context.arguments[2];
    if (!std.mem.startsWith(u8, argument, "--out=")) return error.UnknownOption;
    const path = argument["--out=".len..];
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, context.arguments[0]);
    const photo = (try runtime.libraryRelatedArtistPhoto(library, context.arguments[1])) orelse return error.NoArtistPhoto;
    defer photo.deinit();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = photo.bytes });
    const stdout = context.stdout;
    try stdout.print("{s}\t{d} bytes\twrote {s}\n", .{ photo.mime_type, photo.bytes.len, path });
    var info = (try runtime.libraryRelatedArtistPhotoInfo(library, context.arguments[1])) orelse return;
    defer info.deinit();
    const record = &info.record;
    try stdout.print("source={s}\n", .{@tagName(record.source)});
    if (record.licence) |licence| try stdout.print("licence=\"{s}\"\n", .{licence});
    if (record.credit) |credit| try stdout.print("credit=\"{s}\"\n", .{credit});
    if (record.url) |url| try stdout.print("photo-url={s}\n", .{url});
    if (record.licence_url) |url| try stdout.print("photo-licence-url={s}\n", .{url});
}

/// `orca-cli release-group-cover DATABASE MBID --out=PATH`: the cover an
/// `artist-info --fetch --include-releases` kept for a release group.
fn saveReleaseGroupCover(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const mbid = context.arguments[1];
    if (!liborca.isMusicBrainzId(mbid)) return error.InvalidMusicBrainzId;
    const argument = context.arguments[2];
    if (!std.mem.startsWith(u8, argument, "--out=")) return error.UnknownOption;
    const path = argument["--out=".len..];
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, context.arguments[0]);
    _ = try runtime.libraryRequestArtwork(library, io, .{ .release_group = mbid[0..36].* });
    const result = while (true) {
        if (runtime.libraryTakeArtwork(library)) |result| break result;
        sleepMilliseconds(1);
    };
    const image = result.image orelse return error.NoReleaseGroupCover;
    defer image.deinit();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = image.bytes });
    try context.stdout.print("source=coverartarchive\t{s}\t{d} bytes\twrote {s}\n", .{ image.mime_type, image.bytes.len, path });
}

/// `orca-cli lyrics DATABASE TRACK_ID`: the Track's lyrics, read on a job.
fn showLyrics(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const track_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const options = try parseJobOptions(context.arguments[2..], &.{.fetch});
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    if (options.fetch) {
        try identifyOrca(&runtime);
        try configureLrclib(allocator, &runtime, context.environ);
    }
    const library = try openBrowseLibrary(allocator, io, &runtime, context.arguments[0]);
    const job_handle = try runtime.startTrackLyrics(library, track_id, .{ .fetch = options.fetch });
    try awaitJob(&runtime, stdout, job_handle, null);
    const outcome = try runtime.jobLyricsOutcome(job_handle);
    const lyrics = (try runtime.jobTakeLyrics(job_handle)) orelse {
        try stdout.print("lyrics: outcome={s}\n", .{@tagName(outcome)});
        return;
    };
    defer lyrics.deinit();
    try stdout.print("lyrics: source={s} kind={s} lines={d} outcome={s} source_name={s} offset_ms={d}\n", .{
        @tagName(lyrics.source),
        @tagName(lyrics.kind),
        lyrics.lines.len,
        @tagName(outcome),
        lyrics.source_name orelse "-",
        lyrics.offset_ms,
    });
    for (lyrics.lines) |line| {
        if (line.start_ms) |start| {
            const centiseconds: u64 = start / 10;
            try stdout.print("[{d:0>2}:{d:0>2}.{d:0>2}] ", .{ centiseconds / 6000, centiseconds / 100 % 60, centiseconds % 100 });
        }
        try stdout.print("{s}\n", .{line.text});
    }
}

fn printMatchStats(stdout: *std.Io.Writer, mode: liborca.MatchMode, stats: liborca.MatchStats) !void {
    try stdout.print(
        "examined={d} matched={d} unmatched={d} no_title_or_artist={d} refused={d} matches={d}",
        .{ stats.tracks_examined, stats.matched, stats.unmatched, stats.insufficient_evidence, stats.refused, stats.proposals_stored },
    );
    switch (mode) {
        .search, .verify => {},
        .reidentify => try stdout.print(" confirmed={d}", .{stats.confirmed}),
    }
    try stdout.writeAll("\n");
    try printServiceStats(stdout, stats);
}

fn printServiceStats(stdout: *std.Io.Writer, stats: liborca.MatchStats) !void {
    try stdout.print("requests={d} cached={d}\n", .{ stats.requests, stats.cache_hits });
    try stdout.print(
        "acoustid={s} fingerprinted={d} fingerprints_cached={d} fingerprint_failures={d} acoustid_requests={d} acoustid_cached={d} acoustid_refused={d}\n",
        .{
            @tagName(stats.acoustid),
            stats.fingerprinted,
            stats.fingerprint_cache_hits,
            stats.fingerprint_failures,
            stats.acoustid_requests,
            stats.acoustid_cache_hits,
            stats.acoustid_refused,
        },
    );
}

/// `orca-cli verify DATABASE`: checks each identified file's recording ID
/// against AcoustID through the job the GTK app's verification starts.
fn verifyLibrary(context: Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout;
    const options = try parseJobOptions(context.arguments[1..], &.{ .batch, .limit, .cancel_after, .release, .track });
    var request: liborca.MatchRequest = .{
        .mode = .verify,
        .track_id = options.track_id,
        .release_id = options.release_id,
    };
    if (options.batch_size) |batch_size| request.batch_size = batch_size;
    if (options.limit) |limit| request.limit = limit;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    try identifyOrca(&runtime);
    if (context.environ.get("ORCA_MUSICBRAINZ_URL")) |url| {
        if (url.len > 0) try runtime.setMusicBrainzServer(try allocator.dupe(u8, url));
    }
    try configureAcoustId(allocator, &runtime, context.environ);
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    const job_handle = try runtime.startLibraryMatching(library, request);
    const planned = try runtime.jobSnapshotSynced(job_handle);
    try stdout.print("{d} tracks to verify\n", .{planned.total_units orelse 0});
    try stdout.flush();
    const failed = if (awaitJob(&runtime, stdout, job_handle, options.cancel_after_ms)) false else |err| switch (err) {
        error.JobFailed => true,
        else => return err,
    };
    const stats = try runtime.jobMatchStats(job_handle);
    try stdout.print(
        "verified={d} agreed={d} disagreed={d} unconfirmed={d} skipped={d} correction_groups={d} proposals={d}\n",
        .{ stats.verified, stats.agreed, stats.disagreed, stats.unconfirmed, stats.skipped, stats.correction_groups, stats.proposals_stored },
    );
    try printServiceStats(stdout, stats);
    if (!failed) return;
    try stdout.flush();
    return switch (stats.acoustid) {
        .no_client_key, .off => error.AcoustIdRequired,
        .invalid_client_key => error.InvalidAcoustIdClientKey,
        .searched => switch (stats.busy) {
            .none => error.VerificationStopped,
            .musicbrainz => error.MusicBrainzInUse,
            .acoustid => error.AcoustIdInUse,
        },
    };
}

/// One line per album group: its id, album and album artist; then one line
/// per correction: Track id, the Track as it is, and as the correction makes
/// it, with its recording ID and the one it replaces.
fn listCorrections(context: Context) !void {
    const stdout = context.stdout;
    const options = try parseBrowseOptions(context.arguments[1..]);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const page = try runtime.libraryCorrectionGroups(library, context.allocator, options.limit, options.offset);
    defer page.deinit();
    for (page.items) |group| {
        try stdout.print("{d}\t{s}\t{s}\n", .{ group.group_id, group.album, group.album_artist });
        for (group.proposals) |member| {
            try stdout.writeAll("\t");
            if (member.track_id) |track_id| try stdout.print("{d}", .{track_id}) else try stdout.writeAll("-");
            try stdout.print("\tcurrent \"{s}\" (", .{member.title});
            try writePosition(stdout, member.disc_number, member.track_number);
            try stdout.print(") -> proposed \"{s}\" (", .{member.proposed_title});
            try writePosition(stdout, member.proposed_disc_number, member.proposed_track_number);
            try stdout.print(")\t{s}\t{s}\n", .{ member.recording_mbid, member.corrects orelse "-" });
        }
    }
}

fn writePosition(stdout: *std.Io.Writer, disc: anytype, track: anytype) !void {
    if (disc) |number| try stdout.print("{d}-", .{number});
    if (track) |number| try stdout.print("{d}", .{number}) else try stdout.writeAll("-");
}

fn acceptCorrection(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const group_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const acceptance = try runtime.libraryAcceptCorrectionGroup(library, group_id);
    try context.stdout.print("accepted correction group {d}: accepted={d} values_written={d}\n", .{ group_id, acceptance.accepted, acceptance.values_written });
}

fn dismissCorrection(context: Context) !void {
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const group_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    try runtime.libraryDismissCorrectionGroup(library, group_id);
    try context.stdout.print("dismissed correction group {d}\n", .{group_id});
}

fn printFingerprint(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const database_path_argument = context.arguments[0];
    const id_argument = context.arguments[1];
    const track_id = try std.fmt.parseInt(i64, id_argument, 10);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    const outcome = try runtime.libraryTrackFingerprint(library, io, track_id) orelse return error.NoPresentFile;
    defer outcome.fingerprint.deinit();
    try stdout.print("DURATION={d}\nFINGERPRINT={s}\n", .{ outcome.fingerprint.durationSeconds(), outcome.fingerprint.encoded });
}

fn showAudioFeatures(context: Context) !void {
    const stdout = context.stdout;
    const track_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const features = try runtime.libraryTrackAudioFeatures(library, track_id) orelse return error.NotAnalyzed;
    const pitch_names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
    if (features.tempo) |tempo|
        try printDetail(stdout, "tempo", "{d:.1} bpm confidence={d:.2}", .{ tempo.bpm, tempo.confidence })
    else
        try printDetail(stdout, "tempo", "{s}", .{"-"});
    if (features.key) |key|
        try printDetail(stdout, "key", "{s} {t} confidence={d:.2}", .{ pitch_names[key.pitch], key.mode, key.confidence })
    else
        try printDetail(stdout, "key", "{s}", .{"-"});
    try printOptionalDetail(stdout, "onset rate", "{d:.2} /s", features.onset_rate);
    try printOptionalDetail(stdout, "centroid", "{d:.0} Hz", features.centroid_hz);
    try printOptionalDetail(stdout, "energy", "{d:.2}", features.energy);
}

fn previewRadio(context: Context) !void {
    const stdout = context.stdout;
    var seed: ?liborca.RadioSeed = null;
    var options: liborca.RadioOptions = .{};
    var limit: usize = 25;
    var explain = false;
    var index: usize = 1;
    while (index < context.arguments.len) : (index += 1) {
        const argument = context.arguments[index];
        if (std.mem.eql(u8, argument, "--loved")) {
            if (seed != null) return error.InvalidArguments;
            seed = .loved;
        } else if (std.mem.eql(u8, argument, "--explain")) {
            explain = true;
        } else {
            index += 1;
            if (index == context.arguments.len) return error.MissingOptionValue;
            const value = context.arguments[index];
            if (std.mem.eql(u8, argument, "--explore")) {
                options.explore = try std.fmt.parseInt(u8, value, 10);
            } else if (std.mem.eql(u8, argument, "--limit")) {
                limit = try std.fmt.parseInt(usize, value, 10);
            } else {
                if (seed != null) return error.InvalidArguments;
                const id = try std.fmt.parseInt(i64, value, 10);
                seed = if (std.mem.eql(u8, argument, "--track"))
                    .{ .track = id }
                else if (std.mem.eql(u8, argument, "--release"))
                    .{ .release = id }
                else if (std.mem.eql(u8, argument, "--artist"))
                    .{ .artist = id }
                else if (std.mem.eql(u8, argument, "--genre"))
                    .{ .genre = id }
                else if (std.mem.eql(u8, argument, "--decade"))
                    .{ .decade = id }
                else
                    return error.UnknownOption;
            }
        }
    }
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    var picks = try runtime.libraryRadioPreview(library, context.allocator, seed orelse return error.InvalidArguments, options, limit, .{});
    defer picks.deinit();

    var summaries: std.ArrayList(liborca.TrackSummary) = .empty;
    defer {
        for (summaries.items) |summary| summary.deinit(runtime.allocator);
        summaries.deinit(context.allocator);
    }
    for (picks.items) |pick| {
        const summary = (try runtime.libraryTrackSummary(library, pick.track_id)) orelse continue;
        try summaries.append(context.allocator, summary);
    }

    if (explain) {
        const w = picks.weights;
        try stdout.print("weights artist={d:.3} genre={d:.3} audio={d:.3} co_listening={d:.3} era={d:.3} taste={d:.3} jitter={d:.3}\n", .{
            w.artist, w.genre, w.audio, w.co_listening, w.era, w.taste, w.jitter,
        });
    }
    if (picks.relaxed_recent) try stdout.writeAll("recent plays let back in: nothing else qualified\n");
    for (picks.items, 0..) |pick, rank| {
        const summary: ?liborca.TrackSummary = for (summaries.items) |summary| {
            if (summary.id == pick.track_id) break summary;
        } else null;
        try stdout.print("{d}\t{d}\t{s} - {s}\t", .{
            rank + 1,
            pick.track_id,
            if (summary) |found| found.artist else "",
            if (summary) |found| found.title else "",
        });
        var written = false;
        for ([_]?liborca.ReasonPart{ pick.reason.first, pick.reason.second }) |maybe| {
            const part = maybe orelse continue;
            if (written) try stdout.writeAll("; ");
            written = true;
            try writeRadioReason(stdout, &runtime, library, part);
        }
        try stdout.writeAll("\n");
        if (explain) {
            const c = pick.components;
            try stdout.print("\tscore={d:.3} artist={d:.2} genre={d:.2} audio={d:.2} co_listening={d:.2} era={d:.2} taste={d:.2} jitter={d:.2}\n", .{
                pick.score, c.artist, c.genre, c.audio, c.co_listening, c.era, c.taste, c.jitter,
            });
        }
    }
}

/// `orca-cli mixes DATABASE [--refresh] [--mix N]`: makes the day's Daily
/// Mixes in UTC unless they are from this mix day, or always with
/// `--refresh`, then lists them, or the entries of the Nth with `--mix N`.
fn showDailyMixes(context: Context) !void {
    const stdout = context.stdout;
    var force = false;
    var shown: ?usize = null;
    var index: usize = 1;
    while (index < context.arguments.len) : (index += 1) {
        const argument = context.arguments[index];
        if (std.mem.eql(u8, argument, "--refresh")) {
            force = true;
        } else if (std.mem.eql(u8, argument, "--mix")) {
            index += 1;
            if (index == context.arguments.len) return error.MissingOptionValue;
            shown = try std.fmt.parseInt(usize, context.arguments[index], 10);
        } else return error.UnknownOption;
    }
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const now_s = std.Io.Clock.real.now(context.io).toSeconds();
    const job_handle = try runtime.startDailyMixes(library, .{ .now_s = now_s, .force = force });
    try awaitJob(&runtime, stdout, job_handle, null);
    const mixes = try runtime.libraryDailyMixes(library, now_s, 0);

    if (shown) |number| {
        if (number == 0 or number > mixes.count) return error.UnknownDailyMix;
        const mix = &mixes.items()[number - 1];
        try stdout.print("{s}\n", .{mix.name()});
        var entries: [liborca.max_daily_mix_entries]liborca.DailyMixEntry = undefined;
        const count = try runtime.libraryDailyMixEntries(library, mix.id, &entries);
        for (entries[0..count], 0..) |entry, position| {
            const summary = try runtime.libraryTrackSummary(library, entry.track_id);
            defer if (summary) |found| found.deinit(runtime.allocator);
            try stdout.print("{d}\t{d}\t{s} - {s}\t", .{
                position + 1,
                entry.track_id,
                if (summary) |found| found.artist else "",
                if (summary) |found| found.title else "",
            });
            var written = false;
            for ([_]?liborca.ReasonPart{ entry.reason.first, entry.reason.second }) |maybe| {
                const part = maybe orelse continue;
                if (written) try stdout.writeAll("; ");
                written = true;
                try writeRadioReason(stdout, &runtime, library, part);
            }
            try stdout.writeAll("\n");
        }
        return;
    }

    try stdout.print("state: {t}", .{mixes.state});
    if (mixes.generated_at) |generated_at| {
        try stdout.writeAll(", made ");
        try writeIsoUtc(stdout, generated_at);
    }
    try stdout.writeAll("\n");
    for (mixes.items(), 1..) |*mix, number| {
        try stdout.print("{d}\t{s}\t{d} tracks\t{d} min\t", .{ number, mix.name(), mix.entry_count, mix.duration_ms / 60_000 });
        for (mix.mixArtists(), 0..) |*artist, artist_index| {
            if (artist_index != 0) try stdout.writeAll(", ");
            try stdout.writeAll(artist.name());
        }
        try stdout.print("\n\tfavorites={d} rarely played={d} never played={d}\n", .{ mix.makeup.favorite, mix.makeup.rarely_played, mix.makeup.never_played });
        const left_out = mix.left_out;
        try stdout.print("\tleft out: recent={d} not for me={d} hated={d} live={d} other mix={d} spacing={d}\n", .{
            left_out.recent, left_out.not_for_me, left_out.hated, left_out.live, left_out.other_mix, left_out.diversity,
        });
    }
}

fn writeRadioReason(
    stdout: *std.Io.Writer,
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    part: liborca.ReasonPart,
) !void {
    switch (part.kind) {
        .played => {
            try stdout.print("Played {d} times, last ", .{part.a});
            try writeIsoUtc(stdout, part.b);
        },
        .loved => try stdout.writeAll("Loved"),
        .same_artist => try writeArtistReason(stdout, runtime, library, "By ", part.a),
        .related_artist => {
            try writeArtistReason(stdout, runtime, library, "Related to ", part.a);
            try stdout.writeAll(" (ListenBrainz)");
        },
        .shared_genre => {
            const genre = try runtime.libraryGenre(library, part.a);
            defer if (genre) |found| found.deinit(runtime.allocator);
            try stdout.print("Also tagged {s}", .{if (genre) |found| found.name else "a shared genre"});
        },
        .often_after => if (part.b == 1)
            try writeArtistReason(stdout, runtime, library, "Often played after ", part.a)
        else
            try writeRecordingReason(stdout, runtime, library, "Often played after ", part.a),
        .similar_sound => {
            try stdout.writeAll("Similar");
            const sounds = [_]struct { i64, []const u8 }{
                .{ liborca.radio_sound_tempo, "tempo" },
                .{ liborca.radio_sound_key, "key" },
                .{ liborca.radio_sound_energy, "energy" },
            };
            const total = @popCount(part.a & 7);
            var count: usize = 0;
            for (sounds) |sound| {
                if (part.a & sound[0] == 0) continue;
                count += 1;
                const separator = if (count == 1) " " else if (count == total) " and " else ", ";
                try stdout.print("{s}{s}", .{ separator, sound[1] });
            }
        },
        .never_played => try stdout.writeAll("Never played"),
        .rarely_played => try stdout.print("Rarely played ({d} {s})", .{ part.a, if (part.a == 1) "play" else "plays" }),
        .added => {
            try stdout.writeAll("Added ");
            try writeIsoUtc(stdout, part.a);
        },
    }
}

fn writeRecordingReason(
    stdout: *std.Io.Writer,
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    comptime prefix: []const u8,
    recording_id: i64,
) !void {
    const recording = try runtime.libraryRecordingSummary(library, recording_id);
    defer if (recording) |found| found.deinit(runtime.allocator);
    const found = recording orelse return stdout.writeAll(prefix ++ "a Recording");
    if (found.artist.len == 0) return stdout.print(prefix ++ "{s}", .{found.title});
    try stdout.print(prefix ++ "{s} - {s}", .{ found.artist, found.title });
}

fn writeArtistReason(
    stdout: *std.Io.Writer,
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    comptime prefix: []const u8,
    artist_id: i64,
) !void {
    const artist = try runtime.libraryArtist(library, artist_id);
    defer if (artist) |found| found.deinit(runtime.allocator);
    try stdout.print(prefix ++ "{s}", .{if (artist) |found| found.name else "an Artist"});
}

fn submitAcoustId(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const environ = context.environ;
    const stdout = context.stdout;
    const database_path_argument = context.arguments[0];
    const option_arguments = context.arguments[1..];
    const options = try parseJobOptions(option_arguments, &.{.dry_run});
    var credentials: EnvironmentCredentials = try .init(allocator, environ);
    defer credentials.deinit(allocator);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    try identifyOrca(&runtime);
    try runtime.setCredentialStore(credentials.store());
    try configureAcoustId(allocator, &runtime, environ);
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    try stdout.print("{d} files to submit\n", .{try runtime.libraryAcoustIdSubmittableCount(library)});
    if (options.dry_run) {
        try stdout.print("submitted_total={d}\n", .{try runtime.libraryAcoustIdSubmittedCount(library)});
        return listSubmittable(&runtime, library, stdout);
    }
    try stdout.flush();

    const job_handle = try runtime.startAcoustIdSubmission(library);
    awaitJob(&runtime, stdout, job_handle, null) catch |err| if (err != error.JobFailed) return err;
    const stats = try runtime.jobSubmissionStats(job_handle);
    try stdout.print(
        "outcome={s} examined={d} submitted={d} as_metadata={d} fingerprinted={d} fingerprints_cached={d} fingerprint_failures={d} rejected={d} requests={d}\n",
        .{
            @tagName(stats.outcome),
            stats.files_examined,
            stats.submitted,
            stats.sent_as_metadata,
            stats.fingerprinted,
            stats.fingerprint_cache_hits,
            stats.fingerprint_failures,
            stats.rejected,
            stats.requests,
        },
    );
    try stdout.print("submitted_total={d}\n", .{try runtime.libraryAcoustIdSubmittedCount(library)});
    try stdout.flush();
    return switch (stats.outcome) {
        .completed, .cancelled => {},
        .needs_user_key => error.NeedsAcoustIdUserKey,
        .invalid_user_key => error.InvalidAcoustIdUserKey,
        .credential_unavailable => error.AcoustIdUserKeyUnreadable,
        .needs_client_key, .invalid_client_key => error.InvalidAcoustIdClientKey,
        .unavailable => error.SubmissionStopped,
        .busy => error.AcoustIdInUse,
    };
}

/// One line per file: file id, Track id, what is sent (the recording ID, or
/// `metadata`), recording ID, title and artist.
fn listSubmittable(runtime: *liborca.Runtime, library: liborca.LibraryHandle, stdout: *std.Io.Writer) !void {
    var cursor: i64 = 0;
    while (true) {
        const page = try runtime.libraryAcoustIdSubmittablePage(library, cursor, 512);
        defer page.deinit();
        if (page.items.len == 0) return;
        for (page.items) |item| {
            cursor = item.file_id;
            const length: ?u64 = if (item.duration_ms) |milliseconds| std.math.cast(u64, milliseconds) else null;
            try stdout.print("{d}\t{d}\t{s}\t{s}\t{s}\t{s}\n", .{
                item.file_id,
                item.track_id,
                if (item.sendsRecordingId(length)) "recording_id" else "metadata",
                item.recording_mbid,
                item.title,
                item.artist,
            });
        }
    }
}

fn listMatches(context: Context) !void {
    const mode = context.arguments[1];
    if (std.mem.eql(u8, mode, "--releases")) return listReleaseMatches(context);
    if (std.mem.startsWith(u8, mode, "--release=")) return reviewReleaseMatch(context);
    if (context.arguments.len != 2) return error.UnknownOption;
    return listTrackMatches(context);
}

const default_confident_at: f32 = 0.9;

fn listReleaseMatches(context: Context) !void {
    const stdout = context.stdout;
    var bucket: ?liborca.ReleaseMatchBucket = null;
    var confident_at = default_confident_at;
    var filter: ?[]const u8 = null;
    var limit: u32 = 512;
    var offset: u32 = 0;
    for (context.arguments[2..]) |argument| {
        if (std.mem.startsWith(u8, argument, "--bucket=")) {
            bucket = std.meta.stringToEnum(liborca.ReleaseMatchBucket, argument["--bucket=".len..]) orelse return error.UnknownOption;
        } else if (std.mem.startsWith(u8, argument, "--min-score=")) {
            confident_at = try std.fmt.parseFloat(f32, argument["--min-score=".len..]);
        } else if (std.mem.startsWith(u8, argument, "--filter=")) {
            filter = argument["--filter=".len..];
        } else if (std.mem.startsWith(u8, argument, "--limit=")) {
            limit = try std.fmt.parseInt(u32, argument["--limit=".len..], 10);
        } else if (std.mem.startsWith(u8, argument, "--offset=")) {
            offset = try std.fmt.parseInt(u32, argument["--offset=".len..], 10);
        } else return error.UnknownOption;
    }
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const buckets: []const liborca.ReleaseMatchBucket = if (bucket) |one| &.{one} else &.{ .confident, .needs_review, .unmatched };
    for (buckets) |each| {
        const page = try runtime.libraryReleaseMatchPage(library, context.allocator, each, confident_at, filter, limit, offset);
        defer page.deinit();
        for (page.items) |item| {
            try stdout.print("{d}\t{s}\t{s}\t{s}\ttracks={d}", .{ item.release_id, @tagName(item.bucket), item.title, item.artist, item.track_count });
            if (item.best) |best| {
                try stdout.print("\tcandidate={s} confidence=", .{best.release_mbid});
                if (best.confidence) |confidence| try stdout.print("{d:.2}", .{confidence}) else try stdout.writeAll("unread");
                try stdout.print(" title={s} date={s} candidate_tracks=", .{ best.title, best.date orelse "-" });
                if (best.track_count) |count| try stdout.print("{d}", .{count}) else try stdout.writeAll("-");
            } else try stdout.writeAll("\tcandidate=-");
            if (item.placement) |placement| {
                try stdout.print("\tplaced={d} needs_pairing={d}", .{ placement.placed, placement.needs_pairing });
            } else try stdout.writeAll("\tplaced=- needs_pairing=-");
            if (item.from_tags) try stdout.writeAll("\tfrom_tags");
            try stdout.writeAll("\n");
        }
    }
    const counts = try runtime.libraryReleaseMatchCounts(library, confident_at, filter);
    try stdout.print("confident={d} needs_review={d} unmatched={d} reviewed={d}\n", .{ counts.confident, counts.needs_review, counts.unmatched, counts.reviewed });
}

fn reviewReleaseMatch(context: Context) !void {
    const stdout = context.stdout;
    const release_id = try std.fmt.parseInt(i64, context.arguments[1]["--release=".len..], 10);
    const Action = enum { evidence, diff, dismiss };
    var action: ?Action = null;
    var candidate: ?[]const u8 = null;
    for (context.arguments[2..]) |argument| {
        if (std.mem.eql(u8, argument, "--evidence")) {
            action = .evidence;
        } else if (std.mem.eql(u8, argument, "--diff")) {
            action = .diff;
        } else if (std.mem.startsWith(u8, argument, "--dismiss=")) {
            action = .dismiss;
            candidate = argument["--dismiss=".len..];
        } else if (std.mem.startsWith(u8, argument, "--candidate=")) {
            candidate = argument["--candidate=".len..];
        } else return error.UnknownOption;
    }
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    switch (action orelse return error.MissingReleaseAction) {
        .evidence => {
            const evidence = try runtime.libraryReleaseMatchEvidence(library, release_id, candidate);
            try stdout.print("fingerprints={d}/{d} durations_within_1s={s} date_agrees={s} artist_agrees={s} title_agrees={s}\nnote={s}\n", .{
                evidence.fingerprints_matched,
                evidence.tracks,
                flag(evidence.durations_within_1s),
                flag(evidence.date_agrees),
                flag(evidence.artist_agrees),
                flag(evidence.title_agrees),
                evidence.note.slice(),
            });
        },
        .diff => {
            const diff = try runtime.libraryReleaseMatchDiff(library, context.allocator, release_id, candidate);
            defer diff.deinit();
            try stdout.print("candidate={s} aligned={d}/{d}\n", .{ diff.release_mbid, diff.aligned, diff.tracks.len });
            for (diff.fields) |field| {
                try stdout.print("{s}\tdiffers={s}\tlocal={s}\tcandidate={s}\n", .{
                    @tagName(field.field), flag(field.differs), field.local, field.candidate,
                });
            }
            for (diff.tracks) |track| {
                try stdout.print("track={d}\tposition={d}\tfingerprint={s}\tdelta_ms=", .{ track.track_id, track.position, flag(track.fingerprint) });
                if (track.delta_ms) |delta| try stdout.print("{d}", .{delta}) else try stdout.writeAll("-");
                try stdout.print("\tlocal={s}\tcandidate={s}\tlocal_artist={s}\tcandidate_artist={s}\n", .{
                    track.local_title, track.candidate_title, track.local_artist, track.candidate_artist,
                });
            }
        },
        .dismiss => {
            const mbid = candidate orelse unreachable;
            try runtime.libraryDismissReleaseCandidate(library, release_id, mbid);
            try stdout.print("dismissed release={d} candidate={s}\n", .{ release_id, mbid });
        },
    }
}

fn listTrackMatches(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const database_path_argument = context.arguments[0];
    const id_argument = context.arguments[1];
    const track_id = try std.fmt.parseInt(i64, id_argument, 10);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    const page = try runtime.libraryMatchProposals(library, track_id, 512);
    defer page.deinit();
    for (page.items) |proposal| {
        try stdout.print("{d}\t{d:.2}\t", .{ proposal.id, proposal.confidence });
        if (proposal.musicbrainz_score) |score| try stdout.print("{d}", .{score}) else try stdout.writeAll("-");
        try stdout.print("\t{s}\t", .{proposal.provider});
        if (proposal.acoustid_score) |score| try stdout.print("{d:.2}", .{score}) else try stdout.writeAll("-");
        try stdout.print("\t{s}\t{s}\t{s}\t{s}\t", .{ proposal.recording_mbid, proposal.title, proposal.artist, proposal.album });
        if (proposal.track_number) |number| try stdout.print("{d}", .{number}) else try stdout.writeAll("-");
        try stdout.writeAll("\t");
        try writeDuration(stdout, if (proposal.duration_ms) |milliseconds| std.math.cast(i64, milliseconds) else null);
        try stdout.print("\t{s}\t{s}\t{s}\t{s}\t", .{
            proposal.release_mbid orelse "-",
            proposal.release_title orelse "-",
            proposal.release_artist orelse "-",
            proposal.release_date orelse "-",
        });
        if (proposal.disc_number) |number| try stdout.print("{d}", .{number}) else try stdout.writeAll("-");
        try stdout.print("\t{s}\t{s}\t{s}\t{s}\n", .{
            proposal.track_title orelse "-",
            proposal.track_artist orelse "-",
            proposal.release_track_mbid orelse "-",
            proposal.corrects orelse "-",
        });
    }
}

fn flag(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn writeDetailKey(stdout: *std.Io.Writer, comptime key: []const u8) !void {
    try stdout.print("{s: <17}", .{key ++ ":"});
}

fn printDetail(
    stdout: *std.Io.Writer,
    comptime key: []const u8,
    comptime format: []const u8,
    arguments: anytype,
) !void {
    try writeDetailKey(stdout, key);
    try stdout.print(format ++ "\n", arguments);
}

fn printOptionalDetail(
    stdout: *std.Io.Writer,
    comptime key: []const u8,
    comptime format: []const u8,
    value: anytype,
) !void {
    if (value) |present| return printDetail(stdout, key, format, .{present});
    return printDetail(stdout, key, "{s}", .{"-"});
}

/// `orca-cli artwork DATABASE (--track ID | --release ID) [--out PATH]
/// [--kind=KIND] [--set=PATH | --clear]`.
///
/// The reachability check for embedded cover art: it goes through the same
/// `OrcaRuntime` entry points the GTK frontend calls, so a cover that cannot
/// be produced here cannot be produced anywhere. `--out` writes the exact bytes
/// so they can be compared against what an independent tool extracts.
fn showArtwork(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const database_path_argument = context.arguments[0];
    const option_arguments = context.arguments[1..];
    var track_id: ?i64 = null;
    var release_id: ?i64 = null;
    var out_path: ?[]const u8 = null;
    var kind: ?liborca.ReleaseArtworkKind = null;
    var set_path: ?[]const u8 = null;
    var clear = false;
    var index: usize = 0;
    while (index < option_arguments.len) : (index += 1) {
        const argument = option_arguments[index];
        if (std.mem.startsWith(u8, argument, "--track=")) {
            track_id = try std.fmt.parseInt(i64, argument["--track=".len..], 10);
        } else if (std.mem.startsWith(u8, argument, "--release=")) {
            release_id = try std.fmt.parseInt(i64, argument["--release=".len..], 10);
        } else if (std.mem.startsWith(u8, argument, "--out=")) {
            out_path = argument["--out=".len..];
        } else if (std.mem.startsWith(u8, argument, "--kind=")) {
            kind = try parseArtworkKind(argument["--kind=".len..]);
        } else if (std.mem.startsWith(u8, argument, "--set=")) {
            set_path = argument["--set=".len..];
        } else if (std.mem.eql(u8, argument, "--clear")) {
            clear = true;
        } else return error.UnknownOption;
    }
    // One subject per call. Asking for both would make "which id did this
    // image come from" unanswerable from the output.
    if ((track_id == null) == (release_id == null)) return error.MissingSubject;
    if (release_id == null and (kind != null or set_path != null or clear)) return error.UnknownOption;
    if (set_path != null and clear) return error.UnknownOption;

    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    if (set_path) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(liborca.max_image_bytes + 1)) catch |err| switch (err) {
            error.StreamTooLong => return error.ArtworkTooLarge,
            else => return err,
        };
        defer allocator.free(bytes);
        const mime_type = liborca.sniffImageMimeType(bytes) orelse return error.UnrecognizedArtworkImage;
        try runtime.librarySetReleaseArtwork(library, release_id.?, kind orelse .front, bytes, mime_type);
        try stdout.print("set {t} {s}\t{d} bytes\n", .{ kind orelse .front, mime_type, bytes.len });
    }
    if (clear) {
        const cleared = try runtime.libraryClearReleaseArtwork(library, release_id.?, kind orelse .front);
        try stdout.print("cleared {t} {s}\n", .{ kind orelse .front, if (cleared) "yes" else "no" });
    }
    const image = if (track_id) |id|
        try runtime.libraryTrackArtwork(library, io, id)
    else switch (kind orelse .front) {
        .front => try runtime.libraryReleaseArtwork(library, io, release_id.?),
        .back, .booklet => |stored_kind| try runtime.libraryStoredReleaseArtwork(library, release_id.?, stored_kind),
    };
    const present = image orelse {
        try stdout.print("no artwork\n", .{});
        return;
    };
    defer present.deinit();
    try stdout.print("{s}\t{d} bytes\t{s}\n", .{
        present.mime_type,
        present.bytes.len,
        @tagName(present.kind),
    });
    if (out_path) |path| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = present.bytes });
        try stdout.print("wrote {s}\n", .{path});
    }
}

fn listGenres(context: Context) !void {
    for (context.arguments[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--fill-from-musicbrainz")) return fillGenres(context);
    }
    const allocator = context.allocator;
    const stdout = context.stdout;
    const options = try parseBrowseOptions(context.arguments[1..]);
    if (options.artist_id != null or options.release_id != null or options.genre_id != null or
        options.loved_only or options.descending) return error.UnknownOption;
    const sort: liborca.GenreSort = switch (try parseCountSort(options.sort)) {
        .name => .name,
        .track_count => .track_count,
    };
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    var page = try runtime.libraryGenrePage(library, .{
        .filter = options.filter,
        .sort = sort,
        .limit = options.limit,
        .offset = options.offset,
    });
    defer page.deinit();
    try stdout.print("{d} genres {s}\n", .{
        try runtime.libraryGenreCount(library, options.filter),
        if (options.filter.len == 0) "total" else "match",
    });
    for (page.items) |genre| try writeGenre(stdout, genre);
}

fn writeGenre(stdout: *std.Io.Writer, genre: liborca.GenreSummary) !void {
    try stdout.print("{d}\t{s}\t{d} tracks\t{d} releases\t{d} artists\t", .{
        genre.id,
        genre.name,
        genre.track_count,
        genre.release_count,
        genre.artist_count,
    });
    try writeDuration(stdout, genre.total_duration_ms);
    try stdout.writeAll("\n");
}

/// `orca-cli genre DATABASE ID`: what a genre page shows.
fn showGenre(context: Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout;
    const genre_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    const genre = (try runtime.libraryGenre(library, genre_id)) orelse return error.GenreNotFound;
    defer genre.deinit(allocator);
    try writeGenre(stdout, genre);

    var artists = try runtime.libraryArtistPage(library, .{ .genre_id = genre_id, .sort = .track_count, .limit = 5 });
    defer artists.deinit();
    for (artists.items) |artist| try stdout.print("artist\t{d}\t{s}\t{d} tracks\n", .{ artist.id, artist.name, artist.track_count });

    const releases = try runtime.libraryGenreArtwork(library, genre_id, 5);
    defer releases.deinit();
    for (releases.ids) |release_id| {
        const release = (try runtime.libraryRelease(library, release_id)) orelse continue;
        defer release.deinit(allocator);
        try stdout.print("release\t{d}\t{s}\t{s}\n", .{ release.id, release.title, release.album_artist });
    }
}

fn listArtists(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const database_path_argument = context.arguments[0];
    var option_arguments: std.ArrayList([]const u8) = .empty;
    defer option_arguments.deinit(allocator);
    var role: liborca.ArtistRole = .all;
    var name_order: liborca.NameOrder = .ignore_articles;
    for (context.arguments[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--album-artists")) {
            role = .album_artists;
        } else if (std.mem.eql(u8, argument, "--sort-as-written")) {
            name_order = .as_written;
        } else try option_arguments.append(allocator, argument);
    }
    const options = try parseBrowseOptions(option_arguments.items);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    const sort: liborca.ArtistSort = if (options.sort != null and std.mem.eql(u8, options.sort.?, "loved"))
        .recently_loved
    else if (options.sort != null and std.mem.eql(u8, options.sort.?, "recently_added"))
        .recently_added
    else switch (try parseCountSort(options.sort)) {
        .name => .name,
        .track_count => .track_count,
    };
    var page = try runtime.libraryArtistPage(library, .{
        .filter = options.filter,
        .genre_id = options.genre_id,
        .loved_only = options.loved_only,
        .role = role,
        .sort = sort,
        .name_order = name_order,
        .limit = options.limit,
        .offset = options.offset,
    });
    defer page.deinit();
    // The count of what matched, not of the library, or a filtered listing
    // reports a total it is not showing.
    const query: liborca.ArtistQuery = .{ .filter = options.filter, .genre_id = options.genre_id, .loved_only = options.loved_only, .role = role };
    try stdout.print(
        "{d} artists {s}\n",
        .{
            try runtime.libraryArtistCountMatching(library, query),
            if (options.filter.len == 0 and options.genre_id == null and !options.loved_only and role == .all) "total" else "match",
        },
    );
    for (page.items) |artist| try stdout.print(
        "{d}\t{s}\t{d} releases\t{d} tracks\t[{s}]{s}{s}\n",
        .{
            artist.id,
            artist.name,
            artist.release_count,
            artist.track_count,
            artist.sort_name,
            if (artist.loved) "\tloved" else "",
            if (artist.has_photo) "\tphoto" else "",
        },
    );
}

/// `orca-cli covers DATABASE [--limit N] [--offset N]`: a page of Releases'
/// covers, read on the runtime's artwork loader the way a GUI grid asks for
/// them, with how long the whole page took.
fn loadCovers(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const database_path_argument = context.arguments[0];
    const option_arguments = context.arguments[1..];
    const options = try parseBrowseOptions(option_arguments);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    var page = try runtime.libraryReleasePage(library, .{
        .limit = @min(options.limit, 64),
        .offset = options.offset,
    });
    defer page.deinit();
    const started = std.Io.Clock.awake.now(io);
    for (page.items) |release|
        _ = try runtime.libraryRequestArtwork(library, io, .{ .release = release.id });
    var remaining = page.items.len;
    var covered: usize = 0;
    var bytes: usize = 0;
    while (remaining != 0) {
        const result = runtime.libraryTakeArtwork(library) orelse {
            sleepMilliseconds(1);
            continue;
        };
        remaining -= 1;
        const image = result.image orelse {
            try stdout.print("{d}\tno cover\n", .{result.subject.release});
            continue;
        };
        defer image.deinit();
        covered += 1;
        bytes += image.bytes.len;
        try stdout.print("{d}\t{s}\t{d} bytes\n", .{ result.subject.release, image.mime_type, image.bytes.len });
    }
    const elapsed = started.durationTo(std.Io.Clock.awake.now(io));
    try stdout.print("{d} of {d} releases have covers, {d} bytes, in {d} ms\n", .{
        covered,
        page.items.len,
        bytes,
        @divTrunc(elapsed.nanoseconds, std.time.ns_per_ms),
    });
}

const ReleaseFilters = struct {
    high_resolution_only: bool = false,
    needs_review_only: bool = false,
    lossless_only: bool = false,
    year_min: ?i32 = null,
    year_max: ?i32 = null,
    has_artwork: ?bool = null,
    release_kind: ?liborca.ReleaseKind = null,
    appearing_artist_id: ?i64 = null,
    own_releases_only: bool = false,
    added_days: ?u32 = null,
    name_order: liborca.NameOrder = .ignore_articles,
    letters: bool = false,
    totals: bool = false,
    asynchronous: bool = false,

    fn any(self: ReleaseFilters) bool {
        return self.high_resolution_only or self.needs_review_only or self.lossless_only or
            self.year_min != null or self.year_max != null or self.has_artwork != null or
            self.release_kind != null or self.appearing_artist_id != null or self.own_releases_only or
            self.added_days != null;
    }
};

/// Takes the flags only `releases` reads out of `arguments`, leaving the rest
/// in `remaining` for `parseBrowseOptions`, so every other verb still refuses
/// them.
fn parseReleaseFilters(arguments: []const []const u8, remaining: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !ReleaseFilters {
    var filters: ReleaseFilters = .{};
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const name = arguments[index];
        if (std.mem.eql(u8, name, "--high-resolution")) {
            filters.high_resolution_only = true;
        } else if (std.mem.eql(u8, name, "--needs-review")) {
            filters.needs_review_only = true;
        } else if (std.mem.eql(u8, name, "--lossless")) {
            filters.lossless_only = true;
        } else if (std.mem.eql(u8, name, "--with-artwork")) {
            filters.has_artwork = true;
        } else if (std.mem.eql(u8, name, "--without-artwork")) {
            filters.has_artwork = false;
        } else if (std.mem.startsWith(u8, name, "--type=")) {
            const kind = name["--type=".len..];
            filters.release_kind = if (std.mem.eql(u8, kind, "album"))
                .album
            else if (std.mem.eql(u8, kind, "ep-single"))
                .ep_or_single
            else if (std.mem.eql(u8, kind, "other"))
                .other
            else
                return error.UnknownOption;
        } else if (std.mem.startsWith(u8, name, "--appears=")) {
            filters.appearing_artist_id = try std.fmt.parseInt(i64, name["--appears=".len..], 10);
        } else if (std.mem.eql(u8, name, "--own")) {
            filters.own_releases_only = true;
        } else if (std.mem.startsWith(u8, name, "--added-days=")) {
            filters.added_days = try std.fmt.parseInt(u32, name["--added-days=".len..], 10);
        } else if (std.mem.eql(u8, name, "--sort-as-written")) {
            filters.name_order = .as_written;
        } else if (std.mem.eql(u8, name, "--letters")) {
            filters.letters = true;
        } else if (std.mem.eql(u8, name, "--totals")) {
            filters.totals = true;
        } else if (std.mem.eql(u8, name, "--async")) {
            filters.asynchronous = true;
        } else if (std.mem.eql(u8, name, "--year-from") or std.mem.eql(u8, name, "--year-to")) {
            index += 1;
            if (index >= arguments.len) return error.MissingOptionValue;
            const year = try std.fmt.parseInt(i32, arguments[index], 10);
            if (std.mem.eql(u8, name, "--year-from")) filters.year_min = year else filters.year_max = year;
        } else {
            try remaining.append(allocator, name);
            if (std.mem.startsWith(u8, name, "--") and !std.mem.eql(u8, name, "--loved") and
                !std.mem.eql(u8, name, "--desc") and index + 1 < arguments.len)
            {
                index += 1;
                try remaining.append(allocator, arguments[index]);
            }
        }
    }
    return filters;
}

fn listReleases(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const database_path_argument = context.arguments[0];
    var browse_arguments: std.ArrayList([]const u8) = .empty;
    defer browse_arguments.deinit(allocator);
    const filters = try parseReleaseFilters(context.arguments[1..], &browse_arguments, allocator);
    const options = try parseBrowseOptions(browse_arguments.items);
    if (options.descending) return error.UnknownOption;
    if (filters.own_releases_only and options.artist_id == null) return error.OwnNeedsArtist;
    if (filters.letters and filters.totals) return error.LettersAndTotals;
    if (filters.asynchronous and (filters.letters or filters.totals)) return error.AsyncListingOnly;
    const sort: liborca.ReleaseSort = if (options.sort) |key|
        std.meta.stringToEnum(liborca.ReleaseSort, key) orelse return error.UnknownOption
    else
        .title;
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    const query: liborca.ReleaseQuery = .{
        .album_artist_id = options.artist_id,
        .own_releases_only = filters.own_releases_only,
        .appearing_artist_id = filters.appearing_artist_id,
        .release_kind = filters.release_kind,
        .genre_id = options.genre_id,
        .sort = sort,
        .loved_only = options.loved_only,
        .high_resolution_only = filters.high_resolution_only,
        .needs_review_only = filters.needs_review_only,
        .lossless_only = filters.lossless_only,
        .year_min = filters.year_min,
        .year_max = filters.year_max,
        .has_artwork = filters.has_artwork,
        .added_after = addedAfter(io, filters.added_days),
        .text = if (options.filter.len == 0) null else options.filter,
        .name_order = filters.name_order,
        .limit = options.limit,
        .offset = options.offset,
    };
    if (filters.letters) {
        const buckets = try runtime.libraryReleaseLetterIndex(library, allocator, query);
        defer allocator.free(buckets);
        for (buckets) |bucket| try stdout.print("{c}\t{d}\t{d}\n", .{ bucket.letter, bucket.count, bucket.first_offset });
        return;
    }
    if (filters.totals) {
        const totals = try runtime.libraryReleaseQueryTotals(library, query);
        try stdout.print("count={d} artists={d} bytes={d}\n", .{ totals.count, totals.artists, totals.bytes });
        return;
    }
    var page = if (filters.asynchronous)
        (try awaitBrowse(&runtime, library, io, .{ .release_page = query })).release_page
    else
        try runtime.libraryReleasePage(library, query);
    defer page.deinit();
    if (options.genre_id != null or options.filter.len != 0 or filters.any()) try stdout.print("{d} releases match\n", .{
        if (filters.asynchronous)
            (try awaitBrowse(&runtime, library, io, .{ .release_count = query })).release_count
        else
            try runtime.libraryReleaseCountMatching(library, query),
    });
    for (page.items) |release| {
        try stdout.print("{d}\t{s}\t{s}\t", .{ release.id, release.title, release.album_artist });
        try writeDuration(stdout, release.total_duration_ms);
        try stdout.print(
            "\t{d} tracks\t{d} disc(s)\t{s}{s}{s}\t",
            .{
                release.track_count,
                release.disc_count orelse 1,
                release.release_date orelse "-",
                if (release.is_compilation) "\tcompilation" else "",
                if (release.loved) "\tloved" else "",
            },
        );
        try writeReleaseFormat(stdout, release);
        try stdout.print("{s}\treviews={d}\n", .{ if (release.lossless) "\tlossless" else "", release.pending_reviews });
    }
}

/// `orca-cli search DATABASE TEXT [--artists N] ...`: one line per hit,
/// `kind<TAB>id<TAB>title<TAB>subtitle` then its detail, `reason=` and
/// `count=`, grouped in kind order, and last a `top` line.
fn searchLibrary(context: Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout;
    var limits: liborca.SearchLimits = .{};
    const options = context.arguments[2..];
    var index: usize = 0;
    while (index < options.len) : (index += 2) {
        if (index + 1 >= options.len) return error.MissingOptionValue;
        const cap = try std.fmt.parseInt(u8, options[index + 1], 10);
        inline for (@typeInfo(liborca.SearchLimits).@"struct".field_names) |name| {
            if (std.mem.eql(u8, options[index], "--" ++ name)) {
                @field(limits, name) = cap;
                break;
            }
        } else return error.UnknownOption;
    }
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    var results = try runtime.librarySearch(library, context.arguments[1], limits);
    defer results.deinit();
    for (results.hits) |hit| {
        try stdout.print("{s}\t{d}\t{s}\t{s}\treleases={d}\ttracks={d}\tyear=", .{
            @tagName(hit.kind), hit.id, hit.title, hit.subtitle, hit.release_count, hit.track_count,
        });
        try writeOptionalNumber(stdout, hit.year);
        try stdout.writeAll("\tduration_ms=");
        try writeOptionalNumber(stdout, hit.duration_ms);
        try stdout.print("\tartist={s}\treason={s}\tcount={d}\n", .{ hit.artist, @tagName(hit.reason), hit.reason_count });
    }
    if (results.top) |top| try stdout.print("top\t{s}\t{d}\t{s}\n", .{ @tagName(top.kind), top.id, top.title });
}

/// `format=FLAC 24/96`: codec, then bits per sample over kilohertz, either
/// left out when no file states it.
fn writeReleaseFormat(writer: *std.Io.Writer, release: liborca.ReleaseSummary) !void {
    try writer.writeAll("format=");
    if (release.codec.len == 0) {
        try writer.writeAll("-");
    } else for (release.codec) |byte| try writer.writeByte(std.ascii.toUpper(byte));
    const rate = release.max_sample_rate orelse {
        if (release.max_bit_depth) |bits| try writer.print(" {d}-bit", .{bits});
        return;
    };
    try writer.writeByte(' ');
    if (release.max_bit_depth) |bits| try writer.print("{d}/", .{bits});
    try writer.print("{d}", .{rate / 1000});
    const fraction = rate % 1000;
    if (fraction != 0) {
        var digits: [3]u8 = undefined;
        _ = std.fmt.bufPrint(&digits, "{d:0>3}", .{fraction}) catch unreachable;
        var length: usize = digits.len;
        while (digits[length - 1] == '0') length -= 1;
        try writer.print(".{s}", .{digits[0..length]});
    }
    if (release.max_bit_depth == null) try writer.writeAll("kHz");
}

const TrackFilters = struct {
    year_min: ?i32 = null,
    year_max: ?i32 = null,
    lossless: ?bool = null,
    min_sample_rate: ?u32 = null,
    max_sample_rate: ?u32 = null,
    codec: ?[]const u8 = null,
    added_days: ?u32 = null,
    explicit_only: bool = false,
    totals: bool = false,
    asynchronous: bool = false,
};

/// Takes the flags only `tracks` reads out of `arguments`, leaving the rest
/// in `remaining` for `parseBrowseOptions`, so every other verb still refuses
/// them.
fn parseTrackFilters(arguments: []const []const u8, remaining: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !TrackFilters {
    var filters: TrackFilters = .{};
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const name = arguments[index];
        if (std.mem.eql(u8, name, "--lossless") or std.mem.eql(u8, name, "--lossy")) {
            const lossless = std.mem.eql(u8, name, "--lossless");
            if (filters.lossless) |chosen| if (chosen != lossless) return error.LosslessAndLossy;
            filters.lossless = lossless;
        } else if (std.mem.eql(u8, name, "--explicit")) {
            filters.explicit_only = true;
        } else if (std.mem.eql(u8, name, "--year-from") or std.mem.eql(u8, name, "--year-to")) {
            index += 1;
            if (index >= arguments.len) return error.MissingOptionValue;
            const year = try std.fmt.parseInt(i32, arguments[index], 10);
            if (std.mem.eql(u8, name, "--year-from")) filters.year_min = year else filters.year_max = year;
        } else if (std.mem.eql(u8, name, "--min-rate")) {
            index += 1;
            if (index >= arguments.len) return error.MissingOptionValue;
            filters.min_sample_rate = try std.fmt.parseInt(u32, arguments[index], 10);
        } else if (std.mem.startsWith(u8, name, "--max-rate=")) {
            filters.max_sample_rate = try std.fmt.parseInt(u32, name["--max-rate=".len..], 10);
        } else if (std.mem.startsWith(u8, name, "--codec=")) {
            filters.codec = name["--codec=".len..];
        } else if (std.mem.startsWith(u8, name, "--added-days=")) {
            filters.added_days = try std.fmt.parseInt(u32, name["--added-days=".len..], 10);
        } else if (std.mem.eql(u8, name, "--totals")) {
            filters.totals = true;
        } else if (std.mem.eql(u8, name, "--async")) {
            filters.asynchronous = true;
        } else {
            try remaining.append(allocator, name);
            if (std.mem.startsWith(u8, name, "--") and !std.mem.eql(u8, name, "--loved") and
                !std.mem.eql(u8, name, "--desc") and index + 1 < arguments.len)
            {
                index += 1;
                try remaining.append(allocator, arguments[index]);
            }
        }
    }
    return filters;
}

fn listTracks(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const database_path_argument = context.arguments[0];
    var browse_arguments: std.ArrayList([]const u8) = .empty;
    defer browse_arguments.deinit(allocator);
    const filters = try parseTrackFilters(context.arguments[1..], &browse_arguments, allocator);
    const options = try parseBrowseOptions(browse_arguments.items);
    var runtime = liborca.Runtime.init(context.gpa);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    const query: liborca.TrackQuery = .{
        .artist_id = options.artist_id,
        .release_id = options.release_id,
        .genre_id = options.genre_id,
        .loved_only = options.loved_only,
        .year_min = filters.year_min,
        .year_max = filters.year_max,
        .lossless = filters.lossless,
        .min_sample_rate = filters.min_sample_rate,
        .max_sample_rate = filters.max_sample_rate,
        .codec = filters.codec,
        .added_after = addedAfter(io, filters.added_days),
        .explicit_only = filters.explicit_only,
        .sort = try parseTrackSort(options.sort),
        .direction = if (options.descending) .descending else .ascending,
        .limit = options.limit,
        .offset = options.offset,
    };
    const listing: liborca.BrowseTrackListing = .{ .text = options.filter, .query = query };
    if (filters.totals) {
        const totals = if (filters.asynchronous)
            (try awaitBrowse(&runtime, library, io, .{ .track_totals = listing })).track_totals
        else
            try runtime.libraryTrackQueryTotals(library, options.filter, query);
        try stdout.print("count={d} duration_ms={d}\n", .{ totals.count, totals.duration_ms });
        return;
    }
    var page = if (filters.asynchronous)
        (try awaitBrowse(&runtime, library, io, .{ .track_page = listing })).track_page
    else
        try runtime.libraryTrackQuery(library, options.filter, query);
    defer page.deinit();
    if (options.filter.len == 0) try stdout.print("{d} tracks match\n", .{
        if (filters.asynchronous)
            (try awaitBrowse(&runtime, library, io, .{ .track_totals = listing })).track_totals.count
        else
            try runtime.libraryTrackMatchCount(library, query),
    });
    for (page.items) |track| {
        const disc: u64 = @intCast(@max(track.disc_number orelse 1, 0));
        const number: u64 = @intCast(@max(track.track_number orelse 0, 0));
        try stdout.print(
            "{d}\t{d}-{d:0>2}\t{s}\t{s}\t{s}\t",
            .{ track.id, disc, number, track.title, track.artist, track.album },
        );
        try writeDuration(stdout, track.duration_ms);
        try stdout.print("\tcodec={s} rate=", .{if (track.codec.len == 0) "unknown" else track.codec});
        try writeOptionalNumber(stdout, track.sample_rate);
        try stdout.writeAll(" bits=");
        try writeOptionalNumber(stdout, track.bit_depth);
        try stdout.writeAll(" added=");
        if (track.added_at) |added_at| try writeIsoUtc(stdout, added_at) else try stdout.writeAll("unknown");
        try stdout.print(" plays={d} last=", .{track.play_count});
        if (track.last_played_at) |last| try writeIsoUtc(stdout, last) else try stdout.writeAll("never");
        try stdout.print(" explicit={s} pos=", .{explicitName(track.explicit)});
        try writeOptionalNumber(stdout, track.track_number);
        try stdout.writeAll("/");
        try writeOptionalNumber(stdout, track.track_total);
        try stdout.print(" disc={d}/", .{disc});
        try writeOptionalNumber(stdout, track.disc_total);
        try stdout.writeAll(" lufs=");
        if (track.integrated_lufs) |lufs| try stdout.print("{d:.2}", .{lufs}) else try stdout.writeAll("?");
        try stdout.writeAll(" kbps=");
        try writeOptionalNumber(stdout, track.bitrate_kbps);
        try stdout.print(" path={s}", .{if (track.path.len == 0) "?" else track.path});
        try stdout.print("{s}\n", .{if (track.has_playable_file) "" else "\tunreachable"});
    }
}

fn awaitBrowse(
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    io: std.Io,
    request: liborca.BrowseRequest,
) !liborca.BrowsePayload {
    const id = try runtime.libraryRequestBrowse(library, io, request);
    const result = while (true) {
        if (runtime.libraryTakeBrowse(library)) |result| break result;
        sleepMilliseconds(1);
    };
    std.debug.assert(result.request == id);
    return result.payload;
}

/// The Unix time `days` days before now, for an `--added-days` filter.
fn addedAfter(io: std.Io, days: ?u32) ?i64 {
    const count = days orelse return null;
    return std.Io.Clock.real.now(io).toSeconds() - @as(i64, count) * std.time.s_per_day;
}

/// `n of N`, `n` alone without a total, `-` without a number.
fn writeOfTotal(stdout: *std.Io.Writer, number: ?i64, total: ?i64) !void {
    const value = number orelse return stdout.writeAll("-");
    if (total) |count| return stdout.print("{d} of {d}", .{ value, count });
    try stdout.print("{d}", .{value});
}

fn writeOptionalNumber(stdout: *std.Io.Writer, value: anytype) !void {
    if (value) |number| try stdout.print("{d}", .{number}) else try stdout.writeAll("?");
}

fn explicitName(advisory: liborca.Explicit) []const u8 {
    return switch (advisory) {
        .unknown => "unknown",
        .none => "no",
        .explicit => "yes",
        .clean => "clean",
    };
}

fn sleepMilliseconds(milliseconds: u32) void {
    const duration: std.c.timespec = .{
        .sec = milliseconds / 1000,
        .nsec = @as(c_long, milliseconds % 1000) * std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&duration, null);
}

/// Drives the runtime pump until a job reaches a terminal state, exactly as a
/// frontend event loop would. Nothing about the scan happens on this thread.
fn awaitJob(
    runtime: *liborca.Runtime,
    stdout: *std.Io.Writer,
    job_handle: liborca.JobHandle,
    cancel_after_ms: ?u64,
) !void {
    var elapsed_ms: u64 = 0;
    var cancelled = false;
    while (true) {
        if (cancel_after_ms) |deadline| {
            if (!cancelled and elapsed_ms >= deadline) {
                cancelled = true;
                try runtime.cancelJob(job_handle);
                try stdout.print("cancellation requested at {d}ms\n", .{elapsed_ms});
                try stdout.flush();
            }
        }
        runtime.pump();
        while (runtime.pollEvent()) |_| {}
        while (runtime.pollTelemetry()) |_| {}
        const snapshot = try runtime.jobSnapshotSynced(job_handle);
        switch (snapshot.state) {
            .succeeded => return,
            .failed => return error.JobFailed,
            .cancelled => {
                try stdout.print("cancelled after {d} files\n", .{snapshot.completed_units});
                return;
            },
            else => {},
        }
        sleepMilliseconds(20);
        elapsed_ms += 20;
    }
}

fn awaitArtistInfo(runtime: *liborca.Runtime, io: std.Io, stdout: *std.Io.Writer, job_handle: liborca.JobHandle) !void {
    const started_ms = monotonicMs(io);
    var shown: u32 = 0;
    while (true) {
        runtime.pump();
        while (runtime.pollEvent()) |_| {}
        while (runtime.pollTelemetry()) |_| {}
        const snapshot = try runtime.jobSnapshotSynced(job_handle);
        const stores = try runtime.jobArtistInfoStores(job_handle);
        if (stores != shown) {
            shown = stores;
            try stdout.print("stored n={d} at_ms={d}\n", .{ stores, monotonicMs(io) - started_ms });
            try stdout.flush();
        }
        switch (snapshot.state) {
            .succeeded, .cancelled => return,
            .failed => return error.JobFailed,
            else => {},
        }
        sleepMilliseconds(20);
    }
}

/// The same counters, named for what a library-wide analysis means by them.
fn printAnalysisStats(
    stdout: *std.Io.Writer,
    stats: liborca.ScanStats,
) !void {
    try stdout.print(
        "examined={d} measured={d} no_loudness={d} declined={d} corrupt={d} batches={d}\n",
        .{
            stats.files_seen,
            stats.changed,
            stats.unchanged,
            stats.unsupported,
            stats.errors,
            stats.batches_committed,
        },
    );
}

/// The same counters, named for what a duplicate scan means by them.
///
/// `uncomparable` is printed on its own line rather than beside the rest,
/// because it is the number that decides whether the finding counts mean
/// anything: nothing can be said about a file no analysis has measured, and a
/// report of "no duplicates" over a library full of them would be a lie of
/// omission.
fn printDuplicateStats(
    stdout: *std.Io.Writer,
    stats: liborca.ScanStats,
) !void {
    try stdout.print(
        "examined={d} exact={d} identical={d} likely={d} unique={d} unreadable={d} batches={d}\n",
        .{
            stats.files_seen,
            stats.tracks_written,
            stats.changed -| stats.tracks_written -| stats.releases_written,
            stats.releases_written,
            stats.unchanged,
            stats.errors,
            stats.batches_committed,
        },
    );
    try stdout.print(
        "uncomparable={d} comparisons={d} truncated_buckets={d}\n",
        .{ stats.unsupported, stats.files_projected, stats.folders_visited },
    );
}

/// The same counters, named for what a repair pass means by them.
fn printBackfillStats(
    stdout: *std.Io.Writer,
    stats: liborca.ScanStats,
) !void {
    try stdout.print(
        "examined={d} repaired={d} still_unknown={d} unreachable={d} unreadable={d} batches={d}\n",
        .{
            stats.files_seen,
            stats.changed,
            stats.unchanged,
            stats.unsupported,
            stats.errors,
            stats.batches_committed,
        },
    );
    try stdout.print(
        "projected folders={d} files={d} tracks={d} releases={d}\n",
        .{
            stats.folders_visited,
            stats.files_projected,
            stats.tracks_written,
            stats.releases_written,
        },
    );
}

fn printScanStats(
    stdout: *std.Io.Writer,
    stats: liborca.ScanStats,
) !void {
    try printScanCounters(stdout, stats);
    try stdout.print(
        "projected folders={d} files={d} tracks={d} releases={d}\n",
        .{
            stats.folders_visited,
            stats.files_projected,
            stats.tracks_written,
            stats.releases_written,
        },
    );
}

fn printScanCounters(
    stdout: *std.Io.Writer,
    stats: liborca.ScanStats,
) !void {
    try stdout.print(
        "seen={d} changed={d} unchanged={d} unsupported={d} errors={d} batches={d} missing={d}",
        .{
            stats.files_seen,
            stats.changed,
            stats.unchanged,
            stats.unsupported,
            stats.errors,
            stats.batches_committed,
            stats.marked_missing,
        },
    );
    if (stats.symlinks_skipped != 0) try stdout.print(" symlinks_skipped={d}", .{stats.symlinks_skipped});
    try stdout.writeAll("\n");
}
