//! File I/O.
//!
//! Convenience adapters between files and the document model. All
//! reads are bounded by `max_bytes` (a malicious or accidental
//! multi-gigabyte file fails with `StreamTooLong`, not OOM), and
//! writes are atomic (temp file + rename), so a crash never leaves a
//! half-written YAML file behind.
//!
//! STREAMING DECISION (documented, deliberate): yayl's parser is
//! pull-based at the *event* level (`Parser.nextEvent`) but requires
//! the whole input in memory; there is no chunked reader.
//!
//! The load-bearing reason is round-trip fidelity, not scanning.
//! `Document.parse` keeps a copy of the entire input for the document
//! (`document.zig`, `SharedSource`: one copy per stream, shared by its
//! documents), and every `Node.src` is an absolute byte offset into
//! that copy. Faithful
//! emission is then literally `src[a..b]` slicing: "untouched bytes are
//! exact" is a promise that the original bytes are still there to
//! copy. A reader that discards consumed chunks cannot keep that
//! promise. Chunked input is therefore not merely awkward here -- it is
//! incompatible with the library's central guarantee, and a chunked
//! layer would have to be a parse-only mode with round-tripping off.
//!
//! Scanner lookahead is the lesser constraint and is often quoted as
//! the reason; it is bounded. Simple keys expire after
//! `scanner.max_simple_key_length` (1 KiB), so a sliding window would
//! serve the scanner. It is the CST that needs the whole buffer.
//!
//! The *event* API is already chunk-ready: `Parser.nextEvent` pulls,
//! and the scanner compacts its token queue as it goes. So a streaming
//! layer on top of `Parser` remains possible for callers who want
//! events and not byte-faithful re-emission.
//!
//! CACHING DECISION: no parse cache ships in v1.
//!
//! The usual objection is invalidation -- an mtime/hash-keyed cache
//! depends on filesystem semantics this library does not own (mtime
//! granularity, hard links, network clock skew). True, but the sharper
//! objection is that a `Document` is mutable. Edits mark nodes in place
//! (`Node.modified`) and rewrite the tree, so two callers handed the
//! same cached document would corrupt each other. A correct cache would
//! have to hand out `edit.cloneTree` copies, and cloning a tree along
//! with its spans and dropped-entry tombstones is not clearly cheaper
//! than re-parsing the bytes. That is why this is a non-goal rather
//! than merely deferred work. Applications that know their own access
//! pattern can key a cache on `parseFile`'s inputs trivially.
//!
//! PARAMETER ORDER: the allocator comes first (after the document
//! receiver for write-style functions), then `io`, then `path`, then
//! options (e.g. `max_bytes`).

const std = @import("std");
const builtin = @import("builtin");
const diag = @import("diag.zig");
const document_mod = @import("document.zig");

const Document = document_mod.Document;

pub const max_bytes_default: usize = 64 << 20; // 64 MiB

/// The permission bits a create call should apply. POSIX `stat` reports
/// the file-type bits (`S_IFREG` ...) in `mode` too; `open` ignores them,
/// but carrying them in a permission value is wrong and makes an equality
/// check compare 0o100600 against 0o600. Windows attributes pass through.
fn permissionBits(p: std.Io.File.Permissions) std.Io.File.Permissions {
    if (comptime builtin.os.tag == .windows) return p;
    return @enumFromInt(@as(u32, @intFromEnum(p)) & 0o7777);
}

/// The mode to create a temp file with: restrictive, so there is never a
/// window in which it is wider than the target. The target's exact mode is
/// applied with `fchmod` afterwards (which ignores the umask). Windows
/// attributes are not modes, so the default stands there.
fn restrictivePermissions() std.Io.File.Permissions {
    if (comptime builtin.os.tag == .windows) return .default_file;
    return @enumFromInt(0o600);
}

/// I/O failures plus the parse-error vocabulary the document layer can
/// surface. A convenience vocabulary for callers, NOT an annotation: the
/// public functions use inferred error sets, so they can also return
/// `error.NameTooLong` and the underlying filesystem errors.
pub const Error = error{ StreamTooLong, FileNotFound, AccessDenied, OutOfMemory } || diag.YamlError;

/// Parse the first document of the file at `path`, which may be at most
/// `max_bytes` long. That is the input bound for the parse too, so it can
/// raise the default 64 MiB as well as lower it.
pub fn parseFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    max_bytes: usize,
) !Document {
    return parseFileOpts(allocator, io, path, null, .{ .max_input_bytes = max_bytes });
}

/// `parseFile` with every parse option, and positioned diagnostics in `d`
/// (null for none). The file may be at most `options.max_input_bytes`
/// long.
pub fn parseFileOpts(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    d: ?*diag.Diag,
    options: document_mod.ParseOptions,
) !Document {
    const input = try readFile(allocator, io, path, options.max_input_bytes);
    defer allocator.free(input);
    return Document.parseOpts(allocator, input, d, options);
}

/// Parse every document in the file at `path`; see `parseFile`.
pub fn parseAllFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    max_bytes: usize,
) !std.ArrayList(Document) {
    return parseAllFileOpts(allocator, io, path, null, .{ .max_input_bytes = max_bytes });
}

/// `parseAllFile` with every parse option; see `parseFileOpts`.
pub fn parseAllFileOpts(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    d: ?*diag.Diag,
    options: document_mod.ParseOptions,
) !std.ArrayList(Document) {
    const input = try readFile(allocator, io, path, options.max_input_bytes);
    defer allocator.free(input);
    return Document.parseAllOpts(allocator, input, d, options);
}

/// Render `doc` and write it to `path` atomically: the bytes land in
/// a sibling temp file that is renamed over `path` only after a
/// successful write. On error, `path` is untouched. When `path` is a
/// symbolic link, the file it points to is replaced and the link kept.
pub fn writeFile(doc: *const Document, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const bytes = try doc.write(allocator);
    defer allocator.free(bytes);
    return writeBytesAtomic(io, path, bytes);
}

/// Atomically write raw bytes to `path` (temp file + rename). Through a
/// symbolic link, the file it points to is replaced and the link kept:
/// renaming over the link itself replaced it with a regular file and
/// left the real file unchanged. A link whose target does not exist is
/// `error.FileNotFound`.
pub fn writeBytesAtomic(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = if (isSymlink(io, path))
        real_buf[0..try cwd.realPathFile(io, path, &real_buf)]
    else
        path;
    // The temp file sits next to the target (a rename cannot cross file
    // systems) under a short name of its own: `path` plus a suffix pushed
    // a long but legal file name past the platform's name limit.
    const tmp_name = ".yayl-tmp-".len + 8; // u32 in hex
    var buf: [std.fs.max_path_bytes + 1 + tmp_name]u8 = undefined;
    const tmp_dir = std.fs.path.dirname(target);
    // Preserve the target's permissions across the rename. The temp is
    // created RESTRICTIVELY so it is never wider than the target, then its
    // exact mode is set with fchmod: a create mode is filtered by the
    // umask (022 strips group/other write), so a 0o666 target would
    // otherwise come back narrowed to 0o644. With no target the default
    // mode stands.
    var create_flags: std.Io.Dir.CreateFileOptions = .{ .truncate = true, .exclusive = true };
    var restore_mode: ?std.Io.File.Permissions = null;
    if (cwd.statFile(io, target, .{})) |st| {
        restore_mode = permissionBits(st.permissions);
        create_flags.permissions = restrictivePermissions();
    } else |_| {}
    var attempt: usize = 0;
    while (true) {
        attempt += 1;
        var rand_bytes: [4]u8 = undefined;
        io.random(&rand_bytes);
        const r = std.mem.readInt(u32, &rand_bytes, .little);
        const tmp_path = (if (tmp_dir) |dir|
            std.fmt.bufPrint(&buf, "{s}" ++ std.fs.path.sep_str ++ ".yayl-tmp-{x:0>8}", .{ dir, r })
        else
            std.fmt.bufPrint(&buf, ".yayl-tmp-{x:0>8}", .{r})) catch return error.NameTooLong;
        var file = cwd.createFile(io, tmp_path, create_flags) catch |err| switch (err) {
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
        if (restore_mode) |mode| try file.setPermissions(io, mode);
        try file.writeStreamingAll(io, bytes);
        // Flush to stable storage before the rename so the visible
        // file never contains torn content after a crash.
        try file.sync(io);
        file.close(io);
        file_open = false;
        try cwd.rename(tmp_path, cwd, target, io);
        committed = true;
        return;
    }
}

fn isSymlink(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .sym_link;
}

/// Read a whole file, bounded. Returns `error.StreamTooLong` past
/// `max_bytes`; a file of exactly `max_bytes` is read, as `parseOpts`
/// accepts an input of exactly `max_input_bytes`.
pub fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max_bytes: usize) ![]u8 {
    // `.limited(n)` fails once the n-th byte is reached, not past it.
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes +| 1));
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

test "parse and atomically rewrite a file" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "zig-out-test-file.yaml";
    try writeBytesAtomic(io, path, "# comment\na: 1\nb: 2\n");
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var doc = try parseFile(allocator, io, path, max_bytes_default);
    defer doc.deinit();
    try testing.expectEqualStrings("1", doc.pathGet(&.{"a"}).?.scalarValue().?);

    // Edit and rewrite: byte-faithful for untouched parts.
    try doc.pathSet(&.{"b"}, try doc.createScalar("TWO", .plain));
    try writeFile(&doc, allocator, io, path);
    const round = try readFile(allocator, io, path, max_bytes_default);
    defer allocator.free(round);
    try testing.expectEqualStrings("# comment\na: 1\nb: TWO\n", round);

    try expectNoTempFiles(io, path);
}

test "atomic write removes its temp file when rename fails" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
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
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "zig-out-test-big.yaml";
    try writeBytesAtomic(io, path, "a: 1\n" ** 4);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try testing.expectError(error.StreamTooLong, readFile(allocator, io, path, 4));
}

test "parseAllFile reads every document" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "zig-out-test-multidoc.yaml";
    try writeBytesAtomic(io, path, "---\na: 1\n---\na: 2\n");
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var docs = try parseAllFile(allocator, io, path, max_bytes_default);
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 2), docs.items.len);
    try testing.expectEqualStrings("1", docs.items[0].pathGet(&.{"a"}).?.scalarValue().?);
    try testing.expectEqualStrings("2", docs.items[1].pathGet(&.{"a"}).?.scalarValue().?);

    // A missing file is a clean error.
    try testing.expectError(error.FileNotFound, parseFile(allocator, io, "zig-out-test-nope.yaml", max_bytes_default));
}

test "allocation failures in a bounded read leak nothing" {
    try std.testing.checkAllAllocationFailures(testing.allocator, boundedRead, .{});
}

fn boundedRead(allocator: std.mem.Allocator) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "zig-out-test-bounded.yaml";
    try writeBytesAtomic(io, path, "# comment\na: 1\n");
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const data = try readFile(allocator, io, path, max_bytes_default);
    defer allocator.free(data);
    try testing.expectEqualStrings("# comment\na: 1\n", data);
}

fn expectNoTempFiles(io: std.Io, path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        _ = path;
        if (std.mem.startsWith(u8, entry.name, ".yayl-tmp-")) return error.TempFileLeftBehind;
    }
}

test "a deep but valid path is not refused by the temp-name buffer" {
    // The temp name went into a fixed 512-byte buffer, so a path longer
    // than ~495 bytes -- well inside PATH_MAX on every platform -- failed
    // an otherwise perfectly good atomic write with error.NoSpaceLeft.
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    // 13 nested 40-char directories: ~540 bytes of path, plus the file
    // name -- comfortably inside PATH_MAX, comfortably past 512.
    const segment = "zig-out-test-deep-0123456789012345678901";
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(allocator);
    for (0..13) |_| {
        try path_buf.appendSlice(allocator, segment);
        try path_buf.append(allocator, '/');
        cwd.createDir(io, path_buf.items[0 .. path_buf.items.len - 1], .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    try path_buf.appendSlice(allocator, "deep.yaml");
    const path = path_buf.items;
    try testing.expect(path.len > 512);

    defer {
        cwd.deleteFile(io, path) catch {};
        var end = path.len - "deep.yaml".len;
        while (end > 0) : (end -= segment.len + 1) {
            cwd.deleteDir(io, path[0 .. end - 1]) catch {};
        }
    }

    try writeBytesAtomic(io, path, "a: 1\n");
    const round = try readFile(allocator, io, path, max_bytes_default);
    defer allocator.free(round);
    try testing.expectEqualStrings("a: 1\n", round);
}

test "atomic write preserves the target's permissions" {
    if (comptime builtin.os.tag != .windows) {
        const allocator = testing.allocator;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const cwd = std.Io.Dir.cwd();
        const path = "zig-out-test-perms.yaml";
        defer cwd.deleteFile(io, path) catch {};

        // Every case must survive an atomic rewrite with its mode intact.
        // 0o600 is umask-immune; 0o666 is the case that catches the bug --
        // a create mode is filtered by the umask (022 strips group/other
        // write), so relying on createFile's mode narrowed it to 0o644.
        // fchmod ignores the umask, which is why the fix uses it.
        const modes = [_]std.Io.File.Permissions{
            @enumFromInt(0o600), @enumFromInt(0o666), @enumFromInt(0o640),
        };
        for (modes) |want| {
            {
                // Establish the target's mode explicitly: createFile's own
                // mode is umask-filtered and cannot set 0o666.
                var f = try cwd.createFile(io, path, .{ .truncate = true });
                try f.setPermissions(io, want);
                f.close(io);
            }
            try writeBytesAtomic(io, path, "a: 3\n");
            const st = try cwd.statFile(io, path, .{});
            try testing.expectEqual(want, permissionBits(st.permissions));
        }
    }
}

test "a file of exactly max_bytes is read, and options reach the parse" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    // `.limited(max_bytes)` failed on the max_bytes-th byte, so a file the
    // parser would accept (`max_input_bytes` is inclusive) was refused.
    const path = "zig-out-test-exact.yaml";
    try writeBytesAtomic(io, path, "a: 1\n");
    defer cwd.deleteFile(io, path) catch {};
    const data = try readFile(allocator, io, path, 5);
    defer allocator.free(data);
    try testing.expectEqualStrings("a: 1\n", data);
    try testing.expectError(error.StreamTooLong, readFile(allocator, io, path, 4));
    var doc = try parseFile(allocator, io, path, 5);
    doc.deinit();

    // Every parse option reaches the parse (merge keys here), and a
    // positioned diagnostic comes back.
    const merge = "zig-out-test-merge.yaml";
    try writeBytesAtomic(io, merge, "b: &b {x: 1}\nc:\n  <<: *b\n");
    defer cwd.deleteFile(io, merge) catch {};
    var merged = try parseFileOpts(allocator, io, merge, null, .{ .resolve_merge_keys = true });
    defer merged.deinit();
    try testing.expectEqualStrings("1", merged.pathGet(&.{ "c", "x" }).?.scalarValue().?);
    var all = try parseAllFileOpts(allocator, io, merge, null, .{ .resolve_merge_keys = true });
    defer {
        for (all.items) |*d| d.deinit();
        all.deinit(allocator);
    }
    try testing.expectEqualStrings("1", all.items[0].pathGet(&.{ "c", "x" }).?.scalarValue().?);
}

test "an atomic write through a symlink replaces the file it points to" {
    if (comptime builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    // Renaming over the link replaced it with a regular file and left the
    // real file as it was: a config kept behind a link silently forked.
    const real = "zig-out-test-real.yaml";
    const link = "zig-out-test-link.yaml";
    try writeBytesAtomic(io, real, "a: 1\n");
    defer cwd.deleteFile(io, real) catch {};
    cwd.deleteFile(io, link) catch {};
    try cwd.symLink(io, real, link, .{});
    defer cwd.deleteFile(io, link) catch {};

    try writeBytesAtomic(io, link, "a: 2\n");
    const st = try cwd.statFile(io, link, .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.sym_link, st.kind);
    const round = try readFile(allocator, io, real, max_bytes_default);
    defer allocator.free(round);
    try testing.expectEqualStrings("a: 2\n", round);
    try expectNoTempFiles(io, real);

    // A link to nothing is refused, and nothing is created.
    const dangling = "zig-out-test-dangling.yaml";
    cwd.deleteFile(io, dangling) catch {};
    try cwd.symLink(io, "zig-out-test-nowhere.yaml", dangling, .{});
    defer cwd.deleteFile(io, dangling) catch {};
    try testing.expectError(error.FileNotFound, writeBytesAtomic(io, dangling, "x\n"));
}

test "an atomic write does not lengthen the file name" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    // The temp file was named `path` plus `.yayl-tmp-NNN`, so a 250-byte
    // name -- legal, and creatable directly -- failed with NameTooLong.
    const name = "zig-out-test-" ++ "n" ** 232 ++ ".yaml";
    try testing.expectEqual(@as(usize, 250), name.len);
    {
        var f = try cwd.createFile(io, name, .{});
        f.close(io);
    }
    defer cwd.deleteFile(io, name) catch {};
    try writeBytesAtomic(io, name, "a: 1\n");
    const round = try readFile(allocator, io, name, max_bytes_default);
    defer allocator.free(round);
    try testing.expectEqualStrings("a: 1\n", round);
}
