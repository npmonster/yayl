//! Marks and diagnostics — Zig port of libfyaml's fy-diag.
//!
//! Every parse/emit error carries a `Mark` (line/column/byte offset into the
//! input) plus a human readable message, mirroring fy_diag behavior.

const std = @import("std");

/// A position inside the input stream.
///
/// Corresponds to fy_mark: `line` and `column` are 1-based and count
/// codepoints (not bytes); `offset` is the 0-based byte offset.
/// The defaults (line 1, column 1, offset 0) are therefore a *valid*
/// position — the start of the input — not an "unset" sentinel.
pub const Mark = struct {
    line: usize = 1,
    column: usize = 1,
    offset: usize = 0,

    /// The start of an input stream: line 1, column 1, byte offset 0.
    pub const start: Mark = .{};
};

/// Diagnostic severity.
pub const Level = enum {
    debug,
    info,
    notice,
    warning,
    err,

    pub fn name(self: Level) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .notice => "notice",
            .warning => "warning",
            .err => "error",
        };
    }
};

/// One diagnostic message. `message` is owned by the collector that
/// emitted it (see `Diag`); `mark` and `level` are plain values.
pub const Diagnostic = struct {
    level: Level,
    mark: Mark,
    message: []const u8,
};

/// The library's public error vocabulary. Fallible functions return one
/// of these (plus `error.OutOfMemory`); the human readable detail lives
/// in the diagnostic list.
///
/// Kept as one set rather than per-layer sets on purpose: scanner,
/// parser and builder all feed a single diagnostic channel and callers
/// (parse/parseAll/emit) surface the union anyway, mirroring how
/// libfyaml collapses FYEC_* codes into one error surface. C-level
/// FYEC_* codes map into this set.
pub const YamlError = error{
    /// Input violates YAML syntax (bad token, bad indentation, ...).
    InvalidSyntax,
    /// Input is not valid UTF-8.
    InvalidUtf8,
    /// Bad escape sequence in a double quoted scalar.
    InvalidEscape,
    /// Malformed block scalar header or indentation indicator.
    InvalidIndentation,
    /// An alias references an anchor that was never defined.
    UnknownAlias,
    /// %YAML version directive with an unsupported value.
    UnsupportedVersion,
    /// Quoted scalar was not terminated before EOF. Unterminated flow
    /// collections surface as `InvalidSyntax`.
    Unterminated,
    /// Collection nesting exceeds the scanner's `max_nesting` limit.
    NestingTooDeep,
    /// Alias would create a reference cycle during expansion.
    AliasCycle,
    /// A codepoint being encoded has no UTF-8 representation (a
    /// surrogate half or a value above U+10FFFF).
    InvalidCodepoint,
};

/// Diagnostic collector — the fy_diag equivalent.
///
/// Ownership: the collector owns every message it emits, allocated
/// through `allocator` (which may itself be arena-backed; freeing into an
/// arena is then a harmless no-op). `deinit` frees every message and the
/// list storage; there is no per-message free because diagnostics share
/// one lifetime in practice. Rendering allocates through a caller
/// supplied allocator and never touches collector storage, so a `Diag`
/// can be rendered while other code keeps emitting.
pub const Diag = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(Diagnostic) = .empty,

    pub fn deinit(self: *Diag) void {
        for (self.list.items) |d| self.allocator.free(d.message);
        self.list.deinit(self.allocator);
    }

    /// Format one message and append it to the collector. The message
    /// is allocated through the collector's allocator and freed in
    /// `deinit`; on append failure the message is released and the
    /// error propagates.
    pub fn emit(self: *Diag, level: Level, mark: Mark, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(msg);
        try self.list.append(self.allocator, .{ .level = level, .mark = mark, .message = msg });
    }

    /// Render all diagnostics into a freshly allocated string, one line
    /// per message in `line:col: level: message` shape. Messages render
    /// in full regardless of length; the caller owns and must free the
    /// result with `allocator`.
    pub fn render(self: *const Diag, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        for (self.list.items) |d| {
            try buf.print(allocator, "{d}:{d}: {s}: {s}\n", .{
                d.mark.line, d.mark.column, d.level.name(), d.message,
            });
        }
        return buf.toOwnedSlice(allocator);
    }
};

/// Record a diagnostic when a collector is attached, best-effort: a
/// lost diagnostic must never mask the real error being returned.
/// Scanner and parser report through this on every failure path.
pub fn emitBestEffort(d: ?*Diag, level: Level, mark: Mark, comptime fmt: []const u8, args: anytype) void {
    if (d) |dd| dd.emit(level, mark, fmt, args) catch {};
}

test "diag render" {
    const allocator = std.testing.allocator;
    var d: Diag = .{ .allocator = allocator };
    defer d.deinit();
    try d.emit(.err, .{ .line = 2, .column = 5 }, "expected {s}, got {s}", .{ "key", "-" });
    const text = try d.render(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("2:5: error: expected key, got -\n", text);
}

test "empty diag renders empty string" {
    const allocator = std.testing.allocator;
    var d: Diag = .{ .allocator = allocator };
    defer d.deinit();
    const text = try d.render(allocator);
    defer allocator.free(text);
    try std.testing.expectEqual(@as(usize, 0), text.len);
}

test "render preserves long and unicode messages in full" {
    const allocator = std.testing.allocator;
    var d: Diag = .{ .allocator = allocator };
    defer d.deinit();

    // Longer than any historical fixed-size render buffer (was 4096).
    const long = try allocator.alloc(u8, 10_000);
    defer allocator.free(long);
    @memset(long, 'x');
    try d.emit(.warning, .{ .line = 1, .column = 1 }, "long: {s}", .{long});
    try d.emit(.notice, .{ .line = 3, .column = 7 }, "unicode: {s}", .{"\u{4E2D}\u{6587}\u{1F600}"});

    const text = try d.render(allocator);
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, long) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "unicode: \u{4E2D}\u{6587}\u{1F600}") != null);
    // Both lines carry their level name; no truncation anywhere.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "1:1: warning: long:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "3:7: notice: unicode:") != null);
}

fn diagAllocatingOperations(allocator: std.mem.Allocator) !void {
    var d: Diag = .{ .allocator = allocator };
    defer d.deinit();
    try d.emit(.err, Mark.start, "first {d}", .{1});
    try d.emit(.info, .{ .line = 9, .column = 9, .offset = 42 }, "second {s}", .{"two"});
    const text = try d.render(allocator);
    defer allocator.free(text);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "\n"));
}

test "allocation failures leak nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, diagAllocatingOperations, .{});
}
