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
const markup = @import("markup.zig");
const parser_mod = @import("parser.zig");
const pool_mod = @import("pool.zig");
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

/// The four YAML node shapes. Aliases are first-class nodes (fy_node
/// alias semantics): `- *a` occupies its own slot in the tree with its
/// own source span and formatting, pointing at the anchored target.
pub const NodeType = enum { scalar, mapping, sequence, alias };

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

/// Mapping payload. Add entries via `Document.mappingAppend`, which
/// rejects duplicate keys.
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

/// One YAML node: tagged union over the four shapes plus shared
/// metadata. Pool-owned by the containing document; `parent` is a
/// borrowed back-pointer.
pub const Node = struct {
    parent: ?*Node = null,
    mark: Mark = .{},
    anchor: ?[]const u8 = null,
    /// Fully resolved tag URI (e.g. `tag:yaml.org,2002:int`), or null.
    tag: ?[]const u8 = null,
    /// Presentation metadata into `Document.source` (PLAN-4 CST). Null
    /// for programmatically created nodes, which re-emit normalized.
    src: ?markup.Src = null,
    /// True once the node's value or child list was modified after
    /// parsing; its span is no longer trusted for verbatim emission.
    modified: bool = false,
    data: Data = .{ .scalar = .{} },

    pub const Data = union(NodeType) {
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

    pub fn nodeType(self: *const Node) NodeType {
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
        return self.resolveAlias().nodeType() == .scalar;
    }
    pub fn isMapping(self: *const Node) bool {
        return self.resolveAlias().nodeType() == .mapping;
    }
    pub fn isSequence(self: *const Node) bool {
        return self.resolveAlias().nodeType() == .sequence;
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
};

/// The resolved data kind of a plain scalar (fy_node scalar typing).
pub const ScalarKind = enum { null_, bool_, int, float, str };

/// Classify a scalar value the way YAML 1.2 core schema resolves plain
/// scalars. Non-plain styles are always strings.
pub fn scalarKind(value: []const u8, style: ScalarStyle) ScalarKind {
    if (style != .plain) return .str;
    if (value.len == 0 or std.mem.eql(u8, value, "~") or
        std.mem.eql(u8, value, "null") or std.mem.eql(u8, value, "Null") or
        std.mem.eql(u8, value, "NULL")) return .null_;
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "True") or
        std.mem.eql(u8, value, "TRUE") or std.mem.eql(u8, value, "false") or
        std.mem.eql(u8, value, "False") or std.mem.eql(u8, value, "FALSE")) return .bool_;
    if (looksLikeInt(value)) return .int;
    if (looksLikeFloat(value)) return .float;
    return .str;
}

fn looksLikeInt(value: []const u8) bool {
    var s = value;
    if (s.len == 0) return false;
    if (s[0] == '+' or s[0] == '-') s = s[1..];
    if (s.len == 0) return false;
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        if (s.len == 2) return false;
        for (s[2..]) |c| {
            if (ctype.hexValue(c) == null) return false;
        }
        return true;
    }
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'o' or s[1] == 'O')) {
        if (s.len == 2) return false;
        for (s[2..]) |c| {
            if (c < '0' or c > '7') return false;
        }
        return true;
    }
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn looksLikeFloat(value: []const u8) bool {
    if (std.mem.eql(u8, value, ".inf") or std.mem.eql(u8, value, ".Inf") or
        std.mem.eql(u8, value, ".INF") or std.mem.eql(u8, value, "-.inf") or
        std.mem.eql(u8, value, "-.Inf") or std.mem.eql(u8, value, "-.INF") or
        std.mem.eql(u8, value, "+.inf") or std.mem.eql(u8, value, "+.Inf") or
        std.mem.eql(u8, value, "+.INF") or std.mem.eql(u8, value, ".nan") or
        std.mem.eql(u8, value, ".NaN") or std.mem.eql(u8, value, ".NAN")) return true;
    var has_dot = false;
    var has_exp = false;
    var has_digit = false;
    for (value, 0..) |c, i| {
        switch (c) {
            '0'...'9' => has_digit = true,
            '.',
            => has_dot = true,
            'e', 'E' => {
                if (i == 0 or !has_digit) return false;
                has_exp = true;
            },
            '+', '-' => {
                if (i != 0 and value[i - 1] != 'e' and value[i - 1] != 'E') return false;
            },
            else => return false,
        }
    }
    return has_digit and (has_dot or has_exp);
}

/// A parsed YAML document. All nodes live in `pool`; `deinit` releases
/// everything in one go.
pub const Document = struct {
    alloc: std.mem.Allocator,
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
    /// possible (PLAN-4).
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
        return .{ .alloc = allocator, .pool = Pool.init(allocator) };
    }

    pub fn deinit(self: *Document) void {
        self.tag_directives.deinit(self.alloc);
        self.pool.deinit();
        self.* = undefined;
    }

    /// Parse the first document of `input`. Extra documents in the same
    /// stream are ignored; use `parseAll` for multi-document streams.
    pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Document {
        var p = try Parser.init(allocator, null, input);
        defer p.deinit();
        var docs = try parseStream(allocator, &p, 1, input);
        defer docs.deinit(allocator);
        if (docs.items.len == 0) return Document.init(allocator);
        return docs.items[0];
    }

    /// Parse every document in `input`.
    pub fn parseAll(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(Document) {
        var p = try Parser.init(allocator, null, input);
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
            switch (ev.kind) {
                .document_start => {
                    var d = Document.init(allocator);
                    d.version = ev.kind.document_start.version;
                    d.explicit_start = !ev.kind.document_start.implicit;
                    // Copy the stream input into this document's pool so
                    // presentation spans stay valid for the document's
                    // whole lifetime.
                    d.source = try d.pool.dupe(input);
                    d.region_start = cursor;
                    // Copy directive strings into the pool so the document
                    // does not depend on the parser's lifetime. The two
                    // default handles the parser always installs are not
                    // document data and are not re-emitted.
                    for (ev.kind.document_start.tags) |td| {
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
                    d.explicit_end = !ev.kind.document_end.implicit;
                    d.finishRegion(ev.start.offset);
                    // Hand ownership over only once the append succeeds;
                    // on failure the errdefer still sees `doc` and frees it.
                    try docs.append(allocator, d);
                    doc = null;
                    if (docs.items.len > 0) cursor = docs.items[docs.items.len - 1].region_end;
                    if (limit) |l| if (docs.items.len >= l) break;
                },
                .stream_start, .stream_end => {
                    if (ev.kind == .stream_end) {
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

    /// Append a key/value pair to a mapping node, maintaining parent links.
    pub fn mappingAppend(self: *Document, map: *Node, key: *Node, value: *Node) !void {
        try self.attachPair(map, key, value);
        self.markModified(map);
    }

    /// Structural append without the `modified` mark (the builder uses
    /// this while composing a parsed tree).
    pub fn attachPair(self: *Document, map: *Node, key: *Node, value: *Node) !void {
        switch (map.data) {
            .mapping => |*m| {
                try m.pairs.append(self.pool.allocator(), .{ .key = key, .value = value });
                key.parent = map;
                value.parent = map;
            },
            else => return error.InvalidSyntax,
        }
    }

    /// Append an item to a sequence node, maintaining parent links.
    pub fn sequenceAppend(self: *Document, seq: *Node, item: *Node) !void {
        try self.attachItem(seq, item);
        self.markModified(seq);
    }

    /// Structural append without the `modified` mark.
    pub fn attachItem(self: *Document, seq: *Node, item: *Node) !void {
        switch (seq.data) {
            .sequence => |*s| {
                try s.items.append(self.pool.allocator(), item);
                item.parent = seq;
            },
            else => return error.InvalidSyntax,
        }
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
                        self.dropPairSpan(map, p);
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
                const removed = s.items.orderedRemove(index);
                self.dropItemSpan(seq, removed);
                removed.parent = null;
                self.markModified(seq);
                return removed;
            },
            else => return error.InvalidSyntax,
        }
    }

    /// Tombstone the source bytes a mapping entry occupied (its whole
    /// line, including the line terminator).
    pub fn dropPairSpan(self: *Document, map: *Node, p: Pair) void {
        const src = self.source orelse return;
        const ks = p.key.src orelse return;
        if (ks.synthetic) return;
        const from = markup.lineStart(src, ks.entry_start);
        const to = markup.lineEnd(src, p.src_end orelse ks.end);
        if (to > from) {
            switch (map.data) {
                .mapping => |*m| m.dropped.append(self.pool.allocator(), .{ from, to }) catch {},
                else => {},
            }
        }
    }

    /// Tombstone the source bytes a sequence item occupied.
    pub fn dropItemSpan(self: *Document, seq: *Node, item: *Node) void {
        const src = self.source orelse return;
        const is = item.src orelse return;
        if (is.synthetic) return;
        const from = markup.lineStart(src, is.entry_start);
        const to = markup.lineEnd(src, is.end);
        if (to > from) {
            switch (seq.data) {
                .sequence => |*s| s.dropped.append(self.pool.allocator(), .{ from, to }) catch {},
                else => {},
            }
        }
    }

    // ------------------------------------------------------------------
    // High level path API
    // ------------------------------------------------------------------

    /// Look a node up by mapping-key path.
    pub fn pathGet(self: *const Document, path: []const []const u8) ?*Node {
        const r = self.root orelse return null;
        return r.byPath(path);
    }

    /// Set the value at a mapping-key path, creating intermediate mappings
    /// as needed. The final segment is replaced or appended.
    pub fn pathSet(self: *Document, path: []const []const u8, value: *Node) !void {
        if (path.len == 0) return error.InvalidSyntax;
        if (self.root == null) {
            self.root = try self.createMapping();
        }
        var cur = self.root.?;
        for (path[0 .. path.len - 1]) |seg| {
            if (cur.lookup(seg)) |next| {
                cur = next;
            } else {
                const m = try self.createMapping();
                const k = try self.createScalar(seg, .plain);
                try self.mappingAppend(cur, k, m);
                cur = m;
            }
            if (!cur.isMapping()) return error.InvalidSyntax;
        }
        const last = path[path.len - 1];
        const k = try self.createScalar(last, .plain);
        if (cur.lookup(last)) |existing| {
            // Replace the existing entry in place to keep ordering.
            switch (cur.data) {
                .mapping => |*m| {
                    for (m.pairs.items) |*p| {
                        if (p.value == existing) {
                            value.parent = cur;
                            p.value = value;
                            self.markModified(cur);
                            return;
                        }
                    }
                },
                else => unreachable,
            }
        }
        try self.mappingAppend(cur, k, value);
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
        var end = rs.end;
        if (self.explicit_end) {
            end = markup.lineEnd(src, doc_end);
        } else if (end < src.len) {
            if (src[end] == '\r' and end + 1 < src.len and src[end + 1] == '\n') {
                end += 2;
            } else if (src[end] == '\n') {
                end += 1;
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
        const emitter_mod = @import("emitter.zig");
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var em = emitter_mod.Emitter.init(allocator, &out);
        defer em.deinit();
        try em.emitDocument(self);
        return try out.toOwnedSlice(allocator);
    }
};

/// Builds a node tree out of parser events (fy_docbuilder). While
/// building, every node records its source span (see `markup.Src`) so
/// untouched regions re-emit byte-identically (PLAN-4).
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
            .anchors = std.StringHashMap(*Node).init(doc.alloc),
        };
    }

    fn deinit(self: *Builder) void {
        self.stack.deinit(self.doc.alloc);
        self.anchors.deinit();
    }

    fn finish(self: *Builder) void {
        self.deinit();
    }

    /// Presentation span for an event: byte offsets into the document
    /// source, with the entry indicator (`-`/`?`) walked backwards.
    fn spanOf(self: *Builder, ev: Event) markup.Src {
        const synthetic = switch (ev.kind) {
            .scalar => |s| s.synthetic,
            else => false,
        };
        var end = ev.end.offset;
        // The scanner's scalar end marks swallow trailing blanks (and,
        // for block scalars, the final line break). Those bytes are
        // structure, not content: trim them off the span so the gap
        // bytes carry them instead. Quoted scalars end at the closing
        // quote and are unaffected.
        if (ev.kind == .scalar and !synthetic) {
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
        switch (ev.kind) {
            .scalar => {
                const n = try self.doc.pool.create(Node);
                n.* = .{
                    .mark = ev.start,
                    .anchor = try self.dupeOptional(ev.kind.scalar.anchor),
                    .tag = try self.dupeOptional(ev.kind.scalar.tag),
                    .src = self.spanOf(ev),
                    .data = .{ .scalar = .{
                        .value = try self.doc.pool.dupe(ev.kind.scalar.value),
                        .style = ev.kind.scalar.style,
                    } },
                };
                try self.registerAnchor(n.anchor, n);
                try self.attach(n);
            },
            .alias => {
                const target = self.anchors.get(ev.kind.alias) orelse
                    return error.UnknownAlias;
                const n = try self.doc.pool.create(Node);
                n.* = .{
                    .mark = ev.start,
                    .src = self.spanOf(ev),
                    .data = .{ .alias = .{
                        .name = try self.doc.pool.dupe(ev.kind.alias),
                        .target = target,
                    } },
                };
                try self.attach(n);
            },
            .sequence_start => try self.startCollection(ev, ev.kind.sequence_start),
            .mapping_start => try self.startCollection(ev, ev.kind.mapping_start),
            .sequence_end => {
                const frame = self.stack.pop().?;
                if (frame.node.nodeType() != .sequence) return error.InvalidSyntax;
                // Flow collections close with a bracket: their span ends
                // there. Block collections keep the last child's end.
                if (frame.node.data == .sequence and frame.node.data.sequence.style == .flow) {
                    if (frame.node.src) |*s| s.end = ev.end.offset;
                }
                self.finishChild(frame.node);
            },
            .mapping_end => {
                const frame = self.stack.pop().?;
                if (frame.node.nodeType() != .mapping) return error.InvalidSyntax;
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
        const n = if (ev.kind == .sequence_start)
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
        try self.stack.append(self.doc.alloc, .{ .node = n });
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
                try self.doc.attachItem(frame.node, n);
                self.growSpan(frame.node, n.src orelse return);
            },
            .mapping => {
                if (frame.pending_key) |key| {
                    try self.doc.attachPair(frame.node, key, n);
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
    try testing.expectEqual(ScalarKind.null_, scalarKind("~", .plain));
    try testing.expectEqual(ScalarKind.null_, scalarKind("", .plain));
    try testing.expectEqual(ScalarKind.bool_, scalarKind("true", .plain));
    try testing.expectEqual(ScalarKind.int, scalarKind("-42", .plain));
    try testing.expectEqual(ScalarKind.int, scalarKind("0x1F", .plain));
    try testing.expectEqual(ScalarKind.float, scalarKind("1.5e3", .plain));
    try testing.expectEqual(ScalarKind.float, scalarKind(".inf", .plain));
    try testing.expectEqual(ScalarKind.str, scalarKind("true", .single_quoted));
    try testing.expectEqual(ScalarKind.str, scalarKind("0x1F", .double_quoted));
    try testing.expectEqual(ScalarKind.str, scalarKind("hello", .plain));
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
// Round-trip editing tests (PLAN-4): targeted edits keep untouched
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

test "delete entry removes its line but keeps neighbours" {
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

fn editWrite(alloc: std.mem.Allocator) !void {
    var doc = try Document.parse(alloc, "a: 1\nb:\n  - x  # keep\n  - y\n");
    defer doc.deinit();
    try doc.pathSet(&.{"a"}, try doc.createScalar("2", .plain));
    const items = doc.pathGet(&.{"b"}).?;
    try doc.sequenceAppend(items, try doc.createScalar("z", .plain));
    const out = try doc.write(alloc);
    defer alloc.free(out);
}
