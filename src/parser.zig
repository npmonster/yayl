//! Parser — Zig port of libfyaml's fy-parse.
//!
//! Folds the scanner's token stream into an event stream using the classic
//! YAML grammar state machine. The C code uses setjmp/longjmp for error
//! recovery; the port returns Zig errors and unwinds naturally.

const std = @import("std");
const ctype = @import("ctype.zig");
const diag = @import("diag.zig");
const event_mod = @import("event.zig");
const scanner_mod = @import("scanner.zig");
const token_mod = @import("token.zig");

const Diag = diag.Diag;
const Mark = diag.Mark;
const YamlError = diag.YamlError;
const Event = event_mod.Event;
const EventKind = event_mod.Event.Kind;
const CollectionStyle = event_mod.CollectionStyle;
const ScalarStyle = token_mod.ScalarStyle;
const Scanner = scanner_mod.Scanner;
const Token = token_mod.Token;
const TokenKind = token_mod.Token.Kind;
const TagDirective = token_mod.TagDirective;
const VersionDirective = token_mod.VersionDirective;

/// Parser state-machine states (fy-parse port).
pub const State = enum {
    stream_start,
    implicit_document_start,
    document_start,
    document_content,
    document_end,
    block_node,
    block_node_or_indentless_sequence,
    flow_node,
    block_sequence_first_entry,
    block_sequence_entry,
    indentless_sequence_entry,
    block_mapping_first_key,
    block_mapping_key,
    block_mapping_value,
    flow_sequence_first_entry,
    flow_sequence_entry,
    flow_sequence_entry_mapping_key,
    flow_sequence_entry_mapping_value,
    flow_sequence_entry_mapping_end,
    flow_mapping_first_key,
    flow_mapping_key,
    flow_mapping_value,
    flow_mapping_empty_value,
    end,
};

/// Event parser: folds the scanner's token stream into events.
pub const Parser = struct {
    allocator: std.mem.Allocator,
    d: ?*Diag,
    scanner: Scanner,
    state: State = .stream_start,
    states: std.ArrayList(State) = .empty,
    marks: std.ArrayList(Mark) = .empty,
    /// Active %TAG directives of the current document (including the two
    /// default handles). Used to resolve shorthand tags while parsing nodes.
    tag_directives: std.ArrayList(TagDirective) = .empty,
    version_directive: ?VersionDirective = null,
    /// Transient allocations owned by the parser (resolved tags, directive
    /// snapshots handed to events). Valid until `deinit`.
    temp_bytes: std.ArrayList([]u8) = .empty,
    temp_tags: std.ArrayList([]TagDirective) = .empty,

    /// Parse `input` under the default `scanner.Options`.
    pub fn init(allocator: std.mem.Allocator, d: ?*Diag, input: []const u8) !Parser {
        return initOpts(allocator, d, input, .{});
    }

    /// `init` with explicit bounds and input policy.
    pub fn initOpts(allocator: std.mem.Allocator, d: ?*Diag, input: []const u8, options: scanner_mod.Options) !Parser {
        return .{
            .allocator = allocator,
            .d = d,
            .scanner = try Scanner.initOpts(allocator, d, input, options),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.scanner.deinit();
        self.states.deinit(self.allocator);
        self.marks.deinit(self.allocator);
        self.tag_directives.deinit(self.allocator);
        for (self.temp_bytes.items) |buf| self.allocator.free(buf);
        self.temp_bytes.deinit(self.allocator);
        for (self.temp_tags.items) |t| self.allocator.free(t);
        self.temp_tags.deinit(self.allocator);
    }

    fn trackBytes(self: *Parser, s: []u8) ![]u8 {
        errdefer self.allocator.free(s);
        try self.temp_bytes.append(self.allocator, s);
        return s;
    }

    fn trackTags(self: *Parser, s: []TagDirective) ![]TagDirective {
        errdefer self.allocator.free(s);
        try self.temp_tags.append(self.allocator, s);
        return s;
    }

    /// Produce the next event. Returns null once the stream end event has
    /// been delivered. Events stay valid until the parser is deinited.
    pub fn nextEvent(self: *Parser) !?Event {
        if (self.state == .end) return null;
        const ev: Event = switch (self.state) {
            .stream_start => try self.parseStreamStart(),
            .implicit_document_start => try self.parseDocumentStart(true),
            .document_start => try self.parseDocumentStart(false),
            .document_content => try self.parseDocumentContent(),
            .document_end => try self.parseDocumentEnd(),
            .block_node => try self.parseNode(true, false),
            .block_node_or_indentless_sequence => try self.parseNode(true, true),
            .flow_node => try self.parseNode(false, false),
            .block_sequence_first_entry => try self.parseBlockSequenceEntry(true),
            .block_sequence_entry => try self.parseBlockSequenceEntry(false),
            .indentless_sequence_entry => try self.parseIndentlessSequenceEntry(),
            .block_mapping_first_key => try self.parseBlockMappingKey(true),
            .block_mapping_key => try self.parseBlockMappingKey(false),
            .block_mapping_value => try self.parseBlockMappingValue(),
            .flow_sequence_first_entry => try self.parseFlowSequenceEntry(true),
            .flow_sequence_entry => try self.parseFlowSequenceEntry(false),
            .flow_sequence_entry_mapping_key => try self.parseFlowSequenceEntryMappingKey(),
            .flow_sequence_entry_mapping_value => try self.parseFlowSequenceEntryMappingValue(),
            .flow_sequence_entry_mapping_end => try self.parseFlowSequenceEntryMappingEnd(),
            .flow_mapping_first_key => try self.parseFlowMappingKey(true),
            .flow_mapping_key => try self.parseFlowMappingKey(false),
            .flow_mapping_value => try self.parseFlowMappingValue(false),
            .flow_mapping_empty_value => try self.parseFlowMappingValue(true),
            .end => unreachable,
        };
        return ev;
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    fn fail(self: *Parser, mark: Mark, comptime fmt: []const u8, args: anytype) YamlError {
        diag.emitBestEffort(self.d, .err, mark, fmt, args);
        return error.InvalidSyntax;
    }

    fn peekToken(self: *Parser) !Token {
        return (try self.scanner.peekToken()) orelse
            self.fail(self.scanner.mark, "unexpected end of token stream", .{});
    }

    fn pushState(self: *Parser, s: State) !void {
        try self.states.append(self.allocator, s);
    }

    fn popState(self: *Parser) State {
        return self.states.pop().?;
    }

    fn pushMark(self: *Parser, m: Mark) !void {
        try self.marks.append(self.allocator, m);
    }

    fn processEmptyScalar(self: *Parser, mark: Mark) Event {
        _ = self;
        return .{
            .start = mark,
            .end = mark,
            .data = .{ .scalar = .{ .value = "", .style = .plain, .anchor = null, .tag = null, .synthetic = true } },
        };
    }

    // ------------------------------------------------------------------
    // Stream / document level states
    // ------------------------------------------------------------------

    fn parseStreamStart(self: *Parser) !Event {
        const tok = try self.peekToken();
        if (tok.data != .stream_start) {
            return self.fail(tok.start, "did not find expected <stream-start>", .{});
        }
        self.scanner.skipToken();
        self.state = .implicit_document_start;
        return .{ .data = .stream_start, .start = tok.start, .end = tok.end };
    }

    fn parseDocumentStart(self: *Parser, implicit_allowed: bool) !Event {
        var tok = try self.peekToken();
        // Extra '...' indicators are skipped wherever a document may
        // start; after one was seen the following document is implicit
        // (libfyaml had_doc_end semantics).
        var had_doc_end = false;
        while (tok.data == .document_end) {
            self.scanner.skipToken();
            tok = try self.peekToken();
            had_doc_end = true;
        }

        // Explicit document: directives and/or a '---' marker.
        if (tok.data == .directive or tok.data == .document_start) {
            // Directives are only allowed at the start of the stream or
            // after a '...' marker (corpus EB22/RHX7).
            if (tok.data == .directive and !(implicit_allowed or had_doc_end)) {
                return self.fail(tok.start, "found directive without preceding document end marker", .{});
            }
            try self.processDirectives();
            tok = try self.peekToken();
            if (tok.data != .document_start) {
                return self.fail(tok.start, "did not find expected <document start>", .{});
            }
            self.scanner.skipToken();
            try self.pushState(.document_end);
            self.state = .document_content;
            return .{
                .start = tok.start,
                .end = tok.end,
                .data = .{ .document_start = .{
                    .version = self.version_directive,
                    .tags = try self.trackTags(try self.allocator.dupe(TagDirective, self.tag_directives.items)),
                    .implicit = false,
                } },
            };
        }

        if (tok.data == .stream_end) {
            // End of stream.
            self.scanner.skipToken();
            self.state = .end;
            return Event{ .data = .stream_end, .start = tok.start, .end = tok.end };
        }

        // Bare content: an implicit document, either because the stream
        // allows one or because a '...' marker was just skipped.
        if (implicit_allowed or had_doc_end) {
            try self.prepareDirectives();
            try self.pushState(.document_end);
            self.state = .document_content;
            return .{
                .start = tok.start,
                .end = tok.start,
                .data = .{ .document_start = .{
                    .version = self.version_directive,
                    .tags = try self.trackTags(try self.allocator.dupe(TagDirective, self.tag_directives.items)),
                    .implicit = true,
                } },
            };
        }

        return self.fail(tok.start, "did not find expected <document start>", .{});
    }

    fn parseDocumentContent(self: *Parser) !Event {
        const tok = try self.peekToken();
        switch (tok.data) {
            .directive, .document_start, .document_end, .stream_end => {
                self.state = self.popState();
                return self.processEmptyScalar(tok.start);
            },
            else => return self.parseNode(true, false),
        }
    }

    fn parseDocumentEnd(self: *Parser) !Event {
        const tok = try self.peekToken();
        var implicit = true;
        if (tok.data == .document_end) {
            // Do not consume the '...' here: the next document-start
            // skips it and treats the following document as implicit.
            implicit = false;
        }
        // Directive state is per-document (fy_parse resets between docs).
        self.tag_directives.clearRetainingCapacity();
        self.version_directive = null;
        self.state = .document_start;
        return .{
            .start = tok.start,
            .end = tok.start,
            .data = .{ .document_end = .{ .implicit = implicit } },
        };
    }

    /// Fill `tag_directives` with just the two default handles.
    fn prepareDirectives(self: *Parser) !void {
        self.tag_directives.clearRetainingCapacity();
        self.version_directive = null;
        try self.tag_directives.appendSlice(self.allocator, &.{
            .{ .handle = "!", .prefix = "!" },
            .{ .handle = "!!", .prefix = "tag:yaml.org,2002:" },
        });
    }

    /// Consume directive tokens, validating them, then make sure the
    /// default tag handles are present.
    fn processDirectives(self: *Parser) !void {
        self.tag_directives.clearRetainingCapacity();
        self.version_directive = null;

        while (true) {
            const tok = try self.peekToken();
            if (tok.data != .directive) break;
            const d = tok.data.directive;
            if (std.mem.eql(u8, d.name, "YAML")) {
                if (self.version_directive != null) {
                    return self.fail(tok.start, "found duplicate %YAML directive", .{});
                }
                if (d.params.len != 1) {
                    return self.fail(tok.start, "found malformed %YAML directive", .{});
                }
                const p = d.params[0];
                if (p.len < 3 or p[0] != '1' or p[1] != '.') {
                    return self.failWith(error.UnsupportedVersion, tok.start, "found incompatible YAML document version '{s}'", .{p});
                }
                var minor: u8 = 0;
                for (p[2..]) |ch| {
                    if (ch < '0' or ch > '9') {
                        return self.fail(tok.start, "found malformed %YAML directive", .{});
                    }
                    minor = minor * 10 + (ch - '0');
                }
                self.version_directive = .{ .major = 1, .minor = minor };
            } else if (std.mem.eql(u8, d.name, "TAG")) {
                if (d.params.len != 2) {
                    return self.fail(tok.start, "found malformed %TAG directive", .{});
                }
                for (self.tag_directives.items) |td| {
                    if (std.mem.eql(u8, td.handle, d.params[0])) {
                        return self.fail(tok.start, "found duplicate %TAG directive", .{});
                    }
                }
                try self.tag_directives.append(self.allocator, .{
                    .handle = d.params[0],
                    .prefix = d.params[1],
                });
            } else {
                // Unknown directives are ignored; the spec asks for a
                // warning only (YAML 1.2.2 6.8).
                diag.emitBestEffort(self.d, .warning, tok.start, "found unknown directive name '{s}'", .{d.name});
            }
            self.scanner.skipToken();
        }

        // Ensure the two default handles exist.
        var have_bang = false;
        var have_bangbang = false;
        for (self.tag_directives.items) |td| {
            if (std.mem.eql(u8, td.handle, "!")) have_bang = true;
            if (std.mem.eql(u8, td.handle, "!!")) have_bangbang = true;
        }
        if (!have_bang) try self.tag_directives.append(self.allocator, .{ .handle = "!", .prefix = "!" });
        if (!have_bangbang) try self.tag_directives.append(self.allocator, .{ .handle = "!!", .prefix = "tag:yaml.org,2002:" });
    }

    fn failWith(self: *Parser, err: YamlError, mark: Mark, comptime fmt: []const u8, args: anytype) YamlError {
        diag.emitBestEffort(self.d, .err, mark, fmt, args);
        return err;
    }

    /// Resolve a tag shorthand (handle + suffix) to its full URI.
    fn resolveTag(self: *Parser, handle: []const u8, suffix: []const u8) ![]const u8 {
        if (handle.len == 0) {
            // Verbatim tag.
            return self.trackBytes(try self.allocator.dupe(u8, suffix));
        }
        for (self.tag_directives.items) |td| {
            if (std.mem.eql(u8, td.handle, handle)) {
                var out: std.ArrayList(u8) = .empty;
                errdefer out.deinit(self.allocator);
                try out.appendSlice(self.allocator, td.prefix);
                // Tag suffixes are RFC 2396: %XX escapes are unescaped
                // when the tag is resolved.
                var i: usize = 0;
                while (i < suffix.len) {
                    if (suffix[i] == '%' and i + 3 <= suffix.len and
                        ctype.hexValue(suffix[i + 1]) != null and
                        ctype.hexValue(suffix[i + 2]) != null)
                    {
                        const hi = ctype.hexValue(suffix[i + 1]).?;
                        const lo = ctype.hexValue(suffix[i + 2]).?;
                        try out.append(self.allocator, (hi << 4) | lo);
                        i += 3;
                    } else {
                        try out.append(self.allocator, suffix[i]);
                        i += 1;
                    }
                }
                return self.trackBytes(try out.toOwnedSlice(self.allocator));
            }
        }
        return self.fail(self.scanner.mark, "found undefined tag handle '{s}'", .{handle});
    }

    // ------------------------------------------------------------------
    // Node parsing
    // ------------------------------------------------------------------

    fn parseNode(self: *Parser, block: bool, indentless_sequence: bool) !Event {
        var tok = try self.peekToken();

        if (tok.data == .alias) {
            self.scanner.skipToken();
            self.state = self.popState();
            return .{
                .start = tok.start,
                .end = tok.end,
                .data = .{ .alias = tok.data.alias },
            };
        }

        const start_mark = tok.start;
        var anchor: ?[]const u8 = null;
        var tag_handle: ?[]const u8 = null;
        var tag_suffix: ?[]const u8 = null;

        if (tok.data == .anchor) {
            anchor = tok.data.anchor;
            self.scanner.skipToken();
            tok = try self.peekToken();
        }
        if (tok.data == .tag) {
            tag_handle = tok.data.tag.handle;
            tag_suffix = tok.data.tag.suffix;
            self.scanner.skipToken();
            tok = try self.peekToken();
            if (tok.data == .anchor) {
                if (anchor != null) {
                    return self.fail(tok.start, "found duplicate anchor", .{});
                }
                anchor = tok.data.anchor;
                self.scanner.skipToken();
                tok = try self.peekToken();
            }
        }

        var tag: ?[]const u8 = null;
        if (tag_handle) |h| {
            tag = try self.resolveTag(h, tag_suffix orelse "");
        }

        switch (tok.data) {
            .scalar => {
                self.scanner.skipToken();
                self.state = self.popState();
                return .{
                    .start = start_mark,
                    .end = tok.end,
                    .data = .{ .scalar = .{
                        .value = tok.data.scalar.value,
                        .style = tok.data.scalar.style,
                        .anchor = anchor,
                        .tag = tag,
                    } },
                };
            },
            .flow_sequence_start => {
                self.state = .flow_sequence_first_entry;
                try self.pushMark(tok.start);
                return .{
                    .start = start_mark,
                    .end = tok.end,
                    .data = .{ .sequence_start = .{ .style = .flow, .anchor = anchor, .tag = tag } },
                };
            },
            .flow_mapping_start => {
                self.state = .flow_mapping_first_key;
                try self.pushMark(tok.start);
                return .{
                    .start = start_mark,
                    .end = tok.end,
                    .data = .{ .mapping_start = .{ .style = .flow, .anchor = anchor, .tag = tag } },
                };
            },
            else => {},
        }
        if (block and tok.data == .block_sequence_start) {
            self.state = .block_sequence_first_entry;
            try self.pushMark(tok.start);
            return .{
                .start = start_mark,
                .end = tok.end,
                .data = .{ .sequence_start = .{ .style = .block, .anchor = anchor, .tag = tag } },
            };
        }
        if (block and tok.data == .block_mapping_start) {
            self.state = .block_mapping_first_key;
            try self.pushMark(tok.start);
            return .{
                .start = start_mark,
                .end = tok.end,
                .data = .{ .mapping_start = .{ .style = .block, .anchor = anchor, .tag = tag } },
            };
        }
        if (block and indentless_sequence and tok.data == .block_entry) {
            self.state = .indentless_sequence_entry;
            try self.pushMark(tok.start);
            return .{
                .start = start_mark,
                .end = tok.end,
                .data = .{ .sequence_start = .{ .style = .block, .anchor = anchor, .tag = tag } },
            };
        }

        // Anchor or tag with no content means an empty plain scalar.
        if (anchor != null or tag != null) {
            self.state = self.popState();
            return .{
                .start = start_mark,
                .end = tok.start,
                .data = .{ .scalar = .{ .value = "", .style = .plain, .anchor = anchor, .tag = tag } },
            };
        }

        return self.fail(tok.start, "did not find expected node content", .{});
    }

    // ------------------------------------------------------------------
    // Block sequences and mappings
    // ------------------------------------------------------------------

    fn parseBlockSequenceEntry(self: *Parser, first: bool) !Event {
        var tok = try self.peekToken();
        if (first and tok.data == .block_sequence_start) {
            self.scanner.skipToken();
            tok = try self.peekToken();
        }
        if (tok.data == .block_entry) {
            self.scanner.skipToken();
            tok = try self.peekToken();
            if (tok.data != .block_entry and tok.data != .block_end) {
                try self.pushState(.block_sequence_entry);
                return self.parseNode(true, false);
            }
            self.state = .block_sequence_entry;
            return self.processEmptyScalar(tok.start);
        }
        if (tok.data == .block_end) {
            self.scanner.skipToken();
            self.state = self.popState();
            _ = self.marks.pop();
            return .{ .data = .sequence_end, .start = tok.start, .end = tok.end };
        }
        return self.fail(tok.start, "did not find expected '-' indicator", .{});
    }

    fn parseIndentlessSequenceEntry(self: *Parser) !Event {
        var tok = try self.peekToken();
        if (tok.data == .block_entry) {
            self.scanner.skipToken();
            tok = try self.peekToken();
            if (tok.data != .block_entry and tok.data != .key and
                tok.data != .value and tok.data != .block_end)
            {
                try self.pushState(.indentless_sequence_entry);
                return self.parseNode(true, false);
            }
            self.state = .indentless_sequence_entry;
            return self.processEmptyScalar(tok.start);
        }
        self.state = self.popState();
        _ = self.marks.pop();
        return .{ .data = .sequence_end, .start = tok.start, .end = tok.start };
    }

    fn parseBlockMappingKey(self: *Parser, first: bool) !Event {
        var tok = try self.peekToken();
        if (first and tok.data == .block_mapping_start) {
            self.scanner.skipToken();
            tok = try self.peekToken();
        }
        if (tok.data == .key) {
            self.scanner.skipToken();
            tok = try self.peekToken();
            if (tok.data != .key and tok.data != .value and tok.data != .block_end) {
                // Indentless sequences are allowed in key position too
                // (corpus 6PBE: `?` followed by a zero-indented
                // sequence), matching libyaml's parse_node(1, 1).
                try self.pushState(.block_mapping_value);
                return self.parseNode(true, true);
            }
            self.state = .block_mapping_value;
            return self.processEmptyScalar(tok.start);
        }
        if (tok.data == .value) {
            // Missing (empty) key.
            self.state = .block_mapping_value;
            return self.processEmptyScalar(tok.start);
        }
        if (tok.data == .block_end) {
            self.scanner.skipToken();
            self.state = self.popState();
            _ = self.marks.pop();
            return .{ .data = .mapping_end, .start = tok.start, .end = tok.end };
        }
        return self.fail(tok.start, "did not find expected key", .{});
    }

    fn parseBlockMappingValue(self: *Parser) !Event {
        var tok = try self.peekToken();
        if (tok.data == .value) {
            self.scanner.skipToken();
            tok = try self.peekToken();
            if (tok.data != .key and tok.data != .value and tok.data != .block_end) {
                try self.pushState(.block_mapping_key);
                return self.parseNode(true, true);
            }
            self.state = .block_mapping_key;
            return self.processEmptyScalar(tok.start);
        }
        self.state = .block_mapping_key;
        return self.processEmptyScalar(tok.start);
    }

    // ------------------------------------------------------------------
    // Flow collections
    // ------------------------------------------------------------------

    fn parseFlowSequenceEntry(self: *Parser, first: bool) !Event {
        var tok = try self.peekToken();
        if (first and tok.data == .flow_sequence_start) {
            self.scanner.skipToken();
            tok = try self.peekToken();
        }
        if (tok.data != .flow_sequence_end) {
            if (!first) {
                if (tok.data == .flow_entry) {
                    self.scanner.skipToken();
                    tok = try self.peekToken();
                } else {
                    return self.fail(tok.start, "did not find expected ',' or ']'", .{});
                }
            }
            if (tok.data != .flow_sequence_end) {
                if (tok.data == .value) {
                    // Empty-key single-pair mapping inside a flow sequence:
                    // [: value] (corpus CFD4). The ':' is not consumed here.
                    self.state = .flow_sequence_entry_mapping_key;
                    try self.pushMark(tok.start);
                    return .{
                        .start = tok.start,
                        .end = tok.start,
                        .data = .{ .mapping_start = .{ .style = .flow, .anchor = null, .tag = null } },
                    };
                }
                if (tok.data == .key) {
                    // Single-pair mapping inside a flow sequence: [a: b].
                    self.scanner.skipToken();
                    self.state = .flow_sequence_entry_mapping_key;
                    try self.pushMark(tok.start);
                    return .{
                        .start = tok.start,
                        .end = tok.start,
                        .data = .{ .mapping_start = .{ .style = .flow, .anchor = null, .tag = null } },
                    };
                }
                try self.pushState(.flow_sequence_entry);
                return self.parseNode(false, false);
            }
        }
        self.scanner.skipToken();
        self.state = self.popState();
        _ = self.marks.pop();
        return .{ .data = .sequence_end, .start = tok.start, .end = tok.end };
    }

    fn parseFlowSequenceEntryMappingKey(self: *Parser) !Event {
        const tok = try self.peekToken();
        if (tok.data != .value and tok.data != .flow_entry and tok.data != .flow_sequence_end) {
            try self.pushState(.flow_sequence_entry_mapping_value);
            return self.parseNode(false, false);
        }
        self.state = .flow_sequence_entry_mapping_value;
        return self.processEmptyScalar(tok.start);
    }

    fn parseFlowSequenceEntryMappingValue(self: *Parser) !Event {
        var tok = try self.peekToken();
        if (tok.data == .value) {
            self.scanner.skipToken();
            tok = try self.peekToken();
            if (tok.data != .flow_entry and tok.data != .flow_sequence_end) {
                try self.pushState(.flow_sequence_entry_mapping_end);
                return self.parseNode(false, false);
            }
        }
        self.state = .flow_sequence_entry_mapping_end;
        return self.processEmptyScalar(tok.start);
    }

    fn parseFlowSequenceEntryMappingEnd(self: *Parser) !Event {
        const tok = try self.peekToken();
        self.state = .flow_sequence_entry;
        _ = self.marks.pop();
        return .{ .data = .mapping_end, .start = tok.start, .end = tok.start };
    }

    fn parseFlowMappingKey(self: *Parser, first: bool) !Event {
        var tok = try self.peekToken();
        if (first and tok.data == .flow_mapping_start) {
            self.scanner.skipToken();
            tok = try self.peekToken();
        }
        if (tok.data != .flow_mapping_end) {
            if (!first) {
                if (tok.data == .flow_entry) {
                    self.scanner.skipToken();
                    tok = try self.peekToken();
                } else {
                    return self.fail(tok.start, "did not find expected ',' or '}}'", .{});
                }
            }
            if (tok.data == .value) {
                // Empty key: the ':' arrives without a preceding key node
                // (corpus FRK4/NKF9).
                self.state = .flow_mapping_value;
                return self.processEmptyScalar(tok.start);
            }
            if (tok.data == .key) {
                self.scanner.skipToken();
                tok = try self.peekToken();
                if (tok.data != .value and tok.data != .flow_entry and tok.data != .flow_mapping_end) {
                    try self.pushState(.flow_mapping_value);
                    return self.parseNode(false, false);
                }
                self.state = .flow_mapping_value;
                return self.processEmptyScalar(tok.start);
            }
            if (tok.data != .flow_mapping_end) {
                try self.pushState(.flow_mapping_empty_value);
                return self.parseNode(false, false);
            }
        }
        self.scanner.skipToken();
        self.state = self.popState();
        _ = self.marks.pop();
        return .{ .data = .mapping_end, .start = tok.start, .end = tok.end };
    }

    fn parseFlowMappingValue(self: *Parser, empty: bool) !Event {
        var tok = try self.peekToken();
        if (!empty and tok.data == .value) {
            self.scanner.skipToken();
            tok = try self.peekToken();
            if (tok.data != .flow_entry and tok.data != .flow_mapping_end) {
                try self.pushState(.flow_mapping_key);
                return self.parseNode(false, false);
            }
        }
        self.state = .flow_mapping_key;
        return self.processEmptyScalar(tok.start);
    }
};

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

fn eventTypes(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(EventKind) {
    var p = try Parser.init(allocator, null, input);
    defer p.deinit();
    var out: std.ArrayList(EventKind) = .empty;
    errdefer out.deinit(allocator);
    while (try p.nextEvent()) |ev| try out.append(allocator, ev.data);
    return out;
}

test "scalar document events" {
    var evs = try eventTypes(testing.allocator, "hello\n");
    defer evs.deinit(testing.allocator);
    const want: []const EventKind = &.{
        .stream_start, .document_start, .scalar, .document_end, .stream_end,
    };
    try testing.expectEqualSlices(EventKind, want, evs.items);
}

test "mapping events" {
    var evs = try eventTypes(testing.allocator, "a: 1\nb: [2, 3]\n");
    defer evs.deinit(testing.allocator);
    const want: []const EventKind = &.{
        .stream_start, .document_start, .mapping_start,  .scalar,
        .scalar,       .scalar,         .sequence_start, .scalar,
        .scalar,       .sequence_end,   .mapping_end,    .document_end,
        .stream_end,
    };
    try testing.expectEqualSlices(EventKind, want, evs.items);
}

test "indentless sequence events" {
    var evs = try eventTypes(testing.allocator, "a:\n- 1\n- 2\n");
    defer evs.deinit(testing.allocator);
    const want: []const EventKind = &.{
        .stream_start,   .document_start, .mapping_start, .scalar,
        .sequence_start, .scalar,         .scalar,        .sequence_end,
        .mapping_end,    .document_end,   .stream_end,
    };
    try testing.expectEqualSlices(EventKind, want, evs.items);
}

test "alias event" {
    var evs = try eventTypes(testing.allocator, "- &x 1\n- *x\n");
    defer evs.deinit(testing.allocator);
    const want: []const EventKind = &.{
        .stream_start, .document_start, .sequence_start, .scalar,
        .alias,        .sequence_end,   .document_end,   .stream_end,
    };
    try testing.expectEqualSlices(EventKind, want, evs.items);
}

test "explicit document events" {
    var evs = try eventTypes(testing.allocator, "%YAML 1.2\n---\nx\n...\n");
    defer evs.deinit(testing.allocator);
    const want: []const EventKind = &.{
        .stream_start, .document_start, .scalar, .document_end, .stream_end,
    };
    try testing.expectEqualSlices(EventKind, want, evs.items);
}

test "tag resolution" {
    var p = try Parser.init(testing.allocator, null, "a: !!int 42\nb: !<tag:example.com:t> v\n");
    defer p.deinit();
    var tags: std.ArrayList(?[]const u8) = .empty;
    defer tags.deinit(testing.allocator);
    while (try p.nextEvent()) |ev| {
        if (ev.data == .scalar) try tags.append(testing.allocator, ev.data.scalar.tag);
    }
    try testing.expectEqualStrings("tag:yaml.org,2002:int", tags.items[1].?);
    try testing.expectEqualStrings("tag:example.com:t", tags.items[3].?);
}

test "tag shorthand unescapes RFC 2396 escapes" {
    const allocator = testing.allocator;
    var p = try Parser.init(allocator, null, "%TAG !e! tag:example.com,2000:app/\n---\n- !e!tag%21 baz\n");
    defer p.deinit();
    var found = false;
    while (try p.nextEvent()) |ev| {
        if (ev.data == .scalar) {
            try testing.expectEqualStrings("tag:example.com,2000:app/tag!", ev.data.scalar.tag.?);
            found = true;
        }
    }
    try testing.expect(found);
}

test "unknown directives are ignored with a warning" {
    // YAML 1.2.2 6.8: unknown directives are skipped, not an error
    // (corpus 2LFX).
    const allocator = testing.allocator;
    var p = try Parser.init(allocator, null, "%FOO bar baz\n---\nfoo\n");
    defer p.deinit();
    var found = false;
    while (try p.nextEvent()) |ev| {
        if (ev.data == .scalar) {
            try testing.expectEqualStrings("foo", ev.data.scalar.value);
            found = true;
        }
    }
    try testing.expect(found);
}

test "flow mapping empty key" {
    var evs = try eventTypes(testing.allocator, "{: empty key}\n");
    defer evs.deinit(testing.allocator);
    const want: []const EventKind = &.{
        .stream_start, .document_start, .mapping_start, .scalar,
        .scalar,       .mapping_end,    .document_end,  .stream_end,
    };
    try testing.expectEqualSlices(EventKind, want, evs.items);
}

test "flow sequence empty-key single-pair mapping" {
    var evs = try eventTypes(testing.allocator, "- [ : empty key ]\n");
    defer evs.deinit(testing.allocator);
    const want: []const EventKind = &.{
        .stream_start,  .document_start, .sequence_start, .sequence_start,
        .mapping_start, .scalar,         .scalar,         .mapping_end,
        .sequence_end,  .sequence_end,   .document_end,   .stream_end,
    };
    try testing.expectEqualSlices(EventKind, want, evs.items);
}

test "trailing blanks after top-level flow collection parse" {
    const allocator = testing.allocator;
    var p = try Parser.init(allocator, null, "[1, 2, 3]  ");
    defer p.deinit();
    var scalars: usize = 0;
    while (try p.nextEvent()) |ev| {
        if (ev.data == .scalar) scalars += 1;
    }
    try testing.expectEqual(@as(usize, 3), scalars);
}

test "comma after a tag is rejected in block context" {
    // Corpus U99R: '- !!str, xxx' — the tag stops at the comma and the
    // comma itself is not valid block-context content.
    const allocator = testing.allocator;
    var p = try Parser.init(allocator, null, "- !!str, xxx\n");
    defer p.deinit();
    var outcome: ?anyerror = null;
    while (true) {
        const ev = p.nextEvent() catch |err| {
            outcome = err;
            break;
        };
        if (ev == null) break;
    }
    try testing.expectEqual(@as(?anyerror, error.InvalidSyntax), outcome);
}
