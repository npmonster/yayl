//! Token definitions — Zig port of libfyaml's fy_scan token types (FYTT_*).
//!
//! The token set mirrors libfyaml/libyaml one-to-one so the parser state
//! machine can be converted mechanically. A token is a single tagged union:
//! the kind and its payload are one value, so a mismatched type/payload
//! pair cannot be constructed.

const std = @import("std");
const diag = @import("diag.zig");

const Mark = diag.Mark;

/// Scalar presentation, shared by tokens, events and nodes.
pub const ScalarStyle = enum {
    any,
    plain,
    single_quoted,
    double_quoted,
    literal,
    folded,
};

/// A `%TAG <handle> <prefix>` directive.
pub const TagDirective = struct {
    handle: []const u8,
    prefix: []const u8,
};

/// A `%YAML <major>.<minor>` directive.
pub const VersionDirective = struct {
    major: u8,
    minor: u8,
};

/// One scanner token. `start`/`end` are borrowed marks into the input;
/// payload slices are pool/arena-owned by the scanner that produced
/// them and live until its next reset/deinit.
pub const Token = struct {
    data: Data,
    start: Mark,
    end: Mark,

    /// FYTT_* token kinds. Payload-less kinds mirror libfyaml's bare
    /// token types; payloaded kinds carry the scanner-produced data.
    pub const Data = union(enum) {
        stream_start,
        stream_end,
        document_start: DocumentStart,
        document_end,
        block_mapping_start,
        block_sequence_start,
        block_end,
        flow_sequence_start,
        flow_sequence_end,
        flow_mapping_start,
        flow_mapping_end,
        block_entry,
        flow_entry,
        key,
        value,
        /// ALIAS payload: the alias name (without '*').
        alias: []const u8,
        /// ANCHOR payload: the anchor name (without '&').
        anchor: []const u8,
        tag: Tag,
        scalar: Scalar,
        directive: Directive,
    };

    /// The tag enum of `Kind`, for switches and tests that need the
    /// discriminant without the payload.
    pub const Kind = std.meta.Tag(Data);

    /// DOCUMENT_START payload; `explicit_marker` is false when the
    /// document started implicitly (no `---`).
    pub const DocumentStart = struct {
        explicit_marker: bool,
    };

    /// TAG payload: handle ("!", "!!", "!name!" or "" for verbatim)
    /// and suffix.
    pub const Tag = struct {
        handle: []const u8,
        suffix: []const u8,
    };

    /// SCALAR payload.
    pub const Scalar = struct {
        value: []const u8,
        style: ScalarStyle,
    };

    /// DIRECTIVE payload: name and parameters.
    pub const Directive = struct {
        name: []const u8,
        params: []const []const u8,
    };

    pub fn kindName(self: Token) []const u8 {
        return @tagName(self.data);
    }
};

test "token payload sanity" {
    const t = Token{
        .data = .{ .scalar = .{ .value = "x", .style = .plain } },
        .start = .{},
        .end = .{},
    };
    try std.testing.expectEqualStrings("x", t.data.scalar.value);
    try std.testing.expectEqualStrings("scalar", t.kindName());
    try std.testing.expect(t.data == .scalar);
    try std.testing.expectEqual(Token.Kind.scalar, std.meta.activeTag(t.data));
}
