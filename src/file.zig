//! Production I/O — PLAN-8.
//!
//! Convenience adapters between files and the document model. All
//! reads are bounded by `max_bytes` (a malicious or accidental
//! multi-gigabyte file fails with `StreamTooLong`, not OOM), and
//! writes are atomic (temp file + rename), so a crash never leaves a
//! half-written YAML file behind.
//!
//! STREAMING DECISION (documented, deliberate): yayl's parser is
//! pull-based at the *event* level (`Parser.nextEvent`) but requires
//! the whole input in memory; there is no chunked reader. Rationale:
//! the scanner's lookahead (simple keys, block indentation, flow
//! continuation) needs random access behind the cursor, and every
//! public API already accepts `[]const u8`, so applications can mmap
//! or read once and process many documents with bounded per-document
//! copies (regions share the pooled source). Chunked streaming is a
//! possible future layer on top of `Parser`, not a limitation of the
//! event API.
//!
//! CACHING DECISION: no parse cache ships in v1. Correctness of an
//! mtime/hash-keyed cache depends on filesystem semantics this
//! library does not own; applications that need one can key a cache
//! on `parseFile`'s inputs trivially.
//!
//! PARAMETER ORDER: the allocator comes first (after the document
//! receiver for write-style functions), then `io`, then `path`, then
//! options (e.g. `max_bytes`).

const std = @import("std");
const diag = @import("diag.zig");
const document_mod = @import("document.zig");

const Document = document_mod.Document;

pub const max_bytes_default: usize = 64 << 20; // 64 MiB

/// I/O failures plus the parse-error vocabulary the document layer
/// can surface (kept in sync with `diag.YamlError` by construction).
pub const Error = error{ StreamTooLong, FileNotFound, AccessDenied, OutOfMemory } || diag.YamlError;

/// Parse the first document of the file at `path`.
pub fn parseFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    max_bytes: usize,
) !Document {
    const input = try readFile(alloc, io, path, max_bytes);
    defer alloc.free(input);
    return Document.parse(alloc, input);
}

/// Parse every document in the file at `path`.
pub fn parseAllFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    max_bytes: usize,
) !std.ArrayList(Document) {
    const input = try readFile(alloc, io, path, max_bytes);
    defer alloc.free(input);
    return Document.parseAll(alloc, input);
}

/// Render `doc` and write it to `path` atomically: the bytes land in
/// a sibling temp file that is renamed over `path` only after a
/// successful write. On error, `path` is untouched.
pub fn writeFile(doc: *const Document, alloc: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const bytes = try doc.write(alloc);
    defer alloc.free(bytes);
    return writeBytesAtomic(io, path, bytes);
}

/// Atomically write raw bytes to `path` (temp file + rename).
pub fn writeBytesAtomic(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var buf: [512]u8 = undefined;
    const cwd = std.Io.Dir.cwd();
    var attempt: usize = 0;
    while (true) {
        attempt += 1;
        var rand_bytes: [4]u8 = undefined;
        io.random(&rand_bytes);
        const tmp_path = try std.fmt.bufPrint(&buf, "{s}.yayl-tmp-{d}", .{ path, std.mem.readInt(u32, &rand_bytes, .little) });
        var file = cwd.createFile(io, tmp_path, .{ .truncate = true, .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                if (attempt >= 4) return err;
                continue;
            },
            else => return err,
        };
        var file_open = true;
        var committed = false;
        defer {
            if (file_open) file.close(io);
            if (!committed) cwd.deleteFile(io, tmp_path) catch {};
        }
        try file.writeStreamingAll(io, bytes);
        // Flush to stable storage before the rename so the visible
        // file never contains torn content after a crash.
        try file.sync(io);
        file.close(io);
        file_open = false;
        try cwd.rename(tmp_path, cwd, path, io);
        committed = true;
        return;
    }
}

/// Read a whole file, bounded. Returns `error.StreamTooLong` past
/// `max_bytes`.
pub fn readFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => error.StreamTooLong,
        else => err,
    };
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

test "parse and atomically rewrite a file" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "zig-out-test-file.yaml";
    try writeBytesAtomic(io, path, "# comment\na: 1\nb: 2\n");
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var doc = try parseFile(alloc, io, path, max_bytes_default);
    defer doc.deinit();
    try testing.expectEqualStrings("1", doc.pathGet(&.{"a"}).?.scalarValue().?);

    // Edit and rewrite: byte-faithful for untouched parts.
    try doc.pathSet(&.{"b"}, try doc.createScalar("TWO", .plain));
    try writeFile(&doc, alloc, io, path);
    const round = try readFile(alloc, io, path, max_bytes_default);
    defer alloc.free(round);
    try testing.expectEqualStrings("# comment\na: 1\nb: TWO\n", round);

    try expectNoTempFiles(io, path);
}

test "atomic write removes its temp file when rename fails" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const path = "zig-out-test-atomic-target";
    cwd.deleteDir(io, path) catch {};
    try cwd.createDir(io, path, .default_dir);
    defer cwd.deleteDir(io, path) catch {};

    writeBytesAtomic(io, path, "content") catch {
        try expectNoTempFiles(io, path);
        return;
    };
    return error.TestUnexpectedResult;
}

test "bounded read rejects oversized input" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "zig-out-test-big.yaml";
    try writeBytesAtomic(io, path, "a: 1\n" ** 4);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try testing.expectError(error.StreamTooLong, readFile(alloc, io, path, 4));
}

test "parseAllFile reads every document" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "zig-out-test-multidoc.yaml";
    try writeBytesAtomic(io, path, "---\na: 1\n---\na: 2\n");
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var docs = try parseAllFile(alloc, io, path, max_bytes_default);
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(alloc);
    }
    try testing.expectEqual(@as(usize, 2), docs.items.len);
    try testing.expectEqualStrings("1", docs.items[0].pathGet(&.{"a"}).?.scalarValue().?);
    try testing.expectEqualStrings("2", docs.items[1].pathGet(&.{"a"}).?.scalarValue().?);

    // A missing file is a clean error.
    try testing.expectError(error.FileNotFound, parseFile(alloc, io, "zig-out-test-nope.yaml", max_bytes_default));
}

test "allocation failures in a bounded read leak nothing" {
    try std.testing.checkAllAllocationFailures(testing.allocator, boundedRead, .{});
}

fn boundedRead(alloc: std.mem.Allocator) !void {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "zig-out-test-bounded.yaml";
    try writeBytesAtomic(io, path, "# comment\na: 1\n");
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const data = try readFile(alloc, io, path, max_bytes_default);
    defer alloc.free(data);
    try testing.expectEqualStrings("# comment\na: 1\n", data);
}

fn expectNoTempFiles(io: std.Io, path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, path) and
            std.mem.indexOf(u8, entry.name, ".yayl-tmp-") != null)
        {
            return error.TempFileLeftBehind;
        }
    }
}
