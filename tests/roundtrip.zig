//! Byte-faithful round-trip harness.
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
    // The 46 unnamed suite sub-cases are now loaded (they were silently
    // dropped before). Six of them are valid cases yayl cannot parse yet
    // -- the same six the conformance gate tracks -- so there is no round
    // trip to assert. The stale-skip guard fails the gate if any starts
    // parsing.
    .{ .id = "3RLN-2", .reason = "yayl cannot parse this unnamed sub-case yet" },
    .{ .id = "3RLN-5", .reason = "yayl cannot parse this unnamed sub-case yet" },
    .{ .id = "DE56-3", .reason = "yayl cannot parse this unnamed sub-case yet" },
    .{ .id = "DE56-4", .reason = "yayl cannot parse this unnamed sub-case yet" },
    .{ .id = "DK95-5", .reason = "yayl cannot parse this unnamed sub-case yet" },
    .{ .id = "KH5V-2", .reason = "yayl cannot parse this unnamed sub-case yet" },
};

fn findSkip(id: []const u8) ?Skip {
    for (skips) |s| if (std.mem.eql(u8, s.id, id)) return s;
    return null;
}

const Status = enum { pass, fail, skip };

const Result = struct {
    id: []const u8,
    status: Status,
    /// Owned: every reason is copied at append (see `addResult`). A
    /// shared scratch buffer used to back this field, so every failed
    /// case in the report showed the LAST diff.
    reason: []u8,
};

/// Append a result, COPYING `reason` into the allocator. The reason a
/// caller holds may point into a scratch buffer; storing the slice
/// directly aliased every earlier failure to the last write.
fn addResult(
    allocator: std.mem.Allocator,
    results: *std.ArrayList(Result),
    id: []const u8,
    status: Status,
    reason: []const u8,
) !void {
    try results.append(allocator, .{
        .id = id,
        .status = status,
        .reason = try allocator.dupe(u8, reason),
    });
}

test "addResult owns its reason instead of aliasing a scratch buffer" {
    const allocator = std.testing.allocator;
    var results: std.ArrayList(Result) = .empty;
    defer {
        for (results.items) |r| allocator.free(r.reason);
        results.deinit(allocator);
    }
    var scratch: [16]u8 = undefined;
    const first = std.fmt.bufPrint(&scratch, "first diff", .{}) catch unreachable;
    try addResult(allocator, &results, "A", .fail, first);
    @memset(&scratch, 'x');
    const second = std.fmt.bufPrint(&scratch, "second", .{}) catch unreachable;
    try addResult(allocator, &results, "B", .fail, second);
    // The first reason must survive the second write.
    try std.testing.expectEqualStrings("first diff", results.items[0].reason);
    try std.testing.expectEqualStrings("second", results.items[1].reason);
}

test "corpus round trips byte-for-byte" {
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
        std.debug.print("roundtrip: cannot load corpus ({}); run `make corpus` first\n", .{err});
        return err;
    };

    // Vacuous-pass guard: a mis-loaded corpus (zero cases parsed) must
    // fail the gate, not report zero cases as zero round trips.
    try std.testing.expect(cases.items.len >= 300);

    var results: std.ArrayList(Result) = .empty;
    defer {
        for (results.items) |r| allocator.free(r.reason);
        results.deinit(allocator);
    }

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var stale: usize = 0;

    for (cases.items) |case| {
        if (case.fail) continue; // invalid YAML: no round trip defined

        const skip_entry = findSkip(case.id);
        const outcome = roundTrip(allocator, case.input) catch |err| {
            try addResult(allocator, &results, case.id, .fail, @errorName(err));
            fail += 1;
            continue;
        };
        if (outcome) |reason| {
            if (skip_entry) |s| {
                // A documented skip that is still failing is a skip; the
                // mismatch reason need not match, only the case id. A
                // skip whose mismatch is GONE is stale (handled below,
                // when `outcome` is null).
                skip += 1;
                try addResult(allocator, &results, case.id, .skip, s.reason);
            } else {
                fail += 1;
                try addResult(allocator, &results, case.id, .fail, reason);
                std.debug.print("  RT-FAIL {s} ({s}): {s}\n", .{ case.id, case.name, reason });
            }
            continue;
        }
        if (skip_entry != null) {
            stale += 1;
            try addResult(allocator, &results, case.id, .fail, "stale skip: case round trips, remove from skips");
            continue;
        }
        pass += 1;
        try addResult(allocator, &results, case.id, .pass, "");
    }

    try writeReport(allocator, io, results.items);
    std.debug.print("roundtrip: {d} pass, {d} fail, {d} skip\n", .{ pass, fail, skip });
    try std.testing.expectEqual(@as(usize, 0), fail);
    try std.testing.expectEqual(@as(usize, 0), stale);
}

var diff_buf: [160]u8 = undefined;

/// Parse and re-emit; returns null on an exact round trip, or a static
/// description of the first difference.
fn roundTrip(allocator: std.mem.Allocator, input: []const u8) !?[]const u8 {
    var docs = yaml.parseAll(allocator, input) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => "parse failed",
        };
    };
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(allocator);
    }
    if (docs.items.len == 0) {
        // Streams without a document: nothing to re-emit (matches
        // libfyaml). Reported as a mismatch unless input is empty; the
        // skip table carries these.
        if (input.len == 0) return null;
        return "no document in stream";
    }

    // Through `writeAll`, not a hand-rolled concatenation: the stream
    // writer is what a consumer is told to use, so it is what the gate
    // has to hold to byte-exactness. It inserts a `---` only where a
    // boundary is required and absent, and every corpus stream that
    // parses as more than one document already carries its own -- so a
    // spurious insertion shows up here as a diff, across the whole
    // corpus, rather than only in the unit tests' handful of shapes.
    const out = try yaml.writeAll(allocator, docs.items);
    defer allocator.free(out);

    if (std.mem.eql(u8, out, input)) return null;
    return firstDiff(input, out);
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

fn writeReport(allocator: std.mem.Allocator, io: std.Io, results: []const Result) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "[\n");
    for (results, 0..) |r, i| {
        try buf.print(allocator, "  {{\"id\": \"{s}\", \"status\": \"{s}\"", .{ r.id, @tagName(r.status) });
        if (r.reason.len > 0) {
            try buf.appendSlice(allocator, ", \"reason\": \"");
            try corpus.appendJsonEscaped(&buf, allocator, r.reason);
            try buf.appendSlice(allocator, "\"");
        }
        try buf.appendSlice(allocator, if (i + 1 < results.len) "},\n" else "}\n");
    }
    try buf.appendSlice(allocator, "]\n");

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "zig-out");
    try cwd.writeFile(io, .{ .sub_path = report_path, .data = buf.items });
}

test "fixtures round trip byte-for-byte" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Fixtures are part of the repository; a missing directory is a
    // checkout problem, not an empty pass.
    var dir = try std.Io.Dir.cwd().openDir(io, "tests/fixtures", .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml") and !std.mem.endsWith(u8, entry.name, ".yml")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    // Anti-vacuity: the fixtures are committed, so an empty or shrunken
    // listing is a bad glob or a broken checkout, not a pass. Mirrors
    // the corpus guards above and in tests/conformance.zig.
    try std.testing.expect(names.items.len >= 14);

    for (names.items) |name| {
        const input = try dir.readFileAlloc(io, name, allocator, .limited(4 << 20));
        defer allocator.free(input);
        const reason = (try roundTrip(allocator, input)) orelse continue;
        std.debug.print("  FIXTURE-FAIL {s}: {s}\n", .{ name, reason });
        return error.RoundTripFailed;
    }
}
