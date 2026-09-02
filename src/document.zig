//! Document model — Zig port of libfyaml's fy-doc / fy-node.
//!
//! A `Document` owns a node tree plus the pool every node lives in
//! (fy_pool semantics). Nodes use a tagged union instead of the C code's
//! type field + union pointer, which removes an entire class of
//! wrong-member accesses at compile time.

const std = @import("std");
const ctype = @import("ctype.zig");
const diag = @import("diag.zig");
const event_mod = @import("event.zig");
const internal = @import("internal.zig");
const markup = @import("markup.zig");
const parser_mod = @import("parser.zig");
const pool_mod = @import("pool.zig");
const scanner_mod = @import("scanner.zig");
const token_mod = @import("token.zig");

const Mark = diag.Mark;
const YamlError = diag.YamlError;
const Event = event_mod.Event;
const Parser = parser_mod.Parser;
const Pool = pool_mod.Pool;
const ScalarStyle = token_mod.ScalarStyle;
const CollectionStyle = event_mod.CollectionStyle;
const TagDirective = token_mod.TagDirective;
const VersionDirective = token_mod.VersionDirective;

/// The three YAML node kinds (spec 3.2.1.1) plus `alias`, which yayl
/// models as a node of its own so `*a` keeps its own source span and
/// re-emits verbatim. Aliases are first-class nodes (fy_node
/// alias semantics): `- *a` occupies its own slot in the tree with its
/// own source span and formatting, pointing at the anchored target.
pub const NodeKind = enum { scalar, mapping, sequence, alias };

/// Bounds and input policy for a parse — `scanner.Options`, named for
/// the layer callers reach it through. Use it with `parseOpts` /
/// `parseAllOpts`; `parse` and `parseAll` use the defaults.
pub const ParseOptions = scanner_mod.Options;

/// What a parse does with a NUL byte in the input. See `ParseOptions`.
pub const EmbeddedNul = scanner_mod.EmbeddedNul;

/// Layout choices for emission — `emitter.Emitter.Options`, named for
/// the layer callers reach it through. Use it with `writeOpts` /
/// `writeAllOpts`; `write` and `writeAll` use the defaults.
pub const EmitOptions = @import("emitter.zig").Emitter.Options;

/// One mapping entry; both nodes are pool-owned. `src` records where
/// the pair's bytes end in the original source (see `Node.src`), so
/// untouched pairs re-emit byte-identically.
pub const Pair = struct {
    key: *Node,
    value: *Node,
    /// Offset just past the pair's last content byte: the value's end,
    /// or the `:` for valueless (null) pairs.
    src_end: ?usize = null,
};

/// Scalar node payload: the decoded value and its presentation style.
pub const Scalar = struct {
    value: []const u8 = "",
    style: ScalarStyle = .plain,
};

/// Mapping payload. Add entries via `Document.mappingAppend`.
///
/// Key uniqueness is NOT enforced, here or at parse time: YAML 1.2
/// §3.2.1.1 requires keys to be unique, but this library keeps what the
/// input actually contained rather than rejecting it, because real-world
/// files carry duplicates and losing them silently is worse than
/// surfacing them. `lookup` returns the first match, and a duplicate
/// appended here re-emits as a second entry with the same key.
pub const Mapping = struct {
    pairs: std.ArrayList(Pair) = .empty,
    style: CollectionStyle = .block,
    /// Source byte ranges of removed entries (tombstones): the emitter
    /// skips these inside preserved gaps so deleted entries do not
    /// re-appear verbatim.
    dropped: std.ArrayList([2]usize) = .empty,
};

/// Sequence payload; items are pool-owned nodes.
pub const Sequence = struct {
    items: std.ArrayList(*Node) = .empty,
    style: CollectionStyle = .block,
    /// See `Mapping.dropped`.
    dropped: std.ArrayList([2]usize) = .empty,
};

/// One YAML node: tagged union over the three node kinds and `alias`,
/// plus shared
/// metadata. Pool-owned by the containing document; `parent` is a
/// borrowed back-pointer.
pub const Node = struct {
    parent: ?*Node = null,
    mark: Mark = .{},
    anchor: ?[]const u8 = null,
    /// Fully resolved tag URI (e.g. `tag:yaml.org,2002:int`), or null.
    tag: ?[]const u8 = null,
    /// Presentation metadata into `Document.source` (a CST-style source span). Null
    /// for programmatically created nodes, which re-emit normalized.
    src: ?markup.Src = null,
    /// True once the node's value or child list was modified after
    /// parsing; its span is no longer trusted for verbatim emission.
    modified: bool = false,
    /// Comment overrides written through `setTrailingComment`. Null means
    /// "no override"; the empty slice means "comment deleted". Non-empty
    /// text is the raw comment (`# ...`, pool-owned) the emitter writes
    /// in place of whatever the source had. See the reads, which return
    /// these as-is.
    pending_trailing: ?[]const u8 = null,
    /// Comment block written through `setLeadingComments`; same null /
    /// empty / raw convention, lines separated by `\n`.
    pending_leading: ?[]const u8 = null,
    data: Data = .{ .scalar = .{} },

    pub const Data = union(NodeKind) {
        scalar: Scalar,
        mapping: Mapping,
        sequence: Sequence,
        alias: Alias,
    };

    /// Alias payload: the `*name` occurrence and the node it resolves
    /// to. Accessors on an alias node forward to the target.
    pub const Alias = struct {
        name: []const u8,
        target: *Node,
    };

    pub fn kind(self: *const Node) NodeKind {
        return std.meta.activeTag(self.data);
    }

    pub fn isAlias(self: *const Node) bool {
        return self.data == .alias;
    }

    /// Follow alias nodes to the underlying node. Bounded so a
    /// programmatically built alias cycle terminates (the scanner
    /// rejects cycles in parsed input).
    pub fn resolveAlias(self: *const Node) *const Node {
        var cur = self;
        var depth: usize = 0;
        while (cur.data == .alias and depth < max_alias_depth) : (depth += 1) {
            cur = cur.data.alias.target;
        }
        return cur;
    }

    pub fn isScalar(self: *const Node) bool {
        return self.resolveAlias().kind() == .scalar;
    }
    pub fn isMapping(self: *const Node) bool {
        return self.resolveAlias().kind() == .mapping;
    }
    pub fn isSequence(self: *const Node) bool {
        return self.resolveAlias().kind() == .sequence;
    }

    /// Scalar value or null for collections. Alias nodes forward to
    /// their target.
    pub fn scalarValue(self: *const Node) ?[]const u8 {
        return switch (self.resolveAlias().data) {
            .scalar => |s| s.value,
            else => null,
        };
    }

    /// Mapping pairs or null.
    pub fn pairs(self: *const Node) ?[]const Pair {
        return switch (self.resolveAlias().data) {
            .mapping => |m| m.pairs.items,
            else => null,
        };
    }

    /// Sequence items or null.
    pub fn items(self: *const Node) ?[]const *Node {
        return switch (self.resolveAlias().data) {
            .sequence => |s| s.items.items,
            else => null,
        };
    }

    /// Look up a mapping entry by scalar key text. Alias nodes forward
    /// to their target.
    pub fn lookup(self: *const Node, key: []const u8) ?*Node {
        const ps = self.resolveAlias().pairs() orelse return null;
        for (ps) |p| {
            if (std.mem.eql(u8, p.key.scalarValue() orelse continue, key)) return p.value;
        }
        return null;
    }

    /// Resolve a node by a path of mapping keys, e.g. `&.{ "a", "b" }`.
    /// Alias nodes are followed.
    pub fn byPath(self: *const Node, path: []const []const u8) ?*Node {
        var cur: *const Node = self;
        for (path) |seg| {
            cur = cur.lookup(seg) orelse return null;
        }
        return @constCast(cur);
    }

    /// Depth bound for alias chasing (resolveAlias, emitter).
    pub const max_alias_depth: usize = 100;

    // ------------------------------------------------------------------
    // Comments (see docs/design/comments.md)
    // ------------------------------------------------------------------

    /// The node's trailing (same-line) comment, raw: from the `#` to the
    /// last byte before the line terminator, a slice into
    /// `Document.source` (or into the text passed to `setTrailingComment`
    /// via the document pool). Null when there is none, or when a
    /// written comment was deleted.
    ///
    /// For a `key: value # c` pair the comment is read off the VALUE
    /// node (the pair's value stands in for the pair); a block
    /// collection's trailing comment sits on its last entry's line, so
    /// the collection and that entry read the same bytes. A node built
    /// programmatically has no source bytes and reads null until
    /// something is written.
    pub fn trailingComment(self: *const Node, doc: *const Document) ?[]const u8 {
        if (self.pending_trailing) |t| return if (t.len == 0) null else t;
        const doc_src = doc.source orelse return null;
        const s = self.src orelse return null;
        if (s.synthetic) return null;
        const span = markup.trailingCommentSpan(doc_src, s.end) orelse return null;
        return doc_src[span[0]..span[1]];
    }

    /// The node's leading comment block: the own-line comment(s)
    /// immediately above the entry, with no blank line in between, raw
    /// and newline-joined (`"# one\n# two"`). Null when there is none,
    /// or when a written block was deleted.
    ///
    /// A sequence item and a mapping key carry the comments above their
    /// line; for an inline value (`host: localhost`) the value stands in
    /// for the pair and reads the pair's block, so key and value read
    /// the same bytes; for a block value (a mapping or sequence on its
    /// own line) the comments above it are its own. Free-floating
    /// comments -- separated by a blank line, or in the document head
    /// before `---` -- attach to nothing.
    pub fn leadingComments(self: *const Node, doc: *const Document) ?[]const u8 {
        if (self.pending_leading) |t| return if (t.len == 0) null else t;
        const doc_src = doc.source orelse return null;
        const s = self.src orelse return null;
        if (s.synthetic) return null;
        const span = markup.leadingCommentSpan(doc_src, s.entry_start) orelse return null;
        return doc_src[span[0]..span[1]];
    }
};

/// The Core Schema tag a plain scalar resolves to, in the spec's
/// shorthand form (`tag:yaml.org,2002:int` is `.int`). Distinct from
/// `Node.tag`, which holds a fully resolved tag URI.
pub const CoreTag = enum { null, bool, int, float, str };

/// Resolve a plain scalar to its YAML 1.2.2 Core Schema tag (spec
/// 10.3.2). Non-plain styles always resolve to `str`.
pub fn resolveCoreTag(value: []const u8, style: ScalarStyle) CoreTag {
    if (style != .plain) return .str;
    if (value.len == 0 or std.mem.eql(u8, value, "~") or
        std.mem.eql(u8, value, "null") or std.mem.eql(u8, value, "Null") or
        std.mem.eql(u8, value, "NULL")) return .null;
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "True") or
        std.mem.eql(u8, value, "TRUE") or std.mem.eql(u8, value, "false") or
        std.mem.eql(u8, value, "False") or std.mem.eql(u8, value, "FALSE")) return .bool;
    if (looksLikeInt(value)) return .int;
    if (looksLikeFloat(value)) return .float;
    return .str;
}

/// Core schema int (spec 10.3.2): `[-+]? [0-9]+`, `0o [0-7]+` or
/// `0x [0-9a-fA-F]+`. The radix forms take no sign and are lowercase
/// only, so `+0x1F`, `-0x1F`, `0X1F` and `0O7` are all strings.
fn looksLikeInt(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value.len > 2 and value[0] == '0' and value[1] == 'x') {
        for (value[2..]) |c| {
            if (ctype.hexValue(c) == null) return false;
        }
        return true;
    }
    if (value.len > 2 and value[0] == '0' and value[1] == 'o') {
        for (value[2..]) |c| {
            if (c < '0' or c > '7') return false;
        }
        return true;
    }
    var s = value;
    if (s[0] == '+' or s[0] == '-') s = s[1..];
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// YAML 1.2 core-schema non-finite float spellings (`.inf`, `.nan`,
/// case variants, optional sign) to their Zig float value. Single home
/// for the table: scalar classification (`looksLikeFloat`) and value
/// conversion both use it. (std.fmt.parseFloat rejects the leading dot
/// in `.inf`, hence the table.)
pub fn floatSpecial(value: []const u8) ?f64 {
    const inf = std.math.inf(f64);
    const nan = std.math.nan(f64);
    const map = [_]struct { t: []const u8, v: f64 }{
        .{ .t = ".inf", .v = inf },   .{ .t = ".Inf", .v = inf },   .{ .t = ".INF", .v = inf },
        .{ .t = "+.inf", .v = inf },  .{ .t = "+.Inf", .v = inf },  .{ .t = "+.INF", .v = inf },
        .{ .t = "-.inf", .v = -inf }, .{ .t = "-.Inf", .v = -inf }, .{ .t = "-.INF", .v = -inf },
        .{ .t = ".nan", .v = nan },   .{ .t = ".NaN", .v = nan },   .{ .t = ".NAN", .v = nan },
    };
    for (map) |e| {
        if (std.mem.eql(u8, value, e.t)) return e.v;
    }
    return null;
}

/// Core schema float (spec 10.3.2):
/// `[-+]? ( \. [0-9]+ | [0-9]+ ( \. [0-9]* )? ) ( [eE] [-+]? [0-9]+ )?`
/// plus the `.inf`/`.nan` spellings. At most one dot and one exponent,
/// the dot before the exponent, and the exponent digits are required —
/// so `1.2.3`, `1..2`, `1.2e3.4` and `1e` are all strings.
fn looksLikeFloat(value: []const u8) bool {
    if (floatSpecial(value) != null) return true;
    var i: usize = 0;
    if (i < value.len and (value[i] == '+' or value[i] == '-')) i += 1;

    var int_digits: usize = 0;
    while (i < value.len and value[i] >= '0' and value[i] <= '9') : (i += 1) int_digits += 1;

    var frac_digits: usize = 0;
    if (i < value.len and value[i] == '.') {
        i += 1;
        while (i < value.len and value[i] >= '0' and value[i] <= '9') : (i += 1) frac_digits += 1;
    }
    if (int_digits == 0 and frac_digits == 0) return false;

    if (i < value.len and (value[i] == 'e' or value[i] == 'E')) {
        i += 1;
        if (i < value.len and (value[i] == '+' or value[i] == '-')) i += 1;
        var exp_digits: usize = 0;
        while (i < value.len and value[i] >= '0' and value[i] <= '9') : (i += 1) exp_digits += 1;
        if (exp_digits == 0) return false;
    }
    // Anything left over (a second dot, a stray character) is not a float.
    return i == value.len;
}

/// A parsed YAML document. All nodes live in `pool`; `deinit` releases
/// everything in one go.
pub const Document = struct {
    allocator: std.mem.Allocator,
    pool: Pool,
    root: ?*Node = null,
    version: ?VersionDirective = null,
    tag_directives: std.ArrayList(TagDirective) = .empty,
    explicit_start: bool = false,
    explicit_end: bool = false,
    /// The original input this document was parsed from, duplicated
    /// into the pool so the document owns its bytes. Null for
    /// programmatically built documents. Every parsed document carries
    /// its own copy (a multi-document stream duplicates once per
    /// document); this is what makes byte-faithful round trips
    /// possible.
    ///
    /// PORT NOTE: libfyaml borrows the reader's buffer instead; here
    /// the copy keeps the documented ownership model (a Document is
    /// valid after the caller frees the input).
    source: ?[]const u8 = null,
    /// Round-trip region of this document within `source`:
    /// [region_start, body_start) is the verbatim head (directives,
    /// `---`, leading comments), the root node's span is the body, and
    /// [root end, region_end) is the verbatim tail (trailing comments,
    /// `...`). Adjacent documents tile the stream exactly. `body_end`
    /// records the original root extent so a replaced root still finds
    /// the tail.
    region_start: usize = 0,
    body_start: usize = 0,
    body_end: usize = 0,
    region_end: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Document {
        return .{ .allocator = allocator, .pool = Pool.init(allocator) };
    }

    pub fn deinit(self: *Document) void {
        self.tag_directives.deinit(self.allocator);
        self.pool.deinit();
        self.* = undefined;
    }

    /// Parse the first document of `input`. Extra documents in the same
    /// stream are ignored; use `parseAll` for multi-document streams.
    pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Document {
        return parseDiag(allocator, input, null);
    }

    /// Like `parse`, additionally recording a positioned diagnostic per
    /// problem in `d`. The error return is unchanged; on success `d`
    /// stays empty.
    pub fn parseDiag(allocator: std.mem.Allocator, input: []const u8, d: ?*diag.Diag) !Document {
        return parseOpts(allocator, input, d, .{});
    }

    /// `parseDiag` with explicit bounds and input policy. Pass `d` as
    /// null for no diagnostics.
    pub fn parseOpts(
        allocator: std.mem.Allocator,
        input: []const u8,
        d: ?*diag.Diag,
        options: ParseOptions,
    ) !Document {
        var p = try Parser.initOpts(allocator, d, input, options);
        defer p.deinit();
        var docs = try parseStream(allocator, &p, 1, input);
        defer docs.deinit(allocator);
        if (docs.items.len == 0) return Document.init(allocator);
        return docs.items[0];
    }

    /// Parse every document in `input`.
    pub fn parseAll(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(Document) {
        return parseAllDiag(allocator, input, null);
    }

    /// Like `parseAll`, additionally recording positioned diagnostics
    /// in `d`.
    pub fn parseAllDiag(allocator: std.mem.Allocator, input: []const u8, d: ?*diag.Diag) !std.ArrayList(Document) {
        return parseAllOpts(allocator, input, d, .{});
    }

    /// `parseAllDiag` with explicit bounds and input policy. Pass `d` as
    /// null for no diagnostics.
    pub fn parseAllOpts(
        allocator: std.mem.Allocator,
        input: []const u8,
        d: ?*diag.Diag,
        options: ParseOptions,
    ) !std.ArrayList(Document) {
        var p = try Parser.initOpts(allocator, d, input, options);
        defer p.deinit();
        return parseStream(allocator, &p, null, input);
    }

    fn parseStream(allocator: std.mem.Allocator, p: *Parser, limit: ?usize, input: []const u8) !std.ArrayList(Document) {
        var docs: std.ArrayList(Document) = .empty;
        var doc: ?Document = null;
        var builder: ?Builder = null;
        var cursor: usize = 0;
        errdefer {
            // Release every finished document plus the one in flight.
            for (docs.items) |*d| d.deinit();
            docs.deinit(allocator);
            if (builder) |*b| b.finish();
            if (doc) |*d| d.deinit();
        }

        while (try p.nextEvent()) |ev| {
            switch (ev.data) {
                .document_start => {
                    var d = Document.init(allocator);
                    d.version = ev.data.document_start.version;
                    d.explicit_start = !ev.data.document_start.implicit;
                    // Copy the stream input into this document's pool so
                    // presentation spans stay valid for the document's
                    // whole lifetime.
                    d.source = try d.pool.dupe(input);
                    d.region_start = cursor;
                    // Copy directive strings into the pool so the document
                    // does not depend on the parser's lifetime. The two
                    // default handles the parser always installs are not
                    // document data and are not re-emitted.
                    for (ev.data.document_start.tags) |td| {
                        if (std.mem.eql(u8, td.handle, "!") and std.mem.eql(u8, td.prefix, "!")) continue;
                        if (std.mem.eql(u8, td.handle, "!!") and std.mem.eql(u8, td.prefix, "tag:yaml.org,2002:")) continue;
                        try d.tag_directives.append(allocator, .{
                            .handle = try d.pool.dupe(td.handle),
                            .prefix = try d.pool.dupe(td.prefix),
                        });
                    }
                    doc = d;
                    // The builder works on the live document copy.
                    builder = Builder.init(&doc.?);
                },
                .document_end => {
                    if (builder) |*b| b.finish();
                    builder = null;
                    var d = doc orelse return error.InvalidSyntax;
                    d.explicit_end = !ev.data.document_end.implicit;
                    d.finishRegion(ev.start.offset);
                    // Hand ownership over only once the append succeeds;
                    // on failure the errdefer still sees `doc` and frees it.
                    try docs.append(allocator, d);
                    doc = null;
                    if (docs.items.len > 0) cursor = docs.items[docs.items.len - 1].region_end;
                    if (limit) |l| if (docs.items.len >= l) break;
                },
                .stream_start, .stream_end => {
                    if (ev.data == .stream_end) {
                        // The last document owns everything up to EOF, so
                        // trailing comments after its content (or after
                        // its `...`) stay in its region.
                        if (docs.items.len > 0) {
                            docs.items[docs.items.len - 1].region_end = input.len;
                        }
                    }
                },
                else => {
                    if (builder) |*b| try b.handle(ev);
                },
            }
        }
        return docs;
    }

    // ------------------------------------------------------------------
    // Node construction (fy_node_create_* equivalents)
    // ------------------------------------------------------------------

    /// Create a scalar node, duplicating `value` into the document pool.
    pub fn createScalar(self: *Document, value: []const u8, style: ScalarStyle) !*Node {
        const n = try self.pool.create(Node);
        n.* = .{ .data = .{ .scalar = .{ .value = try self.pool.dupe(value), .style = style } } };
        return n;
    }

    /// Create a scalar node taking ownership of a pool-owned value.
    pub fn createScalarOwned(self: *Document, value: []const u8, style: ScalarStyle) !*Node {
        const n = try self.pool.create(Node);
        n.* = .{ .data = .{ .scalar = .{ .value = value, .style = style } } };
        return n;
    }

    pub fn createMapping(self: *Document) !*Node {
        const n = try self.pool.create(Node);
        n.* = .{ .data = .{ .mapping = .{} } };
        return n;
    }

    pub fn createSequence(self: *Document) !*Node {
        const n = try self.pool.create(Node);
        n.* = .{ .data = .{ .sequence = .{} } };
        return n;
    }

    // ------------------------------------------------------------------
    // Mutation (fy_node_* insert equivalents)
    // ------------------------------------------------------------------

    // The structural attach/drop plumbing (`attachPair`, `attachItem`,
    // `dropPairSpan`, `dropItemSpan`) lives in `internal.zig` as free
    // functions, so it is unreachable from outside the module.

    /// Append a key/value pair to a mapping node, maintaining parent links.
    pub fn mappingAppend(self: *Document, map: *Node, key: *Node, value: *Node) !void {
        try internal.attachPair(self, map, key, value);
        self.markModified(map);
    }

    /// Append an item to a sequence node, maintaining parent links.
    pub fn sequenceAppend(self: *Document, seq: *Node, item: *Node) !void {
        try internal.attachItem(self, seq, item);
        self.markModified(seq);
    }

    /// Insert an item into a sequence at `index`.
    pub fn sequenceInsert(self: *Document, seq: *Node, index: usize, item: *Node) !void {
        switch (seq.data) {
            .sequence => |*s| {
                try s.items.insert(self.pool.allocator(), index, item);
                item.parent = seq;
                self.markModified(seq);
            },
            else => return error.InvalidSyntax,
        }
    }

    /// Remove the mapping entry with scalar key `key`; returns the removed
    /// value node or null when no such key exists. The entry's source
    /// bytes are tombstoned so emission skips them.
    pub fn mappingRemove(self: *Document, map: *Node, key: []const u8) !?*Node {
        switch (map.data) {
            .mapping => |*m| {
                for (m.pairs.items, 0..) |p, i| {
                    if (std.mem.eql(u8, p.key.scalarValue() orelse continue, key)) {
                        try internal.dropPairSpan(self, map, p);
                        const removed = m.pairs.orderedRemove(i);
                        removed.value.parent = null;
                        removed.key.parent = null;
                        self.markModified(map);
                        return removed.value;
                    }
                }
                return null;
            },
            else => return error.InvalidSyntax,
        }
    }

    /// Remove the sequence item at `index`.
    pub fn sequenceRemove(self: *Document, seq: *Node, index: usize) !?*Node {
        switch (seq.data) {
            .sequence => |*s| {
                if (index >= s.items.items.len) return null;
                // Tombstone BEFORE detaching: the span depends on where
                // the following item starts (as in `mappingRemove`).
                const removed = s.items.items[index];
                try internal.dropItemSpan(self, seq, removed);
                _ = s.items.orderedRemove(index);
                removed.parent = null;
                self.markModified(seq);
                return removed;
            },
            else => return error.InvalidSyntax,
        }
    }

    // ------------------------------------------------------------------
    // Comments: writes (docs/design/comments.md, approved 2026-09-02)
    // ------------------------------------------------------------------

    /// Set the node's trailing (same-line) comment. Null deletes it.
    /// `text` is raw — exactly what `trailingComment` returns: one line
    /// starting with `#`, no line breaks. A written comment re-emits
    /// canonically as `content # text` (single blank, the node's own
    /// line terminator convention kept); deleting removes the old
    /// comment and its separating blanks but keeps the terminator.
    ///
    /// Re-setting the comment the node already has is a no-op: nothing
    /// is marked, every source byte stays. The same guarantee the edit
    /// API gives for unchanged scalars, and the property the
    /// preservation sweep asserts at every comment position.
    ///
    /// Only scalars and aliases carry a writable trailing comment — a
    /// block collection's trailing comment sits on its last entry's
    /// line, so address it through that entry. A comment is not
    /// addressable inside a flow collection, and a block scalar's value
    /// owns every line after its header, so `setTrailingComment`
    /// rejects containers, flow-positioned nodes, and literal/folded
    /// scalars with `error.InvalidSyntax` rather than silently dropping
    /// the write at emission time.
    pub fn setTrailingComment(self: *Document, node: *Node, text: ?[]const u8) !void {
        // Validate the position first: a write that emission would
        // silently drop must fail here instead.
        if (!self.trailingWritablePosition(node)) return error.InvalidSyntax;
        const t = text orelse {
            if (node.trailingComment(self) == null) return; // nothing to delete
            node.pending_trailing = "";
            self.markModified(node);
            return;
        };
        try validateTrailingText(t);
        // Set-to-same is a no-op, so the byte-identical invariant holds
        // whatever spacing the original had.
        if (node.trailingComment(self)) |cur| {
            if (std.mem.eql(u8, cur, t)) return;
        }
        node.pending_trailing = try self.pool.dupe(t);
        self.markModified(node);
    }

    /// Set the node's leading comment block: the own-line comments
    /// immediately above the entry. Null deletes the block. `text` is
    /// the raw block, newline-joined (`"# one\n# two"`), every line
    /// blank-indented then `#`; one trailing newline is tolerated.
    /// Written lines re-emit at the entry's own column, with the
    /// document's line-terminator convention; a deleted block's lines
    /// disappear whole.
    ///
    /// Like `setTrailingComment`, set-to-same is a no-op. Rejects nodes
    /// whose comment block cannot be rewritten honestly — a root scalar
    /// (its head is free-floating), a scalar sitting as a block value
    /// (no gap of its own to rewrite), anything inside a flow
    /// collection, and a block separated from this document's region —
    /// with `error.InvalidSyntax`.
    pub fn setLeadingComments(self: *Document, node: *Node, text: ?[]const u8) !void {
        const t: ?[]const u8 = if (text) |raw| try normalizeLeadingText(raw) else null;
        // Position and current block, for the no-op check and the
        // tombstone below.
        const current: ?[]const u8 = blk: {
            if (self.leadingPositionWritable(node)) break :blk node.leadingComments(self);
            // Deleting from an unwritable position is a no-op unless a
            // pending override exists there to remove.
            if (t == null and node.pending_leading != null) break :blk node.pending_leading;
            return error.InvalidSyntax;
        };
        if (t) |body| {
            if (current) |cur| {
                if (std.mem.eql(u8, cur, body)) return;
            }
        } else if (current == null) return; // nothing to delete

        // Sequence matters for OOM: duplicate first, tombstone second,
        // publish last — a failure before the publish leaves the node
        // untouched (the duplicate is pool garbage, freed with the pool).
        const stored: ?[]const u8 = if (t) |body| try self.pool.dupe(body) else "";
        if (current != null and node.pending_leading == null) try self.tombstoneLeadingBlock(node);
        node.pending_leading = stored;
        self.markModified(node);
    }

    /// True when `setTrailingComment` can act on this node.
    fn trailingWritablePosition(self: *const Document, node: *Node) bool {
        _ = self;
        switch (node.data) {
            .scalar => |s| switch (s.style) {
                .literal, .folded => return false, // the value owns its lines
                else => {},
            },
            .mapping, .sequence => return false, // address the last entry
            .alias => {},
        }
        // A multi-line value re-emits as a block scalar, whose lines
        // are all its own; a comment written now would be dropped at
        // emission time.
        if (node.scalarValue()) |v| {
            if (std.mem.indexOfScalar(u8, v, '\n') != null) return false;
        }
        if (insideFlow(node)) return false;
        if (isMappingKey(node)) return false; // the pair's comment lives after the value
        return true;
    }

    /// True when `setLeadingComments` can act on this node: the position
    /// has a gap of its own, and that gap is rewritable verbatim bytes.
    fn leadingPositionWritable(self: *const Document, node: *Node) bool {
        if (insideFlow(node)) return false;
        const src = self.source orelse return false;
        const owner = gapOwnerForLeading(node, src) orelse return false;
        return dropsOf(owner) != null;
    }

    /// Tombstone the source lines of the node's current leading block,
    /// so the verbatim gap walk skips them. The range covers whole
    /// lines: the structural separator before the block (the previous
    /// line's terminator) survives, and so does the entry's own
    /// indentation after it.
    fn tombstoneLeadingBlock(self: *Document, node: *Node) !void {
        const src = self.source orelse return;
        const s = node.src orelse return; // brand-new: no block in the source
        if (s.synthetic) return;
        const span = markup.leadingCommentSpan(src, s.entry_start) orelse return;
        // A root entry sharing its line with `---` reads backwards into
        // the previous document's region; those bytes are not ours.
        if (span[0] < self.region_start or span[1] > self.region_end) return error.InvalidSyntax;
        const owner = gapOwnerForLeading(node, src) orelse return error.InvalidSyntax;
        const drops = dropsOf(owner) orelse return error.InvalidSyntax;
        const from = markup.lineStart(src, span[0]);
        const to = markup.lineEnd(src, span[1]);
        if (to <= from) return;
        try internal.dropRange(self, drops, from, to);
    }

    fn validateTrailingText(t: []const u8) !void {
        if (t.len == 0 or t[0] != '#') return error.InvalidSyntax;
        for (t) |c| {
            if (c == '\n' or c == '\r') return error.InvalidSyntax;
        }
    }

    /// Strip one optional trailing newline and require every line to be
    /// blank-indented then `#`. Blank lines inside a block are rejected:
    /// they would break the adjacency that makes the block re-readable.
    fn normalizeLeadingText(raw: []const u8) ![]const u8 {
        var t = raw;
        if (std.mem.endsWith(u8, t, "\r\n")) t = t[0 .. t.len - 2];
        if (std.mem.endsWith(u8, t, "\n")) t = t[0 .. t.len - 1];
        if (t.len == 0) return error.InvalidSyntax;
        var it = std.mem.splitScalar(u8, t, '\n');
        while (it.next()) |line| {
            var i: usize = 0;
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
            if (i >= line.len or line[i] != '#') return error.InvalidSyntax;
        }
        return t;
    }

    fn isMappingKey(node: *const Node) bool {
        const parent = node.parent orelse return false;
        if (parent.kind() != .mapping) return false;
        for (parent.pairs().?) |p| {
            if (p.key == node) return true;
        }
        return false;
    }

    fn insideFlow(node: *const Node) bool {
        const parent = node.parent orelse return false;
        return switch (parent.data) {
            .mapping => |m| m.style == .flow,
            .sequence => |s| s.style == .flow,
            else => false,
        };
    }

    /// The container whose verbatim gap carries the node's leading
    /// block, and therefore whose tombstone list must record it: the
    /// parent for keys, items and inline values; the node itself for a
    /// block value (the comments sit between its key's colon and its
    /// first line). Null when the position has no gap of its own.
    fn gapOwnerForLeading(node: *Node, src: []const u8) ?*Node {
        const parent = node.parent orelse {
            // The root. A container's first entry can carry a block in
            // the document head; a root scalar's head is free-floating.
            return switch (node.data) {
                .mapping, .sequence => node,
                else => null,
            };
        };
        switch (parent.data) {
            .mapping => {
                if (isBlockValue(parent, node, src)) return node;
                return parent;
            },
            .sequence => return parent,
            else => return null,
        }
    }

    /// True when `node` is a mapping value that starts on its own line
    /// (a block value), rather than one sitting after `key:` on the
    /// key's line.
    fn isBlockValue(parent: *const Node, node: *const Node, src: []const u8) bool {
        const ps = parent.pairs() orelse return false;
        for (ps) |p| {
            if (p.value != node) continue;
            const ks = p.key.src orelse return false;
            const ns = node.src orelse return false;
            if (ks.synthetic or ns.synthetic) return false;
            return markup.lineStart(src, ns.entry_start) > markup.lineStart(src, ks.start);
        }
        return false;
    }

    fn dropsOf(node: *Node) ?*std.ArrayList([2]usize) {
        return switch (node.data) {
            .mapping => |*m| &m.dropped,
            .sequence => |*s| &s.dropped,
            else => null,
        };
    }

    /// Look a node up by mapping-key path.
    pub fn pathGet(self: *const Document, path: []const []const u8) ?*Node {
        const r = self.root orelse return null;
        return r.byPath(path);
    }

    /// Walk the mapping-key chain `keys` (the segments ABOVE a final
    /// key) from the root, creating the root mapping and intermediate
    /// mappings as needed; returns the container holding the final key.
    pub fn mappingWalkOrCreate(self: *Document, keys: []const []const u8) !*Node {
        if (self.root == null) {
            self.root = try self.createMapping();
        }
        var cur = self.root.?;
        for (keys) |seg| {
            if (cur.lookup(seg)) |next| {
                if (!next.isMapping()) return error.NotAMapping;
                cur = next;
            } else {
                const m = try self.createMapping();
                try self.mappingAppend(cur, try self.createScalar(seg, .plain), m);
                cur = m;
            }
        }
        return cur;
    }

    /// Set the value at a mapping-key path, creating intermediate mappings
    /// as needed. The final segment is replaced or appended.
    pub fn pathSet(self: *Document, path: []const []const u8, value: *Node) !void {
        if (path.len == 0) return error.InvalidSyntax;
        const cur = try self.mappingWalkOrCreate(path[0 .. path.len - 1]);
        const last = path[path.len - 1];
        if (cur.lookup(last)) |existing| {
            // `lookup` only matches values of the mapping `cur`, so the
            // in-place replace must succeed; falling through would
            // append a duplicate key.
            if (!internal.mappingReplace(self, cur, existing, value)) return error.InvalidSyntax;
            return;
        }
        try self.mappingAppend(cur, try self.createScalar(last, .plain), value);
    }

    /// Delete the mapping entry at a mapping-key path. Returns true when
    /// something was removed.
    pub fn pathDelete(self: *Document, path: []const []const u8) !bool {
        if (path.len == 0) return false;
        var cur = self.root orelse return false;
        for (path[0 .. path.len - 1]) |seg| {
            cur = cur.lookup(seg) orelse return false;
        }
        return (try self.mappingRemove(cur, path[path.len - 1])) != null;
    }

    /// Mark a node's subtree as no longer byte-trustworthy, propagating
    /// to every ancestor: a container whose bytes changed must not be
    /// re-emitted verbatim from its parent slot, and the parent's parent
    /// must not re-emit *it* verbatim, and so on. Unmodified siblings
    /// stay verbatim regardless (the emitter walks per slot).
    pub fn markModified(self: *Document, node: *Node) void {
        _ = self;
        var cur: ?*Node = node;
        while (cur) |n| {
            n.modified = true;
            cur = n.parent;
        }
    }

    /// The `dropped` tombstone list of a collection node (source ranges
    /// of removed entries that verbatim emission must skip).
    pub fn droppedOf(node: *const Node) []const [2]usize {
        return switch (node.data) {
            .mapping => |m| m.dropped.items,
            .sequence => |s| s.dropped.items,
            else => &.{},
        };
    }

    /// Compute the round-trip region once the tree is complete.
    /// `doc_end` is the byte offset of the `...` token when the document
    /// ended explicitly (otherwise ignored). The tail runs to the end of
    /// the content's line (implicit end) or of the `...` line.
    fn finishRegion(self: *Document, doc_end: usize) void {
        const src = self.source orelse return;
        const root = self.root orelse return;
        const rs = root.src orelse return;
        self.body_start = rs.entry_start;
        self.body_end = rs.end;
        // The implicit region ends where the root's last LINE ends: a
        // trailing comment on the root's own line is this document's
        // tail, not the next document's leading bytes. (Found by the
        // comment API: `parse` never reaches the stream-end event that
        // used to paper over this by handing those bytes to the next
        // document's head, so `parse` + `write` dropped a root trailing
        // comment.)
        var end = rs.end;
        if (self.explicit_end) {
            end = markup.lineEnd(src, doc_end);
        } else if (end < src.len) {
            if (rs.synthetic) {
                // A synthesized empty scalar's span is a point borrowed
                // from the next token; extending to its line end would
                // swallow the next document's bytes (corpus 6XDY). The
                // terminator itself is still structural.
                if (src[end] == '\r' and end + 1 < src.len and src[end + 1] == '\n') {
                    end += 2;
                } else if (src[end] == '\n') {
                    end += 1;
                }
            } else {
                end = markup.lineEnd(src, end);
            }
        }
        self.region_end = @max(end, self.body_start);
    }

    /// Render the document back to YAML text (see emitter.zig).
    ///
    /// Documents produced by `parse`/`parseAll` re-emit their original
    /// bytes verbatim (comments, blank lines, quoting, key order and
    /// indentation included) unless a node was modified after parsing;
    /// modified subtrees are re-emitted normalized in place.
    pub fn write(self: *const Document, allocator: std.mem.Allocator) ![]u8 {
        return self.writeOpts(allocator, .{});
    }

    /// `write` with explicit layout choices for the parts the emitter
    /// lays out itself. See `EmitOptions`.
    pub fn writeOpts(self: *const Document, allocator: std.mem.Allocator, options: EmitOptions) ![]u8 {
        const emitter_mod = @import("emitter.zig");
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var em = emitter_mod.Emitter.init(allocator, &out);
        defer em.deinit();
        em.configure(options);
        try em.emitDocument(self);
        return try out.toOwnedSlice(allocator);
    }
};

/// Serialize a whole stream: every document, in order, into one buffer.
///
/// The counterpart to `parseAll`. `writeAll(parseAll(input))` reproduces
/// `input` byte for byte, because each document keeps its own source
/// region and the regions are contiguous across the stream.
///
/// Concatenating `doc.write()` yourself is *not* the same thing, and the
/// difference is a silent corruption rather than an error: two documents
/// that carry no document-start marker between them — two separately
/// parsed single-document strings, or two documents built by hand —
/// concatenate into one document, and two mappings become one mapping
/// with duplicate keys. This inserts `---` wherever a boundary is
/// required and absent, and inserts nothing where one is already there,
/// which is why the round trip stays byte-exact.
///
/// Each document is emitted by its own `Emitter`, so anchors are scoped
/// per document as YAML requires.
pub fn writeAll(allocator: std.mem.Allocator, docs: []const Document) ![]u8 {
    return writeAllOpts(allocator, docs, .{});
}

/// `writeAll` with explicit layout choices. See `EmitOptions`.
pub fn writeAllOpts(allocator: std.mem.Allocator, docs: []const Document, options: EmitOptions) ![]u8 {
    const emitter_mod = @import("emitter.zig");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (docs, 0..) |*doc, i| {
        const body_start = out.items.len;
        var em = emitter_mod.Emitter.init(allocator, &out);
        defer em.deinit();
        em.configure(options);
        try em.emitDocument(doc);

        if (i == 0) continue;
        if (endsStream(out.items[0..body_start])) continue;
        if (startsDocument(out.items[body_start..])) continue;

        // No boundary either side: supply one. Nothing is inserted on
        // the path above, which is what keeps a parsed stream byte-exact
        // -- including the case that motivated this shape, where a
        // document's region ends mid-line (`--- foo`) and its own
        // trailing comment belongs to the *next* document's leading
        // bytes. Inserting a newline there unconditionally would cut
        // that line in half.
        const sep = if (body_start > 0 and out.items[body_start - 1] != '\n') "\n---\n" else "---\n";
        try out.insertSlice(allocator, body_start, sep);
    }

    return try out.toOwnedSlice(allocator);
}

/// True when `text` opens a new document — its first line that is not
/// blank, a comment or a directive is a `---` marker. Directives imply
/// one, since a directive can only precede a document start.
fn startsDocument(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        if (trimmed[0] == '%') return true;
        return std.mem.startsWith(u8, line, "---") and
            (line.len == 3 or line[3] == ' ' or line[3] == '\t');
    }
    return false;
}

/// True when `text` ends with an explicit `...` end-of-document marker,
/// which is itself a boundary: the next document needs no `---`.
fn endsStream(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    var last: []const u8 = "";
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        last = line;
    }
    return std.mem.startsWith(u8, last, "...") and
        (last.len == 3 or last[3] == ' ' or last[3] == '\t');
}

/// Builds a node tree out of parser events (fy_docbuilder). While
/// building, every node records its source span (see `markup.Src`) so
/// untouched regions re-emit byte-identically.
const Builder = struct {
    doc: *Document,
    source: []const u8,
    stack: std.ArrayList(Frame),
    anchors: std.StringHashMap(*Node),

    const Frame = struct {
        node: *Node,
        pending_key: ?*Node = null,
    };

    fn init(doc: *Document) Builder {
        return .{
            .doc = doc,
            .source = doc.source orelse "",
            .stack = .empty,
            .anchors = std.StringHashMap(*Node).init(doc.allocator),
        };
    }

    fn deinit(self: *Builder) void {
        self.stack.deinit(self.doc.allocator);
        self.anchors.deinit();
    }

    fn finish(self: *Builder) void {
        self.deinit();
    }

    /// Presentation span for an event: byte offsets into the document
    /// source, with the entry indicator (`-`/`?`) walked backwards.
    fn spanOf(self: *Builder, ev: Event) markup.Src {
        const synthetic = switch (ev.data) {
            .scalar => |s| s.synthetic,
            else => false,
        };
        var end = ev.end.offset;
        // The scanner's scalar end marks swallow trailing blanks (and,
        // for block scalars, the final line break). Those bytes are
        // structure, not content: trim them off the span so the gap
        // bytes carry them instead. Quoted scalars end at the closing
        // quote and are unaffected.
        if (ev.data == .scalar and !synthetic) {
            const src = self.source;
            while (end > ev.start.offset and end <= src.len and
                (src[end - 1] == ' ' or src[end - 1] == '\t' or
                    src[end - 1] == '\r' or src[end - 1] == '\n')) end -= 1;
        }
        return .{
            .entry_start = if (synthetic)
                ev.start.offset
            else
                markup.entryStart(self.source, ev.start.offset),
            .start = ev.start.offset,
            .end = end,
            .synthetic = synthetic,
        };
    }

    fn handle(self: *Builder, ev: Event) !void {
        switch (ev.data) {
            .scalar => {
                const n = try self.doc.pool.create(Node);
                n.* = .{
                    .mark = ev.start,
                    .anchor = try self.dupeOptional(ev.data.scalar.anchor),
                    .tag = try self.dupeOptional(ev.data.scalar.tag),
                    .src = self.spanOf(ev),
                    .data = .{ .scalar = .{
                        .value = try self.doc.pool.dupe(ev.data.scalar.value),
                        .style = ev.data.scalar.style,
                    } },
                };
                try self.registerAnchor(n.anchor, n);
                try self.attach(n);
            },
            .alias => {
                const target = self.anchors.get(ev.data.alias) orelse
                    return error.UnknownAlias;
                const n = try self.doc.pool.create(Node);
                n.* = .{
                    .mark = ev.start,
                    .src = self.spanOf(ev),
                    .data = .{ .alias = .{
                        .name = try self.doc.pool.dupe(ev.data.alias),
                        .target = target,
                    } },
                };
                try self.attach(n);
            },
            .sequence_start => try self.startCollection(ev, ev.data.sequence_start),
            .mapping_start => try self.startCollection(ev, ev.data.mapping_start),
            .sequence_end => {
                const frame = self.stack.pop().?;
                if (frame.node.kind() != .sequence) return error.InvalidSyntax;
                // Flow collections close with a bracket: their span ends
                // there. Block collections keep the last child's end.
                if (frame.node.data == .sequence and frame.node.data.sequence.style == .flow) {
                    if (frame.node.src) |*s| s.end = ev.end.offset;
                }
                self.finishChild(frame.node);
            },
            .mapping_end => {
                const frame = self.stack.pop().?;
                if (frame.node.kind() != .mapping) return error.InvalidSyntax;
                if (frame.node.data == .mapping and frame.node.data.mapping.style == .flow) {
                    if (frame.node.src) |*s| s.end = ev.end.offset;
                }
                self.finishChild(frame.node);
            },
            else => {},
        }
    }

    /// A collection just closed: its span end is now final. Propagate it
    /// to the slot it occupies — the enclosing pair's `src_end` (an
    /// attach-time snapshot of a collection value still pointed at its
    /// opening bracket) and the parent container's span.
    fn finishChild(self: *Builder, coll: *Node) void {
        const cs = coll.src orelse return;
        const parent = coll.parent orelse return;
        switch (parent.data) {
            .sequence => self.growSpan(parent, cs),
            .mapping => {
                for (parent.data.mapping.pairs.items) |*p| {
                    if (p.value == coll) {
                        p.src_end = cs.end;
                        self.growSpan(parent, cs);
                        return;
                    }
                }
            },
            else => {},
        }
    }

    fn startCollection(self: *Builder, ev: Event, cs: Event.CollectionStart) !void {
        const n = if (ev.data == .sequence_start)
            try self.doc.createSequence()
        else
            try self.doc.createMapping();
        n.mark = ev.start;
        n.anchor = try self.dupeOptional(cs.anchor);
        n.tag = try self.dupeOptional(cs.tag);
        n.src = self.spanOf(ev);
        switch (n.data) {
            .sequence => |*s| s.style = cs.style,
            .mapping => |*m| m.style = cs.style,
            else => unreachable,
        }
        try self.registerAnchor(n.anchor, n);
        try self.attach(n);
        try self.stack.append(self.doc.allocator, .{ .node = n });
    }

    /// Copy an optional parser-owned string into the document pool.
    fn dupeOptional(self: *Builder, s: ?[]const u8) !?[]const u8 {
        const v = s orelse return null;
        return try self.doc.pool.dupe(v);
    }

    fn registerAnchor(self: *Builder, anchor: ?[]const u8, n: *Node) !void {
        const a = anchor orelse return;
        // Re-anchoring is legal (corpus 3GZX/PW8X, libyaml semantics):
        // a second `&a` definition shadows the first for later aliases,
        // exactly like the event-level parser already treats it.
        const gop = try self.anchors.getOrPut(a);
        gop.value_ptr.* = n;
    }

    /// Attach a freshly produced node at the current position, growing
    /// the enclosing container's span to cover it.
    fn attach(self: *Builder, n: *Node) !void {
        if (self.stack.items.len == 0) {
            self.doc.root = n;
            return;
        }
        const frame = &self.stack.items[self.stack.items.len - 1];
        switch (frame.node.data) {
            .sequence => {
                try internal.attachItem(self.doc, frame.node, n);
                self.growSpan(frame.node, n.src orelse return);
            },
            .mapping => {
                if (frame.pending_key) |key| {
                    try internal.attachPair(self.doc, frame.node, key, n);
                    // A valueless pair ends at its ':'; a synthesized
                    // empty value's own span points at the next token
                    // and must not be trusted.
                    const key_end: usize = if (key.src) |ks| ks.end else key.mark.offset;
                    const pair_end: usize = if (n.src) |vs|
                        (if (vs.synthetic) markup.colonEnd(self.source, key_end) else vs.end)
                    else
                        key_end;
                    if (frame.node.data == .mapping) {
                        const pairs = frame.node.data.mapping.pairs.items;
                        if (pairs.len > 0) pairs[pairs.len - 1].src_end = pair_end;
                    }
                    self.growSpan(frame.node, .{ .entry_start = 0, .start = 0, .end = pair_end });
                    frame.pending_key = null;
                } else {
                    frame.pending_key = n;
                }
            },
            .scalar, .alias => return error.InvalidSyntax,
        }
    }

    fn growSpan(self: *Builder, parent: *Node, child_span: markup.Src) void {
        _ = self;
        if (parent.src) |*ps| {
            if (child_span.end > ps.end) ps.end = child_span.end;
        }
    }
};

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

test "parse simple document" {
    var doc = try Document.parse(testing.allocator, "a: 1\nb:\n  - x\n  - y\n");
    defer doc.deinit();
    const root = doc.root.?;
    try testing.expect(root.isMapping());
    try testing.expectEqualStrings("1", root.lookup("a").?.scalarValue().?);
    const seq = root.lookup("b").?;
    try testing.expect(seq.isSequence());
    try testing.expectEqual(@as(usize, 2), seq.items().?.len);
    try testing.expectEqualStrings("y", seq.items().?[1].scalarValue().?);
}

test "alias resolves to target" {
    var doc = try Document.parse(testing.allocator, "- &v 42\n- *v\n");
    defer doc.deinit();
    const seq = doc.root.?;
    const items = seq.items().?;
    // The alias is its own node (`*v`) pointing at the anchor target.
    try testing.expect(items[0] != items[1]);
    try testing.expect(items[1].isAlias());
    try testing.expect(items[1].resolveAlias() == items[0]);
    try testing.expectEqualStrings("42", items[1].scalarValue().?);
    // Byte-faithful emission keeps the alias form.
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("- &v 42\n- *v\n", out);
}

test "unknown alias fails" {
    const r = Document.parse(testing.allocator, "- *nope\n");
    try testing.expectError(error.UnknownAlias, r);
}

test "scalar kind classification" {
    try testing.expectEqual(CoreTag.null, resolveCoreTag("~", .plain));
    try testing.expectEqual(CoreTag.null, resolveCoreTag("", .plain));
    try testing.expectEqual(CoreTag.bool, resolveCoreTag("true", .plain));
    try testing.expectEqual(CoreTag.int, resolveCoreTag("-42", .plain));
    try testing.expectEqual(CoreTag.int, resolveCoreTag("0x1F", .plain));
    try testing.expectEqual(CoreTag.float, resolveCoreTag("1.5e3", .plain));
    try testing.expectEqual(CoreTag.float, resolveCoreTag(".inf", .plain));
    try testing.expectEqual(CoreTag.str, resolveCoreTag("true", .single_quoted));
    try testing.expectEqual(CoreTag.str, resolveCoreTag("0x1F", .double_quoted));
    try testing.expectEqual(CoreTag.str, resolveCoreTag("hello", .plain));
}

test "core schema tag resolution rejects near-miss int and float forms" {
    // Spec 10.3.2. Every lexeme here resolves to str: the hex and octal
    // int forms take no sign and are lowercase only, and the float
    // production allows one dot, before one exponent, whose digits are
    // required. Nothing in the pinned corpus exercises this table, so it
    // is the only thing standing between these and a silent regression.
    const str_cases = [_][]const u8{
        "+0x1F", "-0x1F",   "0X1F", "0O7",     "+0o7",
        "1.2.3", "1.2.3.4", "1..2", "1.2e3.4", "1e",
        "1e+",   ".",       "+",    "-",
    };
    for (str_cases) |c| {
        testing.expectEqual(CoreTag.str, resolveCoreTag(c, .plain)) catch |err| {
            std.debug.print("expected str for \"{s}\", got {s}\n", .{ c, @tagName(resolveCoreTag(c, .plain)) });
            return err;
        };
    }

    // The forms the spec does accept must keep resolving.
    try testing.expectEqual(CoreTag.int, resolveCoreTag("0x1F", .plain));
    try testing.expectEqual(CoreTag.int, resolveCoreTag("0o7", .plain));
    try testing.expectEqual(CoreTag.int, resolveCoreTag("-42", .plain));
    try testing.expectEqual(CoreTag.int, resolveCoreTag("+42", .plain));
    try testing.expectEqual(CoreTag.float, resolveCoreTag("1.5e3", .plain));
    try testing.expectEqual(CoreTag.float, resolveCoreTag("-1.5E-3", .plain));
    try testing.expectEqual(CoreTag.float, resolveCoreTag(".5", .plain));
    try testing.expectEqual(CoreTag.float, resolveCoreTag("1.", .plain));
    try testing.expectEqual(CoreTag.float, resolveCoreTag(".inf", .plain));
    try testing.expectEqual(CoreTag.float, resolveCoreTag("-.INF", .plain));
    try testing.expectEqual(CoreTag.float, resolveCoreTag(".nan", .plain));
}

test "builder API and path API" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();

    const root = try doc.createMapping();
    doc.root = root;
    try doc.pathSet(&.{ "server", "host" }, try doc.createScalar("localhost", .plain));
    try doc.pathSet(&.{ "server", "port" }, try doc.createScalar("8080", .plain));
    try doc.pathSet(&.{"debug"}, try doc.createScalar("true", .plain));

    try testing.expectEqualStrings("localhost", doc.pathGet(&.{ "server", "host" }).?.scalarValue().?);
    try testing.expectEqualStrings("8080", doc.pathGet(&.{ "server", "port" }).?.scalarValue().?);

    // Replace in place keeps insertion order.
    try doc.pathSet(&.{ "server", "host" }, try doc.createScalar("example.org", .plain));
    const server = doc.root.?.lookup("server").?;
    try testing.expectEqualStrings("example.org", server.pairs().?[0].value.scalarValue().?);

    try testing.expect(try doc.pathDelete(&.{"debug"}));
    try testing.expect(doc.pathGet(&.{"debug"}) == null);
    try testing.expect(!(try doc.pathDelete(&.{"debug"})));
}

test "sequence mutation" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    const seq = try doc.createSequence();
    doc.root = seq;
    try doc.sequenceAppend(seq, try doc.createScalar("a", .plain));
    try doc.sequenceAppend(seq, try doc.createScalar("c", .plain));
    try doc.sequenceInsert(seq, 1, try doc.createScalar("b", .plain));
    try testing.expectEqualStrings("a", seq.items().?[0].scalarValue().?);
    try testing.expectEqualStrings("b", seq.items().?[1].scalarValue().?);
    try testing.expectEqualStrings("c", seq.items().?[2].scalarValue().?);
    _ = try doc.sequenceRemove(seq, 1);
    try testing.expectEqual(@as(usize, 2), seq.items().?.len);
}

// ----------------------------------------------------------------------
// Round-trip editing tests: targeted edits keep untouched
// bytes — comments, blank lines, quoting, key order, indentation.
// ----------------------------------------------------------------------

test "edit one value keeps sibling bytes verbatim" {
    const src =
        \\# service configuration
        \\name: api
        \\port: 8080   # user facing
        \\
        \\# debug section
        \\debug: false
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try doc.pathSet(&.{"port"}, try doc.createScalar("9090", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\# service configuration
        \\name: api
        \\port: 9090   # user facing
        \\
        \\# debug section
        \\debug: false
        \\
    , out);
}

test "deep edit preserves outer formatting" {
    const src =
        \\server:
        \\  # the main host
        \\  host: localhost
        \\  ports:
        \\    - 80
        \\    - 443
        \\tls: true
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try doc.pathSet(&.{ "server", "host" }, try doc.createScalar("example.org", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\server:
        \\  # the main host
        \\  host: example.org
        \\  ports:
        \\    - 80
        \\    - 443
        \\tls: true
        \\
    , out);
}

test "delete entry removes its line but keeps neighbors" {
    const src =
        \\keep-a: 1
        \\drop-me: 2 # gone
        \\keep-b: 3
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try testing.expect(try doc.pathDelete(&.{"drop-me"}));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("keep-a: 1\nkeep-b: 3\n", out);
}

test "append entry at end of mapping" {
    const src = "a: 1\nb: 2\n";
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    const root = doc.root.?;
    try doc.mappingAppend(root, try doc.createScalar("c", .plain), try doc.createScalar("3", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: 1\nb: 2\nc: 3\n", out);
}

test "a BOM before a leading comment line still parses" {
    // The '#' is at line start, but the byte before it is the BOM's
    // last byte: the comment check used to look only at that byte and
    // rejected the document. Found by the preservation gate's BOM
    // fixture variants.
    const src = "\xEF\xBB\xBF# comment\nkey: value\n";
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try testing.expectEqualStrings("value", doc.pathGet(&.{"key"}).?.scalarValue().?);
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "append entry uses sibling indentation" {
    const src =
        \\top:
        \\    deep:
        \\        one: 1
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    const deep = doc.pathGet(&.{ "top", "deep" }).?;
    try doc.mappingAppend(deep, try doc.createScalar("two", .plain), try doc.createScalar("2", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\top:
        \\    deep:
        \\        one: 1
        \\        two: 2
        \\
    , out);
}

test "sequence append keeps items verbatim" {
    const src =
        \\items:
        \\  - first  # keep
        \\  - second
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    const items = doc.pathGet(&.{"items"}).?;
    try doc.sequenceAppend(items, try doc.createScalar("third", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\items:
        \\  - first  # keep
        \\  - second
        \\  - third
        \\
    , out);
}

test "sequence remove drops the item line" {
    const src =
        \\items:
        \\  - first
        \\  - second
        \\  - third
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    const items = doc.pathGet(&.{"items"}).?;
    _ = try doc.sequenceRemove(items, 1);
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("items:\n  - first\n  - third\n", out);
}

test "replace value whose key carries a trailing comment" {
    const src =
        \\a:
        \\  b: 1 # answer
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try doc.pathSet(&.{ "a", "b" }, try doc.createScalar("42", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a:\n  b: 42 # answer\n", out);
}

test "edit in one document of a stream leaves the others verbatim" {
    const src =
        \\---
        \\first: 1
        \\---
        \\second: 2
        \\---
        \\third: 3
        \\
    ;
    var docs = try Document.parseAll(testing.allocator, src);
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 3), docs.items.len);
    try docs.items[1].pathSet(&.{"second"}, try docs.items[1].createScalar("TWO", .plain));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    for (docs.items) |*d| {
        const t = try d.write(testing.allocator);
        defer testing.allocator.free(t);
        try out.appendSlice(testing.allocator, t);
    }
    try testing.expectEqualStrings(
        \\---
        \\first: 1
        \\---
        \\second: TWO
        \\---
        \\third: 3
        \\
    , out.items);
}

test "replace block scalar value in place" {
    const src =
        \\# script
        \\run: |
        \\  echo one
        \\  echo two
        \\after: true
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try doc.pathSet(&.{"run"}, try doc.createScalar("echo three", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\# script
        \\run: echo three
        \\after: true
        \\
    , out);
}

test "allocation failures in edit+write leak nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, editWrite, .{});
}

fn editWrite(allocator: std.mem.Allocator) !void {
    var doc = try Document.parse(allocator, "a: 1\nb:\n  - x  # keep\n  - y\n");
    defer doc.deinit();
    try doc.pathSet(&.{"a"}, try doc.createScalar("2", .plain));
    const items = doc.pathGet(&.{"b"}).?;
    try doc.sequenceAppend(items, try doc.createScalar("z", .plain));
    const out = try doc.write(allocator);
    defer allocator.free(out);
}

test "writeAll reproduces a parsed stream byte for byte" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        "a: 1\n---\nb: 2\n",
        "---\nfirst: doc\n---\nsecond: doc\n",
        "a: 1\n...\n---\nb: 2\n",
        "# leading\n---\none\n--- two\n",
        "%YAML 1.2\n---\na\n...\n",
        "just: one\n",
        // Corpus L383. Document 1's region ends mid-line at `--- foo`,
        // and its own trailing comment is carried in document 2's
        // leading bytes. Anything that "helpfully" terminates a document
        // before the next one cuts that line in half; caught by the
        // corpus gate, pinned here so it does not need the corpus.
        "--- foo  # comment\n--- foo  # comment\n",
    };
    for (cases) |input| {
        var docs = try Document.parseAll(allocator, input);
        defer {
            for (docs.items) |*d| d.deinit();
            docs.deinit(allocator);
        }
        const out = try writeAll(allocator, docs.items);
        defer allocator.free(out);
        try testing.expectEqualStrings(input, out);
    }
}

test "writeAll separates documents that would otherwise merge" {
    const allocator = std.testing.allocator;

    // Two separately parsed single-document strings. Each re-emits as
    // its own bytes with no marker, so plain concatenation yields one
    // mapping with two keys -- valid YAML, wrong data, no error.
    var first = try Document.parse(allocator, "a: 1\n");
    defer first.deinit();
    var second = try Document.parse(allocator, "b: 2\n");
    defer second.deinit();

    const naive = blk: {
        const x = try first.write(allocator);
        defer allocator.free(x);
        const y = try second.write(allocator);
        defer allocator.free(y);
        break :blk try std.mem.concat(allocator, u8, &.{ x, y });
    };
    defer allocator.free(naive);
    {
        var merged = try Document.parseAll(allocator, naive);
        defer {
            for (merged.items) |*d| d.deinit();
            merged.deinit(allocator);
        }
        // The corruption this guards against, pinned so the test fails
        // if it ever stops being a corruption.
        try testing.expectEqual(@as(usize, 1), merged.items.len);
    }

    const out = try writeAll(allocator, &.{ first, second });
    defer allocator.free(out);
    try testing.expectEqualStrings("a: 1\n---\nb: 2\n", out);

    var back = try Document.parseAll(allocator, out);
    defer {
        for (back.items) |*d| d.deinit();
        back.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 2), back.items.len);
    try testing.expectEqualStrings("1", back.items[0].pathGet(&.{"a"}).?.scalarValue().?);
    try testing.expectEqualStrings("2", back.items[1].pathGet(&.{"b"}).?.scalarValue().?);
}

test "writeAll separates hand-built documents" {
    const allocator = std.testing.allocator;
    var one = Document.init(allocator);
    defer one.deinit();
    one.root = try one.createMapping();
    try one.pathSet(&.{"a"}, try one.createScalar("1", .plain));

    var two = Document.init(allocator);
    defer two.deinit();
    two.root = try two.createMapping();
    try two.pathSet(&.{"b"}, try two.createScalar("2", .plain));

    const out = try writeAll(allocator, &.{ one, two });
    defer allocator.free(out);

    var back = try Document.parseAll(allocator, out);
    defer {
        for (back.items) |*d| d.deinit();
        back.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 2), back.items.len);

    // A document that asks for its own marker does not get a second one.
    try testing.expect(std.mem.indexOf(u8, out, "------") == null);
    two.explicit_start = true;
    const again = try writeAll(allocator, &.{ one, two });
    defer allocator.free(again);
    try testing.expectEqualStrings(out, again);
}

test "emit options set the indent for content the emitter lays out" {
    const allocator = std.testing.allocator;

    // A document built from nothing has no convention to measure, so
    // before this its indent was simply 2, with no way to say otherwise.
    var doc = Document.init(allocator);
    defer doc.deinit();
    doc.root = try doc.createMapping();
    const inner = try doc.createMapping();
    try doc.mappingAppend(doc.root.?, try doc.createScalar("outer", .plain), inner);
    try doc.mappingAppend(inner, try doc.createScalar("key", .plain), try doc.createScalar("v", .plain));

    const two = try doc.write(allocator);
    defer allocator.free(two);
    try testing.expectEqualStrings("outer:\n  key: v\n", two);

    const four = try doc.writeOpts(allocator, .{ .indent = 4 });
    defer allocator.free(four);
    try testing.expectEqualStrings("outer:\n    key: v\n", four);

    // Clamped rather than trusted: 0 would emit unparseable YAML.
    const clamped = try doc.writeOpts(allocator, .{ .indent = 0 });
    defer allocator.free(clamped);
    try testing.expectEqualStrings("outer:\n key: v\n", clamped);
}

test "emit options cannot disturb bytes that re-emit verbatim" {
    const allocator = std.testing.allocator;
    // The guarantee has priority over the preference: untouched source
    // bytes are copied, so an indent request cannot reach them.
    const src = "outer:\n      key: v\n      other: w\n";
    var doc = try Document.parse(allocator, src);
    defer doc.deinit();
    const out = try doc.writeOpts(allocator, .{ .indent = 2 });
    defer allocator.free(out);
    try testing.expectEqualStrings(src, out);

    // It does reach a new subtree, which has no source bytes of its own.
    var edited = try Document.parse(allocator, src);
    defer edited.deinit();
    const added = try edited.createMapping();
    try edited.mappingAppend(added, try edited.createScalar("n", .plain), try edited.createScalar("1", .plain));
    try edited.pathSet(&.{"fresh"}, added);
    const with_new = try edited.writeOpts(allocator, .{ .indent = 3 });
    defer allocator.free(with_new);
    try testing.expect(std.mem.indexOf(u8, with_new, "fresh:\n   n: 1") != null);
    // ... and the original lines are still exactly as they were.
    try testing.expect(std.mem.indexOf(u8, with_new, "outer:\n      key: v\n      other: w\n") != null);
}

test "emit options carry the depth bound" {
    const allocator = std.testing.allocator;
    var doc = Document.init(allocator);
    defer doc.deinit();
    const root = try doc.createSequence();
    doc.root = root;
    var cur = root;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const next = try doc.createSequence();
        try doc.sequenceAppend(cur, next);
        cur = next;
    }
    try doc.sequenceAppend(cur, try doc.createScalar("leaf", .plain));

    // Well under the default, so this is the bound doing the work.
    try testing.expectError(error.NestingTooDeep, doc.writeOpts(allocator, .{ .max_depth = 8 }));
    const ok = try doc.writeOpts(allocator, .{ .max_depth = 500 });
    defer allocator.free(ok);
    try testing.expect(std.mem.indexOf(u8, ok, "leaf") != null);
}

// ----------------------------------------------------------------------
// Comments: reads and writes (docs/design/comments.md, PLAN-12 B2).
// ----------------------------------------------------------------------

const comment_src =
    \\# service configuration
    \\name: api   # user facing
    \\# stale, replaced below
    \\port: 8080
    \\
    \\# separated from port by a blank line
    \\debug: false
    \\
;

test "comment reads: trailing and leading, raw" {
    var doc = try Document.parse(testing.allocator, comment_src);
    defer doc.deinit();
    const root = doc.root.?;

    // Trailing: raw, from the '#' to before the terminator.
    try testing.expectEqualStrings("# user facing", root.lookup("name").?.trailingComment(&doc).?);
    try testing.expect(root.lookup("port").?.trailingComment(&doc) == null);

    // Leading, read off the (inline) value standing in for the pair: the
    // block directly above. A blank line breaks the attachment.
    try testing.expectEqualStrings("# service configuration", root.lookup("name").?.leadingComments(&doc).?);
    try testing.expectEqualStrings("# stale, replaced below", root.lookup("port").?.leadingComments(&doc).?);
    try testing.expectEqualStrings("# separated from port by a blank line", root.lookup("debug").?.leadingComments(&doc).?);

    // The key reads the same block as its inline value.
    const pairs = root.pairs().?;
    try testing.expectEqualStrings("# service configuration", pairs[0].key.leadingComments(&doc).?);

    // A programmatically built node has no source bytes to read.
    var built = Document.init(testing.allocator);
    defer built.deinit();
    const n = try built.createScalar("x", .plain);
    try testing.expect(n.trailingComment(&built) == null);
    try testing.expect(n.leadingComments(&built) == null);
}

test "comment reads on containers, aliases and block values" {
    const src =
        \\top:
        \\  # about the sequence
        \\  - one   # first
        \\  - &v two
        \\  - *v
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    const top = doc.pathGet(&.{"top"}).?;

    // The block value's own comments are the ones above its first line.
    try testing.expectEqualStrings("# about the sequence", top.leadingComments(&doc).?);
    // A mid-sequence comment is its item's trailing comment.
    try testing.expectEqualStrings("# first", top.items().?[0].trailingComment(&doc).?);
    try testing.expect(top.trailingComment(&doc) == null);
    // Alias occurrences read their own spans.
    try testing.expect(top.items().?[2].trailingComment(&doc) == null);
}

test "comment write: set, change, delete a trailing comment" {
    var doc = try Document.parse(testing.allocator, comment_src);
    defer doc.deinit();
    const port = doc.pathGet(&.{"port"}).?;

    // Add where there was none.
    try doc.setTrailingComment(port, "# the door");
    {
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(
            "# service configuration\nname: api   # user facing\n# stale, replaced below\nport: 8080 # the door\n\n# separated from port by a blank line\ndebug: false\n",
            out,
        );
        // Reads see the written comment without a re-parse.
        try testing.expectEqualStrings("# the door", port.trailingComment(&doc).?);
    }

    // Change: canonical single blank replaces the original spacing.
    try doc.setTrailingComment(port, "# changed");
    {
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "port: 8080 # changed\n") != null);
    }

    // Delete.
    try doc.setTrailingComment(port, null);
    {
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(
            "# service configuration\nname: api   # user facing\n# stale, replaced below\nport: 8080\n\n# separated from port by a blank line\ndebug: false\n",
            out,
        );
    }
}

test "comment write: re-setting the same comment is byte-identical" {
    const src =
        \\# service configuration
        \\name: api   # user facing
        \\port: 8080 # one space here
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();

    // Same text, whatever the original spacing: a no-op, so even the
    // three blanks before the first comment survive untouched.
    try doc.setTrailingComment(doc.pathGet(&.{"name"}).?, "# user facing");
    try testing.expect(doc.pathGet(&.{"name"}).?.modified == false);
    // A different text is a real edit and marks the tree.
    try doc.setTrailingComment(doc.pathGet(&.{"name"}).?, "# renamed");
    try testing.expect(doc.pathGet(&.{"name"}).?.modified == true);

    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "# service configuration\nname: api # renamed\nport: 8080 # one space here\n",
        out,
    );
}

test "comment write: leading blocks set, change and delete whole lines" {
    var doc = try Document.parse(testing.allocator, comment_src);
    defer doc.deinit();
    const port = doc.pathGet(&.{"port"}).?;

    try doc.setLeadingComments(port, "# rate limit\n# in requests/second");
    {
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(
            "# service configuration\nname: api   # user facing\n# rate limit\n# in requests/second\nport: 8080\n\n# separated from port by a blank line\ndebug: false\n",
            out,
        );
        try testing.expectEqualStrings(
            "# rate limit\n# in requests/second",
            port.leadingComments(&doc).?,
        );
    }

    // Delete removes the lines whole; the entry below stays put.
    try doc.setLeadingComments(port, null);
    {
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(
            "# service configuration\nname: api   # user facing\nport: 8080\n\n# separated from port by a blank line\ndebug: false\n",
            out,
        );
    }
}

test "comment write: a comment on a brand-new entry, the motivating case" {
    var doc = try Document.parse(testing.allocator, "name: api\n");
    defer doc.deinit();
    try doc.pathSet(&.{"port"}, try doc.createScalar("8080", .plain));

    // The replacement value has no source span; its trailing comment is
    // synthesized at emission time.
    try doc.setTrailingComment(doc.pathGet(&.{"port"}).?, "# user facing");
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("name: api\nport: 8080 # user facing\n", out);

    // Comment round trip: parse(emit(doc)) reads the same comments back.
    var again = try Document.parse(testing.allocator, out);
    defer again.deinit();
    try testing.expectEqualStrings("# user facing", again.pathGet(&.{"port"}).?.trailingComment(&again).?);
}

test "comment write: sibling bytes survive a comment edit" {
    const src =
        \\# head
        \\a: 1  # keep
        \\b: 2
        \\c: [x, y]
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try doc.setLeadingComments(doc.pathGet(&.{"b"}).?, "# new\n# block");
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "# head\na: 1  # keep\n# new\n# block\nb: 2\nc: [x, y]\n",
        out,
    );
}

test "comment write: rejects what it cannot write honestly" {
    var doc = try Document.parse(testing.allocator, "a: 1 # c\nlist:\n  - x\nflow: [1, 2]\n");
    defer doc.deinit();

    // Not a comment / not one line.
    try testing.expectError(error.InvalidSyntax, doc.setTrailingComment(doc.pathGet(&.{"a"}).?, "no hash"));
    try testing.expectError(error.InvalidSyntax, doc.setTrailingComment(doc.pathGet(&.{"a"}).?, "# two\nlines"));
    // Trailing on a block collection: address its last entry instead.
    try testing.expectError(error.InvalidSyntax, doc.setTrailingComment(doc.pathGet(&.{"list"}).?, "# c"));
    // Trailing on the pair's key: the comment lives after the value.
    try testing.expectError(error.InvalidSyntax, doc.setTrailingComment(doc.root.?.pairs().?[0].key, "# c"));
    // Inside a flow collection: not addressable (design, out of scope).
    const flow_item = doc.pathGet(&.{"flow"}).?.items().?[0];
    try testing.expectError(error.InvalidSyntax, doc.setTrailingComment(flow_item, "# c"));
    try testing.expectError(error.InvalidSyntax, doc.setLeadingComments(flow_item, "# c"));
    // Leading text with a non-comment line.
    try testing.expectError(error.InvalidSyntax, doc.setLeadingComments(doc.pathGet(&.{"a"}).?, "# ok\nplain line"));
}

test "comment round trip: every written comment survives write and re-parse" {
    const src =
        \\# doc head
        \\a: 1   # tail of a
        \\b:
        \\  # about b
        \\  - x
        \\  - y  # tail of y
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try doc.setTrailingComment(doc.pathGet(&.{"a"}).?, "# new tail");
    try doc.setLeadingComments(doc.pathGet(&.{"b"}).?, "# rewritten");

    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    var again = try Document.parse(testing.allocator, out);
    defer again.deinit();
    try testing.expectEqualStrings("# new tail", again.pathGet(&.{"a"}).?.trailingComment(&again).?);
    try testing.expectEqualStrings("# rewritten", again.pathGet(&.{"b"}).?.leadingComments(&again).?);
    try testing.expectEqualStrings("# doc head", again.pathGet(&.{"a"}).?.leadingComments(&again).?);
    const items = again.pathGet(&.{"b"}).?.items().?;
    try testing.expectEqualStrings("# tail of y", items[1].trailingComment(&again).?);
}

test "comment write in a CRLF document keeps the convention" {
    const src = "# head\r\na: 1 # one\r\nb: 2\r\n";
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try doc.setTrailingComment(doc.pathGet(&.{"b"}).?, "# two");
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# head\r\na: 1 # one\r\nb: 2 # two\r\n", out);

    // And a written leading block uses the same terminator.
    try doc.setLeadingComments(doc.pathGet(&.{"b"}).?, "# lead");
    const out2 = try doc.write(testing.allocator);
    defer testing.allocator.free(out2);
    try testing.expectEqualStrings("# head\r\na: 1 # one\r\n# lead\r\nb: 2 # two\r\n", out2);
}

test "allocation failures in comment writes leak nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, commentWrite, .{});
}

fn commentWrite(allocator: std.mem.Allocator) !void {
    var doc = try Document.parse(allocator, "# head\na: 1 # tail\nb: 2\n");
    defer doc.deinit();
    try doc.setTrailingComment(doc.pathGet(&.{"a"}).?, "# rewritten");
    try doc.setLeadingComments(doc.pathGet(&.{"b"}).?, "# new\n# block");
    const out = try doc.write(allocator);
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "# rewritten") != null);
}
