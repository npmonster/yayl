//! Emit CLI for the emission oracle (scripts/emission-oracle.sh): parse
//! a YAML file with yayl and write the emitted bytes to a second file.
//! Exit statuses let the oracle classify:
//!   0 — parsed and emitted (the oracle then checks libfyaml accepts it)
//!   3 — yayl itself rejected the input (nothing to check)

const std = @import("std");
const yaml = @import("yayl");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();
    _ = it.next(); // program name
    const in_path = it.next() orelse return error.Usage;
    const out_path = it.next() orelse return error.Usage;

    const input = std.Io.Dir.cwd().readFileAlloc(io, in_path, allocator, .limited(1 << 20)) catch |err| {
        if (err == error.FileNotFound) return err;
        return err;
    };

    var docs = yaml.parseAll(allocator, input) catch |err| {
        std.debug.print("emit: yayl rejected {s}: {s}\n", .{ in_path, @errorName(err) });
        return error.YaylRejected;
    };
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(allocator);
    }

    const out = try yaml.writeAll(allocator, docs.items);
    defer allocator.free(out);

    var file = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, out);
}
