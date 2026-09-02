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
const document_mod = @import("document.zig");
const markup = @import("markup.zig");

const Document = document_mod.Document;
const Node = document_mod.Node;
const Pair = document_mod.Pair;

/// INTERNAL. Structural append that deliberately skips the `modified`
/// mark, for the builder composing a parsed tree. Calling this from
/// outside leaves the subtree looking clean, so it re-emits verbatim
/// from source and your change is silently dropped — that omission is
/// what made `move` a silent copy until 9162c7d. Use
/// `Document.mappingAppend`.
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

/// INTERNAL. Structural append without the `modified` mark. Same
/// hazard as `attachPair`; use `Document.sequenceAppend`.
pub fn attachItem(self: *Document, seq: *Node, item: *Node) !void {
    switch (seq.data) {
        .sequence => |*s| {
            try s.items.append(self.pool.allocator(), item);
            item.parent = seq;
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

/// True when `s` is only spaces, tabs and line breaks.
fn isBlankRun(s: []const u8) bool {
    return std.mem.indexOfNone(u8, s, " \t\r\n") == null;
}

/// Record a tombstoned byte range, keeping the list ASCENDING by
/// start. Emission walks a container's bytes in document order and
/// skips tombstones as it passes them (emitter `writeGap`), so a
/// range appended out of order would resurrect the deleted bytes
/// it covers — and edits applied after an earlier one can easily
/// detach entries in reverse document order.
pub fn dropRange(self: *Document, drops: *std.ArrayList([2]usize), from: usize, to: usize) !void {
    var i: usize = 0;
    while (i < drops.items.len and drops.items[i][0] < from) i += 1;
    try drops.insert(self.pool.allocator(), i, .{ from, to });
}

/// INTERNAL. Tombstone the source bytes a mapping entry occupied.
///
/// MUST run BEFORE the entry is detached: the span is derived from
/// where the NEXT entry starts, and the fate of a `- ` sequence
/// indicator on the same line is decided from the successor. Called
/// after detaching, it tombstones the wrong bytes silently. Returns
/// early for flow containers — an emitter gap-walk invariant, not a
/// document-model one.
pub fn dropPairSpan(self: *Document, map: *Node, p: Pair) !void {
    const src = self.source orelse return;
    const ks = p.key.src orelse return;
    if (ks.synthetic) return;
    switch (map.data) {
        .mapping => |*m| {
            // A flow collection re-emits normalized from the tree, so
            // it has no verbatim bytes to skip. Its entries share a
            // line with the parent's `key:`, so a line-range
            // tombstone would swallow those bytes too.
            if (m.style == .flow) return;
            var from = markup.lineStart(src, ks.entry_start);
            var to = markup.lineEnd(src, p.src_end orelse ks.end);
            // A mapping that is a sequence item carries the `- `
            // indicator in its FIRST entry's leading bytes, but the
            // indicator belongs to the item and outlives the entry.
            // Leave it in place and consume the successor's own
            // indentation instead, so it moves up onto that line
            // (`- name: x` + `  port: 1` -> `- port: 1`). Only when
            // nothing but blanks separates them: a comment in
            // between has to stay where the author put it.
            if (ks.entry_start < ks.start) {
                if (nextEntryStart(m, p)) |nx| {
                    if (nx >= to and isBlankRun(src[to..nx])) {
                        from = ks.start;
                        to = nx;
                    } else {
                        // Something the author wrote — a comment —
                        // sits between the two entries and has to
                        // stay where it is, so the successor cannot
                        // move up. Keep the indicator on its own
                        // line (dropping the space after it) and
                        // remove only this entry's own text.
                        from = ks.start;
                        while (from > ks.entry_start and src[from - 1] == ' ') from -= 1;
                        to = markup.newlineAt(src, p.src_end orelse ks.end);
                    }
                } else {
                    // No successor at all: this entry was the item's
                    // only one, so the mapping empties and re-emits
                    // as `{}`. The item itself survives -- it just
                    // becomes `- {}` -- so the indicator has to stay
                    // put. Taking the whole line, indicator and all,
                    // deletes a sequence entry nobody asked to
                    // delete and leaves the `{}` dangling at the
                    // parent's column, which does not parse.
                    from = ks.start;
                    to = markup.newlineAt(src, p.src_end orelse ks.end);
                }
            }
            if (to <= from) return;
            // Losing a tombstone to OOM would resurrect the deleted
            // entry verbatim on the next write: propagate the error.
            try dropRange(self, &m.dropped, from, to);
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
                if (to > from) try dropRange(self, &s.dropped, from, to);
                return;
            }
            var from = markup.lineStart(src, is.entry_start);
            var to = markup.lineEnd(src, is.end);
            // A nested sequence (`- - a`) puts an OUTER item's
            // indicator on this item's line. That indicator belongs
            // to the outer item and outlives this one, so leave it
            // and consume the successor's indentation instead
            // (see dropPairSpan for the mapping equivalent).
            if (std.mem.indexOfScalar(u8, src[from..is.entry_start], '-') != null) {
                if (nextItemStart(s, item)) |nx| {
                    if (nx >= to and isBlankRun(src[to..nx])) {
                        from = is.entry_start;
                        to = nx;
                    }
                }
            }
            if (to <= from) return;
            try dropRange(self, &s.dropped, from, to);
        },
        else => {},
    }
}

/// INTERNAL. Replace one recoverable flow-sequence slot without changing
/// its position or separator layout. The replacement inherits the old
/// item's exact byte bounds; false means the caller must fall back to
/// ordinary remove/insert semantics.
pub fn sequenceReplace(self: *Document, seq: *Node, index: usize, value: *Node) bool {
    switch (seq.data) {
        .sequence => |*s| {
            if (s.style != .flow or index >= s.items.items.len) return false;
            const old = s.items.items[index];
            const old_src = old.src orelse return false;
            if (old_src.synthetic) return false;

            value.parent = seq;
            value.src = .{
                .entry_start = old_src.entry_start,
                .start = old_src.entry_start,
                .end = old_src.end,
            };
            s.items.items[index] = value;
            self.markModified(value);
            return true;
        },
        else => return false,
    }
}

/// INTERNAL. Replace the existing value node `existing` (a value of
/// `map`) with `value`, preserving pair order and the key node. Returns
/// false when `existing` is not a value of `map`.
pub fn mappingReplace(self: *Document, map: *Node, existing: *Node, value: *Node) bool {
    const pairs = switch (map.data) {
        .mapping => |*m| m.pairs.items,
        else => return false,
    };
    for (pairs) |*p| {
        if (p.value == existing) {
            value.parent = map;
            p.value = value;
            // A replacement must never carry a span into a slot it does
            // not describe. A spanned replacement (a clone) either
            // looks clean — the pair's fast path re-emits the ORIGINAL
            // bytes and the replacement silently vanishes — or re-emits
            // whatever region its span happens to name. Clear it and
            // mark it: the value re-emits normalized, like a moved one.
            value.src = null;
            self.markModified(value);
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
