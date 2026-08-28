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
const corpus = @import("corpus_common.zig");

const corpus_dir = corpus.corpus_dir;
const report_path = "zig-out/conformance-report.json";

/// Cases yayl does not handle yet. Each entry records why and where the
/// fix is tracked, per PLAN-2's skip policy.
const Skip = struct {
    id: []const u8,
    reason: []const u8,
    target: []const u8,
};

/// Known gaps, triaged 2026-08-27 from the 301/351 baseline. Every entry
/// carries a reason and the card tracking the fix; a skipped case that
/// starts passing fails the gate ("stale skip") so this table cannot
/// outlive a fix.
const skips: []const Skip = &.{
    // Block scalars, tabs and indentation interplay.
    .{ .id = "MJS9", .reason = "block folding with tabs (spec 6.7)", .target = "PLAN-3" },
    .{ .id = "R4YG", .reason = "block indentation indicator details (spec 8.2)", .target = "PLAN-3" },
    // Wrongly accepted (must become rejections).
    .{ .id = "4EJS", .reason = "tab used as mapping indentation accepted", .target = "PLAN-3" },
    .{ .id = "Y79Y-1", .reason = "tabs in various contexts accepted", .target = "PLAN-3" },
    .{ .id = "9C9N", .reason = "wrong-indented flow continuation accepted", .target = "PLAN-3" },
    .{ .id = "QB6E", .reason = "wrong-indented multiline quoted scalar accepted", .target = "PLAN-3" },
};

fn findSkip(id: []const u8) ?Skip {
    for (skips) |s| if (std.mem.eql(u8, s.id, id)) return s;
    return null;
}

const Status = enum { pass, fail, skip };

const Result = struct {
    id: []const u8,
    name: []const u8,
    status: Status,
    reason: []const u8,
};

const Outcome = struct {
    status: Status,
    reason: []const u8,
};

/// Temporary triage aid: dump expected vs actual trees for these ids.
const debug_ids: []const []const u8 = &.{};

fn isDebugId(id: []const u8) bool {
    for (debug_ids) |d| if (std.mem.eql(u8, d, id)) return true;
    return false;
}

fn runCase(alloc: std.mem.Allocator, case: corpus.Case, verbose: bool) !Outcome {
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

    const actual = renderTree(alloc, case.input, verbose) catch |err| {
        return .{ .status = .fail, .reason = if (err == error.OutOfMemory) "oom" else @errorName(err) };
    };
    defer alloc.free(actual);

    const expected = std.mem.trimEnd(u8, case.tree orelse "", " \n");
    const actual_trimmed = std.mem.trimEnd(u8, actual, "\n");
    if (isDebugId(case.id)) {
        std.debug.print("--- {s} expected ---\n{s}\n--- {s} actual ---\n{s}\n---\n", .{ case.id, expected, case.id, actual_trimmed });
    }
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

fn dumpDiags(diag: yaml.Diag) void {
    for (diag.list.items) |d| {
        std.debug.print("    diag {d}:{d}: {s}\n", .{ d.mark.line, d.mark.column, d.message });
    }
}

/// Render the parser's event stream in the corpus tree notation:
/// `+STR/+DOC/+SEQ/+MAP/...` with one space of indent per open container,
/// anchors as `&name`, resolved tags as `<uri>`, scalar styles as
/// `: ' " | >` prefixes, and `\`, `\n`, `\t`, `\r` escaped in values.
fn renderTree(alloc: std.mem.Allocator, input: []const u8, verbose: bool) ![]u8 {
    var diag: yaml.Diag = .{ .alloc = alloc };
    defer diag.deinit();
    var p = yaml.Parser.init(alloc, &diag, input) catch |err| {
        if (verbose) dumpDiags(diag);
        return err;
    };
    defer p.deinit();

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    var depth: usize = 0;
    while (true) {
        const next = p.nextEvent() catch |err| {
            if (verbose) dumpDiags(diag);
            return err;
        };
        const ev = next orelse break;
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
                try bufPrintMeta(&buf, alloc, depth, "+SEQ", if (cs.style == .flow) " []" else "", cs.anchor, cs.tag);
                try buf.append(alloc, '\n');
                depth += 1;
            },
            .mapping_start => |cs| {
                try bufPrintMeta(&buf, alloc, depth, "+MAP", if (cs.style == .flow) " {}" else "", cs.anchor, cs.tag);
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
                try bufPrintMeta(&buf, alloc, depth, "=VAL", "", s.anchor, s.tag);
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

fn bufPrintMeta(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, depth: usize, head: []const u8, style_suffix: []const u8, anchor: ?[]const u8, tag: ?[]const u8) !void {
    try indent(buf, alloc, depth);
    try buf.appendSlice(alloc, head);
    try buf.appendSlice(alloc, style_suffix);
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
            0x08 => try buf.appendSlice(alloc, "\\b"), // backspace (corpus G4RS)
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
