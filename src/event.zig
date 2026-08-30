//! Event definitions — Zig port of libfyaml's fy-event (FYET_*).
//!
//! The parser is event based like libfyaml: scanning produces tokens, the
//! state machine folds tokens into events, and the document builder turns
//! the event stream into a node tree. An event is a single tagged union:
//! the kind and its payload are one value, so a mismatched type/payload
//! pair cannot be constructed.

const std = @import("std");
const diag = @import("diag.zig");
const token_mod = @import("token.zig");

const Mark = diag.Mark;
// Payload types shared with token.zig.
pub const ScalarStyle = token_mod.ScalarStyle;
pub const TagDirective = token_mod.TagDirective;
pub const VersionDirective = token_mod.VersionDirective;

/// Block or flow collection presentation.
pub const CollectionStyle = enum { block, flow };

/// One parser event. `start`/`end` are borrowed marks into the input;
/// payload slices are arena-owned by the parser that produced them and
/// live until its deinit.
pub const Event = struct {
    data: Data,
    start: Mark,
    end: Mark,

    /// FYET_* event kinds.
    pub const Data = union(enum) {
        stream_start,
        stream_end,
        document_start: DocumentStart,
        document_end: DocumentEnd,
        sequence_start: CollectionStart,
        sequence_end,
        mapping_start: CollectionStart,
        mapping_end,
        scalar: ScalarEvent,
        /// ALIAS payload: the alias name (without '*').
        alias: []const u8,
    };

    /// The tag enum of `Kind`, for switches and tests that need the
    /// discriminant without the payload.
    pub const Kind = std.meta.Tag(Data);

    pub const DocumentStart = struct {
        version: ?VersionDirective,
        tags: []const TagDirective,
        implicit: bool,
    };

    pub const DocumentEnd = struct {
        implicit: bool,
    };

    pub const ScalarEvent = struct {
        value: []const u8,
        style: ScalarStyle,
        anchor: ?[]const u8,
        tag: ?[]const u8,
        /// True when the parser synthesized this scalar for a missing
        /// node (empty key/value). Its marks point at the *next* token,
        /// so CST code must never emit its span verbatim.
        synthetic: bool = false,
    };

    pub const CollectionStart = struct {
        style: CollectionStyle,
        anchor: ?[]const u8,
        tag: ?[]const u8,
    };
};

test "event payload sanity" {
    const e = Event{
        .data = .{ .scalar = .{ .value = "v", .style = .plain, .anchor = null, .tag = null } },
        .start = .{},
        .end = .{},
    };
    try std.testing.expectEqualStrings("v", e.data.scalar.value);
    try std.testing.expect(e.data == .scalar);
    try std.testing.expectEqual(Event.Kind.scalar, std.meta.activeTag(e.data));
}
