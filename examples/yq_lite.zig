//! yq_lite — a small command-line YAML tool built entirely on the public
//! `yaml` module. It is the library's dogfood consumer: file I/O, the
//! path/edit API, value conversion, schema validation and atomic write-back
//! in one program, so API friction shows up here and not in a user's
//! project.
//!
//! Run with: zig build examples && ./zig-out/bin/yq_lite
//!
//! Commands:
//!   yq_lite get    <file> <path>            print the value at path
//!   yq_lite set    <file> <path> <value>    set and rewrite the file
//!   yq_lite delete <file> <path>            remove an entry
//!   yq_lite append <file> <seq> <value>     append to a sequence
//!   yq_lite demo   <file> <out>             full-surface demo, verified
//!
//! Paths use the documented grammar (`$.a.b[0]`, `[?k=v]`, `..name`).

const std = @import("std");
const yaml = @import("yayl");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();
    _ = it.next(); // program name

    const cmd = it.next() orelse return usage();
    const file = it.next() orelse return usage();

    if (std.mem.eql(u8, cmd, "demo")) {
        const out = it.next() orelse return usage();
        return demo(allocator, io, file, out);
    }

    // Every other command is the shape a real config tool has: read the
    // file, mutate, write it back atomically.
    var doc = try yaml.file.parseFile(allocator, io, file, yaml.file.max_bytes_default);
    defer doc.deinit();
    var ed = yaml.edit.Editor.init(&doc);

    if (std.mem.eql(u8, cmd, "get")) {
        const path = it.next() orelse return usage();
        printNode(try ed.one(path));
    } else if (std.mem.eql(u8, cmd, "set")) {
        const path = it.next() orelse return usage();
        const value = it.next() orelse return usage();
        try ed.set(path, try doc.createScalar(value, .plain));
        try yaml.file.writeFile(&doc, allocator, io, file);
    } else if (std.mem.eql(u8, cmd, "delete")) {
        const path = it.next() orelse return usage();
        try ed.delete(path);
        try yaml.file.writeFile(&doc, allocator, io, file);
    } else if (std.mem.eql(u8, cmd, "append")) {
        const seq = it.next() orelse return usage();
        const value = it.next() orelse return usage();
        try ed.apply(&.{.{ .append = .{
            .sequence = seq,
            .value = try doc.createScalar(value, .plain),
        } }});
        try yaml.file.writeFile(&doc, allocator, io, file);
    } else {
        return usage();
    }
}

fn usage() void {
    std.debug.print(
        \\usage: yq_lite <command> ...
        \\  get    <file> <path>
        \\  set    <file> <path> <value>
        \\  delete <file> <path>
        \\  append <file> <seq-path> <value>
        \\  demo   <file> <out-file>   full-surface demo
        \\
    , .{});
}

fn printNode(node: *const yaml.Node) void {
    switch (node.resolveAlias().data) {
        .scalar => |s| std.debug.print("{s}\n", .{s.value}),
        .alias => |a| std.debug.print("*{s}\n", .{a.name}),
        .mapping => std.debug.print("<mapping with {d} entries>\n", .{node.pairs().?.len}),
        .sequence => std.debug.print("<sequence with {d} items>\n", .{node.items().?.len}),
    }
}

/// The full-surface demo, run in CI against a real fixture: every edit
/// operation, value conversion in and out of Zig types, schema validation,
/// and an atomic write whose untouched bytes survive. Any failure is a
/// non-zero exit; the assertions at the end are the point.
fn demo(allocator: std.mem.Allocator, io: std.Io, file: []const u8, out_path: []const u8) !void {
    // 1. File I/O: parse from disk through the public file layer.
    var doc = try yaml.file.parseFile(allocator, io, file, yaml.file.max_bytes_default);
    defer doc.deinit();
    const root = doc.root orelse return error.EmptyDocument;
    if (!root.isMapping()) return error.ExpectedMappingFixture;
    std.debug.print("parsed {s}: {d} top-level entries\n", .{ file, root.pairs().?.len });

    var ed = yaml.edit.Editor.init(&doc);

    // 2. Get by path.
    const style = try ed.one("$.MD003.style");
    std.debug.print("MD003.style = {s}\n", .{style.scalarValue().?});

    // 3. Set: change one entry deep in the tree.
    try ed.set("$.MD013.line_length", try doc.createScalar("100", .plain));

    // 4. Delete: MD024 (and its line) goes away.
    try ed.delete("$.MD024");

    // 5. Insert: build a small sequence, then splice into it.
    const rules = try doc.createSequence();
    try doc.sequenceAppend(rules, try doc.createScalar("add-heading", .plain));
    try doc.sequenceAppend(rules, try doc.createScalar("ul-style", .plain));
    try doc.pathSet(&.{ "dogfood", "rules" }, rules);
    try ed.apply(&.{.{ .insert = .{
        .sequence = "$.dogfood.rules",
        .position = "$.dogfood.rules[1]",
        .value = try doc.createScalar("line-length", .plain),
        .before = true,
    } }});

    // 6. Move: relocate the first rule into a sibling mapping.
    try ed.apply(&.{.{ .move = .{
        .from = "$.dogfood.rules[0]",
        .to = "$.dogfood",
        .key = "archived",
    } }});

    // 7. Value conversion: subtree -> Value -> Zig struct -> Value -> node.
    const dogfood_node = doc.pathGet(&.{"dogfood"}).?;
    const val = try yaml.value.nodeToValue(allocator, dogfood_node);
    defer yaml.value.freeValue(allocator, val);
    const Rules = struct {
        rules: []const []const u8,
        archived: []const u8,
    };
    const cfg = try yaml.value.toZig(Rules, allocator, val);
    defer yaml.value.deinitZig(Rules, allocator, cfg);
    // The insert and the move both landed, in the shapes expected.
    if (!std.mem.eql(u8, cfg.rules[0], "line-length")) return error.DemoValueMismatch;
    if (!std.mem.eql(u8, cfg.archived, "add-heading")) return error.DemoValueMismatch;
    const back = try yaml.value.fromZig(allocator, cfg);
    defer yaml.value.freeValue(allocator, back);
    try doc.pathSet(&.{"dogfood"}, try yaml.value.toNode(&doc, back));

    // 8. Schema validation.
    const schema = yaml.schema.Schema.map(&.{
        .{ .key = "rules", .schema = &yaml.schema.Schema.seq(&yaml.schema.Schema.str), .required = true },
        .{ .key = "archived", .schema = &yaml.schema.Schema.str, .required = true },
    });
    const violations = try schema.validate(allocator, doc.pathGet(&.{"dogfood"}).?, "$.dogfood");
    defer yaml.schema.freeViolations(allocator, violations);
    if (violations.len != 0) return error.DemoSchemaViolation;
    std.debug.print("schema: $.dogfood valid\n", .{});

    // 9. Atomic write-back, then verify what survived.
    try yaml.file.writeFile(&doc, allocator, io, out_path);
    const rewritten = try yaml.file.readFile(allocator, io, out_path, yaml.file.max_bytes_default);

    var check = try yaml.parse(allocator, rewritten);
    defer check.deinit();
    // The edit landed...
    try expectEqualStrings("100", check.pathGet(&.{ "MD013", "line_length" }).?.scalarValue().?);
    try expectEqualStrings("line-length", check.pathGet(&.{ "dogfood", "rules", "0" }).?.scalarValue().?);
    // ...the deletion happened...
    if (check.pathGet(&.{"MD024"}) != null) return error.DemoDeleteDidNotApply;
    // ...and the untouched bytes are exactly the author's: comments, the
    // four-space indent of MD007, everything.
    if (std.mem.indexOf(u8, rewritten, "# First heading is a top-level heading\n") == null)
        return error.DemoCommentLost;
    if (std.mem.indexOf(u8, rewritten, "# Heading style (ATX is leading # symbols)\nMD003:\n  style: atx\n") == null)
        return error.DemoCommentLost;
    if (std.mem.indexOf(u8, rewritten, "MD007:\n    indent: 2\n") == null)
        return error.DemoIndentNormalized;
    std.debug.print("demo ok: wrote {s} with edits applied, untouched bytes preserved\n", .{out_path});
}

fn expectEqualStrings(want: []const u8, got: []const u8) !void {
    if (!std.mem.eql(u8, want, got)) return error.DemoMismatch;
}
