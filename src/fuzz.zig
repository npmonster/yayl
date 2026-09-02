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
        "InvalidSyntax",    "InvalidUtf8",
        "InvalidEscape",    "InvalidIndentation",
        "UnknownAlias",     "UnsupportedVersion",
        "Unterminated",     "NestingTooDeep",
        "InputTooLarge",    "AliasCycle",
        "InvalidCodepoint", "OutOfMemory",
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
    while (iteration < 1200) : (iteration += 1) {
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
        var dit = d.iterate();
        while (try dit.next(io)) |case| {
            if (case.kind != .directory) continue;
            var pbuf: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&pbuf, "vendor/yaml-test-suite/src/{s}/in.yaml", .{case.name}) catch continue;
            const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 << 10)) catch continue;
            try seeds.append(allocator, data);
            if (seeds.items.len >= 700) break;
        }
    }

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var buf: [4096]u8 = undefined;
    var iteration: usize = 0;
    std.debug.print("fuzz: seed {d}, iterations {d}, seeds {d}\n", .{ seed, iterations, seeds.items.len });
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
