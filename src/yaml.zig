//! yayl — a YAML parser and emitter for Zig.
//!
//! This library is a native Zig conversion of libfyaml, a full-featured
//! YAML 1.2 processing library written in C. The module layout mirrors
//! libfyaml's subsystems one-to-one so the conversion can proceed file by
//! file (see AGENTS.md for the mapping table and status).
//!
//! Quick start:
//!
//! ```zig
//! const yaml = @import("yayl");
//!
//! var doc = try yaml.parse(allocator, "hello: world\n");
//! defer doc.deinit();
//!
//! const value = doc.pathGet(&.{"hello"}).?.scalarValue().?;
//!
//! const text = try doc.write(allocator); // back to YAML
//! defer allocator.free(text);
//! ```

const std = @import("std");

pub const diag = @import("diag.zig");
pub const pool = @import("pool.zig");
pub const utf8 = @import("utf8.zig");
pub const ctype = @import("ctype.zig");
pub const token = @import("token.zig");
pub const scanner = @import("scanner.zig");
pub const event = @import("event.zig");
pub const parser = @import("parser.zig");
pub const document = @import("document.zig");
pub const emitter = @import("emitter.zig");

// Public vocabulary, flattened for convenience.
pub const Mark = diag.Mark;
pub const Diag = diag.Diag;
pub const Diagnostic = diag.Diagnostic;
pub const YamlError = diag.YamlError;
pub const ScalarStyle = token.ScalarStyle;
pub const NodeType = document.NodeType;
pub const ScalarKind = document.ScalarKind;
pub const scalarKind = document.scalarKind;
pub const Node = document.Node;
pub const Pair = document.Pair;
pub const Document = document.Document;
pub const Parser = parser.Parser;
pub const Scanner = scanner.Scanner;
pub const Token = token.Token;
pub const Event = event.Event;
pub const EventType = event.Event.Type;

/// Parse the first YAML document in `input`. Additional documents in the
/// same stream are ignored; use `parseAll` for multi-document streams.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Document {
    return Document.parse(allocator, input);
}

/// Parse every YAML document in `input`. The caller owns the returned list
/// and must `deinit` every document plus the list itself.
pub fn parseAll(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(Document) {
    return Document.parseAll(allocator, input);
}

test {
    _ = diag;
    _ = pool;
    _ = utf8;
    _ = ctype;
    _ = token;
    _ = scanner;
    _ = event;
    _ = parser;
    _ = document;
    _ = emitter;
}

test "parse and write round trip" {
    const alloc = std.testing.allocator;
    var doc = try parse(alloc, "name: yayl\nlang: zig\n");
    defer doc.deinit();
    try std.testing.expectEqualStrings("yayl", doc.pathGet(&.{"name"}).?.scalarValue().?);
    const out = try doc.write(alloc);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("name: yayl\nlang: zig\n", out);
}

test "build a document programmatically" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    const root = try doc.createMapping();
    doc.root = root;
    const list = try doc.createSequence();
    try doc.pathSet(&.{"items"}, list);
    try doc.sequenceAppend(list, try doc.createScalar("one", .plain));
    try doc.sequenceAppend(list, try doc.createScalar("two", .plain));

    const out = try doc.write(alloc);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("items:\n  - one\n  - two\n", out);
}

test "invalid input surfaces a yaml error" {
    const alloc = std.testing.allocator;
    const r = parse(alloc, "a: b\n  c: d\n"); // bad indentation
    try std.testing.expectError(error.InvalidSyntax, r);
}

test "multi-document stream" {
    const alloc = std.testing.allocator;
    var docs = try parseAll(alloc, "---\na: 1\n---\nb: 2\n");
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 2), docs.items.len);
    try std.testing.expectEqualStrings("1", docs.items[0].pathGet(&.{"a"}).?.scalarValue().?);
    try std.testing.expectEqualStrings("2", docs.items[1].pathGet(&.{"b"}).?.scalarValue().?);
}

test "realistic configuration round trip" {
    const alloc = std.testing.allocator;
    const src =
        \\database:
        \\  host: localhost
        \\  port: 5432
        \\  credentials:
        \\    user: admin
        \\    password: "s3cr3t"
        \\replicas:
        \\  - db-1
        \\  - db-2
        \\features: [alpha, beta]
        \\enabled: true
        \\
    ;
    var doc = try parse(alloc, src);
    defer doc.deinit();
    try std.testing.expectEqualStrings("admin", doc.pathGet(&.{ "database", "credentials", "user" }).?.scalarValue().?);
    try std.testing.expectEqualStrings("db-2", doc.pathGet(&.{"replicas"}).?.items().?[1].scalarValue().?);
    const out = try doc.write(alloc);
    defer alloc.free(out);
    // Re-parse the emitted text and compare the tree semantically.
    var doc2 = try parse(alloc, out);
    defer doc2.deinit();
    try std.testing.expectEqualStrings("admin", doc2.pathGet(&.{ "database", "credentials", "user" }).?.scalarValue().?);
    try std.testing.expectEqualStrings("db-2", doc2.pathGet(&.{"replicas"}).?.items().?[1].scalarValue().?);
    try std.testing.expectEqualStrings("true", doc2.pathGet(&.{"enabled"}).?.scalarValue().?);
}

test "allocation failures leak nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseWriteRoundTrip, .{});
}

test "allocation failures in parse alone leak nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseOnly, .{});
}

fn parseOnly(alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "name: yayl\nitems:\n  - one\n  - two\n");
    defer doc.deinit();
}

fn parseWriteRoundTrip(alloc: std.mem.Allocator) !void {
    var doc = try parse(alloc, "name: yayl\nitems:\n  - one\n  - two\n");
    defer doc.deinit();
    try std.testing.expectEqualStrings("yayl", doc.pathGet(&.{"name"}).?.scalarValue().?);
    const out = try doc.write(alloc);
    defer alloc.free(out);
}

test "deep nesting and empty collections" {
    const alloc = std.testing.allocator;
    var doc = try parse(alloc, "a:\n  b:\n    c: []\n  d: {}\n");
    defer doc.deinit();
    const out = try doc.write(alloc);
    defer alloc.free(out);
    var doc2 = try parse(alloc, out);
    defer doc2.deinit();
    try std.testing.expect(doc2.pathGet(&.{ "a", "b", "c" }).?.isSequence());
    try std.testing.expect(doc2.pathGet(&.{ "a", "d" }).?.isMapping());
}
