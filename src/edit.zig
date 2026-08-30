//! High-level editing API — PLAN-1/PLAN-5.
//!
//! A path query engine and atomic edit operations layered on the
//! document model. Paths use a small, documented grammar (see `Path`):
//!
//!     $.store.book[0].title      map keys and sequence indices
//!     $.items[*].name            wildcard (every item)
//!     $..id                      recursive descent (every depth)
//!     $.servers[?role=edge]      equality filter over mapping items
//!
//! Query results are deterministic: document order, wildcards and
//! recursion yield in encounter order.
//!
//! All edits run through `Editor`. A `batch` applies every edit to a
//! deep clone of the document tree and swaps it in only when the whole
//! batch succeeded — a failure (unknown path, OOM, cycle) leaves the
//! original document byte-identical, including its round-trip spans.

const std = @import("std");
const document_mod = @import("document.zig");

const Document = document_mod.Document;
const Node = document_mod.Node;

pub const Error = error{
    InvalidPath,
    InvalidSyntax,
    UnknownPath,
    NotACollection,
    NotASequence,
    NotAMapping,
    AmbiguousOperation,
    MoveIntoSubtree,
    OutOfMemory,
};

/// One parsed path segment.
pub const Segment = union(enum) {
    /// Map key lookup (also matches sequence item textual keys).
    key: []const u8,
    /// Sequence index.
    index: usize,
    /// Every child, in document order.
    wildcard,
    /// Every descendant matching `inner`, at every depth (recursive
    /// descent, `..name`).
    descend: []const u8,
    /// Every mapping item whose `filter_key` equals `filter_value`.
    filter: struct { key: []const u8, value: []const u8 },
};

/// A parsed path. Parse with `Path.parse` (grammar in the module docs).
/// `$` at the start is optional and denotes the root.
pub const Path = struct {
    segments: []const Segment,

    /// Segment byte length in the source string, for error reporting.
    pub fn parse(alloc: std.mem.Allocator, input: []const u8) Error!Path {
        var segments: std.ArrayList(Segment) = .empty;
        errdefer segments.deinit(alloc);

        var i: usize = 0;
        // Optional root marker.
        if (i < input.len and input[i] == '$') i += 1;

        while (i < input.len) {
            const c = input[i];
            if (c == '.') {
                i += 1;
                if (i < input.len and input[i] == '.') {
                    // Recursive descent: `..name`.
                    i += 1;
                    const start = i;
                    while (i < input.len and input[i] != '.' and input[i] != '[') i += 1;
                    if (i == start) return error.InvalidPath;
                    try segments.append(alloc, .{ .descend = input[start..i] });
                    continue;
                }
                const start = i;
                while (i < input.len and input[i] != '.' and input[i] != '[') i += 1;
                if (i == start) return error.InvalidPath;
                try segments.append(alloc, .{ .key = input[start..i] });
            } else if (c == '[') {
                i += 1;
                if (i >= input.len) return error.InvalidPath;
                if (input[i] == '*') {
                    i += 1;
                    if (i >= input.len or input[i] != ']') return error.InvalidPath;
                    i += 1;
                    try segments.append(alloc, .wildcard);
                } else if (input[i] == '?') {
                    // [?key=value]
                    i += 1;
                    const eq = std.mem.indexOfScalarPos(u8, input, i, '=') orelse return error.InvalidPath;
                    const key = input[i..eq];
                    if (key.len == 0) return error.InvalidPath;
                    const close = std.mem.indexOfScalarPos(u8, input, eq, ']') orelse return error.InvalidPath;
                    const value = input[eq + 1 .. close];
                    if (value.len == 0) return error.InvalidPath;
                    i = close + 1;
                    try segments.append(alloc, .{ .filter = .{ .key = key, .value = value } });
                } else if (std.ascii.isDigit(input[i])) {
                    const start = i;
                    while (i < input.len and std.ascii.isDigit(input[i])) i += 1;
                    if (i >= input.len or input[i] != ']') return error.InvalidPath;
                    const index = std.fmt.parseInt(usize, input[start..i], 10) catch return error.InvalidPath;
                    i += 1;
                    try segments.append(alloc, .{ .index = index });
                } else {
                    return error.InvalidPath;
                }
            } else {
                // Bare leading key (`a.b` without `$` or `.`).
                const start = i;
                while (i < input.len and input[i] != '.' and input[i] != '[') i += 1;
                try segments.append(alloc, .{ .key = input[start..i] });
            }
        }
        return .{ .segments = try segments.toOwnedSlice(alloc) };
    }

    pub fn deinit(self: *Path, alloc: std.mem.Allocator) void {
        alloc.free(self.segments);
    }
};

/// Evaluate `path` against `root`. Results are in document order;
/// aliases are followed (bounded). Caller owns the returned slice.
pub fn resolve(alloc: std.mem.Allocator, root: *Node, path: Path) Error![]*Node {
    var results: std.ArrayList(*Node) = .empty;
    errdefer results.deinit(alloc);
    var current: std.ArrayList(*Node) = .empty;
    defer current.deinit(alloc);
    try current.append(alloc, root);

    for (path.segments) |seg| {
        var next: std.ArrayList(*Node) = .empty;
        errdefer next.deinit(alloc);
        for (current.items) |node| {
            switch (seg) {
                .key => |k| if (node.lookup(k)) |child| try next.append(alloc, child),
                .index => |ix| {
                    const items = node.items() orelse continue;
                    if (ix < items.len) try next.append(alloc, items[ix]);
                },
                .wildcard => {
                    if (node.items()) |items| {
                        for (items) |child| try next.append(alloc, child);
                    } else if (node.pairs()) |pairs| {
                        for (pairs) |p| try next.append(alloc, p.value);
                    }
                },
                .descend => |k| try collectDescend(alloc, node, k, &next),
                .filter => |f| {
                    // Sequences: every item whose mapping carries
                    // key == value. Mappings: every value that does.
                    if (node.items()) |items| {
                        for (items) |item| {
                            if (filterMatches(item, f.key, f.value)) try next.append(alloc, item);
                        }
                    } else if (node.pairs()) |ps| {
                        for (ps) |p| {
                            if (filterMatches(p.value, f.key, f.value)) try next.append(alloc, p.value);
                        }
                    }
                },
            }
        }
        current.deinit(alloc);
        current = next;
    }
    try results.appendSlice(alloc, current.items);
    return results.toOwnedSlice(alloc);
}

fn filterMatches(candidate: *Node, key: []const u8, value: []const u8) bool {
    const m = candidate.resolveAlias();
    const ps = m.pairs() orelse return false;
    for (ps) |p| {
        const kv = p.key.scalarValue() orelse continue;
        if (std.mem.eql(u8, kv, key)) {
            const vv = p.value.scalarValue() orelse return false;
            return std.mem.eql(u8, vv, value);
        }
    }
    return false;
}

fn collectDescend(alloc: std.mem.Allocator, node: *Node, key: []const u8, out: *std.ArrayList(*Node)) Error!void {
    // Depth-bounded pre-order walk collecting every `key` match.
    const cur = node.resolveAlias();
    if (cur.pairs()) |pairs| {
        for (pairs) |p| {
            const kv = p.key.scalarValue() orelse continue;
            if (std.mem.eql(u8, kv, key)) try out.append(alloc, p.value);
        }
        for (pairs) |p| try collectDescend(alloc, p.value, key, out);
    } else if (cur.items()) |items| {
        for (items) |child| try collectDescend(alloc, child, key, out);
    }
}

/// One queued edit. Values are existing nodes (they may be created with
/// `Document.createScalar`/`createMapping`/...); the batch takes no
/// ownership, the document pool does as usual.
pub const Edit = union(enum) {
    /// Set the (single) node at `path`; creates intermediate mappings
    /// for the trailing segments only when every segment is a plain
    /// key (deterministic; anything else is `UnknownPath`).
    set: struct { path: []const u8, value: *Node },
    /// Delete the (single) node at `path`. No match is not an error.
    delete: []const u8,
    /// Insert `value` into the sequence at `path`, before or after the
    /// (single) node at `position`.
    insert: struct { sequence: []const u8, position: []const u8, value: *Node, before: bool },
    /// Append `value` to the sequence at `path`.
    append: struct { sequence: []const u8, value: *Node },
    /// Move the node at `from` into the container at `to` (a mapping
    /// under `key`, or a sequence append).
    move: struct { from: []const u8, to: []const u8, key: ?[]const u8 = null },
};

/// High-level editor over one document. Single operations apply
/// directly; `batch` is atomic (copy-apply-swap).
pub const Editor = struct {
    doc: *Document,

    pub fn init(doc: *Document) Editor {
        return .{ .doc = doc };
    }

    /// Resolve exactly one node, or `error.UnknownPath`.
    pub fn one(self: *Editor, path: []const u8) Error!*Node {
        var p = try Path.parse(self.doc.alloc, path);
        defer p.deinit(self.doc.alloc);
        const root = self.doc.root orelse return error.UnknownPath;
        const found = try resolve(self.doc.alloc, root, p);
        defer self.doc.alloc.free(found);
        if (found.len != 1) return error.UnknownPath;
        return found[0];
    }

    /// Query convenience: every match for `path`.
    pub fn all(self: *Editor, path: []const u8) Error![]*Node {
        var p = try Path.parse(self.doc.alloc, path);
        defer p.deinit(self.doc.alloc);
        const root = self.doc.root orelse return error.UnknownPath;
        return resolve(self.doc.alloc, root, p);
    }

    pub fn set(self: *Editor, path: []const u8, value: *Node) Error!void {
        return self.apply(&.{.{ .set = .{ .path = path, .value = value } }});
    }

    pub fn delete(self: *Editor, path: []const u8) Error!void {
        return self.apply(&.{.{ .delete = path }});
    }

    /// Apply every edit atomically: work happens on a deep clone; the
    /// clone is swapped in only if all edits succeeded.
    pub fn apply(self: *Editor, edits: []const Edit) Error!void {
        const doc = self.doc;
        const old_root = doc.root;
        const new_root = if (old_root) |r| try cloneTree(doc, r) else null;
        doc.root = new_root;
        var ok = false;
        defer if (!ok) {
            doc.root = old_root; // roll back: discard the clone
        };
        for (edits) |edit| try applyOne(doc, edit);
        ok = true;
    }

    fn applyOne(doc: *Document, edit: Edit) Error!void {
        var ed = Editor{ .doc = doc };
        switch (edit) {
            .set => |s| try applySet(doc, s.path, s.value),
            .delete => |path| {
                _ = ed.one(path) catch return; // no match: no-op
                try applyDelete(doc, path);
            },
            .insert => |ins| try applyInsert(doc, ins),
            .append => |app| {
                const seq = try ed.one(app.sequence);
                if (!seq.isSequence()) return error.NotASequence;
                try doc.sequenceAppend(seq, app.value);
            },
            .move => |mv| try applyMove(doc, mv.from, mv.to, mv.key),
        }
    }

    fn applySet(doc: *Document, path: []const u8, value: *Node) Error!void {
        var p = try Path.parse(doc.alloc, path);
        defer p.deinit(doc.alloc);
        if (p.segments.len == 0) {
            doc.root = value;
            return;
        }
        // Only plain-key paths auto-create intermediate mappings.
        for (p.segments) |seg| {
            if (seg != .key) return error.AmbiguousOperation;
        }
        if (doc.root == null) {
            doc.root = try doc.createMapping();
        }
        var cur = doc.root.?;
        for (p.segments[0 .. p.segments.len - 1]) |seg| {
            const k = seg.key;
            if (cur.lookup(k)) |next| {
                cur = next;
            } else {
                const m = try doc.createMapping();
                try doc.mappingAppend(cur, try doc.createScalar(k, .plain), m);
                cur = m;
            }
            if (!cur.isMapping()) return error.NotAMapping;
        }
        const last = p.segments[p.segments.len - 1].key;
        if (cur.lookup(last)) |existing| {
            // Replace in place, keeping order and the key node.
            const pairs = cur.data.mapping.pairs.items;
            for (pairs) |*pair| {
                if (pair.value == existing) {
                    value.parent = cur;
                    pair.value = value;
                    doc.markModified(cur);
                    return;
                }
            }
        }
        try doc.mappingAppend(cur, try doc.createScalar(last, .plain), value);
    }

    fn applyDelete(doc: *Document, path: []const u8) Error!void {
        var p = try Path.parse(doc.alloc, path);
        defer p.deinit(doc.alloc);
        if (p.segments.len == 0) return error.AmbiguousOperation;
        const root = doc.root orelse return;
        var cur = root;
        for (p.segments[0 .. p.segments.len - 1]) |seg| {
            switch (seg) {
                .key => |k| cur = cur.lookup(k) orelse return,
                else => return error.AmbiguousOperation,
            }
        }
        switch (p.segments[p.segments.len - 1]) {
            .key => |k| _ = doc.mappingRemove(cur, k) catch return,
            .index => |ix| _ = doc.sequenceRemove(cur, ix) catch return,
            else => return error.AmbiguousOperation,
        }
    }

    fn applyInsert(doc: *Document, ins: anytype) Error!void {
        var ed = Editor{ .doc = doc };
        const seq = try ed.one(ins.sequence);
        const items = seq.items() orelse return error.NotASequence;
        const anchor = try ed.one(ins.position);
        var index: usize = items.len;
        for (items, 0..) |item, i| {
            if (item == anchor) {
                index = i;
                break;
            }
        }
        if (index == items.len) return error.UnknownPath;
        try doc.sequenceInsert(seq, index + @intFromBool(!ins.before), ins.value);
    }

    fn applyMove(doc: *Document, from: []const u8, to: []const u8, key: ?[]const u8) Error!void {
        var ed = Editor{ .doc = doc };
        const node = try ed.one(from);
        const target = try ed.one(to);
        // Reject moving a node into its own subtree.
        var anc: ?*Node = target;
        while (anc) |a| : (anc = a.parent) {
            if (a == node) return error.MoveIntoSubtree;
        }
        // Detach from the current parent.
        if (node.parent) |parent| {
            switch (parent.data) {
                .mapping => |*m| {
                    for (m.pairs.items, 0..) |p, i| {
                        if (p.value == node) {
                            try self_dropPairSpan(doc, parent, p);
                            _ = m.pairs.orderedRemove(i);
                            parent.modified = true;
                            break;
                        }
                    }
                },
                .sequence => |*sq| {
                    for (sq.items.items, 0..) |item, i| {
                        if (item == node) {
                            try doc.dropItemSpan(parent, node);
                            _ = sq.items.orderedRemove(i);
                            parent.modified = true;
                            break;
                        }
                    }
                },
                else => {},
            }
        }
        node.parent = null;
        switch (target.data) {
            .mapping => {
                const k = key orelse return error.AmbiguousOperation;
                try doc.mappingAppend(target, try doc.createScalar(k, .plain), node);
                // The node's source spans describe its old location.
                clearSpans(node);
            },
            .sequence => {
                try doc.sequenceAppend(target, node);
                clearSpans(node);
            },
            else => return error.NotACollection,
        }
    }

    fn self_dropPairSpan(doc: *Document, parent: *Node, p: document_mod.Pair) !void {
        try doc.dropPairSpan(parent, p);
    }
};

fn clearSpans(node: *Node) void {
    node.src = null;
    // Children keep their spans: they still describe their own bytes,
    // which the emitter only uses when the slot itself is original.
}

/// Deep-clone a subtree into `doc`'s pool, preserving presentation
/// spans (so a rolled-back-to clone still round-trips untouched parts
/// byte-identically) and rebuilding alias targets within the clone.
pub fn cloneTree(doc: *Document, root: *Node) Error!*Node {
    var anchors = std.StringHashMap(*Node).init(doc.alloc);
    defer anchors.deinit();
    return cloneNode(doc, root, &anchors);
}

fn cloneNode(doc: *Document, node: *Node, anchors: *std.StringHashMap(*Node)) Error!*Node {
    const n = try doc.pool.create(Node);
    n.* = .{
        .parent = null,
        .mark = node.mark,
        .anchor = node.anchor,
        .tag = node.tag,
        .src = node.src,
        .modified = node.modified,
        .data = undefined,
    };
    switch (node.data) {
        .scalar => |s| n.data = .{ .scalar = .{ .value = try doc.pool.dupe(s.value), .style = s.style } },
        .alias => |a| {
            const target = anchors.get(a.name) orelse a.target;
            n.data = .{ .alias = .{ .name = try doc.pool.dupe(a.name), .target = target } };
        },
        .mapping => |m| {
            n.data = .{ .mapping = .{ .style = m.style } };
            if (node.anchor) |a| try anchors.put(try doc.pool.dupe(a), n);
            for (m.pairs.items) |p| {
                const k = try cloneNode(doc, p.key, anchors);
                const v = try cloneNode(doc, p.value, anchors);
                try doc.attachPair(n, k, v);
                // Preserve the pair's original extent.
                if (n.data == .mapping) {
                    const pairs = n.data.mapping.pairs.items;
                    if (pairs.len > 0) pairs[pairs.len - 1].src_end = p.src_end;
                }
            }
            for (m.dropped.items) |d| {
                try n.data.mapping.dropped.append(doc.pool.allocator(), d);
            }
        },
        .sequence => |sq| {
            n.data = .{ .sequence = .{ .style = sq.style } };
            if (node.anchor) |a| try anchors.put(try doc.pool.dupe(a), n);
            for (sq.items.items) |item| {
                const child = try cloneNode(doc, item, anchors);
                try doc.attachItem(n, child);
            }
            for (sq.dropped.items) |d| {
                try n.data.sequence.dropped.append(doc.pool.allocator(), d);
            }
        },
    }
    return n;
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

test "path grammar and queries" {
    var doc = try Document.parse(testing.allocator,
        \\store:
        \\  book:
        \\    - title: t1
        \\      role: edge
        \\    - title: t2
        \\id: root-id
        \\inner:
        \\  id: deep-id
        \\
    );
    defer doc.deinit();
    var ed = Editor.init(&doc);

    {
        const r = try ed.all("$.store.book[0].title");
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(usize, 1), r.len);
        try testing.expectEqualStrings("t1", r[0].scalarValue().?);
    }
    {
        const r = try ed.all("$.store.book[*].title");
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(usize, 2), r.len);
        try testing.expectEqualStrings("t2", r[1].scalarValue().?);
    }
    {
        const r = try ed.all("$..id");
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(usize, 2), r.len);
        try testing.expectEqualStrings("root-id", r[0].scalarValue().?);
    }
    {
        const r = try ed.all("$.store.book[?role=edge]");
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(usize, 1), r.len);
        try testing.expectEqualStrings("t1", r[0].lookup("title").?.scalarValue().?);
    }
    // Bare key without `$` and invalid grammar.
    {
        const r = try ed.all("store");
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(usize, 1), r.len);
    }
    try testing.expectError(error.InvalidPath, ed.all("$.store["));
    try testing.expectError(error.InvalidPath, ed.all("$.."));
    try testing.expectError(error.UnknownPath, ed.one("$.nope"));
}

test "set creates intermediates and replaces in place" {
    var doc = try Document.parse(testing.allocator, "a: 1\nb: 2\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);

    try ed.set("$.a", try doc.createScalar("100", .plain));
    try testing.expectEqualStrings("100", doc.pathGet(&.{"a"}).?.scalarValue().?);

    try ed.set("$.x.y.z", try doc.createScalar("deep", .plain));
    try testing.expectEqualStrings("deep", doc.pathGet(&.{ "x", "y", "z" }).?.scalarValue().?);

    // Untouched sibling bytes survive.
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: 100\nb: 2\nx:\n  y:\n    z: deep\n", out);
}

test "insert, append and delete sequence items" {
    var doc = try Document.parse(testing.allocator, "items:\n  - a\n  - c\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);

    try ed.apply(&.{.{ .append = .{ .sequence = "$.items", .value = try doc.createScalar("d", .plain) } }});
    try ed.apply(&.{.{ .insert = .{ .sequence = "$.items", .position = "$.items[1]", .value = try doc.createScalar("b", .plain), .before = true } }});
    try ed.apply(&.{.{ .delete = "$.items[3]" }});

    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("items:\n  - a\n  - b\n  - c\n", out);
}

test "move between containers" {
    var doc = try Document.parse(testing.allocator,
        \\from:
        \\  - keep
        \\  - take me
        \\to: []
        \\
    );
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.apply(&.{.{ .move = .{ .from = "$.from[1]", .to = "$.to" } }});
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    // `to` is an empty flow sequence, so the moved item joins it in
    // flow style.
    try testing.expectEqualStrings("from:\n  - keep\nto: [take me]\n", out);

    // Moving into one's own subtree is rejected.
    try testing.expectError(error.MoveIntoSubtree, ed.apply(&.{.{ .move = .{ .from = "$", .to = "$.from" } }}));
}

test "failed batch leaves the document untouched" {
    const src =
        \\# keep this comment
        \\a: 1
        \\b: 2
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    var ed = Editor.init(&doc);

    // Unknown single-match path.
    try testing.expectError(error.UnknownPath, ed.one("$.missing.x"));
    // Multi-match queries return an empty set, not an error.
    {
        const r = try ed.all("$.missing.x");
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(usize, 0), r.len);
    }
    // A batch whose later edit fails rolls back everything.
    const batch = [_]Edit{
        .{ .set = .{ .path = "$.a", .value = try doc.createScalar("10", .plain) } },
        .{ .set = .{ .path = "$.b[0].x", .value = try doc.createScalar("boom", .plain) } },
    };
    try testing.expectError(error.AmbiguousOperation, ed.apply(&batch));

    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "batch success applies every edit" {
    var doc = try Document.parse(testing.allocator, "a: 1\nb: 2\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.apply(&.{
        .{ .set = .{ .path = "$.a", .value = try doc.createScalar("10", .plain) } },
        .{ .set = .{ .path = "$.c", .value = try doc.createScalar("3", .plain) } },
        .{ .delete = "$.b" },
    });
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: 10\nc: 3\n", out);
}

test "allocation failures in batch leak nothing" {
    var doc = try Document.parse(testing.allocator, "a: 1\nb:\n  - x\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    const edits = [_]Edit{
        .{ .set = .{ .path = "$.a", .value = try doc.createScalar("2", .plain) } },
        .{ .append = .{ .sequence = "$.b", .value = try doc.createScalar("y", .plain) } },
    };
    try ed.apply(&edits);
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: 2\nb:\n  - x\n  - y\n", out);
}
