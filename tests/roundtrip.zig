//! Byte-faithful round-trip harness (PLAN-4).
//!
//! For every corpus case that is valid YAML, `emit(parseAll(input))`
//! must reproduce the input byte for byte: comments, blank lines,
//! quoting, key order, indentation, anchors/aliases, tags, directives,
//! document markers, block scalar headers and chomping included. This
//! is the differential gate for the CST presentation layer.
//!
//! Real-world fixtures under tests/fixtures/ are exercised by the same
//! guarantee (see the fixtures test below).

const std = @import("std");
const yaml = @import("yayl");
const corpus = @import("corpus_common.zig");

const report_path = "zig-out/roundtrip-report.json";

const Skip = struct {
    id: []const u8,
    reason: []const u8,
};

/// Known round-trip gaps. A skipped case that starts passing fails the
/// gate (stale skip), so this table cannot outlive a fix.
const skips = [_]Skip{
    // Streams with no document at all (indicators/comments only): the
    // parse yields nothing, so there is nothing to re-emit. This
    // matches libfyaml, which also produces no output for these.
    .{ .id = "HWV9", .reason = "no document in stream (lone '...')" },
    .{ .id = "8G76", .reason = "no document in stream (comments + blank lines)" },
    .{ .id = "98YD", .reason = "no document in stream (comment only)" },
    .{ .id = "QT73", .reason = "no document in stream (comment + '...')" },
};

fn findSkip(id: []const u8) ?Skip {
    for (skips) |s| if (std.mem.eql(u8, s.id, id)) return s;
    return null;
}

const Result = struct {
    id: []const u8,
    status: enum { pass, fail, skip },
    reason: []const u8,
};

test "corpus round trips byte-for-byte" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cases: std.ArrayList(corpus.Case) = .empty;
    defer {
        for (cases.items) |*c| corpus.freeCase(alloc, c);
        cases.deinit(alloc);
    }
    corpus.loadCases(alloc, io, &cases) catch |err| {
        std.debug.print("roundtrip: cannot load corpus ({}); run `make corpus` first\n", .{err});
        return err;
    };

    // Vacuous-pass guard: a mis-loaded corpus (zero cases parsed) must
    // fail the gate, not report zero cases as zero round trips.
    try std.testing.expect(cases.items.len >= 300);

    var results: std.ArrayList(Result) = .empty;
    defer results.deinit(alloc);

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var stale: usize = 0;

    for (cases.items) |case| {
        if (case.fail) continue; // invalid YAML: no round trip defined

        const skip_entry = findSkip(case.id);
        const outcome = roundTrip(alloc, case.input) catch |err| {
            try results.append(alloc, .{ .id = case.id, .status = .fail, .reason = @errorName(err) });
            fail += 1;
            continue;
        };
        if (outcome) |reason| {
            if (skip_entry) |s| {
                // A skip that reproduces cleanly (documented
                // no-output case) is fine; a skip whose mismatch is
                // gone is stale.
                if (std.mem.startsWith(u8, s.reason, "no document in stream") and
                    std.mem.eql(u8, reason, "no document in stream"))
                {
                    skip += 1;
                    try results.append(alloc, .{ .id = case.id, .status = .skip, .reason = s.reason });
                } else {
                    stale += 1;
                    try results.append(alloc, .{ .id = case.id, .status = .fail, .reason = "stale skip: case round trips, remove from skips" });
                }
            } else {
                fail += 1;
                try results.append(alloc, .{ .id = case.id, .status = .fail, .reason = reason });
                std.debug.print("  RT-FAIL {s} ({s}): {s}\n", .{ case.id, case.name, reason });
            }
            continue;
        }
        if (skip_entry != null) {
            stale += 1;
            try results.append(alloc, .{ .id = case.id, .status = .fail, .reason = "stale skip: case round trips, remove from skips" });
            continue;
        }
        pass += 1;
        try results.append(alloc, .{ .id = case.id, .status = .pass, .reason = "" });
    }

    try writeReport(alloc, io, results.items);
    std.debug.print("roundtrip: {d} pass, {d} fail, {d} skip\n", .{ pass, fail, skip });
    try std.testing.expectEqual(@as(usize, 0), fail);
    try std.testing.expectEqual(@as(usize, 0), stale);
}

var diff_buf: [160]u8 = undefined;

/// Parse and re-emit; returns null on an exact round trip, or a static
/// description of the first difference.
fn roundTrip(alloc: std.mem.Allocator, input: []const u8) !?[]const u8 {
    var docs = yaml.parseAll(alloc, input) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => "parse failed",
        };
    };
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(alloc);
    }
    if (docs.items.len == 0) {
        // Streams without a document: nothing to re-emit (matches
        // libfyaml). Reported as a mismatch unless input is empty; the
        // skip table carries these.
        if (input.len == 0) return null;
        return "no document in stream";
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (docs.items) |*d| {
        const text = try d.write(alloc);
        defer alloc.free(text);
        try out.appendSlice(alloc, text);
    }

    if (std.mem.eql(u8, out.items, input)) return null;
    return firstDiff(input, out.items);
}

fn firstDiff(input: []const u8, out: []const u8) []const u8 {
    var line: usize = 1;
    const n = @min(input.len, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (input[i] != out[i]) break;
        if (input[i] == '\n') line += 1;
    }
    return std.fmt.bufPrint(&diff_buf, "line {d} differs (in {d} bytes, out {d} bytes, first diff at {d})", .{ line, input.len, out.len, i }) catch "differs";
}

fn appendJsonEscaped(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            else => try buf.append(alloc, c),
        }
    }
}

fn writeReport(alloc: std.mem.Allocator, io: std.Io, results: []const Result) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "[\n");
    for (results, 0..) |r, i| {
        try buf.print(alloc, "  {{\"id\": \"{s}\", \"status\": \"{s}\"", .{ r.id, @tagName(r.status) });
        if (r.reason.len > 0) {
            try buf.appendSlice(alloc, ", \"reason\": \"");
            try appendJsonEscaped(&buf, alloc, r.reason);
            try buf.appendSlice(alloc, "\"");
        }
        try buf.appendSlice(alloc, if (i + 1 < results.len) "},\n" else "}\n");
    }
    try buf.appendSlice(alloc, "]\n");

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "zig-out");
    try cwd.writeFile(io, .{ .sub_path = report_path, .data = buf.items });
}

test "fixtures round trip byte-for-byte" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Fixtures are part of the repository; a missing directory is a
    // checkout problem, not an empty pass.
    var dir = try std.Io.Dir.cwd().openDir(io, "tests/fixtures", .{ .iterate = true });
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
        const input = try dir.readFileAlloc(io, name, alloc, .limited(4 << 20));
        defer alloc.free(input);
        const reason = (try roundTrip(alloc, input)) orelse continue;
        std.debug.print("  FIXTURE-FAIL {s}: {s}\n", .{ name, reason });
        return error.RoundTripFailed;
    }
}
