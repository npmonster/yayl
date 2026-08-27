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

/// The three YAML node shapes.
pub const NodeType = enum { scalar, mapping, sequence };

/// One mapping entry; both nodes are pool-owned.
pub const Pair = struct {
    key: *Node,
    value: *Node,
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
};

/// Sequence payload; items are pool-owned nodes.
pub const Sequence = struct {
    items: std.ArrayList(*Node) = .empty,
    style: CollectionStyle = .block,
};

/// One YAML node: tagged union over the three shapes plus shared
/// metadata. Pool-owned by the containing document; `parent` is a
/// borrowed back-pointer.
pub const Node = struct {
    parent: ?*Node = null,
    mark: Mark = .{},
    anchor: ?[]const u8 = null,
    /// Fully resolved tag URI (e.g. `tag:yaml.org,2002:int`), or null.
    tag: ?[]const u8 = null,
    data: Data = .{ .scalar = .{} },

    pub const Data = union(NodeType) {
        scalar: Scalar,
        mapping: Mapping,
        sequence: Sequence,
    };

    pub fn nodeType(self: *const Node) NodeType {
        return std.meta.activeTag(self.data);
    }

    pub fn isScalar(self: *const Node) bool {
        return self.nodeType() == .scalar;
    }
    pub fn isMapping(self: *const Node) bool {
        return self.nodeType() == .mapping;
    }
    pub fn isSequence(self: *const Node) bool {
        return self.nodeType() == .sequence;
    }

    /// Scalar value or null for collections.
    pub fn scalarValue(self: *const Node) ?[]const u8 {
        return switch (self.data) {
            .scalar => |s| s.value,
            else => null,
        };
    }

    /// Mapping pairs or null.
    pub fn pairs(self: *const Node) ?[]const Pair {
        return switch (self.data) {
            .mapping => |m| m.pairs.items,
            else => null,
        };
    }

    /// Sequence items or null.
    pub fn items(self: *const Node) ?[]const *Node {
        return switch (self.data) {
            .sequence => |s| s.items.items,
            else => null,
        };
    }

    /// Look up a mapping entry by scalar key text.
    pub fn lookup(self: *const Node, key: []const u8) ?*Node {
        const ps = self.pairs() orelse return null;
        for (ps) |p| {
            if (std.mem.eql(u8, p.key.scalarValue() orelse continue, key)) return p.value;
        }
        return null;
    }

    /// Resolve a node by a path of mapping keys, e.g. `&.{ "a", "b" }`.
    pub fn byPath(self: *const Node, path: []const []const u8) ?*Node {
        var cur: *const Node = self;
        for (path) |seg| {
            cur = cur.lookup(seg) orelse return null;
        }
        return @constCast(cur);
    }
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
        var docs = try parseStream(allocator, &p, 1);
        defer docs.deinit(allocator);
        if (docs.items.len == 0) return Document.init(allocator);
        return docs.items[0];
    }

    /// Parse every document in `input`.
    pub fn parseAll(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(Document) {
        var p = try Parser.init(allocator, null, input);
        defer p.deinit();
        return parseStream(allocator, &p, null);
    }

    fn parseStream(allocator: std.mem.Allocator, p: *Parser, limit: ?usize) !std.ArrayList(Document) {
        var docs: std.ArrayList(Document) = .empty;
        var doc: ?Document = null;
        var builder: ?Builder = null;
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
                    // Hand ownership over only once the append succeeds;
                    // on failure the errdefer still sees `doc` and frees it.
                    try docs.append(allocator, d);
                    doc = null;
                    if (limit) |l| if (docs.items.len >= l) break;
                },
                .stream_start, .stream_end => {},
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
            },
            else => return error.InvalidSyntax,
        }
    }

    /// Remove the mapping entry with scalar key `key`; returns the removed
    /// value node or null when no such key exists.
    pub fn mappingRemove(self: *Document, map: *Node, key: []const u8) !?*Node {
        _ = self;
        switch (map.data) {
            .mapping => |*m| {
                for (m.pairs.items, 0..) |p, i| {
                    if (std.mem.eql(u8, p.key.scalarValue() orelse continue, key)) {
                        const removed = m.pairs.orderedRemove(i);
                        removed.value.parent = null;
                        removed.key.parent = null;
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
        _ = self;
        switch (seq.data) {
            .sequence => |*s| {
                if (index >= s.items.items.len) return null;
                const removed = s.items.orderedRemove(index);
                removed.parent = null;
                return removed;
            },
            else => return error.InvalidSyntax,
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

    /// Render the document back to YAML text (see emitter.zig).
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

/// Builds a node tree out of parser events (fy_docbuilder).
const Builder = struct {
    doc: *Document,
    stack: std.ArrayList(Frame),
    anchors: std.StringHashMap(*Node),

    const Frame = struct {
        node: *Node,
        pending_key: ?*Node = null,
    };

    fn init(doc: *Document) Builder {
        return .{
            .doc = doc,
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

    fn handle(self: *Builder, ev: Event) !void {
        switch (ev.kind) {
            .scalar => {
                const n = try self.doc.pool.create(Node);
                n.* = .{
                    .mark = ev.start,
                    .anchor = try self.dupeOptional(ev.kind.scalar.anchor),
                    .tag = try self.dupeOptional(ev.kind.scalar.tag),
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
                try self.attach(target);
            },
            .sequence_start => try self.startCollection(ev, ev.kind.sequence_start),
            .mapping_start => try self.startCollection(ev, ev.kind.mapping_start),
            .sequence_end => {
                const frame = self.stack.pop().?;
                if (frame.node.nodeType() != .sequence) return error.InvalidSyntax;
            },
            .mapping_end => {
                const frame = self.stack.pop().?;
                if (frame.node.nodeType() != .mapping) return error.InvalidSyntax;
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
        const gop = try self.anchors.getOrPut(a);
        if (gop.found_existing) return error.DuplicateAnchor;
        gop.value_ptr.* = n;
    }

    /// Attach a freshly produced node at the current position.
    fn attach(self: *Builder, n: *Node) !void {
        if (self.stack.items.len == 0) {
            self.doc.root = n;
            return;
        }
        const frame = &self.stack.items[self.stack.items.len - 1];
        switch (frame.node.data) {
            .sequence => try self.doc.sequenceAppend(frame.node, n),
            .mapping => {
                if (frame.pending_key) |key| {
                    try self.doc.mappingAppend(frame.node, key, n);
                    frame.pending_key = null;
                } else {
                    frame.pending_key = n;
                }
            },
            .scalar => return error.InvalidSyntax,
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

test "alias shares node" {
    var doc = try Document.parse(testing.allocator, "- &v 42\n- *v\n");
    defer doc.deinit();
    const seq = doc.root.?;
    try testing.expect(seq.items().?[0] == seq.items().?[1]);
    try testing.expectEqualStrings("42", seq.items().?[0].scalarValue().?);
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
