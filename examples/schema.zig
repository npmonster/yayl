//! Validate a YAML document against an explicit schema.
//!
//! Run with: zig build examples && ./zig-out/bin/schema
//!
//! `yaml.schema` checks a parsed document against a small descriptor
//! and reports structured violations (path + rule + detail). Optional
//! by design: nothing pays for it unless you call it.

const std = @import("std");
const yaml = @import("yayl");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const cases = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "config", .text =
        \\name: api
        \\port: 8080
        \\mode: fast
        \\replicas: 4
        \\
        },
        .{ .name = "bad", .text =
        \\name: api
        \\port: 99999
        \\mode: sideways
        \\
        },
    };

    const server = yaml.schema.Schema.map(&.{
        .{ .key = "name", .schema = &yaml.schema.Schema.strLen(1, 64), .required = true },
        .{ .key = "port", .schema = &yaml.schema.Schema.intRange(1, 65535), .required = true },
        .{ .key = "mode", .schema = &yaml.schema.Schema.strEnum(&.{ "fast", "slow" }) },
        .{ .key = "replicas", .schema = &yaml.schema.Schema.intRange(0, 64) },
    });

    for (cases) |case| {
        var doc = try yaml.parse(allocator, case.text);
        defer doc.deinit();
        const violations = try server.validate(allocator, doc.root.?, "$");
        std.debug.print("{s}: {d} violation(s)\n", .{ case.name, violations.len });
        for (violations) |viol| {
            std.debug.print("  {s}: {s} ({s})\n", .{ viol.path, viol.rule, viol.detail });
        }
        yaml.schema.freeViolations(allocator, violations);
    }
}
