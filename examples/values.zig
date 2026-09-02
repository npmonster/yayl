//! Convert YAML to native Zig values and back.
//!
//! Run with: zig build examples && ./zig-out/bin/values
//!
//! `yaml.value` is the schema-free data model: parse once, get plain
//! Zig data (i64, bool, sequences, maps), or go all the way to a typed
//! struct with `toZig` — and back with `fromZig`/`toNode`.

const std = @import("std");
const yaml = @import("yayl");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const input =
        \\name: api
        \\replicas: 3
        \\enabled: true
        \\labels:
        \\  tier: frontend
        \\  track: stable
        \\
    ;

    // 1. Schema-free: a dynamic Value tree.
    const v = try yaml.value.parseToValue(allocator, input);
    defer yaml.value.freeValue(allocator, v);
    std.debug.print("replicas = {d}\n", .{v.get("replicas").?.int});
    std.debug.print("tier = {s}\n", .{v.get("labels").?.get("tier").?.string});

    // 2. Typed: a struct, matched by field name with defaults applied.
    const Labels = std.StringArrayHashMapUnmanaged([]const u8);
    const Config = struct {
        name: []const u8,
        replicas: u8 = 1, // default applies when the key is missing
        enabled: bool,
        labels: Labels,
    };
    const cfg = try yaml.value.toZig(Config, allocator, v);
    defer yaml.value.deinitZig(Config, allocator, cfg);
    std.debug.print("cfg: {s} x{d}, {d} labels\n", .{ cfg.name, cfg.replicas, cfg.labels.count() });

    // 3. Back: Zig value -> Value -> a document node.
    const back = try yaml.value.fromZig(allocator, cfg);
    defer yaml.value.freeValue(allocator, back);
    var doc = yaml.Document.init(allocator);
    defer doc.deinit();
    doc.root = try yaml.value.toNode(&doc, back);
    const out = try doc.write(allocator);
    std.debug.print("--- normalized YAML ---\n{s}", .{out});
}
