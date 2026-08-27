//! Scanner — Zig port of libfyaml's fy-scan.
//!
//! Turns the raw UTF-8 input into a queue of tokens. The algorithm mirrors
//! libfyaml (and its libyaml ancestry): indentation is tracked on a stack,
//! each flow level owns one pending "simple key", and BLOCK_*_START /
//! BLOCK_END / KEY tokens are synthesised as the indentation changes.
//!
//! Deviations from the C code are intentional and marked "PORT NOTE".

const std = @import("std");
const ctype = @import("ctype.zig");
const diag = @import("diag.zig");
const token_mod = @import("token.zig");
const utf8 = @import("utf8.zig");

const Diag = diag.Diag;
const Mark = diag.Mark;
const Token = token_mod.Token;
const TokenType = token_mod.Token.Type;
const ScalarStyle = token_mod.ScalarStyle;
const YamlError = diag.YamlError;

/// Maximum number of bytes a simple key may span (YAML 1.2 / libfyaml).
const max_simple_key_length: usize = 1024;

/// YAML tokenizer: turns input bytes into a token stream (fy-scan port).
pub const Scanner = struct {
    alloc: std.mem.Allocator,
    d: ?*Diag,

    input: []const u8,
    pos: usize,
    mark: Mark,

    stream_start_produced: bool = false,
    stream_end_produced: bool = false,

    flow_level: usize = 0,
    last_node_end: bool = false,
    indent: isize = -1,
    indents: std.ArrayList(isize) = .empty,
    simple_key_allowed: bool = true,
    simple_keys: std.ArrayList(SimpleKey) = .empty,

    /// Token queue. `tokens_parsed` is the index of the first not yet
    /// consumed token; `token_base` is the absolute number of element 0,
    /// so compaction never breaks simple key token numbers.
    tokens: std.ArrayList(Token) = .empty,
    tokens_parsed: usize = 0,
    token_base: usize = 0,

    /// Transient buffers owned by the scanner (scalar values, directive
    /// parameter lists). Tokens handed to the parser stay valid until
    /// `deinit`; consumers that need them longer must copy.
    temp_bytes: std.ArrayList([]u8) = .empty,
    temp_params: std.ArrayList([]const []const u8) = .empty,

    pub const SimpleKey = struct {
        possible: bool = false,
        required: bool = false,
        token_number: usize = 0,
        mark: Mark = .{},
    };

    pub fn init(alloc: std.mem.Allocator, d: ?*Diag, input: []const u8) !Scanner {
        // libyaml/fy_reader treat a NUL byte as end of input.
        var end = input.len;
        if (std.mem.indexOfScalar(u8, input, 0)) |i| end = i;
        const eff = input[0..end];

        if (!utf8.valid(eff)) {
            if (d) |dd| dd.emit(.err, .{}, "input is not valid UTF-8", .{}) catch {};
            return error.InvalidUtf8;
        }

        var self: Scanner = .{ .alloc = alloc, .d = d, .input = eff, .pos = 0, .mark = .{} };
        // Skip a UTF-8 BOM if present (fy_reader does this too).
        if (eff.len >= 3 and std.mem.eql(u8, eff[0..3], "\xEF\xBB\xBF")) self.pos = 3;
        // One simple key slot per flow level; level 0 always exists.
        try self.simple_keys.append(alloc, .{});
        return self;
    }

    pub fn deinit(self: *Scanner) void {
        self.indents.deinit(self.alloc);
        self.simple_keys.deinit(self.alloc);
        self.tokens.deinit(self.alloc);
        for (self.temp_bytes.items) |buf| self.alloc.free(buf);
        self.temp_bytes.deinit(self.alloc);
        for (self.temp_params.items) |p| self.alloc.free(p);
        self.temp_params.deinit(self.alloc);
    }

    /// Finalise a byte scratch buffer and register it for cleanup.
    fn ownTemp(self: *Scanner, buf: *std.ArrayList(u8)) ![]u8 {
        const s = try buf.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(s);
        try self.temp_bytes.append(self.alloc, s);
        return s;
    }

    /// Finalise a directive parameter list and register it for cleanup.
    fn ownParams(self: *Scanner, buf: *std.ArrayList([]const u8)) ![]const []const u8 {
        const s = try buf.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(s);
        try self.temp_params.append(self.alloc, s);
        return s;
    }

    // ------------------------------------------------------------------
    // Public token stream API
    // ------------------------------------------------------------------

    /// Look at the next token without consuming it. Null after the stream
    /// end token has been consumed.
    pub fn peekToken(self: *Scanner) !?Token {
        try self.ensureToken();
        if (self.tokens_parsed >= self.tokens.items.len) return null;
        return self.tokens.items[self.tokens_parsed];
    }

    /// Consume the current token. Must only be called after a successful
    /// peekToken that returned non-null.
    pub fn skipToken(self: *Scanner) void {
        self.tokens_parsed += 1;
        // Keep the queue compact so long streams do not accumulate every
        // token ever produced.
        if (self.tokens_parsed > 16 and self.tokens_parsed * 2 > self.tokens.items.len) {
            const rest = self.tokens.items.len - self.tokens_parsed;
            std.mem.copyForwards(Token, self.tokens.items[0..rest], self.tokens.items[self.tokens_parsed..]);
            self.tokens.shrinkRetainingCapacity(rest);
            self.token_base += self.tokens_parsed;
            self.tokens_parsed = 0;
        }
    }

    fn ensureToken(self: *Scanner) !void {
        while (true) {
            var need_more = false;
            if (self.tokens_parsed >= self.tokens.items.len) {
                need_more = true;
            } else {
                try self.staleSimpleKeys();
                const head_number = self.token_base + self.tokens_parsed;
                for (self.simple_keys.items) |sk| {
                    if (sk.possible and sk.token_number == head_number) {
                        need_more = true;
                        break;
                    }
                }
            }
            if (!need_more or self.stream_end_produced) break;
            try self.fetchNextToken();
        }
    }

    // ------------------------------------------------------------------
    // Diagnostics
    // ------------------------------------------------------------------

    fn failWith(self: *Scanner, err: YamlError, mark: Mark, comptime fmt: []const u8, args: anytype) YamlError {
        if (self.d) |dd| dd.emit(.err, mark, fmt, args) catch {};
        return err;
    }

    fn fail(self: *Scanner, mark: Mark, comptime fmt: []const u8, args: anytype) YamlError {
        return self.failWith(error.InvalidSyntax, mark, fmt, args);
    }

    // ------------------------------------------------------------------
    // Low level input helpers
    // ------------------------------------------------------------------

    /// Byte at pos+off, or 0 past the end (libyaml CHECK_AT semantics:
    /// NUL means "end of stream").
    fn at(self: *const Scanner, off: usize) u8 {
        const p = self.pos + off;
        if (p >= self.input.len) return 0;
        return self.input[p];
    }

    fn matchAt(self: *const Scanner, comptime lit: []const u8, off: usize) bool {
        inline for (0..lit.len) |i| {
            if (self.at(off + i) != lit[i]) return false;
        }
        return true;
    }

    /// Advance over one codepoint (must not be a line break).
    fn skipCp(self: *Scanner) void {
        // Input is UTF-8-validated in init and the cursor is on a
        // character, so neither error nor EOF can occur here.
        const r = (utf8.decode(self.input, self.pos) catch unreachable) orelse unreachable;
        self.pos += r.len;
        self.mark.offset += r.len;
        self.mark.column += 1;
    }

    /// Advance over one line break (LF, CR or CRLF).
    fn skipLine(self: *Scanner) void {
        if (self.at(0) == '\r' and self.at(1) == '\n') {
            self.pos += 2;
            self.mark.offset += 2;
        } else {
            self.pos += 1;
            self.mark.offset += 1;
        }
        self.mark.line += 1;
        self.mark.column = 1;
    }

    /// Append the codepoint at the cursor to `out` and advance.
    fn readCp(self: *Scanner, out: *std.ArrayList(u8)) !void {
        const r = (utf8.decode(self.input, self.pos) catch unreachable) orelse unreachable;
        try out.appendSlice(self.alloc, self.input[self.pos .. self.pos + r.len]);
        self.skipCp();
    }

    // ------------------------------------------------------------------
    // Token queue helpers
    // ------------------------------------------------------------------

    fn appendToken(self: *Scanner, tok: Token) !void {
        try self.tokens.append(self.alloc, tok);
        self.noteNodeEnd(tok.kind);
    }

    fn insertToken(self: *Scanner, number: usize, tok: Token) !void {
        const index = number - self.token_base;
        try self.tokens.insert(self.alloc, index, tok);
        self.noteNodeEnd(tok.kind);
    }

    /// True when the most recently emitted token can end a key node:
    /// the basis for flow adjacent values ("key":value, spec 7.18).
    fn noteNodeEnd(self: *Scanner, kind: Token.Kind) void {
        self.last_node_end = switch (kind) {
            .scalar, .alias, .flow_sequence_end, .flow_mapping_end => true,
            else => false,
        };
    }

    // ------------------------------------------------------------------
    // Simple keys and indentation (fy_scan.c roll/unroll indent)
    // ------------------------------------------------------------------

    fn staleSimpleKeys(self: *Scanner) !void {
        for (self.simple_keys.items) |*sk| {
            if (sk.possible and
                (sk.mark.line < self.mark.line or sk.mark.offset + max_simple_key_length < self.mark.offset))
            {
                if (sk.required) {
                    return self.fail(self.mark, "simple key was expected", .{});
                }
                sk.possible = false;
            }
        }
    }

    fn saveSimpleKey(self: *Scanner) !void {
        if (!self.simple_key_allowed) return;
        const sk = SimpleKey{
            .possible = true,
            .required = self.flow_level == 0 and
                self.indent == @as(isize, @intCast(self.mark.column)),
            .token_number = self.token_base + self.tokens.items.len,
            .mark = self.mark,
        };
        try self.removeSimpleKey();
        self.simple_keys.items[self.simple_keys.items.len - 1] = sk;
    }

    fn removeSimpleKey(self: *Scanner) !void {
        const sk = &self.simple_keys.items[self.simple_keys.items.len - 1];
        if (sk.possible and sk.required) {
            return self.fail(self.mark, "simple key was expected", .{});
        }
        sk.possible = false;
    }

    fn rollIndent(self: *Scanner, column: usize, number: ?usize, kind: Token.Kind, mark: Mark) !void {
        if (self.flow_level > 0) return;
        const col: isize = @intCast(column);
        if (self.indent < col) {
            try self.indents.append(self.alloc, self.indent);
            self.indent = col;
            const tok = Token{ .kind = kind, .start = mark, .end = mark };
            if (number) |n| {
                try self.insertToken(n, tok);
            } else {
                try self.appendToken(tok);
            }
        }
    }

    fn unrollIndent(self: *Scanner, column: isize) !void {
        if (self.flow_level > 0) return;
        while (self.indent > column) {
            try self.appendToken(.{ .kind = .block_end, .start = self.mark, .end = self.mark });
            self.indent = self.indents.pop().?;
        }
    }

    // ------------------------------------------------------------------
    // Whitespace/comment skipping
    // ------------------------------------------------------------------

    fn skipToNextToken(self: *Scanner) !void {
        var line_start = self.mark.column == 1;
        while (true) {
            // Eat whitespace. In block context a tab in the leading
            // whitespace of a line is an indentation error when the
            // content it indents is a block construct: '?', ':', '|',
            // '>' or a '-' entry (libfyaml fy_ws_indentation_check).
            while (true) {
                const c = self.at(0);
                if (c == ' ') {
                    self.skipCp();
                    continue;
                }
                if (c == '\t') {
                    if (line_start and self.flow_level == 0) {
                        var off: usize = 0;
                        while (ctype.isBlank(self.at(off))) off += 1;
                        const nc = self.at(off);
                        const indents_block = switch (nc) {
                            '?', ':', '|', '>' => true,
                            '-' => ctype.isBlankz(self.at(off + 1)),
                            else => false,
                        };
                        if (indents_block) {
                            return self.failWith(error.InvalidIndentation, self.mark, "found a tab character where an indentation space is expected", .{});
                        }
                    }
                    self.skipCp();
                    continue;
                }
                break;
            }
            // Eat a comment until the line break. A '#' only starts a
            // comment when preceded by whitespace or line start;
            // "foo#bar" is not a comment (corpus 9JBA/CVW2/SU5Z).
            // The separator may have been consumed by the previous
            // token's scan, so look at the actual preceding byte.
            if (self.at(0) == '#') {
                const preceded = self.pos == 0 or
                    self.input[self.pos - 1] == ' ' or
                    self.input[self.pos - 1] == '\t' or
                    ctype.isBreak(self.input[self.pos - 1]);
                if (!preceded) {
                    return self.fail(self.mark, "found a '#' that cannot start a comment without preceding whitespace", .{});
                }
                while (self.at(0) != 0 and !ctype.isBreak(self.at(0))) self.skipCp();
            }
            // Eat line breaks; in block context a key may start afterwards.
            if (ctype.isBreak(self.at(0))) {
                self.skipLine();
                if (self.flow_level == 0) self.simple_key_allowed = true;
                line_start = true;
            } else break;
        }
    }

    // ------------------------------------------------------------------
    // fetch_* dispatch (fy_scan.c yaml_parser_fetch_next_token)
    // ------------------------------------------------------------------

    fn fetchNextToken(self: *Scanner) !void {
        if (!self.stream_start_produced) return self.fetchStreamStart();

        try self.skipToNextToken();
        try self.staleSimpleKeys();
        // Close block collections whose indentation is deeper than the
        // current column (libyaml does this before dispatching).
        try self.unrollIndent(@as(isize, @intCast(self.mark.column)));

        const c = self.at(0);
        if (c == 0) return self.fetchStreamEnd();
        if (c == '%' and self.mark.column == 1 and self.flow_level == 0) return self.fetchDirective();
        if (self.mark.column == 1 and self.matchAt("---", 0) and ctype.isBlankz(self.at(3))) {
            return self.fetchDocumentIndicator(.document_start);
        }
        if (self.mark.column == 1 and self.matchAt("...", 0) and ctype.isBlankz(self.at(3))) {
            return self.fetchDocumentIndicator(.document_end);
        }

        switch (c) {
            '[' => return self.fetchFlowCollectionStart(.flow_sequence_start),
            '{' => return self.fetchFlowCollectionStart(.flow_mapping_start),
            ']' => return self.fetchFlowCollectionEnd(.flow_sequence_end),
            '}' => return self.fetchFlowCollectionEnd(.flow_mapping_end),
            ',' => return self.fetchFlowEntry(),
            '-' => if (ctype.isBlankz(self.at(1))) {
                if (self.flow_level > 0) {
                    return self.fail(self.mark, "found a block entry indicator inside a flow collection", .{});
                }
                return self.fetchBlockEntry();
            },
            '?' => if (ctype.isBlankz(self.at(1))) return self.fetchKey(),
            ':' => if (ctype.isBlankz(self.at(1)) or
                (self.flow_level > 0 and
                    (self.last_node_end or self.at(1) == ',' or self.at(1) == ']' or self.at(1) == '}'))) return self.fetchValue(),
            '*' => return self.fetchAnchor(.alias),
            '&' => return self.fetchAnchor(.anchor),
            '!' => return self.fetchTag(),
            '|' => if (self.flow_level == 0) return self.fetchBlockScalar(true),
            '>' => if (self.flow_level == 0) return self.fetchBlockScalar(false),
            '\'' => return self.fetchFlowScalar(.single_quoted),
            '"' => return self.fetchFlowScalar(.double_quoted),
            else => {},
        }

        if (self.canStartPlain()) return self.fetchPlainScalar();

        return self.fail(self.mark, "found character '{u}' that cannot start any token", .{c});
    }

    /// libyaml's check for characters that may open a plain scalar.
    fn canStartPlain(self: *const Scanner) bool {
        const c = self.at(0);
        return switch (c) {
            0, ' ', '\t', '\n', '\r', ',', '[', ']', '{', '}', '#', '&', '*', '!', '|', '>', '\'', '"', '@', '`' => false,
            '-', '?', ':' => blk: {
                if (ctype.isBlankz(self.at(1))) break :blk false;
                if (self.flow_level > 0) {
                    // A dash followed by a flow indicator is not a plain
                    // scalar (corpus G5U8/YJV2).
                    const n = self.at(1);
                    break :blk n != ',' and n != '[' and n != ']' and n != '{' and n != '}';
                }
                break :blk true;
            },
            else => true,
        };
    }

    fn fetchStreamStart(self: *Scanner) !void {
        self.stream_start_produced = true;
        try self.appendToken(.{ .kind = .stream_start, .start = self.mark, .end = self.mark });
    }

    fn fetchStreamEnd(self: *Scanner) !void {
        // Force a new line (libyaml does this to simplify the EOF case).
        if (self.mark.column != 1) {
            self.mark.line += 1;
            self.mark.column = 1;
        }
        try self.unrollIndent(-1);
        try self.removeSimpleKey();
        self.simple_key_allowed = false;
        self.stream_end_produced = true;
        try self.appendToken(.{ .kind = .stream_end, .start = self.mark, .end = self.mark });
    }

    fn fetchDirective(self: *Scanner) !void {
        try self.unrollIndent(-1);
        try self.removeSimpleKey();
        self.simple_key_allowed = false;
        const tok = try self.scanDirective();
        try self.appendToken(tok);
    }

    fn fetchDocumentIndicator(self: *Scanner, tag: Token.Type) !void {
        try self.unrollIndent(-1);
        try self.removeSimpleKey();
        self.simple_key_allowed = false;
        const start = self.mark;
        self.skipCp();
        self.skipCp();
        self.skipCp();
        if (tag == .document_end) {
            // Nothing but a comment may follow '...' on the same line
            // (corpus 3HFZ).
            while (self.at(0) == ' ') self.skipCp();
            const c = self.at(0);
            if (!ctype.isBlankz(c) and c != '#') {
                return self.fail(self.mark, "did not find expected comment or line break after document end marker", .{});
            }
        }
        const k: Token.Kind = switch (tag) {
            .document_start => .{ .document_start = .{ .explicit_marker = true } },
            .document_end => .document_end,
            else => unreachable, // only document indicators are passed
        };
        try self.appendToken(.{ .kind = k, .start = start, .end = self.mark });
    }

    fn fetchFlowCollectionStart(self: *Scanner, kind: Token.Kind) !void {
        try self.saveSimpleKey();
        self.flow_level += 1;
        try self.simple_keys.append(self.alloc, .{});
        // A simple key may follow '[' and '{'.
        self.simple_key_allowed = true;
        const start = self.mark;
        self.skipCp();
        try self.appendToken(.{ .kind = kind, .start = start, .end = self.mark });
    }

    fn fetchFlowCollectionEnd(self: *Scanner, kind: Token.Kind) !void {
        if (self.flow_level > 0) {
            self.flow_level -= 1;
            _ = self.simple_keys.pop();
        }
        self.simple_key_allowed = false;
        const start = self.mark;
        self.skipCp();
        try self.appendToken(.{ .kind = kind, .start = start, .end = self.mark });
    }

    fn fetchFlowEntry(self: *Scanner) !void {
        self.simple_key_allowed = true;
        const start = self.mark;
        self.skipCp();
        try self.appendToken(.{ .kind = .flow_entry, .start = start, .end = self.mark });
    }

    fn fetchBlockEntry(self: *Scanner) !void {
        if (self.flow_level == 0) {
            if (!self.simple_key_allowed) {
                return self.fail(self.mark, "block sequence entries are not allowed in this context", .{});
            }
            try self.rollIndent(self.mark.column, null, .block_sequence_start, self.mark);
        }
        self.simple_key_allowed = self.flow_level == 0;
        const start = self.mark;
        self.skipCp();
        try self.appendToken(.{ .kind = .block_entry, .start = start, .end = self.mark });
    }

    fn fetchKey(self: *Scanner) !void {
        if (self.flow_level == 0) {
            if (!self.simple_key_allowed) {
                return self.fail(self.mark, "mapping keys are not allowed in this context", .{});
            }
            try self.rollIndent(self.mark.column, null, .block_mapping_start, self.mark);
        }
        self.simple_key_allowed = self.flow_level == 0;
        const start = self.mark;
        self.skipCp();
        try self.appendToken(.{ .kind = .key, .start = start, .end = self.mark });
    }

    fn fetchValue(self: *Scanner) !void {
        const sk = &self.simple_keys.items[self.simple_keys.items.len - 1];
        if (sk.possible) {
            try self.insertToken(sk.token_number, .{ .kind = .key, .start = sk.mark, .end = sk.mark });
            // A confirmed simple key starts a block mapping at its own
            // position (inserted before the KEY token).
            try self.rollIndent(sk.mark.column, sk.token_number, .block_mapping_start, sk.mark);
            sk.possible = false;
            self.simple_key_allowed = false;
        } else {
            if (self.flow_level == 0) {
                if (!self.simple_key_allowed) {
                    return self.fail(self.mark, "mapping values are not allowed in this context", .{});
                }
                try self.rollIndent(self.mark.column, null, .block_mapping_start, self.mark);
            }
            self.simple_key_allowed = self.flow_level == 0;
        }
        const start = self.mark;
        self.skipCp();
        try self.appendToken(.{ .kind = .value, .start = start, .end = self.mark });
    }

    fn fetchAnchor(self: *Scanner, tag: Token.Type) !void {
        try self.saveSimpleKey();
        self.simple_key_allowed = false;
        const tok = try self.scanAnchor(tag);
        try self.appendToken(tok);
    }

    fn fetchTag(self: *Scanner) !void {
        try self.saveSimpleKey();
        self.simple_key_allowed = false;
        const tok = try self.scanTag();
        try self.appendToken(tok);
    }

    fn fetchBlockScalar(self: *Scanner, literal: bool) !void {
        try self.saveSimpleKey();
        const tok = try self.scanBlockScalar(literal);
        try self.appendToken(tok);
        // A simple key may follow a block scalar (it ends on a new line).
        self.simple_key_allowed = true;
    }

    fn fetchFlowScalar(self: *Scanner, style: ScalarStyle) !void {
        try self.saveSimpleKey();
        self.simple_key_allowed = false;
        const tok = try self.scanFlowScalar(style);
        try self.appendToken(tok);
    }

    fn fetchPlainScalar(self: *Scanner) !void {
        try self.saveSimpleKey();
        self.simple_key_allowed = false;
        const tok = try self.scanPlainScalar();
        try self.appendToken(tok);
    }

    // ------------------------------------------------------------------
    // scan_* token bodies
    // ------------------------------------------------------------------

    fn scanDirective(self: *Scanner) !Token {
        const start = self.mark;
        self.skipCp(); // '%'

        const name_start = self.pos;
        while (ctype.isWordChar(self.at(0))) self.skipCp();
        const name = self.input[name_start..self.pos];
        if (name.len == 0) {
            return self.fail(self.mark, "could not find expected directive name", .{});
        }
        if (!ctype.isBlankz(self.at(0))) {
            return self.fail(self.mark, "found unexpected non-alphabetical character in directive", .{});
        }

        var params: std.ArrayList([]const u8) = .empty;
        errdefer params.deinit(self.alloc);
        while (self.at(0) == ' ' or self.at(0) == '\t') self.skipCp();
        while (!ctype.isBlankz(self.at(0)) and self.at(0) != '#') {
            const p_start = self.pos;
            while (!ctype.isBlankz(self.at(0))) self.skipCp();
            try params.append(self.alloc, self.input[p_start..self.pos]);
            while (self.at(0) == ' ' or self.at(0) == '\t') self.skipCp();
        }
        if (self.at(0) == '#') {
            while (self.at(0) != 0 and !ctype.isBreak(self.at(0))) self.skipCp();
        }
        if (!ctype.isBlankz(self.at(0))) {
            return self.fail(self.mark, "did not find expected comment or line break after directive", .{});
        }
        if (ctype.isBreak(self.at(0))) self.skipLine();

        return .{
            .kind = .{ .directive = .{ .name = name, .params = try self.ownParams(&params) } },
            .start = start,
            .end = self.mark,
        };
    }

    fn scanAnchor(self: *Scanner, tag: Token.Type) !Token {
        const start = self.mark;
        self.skipCp(); // '&' or '*'
        const name_start = self.pos;
        while (ctype.isWordChar(self.at(0))) self.skipCp();
        const name = self.input[name_start..self.pos];
        const c = self.at(0);
        const ok_after = ctype.isBlankz(c) or switch (c) {
            '?', ':', ',', ']', '}', '%', '@', '`' => true,
            else => false,
        };
        if (name.len == 0 or !ok_after) {
            return self.fail(start, "did not find expected alphabetic or numeric character in {s}", .{@tagName(tag)});
        }
        const k: Token.Kind = if (tag == .anchor) .{ .anchor = name } else .{ .alias = name };
        return .{ .kind = k, .start = start, .end = self.mark };
    }

    fn scanTag(self: *Scanner) !Token {
        const start = self.mark;
        var handle: []const u8 = "";
        var suffix: []const u8 = "";

        if (self.at(1) == '<') {
            // Verbatim tag !<uri>
            self.skipCp();
            self.skipCp();
            const s_start = self.pos;
            try self.scanTagUri();
            suffix = self.input[s_start..self.pos];
            if (suffix.len == 0) {
                return self.fail(start, "tag URI is empty", .{});
            }
            if (self.at(0) != '>') {
                return self.fail(self.mark, "did not find expected '>' in verbatim tag", .{});
            }
            self.skipCp();
        } else if (ctype.isBlankz(self.at(1))) {
            // Non-specific tag '!'
            handle = "!";
            self.skipCp();
        } else {
            self.skipCp(); // '!'
            // Probe the handle body: alphanumerics, then an optional '!'.
            // A trailing '!' makes it a named handle ("!!" or "!name!");
            // otherwise the whole thing is a local tag with handle "!".
            const h_start = self.pos;
            var probe = h_start;
            while (probe < self.input.len and ctype.isWordChar(self.input[probe])) probe += 1;
            const trailing_bang = probe < self.input.len and self.input[probe] == '!';
            if (trailing_bang) {
                while (self.pos < probe) self.skipCp();
                self.skipCp(); // trailing '!'
                handle = self.input[h_start - 1 .. self.pos];
                const s_start = self.pos;
                try self.scanTagUri();
                suffix = self.input[s_start..self.pos];
            } else {
                handle = "!";
                const s_start = h_start;
                try self.scanTagUri();
                suffix = self.input[s_start..self.pos];
            }
        }
        if (!ctype.isBlankz(self.at(0))) {
            return self.fail(self.mark, "did not find expected whitespace or line break after tag", .{});
        }
        return .{
            .kind = .{ .tag = .{ .handle = handle, .suffix = suffix } },
            .start = start,
            .end = self.mark,
        };
    }

    /// Scan a tag URI (RFC 2396 characters plus '%xx' escapes, kept raw).
    fn scanTagUri(self: *Scanner) !void {
        while (true) {
            const c = self.at(0);
            if (ctype.isWordChar(c)) {
                self.skipCp();
                continue;
            }
            switch (c) {
                ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '.', '_', '~', '*', '\'', '(', ')', '[', ']', '-' => self.skipCp(),
                '%' => {
                    if (ctype.hexValue(self.at(1)) == null or ctype.hexValue(self.at(2)) == null) {
                        return self.fail(self.mark, "did not find URI escaped octet", .{});
                    }
                    self.skipCp();
                    self.skipCp();
                    self.skipCp();
                },
                else => break,
            }
        }
    }

    /// Block scalar (`|` literal / `>` folded).
    ///
    /// PORT NOTE: the C implementation folds while scanning; this port
    /// collects lines first and applies the same folding/chomping rules in
    /// `finishBlockScalar`. The observable scalar value is identical.
    fn scanBlockScalar(self: *Scanner, literal: bool) !Token {
        const start = self.mark;
        self.skipCp(); // '|' or '>'

        // Header: chomping and indentation indicators in either order.
        var chomping: i8 = 0;
        var increment: usize = 0;
        if (self.at(0) == '+' or self.at(0) == '-') {
            chomping = if (self.at(0) == '+') 1 else -1;
            self.skipCp();
            if (std.ascii.isDigit(self.at(0))) {
                increment = self.at(0) - '0';
                if (increment == 0) {
                    return self.fail(self.mark, "found an indentation indicator equal to 0", .{});
                }
                self.skipCp();
            }
        } else if (std.ascii.isDigit(self.at(0))) {
            increment = self.at(0) - '0';
            if (increment == 0) {
                return self.fail(self.mark, "found an indentation indicator equal to 0", .{});
            }
            self.skipCp();
            if (self.at(0) == '+' or self.at(0) == '-') {
                chomping = if (self.at(0) == '+') 1 else -1;
                self.skipCp();
            }
        }
        // End of header: spaces, optional comment (which must be
        // whitespace-separated, corpus X4QW), then a line break.
        var header_ws = false;
        while (self.at(0) == ' ') {
            self.skipCp();
            header_ws = true;
        }
        if (self.at(0) == '#') {
            if (!header_ws) {
                return self.fail(self.mark, "did not find expected comment or line break in block scalar header", .{});
            }
            while (self.at(0) != 0 and !ctype.isBreak(self.at(0))) self.skipCp();
        }
        if (!ctype.isBlankz(self.at(0))) {
            return self.fail(self.mark, "did not find expected comment or line break in block scalar header", .{});
        }
        if (ctype.isBreak(self.at(0))) self.skipLine();

        // Determine the content indentation.
        var indent: isize = 0;
        if (increment != 0) {
            indent = @max(self.indent, 0) + @as(isize, @intCast(increment));
        }

        var value: std.ArrayList(u8) = .empty;
        errdefer value.deinit(self.alloc);

        // empty_run: consecutive empty lines since the last content line.
        var empty_run: usize = 0;
        // leading_breaks: empty lines before the first content line.
        var leading_breaks: usize = 0;
        // Trailing breaks after the last content line (for keep chomping).
        var trailing_breaks: usize = 0;
        var have_content = false;
        var prev_more = false;

        outer: while (true) {
            const snap_pos = self.pos;
            const snap_mark = self.mark;

            var ws: usize = 0;
            while (self.at(0) == ' ') {
                self.skipCp();
                ws += 1;
            }
            const c = self.at(0);

            if (c == 0) break :outer;
            // A whitespace-only line is empty unless its spaces reach
            // deeper than the strip column — then the spaces are content
            // (corpus 6FWR).
            const ws_line_is_content = indent != 0 and @as(isize, @intCast(ws)) > indent - 1;
            if (ctype.isBreak(c) and !ws_line_is_content) {
                // Empty line (it may contain whitespace). Lines starting
                // with '#' are content: comments do not exist inside
                // block scalars.
                self.skipLine();
                if (have_content) {
                    empty_run += 1;
                    trailing_breaks += 1;
                } else {
                    leading_breaks += 1;
                }
                continue :outer;
            }

            const col: isize = @intCast(self.mark.column);
            // Document indicators always end a block scalar.
            if (self.mark.column == 1 and
                (self.matchAt("---", 0) or self.matchAt("...", 0)) and
                ctype.isBlankz(self.at(3)))
            {
                self.pos = snap_pos;
                self.mark = snap_mark;
                break :outer;
            }
            if (indent == 0) {
                // Auto-detect: content must sit deeper than the enclosing
                // indentation, otherwise the scalar is empty.
                if (col <= self.indent) {
                    self.pos = snap_pos;
                    self.mark = snap_mark;
                    break :outer;
                }
                indent = col;
            }
            // A tab inside the indentation region is an error.
            const strip: usize = @intCast(indent - 1);
            if (c == '\t' and ws < strip) {
                return self.failWith(error.InvalidIndentation, self.mark, "found a tab character where an indentation space is expected", .{});
            }
            if (col < indent) {
                self.pos = snap_pos;
                self.mark = snap_mark;
                break :outer;
            }

            const more = col > indent;

            // Separator before this content line.
            if (have_content) {
                const k = empty_run + 1;
                if (literal or prev_more or more) {
                    for (0..k) |_| try value.append(self.alloc, '\n');
                } else if (k == 1) {
                    try value.append(self.alloc, ' ');
                } else {
                    for (0..k - 1) |_| try value.append(self.alloc, '\n');
                }
            } else if (leading_breaks > 0) {
                // Leading empty lines survive as newlines in both styles;
                // folding only applies between content lines.
                for (0..leading_breaks) |_| try value.append(self.alloc, '\n');
                leading_breaks = 0;
            }
            empty_run = 0;
            trailing_breaks = 0;

            // Capture the line, keeping any spaces past the strip column
            // (they belong to more-indented lines).
            const text_start = self.pos - (ws - strip);
            while (self.at(0) != 0 and !ctype.isBreak(self.at(0))) self.skipCp();
            try value.appendSlice(self.alloc, self.input[text_start..self.pos]);

            have_content = true;
            prev_more = more;

            if (ctype.isBreak(self.at(0))) {
                self.skipLine();
                trailing_breaks = 1;
            }
        }

        const style: ScalarStyle = if (literal) .literal else .folded;
        if (!have_content) {
            value.clearRetainingCapacity();
        } else if (chomping >= 0) {
            const n: usize = if (chomping == 0) 1 else trailing_breaks;
            for (0..n) |_| try value.append(self.alloc, '\n');
        }

        return .{
            .kind = .{ .scalar = .{ .value = try self.ownTemp(&value), .style = style } },
            .start = start,
            .end = self.mark,
        };
    }

    /// Single or double quoted scalar, including multi-line folding.
    fn scanFlowScalar(self: *Scanner, style: ScalarStyle) !Token {
        const start = self.mark;
        const quote: u8 = if (style == .single_quoted) '\'' else '"';
        self.skipCp(); // opening quote

        var value: std.ArrayList(u8) = .empty;
        errdefer value.deinit(self.alloc);
        var pending_ws: std.ArrayList(u8) = .empty;
        defer pending_ws.deinit(self.alloc);
        var breaks: usize = 0;
        var join_direct = false;

        while (true) {
            const c = self.at(0);
            if (c == 0) {
                return self.failWith(error.Unterminated, start, "found unexpected end of stream in quoted scalar", .{});
            }
            if (c == quote) {
                if (style == .single_quoted and self.at(1) == quote) {
                    // An escaped quote is content: commit separators first.
                    try self.flushQuotedSeparators(&value, &breaks, &join_direct, &pending_ws);
                    try value.append(self.alloc, quote);
                    self.skipCp();
                    self.skipCp();
                    continue;
                }
                self.skipCp(); // closing quote; trailing whitespace is dropped
                break;
            }
            if (ctype.isBreak(c)) {
                pending_ws.clearRetainingCapacity();
                self.skipLine();
                breaks += 1;
                while (ctype.isBlank(self.at(0))) self.skipCp();
                continue;
            }
            // Commit any pending separator before real content.
            try self.flushQuotedSeparators(&value, &breaks, &join_direct, &pending_ws);
            if (ctype.isBlank(c)) {
                try pending_ws.append(self.alloc, c);
                self.skipCp();
                continue;
            }
            if (style == .double_quoted and c == '\\') {
                try self.scanEscape(&value, &join_direct, &breaks);
                continue;
            }
            try self.readCp(&value);
        }

        return .{
            .kind = .{ .scalar = .{ .value = try self.ownTemp(&value), .style = style } },
            .start = start,
            .end = self.mark,
        };
    }

    /// Commit pending line breaks / whitespace before quoted-scalar content.
    fn flushQuotedSeparators(self: *Scanner, value: *std.ArrayList(u8), breaks: *usize, join_direct: *bool, pending_ws: *std.ArrayList(u8)) !void {
        if (breaks.* > 0) {
            if (breaks.* == 1) {
                try value.append(self.alloc, ' ');
            } else {
                for (0..breaks.* - 1) |_| try value.append(self.alloc, '\n');
            }
            breaks.* = 0;
            join_direct.* = false;
        } else if (join_direct.*) {
            join_direct.* = false;
        } else if (pending_ws.items.len > 0) {
            try value.appendSlice(self.alloc, pending_ws.items);
            pending_ws.clearRetainingCapacity();
        }
    }

    fn scanEscape(self: *Scanner, value: *std.ArrayList(u8), join_direct: *bool, breaks: *usize) !void {
        self.skipCp(); // backslash
        const c = self.at(0);
        if (ctype.isBreak(c)) {
            // Escaped line break: content joins directly.
            self.skipLine();
            while (ctype.isBlank(self.at(0))) self.skipCp();
            join_direct.* = true;
            breaks.* = 0;
            return;
        }
        var cp: u21 = 0;
        switch (c) {
            '0' => cp = 0,
            'a' => cp = 0x07,
            'b' => cp = 0x08,
            't' => cp = 0x09,
            'n' => cp = 0x0A,
            'v' => cp = 0x0B,
            'f' => cp = 0x0C,
            'r' => cp = 0x0D,
            'e' => cp = 0x1B,
            ' ' => cp = 0x20,
            '"' => cp = 0x22,
            '/' => cp = 0x2F,
            '\\' => cp = 0x5C,
            'N' => cp = 0x85,
            '_' => cp = 0xA0,
            'L' => cp = 0x2028,
            'P' => cp = 0x2029,
            'x', 'u', 'U' => {
                const n: usize = switch (c) {
                    'x' => 2,
                    'u' => 4,
                    else => 8,
                };
                self.skipCp();
                var v: u32 = 0;
                for (0..n) |_| {
                    const h = ctype.hexValue(self.at(0)) orelse {
                        return self.failWith(error.InvalidEscape, self.mark, "did not find expected hexdecimal number in escape sequence", .{});
                    };
                    v = v * 16 + h;
                    self.skipCp();
                }
                if (v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) {
                    return self.failWith(error.InvalidEscape, self.mark, "escape sequence is not a valid Unicode code point", .{});
                }
                cp = @intCast(v);
            },
            else => return self.failWith(error.InvalidEscape, self.mark, "found unknown escape character '{u}'", .{c}),
        }
        if (c != 'x' and c != 'u' and c != 'U') self.skipCp();
        var buf: [4]u8 = undefined;
        const len = try utf8.encode(cp, &buf);
        try value.appendSlice(self.alloc, buf[0..len]);
    }

    /// Plain (unquoted) scalar with multi-line folding.
    fn scanPlainScalar(self: *Scanner) !Token {
        const start = self.mark;
        var value: std.ArrayList(u8) = .empty;
        errdefer value.deinit(self.alloc);
        var ws: std.ArrayList(u8) = .empty;
        defer ws.deinit(self.alloc);
        var seg: std.ArrayList(u8) = .empty;
        defer seg.deinit(self.alloc);
        var breaks: usize = 0;
        const stop_indent = self.indent + 1;

        while (true) {
            // Document indicators and comments terminate a plain scalar;
            // pending whitespace is trailing and therefore dropped.
            if (self.mark.column == 1 and
                (self.matchAt("---", 0) or self.matchAt("...", 0)) and
                ctype.isBlankz(self.at(3))) break;
            if (self.at(0) == '#') break;

            // Scan one run of non-blank characters.
            seg.clearRetainingCapacity();
            while (!ctype.isBlankz(self.at(0))) {
                const c = self.at(0);
                if (self.flow_level > 0 and
                    (c == ',' or c == '[' or c == ']' or c == '{' or c == '}')) break;
                if (c == ':' and
                    (ctype.isBlankz(self.at(1)) or
                        (self.flow_level > 0 and
                            (self.at(1) == ',' or self.at(1) == ']' or self.at(1) == '}')))) break;
                try self.readCp(&seg);
            }

            // Empty run: the scalar ends at ':' or an indicator. Any
            // pending whitespace was trailing, so it is dropped — YAML
            // plain scalars never carry trailing spaces.
            if (seg.items.len == 0) break;

            // Content follows, so the pending separator joins the value:
            // one line break folds to a space, N breaks keep N-1 newlines.
            if (breaks > 0) {
                if (breaks == 1) {
                    try value.append(self.alloc, ' ');
                } else {
                    for (0..breaks - 1) |_| try value.append(self.alloc, '\n');
                }
                breaks = 0;
            } else if (ws.items.len > 0) {
                try value.appendSlice(self.alloc, ws.items);
            }
            ws.clearRetainingCapacity();
            try value.appendSlice(self.alloc, seg.items);

            // Consume the whitespace/line breaks that follow the run.
            const snap_pos = self.pos;
            const snap_mark = self.mark;
            while (ctype.isBlank(self.at(0)) or ctype.isBreak(self.at(0))) {
                if (ctype.isBreak(self.at(0))) {
                    breaks += 1;
                    self.skipLine();
                } else {
                    if (self.at(0) == '\t' and breaks > 0 and self.flow_level == 0 and
                        @as(isize, @intCast(self.mark.column)) < stop_indent)
                    {
                        return self.failWith(error.InvalidIndentation, self.mark, "found a tab character that violates indentation", .{});
                    }
                    if (breaks == 0) try ws.append(self.alloc, self.at(0));
                    self.skipCp();
                }
            }
            if (self.mark.column == 1 and
                (self.matchAt("---", 0) or self.matchAt("...", 0)) and
                ctype.isBlankz(self.at(3)))
            {
                self.pos = snap_pos;
                self.mark = snap_mark;
                break;
            }
            // In block context, continuation requires deeper indentation.
            if (self.flow_level == 0 and @as(isize, @intCast(self.mark.column)) < stop_indent) {
                self.pos = snap_pos;
                self.mark = snap_mark;
                break;
            }
        }

        return .{
            .kind = .{ .scalar = .{ .value = try self.ownTemp(&value), .style = .plain } },
            .start = start,
            .end = self.mark,
        };
    }
};

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

/// Owns a scanner together with the tokens it produced, so the token
/// payloads (which borrow scanner memory) stay valid until `deinit`.
const ScanResult = struct {
    scanner: Scanner,
    toks: std.ArrayList(Token),

    fn deinit(self: *ScanResult, alloc: std.mem.Allocator) void {
        self.toks.deinit(alloc);
        self.scanner.deinit();
    }
};

fn scanAll(alloc: std.mem.Allocator, input: []const u8) !ScanResult {
    var s = try Scanner.init(alloc, null, input);
    errdefer s.deinit();
    var out: std.ArrayList(Token) = .empty;
    errdefer out.deinit(alloc);
    while (try s.peekToken()) |tok| {
        try out.append(alloc, tok);
        s.skipToken();
    }
    return .{ .scanner = s, .toks = out };
}

fn tokenTypes(alloc: std.mem.Allocator, toks: []const Token) ![]const TokenType {
    var out = try alloc.alloc(TokenType, toks.len);
    for (toks, 0..) |t, i| out[i] = std.meta.activeTag(t.kind);
    return out;
}

test "empty stream" {
    var r = try scanAll(testing.allocator, "");
    defer r.deinit(testing.allocator);
    const toks = r.toks;
    try testing.expectEqual(@as(usize, 2), toks.items.len);
    try testing.expectEqual(TokenType.stream_start, toks.items[0].kind);
    try testing.expectEqual(TokenType.stream_end, toks.items[1].kind);
}

test "simple key value" {
    var r = try scanAll(testing.allocator, "a: b\n");
    defer r.deinit(testing.allocator);
    const toks = r.toks;
    const types = try tokenTypes(testing.allocator, toks.items);
    defer testing.allocator.free(types);
    const want: []const TokenType = &.{
        .stream_start, .block_mapping_start, .key,       .scalar,
        .value,        .scalar,              .block_end, .stream_end,
    };
    try testing.expectEqualSlices(TokenType, want, types);
    try testing.expectEqualStrings("a", toks.items[3].kind.scalar.value);
    try testing.expectEqualStrings("b", toks.items[5].kind.scalar.value);
}

test "block sequence" {
    var r = try scanAll(testing.allocator, "- 1\n- 2\n");
    defer r.deinit(testing.allocator);
    const toks = r.toks;
    const types = try tokenTypes(testing.allocator, toks.items);
    defer testing.allocator.free(types);
    const want: []const TokenType = &.{
        .stream_start, .block_sequence_start, .block_entry, .scalar,
        .block_entry,  .scalar,               .block_end,   .stream_end,
    };
    try testing.expectEqualSlices(TokenType, want, types);
}

test "nested mapping and sequence" {
    const src =
        \\a:
        \\  - x
        \\  - y
        \\b: c
    ;
    var r = try scanAll(testing.allocator, src);
    defer r.deinit(testing.allocator);
    const toks = r.toks;
    const types = try tokenTypes(testing.allocator, toks.items);
    defer testing.allocator.free(types);
    const want: []const TokenType = &.{
        .stream_start, .block_mapping_start, .key,
        .scalar, // a
        .value,
        .block_sequence_start, .block_entry, .scalar, // x
        .block_entry, .scalar, // y
        .block_end,
        .key, .scalar, // b
        .value,     .scalar, // c
        .block_end, .stream_end,
    };
    try testing.expectEqualSlices(TokenType, want, types);
}

test "flow collections" {
    var r = try scanAll(testing.allocator, "[1, {a: b}]\n");
    defer r.deinit(testing.allocator);
    const toks = r.toks;
    const types = try tokenTypes(testing.allocator, toks.items);
    defer testing.allocator.free(types);
    const want: []const TokenType = &.{
        .stream_start,       .flow_sequence_start, .scalar,            .flow_entry,
        .flow_mapping_start, .key,                 .scalar,            .value,
        .scalar,             .flow_mapping_end,    .flow_sequence_end, .stream_end,
    };
    try testing.expectEqualSlices(TokenType, want, types);
}

test "quoted scalars" {
    var r = try scanAll(testing.allocator, "'single ''q'' end'\n\"doub\\\"le\\n\"\n");
    defer r.deinit(testing.allocator);
    const toks = r.toks;
    var scalars: std.ArrayList([]const u8) = .empty;
    defer scalars.deinit(testing.allocator);
    for (toks.items) |t| {
        if (t.kind == .scalar) try scalars.append(testing.allocator, t.kind.scalar.value);
    }
    try testing.expectEqual(@as(usize, 2), scalars.items.len);
    try testing.expectEqualStrings("single 'q' end", scalars.items[0]);
    try testing.expectEqualStrings("doub\"le\n", scalars.items[1]);
}

test "block scalar literal and folded" {
    var r = try scanAll(testing.allocator, "lit: |\n  line1\n  line2\nfold: >\n  one\n  two\n");
    defer r.deinit(testing.allocator);
    const toks = r.toks;
    var scalars: std.ArrayList([]const u8) = .empty;
    defer scalars.deinit(testing.allocator);
    for (toks.items) |t| {
        if (t.kind == .scalar) try scalars.append(testing.allocator, t.kind.scalar.value);
    }
    try testing.expectEqualStrings("lit", scalars.items[0]);
    try testing.expectEqualStrings("line1\nline2\n", scalars.items[1]);
    try testing.expectEqualStrings("fold", scalars.items[2]);
    try testing.expectEqualStrings("one two\n", scalars.items[3]);
}

test "block scalar chomping" {
    var r = try scanAll(testing.allocator, "a: |-\n  x\nb: |+\n  y\n\n");
    defer r.deinit(testing.allocator);
    const toks = r.toks;
    var scalars: std.ArrayList([]const u8) = .empty;
    defer scalars.deinit(testing.allocator);
    for (toks.items) |t| {
        if (t.kind == .scalar) try scalars.append(testing.allocator, t.kind.scalar.value);
    }
    try testing.expectEqualStrings("x", scalars.items[1]);
    try testing.expectEqualStrings("y\n\n", scalars.items[3]);
}

test "plain scalar never keeps trailing whitespace" {
    // YAML 1.2: blanks before ':', before a break or at end of input are
    // not part of a plain scalar's value.
    var r = try scanAll(testing.allocator, "key   : value   \nflow: [a , b ]\n");
    defer r.deinit(testing.allocator);
    var scalars: std.ArrayList([]const u8) = .empty;
    defer scalars.deinit(testing.allocator);
    for (r.toks.items) |t| {
        if (t.kind == .scalar) try scalars.append(testing.allocator, t.kind.scalar.value);
    }
    try testing.expectEqualStrings("key", scalars.items[0]);
    try testing.expectEqualStrings("value", scalars.items[1]);
    try testing.expectEqualStrings("flow", scalars.items[2]);
    try testing.expectEqualStrings("a", scalars.items[3]);
    try testing.expectEqualStrings("b", scalars.items[4]);
}

test "block scalar keeps '#' lines and leading empty lines" {
    // Comments do not exist inside block scalars; leading empty lines
    // are preserved (YAML 1.2 8.1.1, spec example 8.2).
    var r = try scanAll(testing.allocator, "- >\n \n  \n  # detected\n");
    defer r.deinit(testing.allocator);
    var scalars: std.ArrayList([]const u8) = .empty;
    defer scalars.deinit(testing.allocator);
    for (r.toks.items) |t| {
        if (t.kind == .scalar) try scalars.append(testing.allocator, t.kind.scalar.value);
    }
    try testing.expectEqualStrings("\n\n# detected\n", scalars.items[0]);
}

test "flow mapping value may start with ':'" {
    // In flow context ':' is a value indicator only before blanks or
    // flow indicators; ':x' is a plain scalar (corpus 58MP).
    var r = try scanAll(testing.allocator, "{x: :x}\n");
    defer r.deinit(testing.allocator);
    var scalars: std.ArrayList([]const u8) = .empty;
    defer scalars.deinit(testing.allocator);
    for (r.toks.items) |t| {
        if (t.kind == .scalar) try scalars.append(testing.allocator, t.kind.scalar.value);
    }
    try testing.expectEqualStrings("x", scalars.items[0]);
    try testing.expectEqualStrings(":x", scalars.items[1]);
}

test "trailing blanks after top-level flow collection" {
    // Trailing spaces before EOF are not an error (corpus 4RWC).
    var r = try scanAll(testing.allocator, "[1, 2, 3]  ");
    defer r.deinit(testing.allocator);
    const types = try tokenTypes(testing.allocator, r.toks.items);
    defer testing.allocator.free(types);
    const want: []const TokenType = &.{
        .stream_start, .flow_sequence_start, .scalar, .flow_entry,
        .scalar,       .flow_entry,          .scalar, .flow_sequence_end,
        .stream_end,
    };
    try testing.expectEqualSlices(TokenType, want, types);
}

test "tabs before flow content are allowed, tab block indentation is not" {
    // Corpus 6CA3/Q5MG: tabs may precede flow content; corpus tab
    // indentation cases: tabs may not indent block constructs.
    {
        var r = try scanAll(testing.allocator, "\t[\n\t]\n");
        defer r.deinit(testing.allocator);
        const types = try tokenTypes(testing.allocator, r.toks.items);
        defer testing.allocator.free(types);
        const want: []const TokenType = &.{ .stream_start, .flow_sequence_start, .flow_sequence_end, .stream_end };
        try testing.expectEqualSlices(TokenType, want, types);
    }
    try testing.expectError(error.InvalidIndentation, scanAll(testing.allocator, "\t- item\n"));
    try testing.expectError(error.InvalidIndentation, scanAll(testing.allocator, "\t|literal\n"));
    // A tab before plain content is not indentation of a block construct
    // and is accepted.
    {
        var r = try scanAll(testing.allocator, "\tkey: value\n");
        defer r.deinit(testing.allocator);
        var scalars: std.ArrayList([]const u8) = .empty;
        defer scalars.deinit(testing.allocator);
        for (r.toks.items) |t| {
            if (t.kind == .scalar) try scalars.append(testing.allocator, t.kind.scalar.value);
        }
        try testing.expectEqualStrings("key", scalars.items[0]);
        try testing.expectEqualStrings("value", scalars.items[1]);
    }
}

test "rejections required by the corpus" {
    // '#' needs preceding whitespace to start a comment (9JBA/SU5Z).
    try testing.expectError(error.InvalidSyntax, scanAll(testing.allocator, "key: \"value\"# c\n"));
    try testing.expectError(error.InvalidSyntax, scanAll(testing.allocator, "[ a, b ]#c\n"));
    // Nothing but a comment may follow '...' (3HFZ).
    try testing.expectError(error.InvalidSyntax, scanAll(testing.allocator, "---\nkey: value\n... invalid\n"));
    // A bare '-' is not a flow entry (G5U8/YJV2).
    try testing.expectError(error.InvalidSyntax, scanAll(testing.allocator, "[-]\n"));
    try testing.expectError(error.InvalidSyntax, scanAll(testing.allocator, "[-, a]\n"));
    // Block scalar header comments need whitespace (X4QW).
    try testing.expectError(error.InvalidSyntax, scanAll(testing.allocator, "block: ># c\n  x\n"));
    // Sanity: the valid neighbours still parse.
    {
        var r = try scanAll(testing.allocator, "key: \"value\" # c\n");
        defer r.deinit(testing.allocator);
    }
    {
        var r = try scanAll(testing.allocator, "- [-a, b-c]\n");
        defer r.deinit(testing.allocator);
    }
}

test "flow adjacent values and '%' as a scalar in flow" {
    // Spec 7.18 adjacent value: ':' directly after a closing quote is a
    // value indicator (corpus C2DT); '%' inside flow is a plain scalar,
    // never a directive (corpus UT92).
    {
        var r = try scanAll(testing.allocator, "{\"adjacent\":value, \"empty\":}\n");
        defer r.deinit(testing.allocator);
        var scalars: std.ArrayList([]const u8) = .empty;
        defer scalars.deinit(testing.allocator);
        for (r.toks.items) |t| {
            if (t.kind == .scalar) try scalars.append(testing.allocator, t.kind.scalar.value);
        }
        try testing.expectEqualStrings("adjacent", scalars.items[0]);
        try testing.expectEqualStrings("value", scalars.items[1]);
        try testing.expectEqualStrings("empty", scalars.items[2]);
    }
    {
        var r = try scanAll(testing.allocator, "{% : 1}\n");
        defer r.deinit(testing.allocator);
        var scalars: std.ArrayList([]const u8) = .empty;
        defer scalars.deinit(testing.allocator);
        for (r.toks.items) |t| {
            if (t.kind == .scalar) try scalars.append(testing.allocator, t.kind.scalar.value);
        }
        try testing.expectEqualStrings("%", scalars.items[0]);
        try testing.expectEqualStrings("1", scalars.items[1]);
    }
}

test "'?' without blank starts a plain scalar" {
    // '?' is a key indicator only before blanks; '?foo' is a scalar
    // even in flow (corpus 652Z).
    var r = try scanAll(testing.allocator, "{?foo: bar}\n");
    defer r.deinit(testing.allocator);
    var scalars: std.ArrayList([]const u8) = .empty;
    defer scalars.deinit(testing.allocator);
    for (r.toks.items) |t| {
        if (t.kind == .scalar) try scalars.append(testing.allocator, t.kind.scalar.value);
    }
    try testing.expectEqualStrings("?foo", scalars.items[0]);
    try testing.expectEqualStrings("bar", scalars.items[1]);
}

test "literal keeps whitespace-only lines deeper than the strip" {
    // A space-only line below the strip column is content, not an empty
    // line (corpus 6FWR).
    var r = try scanAll(testing.allocator, "|\nab\n\n \nend\n");
    defer r.deinit(testing.allocator);
    var scalars: std.ArrayList([]const u8) = .empty;
    defer scalars.deinit(testing.allocator);
    for (r.toks.items) |t| {
        if (t.kind == .scalar) try scalars.append(testing.allocator, t.kind.scalar.value);
    }
    try testing.expectEqualStrings("ab\n\n \nend\n", scalars.items[0]);
}

test "anchor alias tag" {
    var r = try scanAll(testing.allocator, "- &a !!str x\n- *a\n- !local v\n");
    defer r.deinit(testing.allocator);
    const toks = r.toks;
    const types = try tokenTypes(testing.allocator, toks.items);
    defer testing.allocator.free(types);
    const want: []const TokenType = &.{
        .stream_start, .block_sequence_start, .block_entry, .anchor,
        .tag,          .scalar,               .block_entry, .alias,
        .block_entry,  .tag,                  .scalar,      .block_end,
        .stream_end,
    };
    try testing.expectEqualSlices(TokenType, want, types);
    try testing.expectEqualStrings("a", toks.items[3].kind.anchor);
    try testing.expectEqualStrings("!!", toks.items[4].kind.tag.handle);
    try testing.expectEqualStrings("str", toks.items[4].kind.tag.suffix);
    try testing.expectEqualStrings("a", toks.items[7].kind.alias);
    try testing.expectEqualStrings("!", toks.items[9].kind.tag.handle);
    try testing.expectEqualStrings("local", toks.items[9].kind.tag.suffix);
}

test "document markers and directives" {
    var r = try scanAll(testing.allocator, "%YAML 1.2\n---\na: b\n...\n");
    defer r.deinit(testing.allocator);
    const toks = r.toks;
    const types = try tokenTypes(testing.allocator, toks.items);
    defer testing.allocator.free(types);
    const want: []const TokenType = &.{
        .stream_start, .directive,    .document_start, .block_mapping_start,
        .key,          .scalar,       .value,          .scalar,
        .block_end,    .document_end, .stream_end,
    };
    try testing.expectEqualSlices(TokenType, want, types);
    const d = toks.items[1].kind.directive;
    try testing.expectEqualStrings("YAML", d.name);
    try testing.expectEqual(@as(usize, 1), d.params.len);
    try testing.expectEqualStrings("1.2", d.params[0]);
}

test "plain scalar folding across lines" {
    var r = try scanAll(testing.allocator, "k: a\n  b\n");
    defer r.deinit(testing.allocator);
    const toks = r.toks;
    var scalars: std.ArrayList([]const u8) = .empty;
    defer scalars.deinit(testing.allocator);
    for (toks.items) |t| {
        if (t.kind == .scalar) try scalars.append(testing.allocator, t.kind.scalar.value);
    }
    try testing.expectEqualStrings("k", scalars.items[0]);
    try testing.expectEqualStrings("a b", scalars.items[1]);
}

test "comment termination" {
    var r = try scanAll(testing.allocator, "a: b # trailing\n");
    defer r.deinit(testing.allocator);
    const toks = r.toks;
    var scalars: std.ArrayList([]const u8) = .empty;
    defer scalars.deinit(testing.allocator);
    for (toks.items) |t| {
        if (t.kind == .scalar) try scalars.append(testing.allocator, t.kind.scalar.value);
    }
    try testing.expectEqualStrings("b", scalars.items[1]);
}
