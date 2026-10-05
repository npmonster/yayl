//! Generate edited documents for an independent libyaml compatibility gate.
const std = @import("std");
const yaml = @import("yayl");

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() != .ok) @panic("compatibility gate leaked");
    const allocator = gpa.allocator();
    const io = init.io;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const directory = args.next() orelse return error.Usage;

    const Case = struct { input: []const u8, path: []const u8, alias: bool = false };
    const cases = [_]Case{
        .{ .input = "a: 1\n\t\nb: 2\n", .path = "$.a" },
        .{ .input = "a: 1\n \t\nb: 2\n", .path = "$.a" },
        .{ .input = "a: 1\n  \t \nb: 2\n", .path = "$.a" },
        .{ .input = "a: 1\n \t\n# comment\n  \t\nb: 2\n", .path = "$.a" },
        .{ .input = "a: 1\n \t# comment\nb: 2\n", .path = "$.a" },
        .{ .input = "a: 1\n \t\n  \t# comment\n \t\nb: 2\n", .path = "$.a" },
        .{ .input = "m:\n  a: 1\n \t\n  b: 2\n", .path = "$.m.a" },
        .{ .input = "- 1\n \t\n- 2\n", .path = "$[0]" },
        .{ .input = "1\n \t\n", .path = "$" },
        .{ .input = "---\na: 1\n \t\nb: 2\n", .path = "$.a" },
        .{ .input = "a: [1]\n \t# comment\nb: 2\n", .path = "$.a[0]" },
        .{ .input = "[1]\n \t\n", .path = "$[0]" },
        .{ .input = "? a\n: 1\n \t\nb: 2\n", .path = "$.a" },
        .{ .input = "a: 1\n \t# text\tkept\nb: 2\n", .path = "$.a" },
        .{ .input = "a: 1\n \t", .path = "$.a" },
        .{ .input = "base: &x \"x\\ny\\n\"\na: 1\n \t# comment\nb: 2\n", .path = "$.a", .alias = true },
    };
    var count: usize = 0;
    for (cases) |c| {
        for ([_][]const u8{ "\n", "\r\n", "\r" }) |nl| {
            for ([_][]const u8{ "", "\u{FEFF}" }) |bom| {
                const lines = try std.mem.replaceOwned(u8, allocator, c.input, "\n", nl);
                defer allocator.free(lines);
                for ([_]bool{ false, true }) |stream| {
                    const input = if (stream)
                        try std.mem.concat(allocator, u8, &.{ bom, lines, nl, "---", nl, "next: 2", nl })
                    else
                        try std.mem.concat(allocator, u8, &.{ bom, lines });
                    defer allocator.free(input);
                    for ([_]yaml.ScalarStyle{ .plain, .single_quoted, .double_quoted, .literal, .folded }) |style| {
                        var docs = try yaml.parseAll(allocator, input);
                        defer {
                            for (docs.items) |*part| part.deinit();
                            docs.deinit(allocator);
                        }
                        const doc = &docs.items[0];
                        var editor = yaml.edit.Editor.init(doc);
                        const replacement = if (c.alias)
                            try doc.createAlias(doc.root.?.lookup("base").?)
                        else
                            try doc.createScalar("x\ny\n", style);
                        try editor.apply(&.{.{ .set = .{ .path = c.path, .value = replacement } }});
                        const output = if (stream) try yaml.writeAll(allocator, docs.items) else try doc.write(allocator);
                        defer allocator.free(output);
                        const path = try std.fmt.allocPrint(allocator, "{s}/{s}{d}.yaml", .{ directory, if (stream) "stream-" else "", count });
                        defer allocator.free(path);
                        var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
                        defer file.close(io);
                        try file.writeStreamingAll(io, output);
                        count += 1;
                    }
                }
            }
        }
    }
    std.debug.print("libyaml compatibility: {d} edited streams generated\n", .{count});
}
