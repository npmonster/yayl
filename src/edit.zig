//! High-level editing API.
//!
//! A path query engine and atomic edit operations layered on the
//! document model. Paths use a small, documented grammar (see `Path`):
//!
//!     $.store.book[0].title      map keys and sequence indices
//!     $.items[*].name            wildcard (every item)
//!     $..id                      recursive descent (every depth)
//!     $.servers[?role=edge]      equality filter over mapping items
//!
//! Query results are deterministic: document order, wildcards and
//! recursion yield in encounter order.
//!
//! All edits run through `Editor`. A batch (`apply`) edits the tree in
//! place and records every change in an undo journal; a failure
//! (unknown path, OOM, cycle) rolls the journal back, leaving the
//! document byte-identical, including its round-trip spans.

const std = @import("std");
const document_mod = @import("document.zig");
const emitter_mod = @import("emitter.zig");
const internal = @import("internal.zig");

const Document = document_mod.Document;
const Node = document_mod.Node;

/// Editing failures: `UnknownPath` covers queries that match nothing,
/// and `AmbiguousOperation` a path that must name one node (`one`, and
/// the targets of `set`, `insert`, `append` and `move`) but matches
/// several; the `NotA*` errors describe a value whose shape does not
/// fit the edit; `MoveIntoSubtree` rejects moving a node into its own
/// subtree. `AnchorReferenced` refuses an edit that would strand an
/// alias, and `AnchorShadowed` one after which an alias would bind to a
/// different definition once written and read back (see
/// `Document.setAnchor`).
pub const Error = error{
    InvalidPath,
    InvalidSyntax,
    UnknownPath,
    NotACollection,
    NotASequence,
    NotAMapping,
    AmbiguousOperation,
    MoveIntoSubtree,
    NestingTooDeep,
    WouldCycle,
    AnchorReferenced,
    AnchorShadowed,
    AliasPath,
    OutOfMemory,
};

/// Errors a structural clone can actually return. Narrower than
/// `Error`: cloning copies a tree, it never resolves a path, so the
/// path and query errors cannot occur. Exposed so `document.zig` can
/// call `cloneTree` without widening its own public error set.
pub const CloneError = error{
    NestingTooDeep,
    InvalidSyntax,
    OutOfMemory,
};

/// Refuse a MUTATION whose container is an alias node.
///
/// Reads forward through aliases — `lookup`, `pathGet` and `Editor.one`
/// all resolve — and `docs/USAGE.md` says so. Writes did not, but failed
/// dishonestly: `mappingReplace`/`mappingRemove` switch on the node's
/// own `.data`, hit `.alias`, and the caller turned that into
/// `error.InvalidSyntax` (which blames the path) or, for delete, into a
/// no-op that reported SUCCESS while changing nothing.
///
/// Refusing with a typed error keeps reads and writes honest about
/// disagreeing. Editing the shared target through the anchor side works
/// and is the supported route; whether writes should forward through an
/// alias the way reads do is a semantic decision, not something to
/// settle by accident. An alias EARLIER in the path is refused by
/// `resolveForWrite`: this checks the container the write lands in.
fn refuseAliasContainer(container: *const Node) Error!void {
    if (container.data == .alias) return error.AliasPath;
}

/// Deepest node nesting the recursive edit walks will follow before
/// returning `error.NestingTooDeep`. Matches `value.Limits.max_depth`,
/// `schema.Limits.max_depth` and `Emitter.max_depth`.
///
/// Two distinct things reach it. A document built through
/// `createSequence`/`sequenceAppend` can nest arbitrarily deep, as it
/// can for conversion and emission. But `..key` descent also follows
/// aliases, and an alias may point at an *enclosing* anchor: `&a [*a]`
/// is eight bytes, parses, and describes a cycle of infinite depth.
/// Nothing rejects that at parse time, so the bound is what stops the
/// walk — for parsed input as much as for built trees.
const max_walk_depth: usize = 1000;

/// One parsed path segment.
pub const Segment = union(enum) {
    /// Map key lookup (also matches sequence item textual keys).
    key: []const u8,
    /// Sequence index.
    index: usize,
    /// Every child, in document order.
    wildcard,
    /// Every descendant matching `inner`, at every depth (recursive
    /// descent, `..name`).
    descend: []const u8,
    /// Every child that is a mapping whose `key` equals `value`. Applies
    /// to both sequence entries and mapping values.
    filter: struct { key: []const u8, value: []const u8 },
};

/// A parsed path. Parse with `Path.parse` (grammar in the module docs).
/// `$` at the start is optional and denotes the root when a `.` or `[`
/// (or nothing) follows it; otherwise it begins a key (`$ref`).
pub const Path = struct {
    segments: []const Segment,

    /// Parse `input` into a `Path`. Caller owns the result; `deinit` it.
    pub fn parse(allocator: std.mem.Allocator, input: []const u8) Error!Path {
        var segments: std.ArrayList(Segment) = .empty;
        errdefer segments.deinit(allocator);

        var i: usize = 0;
        // Optional root marker -- only where a segment or nothing follows:
        // `$ref` and `$schema` are ordinary keys (OpenAPI and JSON Schema
        // are full of them), and reading the `$` as the root made
        // `delete("$ref")` delete the key `ref` instead.
        if (input.len > 0 and input[0] == '$' and (input.len == 1 or input[1] == '.' or input[1] == '[')) i = 1;

        while (i < input.len) {
            const c = input[i];
            if (c == '.') {
                i += 1;
                if (i < input.len and input[i] == '.') {
                    // Recursive descent: `..name`.
                    i += 1;
                    const start = i;
                    while (i < input.len and input[i] != '.' and input[i] != '[') i += 1;
                    if (i == start) return error.InvalidPath;
                    try segments.append(allocator, .{ .descend = input[start..i] });
                    continue;
                }
                const start = i;
                while (i < input.len and input[i] != '.' and input[i] != '[') i += 1;
                if (i == start) return error.InvalidPath;
                try segments.append(allocator, .{ .key = input[start..i] });
            } else if (c == '[') {
                i += 1;
                if (i >= input.len) return error.InvalidPath;
                if (input[i] == '*') {
                    i += 1;
                    if (i >= input.len or input[i] != ']') return error.InvalidPath;
                    i += 1;
                    try segments.append(allocator, .wildcard);
                } else if (input[i] == '?') {
                    // [?key=value]
                    i += 1;
                    const eq = std.mem.indexOfScalarPos(u8, input, i, '=') orelse return error.InvalidPath;
                    const key = input[i..eq];
                    if (key.len == 0) return error.InvalidPath;
                    const close = std.mem.indexOfScalarPos(u8, input, eq, ']') orelse return error.InvalidPath;
                    const value = input[eq + 1 .. close];
                    if (value.len == 0) return error.InvalidPath;
                    i = close + 1;
                    try segments.append(allocator, .{ .filter = .{ .key = key, .value = value } });
                } else if (std.ascii.isDigit(input[i])) {
                    const start = i;
                    while (i < input.len and std.ascii.isDigit(input[i])) i += 1;
                    if (i >= input.len or input[i] != ']') return error.InvalidPath;
                    const index = std.fmt.parseInt(usize, input[start..i], 10) catch return error.InvalidPath;
                    i += 1;
                    try segments.append(allocator, .{ .index = index });
                } else if (input[i] == '"' or input[i] == '\'') {
                    // Quoted key: `["a.b"]` or `['a.b']`. The dotted form
                    // splits on `.` and `[`, so a key containing either is
                    // otherwise unreachable — and those are the common case in
                    // this library's own target domain (k8s annotations,
                    // mkdocs `pymdownx.highlight`, GitLab `.defaults`).
                    //
                    // No escapes: a key containing BOTH quote characters stays
                    // unaddressable. Escaping would mean the segment could no
                    // longer be a slice into the input, which is what lets
                    // Path.deinit free only the segment array.
                    const quote = input[i];
                    i += 1;
                    const start = i;
                    while (i < input.len and input[i] != quote) i += 1;
                    if (i >= input.len) return error.InvalidPath;
                    const key = input[start..i];
                    i += 1; // closing quote
                    if (i >= input.len or input[i] != ']') return error.InvalidPath;
                    i += 1;
                    // An empty key is deliberately allowed: `"": v` is legal
                    // YAML and is one of the shapes the dotted form cannot
                    // address.
                    try segments.append(allocator, .{ .key = key });
                } else {
                    return error.InvalidPath;
                }
            } else {
                // Bare leading key (`a.b` without `$` or `.`), and only
                // leading: after a segment, `$.items[0]name` is not a path.
                if (i != 0) return error.InvalidPath;
                const start = i;
                while (i < input.len and input[i] != '.' and input[i] != '[') i += 1;
                try segments.append(allocator, .{ .key = input[start..i] });
            }
        }
        return .{ .segments = try segments.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: *Path, allocator: std.mem.Allocator) void {
        allocator.free(self.segments);
    }
};

/// Evaluate `path` against `root`. Results are in document order;
/// aliases are followed (bounded). Caller owns the returned slice.
pub fn resolve(allocator: std.mem.Allocator, root: *Node, path: Path) Error![]*Node {
    var via_alias = false;
    return resolveTracked(allocator, root, path, &via_alias);
}

/// `resolve`, also reporting in `via_alias` whether a match was reached
/// by stepping out of an alias into its target's entries, at any step.
/// Reads forward through aliases; a write must not, at any depth: an
/// edit at `$.b.inner.j` with `b` an alias changes the anchored node
/// every alias shares (see `resolveForWrite`).
fn resolveTracked(allocator: std.mem.Allocator, root: *Node, path: Path, via_alias: *bool) Error![]*Node {
    var results: std.ArrayList(*Node) = .empty;
    errdefer results.deinit(allocator);
    var current: std.ArrayList(*Node) = .empty;
    defer current.deinit(allocator);
    try current.append(allocator, root);

    for (path.segments) |seg| {
        var next: std.ArrayList(*Node) = .empty;
        errdefer next.deinit(allocator);
        // Aliases fan out: many nodes in `current` can resolve to one
        // target, whose children every one of them would add again --
        // a step multiplied the list by the fan-out, and a few hundred
        // bytes of aliases named more matches than memory holds. Each
        // target is expanded once per step, and a descent never walks a
        // subtree it has finished (`Descent`).
        var expanded: std.AutoHashMapUnmanaged(*const Node, void) = .empty;
        defer expanded.deinit(allocator);
        var descent: Descent = .{ .allocator = allocator, .out = &next };
        defer descent.deinit();
        for (current.items) |node| {
            if ((try expanded.getOrPut(allocator, node.resolveAlias())).found_existing) continue;
            const before = next.items.len;
            defer if (node.data == .alias and next.items.len > before) {
                via_alias.* = true;
            };
            switch (seg) {
                .key => |k| if (node.lookup(k)) |child| try next.append(allocator, child),
                .index => |ix| {
                    const items = node.items() orelse continue;
                    if (ix < items.len) try next.append(allocator, items[ix]);
                },
                .wildcard => {
                    if (node.items()) |items| {
                        for (items) |child| try next.append(allocator, child);
                    } else if (node.pairs()) |pairs| {
                        for (pairs) |p| try next.append(allocator, p.value);
                    }
                },
                .descend => |k| try descent.walk(node, k, 0),
                .filter => |f| {
                    // Sequences: every item whose mapping carries
                    // key == value. Mappings: every value that does.
                    if (node.items()) |items| {
                        for (items) |item| {
                            if (filterMatches(item, f.key, f.value)) try next.append(allocator, item);
                        }
                    } else if (node.pairs()) |ps| {
                        for (ps) |p| {
                            if (filterMatches(p.value, f.key, f.value)) try next.append(allocator, p.value);
                        }
                    }
                },
            }
        }
        if (descent.via_alias) via_alias.* = true;
        current.deinit(allocator);
        current = next;
    }
    try results.appendSlice(allocator, current.items);
    return results.toOwnedSlice(allocator);
}

/// `resolve` for a write: a match reached through an alias is refused
/// with `error.AliasPath`.
fn resolveForWrite(allocator: std.mem.Allocator, root: *Node, path: Path) Error![]*Node {
    var via_alias = false;
    const found = try resolveTracked(allocator, root, path, &via_alias);
    if (via_alias and found.len > 0) {
        allocator.free(found);
        return error.AliasPath;
    }
    return found;
}

/// The single node of `found`: `error.UnknownPath` for none,
/// `error.AmbiguousOperation` for several.
fn exactlyOne(found: []const *Node) Error!*Node {
    return switch (found.len) {
        0 => error.UnknownPath,
        1 => found[0],
        else => error.AmbiguousOperation,
    };
}

fn filterMatches(candidate: *Node, key: []const u8, value: []const u8) bool {
    const m = candidate.resolveAlias();
    const ps = m.pairs() orelse return false;
    for (ps) |p| {
        const kv = p.key.scalarValue() orelse continue;
        if (std.mem.eql(u8, kv, key)) {
            const vv = p.value.scalarValue() orelse return false;
            return std.mem.eql(u8, vv, value);
        }
    }
    return false;
}

/// Does `node` or anything under it define the anchor `name`?
///
/// By NAME, not by pointer: an anchor name is what the emitted `*name`
/// actually refers to, whatever node a hand-built alias's target pointer
/// names. Aliases are leaves here — never followed — so a parsed alias
/// cycle cannot make this recurse forever.
fn anchorDefinedIn(node: *const Node, name: []const u8, depth: usize) bool {
    if (depth >= max_walk_depth) return false;
    if (node.anchor) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    switch (node.data) {
        .mapping => |m| for (m.pairs.items) |pair| {
            if (anchorDefinedIn(pair.key, name, depth + 1)) return true;
            if (anchorDefinedIn(pair.value, name, depth + 1)) return true;
        },
        .sequence => |sq| for (sq.items.items) |item| {
            if (anchorDefinedIn(item, name, depth + 1)) return true;
        },
        else => {},
    }
    return false;
}

/// Would removing `doomed` leave an alias pointing at nothing?
///
/// An anchor lives on the node that defines it, so deleting or
/// replacing that node while `*name` survives elsewhere emits a
/// document that does not parse — `error.UnknownAlias` on the way back
/// in. That is silent corruption through a public API, so the edit is
/// refused instead. The caller can delete the aliases first, or replace
/// the anchored value rather than the node carrying the anchor.
fn aliasWouldDangle(node: *const Node, doomed: *const Node, depth: usize) bool {
    if (depth >= max_walk_depth) return false;
    // Everything inside the doomed subtree is going away together, so
    // an alias in there is not left dangling by this edit.
    if (node == doomed) return false;
    switch (node.data) {
        .alias => |a| return anchorDefinedIn(doomed, a.name, 0),
        .mapping => |m| for (m.pairs.items) |pair| {
            if (aliasWouldDangle(pair.key, doomed, depth + 1)) return true;
            if (aliasWouldDangle(pair.value, doomed, depth + 1)) return true;
        },
        .sequence => |sq| for (sq.items.items) |item| {
            if (aliasWouldDangle(item, doomed, depth + 1)) return true;
        },
        else => {},
    }
    return false;
}

/// The anchor name that `replacement` takes over from `existing`, when
/// both carry the same one -- null otherwise. Only the node's OWN anchor
/// moves; an anchor defined deeper inside a replaced subtree is still a
/// stranding.
fn anchorMovesWith(existing: *const Node, replacement: *const Node) ?[]const u8 {
    const from = existing.anchor orelse return null;
    const to = replacement.anchor orelse return null;
    return if (std.mem.eql(u8, from, to)) from else null;
}

/// Refuse an edit that removes a node an alias still needs.
fn refuseIfAnchorReferenced(doc: *Document, doomed: *const Node) Error!void {
    const root = doc.root orelse return;
    // Nothing to strand without an anchor in the doomed subtree -- the
    // common case, answered from the subtree alone. The alias scan below
    // walks the whole document, and ran for every replace and delete.
    if (!anchorIn(doomed, 0)) return;
    if (aliasWouldDangle(root, doomed, 0)) return error.AnchorReferenced;
}

/// Does `node`, or anything under it, carry an anchor? Aliases are
/// leaves; the walk never follows one. Past the depth bound it answers
/// yes, which only costs the full check.
fn anchorIn(node: *const Node, depth: usize) bool {
    if (depth >= max_walk_depth) return true;
    if (node.anchor != null) return true;
    switch (node.data) {
        .mapping => |m| for (m.pairs.items) |pair| {
            if (anchorIn(pair.key, depth + 1) or anchorIn(pair.value, depth + 1)) return true;
        },
        .sequence => |sq| for (sq.items.items) |item| {
            if (anchorIn(item, depth + 1)) return true;
        },
        else => {},
    }
    return false;
}

/// Refuse removing the mapping pair whose VALUE is `target` when an alias
/// anywhere still needs an anchor carried by EITHER the value or the key.
/// A pair is removed as a unit -- `mappingRemove` detaches both -- so an
/// anchored key strands exactly like an anchored value, and the
/// value-only guard missed it: `&k key: 1\nref: *k` with `$.key` deleted
/// emitted `ref: *k` with no `&k`, which does not reparse.
fn refuseIfPairStrandsAlias(doc: *Document, target: *const Node) Error!void {
    try refuseIfAnchorReferenced(doc, target);
    if (pairKeyOf(target)) |key| try refuseIfAnchorReferenced(doc, key);
}

/// The key node of the mapping pair whose value is `target`, or null when
/// `target` is not a mapping value.
fn pairKeyOf(target: *const Node) ?*Node {
    const parent = target.parent orelse return null;
    switch (parent.data) {
        .mapping => |m| for (m.pairs.items) |p| {
            if (p.value == target) return p.key;
        },
        else => {},
    }
    return null;
}

/// Does `node`, or anything under it, alias an anchor defined OUTSIDE
/// `subtree`? Aliases are leaves; the walk never follows one.
fn dependsOnOutsideAnchor(subtree: *const Node, node: *const Node, depth: usize) bool {
    if (depth >= max_walk_depth) return false;
    switch (node.data) {
        .alias => |a| return !anchorDefinedIn(subtree, a.name, 0),
        .mapping => |m| for (m.pairs.items) |pair| {
            if (dependsOnOutsideAnchor(subtree, pair.key, depth + 1)) return true;
            if (dependsOnOutsideAnchor(subtree, pair.value, depth + 1)) return true;
        },
        .sequence => |sq| for (sq.items.items) |item| {
            if (dependsOnOutsideAnchor(subtree, item, depth + 1)) return true;
        },
        else => {},
    }
    return false;
}

/// Refuse a move that would put an alias ahead of its anchor.
///
/// `delete` and `set` strand an alias by removing the anchor outright.
/// A move keeps it in the document, which is why this was originally
/// exempt — but an alias needs the anchor to come BEFORE it, and a move
/// only ever appends at the destination. So `- &x 1\n- *x\n` with
/// `$[0]` moved to the root emits `- *x\n- &x 1\n`, which does not
/// parse.
///
/// The test is whether an anchor/alias pair CROSSES the subtree
/// boundary, in either direction: an anchor inside referenced from
/// outside, or an alias inside whose anchor is outside. When both ends
/// travel together their relative order is preserved, so a
/// self-contained move stays allowed.
fn refuseIfMoveStrandsAlias(doc: *Document, subtree: *const Node) Error!void {
    const root = doc.root orelse return;
    if (anchorIn(subtree, 0) and aliasWouldDangle(root, subtree, 0)) return error.AnchorReferenced;
    if (dependsOnOutsideAnchor(subtree, subtree, 0)) return error.AnchorReferenced;
}

/// A `..key` walk, collecting every `key` match in pre-order into `out`.
///
/// It resolves aliases, so one node can be reached along many paths --
/// exponentially many, for aliases of aliases. A node whose subtree was
/// walked completely is not walked again: its matches are in `out`
/// already, so skipping it reports each node once, in the order of its
/// first encounter, at the cost of the document's size rather than its
/// paths. A node still being walked is not complete, so an alias to an
/// enclosing anchor (`&a {k: *a}`, a cycle of infinite depth that parses
/// fine) still descends until `max_walk_depth` and fails with
/// NestingTooDeep, rather than aborting the process on the stack.
const Descent = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(*Node),
    done: std.AutoHashMapUnmanaged(*const Node, void) = .empty,
    /// Aliases the walk is inside, and whether it matched anything there.
    alias_depth: usize = 0,
    via_alias: bool = false,

    fn deinit(self: *Descent) void {
        self.done.deinit(self.allocator);
    }

    fn walk(self: *Descent, node: *Node, key: []const u8, depth: usize) Error!void {
        if (depth >= max_walk_depth) return error.NestingTooDeep;
        const cur = node.resolveAlias();
        if (self.done.contains(cur)) return;
        const through = node.data == .alias;
        if (through) self.alias_depth += 1;
        defer if (through) {
            self.alias_depth -= 1;
        };
        if (cur.pairs()) |pairs| {
            for (pairs) |p| {
                const kv = p.key.scalarValue() orelse continue;
                if (std.mem.eql(u8, kv, key)) {
                    try self.out.append(self.allocator, p.value);
                    if (self.alias_depth > 0) self.via_alias = true;
                }
            }
            for (pairs) |p| try self.walk(p.value, key, depth + 1);
        } else if (cur.items()) |items| {
            for (items) |child| try self.walk(child, key, depth + 1);
        }
        try self.done.put(self.allocator, cur, {});
    }
};

/// Payload of `Edit.insert`: splice `value` into `sequence`, before or
/// after the (single) node matching `position`.
pub const Insert = struct { sequence: []const u8, position: []const u8, value: *Node, before: bool };

/// One queued edit. Values are existing nodes (they may be created with
/// `Document.createScalar`/`createMapping`/...); the batch takes no
/// ownership, the document pool does as usual.
pub const Edit = union(enum) {
    /// Set the (single) node at `path`. Intermediate segments walk
    /// mappings (auto-created when missing; plain keys only). The
    /// final segment addresses the entry to set: a mapping key
    /// (replaced in place, or appended when new) or a sequence index
    /// (the item at that position is replaced in place).
    ///
    /// Replacing a scalar with one of identical presentation — same
    /// value, style, anchor and tag — is a no-op: the original node
    /// keeps its place and source span, and emitted output stays
    /// byte-identical. A different style or tag is a real edit.
    set: struct { path: []const u8, value: *Node },
    /// Delete every node `path` matches: a path of keys and indices
    /// names at most one, a wildcard (`[*]`), filter (`[?k=v]`) or
    /// descent (`..k`) can name many, and each is removed. No match is
    /// not an error. All or nothing: if removing any match would strand
    /// an alias (`error.AnchorReferenced`) or a match is reached through
    /// an alias at any step (`error.AliasPath`), nothing is removed.
    delete: []const u8,
    /// Insert `value` into the sequence at `path`, before or after the
    /// (single) node at `position`.
    insert: Insert,
    /// Append `value` to the sequence at `path`.
    append: struct { sequence: []const u8, value: *Node },
    /// Move the node at `from` into the container at `to` (a mapping
    /// under `key`, or a sequence append).
    move: struct { from: []const u8, to: []const u8, key: ?[]const u8 = null },
};

/// High-level editor over one document. Every edit goes through
/// `apply`, which is atomic: a failed batch is rolled back.
pub const Editor = struct {
    doc: *Document,

    pub fn init(doc: *Document) Editor {
        return .{ .doc = doc };
    }

    /// Resolve exactly one node: `error.UnknownPath` when the path
    /// matches nothing, `error.AmbiguousOperation` when it matches
    /// several (a wildcard, filter or descent can).
    pub fn one(self: *Editor, path: []const u8) Error!*Node {
        var p = try Path.parse(self.doc.allocator, path);
        defer p.deinit(self.doc.allocator);
        const root = self.doc.root orelse return error.UnknownPath;
        const found = try resolve(self.doc.allocator, root, p);
        defer self.doc.allocator.free(found);
        return exactlyOne(found);
    }

    /// `one` for the target of a write: a node reached through an alias
    /// is refused (`error.AliasPath`).
    fn oneForWrite(self: *Editor, path: []const u8) Error!*Node {
        var p = try Path.parse(self.doc.allocator, path);
        defer p.deinit(self.doc.allocator);
        const root = self.doc.root orelse return error.UnknownPath;
        const found = try resolveForWrite(self.doc.allocator, root, p);
        defer self.doc.allocator.free(found);
        return exactlyOne(found);
    }

    /// Query convenience: every match for `path`, each node once, in
    /// the order first reached. Queries resolve aliases; the cost is
    /// bounded by the document's size, not by how many alias paths
    /// reach a node.
    pub fn all(self: *Editor, path: []const u8) Error![]*Node {
        var p = try Path.parse(self.doc.allocator, path);
        defer p.deinit(self.doc.allocator);
        const root = self.doc.root orelse return error.UnknownPath;
        return resolve(self.doc.allocator, root, p);
    }

    pub fn set(self: *Editor, path: []const u8, value: *Node) Error!void {
        return self.apply(&.{.{ .set = .{ .path = path, .value = value } }});
    }

    pub fn delete(self: *Editor, path: []const u8) Error!void {
        return self.apply(&.{.{ .delete = path }});
    }

    /// Apply every edit atomically: all of them, or none. Each change is
    /// recorded in an undo journal as it is made (`internal.Journal`),
    /// and a failed batch rolls the recorded changes back, leaving the
    /// document byte-identical. The cost is that of the edits, not of the
    /// document: this used to deep-clone the whole tree on every call.
    pub fn apply(self: *Editor, edits: []const Edit) Error!void {
        var txn: internal.Transaction = undefined;
        txn.begin(self.doc);
        errdefer txn.abort();
        var anchored = false;
        for (edits) |edit| {
            if (!anchored) anchored = self.placesAnchor(edit);
            try applyOne(self.doc, edit);
        }
        // An anchor this batch attached or moved can shadow a definition
        // the aliases after it were bound to, or stop shadowing one: the
        // written document would bind them elsewhere. Checked only then,
        // so an ordinary edit still costs what it changes.
        if (anchored) if (self.doc.root) |root| {
            if (!try internal.aliasesBindInOrder(self.doc.allocator, root, null, null)) return error.AnchorShadowed;
        };
        try txn.commit();
    }

    /// Does `edit` attach or move a subtree that carries an anchor?
    fn placesAnchor(self: *Editor, edit: Edit) bool {
        return switch (edit) {
            .set => |s| anchorIn(s.value, 0),
            .insert => |i| anchorIn(i.value, 0),
            .append => |a| anchorIn(a.value, 0),
            .move => |m| if (self.one(m.from)) |n| anchorIn(n, 0) else |_| true,
            .delete => false,
        };
    }

    fn applyOne(doc: *Document, edit: Edit) Error!void {
        var ed = Editor{ .doc = doc };
        switch (edit) {
            .set => |s| {
                // Replacing the node that CARRIES an anchor strands any
                // alias to it. A no-op set is exempt: it replaces
                // nothing, so nothing is stranded.
                //
                // Unless the replacement carries the SAME anchor: then
                // the anchor moves with the slot and the aliases follow
                // it. That is the sanctioned way to give an aliased
                // scalar a new value (see `Document.setAnchor`), and it
                // keeps the in-memory tree honest -- the aliases point
                // at the node that will be emitted under `&name`.
                if (ed.one(s.path)) |existing| {
                    if (!sameScalarPresentation(existing, s.value)) {
                        if (anchorMovesWith(existing, s.value)) |name| {
                            try doc.retargetAliases(name, s.value);
                        } else {
                            try refuseIfAnchorReferenced(doc, existing);
                        }
                    }
                } else |_| {}
                try applySet(doc, s.path, s.value);
            },
            .delete => |path| {
                // A delete removes EVERY match: unlike `set` there is no
                // single deterministic target to require, and the old
                // behaviour — an error on one match, a silent no-op on
                // several — was exactly backwards. A trailing descent
                // re-collects as it goes (its matches can nest).
                var p = try Path.parse(doc.allocator, path);
                defer p.deinit(doc.allocator);
                if (p.segments.len > 0 and p.segments[p.segments.len - 1] == .descend) {
                    return applyDescendDelete(doc, p.segments);
                }
                try applyDelete(doc, p.segments);
            },
            .insert => |ins| try applyInsert(doc, ins),
            .append => |app| {
                const seq = try ed.oneForWrite(app.sequence);
                try refuseAliasContainer(seq);
                if (!seq.isSequence()) return error.NotASequence;
                try doc.sequenceAppend(seq, app.value);
            },
            .move => |mv| try applyMove(doc, mv.from, mv.to, mv.key),
        }
    }

    /// True when every segment is a plain key, the case in which `set`
    /// is allowed to auto-create the intermediate mappings.
    fn allPlainKeys(segs: []const Segment) bool {
        for (segs) |seg| {
            if (seg != .key) return false;
        }
        return true;
    }

    /// Resolve the container a `set` addresses: the node the final
    /// segment indexes into. Plain-key parents auto-create intermediate
    /// mappings when `may_create` (the documented deterministic case);
    /// anything else addresses existing structure only, so it goes
    /// through the general resolver and must match exactly once.
    fn setContainer(doc: *Document, parent: []const Segment, may_create: bool) Error!*Node {
        if (may_create and allPlainKeys(parent)) {
            // The part of the walk that exists must not step through an
            // alias (the rest is created).
            var cur = doc.root;
            for (parent) |seg| {
                const c = cur orelse break;
                if (c.data == .alias) return error.AliasPath;
                cur = c.lookup(seg.key);
            }
            const keys = try doc.allocator.alloc([]const u8, parent.len);
            defer doc.allocator.free(keys);
            for (parent, 0..) |seg, i| keys[i] = seg.key;
            return doc.mappingWalkOrCreate(keys);
        }
        const root = doc.root orelse return error.UnknownPath;
        const found = try resolveForWrite(doc.allocator, root, .{ .segments = parent });
        defer doc.allocator.free(found);
        if (found.len == 0) return error.UnknownPath;
        if (found.len > 1) return error.AmbiguousOperation;
        return found[0];
    }

    fn applySet(doc: *Document, path: []const u8, value: *Node) Error!void {
        var p = try Path.parse(doc.allocator, path);
        defer p.deinit(doc.allocator);
        if (p.segments.len == 0) {
            if (doc.root) |root| {
                if (sameScalarPresentation(root, value)) return;
            }
            try internal.setRoot(doc, value);
            try internal.setParent(doc, value, null);
            try internal.adopt(doc, value);
            return;
        }
        const parent = p.segments[0 .. p.segments.len - 1];
        switch (p.segments[p.segments.len - 1]) {
            // A final key names a mapping entry: replaced in place when
            // it exists, appended when it does not.
            .key => |last| {
                const cur = try setContainer(doc, parent, true);
                try refuseAliasContainer(cur);
                if (!cur.isMapping()) return error.NotAMapping;
                if (cur.lookup(last)) |existing| {
                    // An exact scalar-presentation match is a no-op:
                    // replacing would drop the entry's source span and
                    // re-emit the value normalized (flow spacing, block
                    // scalar indentation) although nothing changed.
                    if (sameScalarPresentation(existing, value)) return;
                    // `lookup` only matches values of the mapping `cur`,
                    // so the in-place replace must succeed; falling
                    // through would append a duplicate key.
                    if (!try internal.mappingReplace(doc, cur, existing, value)) return error.InvalidSyntax;
                    return;
                }
                try doc.mappingAppend(cur, try doc.createScalar(last, .plain), value);
            },
            // A final index names an existing sequence slot; there is
            // nothing sensible to auto-create at a position.
            .index => |ix| {
                const cur = try setContainer(doc, parent, false);
                try refuseAliasContainer(cur);
                if (!cur.isSequence()) return error.NotASequence;
                if (cur.items()) |items| {
                    if (ix < items.len) {
                        if (sameScalarPresentation(items[ix], value)) return;
                        if (emitter_mod.Emitter.rewritableInFlow(value) and
                            try internal.sequenceReplace(doc, cur, ix, value))
                        {
                            return;
                        }
                    }
                }
                // Block slots, synthetic/missing flow spans, collections,
                // and values carrying properties use ordinary removal and
                // insertion. Their layout is normalized at the measured
                // sibling indentation.
                _ = (try doc.sequenceRemove(cur, ix)) orelse return error.UnknownPath;
                try doc.sequenceInsert(cur, ix, value);
            },
            // Wildcards, filters and recursive descent can match any
            // number of nodes: not a single deterministic target.
            else => return error.AmbiguousOperation,
        }
    }

    /// True when `a` and `b` are scalars with identical presentation:
    /// same value, scalar style, anchor and tag. Setting a node to such
    /// a replacement changes nothing observable, so the edit is a
    /// no-op that preserves the original node's source span.
    fn sameScalarPresentation(a: *Node, b: *Node) bool {
        if (a.data != .scalar or b.data != .scalar) return false;
        if (!std.mem.eql(u8, a.data.scalar.value, b.data.scalar.value)) return false;
        if (a.data.scalar.style != b.data.scalar.style) return false;
        return sameOptionalText(a.anchor, b.anchor) and sameOptionalText(a.tag, b.tag);
    }

    fn sameOptionalText(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return std.mem.eql(u8, a.?, b.?);
    }

    /// A trailing `..key` descent deletes every node the whole path
    /// matches, in document order, atomically (a failure rolls back
    /// through the batch's journal). The prefix resolves through the
    /// full query grammar, so `$..in..k` deletes every `k` beneath
    /// every `in`.
    /// A victim whose removal would strand an alias refuses the WHOLE
    /// delete.
    fn applyDescendDelete(doc: *Document, segments: []const Segment) Error!void {
        const k = segments[segments.len - 1].descend;
        const root = doc.root orelse return;
        var through_alias = false;
        const containers = try resolveTracked(doc.allocator, root, .{ .segments = segments[0 .. segments.len - 1] }, &through_alias);
        defer doc.allocator.free(containers);

        var victims: std.ArrayList(*Node) = .empty;
        defer victims.deinit(doc.allocator);
        var descent: Descent = .{ .allocator = doc.allocator, .out = &victims };
        defer descent.deinit();
        for (containers) |container| try descent.walk(container, k, 0);
        if (victims.items.len == 0) return;
        // Pre-flight every victim's anchor obligations before removing
        // anything: a refusal must not leave a half-deleted document.
        for (victims.items) |victim| {
            try refuseIfPairStrandsAlias(doc, victim);
        }
        // A match found only through an alias sits in the anchored node
        // every alias shares, as for `applyDelete`.
        if (through_alias or descent.via_alias) return error.AliasPath;
        // Outermost first (the walk is pre-order), each by identity. A
        // match inside an earlier one's subtree leaves with it; detaching
        // it from that detached subtree afterwards changes nothing that
        // is emitted. (This re-collected the whole tree after every
        // removal, which was quadratic in the number of matches.)
        for (victims.items) |victim| {
            const parent = victim.parent orelse continue;
            _ = try detachChild(doc, parent, victim);
        }
    }

    /// Delete every node `segments` matches, atomically. A path of keys
    /// and indices names at most one node; a wildcard or filter, at the
    /// end or in the middle, can name many, and each is removed. No
    /// match is a no-op. Every guard runs before anything is removed, so
    /// a refusal leaves the document as it was.
    fn applyDelete(doc: *Document, segments: []const Segment) Error!void {
        const root = doc.root orelse return;
        if (segments.len == 0) {
            try refuseIfPairStrandsAlias(doc, root);
            return error.AmbiguousOperation;
        }
        var through_alias = false;
        const containers = try resolveTracked(doc.allocator, root, .{ .segments = segments[0 .. segments.len - 1] }, &through_alias);
        defer doc.allocator.free(containers);

        // Each victim with the container it is removed from, found one
        // container at a time so a container that is an alias is seen:
        // reads forward through it, writes do not.
        const Victim = struct { container: *Node, node: *Node };
        var victims: std.ArrayList(Victim) = .empty;
        defer victims.deinit(doc.allocator);
        var seen: std.AutoHashMapUnmanaged(*Node, void) = .empty;
        defer seen.deinit(doc.allocator);
        for (containers) |container| {
            const hits = try resolveTracked(doc.allocator, container, .{ .segments = segments[segments.len - 1 ..] }, &through_alias);
            defer doc.allocator.free(hits);
            for (hits) |hit| {
                // One node reached twice (a descent in the prefix, or an
                // alias) is one deletion.
                if ((try seen.getOrPut(doc.allocator, hit)).found_existing) continue;
                try victims.append(doc.allocator, .{ .container = container, .node = hit });
            }
        }
        if (victims.items.len == 0) return;
        for (victims.items) |v| try refuseIfPairStrandsAlias(doc, v.node);
        // Before the removal, not after: `mappingRemove` rejected a
        // non-mapping and the old no-op path swallowed that as "matched
        // nothing", so `delete("$.b.k")` through an alias reported
        // SUCCESS and deleted nothing. Through an alias at ANY step, not
        // only the last: `$.b.inner.j` deleted from the anchored node.
        if (through_alias) return error.AliasPath;
        // By identity, in document order: positions shift as items go,
        // and a mapping may repeat a key.
        for (victims.items) |v| {
            const removed = try detachChild(doc, v.container, v.node);
            std.debug.assert(removed);
        }
    }

    fn applyInsert(doc: *Document, ins: Insert) Error!void {
        var ed = Editor{ .doc = doc };
        const seq = try ed.oneForWrite(ins.sequence);
        try refuseAliasContainer(seq);
        const items = seq.items() orelse return error.NotASequence;
        const anchor = try ed.one(ins.position);
        var index: usize = items.len;
        for (items, 0..) |item, i| {
            if (item == anchor) {
                index = i;
                break;
            }
        }
        if (index == items.len) return error.UnknownPath;
        try doc.sequenceInsert(seq, index + @intFromBool(!ins.before), ins.value);
    }

    fn applyMove(doc: *Document, from: []const u8, to: []const u8, key: ?[]const u8) Error!void {
        var ed = Editor{ .doc = doc };
        const node = try ed.oneForWrite(from);
        const target = try ed.oneForWrite(to);
        try refuseIfMoveStrandsAlias(doc, node);
        // Detaching a mapping value drops the whole pair, key included
        // (see the detach loop below), so an anchor on that key leaves
        // with it. `refuseIfMoveStrandsAlias` only sees the value tree.
        if (pairKeyOf(node)) |pair_key| try refuseIfAnchorReferenced(doc, pair_key);
        try refuseAliasContainer(target);
        // Reject moving a node into its own subtree.
        var anc: ?*Node = target;
        while (anc) |a| : (anc = a.parent) {
            if (a == node) return error.MoveIntoSubtree;
        }
        // Detach from the current parent. An ancestor left clean would
        // re-emit the node at its old place too, and the move would
        // silently become a copy (see `detachChild`).
        if (node.parent) |parent| _ = try detachChild(doc, parent, node);
        switch (target.data) {
            .mapping => {
                const k = key orelse return error.AmbiguousOperation;
                // The attach drops the span of the node's old place
                // (`internal.adopt`).
                try doc.mappingAppend(target, try doc.createScalar(k, .plain), node);
            },
            .sequence => {
                try doc.sequenceAppend(target, node);
            },
            else => return error.NotACollection,
        }
    }
};

/// Remove `child` from `container` by identity -- the pair whose value
/// it is, or the item it is -- tombstoning its bytes, and mark the
/// container modified. The flag has to reach the root, or an ANCESTOR
/// still counts as clean and re-emits the subtree verbatim from the
/// source, reinstating what was removed; `markModified` walks the
/// chain. Returns false when `child` is not there.
fn detachChild(doc: *Document, container: *Node, child: *Node) Error!bool {
    switch (container.data) {
        .mapping => |m| for (m.pairs.items, 0..) |p, i| {
            if (p.value != child) continue;
            try internal.dropPairSpan(doc, container, p);
            _ = try internal.removePair(doc, container, i);
            try internal.setParent(doc, p.key, null);
            break;
        } else return false,
        .sequence => |sq| for (sq.items.items, 0..) |item, i| {
            if (item != child) continue;
            try internal.dropItemSpan(doc, container, child);
            _ = try internal.removeItem(doc, container, i);
            break;
        } else return false,
        else => return false,
    }
    try internal.setParent(doc, child, null);
    try doc.markModified(container);
    return true;
}

/// Deep-clone a subtree into `doc`'s pool, keeping presentation spans
/// and rebuilding alias targets within the clone. Attached anywhere in
/// the tree, the clone is written at its new position: the attach drops
/// the span that no longer describes it (`internal.adopt`).
///
/// SAME-DOCUMENT ONLY. The clone's spans index the source the tree was
/// parsed from: attaching the result anywhere except back into `doc`'s
/// own tree makes the emitter copy bytes from the wrong source —
/// silently, or as an out-of-bounds read when the other document is
/// shorter. For a tree that will live in a different document, use
/// `cloneTreeInto`, which clears spans so the copy re-emits normalized
/// (the same contract as `move`).
pub fn cloneTree(doc: *Document, root: *Node) CloneError!*Node {
    var anchors = std.StringHashMap(*Node).init(doc.allocator);
    defer anchors.deinit();
    return cloneNode(doc, root, &anchors, false, 0);
}

/// Deep-clone a subtree from ANOTHER document into `doc`'s pool.
/// Presentation spans are cleared: the clone has no source bytes in
/// `doc`, so it re-emits normalized — structure and values survive,
/// internal layout, comments and blank lines do not (exactly the moved
/// subtree's contract). Alias targets pointing outside the cloned
/// subtree are followed for their values; anchors are rebuilt within
/// the clone.
pub fn cloneTreeInto(doc: *Document, root: *Node) CloneError!*Node {
    var anchors = std.StringHashMap(*Node).init(doc.allocator);
    defer anchors.deinit();
    return cloneNode(doc, root, &anchors, true, 0);
}

fn cloneNode(doc: *Document, node: *Node, anchors: *std.StringHashMap(*Node), clear_spans: bool, depth: usize) CloneError!*Node {
    // Structural recursion only — an alias is copied as an alias, never
    // followed — so a cycle cannot reach here, but a deep built tree can.
    // The one exception is the cross-document alias below, which is
    // followed and so counts against the same depth budget.
    if (depth >= max_walk_depth) return error.NestingTooDeep;

    // An alias whose anchor lives OUTSIDE the cloned subtree cannot
    // survive a cross-document clone as an alias: its target node
    // belongs to the source document's pool (a dangling pointer once
    // that document is freed) and `*name` would name an anchor this
    // document never defines. Follow it for its value instead — the
    // contract `cloneTreeInto` documents. Following registers the
    // target's own anchor, so a second alias to the same name still
    // clones as an alias, pointing at the copy.
    if (clear_spans and node.data == .alias and anchors.get(node.data.alias.name) == null) {
        return cloneNode(doc, node.data.alias.target, anchors, clear_spans, depth + 1);
    }

    const n = try doc.pool.create(Node);
    n.* = .{
        .parent = null,
        .mark = node.mark,
        // Every string is duped into THIS document's pool. Sharing the
        // source node's slices is safe only within one document; for a
        // cross-document clone they dangle the moment the source
        // document is freed.
        .anchor = if (node.anchor) |a| try doc.pool.dupe(a) else null,
        .tag = if (node.tag) |t| try doc.pool.dupe(t) else null,
        .src = if (clear_spans) null else node.src,
        .modified = node.modified,
        // Written comments travel on the node fields (readable via
        // trailingComment/leadingComments), but note that a span-less
        // cloned subtree (clear_spans=true) re-emits normalized without
        // comments per the moved-subtree contract.
        .pending_trailing = if (node.pending_trailing) |t| try doc.pool.dupe(t) else null,
        .pending_leading = if (node.pending_leading) |t| try doc.pool.dupe(t) else null,
        .data = undefined,
    };
    switch (node.data) {
        .scalar => |s| {
            n.data = .{ .scalar = .{ .value = try doc.pool.dupe(s.value), .style = s.style } };
            // Register scalar anchors like the collection arms do, so a
            // cloned alias to an anchored scalar points into the clone
            // -- not at the pre-clone node, where a later replacement
            // of the scalar would never reach it.
            if (n.anchor) |a| try anchors.put(a, n);
        },
        .alias => |a| {
            // Reached only for an anchor defined inside the clone, or
            // for a same-document clone where the source node is a
            // legitimate target.
            // A same-document subtree clone may legitimately name an
            // anchor outside the cloned subtree; the reference stays in
            // this document and is still valid.
            const target = anchors.get(a.name) orelse a.target;
            n.data = .{ .alias = .{ .name = try doc.pool.dupe(a.name), .target = target } };
        },
        .mapping => |m| {
            n.data = .{ .mapping = .{ .style = m.style } };
            if (n.anchor) |a| try anchors.put(a, n);
            for (m.pairs.items) |p| {
                const k = try cloneNode(doc, p.key, anchors, clear_spans, depth + 1);
                const v = try cloneNode(doc, p.value, anchors, clear_spans, depth + 1);
                try internal.attachPair(doc, n, k, v);
                // Preserve the pair's original extent -- but only for a
                // same-document clone. `src_end` indexes the source the
                // tree was parsed from, so it is a span like any other
                // and goes when the spans go.
                if (!clear_spans and n.data == .mapping) {
                    const pairs = n.data.mapping.pairs.items;
                    if (pairs.len > 0) pairs[pairs.len - 1].src_end = p.src_end;
                }
            }
            // Tombstones are source byte ranges: same rule as spans.
            if (!clear_spans) {
                for (m.dropped.items) |d| {
                    try n.data.mapping.dropped.append(doc.pool.allocator(), d);
                }
            }
        },
        .sequence => |sq| {
            n.data = .{ .sequence = .{ .style = sq.style } };
            if (n.anchor) |a| try anchors.put(a, n);
            for (sq.items.items) |item| {
                const child = try cloneNode(doc, item, anchors, clear_spans, depth + 1);
                try internal.attachItem(doc, n, child);
            }
            if (!clear_spans) {
                for (sq.dropped.items) |d| {
                    try n.data.sequence.dropped.append(doc.pool.allocator(), d);
                }
            }
        },
    }
    return n;
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

test "quoted path segments address keys the dotted form cannot" {
    var doc = try Document.parse(testing.allocator,
        \\app.kubernetes.io/name: yayl
        \\pymdownx.highlight:
        \\  anchor_linenums: true
        \\weird[key]: bracketed
        \\"": empty-key
        \\plain: ordinary
        \\
    );
    defer doc.deinit();
    var ed = Editor.init(&doc);

    // A key containing `.`: unreachable with the dotted form, which would
    // split it into three segments.
    try testing.expectEqualStrings("yayl", (try ed.one("$[\"app.kubernetes.io/name\"]")).scalarValue().?);
    // Single quotes work the same way.
    try testing.expectEqualStrings("true", (try ed.one("$['pymdownx.highlight'].anchor_linenums")).scalarValue().?);
    // A key containing brackets.
    try testing.expectEqualStrings("bracketed", (try ed.one("$[\"weird[key]\"]")).scalarValue().?);
    // The empty key is legal YAML and deliberately addressable.
    try testing.expectEqualStrings("empty-key", (try ed.one("$[\"\"]")).scalarValue().?);
    // Quoting an ordinary key is allowed and means the same thing.
    try testing.expectEqualStrings("ordinary", (try ed.one("$[\"plain\"]")).scalarValue().?);
    // A quoted segment is an ordinary key segment, so it composes.
    try testing.expectEqualStrings("true", (try ed.one("$[\"pymdownx.highlight\"][\"anchor_linenums\"]")).scalarValue().?);

    // The dotted form still cannot reach it.
    try testing.expectError(error.UnknownPath, ed.one("$.app.kubernetes.io/name"));

    // Malformed quoting is rejected rather than silently treated as a key.
    try testing.expectError(error.InvalidPath, Path.parse(testing.allocator, "$[\"unterminated"));
    try testing.expectError(error.InvalidPath, Path.parse(testing.allocator, "$[\"missing-bracket\""));
    try testing.expectError(error.InvalidPath, Path.parse(testing.allocator, "$[\"trailing\"junk]"));
}

test "path grammar and queries" {
    var doc = try Document.parse(testing.allocator,
        \\store:
        \\  book:
        \\    - title: t1
        \\      role: edge
        \\    - title: t2
        \\id: root-id
        \\inner:
        \\  id: deep-id
        \\
    );
    defer doc.deinit();
    var ed = Editor.init(&doc);

    {
        const r = try ed.all("$.store.book[0].title");
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(usize, 1), r.len);
        try testing.expectEqualStrings("t1", r[0].scalarValue().?);
    }
    {
        const r = try ed.all("$.store.book[*].title");
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(usize, 2), r.len);
        try testing.expectEqualStrings("t2", r[1].scalarValue().?);
    }
    {
        const r = try ed.all("$..id");
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(usize, 2), r.len);
        try testing.expectEqualStrings("root-id", r[0].scalarValue().?);
    }
    {
        const r = try ed.all("$.store.book[?role=edge]");
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(usize, 1), r.len);
        try testing.expectEqualStrings("t1", r[0].lookup("title").?.scalarValue().?);
    }
    // Bare key without `$` and invalid grammar.
    {
        const r = try ed.all("store");
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(usize, 1), r.len);
    }
    try testing.expectError(error.InvalidPath, ed.all("$.store["));
    try testing.expectError(error.InvalidPath, ed.all("$.."));
    try testing.expectError(error.UnknownPath, ed.one("$.nope"));
}

test "one tells a path that matches nothing from one that matches several" {
    // Both used to be `UnknownPath`, so a caller -- `delete` among them,
    // before it stopped using `one` -- could not tell "absent" from
    // "ambiguous".
    var doc = try Document.parse(testing.allocator, "s:\n  - {k: 1}\n  - {k: 2}\nt: [x]\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try testing.expectError(error.AmbiguousOperation, ed.one("$.s[*]"));
    try testing.expectError(error.AmbiguousOperation, ed.one("$..k"));
    try testing.expectError(error.UnknownPath, ed.one("$.s[?k=3]"));
    try testing.expectEqualStrings("2", (try ed.one("$.s[?k=2].k")).scalarValue().?);
    try testing.expectEqualStrings("x", (try ed.one("$.t[*]")).scalarValue().?);
    // The single-target edits report the same.
    const v = try doc.createScalar("v", .plain);
    try testing.expectError(error.AmbiguousOperation, ed.apply(&.{.{ .append = .{ .sequence = "$[*]", .value = v } }}));
    try testing.expectError(error.AmbiguousOperation, ed.apply(&.{.{ .move = .{ .from = "$.s[*]", .to = "$.t" } }}));
}

test "set creates intermediates and replaces in place" {
    var doc = try Document.parse(testing.allocator, "a: 1\nb: 2\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);

    try ed.set("$.a", try doc.createScalar("100", .plain));
    try testing.expectEqualStrings("100", doc.pathGet(&.{"a"}).?.scalarValue().?);

    try ed.set("$.x.y.z", try doc.createScalar("deep", .plain));
    try testing.expectEqualStrings("deep", doc.pathGet(&.{ "x", "y", "z" }).?.scalarValue().?);

    // Untouched sibling bytes survive.
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: 100\nb: 2\nx:\n  y:\n    z: deep\n", out);
}

test "insert, append and delete sequence items" {
    var doc = try Document.parse(testing.allocator, "items:\n  - a\n  - c\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);

    try ed.apply(&.{.{ .append = .{ .sequence = "$.items", .value = try doc.createScalar("d", .plain) } }});
    try ed.apply(&.{.{ .insert = .{ .sequence = "$.items", .position = "$.items[1]", .value = try doc.createScalar("b", .plain), .before = true } }});
    try ed.apply(&.{.{ .delete = "$.items[3]" }});

    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("items:\n  - a\n  - b\n  - c\n", out);
}

test "move between containers" {
    var doc = try Document.parse(testing.allocator,
        \\from:
        \\  - keep
        \\  - take me
        \\to: []
        \\
    );
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.apply(&.{.{ .move = .{ .from = "$.from[1]", .to = "$.to" } }});
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    // `to` is an empty flow sequence, so the moved item joins it in
    // flow style.
    try testing.expectEqualStrings("from:\n  - keep\nto: [take me]\n", out);

    // Moving into one's own subtree is rejected.
    try testing.expectError(error.MoveIntoSubtree, ed.apply(&.{.{ .move = .{ .from = "$", .to = "$.from" } }}));
}

test "failed batch leaves the document untouched" {
    const src =
        \\# keep this comment
        \\a: 1
        \\b: 2
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    var ed = Editor.init(&doc);

    // Unknown single-match path.
    try testing.expectError(error.UnknownPath, ed.one("$.missing.x"));
    // Multi-match queries return an empty set, not an error.
    {
        const r = try ed.all("$.missing.x");
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(usize, 0), r.len);
    }
    // A batch whose later edit fails rolls back everything.
    const batch = [_]Edit{
        .{ .set = .{ .path = "$.a", .value = try doc.createScalar("10", .plain) } },
        .{ .set = .{ .path = "$.b[0].x", .value = try doc.createScalar("boom", .plain) } },
    };
    // `b` is a scalar, so `$.b[0]` resolves to nothing.
    try testing.expectError(error.UnknownPath, ed.apply(&batch));

    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "batch success applies every edit" {
    var doc = try Document.parse(testing.allocator, "a: 1\nb: 2\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.apply(&.{
        .{ .set = .{ .path = "$.a", .value = try doc.createScalar("10", .plain) } },
        .{ .set = .{ .path = "$.c", .value = try doc.createScalar("3", .plain) } },
        .{ .delete = "$.b" },
    });
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: 10\nc: 3\n", out);
}

test "set and append batch" {
    var doc = try Document.parse(testing.allocator, "a: 1\nb:\n  - x\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    const edits = [_]Edit{
        .{ .set = .{ .path = "$.a", .value = try doc.createScalar("2", .plain) } },
        .{ .append = .{ .sequence = "$.b", .value = try doc.createScalar("y", .plain) } },
    };
    try ed.apply(&edits);
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: 2\nb:\n  - x\n  - y\n", out);
}

test "deleting a missing path is a no-op" {
    var doc = try Document.parse(testing.allocator, "a: 1\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.apply(&.{.{ .delete = "$.missing" }});
    try ed.apply(&.{.{ .delete = "$.a.deep" }}); // scalar in the middle
    try ed.apply(&.{.{ .delete = "$.a[0]" }}); // index into a scalar
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: 1\n", out);
}

test "deleting a nested first child keeps the surviving siblings' indentation" {
    // The bytes between a key's colon and its block value's first entry
    // carry that entry's indentation. Deleting the first child must not
    // leave those bytes behind for the new first child to indent on top
    // of (they would double: 2 -> 4).
    const cases = [_]struct { src: []const u8, path: []const u8, want: []const u8 }{
        .{ .src = "top:\n  a: 1\n  b: 2\n", .path = "$.top.a", .want = "top:\n  b: 2\n" },
        .{ .src = "top:\n    a: 1\n    b: 2\n", .path = "$.top.a", .want = "top:\n    b: 2\n" },
        .{ .src = "top:\n  mid:\n    a: 1\n    b: 2\n", .path = "$.top.mid.a", .want = "top:\n  mid:\n    b: 2\n" },
        .{ .src = "top:\n  a: 1\n  b: 2\n  c: 3\n", .path = "$.top.a", .want = "top:\n  b: 2\n  c: 3\n" },
        .{ .src = "top:\n  - a\n  - b\n", .path = "$.top[0]", .want = "top:\n  - b\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.delete(c.path);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
    }
}

test "editing a sequence item's last key adds no blank line" {
    // A modified item's container walk already consumes the line
    // terminator; writing the line remainder on top of it appended a
    // blank line after every list-of-mappings entry that was edited.
    const src =
        \\list:
        \\  - name: a
        \\    port: 1
        \\  - name: b
        \\    port: 2
        \\after: 3
        \\
    ;
    const cases = [_]struct { path: []const u8, want: []const u8 }{
        .{ .path = "$.list[0].port", .want = "list:\n  - name: a\n    port: Z\n  - name: b\n    port: 2\nafter: 3\n" },
        .{ .path = "$.list[1].port", .want = "list:\n  - name: a\n    port: 1\n  - name: b\n    port: Z\nafter: 3\n" },
        .{ .path = "$.list[0].name", .want = "list:\n  - name: Z\n    port: 1\n  - name: b\n    port: 2\nafter: 3\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.set(c.path, try doc.createScalar("Z", .plain));
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
    }
}

test "replacing the first entry of a block collection keeps the layout" {
    // The replacement is a brand-new node, so the emitter owns its
    // layout: it must supply the indentation the deleted entry's
    // tombstone took with it, and the line break the tombstone
    // swallowed along with the original terminator.
    const cases = [_]struct { src: []const u8, path: []const u8, want: []const u8 }{
        .{ .src = "items:\n  - a\n  - b\n  - c\n", .path = "$.items[0]", .want = "items:\n  - Z\n  - b\n  - c\n" },
        .{ .src = "items:\n  - a\n  - b\n", .path = "$.items[1]", .want = "items:\n  - a\n  - Z\n" },
        .{ .src = "list:\n  - name: a\n    port: 1\n  - name: b\n", .path = "$.list[0]", .want = "list:\n  - Z\n  - name: b\n" },
        .{ .src = "top:\n  a: 1\n  b: 2\n", .path = "$.top.a", .want = "top:\n  a: Z\n  b: 2\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.set(c.path, try doc.createScalar("Z", .plain));
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
    }
}

test "editing inside a flow collection keeps the entry's key intact" {
    // Flow entries share their line with the parent's `key:`, so the
    // line-range tombstones that let block emission skip a removed entry
    // would swallow the `key: ` bytes as well.
    const src = "numbers:\n  ints: [0, -1, 42]\n  flow: {a: 1, b: 2}\n";
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.set("$.numbers.ints[0]", try doc.createScalar("Z", .plain));
    try ed.delete("$.numbers.flow.a");
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("numbers:\n  ints: [Z, -1, 42]\n  flow: {b: 2}\n", out);
    // The result must still be valid YAML.
    var re = try Document.parse(testing.allocator, out);
    re.deinit();
}

test "deleting a sequence item's first key keeps the item indicator" {
    // The `- ` indicator lives in the first entry's leading bytes but
    // belongs to the sequence ITEM: deleting that entry used to take the
    // indicator with it and emit structurally invalid YAML.
    const src =
        \\steps:
        \\  - name: Checkout
        \\    uses: actions/checkout@v4
        \\  - name: Build
        \\    run: make
        \\
    ;
    const cases = [_]struct { path: []const u8, want: []const u8 }{
        .{
            .path = "$.steps[0].name",
            .want = "steps:\n  - uses: actions/checkout@v4\n  - name: Build\n    run: make\n",
        },
        .{
            .path = "$.steps[1].name",
            .want = "steps:\n  - name: Checkout\n    uses: actions/checkout@v4\n  - run: make\n",
        },
        .{
            .path = "$.steps[0].uses",
            .want = "steps:\n  - name: Checkout\n  - name: Build\n    run: make\n",
        },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.delete(c.path);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
        // Structurally valid, not merely textually plausible.
        var re = try Document.parse(testing.allocator, out);
        re.deinit();
    }
}

test "a comment between entries survives a first-key delete" {
    // Re-anchoring the successor onto the indicator line consumes the
    // blanks between them. A comment cannot be moved, so the successor
    // stays put and the indicator keeps a line of its own — the item
    // must not dissolve into its predecessor.
    const src = "steps:\n  - name: Checkout\n    # keep me\n    uses: x\n  - name: Build\n";
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.delete("$.steps[0].name");
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("steps:\n  -\n    # keep me\n    uses: x\n  - name: Build\n", out);
    // Still two items, and the survivor still belongs to the first.
    var re = try Document.parse(testing.allocator, out);
    defer re.deinit();
    try testing.expectEqual(@as(usize, 2), re.pathGet(&.{"steps"}).?.items().?.len);
    var re_ed = Editor.init(&re);
    _ = try re_ed.one("$.steps[0].uses");
    try testing.expectError(error.UnknownPath, re_ed.one("$.steps[0].name"));
}

test "appending keeps the previous entry's trailing comment attached" {
    // The appended entry used to slot in ahead of the unwritten line
    // remainder, so the comment ended up on the NEW line and the entry
    // it documented lost it.
    var doc = try Document.parse(testing.allocator, "cfg:\n  key: value # trailing comment\n");
    defer doc.deinit();
    const cfg = doc.pathGet(&.{"cfg"}).?;
    try doc.mappingAppend(cfg, try doc.createScalar("added", .plain), try doc.createScalar("1", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("cfg:\n  key: value # trailing comment\n  added: 1\n", out);
}

test "replacing an item of a nested sequence keeps the outer indicator" {
    // `- - a` puts the OUTER item's indicator on the inner item's line;
    // it outlives the inner item and the replacement must sit under it.
    var doc = try Document.parse(testing.allocator, "list:\n  - - nested\n    - sequence\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.set("$.list[0][0]", try doc.createScalar("Z", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("list:\n  - - Z\n    - sequence\n", out);
    // The structure must survive, not merely the bytes.
    var re = try Document.parse(testing.allocator, out);
    defer re.deinit();
    var re_ed = Editor.init(&re);
    _ = try re_ed.one("$.list[0][1]");
}

test "replacing a collection's only entry keeps the sibling column" {
    // With no original entry left to copy the column from, the entry
    // column fell back to the container's own column PLUS one indent
    // step — but that column already is where the entries sit, so the
    // replacement landed one level too deep.
    const cases = [_]struct { src: []const u8, path: []const u8, want: []const u8 }{
        .{ .src = "secrets:\n  - db-password\n", .path = "$.secrets[0]", .want = "secrets:\n  - Z\n" },
        .{ .src = "secrets:\n    - db-password\n", .path = "$.secrets[0]", .want = "secrets:\n    - Z\n" },
        .{ .src = "top:\n  only: 1\n", .path = "$.top.only", .want = "top:\n  only: Z\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.set(c.path, try doc.createScalar("Z", .plain));
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
    }
}

test "allocation failures in a delete batch propagate and leak nothing" {
    try std.testing.checkAllAllocationFailures(testing.allocator, deleteBatch, .{});
}

test "set replaces a sequence item in place" {
    var doc = try Document.parse(testing.allocator, "items:\n  - a\n  - b\n  - c\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.set("$.items[1]", try doc.createScalar("B", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("items:\n  - a\n  - B\n  - c\n", out);
    try testing.expectError(error.UnknownPath, ed.set("$.items[9]", try doc.createScalar("x", .plain)));
    try testing.expectError(error.NotAMapping, ed.set("$.items.a", try doc.createScalar("x", .plain)));
}

test "set addresses through sequence indices in mid-path" {
    var doc = try Document.parse(testing.allocator,
        \\list:
        \\  - name: a
        \\    port: 1
        \\  - name: b
        \\    port: 2
        \\
    );
    defer doc.deinit();
    var ed = Editor.init(&doc);
    // Index in the middle, key final.
    try ed.set("$.list[1].port", try doc.createScalar("9", .plain));
    // Index final, replacing a whole item.
    try ed.set("$.list[0]", try doc.createScalar("gone", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("list:\n  - gone\n  - name: b\n    port: 9\n", out);
    // A path that cannot resolve to exactly one node is not a set target.
    try testing.expectError(error.UnknownPath, ed.set("$.list[9].port", try doc.createScalar("x", .plain)));
    try testing.expectError(error.AmbiguousOperation, ed.set("$.list[*]", try doc.createScalar("x", .plain)));
}

test "allocation failures in a set+append batch leak nothing" {
    try std.testing.checkAllAllocationFailures(testing.allocator, setAppendBatch, .{});
}

fn setAppendBatch(allocator: std.mem.Allocator) !void {
    var doc = try Document.parse(allocator, "a: 1\nb:\n  - x\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    const edits = [_]Edit{
        .{ .set = .{ .path = "$.a", .value = try doc.createScalar("2", .plain) } },
        .{ .append = .{ .sequence = "$.b", .value = try doc.createScalar("y", .plain) } },
    };
    try ed.apply(&edits);
    const out = try doc.write(allocator);
    defer allocator.free(out);
    try testing.expectEqualStrings("a: 2\nb:\n  - x\n  - y\n", out);
}

fn deleteBatch(allocator: std.mem.Allocator) !void {
    var doc = try Document.parse(allocator, "a: 1\nb: 2\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.apply(&.{.{ .delete = "$.b" }});
    const out = try doc.write(allocator);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("a: 1\n", out);
}

test "a new first entry goes below the container's own property line" {
    // Properties on a line of their own are the container's header; the
    // new item was written above them (`- zz\n&sequence\n- a`), which
    // does not parse. The preservation sweep skipped every such
    // container for this; it now sweeps them.
    const cases = [_]struct { in: []const u8, seq: []const u8, out: []const u8 }{
        .{ .in = "&sequence\n- a\n", .seq = "$", .out = "&sequence\n- zz\n- a\n" },
        .{ .in = "sequence: !!seq\n- entry\n- !!seq\n - nested\n", .seq = "$.sequence[1]", .out = "sequence: !!seq\n- entry\n- !!seq\n - zz\n - nested\n" },
        .{ .in = "k: &a\n  - x\n", .seq = "$.k", .out = "k: &a\n  - zz\n  - x\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.in);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        const pos = try std.fmt.allocPrint(testing.allocator, "{s}[0]", .{c.seq});
        defer testing.allocator.free(pos);
        try ed.apply(&.{.{ .insert = .{ .sequence = c.seq, .position = pos, .value = try doc.createScalar("zz", .plain), .before = true } }});
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.out, out);
    }
}

test "emptying a collection under an indicator alone on its line" {
    // `-` over `  - x`: the deleted entry's tombstone took the next
    // line's indentation, and `[]` landed at column 0, out of the item.
    // And an explicit key's `:` on a line of its own belongs to its
    // pair: it stayed behind when the pair was deleted (`{}\n  :`).
    const cases = [_]struct { in: []const u8, del: []const u8, out: []const u8 }{
        .{ .in = "- a\n-\n  - x\n", .del = "$[1][0]", .out = "- a\n-\n  []\n" },
        .{ .in = "-\n foo: bar\n-\n - x\n", .del = "$[1][0]", .out = "-\n foo: bar\n-\n []\n" },
        .{ .in = "k:\n  ? a\n  :\nx: 1\n", .del = "$.k.a", .out = "k:\n  {}\nx: 1\n" },
        .{ .in = "k:\n  ? a\n  :\n  ? b\n  : c\nx: 1\n", .del = "$.k.a", .out = "k:\n  ? b\n  : c\nx: 1\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.in);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.delete(c.del);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.out, out);
    }
}

test "emptying a collection keeps the value's placement under its key" {
    // Removing a container's LAST entry leaves `{}` / `[]` behind. The
    // bytes between the key's colon and the (now departed) first entry
    // are what place that value under its key. They must survive: a
    // surviving sibling would arrive carrying its own indentation, but
    // an emptied container has no successor to carry any, so letting
    // the deleted entry's tombstone eat those bytes drops the `{}` at
    // column 0 -- where it is no longer the value of anything, and the
    // document no longer parses at all.
    const cases = [_]struct { src: []const u8, path: []const u8, want: []const u8 }{
        .{ .src = "src:\n  item: 1\ndest: 2\n", .path = "$.src.item", .want = "src:\n  {}\ndest: 2\n" },
        .{ .src = "src:\n  - only\ndest: 2\n", .path = "$.src[0]", .want = "src:\n  []\ndest: 2\n" },
        // Four-space file: the placement is whatever the author wrote.
        .{ .src = "a:\n    only: 1\nb: 2\n", .path = "$.a.only", .want = "a:\n    {}\nb: 2\n" },
        // Nested, with a surviving sibling in the grandparent.
        .{ .src = "top:\n  mid:\n    only: 1\n  after: 2\n", .path = "$.top.mid.only", .want = "top:\n  mid:\n    {}\n  after: 2\n" },
        // A comment on the key's line is not part of the placement.
        .{ .src = "a: # why\n  only: 1\nb: 2\n", .path = "$.a.only", .want = "a: # why\n  {}\nb: 2\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.delete(c.path);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
        // The invariant that matters more than the exact bytes: the
        // emitter must never produce something we cannot read back.
        var again = try Document.parse(testing.allocator, out);
        defer again.deinit();
    }
}

test "moving out a collection's last entry keeps the source's placement" {
    // Same defect reached through `move` rather than `delete` -- the
    // detach side is shared, so both paths have to be held.
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{
            .src = "src:\n  item:\n    a: 1\ndest:\n  keep: y\n",
            .want = "src:\n  {}\ndest:\n  keep: y\n  moved:\n    a: 1\n",
        },
        // Deliberately 2-space only. A 4-space fixture here would also
        // measure the indentation the emitter gives the MOVED subtree's
        // own children, which is a separate concern (indent_step) with
        // its own test; a fixture that trips two things cannot tell you
        // which one broke. Source-side placement at other widths is
        // covered by the delete cases above.
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.apply(&.{.{ .move = .{ .from = "$.src.item", .to = "$.dest", .key = "moved" } }});
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
        var again = try Document.parse(testing.allocator, out);
        defer again.deinit();
    }
}

test "emptying a sequence item keeps the item and its indicator" {
    // The `- ` indicator lives in the first entry's leading bytes but
    // belongs to the ITEM, which survives its last key as `- {}`. Two
    // things used to go wrong together here, and only one of them was
    // visible: the tombstone ate the indicator (deleting a sequence
    // entry nobody asked to delete), and the `{}` was then left at the
    // parent key's own column, where a FLOW node reads as the key's
    // sibling rather than its value and the document stops parsing.
    //
    // The zero-indent style below -- `- ` items at their parent key's
    // column -- is the Kubernetes and mkdocs house style, so this is
    // not an exotic shape.
    const cases = [_]struct { src: []const u8, path: []const u8, want: []const u8 }{
        .{
            .src = "spec:\n  ports:\n  - containerPort: 80\n  other: 1\n",
            .path = "$.spec.ports[0].containerPort",
            .want = "spec:\n  ports:\n  - {}\n  other: 1\n",
        },
        .{
            .src = "ports:\n- containerPort: 80\nother: 1\n",
            .path = "$.ports[0].containerPort",
            .want = "ports:\n- {}\nother: 1\n",
        },
        // Conventionally indented. This one always PARSED; it was
        // silently dropping the item, which no re-parse check can see.
        .{
            .src = "spec:\n  ports:\n    - containerPort: 80\n  other: 1\n",
            .path = "$.spec.ports[0].containerPort",
            .want = "spec:\n  ports:\n    - {}\n  other: 1\n",
        },
        .{
            .src = "nav:\n  - Home: index.md\n  - About: about.md\n",
            .path = "$.nav[0].Home",
            .want = "nav:\n  - {}\n  - About: about.md\n",
        },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.delete(c.path);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);

        // The weak invariant that actually caught this: the output must
        // parse. Note the third case parsed BEFORE the fix too, while
        // silently dropping the item -- which is why the expected bytes
        // above matter as much as the re-parse.
        var again = try Document.parse(testing.allocator, out);
        defer again.deinit();
    }
}

test "emptying a zero-indent sequence value indents its placeholder" {
    // Deleting the sole ITEM (rather than the item's sole key) empties
    // the sequence itself. Same column hazard: `[]` at the key's own
    // column is the key's sibling, not its value.
    const cases = [_]struct { src: []const u8, path: []const u8, want: []const u8 }{
        .{
            .src = "spec:\n  containers:\n  - name: nginx\n  other: 1\n",
            .path = "$.spec.containers[0]",
            .want = "spec:\n  containers:\n    []\n  other: 1\n",
        },
        .{
            .src = "items:\n- only\nafter: 1\n",
            .path = "$.items[0]",
            .want = "items:\n  []\nafter: 1\n",
        },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.delete(c.path);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
        var again = try Document.parse(testing.allocator, out);
        defer again.deinit();
    }
}

// ----------------------------------------------------------------------
// Block layout for subtrees the emitter owns (new and moved).
//
// A container with no source span has no layout to preserve, so the
// emitter picks one. It used to pick single-line flow, which is valid
// YAML but alien to a block-styled file -- and inconsistent, since a
// brand-new *pair* already went through the block path. These pin the
// consistent behavior: block in, block out.
// ----------------------------------------------------------------------

/// A fresh two-key mapping, the stand-in for "a subtree the caller built".
fn twoKeyMapping(doc: *Document) !*Node {
    const m = try doc.createMapping();
    try doc.mappingAppend(m, try doc.createScalar("host", .plain), try doc.createScalar("h", .plain));
    try doc.mappingAppend(m, try doc.createScalar("port", .plain), try doc.createScalar("80", .plain));
    return m;
}

test "a new collection replacing a value emits block, not flow" {
    const cases = [_]struct { src: []const u8, path: []const u8, want: []const u8 }{
        // Replacing a scalar at the root.
        .{
            .src = "server: old\nother: 1\n",
            .path = "$.server",
            .want = "server:\n  host: h\n  port: 80\nother: 1\n",
        },
        // Nested one level: the new subtree indents from its own key.
        .{
            .src = "a:\n  server: old\n  other: 1\n",
            .path = "$.a.server",
            .want = "a:\n  server:\n    host: h\n    port: 80\n  other: 1\n",
        },
        // Comments on neighboring lines are untouched.
        .{
            .src = "# lead\nserver: old\n# trail\nother: 1\n",
            .path = "$.server",
            .want = "# lead\nserver:\n  host: h\n  port: 80\n# trail\nother: 1\n",
        },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.set(c.path, try twoKeyMapping(&doc));
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
    }
}

test "a replaced value's trailing comment rides the last emitted line" {
    // Documented consequence, not a target: the original line remainder
    // is written after the new value, so a comment that annotated a
    // one-line scalar ends up annotating the block's final line. Pinned
    // so that changing it is a decision rather than an accident.
    var doc = try Document.parse(testing.allocator, "server: old # keep me\nother: 1\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.set("$.server", try twoKeyMapping(&doc));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("server:\n  host: h\n  port: 80 # keep me\nother: 1\n", out);
}

test "a new collection appended to a block sequence emits block" {
    var doc = try Document.parse(testing.allocator, "list:\n  - name: a\n  - name: b\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    const m = try doc.createMapping();
    try doc.mappingAppend(m, try doc.createScalar("name", .plain), try doc.createScalar("c", .plain));
    try doc.mappingAppend(m, try doc.createScalar("port", .plain), try doc.createScalar("9", .plain));
    try ed.apply(&.{.{ .append = .{ .sequence = "$.list", .value = m } }});
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("list:\n  - name: a\n  - name: b\n  - name: c\n    port: 9\n", out);
}

test "a moved subtree emits block at its destination" {
    // `move` clears the node's span (it describes the OLD location), so
    // the destination slot is emitter-owned and takes the same path as
    // a brand-new subtree. Untouched siblings stay verbatim.
    // NOTE on fixture shape: `keep` deliberately comes BEFORE `item`, so
    // the moved node is not its container's FIRST entry. Moving out a
    // first entry additionally exercises the source-side indentation of
    // the surviving sibling, which is a separate concern from where the
    // node lands. Keep those apart -- a fixture that trips both cannot
    // tell you which one broke.
    {
        // Into a block mapping.
        var doc = try Document.parse(testing.allocator, "src:\n  keep: k\n  item:\n    a: 1\n    b: 2\ndest:\n  have: h\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.apply(&.{.{ .move = .{ .from = "$.src.item", .to = "$.dest", .key = "moved" } }});
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("src:\n  keep: k\ndest:\n  have: h\n  moved:\n    a: 1\n    b: 2\n", out);
    }
    {
        // Into a block sequence.
        var doc = try Document.parse(testing.allocator, "src:\n  keep: k\n  item:\n    a: 1\n    b: 2\ndest:\n  - first\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.apply(&.{.{ .move = .{ .from = "$.src.item", .to = "$.dest" } }});
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("src:\n  keep: k\ndest:\n  - first\n  - a: 1\n    b: 2\n", out);
    }
}

test "emitter-owned subtrees still re-parse to the values they were given" {
    // The layout is the emitter's choice, but the meaning is not: every
    // shape above must survive a round trip through the parser.
    const srcs = [_][]const u8{
        "server: old\nother: 1\n",
        "a:\n  server: old\n  other: 1\n",
        "server: old # keep me\nother: 1\n",
    };
    const paths = [_][]const u8{ "$.server", "$.a.server", "$.server" };
    for (srcs, paths) |src, path| {
        var doc = try Document.parse(testing.allocator, src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.set(path, try twoKeyMapping(&doc));
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);

        var again = try Document.parse(testing.allocator, out);
        defer again.deinit();
        var ed2 = Editor.init(&again);
        const moved = try ed2.one(path);
        try testing.expectEqualStrings("h", moved.lookup("host").?.scalarValue().?);
        try testing.expectEqualStrings("80", moved.lookup("port").?.scalarValue().?);
    }
}

test "setting a scalar to its own presentation is a byte-identical no-op" {
    // Each input carries presentation the emitter would normalize away
    // if the node were actually replaced: flow spacing, block-scalar
    // indentation, folding, anchors, tags, null. An exact
    // same-presentation set must leave every byte untouched.
    const Case = struct { input: []const u8, path: []const u8 };
    const cases = [_]Case{
        .{ .input = "branches: [ x ]\n", .path = "$.branches[0]" },
        .{ .input = "run: |-\n  first line\n      deliberately deep\n", .path = "$.run" },
        .{ .input = "description: >-\n  folded text\n  on two lines\n", .path = "$.description" },
        .{ .input = "a: &anch !!str hello\n", .path = "$.a" },
        .{ .input = "db-data:\n", .path = "$.db-data" },
        .{ .input = "plain root\n", .path = "$" },
    };
    for (cases) |case| {
        var doc = try Document.parse(testing.allocator, case.input);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        const existing = try ed.one(case.path);
        const replacement = try doc.createScalar(existing.data.scalar.value, existing.data.scalar.style);
        replacement.anchor = if (existing.anchor) |a| try doc.pool.dupe(a) else null;
        replacement.tag = if (existing.tag) |t| try doc.pool.dupe(t) else null;
        try ed.set(case.path, replacement);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(case.input, out);
    }

    // A different value or style is a real edit, not a no-op.
    {
        var doc = try Document.parse(testing.allocator, "branches: [ x ]\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.set("$.branches[0]", try doc.createScalar("y", .plain));
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("branches: [ y ]\n", out);
    }
    {
        var doc = try Document.parse(testing.allocator, "key: 5\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.set("$.key", try doc.createScalar("5", .single_quoted));
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("key: '5'\n", out);
    }
}

test "deleting two siblings in one batch keeps both deletes" {
    // Tombstones used to be recorded in the order the deletes ran,
    // while emission skips them in document order: deleting `b` then
    // `a` resurrected `a`'s bytes.
    var doc = try Document.parse(testing.allocator, "a: 1\nb: 2\nc: 3\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.apply(&.{ .{ .delete = "$.b" }, .{ .delete = "$.a" } });
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("c: 3\n", out);
}

test "inserting before a commented item does not duplicate the item" {
    var doc = try Document.parse(testing.allocator, "before_script:\n  - python --version  # For debugging\n  - pip install virtualenv\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.apply(&.{.{ .insert = .{
        .sequence = "$.before_script",
        .position = "$.before_script[0]",
        .value = try doc.createScalar("added", .plain),
        .before = true,
    } }});
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "before_script:\n" ++
            "  - added\n" ++
            "  - python --version  # For debugging\n" ++
            "  - pip install virtualenv\n",
        out,
    );
}

test "editing explicit-key entries emits valid YAML" {
    // Set: the value moves to a `: value` line instead of producing
    // the invalid `? key: value`.
    {
        var doc = try Document.parse(testing.allocator, "--- !!set\n? Mark McGwire\n? Sammy Sosa\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.apply(&.{.{ .set = .{ .path = "$.Mark McGwire", .value = try doc.createScalar("zz-edited", .plain) } }});
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("--- !!set\n? Mark McGwire\n: zz-edited\n? Sammy Sosa\n", out);
    }
    // Append: a new plain key sits at the indicator column, where it
    // is a sibling of the explicit entries.
    {
        var doc = try Document.parse(testing.allocator, "? Mark McGwire\n? Sammy Sosa\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.apply(&.{.{ .set = .{ .path = "$.zz_added", .value = try doc.createScalar("added", .plain) } }});
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("? Mark McGwire\n? Sammy Sosa\nzz_added: added\n", out);
    }
}

test "a spanned clone replacing a slot is emitted, not silently dropped" {
    // The audit suspicion, same-document form: `cloneTree` preserves
    // spans, so the clone looks clean to the emitter — and before
    // `mappingReplace` marked the replacement, the pair's fast path
    // re-emitted the ORIGINAL bytes and the replacement vanished.
    var doc = try Document.parse(testing.allocator, "a: 1\ntop:\n  x: 42\n");
    defer doc.deinit();
    const clone = try cloneTree(&doc, doc.pathGet(&.{"top"}).?);
    try testing.expect(try internal.mappingReplace(&doc, doc.root.?, doc.pathGet(&.{"a"}).?, clone));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a:\n  x: 42\ntop:\n  x: 42\n", out);
}

test "a spanned node attached anywhere is written at its new position" {
    // The same hazard everywhere else a node enters a slot: a
    // same-document clone keeps the spans of the slot it was copied from,
    // and the emitter copied that slot's bytes -- then carried on from
    // where that slot ended. As the root, `- p` came back as the whole
    // old document (the replacement vanished) and `a: 1` as `1` followed
    // by the old tail; as a block item it re-wrote the lines after its
    // source.
    const Op = enum { set, append, insert };
    const cases = [_]struct { in: []const u8, op: Op = .set, from: []const u8, to: []const u8, out: []const u8 }{
        .{ .in = "a: 1\nb: 2\n", .from = "$.a", .to = "$", .out = "1\n" },
        .{ .in = "a:\n  x: 1\nb: 2\n", .from = "$.a", .to = "$", .out = "x: 1\n" },
        .{ .in = "- p\n- q\n", .from = "$[0]", .to = "$", .out = "p\n" },
        .{ .in = "a: 1\nb:\n  - x\n  - y\n", .from = "$.a", .to = "$.b[0]", .out = "a: 1\nb:\n  - 1\n  - y\n" },
        .{ .in = "a: 1 # c\nb:\n  - x\n", .op = .append, .from = "$.a", .to = "$.b", .out = "a: 1 # c\nb:\n  - x\n  - 1\n" },
        .{
            .in = "a:\n  - 1\n  - 2\nb:\n  c:\n    - 1\n",
            .op = .append,
            .from = "$.a",
            .to = "$.b.c",
            .out = "a:\n  - 1\n  - 2\nb:\n  c:\n    - 1\n    - - 1\n      - 2\n",
        },
        .{
            .in = "a:\n  - 1\n  - 2\nb:\n  c:\n    - 1\n",
            .op = .insert,
            .from = "$.a",
            .to = "$.b.c",
            .out = "a:\n  - 1\n  - 2\nb:\n  c:\n    - - 1\n      - 2\n    - 1\n",
        },
        .{
            .in = "a: |\n  lit\n  eral\nb:\n  c:\n    - 1\n",
            .op = .append,
            .from = "$.a",
            .to = "$.b.c",
            .out = "a: |\n  lit\n  eral\nb:\n  c:\n    - 1\n    - |\n      lit\n      eral\n",
        },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.in);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        const clone = try cloneTree(&doc, try ed.one(c.from));
        switch (c.op) {
            .set => try ed.set(c.to, clone),
            .append => try ed.apply(&.{.{ .append = .{ .sequence = c.to, .value = clone } }}),
            .insert => try ed.apply(&.{.{ .insert = .{
                .sequence = c.to,
                .position = try std.fmt.allocPrint(doc.pool.allocator(), "{s}[0]", .{c.to}),
                .value = clone,
                .before = true,
            } }}),
        }
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.out, out);
    }

    // A node of the tree itself set as the root leaves its old parent.
    var doc = try Document.parse(testing.allocator, "a:\n  x: 1\nb: 2\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.set("$", try ed.one("$.a"));
    try testing.expect(doc.root.?.parent == null);
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("x: 1\n", out);
}

test "cloneTreeInto a second document cannot copy the wrong source bytes" {
    // The audit suspicion, cross-document form: the clone's spans index
    // the FIRST document's source. Before spans were cleared, attaching
    // the clone into a shorter document either panicked on the
    // out-of-bounds slice or re-emitted document A's bytes from inside
    // document B's slot, silently.
    var a = try Document.parse(testing.allocator,
        \\# padding to push the subtree's spans far into A's source
        \\keep: 1
        \\keep2: 2
        \\subtree:
        \\  x: 42
        \\
    );
    defer a.deinit();
    var b = try Document.parse(testing.allocator, "small: 1\nother: 2\n");
    defer b.deinit();

    const copy = try cloneTreeInto(&b, a.pathGet(&.{"subtree"}).?);
    try testing.expect(copy.src == null);
    // Replace an ORIGINAL slot: the replacement must appear.
    try testing.expect(try internal.mappingReplace(&b, b.root.?, b.pathGet(&.{"other"}).?, copy));
    const out = try b.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("small: 1\nother:\n  x: 42\n", out);

    // And the round trip of the result re-parses to the same values.
    var again = try Document.parse(testing.allocator, out);
    defer again.deinit();
    try testing.expectEqualStrings("42", again.pathGet(&.{ "other", "x" }).?.scalarValue().?);
    try testing.expectEqualStrings("1", again.pathGet(&.{"small"}).?.scalarValue().?);
}

test "cloneTreeInto keeps no pointers into the source document" {
    // Anchor, tag and written comments were copied by SLICE, and every
    // one of them is duped into the *source* document's pool -- so the
    // clone dangled the moment that document was freed.
    var b = try Document.parse(testing.allocator, "small: 1\n");
    defer b.deinit();

    const copy = blk: {
        var a = try Document.parse(testing.allocator,
            \\subtree: &keep !!map
            \\  x: 42
            \\
        );
        defer a.deinit();
        const node = a.pathGet(&.{"subtree"}).?;
        const inner = a.pathGet(&.{ "subtree", "x" }).?;
        try a.setTrailingComment(inner, "# trailing");
        try a.setLeadingComments(inner, "# leading");
        const clone = try cloneTreeInto(&b, node);

        // Checked while `a` is still alive, so this is a statement about
        // OWNERSHIP and not about whether the allocator happens to have
        // recycled the bytes yet: no string on the clone may point at
        // the other document's pool.
        try testing.expect(clone.anchor.?.ptr != node.anchor.?.ptr);
        try testing.expect(clone.tag.?.ptr != node.tag.?.ptr);
        const cloned_value = clone.data.mapping.pairs.items[0].value;
        try testing.expect(cloned_value.pending_trailing.?.ptr != inner.pending_trailing.?.ptr);
        // A leading block is held by the node that starts its line: for
        // an inline value, the key (`Document.setLeadingComments`).
        const inner_key = a.pathGet(&.{"subtree"}).?.pairs().?[0].key;
        const cloned_key = clone.data.mapping.pairs.items[0].key;
        try testing.expect(cloned_key.pending_leading.?.ptr != inner_key.pending_leading.?.ptr);
        break :blk clone;
    };
    // `a` and its pool are gone. Nothing below may read through it.
    try testing.expectEqualStrings("keep", copy.anchor.?);
    try testing.expectEqualStrings("tag:yaml.org,2002:map", copy.tag.?);
    const value = copy.data.mapping.pairs.items[0].value;
    try testing.expectEqualStrings("# trailing", value.pending_trailing.?);
    try testing.expectEqualStrings("# leading", copy.data.mapping.pairs.items[0].key.pending_leading.?);
    // Spans are cleared, and `src_end` is a span like any other.
    try testing.expect(copy.src == null);
    try testing.expect(copy.data.mapping.pairs.items[0].src_end == null);

    try b.pathSet(&.{"imported"}, copy);
    const out = try b.write(testing.allocator);
    defer testing.allocator.free(out);
    var rt = try Document.parse(testing.allocator, out);
    defer rt.deinit();
    try testing.expectEqualStrings("42", rt.pathGet(&.{ "imported", "x" }).?.scalarValue().?);
}

test "cloneTreeInto follows an alias anchored outside the subtree" {
    // `*shared` names an anchor `cloneTreeInto` never copies, so keeping
    // it as an alias left a pointer into the other document's pool AND
    // emitted `*shared` with no `&shared` to match. The documented
    // contract is to follow it for its value.
    var b = try Document.parse(testing.allocator, "small: 1\n");
    defer b.deinit();

    const copy = blk: {
        var a = try Document.parse(testing.allocator,
            \\base: &shared [1, 2]
            \\subtree:
            \\  first: *shared
            \\  second: *shared
            \\
        );
        defer a.deinit();
        break :blk try cloneTreeInto(&b, a.pathGet(&.{"subtree"}).?);
    };
    try b.pathSet(&.{"imported"}, copy);
    const out = try b.write(testing.allocator);
    defer testing.allocator.free(out);

    // The output has to be valid YAML on its own terms: re-parse it and
    // read the values back rather than pinning the exact layout.
    var rt = try Document.parse(testing.allocator, out);
    defer rt.deinit();
    for ([_][]const u8{ "first", "second" }) |key| {
        const seq = rt.pathGet(&.{ "imported", key }).?.resolveAlias();
        const got = seq.items().?;
        try testing.expectEqual(@as(usize, 2), got.len);
        try testing.expectEqualStrings("1", got[0].scalarValue().?);
        try testing.expectEqualStrings("2", got[1].scalarValue().?);
    }
}

test "cloneTree keeps an alias whose anchor is outside the subtree" {
    // A same-document subtree clone may name an anchor it did not copy:
    // the target lives elsewhere in this document, so the reference is
    // still valid and the clone's alias points at it.
    var doc = try Document.parse(testing.allocator, "base: &b 1\nsub:\n  x: *b\n");
    defer doc.deinit();
    const clone = try cloneTree(&doc, doc.pathGet(&.{"sub"}).?);
    const x = clone.lookup("x").?;
    try testing.expect(x.isAlias());
    try testing.expect(x.resolveAlias() == doc.pathGet(&.{"base"}).?);
}

test "a move cannot put an alias ahead of its anchor" {
    const allocator = std.testing.allocator;

    // Reported by wild-gecko. `delete` and `set` strand an alias by
    // removing the anchor; a move keeps it in the document, which is
    // why this was exempt. But an alias needs the anchor to come
    // BEFORE it, and a move only appends at the destination — so
    // `- &x 1\n- *x\n` moving `$[0]` to the root emitted
    // `- *x\n- &x 1\n`, which does not parse.
    const refused = [_]struct {
        input: []const u8,
        from: []const u8,
        to: []const u8,
        key: ?[]const u8,
    }{
        // Anchor moved past the alias that needs it.
        .{ .input = "- &x 1\n- *x\n", .from = "$[0]", .to = "$", .key = null },
        .{ .input = "a: &x 1\nb: *x\n", .from = "$.a", .to = "$", .key = "c" },
        .{ .input = "a: &x\n  k: 1\nb: *x\n", .from = "$.a", .to = "$", .key = "c" },
        // The alias moved into a container that precedes the anchor.
        .{ .input = "m:\n  - 1\na: &x 1\nb: *x\n", .from = "$.b", .to = "$.m", .key = null },
    };
    for (refused) |c| {
        var doc = try Document.parse(allocator, c.input);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try std.testing.expectError(
            error.AnchorReferenced,
            ed.apply(&.{.{ .move = .{ .from = c.from, .to = c.to, .key = c.key } }}),
        );
        const out = try doc.write(allocator);
        defer allocator.free(out);
        try std.testing.expectEqualStrings(c.input, out);
    }

    // A move whose anchor and alias travel TOGETHER keeps their order,
    // so it stays allowed — the test is whether the pair crosses the
    // moved subtree's boundary, not whether an alias is present.
    {
        var doc = try Document.parse(allocator, "m:\n  - &x 1\n  - *x\nz: 1\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.apply(&.{.{ .move = .{ .from = "$.m", .to = "$", .key = "q" } }});
        const out = try doc.write(allocator);
        defer allocator.free(out);
        var re = try Document.parse(allocator, out);
        defer re.deinit();
    }
}

test "a mutation through an alias path is refused, not silently dropped" {
    const allocator = std.testing.allocator;

    // Reported by wild-gecko. Reads forward through aliases (USAGE says
    // so, and `Editor.one` resolves), but writes did not — and failed
    // dishonestly. `mappingReplace`/`mappingRemove` switch on the node's
    // own `.data`, hit `.alias`, and the caller turned that into
    // `error.InvalidSyntax`, which blames the path. Worse, for delete
    // `noopOrOOM` swallowed it as "matched nothing", so
    // `delete("$.b.k")` reported SUCCESS and changed nothing — a
    // successful delete that deleted nothing is the worst outcome of
    // the group.
    const map = "a: &x\n  k: 1\nb: *x\n";
    const seq = "a: &x\n  - 1\nb: *x\n";

    {
        var doc = try Document.parse(allocator, map);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        const v = try doc.createScalar("2", .plain);
        try std.testing.expectError(error.AliasPath, ed.set("$.b.k", v));
        try std.testing.expectError(error.AliasPath, ed.delete("$.b.k"));
        try std.testing.expectError(error.AliasPath, ed.set("$.b.new", v));

        // Refused means untouched.
        const out = try doc.write(allocator);
        defer allocator.free(out);
        try std.testing.expectEqualStrings(map, out);
    }
    {
        var doc = try Document.parse(allocator, seq);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        const v = try doc.createScalar("2", .plain);
        try std.testing.expectError(error.AliasPath, ed.set("$.b[0]", v));
        try std.testing.expectError(
            error.AliasPath,
            ed.apply(&.{.{ .append = .{ .sequence = "$.b", .value = v } }}),
        );
    }

    // The anchor side is the supported route and still works: the
    // target is shared, so the alias reflects the change.
    {
        var doc = try Document.parse(allocator, map);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.set("$.a.k", try doc.createScalar("2", .plain));
        const out = try doc.write(allocator);
        defer allocator.free(out);
        try std.testing.expectEqualStrings("a: &x\n  k: 2\nb: *x\n", out);

        var re = try Document.parse(allocator, out);
        defer re.deinit();
        try std.testing.expectEqualStrings("2", re.pathGet(&.{ "b", "k" }).?.scalarValue().?);
    }
}

test "a following entry is not captured by an indicator-only line above it" {
    const allocator = std.testing.allocator;

    // Found by the fuzz harness's edited-output-must-reparse oracle
    // (seed 3004 and others), and NOT CR-specific despite first
    // appearing that way — plain LF reproduces identically.
    //
    // `markup.entryStart` walks back from a key to the `-`/`?` that
    // introduces it, and accepts an indicator sitting alone on the
    // previous line (the `-\n  content` shape). It required only that
    // nothing but blanks precede the indicator, never that the content
    // be indented UNDER it. So in
    //
    //     a: 1
    //     b:
    //       - <- trailing blank, nothing else on the line
    //     c: 1
    //
    // key `c` at column 0 was given the entry_start of the `-` at
    // column 2. Emitting `c` then re-wrote the item, and deleting `$.a`
    // produced `b:\n  - \n- \nc: 1\n`, which does not reparse.
    //
    // A block entry's content always sits deeper than its indicator, so
    // content at the same or a lower column belongs to an enclosing
    // collection instead.
    const cases = [_]struct { input: []const u8, path: []const u8 }{
        .{ .input = "a: 1\nb:\n  - \nc: 1\n", .path = "$.a" },
        .{ .input = "a: 1\nb:\n  - x\n  - \nc: 1\n", .path = "$.a" },
        .{ .input = "a: \rb:\r  - \rc:\r", .path = "$.a" },
        .{ .input = "a: 1\nb:\n  ? \nc: 1\n", .path = "$.a" },
    };
    for (cases) |c| {
        var doc = try Document.parse(allocator, c.input);
        defer doc.deinit();

        // Unedited round trip was always exact; assert it stays so.
        const plain = try doc.write(allocator);
        defer allocator.free(plain);
        try std.testing.expectEqualStrings(c.input, plain);

        var ed = Editor.init(&doc);
        ed.delete(c.path) catch |err| {
            // A shape this parser rejects is not this test's business.
            if (err == error.UnknownPath) continue;
            return err;
        };
        const out = try doc.write(allocator);
        defer allocator.free(out);

        var re = try Document.parse(allocator, out);
        defer re.deinit();
        const again = try re.write(allocator);
        defer allocator.free(again);
        try std.testing.expectEqualStrings(out, again);
        try std.testing.expect(re.pathGet(&.{"a"}) == null);
    }

    // The genuine indicator-alone shape still resolves to the
    // indicator: content indented under it belongs to it.
    {
        var doc = try Document.parse(allocator, "x:\n  -\n    k: 1\ny: 2\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.delete("$.y");
        const out = try doc.write(allocator);
        defer allocator.free(out);
        var re = try Document.parse(allocator, out);
        defer re.deinit();
    }
}

test "an edit in a CR-terminated document does not duplicate an entry" {
    const allocator = std.testing.allocator;

    // Found by the fuzz harness (seed 3004 and friends, via the
    // edited-output-must-reparse oracle).
    //
    // `markup.entryStart` walks back from a key to find the `-` or `?`
    // that introduces it, and stepped back TWO bytes over a `\r`,
    // assuming it was the LF of a CRLF. For a lone CR that lands inside
    // the previous line, so in `a: 1\rb:\r  - x\rc:\r` the key `c`
    // looked as though it sat under the `-` at offset 10. Its
    // entry_start pointed there, and emitting the entry re-wrote `- x`:
    //
    //   delete $.a  ->  b:\r  - x\n- x\rc:\r
    //
    // Duplicated content, an LF injected into a CR document, and output
    // that does not reparse. The unedited round trip was unaffected
    // (the whole region is one verbatim slice), which is why no
    // round-trip gate saw it.
    const cases = [_]struct { input: []const u8, path: []const u8 }{
        .{ .input = "a: 1\rb:\r  - x\rc:\r", .path = "$.a" },
        .{ .input = "a: 1\rb:\r  - x\rb:\r", .path = "$.a" },
        .{ .input = "a: 1\rb:\r  - x\r  - y\rc:\r", .path = "$.a" },
    };
    for (cases) |c| {
        var doc = try Document.parse(allocator, c.input);
        defer doc.deinit();

        // The unedited round trip was always fine; assert it stays so.
        const plain = try doc.write(allocator);
        defer allocator.free(plain);
        try std.testing.expectEqualStrings(c.input, plain);

        var ed = Editor.init(&doc);
        try ed.delete(c.path);
        const out = try doc.write(allocator);
        defer allocator.free(out);

        // No LF smuggled into a CR document.
        try std.testing.expect(std.mem.indexOfScalar(u8, out, '\n') == null);
        // And the result reads back.
        var re = try Document.parse(allocator, out);
        defer re.deinit();
        const again = try re.write(allocator);
        defer allocator.free(again);
        try std.testing.expectEqualStrings(out, again);
    }

    // The CRLF and LF spellings of the same shape, which must be
    // untouched by the terminator arithmetic.
    for ([_][]const u8{ "a: 1\r\nb:\r\n  - x\r\nc:\r\n", "a: 1\nb:\n  - x\nc:\n" }) |input| {
        var doc = try Document.parse(allocator, input);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.delete("$.a");
        const out = try doc.write(allocator);
        defer allocator.free(out);
        var re = try Document.parse(allocator, out);
        defer re.deinit();
        try std.testing.expect(re.pathGet(&.{"a"}) == null);
        try std.testing.expect(re.pathGet(&.{"c"}) != null);
    }
}

test "an edit that would strand an alias is refused, not silently corrupting" {
    const allocator = std.testing.allocator;

    // Found by the fuzz harness's edited-output-must-reparse oracle
    // (seed 2001, iteration 15828, input `- &v 42\r- *v\r`).
    //
    // An anchor lives on the node that defines it. Deleting or replacing
    // that node while `*v` survives emitted a document that does not
    // parse — `error.UnknownAlias` on the way back in. Silent corruption
    // through a public API. The preservation sweep knew about the shape
    // and *skipped* those positions ("deleting it would leave the
    // aliases dangling") rather than asserting anything, so nothing
    // caught that the output was unreadable.
    const refused = [_]struct { input: []const u8, path: []const u8 }{
        .{ .input = "- &v 42\n- *v\n", .path = "$[0]" },
        .{ .input = "a: &v 42\nb: *v\n", .path = "$.a" },
        .{ .input = "a: &v [1, 2]\nb: *v\n", .path = "$.a" },
        .{ .input = "a: &v 42\nb: *v\nc: *v\n", .path = "$.a" },
    };
    for (refused) |c| {
        {
            var doc = try Document.parse(allocator, c.input);
            defer doc.deinit();
            var ed = Editor.init(&doc);
            try std.testing.expectError(error.AnchorReferenced, ed.delete(c.path));
            // Refused means unchanged, not half-applied.
            const out = try doc.write(allocator);
            defer allocator.free(out);
            try std.testing.expectEqualStrings(c.input, out);
        }
        {
            var doc = try Document.parse(allocator, c.input);
            defer doc.deinit();
            var ed = Editor.init(&doc);
            const v = try doc.createScalar("9", .plain);
            try std.testing.expectError(error.AnchorReferenced, ed.set(c.path, v));
        }
    }

    // What must still be allowed.
    {
        // Deleting the ALIAS is fine — the anchor stays.
        var doc = try Document.parse(allocator, "- &v 42\n- *v\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.delete("$[1]");
        const out = try doc.write(allocator);
        defer allocator.free(out);
        var re = try Document.parse(allocator, out);
        defer re.deinit();
    }
    {
        // An anchor nothing references can go.
        var doc = try Document.parse(allocator, "a: &v 42\nb: 1\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.delete("$.a");
        const out = try doc.write(allocator);
        defer allocator.free(out);
        try std.testing.expectEqualStrings("b: 1\n", out);
    }
    {
        // Setting a REFERENCED anchored node to a bare scalar is not a
        // no-op: `sameScalarPresentation` compares anchors, so `&v 42`
        // and a plain `42` differ and the set really would replace the
        // node and drop the anchor. Refusing is correct.
        //
        // The consequence is a real limitation, and it is the builder's,
        // not this guard's: `createScalar` cannot attach an anchor, so
        // there is no way to construct a replacement carrying `&v`.
        // Every set on a referenced anchor is therefore refused. That is
        // strictly better than the previous behaviour, which accepted it
        // and emitted a document that would not parse.
        var doc = try Document.parse(allocator, "a: &v 42\nb: *v\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        const bare = try doc.createScalar("42", .plain);
        try std.testing.expectError(error.AnchorReferenced, ed.set("$.a", bare));
        const out = try doc.write(allocator);
        defer allocator.free(out);
        try std.testing.expectEqualStrings("a: &v 42\nb: *v\n", out);
    }
    {
        // An anchored node NOTHING references can be replaced freely,
        // anchor and all.
        var doc = try Document.parse(allocator, "a: &v 42\nb: 1\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.set("$.a", try doc.createScalar("9", .plain));
        const out = try doc.write(allocator);
        defer allocator.free(out);
        var re = try Document.parse(allocator, out);
        defer re.deinit();
    }
}

test "deleting a sibling keeps the line break before a synthetic-key entry" {
    const allocator = std.testing.allocator;

    // Found by the fuzz harness's edited-output-must-reparse oracle
    // (smoke iteration 94).
    //
    // `: 1` is an entry whose key is a synthesized empty scalar, so its
    // span is a point borrowed from the following token rather than
    // bytes of its own. `emitPairEdited` skipped the whole leading-gap
    // block for such a key, and the gap is where the terminator
    // separating it from the previous entry lives. Delete any sibling
    // and that terminator vanished, joining two lines: the document
    // below emitted as `b:\n  - y: z: 1\n`, which does not reparse.
    //
    // Only the edited path reaches this — an untouched region is
    // emitted verbatim in one slice — so the round-trip gates could not
    // see it.
    const cases = [_]struct { input: []const u8, path: []const u8 }{
        .{ .input = "a: 1\nb:\n  - y: z\n: 1\n", .path = "$.a" },
        .{ .input = "a: 1\nb:\n  - y: z\n: 1\n", .path = "$.b" },
        .{ .input = "a: 1\nb:\n  y: z\n: 1\n", .path = "$.a" },
        .{ .input = "z: 0\na: 1\nb:\n  - y: z\n: 1\n", .path = "$.a" },
        .{ .input = "a: 1\nb:\n  - x\n  - y: z\n: 1\n", .path = "$.a" },
    };
    for (cases) |c| {
        var doc = try Document.parse(allocator, c.input);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.delete(c.path);

        const out = try doc.write(allocator);
        defer allocator.free(out);

        // The point of the test: an edit must never produce bytes this
        // library cannot read back.
        var re = try Document.parse(allocator, out);
        defer re.deinit();

        // And emission stays a fixpoint after the edit.
        const again = try re.write(allocator);
        defer allocator.free(again);
        try std.testing.expectEqualStrings(out, again);
    }
}

test "an alias to an enclosing anchor is a parsed cycle, and cannot abort the process" {
    const allocator = std.testing.allocator;

    // Eleven bytes. `&a` anchors the mapping, `*a` inside it aliases
    // back to it, so `resolveAlias` on the alias returns the enclosing
    // mapping and a naive `..key` descent revisits it forever. This is
    // spec-legal and parses: nothing rejects a cycle at parse time.
    //
    // Before the bound in the descent walk, this aborted the process
    // with a stack overflow — reachable from untrusted input through a
    // documented public path (`$..key`), which is exactly the threat
    // model SECURITY.md states.
    {
        var doc = try Document.parse(allocator, "&a {k: *a}\n");
        defer doc.deinit();

        // The cycle is real, not a parse quirk.
        const k = doc.pathGet(&.{"k"}).?;
        try std.testing.expect(k.isAlias());
        try std.testing.expect(k.resolveAlias() == doc.root.?);

        var ed = Editor.init(&doc);
        try std.testing.expectError(error.NestingTooDeep, ed.all("$..k"));
        try std.testing.expectError(error.NestingTooDeep, ed.one("$..k"));
    }

    // The sequence spelling of the same shape.
    {
        var doc = try Document.parse(allocator, "&a [*a]\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try std.testing.expectError(error.NestingTooDeep, ed.all("$..anything"));
    }

    // A non-cyclic alias still descends normally: the bound stops a
    // cycle, it does not break aliases.
    {
        var doc = try Document.parse(allocator, "base: &b {k: v}\nuse: *b\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        const hits = try ed.all("$..k");
        defer allocator.free(hits);
        // Walked under `base` and again through the alias under `use`,
        // but it is one node, so it is one match.
        try std.testing.expectEqual(@as(usize, 1), hits.len);
        try std.testing.expect(hits[0] == doc.pathGet(&.{ "base", "k" }).?);
        // Through the alias prefix alone, the walk must still reach it.
        const via = try ed.all("$.use..k");
        defer allocator.free(via);
        try std.testing.expectEqual(@as(usize, 1), via.len);
        try std.testing.expect(via[0] == hits[0]);
    }
}

/// `l0: &l0 x`, then `levels` lines `lN: &lN [*lN-1, ...]` of `fan`
/// aliases each: a few hundred bytes that name fan^levels paths.
fn aliasFan(allocator: std.mem.Allocator, fan: usize, levels: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "l0: &l0 x\n");
    for (1..levels + 1) |l| {
        try out.print(allocator, "l{d}: &l{d} [", .{ l, l });
        for (0..fan) |i| try out.print(allocator, "{s}*l{d}", .{ if (i > 0) ", " else "", l - 1 });
        try out.appendSlice(allocator, "]\n");
    }
    return out.toOwnedSlice(allocator);
}

test "a query through fanned-out aliases costs the document's size, not its paths" {
    // Descent resolves aliases, and a node reached a second time was
    // walked again: 20 levels of 10 aliases (~800 bytes) name 10^20
    // paths, and `all("$..x")` would never return -- through a public
    // query, from untrusted input. Wildcards multiplied the same way,
    // one expansion per alias to the same target.
    const allocator = testing.allocator;
    const input = try aliasFan(allocator, 10, 20);
    defer allocator.free(input);
    var doc = try Document.parse(allocator, input);
    defer doc.deinit();
    var ed = Editor.init(&doc);

    const none = try ed.all("$..nothing");
    defer allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);

    // Every `lN` key, once each, in document order.
    const keys = try ed.all("$..l0");
    defer allocator.free(keys);
    try testing.expectEqual(@as(usize, 1), keys.len);

    // Three wildcard steps below l20: each list holds ten aliases to the
    // same list, so there are ten distinct items at every depth.
    const items = try ed.all("$.l20[*][*][*]");
    defer allocator.free(items);
    try testing.expectEqual(@as(usize, 10), items.len);
    for (items, 0..) |a, i| {
        for (items[0..i]) |b| try testing.expect(a != b);
    }
}

test "the edit walks are depth-bounded on a built tree too" {
    const allocator = std.testing.allocator;

    var doc = Document.init(allocator);
    defer doc.deinit();
    const root = try doc.createMapping();
    doc.root = root;
    var cur = root;
    var i: usize = 0;
    while (i < 1200) : (i += 1) {
        const inner = try doc.createMapping();
        try doc.mappingAppend(cur, try doc.createScalar("k", .plain), inner);
        cur = inner;
    }

    var ed = Editor.init(&doc);
    try std.testing.expectError(error.NestingTooDeep, ed.all("$..k"));

    // `cloneTree` recurses structurally over the same tree.
    try std.testing.expectError(error.NestingTooDeep, cloneTree(&doc, root));
}

test "allocation failures in insert and move batches leak nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, insertMoveBatch, .{});
}

/// Insert and move are the allocation-heaviest edits (journal records,
/// tombstones, sequence bookkeeping). On any OOM the original tree must
/// survive intact and leak-free.
fn insertMoveBatch(allocator: std.mem.Allocator) !void {
    var doc = try Document.parse(allocator,
        \\from:
        \\  - alpha
        \\  - beta
        \\to:
        \\  items: []
        \\
    );
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.apply(&.{
        .{ .insert = .{
            .sequence = "$.from",
            .position = "$.from[1]",
            .value = try doc.createScalar("gamma", .plain),
            .before = true,
        } },
        .{ .move = .{ .from = "$.from[0]", .to = "$.to", .key = "moved" } },
        .{ .append = .{ .sequence = "$.from", .value = try doc.createScalar("delta", .plain) } },
    });
    const out = try doc.write(allocator);
    defer allocator.free(out);
}

test "allocation failures in a wildcard and filter delete leak nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, wildcardDeleteBatch, .{});
}

/// A delete with several matches resolves per container, collects and
/// de-duplicates its victims, then detaches each: every step allocates.
fn wildcardDeleteBatch(allocator: std.mem.Allocator) !void {
    var doc = try Document.parse(allocator,
        \\items:
        \\  - {k: 1, j: 1}
        \\  - {k: 2, j: 2}
        \\  - {k: 1, j: 3}
        \\m:
        \\  a: 1
        \\  b: 2
        \\
    );
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.apply(&.{
        .{ .delete = "$.items[?k=1]" },
        .{ .delete = "$.items[*].j" },
        .{ .delete = "$.m[*]" },
    });
    const out = try doc.write(allocator);
    defer allocator.free(out);
    try testing.expectEqualStrings("items:\n  - {k: 2}\nm:\n  {}\n", out);
}

test "a batch that fails at any allocation leaves the document byte-identical" {
    // `apply` edits in place and rolls back through its undo journal, so
    // every change a batch makes has to be undone exactly -- the list
    // entries, tombstones, parent links, spans and `modified` flags the
    // emitter reads. Fail the batch at each of its allocations in turn:
    // each time the tree must be in exactly the state a fresh parse gives
    // (bytes alone would not show it: an unmodified container is written
    // verbatim, whatever stale tombstones it carries).
    const src =
        \\# head
        \\a: 1  # keep
        \\items:
        \\  - x
        \\  - {k: 1}
        \\  - {k: 2}
        \\m: &m
        \\  p: 1
        \\  q: 2
        \\ref: *m
        \\flow: [1, 2, 3]
        \\
    ;
    const Batch = struct {
        fn make(doc: *Document, buf: []Edit) anyerror![]const Edit {
            const v1 = try doc.createScalar("X", .plain);
            const v2 = try doc.createScalar("Y", .plain);
            const v3 = try doc.createScalar("Z", .plain);
            const v4 = try doc.createScalar("W", .plain);
            const v5 = try doc.createScalar("V", .plain);
            // A replacement carrying the anchor `ref` names: the alias is
            // re-pointed at it, and that has to be undone too.
            const m2 = try doc.createMapping();
            try doc.mappingAppend(m2, try doc.createScalar("r", .plain), try doc.createScalar("1", .plain));
            try doc.setAnchor(m2, "m");
            const edits = [_]Edit{
                .{ .set = .{ .path = "$.a", .value = v1 } },
                .{ .set = .{ .path = "$.flow[1]", .value = v2 } },
                .{ .set = .{ .path = "$.new", .value = v3 } },
                .{ .delete = "$.items[?k=1]" },
                .{ .insert = .{ .sequence = "$.items", .position = "$.items[0]", .value = v4, .before = true } },
                .{ .delete = "$.m.q" },
                .{ .set = .{ .path = "$.m", .value = m2 } },
                .{ .move = .{ .from = "$.items[1]", .to = "$.flow" } },
                .{ .append = .{ .sequence = "$.items", .value = v5 } },
            };
            @memcpy(buf[0..edits.len], &edits);
            return buf[0..edits.len];
        }
    };
    try testing.expect(try rollbackAtEveryAllocation(src, Batch.make) > 20);

    // A batch that fails on an edit's own terms, after replacing the
    // whole root, is rolled back the same way.
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try testing.expectError(error.AmbiguousOperation, ed.apply(&.{
        .{ .set = .{ .path = "$", .value = try doc.createScalar("gone", .plain) } },
        .{ .set = .{ .path = "$[*]", .value = try doc.createScalar("X", .plain) } },
    }));
    var fresh = try Document.parse(testing.allocator, src);
    defer fresh.deinit();
    try expectSameState(doc.root.?, fresh.root.?, doc.root.?, fresh.root.?);
}

test "a batch inside another atomic section is undone with it" {
    // `apply` inside an outer `internal.Transaction` hands its records
    // to the outer journal when it commits, so the outer section's
    // rollback undoes the batch too; a batch that fails (here at each of
    // its allocations, the hand-over included) undoes itself. Either
    // way, aborting the outer section restores the parsed state.
    const src = "a: 1\nitems: [x, y]\nm: {k: v}\n";
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = failing.allocator();
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        failing.fail_index = std.math.maxInt(usize);
        var doc = try Document.parse(allocator, src);
        defer doc.deinit();
        const v1 = try doc.createScalar("2", .plain);
        const v2 = try doc.createScalar("z", .plain);
        var ed = Editor.init(&doc);
        var txn: internal.Transaction = undefined;
        txn.begin(&doc);
        failing.fail_index = failing.alloc_index + fail_at;
        const result = ed.apply(&.{
            .{ .set = .{ .path = "$.a", .value = v1 } },
            .{ .delete = "$.items[0]" },
            .{ .append = .{ .sequence = "$.items", .value = v2 } },
            .{ .delete = "$.m.k" },
        });
        failing.fail_index = std.math.maxInt(usize);
        txn.abort();
        try testing.expect(doc.journal == null);
        var fresh = try Document.parse(allocator, src);
        defer fresh.deinit();
        try expectSameState(doc.root.?, fresh.root.?, doc.root.?, fresh.root.?);
        const out = try doc.write(allocator);
        defer allocator.free(out);
        try testing.expectEqualStrings(src, out);
        if (result) |_| break else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
    try testing.expect(fail_at > 5);
}

test "the journal undoes every other kind of change too" {
    // The paths the first batch does not take: a block item replaced
    // (remove then insert) by a same-document clone, intermediate
    // mappings created, a descent and a wildcard delete, a move into a
    // mapping, and the root replaced.
    const src =
        \\a: 1
        \\items:
        \\  - x
        \\  - {k: 1}
        \\m: &m
        \\  p: 1
        \\ref: *m
        \\flow: [1, 2]
        \\
    ;
    const Batch = struct {
        fn make(doc: *Document, buf: []Edit) anyerror![]const Edit {
            var ed = Editor.init(doc);
            const clone = try cloneTree(doc, try ed.one("$.m"));
            const root = try doc.createMapping();
            try doc.mappingAppend(root, try doc.createScalar("only", .plain), try doc.createScalar("1", .plain));
            const edits = [_]Edit{
                .{ .set = .{ .path = "$.items[0]", .value = clone } },
                .{ .set = .{ .path = "$.n1.n2.leaf", .value = try doc.createScalar("L", .plain) } },
                .{ .delete = "$..k" },
                .{ .delete = "$.flow[*]" },
                .{ .move = .{ .from = "$.a", .to = "$.m", .key = "moved" } },
                .{ .set = .{ .path = "$", .value = root } },
            };
            @memcpy(buf[0..edits.len], &edits);
            return buf[0..edits.len];
        }
    };
    try testing.expect(try rollbackAtEveryAllocation(src, Batch.make) > 20);
}

test "merge resolution that fails at any allocation leaves the tree as parsed" {
    const src =
        \\base: &b {a: 1, b: 2}
        \\more: &c {d: 4}
        \\use:
        \\  <<: [*b, *c]
        \\  e: 5
        \\
    ;
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = failing.allocator();
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        failing.fail_index = std.math.maxInt(usize);
        var doc = try Document.parse(allocator, src);
        defer doc.deinit();
        failing.fail_index = failing.alloc_index + fail_at;
        const result = doc.resolveMergeKeys();
        failing.fail_index = std.math.maxInt(usize);
        if (result) |_| break else |err| try testing.expectEqual(error.OutOfMemory, err);
        var fresh = try Document.parse(allocator, src);
        defer fresh.deinit();
        try expectSameState(doc.root.?, fresh.root.?, doc.root.?, fresh.root.?);
    }
    try testing.expect(fail_at > 3);
    // A budget refusal rolls back the same way.
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try testing.expectError(error.LimitExceeded, doc.resolveMergeKeysLimited(2));
    var fresh = try Document.parse(testing.allocator, src);
    defer fresh.deinit();
    try expectSameState(doc.root.?, fresh.root.?, doc.root.?, fresh.root.?);
}

/// Parse `src`, build a batch with `make` (its values are made before
/// anything fails), and apply it failing at each of its allocations in
/// turn: each time, the tree must be in exactly the state a fresh parse
/// gives. Returns how many allocation points were failed before the
/// batch ran through.
fn rollbackAtEveryAllocation(src: []const u8, make: *const fn (*Document, []Edit) anyerror![]const Edit) !usize {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = failing.allocator();
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        failing.fail_index = std.math.maxInt(usize);
        var doc = try Document.parse(allocator, src);
        defer doc.deinit();
        var buf: [16]Edit = undefined;
        const edits = try make(&doc, &buf);
        var ed = Editor.init(&doc);
        failing.fail_index = failing.alloc_index + fail_at;
        const result = ed.apply(edits);
        failing.fail_index = std.math.maxInt(usize);
        const out = try doc.write(allocator);
        defer allocator.free(out);
        if (result) |_| {
            // Every allocation point has been failed once; this run
            // allocated nothing that could fail, and succeeded.
            try testing.expect(!std.mem.eql(u8, src, out));
            return fail_at;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqualStrings(src, out);
            var fresh = try Document.parse(allocator, src);
            defer fresh.deinit();
            try expectSameState(doc.root.?, fresh.root.?, doc.root.?, fresh.root.?);
        }
    }
}

/// `a` (a rolled-back tree) is in the state `b` (a fresh parse of the
/// same text) is: same shape and scalars, same spans, `modified` flags,
/// tombstones and pair ends, every child's parent link pointing at its
/// container, and every alias naming the node at the same place.
fn expectSameState(a: *const Node, b: *const Node, a_root: *const Node, b_root: *const Node) !void {
    try testing.expectEqual(b.kind(), a.kind());
    try testing.expectEqual(b.modified, a.modified);
    try testing.expectEqual(b.src, a.src);
    try testing.expectEqual(b.anchor == null, a.anchor == null);
    switch (a.data) {
        .scalar => |s| try testing.expectEqualStrings(b.data.scalar.value, s.value),
        .alias => |al| {
            // The target, found by the same walk in both trees.
            try testing.expectEqual(pathIndex(b_root, b.data.alias.target), pathIndex(a_root, al.target));
        },
        .mapping => |m| {
            const bm = b.data.mapping;
            try testing.expectEqual(bm.pairs.items.len, m.pairs.items.len);
            try testing.expectEqualSlices([2]usize, bm.dropped.items, m.dropped.items);
            for (m.pairs.items, bm.pairs.items) |p, q| {
                try testing.expectEqual(q.src_end, p.src_end);
                try testing.expect(p.key.parent == a and p.value.parent == a);
                try expectSameState(p.key, q.key, a_root, b_root);
                try expectSameState(p.value, q.value, a_root, b_root);
            }
        },
        .sequence => |sq| {
            const bs = b.data.sequence;
            try testing.expectEqual(bs.items.items.len, sq.items.items.len);
            try testing.expectEqualSlices([2]usize, bs.dropped.items, sq.dropped.items);
            for (sq.items.items, bs.items.items) |x, y| {
                try testing.expect(x.parent == a);
                try expectSameState(x, y, a_root, b_root);
            }
        },
    }
}

/// The pre-order index of `target` under `root`, or null.
fn pathIndex(root: *const Node, target: *const Node) ?usize {
    var i: usize = 0;
    return pathIndexFrom(root, target, &i);
}

fn pathIndexFrom(node: *const Node, target: *const Node, i: *usize) ?usize {
    if (node == target) return i.*;
    i.* += 1;
    switch (node.data) {
        .mapping => |m| for (m.pairs.items) |p| {
            if (pathIndexFrom(p.key, target, i)) |r| return r;
            if (pathIndexFrom(p.value, target, i)) |r| return r;
        },
        .sequence => |sq| for (sq.items.items) |x| {
            if (pathIndexFrom(x, target, i)) |r| return r;
        },
        else => {},
    }
    return null;
}

test "allocation failures in a cross-document clone leak nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, crossDocumentClone, .{});
}

fn crossDocumentClone(allocator: std.mem.Allocator) !void {
    var a = try Document.parse(allocator, "keep:\n  x: [1, 2]\n  y: {z: 3}\n");
    defer a.deinit();
    var b = try Document.parse(allocator, "small: 1\n");
    defer b.deinit();
    const copy = try cloneTreeInto(&b, a.pathGet(&.{"keep"}).?);
    try b.pathSet(&.{"imported"}, copy);
    const out = try b.write(allocator);
    defer allocator.free(out);
    try testing.expectEqualStrings("small: 1\nimported:\n  x: [1, 2]\n  y: {z: 3}\n", out);
}

/// Delete `del`, then set `add` to a plain `Z`, both in memory, and
/// return the emitted bytes.
fn deleteThenSet(allocator: std.mem.Allocator, input: []const u8, del: []const u8, add: []const u8) ![]u8 {
    var doc = try Document.parse(allocator, input);
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.delete(del);
    try ed.set(add, try doc.createScalar("Z", .plain));
    return doc.write(allocator);
}

test "a deleted entry stays deleted when its emptied container gets a new one" {
    // Deleting the sole entry of a mapping empties it (`{}`); adding an
    // entry afterwards, without a reparse in between, re-emitted the
    // deleted line ahead of the new one -- the brand-new-entry path
    // copied "the rest of the open line" verbatim, and at the start of
    // a container that line is the tombstone. At the root the deleted
    // entry came back (`a: 1\nb: Z\n`); at the first item of a sequence
    // the new key was glued after the old one and did not parse.
    const cases = [_]struct { in: []const u8, del: []const u8, add: []const u8, out: []const u8 }{
        .{ .in = "a: 1\n", .del = "$.a", .add = "$.b", .out = "b: Z\n" },
        .{ .in = "a: 1\n", .del = "$.a", .add = "$.a", .out = "a: Z\n" },
        .{ .in = "a:\n  b:\n    c: 1\n  e: 3\n", .del = "$.a", .add = "$.a", .out = "a: Z\n" },
        .{ .in = "- c: 3\n- a: 1\n", .del = "$[0].c", .add = "$[0].c", .out = "- c: Z\n- a: 1\n" },
        .{ .in = "- a: 1\n  b: 2\n- c: 3\n", .del = "$[1].c", .add = "$[1].c", .out = "- a: 1\n  b: 2\n- c: Z\n" },
        .{ .in = "nav:\n  - Home: index.md\n  - Other: o.md\n", .del = "$.nav[0].Home", .add = "$.nav[0].Home", .out = "nav:\n  - Home: Z\n  - Other: o.md\n" },
        .{ .in = "a:\n  b: 1\nc: 2\n", .del = "$.a.b", .add = "$.a.b", .out = "a:\n  b: Z\nc: 2\n" },
        .{ .in = "# head\na: 1 # t\n# tail\n", .del = "$.a", .add = "$.b", .out = "# head\nb: Z\n# tail\n" },
    };
    for (cases) |c| {
        const out = try deleteThenSet(testing.allocator, c.in, c.del, c.add);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.out, out);
        // And what was written reads back as exactly that tree.
        var re = try Document.parse(testing.allocator, out);
        defer re.deinit();
        const again = try re.write(testing.allocator);
        defer testing.allocator.free(again);
        try testing.expectEqualStrings(out, again);
    }
}

test "a modified scalar or flow sequence item keeps its `- `" {
    // The item's `- ` lives in [entry_start, start). A block collection's
    // slot walk re-emits it with its first entry; a scalar or a flow
    // collection is written from `start`, and the indicator was simply
    // never written: `- {a: 1}` with `$[0].a` set came out as `{a: Z}`
    // at the parent's column, and a refilled `- {}` did not parse.
    const Case = struct { in: []const u8, edit: Edit, out: []const u8 };
    var docs: [6]Document = undefined;
    const cases = [_]Case{
        .{ .in = "- a: 1\n- {}\n", .edit = .{ .set = .{ .path = "$[1].c", .value = undefined } }, .out = "- a: 1\n- {c: Z}\n" },
        .{ .in = "- {a: 1}\n- b\n", .edit = .{ .set = .{ .path = "$[0].a", .value = undefined } }, .out = "- {a: Z}\n- b\n" },
        .{ .in = "- {a: 1}\n- b\n", .edit = .{ .set = .{ .path = "$[0].b", .value = undefined } }, .out = "- {a: 1, b: Z}\n- b\n" },
        .{ .in = "- [1]\n- b\n", .edit = .{ .append = .{ .sequence = "$[0]", .value = undefined } }, .out = "- [1, Z]\n- b\n" },
        .{ .in = "- - {}\n", .edit = .{ .set = .{ .path = "$[0][0].c", .value = undefined } }, .out = "- - {c: Z}\n" },
        .{ .in = "k:\n  - {}\n  - x\n", .edit = .{ .set = .{ .path = "$.k[0].c", .value = undefined } }, .out = "k:\n  - {c: Z}\n  - x\n" },
    };
    for (cases, 0..) |c, i| {
        docs[i] = try Document.parse(testing.allocator, c.in);
        var doc = &docs[i];
        defer doc.deinit();
        const z = try doc.createScalar("Z", .plain);
        var e = c.edit;
        switch (e) {
            .set => |*s| s.value = z,
            .append => |*a| a.value = z,
            else => unreachable,
        }
        var ed = Editor.init(doc);
        try ed.apply(&.{e});
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.out, out);
    }
    // A trailing comment written on a scalar item takes the same path.
    var doc = try Document.parse(testing.allocator, "- a\n- b\n");
    defer doc.deinit();
    try doc.setTrailingComment(doc.root.?.items().?[0], "# c");
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("- a # c\n- b\n", out);
}

test "an edit under a root that shares its line with `---` keeps the marker" {
    // `markup.entryStart` took the marker's third dash for a `- `
    // indicator, so the root's entry_start (and the document's
    // body_start) pointed inside `---`. An untouched root re-emitted
    // from there, dash and all; a modified one from its content, and
    // `--- {a: 1}` with `$.a` set to 2 was written `--{a: 2}`: valid
    // YAML meaning a mapping keyed `--{a`.
    const cases = [_]struct { in: []const u8, path: []const u8, out: []const u8 }{
        .{ .in = "--- {a: 1}\n", .path = "$.a", .out = "--- {a: 2}\n" },
        .{ .in = "--- [1, 2]\n", .path = "$[0]", .out = "--- [2, 2]\n" },
        .{ .in = "--- !!map {a: 1}\n", .path = "$.a", .out = "--- !!map {a: 2}\n" },
        .{ .in = "--- &r {a: 1}\n", .path = "$.a", .out = "--- &r {a: 2}\n" },
        .{ .in = "--- foo\n", .path = "$", .out = "--- 2\n" },
        .{ .in = "--- {a: 1} # c\n", .path = "$.a", .out = "--- {a: 2} # c\n" },
        // Controls: the marker on its own line, and no marker.
        .{ .in = "---\n{a: 1}\n", .path = "$.a", .out = "---\n{a: 2}\n" },
        .{ .in = "{a: 1}\n", .path = "$.a", .out = "{a: 2}\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.in);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.set(c.path, try doc.createScalar("2", .plain));
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.out, out);
    }
}

test "edits inside a compact collection after an explicit `: ` keep the indicator" {
    // `? a` / `: - b` puts the value's first entry on the `: ` line. The
    // indicator belongs to the value, not to that entry, but a delete or
    // replace tombstoned the whole line with it (`? a\n  - X`, a
    // different tree), and a re-emitted value broke its line after the
    // `: `, leaving mis-indented entries that did not parse.
    const Case = struct { in: []const u8, edit: Edit, out: []const u8 };
    const x: *Node = undefined; // replaced per case below
    const cases = [_]Case{
        .{ .in = "? a\n: - b\n  - c\n", .edit = .{ .set = .{ .path = "$.a[0]", .value = x } }, .out = "? a\n: - X\n  - c\n" },
        .{ .in = "? a\n: - b\n  - c\n", .edit = .{ .set = .{ .path = "$.a[1]", .value = x } }, .out = "? a\n: - b\n  - X\n" },
        .{ .in = "? a\n: - b\n  - c\n", .edit = .{ .delete = "$.a[0]" }, .out = "? a\n: - c\n" },
        .{ .in = "? a\n: - b\n  - c\n", .edit = .{ .delete = "$.a[1]" }, .out = "? a\n: - b\n" },
        .{ .in = "? a\n: - b\n  - c\n", .edit = .{ .append = .{ .sequence = "$.a", .value = x } }, .out = "? a\n: - b\n  - c\n  - X\n" },
        .{ .in = "? a\n: x: 1\n  y: 2\n", .edit = .{ .set = .{ .path = "$.a.x", .value = x } }, .out = "? a\n: x: X\n  y: 2\n" },
        .{ .in = "? a\n: x: 1\n  y: 2\n", .edit = .{ .set = .{ .path = "$.a.y", .value = x } }, .out = "? a\n: x: 1\n  y: X\n" },
        .{ .in = "? a\n: x: 1\n  y: 2\n", .edit = .{ .delete = "$.a.x" }, .out = "? a\n: y: 2\n" },
        .{ .in = "? a\n: x: 1\n  y: 2\n", .edit = .{ .delete = "$.a.y" }, .out = "? a\n: x: 1\n" },
        .{ .in = "? a\n: x: 1\n  y: 2\n", .edit = .{ .set = .{ .path = "$.a.z", .value = x } }, .out = "? a\n: x: 1\n  y: 2\n  z: X\n" },
        .{ .in = "- ? a\n  : x: 1\n    y: 2\n", .edit = .{ .set = .{ .path = "$[0].a.y", .value = x } }, .out = "- ? a\n  : x: 1\n    y: X\n" },
        .{ .in = "- ? a\n  : x: 1\n    y: 2\n", .edit = .{ .delete = "$[0].a.x" }, .out = "- ? a\n  : y: 2\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.in);
        defer doc.deinit();
        const v = try doc.createScalar("X", .plain);
        var e = c.edit;
        switch (e) {
            .set => |*st| st.value = v,
            .append => |*ap| ap.value = v,
            else => {},
        }
        var ed = Editor.init(&doc);
        try ed.apply(&.{e});
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.out, out);
        var again = try Document.parse(testing.allocator, out);
        again.deinit();
    }
    // A key that is a compact collection after `? `: modifying it wrote
    // the `? ` for the key and again with its first entry (`? ? - x`).
    var doc = try Document.parse(testing.allocator, "? - x\n  - y\n: v\n");
    defer doc.deinit();
    try doc.setAnchor(doc.root.?.pairs().?[0].key.items().?[1], "z");
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("? - x\n  - &z y\n: v\n", out);
}

test "emptying a container keeps the comments between its entries" {
    // `{}` / `[]` alone ate every comment line the deleted entries had
    // between them, although deleting the entries one at a time kept
    // every one of them. The surviving lines are written verbatim and
    // the empty collection follows on its own line at the value's column.
    const cases = [_]struct { in: []const u8, dels: []const []const u8, out: []const u8 }{
        .{ .in = "a: 1\n# note\nb: 2\n", .dels = &.{ "$.a", "$.b" }, .out = "# note\n{}\n" },
        .{ .in = "a: 1\n# note\nb: 2\n", .dels = &.{ "$.b", "$.a" }, .out = "# note\n{}\n" },
        .{ .in = "# lead a\na: 1\n# lead b\nb: 2\n", .dels = &.{ "$.b", "$.a" }, .out = "# lead a\n# lead b\n{}\n" },
        .{ .in = "m:\n  a: 1\n  # note\n  b: 2\nn: 3\n", .dels = &.{ "$.m.a", "$.m.b" }, .out = "m:\n  # note\n  {}\nn: 3\n" },
        .{ .in = "- 1\n# note\n- 2\n", .dels = &.{ "$[1]", "$[0]" }, .out = "# note\n[]\n" },
        .{ .in = "s:\n  - 1\n  # note\n  - 2\nn: 3\n", .dels = &.{ "$.s[1]", "$.s[0]" }, .out = "s:\n  # note\n  []\nn: 3\n" },
        // The item's `-` stays on its own line (the comment between the
        // entries kept the successor from moving up), then the comment,
        // then the `{}` at the entries' column.
        .{ .in = "- a: 1\n  # note\n  b: 2\n- x\n", .dels = &.{ "$[0].a", "$[0].b" }, .out = "-\n  # note\n  {}\n- x\n" },
        // Blank lines alone are not worth keeping around an empty value.
        .{ .in = "a: 1\n\nb: 2\n", .dels = &.{ "$.a", "$.b" }, .out = "{}\n" },
        .{ .in = "a: 1 # c\n", .dels = &.{"$.a"}, .out = "{}\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.in);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        for (c.dels) |d| try ed.delete(d);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.out, out);
        var re = try Document.parse(testing.allocator, out);
        defer re.deinit();
        const again = try re.write(testing.allocator);
        defer testing.allocator.free(again);
        try testing.expectEqualStrings(out, again);
    }
}

test "a leading comment written on the first item does not open with a blank line" {
    var doc = try Document.parse(testing.allocator, "- {a: 1}\n- b\n");
    defer doc.deinit();
    try doc.setLeadingComments(doc.root.?.items().?[0], "# lead");
    var ed = Editor.init(&doc);
    try ed.set("$[0].b", try doc.createScalar("Z", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# lead\n- {a: 1, b: Z}\n- b\n", out);
}

test "emptying a nested block sequence keeps the outer item's `- `" {
    // `dropItemSpan` kept the outer indicator only when a successor could
    // move up onto its line. Deleting the LAST inner item took the whole
    // line, outer `- ` included: `- - x` minus `$[0][0]` emitted a bare
    // `[]`, and nested under a key the `[]` landed at the parent's
    // column, which does not parse.
    const cases = [_]struct { in: []const u8, dels: []const []const u8, out: []const u8 }{
        .{ .in = "- - x\n", .dels = &.{"$[0][0]"}, .out = "- []\n" },
        .{ .in = "- - x\n- z\n", .dels = &.{"$[0][0]"}, .out = "- []\n- z\n" },
        .{ .in = "- - x\n  - y\n", .dels = &.{ "$[0][1]", "$[0][0]" }, .out = "- []\n" },
        .{ .in = "k:\n  - - x\n    - y\n  - z\n", .dels = &.{ "$.k[0][1]", "$.k[0][0]" }, .out = "k:\n  - []\n  - z\n" },
        .{ .in = "list:\n  - a\n  - - nested\n    - sequence\n", .dels = &.{ "$.list[1][1]", "$.list[1][0]" }, .out = "list:\n  - a\n  - []\n" },
        // A comment between the inner items: the outer `-` stays on
        // its own line and the successor stays put under the comment.
        .{ .in = "- - x\n  # c\n  - y\n", .dels = &.{"$[0][0]"}, .out = "-\n  # c\n  - y\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.in);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        for (c.dels) |d| try ed.delete(d);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.out, out);
        var re = try Document.parse(testing.allocator, out);
        defer re.deinit();
    }
}

test "an aliased scalar gets a new value through a replacement carrying its anchor" {
    // The anchor lives on the node, so replacing an anchored scalar used
    // to be refused outright (AnchorReferenced) -- an aliased scalar was
    // immutable while referenced, and nothing could build a replacement
    // with an anchor. `setAnchor` builds one; `set` treats a replacement
    // carrying the replaced node's anchor as the anchor moving with the
    // slot, and points the aliases at it.
    {
        var doc = try Document.parse(testing.allocator, "a: &x 1\nb: *x\nc: 3\n");
        defer doc.deinit();
        const two = try doc.createScalar("2", .plain);
        try doc.setAnchor(two, "x");
        var ed = Editor.init(&doc);
        try ed.set("$.a", two);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("a: &x 2\nb: *x\nc: 3\n", out);
        // The in-memory alias follows: no stale pre-replacement target.
        try testing.expectEqualStrings("2", (try ed.one("$.b")).scalarValue().?);
        try testing.expect((try ed.one("$.b")).resolveAlias() == try ed.one("$.a"));
        var re = try Document.parse(testing.allocator, out);
        defer re.deinit();
        var red = Editor.init(&re);
        try testing.expectEqualStrings("2", (try red.one("$.b")).scalarValue().?);
    }
    // Same at a sequence index, and for an anchored mapping's own anchor.
    {
        var doc = try Document.parse(testing.allocator, "- &x 1\n- *x\n");
        defer doc.deinit();
        const two = try doc.createScalar("2", .plain);
        try doc.setAnchor(two, "x");
        var ed = Editor.init(&doc);
        try ed.set("$[0]", two);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("- &x 2\n- *x\n", out);
    }
    {
        var doc = try Document.parse(testing.allocator, "a: &m\n  k: 1\nb: *m\n");
        defer doc.deinit();
        const fresh = try doc.createMapping();
        try doc.mappingAppend(fresh, try doc.createScalar("j", .plain), try doc.createScalar("2", .plain));
        try doc.setAnchor(fresh, "m");
        var ed = Editor.init(&doc);
        try ed.set("$.a", fresh);
        try testing.expectEqualStrings("2", (try ed.one("$.b.j")).scalarValue().?);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        var re = try Document.parse(testing.allocator, out);
        defer re.deinit();
        var red = Editor.init(&re);
        try testing.expectEqualStrings("2", (try red.one("$.b.j")).scalarValue().?);
    }
    // A replacement WITHOUT the anchor is still a stranding, refused.
    {
        var doc = try Document.parse(testing.allocator, "a: &x 1\nb: *x\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try testing.expectError(error.AnchorReferenced, ed.set("$.a", try doc.createScalar("2", .plain)));
        // A different anchor name does not move it either.
        const other = try doc.createScalar("2", .plain);
        try doc.setAnchor(other, "y");
        try testing.expectError(error.AnchorReferenced, ed.set("$.a", other));
    }
}

test "setAnchor defines, clears and refuses what would strand an alias" {
    var doc = try Document.parse(testing.allocator, "a: &x 1\nb: *x\nc: 3\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    const a = try ed.one("$.a");
    const c = try ed.one("$.c");
    // Clearing or renaming a referenced anchor strands `*x`.
    try testing.expectError(error.AnchorReferenced, doc.setAnchor(a, null));
    try testing.expectError(error.AnchorReferenced, doc.setAnchor(a, "y"));
    // Re-setting the same name is a no-op, byte for byte.
    try doc.setAnchor(a, "x");
    const same = try doc.write(testing.allocator);
    defer testing.allocator.free(same);
    try testing.expectEqualStrings("a: &x 1\nb: *x\nc: 3\n", same);
    // Defining one on an unanchored node re-emits it with the anchor.
    try doc.setAnchor(c, "k");
    const defined = try doc.write(testing.allocator);
    defer testing.allocator.free(defined);
    try testing.expectEqualStrings("a: &x 1\nb: *x\nc: &k 3\n", defined);
    // ... and clearing an unreferenced one takes it away again.
    try doc.setAnchor(c, null);
    const cleared = try doc.write(testing.allocator);
    defer testing.allocator.free(cleared);
    try testing.expectEqualStrings("a: &x 1\nb: *x\nc: 3\n", cleared);
    // The anchor alphabet: no blanks, no flow indicators, not empty.
    try testing.expectError(error.InvalidSyntax, doc.setAnchor(c, ""));
    try testing.expectError(error.InvalidSyntax, doc.setAnchor(c, "a b"));
    try testing.expectError(error.InvalidSyntax, doc.setAnchor(c, "a,b"));
    try testing.expectError(error.InvalidSyntax, doc.setAnchor(c, "[a]"));
}

test "an alias to an anchored scalar survives a clone pointing into the clone" {
    // `cloneNode` re-registered anchors only for collections, so after
    // any `apply` (which then cloned the tree) an alias to a SCALAR still
    // pointed at the pre-clone node -- harmless while scalars were
    // immutable, wrong the moment a replacement could carry the anchor
    // over. `apply` no longer clones; the alias must still resolve.
    var doc = try Document.parse(testing.allocator, "a: &x 1\nb: *x\nc: 3\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.set("$.c", try doc.createScalar("4", .plain));
    try testing.expect((try ed.one("$.b")).resolveAlias() == try ed.one("$.a"));
}

test "deleting an explicit-key entry removes its `? ` indicator too" {
    // The tombstone kept everything up to the key text, treating `? `
    // like a sequence item's `- ` indicator that outlives the entry. It
    // does not: a bare `? ` left behind reads back as a null key.
    const cases = [_]struct { in: []const u8, del: []const u8, out: []const u8 }{
        .{ .in = "? a\n: 1\n? b\n: 2\n", .del = "$.b", .out = "? a\n: 1\n" },
        .{ .in = "? a\n: 1\n? b\n: 2\n", .del = "$.a", .out = "? b\n: 2\n" },
        .{ .in = "? a\n: 1\nb: 2\n", .del = "$.a", .out = "b: 2\n" },
        .{ .in = "a: 1\n? b\n: 2\n", .del = "$.b", .out = "a: 1\n" },
        .{ .in = "? a\n: 1\n", .del = "$.a", .out = "{}\n" },
        // A `- ` in front of an explicit key still belongs to the item.
        .{ .in = "- ? a\n  : 1\n- b\n", .del = "$[0].a", .out = "- {}\n- b\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.in);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.delete(c.del);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.out, out);
    }
}

test "a trailing descent delete removes every match" {
    var doc = try Document.parse(testing.allocator,
        \\k: 1
        \\inner:
        \\  k: 2
        \\  deep:
        \\    k: 3
        \\other: 4
        \\
    );
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.apply(&.{.{ .delete = "$..k" }});
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    // `deep` empties into `{}`, stepped in from its key like every
    // emptied container.
    try testing.expectEqualStrings("inner:\n  deep:\n    {}\nother: 4\n", out);

    // Re-parse: the value tree holds exactly what survived.
    var re = try Document.parse(testing.allocator, out);
    defer re.deinit();
    try testing.expect(re.pathGet(&.{"k"}) == null);
    try testing.expect(re.pathGet(&.{ "inner", "k" }) == null);
    try testing.expectEqualStrings("4", re.pathGet(&.{"other"}).?.scalarValue().?);
}

test "a wildcard or filter delete removes every match" {
    // `one` answers UnknownPath for several matches as well as none, and
    // delete took any error for "no match": a delete matching several
    // nodes reported success and removed nothing, while one matching a
    // single node reached a final-segment switch that knew only keys and
    // indices, and failed with AmbiguousOperation.
    const cases = [_]struct { in: []const u8, path: []const u8, out: []const u8 }{
        // [*] over 3, 1 and 0 items.
        .{ .in = "items:\n  - a\n  - b\n  - c\nk: v\n", .path = "$.items[*]", .out = "items:\n  []\nk: v\n" },
        .{ .in = "items:\n  - a\nk: v\n", .path = "$.items[*]", .out = "items:\n  []\nk: v\n" },
        .{ .in = "items: []\nk: v\n", .path = "$.items[*]", .out = "items: []\nk: v\n" },
        // [?k=v] with 2, 1 and 0 matches.
        .{ .in = "items:\n  - {k: 1}\n  - {k: 1}\n  - {k: 2}\n", .path = "$.items[?k=1]", .out = "items:\n  - {k: 2}\n" },
        .{ .in = "items:\n  - {k: 1}\n  - {k: 2}\n", .path = "$.items[?k=1]", .out = "items:\n  - {k: 2}\n" },
        .{ .in = "items:\n  - {k: 1}\n  - {k: 2}\n", .path = "$.items[?k=9]", .out = "items:\n  - {k: 1}\n  - {k: 2}\n" },
        // Mappings: [*] takes every entry, [?k=v] every matching value
        // -- by identity, so of two entries with the same key only the
        // matching one goes.
        .{ .in = "m:\n  a: 1\n  b: 2\nk: v\n", .path = "$.m[*]", .out = "m:\n  {}\nk: v\n" },
        .{ .in = "a: {k: 1}\na: {k: 2}\nb: {k: 1}\n", .path = "$[?k=1]", .out = "a: {k: 2}\n" },
        // In the middle of a path: each item's `k`.
        .{ .in = "items:\n  - k: 1\n    j: 1\n  - k: 2\n    j: 2\n", .path = "$.items[*].k", .out = "items:\n  - j: 1\n  - j: 2\n" },
        .{ .in = "items:\n  - k: 1\n    j: 1\n", .path = "$.items[*].k", .out = "items:\n  - j: 1\n" },
        // An alias item goes like any other; its anchor stays.
        .{ .in = "a: &x 1\nitems: [*x, 2]\n", .path = "$.items[*]", .out = "a: &x 1\nitems: []\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.in);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.delete(c.path);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.out, out);
        // And nothing the path matches is left.
        var re = try Document.parse(testing.allocator, out);
        defer re.deinit();
        var red = Editor.init(&re);
        const left = try red.all(c.path);
        defer testing.allocator.free(left);
        try testing.expectEqual(@as(usize, 0), left.len);
    }
}

test "a wildcard delete refuses atomically, and not through an alias" {
    const cases = [_]struct { in: []const u8, path: []const u8, err: Error }{
        // An anchored item an alias still names: nothing is removed,
        // not even the items before it.
        .{ .in = "items:\n  - a\n  - &x b\n  - c\nref: *x\n", .path = "$.items[*]", .err = error.AnchorReferenced },
        .{ .in = "items:\n  - {k: 1}\n  - &x {k: 1}\nref: *x\n", .path = "$.items[?k=1]", .err = error.AnchorReferenced },
        // Writes do not forward through an alias, whatever the count.
        .{ .in = "a: &s [1, 2]\nb: *s\n", .path = "$.b[*]", .err = error.AliasPath },
        .{ .in = "a: &s [{k: 1}]\nb: *s\n", .path = "$.b[?k=1]", .err = error.AliasPath },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.in);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try testing.expectError(c.err, ed.delete(c.path));
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.in, out);
    }
    // In a batch: a later failing edit rolls the deletes back too.
    const src = "items:\n  - a\n  - b\nk: v\n";
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try testing.expectError(error.AmbiguousOperation, ed.apply(&.{
        .{ .delete = "$.items[*]" },
        .{ .set = .{ .path = "$[*]", .value = try doc.createScalar("x", .plain) } },
    }));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
    // An anchored item nobody references is simply deleted.
    var doc2 = try Document.parse(testing.allocator, "items:\n  - &x a\n  - b\n");
    defer doc2.deinit();
    var ed2 = Editor.init(&doc2);
    try ed2.delete("$.items[*]");
    const out2 = try doc2.write(testing.allocator);
    defer testing.allocator.free(out2);
    try testing.expectEqualStrings("items:\n  []\n", out2);
}

test "descent reports a node reached through an alias once" {
    // `$..k` walks `a` directly and again through `b: *x`; the `k`
    // under `a` is one node and must be one match, or a per-match edit
    // over `ed.all` double-applies. Under the alias prefix (`$.b..k`)
    // the walk still has to go through the alias to find it at all.
    var doc = try Document.parse(testing.allocator, "a: &x\n  k: 1\nb: *x\nc:\n  k: 2\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);

    const all = try ed.all("$..k");
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expect(all[0] != all[1]);
    try testing.expectEqualStrings("1", all[0].scalarValue().?);
    try testing.expectEqualStrings("2", all[1].scalarValue().?);

    const via_alias = try ed.all("$.b..k");
    defer testing.allocator.free(via_alias);
    try testing.expectEqual(@as(usize, 1), via_alias.len);
    try testing.expect(via_alias[0] == all[0]);

    // And a descent delete over the same tree removes each once.
    try ed.delete("$..k");
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: &x {}\nb: *x\nc:\n  {}\n", out);
}

test "descent delete with one match is a delete, not an error" {
    var doc = try Document.parse(testing.allocator, "a: 1\ninner:\n  k: 1\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.delete("$..k");
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: 1\ninner:\n  {}\n", out);
}

test "descent delete with no match stays a no-op" {
    const src = "a: 1\n";
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.delete("$..missing");
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "descent delete refuses atomically when a victim would strand an alias" {
    const src = "keep: 1\nk: &x 2\nref: *x\nother:\n  k: 3\n";
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try testing.expectError(error.AnchorReferenced, ed.delete("$..k"));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    // Nothing was removed: the batch rolled back whole.
    try testing.expectEqualStrings(src, out);
}

test "descent delete under a prefix removes matches only within it" {
    var doc = try Document.parse(testing.allocator,
        \\out:
        \\  k: 1
        \\in:
        \\  k: 2
        \\
    );
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.delete("$..in..k");
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("out:\n  k: 1\nin:\n  {}\n", out);
}

test "a write through an alias is refused at any depth, not only the last" {
    // `error.AliasPath` fired only when the IMMEDIATE container was the
    // alias: one level deeper the write went through it and edited the
    // anchored node every alias shares.
    for ([_][]const u8{
        "a: &x {k: 1, inner: {j: 2}, list: [1]}\nb: *x\n",
        "a: &x\n  k: 1\n  inner:\n    j: 2\n  list:\n    - 1\nb: *x\n",
    }) |src| {
        var doc = try Document.parse(testing.allocator, src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        const v = try doc.createScalar("9", .plain);
        const edits = [_]Edit{
            .{ .delete = "$.b.k" },
            .{ .delete = "$.b.inner.j" },
            .{ .delete = "$.b.inner[*]" },
            .{ .delete = "$.b..j" },
            .{ .set = .{ .path = "$.b.inner.j", .value = v } },
            .{ .set = .{ .path = "$.b.inner.new", .value = v } },
            .{ .set = .{ .path = "$.b.list[0]", .value = v } },
            .{ .append = .{ .sequence = "$.b.list", .value = v } },
            .{ .insert = .{ .sequence = "$.b.list", .position = "$.b.list[0]", .value = v, .before = true } },
            .{ .move = .{ .from = "$.b.inner.j", .to = "$", .key = "z" } },
            .{ .move = .{ .from = "$.a.k", .to = "$.b.inner", .key = "z" } },
        };
        for (edits) |e| {
            try testing.expectError(error.AliasPath, ed.apply(&.{e}));
            const out = try doc.write(testing.allocator);
            defer testing.allocator.free(out);
            try testing.expectEqualStrings(src, out);
        }
        // Reads still go through, and the anchor side is writable.
        try testing.expectEqualStrings("2", (try ed.one("$.b.inner.j")).scalarValue().?);
        try ed.set("$.a.inner.j", try doc.createScalar("3", .plain));
        try testing.expectEqualStrings("3", (try ed.one("$.b.inner.j")).scalarValue().?);
        // A descent over the whole document reaches the anchored node
        // directly first, so it deletes there.
        try ed.delete("$..j");
        try testing.expectError(error.UnknownPath, ed.one("$.a.inner.j"));
    }
}

test "deleting or moving an anchored KEY is refused, not silently corrupting" {
    const allocator = testing.allocator;

    // Regression: the stranding guard inspected only the pair's VALUE, but
    // a mapping pair is removed key and all. `&k key: 1\nref: *k` with
    // `$.key` deleted emitted `ref: *k` with no `&k`, which fails to
    // reparse with `error.UnknownAlias`.
    const src = "&k key: 1\nref: *k\n";
    {
        var doc = try Document.parse(allocator, src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try testing.expectError(error.AnchorReferenced, ed.delete("$.key"));
        const out = try doc.write(allocator);
        defer allocator.free(out);
        try testing.expectEqualStrings(src, out);
    }
    {
        // A move detaches the whole pair too, so the key is guarded there.
        var doc = try Document.parse(allocator, src);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try testing.expectError(error.AnchorReferenced, ed.apply(&.{.{ .move = .{
            .from = "$.key",
            .to = "$.ref",
        } }}));
    }
    {
        // An UNREFERENCED key anchor still deletes: the guard must not
        // over-refuse.
        var doc = try Document.parse(allocator, "&k key: 1\nother: 2\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try ed.delete("$.key");
        const out = try doc.write(allocator);
        defer allocator.free(out);
        try testing.expectEqualStrings("other: 2\n", out);
    }
    {
        // The value-side guard still works (the original finding).
        var doc = try Document.parse(allocator, "a: &v 1\nb: *v\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try testing.expectError(error.AnchorReferenced, ed.delete("$.a"));
    }
}

test "a batch edit refuses a forward alias instead of stranding it" {
    const allocator = testing.allocator;
    // An alias whose anchor is defined LATER is valid only in a hand-built
    // tree. `apply` used to deep-clone the whole tree and failed there
    // (UnknownAlias); it now edits in place, and deleting the anchor the
    // alias names is refused like any stranding, leaving the tree as it
    // was.
    var doc = Document.init(allocator);
    defer doc.deinit();
    const root = try doc.createMapping();
    doc.root = root;

    const target = try doc.createScalar("v", .plain);
    const alias = try doc.createScalar("v", .plain);
    alias.data = .{ .alias = .{ .name = "a", .target = target } };
    try doc.mappingAppend(root, try doc.createScalar("use", .plain), alias);

    const anchored = try doc.createScalar("v", .plain);
    try doc.setAnchor(anchored, "a");
    try doc.mappingAppend(root, try doc.createScalar("def", .plain), anchored);

    var ed = Editor.init(&doc);
    try testing.expectError(error.AnchorReferenced, ed.apply(&.{.{ .delete = "$.def" }}));
    try testing.expectEqual(@as(usize, 2), root.pairs().?.len);
    // An edit that strands nothing runs.
    try ed.set("$.other", try doc.createScalar("1", .plain));
    try testing.expectEqual(@as(usize, 3), root.pairs().?.len);
}

/// Structural equality for the edit regression table: kind, scalar text,
/// anchor, tag and alias name, recursively.
fn sameTreeForTest(a: ?*const Node, b: ?*const Node) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    if (x.kind() != y.kind()) return false;
    if (!std.meta.eql(x.anchor == null, y.anchor == null)) return false;
    if (x.anchor) |n| if (!std.mem.eql(u8, n, y.anchor.?)) return false;
    if ((x.tag == null) != (y.tag == null)) return false;
    if (x.tag) |t| if (!std.mem.eql(u8, t, y.tag.?)) return false;
    return switch (x.data) {
        .scalar => |s| std.mem.eql(u8, s.value, y.data.scalar.value),
        .alias => |al| std.mem.eql(u8, al.name, y.data.alias.name),
        .mapping => |m| m.pairs.items.len == y.data.mapping.pairs.items.len and for (m.pairs.items, y.data.mapping.pairs.items) |p, q| {
            if (!sameTreeForTest(p.key, q.key) or !sameTreeForTest(p.value, q.value)) break false;
        } else true,
        .sequence => |sq| sq.items.items.len == y.data.sequence.items.items.len and for (sq.items.items, y.data.sequence.items.items) |i, j| {
            if (!sameTreeForTest(i, j)) break false;
        } else true,
    };
}

test "edits keep the meaning in the shapes the preservation sweep skips" {
    // Found by a randomized differential over the fixtures and corpus
    // (edit, write, read back, compare with the tree in memory). Each
    // output was wrong -- unparseable, or read back as another tree --
    // and each is pinned as the bytes now written.
    const allocator = testing.allocator;
    const Op = union(enum) {
        set: struct { p: []const u8, v: []const u8, s: @import("token.zig").ScalarStyle = .plain },
        set_seq: []const u8,
        set_map: []const u8,
        delete: []const u8,
        append: struct { p: []const u8, v: []const u8, s: @import("token.zig").ScalarStyle = .plain },
        insert: struct { p: []const u8, pos: []const u8, v: []const u8, s: @import("token.zig").ScalarStyle = .plain },
        move: struct { from: []const u8, to: []const u8, key: []const u8 },
        anchor: struct { p: []const u8, name: ?[]const u8 },
        lead: struct { p: []const u8, t: []const u8 },
        trail: struct { p: []const u8, t: []const u8 },
    };
    const bom = "\xEF\xBB\xBF";
    const cases = [_]struct { in: []const u8, ops: []const Op, out: []const u8 }{
        // Any edit to a document opening with a byte order mark.
        .{ .in = bom ++ "a: 1\nb: 2\n", .ops = &.{.{ .set = .{ .p = "$.b", .v = "3" } }}, .out = bom ++ "a: 1\nb: 3\n" },
        .{ .in = bom ++ "a: 1\nb: 2\n", .ops = &.{.{ .trail = .{ .p = "$.b", .t = "# t" } }}, .out = bom ++ "a: 1\nb: 2 # t\n" },
        // A block scalar written by an edit took in what followed it.
        .{ .in = "a: 1 # c\n", .ops = &.{.{ .set = .{ .p = "$.a", .v = "x\ny" } }}, .out = "a: |- # c\n  x\n  y\n" },
        .{ .in = "a:\n  b: 1 # note\n", .ops = &.{.{ .set = .{ .p = "$.a.b", .v = "x\ny", .s = .literal } }}, .out = "a:\n  b: |- # note\n    x\n    y\n" },
        .{ .in = "a: 1 # c\n", .ops = &.{.{ .set = .{ .p = "$", .v = "x\n", .s = .literal } }}, .out = "| # c\nx\n" },
        .{ .in = "a: 1\n# tail\n", .ops = &.{.{ .set = .{ .p = "$", .v = "x\n", .s = .literal } }}, .out = "|\n x\n# tail\n" },
        .{ .in = "a:\n  b: 1\n  # c\nd: 2\n", .ops = &.{.{ .set = .{ .p = "$.a", .v = "x\ny" } }}, .out = "a: |-\n   x\n   y\n  # c\nd: 2\n" },
        .{ .in = "a: 1\n", .ops = &.{.{ .set = .{ .p = "$", .v = "x\n\n", .s = .literal } }}, .out = "|+\nx\n\n" },
        .{ .in = "- 1\n\n- 2\n", .ops = &.{.{ .set = .{ .p = "$[0]", .v = "x\n\n", .s = .literal } }}, .out = "- |+\n  x\n\n- 2\n" },
        .{ .in = "a:\n  - 1\n\nb: 2\n", .ops = &.{.{ .append = .{ .p = "$.a", .v = "x\n\n", .s = .literal } }}, .out = "a:\n  - 1\n  - |+\n    x\n\nb: 2\n" },
        .{ .in = "a: |\n  t\nb: 2\n", .ops = &.{.{ .lead = .{ .p = "$.b", .t = "  # x" } }}, .out = "a: |\n  t\n# x\nb: 2\n" },
        // Indentation and item framing around new and replaced items.
        .{ .in = "a:\n  - x\n", .ops = &.{.{ .insert = .{ .p = "$.a", .pos = "$.a[0]", .v = "q\n", .s = .literal } }}, .out = "a:\n  - |\n    q\n  - x\n" },
        .{ .in = "a:\n  - x\n  - y\n", .ops = &.{.{ .insert = .{ .p = "$.a", .pos = "$.a[0]", .v = "" } }}, .out = "a:\n  -\n  - x\n  - y\n" },
        .{ .in = "- - x\n  - y\n", .ops = &.{.{ .set = .{ .p = "$[0][0]", .v = "" } }}, .out = "- -\n  - y\n" },
        .{ .in = "-\n  - 42\n", .ops = &.{.{ .set = .{ .p = "$[0][0]", .v = "x" } }}, .out = "-\n  - x\n" },
        .{ .in = "- - one\n  - two\n", .ops = &.{ .{ .set = .{ .p = "$[0][0]", .v = "z" } }, .{ .set = .{ .p = "$[0][1]", .v = "z" } } }, .out = "- - z\n  - z\n" },
        .{ .in = "- - x\n", .ops = &.{.{ .set = .{ .p = "$[0][0]", .v = "a\nb", .s = .literal } }}, .out = "- - |-\n    a\n    b\n" },
        .{ .in = "- !!map\n  foo: bar\n", .ops = &.{ .{ .delete = "$[0].foo" }, .{ .set = .{ .p = "$[0].k", .v = "v" } } }, .out = "- !!map\n  k: v\n" },
        .{ .in = "- :\n", .ops = &.{.{ .set = .{ .p = "$[0][\"\"]", .v = "a\nb", .s = .literal } }}, .out = "- : |-\n    a\n    b\n" },
        .{ .in = "- # c\n  x\n- z\n", .ops = &.{.{ .delete = "$[0]" }}, .out = "- z\n" },
        .{ .in = "- # c\n  x\n- z\n", .ops = &.{.{ .set = .{ .p = "$[0]", .v = "NEW" } }}, .out = "- NEW\n- z\n" },
        .{ .in = "- # c\n  x\n", .ops = &.{.{ .append = .{ .p = "$", .v = "y" } }}, .out = "- # c\n  x\n- y\n" },
        // Document markers.
        .{ .in = "--- a\n", .ops = &.{.{ .set_seq = "$" }}, .out = "---\n- x\n" },
        .{ .in = "--- a\n", .ops = &.{.{ .set_map = "$" }}, .out = "---\nk: x\n" },
        .{ .in = "\ta\n", .ops = &.{.{ .set_seq = "$" }}, .out = "- x\n" },
        .{ .in = "a: 1\n...\n", .ops = &.{.{ .delete = "$.a" }}, .out = "{}\n...\n" },
        .{ .in = "---\n...\n", .ops = &.{.{ .set = .{ .p = "$", .v = "x" } }}, .out = "---\nx\n...\n" },
        .{ .in = "---", .ops = &.{.{ .set = .{ .p = "$", .v = "x" } }}, .out = "--- x" },
        // Flow mappings whose `:` does not follow the key directly.
        .{ .in = "{\"foo\"\n: \"bar\"}\n", .ops = &.{.{ .set = .{ .p = "$.foo", .v = "x" } }}, .out = "{\"foo\"\n: x}\n" },
        .{ .in = "{foo, b: 1}\n", .ops = &.{.{ .set = .{ .p = "$.foo", .v = "x" } }}, .out = "{foo: x, b: 1}\n" },
        // CRLF and CR line breaks.
        .{ .in = "- |+\r\n  a\r\n\r\n", .ops = &.{.{ .append = .{ .p = "$", .v = "c" } }}, .out = "- |+\r\n  a\r\n\r\n- c\r\n" },
        .{ .in = "k: |+\r\n  a\r\n\r\n", .ops = &.{.{ .set = .{ .p = "$.j", .v = "c" } }}, .out = "k: |+\r\n  a\r\n\r\nj: c\r\n" },
        .{ .in = "- |\r\n  a\r\n", .ops = &.{.{ .append = .{ .p = "$", .v = "c" } }}, .out = "- |\r\n  a\r\n- c\r\n" },
        .{ .in = "[a, # c\rb]\r", .ops = &.{.{ .delete = "$[1]" }}, .out = "[a]\r" },
        // Properties of a parsed collection, of an empty value and key.
        .{ .in = "a:\n  b: 1\n", .ops = &.{.{ .anchor = .{ .p = "$.a", .name = "x" } }}, .out = "a: &x\n  b: 1\n" },
        .{ .in = "a: &x\n  b: 1\n", .ops = &.{.{ .anchor = .{ .p = "$.a", .name = null } }}, .out = "a:\n  b: 1\n" },
        .{ .in = "a: &x\n  b: 1\n", .ops = &.{.{ .anchor = .{ .p = "$.a", .name = "y" } }}, .out = "a: &y\n  b: 1\n" },
        .{ .in = "b: 1\n", .ops = &.{.{ .anchor = .{ .p = "$", .name = "r" } }}, .out = "&r\nb: 1\n" },
        .{ .in = "- k: v\n- j: w\n", .ops = &.{.{ .anchor = .{ .p = "$[0]", .name = "y" } }}, .out = "- &y\n  k: v\n- j: w\n" },
        .{ .in = "top:\n  - k: v\n  - j: w\n", .ops = &.{.{ .anchor = .{ .p = "$.top[0]", .name = "y" } }}, .out = "top:\n  - &y\n    k: v\n  - j: w\n" },
        .{ .in = "a:\nb: 1\n", .ops = &.{.{ .anchor = .{ .p = "$.a", .name = "x" } }}, .out = "a: &x\nb: 1\n" },
        .{ .in = "!!str : a\n", .ops = &.{.{ .set = .{ .p = "$[\"\"]", .v = "b" } }}, .out = "!!str : b\n" },
        // Properties that are not the collection's own are left alone:
        // ones running over lines, a first key's, a deleted first key's.
        .{ .in = "key: &anchor\n !!map\n  a: b\n", .ops = &.{.{ .set = .{ .p = "$.key.a", .v = "c" } }}, .out = "key: &anchor\n !!map\n  a: c\n" },
        .{ .in = "top:\n  &k 'key' : v\n  j: w\n", .ops = &.{.{ .set = .{ .p = "$.top.j", .v = "x" } }}, .out = "top:\n  &k 'key' : v\n  j: x\n" },
        .{ .in = "-\n  !!null : a\n  b: x\n", .ops = &.{.{ .delete = "$[0][\"\"]" }}, .out = "-\n  b: x\n" },
        .{ .in = "&c : a\n", .ops = &.{.{ .set = .{ .p = "$[\"\"]", .v = "b" } }}, .out = "&c : b\n" },
        // A null key's entry.
        .{ .in = ": a\nb: c\n", .ops = &.{.{ .delete = "$[\"\"]" }}, .out = "b: c\n" },
        .{ .in = ": a\nb: c\n", .ops = &.{.{ .move = .{ .from = "$[\"\"]", .to = "$", .key = "mv" } }}, .out = "b: c\nmv: a\n" },
        // No final line break.
        .{ .in = "a: |\n  x\n  ", .ops = &.{.{ .set = .{ .p = "$.new", .v = "y" } }}, .out = "a: |\n  x\nnew: y" },
        .{ .in = "a: 1", .ops = &.{.{ .trail = .{ .p = "$.a", .t = "# d" } }}, .out = "a: 1 # d\n" },
        .{ .in = "- 1", .ops = &.{.{ .trail = .{ .p = "$[0]", .t = "# d" } }}, .out = "- 1 # d\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(allocator, c.in);
        defer doc.deinit();
        var ed = Editor.init(&doc);
        for (c.ops) |op| switch (op) {
            .set => |s| try ed.set(s.p, try doc.createScalar(s.v, s.s)),
            .set_seq => |p| {
                const q = try doc.createSequence();
                try doc.sequenceAppend(q, try doc.createScalar("x", .plain));
                try ed.set(p, q);
            },
            .set_map => |p| {
                const m = try doc.createMapping();
                try doc.mappingAppend(m, try doc.createScalar("k", .plain), try doc.createScalar("x", .plain));
                try ed.set(p, m);
            },
            .delete => |p| try ed.delete(p),
            .append => |a| try ed.apply(&.{.{ .append = .{ .sequence = a.p, .value = try doc.createScalar(a.v, a.s) } }}),
            .insert => |i| try ed.apply(&.{.{ .insert = .{ .sequence = i.p, .position = i.pos, .value = try doc.createScalar(i.v, i.s), .before = true } }}),
            .move => |m| try ed.apply(&.{.{ .move = .{ .from = m.from, .to = m.to, .key = m.key } }}),
            .anchor => |a| try doc.setAnchor(try ed.one(a.p), a.name),
            .lead => |l| try doc.setLeadingComments(try ed.one(l.p), l.t),
            .trail => |t| try doc.setTrailingComment(try ed.one(t.p), t.t),
        };
        const out = try doc.write(allocator);
        defer allocator.free(out);
        errdefer std.debug.print("{f}: wrote {f}\n", .{ std.zig.fmtString(c.in), std.zig.fmtString(out) });
        try testing.expectEqualStrings(c.out, out);
        var back = try Document.parse(allocator, out);
        defer back.deinit();
        try testing.expect(sameTreeForTest(doc.root, back.root));
    }
}

test "an edit that would rebind an alias, or build a cycle, is refused" {
    const allocator = testing.allocator;
    // A later `&x` shadows an earlier one for the aliases after it, once
    // written and read back: in memory `*x` kept its target, and the
    // written document meant another.
    {
        var doc = try Document.parse(allocator, "- &x 1\n- 2\n- *x\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try testing.expectError(error.AnchorShadowed, doc.setAnchor(try ed.one("$[1]"), "x"));
        // After every alias it is harmless.
        try doc.sequenceAppend(doc.root.?, try doc.createScalar("3", .plain));
        try doc.setAnchor(try ed.one("$[3]"), "x");
    }
    {
        var doc = try Document.parse(allocator, "a: &x 1\nb: 0\nc: *x\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        const v = try doc.createScalar("NEW", .plain);
        try doc.setAnchor(v, "x");
        try testing.expectError(error.AnchorShadowed, ed.set("$.b", v));
        const same = try doc.write(allocator);
        defer allocator.free(same);
        try testing.expectEqualStrings("a: &x 1\nb: 0\nc: *x\n", same);
    }
    // YAML gives an alias no properties.
    {
        var doc = try Document.parse(allocator, "a: &x 1\nb: *x\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        const alias = doc.root.?.pairs().?[1].value;
        try testing.expectError(error.InvalidSyntax, doc.setAnchor(alias, "q"));
        _ = &ed;
    }
    // A node set as a value of its own descendant: a parent cycle, which
    // panicked in `markModified` (the append paths already refused it).
    {
        var doc = try Document.parse(allocator, "a:\n  b: 1\n");
        defer doc.deinit();
        var ed = Editor.init(&doc);
        try testing.expectError(error.WouldCycle, ed.set("$.a.b", doc.root.?));
        try testing.expectError(error.WouldCycle, doc.pathSet(&.{ "a", "b" }, doc.root.?));
    }
}

test "the path grammar reads `$ref` as a key, and refuses text after a segment" {
    const allocator = testing.allocator;
    // `$` followed by a key character was taken for the root marker, so
    // `delete("$ref")` deleted `ref` (OpenAPI and JSON Schema documents
    // are full of `$ref` and `$schema`).
    var doc = try Document.parse(allocator, "$ref: '#/defs/a'\nref: keep\nitems: [a]\nl: [{k: 1}, {k: 2}]\n");
    defer doc.deinit();
    var ed = Editor.init(&doc);
    try ed.delete("$ref");
    try testing.expect(doc.root.?.lookup("$ref") == null);
    try testing.expectEqualStrings("keep", doc.root.?.lookup("ref").?.scalarValue().?);
    try testing.expectError(error.InvalidPath, ed.all("$.items[0]name"));
    try testing.expectError(error.InvalidPath, ed.all("items[0]name"));
    // A set whose parent matches several nodes names no single target.
    try testing.expectError(error.AmbiguousOperation, ed.set("$.l[*].k", try doc.createScalar("3", .plain)));
}
