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

pub fn freeCase(alloc: std.mem.Allocator, c: *const Case) void {
    alloc.free(c.id);
    alloc.free(c.name);
    alloc.free(c.input);
    if (c.tree) |t| alloc.free(t);
}

pub fn loadCases(alloc: std.mem.Allocator, io: std.Io, cases: *std.ArrayList(Case)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, corpus_dir, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml")) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    for (names.items) |name| {
        const text = try dir.readFileAlloc(io, name, alloc, .limited(1 << 20));
        defer alloc.free(text);
        const id = name[0 .. name.len - ".yaml".len];

        var docs = try yaml.parseAll(alloc, text);
        defer {
            for (docs.items) |*d| d.deinit();
            docs.deinit(alloc);
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
                try std.fmt.allocPrint(alloc, "{s}-{d}", .{ id, index })
            else
                try alloc.dupe(u8, id);
            errdefer alloc.free(case_id);

            try cases.append(alloc, .{
                .id = case_id,
                .name = try alloc.dupe(u8, name_val.scalarValue() orelse "?"),
                .input = try replaceMarker(alloc, yaml_val.scalarValue() orelse ""),
                .tree = if (tree_node) |t| try replaceMarker(alloc, t.scalarValue() orelse "") else null,
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
pub fn replaceMarker(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    const space_marker = "\xE2\x90\xA3"; // ␣
    const eof_marker = "\xE2\x88\x8E"; // ∎
    const newline_marker = "\xE2\x86\xB5"; // ↵
    const cr_marker = "\xE2\x86\x90"; // ←
    const bom_marker = "\xE2\x87\x94"; // ⇔
    const em_dash = "\xE2\x80\x94"; // —
    const guillemet = "\xC2\xBB"; // »

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) {
        const rest = input[i..];
        if (starts(rest, eof_marker)) break;
        if (starts(rest, space_marker)) {
            try out.append(alloc, ' ');
            i += space_marker.len;
        } else if (starts(rest, newline_marker)) {
            // ↵ is a *visibility* marker for a trailing newline: every
            // occurrence in the corpus is immediately followed by a real
            // '\n' (the block-scalar line separator), so emitting another
            // newline here would double it (corpus JEF9-1/K858 keep
            // chomping counts). Drop the marker only.
            i += newline_marker.len;
        } else if (starts(rest, cr_marker)) {
            try out.append(alloc, '\r');
            i += cr_marker.len;
        } else if (starts(rest, bom_marker)) {
            try out.appendSlice(alloc, "\xEF\xBB\xBF");
            i += bom_marker.len;
        } else if (starts(rest, em_dash) or starts(rest, guillemet)) {
            // Hard-tab marker: `—*»` (any run of U+2014 then U+00BB) is a
            // single tab. Surrounding spaces are preserved — block/flow
            // scalar indentation, not the harness, decides which spaces
            // are content (YAMLTestSuite.pm `s/—*»/\t/g`).
            while (starts(input[i..], em_dash)) i += em_dash.len;
            if (starts(input[i..], guillemet)) i += guillemet.len;
            try out.append(alloc, '\t');
        } else {
            try out.append(alloc, input[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(alloc);
}

fn starts(haystack: []const u8, needle: []const u8) bool {
    return haystack.len >= needle.len and std.mem.eql(u8, haystack[0..needle.len], needle);
}
