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

/// Editing failures: `UnknownPath` covers queries that match nothing
/// (or not exactly once, for `one`); the `NotA*` errors describe a
/// value whose shape does not fit the edit; `MoveIntoSubtree` rejects
/// moving a node into its own subtree.
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

/// Payload of `Edit.insert`: splice `value` into `sequence`, before or
/// after the (single) node matching `position`.
pub const Insert = struct { sequence: []const u8, position: []const u8, value: *Node, before: bool };

/// One queued edit. Values are existing nodes (they may be created with
/// `Document.createScalar`/`createMapping`/...); the batch takes no
/// ownership, the document pool does as usual.
pub const Edit = union(enum) {
    /// Set the (single) node at `path`. Intermediate segments walk
    /// mappings (auto-created when missing; plain keys only). The
    /// final segment addresses the entry to set: a mapping key
    /// (replaced in place, or appended when new) or a sequence index
    /// (the item at that position is replaced in place).
    set: struct { path: []const u8, value: *Node },
    /// Delete the (single) node at `path`. No match is not an error.
    delete: []const u8,
    /// Insert `value` into the sequence at `path`, before or after the
    /// (single) node at `position`.
    insert: Insert,
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
                _ = ed.one(path) catch |err| {
                    try noopOrOOM(err);
                    return; // no match: no-op
                };
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

    /// True when every segment is a plain key, the case in which `set`
    /// is allowed to auto-create the intermediate mappings.
    fn allPlainKeys(segs: []const Segment) bool {
        for (segs) |seg| {
            if (seg != .key) return false;
        }
        return true;
    }

    /// Resolve the container a `set` addresses: the node the final
    /// segment indexes into. Plain-key parents auto-create intermediate
    /// mappings when `may_create` (the documented deterministic case);
    /// anything else addresses existing structure only, so it goes
    /// through the general resolver and must match exactly once.
    fn setContainer(doc: *Document, parent: []const Segment, may_create: bool) Error!*Node {
        if (may_create and allPlainKeys(parent)) {
            const keys = try doc.alloc.alloc([]const u8, parent.len);
            defer doc.alloc.free(keys);
            for (parent, 0..) |seg, i| keys[i] = seg.key;
            return doc.mappingWalkOrCreate(keys);
        }
        const root = doc.root orelse return error.UnknownPath;
        const found = try resolve(doc.alloc, root, .{ .segments = parent });
        defer doc.alloc.free(found);
        if (found.len != 1) return error.UnknownPath;
        return found[0];
    }

    fn applySet(doc: *Document, path: []const u8, value: *Node) Error!void {
        var p = try Path.parse(doc.alloc, path);
        defer p.deinit(doc.alloc);
        if (p.segments.len == 0) {
            doc.root = value;
            return;
        }
        const parent = p.segments[0 .. p.segments.len - 1];
        switch (p.segments[p.segments.len - 1]) {
            // A final key names a mapping entry: replaced in place when
            // it exists, appended when it does not.
            .key => |last| {
                const cur = try setContainer(doc, parent, true);
                if (!cur.isMapping()) return error.NotAMapping;
                if (cur.lookup(last)) |existing| {
                    // `lookup` only matches values of the mapping `cur`,
                    // so the in-place replace must succeed; falling
                    // through would append a duplicate key.
                    if (!doc.mappingReplace(cur, existing, value)) return error.InvalidSyntax;
                    return;
                }
                try doc.mappingAppend(cur, try doc.createScalar(last, .plain), value);
            },
            // A final index names an existing sequence slot; there is
            // nothing sensible to auto-create at a position.
            .index => |ix| {
                const cur = try setContainer(doc, parent, false);
                if (!cur.isSequence()) return error.NotASequence;
                // Tombstone the old item's line, drop it, and splice the
                // replacement in at the same position: untouched
                // siblings re-emit verbatim, the new item normalizes at
                // the sibling indentation.
                _ = (try doc.sequenceRemove(cur, ix)) orelse return error.UnknownPath;
                try doc.sequenceInsert(cur, ix, value);
            },
            // Wildcards, filters and recursive descent can match any
            // number of nodes: not a single deterministic target.
            else => return error.AmbiguousOperation,
        }
    }

    fn applyDelete(doc: *Document, path: []const u8) Error!void {
        var p = try Path.parse(doc.alloc, path);
        defer p.deinit(doc.alloc);
        if (p.segments.len == 0) return error.AmbiguousOperation;
        const root = doc.root orelse return;
        var cur = root;
        // Keys and indices both step to exactly one node, so either can
        // address the parent. Wildcards, filters and recursive descent
        // can match many: not a single deterministic target.
        for (p.segments[0 .. p.segments.len - 1]) |seg| {
            switch (seg) {
                .key => |k| cur = cur.lookup(k) orelse return,
                .index => |ix| {
                    const items = cur.items() orelse return;
                    if (ix >= items.len) return;
                    cur = items[ix];
                },
                else => return error.AmbiguousOperation,
            }
        }
        switch (p.segments[p.segments.len - 1]) {
            .key => |k| _ = doc.mappingRemove(cur, k) catch |err| try noopOrOOM(err),
            .index => |ix| _ = doc.sequenceRemove(cur, ix) catch |err| try noopOrOOM(err),
            else => return error.AmbiguousOperation,
        }
    }

    /// A delete that matches nothing is a no-op (documented `Edit`
    /// semantics); OOM must propagate so an atomic batch rolls back
    /// instead of silently "succeeding".
    fn noopOrOOM(err: anyerror) Error!void {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => {},
        };
    }

    fn applyInsert(doc: *Document, ins: Insert) Error!void {
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
                            try doc.dropPairSpan(parent, p);
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
    // `b` is a scalar, so `$.b[0]` resolves to nothing.
    try testing.expectError(error.UnknownPath, ed.apply(&batch));

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

test "set and append batch" {
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

test "deleting a missing path is a no-op" {
    var doc = try Document.parse(testing.allocator, "a: 1\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.apply(&.{.{ .delete = "$.missing" }});
    try ed.apply(&.{.{ .delete = "$.a.deep" }}); // scalar in the middle
    try ed.apply(&.{.{ .delete = "$.a[0]" }}); // index into a scalar
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: 1\n", out);
}

test "deleting a nested first child keeps the surviving siblings' indentation" {
    // The bytes between a key's colon and its block value's first entry
    // carry that entry's indentation. Deleting the first child must not
    // leave those bytes behind for the new first child to indent on top
    // of (they would double: 2 -> 4).
    const cases = [_]struct { src: []const u8, path: []const u8, want: []const u8 }{
        .{ .src = "top:\n  a: 1\n  b: 2\n", .path = "$.top.a", .want = "top:\n  b: 2\n" },
        .{ .src = "top:\n    a: 1\n    b: 2\n", .path = "$.top.a", .want = "top:\n    b: 2\n" },
        .{ .src = "top:\n  mid:\n    a: 1\n    b: 2\n", .path = "$.top.mid.a", .want = "top:\n  mid:\n    b: 2\n" },
        .{ .src = "top:\n  a: 1\n  b: 2\n  c: 3\n", .path = "$.top.a", .want = "top:\n  b: 2\n  c: 3\n" },
        .{ .src = "top:\n  - a\n  - b\n", .path = "$.top[0]", .want = "top:\n  - b\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.delete(c.path);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
    }
}

test "editing a sequence item's last key adds no blank line" {
    // A modified item's container walk already consumes the line
    // terminator; writing the line remainder on top of it appended a
    // blank line after every list-of-mappings entry that was edited.
    const src =
        \\list:
        \\  - name: a
        \\    port: 1
        \\  - name: b
        \\    port: 2
        \\after: 3
        \\
    ;
    const cases = [_]struct { path: []const u8, want: []const u8 }{
        .{ .path = "$.list[0].port", .want = "list:\n  - name: a\n    port: Z\n  - name: b\n    port: 2\nafter: 3\n" },
        .{ .path = "$.list[1].port", .want = "list:\n  - name: a\n    port: 1\n  - name: b\n    port: Z\nafter: 3\n" },
        .{ .path = "$.list[0].name", .want = "list:\n  - name: Z\n    port: 1\n  - name: b\n    port: 2\nafter: 3\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.set(c.path, try doc.createScalar("Z", .plain));
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
    }
}

test "replacing the first entry of a block collection keeps the layout" {
    // The replacement is a brand-new node, so the emitter owns its
    // layout: it must supply the indentation the deleted entry's
    // tombstone took with it, and the line break the tombstone
    // swallowed along with the original terminator.
    const cases = [_]struct { src: []const u8, path: []const u8, want: []const u8 }{
        .{ .src = "items:\n  - a\n  - b\n  - c\n", .path = "$.items[0]", .want = "items:\n  - Z\n  - b\n  - c\n" },
        .{ .src = "items:\n  - a\n  - b\n", .path = "$.items[1]", .want = "items:\n  - a\n  - Z\n" },
        .{ .src = "list:\n  - name: a\n    port: 1\n  - name: b\n", .path = "$.list[0]", .want = "list:\n  - Z\n  - name: b\n" },
        .{ .src = "top:\n  a: 1\n  b: 2\n", .path = "$.top.a", .want = "top:\n  a: Z\n  b: 2\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.set(c.path, try doc.createScalar("Z", .plain));
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
    }
}

test "editing inside a flow collection keeps the entry's key intact" {
    // Flow entries share their line with the parent's `key:`, so the
    // line-range tombstones that let block emission skip a removed entry
    // would swallow the `key: ` bytes as well.
    const src = "numbers:\n  ints: [0, -1, 42]\n  flow: {a: 1, b: 2}\n";
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.set("$.numbers.ints[0]", try doc.createScalar("Z", .plain));
    try ed.delete("$.numbers.flow.a");
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("numbers:\n  ints: [Z, -1, 42]\n  flow: {b: 2}\n", out);
    // The result must still be valid YAML.
    var re = try Document.parse(testing.allocator, out);
    re.deinit();
}

test "deleting a sequence item's first key keeps the item indicator" {
    // The `- ` indicator lives in the first entry's leading bytes but
    // belongs to the sequence ITEM: deleting that entry used to take the
    // indicator with it and emit structurally invalid YAML.
    const src =
        \\steps:
        \\  - name: Checkout
        \\    uses: actions/checkout@v4
        \\  - name: Build
        \\    run: make
        \\
    ;
    const cases = [_]struct { path: []const u8, want: []const u8 }{
        .{
            .path = "$.steps[0].name",
            .want = "steps:\n  - uses: actions/checkout@v4\n  - name: Build\n    run: make\n",
        },
        .{
            .path = "$.steps[1].name",
            .want = "steps:\n  - name: Checkout\n    uses: actions/checkout@v4\n  - run: make\n",
        },
        .{
            .path = "$.steps[0].uses",
            .want = "steps:\n  - name: Checkout\n  - name: Build\n    run: make\n",
        },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.delete(c.path);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
        // Structurally valid, not merely textually plausible.
        var re = try Document.parse(testing.allocator, out);
        re.deinit();
    }
}

test "a comment between entries survives a first-key delete" {
    // Re-anchoring the successor onto the indicator line consumes the
    // blanks between them. A comment cannot be moved, so the successor
    // stays put and the indicator keeps a line of its own — the item
    // must not dissolve into its predecessor.
    const src = "steps:\n  - name: Checkout\n    # keep me\n    uses: x\n  - name: Build\n";
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.delete("$.steps[0].name");
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("steps:\n  -\n    # keep me\n    uses: x\n  - name: Build\n", out);
    // Still two items, and the survivor still belongs to the first.
    var re = try Document.parse(testing.allocator, out);
    defer re.deinit();
    try testing.expectEqual(@as(usize, 2), re.pathGet(&.{"steps"}).?.items().?.len);
    var re_ed = Editor.init(&re);
    _ = try re_ed.one("$.steps[0].uses");
    try testing.expectError(error.UnknownPath, re_ed.one("$.steps[0].name"));
}

test "appending keeps the previous entry's trailing comment attached" {
    // The appended entry used to slot in ahead of the unwritten line
    // remainder, so the comment ended up on the NEW line and the entry
    // it documented lost it.
    var doc = try Document.parse(testing.allocator, "cfg:\n  key: value # trailing comment\n");
    defer doc.deinit();
    const cfg = doc.pathGet(&.{"cfg"}).?;
    try doc.mappingAppend(cfg, try doc.createScalar("added", .plain), try doc.createScalar("1", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("cfg:\n  key: value # trailing comment\n  added: 1\n", out);
}

test "replacing an item of a nested sequence keeps the outer indicator" {
    // `- - a` puts the OUTER item's indicator on the inner item's line;
    // it outlives the inner item and the replacement must sit under it.
    var doc = try Document.parse(testing.allocator, "list:\n  - - nested\n    - sequence\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.set("$.list[0][0]", try doc.createScalar("Z", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("list:\n  - - Z\n    - sequence\n", out);
    // The structure must survive, not merely the bytes.
    var re = try Document.parse(testing.allocator, out);
    defer re.deinit();
    var re_ed = Editor.init(&re);
    _ = try re_ed.one("$.list[0][1]");
}

test "replacing a collection's only entry keeps the sibling column" {
    // With no original entry left to copy the column from, the entry
    // column fell back to the container's own column PLUS one indent
    // step — but that column already is where the entries sit, so the
    // replacement landed one level too deep.
    const cases = [_]struct { src: []const u8, path: []const u8, want: []const u8 }{
        .{ .src = "secrets:\n  - db-password\n", .path = "$.secrets[0]", .want = "secrets:\n  - Z\n" },
        .{ .src = "secrets:\n    - db-password\n", .path = "$.secrets[0]", .want = "secrets:\n    - Z\n" },
        .{ .src = "top:\n  only: 1\n", .path = "$.top.only", .want = "top:\n  only: Z\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.set(c.path, try doc.createScalar("Z", .plain));
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
    }
}

test "allocation failures in a delete batch propagate and leak nothing" {
    try std.testing.checkAllAllocationFailures(testing.allocator, deleteBatch, .{});
}

test "set replaces a sequence item in place" {
    var doc = try Document.parse(testing.allocator, "items:\n  - a\n  - b\n  - c\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.set("$.items[1]", try doc.createScalar("B", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("items:\n  - a\n  - B\n  - c\n", out);
    try testing.expectError(error.UnknownPath, ed.set("$.items[9]", try doc.createScalar("x", .plain)));
    try testing.expectError(error.NotAMapping, ed.set("$.items.a", try doc.createScalar("x", .plain)));
}

test "set addresses through sequence indices in mid-path" {
    var doc = try Document.parse(testing.allocator,
        \\list:
        \\  - name: a
        \\    port: 1
        \\  - name: b
        \\    port: 2
        \\
    );
    defer doc.deinit();
    var ed = Editor.init(&doc);
    // Index in the middle, key final.
    try ed.set("$.list[1].port", try doc.createScalar("9", .plain));
    // Index final, replacing a whole item.
    try ed.set("$.list[0]", try doc.createScalar("gone", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("list:\n  - gone\n  - name: b\n    port: 9\n", out);
    // A path that cannot resolve to exactly one node is not a set target.
    try testing.expectError(error.UnknownPath, ed.set("$.list[9].port", try doc.createScalar("x", .plain)));
    try testing.expectError(error.AmbiguousOperation, ed.set("$.list[*]", try doc.createScalar("x", .plain)));
}

test "allocation failures in a set+append batch leak nothing" {
    try std.testing.checkAllAllocationFailures(testing.allocator, setAppendBatch, .{});
}

fn setAppendBatch(alloc: std.mem.Allocator) !void {
    var doc = try Document.parse(alloc, "a: 1\nb:\n  - x\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    const edits = [_]Edit{
        .{ .set = .{ .path = "$.a", .value = try doc.createScalar("2", .plain) } },
        .{ .append = .{ .sequence = "$.b", .value = try doc.createScalar("y", .plain) } },
    };
    try ed.apply(&edits);
    const out = try doc.write(alloc);
    defer alloc.free(out);
    try testing.expectEqualStrings("a: 2\nb:\n  - x\n  - y\n", out);
}

fn deleteBatch(alloc: std.mem.Allocator) !void {
    var doc = try Document.parse(alloc, "a: 1\nb: 2\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.apply(&.{.{ .delete = "$.b" }});
    const out = try doc.write(alloc);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("a: 1\n", out);
}

test "emptying a collection keeps the value's placement under its key" {
    // Removing a container's LAST entry leaves `{}` / `[]` behind. The
    // bytes between the key's colon and the (now departed) first entry
    // are what place that value under its key. They must survive: a
    // surviving sibling would arrive carrying its own indentation, but
    // an emptied container has no successor to carry any, so letting
    // the deleted entry's tombstone eat those bytes drops the `{}` at
    // column 0 -- where it is no longer the value of anything, and the
    // document no longer parses at all.
    const cases = [_]struct { src: []const u8, path: []const u8, want: []const u8 }{
        .{ .src = "src:\n  item: 1\ndest: 2\n", .path = "$.src.item", .want = "src:\n  {}\ndest: 2\n" },
        .{ .src = "src:\n  - only\ndest: 2\n", .path = "$.src[0]", .want = "src:\n  []\ndest: 2\n" },
        // Four-space file: the placement is whatever the author wrote.
        .{ .src = "a:\n    only: 1\nb: 2\n", .path = "$.a.only", .want = "a:\n    {}\nb: 2\n" },
        // Nested, with a surviving sibling in the grandparent.
        .{ .src = "top:\n  mid:\n    only: 1\n  after: 2\n", .path = "$.top.mid.only", .want = "top:\n  mid:\n    {}\n  after: 2\n" },
        // A comment on the key's line is not part of the placement.
        .{ .src = "a: # why\n  only: 1\nb: 2\n", .path = "$.a.only", .want = "a: # why\n  {}\nb: 2\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.delete(c.path);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
        // The invariant that matters more than the exact bytes: the
        // emitter must never produce something we cannot read back.
        var again = try Document.parse(testing.allocator, out);
        defer again.deinit();
    }
}

test "moving out a collection's last entry keeps the source's placement" {
    // Same defect reached through `move` rather than `delete` -- the
    // detach side is shared, so both paths have to be held.
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{
            .src = "src:\n  item:\n    a: 1\ndest:\n  keep: y\n",
            .want = "src:\n  {}\ndest:\n  keep: y\n  moved:\n    a: 1\n",
        },
        // Deliberately 2-space only. A 4-space fixture here would also
        // measure the indentation the emitter gives the MOVED subtree's
        // own children, which is a separate concern (indent_step) with
        // its own test; a fixture that trips two things cannot tell you
        // which one broke. Source-side placement at other widths is
        // covered by the delete cases above.
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.apply(&.{.{ .move = .{ .from = "$.src.item", .to = "$.dest", .key = "moved" } }});
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
        var again = try Document.parse(testing.allocator, out);
        defer again.deinit();
    }
}

test "emptying a sequence item keeps the item and its indicator" {
    // The `- ` indicator lives in the first entry's leading bytes but
    // belongs to the ITEM, which survives its last key as `- {}`. Two
    // things used to go wrong together here, and only one of them was
    // visible: the tombstone ate the indicator (deleting a sequence
    // entry nobody asked to delete), and the `{}` was then left at the
    // parent key's own column, where a FLOW node reads as the key's
    // sibling rather than its value and the document stops parsing.
    //
    // The zero-indent style below -- `- ` items at their parent key's
    // column -- is the Kubernetes and mkdocs house style, so this is
    // not an exotic shape.
    const cases = [_]struct { src: []const u8, path: []const u8, want: []const u8 }{
        .{
            .src = "spec:\n  ports:\n  - containerPort: 80\n  other: 1\n",
            .path = "$.spec.ports[0].containerPort",
            .want = "spec:\n  ports:\n  - {}\n  other: 1\n",
        },
        .{
            .src = "ports:\n- containerPort: 80\nother: 1\n",
            .path = "$.ports[0].containerPort",
            .want = "ports:\n- {}\nother: 1\n",
        },
        // Conventionally indented. This one always PARSED; it was
        // silently dropping the item, which no re-parse check can see.
        .{
            .src = "spec:\n  ports:\n    - containerPort: 80\n  other: 1\n",
            .path = "$.spec.ports[0].containerPort",
            .want = "spec:\n  ports:\n    - {}\n  other: 1\n",
        },
        .{
            .src = "nav:\n  - Home: index.md\n  - About: about.md\n",
            .path = "$.nav[0].Home",
            .want = "nav:\n  - {}\n  - About: about.md\n",
        },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.delete(c.path);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);

        // The weak invariant that actually caught this: the output must
        // parse. Note the third case parsed BEFORE the fix too, while
        // silently dropping the item -- which is why the expected bytes
        // above matter as much as the re-parse.
        var again = try Document.parse(testing.allocator, out);
        defer again.deinit();
    }
}

test "emptying a zero-indent sequence value indents its placeholder" {
    // Deleting the sole ITEM (rather than the item's sole key) empties
    // the sequence itself. Same column hazard: `[]` at the key's own
    // column is the key's sibling, not its value.
    const cases = [_]struct { src: []const u8, path: []const u8, want: []const u8 }{
        .{
            .src = "spec:\n  containers:\n  - name: nginx\n  other: 1\n",
            .path = "$.spec.containers[0]",
            .want = "spec:\n  containers:\n    []\n  other: 1\n",
        },
        .{
            .src = "items:\n- only\nafter: 1\n",
            .path = "$.items[0]",
            .want = "items:\n  []\nafter: 1\n",
        },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.delete(c.path);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
        var again = try Document.parse(testing.allocator, out);
        defer again.deinit();
    }
}

// ----------------------------------------------------------------------
// Block layout for subtrees the emitter owns (new and moved).
//
// A container with no source span has no layout to preserve, so the
// emitter picks one. It used to pick single-line flow, which is valid
// YAML but alien to a block-styled file -- and inconsistent, since a
// brand-new *pair* already went through the block path. These pin the
// consistent behaviour: block in, block out.
// ----------------------------------------------------------------------

/// A fresh two-key mapping, the stand-in for "a subtree the caller built".
fn twoKeyMapping(doc: *Document) !*Node {
    const m = try doc.createMapping();
    try doc.mappingAppend(m, try doc.createScalar("host", .plain), try doc.createScalar("h", .plain));
    try doc.mappingAppend(m, try doc.createScalar("port", .plain), try doc.createScalar("80", .plain));
    return m;
}

test "a new collection replacing a value emits block, not flow" {
    const cases = [_]struct { src: []const u8, path: []const u8, want: []const u8 }{
        // Replacing a scalar at the root.
        .{
            .src = "server: old\nother: 1\n",
            .path = "$.server",
            .want = "server:\n  host: h\n  port: 80\nother: 1\n",
        },
        // Nested one level: the new subtree indents from its own key.
        .{
            .src = "a:\n  server: old\n  other: 1\n",
            .path = "$.a.server",
            .want = "a:\n  server:\n    host: h\n    port: 80\n  other: 1\n",
        },
        // Comments on neighbouring lines are untouched.
        .{
            .src = "# lead\nserver: old\n# trail\nother: 1\n",
            .path = "$.server",
            .want = "# lead\nserver:\n  host: h\n  port: 80\n# trail\nother: 1\n",
        },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.set(c.path, try twoKeyMapping(&doc));
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
    }
}

test "a replaced value's trailing comment rides the last emitted line" {
    // Documented consequence, not a target: the original line remainder
    // is written after the new value, so a comment that annotated a
    // one-line scalar ends up annotating the block's final line. Pinned
    // so that changing it is a decision rather than an accident.
    var doc = try Document.parse(testing.allocator, "server: old # keep me\nother: 1\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.set("$.server", try twoKeyMapping(&doc));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("server:\n  host: h\n  port: 80 # keep me\nother: 1\n", out);
}

test "a new collection appended to a block sequence emits block" {
    var doc = try Document.parse(testing.allocator, "list:\n  - name: a\n  - name: b\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    const m = try doc.createMapping();
    try doc.mappingAppend(m, try doc.createScalar("name", .plain), try doc.createScalar("c", .plain));
    try doc.mappingAppend(m, try doc.createScalar("port", .plain), try doc.createScalar("9", .plain));
    try ed.apply(&.{.{ .append = .{ .sequence = "$.list", .value = m } }});
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("list:\n  - name: a\n  - name: b\n  - name: c\n    port: 9\n", out);
}

test "a moved subtree emits block at its destination" {
    // `move` clears the node's span (it describes the OLD location), so
    // the destination slot is emitter-owned and takes the same path as
    // a brand-new subtree. Untouched siblings stay verbatim.
    // NOTE on fixture shape: `keep` deliberately comes BEFORE `item`, so
    // the moved node is not its container's FIRST entry. Moving out a
    // first entry additionally exercises the source-side indentation of
    // the surviving sibling, which is a separate concern from where the
    // node lands. Keep those apart -- a fixture that trips both cannot
    // tell you which one broke.
    {
        // Into a block mapping.
        var doc = try Document.parse(testing.allocator, "src:\n  keep: k\n  item:\n    a: 1\n    b: 2\ndest:\n  have: h\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.apply(&.{.{ .move = .{ .from = "$.src.item", .to = "$.dest", .key = "moved" } }});
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("src:\n  keep: k\ndest:\n  have: h\n  moved:\n    a: 1\n    b: 2\n", out);
    }
    {
        // Into a block sequence.
        var doc = try Document.parse(testing.allocator, "src:\n  keep: k\n  item:\n    a: 1\n    b: 2\ndest:\n  - first\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.apply(&.{.{ .move = .{ .from = "$.src.item", .to = "$.dest" } }});
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("src:\n  keep: k\ndest:\n  - first\n  - a: 1\n    b: 2\n", out);
    }
}

test "emitter-owned subtrees still re-parse to the values they were given" {
    // The layout is the emitter's choice, but the meaning is not: every
    // shape above must survive a round trip through the parser.
    const srcs = [_][]const u8{
        "server: old\nother: 1\n",
        "a:\n  server: old\n  other: 1\n",
        "server: old # keep me\nother: 1\n",
    };
    const paths = [_][]const u8{ "$.server", "$.a.server", "$.server" };
    for (srcs, paths) |src, path| {
        var doc = try Document.parse(testing.allocator, src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.set(path, try twoKeyMapping(&doc));
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);

        var again = try Document.parse(testing.allocator, out);
        defer again.deinit();
        var ed2 = Editor.init(&again);
        const moved = try ed2.one(path);
        try testing.expectEqualStrings("h", moved.lookup("host").?.scalarValue().?);
        try testing.expectEqualStrings("80", moved.lookup("port").?.scalarValue().?);
    }
}
