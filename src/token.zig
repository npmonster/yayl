//! Token definitions — Zig port of libfyaml's fy_scan token types (FYTT_*).
//!
//! The token set mirrors libfyaml/libyaml one-to-one so the parser state
//! machine can be converted mechanically.

const std = @import("std");
const diag = @import("diag.zig");

const Mark = diag.Mark;

/// FYTT_* token types.
pub const TokenType = enum {
    stream_start,
    stream_end,
    document_start,
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
    alias,
    anchor,
    tag,
    scalar,
    directive,
};

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

pub const Token = struct {
    type: TokenType,
    start: Mark,
    end: Mark,
    data: Data = .{ .none = {} },

    pub const Data = union(enum) {
        none: void,
        /// SCALAR token.
        scalar: struct {
            value: []const u8,
            style: ScalarStyle,
        },
        /// ANCHOR token payload: the anchor name (without '&').
        anchor: []const u8,
        /// ALIAS token payload: the alias name (without '*').
        alias: []const u8,
        /// TAG token payload: handle ("!", "!!", "!name!" or "" for verbatim)
        /// and suffix.
        tag: struct {
            handle: []const u8,
            suffix: []const u8,
        },
        /// DOCUMENT_START payload; `explicit_marker` is false when the
        /// document started implicitly (no `---`).
        document_start: struct {
            explicit_marker: bool,
        },
        /// DIRECTIVE payload: name and parameters.
        directive: struct {
            name: []const u8,
            params: []const []const u8,
        },
    };

    pub fn typeName(self: Token) []const u8 {
        return @tagName(self.type);
    }
};

test "token payload sanity" {
    var t = Token{
        .type = .scalar,
        .start = .{},
        .end = .{},
        .data = .{ .scalar = .{ .value = "x", .style = .plain } },
    };
    try std.testing.expectEqualStrings("x", t.data.scalar.value);
    try std.testing.expectEqualStrings("scalar", t.typeName());
}
