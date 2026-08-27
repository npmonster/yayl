//! Emitter — Zig port of libfyaml's fy-emit.
//!
//! Serialises a `Document` back to YAML text. Block style is the default;
//! collections parsed from flow style (and empty collections) are emitted
//! in flow style. Scalar styles are honoured when safe, with quoting rules
//! that guarantee the re-parsed value is identical.
//!
//! PORT NOTE: libfyaml's emitter is CST based and reproduces the original
//! formatting byte for byte in round-trip mode. This port emits from the
//! semantic document tree: comments are not preserved yet and layout is
//! normalised. Closing that gap is tracked in AGENTS.md.

const std = @import("std");
const document_mod = @import("document.zig");
const token_mod = @import("token.zig");

const Document = document_mod.Document;
const Node = document_mod.Node;
const ScalarStyle = token_mod.ScalarStyle;

const yaml_tag_prefix = "tag:yaml.org,2002:";

/// Serializes a document node tree to YAML text (fy-emit port).
pub const Emitter = struct {
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    /// Anchored nodes already emitted: re-emission becomes an alias.
    seen: std.AutoHashMap(*const Node, []const u8),
    indent_step: usize = 2,

    /// Emission only fails when the output buffer cannot grow.
    pub const Error = std.mem.Allocator.Error;

    pub fn init(alloc: std.mem.Allocator, out: *std.ArrayList(u8)) Emitter {
        return .{
            .alloc = alloc,
            .out = out,
            .seen = std.AutoHashMap(*const Node, []const u8).init(alloc),
        };
    }

    pub fn deinit(self: *Emitter) void {
        self.seen.deinit();
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

    pub fn emitDocument(self: *Emitter, doc: *const Document) Error!void {
        var have_directives = false;
        if (doc.version) |v| {
            var buf: [32]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "%YAML {d}.{d}\n", .{ v.major, v.minor }) catch unreachable;
            try self.write(line);
            have_directives = true;
        }
        for (doc.tag_directives.items) |td| {
            var buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "%TAG {s} {s}\n", .{ td.handle, td.prefix }) catch unreachable;
            try self.write(line);
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
        const inline_value = switch (value.data) {
            .scalar => true,
            .mapping => |m| m.pairs.items.len == 0 or m.style == .flow,
            .sequence => |s| s.items.items.len == 0 or s.style == .flow,
        };
        if (inline_value) {
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
            .literal, .folded => try self.writeLiteral(value, indent),
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

    fn writeLiteral(self: *Emitter, value: []const u8, indent: usize) Error!void {
        var core = value;
        var trailing: usize = 0;
        while (core.len > 0 and core[core.len - 1] == '\n') {
            trailing += 1;
            core = core[0 .. core.len - 1];
        }
        try self.writeByte('|');
        if (trailing == 0) {
            try self.writeByte('-');
        } else if (trailing > 1) {
            try self.writeByte('+');
        }
        try self.writeByte('\n');

        var it = std.mem.splitScalar(u8, core, '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first) try self.writeByte('\n');
            first = false;
            try self.writeIndent(indent);
            try self.write(line);
        }
        for (0..trailing) |_| try self.writeByte('\n');
    }

    fn chooseScalarStyle(value: []const u8, prefer: ScalarStyle, block_ok: bool) ScalarStyle {
        if (value.len == 0) return .double_quoted;
        const has_break = std.mem.indexOfScalar(u8, value, '\n') != null;
        if (has_break) {
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
