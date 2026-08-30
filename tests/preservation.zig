//! Edit-preservation sweep — "never touch what you shouldn't".
//!
//! The round-trip gate proves emit(parse(x)) == x. This harness proves
//! the stronger property for EDITS: for every manipulation position in
//! every real-world fixture, the emitted result differs from the input
//! by exactly the intended change and nothing else, at line granularity:
//!
//!   delete → output is the input minus one contiguous run of lines,
//!            and the run contains the deleted entry
//!   set    → output is the input with exactly one line changed (the
//!            target's line), and re-parses to the new value
//!   add    → output is the input plus inserted lines, nothing changed
//!   failed batch → output is byte-identical to the input
//!
//! Every sub-case re-parses the fixture fresh and works through the
//! public Editor API. Positions that hit documented normalizations are
//! skipped and COUNTED (printed, never silent):
//!   - removing a parent's only child empties the container, which
//!     normalizes to flow style (`key: {}` / `key: []`)
//!   - multi-line values (block scalars, nested blocks) legitimately
//!     reflow when replaced
//!   - deleting an anchor that aliases still reference would dangle
//!   - appending into a flow collection stays on one line
//!
//! Run with: zig build preservation (also part of `make verify`).

const std = @import("std");
const yaml = @import("yayl");

const fixtures_dir = "tests/fixtures";
const multidoc_fixture = "k8s-multidoc.yaml";
const sentinel = "zz-edited";
/// Flip while debugging a sweep failure: prints input/output of the
/// first non-conforming delete.
const debug_output = false;

// ----------------------------------------------------------------------
// Line-level diff helpers (tests-only, no dependencies)
// ----------------------------------------------------------------------

fn lineOf(src: []const u8, off: usize) usize {
    const end = @min(off, src.len);
    var n: usize = 0;
    for (src[0..end]) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

fn splitLines(alloc: std.mem.Allocator, s: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| try out.append(alloc, line);
    // A trailing newline produces one empty final element; drop it so
    // both sides compare on content lines only.
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0) _ = out.pop();
    return try out.toOwnedSlice(alloc);
}

/// `out` is `orig` with exactly one contiguous run of lines removed;
/// returns the removed [start, end) line range.
fn runRemoval(orig: [][]const u8, out: [][]const u8) ?struct { start: usize, end: usize } {
    if (out.len >= orig.len) return null;
    const removed = orig.len - out.len;
    var start: usize = 0;
    outer: while (start + removed <= orig.len) : (start += 1) {
        for (out, 0..) |line, k| {
            const oi = if (k < start) k else k + removed;
            if (!std.mem.eql(u8, orig[oi], line)) continue :outer;
        }
        return .{ .start = start, .end = start + removed };
    }
    return null;
}

/// Strip a block entry's framing — leading indentation and any `- `
/// indicators — leaving the entry's own text. Two lines that differ only
/// in this framing carry the same content at a different position.
fn stripFraming(line: []const u8) []const u8 {
    var s = line;
    while (true) {
        while (s.len > 0 and s[0] == ' ') s = s[1..];
        if (s.len >= 2 and s[0] == '-' and s[1] == ' ') {
            s = s[2..];
            continue;
        }
        if (std.mem.eql(u8, s, "-")) return "";
        return s;
    }
}

/// `out` is `orig` with exactly one contiguous run of lines removed, and
/// AT MOST one surviving line re-framed: deleting the first entry of a
/// mapping that is a sequence item leaves the `- ` indicator behind, and
/// the next entry moves up onto it. Any other change fails.
fn runRemovalReframed(orig: [][]const u8, out: [][]const u8) ?struct { start: usize, end: usize } {
    if (out.len >= orig.len) return null;
    const removed = orig.len - out.len;
    var start: usize = 0;
    outer: while (start + removed <= orig.len) : (start += 1) {
        var reframed: usize = 0;
        for (out, 0..) |line, k| {
            const oi = if (k < start) k else k + removed;
            if (std.mem.eql(u8, orig[oi], line)) continue;
            // The only tolerated difference is entry framing.
            if (!std.mem.eql(u8, stripFraming(orig[oi]), stripFraming(line))) continue :outer;
            reframed += 1;
            if (reframed > 1) continue :outer;
        }
        return .{ .start = start, .end = start + removed };
    }
    return null;
}

/// Index of the single line that differs between two equal-length line
/// lists, or null when zero or several differ.
fn soleChangedLine(orig: [][]const u8, out: [][]const u8) ?usize {
    if (orig.len != out.len) return null;
    var found: ?usize = null;
    for (orig, out, 0..) |a, b, i| {
        if (std.mem.eql(u8, a, b)) continue;
        if (found != null) return null;
        found = i;
    }
    return found;
}

/// `out` is `orig` with lines only inserted at one position; returns
/// the insertion offset (the dual of `runRemoval`).
fn pureInsertion(orig: [][]const u8, out: [][]const u8) ?usize {
    if (out.len <= orig.len) return null;
    const added = out.len - orig.len;
    var at: usize = 0;
    outer: while (at <= orig.len) : (at += 1) {
        for (orig, 0..) |line, k| {
            const oi = if (k < at) k else k + added;
            if (!std.mem.eql(u8, out[oi], line)) continue :outer;
        }
        return at;
    }
    return null;
}

/// Same line count, exactly one differing line; returns its index.
fn oneLineChanged(orig: [][]const u8, out: [][]const u8) ?usize {
    if (orig.len != out.len) return null;
    var diff: ?usize = null;
    for (orig, out, 0..) |a, b, i| {
        if (!std.mem.eql(u8, a, b)) {
            if (diff != null) return null;
            diff = i;
        }
    }
    return diff;
}

// ----------------------------------------------------------------------
// Target discovery: every addressable manipulation position
// ----------------------------------------------------------------------

const Comp = union(enum) { key: []const u8, index: usize };

const Target = struct {
    path: []const u8,
    /// 0-based line where the entry starts in the fixture.
    line: usize,
    /// The entry spans multiple lines (block scalar, nested block...).
    multi_line: bool,
    /// The entry is its parent's only child: removing it would empty
    /// the container, which normalizes to flow style.
    sole_child: bool,
    /// An alias node (setting it would diverge from its anchor).
    is_alias: bool,
    /// An anchored node whose anchor is referenced by an alias
    /// elsewhere (deleting it would leave the aliases dangling).
    anchored_referenced: bool,
    /// The entry's mapping key, for locating the removed lines.
    key_text: []const u8,
};

const Container = struct {
    path: []const u8,
    is_mapping: bool,
    is_flow: bool,
    non_empty: bool,
};

const Found = struct {
    targets: std.ArrayList(Target) = .empty,
    containers: std.ArrayList(Container) = .empty,
    unaddressable: usize = 0,

    fn deinit(self: *Found, alloc: std.mem.Allocator) void {
        for (self.targets.items) |t| {
            alloc.free(t.path);
            alloc.free(t.key_text);
        }
        self.targets.deinit(alloc);
        for (self.containers.items) |c| alloc.free(c.path);
        self.containers.deinit(alloc);
    }
};

fn collectReferencedAnchors(alloc: std.mem.Allocator, node: *const yaml.Node, set: *std.StringHashMap(void)) !void {
    switch (node.data) {
        .alias => |a| {
            // The same anchor may be referenced many times; the set
            // keeps one owned copy.
            if (!set.contains(a.name)) try set.put(try alloc.dupe(u8, a.name), {});
        },
        .mapping => |m| for (m.pairs.items) |p| {
            try collectReferencedAnchors(alloc, p.key, set);
            try collectReferencedAnchors(alloc, p.value, set);
        },
        .sequence => |s| for (s.items.items) |item| {
            try collectReferencedAnchors(alloc, item, set);
        },
        .scalar => {},
    }
}

fn formatPath(alloc: std.mem.Allocator, comps: []const Comp) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.append(alloc, '$');
    for (comps) |c| switch (c) {
        .key => |k| try buf.print(alloc, ".{s}", .{k}),
        .index => |ix| try buf.print(alloc, "[{d}]", .{ix}),
    };
    return try buf.toOwnedSlice(alloc);
}

/// Record a container only when the path grammar can actually address
/// it: a key carrying a dot (GitLab's `.defaults`, mkdocs'
/// `pymdownx.highlight`) formats into a path that parses as something
/// else. Counted, never silently dropped.
fn addContainer(
    alloc: std.mem.Allocator,
    ed: *yaml.edit.Editor,
    node: *yaml.Node,
    comps: []const Comp,
    found: *Found,
    c: Container,
) !void {
    if (comps.len > 0) {
        const resolved = ed.one(c.path) catch null;
        if (resolved == null or resolved.? != node) {
            alloc.free(c.path);
            found.unaddressable += 1;
            return;
        }
    }
    try found.containers.append(alloc, c);
}

fn walkTargets(
    alloc: std.mem.Allocator,
    ed: *yaml.edit.Editor,
    input: []const u8,
    referenced: *std.StringHashMap(void),
    node: *yaml.Node,
    comps: *std.ArrayList(Comp),
    found: *Found,
    depth: usize,
) !void {
    if (depth > 24) return;
    switch (node.data) {
        .mapping => |m| {
            try addContainer(alloc, ed, node, comps.items, found, .{
                .path = try formatPath(alloc, comps.items),
                .is_mapping = true,
                .is_flow = m.style == .flow,
                .non_empty = m.pairs.items.len > 0,
            });
            for (m.pairs.items) |pair| {
                const key_text = pair.key.scalarValue() orelse continue;
                try comps.append(alloc, .{ .key = key_text });
                defer _ = comps.pop();
                const path = try formatPath(alloc, comps.items);
                const resolved = ed.one(path) catch null;
                if (resolved == null or resolved.? != pair.value) {
                    // Key text the path grammar cannot address (dots,
                    // leading dots, ambiguity). Subtree counted as
                    // unaddressable; children are still validated.
                    alloc.free(path);
                    found.unaddressable += 1;
                    try walkTargets(alloc, ed, input, referenced, pair.value, comps, found, depth + 1);
                    continue;
                }
                const line = if (pair.key.src) |s| lineOf(input, s.entry_start) else 0;
                const end_line = if (pair.src_end) |e| lineOf(input, e) else line;
                try found.targets.append(alloc, .{
                    .path = path,
                    .line = line,
                    .multi_line = end_line != line,
                    .sole_child = m.pairs.items.len == 1,
                    .is_alias = pair.value.nodeType() == .alias,
                    .anchored_referenced = pair.value.anchor != null and referenced.contains(pair.value.anchor.?),
                    .key_text = try alloc.dupe(u8, key_text),
                });
                try walkTargets(alloc, ed, input, referenced, pair.value, comps, found, depth + 1);
            }
        },
        .sequence => |s| {
            try addContainer(alloc, ed, node, comps.items, found, .{
                .path = try formatPath(alloc, comps.items),
                .is_mapping = false,
                .is_flow = s.style == .flow,
                .non_empty = s.items.items.len > 0,
            });
            for (s.items.items, 0..) |item, i| {
                try comps.append(alloc, .{ .index = i });
                defer _ = comps.pop();
                const path = try formatPath(alloc, comps.items);
                const resolved = ed.one(path) catch null;
                if (resolved == null or resolved.? != item) {
                    alloc.free(path);
                    found.unaddressable += 1;
                    try walkTargets(alloc, ed, input, referenced, item, comps, found, depth + 1);
                    continue;
                }
                const line = if (item.src) |sp| lineOf(input, sp.entry_start) else 0;
                const end_line = if (item.src) |sp| lineOf(input, sp.end) else line;
                try found.targets.append(alloc, .{
                    .path = path,
                    .line = line,
                    .multi_line = end_line != line,
                    .sole_child = s.items.items.len == 1,
                    .is_alias = item.nodeType() == .alias,
                    .anchored_referenced = item.anchor != null and referenced.contains(item.anchor.?),
                    .key_text = "",
                });
                try walkTargets(alloc, ed, input, referenced, item, comps, found, depth + 1);
            }
        },
        .scalar, .alias => {},
    }
}

// ----------------------------------------------------------------------
// Failure collection
// ----------------------------------------------------------------------

const Failures = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList([]const u8) = .empty,

    fn add(self: *Failures, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        self.list.append(self.alloc, msg) catch {
            self.alloc.free(msg);
            return;
        };
    }
};

const Stats = struct {
    deletes: usize = 0,
    sets: usize = 0,
    map_adds: usize = 0,
    seq_appends: usize = 0,
    rollbacks: usize = 0,
    skipped_sole_child: usize = 0,
    skipped_dangling_anchor: usize = 0,
    skipped_multiline: usize = 0,
    skipped_alias: usize = 0,
    skipped_flow: usize = 0,
    skipped_empty: usize = 0,
    unaddressable: usize = 0,
};

// ----------------------------------------------------------------------
// The sweeps over one fixture
// ----------------------------------------------------------------------

fn sweepFixture(alloc: std.mem.Allocator, name: []const u8, input: []const u8, failures: *Failures, stats: *Stats) !void {
    // Discovery on a pristine parse. The generation document is freed
    // before sweeping; targets own their strings.
    var found: Found = .{};
    defer found.deinit(alloc);
    {
        var gen = try yaml.parse(alloc, input);
        defer gen.deinit();
        const root = gen.root orelse return;
        var referenced: std.StringHashMap(void) = .init(alloc);
        defer {
            var kit = referenced.keyIterator();
            while (kit.next()) |k| alloc.free(k.*);
            referenced.deinit();
        }
        try collectReferencedAnchors(alloc, root, &referenced);
        var ed = yaml.edit.Editor.init(&gen);
        var comps: std.ArrayList(Comp) = .empty;
        defer comps.deinit(alloc);
        try walkTargets(alloc, &ed, input, &referenced, root, &comps, &found, 0);
    }
    stats.unaddressable += found.unaddressable;

    const orig_lines = try splitLines(alloc, input);
    defer alloc.free(orig_lines);

    // DELETE sweep: input minus one contiguous run that contains the
    // deleted entry.
    for (found.targets.items) |t| {
        if (t.sole_child) {
            // Removing a parent's only child empties the container,
            // which normalizes to flow style: line-shape assertions do
            // not apply. The WEAK invariants still do — the output must
            // be valid YAML and the deleted entry must be gone. (A
            // previous regression emitted `key:\n{}` here, which does
            // not re-parse.)
            stats.skipped_sole_child += 1;
            var doc = try yaml.parse(alloc, input);
            defer doc.deinit();
            var ed = yaml.edit.Editor.init(&doc);
            ed.apply(&.{.{ .delete = t.path }}) catch |err| {
                failures.add("{s}: delete {s} failed: {s}", .{ name, t.path, @errorName(err) });
                continue;
            };
            const out = try doc.write(alloc);
            defer alloc.free(out);
            assertsReparse(alloc, name, t.path, out, failures);
            // Semantic: output value tree == input minus the entry. A
            // re-parse cannot see "valid YAML that lost an item" (e.g.
            // a sequence silently replaced by an empty mapping).
            {
                var vin_d = yaml.parse(alloc, input) catch continue;
                defer vin_d.deinit();
                var vout_d = yaml.parse(alloc, out) catch continue;
                defer vout_d.deinit();
                const vin = yaml.value.nodeToValue(alloc, vin_d.root.?) catch continue;
                defer yaml.value.freeValue(alloc, vin);
                const vout = yaml.value.nodeToValue(alloc, vout_d.root.?) catch continue;
                defer yaml.value.freeValue(alloc, vout);
                var p = yaml.edit.Path.parse(alloc, t.path) catch continue;
                defer p.deinit(alloc);
                if (!valueMinusEql(vin, vout, p.segments)) {
                    failures.add("{s}: delete {s}: output value tree is not the input minus the entry", .{ name, t.path });
                }
            }
            if (t.key_text.len > 0) {
                var re = yaml.parse(alloc, out) catch continue;
                defer re.deinit();
                var re_ed = yaml.edit.Editor.init(&re);
                if (re_ed.one(t.path)) |_| {
                    failures.add("{s}: delete {s}: path still resolves after the delete", .{ name, t.path });
                } else |_| {}
            }
            continue;
        }
        if (t.anchored_referenced) {
            stats.skipped_dangling_anchor += 1;
            continue;
        }
        stats.deletes += 1;
        var doc = try yaml.parse(alloc, input);
        defer doc.deinit();
        var ed = yaml.edit.Editor.init(&doc);
        ed.apply(&.{.{ .delete = t.path }}) catch |err| {
            failures.add("{s}: delete {s} failed: {s}", .{ name, t.path, @errorName(err) });
            continue;
        };
        const out = try doc.write(alloc);
        defer alloc.free(out);
        const out_lines = try splitLines(alloc, out);
        defer alloc.free(out_lines);
        // Whatever the shape, the result must still be YAML and must no
        // longer resolve the deleted path.
        {
            var re = yaml.parse(alloc, out) catch {
                failures.add("{s}: delete {s}: output does not re-parse", .{ name, t.path });
                continue;
            };
            defer re.deinit();
            // Only for a key-terminated path: deleting item N shifts
            // its siblings up, so `[N]` resolving again is expected.
            if (t.key_text.len > 0) {
                var re_ed = yaml.edit.Editor.init(&re);
                if (re_ed.one(t.path)) |_| {
                    failures.add("{s}: delete {s}: path still resolves after the delete", .{ name, t.path });
                    continue;
                } else |_| {}
            }
        }
        // A flow collection holds its entries on one line, so removing
        // one rewrites that line instead of dropping any.
        if (out_lines.len == orig_lines.len) {
            if (soleChangedLine(orig_lines, out_lines)) |_| {
                stats.skipped_flow += 1;
            } else {
                failures.add("{s}: delete {s}: no line removed and not a single-line rewrite", .{ name, t.path });
            }
            continue;
        }
        const removed = runRemovalReframed(orig_lines, out_lines) orelse {
            if (debug_output) {
                std.debug.print("DEBUG delete {s} on {s}\n--- input ---\n{s}\n--- output ---\n{s}\n", .{ t.path, name, input, out });
            }
            failures.add("{s}: delete {s}: output is not a single-run line removal", .{ name, t.path });
            continue;
        };
        var hit = false;
        for (orig_lines[removed.start..removed.end]) |line| {
            if (t.key_text.len > 0 and std.mem.indexOf(u8, line, t.key_text) != null) hit = true;
            if (t.key_text.len == 0) {
                var trimmed = line;
                while (trimmed.len > 0 and trimmed[0] == ' ') trimmed = trimmed[1..];
                if (std.mem.startsWith(u8, trimmed, "- ")) hit = true;
            }
        }
        if (!hit) {
            failures.add("{s}: delete {s}: removed lines {d}..{d} do not contain the entry", .{ name, t.path, removed.start, removed.end });
        }
    }

    // SET sweep: exactly the target's line changes; the output
    // re-parses with the new value at the same path.
    for (found.targets.items) |t| {
        if (t.anchored_referenced) {
            // Replacing an anchored node drops the anchor and leaves
            // every alias to it dangling — no valid edit exists, so
            // this skip must come BEFORE the multi_line branch.
            //
            // The order is semantic, not stylistic: every OTHER skip
            // category can still assert "the emitter did not produce
            // invalid YAML", but this one cannot — a dangling alias is
            // the expected outcome, not a defect. A target that is both
            // multi-line and a referenced anchor must be classified by
            // the anchor. Reordering these checks back to shape-first
            // makes this sweep fail with unparseable output and looks
            // like an emitter bug. It is not.
            stats.skipped_dangling_anchor += 1;
            continue;
        }
        if (t.multi_line) {
            // Replacing a multi-line value legitimately reflows lines,
            // so line-shape assertions do not apply. Weak invariants
            // still do: valid YAML, sentinel at the path.
            stats.skipped_multiline += 1;
            var doc = try yaml.parse(alloc, input);
            defer doc.deinit();
            var ed = yaml.edit.Editor.init(&doc);
            ed.apply(&.{.{ .set = .{ .path = t.path, .value = try doc.createScalar(sentinel, .plain) } }}) catch |err| {
                failures.add("{s}: set {s} failed: {s}", .{ name, t.path, @errorName(err) });
                continue;
            };
            const out = try doc.write(alloc);
            defer alloc.free(out);
            assertsReparse(alloc, name, t.path, out, failures);
            // Semantic: output value tree == input with exactly the
            // target set to the sentinel — nothing lost, nothing added.
            {
                var vin_d = yaml.parse(alloc, input) catch continue;
                defer vin_d.deinit();
                var vout_d = yaml.parse(alloc, out) catch continue;
                defer vout_d.deinit();
                const vin = yaml.value.nodeToValue(alloc, vin_d.root.?) catch continue;
                defer yaml.value.freeValue(alloc, vin);
                const vout = yaml.value.nodeToValue(alloc, vout_d.root.?) catch continue;
                defer yaml.value.freeValue(alloc, vout);
                var p = yaml.edit.Path.parse(alloc, t.path) catch continue;
                defer p.deinit(alloc);
                if (!valueSetEql(vin, vout, p.segments, sentinel)) {
                    failures.add("{s}: set {s}: output value tree is not the input with the target set", .{ name, t.path });
                }
            }
            var re = yaml.parse(alloc, out) catch continue;
            defer re.deinit();
            var re_ed = yaml.edit.Editor.init(&re);
            if (re_ed.one(t.path)) |got| {
                const text = got.scalarValue() orelse "";
                if (!std.mem.eql(u8, text, sentinel)) {
                    failures.add("{s}: set {s}: re-parsed value is '{s}', expected '{s}'", .{ name, t.path, text, sentinel });
                }
            } else |_| {
                failures.add("{s}: set {s}: path no longer resolves after the edit", .{ name, t.path });
            }
            continue;
        }
        if (t.is_alias) {
            stats.skipped_alias += 1;
            continue;
        }
        stats.sets += 1;
        var doc = try yaml.parse(alloc, input);
        defer doc.deinit();
        var ed = yaml.edit.Editor.init(&doc);
        ed.apply(&.{.{ .set = .{ .path = t.path, .value = try doc.createScalar(sentinel, .plain) } }}) catch |err| {
            failures.add("{s}: set {s} failed: {s}", .{ name, t.path, @errorName(err) });
            continue;
        };
        const out = try doc.write(alloc);
        defer alloc.free(out);
        const out_lines = try splitLines(alloc, out);
        defer alloc.free(out_lines);
        const idx = oneLineChanged(orig_lines, out_lines) orelse {
            failures.add("{s}: set {s}: more than one line changed", .{ name, t.path });
            continue;
        };
        if (idx != t.line) {
            failures.add("{s}: set {s}: changed line {d}, expected {d}", .{ name, t.path, idx, t.line });
            continue;
        }
        if (std.mem.indexOf(u8, out_lines[idx], sentinel) == null) {
            failures.add("{s}: set {s}: changed line does not carry the sentinel", .{ name, t.path });
            continue;
        }
        var doc2 = yaml.parse(alloc, out) catch {
            failures.add("{s}: set {s}: output does not re-parse", .{ name, t.path });
            continue;
        };
        defer doc2.deinit();
        var ed2 = yaml.edit.Editor.init(&doc2);
        const got = ed2.one(t.path) catch {
            failures.add("{s}: set {s}: path no longer resolves after the edit", .{ name, t.path });
            continue;
        };
        const text = got.scalarValue() orelse {
            failures.add("{s}: set {s}: value at path is not the sentinel scalar", .{ name, t.path });
            continue;
        };
        if (!std.mem.eql(u8, text, sentinel)) {
            failures.add("{s}: set {s}: re-parsed value is '{s}', expected '{s}'", .{ name, t.path, text, sentinel });
        }
    }

    // ADD sweeps: pure insertions only — a new key on every addressable
    // block mapping, an appended item on every block sequence.
    for (found.containers.items) |c| {
        if (!c.non_empty or c.is_flow) {
            stats.skipped_flow += @intFromBool(c.is_flow);
            stats.skipped_empty += @intFromBool(!c.non_empty);
            continue;
        }
        if (c.is_mapping) {
            stats.map_adds += 1;
            var doc = try yaml.parse(alloc, input);
            defer doc.deinit();
            var ed = yaml.edit.Editor.init(&doc);
            const new_path = try std.fmt.allocPrint(alloc, "{s}.zz_added", .{c.path});
            defer alloc.free(new_path);
            ed.apply(&.{.{ .set = .{ .path = new_path, .value = try doc.createScalar("added", .plain) } }}) catch |err| {
                failures.add("{s}: map add under {s} failed: {s}", .{ name, c.path, @errorName(err) });
                continue;
            };
            const out = try doc.write(alloc);
            defer alloc.free(out);
            const out_lines = try splitLines(alloc, out);
            defer alloc.free(out_lines);
            const at = pureInsertion(orig_lines, out_lines) orelse {
                failures.add("{s}: map add under {s}: not a pure line insertion", .{ name, c.path });
                continue;
            };
            var hit = false;
            for (out_lines[at..]) |line| {
                if (std.mem.indexOf(u8, line, "zz_added") != null) hit = true;
            }
            if (!hit) failures.add("{s}: map add under {s}: inserted lines do not carry the new key", .{ name, c.path });
        } else {
            stats.seq_appends += 1;
            var doc = try yaml.parse(alloc, input);
            defer doc.deinit();
            var ed = yaml.edit.Editor.init(&doc);
            ed.apply(&.{.{ .append = .{ .sequence = c.path, .value = try doc.createScalar("added", .plain) } }}) catch |err| {
                failures.add("{s}: seq append to {s} failed: {s}", .{ name, c.path, @errorName(err) });
                continue;
            };
            const out = try doc.write(alloc);
            defer alloc.free(out);
            const out_lines = try splitLines(alloc, out);
            defer alloc.free(out_lines);
            if (pureInsertion(orig_lines, out_lines) == null) {
                failures.add("{s}: seq append to {s}: not a pure line insertion", .{ name, c.path });
            }
        }
    }

    // ROLLBACK: a batch whose later edit fails must leave the fixture
    // byte-identical.
    {
        stats.rollbacks += 1;
        var doc = try yaml.parse(alloc, input);
        defer doc.deinit();
        var ed = yaml.edit.Editor.init(&doc);
        const batch = [_]yaml.edit.Edit{
            .{ .set = .{ .path = "$.zz_probe.deep", .value = try doc.createScalar("x", .plain) } },
            .{ .move = .{ .from = "$.zz_no_such_subtree", .to = "$" } },
        };
        if (ed.apply(&batch)) |_| {
            failures.add("{s}: an invalid batch unexpectedly succeeded", .{name});
        } else |_| {}
        const out = try doc.write(alloc);
        defer alloc.free(out);
        if (!std.mem.eql(u8, out, input)) {
            failures.add("{s}: failed batch did not roll back byte-identically", .{name});
        }
    }
}

/// Weak invariant for every edit, regardless of documented
/// normalizations: the emitter must not emit invalid YAML.
fn assertsReparse(alloc: std.mem.Allocator, name: []const u8, what: []const u8, out: []const u8, failures: *Failures) void {
    var re = yaml.parse(alloc, out) catch {
        failures.add("{s}: {s}: emitted output is not valid YAML", .{ name, what });
        return;
    };
    re.deinit();
}

// ----------------------------------------------------------------------
// Semantic comparison (yaml.value trees)
//
// A re-parse assertion cannot see "valid YAML that lost data": e.g.
// `ports:\n    {}` parses fine while the sequence under `ports` has
// been silently replaced by an empty mapping. These helpers compare
// the parsed VALUE trees, so a deleted entry must be exactly gone and
// every other byte of structure must be exactly what it was.
// ----------------------------------------------------------------------

fn valueEql(a: yaml.value.Value, b: yaml.value.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    switch (a) {
        .null_ => return true,
        .bool_ => |v| return v == b.bool_,
        .int => |v| return v == b.int,
        .bigint => |s| return std.mem.eql(u8, s, b.bigint),
        .float => |v| return v == b.float or (std.math.isNan(v) and std.math.isNan(b.float)),
        .string => |s| return std.mem.eql(u8, s, b.string),
        .list => |items| {
            if (items.len != b.list.len) return false;
            for (items, b.list) |x, y| {
                if (!valueEql(x, y)) return false;
            }
            return true;
        },
        .map => |members| {
            if (members.len != b.map.len) return false;
            for (members) |m| {
                const other = b.get(m.key) orelse return false;
                if (!valueEql(m.value, other)) return false;
            }
            return true;
        },
    }
}

fn valueIsEmptySlot(v: yaml.value.Value) bool {
    return switch (v) {
        .list => |l| l.len == 0,
        .map => |m| m.len == 0,
        else => false,
    };
}

/// `vout` is `vin` with the entry at `segs` removed: everything else
/// unchanged, in order; the slot itself empty (sole child) or absent.
fn valueMinusEql(vin: yaml.value.Value, vout: yaml.value.Value, segs: []const yaml.edit.Segment) bool {
    if (segs.len == 0) return false; // root deletion is not swept
    switch (segs[0]) {
        .key => |k| {
            if (vin != .map or vout != .map) return false;
            if (segs.len == 1) {
                if (vin.get(k) == null) return false; // target must exist
                if (vout.get(k) != null) return false; // and be gone
                var j: usize = 0;
                for (vin.map) |m| {
                    if (std.mem.eql(u8, m.key, k)) continue;
                    if (j >= vout.map.len) return false;
                    if (!std.mem.eql(u8, m.key, vout.map[j].key)) return false;
                    if (!valueEql(m.value, vout.map[j].value)) return false;
                    j += 1;
                }
                return j == vout.map.len;
            }
            return valueMinusEql(vin.get(k) orelse return false, vout.get(k) orelse return false, segs[1..]);
        },
        .index => |ix| {
            if (vin != .list) return false;
            if (ix >= vin.list.len) return false;
            if (segs.len == 1) {
                if (vout != .list) return false;
                if (vout.list.len != vin.list.len - 1) return false;
                for (0..ix) |i| {
                    if (!valueEql(vin.list[i], vout.list[i])) return false;
                }
                for (ix..vout.list.len) |i| {
                    if (!valueEql(vin.list[i + 1], vout.list[i])) return false;
                }
                return true;
            }
            if (vout != .list or ix >= vout.list.len) return false;
            return valueMinusEql(vin.list[ix], vout.list[ix], segs[1..]);
        },
        else => return false,
    }
}

/// `vout` is `vin` with the entry at `segs` set to `sentinel`: every
/// other member unchanged and in order, the target exactly the
/// sentinel string (kept in place when it existed, appended when new).
fn valueSetEql(vin: yaml.value.Value, vout: yaml.value.Value, segs: []const yaml.edit.Segment, sentinel_text: []const u8) bool {
    if (segs.len == 0) {
        // Terminal: the target slot itself now holds the sentinel.
        return vout == .string and std.mem.eql(u8, vout.string, sentinel_text);
    }
    switch (segs[0]) {
        .key => |k| {
            if (vin != .map or vout != .map) return false;
            if (segs.len == 1) {
                const sentinel_value: yaml.value.Value = .{ .string = sentinel_text };
                var ia: usize = 0;
                var ib: usize = 0;
                var seen_target = false;
                while (ia < vin.map.len or ib < vout.map.len) {
                    const a_ok = ia < vin.map.len;
                    const b_ok = ib < vout.map.len;
                    if (a_ok and std.mem.eql(u8, vin.map[ia].key, k)) {
                        // Existed: replaced in place, position kept.
                        if (!b_ok or !std.mem.eql(u8, vout.map[ib].key, k)) return false;
                        if (!valueEql(vout.map[ib].value, sentinel_value)) return false;
                        seen_target = true;
                        ia += 1;
                        ib += 1;
                    } else if (b_ok and std.mem.eql(u8, vout.map[ib].key, k)) {
                        // New key: appended at the end only.
                        if (a_ok) return false;
                        if (!valueEql(vout.map[ib].value, sentinel_value)) return false;
                        seen_target = true;
                        ib += 1;
                    } else {
                        if (!a_ok or !b_ok) return false;
                        if (!std.mem.eql(u8, vin.map[ia].key, vout.map[ib].key)) return false;
                        if (!valueEql(vin.map[ia].value, vout.map[ib].value)) return false;
                        ia += 1;
                        ib += 1;
                    }
                }
                return seen_target;
            }
            return valueSetEql(vin.get(k) orelse return false, vout.get(k) orelse return false, segs[1..], sentinel_text);
        },
        .index => |ix| {
            if (vin != .list or vout != .list) return false;
            if (ix >= vin.list.len or ix >= vout.list.len) return false;
            return valueSetEql(vin.list[ix], vout.list[ix], segs[1..], sentinel_text);
        },
        else => return false,
    }
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

test "preservation: emptying a container and moving a nested first child emit valid YAML" {
    // Leak-checking allocator WITHOUT per-allocation stack traces: the
    // sweep runs ~2500 parse+emit cycles and trace capture alone costs
    // ~30x (>10 min -> ~45 s). Leak detection is retained; when a leak
    // appears, temporarily swap in std.testing.allocator for one run to
    // get the allocating call site in the report.
    var da: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer std.debug.assert(da.deinit() == .ok);
    const alloc = da.allocator();
    // The sole-child delete repro: the emptied container normalizes,
    // but the `{}` must stay the VALUE of its key.
    {
        var doc = try yaml.parse(alloc, "src:\n  item: 1\ndest: 2\n");
        defer doc.deinit();
        var ed = yaml.edit.Editor.init(&doc);
        try ed.apply(&.{.{ .delete = "$.src.item" }});
        const out = try doc.write(alloc);
        defer alloc.free(out);
        var re = try yaml.parse(alloc, out); // must re-parse
        defer re.deinit();
        try std.testing.expectEqualStrings("2", re.pathGet(&.{"dest"}).?.scalarValue().?);
    }
    // Sole child of a sequence.
    {
        var doc = try yaml.parse(alloc, "top:\n  - only\ndest: 2\n");
        defer doc.deinit();
        var ed = yaml.edit.Editor.init(&doc);
        try ed.apply(&.{.{ .delete = "$.top[0]" }});
        const out = try doc.write(alloc);
        defer alloc.free(out);
        var re = try yaml.parse(alloc, out);
        defer re.deinit();
        try std.testing.expectEqualStrings("2", re.pathGet(&.{"dest"}).?.scalarValue().?);
    }
    // Moving a nested container's first child away must not disturb
    // the surviving sibling's indentation.
    {
        var doc = try yaml.parse(alloc, "src:\n  item:\n    a: 1\n    b: 2\n  keep: k\ndst: {}\n");
        defer doc.deinit();
        var ed = yaml.edit.Editor.init(&doc);
        try ed.apply(&.{.{ .move = .{ .from = "$.src.item", .to = "$.dst", .key = "moved" } }});
        const out = try doc.write(alloc);
        defer alloc.free(out);
        var re = try yaml.parse(alloc, out);
        defer re.deinit();
        try std.testing.expectEqualStrings("1", re.pathGet(&.{ "dst", "moved", "a" }).?.scalarValue().?);
        try std.testing.expectEqualStrings("k", re.pathGet(&.{ "src", "keep" }).?.scalarValue().?);
        // The surviving sibling's line at its original indentation.
        var hit = false;
        var it = std.mem.splitScalar(u8, out, '\n');
        while (it.next()) |line| {
            if (std.mem.eql(u8, line, "  keep: k")) hit = true;
        }
        try std.testing.expect(hit);
    }
}

test "preservation sweep: every edit position in every single-document fixture" {
    // Leak-checking allocator WITHOUT per-allocation stack traces: the
    // sweep runs ~2500 parse+emit cycles and trace capture alone costs
    // ~30x (>10 min -> ~45 s). Leak detection is retained; when a leak
    // appears, temporarily swap in std.testing.allocator for one run to
    // get the allocating call site in the report.
    var da: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer std.debug.assert(da.deinit() == .ok);
    const alloc = da.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    {
        var dir = try std.Io.Dir.cwd().openDir(io, fixtures_dir, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".yaml") and !std.mem.endsWith(u8, entry.name, ".yml")) continue;
            if (std.mem.eql(u8, entry.name, multidoc_fixture)) continue; // own test below
            try names.append(alloc, try alloc.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    if (names.items.len < 10) return error.TestUnexpectedResult; // fixtures missing

    var failures: Failures = .{ .alloc = alloc };
    defer {
        for (failures.list.items) |f| alloc.free(f);
        failures.list.deinit(alloc);
    }
    var stats: Stats = .{};

    var dir = try std.Io.Dir.cwd().openDir(io, fixtures_dir, .{});
    defer dir.close(io);
    for (names.items) |name| {
        const input = try dir.readFileAlloc(io, name, alloc, .limited(4 << 20));
        defer alloc.free(input);
        try sweepFixture(alloc, name, input, &failures, &stats);
    }

    std.debug.print(
        "preservation: {d} deletes, {d} sets, {d} map adds, {d} seq appends, {d} rollbacks over {d} fixtures\n" ++
            "  skipped (documented normalizations): {d} sole-child, {d} dangling anchor, {d} multi-line, {d} alias, {d} flow, {d} empty; {d} unaddressable paths\n",
        .{
            stats.deletes,            stats.sets,
            stats.map_adds,           stats.seq_appends,
            stats.rollbacks,          names.items.len,
            stats.skipped_sole_child, stats.skipped_dangling_anchor,
            stats.skipped_multiline,  stats.skipped_alias,
            stats.skipped_flow,       stats.skipped_empty,
            stats.unaddressable,
        },
    );
    if (failures.list.items.len > 0) {
        for (failures.list.items) |f| std.debug.print("  PRESERVATION-FAIL {s}\n", .{f});
        return error.TestUnexpectedResult;
    }
}

test "preservation: editing one document of a real multi-document stream leaves the others byte-identical" {
    // Leak-checking allocator WITHOUT per-allocation stack traces: the
    // sweep runs ~2500 parse+emit cycles and trace capture alone costs
    // ~30x (>10 min -> ~45 s). Leak detection is retained; when a leak
    // appears, temporarily swap in std.testing.allocator for one run to
    // get the allocating call site in the report.
    var da: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer std.debug.assert(da.deinit() == .ok);
    const alloc = da.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const input = try std.Io.Dir.cwd().readFileAlloc(io, fixtures_dir ++ "/" ++ multidoc_fixture, alloc, .limited(4 << 20));
    defer alloc.free(input);

    var docs = try yaml.parseAll(alloc, input);
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(alloc);
    }
    if (docs.items.len < 2) return error.TestUnexpectedResult;
    const mid = docs.items.len / 2;
    const doc_mid = &docs.items[mid];

    // First addressable scalar leaf of the middle document.
    var ed = yaml.edit.Editor.init(doc_mid);
    var comps: std.ArrayList(Comp) = .empty;
    defer comps.deinit(alloc);
    var path: ?[]const u8 = null;
    findFirstScalar(&ed, doc_mid.root.?, &comps, &path, 0);
    const edit_path = path orelse return error.TestUnexpectedResult;
    defer alloc.free(edit_path);

    try ed.set(edit_path, try doc_mid.createScalar(sentinel, .plain));

    // Concatenate every document's bytes; only the middle document's
    // region may differ.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (docs.items) |*d| {
        const text = try d.write(alloc);
        defer alloc.free(text);
        try out.appendSlice(alloc, text);
    }

    const region = docs.items[mid];
    try std.testing.expect(std.mem.startsWith(u8, out.items, input[0..region.region_start]));
    try std.testing.expect(std.mem.endsWith(u8, out.items, input[region.region_end..]));

    // The other documents re-emit to exactly their original bytes.
    var fresh = try yaml.parseAll(alloc, input);
    defer {
        for (fresh.items) |*d| d.deinit();
        fresh.deinit(alloc);
    }
    for (docs.items, fresh.items, 0..) |*d, *f, i| {
        if (i == mid) continue;
        const a = try d.write(alloc);
        defer alloc.free(a);
        const b = try f.write(alloc);
        defer alloc.free(b);
        try std.testing.expectEqualStrings(b, a);
    }
}

fn findFirstScalar(ed: *yaml.edit.Editor, node: *yaml.Node, comps: *std.ArrayList(Comp), out: *?[]const u8, depth: usize) void {
    if (out.* != null or depth > 24) return;
    switch (node.data) {
        .scalar => {
            const p = formatPath(ed.doc.alloc, comps.items) catch return;
            // Keep it only if the editor can resolve it back.
            if (ed.one(p)) |_| {
                out.* = p;
            } else |_| {
                ed.doc.alloc.free(p);
            }
        },
        .mapping => |m| {
            for (m.pairs.items) |pair| {
                if (out.* != null) return;
                const key = pair.key.scalarValue() orelse continue;
                comps.append(ed.doc.alloc, .{ .key = key }) catch return;
                findFirstScalar(ed, pair.value, comps, out, depth + 1);
                _ = comps.pop();
            }
        },
        .sequence => |s| {
            for (s.items.items, 0..) |item, i| {
                if (out.* != null) return;
                comps.append(ed.doc.alloc, .{ .index = i }) catch return;
                findFirstScalar(ed, item, comps, out, depth + 1);
                _ = comps.pop();
            }
        },
        .alias => {},
    }
}
