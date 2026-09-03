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
pub const markup = @import("markup.zig");
pub const token = @import("token.zig");
pub const scanner = @import("scanner.zig");
pub const event = @import("event.zig");
pub const parser = @import("parser.zig");
pub const document = @import("document.zig");
pub const emitter = @import("emitter.zig");
pub const edit = @import("edit.zig");
pub const value = @import("value.zig");
pub const schema = @import("schema.zig");
pub const file = @import("file.zig");

// Public vocabulary, flattened for convenience.
pub const Mark = diag.Mark;
pub const Diag = diag.Diag;
pub const Diagnostic = diag.Diagnostic;
pub const YamlError = diag.YamlError;
pub const ScalarStyle = token.ScalarStyle;
pub const NodeKind = document.NodeKind;
pub const CoreTag = document.CoreTag;
pub const resolveCoreTag = document.resolveCoreTag;
pub const writeAll = document.writeAll;
pub const writeAllOpts = document.writeAllOpts;
pub const EmitOptions = document.EmitOptions;
pub const ParseOptions = document.ParseOptions;
pub const EmbeddedNul = document.EmbeddedNul;
pub const Node = document.Node;
pub const Pair = document.Pair;
pub const Document = document.Document;
pub const Parser = parser.Parser;
pub const Scanner = scanner.Scanner;
pub const Token = token.Token;
pub const Event = event.Event;
pub const EventKind = event.Event.Kind;
pub const TokenKind = token.Token.Kind;

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

/// Like `parse`, additionally recording a positioned diagnostic per
/// problem in `d` (line, column, message). The error return is
/// unchanged — `d` carries the human-readable detail, e.g.:
///
/// ```zig
/// var d: yaml.Diag = .{ .allocator = allocator };
/// defer d.deinit();
/// if (yaml.parseDiag(allocator, input, &d)) |doc| {
///     var document = doc;
///     defer document.deinit();
/// } else |err| {
///     const report = try d.render(allocator); // "2:3: error: ..."
///     defer allocator.free(report);
/// }
/// ```
pub fn parseDiag(allocator: std.mem.Allocator, input: []const u8, d: *Diag) !Document {
    return Document.parseDiag(allocator, input, d);
}

/// Like `parseAll`, additionally recording positioned diagnostics in `d`.
pub fn parseAllDiag(allocator: std.mem.Allocator, input: []const u8, d: *Diag) !std.ArrayList(Document) {
    return Document.parseAllDiag(allocator, input, d);
}

/// `parse` with explicit bounds and input policy, and an optional
/// diagnostic collector. For untrusted input — the defaults are sized
/// for a trusted config file, not a hostile stream:
///
/// ```zig
/// var doc = try yaml.parseOpts(allocator, payload, null, .{
///     .max_input_bytes = 1 << 20,
///     .max_nesting = 32,
/// });
/// defer doc.deinit();
/// ```
pub fn parseOpts(
    allocator: std.mem.Allocator,
    input: []const u8,
    d: ?*Diag,
    options: ParseOptions,
) !Document {
    return Document.parseOpts(allocator, input, d, options);
}

/// `parseAll` with explicit bounds and input policy. The bounds apply
/// to the stream as a whole, not per document.
pub fn parseAllOpts(
    allocator: std.mem.Allocator,
    input: []const u8,
    d: ?*Diag,
    options: ParseOptions,
) !std.ArrayList(Document) {
    return Document.parseAllOpts(allocator, input, d, options);
}

test {
    _ = diag;
    _ = pool;
    _ = utf8;
    _ = ctype;
    _ = markup;
    _ = token;
    _ = scanner;
    _ = event;
    _ = parser;
    _ = document;
    _ = emitter;
    _ = edit;
    _ = value;
    _ = schema;
    _ = file;
    // The fuzz harness is internal (never re-exported); its tests run
    // with the suite so CI always fuzzes something.
    _ = @import("fuzz.zig");
}

test "parse and write round trip" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "name: yayl\nlang: zig\n");
    defer doc.deinit();
    try std.testing.expectEqualStrings("yayl", doc.pathGet(&.{"name"}).?.scalarValue().?);
    const out = try doc.write(allocator);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("name: yayl\nlang: zig\n", out);
}

test "build a document programmatically" {
    const allocator = std.testing.allocator;
    var doc = Document.init(allocator);
    defer doc.deinit();

    const root = try doc.createMapping();
    doc.root = root;
    const list = try doc.createSequence();
    try doc.pathSet(&.{"items"}, list);
    try doc.sequenceAppend(list, try doc.createScalar("one", .plain));
    try doc.sequenceAppend(list, try doc.createScalar("two", .plain));

    const out = try doc.write(allocator);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("items:\n  - one\n  - two\n", out);
}

test "invalid input surfaces a yaml error" {
    const allocator = std.testing.allocator;
    const r = parse(allocator, "a: b\n  c: d\n"); // bad indentation
    try std.testing.expectError(error.InvalidSyntax, r);
}

test "parseDiag surfaces positioned diagnostics" {
    const allocator = std.testing.allocator;
    var d: Diag = .{ .allocator = allocator };
    defer d.deinit();
    const r = parseDiag(allocator, "a: b\n  c: d\n", &d);
    try std.testing.expectError(error.InvalidSyntax, r);
    try std.testing.expect(d.list.items.len > 0);
    try std.testing.expect(d.list.items[0].mark.line >= 1);

    // Valid input records nothing.
    var d2: Diag = .{ .allocator = allocator };
    defer d2.deinit();
    var doc = try parseDiag(allocator, "ok: 1\n", &d2);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 0), d2.list.items.len);
}

test "multi-document stream" {
    const allocator = std.testing.allocator;
    var docs = try parseAll(allocator, "---\na: 1\n---\nb: 2\n");
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), docs.items.len);
    try std.testing.expectEqualStrings("1", docs.items[0].pathGet(&.{"a"}).?.scalarValue().?);
    try std.testing.expectEqualStrings("2", docs.items[1].pathGet(&.{"b"}).?.scalarValue().?);
}

test "realistic configuration round trip" {
    const allocator = std.testing.allocator;
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
    var doc = try parse(allocator, src);
    defer doc.deinit();
    try std.testing.expectEqualStrings("admin", doc.pathGet(&.{ "database", "credentials", "user" }).?.scalarValue().?);
    try std.testing.expectEqualStrings("db-2", doc.pathGet(&.{"replicas"}).?.items().?[1].scalarValue().?);
    const out = try doc.write(allocator);
    defer allocator.free(out);
    // Re-parse the emitted text and compare the tree semantically.
    var doc2 = try parse(allocator, out);
    defer doc2.deinit();
    try std.testing.expectEqualStrings("admin", doc2.pathGet(&.{ "database", "credentials", "user" }).?.scalarValue().?);
    try std.testing.expectEqualStrings("db-2", doc2.pathGet(&.{"replicas"}).?.items().?[1].scalarValue().?);
    try std.testing.expectEqualStrings("true", doc2.pathGet(&.{"enabled"}).?.scalarValue().?);
}

/// Total allocations one parse of `input` performs. `FailingAllocator`
/// with the default config never fails; it is used here purely as a
/// counter, and the count is exactly the number of runs
/// `checkAllAllocationFailures` will perform over the same function.
fn countParseAllocations(input: []const u8) !usize {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var doc = try parse(failing.allocator(), input);
    doc.deinit();
    return failing.allocations;
}

test "the scanner/parser sweep input is broad, and stays that way" {
    // The exact string the v0.12.0 audit called out (vast-wren,
    // suspicion 3) as missing "most of the allocating surface". Kept
    // verbatim as the baseline it is: allocation count under one parse
    // is the number of failure points `checkAllAllocationFailures`
    // injects at, so it measures the sweep's reach directly.
    const audit_baseline = "name: yayl\nitems:\n  - one\n  - two\n";

    const before = try countParseAllocations(audit_baseline);
    const after = try countParseAllocations(sweep_yaml);

    // Not a tuning knob. The margin is wide enough to survive an
    // allocator or scanner change, and tight enough that thinning
    // `sweep_yaml` back toward a flat mapping trips it.
    try std.testing.expect(before > 0);
    try std.testing.expect(after > before * 3);
}

test "allocation failures leak nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseWriteRoundTrip, .{});
}

test "allocation failures in parse alone leak nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseOnly, .{});
}

test "allocation failures in parseAll leak nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseMultiDoc, .{});
}

fn parseMultiDoc(allocator: std.mem.Allocator) !void {
    var docs = try parseAll(allocator, sweep_stream);
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), docs.items.len);
}

test "seeded fuzz: random ASCII input never panics or leaks" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed); // fixed seed: deterministic
    const random = prng.random();
    var buf: [256]u8 = undefined;
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        const len = random.uintAtMost(usize, buf.len + 1);
        random.bytes(buf[0..len]);
        // ASCII keeps the input valid UTF-8; InvalidUtf8 is covered by
        // dedicated tests.
        for (buf[0..len]) |*b| b.* &= 0x7F;
        var docs = parseAll(allocator, buf[0..len]) catch continue;
        defer {
            for (docs.items) |*d| d.deinit();
            docs.deinit(allocator);
        }
        // Emission paths (span arithmetic, quoting) get fuzzed too.
        for (docs.items) |*d| {
            const out = try d.write(allocator);
            allocator.free(out);
        }
    }
}

test "seeded fuzz: random multibyte UTF-8 input never panics or leaks" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed0002); // fixed seed: deterministic
    const random = prng.random();
    var buf: [256]u8 = undefined;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        // Valid UTF-8: printable ASCII mixed with random non-surrogate
        // codepoints, exercising the scanner's multibyte paths.
        var len: usize = 0;
        while (len < buf.len and random.boolean()) {
            if (random.boolean()) {
                buf[len] = random.intRangeAtMost(u8, 0x20, 0x7E);
                len += 1;
            } else {
                var cp = random.intRangeAtMost(u21, 0xA0, 0xFFFF);
                if (cp >= 0xD800 and cp <= 0xDFFF) cp = 0x2022;
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &tmp) catch unreachable;
                if (len + n > buf.len) break;
                @memcpy(buf[len .. len + n], tmp[0..n]);
                len += n;
            }
        }
        var docs = parseAll(allocator, buf[0..len]) catch continue;
        defer {
            for (docs.items) |*d| d.deinit();
            docs.deinit(allocator);
        }
        for (docs.items) |*d| {
            const out = try d.write(allocator);
            allocator.free(out);
        }
    }
}

test "seeded fuzz: arbitrary bytes never panic or leak" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed0003); // fixed seed: deterministic
    const random = prng.random();
    var buf: [256]u8 = undefined;
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        const len = random.uintAtMost(usize, buf.len);
        random.bytes(buf[0..len]);
        var docs = parseAll(allocator, buf[0..len]) catch continue;
        defer {
            for (docs.items) |*d| d.deinit();
            docs.deinit(allocator);
        }
        for (docs.items) |*d| {
            const out = try d.write(allocator);
            allocator.free(out);
        }
    }
}

test "property: write(parse(write(parse(x)))) is a fixpoint" {
    const allocator = std.testing.allocator;
    const samples = [_][]const u8{
        "a: 1\nb:\n  - x\n  - y: z\n",
        "top:\n  nested:\n    deep: value\n  list:\n    - 1\n    - two\n",
        "plain: text\nquoted: \"with: colon\"\nsingle: 'it''s'\n",
        "---\nfirst: doc\n---\nsecond: doc\n",
    };
    for (samples) |src| {
        var d1 = try parse(allocator, src);
        defer d1.deinit();
        const out1 = try d1.write(allocator);
        defer allocator.free(out1);
        var d2 = try parse(allocator, out1);
        defer d2.deinit();
        const out2 = try d2.write(allocator);
        defer allocator.free(out2);
        try std.testing.expectEqualStrings(out1, out2);
    }
}

test "fuzz smoke: mutated corpus never panics, leaks, or loses the round trip" {
    try @import("fuzz.zig").runSmoke(std.testing.allocator);
}

/// The input the scanner and parser allocation sweeps run on.
///
/// The v0.12.0 audit (vast-wren, suspicion 3) found these sweeps reaching
/// the scanner and parser only through
/// `"name: yayl\nitems:\n  - one\n  - two\n"`, which in its words
/// "misses most of the allocating surface": no anchors, aliases, tags,
/// flow collections or block scalars. Neither `scanner.zig` (63 allocator
/// sites) nor `parser.zig` (18) has a sweep of its own, so this input is
/// the only way those sites are reached under allocation failure.
///
/// Every construct below is deliberate and pulls its own weight; thinning
/// this silently narrows the sweep. `sweep_input_is_broad` asserts it
/// stays substantially richer than the string it replaced.
const sweep_yaml =
    \\%YAML 1.2
    \\---
    \\# a leading comment, so comment gaps are scanned
    \\anchored: &anchor [1, 2, 3]
    \\alias: *anchor
    \\flow_map: {alpha: 1, beta: [x, y]}
    \\tagged: !!str 42
    \\literal: |
    \\  first line
    \\  second line
    \\folded: >-
    \\  folded text
    \\  keeps flowing
    \\double: "quoted: value"
    \\single: 'it''s here'
    \\nested:
    \\  - key: value    # a trailing comment
    \\    inner: [{deep: 1}]
    \\  - plain
    \\
;

/// A two-document stream carrying the same breadth, for the `parseAll`
/// sweep: the stream path allocates per document as well as per node.
const sweep_stream = sweep_yaml ++
    \\---
    \\second: &s {k: v}
    \\echo: *s
    \\block: |-
    \\  tail
    \\
;

fn parseOnly(allocator: std.mem.Allocator) !void {
    var doc = try parse(allocator, sweep_yaml);
    defer doc.deinit();
}

fn parseWriteRoundTrip(allocator: std.mem.Allocator) !void {
    var doc = try parse(allocator, sweep_yaml);
    defer doc.deinit();
    // The alias node is an alias, and resolves to the anchored sequence.
    // (Asserted through `isAlias`/`items`, not `scalarValue`: that
    // resolves the alias and returns null for a collection, so an
    // `orelse` on it would assert nothing at all.)
    const alias_node = doc.pathGet(&.{"alias"}).?;
    try std.testing.expect(alias_node.isAlias());
    try std.testing.expectEqual(@as(usize, 3), alias_node.resolveAlias().items().?.len);
    const out = try doc.write(allocator);
    defer allocator.free(out);
    // Emission of every construct above, not just of a flat mapping.
    try std.testing.expectEqualStrings(sweep_yaml, out);
}

test "a lone CR ends a line, so a document region cannot swallow the next marker" {
    const allocator = std.testing.allocator;

    // Found by the extended fuzz harness (seed 987654321, iteration
    // 28041) once the corpus was actually being loaded as seeds.
    //
    // YAML 1.2 §5.4 makes a lone CR a line break (`b-break ::= CRLF |
    // CR | LF`) and the scanner agrees, so `x\r---\n` is two documents.
    // But `markup.lineEnd` scanned for `\n` only, so the first
    // document's source region ran past the CR and swallowed the
    // `---\n` that marks the second. Emission then wrote those bytes as
    // document one's content AND a fresh `---` for document two, so
    // every round trip grew the text by four bytes, forever:
    // 6 -> 10 -> 14. Byte-faithfulness and idempotence both broken.
    const inputs = [_][]const u8{
        "x\r---\n",
        "a: 1\r---\n",
        "a: |\n  x\r---\n",
    };
    for (inputs) |input| {
        var docs = try parseAll(allocator, input);
        defer {
            for (docs.items) |*d| d.deinit();
            docs.deinit(allocator);
        }
        const first = try writeAll(allocator, docs.items);
        defer allocator.free(first);

        // Byte-faithful: the round trip returns the input unchanged.
        try std.testing.expectEqualStrings(input, first);

        // And a fixpoint, which is what the growth broke.
        var again = try parseAll(allocator, first);
        defer {
            for (again.items) |*d| d.deinit();
            again.deinit(allocator);
        }
        const second = try writeAll(allocator, again.items);
        defer allocator.free(second);
        try std.testing.expectEqualStrings(first, second);
    }

    // LF and CRLF were always fine; keep them asserted alongside so the
    // three break spellings are covered in one place.
    for ([_][]const u8{ "x\n---\n", "x\r\n---\n" }) |input| {
        var docs = try parseAll(allocator, input);
        defer {
            for (docs.items) |*d| d.deinit();
            docs.deinit(allocator);
        }
        const out = try writeAll(allocator, docs.items);
        defer allocator.free(out);
        try std.testing.expectEqualStrings(input, out);
    }
}

test "document marker streams" {
    const allocator = std.testing.allocator;

    // Two explicit markers: two documents with empty content (6XDY).
    {
        var docs = try parseAll(allocator, "---\n---\n");
        defer {
            for (docs.items) |*d| d.deinit();
            docs.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 2), docs.items.len);
        try std.testing.expectEqualStrings("", docs.items[0].root.?.scalarValue().?);
        try std.testing.expectEqualStrings("", docs.items[1].root.?.scalarValue().?);
    }

    // A lone '...' produces no document at all (HWV9).
    {
        var docs = try parseAll(allocator, "...\n");
        defer {
            for (docs.items) |*d| d.deinit();
            docs.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 0), docs.items.len);
    }

    // Trailing '---' opens a second, empty document (PUW8).
    {
        var docs = try parseAll(allocator, "---\na: b\n---\n");
        defer {
            for (docs.items) |*d| d.deinit();
            docs.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 2), docs.items.len);
        try std.testing.expectEqualStrings("b", docs.items[0].pathGet(&.{"a"}).?.scalarValue().?);
        try std.testing.expectEqualStrings("", docs.items[1].root.?.scalarValue().?);
    }

    // Bare document after '...' is implicit but present (7Z25).
    {
        var docs = try parseAll(allocator, "---\nscalar1\n...\nkey: value\n");
        defer {
            for (docs.items) |*d| d.deinit();
            docs.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 2), docs.items.len);
        try std.testing.expectEqualStrings("scalar1", docs.items[0].root.?.scalarValue().?);
        try std.testing.expectEqualStrings("value", docs.items[1].pathGet(&.{"key"}).?.scalarValue().?);
    }
}

test "deep nesting and empty collections" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "a:\n  b:\n    c: []\n  d: {}\n");
    defer doc.deinit();
    const out = try doc.write(allocator);
    defer allocator.free(out);
    var doc2 = try parse(allocator, out);
    defer doc2.deinit();
    try std.testing.expect(doc2.pathGet(&.{ "a", "b", "c" }).?.isSequence());
    try std.testing.expect(doc2.pathGet(&.{ "a", "d" }).?.isMapping());
}

test "parse bounds are reachable through the public API" {
    const allocator = std.testing.allocator;

    // Input size. The default entry points had no bound at all: the
    // 64 MiB in `yaml.file` only ever covered reads from disk.
    try std.testing.expectError(
        error.InputTooLarge,
        parseOpts(allocator, "a: 1\n", null, .{ .max_input_bytes = 4 }),
    );
    {
        // Non-vacuous: the same input parses when the bound admits it.
        var doc = try parseOpts(allocator, "a: 1\n", null, .{ .max_input_bytes = 5 });
        defer doc.deinit();
        try std.testing.expectEqualStrings("1", doc.pathGet(&.{"a"}).?.scalarValue().?);
    }

    // Nesting. The 200-level default is not a knob a caller could reach
    // without hand-rolling a Scanner.
    try std.testing.expectError(
        error.NestingTooDeep,
        parseOpts(allocator, "[[[[a]]]]", null, .{ .max_nesting = 2 }),
    );
    {
        var doc = try parseOpts(allocator, "[[[[a]]]]", null, .{ .max_nesting = 8 });
        defer doc.deinit();
        try std.testing.expect(doc.root != null);
    }
}

test "an embedded NUL is rejected, and truncation is opt-in" {
    const allocator = std.testing.allocator;
    const input = "a: 1\nb: \x00 2\n";

    // Default: NUL is not a printable character in YAML 1.2, and
    // silently dropping the rest of the buffer is data loss.
    try std.testing.expectError(error.InvalidSyntax, parse(allocator, input));

    // The libyaml behaviour is still available, and still lossy --
    // everything from the NUL on is gone, which is the point of making
    // it explicit.
    var doc = try parseOpts(allocator, input, null, .{ .embedded_nul = .truncate });
    defer doc.deinit();
    try std.testing.expectEqualStrings("1", doc.pathGet(&.{"a"}).?.scalarValue().?);
    // `b`'s value was cut off mid-scalar: the key survives, its content
    // does not. That silent half-entry is exactly why `.reject` is the
    // default.
    try std.testing.expectEqualStrings("", doc.pathGet(&.{"b"}).?.scalarValue().?);
}

test "a parse diagnostic survives the options path, positioned" {
    const allocator = std.testing.allocator;
    var d: Diag = .{ .allocator = allocator };
    defer d.deinit();
    try std.testing.expectError(
        error.InvalidSyntax,
        parseOpts(allocator, "a: 1\nb: \x00 2\n", &d, .{}),
    );
    const report = try d.render(allocator);
    defer allocator.free(report);
    // `Diag.render` prints line:column and never the offset, so a mark
    // carrying only an offset renders as a confident `1:1` -- a wrong
    // position is worse than none. The NUL is on line 2, column 4.
    try std.testing.expect(std.mem.startsWith(u8, report, "2:4: error: "));
    try std.testing.expect(std.mem.indexOf(u8, report, "NUL") != null);
}

test "a UTF-16 stream is named, not reported as a stray NUL" {
    const allocator = std.testing.allocator;
    var d: Diag = .{ .allocator = allocator };
    defer d.deinit();
    // UTF-16LE "a: 1": every ASCII character carries a NUL high byte, so
    // the NUL check sees it first and would send the reader hunting for
    // a stray byte in what is simply the wrong encoding.
    const utf16 = "\xFF\xFEa\x00:\x00 \x001\x00";
    try std.testing.expectError(error.InvalidUtf8, parseDiag(allocator, utf16, &d));
    const report = try d.render(allocator);
    defer allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "UTF-16") != null);
}

test "an escaped NUL is content, not a raw NUL" {
    const allocator = std.testing.allocator;
    // `\0` inside a double-quoted scalar is legal YAML and decodes to a
    // real NUL in the *value*. Now that raw NULs in the input are
    // rejected, this is the one interaction worth a permanent witness:
    // emission must never write that byte out raw, or a document would
    // stop round-tripping through its own writer.
    var doc = try parse(allocator, "a: \"x\\0y\"\n");
    defer doc.deinit();
    const decoded = doc.pathGet(&.{"a"}).?.scalarValue().?;
    try std.testing.expectEqual(@as(usize, 3), decoded.len);
    try std.testing.expectEqual(@as(u8, 0), decoded[1]);

    const out = try doc.write(allocator);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOfScalar(u8, out, 0) == null);

    var again = try parse(allocator, out);
    defer again.deinit();
    try std.testing.expectEqualStrings(decoded, again.pathGet(&.{"a"}).?.scalarValue().?);
}

test "allocation failures in emission leak nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, emitBuilt, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, emitStream, .{});
}

/// Emission as its own allocation-failure family: a built document
/// (nested block + flow + quoted scalars) through writeOpts, and a
/// multi-document stream through writeAll.
fn emitBuilt(allocator: std.mem.Allocator) !void {
    var doc = Document.init(allocator);
    defer doc.deinit();
    const root = try doc.createMapping();
    doc.root = root;
    const inner = try doc.createMapping();
    try doc.mappingAppend(root, try doc.createScalar("outer", .plain), inner);
    try doc.mappingAppend(inner, try doc.createScalar("name", .plain), try doc.createScalar("a: b", .double_quoted));
    const seq = try doc.createSequence();
    try doc.mappingAppend(root, try doc.createScalar("list", .plain), seq);
    try doc.sequenceAppend(seq, try doc.createScalar("one", .plain));
    try doc.sequenceAppend(seq, try doc.createScalar("two", .plain));
    const out = try doc.writeOpts(allocator, .{ .indent = 3 });
    defer allocator.free(out);
}

fn emitStream(allocator: std.mem.Allocator) !void {
    var docs = try parseAll(allocator, "---\na: 1\n---\nb: 2\n");
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(allocator);
    }
    const out = try writeAll(allocator, docs.items);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("---\na: 1\n---\nb: 2\n", out);
}
