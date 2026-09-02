//! File I/O: bounded reads and atomic writes.
//!
//! Run with: zig build examples && ./zig-out/bin/files
//!
//! `yaml.file` wraps parsing and writing with production safeguards:
//! reads are bounded (a huge file fails with StreamTooLong, not OOM)
//! and writes are atomic (temp file + rename, so a crash never leaves
//! a half-written YAML file behind).

const std = @import("std");
const yaml = @import("yayl");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const path = "yayl-files-example.yaml";

    // Write bytes atomically (temp file, sync, rename).
    try yaml.file.writeBytesAtomic(io, path,
        \\# written by the files example
        \\counter: 1
        \\
    );

    // Bounded read + parse. The bound is explicit: an oversized file
    // fails with error.StreamTooLong rather than exhausting memory.
    var doc = try yaml.file.parseFile(allocator, io, path, yaml.file.max_bytes_default);
    defer doc.deinit();

    // Edit and write back atomically; untouched bytes survive.
    try doc.pathSet(&.{"counter"}, try doc.createScalar("2", .plain));
    try yaml.file.writeFile(&doc, allocator, io, path);

    // Read the result back and show it.
    const text = try yaml.file.readFile(allocator, io, path, yaml.file.max_bytes_default);
    std.debug.print("--- {s} ---\n{s}", .{ path, text });

    // Clean up the example's file.
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}
