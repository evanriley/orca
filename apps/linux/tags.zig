//! Edit Tags: Orca's own values for one or more tracks, and writing them into
//! the files.
//!
//! Editing is a library edit only, on the Edit Metadata page. Writing is a
//! separate, confirmed step on the Write to Files page: the engine plans the
//! write, the plan is shown, and only an approved plan runs, as a job whose
//! result can be undone.

const app = @import("app.zig");
const jobs = @import("jobs.zig");
const metadata_editor = @import("metadata_editor.zig");
const window = @import("window.zig");
const write_tags = @import("write_tags.zig");

const App = app.App;

pub fn edit(self: *App, ids: []const i64) void {
    metadata_editor.open(self, ids);
}

/// Plans writing the tracks' Orca values into their files and shows the plan
/// before doing it. Files that cannot be written are listed with why.
pub fn confirmWrite(self: *App, ids: []const i64) void {
    write_tags.open(self, ids);
}

/// Album and artist pages show what they were opened with; after an edit or
/// an accepted match that may have moved tracks between them, they go back to
/// their lists.
pub fn popPages(self: *App) void {
    if (self.albums_navigation) |navigation| window.popToTag(self, navigation, "albums");
    if (self.artists_navigation) |navigation| window.popToTag(self, navigation, "artists");
}

/// Restores the files the last tag write changed.
pub fn undoLastWrite(self: *App) void {
    if (self.tag_write_group == 0) return;
    _ = undoWrite(self, self.tag_write_group);
}

/// Restores the files tag write `group` changed. False when they could not
/// be restored, after a toast saying why.
pub fn undoWrite(self: *App, group: u64) bool {
    const library = self.library orelse return false;
    self.runtime.undoTagWrite(library, self.io, group) catch |err| switch (err) {
        error.MutationGroupAlreadyUndone => {},
        else => {
            self.toast(switch (err) {
                error.TagWriteBackupPruned => "The backups for that write were pruned, so it can't be undone",
                error.MutationInProgress => "Another Orca is writing tags",
                error.MutationNeedsReconciliation => "Some files changed after the write, so Orca left them as they are",
                else => "Could not undo that write",
            });
            return false;
        },
    };
    if (self.tag_write_group == group) self.tag_write_group = 0;
    jobs.reloadLibraryViews(self);
    self.requestTick();
    self.toast("The files are back as they were");
    return true;
}
