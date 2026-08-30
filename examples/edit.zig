//! Parse, edit as an atomic batch, and re-emit: untouched bytes
//! survive byte for byte (comments, blank lines, quoting, layout).
//!
//! Run with: zig build examples && ./zig-out/bin/edit

const std = @import("std");
const yaml = @import("yayl");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const input =
        \\# deployment config
        \\name: api
        \\replicas: 2
        \\image: api:1.4.0
        \\legacy: true
        \\
    ;

    var doc = try yaml.parse(allocator, input);
    defer doc.deinit();

    // Atomic batch: edits run on a clone and swap in only if ALL
    // succeed. Deleting a missing key is a no-op, not an error.
    var ed = yaml.edit.Editor.init(&doc);
    try ed.apply(&.{
        .{ .set = .{ .path = "$.replicas", .value = try doc.createScalar("5", .plain) } },
        .{ .set = .{ .path = "$.image", .value = try doc.createScalar("api:1.5.0", .plain) } },
        .{ .delete = "$.legacy" },
    });

    const out = try doc.write(allocator);
    std.debug.print("{s}", .{out});
    // # deployment config
    // name: api
    // replicas: 5
    // image: api:1.5.0
}
