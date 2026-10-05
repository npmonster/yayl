//! Randomized edit differential -- "every edit writes the document it
//! describes".
//!
//! The preservation sweep checks one edit at a time against the lines it
//! should touch. This harness drives random sequences of them: for every
//! valid corpus case and real-world fixture, in five variants (as written,
//! CRLF, CR, a byte order mark, no final line break), up to `steps` random
//! steps through the public API -- a direct node operation (anchor, tag,
//! leading or trailing comment) or an `Editor` batch of one to three edits
//! (set, a new key, delete, append, insert, move, aliases), on a random
//! document of the stream. After every applied step:
//!
//!   - the stream writes, and parses back with the same document count;
//!   - each document reads back as the tree in memory: kinds, anchors,
//!     tags, scalar values (null spellings equal) and the Core Schema type
//!     each scalar resolves to, alias names;
//!   - the output, parsed and written again unchanged, reproduces itself.
//!
//! A batch made to fail (its last edit has a path that cannot parse) must
//! leave the output byte-identical: the undo journal's promise. A set of a
//! scalar to an identical one must change no byte. Every allocation goes
//! through a 256 MB cap, and the bytes it holds must be back at 0 when an
//! iteration ends, error paths included: a leak is a finding.
//!
//! It prints a hash of every stream written, so two builds that must write
//! the same bytes (a refactor) can be compared run for run.
//!
//! Run with: zig build randedit -- [seed] [iterations] [steps]
//! (defaults 1, 2 and 4: a smoke; the release review ran ~95,000
//! iterations a seed). Exits 1 on any finding. Needs the corpus
//! (`make corpus`).

const std = @import("std");
const yaml = @import("yayl");
const corpus = @import("corpus_common.zig");

const Document = yaml.Document;
const Node = yaml.document.Node;
const Edit = yaml.edit.Edit;
const Editor = yaml.edit.Editor;
const ScalarStyle = yaml.ScalarStyle;

/// Findings printed in full; the rest are only counted.
const print_cap: usize = 40;

/// An allocator with a hard cap that counts the bytes it holds.
const Cap = struct {
    inner: std.mem.Allocator,
    cap: usize,
    live: usize = 0,

    fn allocator(self: *Cap) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const s: *Cap = @ptrCast(@alignCast(ctx));
        if (s.live + len > s.cap) return null;
        const p = s.inner.rawAlloc(len, al, ra) orelse return null;
        s.live += len;
        return p;
    }
    fn resize(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) bool {
        const s: *Cap = @ptrCast(@alignCast(ctx));
        if (n > m.len and s.live + (n - m.len) > s.cap) return false;
        if (!s.inner.rawResize(m, al, n, ra)) return false;
        s.live = s.live - m.len + n;
        return true;
    }
    fn remap(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const s: *Cap = @ptrCast(@alignCast(ctx));
        if (n > m.len and s.live + (n - m.len) > s.cap) return null;
        const p = s.inner.rawRemap(m, al, n, ra) orelse return null;
        s.live = s.live - m.len + n;
        return p;
    }
    fn free(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, ra: usize) void {
        const s: *Cap = @ptrCast(@alignCast(ctx));
        s.inner.rawFree(m, al, ra);
        s.live -= m.len;
    }
};

// ----------------------------------------------------------------------
// The oracle: what "reads back as the tree in memory" means
// ----------------------------------------------------------------------

fn isNull(n: *const Node) bool {
    if (n.tag != null or n.data != .scalar) return false;
    const s = n.data.scalar;
    if (s.style != .plain) return false;
    for ([_][]const u8{ "", "~", "null", "Null", "NULL" }) |t| {
        if (std.mem.eql(u8, s.value, t)) return true;
    }
    return false;
}

fn sameTree(a: ?*const Node, b: ?*const Node, depth: usize) bool {
    // Alias cycles (`&a [*a]`) are infinitely deep.
    if (depth > 40) return true;
    const x = a orelse return b == null or isNull(b.?);
    const y = b orelse return isNull(x);
    if (x.kind() != y.kind()) return false;
    if ((x.anchor == null) != (y.anchor == null)) return false;
    if (x.anchor) |n| if (!std.mem.eql(u8, n, y.anchor.?)) return false;
    if ((x.tag == null) != (y.tag == null)) return false;
    if (x.tag) |t| if (!std.mem.eql(u8, t, y.tag.?)) return false;
    return switch (x.data) {
        .scalar => |s| (std.mem.eql(u8, s.value, y.data.scalar.value) or (isNull(x) and isNull(y))) and
            sameCoreType(x, y),
        .alias => |al| std.mem.eql(u8, al.name, y.data.alias.name) and sameTree(al.target, y.data.alias.target, depth + 8),
        .mapping => |m| m.pairs.items.len == y.data.mapping.pairs.items.len and for (m.pairs.items, y.data.mapping.pairs.items) |p, q| {
            if (!sameTree(p.key, q.key, depth + 1) or !sameTree(p.value, q.value, depth + 1)) break false;
        } else true,
        .sequence => |sq| sq.items.items.len == y.data.sequence.items.items.len and for (sq.items.items, y.data.sequence.items.items) |i, j| {
            if (!sameTree(i, j, depth + 1)) break false;
        } else true,
    };
}

/// The same text can be another value: `'true'` is a string, `true` a
/// bool. The type each scalar resolves to must survive the write too.
fn sameCoreType(x: *const Node, y: *const Node) bool {
    const tx = yaml.document.scalarCoreTag(x);
    const ty = yaml.document.scalarCoreTag(y);
    if (tx == null or ty == null) return tx == null and ty == null;
    return tx.? == ty.?;
}

// ----------------------------------------------------------------------
// Random material
// ----------------------------------------------------------------------

const texts = [_][]const u8{
    "",       " ",        "x",         "hello world", "a: b",        "- x",    "# c",       "&a",
    "*a",     "!t",       "'",         "\"",          "---",         "...",    "x\n",       "\n",
    "\n\nx",  "a\nb\n",   "a\n\n b",   "multi\nline", " lead",       "trail ", "tab\there", "\t",
    "0x1F",   "true",     "~",         "null",        "1e3",         "\u{85}", "\u{2028}",  "\u{FEFF}",
    "\u{E9}", "\u{4E2D}", "a\r\nb",    "key: [1, 2]", "? q",         "%TAG",   "@x",        "`x",
    "|",      ">",        "{",         "}",           "[",           "]",      ",",         ": ",
    "a #b",   "a# b",     "\\",        "\"q\"",       "'s'",         "a\x00b", "x\n\n",     "  x\n y",
    "- - x",  "? - x",    "a\n---\nb", "\n---\n",     "long " ** 30,
};
const keys = [_][]const u8{ "mv", "new", "k", "a b", "x.y", "1", "", "null", "~", "- x", "*a", "&a", "on", "y", "[z]", "q\"r", "s'r" };
const tags = [_][]const u8{ "!t", "!", "tag:yaml.org,2002:str", "tag:yaml.org,2002:int", "tag:example.com,2000:x", "!local", "tag:yaml.org,2002:map", "tag:yaml.org,2002:seq" };
const anchors = [_][]const u8{ "a", "b", "x1", "zq", "nw", "r" };
const comments = [_][]const u8{ "# c", "# a\n# b", "#", "# with # hash", "#\u{E9}" };
const trail_comments = [_][]const u8{ "# c", "#", "# with # hash", "#\u{E9}" };
const styles = [_]ScalarStyle{ .any, .plain, .single_quoted, .double_quoted, .literal, .folded };

/// A node of the document, with the path that names it.
const Info = struct { path: []const u8, node: *Node, container: bool };

const Ctx = struct {
    arena: std.mem.Allocator, // paths and descriptions, freed per iteration
    doc: *Document,
    r: std.Random,
    infos: std.ArrayList(Info) = .empty,
    anchored: std.ArrayList(*Node) = .empty,
    desc: std.ArrayList(u8) = .empty,

    fn pick(self: *Ctx, comptime T: type, items: []const T) T {
        return items[self.r.uintLessThan(usize, items.len)];
    }
    fn note(self: *Ctx, comptime fmt: []const u8, args: anytype) void {
        self.desc.print(self.arena, fmt, args) catch {};
        self.desc.append(self.arena, ';') catch {};
    }
};

fn keyPath(arena: std.mem.Allocator, base: []const u8, k: []const u8) !?[]const u8 {
    const dq = std.mem.indexOfScalar(u8, k, '"') != null;
    const sq = std.mem.indexOfScalar(u8, k, '\'') != null;
    if (dq and sq) return null;
    const quote: u8 = if (dq) '\'' else '"';
    return try std.fmt.allocPrint(arena, "{s}[{c}{s}{c}]", .{ base, quote, k, quote });
}

fn collect(cx: *Ctx, node: *Node, path: []const u8, depth: usize) !void {
    if (depth > 10 or cx.infos.items.len > 400) return;
    try cx.infos.append(cx.arena, .{ .path = path, .node = node, .container = node.data == .mapping or node.data == .sequence });
    if (node.anchor != null) try cx.anchored.append(cx.arena, node);
    switch (node.data) {
        .mapping => |m| for (m.pairs.items) |p| {
            if (p.key.data != .scalar) continue;
            const child = (try keyPath(cx.arena, path, p.key.data.scalar.value)) orelse continue;
            try collect(cx, p.value, child, depth + 1);
        },
        .sequence => |sq| for (sq.items.items, 0..) |it, i| {
            try collect(cx, it, try std.fmt.allocPrint(cx.arena, "{s}[{d}]", .{ path, i }), depth + 1);
        },
        else => {},
    }
}

fn randScalar(cx: *Ctx) !*Node {
    const n = try cx.doc.createScalar(cx.pick([]const u8, &texts), cx.pick(ScalarStyle, &styles));
    if (cx.r.uintLessThan(u8, 6) == 0) n.tag = cx.pick([]const u8, tags[0..6]);
    if (cx.r.uintLessThan(u8, 8) == 0) try cx.doc.setAnchor(n, cx.pick([]const u8, &anchors));
    return n;
}

fn randNode(cx: *Ctx, depth: usize) !*Node {
    switch (cx.r.uintLessThan(u8, 12)) {
        0, 1, 2, 3, 4 => return randScalar(cx),
        5, 6 => {
            const q = try cx.doc.createSequence();
            if (cx.r.boolean()) q.data.sequence.style = .flow;
            if (cx.r.uintLessThan(u8, 8) == 0) q.tag = "tag:yaml.org,2002:seq";
            if (depth < 2) for (0..cx.r.uintLessThan(usize, 4)) |_| try cx.doc.sequenceAppend(q, try randNode(cx, depth + 1));
            return q;
        },
        7, 8 => {
            const m = try cx.doc.createMapping();
            if (cx.r.boolean()) m.data.mapping.style = .flow;
            if (cx.r.uintLessThan(u8, 8) == 0) m.tag = "tag:yaml.org,2002:map";
            if (depth < 2) for (0..cx.r.uintLessThan(usize, 4)) |i| {
                const k = keys[(i * 5 + cx.r.uintLessThan(usize, keys.len)) % keys.len];
                try cx.doc.mappingAppend(m, try cx.doc.createScalar(k, .plain), try randNode(cx, depth + 1));
            };
            return m;
        },
        9, 10 => {
            if (cx.anchored.items.len > 0) return cx.doc.createAlias(cx.pick(*Node, cx.anchored.items));
            return randScalar(cx);
        },
        else => {
            const n = try randScalar(cx);
            try cx.doc.setAnchor(n, cx.pick([]const u8, &anchors));
            return n;
        },
    }
}

/// One random edit; null when nothing suitable was drawn.
fn randEdit(cx: *Ctx, ed: *Editor, same_mode: bool) !?Edit {
    if (cx.infos.items.len == 0) return null;
    const inf = cx.pick(Info, cx.infos.items);
    // The path must name exactly the node drawn (a duplicate key resolves
    // to its first occurrence).
    if ((ed.one(inf.path) catch return null) != inf.node) return null;
    if (same_mode) {
        // A scalar replaced by an identical one: a byte-for-byte no-op.
        if (inf.node.data != .scalar) return null;
        const sc = inf.node.data.scalar;
        const v = try cx.doc.createScalar(sc.value, sc.style);
        v.anchor = inf.node.anchor;
        v.tag = inf.node.tag;
        cx.note("set_same {s}", .{inf.path});
        return .{ .set = .{ .path = inf.path, .value = v } };
    }
    switch (cx.r.uintLessThan(u8, 7)) {
        0, 1 => {
            cx.note("set {s}", .{inf.path});
            return .{ .set = .{ .path = inf.path, .value = try randNode(cx, 0) } };
        },
        2 => {
            if (inf.node.data != .mapping) return null;
            const p = (try keyPath(cx.arena, inf.path, cx.pick([]const u8, &keys))) orelse return null;
            cx.note("set(new) {s}", .{p});
            return .{ .set = .{ .path = p, .value = try randNode(cx, 0) } };
        },
        3 => {
            if (std.mem.eql(u8, inf.path, "$")) return null;
            cx.note("delete {s}", .{inf.path});
            return .{ .delete = inf.path };
        },
        4 => {
            if (inf.node.data != .sequence) return null;
            cx.note("append {s}", .{inf.path});
            return .{ .append = .{ .sequence = inf.path, .value = try randNode(cx, 0) } };
        },
        5 => {
            if (inf.node.data != .sequence) return null;
            const items = inf.node.items().?;
            if (items.len == 0) return null;
            const pos = try std.fmt.allocPrint(cx.arena, "{s}[{d}]", .{ inf.path, cx.r.uintLessThan(usize, items.len) });
            const before = cx.r.boolean();
            cx.note("insert-{s} {s}", .{ if (before) "before" else "after", pos });
            return .{ .insert = .{ .sequence = inf.path, .position = pos, .value = try randNode(cx, 0), .before = before } };
        },
        6 => {
            if (std.mem.eql(u8, inf.path, "$")) return null;
            const dst = cx.pick(Info, cx.infos.items);
            if (!dst.container) return null;
            if ((ed.one(dst.path) catch return null) != dst.node) return null;
            const key: ?[]const u8 = if (dst.node.data == .mapping) cx.pick([]const u8, &keys) else null;
            cx.note("move {s} -> {s} key={?s}", .{ inf.path, dst.path, key });
            return .{ .move = .{ .from = inf.path, .to = dst.path, .key = key } };
        },
        else => return null,
    }
}

// ----------------------------------------------------------------------
// The run
// ----------------------------------------------------------------------

const Stats = struct {
    applied: usize = 0,
    refused: usize = 0,
    failed_batches: usize = 0,
    noops_checked: usize = 0,
    iterations: usize = 0,
    parse_skipped: usize = 0,
    printed: usize = 0,
    findings: usize = 0,
    kinds: std.StringArrayHashMapUnmanaged(usize) = .empty,
    /// Every stream written, hashed in order.
    out_hash: u64 = 0,
    out_count: usize = 0,
};

/// One run's identity, for the report.
const Where = struct { id: []const u8, variant: []const u8, seed: u64, iteration: usize, input: []const u8 };

fn report(gpa: std.mem.Allocator, st: *Stats, kind: []const u8, at: Where, ops: []const u8, out: ?[]const u8) void {
    st.findings += 1;
    const e = st.kinds.getOrPut(gpa, kind) catch return;
    if (!e.found_existing) {
        e.key_ptr.* = gpa.dupe(u8, kind) catch kind;
        e.value_ptr.* = 0;
    }
    e.value_ptr.* += 1;
    if (st.printed >= print_cap) return;
    st.printed += 1;
    std.debug.print("FAIL {s} case={s} variant={s} seed={d} iteration={d}\n   ops: {s}\n   in : {f}\n", .{
        kind, at.id, at.variant, at.seed, at.iteration, ops, std.zig.fmtString(at.input),
    });
    if (out) |o| std.debug.print("   out: {f}\n", .{std.zig.fmtString(o)});
}

const variants = [_][]const u8{ "plain", "crlf", "cr", "bom", "nofinal" };

fn makeVariant(gpa: std.mem.Allocator, which: usize, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    switch (which) {
        0 => try out.appendSlice(gpa, src),
        1, 2 => for (src) |c| {
            if (c == '\n') try out.appendSlice(gpa, if (which == 1) "\r\n" else "\r") else try out.append(gpa, c);
        },
        3 => {
            try out.appendSlice(gpa, "\u{FEFF}");
            try out.appendSlice(gpa, src);
        },
        else => try out.appendSlice(gpa, std.mem.trimEnd(u8, src, "\n")),
    }
    return out.toOwnedSlice(gpa);
}

fn runOne(gpa: std.mem.Allocator, st: *Stats, at: Where, steps: usize) !void {
    var cap: Cap = .{ .inner = std.heap.smp_allocator, .cap = 256 << 20 };
    const a = cap.allocator();
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    st.iterations += 1;
    // Every op of this iteration, for the report.
    var hist: std.ArrayList(u8) = .empty;
    // Whatever way this function returns, everything the library allocated
    // must be back. Declared before the documents, so it runs after they
    // are freed (and before the arena that holds `hist`).
    defer if (cap.live != 0) {
        var nb: [64]u8 = undefined;
        report(gpa, st, std.fmt.bufPrint(&nb, "leak-{d}-bytes", .{cap.live}) catch "leak", at, hist.items, null);
    };
    var docs = yaml.parseAll(a, at.input) catch {
        st.parse_skipped += 1;
        return;
    };
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(a);
    }
    if (docs.items.len == 0) {
        st.parse_skipped += 1;
        return;
    }
    const mix = at.seed ^ (@as(u64, at.iteration) *% 0x9E3779B97F4A7C15) ^ std.hash.Wyhash.hash(0, at.id) ^ std.hash.Wyhash.hash(1, at.variant);
    var prng = std.Random.DefaultPrng.init(mix);
    var cx: Ctx = .{ .arena = arena, .doc = &docs.items[0], .r = prng.random() };
    var prev_out = yaml.writeAll(a, docs.items) catch return; // out of memory: not what this tests
    defer a.free(prev_out);
    for (0..steps) |_| {
        // Any document of the stream, not only the first.
        cx.doc = &docs.items[cx.r.uintLessThan(usize, docs.items.len)];
        var ed = Editor.init(cx.doc);
        cx.infos.clearRetainingCapacity();
        cx.anchored.clearRetainingCapacity();
        cx.desc.clearRetainingCapacity();
        if (cx.doc.root) |root| try collect(&cx, root, "$", 0);
        var noop_expected = false;
        if (cx.r.uintLessThan(u8, 10) < 2) {
            // A direct node operation: anchor, tag, comments.
            if (cx.infos.items.len == 0) continue;
            const inf = cx.pick(Info, cx.infos.items);
            const res: anyerror!void = switch (cx.r.uintLessThan(u8, 4)) {
                0 => blk: {
                    const name: ?[]const u8 = if (cx.r.uintLessThan(u8, 4) == 0) null else cx.pick([]const u8, &anchors);
                    cx.note("anchor {s} {?s}", .{ inf.path, name });
                    break :blk cx.doc.setAnchor(inf.node, name);
                },
                1 => blk: {
                    const tag: ?[]const u8 = if (cx.r.uintLessThan(u8, 4) == 0) null else cx.pick([]const u8, &tags);
                    cx.note("tag {s} {?s}", .{ inf.path, tag });
                    break :blk cx.doc.setTag(inf.node, tag);
                },
                2 => blk: {
                    const text: ?[]const u8 = if (cx.r.uintLessThan(u8, 4) == 0) null else cx.pick([]const u8, &comments);
                    cx.note("leading {s} {?s}", .{ inf.path, text });
                    break :blk cx.doc.setLeadingComments(inf.node, text);
                },
                else => blk: {
                    const text: ?[]const u8 = if (cx.r.uintLessThan(u8, 4) == 0) null else cx.pick([]const u8, &trail_comments);
                    cx.note("trailing {s} {?s}", .{ inf.path, text });
                    break :blk cx.doc.setTrailingComment(inf.node, text);
                },
            };
            hist.appendSlice(arena, cx.desc.items) catch {};
            res catch {
                st.refused += 1;
                continue;
            };
        } else {
            // A batch of one to three edits, perhaps ending in one that
            // must fail.
            var batch: std.ArrayList(Edit) = .empty;
            const same_mode = cx.r.uintLessThan(u8, 6) == 0;
            const want = if (same_mode) 1 else 1 + cx.r.uintLessThan(usize, 3);
            var tries: usize = 0;
            while (batch.items.len < want and tries < 12) : (tries += 1) {
                if (randEdit(&cx, &ed, same_mode) catch null) |e| try batch.append(arena, e);
            }
            if (batch.items.len == 0) continue;
            const must_fail = !same_mode and cx.r.uintLessThan(u8, 5) == 0;
            noop_expected = same_mode and batch.items.len == 1;
            if (must_fail) {
                // Reached only after the edits before it were applied.
                try batch.append(arena, .{ .append = .{ .sequence = "$.[bad", .value = try cx.doc.createScalar("x", .plain) } });
                cx.note("then an edit that must fail", .{});
            }
            hist.appendSlice(arena, cx.desc.items) catch {};
            if (ed.apply(batch.items)) |_| {
                if (must_fail) return report(gpa, st, "failing-batch-succeeded", at, hist.items, null);
                st.applied += 1;
            } else |err| {
                st.refused += 1;
                if (err == error.OutOfMemory) return;
                st.failed_batches += 1;
                const after = yaml.writeAll(a, docs.items) catch |we| {
                    if (we == error.OutOfMemory) return;
                    return report(gpa, st, "write-after-failed-batch", at, hist.items, null);
                };
                defer a.free(after);
                if (!std.mem.eql(u8, after, prev_out)) return report(gpa, st, "rollback-not-byte-identical", at, hist.items, after);
                continue;
            }
        }
        const out = yaml.writeAll(a, docs.items) catch |we| {
            if (we == error.OutOfMemory) return;
            var nb: [64]u8 = undefined;
            return report(gpa, st, std.fmt.bufPrint(&nb, "write-error-{s}", .{@errorName(we)}) catch "write-error", at, hist.items, null);
        };
        defer a.free(out);
        st.out_hash = std.hash.Wyhash.hash(st.out_hash, out);
        st.out_count += 1;
        var back = yaml.parseAll(a, out) catch |pe| {
            if (pe == error.OutOfMemory) return;
            return report(gpa, st, "output-does-not-parse", at, hist.items, out);
        };
        defer {
            for (back.items) |*d| d.deinit();
            back.deinit(a);
        }
        if (back.items.len != docs.items.len) {
            return report(gpa, st, "document-count-changed", at, hist.items, out);
        } else for (docs.items, back.items) |*x, *y| {
            if (!sameTree(x.root, y.root, 0)) return report(gpa, st, "reads-back-as-another-tree", at, hist.items, out);
        }
        if (yaml.writeAll(a, back.items)) |again| {
            defer a.free(again);
            if (!std.mem.eql(u8, again, out)) return report(gpa, st, "output-not-stable-under-reparse", at, hist.items, out);
        } else |_| {}
        if (noop_expected) {
            st.noops_checked += 1;
            if (!std.mem.eql(u8, out, prev_out)) return report(gpa, st, "set-to-identical-scalar-changed-bytes", at, hist.items, out);
        }
        a.free(prev_out);
        prev_out = a.dupe(u8, out) catch return;
    }
}

fn lessThanString(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next(); // program name
    var numbers = [_]u64{ 1, 2, 4 }; // seed, iterations, steps
    var given: usize = 0;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--")) continue;
        if (given == numbers.len) return usage();
        numbers[given] = std.fmt.parseInt(u64, arg, 10) catch return usage();
        given += 1;
    }
    const seed = numbers[0];
    const iterations: usize = @intCast(numbers[1]);
    const steps: usize = @intCast(numbers[2]);

    var cases: std.ArrayList(corpus.Case) = .empty;
    defer {
        for (cases.items) |*c| corpus.freeCase(gpa, c);
        cases.deinit(gpa);
    }
    try corpus.loadCases(gpa, io, &cases);
    const Input = struct { id: []const u8, text: []const u8 };
    var inputs: std.ArrayList(Input) = .empty;
    defer inputs.deinit(gpa);
    for (cases.items) |*c| {
        if (!c.fail) try inputs.append(gpa, .{ .id = c.id, .text = c.input });
    }

    // Fixtures are part of the repository; a missing directory is a
    // checkout problem, not an empty pass.
    var names: std.ArrayList([]const u8) = .empty;
    var texts_owned: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
        for (texts_owned.items) |t| gpa.free(t);
        texts_owned.deinit(gpa);
    }
    var dir = try std.Io.Dir.cwd().openDir(io, "tests/fixtures", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml") and !std.mem.endsWith(u8, entry.name, ".yml")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThanString);
    for (names.items) |name| {
        const text = try dir.readFileAlloc(io, name, gpa, .limited(1 << 20));
        try texts_owned.append(gpa, text);
        try inputs.append(gpa, .{ .id = name, .text = text });
    }
    // Anti-vacuity: the corpus and the fixtures are pinned, so a short
    // listing is a broken checkout or loader, not a pass.
    if (inputs.items.len < 300) {
        std.debug.print("randedit: only {d} inputs (corpus missing? run `make corpus`)\n", .{inputs.items.len});
        std.process.exit(2);
    }

    var st: Stats = .{};
    defer {
        for (st.kinds.keys()) |k| gpa.free(k);
        st.kinds.deinit(gpa);
    }
    const t0 = std.Io.Timestamp.now(io, .awake).nanoseconds;
    for (inputs.items) |inp| {
        for (variants, 0..) |variant, vi| {
            const text = try makeVariant(gpa, vi, inp.text);
            defer gpa.free(text);
            for (0..iterations) |i| {
                try runOne(gpa, &st, .{ .id = inp.id, .variant = variant, .seed = seed, .iteration = i, .input = text }, steps);
            }
        }
    }
    const ms = @divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds - t0, 1_000_000);
    std.debug.print(
        \\randedit seed={d} iterations={d} steps={d}: {d} inputs x {d} variants, {d} runs ({d} variants do not parse)
        \\  {d} batches applied and verified, {d} refused, {d} failed batches checked for rollback, {d} no-op sets checked
        \\  output hash {x:0>16} over {d} written streams, {d} ms
        \\
    , .{ seed, iterations, steps, inputs.items.len, variants.len, st.iterations, st.parse_skipped, st.applied, st.refused, st.failed_batches, st.noops_checked, st.out_hash, st.out_count, ms });
    var kit = st.kinds.iterator();
    while (kit.next()) |e| std.debug.print("  FINDINGS {s}: {d}\n", .{ e.key_ptr.*, e.value_ptr.* });
    std.debug.print("  findings: {d}\n", .{st.findings});
    // A run that verified nothing proves nothing.
    if (st.applied == 0) std.process.exit(2);
    if (st.findings != 0) std.process.exit(1);
}

fn usage() noreturn {
    std.debug.print("usage: zig build randedit -- [seed] [iterations] [steps]\n", .{});
    std.process.exit(2);
}
