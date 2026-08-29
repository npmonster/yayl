//! Debug CLI: print the parser's event stream for a YAML file in the
//! corpus tree notation. Used by scripts/differential.sh to compare
//! yayl against libfyaml (fydump). Not part of the unit suite.
//!
//! Usage: dump <file>

const std = @import("std");
const corpus = @import("corpus_common.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const io = init.io;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // program name
    const path = it.next() orelse {
        std.debug.print("usage: dump <file>\n", .{});
        return error.Usage;
    };
    const input = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(16 << 20));
    const tree = try corpus.renderTree(alloc, input, false);
    var stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, tree);
}
