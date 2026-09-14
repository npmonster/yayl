//! Emit CLI for the emission oracle (scripts/emission-oracle.sh): parse
//! a YAML file with yayl and write the emitted bytes to a second file.
//!
//! Modes (third argument, default `faithful`):
//!   faithful — re-emit the parsed documents verbatim. This is the
//!              byte-faithful path, and every scalar carries the style
//!              the author wrote.
//!   merged   — parse with `resolve_merge_keys`, then re-emit. The
//!              resolved mappings are laid out by the emitter, so this is
//!              the only oracle mode that sees the merge path's output.
//!   dump-merged — parse with `resolve_merge_keys`, then write a
//!              CANONICAL TREE DUMP instead of YAML, for
//!              scripts/merge-differential.sh to compare against
//!              libfyaml's `FYPCF_RESOLVE_DOCUMENT` output. See
//!              `dumpCanonical` for the grammar and for what the form
//!              deliberately drops.
//!   value    — rebuild each document through `yaml.value` and emit the
//!              result. Nothing here has a source span or a parsed
//!              style, so the emitter has to CHOOSE every scalar's form
//!              (`.any`). That is a different decision procedure from
//!              the faithful path, and it was previously ungated: a
//!              string emitted bare because it looked syntactically safe
//!              (`true`, `90210`) re-parses as another type, and no
//!              gate that starts from parsed documents can see it.
//!
//! Exit statuses let the oracle classify:
//!   0 — parsed and emitted (the oracle then checks libfyaml accepts it)
//!   3 — yayl itself rejected the input (nothing to check)
//!   4 — the mode does not apply to this input (nothing emitted)

const std = @import("std");
const yaml = @import("yayl");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();
    _ = it.next(); // program name
    const in_path = it.next() orelse return error.Usage;
    const out_path = it.next() orelse return error.Usage;
    const mode = it.next() orelse "faithful";

    const input = std.Io.Dir.cwd().readFileAlloc(io, in_path, allocator, .limited(1 << 20)) catch |err| {
        if (err == error.FileNotFound) return err;
        return err;
    };

    const resolve = std.mem.eql(u8, mode, "merged") or std.mem.eql(u8, mode, "dump-merged");
    var docs = if (resolve)
        yaml.Document.parseAllOpts(allocator, input, null, .{ .resolve_merge_keys = true }) catch |err| {
            std.debug.print("emit: yayl rejected {s}: {s}\n", .{ in_path, @errorName(err) });
            std.process.exit(3);
        }
    else
        yaml.parseAll(allocator, input) catch |err| {
            std.debug.print("emit: yayl rejected {s}: {s}\n", .{ in_path, @errorName(err) });
            // An explicit status, not a returned error: Zig maps ANY error
            // from main to exit 1, which would make "yayl rejected this
            // input" indistinguishable from a genuine failure.
            std.process.exit(3);
        };
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(allocator);
    }

    const out = if (std.mem.eql(u8, mode, "dump-merged"))
        dumpCanonical(allocator, docs.items) catch |err| switch (err) {
            // A cyclic alias has no finite value form. Not a merge
            // defect: the differential simply cannot compare it.
            error.NestingTooDeep => std.process.exit(4),
            else => return err,
        }
    else if (std.mem.eql(u8, mode, "value"))
        rebuildThroughValue(allocator, docs.items) catch |err| switch (err) {
            // Not every document survives a Value round trip by design:
            // a complex key has no string form, and alias expansion is
            // bounded. Those are documented limits, not emission bugs.
            error.TypeMismatch, error.LimitExceeded, error.NestingTooDeep => std.process.exit(4),
            else => return err,
        }
    else
        try yaml.writeAll(allocator, docs.items);
    defer allocator.free(out);

    var file = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, out);
}

/// Convert every document to an untyped `Value` and build it back into
/// a fresh document, so the emitter picks each scalar's form instead of
/// replaying the author's. Returns the emitted bytes.
fn rebuildThroughValue(allocator: std.mem.Allocator, docs: []yaml.Document) ![]u8 {
    var rebuilt: std.ArrayList(yaml.Document) = .empty;
    defer {
        for (rebuilt.items) |*d| d.deinit();
        rebuilt.deinit(allocator);
    }
    for (docs) |*doc| {
        var fresh = yaml.Document.init(allocator);
        errdefer fresh.deinit();
        if (doc.root) |root| {
            const v = try yaml.value.nodeToValue(allocator, root);
            defer yaml.value.freeValue(allocator, v);
            fresh.root = try yaml.value.toNode(&fresh, v);
        }
        try rebuilt.append(allocator, fresh);
    }
    return yaml.writeAll(allocator, rebuilt.items);
}

/// Write a canonical, order-preserving dump of every resolved document,
/// in the exact form `scripts/merge-differential.sh`'s C reference emits
/// from libfyaml's `FYPCF_RESOLVE_DOCUMENT` output.
///
/// Grammar (one node per production, length-prefixed so no byte needs
/// escaping and no delimiter can be forged by content):
///
///     stream  := "D" count LF node*
///     node    := "S" len ":" bytes LF        -- scalar
///              | "[" count LF node* "]" LF   -- sequence
///              | "{" count LF (node node)* "}" LF -- mapping, key then value
///              | "N" LF                      -- absent root
///
/// What it deliberately drops, because the two libraries cannot agree on
/// it and none of it is part of a document's VALUE:
///
///   * Anchors. `fy_document_resolve` purges every anchor; yayl's merge
///     is merge-only and keeps them. Printing them would report a known,
///     intentional divergence as a value mismatch on every fixture.
///   * Aliases, which are FOLLOWED on this side. libfyaml inlines every
///     alias during resolution, so following is what makes the two
///     comparable — and it is the value either way.
///   * Tags and scalar style. A tag is a type annotation and a style is
///     presentation; the emission oracle already covers style, and the
///     conformance gate covers tag resolution.
///
/// PORT NOTE: following aliases means a cyclic anchor (`&a [*a]`, legal
/// input yayl accepts) has no finite dump. Bounded by `max_dump_depth`
/// and reported as `error.NestingTooDeep`, which the caller maps to the
/// "not comparable" exit status rather than a failure.
fn dumpCanonical(allocator: std.mem.Allocator, docs: []yaml.Document) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "D{d}\n", .{docs.len});
    for (docs) |*doc| {
        if (doc.root) |root| {
            try dumpNode(allocator, &out, root, 0);
        } else {
            try out.appendSlice(allocator, "N\n");
        }
    }
    return out.toOwnedSlice(allocator);
}

const max_dump_depth: usize = 256;

fn dumpNode(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    node: *const yaml.Node,
    depth: usize,
) !void {
    if (depth >= max_dump_depth) return error.NestingTooDeep;
    // Follow aliases: libfyaml has already inlined them by this point.
    const n = node.resolveAlias();
    switch (n.data) {
        .scalar => |s| try out.print(allocator, "S{d}:{s}\n", .{ s.value.len, s.value }),
        .sequence => |s| {
            try out.print(allocator, "[{d}\n", .{s.items.items.len});
            for (s.items.items) |item| try dumpNode(allocator, out, item, depth + 1);
            try out.appendSlice(allocator, "]\n");
        },
        .mapping => |m| {
            try out.print(allocator, "{{{d}\n", .{m.pairs.items.len});
            for (m.pairs.items) |p| {
                try dumpNode(allocator, out, p.key, depth + 1);
                try dumpNode(allocator, out, p.value, depth + 1);
            }
            try out.appendSlice(allocator, "}\n");
        },
        // resolveAlias only returns an alias node for a cycle it could
        // not resolve within its own bound; treat it as unrepresentable.
        .alias => return error.NestingTooDeep,
    }
}
