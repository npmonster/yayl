//! Marks and diagnostics — Zig port of libfyaml's fy-diag.
//!
//! Every parse/emit error carries a `Mark` (line/column/byte offset into the
//! input) plus a human readable message, mirroring fy_diag behaviour.

const std = @import("std");

/// A position inside the input stream.
///
/// Corresponds to fy_mark: `line` and `column` are 1-based and count
/// codepoints (not bytes); `offset` is the 0-based byte offset.
pub const Mark = struct {
    line: usize = 1,
    column: usize = 1,
    offset: usize = 0,

    pub const zero: Mark = .{};
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

/// One diagnostic message, owned by the arena of the parser that created it.
pub const Diagnostic = struct {
    level: Level,
    mark: Mark,
    message: []const u8,
};

/// The complete error surface of the library. Fallible functions return one
/// of these (plus `error.OutOfMemory`). C-level FYEC_* codes collapse into
/// this set; the human readable detail lives in the diagnostic list.
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

/// Diagnostic collector — the fy_diag equivalent. Diagnostics are allocated
/// from the caller supplied arena so they share the parser's lifetime.
pub const Diag = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList(Diagnostic) = .empty,

    pub fn deinit(self: *Diag) void {
        for (self.list.items) |d| self.alloc.free(d.message);
        self.list.deinit(self.alloc);
    }

    pub fn emit(self: *Diag, level: Level, mark: Mark, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.alloc, fmt, args);
        try self.list.append(self.alloc, .{ .level = level, .mark = mark, .message = msg });
    }

    /// Render all diagnostics into a freshly allocated string, one line per
    /// message in `line:col: level: message` shape.
    pub fn render(self: *const Diag, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        var line: [4096]u8 = undefined;
        for (self.list.items) |d| {
            const text = std.fmt.bufPrint(&line, "{d}:{d}: {s}: {s}\n", .{
                d.mark.line, d.mark.column, d.level.name(), d.message,
            }) catch &line[0..0].*;
            try buf.appendSlice(allocator, text);
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
