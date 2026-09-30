const std = @import("std");

/// The one logical write lane per Library.
///
/// A scan worker holds this across a bounded 256-row transaction while UI
/// threads read, so waiting must park rather than spin. `std.Thread.Mutex` does
/// not exist in this toolchain; `std.Io.Mutex` does, and it futex-waits, so the
/// lane carries the `io` its Library was opened with.
pub const WriteLane = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    /// Uncancelable on purpose: a half-applied write transaction is not a state
    /// this lane is allowed to leave behind.
    pub fn acquire(self: *WriteLane) void {
        self.mutex.lockUncancelable(self.io);
    }

    /// Takes the lane only if it is free. For a writer that would rather skip
    /// its write than wait — the decode producer is the case this exists for,
    /// since a job worker holds this lane across a whole batch commit and a
    /// producer parked behind one starves the render callback into underruns.
    pub fn tryAcquire(self: *WriteLane) bool {
        return self.mutex.tryLock();
    }

    pub fn release(self: *WriteLane) void {
        self.mutex.unlock(self.io);
    }
};
