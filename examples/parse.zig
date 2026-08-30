//! Parse a YAML document and read values out of it.
//!
//! Run with: zig build examples && ./zig-out/bin/parse
//!
//! `main(init: std.process.Init)` hands us an arena and the platform
//! I/O context; the arena frees everything at exit. Library callers
//! bring their own allocator and free what the library returns.

const std = @import("std");
const yaml = @import("yayl");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const input =
        \\service: api
        \\replicas: 3
        \\ports: [8080, 8443]
        \\
    ;

    var doc = try yaml.parse(allocator, input);
    defer doc.deinit();

    std.debug.print("service = {s}\n", .{doc.pathGet(&.{"service"}).?.scalarValue().?});
    for (doc.pathGet(&.{"ports"}).?.items().?) |port| {
        std.debug.print("port = {s}\n", .{port.scalarValue().?});
    }

    // Parse errors are error unions; attach a Diag to also learn where
    // the problem is.
    var d: yaml.Diag = .{ .allocator = allocator };
    defer d.deinit();
    _ = yaml.parseDiag(allocator, "a: b\n  c: d\n", &d) catch {
        const report = try d.render(allocator);
        std.debug.print("{s}", .{report}); // "2:4: error: ..."
        return;
    };
}
