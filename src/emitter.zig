//! Emitter — Zig port of libfyaml's fy-emit.
//!
//! Serializes a `Document` back to YAML text. Two modes:
//!
//! *Faithful* (parsed documents): every node carries a span
//! into the original source; untouched regions re-emit byte for byte
//! (comments, blank lines, quoting, key order, indentation), and only
//! modified subtrees are re-emitted, in place, with the surrounding
//! bytes preserved. This is libfyaml's round-trip behavior.
//!
//! *Normalized* (programmatic documents): emitted from the semantic
//! tree. Block style is the default; collections parsed from flow style
//! (and empty collections) are emitted in flow style. Scalar styles are
//! honored when safe, with quoting rules that guarantee the re-parsed
//! value is identical.
//!
//! PORT NOTE: libfyaml's CST covers every byte including intra-node
//! layout; this port keeps per-node/entry spans, so some re-emitted
//! subtrees normalize their internal layout. Untouched bytes are
//! exact. A multi-line flow mapping and a recoverable flow-sequence
//! replacement survive a value change (see `flowLayoutRecoverable`).
//! Actual insertion or removal, including an explicit remove-plus-insert,
//! still collapses the collection because separators must be re-flowed.
//!
//! A subtree with no span at all -- brand-new, or moved, since `move`
//! clears the span that described the old location -- has no layout to
//! preserve, so the emitter picks one: BLOCK, at the document's own
//! indent width (measured, not assumed; see `inferIndentStep`). Flow is
//! reserved for collections that were written in flow style and for
//! empty ones, which block layout cannot express.

const std = @import("std");
const ctype = @import("ctype.zig");
const diag = @import("diag.zig");
const document_mod = @import("document.zig");
const internal = @import("internal.zig");
const markup = @import("markup.zig");
const token_mod = @import("token.zig");

const Document = document_mod.Document;
const Node = document_mod.Node;
const Pair = document_mod.Pair;
const ScalarStyle = token_mod.ScalarStyle;

const yaml_tag_prefix = "tag:yaml.org,2002:";

/// Serializes a document node tree to YAML text (fy-emit port).
pub const Emitter = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    /// Anchored nodes already emitted: re-emission becomes an alias.
    seen: std.AutoHashMap(*const Node, []const u8),
    /// Nodes emitted by the faithful walker (cycle/duplicate guard for
    /// programmatically shared nodes).
    emitted: std.AutoHashMap(*const Node, void),
    /// Active source for faithful emission (empty when normalized).
    src: []const u8 = "",
    indent_step: usize = 2,
    /// True when the caller set `indent_step` explicitly, so faithful
    /// emission must not overwrite it with the source's own convention.
    forced_indent: bool = false,
    /// The scalar last written by `emitScalarValue` was a block with keep
    /// chomping (`|+`, `>+`), which absorbs any blank lines after it into
    /// its value; see `pastKeptBlanks`.
    kept_breaks: bool = false,
    /// Nesting levels currently open. Emission is recursive, so this
    /// bounds native stack use; see `max_depth`.
    depth: usize = 0,
    /// Deepest node nesting this emitter will serialize before returning
    /// `error.NestingTooDeep`.
    ///
    /// A tree built through `createSequence`/`sequenceAppend` or
    /// `value.toNode` has no such bound, and unbounded recursion here is
    /// a stack overflow rather than a typed error. Parsed documents
    /// reach it only through an alias cycle (`&a [*a]`): the scanner's
    /// `max_nesting` (200) caps syntactic nesting, not the alias graph.
    ///
    /// A node is charged more than once only where emission crosses
    /// from one land into another, and a root-to-leaf path crosses at
    /// most two such boundaries: faithful to normalized (`emitContent`
    /// delegating to `emitNode` for a `src == null` block node, which
    /// never calls back), and either of those to flow (`emitFlowBody`,
    /// which only ever calls `emitFlowNode`). The two cannot both apply
    /// to the same node — the first needs a non-empty block collection,
    /// the second a flow or empty one. So charges ≤ real depth + 2, and
    /// the nesting actually admitted is `max_depth - 2`.
    max_depth: usize = 1000,

    /// Emission fails on output allocation, on a programmatic node
    /// graph that cannot be serialized (unanchored cycle), or on one
    /// nested past `max_depth`.
    pub const Error = std.mem.Allocator.Error || diag.YamlError;

    /// Open one nesting level, or fail. Paired with `leave`.
    fn enter(self: *Emitter) Error!void {
        if (self.depth >= self.max_depth) return error.NestingTooDeep;
        self.depth += 1;
    }

    fn leave(self: *Emitter) void {
        // Every caller pairs this with `enter` through `defer`, which
        // holds on the error path too. An unpaired call would wrap.
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
    }

    pub fn init(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) Emitter {
        return .{
            .allocator = allocator,
            .out = out,
            .seen = std.AutoHashMap(*const Node, []const u8).init(allocator),
            .emitted = std.AutoHashMap(*const Node, void).init(allocator),
        };
    }

    pub fn deinit(self: *Emitter) void {
        self.seen.deinit();
        self.emitted.deinit();
    }

    // ------------------------------------------------------------------
    // Output primitives
    // ------------------------------------------------------------------

    fn write(self: *Emitter, bytes: []const u8) Error!void {
        try self.out.appendSlice(self.allocator, bytes);
    }

    fn writeByte(self: *Emitter, b: u8) Error!void {
        try self.out.append(self.allocator, b);
    }

    fn writeIndent(self: *Emitter, indent: usize) Error!void {
        for (0..indent) |_| try self.writeByte(' ');
    }

    fn newlineAt(self: *Emitter, indent: usize) Error!void {
        // A literal block scalar already ends on a fresh line; avoid a blank
        // line in that case.
        if (!self.endsWithNewline()) try self.write(self.defaultTerminator());
        try self.writeIndent(indent);
    }

    /// Is the output currently positioned at the start of a line? All
    /// three YAML line breaks count — a chunk emitted verbatim from a
    /// CR-terminated document ends in `\r`, and treating that as
    /// "no newline yet" made the caller write a second terminator.
    fn endsWithNewline(self: *const Emitter) bool {
        const items = self.out.items;
        if (items.len == 0) return false;
        const last = items[items.len - 1];
        return last == '\n' or last == '\r';
    }

    /// The bytes written since the last line terminator: the partially
    /// built current line. Measured from any break, for the same reason
    /// as `endsWithNewline` — measuring from the last `\n` alone made
    /// the current column wrong across CR-terminated lines, and the
    /// column is what re-emitted blocks are indented against.
    fn pendingLine(self: *const Emitter) []const u8 {
        const items = self.out.items;
        var i = items.len;
        while (i > 0) : (i -= 1) {
            if (items[i - 1] == '\n' or items[i - 1] == '\r') return items[i..];
        }
        return items;
    }

    /// Write the framing bytes a container carries ahead of its first
    /// entry — an outer `- ` indicator when the container is itself a
    /// sequence item. They are normally re-emitted with the first
    /// original entry, so a BRAND-NEW first entry has to claim them.
    /// Returns the gap offset to continue from.
    fn writeContainerFraming(self: *Emitter, container: *const Node, gap_start: usize) Error!usize {
        const cs = container.src orelse return gap_start;
        if (cs.synthetic or gap_start >= cs.start) return gap_start;
        try self.writeGap(container, gap_start, cs.start);
        return cs.start;
    }

    /// An emptied container re-emits as `{}` / `[]` straight from the
    /// tree, which skips the slot walk that would otherwise have
    /// re-emitted its framing along with the first entry. When the
    /// container is a sequence ITEM, that framing is the `- ` indicator
    /// — and without it the item vanishes and the `{}` is left dangling
    /// at the parent's column, which does not parse.
    fn writeEmptiedFraming(self: *Emitter, node: *Node) Error!void {
        const cs = node.src orelse return;
        if (cs.synthetic) return;
        const parent = node.parent orelse return;
        if (parent.kind() != .sequence) return;
        _ = try self.writeContainerFraming(node, cs.entry_start);
    }

    /// An emptied BLOCK collection's source still holds the comment and
    /// blank lines that sat between its deleted entries. Writing `{}` /
    /// `[]` alone ate them (`a: 1\n# note\nb: 2` minus both entries came
    /// back as `{}`), although deleting the entries one at a time kept
    /// the comment. Write what the tombstones leave, each line with its
    /// own indentation, and put the `{}` on a fresh line at the value's
    /// column. Blank lines alone are not worth a line of their own.
    fn writeEmptiedInterior(self: *Emitter, node: *Node, indent: usize) Error!void {
        const cs = node.src orelse return;
        if (cs.synthetic or cs.end <= cs.start) return;
        switch (node.data) {
            .mapping => |m| if (m.style == .flow) return,
            .sequence => |s| if (s.style == .flow) return,
            else => return,
        }
        // Indentation the caller laid down to place the value: the
        // surviving lines carry their own, so it comes back out. A `- `
        // framing is not indentation and stays.
        const pending = self.pendingLine();
        const placed = if (pending.len > 0 and std.mem.indexOfNone(u8, pending, " ") == null) pending.len else 0;
        const before = self.out.items.len;
        try self.writeGap(node, cs.start, cs.end);
        const kept = self.out.items[before..];
        // Only comment lines are worth keeping, and only they are safe
        // to: an entry with a synthesized key (`:` alone) leaves no
        // tombstone behind, so its bytes survive the walk although the
        // entry is gone. Anything but comments and blanks means the
        // interior is not ours to re-emit; blanks alone are not worth
        // a line of their own.
        var worth_keeping = false;
        var lines = std.mem.splitScalar(u8, kept, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0) continue;
            if (t[0] != '#') {
                self.out.shrinkRetainingCapacity(before);
                return;
            }
            worth_keeping = true;
        }
        if (!worth_keeping) {
            self.out.shrinkRetainingCapacity(before);
            return;
        }
        if (placed > 0) {
            const start = before - placed;
            std.mem.copyForwards(u8, self.out.items[start..], self.out.items[before..]);
            self.out.shrinkRetainingCapacity(self.out.items.len - placed);
        }
        if (!self.endsWithNewline()) try self.write(self.defaultTerminator());
        try self.writeIndent(indent);
    }

    /// True when the pending line holds nothing but block-entry framing:
    /// indentation and `- `, `? ` or `: ` indicators. The cursor then
    /// already sits where an entry belongs (`- ` left behind by a deleted
    /// first entry, a nested `- - `, the `: ` of an explicit key's
    /// compact value), so no line break is owed -- breaking there cut
    /// `: - b` into `:` and a mis-indented ` - b` -- and a leading block
    /// written for the entry goes above the whole line.
    fn isEntryFraming(pending: []const u8) bool {
        var i: usize = 0;
        while (i < pending.len and pending[i] == ' ') i += 1;
        while (i < pending.len) {
            if (pending[i] != '-' and pending[i] != '?' and pending[i] != ':') return false;
            i += 1;
            if (i >= pending.len or pending[i] != ' ') return false;
            while (i < pending.len and pending[i] == ' ') i += 1;
        }
        return true;
    }

    /// Open a line at `col` for a BRAND-NEW block entry, whose layout
    /// the emitter owns. The gap before it may have supplied the
    /// indentation already, none of it (the original indentation went
    /// with a deleted sibling's tombstone), or a whole previous entry.
    /// Returns true when the entry lands on a line the previous entry
    /// had already terminated — nothing downstream will close this one,
    /// so the entry owes its own line terminator. Without it the entry
    /// borrows the NEXT line's newline and swallows a blank separator.
    fn openEntryLine(self: *Emitter, col: usize) Error!bool {
        const pending = self.pendingLine();
        // Fresh line with nothing on it: the indentation is ours to write.
        if (pending.len == 0) {
            try self.writeIndent(col);
            return true;
        }
        // Indentation, or an indicator left by a deleted entry, already
        // in place: keep the original bytes.
        if (isEntryFraming(pending)) return false;
        try self.write(self.defaultTerminator());
        try self.writeIndent(col);
        return false;
    }

    /// A block entry starts its own line. Called once its leading gap is
    /// written, this restores the line break when the gap could not: a
    /// deleted first entry's tombstone swallows the line terminator that
    /// would have separated a replacement from the next sibling.
    /// The break goes BEFORE the indentation the gap already wrote, so
    /// the entry keeps its original column byte for byte.
    fn breakBeforeEntry(self: *Emitter, col: usize) Error!void {
        const pending = self.pendingLine();
        if (pending.len == 0) return; // already at a fresh line
        // Indentation, or an indicator a deleted entry left behind: the
        // cursor is already where this entry goes.
        if (isEntryFraming(pending)) return;
        var k = pending.len;
        while (k > 0 and pending[k - 1] == ' ') k -= 1;
        if (k == pending.len) {
            // No indentation was written either: supply the whole prefix.
            try self.write(self.defaultTerminator());
            return self.writeIndent(col);
        }
        try self.out.insert(self.allocator, self.out.items.len - (pending.len - k), '\n');
    }

    // ------------------------------------------------------------------
    // Document level
    // ------------------------------------------------------------------

    /// Layout choices for content the emitter lays out itself: nodes
    /// with no source bytes to copy — a whole document you built, or a
    /// new subtree inside a parsed one. It cannot affect bytes that are
    /// re-emitted verbatim, which is the point of those bytes.
    pub const Options = struct {
        /// Spaces per nesting level. Null measures the document's own
        /// convention and falls back to 2, which is what a parsed
        /// document wants: a new subtree should match the file it lands
        /// in, not the emitter's taste. Set it for a document you built
        /// from nothing, where there is no convention to measure.
        /// Clamped to 1..8.
        indent: ?usize = null,

        /// Nesting past which emission fails rather than recursing.
        /// See `Emitter.max_depth`.
        max_depth: usize = 1000,
    };

    /// Apply `options` to this emitter.
    pub fn configure(self: *Emitter, options: Options) void {
        if (options.indent) |n| self.indent_step = @min(@max(n, 1), 8);
        self.forced_indent = options.indent != null;
        self.max_depth = options.max_depth;
    }

    /// Serialize `doc` into the output list. Parsed documents re-emit
    /// byte-faithfully outside modified slots; programmatic documents
    /// emit normalized.
    pub fn emitDocument(self: *Emitter, doc: *const Document) Error!void {
        if (doc.source) |src| {
            self.src = src;
            defer self.src = "";
            return self.emitFaithful(doc);
        }

        var have_directives = false;
        if (doc.version) |v| {
            var buf: [32]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "%YAML {d}.{d}\n", .{ v.major, v.minor }) catch unreachable;
            try self.write(line);
            have_directives = true;
        }
        for (doc.tag_directives.items) |td| {
            // Piecewise: handles/prefixes are user-supplied and may be
            // arbitrarily long.
            try self.write("%TAG ");
            try self.write(td.handle);
            try self.writeByte(' ');
            try self.write(td.prefix);
            try self.write(self.defaultTerminator());
            have_directives = true;
        }

        const root = doc.root orelse {
            if (have_directives) try self.write("---\n");
            return;
        };

        if (have_directives or doc.explicit_start) try self.write("---\n");
        try self.emitNode(root, 0);
        if (!self.endsWithNewline()) try self.write(self.defaultTerminator());
        if (doc.explicit_end) try self.write("...\n");
    }

    // ------------------------------------------------------------------
    // Faithful emission: unmodified subtrees re-emit verbatim.
    //
    // Contract: slot emitters (`emitPair`, `emitItem`) receive the
    // source offset where the *gap* into their entry begins (just past
    // the previous entry's original bytes) and return the offset where
    // the next gap starts. Gaps are verbatim source bytes with removed
    // entries tombstoned, so comments, blank lines and indentation
    // between surviving entries survive edits byte for byte.
    // ------------------------------------------------------------------

    fn emitFaithful(self: *Emitter, doc: *const Document) Error!void {
        const src = self.src;
        // Adopt the document's indentation convention before emitting
        // anything, so new subtrees match the file they land in. Bounded
        // because a pathological source (or a tab-indented one measured
        // in columns) must not make the emitter write absurd runs of
        // spaces; two is the YAML house default when unmeasurable.
        if (!self.forced_indent) {
            if (doc.root) |root| {
                if (self.inferIndentStep(root, 0)) |step| {
                    self.indent_step = @min(@max(step, 1), 8);
                }
            }
        }
        // The head is verbatim, except for tombstones: a leading comment
        // block rewritten on the first entry lives here, and the root
        // container's tombstone list is what removes the old lines.
        if (doc.root) |root| {
            if (root.src != null) {
                try self.writeGap(root, doc.region_start, doc.body_start);
            } else {
                try self.write(src[doc.region_start..doc.body_start]);
            }
        } else {
            try self.write(src[doc.region_start..doc.body_start]);
        }
        var stop = doc.body_start;
        if (doc.root) |root| {
            // A leading block written on the root: its old lines were
            // tombstoned out of the head above, and nothing else writes
            // the new ones -- the root has no entry slot of its own.
            const col = markup.columnOf(src, doc.body_start);
            if (root.pending_leading) |pt| try self.writePendingLeadingText(pt, col, self.terminatorAt(doc.body_start));
            stop = try self.emitRoot(root, col, doc.body_end);
        }
        if (stop < doc.region_end) {
            // Deleted-entry tombstones of the root container can reach
            // into the tail (when the last surviving entry is new).
            const before = self.out.items.len;
            if (doc.root != null and doc.root.?.src != null) {
                // A tombstone can consume the terminator that separated
                // the document's last emission from a surviving tail
                // comment — deleting the only real entry of a document
                // with a trailing comment emitted `{}# delta`, which
                // does not parse. When the first LIVE tail byte is a
                // comment and the cursor is mid-line, re-own the break.
                // (Surfaced when `parse` stopped dropping the tail.)
                if (!self.endsWithNewline() and
                    self.firstLiveTailByte(doc.root.?, stop, doc.region_end) == '#')
                {
                    try self.write(self.defaultTerminator());
                }
                try self.writeGap(doc.root.?, stop, doc.region_end);
            } else {
                try self.write(src[stop..doc.region_end]);
            }
            // If everything remaining was deleted, the file's final
            // newline is still structural: keep the output terminated.
            if (self.out.items.len == before and self.out.items.len > 0 and
                self.out.items[self.out.items.len - 1] != '\n' and
                src.len > 0 and src[src.len - 1] == '\n')
            {
                try self.write(self.defaultTerminator());
            }
        }
    }

    /// Emit the root node; returns the source offset where the document
    /// tail begins. `orig_end` is the original root extent, used when
    /// the root was replaced by a programmatic node.
    fn emitRoot(self: *Emitter, node: *Node, indent: usize, orig_end: usize) Error!usize {
        const s = node.src orelse {
            // Root replaced by a programmatic node: emit normalized and
            // keep the original tail.
            _ = try self.emitContent(node, indent);
            return orig_end;
        };
        if (s.synthetic) return s.end; // empty document: head/tail only
        if (try self.writeCleanSlice(node, s.entry_start)) |end| return end;
        switch (node.data) {
            // Modified scalar/alias: re-emit content, then the original
            // line remainder (or a written trailing comment) and tail
            // from there.
            .scalar, .alias => {
                _ = try self.emitContent(node, indent);
                if (self.kept_breaks and self.endsWithNewline()) {
                    return self.pastKeptBlanks(node, markup.lineEnd(self.src, s.end));
                }
                return self.writeEntryTail(node, s.end);
            },
            // Modified container: its slot walk consumes through the
            // last entry's line end.
            else => return self.emitContent(node, indent),
        }
    }

    /// A block scalar's token can swallow trailing empty lines the
    /// chomping then discards or keeps as value; its slot ends before
    /// them, so they sit at the start of the next entry's gap. A
    /// BRAND-NEW entry must write them BEFORE itself — they are the
    /// block's kept trailing breaks or its separator — or they end up
    /// after it and a keep-chomped block loses its content (corpus
    /// K858, found by the preservation sweep). Returns the advanced gap
    /// offset. Only fires when the sibling ending at `gap` is a block
    /// scalar; blanks after other scalars stay separator-in-the-gap.
    fn consumeBlockTrailingBlanks(self: *Emitter, container: *const Node, gap: usize) Error!usize {
        const src = self.src;
        var prev_value: ?*const Node = null;
        switch (container.data) {
            .mapping => |m| for (m.pairs.items) |p| {
                if (p.value.src) |vs| {
                    if (vs.end <= gap) prev_value = p.value;
                }
            },
            .sequence => |sq| for (sq.items.items) |it| {
                if (it.src) |is| {
                    if (is.end <= gap) prev_value = it;
                }
            },
            else => {},
        }
        const v = prev_value orelse return gap;
        if (v.kind() != .scalar) return gap;
        if (v.data.scalar.style != .literal and v.data.scalar.style != .folded) return gap;

        var g = gap;
        while (g < src.len) {
            const nl = markup.newlineAt(src, g);
            if (nl < g) break; // never slice inverted (defensive)
            if (nl == g) {
                // The cursor sits ON a line break: an empty line, which
                // the blank run consumes like any other.
                g = g + 1;
                continue;
            }
            if (std.mem.indexOfNone(u8, src[g..nl], " \t\r") != null) break; // content line
            g = if (nl < src.len) nl + 1 else src.len;
        }
        if (g > src.len) g = src.len;
        if (g > gap) {
            try self.write(src[gap..g]);
            return g;
        }
        return gap;
    }

    /// Emit a mapping entry. `gap_start` is where this entry's leading
    /// gap begins in the source; returns where the next gap begins.
    fn emitPair(self: *Emitter, container: *const Node, pair: Pair, entry_col: usize, gap_start: usize) Error!usize {
        const src = self.src;
        const key = pair.key;
        const value = pair.value;

        // Fast path: the whole entry is original and untouched.
        if (self.nodeClean(key) and self.nodeClean(value)) {
            if (pair.src_end) |pend| {
                try self.emitted.put(key, {});
                try self.emitted.put(value, {});
                try self.writeGap(container, gap_start, key.src.?.entry_start);
                try self.breakBeforeEntry(entry_col);
                try self.write(src[key.src.?.entry_start..pend]);
                return pend;
            }
        }
        return self.emitPairEdited(container, pair, entry_col, gap_start);
    }

    /// Re-emission path for a mapping entry that gained, lost or
    /// changed content.
    fn emitPairEdited(self: *Emitter, container: *const Node, pair: Pair, entry_col: usize, gap_start: usize) Error!usize {
        const src = self.src;
        const key = pair.key;
        const value = pair.value;
        const ks = key.src;
        // A key with bytes of its own. Whether they can be copied is
        // `nodeClean`'s call, as for any value: a key given an anchor or
        // tag after parsing is modified, and its old bytes would drop it.
        const key_spanned = ks != null and !ks.?.synthetic;
        const pair_end = pair.src_end;
        const value_empty = pairEndsAtColon(pair);

        // Leading gap: original bytes up to the entry's key. Brand-new
        // pairs derive their own newline + column instead and leave the
        // gap anchor untouched for the next original sibling.
        if (ks) |s| {
            if (!s.synthetic) {
                // A written leading block replaces the entry's own
                // lines (the tombstoned old block is skipped in the
                // gap). The gap runs up to the key as usual, leaving the
                // entry's line begun -- indentation and any outer `- `
                // -- and the block writer lifts that above the new
                // lines. The key's own framing is written below from
                // entry_start; re-assembling the line here as well
                // doubled it (`- - k: v`, `? ? k`), and stopping the gap
                // at the line start lost an item's `- ` before `? k`.
                try self.writeGap(container, gap_start, s.entry_start);
                const pending = internal.pairLeadingOverride(src, key, value);
                if (pending != null) {
                    const col = markup.columnOf(src, s.entry_start);
                    try self.writePendingLeadingText(pending, col, self.terminatorAt(s.entry_start));
                }
                try self.breakBeforeEntry(entry_col);
            } else {
                // A SYNTHETIC key has no bytes of its own — its span is
                // a point borrowed from the following token — but the
                // entry still occupies a line, and the gap in front of
                // that point is real: it holds the terminator that
                // separates this entry from the previous one.
                //
                // Skipping the gap entirely (which is what this branch
                // used to do by falling through) dropped that
                // terminator as soon as any sibling was deleted, so
                // `a: 1\nb:\n  - y: z\n: 1\n` minus `$.a` emitted
                // `b:\n  - y: z: 1\n` — two lines joined into one, and
                // output this library cannot reparse. Only the edited
                // path reaches here; an untouched region is emitted
                // verbatim in one slice.
                try self.writeGap(container, gap_start, s.entry_start);
                // With no key bytes, the value holds the entry line's
                // written block (`: a`); it was accepted and never
                // written.
                if (internal.pairLeadingOverride(src, key, value)) |pt| {
                    try self.writePendingLeadingText(pt, markup.columnOf(src, s.entry_start), self.terminatorAt(s.entry_start));
                }
                try self.breakBeforeEntry(entry_col);
            }
        } else if (pair_end == null) {
            // Brand-new pair. While the previous entry's line is still
            // open, its remainder — a trailing comment, or plain
            // trailing blanks — belongs to THAT entry: write it before
            // opening a line of our own, or the new entry slots in
            // ahead of it and the next sibling's gap re-attaches the
            // bytes to the wrong line.
            var gap = gap_start;
            var owed_terminator = false;
            // "Still open" means a previous ENTRY is on the pending
            // line — not that the output happens not to end in a
            // newline. Nothing written yet, or only indentation and
            // `- ` framing, is this entry's own line, and the source
            // bytes ahead of the gap are then the container's FIRST
            // line: when every original entry was deleted, that line
            // is a tombstone. Copying it verbatim resurrected the
            // deleted entry (`a: 1` minus `$.a` plus `$.b` came back as
            // `a: 1\nb: Z\n`), and at the first item of a sequence
            // glued the new key after the old one, which did not parse.
            // The remainder is written through the tombstone-aware gap
            // walk for the same reason.
            const open = self.pendingLine();
            if (open.len > 0 and !isEntryFraming(open) and markup.newlineAt(src, gap) > gap) {
                const le = markup.lineEnd(src, gap);
                try self.writeGap(container, gap, le);
                gap = le;
                // The remainder took the line terminator along with it
                // (or a tombstone did); this entry now owes the line
                // ending either way.
                owed_terminator = true;
            }
            gap = try self.writeContainerFraming(container, gap);
            gap = try self.consumeBlockTrailingBlanks(container, gap);
            const pending = internal.pairLeadingOverride(src, key, value);
            if (pending != null) {
                // Written lines terminate themselves and end with the
                // indentation the entry continues on.
                try self.writePendingLeadingText(pending, entry_col, self.terminatorAt(gap));
                owed_terminator = true;
            } else if (try self.openEntryLine(entry_col)) {
                owed_terminator = true;
            }
            try self.emitEntry(key, value, entry_col);
            if (value.pending_trailing) |tt| {
                if (tt.len > 0) {
                    try self.writeByte(' ');
                    try self.write(tt);
                }
            }
            if (owed_terminator and !self.endsWithNewline()) try self.write(self.defaultTerminator());
            return gap;
        }

        // Key. `key_end` is where the source bytes after it begin: a
        // re-emitted block collection key's walk consumes through its
        // last entry's line break, which the gap to the value must not
        // write again (a blank line before `: v`).
        const expl = key_spanned and explicitKeySpan(src, ks.?.entry_start, ks.?.start);
        var key_end: usize = if (ks) |s| s.end else 0;
        if (key_spanned and self.nodeClean(key)) {
            try self.emitted.put(key, {});
            try self.write(src[ks.?.entry_start..ks.?.end]);
        } else {
            try self.emitted.put(key, {});
            // A modified key keeps its framing -- the `- ` or `? ` in
            // [entry_start, start) -- and re-emits only its content. A
            // block collection key's own walk writes that framing with
            // its first entry, as for items (`? ? - a` otherwise).
            if (key_spanned and !framingOwnedByContent(key)) try self.write(src[ks.?.entry_start..ks.?.start]);
            const stop = try self.emitKeyContent(key, if (ks) |s| markup.columnOf(src, s.start) else entry_col, expl);
            if (key_spanned and stop > key_end) key_end = stop;
        }

        // Valueless entry (`key:` / `? key`): emit the original colon
        // bytes and stop.
        if (value_empty) {
            if (ks != null and pair_end != null) {
                try self.write(src[@min(key_end, pair_end.?)..pair_end.?]);
                return self.writeEntryTail(value, pair_end.?);
            }
            try self.writeByte(':');
            if (pair_end) |pe| return self.writeEntryTail(value, pe);
            return gap_start;
        }

        // Colon bytes between key and value, then the value itself.
        if (value.src) |vs| {
            if (!vs.synthetic) {
                // Original layout (": " or a block ":\n    "). For a
                // block value these bytes carry its FIRST entry's
                // indentation, so they must honor that container's
                // tombstones: deleting the first child otherwise leaves
                // the indent behind for the new first child to add its
                // own on top of (2 -> 4).
                //
                // Unless every entry is gone. A surviving entry arrives
                // carrying its own indentation, which is what makes the
                // tombstone the right answer above; an emptied
                // container has no successor to carry anything, so the
                // `{}` / `[]` standing in for it would be written
                // wherever the cursor happens to sit -- column 0, where
                // it is no longer the value of its key and no longer
                // parses. These bytes place the VALUE; only their
                // overlap with the first entry ever belonged to that
                // entry.
                if (ks) |s| {
                    if (emptiedCollection(value)) {
                        try self.write(src[key_end..vs.entry_start]);
                        try self.indentEmptied(markup.columnOf(src, s.entry_start));
                    } else if (value.pending_leading != null and
                        markup.lineStart(src, vs.entry_start) != markup.lineStart(src, s.start))
                    {
                        // A written leading block for a BLOCK value
                        // replaces the comment lines between the key's
                        // colon and the value's first line (tombstoned
                        // out of the gap), and goes above the value's
                        // line, which the gap has begun: its indentation,
                        // and for an explicit key's value the `: `
                        // indicator, which stopping the gap at the line
                        // start dropped. (An inline value's block belongs
                        // to the pair and was already written at the
                        // key's gap.)
                        try self.writeGap(value, key_end, vs.entry_start);
                        const vcol = markup.columnOf(src, vs.entry_start);
                        try self.writePendingLeadingText(value.pending_leading, vcol, self.terminatorAt(vs.entry_start));
                    } else {
                        try self.writeGap(value, key_end, vs.entry_start);
                    }
                }
                if (try self.writeCleanSlice(value, vs.entry_start)) |vend| {
                    return self.writeEntryTail(value, pair_end orelse vend);
                }
                const stop = try self.emitContent(value, markup.columnOf(src, vs.start));
                // A container walk that reached the line end already
                // consumed the terminator; deeper slots must not write
                // it twice. A re-emitted block scalar closes its own
                // line with its chomping break.
                const base = pair_end orelse vs.end;
                const le = markup.lineEnd(src, base);
                if (stop >= le) return stop;
                if (self.endsWithNewline()) return self.pastKeptBlanks(value, le);
                // Write the remainder of the line the walk actually
                // stopped on — when the value's LAST entry was deleted,
                // `base` sits on a tombstoned line whose remainder is
                // that entry's trailing comment, and writing it would
                // overwrite the surviving entry's own. `stop` only says
                // where the next gap starts, so it is usable just when
                // it points at live bytes: after a brand-new last entry
                // it still sits inside the deleted entry's text.
                const from = if (stop < base and !dropCovers(value, stop)) stop else base;
                _ = try self.writeEntryTail(value, from);
                // Advance past the value's original extent either way,
                // so the tombstoned tail is not re-emitted.
                return le;
            }
            // Replaced by an empty value node: normalized colon. An
            // explicit key needs none — `? key` is already the whole
            // entry — and `? key: ` would not parse.
            if (!expl) try self.write(": ");
            _ = try self.emitContent(value, entry_col + self.indent_step);
            if (pair_end) |pe| return self.writeEntryTail(value, pe);
            return gap_start;
        }
        // Brand-new value: layout by its shape.
        if (expl) {
            // `? key` gaining a value it did not have: the value
            // indicator goes on its own line at the indicator column.
            // Writing ": value" after the key text would emit
            // `? key: value`, which is not YAML.
            const icol = markup.columnOf(src, ks.?.entry_start);
            try self.writeNewlineIndent(icol);
            try self.write(": ");
            _ = try self.emitContent(value, icol + self.indent_step);
        } else if (inlineValue(value)) {
            try self.write(": ");
            _ = try self.emitContent(value, entry_col + self.indent_step);
        } else {
            try self.writeByte(':');
            try self.writeNewlineIndent(entry_col + self.indent_step);
            _ = try self.emitContent(value, entry_col + self.indent_step);
        }
        // A re-emitted block scalar closed its own line with its
        // chomping break; only advance the gap anchor.
        if (pair_end) |pe| {
            const le = markup.lineEnd(src, pe);
            if (self.endsWithNewline()) return self.pastKeptBlanks(value, le);
            return self.writeEntryTail(value, pe);
        }
        return gap_start;
    }

    /// Emit a sequence item slot; same gap contract as `emitPair`.
    fn emitItem(self: *Emitter, container: *const Node, item: *Node, entry_col: usize, gap_start: usize) Error!usize {
        const src = self.src;
        const s = item.src orelse {
            // Brand-new or moved item: sibling-local indentation. The
            // previous entry's trailing comment belongs to it (see the
            // brand-new pair case in `emitPairEdited`) — but only an
            // ORIGINAL sibling BEFORE this one owns the bytes at
            // `gap_start`. An item spliced ahead of every original
            // item finds `gap_start` on the SUCCESSOR's line, and
            // taking its remainder here would emit that line ahead
            // of itself and duplicate it later.
            var has_original_prev = false;
            if (container.data == .sequence) {
                for (container.data.sequence.items.items) |it| {
                    if (it == item) break;
                    if (it.src) |is| {
                        if (!is.synthetic) {
                            has_original_prev = true;
                            break;
                        }
                    }
                }
            }
            var gap = gap_start;
            var owed_terminator = false;
            if (has_original_prev and !self.endsWithNewline() and markup.newlineAt(src, gap) > gap) {
                gap = try self.writeRemainder(gap);
                owed_terminator = true; // see the pair case
            }
            gap = try self.writeContainerFraming(container, gap);
            gap = try self.consumeBlockTrailingBlanks(container, gap);
            if (item.pending_leading) |pt| {
                // Written lines terminate themselves and end with the
                // indentation the entry continues on.
                try self.writePendingLeadingText(pt, entry_col, self.terminatorAt(gap));
                owed_terminator = true;
            } else if (try self.openEntryLine(entry_col)) {
                owed_terminator = true;
            }
            try self.write("- ");
            _ = try self.emitContent(item, entry_col + 2);
            if (item.pending_trailing) |tt| {
                if (tt.len > 0) {
                    try self.writeByte(' ');
                    try self.write(tt);
                }
            }
            if (owed_terminator and !self.endsWithNewline()) try self.write(self.defaultTerminator());
            return gap;
        };
        if (self.emitted.contains(item)) {
            if (item.anchor) |a| {
                try self.writeGap(container, gap_start, s.entry_start);
                try self.breakBeforeEntry(entry_col);
                try self.writeByte('*');
                try self.write(a);
                return markup.lineEnd(src, s.end);
            }
            return error.AliasCycle;
        }
        // A written leading block replaces the item's own comment lines
        // (tombstoned out of the gap) and goes above the item's line,
        // which the gap has begun; the block writer lifts that above the
        // new lines (see the pair case). The item's `- ` is then written
        // by the rule below and nowhere else: re-assembling it here as
        // well doubled it for a block collection item, whose first entry
        // carries it (`- - name: x`).
        try self.writeGap(container, gap_start, s.entry_start);
        if (item.pending_leading != null) {
            const col = markup.columnOf(src, s.entry_start);
            try self.writePendingLeadingText(item.pending_leading, col, self.terminatorAt(s.entry_start));
        }
        try self.breakBeforeEntry(entry_col);
        if (!s.synthetic) {
            if (try self.writeCleanSlice(item, s.entry_start)) |end| return end;
            try self.emitted.put(item, {});
            // [entry_start, start) is the item's `- ` framing. A block
            // collection's slot walk re-emits it (the walk starts at
            // entry_start, and its first entry carries the indicator),
            // and the emptied-collection path writes it on its own.
            // Everything else -- a scalar, an alias, a flow collection
            // with entries -- is emitted from `start`, so the indicator
            // went missing and the item stopped being one: `- {a: 1}`
            // with `$[0].a` set wrote `{a: Z}` at the parent's column,
            // and a refilled `- {}` did not parse at all.
            if (!framingOwnedByContent(item)) {
                try self.write(src[s.entry_start..s.start]);
            }
            const stop = try self.emitContent(item, markup.columnOf(src, s.start));
            // A container walk that re-emitted its last entry already
            // consumed the line terminator; writing the remainder on top
            // of that would append a blank line after the item.
            const le = markup.lineEnd(src, s.end);
            if (stop >= le) return stop;
            if (self.endsWithNewline()) return self.pastKeptBlanks(item, le);
            return self.writeEntryTail(item, s.end);
        }
        // Synthesized empty item: the entry shell only.
        try self.emitted.put(item, {});
        try self.write(src[s.entry_start..s.start]);
        return s.end;
    }

    /// Where the next gap starts after `node` was re-emitted, given the
    /// offset `le` its original line ended at. A block written with keep
    /// chomping already holds all its trailing line breaks, and would
    /// absorb any blank line after it into its value -- the source's own
    /// blank lines there, which were the old block's kept breaks, then
    /// doubled them on every edit (`keep\n\n` read back `keep\n\n\n`).
    /// So those are skipped.
    fn pastKeptBlanks(self: *const Emitter, node: *const Node, le: usize) usize {
        if (node.data != .scalar or !self.kept_breaks) return le;
        var i = le;
        while (i < self.src.len) {
            const next = markup.lineEnd(self.src, i);
            if (next == i or !ctype.isBlankRun(self.src[i..next])) break;
            i = next;
        }
        return i;
    }

    /// A mapping key's own content, under the rules for keys. An
    /// implicit key is one line, so a scalar key is never a block
    /// scalar there; `emitContent` would write a multi-line key as `|-`
    /// and its lines, which reads back as a different mapping. An
    /// explicit key (`? `) takes any form.
    /// Returns what `emitContent` does: the source offset its bytes
    /// reach (a scalar's end, a container walk's stop).
    fn emitKeyContent(self: *Emitter, key: *Node, col: usize, explicit: bool) Error!usize {
        switch (key.data) {
            .scalar => |s| {
                if (try self.writeProperties(key)) try self.writeByte(' ');
                try self.emitScalarValue(s.value, s.style, col, explicit, false);
                return if (key.src) |ks| ks.end else 0;
            },
            else => return self.emitContent(key, col),
        }
    }

    /// Emit a node's own content (properties + body) at the cursor.
    /// Modified block containers walk their slots so untouched entries
    /// stay verbatim; everything else re-emits normalized.
    fn emitContent(self: *Emitter, node: *Node, indent: usize) Error!usize {
        try self.enter();
        defer self.leave();
        switch (node.data) {
            .scalar => |s| {
                const props = try self.writeProperties(node);
                if (props) try self.writeByte(' ');
                try self.emitScalarValue(s.value, s.style, indent, true, false);
                return if (node.src) |sn| sn.end else 0;
            },
            .alias => |a| {
                try self.writeByte('*');
                try self.write(a.name);
                return if (node.src) |sn| sn.end else 0;
            },
            .mapping => |*m| {
                if (m.style == .flow or m.pairs.items.len == 0) {
                    // Flow-styled in the source, or emptied in place:
                    // block layout cannot express an empty mapping.
                    if (m.pairs.items.len == 0) {
                        try self.writeEmptiedFraming(node);
                        try self.writeEmptiedInterior(node, indent);
                    }
                    if (self.flowLayoutRecoverable(node)) {
                        try self.emitFlowFaithful(node);
                        return node.src.?.end;
                    }
                    try self.emitFlowNode(node);
                    // The line terminator was not consumed.
                    return if (node.src) |sn| sn.end else 0;
                }
                if (node.src == null) {
                    // Brand-new or moved block mapping: no source bytes
                    // describe it, so its layout is the emitter's to
                    // choose -- and block is what the surrounding
                    // document is written in. One-line flow here would
                    // be valid but alien to the file.
                    try self.emitNode(node, indent);
                    return 0;
                }
                // The walk starts at `entry_start`, not `start`: a
                // mapping that is a sequence item carries the `- `
                // indicator in those leading bytes. They are normally
                // re-emitted with the first entry, but when that entry
                // is deleted the next one must pick them up.
                var gap = node.src.?.entry_start;
                const col = self.entryColumn(node, indent);
                for (m.pairs.items) |pair| {
                    gap = try self.emitPair(node, pair, col, gap);
                }
                return gap;
            },
            .sequence => |*sq| {
                if (sq.style == .flow or sq.items.items.len == 0) {
                    if (sq.items.items.len == 0) {
                        try self.writeEmptiedFraming(node);
                        try self.writeEmptiedInterior(node, indent);
                    }
                    if (self.flowLayoutRecoverable(node)) {
                        try self.emitFlowFaithful(node);
                        return node.src.?.end;
                    }
                    try self.emitFlowNode(node);
                    // The line terminator was not consumed.
                    return if (node.src) |sn| sn.end else 0;
                }
                if (node.src == null) {
                    // Brand-new or moved block sequence: see the
                    // mapping arm above.
                    try self.emitNode(node, indent);
                    return 0;
                }
                var gap = node.src.?.entry_start; // see the mapping case
                const col = self.entryColumn(node, indent);
                for (sq.items.items) |item| {
                    gap = try self.emitItem(node, item, col, gap);
                }
                return gap;
            },
        }
    }

    /// True when a pair's value is a synthesized empty node (`key:` with
    /// nothing after the colon, or an explicit-key-only pair).
    fn pairEndsAtColon(pair: Pair) bool {
        const v = pair.value;
        if (v.kind() != .scalar) return false;
        if (v.data.scalar.value.len != 0) return false;
        const vs = v.src orelse return false;
        return vs.synthetic;
    }

    /// Indent an emptied collection's `{}` / `[]` deeper than the key it
    /// belongs to, when the preserved placement would not be.
    ///
    /// A block sequence is allowed to sit at its parent key's own column:
    ///
    ///     ports:
    ///     - containerPort: 80
    ///
    /// (the k8s and mkdocs house style). Its ENTRIES are legal there --
    /// a `- ` indicator is unambiguous at any column >= the key's. The
    /// `{}` / `[]` replacing them is not: it is a FLOW node, and a flow
    /// value sitting at its key's column reads as the key's SIBLING, so
    /// the document stops parsing. Nothing is being preserved once the
    /// collection is empty, so step it in far enough to be read as the
    /// value it is.
    fn indentEmptied(self: *Emitter, key_col: usize) Error!void {
        const pending = self.pendingLine();
        // Only when the placement left us on a fresh line: a value still
        // sharing the key's line is already unambiguous.
        if (pending.len > 0 and std.mem.indexOfNone(u8, pending, " ") != null) return;
        if (pending.len > key_col) return;
        try self.writeIndent(key_col + self.indent_step - pending.len);
    }

    /// True when re-emitting `node`'s content also re-emits the framing
    /// bytes ahead of it ([entry_start, start), a sequence item's `- `):
    /// a block collection's slot walk starts at entry_start, and an
    /// emptied collection writes its framing explicitly. A scalar, an
    /// alias, or a flow collection with entries is written from `start`.
    fn framingOwnedByContent(node: *const Node) bool {
        return switch (node.data) {
            .mapping => |m| m.style != .flow or m.pairs.items.len == 0,
            .sequence => |s| s.style != .flow or s.items.items.len == 0,
            .scalar, .alias => false,
        };
    }

    /// A collection every entry of which has been removed. It re-emits
    /// as `{}` / `[]` (block layout cannot express an empty collection),
    /// so no entry follows to supply the indentation that places it
    /// after its key -- the gap bytes have to.
    fn emptiedCollection(node: *const Node) bool {
        return switch (node.data) {
            .mapping => |m| m.pairs.items.len == 0,
            .sequence => |s| s.items.items.len == 0,
            else => false,
        };
    }

    /// An empty plain scalar: YAML's null, which is written as the
    /// absence of a value rather than as any text.
    fn isNullScalar(node: *const Node) bool {
        if (node.anchor != null or node.tag != null) return false;
        return switch (node.data) {
            .scalar => |s| s.value.len == 0 and s.style == .plain,
            else => false,
        };
    }

    /// True when a value can sit on the same line as its key.
    fn inlineValue(value: *const Node) bool {
        return switch (value.data) {
            .scalar, .alias => true,
            .mapping => |m| m.pairs.items.len == 0 or m.style == .flow,
            .sequence => |s| s.items.items.len == 0 or s.style == .flow,
        };
    }

    /// Column where a container's entries sit: derived from the first
    /// original child, falling back to `fallback` + one indent step.
    /// Column of a block container's first original entry, or null when
    /// the node is not a block container or nothing in it came from the
    /// source. Unlike `entryColumn` this never invents a fallback --
    /// callers that need to know whether the source actually says
    /// anything use this one.
    fn originalEntryColumn(self: *const Emitter, node: *const Node) ?usize {
        switch (node.data) {
            .mapping => |m| {
                if (m.style == .flow) return null;
                for (m.pairs.items) |pair| {
                    if (pair.key.src) |s| {
                        if (!s.synthetic) return markup.columnOf(self.src, s.entry_start);
                    }
                }
            },
            .sequence => |sq| {
                if (sq.style == .flow) return null;
                for (sq.items.items) |item| {
                    if (item.src) |is| {
                        if (!is.synthetic) return markup.columnOf(self.src, is.entry_start);
                    }
                }
            },
            else => {},
        }
        return null;
    }

    /// The document's own indentation convention, measured as the first
    /// nested block container's entry column minus the column of the key
    /// that owns it. A brand-new or moved subtree adopts this, so an
    /// insert into a four-space file does not arrive wearing two-space
    /// indentation. Null when the document nests nowhere and there is
    /// nothing to measure.
    fn inferIndentStep(self: *const Emitter, node: *const Node, depth: usize) ?usize {
        // Bounded like the emission walk: this measurement runs BEFORE
        // the depth-checked walk, so unbounded recursion here segfaulted
        // on a deep grafted subtree (a 60k-deep sequence reached the
        // emitter through `Editor.set`) instead of letting the walk
        // return `error.NestingTooDeep`. It is only a measurement, so
        // giving up returns null and the walk reports the bound.
        if (depth >= self.max_depth) return null;
        switch (node.data) {
            .mapping => |m| {
                for (m.pairs.items) |pair| {
                    const ks = pair.key.src orelse continue;
                    if (ks.synthetic) continue;
                    const key_col = markup.columnOf(self.src, ks.entry_start);
                    if (self.originalEntryColumn(pair.value)) |child_col| {
                        // A block value on the SAME line as its key (a
                        // compact `- name: a`) measures nothing.
                        if (child_col > key_col) return child_col - key_col;
                    }
                    if (self.inferIndentStep(pair.value, depth + 1)) |d| return d;
                }
            },
            .sequence => |sq| {
                for (sq.items.items) |item| {
                    if (self.inferIndentStep(item, depth + 1)) |d| return d;
                }
            },
            else => {},
        }
        return null;
    }

    /// True when the bytes between a key's entry start and its text are
    /// an explicit key indicator: framing plus `? `. For an explicit
    /// key the span's `entry_start` sits ON the `?` and `start` just
    /// past it; a plain sequence item's framing (`- `) carries no `?`.
    fn explicitKeySpan(src: []const u8, from: usize, to: usize) bool {
        if (to <= from) return false;
        var saw_q = false;
        for (src[from..to]) |c| switch (c) {
            ' ', '\t', '\n', '\r', '-' => {},
            '?' => saw_q = true,
            else => return false,
        };
        return saw_q;
    }

    fn entryColumn(self: *Emitter, node: *Node, fallback: usize) usize {
        const src = self.src;
        switch (node.data) {
            .mapping => |m| {
                for (m.pairs.items) |pair| {
                    if (pair.key.src) |s| {
                        // `start`, not `entry_start`. A mapping that is a
                        // sequence item carries the `- ` indicator in its
                        // FIRST pair's leading bytes, so `entry_start`
                        // there is the indicator's column, one step out
                        // from where the keys actually sit. Measuring
                        // from it puts every brand-new key at the
                        // sequence's column instead of the mapping's --
                        // `steps:` / `  - name: build` / `  shell: bash`
                        // -- which reads as a sibling of the list and
                        // does not parse. Keys sit at `start`.
                        if (!s.synthetic) {
                            // An EXPLICIT-key entry (`? key`) is the one
                            // case where the text column is not the entry
                            // column: its key text sits one step in from
                            // the line's indentation, and a brand-new
                            // plain key written there would land inside
                            // the previous explicit entry's value slot.
                            // Entries live at the indicator's column.
                            if (explicitKeySpan(src, s.entry_start, s.start)) {
                                return markup.columnOf(src, s.entry_start);
                            }
                            return markup.columnOf(src, s.start);
                        }
                    }
                }
            },
            .sequence => |s| {
                for (s.items.items) |item| {
                    if (item.src) |is| {
                        if (!is.synthetic) return markup.columnOf(src, is.entry_start);
                    }
                }
            },
            else => {},
        }
        // No original entry left to copy the column from (they were all
        // deleted or replaced). The container's own `entry_start` still
        // records where its first entry sat, which is the column its
        // entries belong at — `fallback` is the container's own column,
        // so stepping in from it would indent one level too deep.
        if (node.src) |s| {
            if (!s.synthetic) return markup.columnOf(src, s.entry_start);
        }
        return fallback + self.indent_step;
    }

    /// True when a node can be emitted from its original bytes.
    fn nodeClean(self: *Emitter, node: *Node) bool {
        const s = node.src orelse return false;
        return !s.synthetic and !node.modified and !self.emitted.contains(node);
    }

    /// Write a node's original bytes when it is untouched; returns the
    /// end offset on success, null when the caller must re-emit.
    fn writeCleanSlice(self: *Emitter, node: *Node, from: usize) Error!?usize {
        if (!self.nodeClean(node)) return null;
        const s = node.src.?;
        try self.emitted.put(node, {});
        try self.write(self.src[from..s.end]);
        return s.end;
    }

    /// Write the gap bytes [from, to), skipping tombstoned ranges of
    /// removed entries inside the container.
    fn writeGap(self: *Emitter, container: *const Node, from: usize, to: usize) Error!void {
        const src = self.src;
        if (to <= from) return;
        const drops = Document.droppedOf(container);
        var i: usize = from;
        outer: while (i < to) {
            for (drops) |d| {
                if (d[0] < to and d[1] > i) {
                    if (d[0] > i) try self.write(src[i..d[0]]);
                    i = @max(i, d[1]);
                    continue :outer;
                }
            }
            try self.write(src[i..to]);
            return;
        }
    }

    /// The first byte at/after `from` that a tombstone does not cover,
    /// up to `to`; 0 when the whole range is deleted or empty. Used to
    /// decide whether the verbatim tail opens with a comment.
    fn firstLiveTailByte(self: *const Emitter, container: *const Node, from: usize, to: usize) u8 {
        const src = self.src;
        var i: usize = from;
        outer: while (i < to) {
            for (Document.droppedOf(container)) |d| {
                if (d[0] < to and d[1] > i) {
                    if (d[0] > i) return if (d[0] <= to) src[i] else 0;
                    i = @max(i, d[1]);
                    continue :outer;
                }
            }
            return src[i];
        }
        return 0;
    }

    /// True when `offset` falls inside one of `container`'s tombstoned
    /// ranges, i.e. points at bytes a deleted entry used to own.
    fn dropCovers(container: *const Node, offset: usize) bool {
        for (Document.droppedOf(container)) |d| {
            if (offset >= d[0] and offset < d[1]) return true;
        }
        return false;
    }

    /// Write the rest of the line after `offset` (trailing comment,
    /// line terminator) and return the offset just past it.
    fn writeRemainder(self: *Emitter, offset: usize) Error!usize {
        const src = self.src;
        const le = markup.lineEnd(src, offset);
        if (offset < le) try self.write(src[offset..le]);
        return le;
    }

    /// The line terminator convention the source uses at `offset`.
    /// Written comments keep the document's convention; bytes with no
    /// source behind them default to `\n`.
    fn terminatorAt(self: *const Emitter, offset: usize) []const u8 {
        const src = self.src;
        if (offset == 0 or offset > src.len) return "\n";
        // `newlineAt` returns the first byte of the terminator, which
        // for CRLF is the CR (it treats a lone CR as a break, as the
        // scanner does). So the CRLF test is on that byte and its
        // successor, not on a `\n` with a `\r` behind it.
        const nl = markup.newlineAt(src, offset);
        if (nl < src.len and src[nl] == '\r') {
            return if (nl + 1 < src.len and src[nl + 1] == '\n') "\r\n" else "\r";
        }
        return "\n";
    }

    /// The document's own line-break convention, for a structural break
    /// the emitter lays out itself (a brand-new entry's line, a restored
    /// line break, a written comment). `terminatorAt` answers this for a
    /// known source offset; this is the document-wide fallback, taken from
    /// the source's first break. A programmatic or single-line source
    /// breaks with `\n`, as it always did.
    fn defaultTerminator(self: *const Emitter) []const u8 {
        const src = self.src;
        var i: usize = 0;
        while (i < src.len) : (i += 1) {
            if (src[i] == '\n') return "\n";
            if (src[i] == '\r') {
                return if (i + 1 < src.len and src[i + 1] == '\n') "\r\n" else "\r";
            }
        }
        return "\n";
    }

    /// Write the tail of an entry's line: the trailing comment and the
    /// terminator. A node with a pending trailing override (see
    /// `Document.setTrailingComment`) gets the canonical ` # text` —
    /// or, for the empty override (a deletion), just the terminator —
    /// instead of the original bytes. Returns the offset past the line.
    fn writeEntryTail(self: *Emitter, node: *const Node, offset: usize) Error!usize {
        const src = self.src;
        const t = node.pending_trailing orelse return self.writeRemainder(offset);
        const le = markup.lineEnd(src, offset);
        if (t.len == 0) {
            // Deletion: the blanks and the comment go, the terminator
            // stays structural.
            if (!self.endsWithNewline()) try self.write(self.terminatorAt(offset));
            return le;
        }
        try self.writeByte(' ');
        try self.write(t);
        try self.write(self.terminatorAt(offset));
        return le;
    }

    /// Write a pending leading comment block ahead of an entry, one
    /// line per source line at the entry's own column, then the
    /// indentation the entry itself continues on. The caller has written
    /// everything before the entry (the original gap up to its entry
    /// start, or a new entry's separator); indentation and `- `/`? `/`: `
    /// framing already written on the entry's line is lifted off and put
    /// back after the block. The empty override (a
    /// deletion) writes nothing — the tombstoned block is already
    /// skipped in the gap.
    fn writePendingLeadingText(self: *Emitter, pending: ?[]const u8, col: usize, term: []const u8) Error!void {
        const t = pending orelse return;
        if (t.len == 0) return;
        // The block opens a line of its own, above the entry's line. A
        // pending line holding only indentation and `- `/`? `/`: `
        // framing IS the entry's line, already begun: lift it off, write
        // the block at its indentation, and put the framing back after
        // it.
        // Breaking the line instead left a whitespace-only line behind
        // (`items:\n  \n  # c`), or cut an item's `- ` off its entry
        // (`- \n  # c\n  ? k`).
        const open = self.pendingLine();
        if (isEntryFraming(open)) {
            var indent: usize = 0;
            while (indent < open.len and open[indent] == ' ') indent += 1;
            const framing = try self.allocator.dupe(u8, open[indent..]);
            defer self.allocator.free(framing);
            self.out.shrinkRetainingCapacity(self.out.items.len - open.len);
            try self.writeLeadingLines(t, if (framing.len > 0) indent else col, term);
            try self.write(framing);
            return;
        }
        if (!self.endsWithNewline()) try self.write(self.defaultTerminator());
        try self.writeLeadingLines(t, col, term);
    }

    /// The lines of a written leading block at `col`, each terminated,
    /// then the indentation of the line they sit above.
    fn writeLeadingLines(self: *Emitter, text: []const u8, col: usize, term: []const u8) Error!void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            try self.writeIndent(col);
            try self.write(line);
            try self.write(term);
        }
        try self.writeIndent(col);
    }

    fn writeNewlineIndent(self: *Emitter, indent: usize) Error!void {
        try self.write(self.defaultTerminator());
        try self.writeIndent(indent);
    }

    // ------------------------------------------------------------------
    // Node emission
    //
    // Contract: the cursor sits at the column where the node's first line
    // begins (start of a line at `indent`, or just after a "key: " / "- "
    // prefix). Continuation lines are written at `indent`.
    // ------------------------------------------------------------------

    fn emitNode(self: *Emitter, node: *Node, indent: usize) Error!void {
        try self.enter();
        defer self.leave();
        // Alias emission: an anchored node that was already written is
        // referenced as *anchor instead of duplicating its content.
        if (self.seen.get(node)) |anchor| {
            try self.writeByte('*');
            try self.write(anchor);
            return;
        }

        switch (node.data) {
            .scalar => |s| {
                if (node.anchor) |a| try self.seen.put(node, a);
                const props = try self.writeProperties(node);
                if (props) try self.writeByte(' ');
                try self.emitScalarValue(s.value, s.style, indent, true, false);
            },
            .mapping => |*m| {
                if (m.pairs.items.len == 0 or m.style == .flow) {
                    try self.emitFlowNode(node);
                    return;
                }
                if (node.anchor) |a| try self.seen.put(node, a);
                const props = try self.writeProperties(node);
                if (props) try self.newlineAt(indent);
                for (m.pairs.items, 0..) |pair, i| {
                    if (i > 0) try self.newlineAt(indent);
                    try self.emitEntry(pair.key, pair.value, indent);
                }
            },
            .sequence => |*s| {
                if (s.items.items.len == 0 or s.style == .flow) {
                    try self.emitFlowNode(node);
                    return;
                }
                if (node.anchor) |a| try self.seen.put(node, a);
                const props = try self.writeProperties(node);
                if (props) try self.newlineAt(indent);
                for (s.items.items, 0..) |item, i| {
                    if (i > 0) try self.newlineAt(indent);
                    try self.write("- ");
                    try self.emitNode(item, indent + 2);
                }
            },
            .alias => |a| {
                try self.writeByte('*');
                try self.write(a.name);
            },
        }
    }

    /// Emit one mapping entry. The cursor is at the key column.
    fn emitEntry(self: *Emitter, key: *Node, value: *Node, indent: usize) Error!void {
        switch (key.data) {
            .scalar => {
                // A scalar key can carry properties too (`&k name: v`,
                // `!t 1: v`). They were dropped here while non-scalar
                // keys (through `emitFlowNode`) kept theirs, so an alias
                // to an anchored scalar key emitted `*k` with no `&k`.
                if (key.anchor) |a| try self.seen.put(key, a);
                _ = try self.emitKeyContent(key, indent, false);
                try self.writeByte(':');
            },
            else => {
                // Explicit key (spec 7.4.2). The key itself is written in
                // compact flow form, but the value indicator MUST open a
                // line of its own at the key's own column. `? K: V` on one
                // line is not the entry it looks like: a block mapping
                // reads it as an explicit key that is the mapping `{K: V}`,
                // with a null value — silently changing both the key and
                // the value on a round trip. Only this laid-out path is
                // affected; an unmodified entry re-emits from its source
                // span (`explicitKeySpan`) and keeps whatever shape it had.
                try self.write("? ");
                try self.emitFlowNode(key);
                try self.newlineAt(indent);
                try self.writeByte(':');
            },
        }

        // A null value is written by writing nothing at all: `key:`.
        // Emitting the separating space too would leave the line with
        // trailing whitespace for no reason.
        if (isNullScalar(value)) return;

        // Value placement: scalars and flow collections stay inline,
        // block collections start on the next, deeper line.
        if (inlineValue(value)) {
            try self.writeByte(' ');
            try self.emitNode(value, indent + self.indent_step);
        } else {
            try self.newlineAt(indent + self.indent_step);
            try self.emitNode(value, indent + self.indent_step);
        }
    }

    // ------------------------------------------------------------------
    // Flow style
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // Faithful flow emission.
    //
    // A flow collection can be written across several lines, with its
    // own indentation and comments:
    //
    //     matrix: [
    //       alpha,   # the good one
    //       beta,
    //       ]
    //
    // Re-emitting that from the tree collapses it to one line and drops
    // the comment. The bytes between entries are a gap in exactly the
    // sense block containers already use -- commas and layout instead of
    // newlines and indentation -- so the same walk applies: copy the
    // gaps, re-emit only the entries that changed.
    //
    // Scope: MODIFICATION only. Adding or removing a flow entry means
    // rewriting separators (dropping one from `[a, b, c]` must not leave
    // `a, , c`), and there is no original layout for a new entry to sit
    // in. Those still normalize, and `flowLayoutRecoverable` is what
    // draws the line -- checked in full before anything is written, so
    // the fallback stays all-or-nothing.
    // ------------------------------------------------------------------

    /// Scan `src[from..to]` accepting only inter-entry filler -- blanks,
    /// line breaks, `#` comments -- and report how many `,` separators it
    /// held. Null when anything else turns up.
    ///
    /// This is what distinguishes a MODIFIED flow collection from one an
    /// entry was REMOVED from. Flow containers deliberately record no
    /// tombstones (their entries share a line with the parent's `key:`,
    /// so a line-range tombstone would swallow those bytes), which
    /// leaves the emitter no other way to notice a deletion: the entry
    /// list is simply shorter and the departed entry's text is still
    /// sitting in the gap. When it is, this returns null and the
    /// collection normalizes -- re-flowing separators around a hole is a
    /// different job from preserving layout, and not this one.
    fn flowFillerCommas(src: []const u8, from: usize, to: usize) ?usize {
        var i = from;
        var commas: usize = 0;
        while (i < to) : (i += 1) {
            switch (src[i]) {
                ' ', '\t', '\n', '\r' => {},
                ',' => commas += 1,
                '#' => while (i + 1 < to and src[i + 1] != '\n') : (i += 1) {},
                else => return null,
            }
        }
        return commas;
    }

    /// True when `node`'s original flow bytes can still carry its current
    /// contents: nothing added or removed, every entry still spanned or
    /// bounded, keys untouched, and every changed value a plain scalar or
    /// alias we can write back into its slot.
    fn flowLayoutRecoverable(self: *Emitter, node: *Node) bool {
        const src = self.src;
        const cs = node.src orelse return false;
        if (cs.synthetic or cs.end <= cs.start) return false;
        // Anchors and tags are written ahead of the bracket; re-emitting
        // them is `writeProperties`' job and not worth entangling here.
        if (node.anchor != null or node.tag != null) return false;
        if (Document.droppedOf(node).len != 0) return false;

        // Walk the entries and the gaps between them together: the gaps
        // are what prove no entry went missing.
        var prev_end = cs.start + 1; // just past `[` / `{`
        var first = true;
        switch (node.data) {
            .mapping => |*m| {
                if (m.pairs.items.len == 0) return false;
                for (m.pairs.items) |pair| {
                    const pend = pair.src_end orelse return false;
                    // A changed KEY would need its bytes rewritten in
                    // place, and a flow key can be a whole collection.
                    // Values are the case worth having.
                    const ks = pair.key.src orelse return false;
                    if (ks.synthetic or !self.nodeClean(pair.key)) return false;
                    // The value may have lost its span entirely --
                    // `mappingReplace` swaps the node out -- and that is
                    // the case this exists for. The key's colon and the
                    // pair's own end still bound the slot.
                    if (pair.value.src) |vs| {
                        if (vs.synthetic) return false;
                        if (!self.nodeClean(pair.value) and !rewritableInFlow(pair.value)) return false;
                    } else if (!rewritableInFlow(pair.value)) return false;

                    const commas = flowFillerCommas(src, prev_end, ks.entry_start) orelse return false;
                    if (commas != @intFromBool(!first)) return false;
                    first = false;
                    prev_end = pend;
                }
            },
            .sequence => |*sq| {
                if (sq.items.items.len == 0) return false;
                for (sq.items.items) |item| {
                    // `Editor.set` transfers a recoverable original slot
                    // to its replacement. Raw remove/insert operations do
                    // not, so they still fail this check and normalize.
                    const is = item.src orelse return false;
                    if (is.synthetic) return false;
                    if (!self.nodeClean(item) and !rewritableInFlow(item)) return false;

                    const commas = flowFillerCommas(src, prev_end, is.entry_start) orelse return false;
                    if (commas != @intFromBool(!first)) return false;
                    first = false;
                    prev_end = is.end;
                }
            },
            else => return false,
        }
        // Tail: layout, an optional trailing comma, then the bracket.
        const tail = flowFillerCommas(src, prev_end, cs.end - 1) orelse return false;
        return tail <= 1;
    }

    /// A changed entry we can write back into a flow slot: a scalar or
    /// an alias, carrying no properties of its own.
    ///
    /// `pub` only so `edit.zig` can use the emitter's exact eligibility
    /// rule across the file boundary. Not part of the supported API.
    pub fn rewritableInFlow(node: *Node) bool {
        if (node.anchor != null or node.tag != null) return false;
        return switch (node.data) {
            .scalar, .alias => true,
            else => false,
        };
    }

    /// Re-emit a modified flow collection over its original bytes.
    /// Only call when `flowLayoutRecoverable` said yes.
    fn emitFlowFaithful(self: *Emitter, node: *Node) Error!void {
        const src = self.src;
        const cs = node.src.?;
        var gap = cs.start;
        switch (node.data) {
            .mapping => |*m| {
                for (m.pairs.items) |pair| {
                    const ks = pair.key.src.?;
                    const pend = pair.src_end.?;
                    // Opening bracket, or the comma and layout since the
                    // previous entry -- comments included.
                    try self.write(src[gap..ks.entry_start]);
                    if (pair.value.src != null and self.nodeClean(pair.value)) {
                        try self.write(src[ks.entry_start..pend]);
                    } else {
                        // Key, colon and the spacing after it are the
                        // author's; only the value is ours to rewrite.
                        // A replaced value has no span left, so the slot
                        // is bounded by the colon and the pair's end.
                        const vstart = if (pair.value.src) |vs|
                            vs.start
                        else
                            markup.spaceEnd(src, markup.colonEnd(src, ks.end));
                        try self.write(src[ks.entry_start..vstart]);
                        try self.emitFlowBody(pair.value);
                    }
                    gap = pend;
                }
            },
            .sequence => |*sq| {
                for (sq.items.items) |item| {
                    const is = item.src.?;
                    try self.write(src[gap..is.entry_start]);
                    if (self.nodeClean(item)) {
                        try self.write(src[is.entry_start..is.end]);
                    } else {
                        try self.write(src[is.entry_start..is.start]);
                        if (!try self.writeNullFlowItem(item)) try self.emitFlowBody(item);
                    }
                    gap = is.end;
                }
            },
            else => unreachable,
        }
        // Trailing layout and the closing bracket.
        try self.write(src[gap..cs.end]);
    }

    /// Emit a node in flow style, registering it for alias tracking.
    fn emitFlowNode(self: *Emitter, node: *Node) Error!void {
        if (self.seen.get(node)) |anchor| {
            try self.writeByte('*');
            try self.write(anchor);
            return;
        }
        if (node.anchor) |a| try self.seen.put(node, a);
        try self.emitFlowBody(node);
    }

    fn emitFlowBody(self: *Emitter, node: *Node) Error!void {
        try self.enter();
        defer self.leave();
        if (node.anchor) |a| {
            try self.writeByte('&');
            try self.write(a);
            try self.writeByte(' ');
        }
        if (node.tag) |t| {
            try self.writeTag(t);
            try self.writeByte(' ');
        }
        switch (node.data) {
            .scalar => |s| try self.emitScalarValue(s.value, s.style, 0, false, true),
            .alias => |a| {
                try self.writeByte('*');
                try self.write(a.name);
            },
            .mapping => |*m| {
                try self.writeByte('{');
                for (m.pairs.items, 0..) |pair, i| {
                    if (i > 0) try self.write(", ");
                    switch (pair.key.data) {
                        .scalar => |s| {
                            // Same rule as the block path: a scalar key's
                            // own anchor/tag is written and registered.
                            if (pair.key.anchor) |a| try self.seen.put(pair.key, a);
                            if (try self.writeProperties(pair.key)) try self.writeByte(' ');
                            try self.emitScalarValue(s.value, s.style, 0, false, true);
                        },
                        else => try self.emitFlowNode(pair.key),
                    }
                    try self.write(": ");
                    try self.emitFlowNode(pair.value);
                }
                try self.writeByte('}');
            },
            .sequence => |*s| {
                try self.writeByte('[');
                for (s.items.items, 0..) |item, i| {
                    if (i > 0) try self.write(", ");
                    if (!try self.writeNullFlowItem(item)) try self.emitFlowNode(item);
                }
                try self.writeByte(']');
            },
        }
    }

    /// An empty plain scalar is YAML's null and is written as nothing
    /// (`key:`, `- `, `{k: }`), but a flow sequence item cannot be
    /// nothing: `[, b]` does not parse and `[a, ]` has one item. Such an
    /// item, with no anchor or tag to stand in for it, is written `null`,
    /// the core schema's spelling of the same value (`""` would be the
    /// empty string). Returns whether it wrote the item.
    fn writeNullFlowItem(self: *Emitter, item: *const Node) Error!bool {
        if (item.anchor != null or item.tag != null) return false;
        switch (item.data) {
            .scalar => |s| if (s.value.len != 0 or s.style != .plain) return false,
            else => return false,
        }
        try self.write("null");
        return true;
    }

    // ------------------------------------------------------------------
    // Properties: anchors and tags
    // ------------------------------------------------------------------

    /// Write "&anchor" and the node tag (if any). Returns true when
    /// anything was written.
    fn writeProperties(self: *Emitter, node: *Node) Error!bool {
        var written = false;
        if (node.anchor) |a| {
            try self.writeByte('&');
            try self.write(a);
            written = true;
        }
        if (node.tag) |t| {
            if (written) try self.writeByte(' ');
            try self.writeTag(t);
            written = true;
        }
        return written;
    }

    fn writeTag(self: *Emitter, tag: []const u8) Error!void {
        if (std.mem.startsWith(u8, tag, yaml_tag_prefix)) {
            try self.write("!!");
            try self.write(tag[yaml_tag_prefix.len..]);
        } else if (tag.len > 0 and tag[0] == '!') {
            try self.write(tag);
        } else {
            try self.write("!<");
            try self.write(tag);
            try self.writeByte('>');
        }
    }

    // ------------------------------------------------------------------
    // Scalars
    // ------------------------------------------------------------------

    fn emitScalarValue(self: *Emitter, value: []const u8, prefer: ScalarStyle, indent: usize, block_ok: bool, flow: bool) Error!void {
        const style = chooseScalarStyle(value, prefer, indent, block_ok, flow);
        self.kept_breaks = (style == .literal or style == .folded) and stripTrailingNewlines(value).trailing > 1;
        switch (style) {
            .plain => try self.write(value),
            .single_quoted => {
                try self.writeByte('\'');
                for (value) |c| {
                    if (c == '\'') try self.writeByte('\'');
                    try self.writeByte(c);
                }
                try self.writeByte('\'');
            },
            .double_quoted => try self.writeDoubleQuoted(value),
            .literal => try self.writeLiteral(value, indent),
            .folded => try self.writeFolded(value, indent),
            .any => unreachable,
        }
    }

    fn writeDoubleQuoted(self: *Emitter, value: []const u8) Error!void {
        try self.writeByte('"');
        for (value) |c| {
            switch (c) {
                '"' => try self.write("\\\""),
                '\\' => try self.write("\\\\"),
                '\n' => try self.write("\\n"),
                '\t' => try self.write("\\t"),
                '\r' => try self.write("\\r"),
                0 => try self.write("\\0"),
                0x07 => try self.write("\\a"),
                0x08 => try self.write("\\b"),
                0x0B => try self.write("\\v"),
                0x0C => try self.write("\\f"),
                0x1B => try self.write("\\e"),
                else => {
                    if (c < 0x20 or c == 0x7F) {
                        var buf: [8]u8 = undefined;
                        const seq = std.fmt.bufPrint(&buf, "\\x{x:0>2}", .{c}) catch unreachable;
                        try self.write(seq);
                    } else {
                        try self.writeByte(c);
                    }
                },
            }
        }
        try self.writeByte('"');
    }

    /// Value with its trailing newlines stripped and counted (block
    /// scalar chomping).
    fn stripTrailingNewlines(value: []const u8) struct { core: []const u8, trailing: usize } {
        var core = value;
        var trailing: usize = 0;
        while (core.len > 0 and core[core.len - 1] == '\n') {
            trailing += 1;
            core = core[0 .. core.len - 1];
        }
        return .{ .core = core, .trailing = trailing };
    }

    /// Block scalar header: `|` or `>` plus the chomping indicator
    /// (`-` strip, `+` keep) computed from the trailing-newline count.
    fn writeBlockHeader(self: *Emitter, indicator: u8, trailing: usize) Error!void {
        try self.writeByte(indicator);
        if (trailing == 0) {
            try self.writeByte('-');
        } else if (trailing > 1) {
            try self.writeByte('+');
        }
        try self.writeByte('\n');
    }

    fn writeLiteral(self: *Emitter, value: []const u8, indent: usize) Error!void {
        const s = stripTrailingNewlines(value);
        try self.writeBlockHeader('|', s.trailing);

        var it = std.mem.splitScalar(u8, s.core, '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first) try self.writeByte('\n');
            first = false;
            try self.writeIndent(indent);
            try self.write(line);
        }
        for (0..s.trailing) |_| try self.writeByte('\n');
    }

    /// `indent` is the column a block scalar's content lines would be
    /// written at.
    fn chooseScalarStyle(value: []const u8, prefer: ScalarStyle, indent: usize, block_ok: bool, flow: bool) ScalarStyle {
        if (value.len == 0) {
            // An empty PLAIN scalar is YAML's null -- `key:` with
            // nothing after it -- and null is not the empty string.
            // Quoting it would silently turn one into the other, which
            // is how a moved `push:` came out as `push: ""`. Any other
            // requested style for an empty value means the string.
            return if (prefer == .plain) .plain else .double_quoted;
        }
        // Whatever was asked for: no other style can spell these bytes.
        if (needsEscape(value)) return .double_quoted;
        const has_break = std.mem.indexOfScalar(u8, value, '\n') != null;
        if (has_break) {
            // Modified scalars keep their parsed block style when the
            // content can be re-emitted losslessly in it.
            if (block_ok and prefer == .folded and foldedSafe(value, indent)) return .folded;
            if (block_ok and literalSafe(value, indent)) return .literal;
            return .double_quoted;
        }
        switch (prefer) {
            .single_quoted => return .single_quoted,
            .double_quoted => return .double_quoted,
            .literal, .folded => return .double_quoted,
            .any, .plain => {},
        }
        // `.any` is "you pick" for a value the caller holds as a STRING
        // -- it is what `yaml.value` builds string scalars with. Picking
        // plain is only safe when the text does not resolve to some
        // other core tag: emitted bare, `true` re-parses as a bool and
        // `90210` as an int, so a postal code comes back as a number and
        // `toZig` into a `[]const u8` field fails. `.plain` keeps
        // meaning "the author wrote it bare", and is left alone.
        if (prefer == .any and document_mod.resolveCoreTag(value, .plain) != .str) {
            return .single_quoted;
        }
        if (plainSafe(value) and (!flow or flowPlainSafe(value))) return .plain;
        return .single_quoted;
    }

    /// True when `value` holds a byte only a double-quoted scalar can
    /// write: an ASCII control other than tab and line feed, or DEL.
    /// Single quotes and block scalars have no escapes, so the raw byte
    /// goes out as is -- and a CR is a line break to the reader (a
    /// quoted `a\rb` folds to `a b`, a literal CRLF comes back LF), a
    /// NUL is rejected on read, and ESC and DEL are not printable
    /// (YAML 1.2 5.1). `writeDoubleQuoted` has an escape for each.
    fn needsEscape(value: []const u8) bool {
        for (value) |c| {
            if (c != '\t' and c != '\n' and c < 0x80 and !ctype.isPrintableAscii(c)) return true;
        }
        return false;
    }

    /// Written at column 0 -- a root block scalar's content -- a line
    /// that starts with `---` or `...` followed by a blank or the end of
    /// the line is a document marker (spec 9.1.4 `c-forbidden`), so the
    /// block ends there and the rest reads as another document.
    fn hasMarkerLine(value: []const u8) bool {
        var it = std.mem.splitScalar(u8, value, '\n');
        while (it.next()) |line| {
            if (line.len < 3) continue;
            if (!std.mem.eql(u8, line[0..3], "---") and !std.mem.eql(u8, line[0..3], "...")) continue;
            if (line.len == 3 or ctype.isBlank(line[3])) return true;
        }
        return false;
    }

    /// Inside `[...]` or `{...}` the flow indicators end the entry or the
    /// collection wherever they appear -- not only as the first byte,
    /// which is all `plainSafe` inspects. A sequence item whose text is
    /// `x, y` emitted bare re-parses as TWO items; one containing `]`
    /// closes the sequence early and leaves a syntax error behind.
    fn flowPlainSafe(value: []const u8) bool {
        return std.mem.indexOfAny(u8, value, ",[]{}") == null;
    }

    /// A literal re-emission must re-parse to exactly `value` -- and the
    /// block it writes has to be a block at all. `writeLiteral` never
    /// writes an explicit indentation indicator, so three shapes are out
    /// of its reach (all found by the emission oracle's `value` mode):
    ///
    ///   - Content that is nothing but line breaks. No run of block
    ///     lines reads back as `"\n"`: the header alone gives `""`, and
    ///     a lone blank line is the block's own terminator.
    ///   - A first non-empty line that starts with a space. The reader
    ///     takes THAT line's indentation as the block's, so every later
    ///     line is under-indented and closes the block early. Saying
    ///     otherwise needs an explicit indicator (`|2`).
    ///   - Any line starting with a tab. Emitted at indent 0 -- a root
    ///     scalar, or a shallow one -- the tab lands exactly where
    ///     indentation is read, and a tab is never valid indentation.
    ///   - At indent 0, a document marker line (`hasMarkerLine`).
    ///
    /// Each falls back to double-quoted, which can always express the
    /// value.
    fn literalSafe(value: []const u8, indent: usize) bool {
        const s = stripTrailingNewlines(value);
        if (s.core.len == 0) return false;
        if (indent == 0 and hasMarkerLine(s.core)) return false;
        var it = std.mem.splitScalar(u8, s.core, '\n');
        var first_content = true;
        while (it.next()) |line| {
            if (line.len == 0) continue;
            if (line[0] == '\t') return false;
            if (first_content and line[0] == ' ') return false;
            first_content = false;
        }
        return true;
    }

    /// A folded re-emission must re-parse to exactly `value`: no leading
    /// blank line, no more-indented lines, no tabs, no trailing
    /// whitespace on any line (folding strips those), and at indent 0
    /// no document marker line (`hasMarkerLine`).
    fn foldedSafe(value: []const u8, indent: usize) bool {
        if (value.len == 0) return false;
        if (indent == 0 and hasMarkerLine(value)) return false;
        switch (value[0]) {
            '\n', ' ', '\t' => return false,
            else => {},
        }
        var it = std.mem.splitScalar(u8, value, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            if (line[0] == ' ' or line[0] == '\t') return false;
            if (std.mem.indexOfScalar(u8, line, '\t') != null) return false;
            const last = line[line.len - 1];
            if (last == ' ' or last == '\t') return false;
        }
        return true;
    }

    /// Folded block scalar (`>`). Folding joins consecutive lines with
    /// a space; a newline in the value therefore needs one blank output
    /// line (k consecutive breaks fold to k-1 newlines). Each value
    /// newline between content lines emits `breaks = newlines + 1`.
    /// Chomping mirrors `writeLiteral`.
    fn writeFolded(self: *Emitter, value: []const u8, indent: usize) Error!void {
        const s = stripTrailingNewlines(value);
        try self.writeBlockHeader('>', s.trailing);

        var it = std.mem.splitScalar(u8, s.core, '\n');
        var have_line = false;
        var blanks: usize = 0; // blank value lines since the last content line
        while (it.next()) |line| {
            if (line.len == 0) {
                blanks += 1;
                continue;
            }
            if (have_line) {
                // Terminate the previous line, then one blank output
                // line per value newline (the separator itself plus
                // each blank value line).
                for (0..blanks + 2) |_| try self.writeByte('\n');
            }
            blanks = 0;
            have_line = true;
            try self.writeIndent(indent);
            try self.write(line);
        }
        for (0..s.trailing) |_| try self.writeByte('\n');
    }

    fn plainSafe(value: []const u8) bool {
        if (value.len == 0) return false;
        const first = value[0];
        const last = value[value.len - 1];
        if (first == ' ' or last == ' ') return false;
        switch (first) {
            '!', '&', '*', '#', '|', '>', '\'', '"', '%', '@', '`', ',', '[', ']', '{', '}' => return false,
            '-', '?', ':' => {
                if (value.len == 1) return false;
                const next = value[1];
                if (next == ' ' or next == '\t') return false;
            },
            else => {},
        }
        if (value.len >= 3 and (std.mem.eql(u8, value[0..3], "---") or std.mem.eql(u8, value[0..3], "..."))) {
            if (value.len == 3 or value[3] == ' ' or value[3] == '\t') return false;
        }
        for (value) |c| {
            if (c < 0x20 or c == 0x7F) return false;
        }
        if (std.mem.indexOf(u8, value, ": ") != null) return false;
        if (last == ':') return false;
        if (std.mem.indexOf(u8, value, " #") != null) return false;
        return true;
    }
};

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

fn roundTrip(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var doc = try Document.parse(allocator, input);
    defer doc.deinit();
    return doc.write(allocator);
}

test "emitDocument writes into the caller's list" {
    const allocator = testing.allocator;
    var doc = try Document.parse(allocator, "a: 1\nb: [x, y]\n");
    defer doc.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var em = Emitter.init(allocator, &out);
    defer em.deinit();
    try em.emitDocument(&doc);
    try testing.expectEqualStrings("a: 1\nb: [x, y]\n", out.items);
}

test "emit flat mapping" {
    const out = try roundTrip(testing.allocator, "a: 1\nb: hello\nc: true\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: 1\nb: hello\nc: true\n", out);
}

test "emit nested structures" {
    const src =
        \\server:
        \\  host: localhost
        \\  ports:
        \\    - 80
        \\    - 443
        \\debug: false
        \\
    ;
    const out = try roundTrip(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "emit sequence of mappings" {
    const src =
        \\- name: a
        \\  value: 1
        \\- name: b
        \\  value: 2
        \\
    ;
    const out = try roundTrip(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "emit quoting" {
    const cases = [_]struct { k: []const u8, v: []const u8, want: []const u8 }{
        .{ .k = "empty", .v = "", .want = "\"\"" },
        .{ .k = "colon", .v = "a: b", .want = "'a: b'" },
        .{ .k = "hash", .v = "x # y", .want = "'x # y'" },
        .{ .k = "lead", .v = " spaced", .want = "' spaced'" },
        .{ .k = "apos", .v = "it's", .want = "it's" },
        .{ .k = "newline", .v = "l1\nl2\n", .want = "|\n  l1\n  l2" },
    };
    for (cases) |c| {
        var doc = Document.init(testing.allocator);
        defer doc.deinit();
        const root = try doc.createMapping();
        doc.root = root;
        try doc.pathSet(&.{c.k}, try doc.createScalar(c.v, .any));
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        var buf: [256]u8 = undefined;
        const want = std.fmt.bufPrint(&buf, "{s}: {s}\n", .{ c.k, c.want }) catch unreachable;
        try testing.expectEqualStrings(want, out);
    }
}

test "emit flow collections" {
    const out = try roundTrip(testing.allocator, "a: [1, 2, 3]\nb: {x: 1, y: 2}\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: [1, 2, 3]\nb: {x: 1, y: 2}\n", out);
}

test "emit anchors and aliases" {
    const src = "- &v 42\n- *v\n";
    const out = try roundTrip(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "emit block scalar round trip" {
    const src = "text: |\n  line one\n  line two\n";
    const out = try roundTrip(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "emit explicit document markers" {
    const src = "%YAML 1.2\n---\na: b\n...\n";
    const out = try roundTrip(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "emit tags" {
    const src = "n: !!int 42\n";
    const out = try roundTrip(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "modified folded scalar keeps folded style" {
    const src = "desc: >\n  first paragraph\n  more text\nother: 1\n";
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try doc.pathSet(&.{"desc"}, try doc.createScalar("new paragraph\nstill folded\n", .folded));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("desc: >\n  new paragraph\n\n  still folded\nother: 1\n", out);
    // The re-emitted text re-parses to the same value.
    var doc2 = try Document.parse(testing.allocator, out);
    defer doc2.deinit();
    try testing.expectEqualStrings("new paragraph\nstill folded\n", doc2.pathGet(&.{"desc"}).?.scalarValue().?);
}

test "unsafe folded content falls back to literal" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    const root = try doc.createMapping();
    doc.root = root;
    // A line with trailing whitespace cannot round-trip folded.
    try doc.pathSet(&.{"x"}, try doc.createScalar("line one \nline two\n", .folded));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("x: |\n  line one \n  line two\n", out);
}

test "a new subtree adopts the document's indent width" {
    // A subtree the emitter owns has no indentation of its own to
    // preserve, so it inherits the file's. Measuring beats assuming:
    // hard-coding two spaces makes an insert into a four-space file
    // look like it came from somewhere else.
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{
            .src = "top:\n  a: 1\n",
            .want = "top:\n  a: 1\n  added:\n    x: 1\n",
        },
        .{
            .src = "top:\n    a: 1\n",
            .want = "top:\n    a: 1\n    added:\n        x: 1\n",
        },
        .{
            .src = "top:\n   a: 1\n",
            .want = "top:\n   a: 1\n   added:\n      x: 1\n",
        },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.src);
        defer doc.deinit();
        const m = try doc.createMapping();
        try doc.mappingAppend(m, try doc.createScalar("x", .plain), try doc.createScalar("1", .plain));
        try doc.pathSet(&.{ "top", "added" }, m);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
        // Whatever the width, the result must still parse back.
        var again = try Document.parse(testing.allocator, out);
        defer again.deinit();
        try testing.expectEqualStrings(
            "1",
            again.pathGet(&.{ "top", "added", "x" }).?.scalarValue().?,
        );
    }
}

test "a document with nothing to measure keeps the two-space default" {
    // Flat documents nest nowhere, so there is no convention to read.
    var doc = try Document.parse(testing.allocator, "a: 1\nb: 2\n");
    defer doc.deinit();
    const m = try doc.createMapping();
    try doc.mappingAppend(m, try doc.createScalar("x", .plain), try doc.createScalar("1", .plain));
    try doc.pathSet(&.{"c"}, m);
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: 1\nb: 2\nc:\n  x: 1\n", out);
}

test "a modified multi-line flow mapping keeps its layout" {
    // The bytes between flow entries are a gap in exactly the sense
    // block containers already use -- commas and line breaks instead of
    // newlines and indentation -- so only the changed value is rewritten
    // and everything else, comments included, is copied.
    const cases = [_]struct { src: []const u8, path: []const u8, want: []const u8 }{
        .{
            .src = "m: {\n  a: 1,\n  b: 2,\n  }\nafter: 1\n",
            .path = "b",
            .want = "m: {\n  a: 1,\n  b: Z,\n  }\nafter: 1\n",
        },
        // A comment between entries is layout, and survives.
        .{
            .src = "m: {\n  a: 1,   # keep me\n  b: 2,\n  }\n",
            .path = "b",
            .want = "m: {\n  a: 1,   # keep me\n  b: Z,\n  }\n",
        },
        // The first entry, so the opening-bracket gap is exercised too.
        .{
            .src = "m: {\n  a: 1,\n  b: 2,\n  }\n",
            .path = "a",
            .want = "m: {\n  a: Z,\n  b: 2,\n  }\n",
        },
        // Single-line flow keeps working; it is the same walk.
        .{
            .src = "m: {a: 1, b: 2}\n",
            .path = "b",
            .want = "m: {a: 1, b: Z}\n",
        },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.src);
        defer doc.deinit();
        try doc.pathSet(&.{ "m", c.path }, try doc.createScalar("Z", .plain));
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
        var again = try Document.parse(testing.allocator, out);
        defer again.deinit();
        try testing.expectEqualStrings("Z", again.pathGet(&.{ "m", c.path }).?.scalarValue().?);
    }
}

test "flow collections normalize when the layout cannot carry the change" {
    // The boundary, pinned deliberately. `Editor.set` can preserve a
    // recoverable flow-sequence slot, but actual insertion or removal has
    // no slot to write into and separators must be re-flowed around the
    // change. Those operations still collapse to one line -- correct,
    // just not layout-preserving.
    {
        // Deleting an entry: the gap between survivors would still hold
        // the departed entry's bytes, which `flowFillerCommas` detects.
        var doc = try Document.parse(testing.allocator, "m: {\n  a: 1,\n  b: 2,\n  }\n");
        defer doc.deinit();
        try testing.expect(try doc.pathDelete(&.{ "m", "a" }));
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("m: {b: 2}\n", out);
    }
    {
        // An explicit remove-plus-insert keeps no span, and a flow
        // container records no tombstone, so its slot is unrecoverable.
        var doc = try Document.parse(testing.allocator, "s: [\n  alpha,\n  beta,\n  ]\n");
        defer doc.deinit();
        // Deliberately exercise the raw operations rather than
        // `Editor.set`, whose eligible replacement path preserves a slot.
        const seq = doc.pathGet(&.{"s"}).?;
        _ = (try doc.sequenceRemove(seq, 1)).?;
        try doc.sequenceInsert(seq, 1, try doc.createScalar("Z", .plain));
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("s: [alpha, Z]\n", out);
    }
}

test "a programmatically nested tree is bounded, not a stack overflow" {
    // The scanner's nesting cap covers parsed input, but a tree built
    // through the document API is never scanned. Before the emitter
    // carried its own bound this recursed until the native stack ran
    // out; the contract is a typed error.
    var doc = Document.init(testing.allocator);
    defer doc.deinit();

    const root = try doc.createSequence();
    doc.root = root;
    var cur = root;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const next = try doc.createSequence();
        try doc.sequenceAppend(cur, next);
        cur = next;
    }
    try doc.sequenceAppend(cur, try doc.createScalar("leaf", .plain));

    try testing.expectError(error.NestingTooDeep, doc.write(testing.allocator));
}

test "the depth bound is a bound, and nesting under it still emits" {
    // Non-vacuous in both directions: the shallow tree must round trip,
    // so the guard is not simply rejecting everything.
    var doc = Document.init(testing.allocator);
    defer doc.deinit();

    const root = try doc.createSequence();
    doc.root = root;
    var cur = root;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const next = try doc.createSequence();
        try doc.sequenceAppend(cur, next);
        cur = next;
    }
    try doc.sequenceAppend(cur, try doc.createScalar("leaf", .plain));

    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "leaf") != null);

    // And the emitted text re-parses, so the bound did not truncate it.
    var again = try Document.parse(testing.allocator, out);
    defer again.deinit();
}

test "a plain scalar in a flow collection is quoted when it holds a flow indicator" {
    // `plainSafe` only inspects value[0], so an edited flow item whose
    // text contains `,` went out bare: `[hello, world, y]` re-parsed as
    // THREE items, and a `]` in the text closed the sequence early.
    const cases = [_]struct { value: []const u8, want: []const u8 }{
        .{ .value = "hello, world", .want = "a: ['hello, world', y]\n" },
        .{ .value = "item]close", .want = "a: ['item]close', y]\n" },
        .{ .value = "{braced}", .want = "a: ['{braced}', y]\n" },
        // Nothing to escape: the plain form is still preferred.
        .{ .value = "plain text", .want = "a: [plain text, y]\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, "a: [x, y]\n");
        defer doc.deinit();
        const seq = doc.pathGet(&.{"a"}).?;
        try testing.expect(try internal.sequenceReplace(&doc, seq, 0, try doc.createScalar(c.value, .plain)));
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);

        // And the emitted text has to re-parse to the value we set.
        var rt = try Document.parse(testing.allocator, out);
        defer rt.deinit();
        const items = rt.pathGet(&.{"a"}).?.items().?;
        try testing.expectEqual(@as(usize, 2), items.len);
        try testing.expectEqualStrings(c.value, items[0].scalarValue().?);
    }
}

test "an empty plain scalar in a flow sequence is written as null" {
    // An empty plain scalar is YAML's null, written as nothing. A flow
    // sequence item cannot be nothing: `s: [a, b]` with `$.s[0]` set to
    // it was written `s: [, b]`, which does not parse, and `$.s[1]`
    // gave `s: [a, ]`, which has one item.
    // `index` set: replace that item of `s`; otherwise set `m.k`.
    const cases = [_]struct { in: []const u8, index: ?usize, out: []const u8 }{
        .{ .in = "s: [a, b]\n", .index = 0, .out = "s: [null, b]\n" },
        .{ .in = "s: [a, b]\n", .index = 1, .out = "s: [a, null]\n" },
        .{ .in = "s: [a]\n", .index = 0, .out = "s: [null]\n" },
        // Controls: a block item and a flow mapping value can be empty.
        .{ .in = "s:\n  - a\n  - b\n", .index = 0, .out = "s:\n  - \n  - b\n" },
        .{ .in = "m: {k: v, j: w}\n", .index = null, .out = "m: {k: , j: w}\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.in);
        defer doc.deinit();
        const empty = try doc.createScalar("", .plain);
        if (c.index) |i| {
            const seq = doc.pathGet(&.{"s"}).?;
            if (seq.data.sequence.style == .flow) {
                try testing.expect(try internal.sequenceReplace(&doc, seq, i, empty));
            } else {
                // Block items have no in-place replace: empty the item.
                const item = seq.items().?[i];
                item.data.scalar.value = "";
                try doc.markModified(item);
            }
        } else try doc.pathSet(&.{ "m", "k" }, empty);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.out, out);
    }

    // Every position of flow sequences of one to four items, parsed and
    // built: the item stays a null and the length stays the same.
    for (1..5) |n| {
        for (0..n) |pos| {
            for ([_]bool{ true, false }) |parsed| {
                var doc = Document.init(testing.allocator);
                defer doc.deinit();
                if (parsed) {
                    doc.deinit();
                    doc = try Document.parse(testing.allocator, ([_][]const u8{ "[a]\n", "[a, b]\n", "[a, b, c]\n", "[a, b, c, d]\n" })[n - 1]);
                    try testing.expect(try internal.sequenceReplace(&doc, doc.root.?, pos, try doc.createScalar("", .plain)));
                } else {
                    const seq = try doc.createSequence();
                    seq.data.sequence.style = .flow;
                    for (0..n) |i| try doc.sequenceAppend(seq, try doc.createScalar(if (i == pos) "" else "x", .plain));
                    doc.root = seq;
                }
                const out = try doc.write(testing.allocator);
                defer testing.allocator.free(out);
                var rt = try Document.parse(testing.allocator, out);
                defer rt.deinit();
                const items = rt.root.?.items().?;
                try testing.expectEqual(n, items.len);
                try testing.expectEqual(document_mod.CoreTag.null, document_mod.resolveCoreTag(items[pos].scalarValue().?, items[pos].data.scalar.style));
            }
        }
    }
}

test "a re-emitted keep-chomped block scalar keeps its value" {
    // A `|+`/`>+` block keeps its trailing line breaks as value, and they
    // sit in the source after its slot, at the start of the next gap. A
    // modified one is re-written with its whole value -- and the gap then
    // replayed the same blank lines, which the keep chomping absorbed:
    // `keep\n\n` came back `keep\n\n\n` on every edit of that node.
    const cases = [_]struct { in: []const u8, path: []const []const u8, out: []const u8 }{
        .{ .in = "- |+\n keep\n\n- x\n", .path = &.{"0"}, .out = "- &z |+\n  keep\n\n- x\n" },
        .{ .in = "a: |+\n  keep\n\nb: x\n", .path = &.{"a"}, .out = "a: &z |+\n   keep\n\nb: x\n" },
        .{ .in = "a: >+\n  keep\n\n\nb: x\n", .path = &.{"a"}, .out = "a: &z >+\n   keep\n\n\nb: x\n" },
        .{ .in = "a: |+\n  keep\n\n", .path = &.{"a"}, .out = "a: &z |+\n   keep\n\n" },
        .{ .in = "a: |+\n  keep\n\n# c\nb: x\n", .path = &.{"a"}, .out = "a: &z |+\n   keep\n\n# c\nb: x\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.in);
        defer doc.deinit();
        const node = doc.root.?.byPath(c.path).?;
        const want = try testing.allocator.dupe(u8, node.scalarValue().?);
        defer testing.allocator.free(want);
        try doc.setAnchor(node, "z");
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.out, out);
        var again = try Document.parse(testing.allocator, out);
        defer again.deinit();
        try testing.expectEqualStrings(want, again.root.?.byPath(c.path).?.scalarValue().?);
    }
}

test "a block scalar the literal form cannot express falls back to quoting" {
    // Found by the emission oracle's `value` mode: `literalSafe` only
    // looked at value[0], so `writeLiteral` produced blocks libfyaml
    // (and the spec) reject -- a body of blank lines only, a first
    // content line the reader would take the block's indentation from,
    // and a tab where indentation is read.
    const values = [_][]const u8{
        "\n", // nothing but a line break
        "\n\n more indented\nregular\n", // first content line is indented
        "literal\n\ttext\n", // a line starting with a tab
        "a\n\tb\n", // ... at any depth
    };
    // Both the styles that can reach `literalSafe`.
    for ([_]ScalarStyle{ .literal, .folded, .any }) |style| {
        for (values) |v| {
            var doc = Document.init(testing.allocator);
            defer doc.deinit();
            doc.root = try doc.createMapping();
            try doc.pathSet(&.{"k"}, try doc.createScalar(v, style));

            const out = try doc.write(testing.allocator);
            defer testing.allocator.free(out);

            var rt = try Document.parse(testing.allocator, out);
            defer rt.deinit();
            try testing.expectEqualStrings(v, rt.pathGet(&.{"k"}).?.scalarValue().?);
        }
    }
}

test "a literal block is still chosen when it can express the value" {
    // The fallback must not swallow the ordinary case.
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    doc.root = try doc.createMapping();
    try doc.pathSet(&.{"k"}, try doc.createScalar("line one\nline two\n", .literal));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("k: |\n  line one\n  line two\n", out);
}

/// Where a swept scalar sits. Each place writes it at a different
/// indent, in block or flow context, with a sibling after it.
const SweepPlace = enum { root, value, key, item, nested, flow_item, flow_key, flow_value };

/// Write `text` in the requested style at `place`, read the output
/// back, and report whether exactly `text` came back from that place
/// (as a string, for `.any`, which is how `yaml.value` builds one). A
/// sibling follows the scalar in every collection, so a scalar that
/// swallows or ends the next line is caught as well.
fn scalarSurvives(allocator: std.mem.Allocator, text: []const u8, style: ScalarStyle, place: SweepPlace) !bool {
    var doc = Document.init(allocator);
    defer doc.deinit();
    const node = try doc.createScalar(text, style);
    switch (place) {
        .root => doc.root = node,
        .item, .flow_item => {
            const seq = try doc.createSequence();
            if (place == .flow_item) seq.data.sequence.style = .flow;
            try doc.sequenceAppend(seq, node);
            try doc.sequenceAppend(seq, try doc.createScalar("z", .plain));
            doc.root = seq;
        },
        .value, .key, .nested, .flow_key, .flow_value => {
            const map = try doc.createMapping();
            if (place == .flow_key or place == .flow_value) map.data.mapping.style = .flow;
            if (place == .key or place == .flow_key) {
                try doc.mappingAppend(map, node, try doc.createScalar("v", .plain));
            } else {
                try doc.mappingAppend(map, try doc.createScalar("k", .plain), node);
            }
            try doc.mappingAppend(map, try doc.createScalar("z", .plain), try doc.createScalar("z", .plain));
            if (place == .nested) {
                // A mapping value inside a sequence item, two levels in.
                const seq = try doc.createSequence();
                try doc.sequenceAppend(seq, map);
                try doc.sequenceAppend(seq, try doc.createScalar("z", .plain));
                doc.root = seq;
            } else doc.root = map;
        },
    }
    const out = try doc.write(allocator);
    defer allocator.free(out);

    var rt = Document.parse(allocator, out) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer rt.deinit();
    var at = rt.root orelse return false;
    if (place == .nested) {
        const items = at.items() orelse return false;
        if (items.len != 2 or !std.mem.eql(u8, items[1].scalarValue() orelse "", "z")) return false;
        at = items[0];
    }
    const back = switch (place) {
        .root => at,
        .item, .flow_item => blk: {
            const items = at.items() orelse return false;
            if (items.len != 2 or !std.mem.eql(u8, items[1].scalarValue() orelse "", "z")) return false;
            break :blk items[0];
        },
        .value, .key, .nested, .flow_key, .flow_value => blk: {
            const pairs = at.pairs() orelse return false;
            if (pairs.len != 2 or !std.mem.eql(u8, pairs[1].key.scalarValue() orelse "", "z")) return false;
            break :blk if (place == .key or place == .flow_key) pairs[0].key else pairs[0].value;
        },
    };
    const s = switch (back.data) {
        .scalar => |s| s,
        else => return false,
    };
    if (!std.mem.eql(u8, s.value, text)) return false;
    return style != .any or document_mod.resolveCoreTag(s.value, s.style) == .str;
}

/// Run `scalarSurvives` over every string up to `max_len` bytes drawn
/// from `alphabet`, in every place and each of `styles`. Fails with the
/// first string that does not survive, after printing it.
fn sweepScalars(alphabet: []const u8, max_len: usize, styles: []const ScalarStyle) !void {
    // Tens of thousands of documents: an arena over the leak-checking
    // allocator, reset per string, keeps the sweep to seconds in Debug.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [8]u8 = undefined;
    std.debug.assert(max_len <= buf.len);
    var digits = [_]usize{0} ** buf.len;
    for (0..max_len + 1) |len| {
        @memset(digits[0..len], 0);
        while (true) {
            for (digits[0..len], 0..) |d, i| buf[i] = alphabet[d];
            const text = buf[0..len];
            for (styles) |style| {
                // An empty PLAIN scalar is YAML's null, not a string:
                // it is written bare on purpose (see `chooseScalarStyle`).
                if (len == 0 and style == .plain) continue;
                for (std.enums.values(SweepPlace)) |place| {
                    defer _ = arena.reset(.retain_capacity);
                    if (!try scalarSurvives(arena.allocator(), text, style, place)) {
                        std.debug.print("did not survive: \"{f}\" style={t} place={t}\n", .{ std.zig.fmtString(text), style, place });
                        return error.TestUnexpectedResult;
                    }
                }
            }
            // Next string of this length (odometer); done when it wraps.
            var i = len;
            while (i > 0) {
                i -= 1;
                digits[i] += 1;
                if (digits[i] < alphabet.len) break;
                digits[i] = 0;
            } else break;
        }
    }
}

test "every short string survives write and re-read, whatever its bytes" {
    // A value's bytes, not its author, decide which styles can express
    // it. Single quotes and block scalars cannot escape anything, so a
    // CR (a line break to the reader), a NUL (rejected by the reader),
    // and ESC or DEL (not printable, YAML 1.2 5.1) written raw in them
    // came back changed or not at all: `a\rb` read back as `a b`, and a
    // CRLF in a literal block lost its CR. Only double quotes can spell
    // those; tab stays legal in every style.
    const alphabet = "a \t\n\r\x00\x1b\x7f\"'\\#:-.%|>";
    try sweepScalars(alphabet, 3, &.{.any});
    try sweepScalars(alphabet, 2, &.{ .plain, .single_quoted, .double_quoted, .literal, .folded });
}

test "a line that would be a document marker keeps a block scalar out of column 0" {
    // A root block scalar's content sits at column 0, where a `---` or
    // `...` line (followed by a blank or the end of the line) is a
    // document marker: `a\n---\nb\n` written as a literal block read
    // back as `a\n`, the rest a second document.
    try sweepScalars("-. \na", 5, &.{ .any, .literal, .folded });
    const cases = [_][]const u8{
        "a\n---\nb\n", "a\n...\nb\n", "x\n--- y\n", "x\n...\tz\n",
        "---\nb\n",    "...\n",       "a\n---",     "a\n...x\nb\n",
        "a\n---x\n",   "a\n ---\n",
    };
    for (cases) |text| {
        for ([_]ScalarStyle{ .any, .literal, .folded }) |style| {
            for (std.enums.values(SweepPlace)) |place| {
                if (!try scalarSurvives(testing.allocator, text, style, place)) {
                    std.debug.print("did not survive: \"{f}\" style={t} place={t}\n", .{ std.zig.fmtString(text), style, place });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
    // The fallback is only for values that need it: a marker-like line
    // that is not a marker, and any marker line below the root, still
    // get a block.
    for ([_]struct { root: bool, text: []const u8, want: []const u8 }{
        .{ .root = true, .text = "a\n---x\nb\n", .want = "|\na\n---x\nb\n" },
        .{ .root = true, .text = "a\n....\nb\n", .want = "|\na\n....\nb\n" },
        .{ .root = true, .text = "a\n---\nb\n", .want = "\"a\\n---\\nb\\n\"\n" },
        .{ .root = false, .text = "a\n---\nb\n", .want = "k: |\n  a\n  ---\n  b\n" },
    }) |c| {
        var doc = Document.init(testing.allocator);
        defer doc.deinit();
        const node = try doc.createScalar(c.text, .any);
        if (c.root) doc.root = node else {
            doc.root = try doc.createMapping();
            try doc.pathSet(&.{"k"}, node);
        }
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
    }
}

test "a laid-out explicit key puts the value indicator on its own line" {
    // `? K: V` on one line is read back as an explicit key that IS the
    // mapping `{K: V}`, with a null value -- so the key and the value
    // both change on a round trip. The entry must be two lines.
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    const root = try doc.createMapping();
    doc.root = root;
    const key = try doc.createSequence();
    try doc.sequenceAppend(key, try doc.createScalar("1", .plain));
    try doc.sequenceAppend(key, try doc.createScalar("2", .plain));
    try doc.mappingAppend(root, key, try doc.createScalar("pair", .plain));
    try doc.mappingAppend(root, try doc.createScalar("a", .plain), try doc.createScalar("1", .plain));

    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("? [1, 2]\n: pair\na: 1\n", out);

    var rt = try Document.parse(testing.allocator, out);
    defer rt.deinit();
    const pairs = rt.root.?.data.mapping.pairs.items;
    try testing.expectEqual(@as(usize, 2), pairs.len);
    try testing.expectEqual(document_mod.NodeKind.sequence, pairs[0].key.kind());
    try testing.expectEqualStrings("pair", pairs[0].value.scalarValue().?);
    try testing.expectEqualStrings("a", pairs[1].key.scalarValue().?);
}

test "an explicit key with a mapping key and with a null value both re-read" {
    // A mapping as the key is the case `? K: V` corrupts most visibly,
    // and a null value must not leave a dangling `: ` either.
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    const root = try doc.createMapping();
    doc.root = root;
    const mkey = try doc.createMapping();
    try doc.mappingAppend(mkey, try doc.createScalar("x", .plain), try doc.createScalar("1", .plain));
    try doc.mappingAppend(root, mkey, try doc.createScalar("pair", .plain));
    const nkey = try doc.createSequence();
    try doc.sequenceAppend(nkey, try doc.createScalar("n", .plain));
    try doc.mappingAppend(root, nkey, try doc.createScalar("", .plain));

    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("? {x: 1}\n: pair\n? [n]\n:\n", out);

    var rt = try Document.parse(testing.allocator, out);
    defer rt.deinit();
    const pairs = rt.root.?.data.mapping.pairs.items;
    try testing.expectEqual(@as(usize, 2), pairs.len);
    try testing.expectEqual(document_mod.NodeKind.mapping, pairs[0].key.kind());
    try testing.expectEqualStrings("pair", pairs[0].value.scalarValue().?);
    try testing.expectEqual(document_mod.NodeKind.sequence, pairs[1].key.kind());
}

test "an explicit key whose value is a block collection re-reads" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    const root = try doc.createMapping();
    doc.root = root;
    const key = try doc.createSequence();
    try doc.sequenceAppend(key, try doc.createScalar("k", .plain));
    const value = try doc.createMapping();
    try doc.mappingAppend(value, try doc.createScalar("deep", .plain), try doc.createScalar("v", .plain));
    try doc.mappingAppend(root, key, value);

    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);

    var rt = try Document.parse(testing.allocator, out);
    defer rt.deinit();
    const pairs = rt.root.?.data.mapping.pairs.items;
    try testing.expectEqual(@as(usize, 1), pairs.len);
    try testing.expectEqual(document_mod.NodeKind.sequence, pairs[0].key.kind());
    try testing.expectEqualStrings("v", pairs[0].value.lookup("deep").?.scalarValue().?);
}

test "an explicit key appended to a parsed document keeps the neighbours verbatim" {
    var doc = try Document.parse(testing.allocator, "a: 1  # kept\n");
    defer doc.deinit();
    const key = try doc.createSequence();
    try doc.sequenceAppend(key, try doc.createScalar("x", .plain));
    try doc.mappingAppend(doc.root.?, key, try doc.createScalar("pair", .plain));

    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: 1  # kept\n? [x]\n: pair\n", out);

    var rt = try Document.parse(testing.allocator, out);
    defer rt.deinit();
    const pairs = rt.root.?.data.mapping.pairs.items;
    try testing.expectEqual(@as(usize, 2), pairs.len);
    try testing.expectEqual(document_mod.NodeKind.sequence, pairs[1].key.kind());
    try testing.expectEqualStrings("pair", pairs[1].value.scalarValue().?);
}

test "an unmodified explicit key still re-emits from its source span" {
    // The fix touches only the laid-out path; a parsed entry nobody
    // edited keeps its original bytes, whatever shape they had.
    const src = "? [1, 2]\n: pair\nkeep: me\n";
    const out = try roundTrip(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "an anchor set on or cleared from a parsed key is written" {
    // `key_clean` only asked whether the key had a source span, never
    // whether it was modified, so a parsed key was always copied from
    // its old bytes: `setAnchor(key, "x")` on `k: v` wrote `k: v`, and
    // the new anchor was silently lost. Values already went through
    // `nodeClean`, which is why `k: &x v` worked.
    const cases = [_]struct { in: []const u8, key: []const u8 = "k", item: bool = false, anchor: ?[]const u8, out: []const u8 }{
        .{ .in = "k: v\n", .anchor = "x", .out = "&x k: v\n" },
        .{ .in = "&x k: v\n", .anchor = null, .out = "k: v\n" },
        .{ .in = "&x k: v\n", .anchor = "y", .out = "&y k: v\n" },
        .{ .in = "!!str k: v\n", .anchor = "x", .out = "&x !!str k: v\n" },
        .{ .in = "\"q k\": v\n", .key = "q k", .anchor = "x", .out = "&x \"q k\": v\n" },
        // Next to an untouched sibling key, whose bytes stay as written.
        .{ .in = "a:   1 # one\nk: v # two\n", .anchor = "x", .out = "a:   1 # one\n&x k: v # two\n" },
        .{ .in = "k:\n  z: 1\nj: 2\n", .anchor = "x", .out = "&x k:\n  z: 1\nj: 2\n" },
        .{ .in = "k:\nj: 2\n", .anchor = "x", .out = "&x k:\nj: 2\n" },
        // The key's `- ` and `? ` framing is the author's and stays.
        .{ .in = "- k: v\n  j: w\n", .item = true, .anchor = "x", .out = "- &x k: v\n  j: w\n" },
        .{ .in = "? k\n: v\n", .anchor = "x", .out = "? &x k\n: v\n" },
        .{ .in = "- ? k\n  : v\n", .item = true, .anchor = "x", .out = "- ? &x k\n  : v\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.in);
        defer doc.deinit();
        const map = if (c.item) doc.root.?.items().?[0] else doc.root.?;
        const pairs = map.pairs().?;
        // Any key but `c.key` is an untouched sibling.
        const key = for (pairs) |p| {
            if (std.mem.eql(u8, p.key.scalarValue().?, c.key)) break p.key;
        } else unreachable;
        try doc.setAnchor(key, c.anchor);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.out, out);
    }
}

test "a normalized scalar key keeps its anchor and tag" {
    const allocator = testing.allocator;

    // Regression: `emitEntry`'s scalar arm wrote only the key text, so an
    // anchored or tagged scalar KEY lost its properties (non-scalar keys
    // went through `emitFlowNode`, which kept them). `&k key: v` with a
    // `*k` elsewhere then emitted an undefined alias.
    {
        var doc = Document.init(allocator);
        defer doc.deinit();
        const root = try doc.createMapping();
        doc.root = root;
        const key = try doc.createScalar("name", .plain);
        try doc.setAnchor(key, "k");
        key.tag = "tag:yaml.org,2002:str";
        try doc.mappingAppend(root, key, try doc.createScalar("v", .plain));
        const out = try doc.write(allocator);
        defer allocator.free(out);
        try testing.expectEqualStrings("&k !!str name: v\n", out);
    }
    {
        // The flow path follows the same rule.
        var doc = Document.init(allocator);
        defer doc.deinit();
        const root = try doc.createMapping();
        doc.root = root;
        switch (root.data) {
            .mapping => |*m| m.style = .flow,
            else => unreachable,
        }
        const key = try doc.createScalar("name", .plain);
        try doc.setAnchor(key, "k");
        try doc.mappingAppend(root, key, try doc.createScalar("v", .plain));
        const out = try doc.write(allocator);
        defer allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "&k name") != null);
    }
}

test "indent inference is depth-bounded, so a deep graft cannot overflow the stack" {
    const allocator = testing.allocator;

    // The faithful emitter measures the document's indent convention
    // BEFORE the depth-checked walk. That pre-walk recursion was
    // unbounded, so a deep subtree grafted into a parsed document (a
    // 60k-deep sequence reached through `Editor.set`) segfaulted instead
    // of returning `error.NestingTooDeep`. Build the chain directly, so
    // the test bypasses the O(depth) mark-modified walk and stays fast.
    var doc = try Document.parse(allocator, "a: 1\n");
    defer doc.deinit();
    const root = try doc.createSequence();
    var cur = root;
    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        const next = try doc.createSequence();
        switch (cur.data) {
            .sequence => |*s| try s.items.append(doc.pool.allocator(), next),
            else => unreachable,
        }
        next.parent = cur;
        cur = next;
    }
    doc.root = root;

    // A typed error, not a stack overflow in the pre-walk measurement.
    try std.testing.expectError(error.NestingTooDeep, doc.write(allocator));
}
