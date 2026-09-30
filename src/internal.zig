//! INTERNAL document-model plumbing. Nothing in this file is part of
//! the supported API: the module root (`yaml.zig`) never re-exports it,
//! so downstream consumers cannot reach these functions at all — the
//! decls are `pub` only so `document.zig` and `edit.zig` can call them
//! across a file boundary within this module.
//!
//! These are free functions rather than `Document` methods on purpose:
//! a `pub` method travels with the flattened type, so it would stay
//! reachable through the re-exported `yaml.Document` no matter which
//! namespace re-exports were trimmed.

const std = @import("std");
const ctype = @import("ctype.zig");
const document_mod = @import("document.zig");
const markup = @import("markup.zig");
const utf8 = @import("utf8.zig");

const Document = document_mod.Document;
const Node = document_mod.Node;
const Pair = document_mod.Pair;

// ----------------------------------------------------------------------
// Journal: the undo log behind atomic edits
// ----------------------------------------------------------------------

/// INTERNAL. The undo log of one atomic batch -- `edit.Editor.apply`, or
/// merge-key resolution (see `Transaction`). While `Document.journal`
/// points at one, every
/// structural mutation goes through the primitives below, which record
/// what they overwrite; a failed batch replays the records newest first.
///
/// A record is reserved before its mutation and pushed only after the
/// mutation succeeded, so the log never names a change that did not
/// happen. And every undo writes back into room the forward change left
/// -- a list never gives capacity back, so re-inserting a removed entry
/// fits -- so rolling back cannot fail.
///
/// It replaces a deep clone of the whole tree per batch, which made every
/// single `set` cost the document's size and left a dead copy of the tree
/// in the arena each time: 800 sets on an 8,000-key mapping took 20 s and
/// 4.3 GB.
pub const Journal = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = union(enum) {
        root: ?*Node,
        parent: struct { node: *Node, old: ?*Node },
        src: struct { node: *Node, old: ?markup.Src },
        /// The node's `modified` flag was false.
        modified: *Node,
        alias_target: struct { node: *Node, old: *Node },
        pair_inserted: struct { map: *Node, index: usize },
        pair_removed: struct { map: *Node, index: usize, pair: Pair },
        pair_value: struct { map: *Node, index: usize, old: *Node },
        item_inserted: struct { seq: *Node, index: usize },
        item_removed: struct { seq: *Node, index: usize, item: *Node },
        item_replaced: struct { seq: *Node, index: usize, old: *Node },
        dropped_inserted: struct { node: *Node, index: usize },
    };

    pub fn deinit(self: *Journal) void {
        self.entries.deinit(self.allocator);
    }

    /// Undo every recorded change, newest first.
    pub fn rollback(self: *Journal, doc: *Document) void {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            undo(doc, self.entries.items[i]);
        }
        self.entries.clearRetainingCapacity();
    }

    fn undo(doc: *Document, e: Entry) void {
        switch (e) {
            .root => |r| doc.root = r,
            .parent => |x| x.node.parent = x.old,
            .src => |x| x.node.src = x.old,
            .modified => |n| n.modified = false,
            .alias_target => |x| x.node.data.alias.target = x.old,
            .pair_inserted => |x| _ = x.map.data.mapping.pairs.orderedRemove(x.index),
            .pair_removed => |x| x.map.data.mapping.pairs.insertAssumeCapacity(x.index, x.pair),
            .pair_value => |x| x.map.data.mapping.pairs.items[x.index].value = x.old,
            .item_inserted => |x| _ = x.seq.data.sequence.items.orderedRemove(x.index),
            .item_removed => |x| x.seq.data.sequence.items.insertAssumeCapacity(x.index, x.item),
            .item_replaced => |x| x.seq.data.sequence.items.items[x.index] = x.old,
            .dropped_inserted => |x| _ = droppedList(x.node).orderedRemove(x.index),
        }
    }
};

/// INTERNAL. One atomic section over a document: `begin` points
/// `Document.journal` at a fresh log, `abort` rolls it back, `commit`
/// keeps the changes. Lives on the caller's stack (the document points
/// into it) and is used as
///
///     var txn: internal.Transaction = undefined;
///     txn.begin(doc);
///     errdefer txn.abort();
///     ... journalled mutations ...
///     try txn.commit();
///
/// A section begun inside another hands its records to the outer one on
/// commit, so the outer one's rollback still undoes them.
pub const Transaction = struct {
    doc: *Document,
    journal: Journal,
    outer: ?*Journal,

    pub fn begin(self: *Transaction, doc: *Document) void {
        self.* = .{ .doc = doc, .journal = .{ .allocator = doc.allocator }, .outer = doc.journal };
        doc.journal = &self.journal;
    }

    /// Keep the changes. Fails only while nested (the outer log could
    /// not take the records); the caller's `abort` then undoes them.
    pub fn commit(self: *Transaction) !void {
        if (self.outer) |o| try o.entries.appendSlice(o.allocator, self.journal.entries.items);
        self.end();
    }

    /// Undo every change made since `begin`.
    pub fn abort(self: *Transaction) void {
        self.doc.journal = null; // the rollback itself records nothing
        self.journal.rollback(self.doc);
        self.end();
    }

    fn end(self: *Transaction) void {
        self.doc.journal = self.outer;
        self.journal.deinit();
    }
};

/// Room for one record, before the mutation it describes.
fn reserve(doc: *Document) !void {
    if (doc.journal) |j| try j.entries.ensureUnusedCapacity(j.allocator, 1);
}

/// The record of a mutation that has just succeeded (room reserved).
fn record(doc: *Document, e: Journal.Entry) void {
    if (doc.journal) |j| j.entries.appendAssumeCapacity(e);
}

fn droppedList(node: *Node) *std.ArrayList([2]usize) {
    return switch (node.data) {
        .mapping => |*m| &m.dropped,
        .sequence => |*s| &s.dropped,
        else => unreachable,
    };
}

/// INTERNAL mutation primitives: each records itself when a journal is
/// active. Every change `edit` or merge resolution makes to an existing
/// tree goes through one of these (or `Document.markModified`).
pub fn setRoot(doc: *Document, root: ?*Node) !void {
    try reserve(doc);
    record(doc, .{ .root = doc.root });
    doc.root = root;
}

pub fn setParent(doc: *Document, node: *Node, parent: ?*Node) !void {
    if (node.parent == parent) return;
    try reserve(doc);
    record(doc, .{ .parent = .{ .node = node, .old = node.parent } });
    node.parent = parent;
}

pub fn setSrc(doc: *Document, node: *Node, src: ?markup.Src) !void {
    try reserve(doc);
    record(doc, .{ .src = .{ .node = node, .old = node.src } });
    node.src = src;
}

pub fn setAliasTarget(doc: *Document, node: *Node, target: *Node) !void {
    try reserve(doc);
    record(doc, .{ .alias_target = .{ .node = node, .old = node.data.alias.target } });
    node.data.alias.target = target;
}

/// Record that `node.modified` is about to flip from false. Called by
/// `Document.markModified` for each node it flips.
pub fn recordModified(doc: *Document, node: *Node) !void {
    try reserve(doc);
    record(doc, .{ .modified = node });
}

pub fn insertPair(doc: *Document, map: *Node, index: usize, pair: Pair) !void {
    try reserve(doc);
    try map.data.mapping.pairs.insert(doc.pool.allocator(), index, pair);
    record(doc, .{ .pair_inserted = .{ .map = map, .index = index } });
}

pub fn removePair(doc: *Document, map: *Node, index: usize) !Pair {
    try reserve(doc);
    const pair = map.data.mapping.pairs.orderedRemove(index);
    record(doc, .{ .pair_removed = .{ .map = map, .index = index, .pair = pair } });
    return pair;
}

pub fn setPairValue(doc: *Document, map: *Node, index: usize, value: *Node) !void {
    try reserve(doc);
    const slot = &map.data.mapping.pairs.items[index];
    record(doc, .{ .pair_value = .{ .map = map, .index = index, .old = slot.value } });
    slot.value = value;
}

pub fn insertItem(doc: *Document, seq: *Node, index: usize, item: *Node) !void {
    try reserve(doc);
    try seq.data.sequence.items.insert(doc.pool.allocator(), index, item);
    record(doc, .{ .item_inserted = .{ .seq = seq, .index = index } });
}

pub fn removeItem(doc: *Document, seq: *Node, index: usize) !*Node {
    try reserve(doc);
    const item = seq.data.sequence.items.orderedRemove(index);
    record(doc, .{ .item_removed = .{ .seq = seq, .index = index, .item = item } });
    return item;
}

pub fn setItem(doc: *Document, seq: *Node, index: usize, item: *Node) !void {
    try reserve(doc);
    const slot = &seq.data.sequence.items.items[index];
    record(doc, .{ .item_replaced = .{ .seq = seq, .index = index, .old = slot.* } });
    slot.* = item;
}

/// INTERNAL. `node` has just been attached to a slot of the tree by an
/// edit. A source span it carries describes the slot it was PARSED in --
/// a same-document `cloneTree` copy keeps its spans, and so does a node
/// detached from one place and attached in another -- and the emitter,
/// finding it clean, would copy that other slot's bytes here and carry on
/// from where that slot ended: `- p` set as the root came back as the
/// whole old document, and a block sequence item re-wrote the lines
/// after its source. Clear the span and mark the node, so it re-emits
/// normalized at its new position like a moved subtree. Its descendants
/// keep their spans; a modified container lays them out afresh.
pub fn adopt(doc: *Document, node: *Node) !void {
    if (node.src != null) try setSrc(doc, node, null);
    try doc.markModified(node);
}

/// INTERNAL. True when the emitter lays a value out on its key's line:
/// scalars, aliases, flow and empty collections. A block collection
/// starts on the next, deeper line.
pub fn inlineValue(value: *const Node) bool {
    return switch (value.data) {
        .scalar, .alias => true,
        .mapping => |m| m.pairs.items.len == 0 or m.style == .flow,
        .sequence => |s| s.items.items.len == 0 or s.style == .flow,
    };
}

/// INTERNAL. True when `name` can be written as an anchor or alias name
/// (spec 6.9.2 `ns-anchor-char`): one or more printable characters in
/// valid UTF-8, none of them a blank, a line break, a flow indicator or
/// the byte order mark. `Document.setAnchor` refuses anything else, and
/// the emitter refuses to write it, since the name would end early or
/// not read back at all.
pub fn validAnchorName(name: []const u8) bool {
    if (name.len == 0) return false;
    var i: usize = 0;
    while (utf8.decode(name, i) catch return false) |d| : (i += d.len) {
        switch (d.cp) {
            ' ', '\t', '\n', '\r', ',', '[', ']', '{', '}', 0xFEFF => return false,
            else => if (!utf8.isPrintableCodepoint(d.cp)) return false,
        }
    }
    return true;
}

/// INTERNAL. Structural append that deliberately skips the `modified`
/// mark, for the builder composing a parsed tree. Calling this from
/// outside leaves the subtree looking clean, so it re-emits verbatim
/// from source and your change is silently dropped — that omission is
/// what made `move` a silent copy until 9162c7d. Use
/// `Document.mappingAppend`.
pub fn attachPair(self: *Document, map: *Node, key: *Node, value: *Node) !void {
    switch (map.data) {
        .mapping => |m| {
            try insertPair(self, map, m.pairs.items.len, .{ .key = key, .value = value });
            try setParent(self, key, map);
            try setParent(self, value, map);
        },
        else => return error.InvalidSyntax,
    }
}

/// INTERNAL. Structural append without the `modified` mark. Same
/// hazard as `attachPair`; use `Document.sequenceAppend`.
pub fn attachItem(self: *Document, seq: *Node, item: *Node) !void {
    switch (seq.data) {
        .sequence => |s| {
            try insertItem(self, seq, s.items.items.len, item);
            try setParent(self, item, seq);
        },
        else => return error.InvalidSyntax,
    }
}

/// Source offset where the entry after `p` begins, or null when `p`
/// is the last (or is not found).
fn nextEntryStart(m: anytype, p: Pair) ?usize {
    for (m.pairs.items, 0..) |q, i| {
        if (q.key != p.key) continue;
        if (i + 1 >= m.pairs.items.len) return null;
        const ns = m.pairs.items[i + 1].key.src orelse return null;
        if (ns.synthetic) return null;
        return ns.start;
    }
    return null;
}

/// Source offset where the item after `item` begins, or null when
/// `item` is the last (or is not found).
fn nextItemStart(s: anytype, item: *const Node) ?usize {
    for (s.items.items, 0..) |q, i| {
        if (q != item) continue;
        if (i + 1 >= s.items.items.len) return null;
        const ns = s.items.items[i + 1].src orelse return null;
        if (ns.synthetic) return null;
        return ns.entry_start;
    }
    return null;
}

/// Record a tombstoned byte range, keeping the list ASCENDING by
/// start. Emission walks a container's bytes in document order and
/// skips tombstones as it passes them (emitter `writeGap`), so a
/// range appended out of order would resurrect the deleted bytes
/// it covers — and edits applied after an earlier one can easily
/// detach entries in reverse document order.
pub fn dropRange(self: *Document, node: *Node, from: usize, to: usize) !void {
    const drops = droppedList(node);
    var i: usize = 0;
    while (i < drops.items.len and drops.items[i][0] < from) i += 1;
    try reserve(self);
    try drops.insert(self.pool.allocator(), i, .{ from, to });
    record(self, .{ .dropped_inserted = .{ .node = node, .index = i } });
}

/// INTERNAL. Tombstone the source bytes a mapping entry occupied.
///
/// MUST run BEFORE the entry is detached: the span is derived from
/// where the NEXT entry starts, and the fate of a `- ` sequence
/// indicator on the same line is decided from the successor. Called
/// after detaching, it tombstones the wrong bytes silently. Returns
/// early for flow containers — an emitter gap-walk invariant, not a
/// document-model one.
/// The framing an entry's line carries for the nodes around it. When
/// `container` starts on that line -- the entry is its first -- the
/// bytes from the line start to the container's own start are the
/// indicators of enclosing nodes (an item's `- `, a key collection's
/// `? `, an explicit value's `: `, nested: `- - `, `- ? `) and
/// indentation. They belong to those nodes and outlive the entry; the
/// entry's own bytes begin at the container's start (which is where an
/// explicit key's own `? ` sits: `? a\n: 1`). Returns that start and the
/// end of the last indicator, or null when the line has no such framing.
fn outerFraming(src: []const u8, container: *const Node, line: usize) ?struct { own: usize, after: usize } {
    const cs = container.src orelse return null;
    if (cs.synthetic or cs.start < line) return null;
    var after = line;
    for (src[line..cs.start], line..) |c, i| {
        if (!ctype.isBlank(c) and !ctype.isBreak(c)) after = i + 1;
    }
    if (after == line) return null; // indentation only
    return .{ .own = cs.start, .after = after };
}

pub fn dropPairSpan(self: *Document, map: *Node, p: Pair) !void {
    const src = self.source orelse return;
    const ks = p.key.src orelse return;
    // A null key (`: a`) has no text, but its span still points at the
    // indicator its entry starts with; skipping it left a deleted entry
    // in the output (and a moved one there as well as at its new place).
    if (ks.synthetic and !(ks.entry_start < src.len and (src[ks.entry_start] == ':' or src[ks.entry_start] == '?'))) return;
    switch (map.data) {
        .mapping => |*m| {
            // A flow collection re-emits normalized from the tree, so
            // it has no verbatim bytes to skip. Its entries share a
            // line with the parent's `key:`, so a line-range
            // tombstone would swallow those bytes too.
            if (m.style == .flow) return;
            var from = markup.lineStart(src, ks.entry_start);
            var to = markup.lineEnd(src, p.src_end orelse ks.end);
            // The first entry's line can carry enclosing nodes' framing
            // (`- name: x`, `? x: 1` for a key mapping, `: x: 1` for an
            // explicit key's value). It outlives the entry: leave it and
            // consume the successor's own indentation instead, so the
            // successor moves up onto that line (`- name: x` +
            // `  port: 1` -> `- port: 1`). Only when nothing but blanks
            // separates them: a comment in between has to stay where the
            // author put it. Taking the whole line lost a `: ` (a
            // different tree) and left a bare `- ` or `? ` behind.
            if (outerFraming(src, map, markup.lineStart(src, ks.entry_start))) |fr| {
                if (nextEntryStart(m, p)) |nx| {
                    if (nx >= to and ctype.isBlankRun(src[to..nx])) {
                        from = fr.own;
                        to = nx;
                    } else {
                        // Something the author wrote — a comment —
                        // sits between the two entries and has to
                        // stay where it is, so the successor cannot
                        // move up. Keep the framing on its own line
                        // (dropping the space after it) and remove
                        // only this entry's own text.
                        from = fr.own;
                        while (from > fr.after and src[from - 1] == ' ') from -= 1;
                        to = markup.newlineAt(src, p.src_end orelse ks.end);
                    }
                } else {
                    // No successor at all: this entry was the mapping's
                    // only one, so it empties and re-emits as `{}`. The
                    // enclosing node survives -- `- {}`, `: {}` -- so the
                    // framing has to stay put. Taking the whole line
                    // deletes an entry nobody asked to delete and leaves
                    // the `{}` dangling at the parent's column, which
                    // does not parse.
                    from = fr.own;
                    to = markup.newlineAt(src, p.src_end orelse ks.end);
                }
            }
            if (to <= from) return;
            // Losing a tombstone to OOM would resurrect the deleted
            // entry verbatim on the next write: propagate the error.
            try dropRange(self, map, from, to);
        },
        else => {},
    }
}

/// INTERNAL. Tombstone the source bytes a sequence entry occupied.
/// Same ordering requirement as `dropPairSpan`: the span depends on
/// where the next entry starts, so it must run before the item is
/// detached. Returns early for flow containers.
pub fn dropItemSpan(self: *Document, seq: *Node, item: *Node) !void {
    const src = self.source orelse return;
    const is = item.src orelse return;
    switch (seq.data) {
        .sequence => |*s| {
            // Flow items share their line with the parent's `key:`
            // (see dropPairSpan).
            if (s.style == .flow) return;
            if (is.synthetic) {
                // A synthesized empty item's span is a point borrowed
                // from the NEXT token (`entry_start == start == end`),
                // unusable for slicing forward — but the bytes the item
                // owns are the line(s) BEFORE that point: `- # Empty`
                // borrows the next item's dash. Tombstone from the last
                // line break before the borrowed point; without this,
                // deleting the item was a silent no-op (the next item's
                // gap re-emitted the deleted bytes verbatim). Found by
                // the preservation corpus sweep once `parse`'s region
                // covered the document tail.
                const from = if (is.end > 0) markup.lineStart(src, is.end - 1) else 0;
                const to = is.end;
                if (to > from) try dropRange(self, seq, from, to);
                return;
            }
            var from = markup.lineStart(src, is.entry_start);
            var to = markup.lineEnd(src, is.end);
            // The first item's line can carry enclosing nodes' framing
            // (an outer item's `- ` in `- - a`, an explicit key's `? `
            // or value's `: `). It outlives this item, so leave it and
            // consume the successor's indentation instead (see
            // dropPairSpan for the mapping equivalent).
            if (outerFraming(src, seq, from)) |fr| {
                if (nextItemStart(s, item)) |nx| {
                    if (nx >= to and ctype.isBlankRun(src[to..nx])) {
                        from = fr.own;
                        to = nx;
                    } else {
                        // A comment between the two items keeps the
                        // successor from moving up: the framing stays on
                        // its own line (dropping the blanks after it)
                        // and only this item's text goes.
                        from = fr.own;
                        while (from > fr.after and src[from - 1] == ' ') from -= 1;
                        to = markup.newlineAt(src, is.end);
                    }
                } else {
                    // No successor: this sequence empties and re-emits
                    // as `[]`, but the enclosing node survives as
                    // `- []`. Taking the whole line deleted an item
                    // nobody asked to delete and left `[]` dangling at
                    // the parent's column, which does not parse (`- - x`
                    // minus `$[0][0]` emitted a bare `[]`).
                    from = fr.own;
                    to = markup.newlineAt(src, is.end);
                }
            }
            if (to <= from) return;
            try dropRange(self, seq, from, to);
        },
        else => {},
    }
}

/// INTERNAL. Replace one recoverable flow-sequence slot without changing
/// its position or separator layout. The replacement inherits the old
/// item's exact byte bounds; false means the caller must fall back to
/// ordinary remove/insert semantics.
pub fn sequenceReplace(self: *Document, seq: *Node, index: usize, value: *Node) !bool {
    switch (seq.data) {
        .sequence => |s| {
            if (s.style != .flow or index >= s.items.items.len) return false;
            const old = s.items.items[index];
            const old_src = old.src orelse return false;
            if (old_src.synthetic) return false;

            try setParent(self, value, seq);
            try setSrc(self, value, .{
                .entry_start = old_src.entry_start,
                .start = old_src.entry_start,
                .end = old_src.end,
            });
            try setItem(self, seq, index, value);
            try self.markModified(value);
            return true;
        },
        else => return false,
    }
}

/// INTERNAL. Why attaching `child` under `parent` must be refused, or null
/// when it is safe. `child` being `parent` itself or one of its
/// ancestors is a parent cycle. An ancestor chain longer than the
/// walk bound is reported as `NestingTooDeep` rather than a cycle:
/// `markModified` asserts past the same bound, so attaching there
/// would build a tree the rest of the module cannot maintain. The
/// chain is acyclic by induction — this is the check that keeps it so
/// — hence the plain walk.
pub fn attachRefusal(parent: *Node, child: *Node) ?error{ WouldCycle, NestingTooDeep } {
    var cur: ?*Node = parent;
    var guard: usize = 0;
    while (cur) |n| : (guard += 1) {
        if (n == child) return error.WouldCycle;
        if (guard >= Node.max_parent_walk) return error.NestingTooDeep;
        cur = n.parent;
    }
    return null;
}

/// INTERNAL. Would every alias under `root` still bind to its current
/// target once the document is written and read back? A reader binds an
/// alias to the nearest definition of its name before it (a later `&x`
/// shadows an earlier one), so an edit that defines a name again, or
/// moves a definition, rebinds the aliases after it: in memory `*x` kept
/// its old target, and the written document meant something else. An
/// alias with no definition before it is not judged: that is a forward
/// alias in a hand-built tree, which no edit made. `renamed`, when set,
/// gives that node the anchor `as` for the check (a `setAnchor` about to
/// happen).
pub fn aliasesBindInOrder(allocator: std.mem.Allocator, root: *const Node, renamed: ?*const Node, as: ?[]const u8) !bool {
    var defs: std.StringHashMapUnmanaged(*const Node) = .empty;
    defer defs.deinit(allocator);
    return bindsInOrder(allocator, root, &defs, renamed, as, 0);
}

fn bindsInOrder(allocator: std.mem.Allocator, node: *const Node, defs: *std.StringHashMapUnmanaged(*const Node), renamed: ?*const Node, as: ?[]const u8, depth: usize) !bool {
    if (depth >= Node.max_parent_walk) return true;
    // A definition comes before its node's content (`&x [*x]`).
    const anchor = if (renamed == node) as else node.anchor;
    if (anchor) |a| try defs.put(allocator, a, node);
    switch (node.data) {
        .scalar => {},
        .alias => |al| if (defs.get(al.name)) |bound| {
            if (bound != al.target) return false;
        },
        .mapping => |m| for (m.pairs.items) |p| {
            if (!try bindsInOrder(allocator, p.key, defs, renamed, as, depth + 1)) return false;
            if (!try bindsInOrder(allocator, p.value, defs, renamed, as, depth + 1)) return false;
        },
        .sequence => |sq| for (sq.items.items) |item| {
            if (!try bindsInOrder(allocator, item, defs, renamed, as, depth + 1)) return false;
        },
    }
    return true;
}

/// INTERNAL. Replace the existing value node `existing` (a value of
/// `map`) with `value`, preserving pair order and the key node. Returns
/// false when `existing` is not a value of `map`.
pub fn mappingReplace(self: *Document, map: *Node, existing: *Node, value: *Node) !bool {
    const pairs = switch (map.data) {
        .mapping => |m| m.pairs.items,
        else => return false,
    };
    for (pairs, 0..) |p, i| {
        if (p.value == existing) {
            // Set as a value of its own descendant (`$.a.b` to `$`): a
            // parent cycle, which the append paths already refused.
            if (attachRefusal(map, value)) |reason| return reason;
            try setParent(self, value, map);
            try setPairValue(self, map, i, value);
            // A spanned replacement (a clone) would otherwise look
            // clean, and the pair's fast path would re-emit the ORIGINAL
            // bytes: the replacement silently vanished.
            try adopt(self, value);
            return true;
        }
    }
    return false;
}

/// INTERNAL. The leading comment override the emitter must write ahead
/// of a pair's key: the key's own, or — for a pair whose value shares
/// the key's line, where the value stands in for the pair — the value's.
/// A block value's comments are its own and are handled at that value's
/// own slot, not here.
pub fn pairLeadingOverride(src: []const u8, key: *const Node, value: *const Node) ?[]const u8 {
    if (key.pending_leading) |t| return t;
    const ks = key.src orelse return value.pending_leading; // brand-new key: the value stands in
    const vs = value.src orelse return value.pending_leading; // brand-new value sits inline
    if (ks.synthetic or vs.synthetic) return value.pending_leading;
    const same_line = markup.lineStart(src, vs.entry_start) == markup.lineStart(src, ks.start);
    return if (same_line) value.pending_leading else null;
}
