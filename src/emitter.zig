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
        if (!self.endsWithNewline()) try self.writeByte('\n');
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
        if (!self.endsWithNewline()) try self.writeByte('\n');
        try self.writeIndent(indent);
    }

    /// True when the pending line holds nothing but block-entry framing:
    /// indentation and `- ` indicators. The cursor then already sits
    /// where an entry belongs (`- ` left behind by a deleted first
    /// entry, or a nested `- - `), so no line break is owed.
    fn isEntryFraming(pending: []const u8) bool {
        var i: usize = 0;
        while (i < pending.len and pending[i] == ' ') i += 1;
        while (i < pending.len) {
            if (pending[i] != '-') return false;
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
        try self.writeByte('\n');
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
            try self.writeByte('\n');
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
            try self.writeByte('\n');
            have_directives = true;
        }

        const root = doc.root orelse {
            if (have_directives) try self.write("---\n");
            return;
        };

        if (have_directives or doc.explicit_start) try self.write("---\n");
        try self.emitNode(root, 0);
        if (!self.endsWithNewline()) try self.writeByte('\n');
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
                if (self.inferIndentStep(root)) |step| {
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
            stop = try self.emitRoot(root, markup.columnOf(src, doc.body_start), doc.body_end);
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
                    try self.writeByte('\n');
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
                try self.writeByte('\n');
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
            if (std.mem.indexOfNone(u8, src[g..nl], " \t\r") != null) break; // content line
            g = if (nl < src.len) nl + 1 else src.len;
        }
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
        const key_clean = ks != null and !ks.?.synthetic;
        const pair_end = pair.src_end;
        const value_empty = pairEndsAtColon(pair);

        // Leading gap: original bytes up to the entry's key. Brand-new
        // pairs derive their own newline + column instead and leave the
        // gap anchor untouched for the next original sibling.
        if (ks) |s| {
            if (!s.synthetic) {
                // A written leading block replaces the entry's own
                // lines: stop the verbatim gap at the entry's line
                // start (the tombstoned old block is already skipped in
                // there), write the new lines, then re-assemble the
                // entry's line -- indentation, framing indicator, key.
                const pending = internal.pairLeadingOverride(src, key, value);
                if (pending != null) {
                    const ls = markup.lineStart(src, s.entry_start);
                    try self.writeGap(container, gap_start, ls);
                    const col = markup.columnOf(src, s.entry_start);
                    try self.writePendingLeadingText(pending, col, self.terminatorAt(s.entry_start));
                    try self.write(src[s.entry_start..s.start]);
                } else {
                    try self.writeGap(container, gap_start, s.entry_start);
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
            if (owed_terminator and !self.endsWithNewline()) try self.writeByte('\n');
            return gap;
        }

        // Key.
        const expl = key_clean and explicitKeySpan(src, ks.?.entry_start, ks.?.start);
        if (key_clean) {
            try self.emitted.put(key, {});
            try self.write(src[ks.?.entry_start..ks.?.end]);
        } else {
            try self.emitted.put(key, {});
            _ = try self.emitContent(key, if (ks) |s| markup.columnOf(src, s.start) else entry_col);
        }

        // Valueless entry (`key:` / `? key`): emit the original colon
        // bytes and stop.
        if (value_empty) {
            if (ks != null and pair_end != null) {
                try self.write(src[ks.?.end..pair_end.?]);
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
                        try self.write(src[s.end..vs.entry_start]);
                        try self.indentEmptied(markup.columnOf(src, s.entry_start));
                    } else if (value.pending_leading != null and
                        markup.lineStart(src, vs.entry_start) != markup.lineStart(src, s.start))
                    {
                        // A written leading block for a BLOCK value
                        // replaces the comment lines between the key's
                        // colon and the value's first line. The verbatim
                        // gap stops after its last newline -- the lines'
                        // indentation is re-written below with the new
                        // block. (An inline value's block belongs to the
                        // pair and was already written at the key's gap.)
                        const vls = markup.lineStart(src, vs.entry_start);
                        const split = s.end + if (std.mem.lastIndexOfScalar(u8, src[s.end..vls], '\n')) |idx|
                            idx + 1
                        else
                            0;
                        try self.writeGap(value, s.end, split);
                        const vcol = markup.columnOf(src, vs.entry_start);
                        try self.writePendingLeadingText(value.pending_leading, vcol, self.terminatorAt(vs.entry_start));
                    } else {
                        try self.writeGap(value, s.end, vs.entry_start);
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
                if (self.endsWithNewline()) return le;
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
            if (self.endsWithNewline()) return le;
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
            if (owed_terminator and !self.endsWithNewline()) try self.writeByte('\n');
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
        if (item.pending_leading != null) {
            // A written leading block replaces the item's own comment
            // lines; the verbatim gap stops at the item's line start
            // (tombstoned old lines are already skipped in there). The
            // entry's line is re-assembled here: indentation, then the
            // `- ` framing the walk's content emission assumes copied.
            const ls = markup.lineStart(src, s.entry_start);
            try self.writeGap(container, gap_start, ls);
            const col = markup.columnOf(src, s.entry_start);
            try self.writePendingLeadingText(item.pending_leading, col, self.terminatorAt(s.entry_start));
            try self.write(src[s.entry_start..s.start]);
        } else {
            try self.writeGap(container, gap_start, s.entry_start);
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
            // and a refilled `- {}` did not parse at all. A written
            // leading block re-assembled the line above already.
            if (item.pending_leading == null and !framingOwnedByContent(item)) {
                try self.write(src[s.entry_start..s.start]);
            }
            const stop = try self.emitContent(item, markup.columnOf(src, s.start));
            // A container walk that re-emitted its last entry already
            // consumed the line terminator; writing the remainder on top
            // of that would append a blank line after the item.
            const le = markup.lineEnd(src, s.end);
            if (stop >= le) return stop;
            if (self.endsWithNewline()) return le;
            return self.writeEntryTail(item, s.end);
        }
        // Synthesized empty item: the entry shell only.
        try self.emitted.put(item, {});
        try self.write(src[s.entry_start..s.start]);
        return s.end;
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
                try self.emitScalarValue(s.value, s.style, indent, true);
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
    fn inferIndentStep(self: *const Emitter, node: *const Node) ?usize {
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
                    if (self.inferIndentStep(pair.value)) |d| return d;
                }
            },
            .sequence => |sq| {
                for (sq.items.items) |item| {
                    if (self.inferIndentStep(item)) |d| return d;
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
    /// indentation the entry itself continues on. The caller must have
    /// stopped copying the original gap at the entry's line start (see
    /// the split-gap sites); the empty override (a deletion) writes
    /// nothing — the tombstoned block is already skipped in the gap.
    fn writePendingLeadingText(self: *Emitter, pending: ?[]const u8, col: usize, term: []const u8) Error!void {
        const t = pending orelse return;
        if (t.len == 0) return;
        // An empty output is at a line start already: breaking here put
        // a blank line ahead of a comment written on the first item.
        if (self.out.items.len > 0 and !self.endsWithNewline()) try self.writeByte('\n');
        var it = std.mem.splitScalar(u8, t, '\n');
        while (it.next()) |line| {
            try self.writeIndent(col);
            try self.write(line);
            try self.write(term);
        }
        try self.writeIndent(col);
    }

    fn writeNewlineIndent(self: *Emitter, indent: usize) Error!void {
        try self.writeByte('\n');
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
                try self.emitScalarValue(s.value, s.style, indent, true);
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
            .scalar => |s| {
                try self.emitScalarValue(s.value, s.style, indent, false);
                try self.writeByte(':');
            },
            else => {
                // Explicit key (spec 7.4.2) in compact flow form.
                try self.write("? ");
                try self.emitFlowNode(key);
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
                        try self.emitFlowBody(item);
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
            .scalar => |s| try self.emitScalarValue(s.value, s.style, 0, false),
            .alias => |a| {
                try self.writeByte('*');
                try self.write(a.name);
            },
            .mapping => |*m| {
                try self.writeByte('{');
                for (m.pairs.items, 0..) |pair, i| {
                    if (i > 0) try self.write(", ");
                    switch (pair.key.data) {
                        .scalar => |s| try self.emitScalarValue(s.value, s.style, 0, false),
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
                    try self.emitFlowNode(item);
                }
                try self.writeByte(']');
            },
        }
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

    fn emitScalarValue(self: *Emitter, value: []const u8, prefer: ScalarStyle, indent: usize, block_ok: bool) Error!void {
        const style = chooseScalarStyle(value, prefer, block_ok);
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

    fn chooseScalarStyle(value: []const u8, prefer: ScalarStyle, block_ok: bool) ScalarStyle {
        if (value.len == 0) {
            // An empty PLAIN scalar is YAML's null -- `key:` with
            // nothing after it -- and null is not the empty string.
            // Quoting it would silently turn one into the other, which
            // is how a moved `push:` came out as `push: ""`. Any other
            // requested style for an empty value means the string.
            return if (prefer == .plain) .plain else .double_quoted;
        }
        const has_break = std.mem.indexOfScalar(u8, value, '\n') != null;
        if (has_break) {
            // Modified scalars keep their parsed block style when the
            // content can be re-emitted losslessly in it.
            if (block_ok and prefer == .folded and foldedSafe(value)) return .folded;
            if (block_ok and literalSafe(value)) return .literal;
            return .double_quoted;
        }
        switch (prefer) {
            .single_quoted => return .single_quoted,
            .double_quoted => return .double_quoted,
            .literal, .folded => return .double_quoted,
            .any, .plain => {},
        }
        if (plainSafe(value)) return .plain;
        return .single_quoted;
    }

    fn literalSafe(value: []const u8) bool {
        if (value.len == 0) return false;
        // A leading space would need an explicit indentation indicator.
        if (value[0] == ' ') return false;
        return true;
    }

    /// A folded re-emission must re-parse to exactly `value`: no leading
    /// blank line, no more-indented lines, no tabs, and no trailing
    /// whitespace on any line (folding strips those).
    fn foldedSafe(value: []const u8) bool {
        if (value.len == 0) return false;
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
