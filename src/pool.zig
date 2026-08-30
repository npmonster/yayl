//! Arena allocator wrapper — Zig port of libfyaml's fy-pool.
//!
//! libfyaml allocates every token, event and node object out of a single
//! arena (`fy_pool`) and resets it between documents. The Zig port wraps
//! `std.heap.ArenaAllocator` and keeps the same allocate-then-drop
//! lifetime model: objects are never freed individually, only by
//! `deinit`/`reset`.

const std = @import("std");

/// Arena allocator: objects are freed in bulk via `reset`/`deinit`,
/// never individually (fy-pool port).
pub const Pool = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(backing_allocator: std.mem.Allocator) Pool {
        return .{ .arena = std.heap.ArenaAllocator.init(backing_allocator) };
    }

    /// Allocator handle for objects owned by this pool.
    pub fn allocator(self: *Pool) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Create an uninitialized value of type `T` inside the pool.
    ///
    /// The memory content is undefined: assign `ptr.*` before any use.
    /// Zero-initialization is deliberately not performed — all-zero bits
    /// fabricate invalid values for types whose valid state is narrower
    /// (tagged unions, enums with no zero member, non-null pointers).
    pub fn create(self: *Pool, comptime T: type) !*T {
        return self.arena.allocator().create(T);
    }

    /// Duplicate a byte slice into the pool (fy_pool_strdup).
    pub fn dupe(self: *Pool, bytes: []const u8) ![]u8 {
        return self.arena.allocator().dupe(u8, bytes);
    }

    /// Free everything allocated since `init` (or the last `reset`) while
    /// keeping the backing memory for reuse — fy_pool_reset semantics.
    ///
    /// Every pointer and slice handed out by this pool becomes invalid;
    /// using one afterwards is unchecked illegal memory access.
    pub fn reset(self: *Pool) void {
        _ = self.arena.reset(.retain_capacity);
    }

    /// Free everything and release the backing memory. Invalidates every
    /// pointer and slice handed out by this pool, like `reset`.
    pub fn deinit(self: *Pool) void {
        self.arena.deinit();
    }
};

test "create, dupe and reset" {
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

test "repeated reset and deinit are leak-free" {
    const alloc = std.testing.allocator;
    var p = Pool.init(alloc);
    defer p.deinit();

    var round: usize = 0;
    while (round < 4) : (round += 1) {
        const n = try p.create([16]u8);
        @memset(n, @intCast(round));
        _ = try p.dupe("some bytes to duplicate");
        p.reset();
    }
}

fn allocatingOperations(alloc: std.mem.Allocator) !void {
    var p = Pool.init(alloc);
    defer p.deinit();

    const a = try p.create(u32);
    a.* = 7;
    const s = try p.dupe("allocation failure test");
    try std.testing.expectEqualStrings("allocation failure test", s);
    const via_handle = try p.allocator().alloc(u8, 3);
    @memset(via_handle, 'x');
}

test "allocation failures leak nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocatingOperations, .{});
}
