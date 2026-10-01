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
const TagDirective = @import("token.zig").TagDirective;

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
        trailing: struct { node: *Node, old: ?[]const u8 },
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
            .trailing => |x| x.node.pending_trailing = x.old,
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

/// A written trailing comment for `node` (see `Document.setTrailingComment`),
/// journaled: `text` must live in the document pool.
pub fn setPendingTrailing(doc: *Document, node: *Node, text: ?[]const u8) !void {
    try reserve(doc);
    record(doc, .{ .trailing = .{ .node = node, .old = node.pending_trailing } });
    node.pending_trailing = text;
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

/// The core schema's tag prefix, written `!!`.
pub const yaml_tag_prefix = "tag:yaml.org,2002:";

/// INTERNAL. Does a document with `directives` give `handle` a prefix of
/// its own?
pub fn handleRedefined(directives: []const TagDirective, handle: []const u8) bool {
    for (directives) |td| {
        if (std.mem.eql(u8, td.handle, handle)) return true;
    }
    return false;
}

/// INTERNAL. True when `tag` can be written, verbatim or as a shorthand,
/// in a document with `directives`: the choice `Emitter.writeTag` makes.
/// A shorthand escapes any byte its suffix cannot hold, so only a tag
/// left to the verbatim form can be unspellable. `Document.setTag`
/// refuses such a tag; the emitter refuses to write one.
pub fn tagSpellable(directives: []const TagDirective, tag: []const u8) bool {
    if (std.mem.eql(u8, tag, "!")) return true;
    for (directives) |td| {
        if (tag.len > td.prefix.len and std.mem.startsWith(u8, tag, td.prefix)) return true;
    }
    if (!handleRedefined(directives, "!!") and tag.len > yaml_tag_prefix.len and std.mem.startsWith(u8, tag, yaml_tag_prefix)) return true;
    if (!handleRedefined(directives, "!") and tag.len > 1 and tag[0] == '!') return true;
    return verbatimSpellable(tag);
}

/// INTERNAL. True when `tag` can be written `!<tag>`, which is read raw
/// up to the `>`: printable UTF-8 with no blank, line break or `>`.
pub fn verbatimSpellable(tag: []const u8) bool {
    if (tag.len == 0 or !utf8.valid(tag)) return false;
    var i: usize = 0;
    while (utf8.decode(tag, i) catch unreachable) |d| : (i += d.len) {
        if (d.cp == ' ' or d.cp == '>' or !utf8.isPrintableCodepoint(d.cp) or ctype.isBreak(tag[i])) return false;
    }
    return true;
}

test "a tag is spellable unless it falls to a verbatim form it cannot take" {
    const none: []const TagDirective = &.{};
    try std.testing.expect(tagSpellable(none, "!"));
    try std.testing.expect(tagSpellable(none, "tag:yaml.org,2002:str x")); // `!!str%20x`
    try std.testing.expect(tagSpellable(none, "!local thing"));
    try std.testing.expect(tagSpellable(none, "tag:example.com,2000:app"));
    try std.testing.expect(!tagSpellable(none, "tag:example.com,2000:a b"));
    try std.testing.expect(!tagSpellable(none, "a>b"));
    try std.testing.expect(!tagSpellable(none, ""));
    try std.testing.expect(!tagSpellable(none, "x\ny"));
    // With `!` redefined, a local tag has only the verbatim form.
    const bang: []const TagDirective = &.{.{ .handle = "!", .prefix = "tag:example.com,2000:" }};
    try std.testing.expect(!tagSpellable(bang, "!a b"));
    try std.testing.expect(tagSpellable(bang, "tag:example.com,2000:a b"));
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

/// Whether `[from, to)` holds nothing but blanks, line breaks and bytes in
/// one of `node`'s tombstones: text a deleted entry owned is gone, so it
/// separates nothing. A successor moves up onto a removed first entry's
/// line only when nothing but that lies between them; an entry deleted
/// earlier, from after it, sat between and left the successor where it
/// was (`- name` / `  image` / `  res` / `  ports` with `res`, `name` and
/// then `image` removed wrote `-   ports`).
fn blankOrDropped(node: *const Node, src: []const u8, from: usize, to: usize) bool {
    var walk: DropWalk = .{ .drops = Document.droppedOf(node) };
    var i = from;
    while (true) {
        i = walk.skip(i);
        if (i >= to) return true;
        if (!ctype.isBlankRun(src[i .. i + 1])) return false;
        i += 1;
    }
}

/// INTERNAL. Whether every byte of `[from, to)` lies in one of `node`'s
/// tombstones.
pub fn coveredByDrops(node: *const Node, from: usize, to: usize) bool {
    var walk: DropWalk = .{ .drops = Document.droppedOf(node) };
    return walk.skip(from) >= to;
}

/// A forward walk over a collection's tombstones, which `dropRange` keeps
/// ascending by start (they may overlap or touch). Offsets asked of it
/// must not decrease; each range is then looked at once, so a walk over
/// a gap is linear in its bytes and the ranges before its end. A scan
/// from the first range at every byte made deleting thousands of entries
/// from one item quadratic in the bytes between them.
const DropWalk = struct {
    drops: []const [2]usize,
    next: usize = 0,

    /// The first offset at or after `at` that no tombstone covers.
    fn skip(self: *DropWalk, at: usize) usize {
        var i = at;
        while (self.next < self.drops.len and self.drops[self.next][0] <= i) : (self.next += 1) {
            i = @max(i, self.drops[self.next][1]);
        }
        return i;
    }
};

/// INTERNAL. The start of a line holding only an explicit key indicator
/// (`?`, and perhaps a comment) above `pos`'s line, with only blank and
/// comment lines between; null when there is none.
pub fn explicitIndicatorAbove(src: []const u8, pos: usize) ?usize {
    var ls = markup.lineStart(src, pos);
    while (ls > 0) {
        const prev = markup.lineStart(src, ls - 1);
        const body = std.mem.trimStart(u8, src[prev..markup.newlineAt(src, prev)], " \t");
        if (body.len == 0 or body[0] == '#') {
            ls = prev;
            continue;
        }
        if (body[0] != '?') return null;
        const rest = std.mem.trimStart(u8, body[1..], " \t");
        if (body.len > 1 and !ctype.isBlank(body[1])) return null;
        return if (rest.len == 0 or rest[0] == '#') prev else null;
    }
    return null;
}

/// Past the blank lines at `to` when `node`'s source ends in a
/// keep-chomped block scalar (`|+`, `>+`): they are its value's trailing
/// line breaks, not space between entries. Left behind by a tombstone
/// that stopped at the block's last content line, they stayed in the gap
/// while a moved copy of the block wrote them again.
fn keptBlanksEnd(src: []const u8, node: *const Node, to: usize) usize {
    var n = node;
    var depth: usize = 0;
    // Down to the last original leaf, as the block would be.
    while (depth < Node.max_parent_walk) : (depth += 1) {
        n = switch (n.data) {
            .mapping => |m| if (m.pairs.items.len == 0) break else blk: {
                const last = m.pairs.items[m.pairs.items.len - 1];
                const vs = last.value.src orelse return to;
                break :blk if (vs.synthetic) last.key else last.value;
            },
            .sequence => |sq| if (sq.items.items.len == 0) break else sq.items.items[sq.items.items.len - 1],
            else => break,
        };
    }
    if (n.data != .scalar) return to;
    const ns = n.src orelse return to;
    if (ns.synthetic) return to;
    var h = markup.propertiesLineEnd(src, ns.start) orelse markup.propertiesEnd(src, ns.start);
    while (h < src.len and (src[h] == ' ' or src[h] == '\t')) h += 1;
    if (h >= src.len or (src[h] != '|' and src[h] != '>')) return to;
    h += 1;
    var keep = false;
    while (h < src.len and (src[h] == '+' or src[h] == '-' or std.ascii.isDigit(src[h]))) : (h += 1) {
        if (src[h] == '+') keep = true;
    }
    if (!keep) return to;
    var i = to;
    while (i < src.len) {
        const next = markup.lineEnd(src, i);
        if (next == i or !ctype.isBlankRun(src[i..markup.newlineAt(src, i)])) break;
        i = next;
    }
    return i;
}

pub fn dropPairSpan(self: *Document, map: *Node, p: Pair) !void {
    const src = self.source orelse return;
    const ks = p.key.src orelse return;
    // A null key (`: a`) has no text, but its span still points at the
    // indicator its entry starts with; skipping it left a deleted entry
    // in the output (and a moved one there as well as at its new place).
    if (ks.synthetic and !(ks.entry_start < src.len and (src[ks.entry_start] == ':' or src[ks.entry_start] == '?'))) return;
    // An explicit null key (`?` over `:`) points at its `:`; the entry
    // starts at the `?` line above.
    const entry_start = if (ks.synthetic) explicitIndicatorAbove(src, ks.entry_start) orelse ks.entry_start else ks.entry_start;
    switch (map.data) {
        .mapping => |*m| {
            // A flow collection re-emits normalized from the tree, so
            // it has no verbatim bytes to skip. Its entries share a
            // line with the parent's `key:`, so a line-range
            // tombstone would swallow those bytes too.
            if (m.style == .flow) return;
            var from = markup.lineStart(src, entry_start);
            var to = keptBlanksEnd(src, p.value, markup.lineEnd(src, p.src_end orelse ks.end));
            // The first entry's line can carry enclosing nodes' framing
            // (`- name: x`, `? x: 1` for a key mapping, `: x: 1` for an
            // explicit key's value). It outlives the entry: leave it and
            // consume the successor's own indentation instead, so the
            // successor moves up onto that line (`- name: x` +
            // `  port: 1` -> `- port: 1`). Only when nothing but blanks
            // separates them: a comment in between has to stay where the
            // author put it. Taking the whole line lost a `: ` (a
            // different tree) and left a bare `- ` or `? ` behind.
            if (outerFraming(src, map, markup.lineStart(src, entry_start))) |fr| {
                if (nextEntryStart(m, p)) |nx| {
                    if (nx >= to and blankOrDropped(map, src, to, nx)) {
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
            } else if (from < entry_start and coveredByDrops(map, from, entry_start)) {
                // This entry had moved up onto an earlier one's line (that
                // tombstone took its indentation): it is first on the line
                // now, and passes the move on to its successor. Taking its
                // whole line left the earlier line's indentation in front
                // of the successor's own (`-\n    avg`).
                if (nextEntryStart(m, p)) |nx| {
                    if (nx >= to and blankOrDropped(map, src, to, nx)) {
                        from = entry_start;
                        to = nx;
                    }
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
                var from = if (is.end > 0) markup.lineStart(src, is.end - 1) else 0;
                var to = is.end;
                // Its own `-` says which line that is: the line before the
                // borrowed point is the next item's indentation when that
                // item is indented (`- -` over `  - x`).
                if (markup.emptyItemDash(src, is.end)) |dash| {
                    from = markup.lineStart(src, dash);
                    to = markup.lineEnd(src, dash);
                }
                // An outer item's `- ` on the line (`- -`) outlives it, and
                // so does the line's break.
                if (outerFraming(src, seq, from)) |fr| {
                    from = @max(from, fr.own);
                    to = @min(to, markup.newlineAt(src, from));
                }
                if (to > from) try dropRange(self, seq, from, to);
                return;
            }
            var from = markup.lineStart(src, is.entry_start);
            var to = keptBlanksEnd(src, item, markup.lineEnd(src, is.end));
            // The first item's line can carry enclosing nodes' framing
            // (an outer item's `- ` in `- - a`, an explicit key's `? `
            // or value's `: `). It outlives this item, so leave it and
            // consume the successor's indentation instead (see
            // dropPairSpan for the mapping equivalent).
            if (outerFraming(src, seq, from)) |fr| {
                if (nextItemStart(s, item)) |nx| {
                    if (nx >= to and blankOrDropped(seq, src, to, nx)) {
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
            } else if (from < is.entry_start and coveredByDrops(seq, from, is.entry_start)) {
                // Moved up onto an earlier item's line (see dropPairSpan).
                if (nextItemStart(s, item)) |nx| {
                    if (nx >= to and blankOrDropped(seq, src, to, nx)) {
                        from = is.entry_start;
                        to = nx;
                    }
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

/// How the aliases under a root bind once the document is written and
/// read back (see `aliasBinding`).
pub const Binding = enum {
    /// Each to its current target.
    in_order,
    /// One to another definition of its name.
    shadowed,
    /// One to no definition: none of its name comes before it.
    unbound,
};

/// INTERNAL. Would every alias under `root` still bind to its current
/// target once the document is written and read back? A reader binds an
/// alias to the nearest definition of its name before it (a later `&x`
/// shadows an earlier one), so an edit that defines a name again, or
/// moves a definition, rebinds the aliases after it: in memory `*x` kept
/// its old target, and the written document meant something else. And
/// an alias placed ahead of every definition of its name, or over the
/// node that carried it, does not read back at all. The first problem
/// found is reported. `renamed`, when set, gives that node the anchor
/// `as` for the check (a `setAnchor` about to happen).
pub fn aliasBinding(allocator: std.mem.Allocator, root: *const Node, renamed: ?*const Node, as: ?[]const u8) !Binding {
    var defs: std.StringHashMapUnmanaged(*const Node) = .empty;
    defer defs.deinit(allocator);
    return bindsInOrder(allocator, root, &defs, renamed, as, 0);
}

fn bindsInOrder(allocator: std.mem.Allocator, node: *const Node, defs: *std.StringHashMapUnmanaged(*const Node), renamed: ?*const Node, as: ?[]const u8, depth: usize) !Binding {
    if (depth >= Node.max_parent_walk) return .in_order;
    // A definition comes before its node's content (`&x [*x]`).
    const anchor = if (renamed == node) as else node.anchor;
    if (anchor) |a| try defs.put(allocator, a, node);
    switch (node.data) {
        .scalar => {},
        .alias => |al| {
            const bound = defs.get(al.name) orelse return .unbound;
            if (bound != al.target) return .shadowed;
        },
        .mapping => |m| for (m.pairs.items) |p| {
            for ([_]*const Node{ p.key, p.value }) |n| {
                const b = try bindsInOrder(allocator, n, defs, renamed, as, depth + 1);
                if (b != .in_order) return b;
            }
        },
        .sequence => |sq| for (sq.items.items) |item| {
            const b = try bindsInOrder(allocator, item, defs, renamed, as, depth + 1);
            if (b != .in_order) return b;
        },
    }
    return .in_order;
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
