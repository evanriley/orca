const std = @import("std");
const build_options = @import("build_options");
const liborca = @import("liborca");

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        var stderr_buffer: [256]u8 = undefined;
        var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
        const stderr = &stderr_file_writer.interface;
        stderr.print("orca-cli: {s}\n", .{describe(err)}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.TrackNotFound => "no track with that id",
        error.UnknownRoot => "no folder with that id",
        error.RootVolumeChanged => "the folder is not on the drive it was added from, so nothing was scanned; mount that drive, or run add-root to accept the drive it is on now",
        error.OpenFailed => "could not open the database",
        error.InvalidCharacter, error.Overflow => "expected a number",
        error.InvalidThreadCount => "--threads must be at least 1",
        error.UnknownOption => "unknown option",
        error.LibraryJobRunning => "a job is running on this library",
        error.LibraryScanRunning => "a scan is already running on this library; wait for it to finish",
        error.InvalidReconcileDirectory => "each DIR must be a path relative to the root, with no '.', '..', empty or trailing component",
        error.WatchingUnsupported => "watching folders needs Linux",
        error.InvalidWatchOptions => "--quiet must be at least 1 and --max-delay at least --quiet",
        error.InvalidMaintenanceOptions => "--maintenance must be at least 1",
        error.WatchInstanceLimit => "too many inotify instances are open; raise fs.inotify.max_user_instances",
        error.WatcherStopped => "the watcher stopped on an error it could not recover from",
        error.InvalidToken => "ListenBrainz does not accept the token in ORCA_LISTENBRAINZ_TOKEN",
        error.NeedsToken => "set ORCA_LISTENBRAINZ_TOKEN to a ListenBrainz user token",
        error.InvalidServerUrl => "ORCA_LISTENBRAINZ_URL, ORCA_MUSICBRAINZ_URL, ORCA_ACOUSTID_URL and ORCA_COVERARTARCHIVE_URL must be https, or http to localhost",
        error.InvalidMatchRequest => "--accept-min-score and --cover-art need --release; --reidentify needs --track or --release and takes no --accept-min-score; --track and --release do not go together",
        error.UnknownRelease => "no release with that id",
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
        error.PageOutOfRange => "at most 512 ids at a time, and --limit must be 1 to 512",
        error.TracksAndPlaylist => "give either IDS or --playlist=ID, not both",
        error.UnknownHealthKind => "KIND must be the kind health prints, such as clipping or exact_duplicate",
        error.UnknownFile => "no file with that id",
        else => @errorName(err),
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const command = if (args.len > 1) findCommand(args[1], args.len - 2) else null;
    if (command) |found| {
        try found.run(.{
            .allocator = allocator,
            .io = init.io,
            .environ = init.environ_map,
            .stdout = stdout,
            .arguments = args[2..],
        });
    } else try writeHelp(stdout);

    try stdout.flush();
}

const Context = struct {
    allocator: std.mem.Allocator,
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
    .{ .name = "scan", .usage = "scan DATABASE ROOT", .min_arguments = 2, .max_arguments = 2, .run = scanRoot, .shares_usage_line = true },
    .{ .name = "reconcile", .usage = "reconcile DATABASE ROOT_ID [DIR...]", .min_arguments = 2, .max_arguments = null, .run = reconcileRoot },
    .{
        .name = "watch",
        .usage = "watch DATABASE [--quiet=MS] [--max-delay=MS] [--once]\n" ++ usage_indent ++ "  [--limit=MS] [--maintenance[=MS]]",
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
    .{ .name = "duplicates", .usage = "duplicates DATABASE [--batch=N] [--cancel-after=MS]", .min_arguments = 1, .max_arguments = null, .run = findDuplicates },
    .{ .name = "roots", .usage = "roots DATABASE", .min_arguments = 1, .max_arguments = 1, .run = listRoots },
    .{ .name = "add-root", .usage = "add-root DATABASE ROOT", .min_arguments = 2, .max_arguments = 2, .run = addRoot, .shares_usage_line = true },
    .{ .name = "remove-root", .usage = "remove-root DATABASE ID", .min_arguments = 2, .max_arguments = 2, .run = removeRoot, .shares_usage_line = true },
    .{ .name = "health", .usage = "health DATABASE [OFFSET]", .min_arguments = 1, .max_arguments = 2, .run = listHealthIssues },
    .{ .name = "devices", .usage = "devices", .min_arguments = 0, .max_arguments = 0, .run = listDevices, .shares_usage_line = true },
    .{ .name = "play", .usage = "play AUDIO [DEVICE_ID]", .min_arguments = 1, .max_arguments = 2, .run = playFile, .shares_usage_line = true },
    .{ .name = "health-dismiss", .usage = "health-dismiss DATABASE FILE_ID KIND", .min_arguments = 3, .max_arguments = 3, .run = dismissHealthIssue },
    .{ .name = "health-restore", .usage = "health-restore DATABASE FILE_ID KIND", .min_arguments = 3, .max_arguments = 3, .run = restoreHealthIssue, .shares_usage_line = true },
    .{ .name = "play-tracks", .usage = "play-tracks DATABASE (IDS | --playlist=ID) [OPTIONS]", .min_arguments = 2, .max_arguments = null, .run = playTracks },
    .{ .name = "scrobble", .usage = "scrobble DATABASE [--status] [--timeout=MS]", .min_arguments = 1, .max_arguments = null, .run = scrobble },
    .{ .name = "feedback", .usage = "feedback DATABASE IDS (--love | --hate | --clear)", .min_arguments = 3, .max_arguments = 3, .run = setFeedback },
    .{ .name = "rate", .usage = "rate DATABASE IDS (--stars=1..5 | --rating=1..100 | --clear)", .min_arguments = 3, .max_arguments = 3, .run = setRating },
    .{ .name = "playlists", .usage = "playlists DATABASE", .min_arguments = 1, .max_arguments = 1, .run = listPlaylists },
    .{ .name = "playlist", .usage = "playlist DATABASE ID [--limit N] [--offset N]", .min_arguments = 2, .max_arguments = 6, .run = showPlaylist },
    .{ .name = "playlist-create", .usage = "playlist-create DATABASE NAME", .min_arguments = 2, .max_arguments = 2, .run = createPlaylist },
    .{ .name = "playlist-rename", .usage = "playlist-rename DATABASE ID NAME", .min_arguments = 3, .max_arguments = 3, .run = renamePlaylist, .shares_usage_line = true },
    .{ .name = "playlist-delete", .usage = "playlist-delete DATABASE ID", .min_arguments = 2, .max_arguments = 2, .run = deletePlaylist },
    .{ .name = "playlist-add", .usage = "playlist-add DATABASE ID IDS [--at=N]", .min_arguments = 3, .max_arguments = 4, .run = addToPlaylist },
    .{ .name = "playlist-remove", .usage = "playlist-remove DATABASE ID POSITIONS", .min_arguments = 3, .max_arguments = 3, .run = removeFromPlaylist, .shares_usage_line = true },
    .{ .name = "playlist-move", .usage = "playlist-move DATABASE ID FROM TO", .min_arguments = 4, .max_arguments = 4, .run = moveInPlaylist },
    .{ .name = "playlist-import", .usage = "playlist-import DATABASE FILE [--name=NAME]", .min_arguments = 2, .max_arguments = 3, .run = importPlaylist },
    .{ .name = "playlist-export", .usage = "playlist-export DATABASE ID FILE [--relative] [--force]", .min_arguments = 3, .max_arguments = 5, .run = exportPlaylist },
    .{
        .name = "match",
        .usage = "match DATABASE [--batch=N] [--limit=N] [--no-fingerprints]\n" ++ usage_indent ++
            "  [--cancel-after=MS] [--release=ID [--accept-min-score=SCORE] [--cover-art]]\n" ++ usage_indent ++
            "  [--track=ID] [--reidentify (with --track or --release)]",
        .min_arguments = 1,
        .max_arguments = null,
        .run = matchLibrary,
    },
    .{ .name = "matches", .usage = "matches DATABASE TRACK_ID", .min_arguments = 2, .max_arguments = 2, .run = listMatches },
    .{ .name = "cover-art", .usage = "cover-art DATABASE RELEASE_ID", .min_arguments = 2, .max_arguments = 2, .run = fetchCoverArt, .shares_usage_line = true },
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
    .{ .name = "apply-release", .usage = "apply-release DATABASE RELEASE_ID", .min_arguments = 2, .max_arguments = 2, .run = applyMatchedRelease, .shares_usage_line = true },
    .{ .name = "artists", .usage = "artists DATABASE [OPTIONS]", .min_arguments = 1, .max_arguments = null, .run = listArtists },
    .{ .name = "releases", .usage = "releases DATABASE [--artist ID] [OPTIONS]", .min_arguments = 1, .max_arguments = null, .run = listReleases },
    .{ .name = "tracks", .usage = "tracks DATABASE [OPTIONS]", .min_arguments = 1, .max_arguments = null, .run = listTracks },
    .{ .name = "track", .usage = "track DATABASE ID", .min_arguments = 2, .max_arguments = 2, .run = showTrack },
    .{ .name = "artwork", .usage = "artwork DATABASE (--track=ID | --release=ID) [--out=PATH]", .min_arguments = 1, .max_arguments = null, .run = showArtwork },
    .{ .name = "covers", .usage = "covers DATABASE [--limit N] [--offset N]", .min_arguments = 1, .max_arguments = null, .run = loadCovers },
    .{ .name = "edit", .usage = "edit DATABASE IDS [EDITS]", .min_arguments = 2, .max_arguments = null, .run = editTracks },
    .{ .name = "write-tags", .usage = "write-tags DATABASE IDS [--approve=DIGEST]", .min_arguments = 2, .max_arguments = 3, .run = writeTags },
    .{ .name = "undo-tags", .usage = "undo-tags DATABASE GROUP", .min_arguments = 2, .max_arguments = 2, .run = undoTagWrite },
    .{ .name = "prune-backups", .usage = "prune-backups DATABASE [--older-than=DAYS]", .min_arguments = 1, .max_arguments = 2, .run = pruneBackups },
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
    \\roots lists the registered folders. remove-root forgets one and every
    \\file, Track, Release and Artist that exists only under it; a file also
    \\located under another root stays. Files on disk are not touched.
    \\
    \\edit sets Orca's own values for a comma-separated list of Track ids;
    \\the files are not written. With no edits it lists the values held.
    \\  --title= --artist= --album= --album-artist= --date=
    \\  --track=N --disc=N --compilation=0|1 --recording-id=MBID
    \\  --clear=FIELD      drop Orca's value so the file's tag applies again
    \\                     (title|artist|album|album_artist|track_number|
    \\                      disc_number|date|compilation|
    \\                      musicbrainz_recording_id|musicbrainz_release_id|
    \\                      musicbrainz_release_group_id|
    \\                      musicbrainz_release_track_id|
    \\                      musicbrainz_album_artist_id)
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
    \\to pass to undo-tags, which restores the files' previous bytes.
    \\
    \\Each write keeps the files' previous bytes in DATABASE.orca-backups until
    \\they are undone or pruned. prune-backups deletes the backups of every
    \\write whose files all committed, or with --older-than=DAYS only of writes
    \\at least that old, and prints how many it deleted and their size. A
    \\pruned write cannot be undone.
    \\
    \\Browsing. artists lists Artists in sort order; releases lists Releases,
    \\optionally one Artist's; tracks lists Tracks in a named order, optionally
    \\scoped to one Artist or one Release. Options:
    \\  --artist ID        only this Artist
    \\  --release ID       only this Release (tracks only)
    \\  --sort KEY         id|artist|album|title|track|duration|added|rating
    \\                     (tracks only; unrated last either way)
    \\  --desc             reverse the order
    \\  --limit N          page size, 1 to 512 (default 50)
    \\  --offset N         rows to skip
    \\
    \\track prints what the Library recorded about one Track and its file: tags,
    \\format, size, path, stored loudness, whether the file carries a cover,
    \\the rating, and the file's last verification. It opens no file.
    \\
    \\play-tracks plays a comma-separated list of Track ids, or with
    \\--playlist=ID the playlist's entries that have a Track, as a playback
    \\queue. Options:
    \\  --device=ID        output device (0 = server default)
    \\  --volume=LINEAR    volume as a linear gain, 0 to 4 (default 1)
    \\  --set-volume=MS:LINEAR  set the volume to LINEAR once, MS after
    \\                     playback starts
    \\  --replay-gain=off|track   loudness correction per entry (default track)
    \\  --eq=PRESET        equalizer preset: flat|bass|treble|vocal|loudness
    \\  --eq=G1,...,G10[:PREAMP]   ten band gains in dB (31 Hz to 16 kHz, each
    \\                     within 12) and a preamp in dB (default: minus the
    \\                     largest boost)
    \\  --crossfeed=AMOUNT stereo crossfeed for headphones, 0 to 1
    \\  --start=N          queue position to begin at
    \\  --repeat=off|all|one
    \\  --shuffle
    \\  --tail=MS          on each new entry, seek to MS before its end
    \\  --skip-after=MS    issue next MS after each entry becomes audible
    \\  --previous-after=MS  issue previous once, MS after playback starts
    \\  --limit=MS         stop after MS of wall clock
    \\
    \\play-tracks prints one `signal:` line once playback is a second in: the
    \\source, each stage that changes the samples, the output stream, and
    \\whether the path could be bit-perfect. It records listens in the
    \\Library's play history and never sends them anywhere.
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
    \\rate rates the Tracks' recordings in whole stars (--stars=N stores N*20)
    \\or 1 to 100, or clears the rating, and prints how many Tracks changed and
    \\how many were skipped for having no recording. Ratings are kept in the
    \\Library only; no file is written.
    \\
    \\Playlists are ordered lists of recordings, kept in the Library. playlists
    \\lists them: id, name, entries, entries with a Track, and length.
    \\playlist lists one's entries from position 0: the Track each plays (the
    \\lowest Track id of its recording), or `unavailable` when its recording
    \\has none. playlist-add appends the Tracks' recordings, or inserts them
    \\before position --at=N; playlist-remove removes a comma-separated list of
    \\positions; playlist-move moves the entry at FROM to TO. A playlist holds
    \\at most 10000 entries.
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
    \\cover as cover-art does. It prints accepted= and cover_art=.
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
    \\the Library, unless one of its files carries a cover, under the release ID
    \\its tags give or most of its accepted matches name. It prints where the
    \\cover comes from (embedded, fetched, cached, cached-miss, not-found or
    \\no-release-id) and its size; artwork --release=ID then reads it. A
    \\release the archive has no cover for is not asked again for 30 days.
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
    \\somewhere else, as health issues that `health` then lists. It compares
    \\what analyze-library measured -- it opens no files -- so it is fast, and
    \\it is only as complete as that analysis: the uncomparable count is how
    \\many files it could say nothing about, and a zero-finding run over a
    \\library with a large uncomparable count means "not measured", not "no
    \\duplicates".
    \\
    \\health prints one issue per line: file id, severity, kind, the action
    \\that resolves it (match_or_edit, fetch_cover_art, compare_duplicate,
    \\review_correction or reveal_file), path and details. health-dismiss
    \\hides an issue of a file until the file's bytes change; health-restore
    \\shows it again. KIND is the kind health prints.
    \\
    \\backfill re-reads the headers of files whose declared audio properties
    \\are missing and reprojects the Tracks derived from them, without walking
    \\a filesystem. --force also re-probes rows that already declare
    \\properties, which is for a probe implementation that improved rather
    \\than for ordinary use. --cancel-after=MS interrupts the job cooperatively
    \\once it has run that long; a later run resumes what it did not finish.
    \\
    \\The host-independent Orca control client.
    \\
;

fn printVersion(context: Context) !void {
    try context.stdout.print("orca-cli {f}\n", .{liborca.version});
}

fn runDemo(context: Context) !void {
    var runtime = liborca.Runtime.init(context.allocator);
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
    var runtime = liborca.Runtime.init(context.allocator);
    defer runtime.deinit();
    const library_handle = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    // Re-adding a registered root would rebind it to whatever volume its path
    // is on now, so an unmounted drive's empty mount point would pass the
    // volume check and the scan would mark every file under it missing.
    const root_id = try registeredRootId(&runtime, library_handle, context.arguments[1]) orelse
        (try bindRoot(&runtime, library_handle, context)).root_id;
    const job_handle = try runtime.startLibraryScan(library_handle, .{ .root_id = root_id });
    awaitJob(&runtime, stdout, job_handle, null) catch |err| {
        if (err == error.JobFailed and (try runtime.jobScanStats(job_handle)).volume_changed)
            return error.RootVolumeChanged;
        return err;
    };
    try printScanStats(stdout, try runtime.jobScanStats(job_handle));
}

fn addRoot(context: Context) !void {
    var runtime = liborca.Runtime.init(context.allocator);
    defer runtime.deinit();
    const library_handle = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const binding = try bindRoot(&runtime, library_handle, context);
    try context.stdout.print("root {d} on volume {d}\n", .{ binding.root_id, binding.volume_id });
}

/// Adding a root is an explicit user action, so this is the one path allowed
/// to write a volume identifier to a mount root that has no filesystem UUID
/// of its own, and to bind an existing root to the volume it is on now.
fn bindRoot(
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    context: Context,
) !liborca.RootBinding {
    const binding = try runtime.libraryAddRoot(library, context.io, context.arguments[1]);
    if (binding.claimed_locations != 0) try context.stdout.print(
        "claimed {d} migrated locations for volume {d}\n",
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
    var runtime = liborca.Runtime.init(context.allocator);
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
    const options = try parseJobOptions(context.arguments[1..], &.{ .quiet, .max_delay, .once, .limit, .maintenance });
    const limit_ms: u64 = options.limit orelse 10 * 60 * 1000;
    var runtime = liborca.Runtime.init(context.allocator);
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
    while (monotonicMs(context.io) - started_ms < limit_ms) {
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

/// Reprojection without a filesystem walk: this is what refreshes the library
/// after a metadata edit or a provider acceptance, and it is why the
/// projection is a pass of its own rather than part of the scanner.
fn projectLibrary(context: Context) !void {
    var runtime = liborca.Runtime.init(context.allocator);
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

/// Repairs `files` rows whose declared audio properties are missing, with no
/// filesystem walk. The job reprojects each repaired batch itself, which is
/// why there is no `project` step after this one. `--cancel-after=MS` is the
/// same kind of affordance `play-tracks` carries: the CLI is the
/// architectural test client, and a cooperative cancellation nothing outside
/// a unit test can trigger is not one a host can rely on.
fn backfillProperties(context: Context) !void {
    const stdout = context.stdout;
    const options = try parseJobOptions(context.arguments[1..], &.{ .force, .cancel_after });
    var runtime = liborca.Runtime.init(context.allocator);
    defer runtime.deinit();
    const library_handle = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const job_handle = try runtime.startLibraryPropertyBackfill(library_handle, .{
        .force = options.force,
    });
    const planned = try runtime.jobSnapshotSynced(job_handle);
    try stdout.print("{d} files to probe\n", .{planned.total_units orelse 0});
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
    // Not the process arena: it would keep every decoded file's buffers
    // until the run ends.
    var runtime = liborca.Runtime.init(std.heap.smp_allocator);
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
    const stdout = context.stdout;
    const options = try parseJobOptions(context.arguments[1..], &.{ .batch, .cancel_after });
    const database_path = try context.allocator.dupeSentinel(u8, context.arguments[0], 0);
    // Not the process arena: the pass frees a fingerprint per comparison, and
    // an arena would keep every one of them.
    var runtime = liborca.Runtime.init(std.heap.smp_allocator);
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

fn analyzeFile(context: Context) !void {
    var runtime = liborca.Runtime.init(context.allocator);
    defer runtime.deinit();
    const library_handle = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const result = try runtime.libraryAnalyzeFile(library_handle, context.io, context.arguments[1]);
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
    const offset = if (context.arguments.len == 2) try std.fmt.parseInt(u32, context.arguments[1], 10) else 0;
    var runtime = liborca.Runtime.init(context.allocator);
    defer runtime.deinit();
    const library_handle = try runtime.openLibrary(context.io, database_path);
    var page = try runtime.libraryHealthIssuePage(library_handle, 256, offset);
    defer page.deinit();
    for (page.items) |issue| try context.stdout.print(
        "{d}\t{s}\t{s}\t{s}\t{s}\t{s}\n",
        .{ issue.file_id, @tagName(issue.severity), @tagName(issue.kind), @tagName(issue.action), issue.path, issue.details },
    );
}

fn dismissHealthIssue(context: Context) !void {
    const file_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const kind = std.meta.stringToEnum(liborca.HealthIssueKind, context.arguments[2]) orelse return error.UnknownHealthKind;
    var runtime = liborca.Runtime.init(context.allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    try runtime.libraryDismissHealthIssue(library, file_id, kind);
    try context.stdout.print("dismissed {s} for file {d}\n", .{ @tagName(kind), file_id });
}

fn restoreHealthIssue(context: Context) !void {
    const file_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const kind = std.meta.stringToEnum(liborca.HealthIssueKind, context.arguments[2]) orelse return error.UnknownHealthKind;
    var runtime = liborca.Runtime.init(context.allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    try runtime.libraryRestoreHealthIssue(library, file_id, kind);
    try context.stdout.print("restored {s} for file {d}\n", .{ @tagName(kind), file_id });
}

fn listRoots(context: Context) !void {
    var runtime = liborca.Runtime.init(context.allocator);
    defer runtime.deinit();
    const library_handle = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    var page = try runtime.libraryRootPage(library_handle, 512, 0);
    defer page.deinit();
    for (page.items) |root| try context.stdout.print(
        "{d}\t{s}\t{s}\n",
        .{ root.id, if (root.enabled) "enabled" else "disabled", root.path },
    );
}

fn removeRoot(context: Context) !void {
    var runtime = liborca.Runtime.init(context.allocator);
    defer runtime.deinit();
    const library_handle = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const root_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const removed = try runtime.libraryRemoveRoot(library_handle, root_id);
    try context.stdout.print(
        "removed root {d}: {d} files, {d} tracks\n",
        .{ root_id, removed.files_forgotten, removed.tracks_removed },
    );
}

fn undoTagWrite(context: Context) !void {
    var runtime = liborca.Runtime.init(context.allocator);
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
    var runtime = liborca.Runtime.init(context.allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const pruned = try runtime.pruneTagWriteBackups(
        library,
        context.io,
        try std.math.mul(u64, older_than_days, std.time.s_per_day),
    );
    try context.stdout.print("pruned {d} backups ({d} bytes)\n", .{ pruned.backups, pruned.bytes });
}

fn listDevices(context: Context) !void {
    var runtime = liborca.Runtime.init(context.allocator);
    defer runtime.deinit();
    var devices: [32]liborca.Device = undefined;
    const count = try runtime.enumerateOutputDevices(&devices);
    for (devices[0..count]) |device|
        try context.stdout.print("{d}\t{s}\n", .{ device.id, device.nameSlice() });
}

/// The one object graph: a runtime Player owns the source and the single
/// decode producer, and a runtime Zone owns the pool, pipe, render context and
/// OutputSession. Nothing about playback lives in this frame.
fn playFile(context: Context) !void {
    const device_id = if (context.arguments.len == 2)
        try std.fmt.parseInt(u64, context.arguments[1], 10)
    else
        0;
    var runtime = liborca.Runtime.init(context.allocator);
    defer runtime.deinit();
    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.playerLoadFile(player, context.io, context.arguments[0]);
    try runtime.zoneRequestOutput(zone, device_id);
    try runtime.playPlayer(player);

    var elapsed_ms: u64 = 0;
    while (!try runtime.playerDrained(player)) {
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

fn acceptMatch(context: Context) !void {
    var runtime = liborca.Runtime.init(context.allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const proposal_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const acceptance = try runtime.libraryAcceptMatch(library, proposal_id);
    try context.stdout.print("accepted match {d}: values_written={d}\n", .{ proposal_id, acceptance.values_written });
}

fn applyMatchedRelease(context: Context) !void {
    var runtime = liborca.Runtime.init(context.allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const release_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const values_written = try runtime.libraryApplyMatchedRelease(library, release_id);
    try context.stdout.print("values_written={d}\n", .{values_written});
}

fn dismissMatch(context: Context) !void {
    var runtime = liborca.Runtime.init(context.allocator);
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
    var runtime = liborca.Runtime.init(context.allocator);
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

const PlayTracksOptions = struct {
    device: u64 = 0,
    volume: f32 = 1,
    set_volume: ?ScheduledVolume = null,
    replay_gain: liborca.ReplayGainMode = .track,
    equalizer: ?liborca.Equalizer = null,
    crossfeed: ?f32 = null,
    start: u32 = 0,
    repeat: liborca.RepeatMode = .off,
    shuffle: bool = false,
    tail_ms: ?u64 = null,
    skip_after_ms: ?u64 = null,
    previous_after_ms: ?u64 = null,
    limit_ms: u64 = 10 * 60 * 1000,
    playlist_id: ?i64 = null,
};

fn parseOption(options: *PlayTracksOptions, argument: []const u8) !void {
    if (std.mem.eql(u8, argument, "--shuffle")) {
        options.shuffle = true;
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
    } else if (std.mem.eql(u8, name, "--start")) {
        options.start = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--replay-gain")) {
        options.replay_gain = if (std.mem.eql(u8, value, "off"))
            .off
        else if (std.mem.eql(u8, value, "track"))
            .track
        else
            return error.UnknownReplayGainMode;
    } else if (std.mem.eql(u8, name, "--eq")) {
        options.equalizer = try parseEqualizer(value);
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
    if (path.replay_gain_db) |decibels| try stdout.print(" -> replay gain {d:.1} dB", .{decibels});
    if (path.equalizer != null) try stdout.writeAll(" -> eq");
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
    try stdout.writeByte('\n');
}

fn formatName(sample_format: liborca.SampleFormat) []const u8 {
    return switch (sample_format) {
        .unsigned_8 => "uint8",
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

    var ids: std.ArrayList(i64) = if (id_list) |list| try parseTrackIds(allocator, list) else .empty;
    defer ids.deinit(allocator);
    if (id_list == null and options.playlist_id == null) return error.NoTrackIds;

    const database_path = try allocator.dupeSentinel(u8, database_path_argument, 0);
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    try identifyOrca(&runtime);
    const library = try runtime.openLibrary(io, database_path);
    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneRequestOutput(zone, options.device);

    try runtime.playerSetVolume(player, options.volume);
    try runtime.playerSetReplayGainMode(player, options.replay_gain);
    try runtime.playerSetEqualizer(player, options.equalizer);
    try runtime.playerSetCrossfeed(player, options.crossfeed);
    try runtime.playerSetRepeat(player, options.repeat);
    if (options.shuffle) try runtime.playerSetShuffle(player, true);
    if (options.playlist_id) |playlist_id| {
        try runtime.playerPlayPlaylist(player, library, io, playlist_id, options.start);
    } else try runtime.playerPlayTracks(player, library, io, ids.items, options.start);

    var elapsed_ms: u64 = 0;
    var entry_elapsed_ms: u64 = 0;
    var last_cursor: ?u32 = null;
    var took_previous = options.previous_after_ms == null;
    var set_volume = options.set_volume == null;
    var printed_signal_path = false;
    // How often the producer was observed a whole entry ahead of the audio.
    // Nonzero is the proof that now-playing is derived from rendered audio
    // rather than from the decode cursor.
    var decode_lead_polls: u64 = 0;
    while (elapsed_ms < options.limit_ms) {
        _ = runtime.processNextCommand();
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
        if (!took_previous and elapsed_ms >= options.previous_after_ms.?) {
            took_previous = true;
            const moved = try runtime.playerPrevious(player);
            try stdout.print("previous at={d}ms moved={}\n", .{ elapsed_ms, moved });
            try stdout.flush();
            last_cursor = null;
        }
        if (options.skip_after_ms) |after| {
            if (entry_elapsed_ms >= after) {
                const moved = try runtime.playerNext(player);
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
        if (try runtime.playerDrained(player)) break;
        sleepMilliseconds(10);
        elapsed_ms += 10;
        entry_elapsed_ms += 10;
    }

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
}

const BrowseOptions = struct {
    artist_id: ?i64 = null,
    /// Free text for `artists`, folded the way artist keys are folded, so
    /// `--filter el-p` finds the one spelled with a U+2010 hyphen.
    filter: []const u8 = "",
    release_id: ?i64 = null,
    sort: liborca.TrackSort = .id,
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
        if (index + 1 >= arguments.len) return error.MissingOptionValue;
        const value = arguments[index + 1];
        index += 2;
        if (std.mem.eql(u8, name, "--artist")) {
            options.artist_id = try std.fmt.parseInt(i64, value, 10);
        } else if (std.mem.eql(u8, name, "--filter")) {
            options.filter = value;
        } else if (std.mem.eql(u8, name, "--release")) {
            options.release_id = try std.fmt.parseInt(i64, value, 10);
        } else if (std.mem.eql(u8, name, "--limit")) {
            options.limit = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, name, "--offset")) {
            options.offset = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, name, "--sort")) {
            options.sort = if (std.mem.eql(u8, value, "id"))
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
            else
                return error.UnknownSortKey;
        } else return error.UnknownOption;
    }
    return options;
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
    for (option_arguments) |argument| {
        const split = std.mem.indexOfScalar(u8, argument, '=') orelse return error.UnknownOption;
        const name = argument[0..split];
        const value = argument[split + 1 ..];
        if (std.mem.eql(u8, name, "--clear")) {
            const field = std.meta.stringToEnum(liborca.MetadataField, value) orelse
                return error.UnknownField;
            try edits.append(allocator, .{ .field = field, .value = null });
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
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(io, database_path);
    if (edits.items.len > 0) {
        const edited = try runtime.libraryEditTracks(library, ids.items, edits.items);
        defer edited.deinit();
        try stdout.print("edited {d} tracks, now", .{ids.items.len});
        for (edited.ids, 0..) |id, index| try stdout.print("{s}{d}", .{ if (index == 0) " " else ",", id });
        try stdout.writeAll("\n");
        return;
    }
    for (ids.items) |track_id| {
        var page = try runtime.libraryTrackEdits(library, track_id);
        defer page.deinit();
        for (page.items) |value| try stdout.print(
            "{d}\t{t}\t{s}\t{t}{s}\n",
            .{ track_id, value.field, value.text, value.provenance, if (value.locked) "\tlocked" else "" },
        );
    }
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
    var runtime = liborca.Runtime.init(allocator);
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
    try awaitJob(&runtime, stdout, job_handle, null);
    const stats = try runtime.jobScanStats(job_handle);
    try stdout.print("wrote {d} files as group {d}\n", .{ stats.changed, plan.plan_id });
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
    var runtime = liborca.Runtime.init(allocator);
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
    try printOptionalDetail(stdout, "track", "{d}", details.track_number);
    try printOptionalDetail(stdout, "disc", "{d}", details.disc_number);
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

    var runtime = liborca.Runtime.init(allocator);
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
    var runtime = liborca.Runtime.init(allocator);
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
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    const change = try runtime.librarySetRating(library, ids.items, rating);
    try stdout.print("rating: updated={d} skipped={d}\n", .{ change.updated, change.skipped });
}

fn listPlaylists(context: Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout;
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    var offset: u32 = 0;
    while (true) {
        var page = try runtime.libraryPlaylists(library, 512, offset);
        defer page.deinit();
        for (page.items) |playlist| {
            try stdout.print("{d}\t{s}\t{d}\t{d}\t", .{ playlist.id, playlist.name, playlist.entries, playlist.available });
            try writeDuration(stdout, playlist.duration_ms);
            try stdout.writeAll("\n");
        }
        if (page.items.len < 512) break;
        offset += 512;
    }
}

fn showPlaylist(context: Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout;
    const playlist_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const options = try parseBrowseOptions(context.arguments[2..]);
    if (options.artist_id != null or options.release_id != null or options.filter.len != 0 or
        options.descending or options.sort != .id) return error.UnknownOption;
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
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

fn createPlaylist(context: Context) !void {
    const allocator = context.allocator;
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    const playlist_id = try runtime.libraryCreatePlaylist(library, context.arguments[1]);
    try context.stdout.print("playlist_id={d}\n", .{playlist_id});
}

fn renamePlaylist(context: Context) !void {
    const allocator = context.allocator;
    const playlist_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, context.io, &runtime, context.arguments[0]);
    try runtime.libraryRenamePlaylist(library, playlist_id, context.arguments[2]);
}

fn deletePlaylist(context: Context) !void {
    const allocator = context.allocator;
    const playlist_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    var runtime = liborca.Runtime.init(allocator);
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
    var runtime = liborca.Runtime.init(allocator);
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
    var runtime = liborca.Runtime.init(allocator);
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
    var runtime = liborca.Runtime.init(allocator);
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
    var runtime = liborca.Runtime.init(allocator);
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
    var runtime = liborca.Runtime.init(allocator);
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
    var runtime = liborca.Runtime.init(allocator);
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
    if (stats.cover_art == .no_release_id) try stdout.writeAll(no_release_id_hint);
}

const no_release_id_hint = "no release ID: review matches, then run cover-art\n";

fn configureCoverArtArchive(allocator: std.mem.Allocator, runtime: *liborca.Runtime, environ: *std.process.Environ.Map) !void {
    if (environ.get("ORCA_COVERARTARCHIVE_URL")) |url| {
        if (url.len > 0) try runtime.setCoverArtArchiveServer(try allocator.dupe(u8, url));
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
    };
}

fn coverArtError(outcome: liborca.CoverArtOutcome) ?anyerror {
    return switch (outcome) {
        .refused => error.CoverArtRefused,
        .unavailable => error.CoverArtUnavailable,
        .busy => error.CoverArtArchiveInUse,
        .not_requested, .embedded, .fetched, .cached, .cached_miss, .not_found, .no_release_id, .cancelled => null,
    };
}

/// `orca-cli cover-art DATABASE RELEASE_ID`: the Release's cover from the
/// Cover Art Archive, through the job the GTK app's Fetch Cover Art starts.
fn fetchCoverArt(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const release_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    try identifyOrca(&runtime);
    try configureCoverArtArchive(allocator, &runtime, context.environ);
    const library = try openBrowseLibrary(allocator, io, &runtime, context.arguments[0]);
    const job_handle = try runtime.startReleaseCoverArtFetch(library, release_id);
    const failed = if (awaitJob(&runtime, stdout, job_handle, null)) false else |err| switch (err) {
        error.JobFailed => true,
        else => return err,
    };
    const outcome = (try runtime.jobMatchStats(job_handle)).cover_art;
    const image = try runtime.libraryReleaseArtwork(library, io, release_id);
    defer if (image) |present| present.deinit();
    const bytes: usize = switch (outcome) {
        .embedded, .fetched, .cached => if (image) |present| present.bytes.len else 0,
        else => 0,
    };
    try stdout.print("cover-art: source={s} bytes={d}\n", .{ coverArtSource(outcome), bytes });
    if (outcome == .no_release_id) try stdout.writeAll(no_release_id_hint);
    if (failed) {
        try stdout.flush();
        return coverArtError(outcome) orelse error.JobFailed;
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
    var runtime = liborca.Runtime.init(allocator);
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
    var runtime = liborca.Runtime.init(context.allocator);
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
    var runtime = liborca.Runtime.init(context.allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(context.allocator, context.io, &runtime, context.arguments[0]);
    const group_id = try std.fmt.parseInt(i64, context.arguments[1], 10);
    const acceptance = try runtime.libraryAcceptCorrectionGroup(library, group_id);
    try context.stdout.print("accepted correction group {d}: accepted={d} values_written={d}\n", .{ group_id, acceptance.accepted, acceptance.values_written });
}

fn dismissCorrection(context: Context) !void {
    var runtime = liborca.Runtime.init(context.allocator);
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
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    const outcome = try runtime.libraryTrackFingerprint(library, io, track_id) orelse return error.NoPresentFile;
    defer outcome.fingerprint.deinit();
    try stdout.print("DURATION={d}\nFINGERPRINT={s}\n", .{ outcome.fingerprint.durationSeconds(), outcome.fingerprint.encoded });
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
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    try identifyOrca(&runtime);
    try runtime.setCredentialStore(credentials.store());
    try configureAcoustId(allocator, &runtime, environ);
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    try stdout.print("{d} files to submit\n", .{try runtime.libraryAcoustIdSubmittableCount(library)});
    if (options.dry_run) return listSubmittable(&runtime, library, stdout);
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
    try stdout.flush();
    return switch (stats.outcome) {
        .completed, .cancelled => {},
        .needs_user_key => error.NeedsAcoustIdUserKey,
        .invalid_user_key => error.InvalidAcoustIdUserKey,
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
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const database_path_argument = context.arguments[0];
    const id_argument = context.arguments[1];
    const track_id = try std.fmt.parseInt(i64, id_argument, 10);
    var runtime = liborca.Runtime.init(allocator);
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

/// `orca-cli artwork DATABASE (--track ID | --release ID) [--out PATH]`.
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
    var index: usize = 0;
    while (index < option_arguments.len) : (index += 1) {
        const argument = option_arguments[index];
        if (std.mem.startsWith(u8, argument, "--track=")) {
            track_id = try std.fmt.parseInt(i64, argument["--track=".len..], 10);
        } else if (std.mem.startsWith(u8, argument, "--release=")) {
            release_id = try std.fmt.parseInt(i64, argument["--release=".len..], 10);
        } else if (std.mem.startsWith(u8, argument, "--out=")) {
            out_path = argument["--out=".len..];
        } else return error.UnknownOption;
    }
    // One subject per call. Asking for both would make "which id did this
    // image come from" unanswerable from the output.
    if ((track_id == null) == (release_id == null)) return error.MissingSubject;

    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    const image = if (track_id) |id|
        try runtime.libraryTrackArtwork(library, io, id)
    else
        try runtime.libraryReleaseArtwork(library, io, release_id.?);
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

fn listArtists(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const database_path_argument = context.arguments[0];
    const option_arguments = context.arguments[1..];
    const options = try parseBrowseOptions(option_arguments);
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    var page = try runtime.libraryArtistPage(library, .{
        .filter = options.filter,
        .limit = options.limit,
        .offset = options.offset,
    });
    defer page.deinit();
    // The count of what matched, not of the library, or a filtered listing
    // reports a total it is not showing.
    const query: liborca.ArtistQuery = .{ .filter = options.filter };
    try stdout.print(
        "{d} artists {s}\n",
        .{
            try runtime.libraryArtistCountMatching(library, query),
            if (options.filter.len == 0) "total" else "match",
        },
    );
    for (page.items) |artist| try stdout.print(
        "{d}\t{s}\t{d} releases\t{d} tracks\t[{s}]\n",
        .{ artist.id, artist.name, artist.release_count, artist.track_count, artist.sort_name },
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
    var runtime = liborca.Runtime.init(allocator);
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

fn listReleases(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const database_path_argument = context.arguments[0];
    const option_arguments = context.arguments[1..];
    const options = try parseBrowseOptions(option_arguments);
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    var page = try runtime.libraryReleasePage(library, .{
        .album_artist_id = options.artist_id,
        .limit = options.limit,
        .offset = options.offset,
    });
    defer page.deinit();
    for (page.items) |release| {
        try stdout.print("{d}\t{s}\t{s}\t", .{ release.id, release.title, release.album_artist });
        try writeDuration(stdout, release.total_duration_ms);
        try stdout.print(
            "\t{d} tracks\t{d} disc(s)\t{s}{s}\n",
            .{
                release.track_count,
                release.disc_count orelse 1,
                release.release_date orelse "-",
                if (release.is_compilation) "\tcompilation" else "",
            },
        );
    }
}

fn listTracks(context: Context) !void {
    const allocator = context.allocator;
    const io = context.io;
    const stdout = context.stdout;
    const database_path_argument = context.arguments[0];
    const option_arguments = context.arguments[1..];
    const options = try parseBrowseOptions(option_arguments);
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    const query: liborca.TrackQuery = .{
        .artist_id = options.artist_id,
        .release_id = options.release_id,
        .sort = options.sort,
        .direction = if (options.descending) .descending else .ascending,
        .limit = options.limit,
        .offset = options.offset,
    };
    var page = try runtime.libraryTrackQuery(library, "", query);
    defer page.deinit();
    try stdout.print(
        "{d} tracks match\n",
        .{try runtime.libraryTrackMatchCount(library, query)},
    );
    for (page.items) |track| {
        const disc: u64 = @intCast(@max(track.disc_number orelse 1, 0));
        const number: u64 = @intCast(@max(track.track_number orelse 0, 0));
        try stdout.print(
            "{d}\t{d}-{d:0>2}\t{s}\t{s}\t{s}\t",
            .{ track.id, disc, number, track.title, track.artist, track.album },
        );
        try writeDuration(stdout, track.duration_ms);
        try stdout.print("{s}\n", .{if (track.has_playable_file) "" else "\tunreachable"});
    }
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
        _ = runtime.processNextCommand();
        runtime.reapFinishedJobs();
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
        "examined={d} exact={d} likely={d} unique={d} unreadable={d} batches={d}\n",
        .{
            stats.files_seen,
            stats.tracks_written,
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
        "seen={d} changed={d} unchanged={d} unsupported={d} errors={d} batches={d} missing={d}\n",
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
}
