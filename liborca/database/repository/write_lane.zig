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
    /// The thread that holds the lane, or 0 when no one does. `Id` is an
    /// integer on every platform, so the atomic load is portable.
    owner: std.atomic.Value(std.Thread.Id) = .init(0),

    /// Uncancelable on purpose: a half-applied write transaction is not a state
    /// this lane is allowed to leave behind.
    pub fn acquire(self: *WriteLane) void {
        self.mutex.lockUncancelable(self.io);
        self.owner.store(std.Thread.getCurrentId(), .release);
    }

    /// Takes the lane only if it is free. For a writer that would rather skip
    /// its write than wait — the decode producer is the case this exists for,
    /// since a job worker holds this lane across a whole batch commit and a
    /// producer parked behind one starves the render callback into underruns.
    pub fn tryAcquire(self: *WriteLane) bool {
        if (!self.mutex.tryLock()) return false;
        self.owner.store(std.Thread.getCurrentId(), .release);
        return true;
    }

    pub fn release(self: *WriteLane) void {
        self.owner.store(0, .release);
        self.mutex.unlock(self.io);
    }

    /// Which connection a Database built on this lane should use: the holder's
    /// own writes are the only ones it may see. A thread that does not hold
    /// the lane is not the owner, whatever any other thread stored.
    pub fn heldByCurrentThread(self: *const WriteLane) bool {
        const owner = self.owner.load(.acquire);
        return owner != 0 and owner == std.Thread.getCurrentId();
    }
};
