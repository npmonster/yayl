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
const corpus = @import("corpus_common.zig");

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

fn splitLines(allocator: std.mem.Allocator, s: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| try out.append(allocator, line);
    // A trailing newline produces one empty final element; drop it so
    // both sides compare on content lines only.
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0) _ = out.pop();
    return try out.toOwnedSlice(allocator);
}

/// `input` with every occurrence of `byte` replaced by `with` — the
/// CRLF fixture-variant derivation.
fn replaceByte(allocator: std.mem.Allocator, input: []const u8, byte: u8, with: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |c| {
        if (c == byte) {
            try out.appendSlice(allocator, with);
        } else {
            try out.append(allocator, c);
        }
    }
    return try out.toOwnedSlice(allocator);
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
    /// Moving this subtree cannot be asserted independently: it is an
    /// alias, contains an alias that could become a forward reference,
    /// carries an anchor whose references depend on its source
    /// position, or sits under a container whose leading bytes are
    /// anchor/tag properties the edited walk does not re-emit.
    move_unsafe: bool,
    /// Some ancestor container (or the parent itself) opens its span
    /// with anchor/tag property lines. An edit marks that container
    /// modified, and the edited walk re-orders the property bytes
    /// behind the entries — counted, never swept.
    props_preamble: bool,
    /// The entry was written with an explicit key indicator (`? key`).
    /// Edits re-emit it as a two-line entry, so line-shape assertions
    /// do not apply; the semantic ones still run.
    explicit_key: bool,
    /// The parent container is flow-styled: the emitter's documented
    /// normalization reflows the collection, so line-shape assertions
    /// do not apply; the semantic ones still run.
    in_flow: bool,
    /// The entry's own bytes contain a hard tab. Tab-indented entries
    /// are not yet preserved by the edit path — counted, never swept.
    tab_span: bool,
    /// The entry uses a construct the edit path does not model: a
    /// tagged, anchored, aliased, empty or multi-line key — or it sits
    /// below a mapping that does. Counted, never swept.
    unsupported: bool,
    /// The entry's mapping key, for locating the removed lines.
    key_text: []const u8,
};

const Container = struct {
    path: []const u8,
    is_mapping: bool,
    is_flow: bool,
    non_empty: bool,
    /// See `Target.props_preamble`.
    props_preamble: bool,
    /// The container's own bytes carry a hard tab.
    tab_span: bool,
    /// See `Target.unsupported`.
    unsupported: bool,
};

const Found = struct {
    targets: std.ArrayList(Target) = .empty,
    containers: std.ArrayList(Container) = .empty,
    unaddressable: usize = 0,

    fn deinit(self: *Found, allocator: std.mem.Allocator) void {
        for (self.targets.items) |t| {
            allocator.free(t.path);
            allocator.free(t.key_text);
        }
        self.targets.deinit(allocator);
        for (self.containers.items) |c| allocator.free(c.path);
        self.containers.deinit(allocator);
    }
};

fn collectReferencedAnchors(allocator: std.mem.Allocator, node: *const yaml.Node, set: *std.StringHashMap(void)) !void {
    switch (node.data) {
        .alias => |a| {
            // The same anchor may be referenced many times; the set
            // keeps one owned copy.
            if (!set.contains(a.name)) try set.put(try allocator.dupe(u8, a.name), {});
        },
        .mapping => |m| for (m.pairs.items) |p| {
            try collectReferencedAnchors(allocator, p.key, set);
            try collectReferencedAnchors(allocator, p.value, set);
        },
        .sequence => |s| for (s.items.items) |item| {
            try collectReferencedAnchors(allocator, item, set);
        },
        .scalar => {},
    }
}

fn subtreeContainsAlias(node: *const yaml.Node, depth: usize) bool {
    if (depth > 24) return true;
    return switch (node.data) {
        .alias => true,
        .mapping => |m| blk: {
            for (m.pairs.items) |pair| {
                if (subtreeContainsAlias(pair.key, depth + 1) or subtreeContainsAlias(pair.value, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        .sequence => |s| blk: {
            for (s.items.items) |item| {
                if (subtreeContainsAlias(item, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        .scalar => false,
    };
}

/// True when any node in the subtree defines an anchor that some alias
/// in the document references. Replacing or deleting such a subtree
/// leaves those aliases dangling, no matter how deep the anchor sits
/// (`top: {k: &a v}` + `other: *a`). Depth overflow counts as unsafe.
fn subtreeDefinesReferencedAnchor(node: *const yaml.Node, referenced: *const std.StringHashMap(void), depth: usize) bool {
    if (depth > 24) return true;
    if (node.anchor) |a| {
        if (referenced.contains(a)) return true;
    }
    return switch (node.data) {
        .alias => false,
        .mapping => |m| blk: {
            for (m.pairs.items) |pair| {
                if (subtreeDefinesReferencedAnchor(pair.key, referenced, depth + 1)) break :blk true;
                if (subtreeDefinesReferencedAnchor(pair.value, referenced, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        .sequence => |s| blk: {
            for (s.items.items) |item| {
                if (subtreeDefinesReferencedAnchor(item, referenced, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        .scalar => false,
    };
}

fn formatPath(allocator: std.mem.Allocator, comps: []const Comp) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '$');
    for (comps) |c| switch (c) {
        .key => |k| try buf.print(allocator, ".{s}", .{k}),
        .index => |ix| try buf.print(allocator, "[{d}]", .{ix}),
    };
    return try buf.toOwnedSlice(allocator);
}

/// Record a container only when the path grammar can actually address
/// it: a key carrying a dot (GitLab's `.defaults`, mkdocs'
/// `pymdownx.highlight`) formats into a path that parses as something
/// else. Counted, never silently dropped.
fn addContainer(
    allocator: std.mem.Allocator,
    ed: *yaml.edit.Editor,
    node: *yaml.Node,
    comps: []const Comp,
    found: *Found,
    c: Container,
) !void {
    if (comps.len > 0) {
        const resolved = ed.one(c.path) catch null;
        if (resolved == null or resolved.? != node) {
            allocator.free(c.path);
            found.unaddressable += 1;
            return;
        }
    }
    try found.containers.append(allocator, c);
}

/// True when a block container's span opens with bytes that are neither
/// entry framing nor blank: anchor and tag properties written on their
/// own lines before the first entry (`&sequence\n- a`). The same
/// hazard arises when the property bytes sit in the gap BETWEEN the
/// owning key and the container (`sequence: !!seq\n- entry`) or before
/// the root's span (`--- &anchor\n- a`) — `gap` checks those bytes.
fn containerPropsPreamble(node: *const yaml.Node, src: []const u8) bool {
    const cs = node.src orelse return false;
    if (cs.synthetic or cs.start >= cs.entry_start) return false;
    return gapHasProps(src, cs.start, cs.entry_start);
}

/// True when `src[from..to]` contains an anchor or tag indicator (`&`
/// or `!`) among otherwise blank/framing bytes.
fn gapHasProps(src: []const u8, from: usize, to: usize) bool {
    if (to <= from) return false;
    for (src[from..to]) |ch| switch (ch) {
        ' ', '\t', '\n', '\r', '-', ':' => {},
        '&', '!' => return true,
        else => {},
    };
    return false;
}

/// True when the span [from, to) carries a hard tab.
fn spanHasTab(src: []const u8, from: usize, to: usize) bool {
    if (to <= from or to > src.len or from > src.len) return false;
    return std.mem.indexOfScalar(u8, src[from..to], '\t') != null;
}

/// True when a container's own header — the bytes between its entry
/// start and its first entry's start — carries an anchor or tag
/// (`!!seq` on its own line before `- entry`). The edited walk treats
/// those bytes as inter-entry gap, so a re-emitted first slot lands
/// ahead of them and reorders the container: counted, never swept.
fn containerHeaderProps(node: *const yaml.Node, src: []const u8) bool {
    const cs = node.src orelse return false;
    if (cs.synthetic) return false;
    var first_entry: usize = cs.end;
    switch (node.data) {
        .mapping => |m| for (m.pairs.items) |p| {
            if (p.key.src) |s| {
                if (!s.synthetic) {
                    first_entry = s.entry_start;
                    break;
                }
            }
        },
        .sequence => |sq| for (sq.items.items) |it| {
            if (it.src) |s| {
                if (!s.synthetic) {
                    first_entry = s.entry_start;
                    break;
                }
            }
        },
        else => {},
    }
    return cs.entry_start < first_entry and first_entry <= src.len and
        gapHasProps(src, cs.entry_start, first_entry);
}

/// True when the bytes between a key's entry start and its text are an
/// explicit key indicator: framing plus `? `.
fn explicitKeyBytes(src: []const u8, from: usize, to: usize) bool {
    if (to <= from) return false;
    var saw_q = false;
    for (src[from..to]) |ch| switch (ch) {
        ' ', '\t', '\n', '\r', '-' => {},
        '?' => saw_q = true,
        else => return false,
    };
    return saw_q;
}

fn walkTargets(
    allocator: std.mem.Allocator,
    ed: *yaml.edit.Editor,
    input: []const u8,
    referenced: *std.StringHashMap(void),
    node: *yaml.Node,
    comps: *std.ArrayList(Comp),
    found: *Found,
    depth: usize,
    preamble: bool,
    preamble_unsupported: bool,
) !void {
    if (depth > 24) return;
    // An edit below this container marks it modified; if its span
    // opens with property bytes — in its own header, in the gap its
    // owning key left, or, at the root, before the root's span — every
    // position inside inherits the re-ordering hazard.
    const unsafe = preamble or containerPropsPreamble(node, input) or
        containerHeaderProps(node, input) or
        (depth == 0 and node.src != null and gapHasProps(input, 0, node.src.?.start));
    // A mapping whose KEYS use constructs the edit path does not model
    // (tagged, anchored, aliased, empty or multi-line keys) makes every
    // position inside it unsupported, this container's own adds
    // included.
    var unsupported = preamble_unsupported;
    switch (node.data) {
        .mapping => |m| for (m.pairs.items) |p| {
            const kt = p.key.scalarValue() orelse {
                unsupported = true;
                break;
            };
            if (kt.len == 0 or std.mem.indexOfScalar(u8, kt, '\n') != null or
                p.key.anchor != null or p.key.tag != null or p.key.kind() == .alias)
            {
                unsupported = true;
                break;
            }
        },
        else => {},
    }
    switch (node.data) {
        .mapping => |m| {
            try addContainer(allocator, ed, node, comps.items, found, .{
                .path = try formatPath(allocator, comps.items),
                .is_mapping = true,
                .is_flow = m.style == .flow,
                .non_empty = m.pairs.items.len > 0,
                .props_preamble = unsafe,
                .tab_span = if (node.src) |cs| spanHasTab(input, cs.start, cs.end) else false,
                .unsupported = unsupported,
            });
            for (m.pairs.items) |pair| {
                // A non-scalar key (complex `? key`) formats no path:
                // counted as unaddressable, its subtree is not swept.
                const key_text = pair.key.scalarValue() orelse {
                    found.unaddressable += 1;
                    continue;
                };
                // The grammar has no form for an empty key either
                // (`$.` is degenerate): counted, subtree not swept.
                if (key_text.len == 0) {
                    found.unaddressable += 1;
                    continue;
                }
                try comps.append(allocator, .{ .key = key_text });
                defer _ = comps.pop();
                const path = try formatPath(allocator, comps.items);
                const resolved = ed.one(path) catch null;
                if (resolved == null or resolved.? != pair.value) {
                    // Key text the path grammar cannot address (dots,
                    // leading dots, ambiguity). Subtree counted as
                    // unaddressable; children are still validated.
                    allocator.free(path);
                    found.unaddressable += 1;
                    try walkTargets(allocator, ed, input, referenced, pair.value, comps, found, depth + 1, unsafe, unsupported);
                    continue;
                }
                const line = if (pair.key.src) |s| lineOf(input, s.entry_start) else 0;
                const end_line = if (pair.src_end) |e| lineOf(input, e) else line;
                const ks = pair.key.src;
                const vs = pair.value.src;
                try found.targets.append(allocator, .{
                    .path = path,
                    .line = line,
                    .multi_line = end_line != line,
                    .sole_child = m.pairs.items.len == 1,
                    .is_alias = pair.value.kind() == .alias,
                    .anchored_referenced = subtreeDefinesReferencedAnchor(pair.value, referenced, 0),
                    .move_unsafe = subtreeContainsAlias(pair.value, 0) or
                        subtreeDefinesReferencedAnchor(pair.value, referenced, 0),
                    .props_preamble = unsafe or
                        (ks != null and vs != null and gapHasProps(input, ks.?.end, vs.?.entry_start)),
                    .explicit_key = ks != null and !ks.?.synthetic and
                        explicitKeyBytes(input, ks.?.entry_start, ks.?.start),
                    .in_flow = m.style == .flow,
                    .tab_span = spanHasTab(input, if (ks) |s| s.entry_start else 0, pair.src_end orelse (if (vs) |s| s.end else 0)),
                    .unsupported = unsupported,
                    .key_text = try allocator.dupe(u8, key_text),
                });
                try walkTargets(allocator, ed, input, referenced, pair.value, comps, found, depth + 1, unsafe, unsupported);
            }
        },
        .sequence => |s| {
            try addContainer(allocator, ed, node, comps.items, found, .{
                .path = try formatPath(allocator, comps.items),
                .is_mapping = false,
                .is_flow = s.style == .flow,
                .non_empty = s.items.items.len > 0,
                .props_preamble = unsafe,
                .tab_span = if (node.src) |cs| spanHasTab(input, cs.start, cs.end) else false,
                .unsupported = unsupported,
            });
            for (s.items.items, 0..) |item, i| {
                try comps.append(allocator, .{ .index = i });
                defer _ = comps.pop();
                const path = try formatPath(allocator, comps.items);
                const resolved = ed.one(path) catch null;
                if (resolved == null or resolved.? != item) {
                    allocator.free(path);
                    found.unaddressable += 1;
                    try walkTargets(allocator, ed, input, referenced, item, comps, found, depth + 1, unsafe, unsupported);
                    continue;
                }
                const line = if (item.src) |sp| lineOf(input, sp.entry_start) else 0;
                const end_line = if (item.src) |sp| lineOf(input, sp.end) else line;
                try found.targets.append(allocator, .{
                    .path = path,
                    .line = line,
                    .multi_line = end_line != line,
                    .sole_child = s.items.items.len == 1,
                    .is_alias = item.kind() == .alias,
                    .anchored_referenced = subtreeDefinesReferencedAnchor(item, referenced, 0),
                    .move_unsafe = subtreeContainsAlias(item, 0) or
                        subtreeDefinesReferencedAnchor(item, referenced, 0),
                    .props_preamble = unsafe,
                    .explicit_key = false,
                    .in_flow = s.style == .flow,
                    .tab_span = if (item.src) |sp| spanHasTab(input, sp.entry_start, sp.end) else false,
                    .unsupported = unsupported or item.anchor != null or item.tag != null,
                    .key_text = "",
                });
                try walkTargets(allocator, ed, input, referenced, item, comps, found, depth + 1, unsafe, unsupported);
            }
        },
        .scalar, .alias => {},
    }
}

// ----------------------------------------------------------------------
// Failure collection
// ----------------------------------------------------------------------

const Failures = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList([]const u8) = .empty,

    fn add(self: *Failures, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.list.append(self.allocator, msg) catch {
            self.allocator.free(msg);
            return;
        };
    }
};

const Stats = struct {
    documents: usize = 0,
    deletes: usize = 0,
    sets: usize = 0,
    same_sets: usize = 0,
    map_adds: usize = 0,
    seq_appends: usize = 0,
    inserts: usize = 0,
    moves: usize = 0,
    rollbacks: usize = 0,
    skipped_sole_child: usize = 0,
    skipped_dangling_anchor: usize = 0,
    skipped_multiline: usize = 0,
    skipped_alias: usize = 0,
    skipped_flow: usize = 0,
    skipped_empty: usize = 0,
    skipped_same_non_scalar: usize = 0,
    skipped_move_related: usize = 0,
    skipped_move_dest: usize = 0,
    skipped_no_root: usize = 0,
    skipped_roundtrip_unstable: usize = 0,
    skipped_props_preamble: usize = 0,
    skipped_explicit_key: usize = 0,
    skipped_tab_span: usize = 0,
    skipped_unsupported: usize = 0,
    skipped_no_final_newline: usize = 0,
    skipped_bom: usize = 0,
    skipped_crlf: usize = 0,
    capped_targets: usize = 0,
    capped_containers: usize = 0,
    unaddressable: usize = 0,
};

/// Per-kind sweep bounds. Mapping-shaped and sequence-shaped positions
/// draw from SEPARATE allowances, so a mapping-heavy document cannot
/// consume a sequence position's slot or vice versa; `max_targets`
/// additionally bounds each kind's manipulation positions and
/// `max_move_dests_per_target` bounds move destinations per source
/// subtree. The defaults are unbounded — the fixture sweeps; the
/// corpus and variant sweeps pass small bounds to stay inside the
/// runtime budget.
const SweepLimits = struct {
    max_targets: usize = std.math.maxInt(usize),
    max_mappings: usize = std.math.maxInt(usize),
    max_sequences: usize = std.math.maxInt(usize),
    max_move_dests_per_target: usize = 3,
};

/// Select the manipulation positions a sweep visits: mapping entries
/// and sequence items are budgeted separately (`max_mappings` vs
/// `max_sequences`, each further bounded by `max_targets`) so one kind
/// cannot consume the other's per-document allowance. Positions beyond
/// a budget are counted into `capped`, never silently dropped.
/// Mapping entries come first, sequence items after.
fn selectTargets(allocator: std.mem.Allocator, all: []const Target, limits: SweepLimits, capped: *usize) ![]Target {
    var out: std.ArrayList(Target) = .empty;
    errdefer out.deinit(allocator);
    const kinds = [_]struct { want_item: bool, budget: usize }{
        .{ .want_item = false, .budget = @min(limits.max_targets, limits.max_mappings) },
        .{ .want_item = true, .budget = @min(limits.max_targets, limits.max_sequences) },
    };
    for (kinds) |kind| {
        var budget = kind.budget;
        for (all) |t| {
            if (std.mem.endsWith(u8, t.path, "]") != kind.want_item) continue;
            if (budget == 0) {
                capped.* += 1;
                continue;
            }
            budget -= 1;
            try out.append(allocator, t);
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// The parent sequence path of a sequence item path: item paths end
/// in `]`, and the sequence is everything before its last `[`.
fn sequenceParentOf(path: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, path, "]")) return null;
    const open = std.mem.lastIndexOfScalar(u8, path, '[') orelse return null;
    if (open == 0) return null;
    return path[0..open];
}

/// `out` is `orig` with lines only inserted at one position, with at
/// most one surviving line re-framed: inserting before the first item
/// of a sequence that shares its parent's line (`- - a`) moves the
/// inner `- ` indicator onto the new line and the old first item down.
fn pureInsertionReframed(orig: [][]const u8, out: [][]const u8) ?usize {
    if (out.len <= orig.len) return null;
    const added = out.len - orig.len;
    var at: usize = 0;
    outer: while (at <= orig.len) : (at += 1) {
        var reframed: usize = 0;
        for (orig, 0..) |line, k| {
            const oi = if (k < at) k else k + added;
            if (std.mem.eql(u8, out[oi], line)) continue;
            if (!std.mem.eql(u8, stripFraming(out[oi]), stripFraming(line))) continue :outer;
            reframed += 1;
            if (reframed > 1) continue :outer;
        }
        return at;
    }
    return null;
}

/// The strong assertion for every edit without a documented
/// normalization: the edited in-memory document and a re-parse of the
/// emitted bytes must have the same semantic value tree. A re-parse
/// alone cannot see "valid YAML that lost data" (a sequence silently
/// replaced by an empty mapping still parses); this can.
fn assertsSemanticRoundTrip(
    allocator: std.mem.Allocator,
    name: []const u8,
    comptime what: []const u8,
    path: []const u8,
    edited: *yaml.Document,
    out: []const u8,
    failures: *Failures,
) void {
    var re = yaml.parse(allocator, out) catch {
        failures.add("{s}: " ++ what ++ " {s}: emitted output is not valid YAML", .{ name, path });
        return;
    };
    defer re.deinit();
    const v_edited = yaml.value.nodeToValue(allocator, edited.root orelse return) catch return;
    defer yaml.value.freeValue(allocator, v_edited);
    const v_out = yaml.value.nodeToValue(allocator, re.root orelse return) catch return;
    defer yaml.value.freeValue(allocator, v_out);
    if (!valueEql(v_edited, v_out)) {
        failures.add("{s}: " ++ what ++ " {s}: re-parsed output does not match the edited document", .{ name, path });
    }
}

/// One reporting helper for every sweep run: every counter, including
/// every skip and cap category — printed, never silent.
fn printSummary(label: []const u8, noun: []const u8, units: usize, stats: Stats) void {
    std.debug.print(
        "preservation[{s}]: {d} deletes, {d} sets, {d} same-value sets, {d} map adds, {d} seq appends, {d} inserts, {d} moves, {d} rollbacks over {d} {s} ({d} documents, {d} without a root)\n",
        .{
            label,
            stats.deletes,
            stats.sets,
            stats.same_sets,
            stats.map_adds,
            stats.seq_appends,
            stats.inserts,
            stats.moves,
            stats.rollbacks,
            units,
            noun,
            stats.documents,
            stats.skipped_no_root,
        },
    );
    std.debug.print(
        "  skipped: {d} sole-child, {d} dangling anchor, {d} multi-line, {d} alias, {d} flow, {d} empty, {d} same non-scalar, {d} explicit-key, {d} tab-span, {d} unsupported constructs, {d} no-final-newline, {d} bom, {d} crlf\n" ++
            "  skipped: {d} unaddressable paths, {d} round-trip-unstable, {d} property-preamble, {d} move/insert related, {d} unusable destinations; capped: {d} targets, {d} containers\n",
        .{
            stats.skipped_sole_child,
            stats.skipped_dangling_anchor,
            stats.skipped_multiline,
            stats.skipped_alias,
            stats.skipped_flow,
            stats.skipped_empty,
            stats.skipped_same_non_scalar,
            stats.skipped_explicit_key,
            stats.skipped_tab_span,
            stats.skipped_unsupported,
            stats.skipped_no_final_newline,
            stats.skipped_bom,
            stats.skipped_crlf,
            stats.unaddressable,
            stats.skipped_roundtrip_unstable,
            stats.skipped_props_preamble,
            stats.skipped_move_related,
            stats.skipped_move_dest,
            stats.capped_targets,
            stats.capped_containers,
        },
    );
}

// ----------------------------------------------------------------------
// The sweeps over one fixture
// ----------------------------------------------------------------------

fn sweepFixture(allocator: std.mem.Allocator, name: []const u8, raw_input: []const u8, failures: *Failures, stats: *Stats, limits: SweepLimits) !void {
    // A multi-document stream: `parse` covers only the FIRST document,
    // so sweep exactly its region — the byte-level assertions must
    // compare like with like. Single documents are swept whole.
    var input = raw_input;
    {
        var docs = try yaml.parseAll(allocator, raw_input);
        defer {
            for (docs.items) |*d| d.deinit();
            docs.deinit(allocator);
        }
        if (docs.items.len == 0) {
            stats.skipped_no_root += 1;
            return;
        }
        if (docs.items.len > 1) input = raw_input[docs.items[0].region_start..docs.items[0].region_end];
    }
    // Discovery on a pristine parse. The generation document is freed
    // before sweeping; targets own their strings.
    var found: Found = .{};
    defer found.deinit(allocator);
    {
        var gen = try yaml.parse(allocator, input);
        defer gen.deinit();
        const root = gen.root orelse {
            stats.skipped_no_root += 1;
            return;
        };
        // A few shapes are documented round-trip-unstable (the
        // roundtrip gate's four skips): their plain parse -> write
        // already normalizes bytes, so byte-level assertions cannot
        // apply to them. Counted, never silent.
        const plain = try gen.write(allocator);
        defer allocator.free(plain);
        if (!std.mem.eql(u8, plain, input)) {
            stats.skipped_roundtrip_unstable += 1;
            return;
        }
        // A byte-order mark keeps the document's untouched bytes exact
        // (the round-trip gate and the BOM unit test prove it), but the
        // edited walk still misaligns its slots around the prefix.
        // Counted, never swept.
        if (std.mem.startsWith(u8, input, "\xEF\xBB\xBF")) {
            stats.skipped_bom += 1;
            return;
        }
        stats.documents += 1;
        var referenced: std.StringHashMap(void) = .init(allocator);
        defer {
            var kit = referenced.keyIterator();
            while (kit.next()) |k| allocator.free(k.*);
            referenced.deinit();
        }
        try collectReferencedAnchors(allocator, root, &referenced);
        var ed = yaml.edit.Editor.init(&gen);
        var comps: std.ArrayList(Comp) = .empty;
        defer comps.deinit(allocator);
        try walkTargets(allocator, &ed, input, &referenced, root, &comps, &found, 0, false, false);
    }
    stats.unaddressable += found.unaddressable;
    var capped_targets: usize = 0;
    const targets = try selectTargets(allocator, found.targets.items, limits, &capped_targets);
    defer allocator.free(targets);
    stats.capped_targets += capped_targets;

    const orig_lines = try splitLines(allocator, input);
    defer allocator.free(orig_lines);
    // An input without a final newline: an edit that touches the last
    // line legitimately terminates it, so line-shape assertions do not
    // apply and the weak ones run instead.
    const no_final = !std.mem.endsWith(u8, input, "\n");

    // CRLF documents: edits that reuse existing line terminators
    // (delete, set, move, same-value set) are swept; edits that ADD a
    // line still write a bare LF for it, which is not preserved yet —
    // counted, never swept.
    const is_crlf = std.mem.indexOf(u8, input, "\r\n") != null;

    // DELETE sweep: input minus one contiguous run that contains the
    // deleted entry.
    for (targets) |t| {
        if (t.props_preamble) {
            stats.skipped_props_preamble += 1;
            continue;
        }
        if (t.unsupported) {
            stats.skipped_unsupported += 1;
            continue;
        }
        if (t.tab_span) {
            stats.skipped_tab_span += 1;
            continue;
        }
        if (t.anchored_referenced) {
            stats.skipped_dangling_anchor += 1;
            continue;
        }
        if (t.explicit_key or t.in_flow) {
            // An explicit-key entry re-emits as two lines and its
            // tombstone arithmetic does not yet cover the `? ` line; a
            // flow collection reflows by design, legitimately changing
            // even key text. Counted, never swept.
            stats.skipped_explicit_key += @intFromBool(t.explicit_key);
            stats.skipped_flow += @intFromBool(t.in_flow);
            continue;
        }
        if (t.sole_child or no_final) {
            // Line-shape assertions do not apply: an emptied container
            // normalizes to flow style, and a document without a final
            // newline legitimately gains one when its last line is
            // edited. The WEAK invariants still do — the output must
            // be valid YAML and the deleted entry must be gone. (A
            // previous regression emitted `key:\n{}` here, which does
            // not re-parse.)
            stats.skipped_sole_child += @intFromBool(t.sole_child);
            stats.skipped_no_final_newline += @intFromBool(no_final);
            var doc = try yaml.parse(allocator, input);
            defer doc.deinit();
            var ed = yaml.edit.Editor.init(&doc);
            ed.apply(&.{.{ .delete = t.path }}) catch |err| {
                failures.add("{s}: delete {s} failed: {s}", .{ name, t.path, @errorName(err) });
                continue;
            };
            const out = try doc.write(allocator);
            defer allocator.free(out);
            assertsReparse(allocator, name, t.path, out, failures);
            // Semantic: output value tree == input minus the entry. A
            // re-parse cannot see "valid YAML that lost an item" (e.g.
            // a sequence silently replaced by an empty mapping).
            {
                var vin_d = yaml.parse(allocator, input) catch continue;
                defer vin_d.deinit();
                var vout_d = yaml.parse(allocator, out) catch continue;
                defer vout_d.deinit();
                const vin = yaml.value.nodeToValue(allocator, vin_d.root.?) catch continue;
                defer yaml.value.freeValue(allocator, vin);
                const vout = yaml.value.nodeToValue(allocator, vout_d.root.?) catch continue;
                defer yaml.value.freeValue(allocator, vout);
                var p = yaml.edit.Path.parse(allocator, t.path) catch continue;
                defer p.deinit(allocator);
                if (!valueMinusEql(vin, vout, p.segments)) {
                    failures.add("{s}: delete {s}: output value tree is not the input minus the entry", .{ name, t.path });
                }
            }
            if (t.key_text.len > 0) {
                var re = yaml.parse(allocator, out) catch continue;
                defer re.deinit();
                var re_ed = yaml.edit.Editor.init(&re);
                if (re_ed.one(t.path)) |_| {
                    failures.add("{s}: delete {s}: path still resolves after the delete", .{ name, t.path });
                } else |_| {}
            }
            continue;
        }
        stats.deletes += 1;
        var doc = try yaml.parse(allocator, input);
        defer doc.deinit();
        var ed = yaml.edit.Editor.init(&doc);
        ed.apply(&.{.{ .delete = t.path }}) catch |err| {
            failures.add("{s}: delete {s} failed: {s}", .{ name, t.path, @errorName(err) });
            continue;
        };
        const out = try doc.write(allocator);
        defer allocator.free(out);
        const out_lines = try splitLines(allocator, out);
        defer allocator.free(out_lines);
        // Whatever the shape, the result must still be YAML and must no
        // longer resolve the deleted path.
        {
            var re = yaml.parse(allocator, out) catch {
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
                // The item indicator either rides its first line
                // (`- x`) or, for a multi-line item, fills a line of
                // its own (`-`).
                if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.eql(u8, trimmed, "-")) hit = true;
            }
        }
        if (!hit) {
            failures.add("{s}: delete {s}: removed lines {d}..{d} do not contain the entry", .{ name, t.path, removed.start, removed.end });
        }
    }

    // SET sweep: exactly the target's line changes; the output
    // re-parses with the new value at the same path.
    for (targets) |t| {
        if (t.props_preamble) {
            stats.skipped_props_preamble += 1;
            continue;
        }
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
        if (t.anchored_referenced) {
            stats.skipped_dangling_anchor += 1;
            continue;
        }
        if (t.unsupported or t.tab_span) {
            stats.skipped_unsupported += @intFromBool(t.unsupported);
            stats.skipped_tab_span += @intFromBool(t.tab_span);
            continue;
        }
        if (t.explicit_key or t.in_flow) {
            // An explicit-key entry re-emits as two lines (`? key` +
            // `: value`); a flow collection reflows by design and may
            // legitimately change even key text. Counted, never swept.
            stats.skipped_explicit_key += @intFromBool(t.explicit_key);
            stats.skipped_flow += @intFromBool(t.in_flow);
            continue;
        }
        if (t.multi_line or no_final) {
            // Replacing a multi-line value legitimately reflows lines,
            // and a missing final newline terminates on edit: line-
            // shape assertions do not apply. Weak invariants still do:
            // valid YAML, sentinel at the path, and the semantic value
            // tree.
            stats.skipped_multiline += @intFromBool(t.multi_line);
            stats.skipped_no_final_newline += @intFromBool(no_final);
            var doc = try yaml.parse(allocator, input);
            defer doc.deinit();
            var ed = yaml.edit.Editor.init(&doc);
            ed.apply(&.{.{ .set = .{ .path = t.path, .value = try doc.createScalar(sentinel, .plain) } }}) catch |err| {
                failures.add("{s}: set {s} failed: {s}", .{ name, t.path, @errorName(err) });
                continue;
            };
            const out = try doc.write(allocator);
            defer allocator.free(out);
            assertsReparse(allocator, name, t.path, out, failures);
            // Semantic: output value tree == input with exactly the
            // target set to the sentinel — nothing lost, nothing added.
            {
                var vin_d = yaml.parse(allocator, input) catch continue;
                defer vin_d.deinit();
                var vout_d = yaml.parse(allocator, out) catch continue;
                defer vout_d.deinit();
                const vin = yaml.value.nodeToValue(allocator, vin_d.root.?) catch continue;
                defer yaml.value.freeValue(allocator, vin);
                const vout = yaml.value.nodeToValue(allocator, vout_d.root.?) catch continue;
                defer yaml.value.freeValue(allocator, vout);
                var p = yaml.edit.Path.parse(allocator, t.path) catch continue;
                defer p.deinit(allocator);
                if (!valueSetEql(vin, vout, p.segments, sentinel)) {
                    failures.add("{s}: set {s}: output value tree is not the input with the target set", .{ name, t.path });
                }
            }
            var re = yaml.parse(allocator, out) catch continue;
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
        var doc = try yaml.parse(allocator, input);
        defer doc.deinit();
        var ed = yaml.edit.Editor.init(&doc);
        ed.apply(&.{.{ .set = .{ .path = t.path, .value = try doc.createScalar(sentinel, .plain) } }}) catch |err| {
            failures.add("{s}: set {s} failed: {s}", .{ name, t.path, @errorName(err) });
            continue;
        };
        const out = try doc.write(allocator);
        defer allocator.free(out);
        const out_lines = try splitLines(allocator, out);
        defer allocator.free(out_lines);
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
        var doc2 = yaml.parse(allocator, out) catch {
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

    // SET-TO-SAME sweep: an exact scalar replacement is a semantic no-op
    // and must preserve every source byte, including flow spacing and block
    // scalar indentation/chomping.
    for (targets) |t| {
        if (t.is_alias) {
            stats.skipped_alias += 1;
            continue;
        }
        var doc = try yaml.parse(allocator, input);
        defer doc.deinit();
        var ed = yaml.edit.Editor.init(&doc);
        const existing = ed.one(t.path) catch continue;
        if (existing.data != .scalar) {
            stats.skipped_same_non_scalar += 1;
            continue;
        }
        stats.same_sets += 1;
        const replacement = try doc.createScalar(existing.data.scalar.value, existing.data.scalar.style);
        replacement.anchor = if (existing.anchor) |anchor| try doc.pool.dupe(anchor) else null;
        replacement.tag = if (existing.tag) |tag| try doc.pool.dupe(tag) else null;
        ed.apply(&.{.{ .set = .{ .path = t.path, .value = replacement } }}) catch |err| {
            failures.add("{s}: same-value set {s} failed: {s}", .{ name, t.path, @errorName(err) });
            continue;
        };
        const out = try doc.write(allocator);
        defer allocator.free(out);
        if (!std.mem.eql(u8, input, out)) {
            failures.add("{s}: same-value set {s} was not byte-identical", .{ name, t.path });
        }
    }

    // ADD sweeps: pure insertions only — a new key on every addressable
    // block mapping, an appended item on every block sequence. The two
    // container kinds draw from separate budgets (see `SweepLimits`).
    var map_budget = limits.max_mappings;
    var seq_budget = limits.max_sequences;
    for (found.containers.items) |c| {
        if (!c.non_empty or c.is_flow) {
            stats.skipped_flow += @intFromBool(c.is_flow);
            stats.skipped_empty += @intFromBool(!c.non_empty);
            continue;
        }
        if (c.props_preamble) {
            stats.skipped_props_preamble += 1;
            continue;
        }
        if (c.tab_span) {
            stats.skipped_tab_span += 1;
            continue;
        }
        if (c.unsupported) {
            stats.skipped_unsupported += 1;
            continue;
        }
        if (is_crlf) {
            // Adding a line writes a bare LF for it on a CRLF file.
            stats.skipped_crlf += 1;
            continue;
        }
        if (c.is_mapping) {
            if (map_budget == 0) {
                stats.capped_containers += 1;
                continue;
            }
            map_budget -= 1;
            stats.map_adds += 1;
            var doc = try yaml.parse(allocator, input);
            defer doc.deinit();
            var ed = yaml.edit.Editor.init(&doc);
            const new_path = try std.fmt.allocPrint(allocator, "{s}.zz_added", .{c.path});
            defer allocator.free(new_path);
            ed.apply(&.{.{ .set = .{ .path = new_path, .value = try doc.createScalar("added", .plain) } }}) catch |err| {
                failures.add("{s}: map add under {s} failed: {s}", .{ name, c.path, @errorName(err) });
                continue;
            };
            const out = try doc.write(allocator);
            defer allocator.free(out);
            const out_lines = try splitLines(allocator, out);
            defer allocator.free(out_lines);
            const at = pureInsertion(orig_lines, out_lines) orelse {
                failures.add("{s}: map add under {s}: not a pure line insertion", .{ name, c.path });
                continue;
            };
            var hit = false;
            for (out_lines[at..]) |line| {
                if (std.mem.indexOf(u8, line, "zz_added") != null) hit = true;
            }
            if (!hit) failures.add("{s}: map add under {s}: inserted lines do not carry the new key", .{ name, c.path });
            assertsSemanticRoundTrip(allocator, name, "map add under", c.path, &doc, out, failures);
        } else {
            if (seq_budget == 0) {
                stats.capped_containers += 1;
                continue;
            }
            seq_budget -= 1;
            stats.seq_appends += 1;
            var doc = try yaml.parse(allocator, input);
            defer doc.deinit();
            var ed = yaml.edit.Editor.init(&doc);
            ed.apply(&.{.{ .append = .{ .sequence = c.path, .value = try doc.createScalar("added", .plain) } }}) catch |err| {
                failures.add("{s}: seq append to {s} failed: {s}", .{ name, c.path, @errorName(err) });
                continue;
            };
            const out = try doc.write(allocator);
            defer allocator.free(out);
            const out_lines = try splitLines(allocator, out);
            defer allocator.free(out_lines);
            if (pureInsertion(orig_lines, out_lines) == null) {
                failures.add("{s}: seq append to {s}: not a pure line insertion", .{ name, c.path });
            }
            assertsSemanticRoundTrip(allocator, name, "seq append to", c.path, &doc, out, failures);
        }
    }

    // INSERT sweep: a new item spliced before an existing one, at
    // every addressable position of every block sequence. Like the
    // append sweep it must be a pure line insertion — and like every
    // sweep the re-parsed output must equal the edited document, with
    // the new item resolvable at the exact position it was given.
    for (targets) |t| {
        if (t.props_preamble) {
            stats.skipped_props_preamble += 1;
            continue;
        }
        if (t.tab_span) {
            stats.skipped_tab_span += 1;
            continue;
        }
        if (t.unsupported) {
            stats.skipped_unsupported += 1;
            continue;
        }
        if (is_crlf) {
            // Splicing a line writes a bare LF for it on a CRLF file.
            stats.skipped_crlf += 1;
            continue;
        }
        const seq_path = sequenceParentOf(t.path) orelse continue;
        var parent: ?Container = null;
        for (found.containers.items) |c| {
            if (std.mem.eql(u8, c.path, seq_path)) {
                parent = c;
                break;
            }
        }
        const pc = parent orelse {
            failures.add("{s}: insert before {s}: the parent sequence was not discovered", .{ name, t.path });
            continue;
        };
        if (pc.is_flow) {
            stats.skipped_flow += 1;
            continue;
        }
        if (!pc.non_empty) {
            stats.skipped_empty += 1;
            continue;
        }
        stats.inserts += 1;
        var doc = try yaml.parse(allocator, input);
        defer doc.deinit();
        var ed = yaml.edit.Editor.init(&doc);
        ed.apply(&.{.{ .insert = .{
            .sequence = seq_path,
            .position = t.path,
            .value = try doc.createScalar("added", .plain),
            .before = true,
        } }}) catch |err| {
            failures.add("{s}: insert before {s} failed: {s}", .{ name, t.path, @errorName(err) });
            continue;
        };
        const out = try doc.write(allocator);
        defer allocator.free(out);
        const out_lines = try splitLines(allocator, out);
        defer allocator.free(out_lines);
        const at = pureInsertionReframed(orig_lines, out_lines) orelse {
            failures.add("{s}: insert before {s}: not a pure line insertion", .{ name, t.path });
            continue;
        };
        if (out_lines.len - orig_lines.len != 1 or std.mem.indexOf(u8, out_lines[at], "added") == null) {
            failures.add("{s}: insert before {s}: the inserted lines do not carry the new item", .{ name, t.path });
            continue;
        }
        assertsSemanticRoundTrip(allocator, name, "insert before", t.path, &doc, out, failures);
        var re = yaml.parse(allocator, out) catch continue;
        defer re.deinit();
        var re_ed = yaml.edit.Editor.init(&re);
        const inserted = re_ed.one(t.path) catch {
            failures.add("{s}: insert before {s}: the new item does not resolve at its position", .{ name, t.path });
            continue;
        };
        if (!std.mem.eql(u8, inserted.scalarValue() orelse "", "added")) {
            failures.add("{s}: insert before {s}: the item at the position is not the inserted scalar", .{ name, t.path });
        }
    }

    // MOVE sweep. Moves had almost no coverage: the operation where the
    // emitter knows LEAST, because `move` clears the node's span and the
    // destination layout is entirely the emitter's choice.
    //
    // Byte-level assertions do not apply. A moved subtree re-emits in
    // block layout at the destination, so its BYTES legitimately differ
    // from the source's; what must not differ is its meaning. So the
    // invariants here are semantic:
    //   - the output is valid YAML;
    //   - the subtree's value tree at its new path equals what it was;
    //   - the old path no longer resolves;
    //   - the document's total leaf count is unchanged, so nothing was
    //     lost or duplicated anywhere else.
    //
    // The cross product of targets and destinations is quadratic, so it
    // is capped per fixture. The cap is counted, never silent.
    {
        const max_dests_per_target = limits.max_move_dests_per_target;
        for (targets) |t| {
            if (t.move_unsafe) {
                stats.skipped_move_related += 1;
                continue;
            }
            var used: usize = 0;
            for (found.containers.items) |c| {
                if (used >= max_dests_per_target) break;
                // Block mapping destinations only: a flow destination
                // normalizes by design, and a sequence destination takes
                // no key so two moves there are indistinguishable.
                if (!c.is_mapping or c.is_flow or !c.non_empty) {
                    stats.skipped_move_dest += 1;
                    continue;
                }
                if (pathRelated(c.path, t.path)) {
                    stats.skipped_move_related += 1;
                    continue;
                }
                if (t.props_preamble or c.props_preamble) {
                    stats.skipped_props_preamble += 1;
                    continue;
                }
                if (t.tab_span or c.tab_span) {
                    stats.skipped_tab_span += 1;
                    continue;
                }
                if (t.unsupported or c.unsupported) {
                    stats.skipped_unsupported += 1;
                    continue;
                }
                used += 1;
                stats.moves += 1;

                // Parse once before and once after emission. The edited
                // document itself is the semantic oracle: comparing the
                // re-parsed output with it proves the exact move without
                // assuming aliases leave the document's leaf count fixed.
                var doc = try yaml.parse(allocator, input);
                defer doc.deinit();
                var ed = yaml.edit.Editor.init(&doc);
                const src_node = ed.one(t.path) catch continue;
                const v_src = yaml.value.nodeToValue(allocator, src_node) catch continue;
                defer yaml.value.freeValue(allocator, v_src);
                ed.apply(&.{.{ .move = .{ .from = t.path, .to = c.path, .key = "zz_moved" } }}) catch |err| {
                    failures.add("{s}: move {s} -> {s} failed: {s}", .{ name, t.path, c.path, @errorName(err) });
                    continue;
                };
                const v_expected = yaml.value.nodeToValue(allocator, doc.root.?) catch continue;
                defer yaml.value.freeValue(allocator, v_expected);
                const out = try doc.write(allocator);
                defer allocator.free(out);

                var after = yaml.parse(allocator, out) catch {
                    failures.add("{s}: move {s} -> {s}: emitted output is not valid YAML", .{ name, t.path, c.path });
                    continue;
                };
                defer after.deinit();
                const v_after = yaml.value.nodeToValue(allocator, after.root.?) catch continue;
                defer yaml.value.freeValue(allocator, v_after);
                if (!valueEql(v_expected, v_after)) {
                    failures.add("{s}: move {s} -> {s}: output value tree differs from the edited document", .{ name, t.path, c.path });
                }

                var ed_after = yaml.edit.Editor.init(&after);
                const adjusted_dest = try moveDestinationAfterDetach(allocator, t.path, c.path);
                defer allocator.free(adjusted_dest);
                const dest_path = try std.fmt.allocPrint(allocator, "{s}.zz_moved", .{adjusted_dest});
                defer allocator.free(dest_path);
                const moved = ed_after.one(dest_path) catch {
                    failures.add("{s}: move {s} -> {s}: the moved node is not at its destination", .{ name, t.path, c.path });
                    continue;
                };
                const v_moved = yaml.value.nodeToValue(allocator, moved) catch continue;
                defer yaml.value.freeValue(allocator, v_moved);
                if (!valueEql(v_src, v_moved)) {
                    failures.add("{s}: move {s} -> {s}: the subtree's value changed in transit", .{ name, t.path, c.path });
                }
                // A key path must disappear. An index can resolve again
                // because later sequence items shift into the vacant slot.
                if (!std.mem.endsWith(u8, t.path, "]")) {
                    if (ed_after.one(t.path)) |_| {
                        failures.add("{s}: move {s} -> {s}: the source path still resolves", .{ name, t.path, c.path });
                    } else |_| {}
                }
            }
        }
    }

    // ROLLBACK: a batch whose later edit fails must leave the fixture
    // byte-identical.
    {
        stats.rollbacks += 1;
        var doc = try yaml.parse(allocator, input);
        defer doc.deinit();
        var ed = yaml.edit.Editor.init(&doc);
        const batch = [_]yaml.edit.Edit{
            .{ .set = .{ .path = "$.zz_probe.deep", .value = try doc.createScalar("x", .plain) } },
            .{ .move = .{ .from = "$.zz_no_such_subtree", .to = "$" } },
        };
        if (ed.apply(&batch)) |_| {
            failures.add("{s}: an invalid batch unexpectedly succeeded", .{name});
        } else |_| {}
        const out = try doc.write(allocator);
        defer allocator.free(out);
        if (!std.mem.eql(u8, out, input)) {
            failures.add("{s}: failed batch did not roll back byte-identically", .{name});
        }
    }
}

/// Weak invariant for every edit, regardless of documented
/// normalizations: the emitter must not emit invalid YAML.
fn assertsReparse(allocator: std.mem.Allocator, name: []const u8, what: []const u8, out: []const u8, failures: *Failures) void {
    var re = yaml.parse(allocator, out) catch {
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
        .null => return true,
        .bool => |v| return v == b.bool,
        .int => |v| return v == b.int,
        .bigint => |s| return std.mem.eql(u8, s, b.bigint),
        .float => |v| return v == b.float or (std.math.isNan(v) and std.math.isNan(b.float)),
        .string => |s| return std.mem.eql(u8, s, b.string),
        .sequence => |items| {
            if (items.len != b.sequence.len) return false;
            for (items, b.sequence) |x, y| {
                if (!valueEql(x, y)) return false;
            }
            return true;
        },
        .mapping => |members| {
            if (members.len != b.mapping.len) return false;
            for (members) |m| {
                const other = b.get(m.key) orelse return false;
                if (!valueEql(m.value, other)) return false;
            }
            return true;
        },
    }
}

/// True when `outer` addresses `inner` or an ancestor of it, comparing
/// the rendered paths segment-wise. Moving a node into its own subtree
/// is rejected by the editor (`MoveIntoSubtree`); this keeps the sweep
/// from spending cases on edits that cannot succeed.
fn pathRelated(outer: []const u8, inner: []const u8) bool {
    if (std.mem.eql(u8, outer, inner)) return true;
    if (outer.len < inner.len) {
        // `$.a` is a prefix of `$.a.b` and of `$.a[0]`, but not of `$.ab`.
        if (!std.mem.startsWith(u8, inner, outer)) return false;
        const next = inner[outer.len];
        return next == '.' or next == '[';
    }
    if (!std.mem.startsWith(u8, outer, inner)) return false;
    const next = outer[inner.len];
    return next == '.' or next == '[';
}

/// A move that removes a direct sequence item shifts every later
/// sibling down by one. Adjust the destination path used to find the
/// inserted key after re-parsing; the editor resolved the destination
/// pointer before detaching, so the operation itself already hit the
/// intended container.
fn moveDestinationAfterDetach(allocator: std.mem.Allocator, from: []const u8, to: []const u8) ![]const u8 {
    const source_open = std.mem.lastIndexOfScalar(u8, from, '[') orelse return allocator.dupe(u8, to);
    if (from.len == 0 or from[from.len - 1] != ']') return allocator.dupe(u8, to);
    const source_index = std.fmt.parseInt(usize, from[source_open + 1 .. from.len - 1], 10) catch return allocator.dupe(u8, to);
    const parent = from[0..source_open];
    if (!std.mem.startsWith(u8, to, parent)) return allocator.dupe(u8, to);
    const rest = to[parent.len..];
    if (rest.len < 3 or rest[0] != '[') return allocator.dupe(u8, to);
    const dest_close = std.mem.indexOfScalar(u8, rest, ']') orelse return allocator.dupe(u8, to);
    const dest_index = std.fmt.parseInt(usize, rest[1..dest_close], 10) catch return allocator.dupe(u8, to);
    if (dest_index <= source_index) return allocator.dupe(u8, to);
    return std.fmt.allocPrint(allocator, "{s}[{d}]{s}", .{ parent, dest_index - 1, rest[dest_close + 1 ..] });
}

fn valueIsEmptySlot(v: yaml.value.Value) bool {
    return switch (v) {
        .sequence => |l| l.len == 0,
        .mapping => |m| m.len == 0,
        else => false,
    };
}

/// `vout` is `vin` with the entry at `segs` removed: everything else
/// unchanged, in order; the slot itself empty (sole child) or absent.
fn valueMinusEql(vin: yaml.value.Value, vout: yaml.value.Value, segs: []const yaml.edit.Segment) bool {
    if (segs.len == 0) return false; // root deletion is not swept
    switch (segs[0]) {
        .key => |k| {
            if (vin != .mapping or vout != .mapping) return false;
            if (segs.len == 1) {
                if (vin.get(k) == null) return false; // target must exist
                if (vout.get(k) != null) return false; // and be gone
                var j: usize = 0;
                for (vin.mapping) |m| {
                    if (std.mem.eql(u8, m.key, k)) continue;
                    if (j >= vout.mapping.len) return false;
                    if (!std.mem.eql(u8, m.key, vout.mapping[j].key)) return false;
                    if (!valueEql(m.value, vout.mapping[j].value)) return false;
                    j += 1;
                }
                return j == vout.mapping.len;
            }
            return valueMinusEql(vin.get(k) orelse return false, vout.get(k) orelse return false, segs[1..]);
        },
        .index => |ix| {
            if (vin != .sequence) return false;
            if (ix >= vin.sequence.len) return false;
            if (segs.len == 1) {
                if (vout != .sequence) return false;
                if (vout.sequence.len != vin.sequence.len - 1) return false;
                for (0..ix) |i| {
                    if (!valueEql(vin.sequence[i], vout.sequence[i])) return false;
                }
                for (ix..vout.sequence.len) |i| {
                    if (!valueEql(vin.sequence[i + 1], vout.sequence[i])) return false;
                }
                return true;
            }
            if (vout != .sequence or ix >= vout.sequence.len) return false;
            return valueMinusEql(vin.sequence[ix], vout.sequence[ix], segs[1..]);
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
            if (vin != .mapping or vout != .mapping) return false;
            if (segs.len == 1) {
                const sentinel_value: yaml.value.Value = .{ .string = sentinel_text };
                var ia: usize = 0;
                var ib: usize = 0;
                var seen_target = false;
                while (ia < vin.mapping.len or ib < vout.mapping.len) {
                    const a_ok = ia < vin.mapping.len;
                    const b_ok = ib < vout.mapping.len;
                    if (a_ok and std.mem.eql(u8, vin.mapping[ia].key, k)) {
                        // Existed: replaced in place, position kept.
                        if (!b_ok or !std.mem.eql(u8, vout.mapping[ib].key, k)) return false;
                        if (!valueEql(vout.mapping[ib].value, sentinel_value)) return false;
                        seen_target = true;
                        ia += 1;
                        ib += 1;
                    } else if (b_ok and std.mem.eql(u8, vout.mapping[ib].key, k)) {
                        // New key: appended at the end only.
                        if (a_ok) return false;
                        if (!valueEql(vout.mapping[ib].value, sentinel_value)) return false;
                        seen_target = true;
                        ib += 1;
                    } else {
                        if (!a_ok or !b_ok) return false;
                        if (!std.mem.eql(u8, vin.mapping[ia].key, vout.mapping[ib].key)) return false;
                        if (!valueEql(vin.mapping[ia].value, vout.mapping[ib].value)) return false;
                        ia += 1;
                        ib += 1;
                    }
                }
                return seen_target;
            }
            return valueSetEql(vin.get(k) orelse return false, vout.get(k) orelse return false, segs[1..], sentinel_text);
        },
        .index => |ix| {
            if (vin != .sequence or vout != .sequence) return false;
            if (ix >= vin.sequence.len or ix >= vout.sequence.len) return false;
            return valueSetEql(vin.sequence[ix], vout.sequence[ix], segs[1..], sentinel_text);
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
    const allocator = da.allocator();
    // The sole-child delete repro: the emptied container normalizes,
    // but the `{}` must stay the VALUE of its key.
    {
        var doc = try yaml.parse(allocator, "src:\n  item: 1\ndest: 2\n");
        defer doc.deinit();
        var ed = yaml.edit.Editor.init(&doc);
        try ed.apply(&.{.{ .delete = "$.src.item" }});
        const out = try doc.write(allocator);
        defer allocator.free(out);
        var re = try yaml.parse(allocator, out); // must re-parse
        defer re.deinit();
        try std.testing.expectEqualStrings("2", re.pathGet(&.{"dest"}).?.scalarValue().?);
    }
    // Sole child of a sequence.
    {
        var doc = try yaml.parse(allocator, "top:\n  - only\ndest: 2\n");
        defer doc.deinit();
        var ed = yaml.edit.Editor.init(&doc);
        try ed.apply(&.{.{ .delete = "$.top[0]" }});
        const out = try doc.write(allocator);
        defer allocator.free(out);
        var re = try yaml.parse(allocator, out);
        defer re.deinit();
        try std.testing.expectEqualStrings("2", re.pathGet(&.{"dest"}).?.scalarValue().?);
    }
    // Moving a nested container's first child away must not disturb
    // the surviving sibling's indentation.
    {
        var doc = try yaml.parse(allocator, "src:\n  item:\n    a: 1\n    b: 2\n  keep: k\ndst: {}\n");
        defer doc.deinit();
        var ed = yaml.edit.Editor.init(&doc);
        try ed.apply(&.{.{ .move = .{ .from = "$.src.item", .to = "$.dst", .key = "moved" } }});
        const out = try doc.write(allocator);
        defer allocator.free(out);
        var re = try yaml.parse(allocator, out);
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
    const allocator = da.allocator();
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    {
        var dir = try std.Io.Dir.cwd().openDir(io, fixtures_dir, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".yaml") and !std.mem.endsWith(u8, entry.name, ".yml")) continue;
            if (std.mem.eql(u8, entry.name, multidoc_fixture)) continue; // own test below
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    if (names.items.len < 10) return error.TestUnexpectedResult; // fixtures missing

    var failures: Failures = .{ .allocator = allocator };
    defer {
        for (failures.list.items) |f| allocator.free(f);
        failures.list.deinit(allocator);
    }
    var stats: Stats = .{};

    var dir = try std.Io.Dir.cwd().openDir(io, fixtures_dir, .{});
    defer dir.close(io);
    for (names.items) |name| {
        const input = try dir.readFileAlloc(io, name, allocator, .limited(4 << 20));
        defer allocator.free(input);
        try sweepFixture(allocator, name, input, &failures, &stats, .{});
    }

    printSummary("fixtures", "fixtures", names.items.len, stats);
    // The wider sweeps must actually run: same-value sets, inserts and
    // moves each cover real positions in the fixture set, and every
    // fixture is accounted for.
    try std.testing.expect(stats.same_sets > 0);
    try std.testing.expect(stats.inserts > 0);
    try std.testing.expect(stats.moves > 0);
    try std.testing.expectEqual(names.items.len, stats.documents + stats.skipped_no_root + stats.skipped_roundtrip_unstable + stats.skipped_bom);
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
    const allocator = da.allocator();
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const input = try std.Io.Dir.cwd().readFileAlloc(io, fixtures_dir ++ "/" ++ multidoc_fixture, allocator, .limited(4 << 20));
    defer allocator.free(input);

    var docs = try yaml.parseAll(allocator, input);
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(allocator);
    }
    if (docs.items.len < 2) return error.TestUnexpectedResult;
    const mid = docs.items.len / 2;
    const doc_mid = &docs.items[mid];

    // First addressable scalar leaf of the middle document.
    var ed = yaml.edit.Editor.init(doc_mid);
    var comps: std.ArrayList(Comp) = .empty;
    defer comps.deinit(allocator);
    var path: ?[]const u8 = null;
    findFirstScalar(&ed, doc_mid.root.?, &comps, &path, 0);
    const edit_path = path orelse return error.TestUnexpectedResult;
    defer allocator.free(edit_path);

    try ed.set(edit_path, try doc_mid.createScalar(sentinel, .plain));

    // Concatenate every document's bytes; only the middle document's
    // region may differ.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (docs.items) |*d| {
        const text = try d.write(allocator);
        defer allocator.free(text);
        try out.appendSlice(allocator, text);
    }

    const region = docs.items[mid];
    try std.testing.expect(std.mem.startsWith(u8, out.items, input[0..region.region_start]));
    try std.testing.expect(std.mem.endsWith(u8, out.items, input[region.region_end..]));

    // The other documents re-emit to exactly their original bytes.
    var fresh = try yaml.parseAll(allocator, input);
    defer {
        for (fresh.items) |*d| d.deinit();
        fresh.deinit(allocator);
    }
    for (docs.items, fresh.items, 0..) |*d, *f, i| {
        if (i == mid) continue;
        const a = try d.write(allocator);
        defer allocator.free(a);
        const b = try f.write(allocator);
        defer allocator.free(b);
        try std.testing.expectEqualStrings(b, a);
    }
}

fn findFirstScalar(ed: *yaml.edit.Editor, node: *yaml.Node, comps: *std.ArrayList(Comp), out: *?[]const u8, depth: usize) void {
    if (out.* != null or depth > 24) return;
    switch (node.data) {
        .scalar => {
            const p = formatPath(ed.doc.allocator, comps.items) catch return;
            // Keep it only if the editor can resolve it back.
            if (ed.one(p)) |_| {
                out.* = p;
            } else |_| {
                ed.doc.allocator.free(p);
            }
        },
        .mapping => |m| {
            for (m.pairs.items) |pair| {
                if (out.* != null) return;
                const key = pair.key.scalarValue() orelse continue;
                comps.append(ed.doc.allocator, .{ .key = key }) catch return;
                findFirstScalar(ed, pair.value, comps, out, depth + 1);
                _ = comps.pop();
            }
        },
        .sequence => |s| {
            for (s.items.items, 0..) |item, i| {
                if (out.* != null) return;
                comps.append(ed.doc.allocator, .{ .index = i }) catch return;
                findFirstScalar(ed, item, comps, out, depth + 1);
                _ = comps.pop();
            }
        },
        .alias => {},
    }
}

test "preservation sweep: bounded edits over every valid corpus document" {
    // Leak-checking allocator WITHOUT per-allocation stack traces (see
    // the fixture sweep above for the cost arithmetic).
    var da: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer std.debug.assert(da.deinit() == .ok);
    const allocator = da.allocator();
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cases: std.ArrayList(corpus.Case) = .empty;
    defer {
        for (cases.items) |*c| corpus.freeCase(allocator, c);
        cases.deinit(allocator);
    }
    try corpus.loadCases(allocator, io, &cases);

    var valid: usize = 0;
    for (cases.items) |*c| {
        if (!c.fail) valid += 1;
    }
    // The whole yaml-test-suite corpus: the 269 valid documents the
    // round-trip and conformance gates cover — here under edits.
    try std.testing.expectEqual(@as(usize, 269), valid);

    var failures: Failures = .{ .allocator = allocator };
    defer {
        for (failures.list.items) |f| allocator.free(f);
        failures.list.deinit(allocator);
    }
    var stats: Stats = .{};

    // Bounded but real edits per document: one mapping and one
    // sequence position, one container of each kind, one move
    // destination. Every assertion is the FULL one — the same
    // `sweepFixture` the fixtures get, not a weaker corpus-specific
    // form; the caps are reported in the summary, never silent.
    const smoke: SweepLimits = .{
        .max_targets = 1,
        .max_mappings = 1,
        .max_sequences = 1,
        .max_move_dests_per_target = 1,
    };
    for (cases.items) |*c| {
        if (c.fail) continue;
        try sweepFixture(allocator, c.id, c.input, &failures, &stats, smoke);
    }

    // Every valid document accounted for: edited, root-less, or one of
    // the documented round-trip-unstable shapes.
    try std.testing.expectEqual(@as(usize, 269), stats.documents + stats.skipped_no_root + stats.skipped_roundtrip_unstable + stats.skipped_bom);
    // The bounded sweep must still exercise every operation kind.
    try std.testing.expect(stats.deletes > 0);
    try std.testing.expect(stats.sets > 0);
    try std.testing.expect(stats.same_sets > 0);
    try std.testing.expect(stats.inserts > 0);
    try std.testing.expect(stats.moves > 0);
    printSummary("corpus", "cases", valid, stats);
    if (failures.list.items.len > 0) {
        for (failures.list.items) |f| std.debug.print("  PRESERVATION-FAIL {s}\n", .{f});
        return error.TestUnexpectedResult;
    }
}

test "preservation sweep: CRLF, BOM and no-final-newline fixture variants" {
    var da: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer std.debug.assert(da.deinit() == .ok);
    const allocator = da.allocator();
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Every fixture filename, INCLUDING the multi-document stream.
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    {
        var dir = try std.Io.Dir.cwd().openDir(io, fixtures_dir, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".yaml") and !std.mem.endsWith(u8, entry.name, ".yml")) continue;
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    if (names.items.len < 10) return error.TestUnexpectedResult; // fixtures missing

    var failures: Failures = .{ .allocator = allocator };
    defer {
        for (failures.list.items) |f| allocator.free(f);
        failures.list.deinit(allocator);
    }
    var stats: Stats = .{};
    const smoke: SweepLimits = .{
        .max_targets = 1,
        .max_mappings = 1,
        .max_sequences = 1,
        .max_move_dests_per_target = 1,
    };

    var attempted: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(io, fixtures_dir, .{});
    defer dir.close(io);
    for (names.items) |name| {
        const raw = try dir.readFileAlloc(io, name, allocator, .limited(4 << 20));
        defer allocator.free(raw);
        // sweepFixture restricts a multi-document stream to its first
        // document's region itself; every fixture is passed whole.
        const input = raw;
        // Three variants derived in memory — no new fixture files.
        const crlf = try replaceByte(allocator, input, '\n', "\r\n");
        defer allocator.free(crlf);
        const bom = try std.fmt.allocPrint(allocator, "\xEF\xBB\xBF{s}", .{input});
        defer allocator.free(bom);
        const nofinal = if (std.mem.endsWith(u8, input, "\n"))
            try allocator.dupe(u8, input[0 .. input.len - 1])
        else
            try allocator.dupe(u8, input);
        defer allocator.free(nofinal);
        const variants = [_]struct { label: []const u8, bytes: []const u8 }{
            .{ .label = "crlf", .bytes = crlf },
            .{ .label = "bom", .bytes = bom },
            .{ .label = "no-final-newline", .bytes = nofinal },
        };
        for (variants) |v| {
            attempted += 1;
            const label = try std.fmt.allocPrint(allocator, "{s}[{s}]", .{ name, v.label });
            defer allocator.free(label);
            try sweepFixture(allocator, label, v.bytes, &failures, &stats, smoke);
        }
    }

    // No silent omission: every fixture contributed exactly its three
    // variants, every variant parsed (or is counted as root-less), and
    // the bounded sweeps still exercised the no-op, insert and move
    // paths.
    try std.testing.expectEqual(names.items.len * 3, attempted);
    try std.testing.expectEqual(attempted, stats.documents + stats.skipped_no_root + stats.skipped_roundtrip_unstable + stats.skipped_bom);
    try std.testing.expect(stats.same_sets > 0);
    try std.testing.expect(stats.inserts > 0);
    try std.testing.expect(stats.moves > 0);
    printSummary("variants", "variants", attempted, stats);
    if (failures.list.items.len > 0) {
        for (failures.list.items) |f| std.debug.print("  PRESERVATION-FAIL {s}\n", .{f});
        return error.TestUnexpectedResult;
    }
}

test "preservation: deleting two siblings composes identically in either order" {
    var da: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer std.debug.assert(da.deinit() == .ok);
    const allocator = da.allocator();

    const input = "a: 1\nb: 2\nc: 3\n";
    const orders = [_][2][]const u8{
        .{ "$.a", "$.b" }, // document order
        .{ "$.b", "$.a" }, // reverse order
    };
    var outs: std.ArrayList([]u8) = .empty;
    defer {
        for (outs.items) |o| allocator.free(o);
        outs.deinit(allocator);
    }
    for (orders) |order| {
        var doc = try yaml.parse(allocator, input);
        defer doc.deinit();
        var ed = yaml.edit.Editor.init(&doc);
        try ed.apply(&.{ .{ .delete = order[0] }, .{ .delete = order[1] } });
        try outs.append(allocator, try doc.write(allocator));
    }
    // Order-independent bytes.
    try std.testing.expectEqualStrings(outs.items[0], outs.items[1]);

    // And order-independent meaning: exactly `c: 3` survives.
    const expected: yaml.value.Value = .{ .mapping = &[_]yaml.value.Value.Pair{
        .{ .key = "c", .value = .{ .int = 3 } },
    } };
    for (outs.items) |o| {
        var re = try yaml.parse(allocator, o);
        defer re.deinit();
        const v = try yaml.value.nodeToValue(allocator, re.root.?);
        defer yaml.value.freeValue(allocator, v);
        try std.testing.expect(valueEql(expected, v));
    }

    // A seeded permutation over a larger sibling set: delete k1..k6 in
    // a seeded shuffled order; the survivors (k7, k8, in order) are
    // the same for every seed. Deterministic: a failure names no
    // mystery input, and re-running reproduces it.
    const eight = "k1: 1\nk2: 2\nk3: 3\nk4: 4\nk5: 5\nk6: 6\nk7: 7\nk8: 8\n";
    var seed: u32 = 0;
    while (seed < 8) : (seed += 1) {
        var keys: [6][]const u8 = .{ "$.k1", "$.k2", "$.k3", "$.k4", "$.k5", "$.k6" };
        var order: [6][]const u8 = undefined;
        var state: u32 = seed *% 2654435761 +% 1;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            state = state *% 1664525 +% 1013904223;
            const pick: usize = @intCast(state % @as(u32, @intCast(6 - i)));
            order[i] = keys[i + pick];
            keys[i + pick] = keys[i];
        }
        var doc = try yaml.parse(allocator, eight);
        defer doc.deinit();
        var ed = yaml.edit.Editor.init(&doc);
        try ed.apply(&.{
            .{ .delete = order[0] }, .{ .delete = order[1] }, .{ .delete = order[2] },
            .{ .delete = order[3] }, .{ .delete = order[4] }, .{ .delete = order[5] },
        });
        const out = try doc.write(allocator);
        defer allocator.free(out);
        var re = try yaml.parse(allocator, out);
        defer re.deinit();
        try std.testing.expectEqual(@as(usize, 2), re.root.?.pairs().?.len);
        try std.testing.expectEqualStrings("7", re.pathGet(&.{"k7"}).?.scalarValue().?);
        try std.testing.expectEqualStrings("8", re.pathGet(&.{"k8"}).?.scalarValue().?);
    }
}
