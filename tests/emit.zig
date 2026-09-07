//! Emit CLI for the emission oracle (scripts/emission-oracle.sh): parse
//! a YAML file with yayl and write the emitted bytes to a second file.
//!
//! Modes (third argument, default `faithful`):
//!   faithful — re-emit the parsed documents verbatim. This is the
//!              byte-faithful path, and every scalar carries the style
//!              the author wrote.
//!   value    — rebuild each document through `yaml.value` and emit the
//!              result. Nothing here has a source span or a parsed
//!              style, so the emitter has to CHOOSE every scalar's form
//!              (`.any`). That is a different decision procedure from
//!              the faithful path, and it was previously ungated: a
//!              string emitted bare because it looked syntactically safe
//!              (`true`, `90210`) re-parses as another type, and no
//!              gate that starts from parsed documents can see it.
//!
//! Exit statuses let the oracle classify:
//!   0 — parsed and emitted (the oracle then checks libfyaml accepts it)
//!   3 — yayl itself rejected the input (nothing to check)
//!   4 — the mode does not apply to this input (nothing emitted)

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
    const mode = it.next() orelse "faithful";

    const input = std.Io.Dir.cwd().readFileAlloc(io, in_path, allocator, .limited(1 << 20)) catch |err| {
        if (err == error.FileNotFound) return err;
        return err;
    };

    var docs = yaml.parseAll(allocator, input) catch |err| {
        std.debug.print("emit: yayl rejected {s}: {s}\n", .{ in_path, @errorName(err) });
        // An explicit status, not a returned error: Zig maps ANY error
        // from main to exit 1, which would make "yayl rejected this
        // input" indistinguishable from a genuine failure.
        std.process.exit(3);
    };
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(allocator);
    }

    const out = if (std.mem.eql(u8, mode, "value"))
        rebuildThroughValue(allocator, docs.items) catch |err| switch (err) {
            // Not every document survives a Value round trip by design:
            // a complex key has no string form, and alias expansion is
            // bounded. Those are documented limits, not emission bugs.
            error.TypeMismatch, error.LimitExceeded, error.NestingTooDeep => std.process.exit(4),
            else => return err,
        }
    else
        try yaml.writeAll(allocator, docs.items);
    defer allocator.free(out);

    var file = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, out);
}

/// Convert every document to an untyped `Value` and build it back into
/// a fresh document, so the emitter picks each scalar's form instead of
/// replaying the author's. Returns the emitted bytes.
fn rebuildThroughValue(allocator: std.mem.Allocator, docs: []yaml.Document) ![]u8 {
    var rebuilt: std.ArrayList(yaml.Document) = .empty;
    defer {
        for (rebuilt.items) |*d| d.deinit();
        rebuilt.deinit(allocator);
    }
    for (docs) |*doc| {
        var fresh = yaml.Document.init(allocator);
        errdefer fresh.deinit();
        if (doc.root) |root| {
            const v = try yaml.value.nodeToValue(allocator, root);
            defer yaml.value.freeValue(allocator, v);
            fresh.root = try yaml.value.toNode(&fresh, v);
        }
        try rebuilt.append(allocator, fresh);
    }
    return yaml.writeAll(allocator, rebuilt.items);
}
