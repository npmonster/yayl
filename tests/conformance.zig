//! YAML Test Suite conformance harness (PLAN-2).
//!
//! Runs the pinned upstream corpus (vendor/yaml-test-suite, fetched by
//! `make corpus`) through yayl's parser and compares a rendered event
//! tree against each case's expected tree, at capability level. Every
//! skipped case carries a reason and a target card; nothing is skipped
//! silently. A machine-readable report lands in
//! zig-out/conformance-report.json.

const std = @import("std");
const yaml = @import("yayl");

const corpus_dir = "vendor/yaml-test-suite/src";
const report_path = "zig-out/conformance-report.json";

/// Cases yayl does not handle yet. Each entry records why and where the
/// fix is tracked, per PLAN-2's skip policy.
const Skip = struct {
    id: []const u8,
    reason: []const u8,
    target: []const u8,
};

const skips: []const Skip = &.{};

fn findSkip(id: []const u8) ?Skip {
    for (skips) |s| if (std.mem.eql(u8, s.id, id)) return s;
    return null;
}

const Case = struct {
    id: []const u8,
    name: []const u8,
    input: []const u8,
    tree: ?[]const u8,
    fail: bool,
};

const Status = enum { pass, fail, skip };

const Result = struct {
    id: []const u8,
    name: []const u8,
    status: Status,
    reason: []const u8,
};

test "yaml test suite corpus" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cases: std.ArrayList(Case) = .empty;
    defer {
        for (cases.items) |c| {
            alloc.free(c.id);
            alloc.free(c.name);
            alloc.free(c.input);
            if (c.tree) |t| alloc.free(t);
        }
        cases.deinit(alloc);
    }
    loadCases(alloc, io, &cases) catch |err| {
        std.debug.print(
            "conformance: cannot load corpus from {s} ({}); run `make corpus` first\n",
            .{ corpus_dir, err },
        );
        return err;
    };

    var results: std.ArrayList(Result) = .empty;
    defer results.deinit(alloc);

    for (cases.items) |case| {
        if (findSkip(case.id)) |s| {
            try results.append(alloc, .{ .id = case.id, .name = case.name, .status = .skip, .reason = s.reason });
            continue;
        }
        const outcome = runCase(alloc, case) catch |err| {
            var reason_buf: [128]u8 = undefined;
            const reason = std.fmt.bufPrint(&reason_buf, "harness error: {}", .{err}) catch "harness error";
            try results.append(alloc, .{ .id = case.id, .name = case.name, .status = .fail, .reason = reason });
            continue;
        };
        try results.append(alloc, .{ .id = case.id, .name = case.name, .status = outcome.status, .reason = outcome.reason });
    }

    try writeReport(alloc, io, results.items);

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    for (results.items) |r| {
        switch (r.status) {
            .pass => pass += 1,
            .fail => fail += 1,
            .skip => skip += 1,
        }
    }
    std.debug.print("conformance: {d} pass, {d} fail, {d} skip ({d} cases); report: {s}\n", .{ pass, fail, skip, results.items.len, report_path });
    for (results.items) |r| {
        if (r.status == .fail) std.debug.print("  FAIL {s} {s}: {s}\n", .{ r.id, r.name, r.reason });
    }
    try std.testing.expectEqual(@as(usize, 0), fail);
}

fn loadCases(alloc: std.mem.Allocator, io: std.Io, cases: *std.ArrayList(Case)) !void {
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

        // The corpus files are themselves YAML: one document holding a
        // sequence of test records.
        var docs = try yaml.parseAll(alloc, text);
        defer {
            for (docs.items) |*d| d.deinit();
            docs.deinit(alloc);
        }
        if (docs.items.len == 0) continue;
        const root = docs.items[0].root orelse continue;
        const records = root.items() orelse continue;
        if (records.len != 1) {
            std.debug.print("conformance: {s}: parsed {d} top-level records (expected 1)\n", .{ name, records.len });
        }

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
                .tree = if (tree_node) |t| try alloc.dupe(u8, t.scalarValue() orelse "") else null,
                .fail = if (fail_node) |f| std.mem.eql(u8, f.scalarValue() orelse "", "true") else false,
            });
        }
    }
}

/// The corpus marks significant trailing spaces with U+2423 (␣).
fn replaceMarker(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    const marker = "\xE2\x90\xA3";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) {
        if (i + marker.len <= input.len and std.mem.eql(u8, input[i .. i + marker.len], marker)) {
            try out.append(alloc, ' ');
            i += marker.len;
        } else {
            try out.append(alloc, input[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(alloc);
}

const Outcome = struct {
    status: Status,
    reason: []const u8,
};

fn runCase(alloc: std.mem.Allocator, case: Case) !Outcome {
    if (case.fail) {
        const ok = blk: {
            var docs = yaml.parseAll(alloc, case.input) catch break :blk true;
            defer {
                for (docs.items) |*d| d.deinit();
                docs.deinit(alloc);
            }
            break :blk false;
        };
        if (ok) return .{ .status = .pass, .reason = "rejected as expected" };
        return .{ .status = .fail, .reason = "expected parse error, got success" };
    }

    const actual = renderTree(alloc, case.input) catch |err| {
        return .{ .status = .fail, .reason = if (err == error.OutOfMemory) "oom" else "parse error" };
    };
    defer alloc.free(actual);

    const expected = std.mem.trimEnd(u8, case.tree orelse "", " \n");
    const actual_trimmed = std.mem.trimEnd(u8, actual, "\n");
    if (std.mem.eql(u8, expected, actual_trimmed)) {
        return .{ .status = .pass, .reason = "" };
    }
    return .{ .status = .fail, .reason = firstMismatch(expected, actual_trimmed) };
}

/// Static detail string for the report: the first line pair that differs.
fn firstMismatch(expected: []const u8, actual: []const u8) []const u8 {
    var exp_it = std.mem.splitScalar(u8, expected, '\n');
    var act_it = std.mem.splitScalar(u8, actual, '\n');
    while (true) {
        const e = exp_it.next();
        const a = act_it.next();
        if (e == null and a == null) return "mismatch";
        if (e == null) return "actual has extra trailing lines";
        if (a == null) return "actual is missing trailing lines";
        if (!std.mem.eql(u8, e.?, a.?)) {
            if (std.mem.eql(u8, std.mem.trim(u8, e.?, " "), std.mem.trim(u8, a.?, " "))) {
                return "indentation differs";
            }
            return "line content differs";
        }
    }
}

/// Render the parser's event stream in the corpus tree notation:
/// `+STR/+DOC/+SEQ/+MAP/...` with one space of indent per open container,
/// anchors as `&name`, resolved tags as `<uri>`, scalar styles as
/// `: ' " | >` prefixes, and `\`, `\n`, `\t`, `\r` escaped in values.
fn renderTree(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var p = try yaml.Parser.init(alloc, null, input);
    defer p.deinit();

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    var depth: usize = 0;
    while (try p.nextEvent()) |ev| {
        switch (ev.kind) {
            .stream_start => {
                try writeLine(&buf, alloc, depth, "+STR");
                depth += 1;
            },
            .stream_end => {
                depth -= 1;
                try writeLine(&buf, alloc, depth, "-STR");
            },
            .document_start => |d| {
                try writeLine(&buf, alloc, depth, if (!d.implicit) "+DOC ---" else "+DOC");
                depth += 1;
            },
            .document_end => |d| {
                depth -= 1;
                try writeLine(&buf, alloc, depth, if (!d.implicit) "-DOC ..." else "-DOC");
            },
            .sequence_start => |cs| {
                try bufPrintMeta(&buf, alloc, depth, "+SEQ", cs.anchor, cs.tag);
                if (cs.style == .flow) try buf.appendSlice(alloc, " []");
                try buf.append(alloc, '\n');
                depth += 1;
            },
            .mapping_start => |cs| {
                try bufPrintMeta(&buf, alloc, depth, "+MAP", cs.anchor, cs.tag);
                if (cs.style == .flow) try buf.appendSlice(alloc, " {}");
                try buf.append(alloc, '\n');
                depth += 1;
            },
            .sequence_end => {
                depth -= 1;
                try writeLine(&buf, alloc, depth, "-SEQ");
            },
            .mapping_end => {
                depth -= 1;
                try writeLine(&buf, alloc, depth, "-MAP");
            },
            .scalar => |s| {
                try bufPrintMeta(&buf, alloc, depth, "=VAL", s.anchor, s.tag);
                try buf.append(alloc, ' ');
                try buf.append(alloc, styleChar(s.style));
                try appendEscaped(&buf, alloc, s.value);
                try buf.append(alloc, '\n');
            },
            .alias => |a| {
                try indent(&buf, alloc, depth);
                try buf.print(alloc, "=ALI *{s}\n", .{a});
            },
        }
    }
    return try buf.toOwnedSlice(alloc);
}

fn bufPrintMeta(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, depth: usize, head: []const u8, anchor: ?[]const u8, tag: ?[]const u8) !void {
    try indent(buf, alloc, depth);
    try buf.appendSlice(alloc, head);
    if (anchor) |a| {
        try buf.append(alloc, ' ');
        try buf.append(alloc, '&');
        try buf.appendSlice(alloc, a);
    }
    if (tag) |t| {
        try buf.print(alloc, " <{s}>", .{t});
    }
}

fn writeLine(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, depth: usize, text: []const u8) !void {
    try indent(buf, alloc, depth);
    try buf.appendSlice(alloc, text);
    try buf.append(alloc, '\n');
}

fn indent(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try buf.append(alloc, ' ');
}

fn styleChar(style: yaml.ScalarStyle) u8 {
    return switch (style) {
        .plain, .any => ':',
        .single_quoted => '\'',
        .double_quoted => '"',
        .literal => '|',
        .folded => '>',
    };
}

fn appendEscaped(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            else => try buf.append(alloc, c),
        }
    }
}

fn appendJsonEscaped(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                const hexd = "0123456789abcdef";
                try buf.appendSlice(alloc, "\\u00");
                try buf.append(alloc, hexd[(c >> 4) & 0xF]);
                try buf.append(alloc, hexd[c & 0xF]);
            },
            else => try buf.append(alloc, c),
        }
    }
}

fn writeReport(alloc: std.mem.Allocator, io: std.Io, results: []const Result) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "[\n");
    for (results, 0..) |r, i| {
        try buf.print(alloc, "  {{\"id\": \"{s}\", \"name\": \"", .{r.id});
        try appendJsonEscaped(&buf, alloc, r.name);
        try buf.print(alloc, "\", \"status\": \"{s}\"", .{@tagName(r.status)});
        if (r.reason.len > 0) {
            try buf.appendSlice(alloc, ", \"reason\": \"");
            try appendJsonEscaped(&buf, alloc, r.reason);
            try buf.append(alloc, '"');
        }
        try buf.appendSlice(alloc, if (i + 1 < results.len) "},\n" else "}\n");
    }
    try buf.appendSlice(alloc, "]\n");

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "zig-out");
    try cwd.writeFile(io, .{ .sub_path = report_path, .data = buf.items });
}
