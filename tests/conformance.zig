//! YAML Test Suite conformance harness.
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
/// fix is tracked, per the skip policy in tests/README.md.
const Skip = struct {
    id: []const u8,
    reason: []const u8,
    target: []const u8,
};

/// Cases yayl does not handle yet: none. The pinned corpus passes in
/// full (351/351 as of 2026-08-29). The stale-skip guard keeps this
/// table honest if it ever grows again.
const skips: []const Skip = &.{};

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

fn runCase(allocator: std.mem.Allocator, case: corpus.Case, verbose: bool) !Outcome {
    if (case.fail) {
        const ok = blk: {
            var docs = yaml.parseAll(allocator, case.input) catch break :blk true;
            defer {
                for (docs.items) |*d| d.deinit();
                docs.deinit(allocator);
            }
            break :blk false;
        };
        if (ok) return .{ .status = .pass, .reason = "rejected as expected" };
        return .{ .status = .fail, .reason = "expected parse error, got success" };
    }

    const actual = corpus.renderTree(allocator, case.input, verbose) catch |err| {
        return .{ .status = .fail, .reason = if (err == error.OutOfMemory) "oom" else @errorName(err) };
    };
    defer allocator.free(actual);

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

fn appendJsonEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            else => try buf.append(allocator, c),
        }
    }
}
fn writeReport(allocator: std.mem.Allocator, io: std.Io, results: []const Result) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "[\n");
    for (results, 0..) |r, i| {
        try buf.print(allocator, "  {{\"id\": \"{s}\", \"name\": \"", .{r.id});
        try appendJsonEscaped(&buf, allocator, r.name);
        try buf.print(allocator, "\", \"status\": \"{s}\"", .{@tagName(r.status)});
        if (r.reason.len > 0) {
            try buf.appendSlice(allocator, ", \"reason\": \"");
            try appendJsonEscaped(&buf, allocator, r.reason);
            try buf.append(allocator, '"');
        }
        try buf.appendSlice(allocator, if (i + 1 < results.len) "},\n" else "}\n");
    }
    try buf.appendSlice(allocator, "]\n");

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "zig-out");
    try cwd.writeFile(io, .{ .sub_path = report_path, .data = buf.items });
}

// ----------------------------------------------------------------------
// Corpus gate
// ----------------------------------------------------------------------

test "yaml test suite corpus" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cases: std.ArrayList(corpus.Case) = .empty;
    defer {
        for (cases.items) |*c| corpus.freeCase(allocator, c);
        cases.deinit(allocator);
    }
    corpus.loadCases(allocator, io, &cases) catch |err| {
        std.debug.print(
            "conformance: cannot load corpus from {s} ({}); run `make corpus` first\n",
            .{ corpus_dir, err },
        );
        return err;
    };

    // Vacuous-pass guard: a mis-loaded corpus (zero cases parsed) must
    // fail the gate, not report zero cases as zero failures.
    try std.testing.expect(cases.items.len >= 300);

    var results: std.ArrayList(Result) = .empty;
    defer results.deinit(allocator);

    var pass: usize = 0;
    var fail: usize = 0;
    var stale: usize = 0;
    for (cases.items) |case| {
        const skip = findSkip(case.id);
        const outcome = runCase(allocator, case, skip == null) catch |err| {
            var reason_buf: [128]u8 = undefined;
            const reason = std.fmt.bufPrint(&reason_buf, "harness error: {}", .{err}) catch "harness error";
            try results.append(allocator, .{ .id = case.id, .name = case.name, .status = .fail, .reason = reason });
            continue;
        };
        if (skip) |s| {
            if (outcome.status == .pass) {
                // A skipped case that now passes means the table is stale.
                stale += 1;
                try results.append(allocator, .{ .id = case.id, .name = case.name, .status = .fail, .reason = "stale skip: case passes, remove from skips table" });
            } else {
                try results.append(allocator, .{ .id = case.id, .name = case.name, .status = .skip, .reason = s.reason });
            }
            continue;
        }
        if (outcome.status == .pass) pass += 1;
        if (outcome.status == .fail) fail += 1;
        try results.append(allocator, .{ .id = case.id, .name = case.name, .status = outcome.status, .reason = outcome.reason });
    }

    try writeReport(allocator, io, results.items);

    std.debug.print("conformance: {d} pass, {d} fail, {d} skip, {d} stale\n", .{ pass, fail, results.items.len - pass - fail, stale });
    for (results.items) |r| {
        if (r.status == .fail) {
            std.debug.print("  FAIL {s} {s}: {s}\n", .{ r.id, r.name, r.reason });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), fail);
    try std.testing.expectEqual(@as(usize, 0), stale);
}
