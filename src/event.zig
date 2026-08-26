//! Event definitions — Zig port of libfyaml's fy-event (FYET_*).
//!
//! The parser is event based like libfyaml: scanning produces tokens, the
//! state machine folds tokens into events, and the document builder turns
//! the event stream into a node tree.

const diag = @import("diag.zig");
const token_mod = @import("token.zig");

const Mark = diag.Mark;
pub const ScalarStyle = token_mod.ScalarStyle;
pub const TagDirective = token_mod.TagDirective;
pub const VersionDirective = token_mod.VersionDirective;

pub const EventType = enum {
    stream_start,
    stream_end,
    document_start,
    document_end,
    sequence_start,
    sequence_end,
    mapping_start,
    mapping_end,
    scalar,
    alias,
};

pub const CollectionStyle = enum { block, flow };

pub const Event = struct {
    type: EventType,
    start: Mark,
    end: Mark,
    data: Data = .{ .none = {} },

    pub const Data = union(enum) {
        none: void,
        document_start: struct {
            version: ?VersionDirective,
            tags: []const TagDirective,
            implicit: bool,
        },
        document_end: struct {
            implicit: bool,
        },
        scalar: ScalarEvent,
        alias: []const u8,
        collection_start: CollectionStart,
    };

    pub const ScalarEvent = struct {
        value: []const u8,
        style: ScalarStyle,
        anchor: ?[]const u8,
        tag: ?[]const u8,
    };

    pub const CollectionStart = struct {
        style: CollectionStyle,
        anchor: ?[]const u8,
        tag: ?[]const u8,
    };
};
