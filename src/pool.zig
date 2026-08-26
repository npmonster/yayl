//! Arena allocator wrapper — Zig port of libfyaml's fy-pool.
//!
//! libfyaml allocates every token, event and node object out of a single
//! arena (`fy_pool`) and resets it between documents. The Zig port wraps
//! `std.heap.ArenaAllocator` and keeps the same allocate-then-drop lifetime
//! model: objects are never freed individually, only by `deinit`/`reset`.

const std = @import("std");

pub const Pool = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) Pool {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    /// Allocator handle for objects owned by this pool.
    pub fn allocator(self: *Pool) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Create a value of type T inside the pool. The memory is not
    /// initialised; callers must assign `ptr.*` before use.
    pub fn create(self: *Pool, comptime T: type) !*T {
        return self.arena.allocator().create(T);
    }

    /// Create an uninitialised value of type T inside the pool.
    pub fn createUninit(self: *Pool, comptime T: type) !*T {
        return self.arena.allocator().create(T);
    }

    /// Duplicate a byte slice into the pool (fy_pool_strdup).
    pub fn dupe(self: *Pool, bytes: []const u8) ![]u8 {
        return self.arena.allocator().dupe(u8, bytes);
    }

    /// Free everything allocated since `init` (or the last `reset`) while
    /// keeping the backing memory for reuse — fy_pool_reset semantics.
    pub fn reset(self: *Pool) void {
        _ = self.arena.reset(.retain_capacity);
    }

    /// Free everything and release the backing memory.
    pub fn deinit(self: *Pool) void {
        self.arena.deinit();
    }
};

test "pool create and reset" {
    const alloc = std.testing.allocator;
    var p = Pool.init(alloc);
    defer p.deinit();

    const a = try p.create(u32);
    a.* = 42;
    try std.testing.expectEqual(@as(u32, 42), a.*);

    const s = try p.dupe("hello");
    try std.testing.expectEqualStrings("hello", s);

    p.reset();
    const b = try p.create(u32);
    b.* = 0;
    try std.testing.expectEqual(@as(u32, 0), b.*);
}
