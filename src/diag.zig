//! Marks and diagnostics — Zig port of libfyaml's fy-diag.
//!
//! Every parse/emit error carries a `Mark` (line/column/byte offset into the
//! input) plus a human readable message, mirroring fy_diag behaviour.

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
    /// Token appears where the grammar does not allow it.
    UnexpectedToken,
    /// The same anchor name was defined twice in one document.
    DuplicateAnchor,
    /// An alias references an anchor that was never defined.
    UnknownAlias,
    /// Malformed or unsupported directive.
    InvalidDirective,
    /// %YAML version directive with an unsupported value.
    UnsupportedVersion,
    /// Quoted scalar or flow collection was not terminated before EOF.
    Unterminated,
    /// A simple key would exceed the maximum allowed length.
    KeyTooLong,
    /// Alias would create a reference cycle during expansion.
    AliasCycle,
};

/// Diagnostic collector — the fy_diag equivalent.
///
/// Ownership: the collector owns every message it emits, allocated
/// through `alloc` (which may itself be arena-backed; freeing into an
/// arena is then a harmless no-op). `deinit` frees every message and the
/// list storage; there is no per-message free because diagnostics share
/// one lifetime in practice. Rendering allocates through a caller
/// supplied allocator and never touches collector storage, so a `Diag`
/// can be rendered while other code keeps emitting.
pub const Diag = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList(Diagnostic) = .empty,

    pub fn deinit(self: *Diag) void {
        for (self.list.items) |d| self.alloc.free(d.message);
        self.list.deinit(self.alloc);
    }

    pub fn emit(self: *Diag, level: Level, mark: Mark, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.alloc, fmt, args);
        errdefer self.alloc.free(msg);
        try self.list.append(self.alloc, .{ .level = level, .mark = mark, .message = msg });
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

test "diag render" {
    const alloc = std.testing.allocator;
    var d: Diag = .{ .alloc = alloc };
    defer d.deinit();
    try d.emit(.err, .{ .line = 2, .column = 5 }, "expected {s}, got {s}", .{ "key", "-" });
    const text = try d.render(alloc);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("2:5: error: expected key, got -\n", text);
}

test "empty diag renders empty string" {
    const alloc = std.testing.allocator;
    var d: Diag = .{ .alloc = alloc };
    defer d.deinit();
    const text = try d.render(alloc);
    defer alloc.free(text);
    try std.testing.expectEqual(@as(usize, 0), text.len);
}

test "render preserves long and unicode messages in full" {
    const alloc = std.testing.allocator;
    var d: Diag = .{ .alloc = alloc };
    defer d.deinit();

    // Longer than any historical fixed-size render buffer (was 4096).
    const long = try alloc.alloc(u8, 10_000);
    defer alloc.free(long);
    @memset(long, 'x');
    try d.emit(.warning, .{ .line = 1, .column = 1 }, "long: {s}", .{long});
    try d.emit(.notice, .{ .line = 3, .column = 7 }, "unicode: {s}", .{"\u{4E2D}\u{6587}\u{1F600}"});

    const text = try d.render(alloc);
    defer alloc.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, long) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "unicode: \u{4E2D}\u{6587}\u{1F600}") != null);
    // Both lines carry their level name; no truncation anywhere.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "1:1: warning: long:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "3:7: notice: unicode:") != null);
}

fn diagAllocatingOperations(alloc: std.mem.Allocator) !void {
    var d: Diag = .{ .alloc = alloc };
    defer d.deinit();
    try d.emit(.err, Mark.start, "first {d}", .{1});
    try d.emit(.info, .{ .line = 9, .column = 9, .offset = 42 }, "second {s}", .{"two"});
    const text = try d.render(alloc);
    defer alloc.free(text);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "\n"));
}

test "allocation failures leak nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, diagAllocatingOperations, .{});
}
