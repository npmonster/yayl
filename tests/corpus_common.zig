//! Shared corpus loading for the data-driven test harnesses
//! (conformance + round trip). The corpus files are themselves YAML:
//! one document holding a sequence of test records with `yaml`,
//! `tree`, `fail` and `name` fields, using visible markers for
//! invisible characters.

const std = @import("std");
const yaml = @import("yayl");

pub const corpus_dir = "vendor/yaml-test-suite/src";

pub const Case = struct {
    id: []const u8,
    name: []const u8,
    input: []const u8,
    tree: ?[]const u8,
    fail: bool,
};

pub fn freeCase(allocator: std.mem.Allocator, c: *const Case) void {
    allocator.free(c.id);
    allocator.free(c.name);
    allocator.free(c.input);
    if (c.tree) |t| allocator.free(t);
}

pub fn loadCases(allocator: std.mem.Allocator, io: std.Io, cases: *std.ArrayList(Case)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, corpus_dir, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    for (names.items) |name| {
        const text = try dir.readFileAlloc(io, name, allocator, .limited(1 << 20));
        defer allocator.free(text);
        const id = name[0 .. name.len - ".yaml".len];

        var docs = try yaml.parseAll(allocator, text);
        defer {
            for (docs.items) |*d| d.deinit();
            docs.deinit(allocator);
        }
        if (docs.items.len == 0) continue;
        const root = docs.items[0].root orelse continue;
        const records = root.items() orelse continue;

        var index: usize = 0;
        for (records) |record| {
            index += 1;
            const name_val = record.lookup("name") orelse continue;
            const yaml_val = record.lookup("yaml") orelse continue;
            const tree_node = record.lookup("tree");
            const fail_node = record.lookup("fail");

            const case_id = if (records.len > 1)
                try std.fmt.allocPrint(allocator, "{s}-{d}", .{ id, index })
            else
                try allocator.dupe(u8, id);
            errdefer allocator.free(case_id);

            try cases.append(allocator, .{
                .id = case_id,
                .name = try allocator.dupe(u8, name_val.scalarValue() orelse "?"),
                .input = try replaceMarker(allocator, yaml_val.scalarValue() orelse ""),
                .tree = if (tree_node) |t| try replaceMarker(allocator, t.scalarValue() orelse "") else null,
                .fail = if (fail_node) |f| std.mem.eql(u8, f.scalarValue() orelse "", "true") else false,
            });
        }
    }
}

/// The corpus encodes invisible characters with visible markers (see the
/// corpus ReadMe):
///
///   ␣ U+2423  significant trailing space
///   —…»       hard tab; up to 3 spaces before the marker are the tab's
///             column padding and collapse into the tab
///   ↵ U+21B5  trailing-newline visibility marker (dropped; the real
///             newline is the line separator that follows it)
///   ← U+2190  carriage return
///   ⇔ U+21D4  byte order mark
///   ∎ U+220E  end of input (no final newline); terminates the input
pub fn replaceMarker(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const space_marker = "\xE2\x90\xA3"; // ␣
    const eof_marker = "\xE2\x88\x8E"; // ∎
    const newline_marker = "\xE2\x86\xB5"; // ↵
    const cr_marker = "\xE2\x86\x90"; // ←
    const bom_marker = "\xE2\x87\x94"; // ⇔
    const em_dash = "\xE2\x80\x94"; // —
    const guillemet = "\xC2\xBB"; // »

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        const rest = input[i..];
        if (starts(rest, eof_marker)) break;
        if (starts(rest, space_marker)) {
            try out.append(allocator, ' ');
            i += space_marker.len;
        } else if (starts(rest, newline_marker)) {
            // ↵ is a *visibility* marker for a trailing newline: every
            // occurrence in the corpus is immediately followed by a real
            // '\n' (the block-scalar line separator), so emitting another
            // newline here would double it (corpus JEF9-1/K858 keep
            // chomping counts). Drop the marker only.
            i += newline_marker.len;
        } else if (starts(rest, cr_marker)) {
            try out.append(allocator, '\r');
            i += cr_marker.len;
        } else if (starts(rest, bom_marker)) {
            try out.appendSlice(allocator, "\xEF\xBB\xBF");
            i += bom_marker.len;
        } else if (starts(rest, em_dash) or starts(rest, guillemet)) {
            // Hard-tab marker: `—*»` (any run of U+2014 then U+00BB) is a
            // single tab. Surrounding spaces are preserved — block/flow
            // scalar indentation, not the harness, decides which spaces
            // are content (YAMLTestSuite.pm `s/—*»/\t/g`).
            while (starts(input[i..], em_dash)) i += em_dash.len;
            if (starts(input[i..], guillemet)) i += guillemet.len;
            try out.append(allocator, '\t');
        } else {
            try out.append(allocator, input[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn starts(haystack: []const u8, needle: []const u8) bool {
    return haystack.len >= needle.len and std.mem.eql(u8, haystack[0..needle.len], needle);
}

/// Print each collected diagnostic as `line:column: message`.
pub fn dumpDiags(diag: yaml.Diag) void {
    for (diag.list.items) |d| {
        std.debug.print("    diag {d}:{d}: {s}\n", .{ d.mark.line, d.mark.column, d.message });
    }
}

/// Render the parser's event stream in the corpus tree notation:
/// `+STR/+DOC/+SEQ/+MAP/...` with one space of indent per open container,
/// anchors as `&name`, resolved tags as `<uri>`, scalar styles as
/// `: ' " | >` prefixes, and `\`, `\n`, `\t`, `\r` escaped in values.
pub fn renderTree(allocator: std.mem.Allocator, input: []const u8, verbose: bool) ![]u8 {
    var diag: yaml.Diag = .{ .allocator = allocator };
    defer diag.deinit();
    var p = yaml.Parser.init(allocator, &diag, input) catch |err| {
        if (verbose) dumpDiags(diag);
        return err;
    };
    defer p.deinit();

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var depth: usize = 0;
    while (true) {
        const next = p.nextEvent() catch |err| {
            if (verbose) dumpDiags(diag);
            return err;
        };
        const ev = next orelse break;
        switch (ev.data) {
            .stream_start => {
                try writeLine(&buf, allocator, depth, "+STR");
                depth += 1;
            },
            .stream_end => {
                depth -= 1;
                try writeLine(&buf, allocator, depth, "-STR");
            },
            .document_start => |d| {
                try writeLine(&buf, allocator, depth, if (!d.implicit) "+DOC ---" else "+DOC");
                depth += 1;
            },
            .document_end => |d| {
                depth -= 1;
                try writeLine(&buf, allocator, depth, if (!d.implicit) "-DOC ..." else "-DOC");
            },
            .sequence_start => |cs| {
                try bufPrintMeta(&buf, allocator, depth, "+SEQ", if (cs.style == .flow) " []" else "", cs.anchor, cs.tag);
                try buf.append(allocator, '\n');
                depth += 1;
            },
            .mapping_start => |cs| {
                try bufPrintMeta(&buf, allocator, depth, "+MAP", if (cs.style == .flow) " {}" else "", cs.anchor, cs.tag);
                try buf.append(allocator, '\n');
                depth += 1;
            },
            .sequence_end => {
                depth -= 1;
                try writeLine(&buf, allocator, depth, "-SEQ");
            },
            .mapping_end => {
                depth -= 1;
                try writeLine(&buf, allocator, depth, "-MAP");
            },
            .scalar => |s| {
                try bufPrintMeta(&buf, allocator, depth, "=VAL", "", s.anchor, s.tag);
                try buf.append(allocator, ' ');
                try buf.append(allocator, styleChar(s.style));
                try appendEscaped(&buf, allocator, s.value);
                try buf.append(allocator, '\n');
            },
            .alias => |a| {
                try indent(&buf, allocator, depth);
                try buf.print(allocator, "=ALI *{s}\n", .{a});
            },
        }
    }
    return try buf.toOwnedSlice(allocator);
}

pub fn bufPrintMeta(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, depth: usize, head: []const u8, style_suffix: []const u8, anchor: ?[]const u8, tag: ?[]const u8) !void {
    try indent(buf, allocator, depth);
    try buf.appendSlice(allocator, head);
    try buf.appendSlice(allocator, style_suffix);
    if (anchor) |a| {
        try buf.append(allocator, ' ');
        try buf.append(allocator, '&');
        try buf.appendSlice(allocator, a);
    }
    if (tag) |t| {
        try buf.print(allocator, " <{s}>", .{t});
    }
}

pub fn writeLine(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, depth: usize, text: []const u8) !void {
    try indent(buf, allocator, depth);
    try buf.appendSlice(allocator, text);
    try buf.append(allocator, '\n');
}

pub fn indent(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try buf.append(allocator, ' ');
}

pub fn styleChar(style: yaml.ScalarStyle) u8 {
    return switch (style) {
        .plain, .any => ':',
        .single_quoted => '\'',
        .double_quoted => '"',
        .literal => '|',
        .folded => '>',
    };
}

pub fn appendEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            0x08 => try buf.appendSlice(allocator, "\\b"), // backspace (corpus G4RS)
            else => try buf.append(allocator, c),
        }
    }
}
