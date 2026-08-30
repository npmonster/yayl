//! Emitter — Zig port of libfyaml's fy-emit.
//!
//! Serialises a `Document` back to YAML text. Two modes:
//!
//! *Faithful* (parsed documents, PLAN-4): every node carries a span
//! into the original source; untouched regions re-emit byte for byte
//! (comments, blank lines, quoting, key order, indentation), and only
//! modified subtrees are re-emitted, in place, with the surrounding
//! bytes preserved. This is libfyaml's round-trip behaviour.
//!
//! *Normalized* (programmatic documents): emitted from the semantic
//! tree. Block style is the default; collections parsed from flow style
//! (and empty collections) are emitted in flow style. Scalar styles are
//! honoured when safe, with quoting rules that guarantee the re-parsed
//! value is identical.
//!
//! PORT NOTE: libfyaml's CST covers every byte including intra-node
//! layout; this port keeps per-node/entry spans, so re-emitted
//! subtrees normalize their internal layout (e.g. multi-line flow
//! collapses to one line). Untouched bytes are exact.

const std = @import("std");
const diag = @import("diag.zig");
const document_mod = @import("document.zig");
const markup = @import("markup.zig");
const token_mod = @import("token.zig");

const Document = document_mod.Document;
const Node = document_mod.Node;
const Pair = document_mod.Pair;
const ScalarStyle = token_mod.ScalarStyle;

const yaml_tag_prefix = "tag:yaml.org,2002:";

/// Serializes a document node tree to YAML text (fy-emit port).
pub const Emitter = struct {
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    /// Anchored nodes already emitted: re-emission becomes an alias.
    seen: std.AutoHashMap(*const Node, []const u8),
    /// Nodes emitted by the faithful walker (cycle/duplicate guard for
    /// programmatically shared nodes).
    emitted: std.AutoHashMap(*const Node, void),
    /// Active source for faithful emission (empty when normalized).
    src: []const u8 = "",
    indent_step: usize = 2,

    /// Emission fails on output allocation or on a programmatic node
    /// graph that cannot be serialized (unanchored cycle).
    pub const Error = std.mem.Allocator.Error || diag.YamlError;

    pub fn init(alloc: std.mem.Allocator, out: *std.ArrayList(u8)) Emitter {
        return .{
            .alloc = alloc,
            .out = out,
            .seen = std.AutoHashMap(*const Node, []const u8).init(alloc),
            .emitted = std.AutoHashMap(*const Node, void).init(alloc),
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
        try self.out.appendSlice(self.alloc, bytes);
    }

    fn writeByte(self: *Emitter, b: u8) Error!void {
        try self.out.append(self.alloc, b);
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

    fn endsWithNewline(self: *const Emitter) bool {
        return self.out.items.len > 0 and self.out.items[self.out.items.len - 1] == '\n';
    }

    // ------------------------------------------------------------------
    // Document level
    // ------------------------------------------------------------------

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
    // Faithful emission (PLAN-4): unmodified subtrees re-emit verbatim.
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
        try self.write(src[doc.region_start..doc.body_start]);
        var stop = doc.body_start;
        if (doc.root) |root| {
            stop = try self.emitRoot(root, markup.columnOf(src, doc.body_start), doc.body_end);
        }
        if (stop < doc.region_end) {
            // Deleted-entry tombstones of the root container can reach
            // into the tail (when the last surviving entry is new).
            const before = self.out.items.len;
            if (doc.root != null and doc.root.?.src != null) {
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
            // line remainder (trailing comment) and tail from there.
            .scalar, .alias => {
                _ = try self.emitContent(node, indent);
                return self.writeRemainder(s.end);
            },
            // Modified container: its slot walk consumes through the
            // last entry's line end.
            else => return self.emitContent(node, indent),
        }
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
                try self.writeGap(container, gap_start, s.entry_start);
            }
        } else if (pair_end == null) {
            // Brand-new pair: the previous entry's remainder already
            // ended the line when it was re-emitted in place.
            if (!self.endsWithNewline()) try self.writeNewlineIndent(entry_col);
            try self.emitEntry(key, value, entry_col);
            return gap_start;
        }

        // Key.
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
                return self.writeRemainder(pair_end.?);
            }
            try self.writeByte(':');
            if (pair_end) |pe| return self.writeRemainder(pe);
            return gap_start;
        }

        // Colon bytes between key and value, then the value itself.
        if (value.src) |vs| {
            if (!vs.synthetic) {
                // Original layout (": " or a block ":\n    ").
                if (ks) |s| try self.write(src[s.end..vs.entry_start]);
                if (try self.writeCleanSlice(value, vs.entry_start)) |vend| {
                    return self.writeRemainder(pair_end orelse vend);
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
                return self.writeRemainder(base);
            }
            // Replaced by an empty value node: normalized colon.
            try self.write(": ");
            _ = try self.emitContent(value, entry_col + self.indent_step);
            if (pair_end) |pe| return self.writeRemainder(pe);
            return gap_start;
        }
        // Brand-new value: layout by its shape.
        if (inlineValue(value)) {
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
            return self.writeRemainder(pe);
        }
        return gap_start;
    }

    /// Emit a sequence item slot; same gap contract as `emitPair`.
    fn emitItem(self: *Emitter, container: *const Node, item: *Node, entry_col: usize, gap_start: usize) Error!usize {
        const src = self.src;
        const s = item.src orelse {
            // Brand-new or moved item: sibling-local indentation.
            if (!self.endsWithNewline()) try self.writeNewlineIndent(entry_col);
            try self.write("- ");
            _ = try self.emitContent(item, entry_col + 2);
            return gap_start;
        };
        if (self.emitted.contains(item)) {
            if (item.anchor) |a| {
                try self.writeGap(container, gap_start, s.entry_start);
                try self.writeByte('*');
                try self.write(a);
                return markup.lineEnd(src, s.end);
            }
            return error.AliasCycle;
        }
        try self.writeGap(container, gap_start, s.entry_start);
        if (!s.synthetic) {
            if (try self.writeCleanSlice(item, s.entry_start)) |end| return end;
            try self.emitted.put(item, {});
            _ = try self.emitContent(item, markup.columnOf(src, s.start));
            return self.writeRemainder(s.end);
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
                if (node.src == null or m.style == .flow or m.pairs.items.len == 0) {
                    // New, flow-styled, or emptied in place: block
                    // layout cannot express an empty mapping.
                    try self.emitFlowNode(node);
                    // The line terminator was not consumed.
                    return if (node.src) |sn| sn.end else 0;
                }
                var gap = node.src.?.start;
                const col = self.entryColumn(node, indent);
                for (m.pairs.items) |pair| {
                    gap = try self.emitPair(node, pair, col, gap);
                }
                return gap;
            },
            .sequence => |*sq| {
                if (node.src == null or sq.style == .flow or sq.items.items.len == 0) {
                    try self.emitFlowNode(node);
                    // The line terminator was not consumed.
                    return if (node.src) |sn| sn.end else 0;
                }
                var gap = node.src.?.start;
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
        if (v.nodeType() != .scalar) return false;
        if (v.data.scalar.value.len != 0) return false;
        const vs = v.src orelse return false;
        return vs.synthetic;
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
    fn entryColumn(self: *Emitter, node: *Node, fallback: usize) usize {
        const src = self.src;
        switch (node.data) {
            .mapping => |m| {
                for (m.pairs.items) |pair| {
                    if (pair.key.src) |s| {
                        if (!s.synthetic) return markup.columnOf(src, s.entry_start);
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

    /// Write the rest of the line after `offset` (trailing comment,
    /// line terminator) and return the offset just past it.
    fn writeRemainder(self: *Emitter, offset: usize) Error!usize {
        const src = self.src;
        const le = markup.lineEnd(src, offset);
        if (offset < le) try self.write(src[offset..le]);
        return le;
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
                // Complex key in compact flow form.
                try self.write("? ");
                try self.emitFlowNode(key);
                try self.writeByte(':');
            },
        }

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
        if (value.len == 0) return .double_quoted;
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

fn roundTrip(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var doc = try Document.parse(alloc, input);
    defer doc.deinit();
    return doc.write(alloc);
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
