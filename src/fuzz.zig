//! INTERNAL fuzzing harness (PLAN-12 C1).
//!
//! Not part of the supported API: `yaml.zig` imports this only from its
//! test block, so consumers never see it. Deterministic by design —
//! every failure prints the seed and iteration index, and rerunning the
//! same seed reproduces the same byte sequence exactly.
//!
//! Zig 0.16.0's std has no `std.testing.fuzz` entry point (verified
//! against the installed toolchain), so this is the documented
//! fallback from the card contract: a seeded PRNG mutating a seed
//! corpus, with the contract
//!
//!   1. `parseAll` returns a parsed document list or a typed error —
//!      never a crash, hang, or leak (the leak-checking test allocator
//!      is the judge of the last one).
//!   2. For inputs that parse, `write` must not crash, and
//!      `parse(write(docs))` must parse again; writing the re-parse is
//!      a fixpoint (`write` is idempotent past one parse).
//!   3. Errors come from the declared vocabulary, not arbitrary
//!      `anyerror`s smuggled out of the scanner.

const std = @import("std");
const yaml = @import("yaml.zig");

/// Compact seeds covering the shapes that historically break parsers:
/// block/flow nesting, quoting, anchors, comments, block scalars,
/// CRLF, BOM, duplicate keys, explicit keys, and multi-document
/// streams. Embedded so the smoke run needs no filesystem and runs
/// identically on every platform.
const seed_corpus = [_][]const u8{
    "a: 1\nb:\n  - x\n  - y: z\n",
    "---\nfirst: doc\n---\nsecond: doc\n",
    "# head\nkey: value # tail\n\n# detached\nother: 2\n",
    "quoted: \"with: colon\"\nsingle: 'it''s'\nblock: |\n  line one\n  line two\nfolded: >\n  para\n",
    "- &v 42\n- *v\nanchors: [&a [1, 2], *a]\n",
    "flow: [1, 2, {x: y}, [deep, {er: 1}]]\nempty: {}\nempty2: []\n",
    "? complex\n: value\n? [multi, key]\n: other\n",
    "%YAML 1.2\n---\ntagged: !!int 42\nlocal: !x y\n...\n",
    "a: 1\r\nb: 2\r\n",
    "\xEF\xBB\xBF# bom comment\nkey: value\n",
    "dup: 1\ndup: 2\nnull: ~\nempty:\n",
    "deep:\n  a:\n    b: [1, [2, [3]]]\n",
    "- \n- \n-\n",
    "tab\tseparated: value\nafter: 1\n",
    "lit: |2\n   indented\nfold: >-\n  stripped\n",
    "k: value\n" ** 4,
};

/// Mutations aimed at parser stress: byte flips (including structural
/// bytes), insertions, deletions, truncations, and chunk duplication.
fn mutate(random: std.Random, input: []const u8, buf: []u8) []const u8 {
    const structural = [_]u8{ ':', '-', '#', '[', ']', '{', '}', ',', '\'', '"', '|', '>', '&', '*', '!', '%', '@', '`', '?', '\n', ' ', '\t', '\r', 0 };
    if (input.len >= buf.len) return input;
    @memcpy(buf[0..input.len], input);
    var out: []const u8 = buf[0..input.len];
    const rounds = 1 + random.uintLessThan(usize, 4);
    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        if (out.len == 0) break;
        switch (random.uintLessThan(usize, 5)) {
            0 => {
                // Byte flip: ASCII keeps UTF-8 validity; arbitrary bytes
                // exercise the UTF-8 rejection paths too.
                const pos = random.uintLessThan(usize, out.len);
                if (random.boolean()) {
                    buf[pos] &= 0x7F;
                } else {
                    buf[pos] = random.int(u8);
                }
            },
            1 => {
                // Insert a structural byte.
                if (out.len + 1 > buf.len) break;
                const pos = random.uintLessThan(usize, out.len + 1);
                std.mem.copyBackwards(u8, buf[pos + 1 .. out.len + 1], buf[pos..out.len]);
                buf[pos] = structural[random.uintLessThan(usize, structural.len)];
                out = buf[0 .. out.len + 1];
            },
            2 => {
                // Delete a byte.
                const pos = random.uintLessThan(usize, out.len);
                std.mem.copyForwards(u8, buf[pos .. out.len - 1], buf[pos + 1 .. out.len]);
                out = buf[0 .. out.len - 1];
            },
            3 => {
                // Truncate.
                const pos = random.uintLessThan(usize, out.len);
                out = buf[0..pos];
            },
            else => {
                // Duplicate a chunk.
                if (out.len == 0) break;
                const start = random.uintLessThan(usize, out.len);
                const end = start + random.uintLessThan(usize, out.len - start + 1);
                const chunk = out[start..end];
                if (out.len + chunk.len > buf.len) break;
                @memcpy(buf[out.len .. out.len + chunk.len], chunk);
                out = buf[0 .. out.len + chunk.len];
            },
        }
    }
    return out;
}

/// The contract every mutated input must satisfy. Returns an error
/// naming the violated clause; the caller prints seed and iteration.
fn fuzzOnce(allocator: std.mem.Allocator, input: []const u8) !void {
    var docs = yaml.parseAll(allocator, input) catch |err| {
        try expectTypedError(err);
        return; // typed rejection is a fine outcome
    };
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(allocator);
    }

    // Parsed: emission must hold, and the second round is a fixpoint.
    const first = try writeAllDocs(allocator, docs.items);
    defer allocator.free(first);

    var again = try yaml.parseAll(allocator, first);
    defer {
        for (again.items) |*d| d.deinit();
        again.deinit(allocator);
    }
    const second = try writeAllDocs(allocator, again.items);
    defer allocator.free(second);
    if (!std.mem.eql(u8, first, second)) return error.FuzzNotIdempotent;

    // The streaming event API must drain arbitrary bytes without
    // crashing (hangs surface as the test runner's timeout).
    var p = try yaml.Parser.initOpts(allocator, null, input, .{});
    defer p.deinit();
    while (try p.nextEvent()) |_| {}

    // The consuming surfaces. Until 0.15.0 this harness drove parse and
    // emit only, so every defect in value, schema and edit was outside
    // what it could reach — including a parsed alias cycle that aborted
    // the process from eight bytes of input. Same contract as above: a
    // result or a typed error, never a crash, hang or leak.
    for (docs.items) |*doc| {
        const root = doc.root orelse continue;
        try fuzzValue(allocator, root);
        try fuzzSchema(allocator, root);
        try fuzzEdit(allocator, doc);
    }

    // Path addressing and the edit algebra, checked against the tree
    // they were derived from. Unlike the fixed paths above these are
    // oracles rather than smoke tests: a path built by walking the
    // document MUST resolve back, so a failure is a real addressing
    // defect and not a miss.
    //
    // Bounded to small inputs. Each re-parses and deep-clones the tree
    // several times (an edit clones the whole root), and the corpus
    // seeds run to 64 KiB, which put one iteration into the hundreds of
    // milliseconds. Every defect these have found lived in a document
    // under a hundred bytes; the large seeds still get the parse, emit,
    // value and schema coverage above.
    if (docs.items.len > 0 and input.len <= 2048) try fuzzPaths(allocator, input);
}

/// One derived path and the node it was built for.
const PathHit = struct { path: []u8, node: *yaml.Node };

/// Append an addressable path for every reachable node, depth- and
/// count-bounded. Aliases are recorded but never descended into, so a
/// parsed alias cycle cannot make this loop.
fn collectPaths(
    allocator: std.mem.Allocator,
    node: *yaml.Node,
    prefix: []const u8,
    out: *std.ArrayList(PathHit),
    depth: usize,
) !void {
    if (depth > 5 or out.items.len >= 48) return;
    switch (node.data) {
        .mapping => |m| {
            for (m.pairs.items) |pair| {
                const key = pair.key.scalarValue() orelse continue;
                // A duplicated key is not uniquely addressable: YAML
                // permits duplicates, this library keeps them, and
                // `lookup` returns the first by documented design. So
                // the second one has no path of its own — skip it
                // rather than assert a resolution that cannot hold.
                var seen: usize = 0;
                for (m.pairs.items) |other| {
                    const ok = other.key.scalarValue() orelse continue;
                    if (std.mem.eql(u8, ok, key)) seen += 1;
                }
                if (seen != 1) continue;
                const seg = segmentFor(allocator, key) catch continue orelse continue;
                defer allocator.free(seg);
                const path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, seg });
                try out.append(allocator, .{ .path = path, .node = pair.value });
                try collectPaths(allocator, pair.value, path, out, depth + 1);
            }
        },
        .sequence => |sq| {
            for (sq.items.items, 0..) |item, i| {
                const path = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ prefix, i });
                try out.append(allocator, .{ .path = path, .node = item });
                try collectPaths(allocator, item, path, out, depth + 1);
            }
        },
        else => {},
    }
}

/// The path segment addressing `key`, or null when the grammar cannot
/// express it. The dotted form splits on `.` and `[`; the quoted forms
/// have no escapes, so a key holding BOTH quote characters is
/// unaddressable — documented in `Path.parse`, and not a defect.
fn segmentFor(allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    const dotted = std.mem.indexOfAny(u8, key, ".[") == null;
    if (dotted and key.len > 0) return try std.fmt.allocPrint(allocator, ".{s}", .{key});
    const has_dq = std.mem.indexOfScalar(u8, key, '"') != null;
    const has_sq = std.mem.indexOfScalar(u8, key, '\'') != null;
    if (has_dq and has_sq) return null;
    if (has_dq) return try std.fmt.allocPrint(allocator, "['{s}']", .{key});
    return try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{key});
}

/// Two oracles over the edit surface.
///
///   1. A path derived by walking the document resolves to the node it
///      was derived FOR. Pointer equality, so an addressing bug cannot
///      hide behind a coincidental match.
///   2. Setting a scalar to the value it already has re-emits the
///      document byte for byte. The preservation sweep asserts this
///      over 13 fixtures; here it runs over every mutated corpus input
///      the fuzzer produces.
fn fuzzPaths(allocator: std.mem.Allocator, input: []const u8) !void {
    var doc = yaml.parse(allocator, input) catch return;
    defer doc.deinit();
    const root = doc.root orelse return;

    var hits: std.ArrayList(PathHit) = .empty;
    defer {
        for (hits.items) |h| allocator.free(h.path);
        hits.deinit(allocator);
    }
    collectPaths(allocator, root, "$", &hits, 0) catch |err| {
        try expectTypedError(err);
        return;
    };

    const before = doc.write(allocator) catch |err| {
        try expectTypedError(err);
        return;
    };
    defer allocator.free(before);

    var ed = yaml.edit.Editor.init(&doc);
    for (hits.items) |h| {
        const got = ed.one(h.path) catch |err| {
            // A derived path must resolve. Anything else is a defect in
            // the path grammar or in resolution, not a fuzz miss.
            std.debug.print("fuzz: derived path {s} failed to resolve: {s}\n", .{ h.path, @errorName(err) });
            return error.FuzzPathUnresolvable;
        };
        if (got != h.node) {
            std.debug.print("fuzz: derived path {s} resolved to the wrong node\n", .{h.path});
            return error.FuzzPathWrongNode;
        }
    }

    // Set-to-same on the first addressable scalar: byte-identical.
    //
    // Same exclusions the preservation sweep documents, for the same
    // reasons — these are normalizations, not defects:
    //   - a node carrying an anchor or tag has a property preamble that
    //     a bare replacement cannot reproduce, so replacing it drops
    //     those bytes legitimately (`a: !1` -> `a:`)
    //   - a multi-line value reflows when replaced
    for (hits.items) |h| {
        const text = switch (h.node.data) {
            .scalar => |sc| sc.value,
            else => continue,
        };
        if (h.node.anchor != null or h.node.tag != null) continue;
        if (std.mem.indexOfAny(u8, text, "\n\r") != null) continue;
        const style = h.node.data.scalar.style;
        const same = doc.createScalar(text, style) catch |err| {
            try expectTypedError(err);
            return;
        };
        ed.set(h.path, same) catch |err| {
            try expectTypedError(err);
            return;
        };
        const after = doc.write(allocator) catch |err| {
            try expectTypedError(err);
            return;
        };
        defer allocator.free(after);
        if (!std.mem.eql(u8, before, after)) {
            std.debug.print("fuzz: set-to-same changed bytes at {s}\n  anchor={?s} tag={?s} style={s}\n  input ={any}\n  before={any}\n  after ={any}\n", .{
                h.path, h.node.anchor, h.node.tag, @tagName(style), input, before, after,
            });
            return error.FuzzSetSameNotIdentical;
        }
        break;
    }

    try editedIsFixpoint(allocator, input);
    try editsCommute(allocator, input);
}

/// Two edits at INDEPENDENT positions must produce the same bytes in
/// either order.
///
/// Independent means neither path is a prefix of the other — setting an
/// ancestor legitimately replaces the subtree a descendant lives in, so
/// order matters there and the property does not apply. For genuine
/// siblings it does: the emitter walks entries in source order, and if
/// applying `a` then `b` differs from `b` then `a`, one of them left the
/// other's spans or tombstones in a state that depends on when it ran.
fn editsCommute(allocator: std.mem.Allocator, input: []const u8) !void {
    var probe = yaml.parse(allocator, input) catch return;
    defer probe.deinit();
    const proot = probe.root orelse return;

    var hits: std.ArrayList(PathHit) = .empty;
    defer {
        for (hits.items) |h| allocator.free(h.path);
        hits.deinit(allocator);
    }
    collectPaths(allocator, proot, "$", &hits, 0) catch return;
    if (hits.items.len < 2) return;

    // First independent pair.
    var pa: ?[]const u8 = null;
    var pb: ?[]const u8 = null;
    outer: for (hits.items) |x| {
        for (hits.items) |y| {
            if (std.mem.eql(u8, x.path, y.path)) continue;
            if (std.mem.startsWith(u8, y.path, x.path)) continue;
            if (std.mem.startsWith(u8, x.path, y.path)) continue;
            pa = x.path;
            pb = y.path;
            break :outer;
        }
    }
    const a_path = pa orelse return;
    const b_path = pb orelse return;

    // The value travels with the PATH, not with the position in the
    // sequence — otherwise this compares two different edits and always
    // "fails".
    const first = applyBoth(allocator, input, .{ a_path, "fzA" }, .{ b_path, "fzB" }) catch |err| {
        try expectTypedError(err);
        return;
    } orelse return;
    defer allocator.free(first);
    const second = applyBoth(allocator, input, .{ b_path, "fzB" }, .{ a_path, "fzA" }) catch |err| {
        try expectTypedError(err);
        return;
    } orelse return;
    defer allocator.free(second);

    if (!std.mem.eql(u8, first, second)) {
        std.debug.print("fuzz: edits do not commute\n  input={any}\n  a={s} b={s}\n  ab={any}\n  ba={any}\n", .{ input, a_path, b_path, first, second });
        return error.FuzzEditsDoNotCommute;
    }
}

/// Set `p1` then `p2` to fixed scalars and return the emitted bytes, or
/// null when either edit is refused (the shapes differ per input; a
/// typed refusal is a fine outcome and simply makes the pair unusable).
fn applyBoth(
    allocator: std.mem.Allocator,
    input: []const u8,
    e1: struct { []const u8, []const u8 },
    e2: struct { []const u8, []const u8 },
) !?[]u8 {
    var doc = yaml.parse(allocator, input) catch return null;
    defer doc.deinit();
    var ed = yaml.edit.Editor.init(&doc);
    const v1 = try doc.createScalar(e1[1], .plain);
    ed.set(e1[0], v1) catch return null;
    const v2 = try doc.createScalar(e2[1], .plain);
    ed.set(e2[0], v2) catch return null;
    return try doc.write(allocator);
}

/// Emission must still be a fixpoint AFTER an edit.
///
/// `fuzzOnce` asserts write/reparse/write stability for documents that
/// were never touched, but a modified document travels a different path
/// through the emitter: spans are stale, tombstones are live, and
/// modified subtrees re-emit normalized in place. The two unbounded
/// growth bugs this release fixed were violations of exactly this
/// property on the *unedited* path — nothing was checking the edited
/// one.
fn editedIsFixpoint(allocator: std.mem.Allocator, input: []const u8) !void {
    var doc = yaml.parse(allocator, input) catch return;
    defer doc.deinit();
    const root = doc.root orelse return;

    var hits: std.ArrayList(PathHit) = .empty;
    defer {
        for (hits.items) |h| allocator.free(h.path);
        hits.deinit(allocator);
    }
    collectPaths(allocator, root, "$", &hits, 0) catch return;
    if (hits.items.len == 0) return;

    var ed = yaml.edit.Editor.init(&doc);
    // A delete is the sharpest edit for this: it leaves a tombstone the
    // verbatim walk has to skip, which is where span arithmetic bites.
    ed.delete(hits.items[0].path) catch |err| {
        try expectTypedError(err);
        return;
    };

    const w1 = doc.write(allocator) catch |err| {
        try expectTypedError(err);
        return;
    };
    defer allocator.free(w1);

    var re = yaml.parse(allocator, w1) catch |err| {
        // An edit must not produce bytes this library cannot read back.
        std.debug.print("fuzz: edited output does not reparse: {s}\n  input={any}\n  out  ={any}\n", .{ @errorName(err), input, w1 });
        return error.FuzzEditedOutputUnparsable;
    };
    defer re.deinit();

    const w2 = re.write(allocator) catch |err| {
        try expectTypedError(err);
        return;
    };
    defer allocator.free(w2);

    if (!std.mem.eql(u8, w1, w2)) {
        std.debug.print("fuzz: edited output is not a fixpoint\n  input={any}\n  w1   ={any}\n  w2   ={any}\n", .{ input, w1, w2 });
        return error.FuzzEditedNotIdempotent;
    }
}

/// Conversion, and the Value round trip back into a node.
fn fuzzValue(allocator: std.mem.Allocator, root: *yaml.Node) !void {
    // Tight bounds on purpose. The default 1,048,576 lets an alias
    // bomb — which mutation produces readily from the anchored seeds —
    // expand for seconds before erroring, and the fuzzer is looking for
    // crashes and leaks, not for the budget's exact value. The bound
    // itself has its own unit tests.
    const v = yaml.value.nodeToValueLimited(allocator, root, .{ .max_values = 4096 }) catch |err| {
        try expectTypedError(err);
        return;
    };
    defer yaml.value.freeValue(allocator, v);

    // Value -> Node -> bytes. The rebuilt tree is normalized, not
    // faithful, so nothing is compared against the input; the contract
    // is that it neither crashes nor leaks.
    var out = yaml.Document.init(allocator);
    defer out.deinit();
    const node = yaml.value.toNode(&out, v) catch |err| {
        try expectTypedError(err);
        return;
    };
    out.root = node;
    const text = out.write(allocator) catch |err| {
        try expectTypedError(err);
        return;
    };
    allocator.free(text);
}

/// Validation against schemas shaped to exercise the scalar arms, the
/// recursive descent, and composition.
fn fuzzSchema(allocator: std.mem.Allocator, root: *yaml.Node) !void {
    // Self-referential: descends once per document level, so a deep or
    // cyclic document drives `checkSchema` as far as it can go.
    var deep: yaml.schema.Schema = undefined;
    deep = yaml.schema.Schema.seq(&deep);

    const nullable_any = yaml.schema.Schema{ .kind = .{ .nullable = &yaml.schema.Schema.any } };
    const branches = [_]*const yaml.schema.Schema{
        &yaml.schema.Schema.str,
        &yaml.schema.Schema.int,
    };
    const one_of = yaml.schema.Schema{ .kind = .{ .one_of = &branches } };

    const schemas = [_]*const yaml.schema.Schema{
        &yaml.schema.Schema.any,   &yaml.schema.Schema.str,
        &yaml.schema.Schema.int,   &yaml.schema.Schema.boolean,
        &yaml.schema.Schema.float, &yaml.schema.Schema.scalar,
        &deep,                     &nullable_any,
        &one_of,
    };
    for (schemas) |sch| {
        const violations = sch.validateLimited(allocator, root, "$", .{ .max_nodes = 4096 }) catch |err| {
            try expectTypedError(err);
            continue;
        };
        for (violations) |*viol| viol.deinitSelf(allocator);
        allocator.free(violations);
    }
}

/// Path resolution and a mutating batch. `..` descent resolves aliases,
/// which is where a cyclic document bites.
fn fuzzEdit(allocator: std.mem.Allocator, doc: *yaml.Document) !void {
    const paths = [_][]const u8{
        "$..a", "$..k",   "$..key", "$..x",
        "$.a",  "$.a[0]", "$[0]",   "$",
    };

    var ed = yaml.edit.Editor.init(doc);
    for (paths) |path| {
        const hits = ed.all(path) catch |err| {
            try expectTypedError(err);
            continue;
        };
        allocator.free(hits);
    }
    for (paths) |path| {
        _ = ed.one(path) catch |err| {
            try expectTypedError(err);
        };
    }

    // A mutating batch, then prove the document still round-trips.
    // `apply` clones the root, so a deep or cyclic tree drives the
    // clone walk too.
    const scalar = doc.createScalar("fuzz", .plain) catch |err| {
        try expectTypedError(err);
        return;
    };
    // `set` routes through `apply`, which deep-clones the root, so a
    // deep or cyclic tree drives the clone walk as well as the edit.
    ed.set("$.fuzzed", scalar) catch |err| {
        try expectTypedError(err);
        return;
    };

    // A multi-edit batch: applied atomically, rolled back as a unit if
    // any one of them fails.
    const extra = doc.createScalar("batch", .plain) catch |err| {
        try expectTypedError(err);
        return;
    };
    ed.apply(&.{
        .{ .set = .{ .path = "$.batched", .value = extra } },
        .{ .delete = "$.fuzzed" },
    }) catch |err| {
        try expectTypedError(err);
    };

    const text = doc.write(allocator) catch |err| {
        try expectTypedError(err);
        return;
    };
    defer allocator.free(text);
    var reparsed = yaml.parse(allocator, text) catch |err| {
        try expectTypedError(err);
        return;
    };
    reparsed.deinit();
}

fn writeAllDocs(allocator: std.mem.Allocator, docs: []const yaml.Document) ![]u8 {
    return yaml.writeAll(allocator, docs) catch |err| {
        try expectTypedError(err);
        return err;
    };
}

/// The declared error vocabulary plus OOM. Anything else escaping the
/// scanner/parser/emitter is a bug dressed up as an error.
fn expectTypedError(err: anyerror) !void {
    const known = [_][]const u8{
        // parse / emit
        "InvalidSyntax",      "InvalidUtf8",
        "InvalidEscape",      "InvalidIndentation",
        "UnknownAlias",       "UnsupportedVersion",
        "Unterminated",       "NestingTooDeep",
        "InputTooLarge",      "AliasCycle",
        "InvalidCodepoint",   "OutOfMemory",
        // value / schema
        "TypeMismatch",       "UnsupportedType",
        "LimitExceeded",
        // edit
             "InvalidPath",
        "UnknownPath",        "NotACollection",
        "NotASequence",       "NotAMapping",
        "AmbiguousOperation", "MoveIntoSubtree",
        "WouldCycle",         "AnchorReferenced",
    };
    const name = @errorName(err);
    for (known) |k| {
        if (std.mem.eql(u8, k, name)) return;
    }
    std.debug.print("fuzz: untyped error escaped: {s}\n", .{name});
    return error.FuzzUntypedError;
}

/// Bounded smoke run for `zig build test`: fixed seed, embedded corpus,
/// small inputs. A few seconds at most, on every platform, no
/// filesystem.
pub fn runSmoke(allocator: std.mem.Allocator) !void {
    var prng = std.Random.DefaultPrng.init(0xF022); // fixed: deterministic
    const random = prng.random();
    var buf: [1024]u8 = undefined;
    var iteration: usize = 0;
    // Fewer iterations than the 1200 this ran when it only drove parse
    // and emit: each one now also converts, validates against nine
    // schemas, resolves every derived path, edits, and checks the
    // edited output reparses, is a fixpoint, and commutes. The work per
    // iteration is an order of magnitude up, so the count comes down to
    // keep `zig build test` quick — the long run (`zig build fuzz`) is
    // where volume belongs.
    while (iteration < 400) : (iteration += 1) {
        const seed = seed_corpus[random.uintLessThan(usize, seed_corpus.len)];
        const input = mutate(random, seed, &buf);
        fuzzOnce(allocator, input) catch |err| {
            std.debug.print("fuzz smoke failure: seed 0xF022 iteration {d}, input:\n---\n{any}\n---\n", .{ iteration, input });
            return err;
        };
    }
}

/// Long-run harness for `zig build fuzz` (manual, not a gate): takes a
/// seed and an iteration count, and may load the real corpora as extra
/// seeds when they are vendored. Prints its parameters up front so any
/// failure is reproducible as "same command, same place".
pub fn runLong(allocator: std.mem.Allocator, io: std.Io, seed: u64, iterations: usize) !void {
    // Every entry is owned (the embedded literals are duped too), so
    // one cleanup frees them all.
    var seeds: std.ArrayList([]const u8) = .empty;
    defer {
        for (seeds.items) |s| allocator.free(s);
        seeds.deinit(allocator);
    }
    for (seed_corpus) |literal| {
        try seeds.append(allocator, try allocator.dupe(u8, literal));
    }

    // Extra seeds when vendored: fixtures (committed) and corpus inputs
    // (gitignored; present locally and in CI after the fetch step).
    appendDirSeeds(allocator, io, "tests/fixtures", &seeds) catch {};
    var corpus_dir = std.Io.Dir.cwd().openDir(io, "vendor/yaml-test-suite/src", .{ .iterate = true }) catch null;
    if (corpus_dir) |*d| {
        defer d.close(io);
        // Two layouts, because the vendored tree has had both: a flat
        // `<case>.yaml` per case (what `scripts/fetch-corpus.sh`
        // produces today) and the upstream `<case>/in.yaml` directory.
        // Accepting only the directory form silently skipped all 351
        // files, so the long run advertised corpus seeds and never
        // actually loaded one.
        var dit = d.iterate();
        while (try dit.next(io)) |case| {
            var pbuf: [256]u8 = undefined;
            const path = switch (case.kind) {
                .directory => std.fmt.bufPrint(&pbuf, "vendor/yaml-test-suite/src/{s}/in.yaml", .{case.name}) catch continue,
                .file => blk: {
                    if (!std.mem.endsWith(u8, case.name, ".yaml")) continue;
                    break :blk std.fmt.bufPrint(&pbuf, "vendor/yaml-test-suite/src/{s}", .{case.name}) catch continue;
                },
                else => continue,
            };
            const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 << 10)) catch continue;
            try seeds.append(allocator, data);
            if (seeds.items.len >= 700) break;
        }
    }

    // Seed TRANSFORMS, not mutations. Byte flips almost never produce a
    // document that is CONSISTENTLY terminated one way, but that global
    // shape is exactly what the line-handling code branches on: the
    // emitter's terminator convention only matters when a whole
    // document uses it. A wholly CR-terminated stream hit three
    // `\n`-only sites at once and grew without bound; mutation found it
    // only by luck, at iteration 224765. Re-running every seed with its
    // line endings rewritten reaches that class on purpose.
    const base_count = seeds.items.len;
    for (0..base_count) |i| {
        const original = seeds.items[i];
        for ([_][]const u8{ "\r", "\r\n" }) |eol| {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            for (original) |c| {
                if (c == '\n') try out.appendSlice(allocator, eol) else try out.append(allocator, c);
            }
            try seeds.append(allocator, try out.toOwnedSlice(allocator));
        }
    }

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var buf: [4096]u8 = undefined;
    var iteration: usize = 0;
    std.debug.print("fuzz: seed {d}, iterations {d}, seeds {d} ({d} base + CR/CRLF transforms)\n", .{ seed, iterations, seeds.items.len, base_count });
    while (iteration < iterations) : (iteration += 1) {
        const base = seeds.items[random.uintLessThan(usize, seeds.items.len)];
        const input = mutate(random, base, &buf);
        fuzzOnce(allocator, input) catch |err| {
            std.debug.print("fuzz failure: seed {d} iteration {d}, input:\n---\n{any}\n---\n", .{ seed, iteration, input });
            return err;
        };
    }
    std.debug.print("fuzz: {d} iterations clean\n", .{iterations});
}

fn appendDirSeeds(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, seeds: *std.ArrayList([]const u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var dit = dir.iterate();
    while (try dit.next(io)) |entry| {
        if (entry.kind != .file) continue;
        var pbuf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 << 10));
        try seeds.append(allocator, data);
    }
}

test {
    _ = yaml;
}

/// Executable entry for `zig build fuzz` (this file is the exe root).
/// The library's own tests pull this module in via their test block, so
/// the same code is smoke-run there.
pub fn main(init: std.process.Init) !void {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next(); // program name

    var seed: u64 = 0xC0FFEE;
    var iterations: usize = 50_000;
    var seen_args: usize = 0;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--")) continue;
        const n = std.fmt.parseInt(u64, arg, 10) catch {
            std.debug.print("usage: fuzz [seed] [iterations]\n", .{});
            return error.InvalidArguments;
        };
        seen_args += 1;
        if (seen_args == 1) {
            seed = n;
        } else {
            iterations = @intCast(n);
        }
    }
    try runLong(init.gpa, init.io, seed, iterations);
}
