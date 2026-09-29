//! Document model — Zig port of libfyaml's fy-doc / fy-node.
//!
//! A `Document` owns a node tree plus the pool every node lives in
//! (fy_pool semantics). Nodes use a tagged union instead of the C code's
//! type field + union pointer, which removes an entire class of
//! wrong-member accesses at compile time.

const std = @import("std");
const ctype = @import("ctype.zig");
const diag = @import("diag.zig");
const edit = @import("edit.zig");
const event_mod = @import("event.zig");
const internal = @import("internal.zig");
const markup = @import("markup.zig");
const parser_mod = @import("parser.zig");
const pool_mod = @import("pool.zig");
const scanner_mod = @import("scanner.zig");
const token_mod = @import("token.zig");

const Mark = diag.Mark;
const YamlError = diag.YamlError;
const Event = event_mod.Event;
const Parser = parser_mod.Parser;
const Pool = pool_mod.Pool;
const ScalarStyle = token_mod.ScalarStyle;
const CollectionStyle = event_mod.CollectionStyle;
const TagDirective = token_mod.TagDirective;
const VersionDirective = token_mod.VersionDirective;

/// The three YAML node kinds (spec 3.2.1.1) plus `alias`, which yayl
/// models as a node of its own so `*a` keeps its own source span and
/// re-emits verbatim. Aliases are first-class nodes (fy_node
/// alias semantics): `- *a` occupies its own slot in the tree with its
/// own source span and formatting, pointing at the anchored target.
pub const NodeKind = enum { scalar, mapping, sequence, alias };

/// Bounds and input policy for a parse — `scanner.Options`, named for
/// the layer callers reach it through. Use it with `parseOpts` /
/// `parseAllOpts`; `parse` and `parseAll` use the defaults.
pub const ParseOptions = scanner_mod.Options;

/// What a parse does with a NUL byte in the input. See `ParseOptions`.
pub const EmbeddedNul = scanner_mod.EmbeddedNul;

/// Layout choices for emission — `emitter.Emitter.Options`, named for
/// the layer callers reach it through. Use it with `writeOpts` /
/// `writeAllOpts`; `write` and `writeAll` use the defaults.
pub const EmitOptions = @import("emitter.zig").Emitter.Options;

/// One mapping entry; both nodes are pool-owned. `src` records where
/// the pair's bytes end in the original source (see `Node.src`), so
/// untouched pairs re-emit byte-identically.
pub const Pair = struct {
    key: *Node,
    value: *Node,
    /// Offset just past the pair's last content byte: the value's end,
    /// or the `:` for valueless (null) pairs.
    src_end: ?usize = null,
};

/// Scalar node payload: the decoded value and its presentation style.
pub const Scalar = struct {
    value: []const u8 = "",
    style: ScalarStyle = .plain,
};

/// Mapping payload. Add entries via `Document.mappingAppend`.
///
/// Key uniqueness is NOT enforced, here or at parse time: YAML 1.2
/// §3.2.1.1 requires keys to be unique, but this library keeps what the
/// input actually contained rather than rejecting it, because real-world
/// files carry duplicates and losing them silently is worse than
/// surfacing them. `lookup` returns the first match, and a duplicate
/// appended here re-emits as a second entry with the same key.
pub const Mapping = struct {
    pairs: std.ArrayList(Pair) = .empty,
    style: CollectionStyle = .block,
    /// Source byte ranges of removed entries (tombstones): the emitter
    /// skips these inside preserved gaps so deleted entries do not
    /// re-appear verbatim.
    dropped: std.ArrayList([2]usize) = .empty,
};

/// Sequence payload; items are pool-owned nodes.
pub const Sequence = struct {
    items: std.ArrayList(*Node) = .empty,
    style: CollectionStyle = .block,
    /// See `Mapping.dropped`.
    dropped: std.ArrayList([2]usize) = .empty,
};

/// One YAML node: tagged union over the three node kinds and `alias`,
/// plus shared
/// metadata. Pool-owned by the containing document; `parent` is a
/// borrowed back-pointer.
pub const Node = struct {
    parent: ?*Node = null,
    mark: Mark = .{},
    anchor: ?[]const u8 = null,
    /// Fully resolved tag URI (e.g. `tag:yaml.org,2002:int`), or null.
    tag: ?[]const u8 = null,
    /// Presentation metadata into `Document.source` (a CST-style source span). Null
    /// for programmatically created nodes, which re-emit normalized.
    src: ?markup.Src = null,
    /// True once the node's value or child list was modified after
    /// parsing; its span is no longer trusted for verbatim emission.
    modified: bool = false,
    /// Comment overrides written through `setTrailingComment`. Null means
    /// "no override"; the empty slice means "comment deleted". Non-empty
    /// text is the raw comment (`# ...`, pool-owned) the emitter writes
    /// in place of whatever the source had. See the reads, which return
    /// these as-is.
    pending_trailing: ?[]const u8 = null,
    /// Comment block written through `setLeadingComments`; same null /
    /// empty / raw convention, lines separated by `\n`.
    pending_leading: ?[]const u8 = null,
    data: Data = .{ .scalar = .{} },

    pub const Data = union(NodeKind) {
        scalar: Scalar,
        mapping: Mapping,
        sequence: Sequence,
        alias: Alias,
    };

    /// Alias payload: the `*name` occurrence and the node it resolves
    /// to. Accessors on an alias node forward to the target.
    pub const Alias = struct {
        name: []const u8,
        target: *Node,
    };

    pub fn kind(self: *const Node) NodeKind {
        return std.meta.activeTag(self.data);
    }

    pub fn isAlias(self: *const Node) bool {
        return self.data == .alias;
    }

    /// Follow alias nodes to the underlying node, bounded by
    /// `max_alias_depth` so an alias *chain* terminates.
    ///
    /// That bound is on the chain, not on the graph: nothing rejects a
    /// cycle, in parsed input or built. `&a [*a]` parses, and this
    /// returns the enclosing sequence, so a caller that recurses into
    /// the result revisits the same node forever. Every recursive walk
    /// over resolved nodes carries its own depth bound for that reason
    /// — see `edit.max_walk_depth`, `value.Limits.max_depth` and
    /// `schema.Limits.max_depth`.
    pub fn resolveAlias(self: *const Node) *const Node {
        var cur = self;
        var depth: usize = 0;
        while (cur.data == .alias and depth < max_alias_depth) : (depth += 1) {
            cur = cur.data.alias.target;
        }
        return cur;
    }

    pub fn isScalar(self: *const Node) bool {
        return self.resolveAlias().kind() == .scalar;
    }
    pub fn isMapping(self: *const Node) bool {
        return self.resolveAlias().kind() == .mapping;
    }
    pub fn isSequence(self: *const Node) bool {
        return self.resolveAlias().kind() == .sequence;
    }

    /// Scalar value or null for collections. Alias nodes forward to
    /// their target.
    pub fn scalarValue(self: *const Node) ?[]const u8 {
        return switch (self.resolveAlias().data) {
            .scalar => |s| s.value,
            else => null,
        };
    }

    /// Mapping pairs or null.
    pub fn pairs(self: *const Node) ?[]const Pair {
        return switch (self.resolveAlias().data) {
            .mapping => |m| m.pairs.items,
            else => null,
        };
    }

    /// Sequence items or null.
    pub fn items(self: *const Node) ?[]const *Node {
        return switch (self.resolveAlias().data) {
            .sequence => |s| s.items.items,
            else => null,
        };
    }

    /// Look up a mapping entry by scalar key text. Alias nodes forward
    /// to their target.
    pub fn lookup(self: *const Node, key: []const u8) ?*Node {
        const ps = self.resolveAlias().pairs() orelse return null;
        for (ps) |p| {
            if (std.mem.eql(u8, p.key.scalarValue() orelse continue, key)) return p.value;
        }
        return null;
    }

    /// Resolve a node by a path of mapping keys, e.g. `&.{ "a", "b" }`.
    /// Alias nodes are followed. A segment that parses as a decimal
    /// number also indexes into a sequence — `&.{ "items", "0" }` is
    /// the first item — so a read path can mirror the edit grammar's
    /// `$[N]` without a second API. A numeric segment on a mapping is
    /// still an ordinary key; only sequences take the index reading.
    /// Out-of-range indices and non-numeric segments on a sequence
    /// return null.
    pub fn byPath(self: *const Node, path: []const []const u8) ?*Node {
        var cur: *const Node = self;
        for (path) |seg| {
            cur = walkReadSegment(cur, seg) orelse return null;
        }
        return @constCast(cur);
    }

    /// Depth bound for alias chasing (resolveAlias, emitter).
    pub const max_alias_depth: usize = 100;

    /// Bound on walks up the `parent` chain (`markModified`,
    /// `wouldCycle`). Generous next to the 1000-level depth bounds the
    /// recursive walks carry, since a legitimate chain is bounded by
    /// those; it exists so a parent cycle can never become a hang.
    pub const max_parent_walk: usize = 1 << 16;

    // ------------------------------------------------------------------
    // Comments (see docs/design/comments.md)
    // ------------------------------------------------------------------

    /// The node's trailing (same-line) comment, raw: from the `#` to the
    /// last byte before the line terminator, a slice into
    /// `Document.source` (or into the text passed to `setTrailingComment`
    /// via the document pool). Null when there is none, or when a
    /// written comment was deleted.
    ///
    /// For a `key: value # c` pair the comment is read off the VALUE
    /// node (the pair's value stands in for the pair); a block
    /// collection's trailing comment sits on its last entry's line, so
    /// the collection and that entry read the same bytes. A node built
    /// programmatically has no source bytes and reads null until
    /// something is written.
    pub fn trailingComment(self: *const Node, doc: *const Document) ?[]const u8 {
        if (!trailingPlaced(self)) return null;
        // A block collection's trailing comment is its LAST entry's, as
        // the entries are now: after an edit its source end is another
        // entry's line, or a deleted one's.
        const last: ?*const Node = switch (self.data) {
            .mapping => |m| if (m.style == .block and m.pairs.items.len > 0) m.pairs.items[m.pairs.items.len - 1].value else null,
            .sequence => |sq| if (sq.style == .block and sq.items.items.len > 0) sq.items.items[sq.items.items.len - 1] else null,
            else => null,
        };
        if (last) |l| return l.trailingComment(doc);
        // `? key # c` with no value: the comment after the key is its
        // empty value's (where it is written), and both read it.
        if (emptyValueAfterKey(self, doc.source orelse "")) |v| return v.trailingComment(doc);
        if (self.pending_trailing) |t| return if (t.len == 0) null else t;
        const doc_src = doc.source orelse return null;
        const at = trailingAnchor(self, doc_src) orelse return null;
        const span = markup.trailingCommentSpan(doc_src, at) orelse return null;
        return doc_src[span[0]..span[1]];
    }

    /// The node's leading comment block: the own-line comment(s)
    /// immediately above the entry, with no blank line in between, raw
    /// and newline-joined (`"# one\n# two"`). Null when there is none,
    /// or when a written block was deleted.
    ///
    /// A sequence item and a mapping key carry the comments above their
    /// line; for an inline value (`host: localhost`) the value stands in
    /// for the pair and reads the pair's block, so key and value read
    /// the same bytes; for a block value (a mapping or sequence on its
    /// own line) the comments above it are its own. Every node starting
    /// on a line reads that line's block: a collection and its first
    /// entry, an item and its mapping's first key. Free-floating
    /// comments -- separated by a blank line, or in the document head
    /// before `---` -- attach to nothing.
    ///
    /// After an edit the reads follow the tree as it is now: which entry
    /// is first, and a block written on an entry wherever that entry now
    /// is. Nothing inside a new or moved subtree reads a comment -- the
    /// emitter lays it out afresh, without any. Source comments are read
    /// where the source put them, so a comment left above a deleted
    /// neighbour reads as that neighbour's until the document is written
    /// and parsed again.
    pub fn leadingComments(self: *const Node, doc: *const Document) ?[]const u8 {
        const src = doc.source orelse return null;
        const owner = leadingOwner(self, src);
        if (!leadingPlaced(owner)) return null;
        // A block written on any node that starts on the line is written
        // above it -- including one written on an entry that has since
        // become its container's first (an earlier sibling deleted).
        var c: ?*const Node = owner;
        while (c) |n| : (c = nextOnLine(n, src)) {
            if (ownerPending(n, src)) |t| if (t.len > 0) return t;
        }
        if (owner.pending_leading) |t| if (t.len == 0) return null; // deleted
        const span = doc.leadingSourceSpan(owner) orelse return null;
        return src[span[0]..span[1]];
    }
};

/// Where a node's trailing comment is looked for: after its content, or
/// for an empty mapping value (`push:`, `? key`) -- whose span is a point
/// borrowed from the next token -- after its key and colon, on the
/// key's line. Null for other empty nodes: an empty item or document has
/// no bytes to hang a comment on.
fn trailingAnchor(node: *const Node, source: []const u8) ?usize {
    const s = node.src orelse return null;
    if (!s.synthetic) return s.end;
    const parent = node.parent orelse return null;
    switch (parent.data) {
        .mapping => |m| for (m.pairs.items) |pair| {
            if (pair.value != node) continue;
            const ks = realSpan(pair.key) orelse return null;
            // Past the value indicator, which for an explicit key can sit
            // on a line of its own (`? a` over `: # c`).
            const after = pair.src_end orelse markup.colonEnd(source, ks.end);
            // `? >` with no `:` on its line: after the key is inside the
            // block scalar's content, not a comment position.
            if (after == ks.end) switch (pair.key.data) {
                .scalar => |k| if (k.style == .literal or k.style == .folded) return null,
                else => {},
            };
            return after;
        },
        else => {},
    }
    return null;
}

/// The empty value of the pair keyed by `key` when nothing -- no `:` --
/// stands between them, so the value's trailing comment follows the key.
fn emptyValueAfterKey(key: *const Node, source: []const u8) ?*const Node {
    const p = key.parent orelse return null;
    const ps = p.pairs() orelse return null;
    for (ps) |pair| {
        if (pair.key != key) continue;
        const vs = pair.value.src orelse return null;
        const ks = realSpan(key) orelse return null;
        if (!vs.synthetic) return null;
        const at = trailingAnchor(pair.value, source) orelse return null;
        return if (at == ks.end) pair.value else null;
    }
    return null;
}

/// The node that holds the leading comment block of `node`'s entry
/// line. Several nodes start on one line: a sequence item's mapping and
/// its first key share the item's `- `, a block collection shares its
/// line with its first entry, and an inline value (`k: v`) sits on its
/// key's line. All of them read the block above that line, so a
/// written block belongs to the outermost of them: every node on the
/// line then reads the same block, its old lines are tombstoned in the
/// gap that holds them, and the emitter writes the new ones once, where
/// that node is emitted. Without this the first key of an item recorded
/// its tombstone in the item's list while the lines sat in the
/// sequence's gap, and the old block survived beside the new one.
///
/// The climb follows the tree as it is NOW, not the source lines: a
/// node shares its container's line only while it is the container's
/// first entry. After an insert ahead of it, the old first item has a
/// line of its own again, and a block written on it goes above it --
/// reading source lines, it went above the new first item instead. A
/// new first entry takes the container's line, and a new inline value
/// its key's, as the emitter lays them out.
fn leadingOwner(node: anytype, source: []const u8) @TypeOf(node) {
    var n = node;
    var guard: usize = 0;
    climb: while (n.parent) |p| : (guard += 1) {
        if (guard >= Node.max_parent_walk) break;
        // A flow collection's entries share its line but have no line of
        // their own; they stay themselves (and unwritable).
        if (Document.insideFlow(n)) break;
        switch (p.data) {
            .mapping => |m| for (m.pairs.items, 0..) |pair, i| {
                if (pair.key == n) {
                    if (i != 0 or !startsOnFirstEntryLine(p, source)) break :climb;
                    n = p;
                    continue :climb;
                }
                if (pair.value == n) {
                    // After a synthetic key (`: v`) the value is the
                    // entry's first byte and owns its line, climbing as
                    // a key would: the key has no bytes to hold a block.
                    if (pair.key.src) |ks| if (ks.synthetic) {
                        if (i != 0 or !startsOnFirstEntryLine(p, source)) break :climb;
                        n = p;
                        continue :climb;
                    };
                    // An inline value hands over to its key.
                    if (!valueOnKeyLine(pair, source)) break :climb;
                    n = pair.key;
                    continue :climb;
                }
            },
            .sequence => |sq| {
                if (sq.items.items.len == 0 or sq.items.items[0] != n) break;
                if (!startsOnFirstEntryLine(p, source)) break;
                n = p;
                continue :climb;
            },
            else => {},
        }
        break;
    }
    return n;
}

/// True when a block collection begins on its first entry's line -- the
/// line whatever entry is first now takes. Not when its properties end
/// a line of their own (`k: &a !!map` over `  x: 1`): the first entry
/// then has a line, and a block, of its own.
fn startsOnFirstEntryLine(container: *const Node, source: []const u8) bool {
    const cs = realSpan(container) orelse return true;
    return markup.propertiesLineEnd(source, cs.start) == null;
}

/// True when a mapping value sits on its key's line: by the source when
/// both have bytes of their own, and by the emitter's layout otherwise
/// (`internal.inlineValue`). An empty value's point span is on the key's
/// line.
fn valueOnKeyLine(pair: Pair, source: []const u8) bool {
    // A new key: the value is laid out after it.
    const ks = realSpan(pair.key) orelse return internal.inlineValue(pair.value);
    const vs = pair.value.src orelse return internal.inlineValue(pair.value);
    if (vs.synthetic) return true;
    return markup.lineStart(source, vs.entry_start) == markup.lineStart(source, ks.start);
}

/// True when the faithful emitter reaches `node` by walking entries --
/// the root, or an entry of a container that itself has source bytes,
/// all the way up. Below a node with none (a new or moved subtree, a
/// replaced root) everything is laid out afresh: comments written there
/// are never emitted, and source comments no longer describe it.
fn walkedFaithfully(node: *const Node) bool {
    var cur = node.parent;
    var guard: usize = 0;
    while (cur) |c| : (guard += 1) {
        if (guard >= Node.max_parent_walk) return false;
        if (realSpan(c) == null) return false;
        cur = c.parent;
    }
    return true;
}

/// The written block the emitter puts above `owner`'s line, if any. For a
/// key that is the pair's (`internal.pairLeadingOverride`), which a value
/// carried into the pair can hold.
fn ownerPending(owner: *const Node, source: []const u8) ?[]const u8 {
    if (owner.parent) |p| if (p.pairs()) |ps| for (ps) |pair| {
        if (pair.key == owner) return internal.pairLeadingOverride(source, pair.key, pair.value);
    };
    return owner.pending_leading;
}

/// The next node that starts on `node`'s line, going in: a block
/// collection's first entry (for a mapping its key, or the value after a
/// synthetic key), or null. A key's inline value is covered by the key
/// (`ownerPending`).
fn nextOnLine(node: anytype, source: []const u8) ?@TypeOf(node) {
    switch (node.data) {
        .mapping => |m| {
            if (m.style == .flow or m.pairs.items.len == 0 or !startsOnFirstEntryLine(node, source)) return null;
            const first = m.pairs.items[0];
            if (first.key.src) |ks| if (ks.synthetic) return first.value;
            return first.key;
        },
        .sequence => |sq| {
            if (sq.style == .flow or sq.items.items.len == 0 or !startsOnFirstEntryLine(node, source)) return null;
            return sq.items.items[0];
        },
        else => return null,
    }
}

/// True when a trailing comment on `node` is written where it reads
/// back: an entry the faithful emitter walks to, or a root with source
/// bytes (a replaced root is laid out afresh, without one).
fn trailingPlaced(node: *const Node) bool {
    if (!walkedFaithfully(node)) return false;
    return node.parent != null or node.src != null;
}

/// True when a leading block on `owner` (see `leadingOwner`) is written
/// where it reads back: `owner` is walked faithfully, and a block value
/// -- the one owner that is not an entry -- has the source line the
/// emitter writes its block above.
fn leadingPlaced(owner: *const Node) bool {
    if (!walkedFaithfully(owner)) return false;
    if (Document.isMappingValue(owner)) return realSpan(owner) != null;
    return true;
}

/// Where the bytes that can hold `owner`'s leading block begin: past
/// whatever precedes its entry -- the previous entry of its container,
/// the key of a value, the container's own start for a first entry --
/// so the content lines of a block scalar above (`  # text`) are never
/// read as a comment. The root's is its document's region, except that
/// a root sharing its line with `---` has none: the head before the
/// marker is free-floating.
fn leadingFloor(owner: *const Node, doc: *const Document) usize {
    const s = owner.src.?;
    const parent = owner.parent orelse {
        const src = doc.source.?;
        const ls = markup.lineStart(src, s.entry_start);
        if (s.entry_start > ls + 3 and std.mem.startsWith(u8, src[ls..], "---")) return ls;
        return doc.region_start;
    };
    // Only real spans count: an empty node's span is a point borrowed
    // from the NEXT token (`a: &anchor` then `b:`), which would put the
    // floor past the lines above this entry.
    var floor: usize = if (realSpan(parent)) |cs| cs.entry_start else 0;
    switch (parent.data) {
        .mapping => |m| for (m.pairs.items) |pair| {
            if (pair.key == owner) break;
            if (pair.value == owner) {
                if (realSpan(pair.key)) |ks| floor = @max(floor, ks.end);
                break;
            }
            if (realSpan(pair.key)) |ks| floor = @max(floor, ks.end);
            if (realSpan(pair.value)) |vs| floor = @max(floor, vs.end);
        },
        .sequence => |sq| for (sq.items.items) |item| {
            if (item == owner) break;
            if (realSpan(item)) |is| floor = @max(floor, is.end);
        },
        else => {},
    }
    return floor;
}

/// A node's span when it covers bytes of its own, not a synthetic point.
fn realSpan(node: *const Node) ?markup.Src {
    const s = node.src orelse return null;
    return if (s.synthetic) null else s;
}

/// One `byPath` segment: a decimal number indexes a sequence, anything
/// else is a mapping key. The accessors forward through aliases, so an
/// alias in the middle resolves either way.
fn walkReadSegment(node: *const Node, seg: []const u8) ?*const Node {
    if (node.items()) |list| {
        // Plain digits only: `parseInt` also takes `+1` and `1_0`.
        if (seg.len == 0) return null;
        for (seg) |c| if (!std.ascii.isDigit(c)) return null;
        const ix = std.fmt.parseInt(usize, seg, 10) catch return null;
        if (ix >= list.len) return null;
        return list[ix];
    }
    return node.lookup(seg);
}

/// The Core Schema tag a plain scalar resolves to, in the spec's
/// shorthand form (`tag:yaml.org,2002:int` is `.int`). Distinct from
/// `Node.tag`, which holds a fully resolved tag URI.
pub const CoreTag = enum { null, bool, int, float, str };

/// The Core Schema tag named by a fully resolved tag URI, or null when
/// the URI is not one of the five (`!!seq`, `!!map` and any
/// application tag included).
pub fn coreTagFromUri(uri: []const u8) ?CoreTag {
    const prefix = "tag:yaml.org,2002:";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const name = uri[prefix.len..];
    if (std.mem.eql(u8, name, "str")) return .str;
    if (std.mem.eql(u8, name, "int")) return .int;
    if (std.mem.eql(u8, name, "float")) return .float;
    if (std.mem.eql(u8, name, "bool")) return .bool;
    if (std.mem.eql(u8, name, "null")) return .null;
    return null;
}

/// The Core Schema tag a scalar node actually carries. An explicit
/// `!!str`/`!!int`/... wins: the tag is an assertion about the value,
/// and resolving `!!str 42` as an integer would contradict it. Plain
/// resolution is the fallback for an untagged scalar, which is the
/// common case. Null when an explicit core tag's text is not spelled as
/// that type (`!!int abc`, `!!int 0b101`): the document contradicts
/// itself, and `value` and `schema` both report it.
///
/// `node` must already be alias-resolved and must be a scalar.
pub fn scalarCoreTag(node: *const Node) ?CoreTag {
    const s = node.data.scalar;
    if (node.tag) |uri| if (coreTagFromUri(uri)) |t| {
        return if (coreTextFits(t, s.value)) t else null;
    };
    return resolveCoreTag(s.value, s.style);
}

/// Whether `text` is spelled as the core schema (spec 10.3.2) spells a
/// `tag` value, whatever its quoting: under an explicit tag, `!!int '7'`
/// is an integer, but `!!int 0b101` is not (the binary form is YAML
/// 1.1), nor `!!float nan` (`.nan` is). `!!str` takes any text, and
/// `!!float` the integer spellings too, as its grammar does. This is
/// what keeps the explicit-tag paths from reading text through
/// `std.fmt`, which takes far more (`0x10` as a float, `1_000`).
pub fn coreTextFits(tag: CoreTag, text: []const u8) bool {
    return switch (tag) {
        .str => true,
        .float => looksLikeFloat(text),
        else => resolveCoreTag(text, .plain) == tag,
    };
}

/// Resolve a plain scalar to its YAML 1.2.2 Core Schema tag (spec
/// 10.3.2). Non-plain styles always resolve to `str`. Ignores any
/// explicit tag on the node — see `scalarCoreTag`.
pub fn resolveCoreTag(value: []const u8, style: ScalarStyle) CoreTag {
    if (style != .plain) return .str;
    if (value.len == 0 or std.mem.eql(u8, value, "~") or
        std.mem.eql(u8, value, "null") or std.mem.eql(u8, value, "Null") or
        std.mem.eql(u8, value, "NULL")) return .null;
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "True") or
        std.mem.eql(u8, value, "TRUE") or std.mem.eql(u8, value, "false") or
        std.mem.eql(u8, value, "False") or std.mem.eql(u8, value, "FALSE")) return .bool;
    if (looksLikeInt(value)) return .int;
    if (looksLikeFloat(value)) return .float;
    return .str;
}

/// Parse the text of a scalar already classified as a core-schema
/// integer. Returns the value, or null when the text is a valid integer
/// that does not fit `i64` (the "bigint" case). Callers must first
/// confirm `resolveCoreTag(text, .plain) == .int`; this answers only
/// "does it fit". `value` and `schema` previously each spelled this out,
/// and disagreed: schema called the overflow a type error.
pub fn parseCoreInt(text: []const u8) ?i64 {
    // Base 0 would also take `0b101`, `1_000` and `-0x1F`; only the core
    // spellings may reach it.
    std.debug.assert(looksLikeInt(text));
    return std.fmt.parseInt(i64, text, 0) catch null;
}

/// Parse the text of a scalar already classified as a core-schema float,
/// resolving the `.inf`/`.nan` spellings. Null when the text is not a
/// float. One home for the rule `value` and `schema` both apply.
pub fn parseCoreFloat(text: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, text) catch floatSpecial(text);
}

/// Core schema int (spec 10.3.2): `[-+]? [0-9]+`, `0o [0-7]+` or
/// `0x [0-9a-fA-F]+`. The radix forms take no sign and are lowercase
/// only, so `+0x1F`, `-0x1F`, `0X1F` and `0O7` are all strings.
fn looksLikeInt(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value.len > 2 and value[0] == '0' and value[1] == 'x') {
        for (value[2..]) |c| {
            if (ctype.hexValue(c) == null) return false;
        }
        return true;
    }
    if (value.len > 2 and value[0] == '0' and value[1] == 'o') {
        for (value[2..]) |c| {
            if (c < '0' or c > '7') return false;
        }
        return true;
    }
    var s = value;
    if (s[0] == '+' or s[0] == '-') s = s[1..];
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// YAML 1.2 core-schema non-finite float spellings (`.inf`, `.nan`,
/// case variants, optional sign) to their Zig float value. Single home
/// for the table: scalar classification (`looksLikeFloat`) and value
/// conversion both use it. (std.fmt.parseFloat rejects the leading dot
/// in `.inf`, hence the table.)
pub fn floatSpecial(value: []const u8) ?f64 {
    const inf = std.math.inf(f64);
    const nan = std.math.nan(f64);
    const map = [_]struct { t: []const u8, v: f64 }{
        .{ .t = ".inf", .v = inf },   .{ .t = ".Inf", .v = inf },   .{ .t = ".INF", .v = inf },
        .{ .t = "+.inf", .v = inf },  .{ .t = "+.Inf", .v = inf },  .{ .t = "+.INF", .v = inf },
        .{ .t = "-.inf", .v = -inf }, .{ .t = "-.Inf", .v = -inf }, .{ .t = "-.INF", .v = -inf },
        .{ .t = ".nan", .v = nan },   .{ .t = ".NaN", .v = nan },   .{ .t = ".NAN", .v = nan },
    };
    for (map) |e| {
        if (std.mem.eql(u8, value, e.t)) return e.v;
    }
    return null;
}

/// Core schema float (spec 10.3.2):
/// `[-+]? ( \. [0-9]+ | [0-9]+ ( \. [0-9]* )? ) ( [eE] [-+]? [0-9]+ )?`
/// plus the `.inf`/`.nan` spellings. At most one dot and one exponent,
/// the dot before the exponent, and the exponent digits are required —
/// so `1.2.3`, `1..2`, `1.2e3.4` and `1e` are all strings.
fn looksLikeFloat(value: []const u8) bool {
    if (floatSpecial(value) != null) return true;
    var i: usize = 0;
    if (i < value.len and (value[i] == '+' or value[i] == '-')) i += 1;

    var int_digits: usize = 0;
    while (i < value.len and value[i] >= '0' and value[i] <= '9') : (i += 1) int_digits += 1;

    var frac_digits: usize = 0;
    if (i < value.len and value[i] == '.') {
        i += 1;
        while (i < value.len and value[i] >= '0' and value[i] <= '9') : (i += 1) frac_digits += 1;
    }
    if (int_digits == 0 and frac_digits == 0) return false;

    if (i < value.len and (value[i] == 'e' or value[i] == 'E')) {
        i += 1;
        if (i < value.len and (value[i] == '+' or value[i] == '-')) i += 1;
        var exp_digits: usize = 0;
        while (i < value.len and value[i] >= '0' and value[i] <= '9') : (i += 1) exp_digits += 1;
        if (exp_digits == 0) return false;
    }
    // Anything left over (a second dot, a stray character) is not a float.
    return i == value.len;
}

/// One immutable copy of a parsed stream, shared by every `Document`
/// parsed from it.
///
/// Node spans are absolute byte offsets into the stream, so each document
/// needs the stream's bytes (not only its own region) for as long as it
/// lives. Giving every document its own copy costs documents x stream:
/// doubling the input quadrupled the memory, and 1 MiB of 9-byte documents
/// wanted ~114 GiB. One copy, released with the last document that
/// references it, costs one stream and leaves every document valid however
/// its siblings are freed.
const SharedSource = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    refs: std.atomic.Value(usize),

    /// Copy `input`. The caller holds the first reference.
    fn create(allocator: std.mem.Allocator, input: []const u8) !*SharedSource {
        const self = try allocator.create(SharedSource);
        errdefer allocator.destroy(self);
        const bytes = try allocator.dupe(u8, input);
        self.* = .{ .allocator = allocator, .bytes = bytes, .refs = .init(1) };
        return self;
    }

    fn retain(self: *SharedSource) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    /// Drop one reference; the last one frees the copy.
    fn release(self: *SharedSource) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.allocator;
        allocator.free(self.bytes);
        allocator.destroy(self);
    }
};

/// A parsed YAML document. All nodes live in `pool`; `deinit` releases
/// everything in one go.
pub const Document = struct {
    allocator: std.mem.Allocator,
    pool: Pool,
    root: ?*Node = null,
    version: ?VersionDirective = null,
    tag_directives: std.ArrayList(TagDirective) = .empty,
    explicit_start: bool = false,
    explicit_end: bool = false,
    /// The original input this document was parsed from, kept so the
    /// document owns its bytes. Null for programmatically built
    /// documents. This is what makes byte-faithful round trips possible.
    /// The documents of one stream (`parseAll`) read it through a single
    /// shared copy, reference-counted by `shared_source`, so a stream of
    /// any number of documents holds the input once.
    ///
    /// PORT NOTE: libfyaml borrows the reader's buffer instead; here
    /// the copy keeps the documented ownership model (a Document is
    /// valid after the caller frees the input).
    source: ?[]const u8 = null,
    /// Owner of `source` (null exactly when `source` is null). Internal:
    /// `deinit` drops this document's reference.
    shared_source: ?*SharedSource = null,
    /// Round-trip region of this document within `source`:
    /// [region_start, body_start) is the verbatim head (directives,
    /// `---`, leading comments), the root node's span is the body, and
    /// [root end, region_end) is the verbatim tail (trailing comments,
    /// `...`). Adjacent documents tile the stream exactly. `body_end`
    /// records the original root extent so a replaced root still finds
    /// the tail.
    region_start: usize = 0,
    body_start: usize = 0,
    body_end: usize = 0,
    region_end: usize = 0,
    /// INTERNAL. The undo log of the atomic batch in progress
    /// (`edit.Editor.apply`, merge resolution), or null. Transient: only
    /// `internal.Transaction` sets it.
    journal: ?*internal.Journal = null,

    pub fn init(allocator: std.mem.Allocator) Document {
        return .{ .allocator = allocator, .pool = Pool.init(allocator) };
    }

    pub fn deinit(self: *Document) void {
        self.tag_directives.deinit(self.allocator);
        self.pool.deinit();
        if (self.shared_source) |shared| shared.release();
        self.* = undefined;
    }

    /// Read the stream through `shared`, taking a reference that `deinit`
    /// drops. Cannot fail, so a document can be published for cleanup
    /// before anything that can.
    fn shareSource(self: *Document, shared: *SharedSource) void {
        shared.retain();
        self.shared_source = shared;
        self.source = shared.bytes;
    }

    /// Give this document a copy of `input` that no other document shares.
    fn ownSource(self: *Document, input: []const u8) !void {
        const shared = try SharedSource.create(self.allocator, input);
        self.shared_source = shared;
        self.source = shared.bytes;
    }

    /// Parse the first document of `input`. Extra documents in the same
    /// stream are ignored; use `parseAll` for multi-document streams.
    pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Document {
        return parseDiag(allocator, input, null);
    }

    /// Like `parse`, additionally recording a positioned diagnostic per
    /// problem in `d`. The error return is unchanged; on success `d`
    /// stays empty.
    pub fn parseDiag(allocator: std.mem.Allocator, input: []const u8, d: ?*diag.Diag) !Document {
        return parseOpts(allocator, input, d, .{});
    }

    /// `parseDiag` with explicit bounds and input policy. Pass `d` as
    /// null for no diagnostics.
    pub fn parseOpts(
        allocator: std.mem.Allocator,
        input: []const u8,
        d: ?*diag.Diag,
        options: ParseOptions,
    ) !Document {
        var p = try Parser.initOpts(allocator, d, input, options);
        defer p.deinit();
        var docs = try parseStream(allocator, &p, 1, input);
        defer docs.deinit(allocator);
        if (docs.items.len == 0) {
            // No node content reached the builder. An input that is
            // ENTIRELY comments and blank lines is already carried by
            // `parseStream`'s stream_end arm (it appends a rootless
            // document there); what arrives here is the genuinely empty
            // input, which still yields a rootless document so
            // `parse("")` and `parseAll("")` agree on the shape.
            return rootlessDocument(allocator, input);
        }
        var doc = docs.items[0];
        if (options.resolve_merge_keys) {
            doc.resolveMergeKeysLimited(options.max_merge_nodes) catch |err| {
                doc.deinit();
                return err;
            };
        }
        return doc;
    }

    /// Parse every document in `input`.
    pub fn parseAll(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(Document) {
        return parseAllDiag(allocator, input, null);
    }

    /// Like `parseAll`, additionally recording positioned diagnostics
    /// in `d`.
    pub fn parseAllDiag(allocator: std.mem.Allocator, input: []const u8, d: ?*diag.Diag) !std.ArrayList(Document) {
        return parseAllOpts(allocator, input, d, .{});
    }

    /// `parseAllDiag` with explicit bounds and input policy. Pass `d` as
    /// null for no diagnostics.
    pub fn parseAllOpts(
        allocator: std.mem.Allocator,
        input: []const u8,
        d: ?*diag.Diag,
        options: ParseOptions,
    ) !std.ArrayList(Document) {
        var p = try Parser.initOpts(allocator, d, input, options);
        defer p.deinit();
        var docs = try parseStream(allocator, &p, null, input);
        if (!options.resolve_merge_keys) return docs;
        errdefer {
            for (docs.items) |*doc| doc.deinit();
            docs.deinit(allocator);
        }
        for (docs.items) |*doc| try doc.resolveMergeKeysLimited(options.max_merge_nodes);
        return docs;
    }

    /// A document that carries bytes but has no node: an input that is
    /// entirely comments and blank lines. `emitFaithful` re-emits a null
    /// root's region verbatim, which is what makes
    /// `writeAll(parseAll(x)) == x` hold for such a stream.
    fn rootlessDocument(allocator: std.mem.Allocator, input: []const u8) !Document {
        var d = Document.init(allocator);
        errdefer d.deinit();
        try d.ownSource(input);
        d.region_start = 0;
        d.body_start = input.len;
        d.body_end = input.len;
        d.region_end = input.len;
        return d;
    }

    fn parseStream(allocator: std.mem.Allocator, p: *Parser, limit: ?usize, input: []const u8) !std.ArrayList(Document) {
        var docs: std.ArrayList(Document) = .empty;
        var doc: ?Document = null;
        var builder: ?Builder = null;
        var cursor: usize = 0;
        // ONE copy of the stream for every document parsed from it (see
        // `SharedSource`). This function holds the creating reference
        // until it returns, so a failure before the first document, or
        // after every document is already freed, cannot leak the copy.
        var stream_source: ?*SharedSource = null;
        defer if (stream_source) |shared| shared.release();
        errdefer {
            // Release every finished document plus the one in flight.
            for (docs.items) |*d| d.deinit();
            docs.deinit(allocator);
            if (builder) |*b| b.finish();
            if (doc) |*d| d.deinit();
        }

        while (try p.nextEvent()) |ev| {
            switch (ev.data) {
                .document_start => {
                    // Publish the new document to the function-scope
                    // errdefer BEFORE any allocation: every allocation
                    // below belongs to it, and a failure anywhere in the
                    // %TAG copy loop would otherwise leak the whole arena
                    // (the local was only assigned to `doc` at the end).
                    doc = Document.init(allocator);
                    const d = &doc.?;
                    d.version = ev.data.document_start.version;
                    d.explicit_start = !ev.data.document_start.implicit;
                    // Presentation spans are offsets into the stream, so
                    // the document keeps the stream's bytes alive for its
                    // whole lifetime. The copy is made once and shared:
                    // copying it per document made memory documents x
                    // stream.
                    if (stream_source == null) stream_source = try SharedSource.create(allocator, input);
                    d.shareSource(stream_source.?);
                    d.region_start = cursor;
                    // Copy directive strings into the pool so the document
                    // does not depend on the parser's lifetime. The two
                    // default handles the parser always installs are not
                    // document data and are not re-emitted.
                    for (ev.data.document_start.tags) |td| {
                        if (std.mem.eql(u8, td.handle, "!") and std.mem.eql(u8, td.prefix, "!")) continue;
                        if (std.mem.eql(u8, td.handle, "!!") and std.mem.eql(u8, td.prefix, "tag:yaml.org,2002:")) continue;
                        try d.tag_directives.append(allocator, .{
                            .handle = try d.pool.dupe(td.handle),
                            .prefix = try d.pool.dupe(td.prefix),
                        });
                    }
                    // The builder works on the live document copy.
                    builder = Builder.init(d);
                },
                .document_end => {
                    if (builder) |*b| b.finish();
                    builder = null;
                    var d = doc orelse return error.InvalidSyntax;
                    d.explicit_end = !ev.data.document_end.implicit;
                    d.finishRegion(ev.start.offset);
                    // Hand ownership over only once the append succeeds;
                    // on failure the errdefer still sees `doc` and frees it.
                    try docs.append(allocator, d);
                    doc = null;
                    if (docs.items.len > 0) cursor = docs.items[docs.items.len - 1].region_end;
                    if (limit) |l| if (docs.items.len >= l) {
                        // Stopping here skips the stream_end arm below,
                        // which is where the last document claims its
                        // tail. Claim it now when only blank and comment
                        // lines remain; a directive or any content means
                        // another document follows (`a: 1\n...\nb: 2\n`
                        // needs no `---`), and the clamped region already
                        // stops in front of it. Decided on the bytes, not
                        // by peeking the parser: a malformed second
                        // document must not fail, or diagnose, a
                        // successful single-document parse.
                        const last = &docs.items[docs.items.len - 1];
                        if (isTrailer(input[last.region_end..])) last.region_end = input.len;
                        break;
                    };
                },
                .stream_start, .stream_end => {
                    if (ev.data == .stream_end) {
                        // The last document owns everything up to EOF, so
                        // trailing comments after its content (or after
                        // its `...`) stay in its region.
                        if (docs.items.len > 0) {
                            docs.items[docs.items.len - 1].region_end = input.len;
                        } else if (input.len > 0) {
                            // No document at all, but the stream still
                            // has bytes: it is entirely comments and
                            // blank lines. `writeAll(parseAll(x)) == x`
                            // is a documented promise, and with no
                            // document to carry them those bytes were
                            // silently erased — a fully commented-out
                            // config file came back empty. Carry them
                            // as one rootless document; the faithful
                            // emitter re-emits a null root's region
                            // verbatim.
                            var only = try rootlessDocument(allocator, input);
                            errdefer only.deinit();
                            try docs.append(allocator, only);
                        }
                    }
                },
                else => {
                    if (builder) |*b| try b.handle(ev);
                },
            }
        }
        return docs;
    }

    // ------------------------------------------------------------------
    // Node construction (fy_node_create_* equivalents)
    // ------------------------------------------------------------------

    /// Create a scalar node, duplicating `value` into the document pool.
    pub fn createScalar(self: *Document, value: []const u8, style: ScalarStyle) !*Node {
        const n = try self.pool.create(Node);
        n.* = .{ .data = .{ .scalar = .{ .value = try self.pool.dupe(value), .style = style } } };
        return n;
    }

    /// Create a scalar node taking ownership of a pool-owned value.
    pub fn createScalarOwned(self: *Document, value: []const u8, style: ScalarStyle) !*Node {
        const n = try self.pool.create(Node);
        n.* = .{ .data = .{ .scalar = .{ .value = value, .style = style } } };
        return n;
    }

    pub fn createMapping(self: *Document) !*Node {
        const n = try self.pool.create(Node);
        n.* = .{ .data = .{ .mapping = .{} } };
        return n;
    }

    pub fn createSequence(self: *Document) !*Node {
        const n = try self.pool.create(Node);
        n.* = .{ .data = .{ .sequence = .{} } };
        return n;
    }

    /// Define or clear the anchor on `node`. `name` null clears it.
    ///
    /// Clearing (or renaming) an anchor that an alias in this document
    /// still names would strand that alias, so it is refused with
    /// `error.AnchorReferenced`; delete the aliases first. Defining a
    /// name a second time is allowed, as it is in YAML (`&a` twice:
    /// the later definition shadows the earlier for aliases after it)
    /// -- and it is how an aliased scalar gets a new value, since the
    /// anchor lives on the node: build the replacement, give it the same
    /// name, and `set` it over the old node. The edit surface treats a
    /// replacement carrying the replaced node's anchor as the anchor
    /// moving with the slot, and re-points the aliases at it.
    ///
    /// A name must be one or more non-blank characters with no flow
    /// indicator (`,[]{}`), the YAML anchor alphabet.
    pub fn setAnchor(self: *Document, node: *Node, name: ?[]const u8) !void {
        if (name) |n| {
            if (n.len == 0) return error.InvalidSyntax;
            for (n) |c| switch (c) {
                ' ', '\t', '\n', '\r', ',', '[', ']', '{', '}' => return error.InvalidSyntax,
                else => {},
            };
            if (node.anchor) |cur| {
                if (std.mem.eql(u8, cur, n)) return;
            }
        } else if (node.anchor == null) return;
        if (node.anchor) |cur| {
            if (self.root) |root| {
                if (aliasNamed(root, cur, 0)) return error.AnchorReferenced;
            }
        }
        node.anchor = if (name) |n| try self.pool.dupe(n) else null;
        try self.markModified(node);
    }

    /// Point every alias in this document named `name` at `target`.
    /// Used when the node carrying an anchor is replaced by one that
    /// carries the same name: the aliases follow the anchor.
    pub fn retargetAliases(self: *Document, name: []const u8, target: *Node) !void {
        const root = self.root orelse return;
        try self.retarget(root, name, target, 0);
    }

    fn retarget(self: *Document, node: *Node, name: []const u8, target: *Node, depth: usize) !void {
        if (depth >= max_alias_walk) return;
        switch (node.data) {
            .alias => |a| if (std.mem.eql(u8, a.name, name)) {
                try internal.setAliasTarget(self, node, target);
            },
            .mapping => |m| for (m.pairs.items) |p| {
                try self.retarget(p.key, name, target, depth + 1);
                try self.retarget(p.value, name, target, depth + 1);
            },
            .sequence => |sq| for (sq.items.items) |item| try self.retarget(item, name, target, depth + 1),
            .scalar => {},
        }
    }

    /// Does any alias under `node` name `name`? Aliases are leaves here
    /// -- never followed -- so a parsed alias cycle cannot recurse.
    fn aliasNamed(node: *const Node, name: []const u8, depth: usize) bool {
        if (depth >= max_alias_walk) return false;
        return switch (node.data) {
            .alias => |a| std.mem.eql(u8, a.name, name),
            .mapping => |m| for (m.pairs.items) |p| {
                if (aliasNamed(p.key, name, depth + 1) or aliasNamed(p.value, name, depth + 1)) break true;
            } else false,
            .sequence => |s| for (s.items.items) |item| {
                if (aliasNamed(item, name, depth + 1)) break true;
            } else false,
            .scalar => false,
        };
    }

    /// Structural walks over the tree stop here; matches the edit
    /// surface's `max_walk_depth`.
    const max_alias_walk: usize = 1000;

    // ------------------------------------------------------------------
    // Mutation (fy_node_* insert equivalents)
    // ------------------------------------------------------------------

    // The structural attach/drop plumbing (`attachPair`, `attachItem`,
    // `dropPairSpan`, `dropItemSpan`) lives in `internal.zig` as free
    // functions, so it is unreachable from outside the module.

    /// Append a key/value pair to a mapping node, maintaining parent links.
    pub fn mappingAppend(self: *Document, map: *Node, key: *Node, value: *Node) !void {
        if (attachRefusal(map, key)) |reason| return reason;
        if (attachRefusal(map, value)) |reason| return reason;
        try internal.attachPair(self, map, key, value);
        try internal.adopt(self, key);
        try internal.adopt(self, value);
    }

    /// Append an item to a sequence node, maintaining parent links.
    pub fn sequenceAppend(self: *Document, seq: *Node, item: *Node) !void {
        if (attachRefusal(seq, item)) |reason| return reason;
        try internal.attachItem(self, seq, item);
        try internal.adopt(self, item);
    }

    /// Insert an item into a sequence at `index`.
    ///
    /// Guarded like the append siblings. Without the guard an insert could
    /// splice an ancestor under its own descendant, and `markModified`
    /// then tripped its parent-cycle assert -- a panic reachable through
    /// the public API (and through `Editor`'s insert/set).
    pub fn sequenceInsert(self: *Document, seq: *Node, index: usize, item: *Node) !void {
        if (attachRefusal(seq, item)) |reason| return reason;
        switch (seq.data) {
            .sequence => {
                try internal.insertItem(self, seq, index, item);
                try internal.setParent(self, item, seq);
                try internal.adopt(self, item);
            },
            else => return error.InvalidSyntax,
        }
    }

    /// Remove the mapping entry with scalar key `key`; returns the removed
    /// value node or null when no such key exists. The entry's source
    /// bytes are tombstoned so emission skips them.
    ///
    /// RAW: this detaches the key as well as the value and does NOT check
    /// whether either carries an anchor an alias still needs, so removing
    /// an anchored pair can emit a document that will not reparse.
    /// `edit.Editor` is the guarded path; use it unless the tree is known
    /// to contain no aliases.
    pub fn mappingRemove(self: *Document, map: *Node, key: []const u8) !?*Node {
        switch (map.data) {
            .mapping => |m| {
                for (m.pairs.items, 0..) |p, i| {
                    if (std.mem.eql(u8, p.key.scalarValue() orelse continue, key)) {
                        try internal.dropPairSpan(self, map, p);
                        const removed = try internal.removePair(self, map, i);
                        try internal.setParent(self, removed.value, null);
                        try internal.setParent(self, removed.key, null);
                        try self.markModified(map);
                        return removed.value;
                    }
                }
                return null;
            },
            else => return error.InvalidSyntax,
        }
    }

    /// Remove the sequence item at `index`.
    pub fn sequenceRemove(self: *Document, seq: *Node, index: usize) !?*Node {
        switch (seq.data) {
            .sequence => |s| {
                if (index >= s.items.items.len) return null;
                // Tombstone BEFORE detaching: the span depends on where
                // the following item starts (as in `mappingRemove`).
                const removed = s.items.items[index];
                try internal.dropItemSpan(self, seq, removed);
                _ = try internal.removeItem(self, seq, index);
                try internal.setParent(self, removed, null);
                try self.markModified(seq);
                return removed;
            },
            else => return error.InvalidSyntax,
        }
    }
    // ------------------------------------------------------------------
    // Merge keys (<<) — opt-in resolution (PLAN-16,
    // docs/design/merge-keys.md)
    //
    // PORT NOTE: libfyaml has two merge implementations that disagree on
    // the value rule. `fy_document_resolve` (the FYPCF_RESOLVE_DOCUMENT
    // path) requires the value to be an alias (or aliases) to a mapping;
    // the event path (`fy_parser_get_merge_key_document`) also accepts a
    // direct mapping and direct mappings inside a sequence. yayl follows
    // the permissive YAML 1.1 rule (the event path), in one place. It is
    // merge-only: aliases outside the merged mapping are kept, unlike
    // fy_document_resolve, which also inlines every alias and purges all
    // anchors.
    // ------------------------------------------------------------------

    /// Deepest resolution this pass will walk before returning
    /// `error.NestingTooDeep`. Parsed input is already capped at
    /// `max_nesting`; this bounds a tree that was built by hand.
    const max_merge_depth: usize = 1000;

    /// Resolution state for one mapping node. `active` is a mapping the
    /// walk is currently inside; reaching it again as a merge source is a
    /// self-referential merge.
    const MergeVisit = enum { active, done };

    /// Error vocabulary of the merge-resolution walk. Explicit because
    /// the helpers are mutually recursive and Zig cannot infer an error
    /// set through a cycle.
    const MergeResolveError = error{
        InvalidMergeKey,
        MergeKeyRecursive,
        NestingTooDeep,
        InvalidSyntax,
        LimitExceeded,
        OutOfMemory,
    };

    /// One resolution: the visit state of each mapping, and how many
    /// nodes it may still create by copying merge sources.
    const MergeRun = struct {
        seen: std.AutoHashMap(*Node, MergeVisit),
        remaining: usize,
    };

    /// Resolve YAML 1.1 merge keys (`<<`) in place.
    ///
    /// A mapping pair whose key is a plain scalar `<<` contributes the
    /// pairs of its value: a mapping, an alias to one, or a sequence of
    /// those. A key the mapping already has wins; among sequence sources
    /// the earliest wins. The `<<` pair is removed afterwards.
    ///
    /// It is atomic (the `edit.apply` contract, through the same undo
    /// journal): a document that fails to resolve — an invalid value, a
    /// merge that reaches itself, a size, depth or allocation failure —
    /// is left byte-identical, spans included. A document with no `<<` is
    /// returned untouched.
    ///
    /// `ParseOptions.resolve_merge_keys` calls this after each document
    /// is built. Resolution re-emits the mappings it touches normalized,
    /// exactly like any other structural mutation.
    ///
    /// Every merge copies its source's pairs, so the result can be far
    /// larger than the document: this stops with `error.LimitExceeded`
    /// once it would create more than `ParseOptions.max_merge_nodes`
    /// nodes (see `resolveMergeKeysLimited`).
    pub fn resolveMergeKeys(self: *Document) !void {
        return self.resolveMergeKeysLimited((ParseOptions{}).max_merge_nodes);
    }

    /// `resolveMergeKeys` creating at most `max_nodes` nodes.
    pub fn resolveMergeKeysLimited(self: *Document, max_nodes: usize) !void {
        const root = self.root orelse return;
        if (!treeHasMergeKey(root, 0)) return;
        // Atomic through the undo journal (`internal.Journal`), as for
        // `edit.Editor.apply`: a failure rolls every change back.
        var txn: internal.Transaction = undefined;
        txn.begin(self);
        errdefer txn.abort();
        var run: MergeRun = .{ .seen = std.AutoHashMap(*Node, MergeVisit).init(self.allocator), .remaining = max_nodes };
        defer run.seen.deinit();
        try self.resolveMergeNode(root, &run, 0);
        try txn.commit();
    }

    /// True when any mapping pair in `node` is a merge key. Structural
    /// only: an alias is not followed, because a mapping reachable by
    /// alias is also present structurally.
    fn treeHasMergeKey(node: *const Node, depth: usize) bool {
        if (depth >= max_merge_depth) return true; // let the pass report it
        switch (node.data) {
            .scalar, .alias => return false,
            .sequence => |s| {
                for (s.items.items) |item| {
                    if (treeHasMergeKey(item, depth + 1)) return true;
                }
                return false;
            },
            .mapping => |m| {
                for (m.pairs.items) |p| {
                    if (isMergeKeyPair(p)) return true;
                    if (treeHasMergeKey(p.key, depth + 1)) return true;
                    if (treeHasMergeKey(p.value, depth + 1)) return true;
                }
                return false;
            },
        }
    }

    /// A merge key is a pair whose key is a *plain* scalar `<<`
    /// (`fy_node_pair_is_merge_key`); a quoted `<<` is an ordinary key.
    fn isMergeKeyPair(p: Pair) bool {
        const k = p.key;
        return k.data == .scalar and
            k.data.scalar.style == .plain and
            std.mem.eql(u8, k.data.scalar.value, "<<");
    }

    fn resolveMergeNode(
        self: *Document,
        node: *Node,
        run: *MergeRun,
        depth: usize,
    ) MergeResolveError!void {
        if (depth >= max_merge_depth) return error.NestingTooDeep;
        switch (node.data) {
            .scalar, .alias => {},
            .sequence => |s| {
                for (s.items.items) |item| try self.resolveMergeNode(item, run, depth + 1);
            },
            .mapping => {
                if (run.seen.get(node)) |state| {
                    if (state == .done) return;
                    return error.MergeKeyRecursive;
                }
                try run.seen.put(node, .active);
                // Nested mappings first, so a merge source is fully
                // expanded by the time its pairs are copied.
                const m = &node.data.mapping;
                for (m.pairs.items) |p| {
                    try self.resolveMergeNode(p.key, run, depth + 1);
                    try self.resolveMergeNode(p.value, run, depth + 1);
                }
                try self.resolveMappingMerges(node, run, depth);
                try run.seen.put(node, .done);
            },
        }
    }

    /// Expand every `<<` entry of `map`, earliest first, so an explicit
    /// key wins and the first merge wins among duplicates. Every merge
    /// value is collected before any pair is removed, so an appended pair
    /// can never be mistaken for a merge entry.
    fn resolveMappingMerges(
        self: *Document,
        map: *Node,
        run: *MergeRun,
        depth: usize,
    ) MergeResolveError!void {
        const m = &map.data.mapping;
        var values: std.ArrayList(*Node) = .empty;
        defer values.deinit(self.allocator);
        for (m.pairs.items) |p| {
            if (isMergeKeyPair(p)) try values.append(self.allocator, p.value);
        }
        if (values.items.len == 0) return;
        // Remove the entries before merging: an explicit key then wins the
        // duplicate check, and `<<` cannot shadow a source key.
        var i: usize = m.pairs.items.len;
        while (i > 0) {
            i -= 1;
            const p = m.pairs.items[i];
            if (!isMergeKeyPair(p)) continue;
            try internal.dropPairSpan(self, map, p);
            _ = try internal.removePair(self, map, i);
            try internal.setParent(self, p.key, null);
            try internal.setParent(self, p.value, null);
        }
        // The key texts the mapping holds, so each copied pair's check is
        // one lookup: scanning the pairs made every merge quadratic.
        var present: std.StringHashMapUnmanaged(void) = .empty;
        defer present.deinit(self.allocator);
        for (m.pairs.items) |p| {
            if (p.key.scalarValue()) |t| try present.put(self.allocator, t, {});
        }
        for (values.items) |value| try self.mergeValueInto(map, value, run, &present, depth);
        try self.markModified(map);
    }

    /// Add the pairs a merge value contributes to `map`, in source order,
    /// skipping keys the mapping already has.
    fn mergeValueInto(
        self: *Document,
        map: *Node,
        value: *Node,
        run: *MergeRun,
        present: *std.StringHashMapUnmanaged(void),
        depth: usize,
    ) MergeResolveError!void {
        const resolved = value.resolveAlias();
        switch (resolved.data) {
            .mapping => try self.mergeOneInto(map, @constCast(resolved), run, present, depth),
            .sequence => |s| {
                for (s.items.items) |item| {
                    const src = item.resolveAlias();
                    if (src.kind() != .mapping) return error.InvalidMergeKey;
                    try self.mergeOneInto(map, @constCast(src), run, present, depth);
                }
            },
            else => return error.InvalidMergeKey,
        }
    }

    fn mergeOneInto(
        self: *Document,
        map: *Node,
        source: *Node,
        run: *MergeRun,
        present: *std.StringHashMapUnmanaged(void),
        depth: usize,
    ) MergeResolveError!void {
        // Resolve the source before copying from it; a source that is
        // still `active` is a merge cycle.
        try self.resolveMergeNode(source, run, depth + 1);
        for (source.data.mapping.pairs.items) |p| {
            // A key the mapping already has wins. Compared on the
            // RESOLVED text, while `isMergeKeyPair` is style-sensitive:
            // a quoted `"a": 9` is not a merge key, but it does block a
            // merged plain `a` -- detection follows the spec form of
            // `<<`, equality follows how a reader reads a key. Non-scalar
            // keys never collide, as for `lookup`.
            const text = p.key.scalarValue();
            if (text) |t| if (present.contains(t)) continue;
            const key = try self.cloneMergeNode(p.key, run, 0);
            const value = try self.cloneMergeNode(p.value, run, 0);
            // Raw attach: a freshly cloned node is detached, so it
            // cannot cycle, and resolveMappingMerges marks the mapping.
            try internal.attachPair(self, map, key, value);
            if (text) |t| try present.put(self.allocator, t, {});
        }
    }

    /// Copy one node into this document's pool for insertion at a new
    /// place: strings are duped, presentation spans and written comments
    /// are dropped (the pair re-emits normalized), and an anchor is NOT
    /// carried, so the copy never becomes a second definition of a name
    /// the source already anchors. An alias is copied as an alias: its
    /// target stays in this document, so the reference remains valid and
    /// the document keeps its anchors.
    fn cloneMergeNode(self: *Document, node: *Node, run: *MergeRun, depth: usize) MergeResolveError!*Node {
        if (depth >= max_merge_depth) return error.NestingTooDeep;
        if (run.remaining == 0) return error.LimitExceeded;
        run.remaining -= 1;
        const n = try self.pool.create(Node);
        n.* = .{
            .mark = node.mark,
            .tag = if (node.tag) |t| try self.pool.dupe(t) else null,
            .modified = true,
            .data = undefined,
        };
        switch (node.data) {
            .scalar => |s| {
                n.data = .{ .scalar = .{ .value = try self.pool.dupe(s.value), .style = s.style } };
            },
            .alias => |a| {
                n.data = .{ .alias = .{ .name = try self.pool.dupe(a.name), .target = a.target } };
            },
            .sequence => |s| {
                n.data = .{ .sequence = .{ .style = s.style } };
                for (s.items.items) |item| {
                    try internal.attachItem(self, n, try self.cloneMergeNode(item, run, depth + 1));
                }
            },
            .mapping => |m| {
                n.data = .{ .mapping = .{ .style = m.style } };
                for (m.pairs.items) |p| {
                    const key = try self.cloneMergeNode(p.key, run, depth + 1);
                    const value = try self.cloneMergeNode(p.value, run, depth + 1);
                    try internal.attachPair(self, n, key, value);
                }
            },
        }
        return n;
    }

    // ------------------------------------------------------------------
    // Comments: writes (docs/design/comments.md, approved 2026-09-02)
    // ------------------------------------------------------------------

    /// Set the node's trailing (same-line) comment. Null deletes it.
    /// `text` is raw — exactly what `trailingComment` returns: one line
    /// starting with `#`, no line breaks. A written comment re-emits
    /// canonically as `content # text` (single blank, the node's own
    /// line terminator convention kept); deleting removes the old
    /// comment and its separating blanks but keeps the terminator.
    ///
    /// Re-setting the comment the node already has is a no-op: nothing
    /// is marked, every source byte stays. The same guarantee the edit
    /// API gives for unchanged scalars, and the property the
    /// preservation sweep asserts at every comment position.
    ///
    /// Only scalars and aliases carry a writable trailing comment — a
    /// block collection's trailing comment sits on its last entry's
    /// line, so address it through that entry. A comment is not
    /// addressable inside a flow collection, and a block scalar's value
    /// owns every line after its header, so `setTrailingComment`
    /// rejects containers, flow-positioned nodes, literal/folded scalars
    /// and nodes inside a new or moved subtree (laid out afresh, without
    /// comments) with `error.InvalidSyntax` rather than silently
    /// dropping the write at emission time.
    pub fn setTrailingComment(self: *Document, node: *Node, text: ?[]const u8) !void {
        // Validate the position first: a write that emission would
        // silently drop must fail here instead.
        if (!self.trailingWritablePosition(node)) return error.InvalidSyntax;
        const t = text orelse {
            if (node.trailingComment(self) == null) return; // nothing to delete
            node.pending_trailing = "";
            try self.markModified(node);
            return;
        };
        try validateTrailingText(t);
        // Set-to-same is a no-op, so the byte-identical invariant holds
        // whatever spacing the original had.
        if (node.trailingComment(self)) |cur| {
            if (std.mem.eql(u8, cur, t)) return;
        }
        node.pending_trailing = try self.pool.dupe(t);
        try self.markModified(node);
    }

    /// Set the node's leading comment block: the own-line comments
    /// immediately above the entry. Null deletes the block. `text` is
    /// the raw block, newline-joined (`"# one\n# two"`), every line
    /// blank-indented then `#`; one trailing newline is tolerated.
    /// Written lines re-emit at the entry's own column, with the
    /// document's line-terminator convention; a deleted block's lines
    /// disappear whole.
    ///
    /// The block belongs to the line, not to one node: a write through
    /// any node starting on it replaces what is written above that line,
    /// and the block lives as long as the outermost of those nodes. A
    /// collection's first entry shares the collection's line, so a block
    /// written there stays above whichever entry is first -- after that
    /// entry is deleted, or another inserted ahead of it -- as a comment
    /// in the source would; a later entry owns its own line, and its
    /// block is deleted with it.
    ///
    /// Like `setTrailingComment`, set-to-same is a no-op. Rejects nodes
    /// whose comment block cannot be rewritten honestly — a root scalar
    /// (its head is free-floating), a scalar sitting as a block value
    /// (no gap of its own to rewrite), anything inside a flow
    /// collection or inside a new or moved subtree (laid out afresh,
    /// without comments), and a block separated from this document's
    /// region — with `error.InvalidSyntax`.
    pub fn setLeadingComments(self: *Document, node_in: *Node, text: ?[]const u8) !void {
        const t: ?[]const u8 = if (text) |raw| try normalizeLeadingText(raw) else null;
        // The block belongs to the outermost node starting on this line.
        const node = if (self.source) |src| leadingOwner(node_in, src) else node_in;
        // Position and current block, for the no-op check and the
        // tombstone below.
        const current: ?[]const u8 = blk: {
            if (self.leadingPositionWritable(node)) break :blk node.leadingComments(self);
            // Deleting from an unwritable position is a no-op unless a
            // pending override exists there to remove.
            if (t == null and node.pending_leading != null) break :blk node.pending_leading;
            return error.InvalidSyntax;
        };
        if (t) |body| {
            if (current) |cur| {
                if (std.mem.eql(u8, cur, body)) return;
            }
        } else if (current == null) return; // nothing to delete

        // Sequence matters for OOM: duplicate first, tombstone second,
        // publish last — a failure before the publish leaves the node
        // untouched (the duplicate is pool garbage, freed with the pool).
        const stored: ?[]const u8 = if (t) |body| try self.pool.dupe(body) else "";
        const src = self.source.?;
        // The block replaces everything written above the line. An entry
        // that became first after a sibling was deleted still carries its
        // own written block, or its source block in its own gap; both
        // would be written below the new one.
        var c: ?*Node = nextOnLine(node, src);
        while (c) |inner| : (c = nextOnLine(inner, src)) {
            if (inner.pending_leading == null and !sameLeadingSource(self, inner, node)) {
                if (self.leadingSourceSpan(inner) != null) try self.tombstoneLeadingBlock(inner);
            }
        }
        if (current != null and node.pending_leading == null) try self.tombstoneLeadingBlock(node);
        c = nextOnLine(node, src);
        while (c) |inner| : (c = nextOnLine(inner, src)) {
            clearPendingLeading(inner);
        }
        node.pending_leading = stored;
        try self.markModified(node);
    }

    /// Drop a written block from `node` (and from a key's inline value,
    /// which `internal.pairLeadingOverride` also reads). Its source block
    /// was tombstoned when it was written.
    fn clearPendingLeading(node: *Node) void {
        node.pending_leading = null;
        if (node.parent) |p| if (p.pairs()) |ps| for (ps) |pair| {
            if (pair.key == node) pair.value.pending_leading = null;
        };
    }

    /// True when `inner` reads its source block from the same bytes as
    /// `outer`: they shared the line in the source.
    fn sameLeadingSource(self: *const Document, inner: *const Node, outer: *const Node) bool {
        const a = self.leadingSourceSpan(inner) orelse return true;
        const b = self.leadingSourceSpan(outer) orelse return false;
        return a[0] == b[0] and a[1] == b[1];
    }

    /// True when `setTrailingComment` can act on this node.
    fn trailingWritablePosition(self: *const Document, node: *Node) bool {
        // Below a node with no source bytes the emitter lays everything
        // out afresh and writes no comments: the write was accepted and
        // dropped.
        if (!trailingPlaced(node)) return false;
        // An empty node that reads no trailing comment (an empty item or
        // document) must not take one: it was accepted and never written.
        if (node.src) |s| if (s.synthetic) {
            const src = self.source orelse return false;
            if (trailingAnchor(node, src) == null) return false;
        };
        switch (node.data) {
            .scalar => |s| switch (s.style) {
                .literal, .folded => return false, // the value owns its lines
                else => {},
            },
            .mapping, .sequence => return false, // address the last entry
            .alias => {},
        }
        // A multi-line value re-emits as a block scalar, whose lines
        // are all its own; a comment written now would be dropped at
        // emission time.
        if (node.scalarValue()) |v| {
            if (std.mem.indexOfScalar(u8, v, '\n') != null) return false;
        }
        if (insideFlow(node)) return false;
        if (isMappingKey(node)) return false; // the pair's comment lives after the value
        return true;
    }

    /// True when `setLeadingComments` can act on this node: the position
    /// has a gap of its own, and that gap is rewritable verbatim bytes.
    fn leadingPositionWritable(self: *const Document, node: *Node) bool {
        if (insideFlow(node)) return false;
        // Inside a new or moved subtree, or under a replaced root: laid
        // out afresh, and a written block was accepted and dropped.
        if (!leadingPlaced(node)) return false;
        // An empty node's span is a point borrowed from the next token:
        // it has no line of its own to write a block above, and reads
        // none. The write used to be accepted and then dropped.
        if (node.src) |s| if (s.synthetic) return false;
        const src = self.source orelse return false;
        const owner = gapOwnerForLeading(node, src) orelse return false;
        return dropsOf(owner) != null;
    }

    /// Tombstone the source lines of the node's current leading block,
    /// so the verbatim gap walk skips them. The range covers whole
    /// lines: the structural separator before the block (the previous
    /// line's terminator) survives, and so does the entry's own
    /// indentation after it.
    /// The source span of the block above `owner`'s entry line (see
    /// `leadingOwner`), or null.
    fn leadingSourceSpan(self: *const Document, owner: *const Node) ?[2]usize {
        const src = self.source orelse return null;
        const s = owner.src orelse return null; // brand-new: no block in the source
        if (s.synthetic) return null;
        return markup.leadingCommentSpan(src, s.entry_start, leadingFloor(owner, self));
    }

    fn tombstoneLeadingBlock(self: *Document, node: *Node) !void {
        const src = self.source orelse return;
        const span = self.leadingSourceSpan(node) orelse return;
        // A root entry sharing its line with `---` reads backwards into
        // the previous document's region; those bytes are not ours.
        if (span[0] < self.region_start or span[1] > self.region_end) return error.InvalidSyntax;
        const owner = gapOwnerForLeading(node, src) orelse return error.InvalidSyntax;
        if (dropsOf(owner) == null) return error.InvalidSyntax;
        const from = markup.lineStart(src, span[0]);
        const to = markup.lineEnd(src, span[1]);
        if (to <= from) return;
        try internal.dropRange(self, owner, from, to);
    }

    /// Refuse comment bytes the scanner refuses on input: a write that
    /// `write` would emit raw and `parse` would then reject is not a
    /// write. Invalid UTF-8 fails the way the scanner fails it
    /// (error.InvalidUtf8); a NUL is a syntax error there too. The rest
    /// of what §5.1 leaves printable — NEL, LS, PS, a BOM, C0 controls,
    /// DEL — the scanner accepts inside a comment, so it stays accepted.
    fn validateCommentBytes(t: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(t)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, t, 0) != null) return error.InvalidSyntax;
    }

    fn validateTrailingText(t: []const u8) !void {
        if (t.len == 0 or t[0] != '#') return error.InvalidSyntax;
        for (t) |c| {
            if (c == '\n' or c == '\r') return error.InvalidSyntax;
        }
        try validateCommentBytes(t);
    }

    /// Strip one optional trailing newline and require every line to be
    /// blank-indented then `#`. Blank lines inside a block are rejected:
    /// they would break the adjacency that makes the block re-readable.
    fn normalizeLeadingText(raw: []const u8) ![]const u8 {
        var t = raw;
        if (std.mem.endsWith(u8, t, "\r\n"))
            t = t[0 .. t.len - 2]
        else if (std.mem.endsWith(u8, t, "\n") or std.mem.endsWith(u8, t, "\r"))
            t = t[0 .. t.len - 1];
        if (t.len == 0) return error.InvalidSyntax;
        try validateCommentBytes(t);

        // A CR is only ever the first byte of a CRLF separator. A LONE
        // CR is a YAML line break (§5.4), so it ends the comment and
        // whatever follows becomes document structure on reparse:
        // `setLeadingComments(n, "# c\rinjected: yes")` split on `\n`
        // alone is one "line" starting with `#`, validates, is emitted
        // raw, and comes back as a real mapping entry. That is caller
        // input crossing a validation boundary into document structure.
        // `validateTrailingText` closes the same hole by refusing CR
        // outright; the leading side has to allow CRLF between lines,
        // so it refuses the lone form specifically.
        for (t, 0..) |c, i| {
            if (c == '\r' and (i + 1 >= t.len or t[i + 1] != '\n')) return error.InvalidSyntax;
        }

        var it = std.mem.splitScalar(u8, t, '\n');
        while (it.next()) |raw_line| {
            const line = if (std.mem.endsWith(u8, raw_line, "\r"))
                raw_line[0 .. raw_line.len - 1]
            else
                raw_line;
            var i: usize = 0;
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
            if (i >= line.len or line[i] != '#') return error.InvalidSyntax;
        }
        return t;
    }

    fn isMappingValue(node: *const Node) bool {
        const parent = node.parent orelse return false;
        const ps = parent.pairs() orelse return false;
        for (ps) |p| {
            if (p.value == node) return true;
        }
        return false;
    }

    fn isMappingKey(node: *const Node) bool {
        const parent = node.parent orelse return false;
        if (parent.kind() != .mapping) return false;
        for (parent.pairs().?) |p| {
            if (p.key == node) return true;
        }
        return false;
    }

    fn insideFlow(node: *const Node) bool {
        const parent = node.parent orelse return false;
        return switch (parent.data) {
            .mapping => |m| m.style == .flow,
            .sequence => |s| s.style == .flow,
            else => false,
        };
    }

    /// The container whose verbatim gap carries the node's leading
    /// block, and therefore whose tombstone list must record it: the
    /// parent for keys, items and inline values; the node itself for a
    /// block value (the comments sit between its key's colon and its
    /// first line). Null when the position has no gap of its own.
    fn gapOwnerForLeading(node: *Node, src: []const u8) ?*Node {
        const parent = node.parent orelse {
            // The root. A container's first entry can carry a block in
            // the document head; a root scalar's head is free-floating.
            return switch (node.data) {
                .mapping, .sequence => node,
                else => null,
            };
        };
        switch (parent.data) {
            .mapping => {
                if (isBlockValue(parent, node, src)) return node;
                return parent;
            },
            .sequence => return parent,
            else => return null,
        }
    }

    /// True when `node` is a mapping value that starts on its own line
    /// (a block value), rather than one sitting after `key:` on the
    /// key's line.
    fn isBlockValue(parent: *const Node, node: *const Node, src: []const u8) bool {
        const ps = parent.pairs() orelse return false;
        for (ps) |p| {
            if (p.value != node) continue;
            const ks = p.key.src orelse return false;
            const ns = node.src orelse return false;
            if (ks.synthetic or ns.synthetic) return false;
            return markup.lineStart(src, ns.entry_start) > markup.lineStart(src, ks.start);
        }
        return false;
    }

    fn dropsOf(node: *Node) ?*std.ArrayList([2]usize) {
        return switch (node.data) {
            .mapping => |*m| &m.dropped,
            .sequence => |*s| &s.dropped,
            else => null,
        };
    }

    /// Look a node up by mapping-key path.
    pub fn pathGet(self: *const Document, path: []const []const u8) ?*Node {
        const r = self.root orelse return null;
        return r.byPath(path);
    }

    /// Walk the mapping-key chain `keys` (the segments ABOVE a final
    /// key) from the root, creating the root mapping and intermediate
    /// mappings as needed; returns the container holding the final key.
    pub fn mappingWalkOrCreate(self: *Document, keys: []const []const u8) !*Node {
        if (self.root == null) {
            try internal.setRoot(self, try self.createMapping());
        }
        var cur = self.root.?;
        for (keys) |seg| {
            if (cur.lookup(seg)) |next| {
                if (!next.isMapping()) return error.NotAMapping;
                cur = next;
            } else {
                const m = try self.createMapping();
                try self.mappingAppend(cur, try self.createScalar(seg, .plain), m);
                cur = m;
            }
        }
        return cur;
    }

    /// Set the value at a mapping-key path, creating intermediate mappings
    /// as needed. The final segment is replaced or appended.
    pub fn pathSet(self: *Document, path: []const []const u8, value: *Node) !void {
        if (path.len == 0) return error.InvalidSyntax;
        const cur = try self.mappingWalkOrCreate(path[0 .. path.len - 1]);
        const last = path[path.len - 1];
        if (cur.lookup(last)) |existing| {
            // `lookup` only matches values of the mapping `cur`, so the
            // in-place replace must succeed; falling through would
            // append a duplicate key.
            if (!try internal.mappingReplace(self, cur, existing, value)) return error.InvalidSyntax;
            return;
        }
        try self.mappingAppend(cur, try self.createScalar(last, .plain), value);
    }

    /// Delete the mapping entry at a mapping-key path. Returns true when
    /// something was removed.
    ///
    /// RAW: like `mappingRemove`, no alias-stranding check is performed.
    pub fn pathDelete(self: *Document, path: []const []const u8) !bool {
        if (path.len == 0) return false;
        var cur = self.root orelse return false;
        for (path[0 .. path.len - 1]) |seg| {
            cur = cur.lookup(seg) orelse return false;
        }
        return (try self.mappingRemove(cur, path[path.len - 1])) != null;
    }

    /// Mark a node's subtree as no longer byte-trustworthy, propagating
    /// to every ancestor: a container whose bytes changed must not be
    /// re-emitted verbatim from its parent slot, and the parent's parent
    /// must not re-emit *it* verbatim, and so on. Unmodified siblings
    /// stay verbatim regardless (the emitter walks per slot).
    pub fn markModified(self: *Document, node: *Node) !void {
        var cur: ?*Node = node;
        // Bounded. `mappingAppend`/`sequenceAppend` refuse to build a
        // parent cycle, so the chain is acyclic and this never trips —
        // but an unbounded walk up `parent` turns any future mistake
        // into a silent hang at 100% CPU rather than a visible failure,
        // and a hang is worse than a crash: nothing to catch, nothing
        // in the logs.
        var guard: usize = 0;
        while (cur) |n| : (guard += 1) {
            if (guard >= Node.max_parent_walk) {
                std.debug.assert(false); // parent cycle: attach guards were bypassed
                return;
            }
            if (!n.modified) {
                try internal.recordModified(self, n);
                n.modified = true;
            }
            cur = n.parent;
        }
    }

    /// Why attaching `child` under `parent` must be refused, or null
    /// when it is safe. `child` being `parent` itself or one of its
    /// ancestors is a parent cycle. An ancestor chain longer than the
    /// walk bound is reported as `NestingTooDeep` rather than a cycle:
    /// `markModified` asserts past the same bound, so attaching there
    /// would build a tree the rest of the module cannot maintain. The
    /// chain is acyclic by induction — this is the check that keeps it so
    /// — hence the plain walk.
    fn attachRefusal(parent: *Node, child: *Node) ?error{ WouldCycle, NestingTooDeep } {
        var cur: ?*Node = parent;
        var guard: usize = 0;
        while (cur) |n| : (guard += 1) {
            if (n == child) return error.WouldCycle;
            if (guard >= Node.max_parent_walk) return error.NestingTooDeep;
            cur = n.parent;
        }
        return null;
    }

    /// The `dropped` tombstone list of a collection node (source ranges
    /// of removed entries that verbatim emission must skip).
    pub fn droppedOf(node: *const Node) []const [2]usize {
        return switch (node.data) {
            .mapping => |m| m.dropped.items,
            .sequence => |s| s.dropped.items,
            else => &.{},
        };
    }

    /// Compute the round-trip region once the tree is complete.
    /// `doc_end` is the byte offset of the `...` token when the document
    /// ended explicitly (otherwise ignored). The tail runs to the end of
    /// the content's line (implicit end) or of the `...` line.
    fn finishRegion(self: *Document, doc_end: usize) void {
        const src = self.source orelse return;
        const root = self.root orelse return;
        const rs = root.src orelse return;
        self.body_start = rs.entry_start;
        self.body_end = rs.end;
        // The implicit region ends where the root's last LINE ends: a
        // trailing comment on the root's own line is this document's
        // tail, not the next document's leading bytes. (Found by the
        // comment API: `parse` never reaches the stream-end event that
        // used to paper over this by handing those bytes to the next
        // document's head, so `parse` + `write` dropped a root trailing
        // comment.)
        var end = rs.end;
        if (self.explicit_end) {
            end = markup.lineEnd(src, doc_end);
        } else if (end < src.len) {
            if (rs.synthetic) {
                // A synthesized empty scalar's span is a point borrowed
                // from the next token; extending to its line end would
                // swallow the next document's bytes (corpus 6XDY). The
                // terminator itself is still structural.
                if (src[end] == '\r' and end + 1 < src.len and src[end + 1] == '\n') {
                    end += 2;
                } else if (src[end] == '\n') {
                    end += 1;
                }
            } else {
                end = clampToMarker(src, end, markup.lineEnd(src, end));
            }
        }
        self.region_end = @max(end, self.body_start);
    }

    /// True when the line starting at `ls` is a document marker line:
    /// `---` or `...` at column 0, followed by a break, a blank, or the
    /// end of input.
    fn isMarkerLine(src: []const u8, ls: usize) bool {
        if (ls + 3 > src.len) return false;
        const t = src[ls .. ls + 3];
        if (!std.mem.eql(u8, t, "---") and !std.mem.eql(u8, t, "...")) return false;
        if (ls + 3 == src.len) return true;
        return switch (src[ls + 3]) {
            '\n', '\r', ' ', '\t' => true,
            else => false,
        };
    }

    /// Clamp an implicit region end so it cannot reach into a line that
    /// opens or closes another document.
    ///
    /// The root's `end` can already sit on the next line when its last
    /// descendant is a synthesized empty scalar, whose span is a point
    /// borrowed from the following token — `-\n---\n` is the six-byte
    /// case. Running `lineEnd` from there swallows the `---`, and then
    /// emission writes it twice: once verbatim as this document's tail,
    /// once as the next document's marker. Every round trip grew the
    /// text by four bytes, without bound.
    ///
    /// The `rs.synthetic` branch above guards the same hazard for a
    /// synthetic ROOT (corpus 6XDY); this covers a real root whose last
    /// child is synthetic, which that check cannot see.
    fn clampToMarker(src: []const u8, from: usize, end: usize) usize {
        // Start at `from`'s own line when `from` sits exactly on a line
        // start (the borrowed-point case), otherwise at the next line.
        var ls = markup.lineStart(src, from);
        if (ls < from) ls = markup.lineEnd(src, from);
        while (ls < end) {
            if (isMarkerLine(src, ls)) return ls;
            const next = markup.lineEnd(src, ls);
            if (next <= ls) break;
            ls = next;
        }
        return end;
    }

    /// Render the document back to YAML text (see emitter.zig).
    ///
    /// Documents produced by `parse`/`parseAll` re-emit their original
    /// bytes verbatim (comments, blank lines, quoting, key order and
    /// indentation included) unless a node was modified after parsing;
    /// modified subtrees are re-emitted normalized in place.
    pub fn write(self: *const Document, allocator: std.mem.Allocator) ![]u8 {
        return self.writeOpts(allocator, .{});
    }

    /// `write` with explicit layout choices for the parts the emitter
    /// lays out itself. See `EmitOptions`.
    pub fn writeOpts(self: *const Document, allocator: std.mem.Allocator, options: EmitOptions) ![]u8 {
        const emitter_mod = @import("emitter.zig");
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var em = emitter_mod.Emitter.init(allocator, &out);
        defer em.deinit();
        em.configure(options);
        try em.emitDocument(self);
        return try out.toOwnedSlice(allocator);
    }
};

/// Serialize a whole stream: every document, in order, into one buffer.
///
/// The counterpart to `parseAll`. `writeAll(parseAll(input))` reproduces
/// `input` byte for byte, because each document keeps its own source
/// region and the regions are contiguous across the stream.
///
/// Concatenating `doc.write()` yourself is *not* the same thing, and the
/// difference is a silent corruption rather than an error: two documents
/// that carry no document-start marker between them — two separately
/// parsed single-document strings, or two documents built by hand —
/// concatenate into one document, and two mappings become one mapping
/// with duplicate keys. This inserts `---` wherever a boundary is
/// required and absent, and inserts nothing where one is already there,
/// which is why the round trip stays byte-exact.
///
/// Each document is emitted by its own `Emitter`, so anchors are scoped
/// per document as YAML requires.
pub fn writeAll(allocator: std.mem.Allocator, docs: []const Document) ![]u8 {
    return writeAllOpts(allocator, docs, .{});
}

/// `writeAll` with explicit layout choices. See `EmitOptions`.
pub fn writeAllOpts(allocator: std.mem.Allocator, docs: []const Document, options: EmitOptions) ![]u8 {
    const emitter_mod = @import("emitter.zig");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (docs, 0..) |*doc, i| {
        const body_start = out.items.len;
        var em = emitter_mod.Emitter.init(allocator, &out);
        defer em.deinit();
        em.configure(options);
        try em.emitDocument(doc);

        if (i == 0) continue;
        if (endsStream(out.items[0..body_start])) continue;
        if (startsDocument(out.items[body_start..])) continue;

        // No boundary either side: supply one. Nothing is inserted on
        // the path above, which is what keeps a parsed stream byte-exact
        // -- including the case that motivated this shape, where a
        // document's region ends mid-line (`--- foo`) and its own
        // trailing comment belongs to the *next* document's leading
        // bytes. Inserting a newline there unconditionally would cut
        // that line in half.
        const sep = if (body_start > 0 and out.items[body_start - 1] != '\n') "\n---\n" else "---\n";
        try out.insertSlice(allocator, body_start, sep);
    }

    return try out.toOwnedSlice(allocator);
}

/// True when `text` opens a new document — its first line that is not
/// blank, a comment or a directive is a `---` marker. Directives imply
/// one, since a directive can only precede a document start.
/// Iterate lines on any YAML line break — `\n`, `\r\n`, or a lone `\r`
/// (§5.4 `b-break ::= CRLF | CR | LF`) — yielding each line without its
/// terminator. Splitting on `\n` alone left a wholly CR-terminated
/// document as a single "line", so `---\r-` did not read as a marker
/// and `writeAll` injected a second one.
const LineIter = struct {
    src: []const u8,
    i: usize = 0,

    fn next(self: *LineIter) ?[]const u8 {
        if (self.i >= self.src.len) return null;
        const start = self.i;
        while (self.i < self.src.len) : (self.i += 1) {
            switch (self.src[self.i]) {
                '\n' => {
                    const line = self.src[start..self.i];
                    self.i += 1;
                    return line;
                },
                '\r' => {
                    const line = self.src[start..self.i];
                    self.i += if (self.i + 1 < self.src.len and self.src[self.i + 1] == '\n') 2 else 1;
                    return line;
                },
                else => {},
            }
        }
        return self.src[start..];
    }
};

fn startsDocument(text: []const u8) bool {
    var it: LineIter = .{ .src = text };
    while (it.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        if (trimmed[0] == '%') return true;
        return std.mem.startsWith(u8, line, "---") and
            (line.len == 3 or line[3] == ' ' or line[3] == '\t');
    }
    return false;
}

/// True when `text` is nothing but blank and comment lines: the tail a
/// document may own after its content. A directive line is not one; it
/// opens the next document.
fn isTrailer(text: []const u8) bool {
    var it: LineIter = .{ .src = text };
    while (it.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (trimmed[0] != '#') return false;
    }
    return true;
}

/// True when `text` ends with an explicit `...` end-of-document marker,
/// which is itself a boundary: the next document needs no `---`.
fn endsStream(text: []const u8) bool {
    var it: LineIter = .{ .src = text };
    var last: []const u8 = "";
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        last = line;
    }
    return std.mem.startsWith(u8, last, "...") and
        (last.len == 3 or last[3] == ' ' or last[3] == '\t');
}

/// Builds a node tree out of parser events (fy_docbuilder). While
/// building, every node records its source span (see `markup.Src`) so
/// untouched regions re-emit byte-identically.
const Builder = struct {
    doc: *Document,
    source: []const u8,
    stack: std.ArrayList(Frame),
    anchors: std.StringHashMap(*Node),

    const Frame = struct {
        node: *Node,
        pending_key: ?*Node = null,
    };

    fn init(doc: *Document) Builder {
        return .{
            .doc = doc,
            .source = doc.source orelse "",
            .stack = .empty,
            .anchors = std.StringHashMap(*Node).init(doc.allocator),
        };
    }

    fn deinit(self: *Builder) void {
        self.stack.deinit(self.doc.allocator);
        self.anchors.deinit();
    }

    fn finish(self: *Builder) void {
        self.deinit();
    }

    /// Presentation span for an event: byte offsets into the document
    /// source, with the entry indicator (`-`/`?`) walked backwards.
    fn spanOf(self: *Builder, ev: Event) markup.Src {
        const synthetic = switch (ev.data) {
            .scalar => |s| s.synthetic,
            else => false,
        };
        var end = ev.end.offset;
        // The scanner's scalar end marks swallow trailing blanks (and,
        // for block scalars, the final line break). Those bytes are
        // structure, not content: trim them off the span so the gap
        // bytes carry them instead. Quoted scalars end at the closing
        // quote and are unaffected.
        if (ev.data == .scalar and !synthetic) {
            const src = self.source;
            while (end > ev.start.offset and end <= src.len and
                (src[end - 1] == ' ' or src[end - 1] == '\t' or
                    src[end - 1] == '\r' or src[end - 1] == '\n')) end -= 1;
            // A scalar that is only properties (`a: &anchor`, `- !!str`)
            // ends at the next token, so trimming blanks stops inside
            // any comment in between: `&anchor\n# c` took the next
            // entry's comment, and a trailing `# t` was not read as one.
            const sc = ev.data.scalar;
            if (sc.value.len == 0 and sc.style == .plain) {
                end = @min(end, markup.propertiesEnd(src, ev.start.offset));
            }
        }
        return .{
            .entry_start = if (synthetic)
                ev.start.offset
            else
                markup.entryStart(self.source, ev.start.offset),
            .start = ev.start.offset,
            .end = end,
            .synthetic = synthetic,
        };
    }

    fn handle(self: *Builder, ev: Event) !void {
        switch (ev.data) {
            .scalar => {
                const n = try self.doc.pool.create(Node);
                n.* = .{
                    .mark = ev.start,
                    .anchor = try self.dupeOptional(ev.data.scalar.anchor),
                    .tag = try self.dupeOptional(ev.data.scalar.tag),
                    .src = self.spanOf(ev),
                    .data = .{ .scalar = .{
                        .value = try self.doc.pool.dupe(ev.data.scalar.value),
                        .style = ev.data.scalar.style,
                    } },
                };
                try self.registerAnchor(n.anchor, n);
                try self.attach(n);
            },
            .alias => {
                const target = self.anchors.get(ev.data.alias) orelse
                    return error.UnknownAlias;
                const n = try self.doc.pool.create(Node);
                n.* = .{
                    .mark = ev.start,
                    .src = self.spanOf(ev),
                    .data = .{ .alias = .{
                        .name = try self.doc.pool.dupe(ev.data.alias),
                        .target = target,
                    } },
                };
                try self.attach(n);
            },
            .sequence_start => try self.startCollection(ev, ev.data.sequence_start),
            .mapping_start => try self.startCollection(ev, ev.data.mapping_start),
            .sequence_end => {
                const frame = self.stack.pop().?;
                if (frame.node.kind() != .sequence) return error.InvalidSyntax;
                // Flow collections close with a bracket: their span ends
                // there. Block collections keep the last child's end.
                if (frame.node.data == .sequence and frame.node.data.sequence.style == .flow) {
                    if (frame.node.src) |*s| s.end = ev.end.offset;
                }
                self.finishChild(frame.node);
            },
            .mapping_end => {
                const frame = self.stack.pop().?;
                if (frame.node.kind() != .mapping) return error.InvalidSyntax;
                if (frame.node.data == .mapping and frame.node.data.mapping.style == .flow) {
                    if (frame.node.src) |*s| s.end = ev.end.offset;
                }
                self.finishChild(frame.node);
            },
            else => {},
        }
    }

    /// A collection just closed: its span end is now final. Propagate it
    /// to the slot it occupies — the enclosing pair's `src_end` (an
    /// attach-time snapshot of a collection value still pointed at its
    /// opening bracket) and the parent container's span.
    fn finishChild(self: *Builder, coll: *Node) void {
        const cs = coll.src orelse return;
        const parent = coll.parent orelse return;
        switch (parent.data) {
            .sequence => self.growSpan(parent, cs),
            .mapping => {
                for (parent.data.mapping.pairs.items) |*p| {
                    if (p.value == coll) {
                        p.src_end = cs.end;
                        self.growSpan(parent, cs);
                        return;
                    }
                }
            },
            else => {},
        }
    }

    fn startCollection(self: *Builder, ev: Event, cs: Event.CollectionStart) !void {
        const n = if (ev.data == .sequence_start)
            try self.doc.createSequence()
        else
            try self.doc.createMapping();
        n.mark = ev.start;
        n.anchor = try self.dupeOptional(cs.anchor);
        n.tag = try self.dupeOptional(cs.tag);
        n.src = self.spanOf(ev);
        switch (n.data) {
            .sequence => |*s| s.style = cs.style,
            .mapping => |*m| m.style = cs.style,
            else => unreachable,
        }
        try self.registerAnchor(n.anchor, n);
        try self.attach(n);
        try self.stack.append(self.doc.allocator, .{ .node = n });
    }

    /// Copy an optional parser-owned string into the document pool.
    fn dupeOptional(self: *Builder, s: ?[]const u8) !?[]const u8 {
        const v = s orelse return null;
        return try self.doc.pool.dupe(v);
    }

    fn registerAnchor(self: *Builder, anchor: ?[]const u8, n: *Node) !void {
        const a = anchor orelse return;
        // Re-anchoring is legal (corpus 3GZX/PW8X, libyaml semantics):
        // a second `&a` definition shadows the first for later aliases,
        // exactly like the event-level parser already treats it.
        const gop = try self.anchors.getOrPut(a);
        gop.value_ptr.* = n;
    }

    /// Attach a freshly produced node at the current position, growing
    /// the enclosing container's span to cover it.
    fn attach(self: *Builder, n: *Node) !void {
        if (self.stack.items.len == 0) {
            self.doc.root = n;
            return;
        }
        const frame = &self.stack.items[self.stack.items.len - 1];
        switch (frame.node.data) {
            .sequence => {
                try internal.attachItem(self.doc, frame.node, n);
                self.growSpan(frame.node, n.src orelse return);
            },
            .mapping => {
                if (frame.pending_key) |key| {
                    try internal.attachPair(self.doc, frame.node, key, n);
                    // A valueless pair ends at its ':'; a synthesized
                    // empty value's own span points at the next token
                    // and must not be trusted.
                    const key_end: usize = if (key.src) |ks| ks.end else key.mark.offset;
                    const pair_end: usize = if (n.src) |vs|
                        (if (vs.synthetic) markup.valueIndicatorEnd(self.source, key_end, vs.start) else vs.end)
                    else
                        key_end;
                    if (frame.node.data == .mapping) {
                        const pairs = frame.node.data.mapping.pairs.items;
                        if (pairs.len > 0) pairs[pairs.len - 1].src_end = pair_end;
                    }
                    self.growSpan(frame.node, .{ .entry_start = 0, .start = 0, .end = pair_end });
                    frame.pending_key = null;
                } else {
                    frame.pending_key = n;
                }
            },
            .scalar, .alias => return error.InvalidSyntax,
        }
    }

    fn growSpan(self: *Builder, parent: *Node, child_span: markup.Src) void {
        _ = self;
        if (parent.src) |*ps| {
            if (child_span.end > ps.end) ps.end = child_span.end;
        }
    }
};

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

test "parse simple document" {
    var doc = try Document.parse(testing.allocator, "a: 1\nb:\n  - x\n  - y\n");
    defer doc.deinit();
    const root = doc.root.?;
    try testing.expect(root.isMapping());
    try testing.expectEqualStrings("1", root.lookup("a").?.scalarValue().?);
    const seq = root.lookup("b").?;
    try testing.expect(seq.isSequence());
    try testing.expectEqual(@as(usize, 2), seq.items().?.len);
    try testing.expectEqualStrings("y", seq.items().?[1].scalarValue().?);
}

test "alias resolves to target" {
    var doc = try Document.parse(testing.allocator, "- &v 42\n- *v\n");
    defer doc.deinit();
    const seq = doc.root.?;
    const items = seq.items().?;
    // The alias is its own node (`*v`) pointing at the anchor target.
    try testing.expect(items[0] != items[1]);
    try testing.expect(items[1].isAlias());
    try testing.expect(items[1].resolveAlias() == items[0]);
    try testing.expectEqualStrings("42", items[1].scalarValue().?);
    // Byte-faithful emission keeps the alias form.
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("- &v 42\n- *v\n", out);
}

test "unknown alias fails" {
    const r = Document.parse(testing.allocator, "- *nope\n");
    try testing.expectError(error.UnknownAlias, r);
}

test "scalar kind classification" {
    try testing.expectEqual(CoreTag.null, resolveCoreTag("~", .plain));
    try testing.expectEqual(CoreTag.null, resolveCoreTag("", .plain));
    try testing.expectEqual(CoreTag.bool, resolveCoreTag("true", .plain));
    try testing.expectEqual(CoreTag.int, resolveCoreTag("-42", .plain));
    try testing.expectEqual(CoreTag.int, resolveCoreTag("0x1F", .plain));
    try testing.expectEqual(CoreTag.float, resolveCoreTag("1.5e3", .plain));
    try testing.expectEqual(CoreTag.float, resolveCoreTag(".inf", .plain));
    try testing.expectEqual(CoreTag.str, resolveCoreTag("true", .single_quoted));
    try testing.expectEqual(CoreTag.str, resolveCoreTag("0x1F", .double_quoted));
    try testing.expectEqual(CoreTag.str, resolveCoreTag("hello", .plain));
}

test "core schema tag resolution rejects near-miss int and float forms" {
    // Spec 10.3.2. Every lexeme here resolves to str: the hex and octal
    // int forms take no sign and are lowercase only, and the float
    // production allows one dot, before one exponent, whose digits are
    // required. Nothing in the pinned corpus exercises this table, so it
    // is the only thing standing between these and a silent regression.
    const str_cases = [_][]const u8{
        "+0x1F", "-0x1F",   "0X1F", "0O7",     "+0o7",
        "1.2.3", "1.2.3.4", "1..2", "1.2e3.4", "1e",
        "1e+",   ".",       "+",    "-",
    };
    for (str_cases) |c| {
        testing.expectEqual(CoreTag.str, resolveCoreTag(c, .plain)) catch |err| {
            std.debug.print("expected str for \"{s}\", got {s}\n", .{ c, @tagName(resolveCoreTag(c, .plain)) });
            return err;
        };
    }

    // The forms the spec does accept must keep resolving.
    try testing.expectEqual(CoreTag.int, resolveCoreTag("0x1F", .plain));
    try testing.expectEqual(CoreTag.int, resolveCoreTag("0o7", .plain));
    try testing.expectEqual(CoreTag.int, resolveCoreTag("-42", .plain));
    try testing.expectEqual(CoreTag.int, resolveCoreTag("+42", .plain));
    try testing.expectEqual(CoreTag.float, resolveCoreTag("1.5e3", .plain));
    try testing.expectEqual(CoreTag.float, resolveCoreTag("-1.5E-3", .plain));
    try testing.expectEqual(CoreTag.float, resolveCoreTag(".5", .plain));
    try testing.expectEqual(CoreTag.float, resolveCoreTag("1.", .plain));
    try testing.expectEqual(CoreTag.float, resolveCoreTag(".inf", .plain));
    try testing.expectEqual(CoreTag.float, resolveCoreTag("-.INF", .plain));
    try testing.expectEqual(CoreTag.float, resolveCoreTag(".nan", .plain));
}

test "builder API and path API" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();

    const root = try doc.createMapping();
    doc.root = root;
    try doc.pathSet(&.{ "server", "host" }, try doc.createScalar("localhost", .plain));
    try doc.pathSet(&.{ "server", "port" }, try doc.createScalar("8080", .plain));
    try doc.pathSet(&.{"debug"}, try doc.createScalar("true", .plain));

    try testing.expectEqualStrings("localhost", doc.pathGet(&.{ "server", "host" }).?.scalarValue().?);
    try testing.expectEqualStrings("8080", doc.pathGet(&.{ "server", "port" }).?.scalarValue().?);

    // Replace in place keeps insertion order.
    try doc.pathSet(&.{ "server", "host" }, try doc.createScalar("example.org", .plain));
    const server = doc.root.?.lookup("server").?;
    try testing.expectEqualStrings("example.org", server.pairs().?[0].value.scalarValue().?);

    try testing.expect(try doc.pathDelete(&.{"debug"}));
    try testing.expect(doc.pathGet(&.{"debug"}) == null);
    try testing.expect(!(try doc.pathDelete(&.{"debug"})));
}

test "sequence mutation" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    const seq = try doc.createSequence();
    doc.root = seq;
    try doc.sequenceAppend(seq, try doc.createScalar("a", .plain));
    try doc.sequenceAppend(seq, try doc.createScalar("c", .plain));
    try doc.sequenceInsert(seq, 1, try doc.createScalar("b", .plain));
    try testing.expectEqualStrings("a", seq.items().?[0].scalarValue().?);
    try testing.expectEqualStrings("b", seq.items().?[1].scalarValue().?);
    try testing.expectEqualStrings("c", seq.items().?[2].scalarValue().?);
    _ = try doc.sequenceRemove(seq, 1);
    try testing.expectEqual(@as(usize, 2), seq.items().?.len);
}

// ----------------------------------------------------------------------
// Round-trip editing tests: targeted edits keep untouched
// bytes — comments, blank lines, quoting, key order, indentation.
// ----------------------------------------------------------------------

test "edit one value keeps sibling bytes verbatim" {
    const src =
        \\# service configuration
        \\name: api
        \\port: 8080   # user facing
        \\
        \\# debug section
        \\debug: false
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try doc.pathSet(&.{"port"}, try doc.createScalar("9090", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\# service configuration
        \\name: api
        \\port: 9090   # user facing
        \\
        \\# debug section
        \\debug: false
        \\
    , out);
}

test "deep edit preserves outer formatting" {
    const src =
        \\server:
        \\  # the main host
        \\  host: localhost
        \\  ports:
        \\    - 80
        \\    - 443
        \\tls: true
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try doc.pathSet(&.{ "server", "host" }, try doc.createScalar("example.org", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\server:
        \\  # the main host
        \\  host: example.org
        \\  ports:
        \\    - 80
        \\    - 443
        \\tls: true
        \\
    , out);
}

test "delete entry removes its line but keeps neighbors" {
    const src =
        \\keep-a: 1
        \\drop-me: 2 # gone
        \\keep-b: 3
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try testing.expect(try doc.pathDelete(&.{"drop-me"}));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("keep-a: 1\nkeep-b: 3\n", out);
}

test "append entry at end of mapping" {
    const src = "a: 1\nb: 2\n";
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    const root = doc.root.?;
    try doc.mappingAppend(root, try doc.createScalar("c", .plain), try doc.createScalar("3", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: 1\nb: 2\nc: 3\n", out);
}

test "a BOM before a leading comment line still parses" {
    // The '#' is at line start, but the byte before it is the BOM's
    // last byte: the comment check used to look only at that byte and
    // rejected the document. Found by the preservation gate's BOM
    // fixture variants.
    const src = "\xEF\xBB\xBF# comment\nkey: value\n";
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try testing.expectEqualStrings("value", doc.pathGet(&.{"key"}).?.scalarValue().?);
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "append entry uses sibling indentation" {
    const src =
        \\top:
        \\    deep:
        \\        one: 1
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    const deep = doc.pathGet(&.{ "top", "deep" }).?;
    try doc.mappingAppend(deep, try doc.createScalar("two", .plain), try doc.createScalar("2", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\top:
        \\    deep:
        \\        one: 1
        \\        two: 2
        \\
    , out);
}

test "sequence append keeps items verbatim" {
    const src =
        \\items:
        \\  - first  # keep
        \\  - second
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    const items = doc.pathGet(&.{"items"}).?;
    try doc.sequenceAppend(items, try doc.createScalar("third", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\items:
        \\  - first  # keep
        \\  - second
        \\  - third
        \\
    , out);
}

test "sequence remove drops the item line" {
    const src =
        \\items:
        \\  - first
        \\  - second
        \\  - third
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    const items = doc.pathGet(&.{"items"}).?;
    _ = try doc.sequenceRemove(items, 1);
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("items:\n  - first\n  - third\n", out);
}

test "replace value whose key carries a trailing comment" {
    const src =
        \\a:
        \\  b: 1 # answer
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try doc.pathSet(&.{ "a", "b" }, try doc.createScalar("42", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a:\n  b: 42 # answer\n", out);
}

test "edit in one document of a stream leaves the others verbatim" {
    const src =
        \\---
        \\first: 1
        \\---
        \\second: 2
        \\---
        \\third: 3
        \\
    ;
    var docs = try Document.parseAll(testing.allocator, src);
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 3), docs.items.len);
    try docs.items[1].pathSet(&.{"second"}, try docs.items[1].createScalar("TWO", .plain));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    for (docs.items) |*d| {
        const t = try d.write(testing.allocator);
        defer testing.allocator.free(t);
        try out.appendSlice(testing.allocator, t);
    }
    try testing.expectEqualStrings(
        \\---
        \\first: 1
        \\---
        \\second: TWO
        \\---
        \\third: 3
        \\
    , out.items);
}

test "replace block scalar value in place" {
    const src =
        \\# script
        \\run: |
        \\  echo one
        \\  echo two
        \\after: true
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try doc.pathSet(&.{"run"}, try doc.createScalar("echo three", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\# script
        \\run: echo three
        \\after: true
        \\
    , out);
}

test "allocation failures in edit+write leak nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, editWrite, .{});
}

fn editWrite(allocator: std.mem.Allocator) !void {
    var doc = try Document.parse(allocator, "a: 1\nb:\n  - x  # keep\n  - y\n");
    defer doc.deinit();
    try doc.pathSet(&.{"a"}, try doc.createScalar("2", .plain));
    const items = doc.pathGet(&.{"b"}).?;
    try doc.sequenceAppend(items, try doc.createScalar("z", .plain));
    const out = try doc.write(allocator);
    defer allocator.free(out);
}

test "parse keeps the document's tail: trailing comments and blank lines round-trip" {
    // `parse` stops after the first document and used to skip the
    // stream_end bookkeeping that hands the last document its tail, so
    // `a: 1\n# c\n` came back as `a: 1\n` — through the single-document
    // API only; `writeAll(parseAll(x))` was already exact.
    const kept = [_][]const u8{
        "a: 1\n# c\n",
        "a: 1\n\n\n",
        "a: 1\n\n# c\n\n",
        "a: 1 # t\n\n",
        "a: 1\r\n\r\n",
        "a: 1\r\r# c\r",
        "- 1\n\n",
        "a:\n  b: 1\n\n",
        "a: 1\n...\n\n# after the end marker\n",
        "x\n\n",
    };
    for (kept) |input| {
        var doc = try Document.parse(std.testing.allocator, input);
        defer doc.deinit();
        const out = try doc.write(std.testing.allocator);
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(input, out);
    }
    // Whatever follows the first document is not its tail: a `---`, a
    // directive, or a bare document after `...` all stay out.
    const clamped = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "a: 1\n---\nb: 2\n\n", .out = "a: 1\n" },
        .{ .in = "a: 1\n# c\n%YAML 1.2\n---\nb: 2\n", .out = "a: 1\n" },
        .{ .in = "a: 1\n...\nb: 2\n\n", .out = "a: 1\n...\n" },
    };
    for (clamped) |c| {
        var doc = try Document.parse(std.testing.allocator, c.in);
        defer doc.deinit();
        const out = try doc.write(std.testing.allocator);
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(c.out, out);
    }
}

test "writeAll reproduces a parsed stream byte for byte" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        "a: 1\n---\nb: 2\n",
        "---\nfirst: doc\n---\nsecond: doc\n",
        "a: 1\n...\n---\nb: 2\n",
        "# leading\n---\none\n--- two\n",
        "%YAML 1.2\n---\na\n...\n",
        "just: one\n",
        // Corpus L383. Document 1's region ends mid-line at `--- foo`,
        // and its own trailing comment is carried in document 2's
        // leading bytes. Anything that "helpfully" terminates a document
        // before the next one cuts that line in half; caught by the
        // corpus gate, pinned here so it does not need the corpus.
        "--- foo  # comment\n--- foo  # comment\n",
    };
    for (cases) |input| {
        var docs = try Document.parseAll(allocator, input);
        defer {
            for (docs.items) |*d| d.deinit();
            docs.deinit(allocator);
        }
        const out = try writeAll(allocator, docs.items);
        defer allocator.free(out);
        try testing.expectEqualStrings(input, out);
    }
}

test "parseAll holds one copy of the stream, however many documents it has" {
    // Every document used to duplicate the WHOLE stream into its own
    // arena, so memory was documents x stream: doubling the input
    // quadrupled it, and 1 MiB of nine-byte documents wanted ~114 GiB
    // (a 32 KiB stream measured 180 MB). Growth is linear in the input
    // now. Measured as live bytes with a counting allocator, so the test
    // needs no large allocation of its own and catches the regression at
    // a size where the old code was already 16x apart.
    const allocator = std.testing.allocator;
    var live: [2]usize = undefined;
    const doc_counts = [_]usize{ 400, 1600 };
    for (doc_counts, 0..) |count, i| {
        var stream: std.ArrayList(u8) = .empty;
        defer stream.deinit(allocator);
        for (0..count) |_| try stream.appendSlice(allocator, "---\na: 1\n");

        var counting = std.testing.FailingAllocator.init(allocator, .{});
        const counted = counting.allocator();
        var docs = try Document.parseAll(counted, stream.items);
        defer docs.deinit(counted);
        try testing.expectEqual(count, docs.items.len);
        live[i] = counting.allocated_bytes - counting.freed_bytes;
        for (docs.items) |*d| d.deinit();
    }
    // 4x the documents: linear growth is ~4x, the per-document copy was
    // ~16x. The slack absorbs allocator and arena rounding.
    try testing.expect(live[1] < live[0] * 6);
}

test "documents of one stream stay valid in any order of release" {
    // The shared copy of the stream is reference-counted, so a document
    // must keep working after any of its siblings is gone, and the copy
    // must be freed exactly once (the testing allocator reports both a
    // leak and a double free).
    const allocator = std.testing.allocator;
    const input = "---\na: 1 # one\n---\nb: 2 # two\n---\nc: 3 # three\n";
    var docs = try Document.parseAll(allocator, input);
    defer docs.deinit(allocator);
    try testing.expectEqual(@as(usize, 3), docs.items.len);

    // Release the first and last; the middle one is the survivor.
    docs.items[0].deinit();
    docs.items[2].deinit();
    const out = try docs.items[1].write(allocator);
    defer allocator.free(out);
    try testing.expectEqualStrings("---\nb: 2 # two\n", out);
    try testing.expectEqualStrings("2", docs.items[1].pathGet(&.{"b"}).?.scalarValue().?);
    docs.items[1].deinit();
}

test "a stream that fails after its first document releases the shared copy" {
    // The failure path frees the finished documents and the one in
    // flight; the copy they share must go with the last of them.
    const allocator = std.testing.allocator;
    try testing.expectError(error.InvalidSyntax, Document.parseAll(allocator, "a: 1\n---\nb: [\n"));
    try testing.expectError(error.InvalidSyntax, Document.parseAll(allocator, "---\na: 1\n---\nb: 2\n---\nc: {\n"));
}

test "writeAll separates documents that would otherwise merge" {
    const allocator = std.testing.allocator;

    // Two separately parsed single-document strings. Each re-emits as
    // its own bytes with no marker, so plain concatenation yields one
    // mapping with two keys -- valid YAML, wrong data, no error.
    var first = try Document.parse(allocator, "a: 1\n");
    defer first.deinit();
    var second = try Document.parse(allocator, "b: 2\n");
    defer second.deinit();

    const naive = blk: {
        const x = try first.write(allocator);
        defer allocator.free(x);
        const y = try second.write(allocator);
        defer allocator.free(y);
        break :blk try std.mem.concat(allocator, u8, &.{ x, y });
    };
    defer allocator.free(naive);
    {
        var merged = try Document.parseAll(allocator, naive);
        defer {
            for (merged.items) |*d| d.deinit();
            merged.deinit(allocator);
        }
        // The corruption this guards against, pinned so the test fails
        // if it ever stops being a corruption.
        try testing.expectEqual(@as(usize, 1), merged.items.len);
    }

    const out = try writeAll(allocator, &.{ first, second });
    defer allocator.free(out);
    try testing.expectEqualStrings("a: 1\n---\nb: 2\n", out);

    var back = try Document.parseAll(allocator, out);
    defer {
        for (back.items) |*d| d.deinit();
        back.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 2), back.items.len);
    try testing.expectEqualStrings("1", back.items[0].pathGet(&.{"a"}).?.scalarValue().?);
    try testing.expectEqualStrings("2", back.items[1].pathGet(&.{"b"}).?.scalarValue().?);
}

test "writeAll separates hand-built documents" {
    const allocator = std.testing.allocator;
    var one = Document.init(allocator);
    defer one.deinit();
    one.root = try one.createMapping();
    try one.pathSet(&.{"a"}, try one.createScalar("1", .plain));

    var two = Document.init(allocator);
    defer two.deinit();
    two.root = try two.createMapping();
    try two.pathSet(&.{"b"}, try two.createScalar("2", .plain));

    const out = try writeAll(allocator, &.{ one, two });
    defer allocator.free(out);

    var back = try Document.parseAll(allocator, out);
    defer {
        for (back.items) |*d| d.deinit();
        back.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 2), back.items.len);

    // A document that asks for its own marker does not get a second one.
    try testing.expect(std.mem.indexOf(u8, out, "------") == null);
    two.explicit_start = true;
    const again = try writeAll(allocator, &.{ one, two });
    defer allocator.free(again);
    try testing.expectEqualStrings(out, again);
}

test "emit options set the indent for content the emitter lays out" {
    const allocator = std.testing.allocator;

    // A document built from nothing has no convention to measure, so
    // before this its indent was simply 2, with no way to say otherwise.
    var doc = Document.init(allocator);
    defer doc.deinit();
    doc.root = try doc.createMapping();
    const inner = try doc.createMapping();
    try doc.mappingAppend(doc.root.?, try doc.createScalar("outer", .plain), inner);
    try doc.mappingAppend(inner, try doc.createScalar("key", .plain), try doc.createScalar("v", .plain));

    const two = try doc.write(allocator);
    defer allocator.free(two);
    try testing.expectEqualStrings("outer:\n  key: v\n", two);

    const four = try doc.writeOpts(allocator, .{ .indent = 4 });
    defer allocator.free(four);
    try testing.expectEqualStrings("outer:\n    key: v\n", four);

    // Clamped rather than trusted: 0 would emit unparseable YAML.
    const clamped = try doc.writeOpts(allocator, .{ .indent = 0 });
    defer allocator.free(clamped);
    try testing.expectEqualStrings("outer:\n key: v\n", clamped);
}

test "emit options cannot disturb bytes that re-emit verbatim" {
    const allocator = std.testing.allocator;
    // The guarantee has priority over the preference: untouched source
    // bytes are copied, so an indent request cannot reach them.
    const src = "outer:\n      key: v\n      other: w\n";
    var doc = try Document.parse(allocator, src);
    defer doc.deinit();
    const out = try doc.writeOpts(allocator, .{ .indent = 2 });
    defer allocator.free(out);
    try testing.expectEqualStrings(src, out);

    // It does reach a new subtree, which has no source bytes of its own.
    var edited = try Document.parse(allocator, src);
    defer edited.deinit();
    const added = try edited.createMapping();
    try edited.mappingAppend(added, try edited.createScalar("n", .plain), try edited.createScalar("1", .plain));
    try edited.pathSet(&.{"fresh"}, added);
    const with_new = try edited.writeOpts(allocator, .{ .indent = 3 });
    defer allocator.free(with_new);
    try testing.expect(std.mem.indexOf(u8, with_new, "fresh:\n   n: 1") != null);
    // ... and the original lines are still exactly as they were.
    try testing.expect(std.mem.indexOf(u8, with_new, "outer:\n      key: v\n      other: w\n") != null);
}

test "emit options carry the depth bound" {
    const allocator = std.testing.allocator;
    var doc = Document.init(allocator);
    defer doc.deinit();
    const root = try doc.createSequence();
    doc.root = root;
    var cur = root;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const next = try doc.createSequence();
        try doc.sequenceAppend(cur, next);
        cur = next;
    }
    try doc.sequenceAppend(cur, try doc.createScalar("leaf", .plain));

    // Well under the default, so this is the bound doing the work.
    try testing.expectError(error.NestingTooDeep, doc.writeOpts(allocator, .{ .max_depth = 8 }));
    const ok = try doc.writeOpts(allocator, .{ .max_depth = 500 });
    defer allocator.free(ok);
    try testing.expect(std.mem.indexOf(u8, ok, "leaf") != null);
}

// ----------------------------------------------------------------------
// Comments: reads and writes (docs/design/comments.md, PLAN-12 B2).
// ----------------------------------------------------------------------

const comment_src =
    \\# service configuration
    \\name: api   # user facing
    \\# stale, replaced below
    \\port: 8080
    \\
    \\# separated from port by a blank line
    \\debug: false
    \\
;

test "comment reads: trailing and leading, raw" {
    var doc = try Document.parse(testing.allocator, comment_src);
    defer doc.deinit();
    const root = doc.root.?;

    // Trailing: raw, from the '#' to before the terminator.
    try testing.expectEqualStrings("# user facing", root.lookup("name").?.trailingComment(&doc).?);
    try testing.expect(root.lookup("port").?.trailingComment(&doc) == null);

    // Leading, read off the (inline) value standing in for the pair: the
    // block directly above. A blank line breaks the attachment.
    try testing.expectEqualStrings("# service configuration", root.lookup("name").?.leadingComments(&doc).?);
    try testing.expectEqualStrings("# stale, replaced below", root.lookup("port").?.leadingComments(&doc).?);
    try testing.expectEqualStrings("# separated from port by a blank line", root.lookup("debug").?.leadingComments(&doc).?);

    // The key reads the same block as its inline value.
    const pairs = root.pairs().?;
    try testing.expectEqualStrings("# service configuration", pairs[0].key.leadingComments(&doc).?);

    // A programmatically built node has no source bytes to read.
    var built = Document.init(testing.allocator);
    defer built.deinit();
    const n = try built.createScalar("x", .plain);
    try testing.expect(n.trailingComment(&built) == null);
    try testing.expect(n.leadingComments(&built) == null);
}

test "comment reads on containers, aliases and block values" {
    const src =
        \\top:
        \\  # about the sequence
        \\  - one   # first
        \\  - &v two
        \\  - *v
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    const top = doc.pathGet(&.{"top"}).?;

    // The block value's own comments are the ones above its first line.
    try testing.expectEqualStrings("# about the sequence", top.leadingComments(&doc).?);
    // A mid-sequence comment is its item's trailing comment.
    try testing.expectEqualStrings("# first", top.items().?[0].trailingComment(&doc).?);
    try testing.expect(top.trailingComment(&doc) == null);
    // Alias occurrences read their own spans.
    try testing.expect(top.items().?[2].trailingComment(&doc) == null);
}

test "comment write: set, change, delete a trailing comment" {
    var doc = try Document.parse(testing.allocator, comment_src);
    defer doc.deinit();
    const port = doc.pathGet(&.{"port"}).?;

    // Add where there was none.
    try doc.setTrailingComment(port, "# the door");
    {
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(
            "# service configuration\nname: api   # user facing\n# stale, replaced below\nport: 8080 # the door\n\n# separated from port by a blank line\ndebug: false\n",
            out,
        );
        // Reads see the written comment without a re-parse.
        try testing.expectEqualStrings("# the door", port.trailingComment(&doc).?);
    }

    // Change: canonical single blank replaces the original spacing.
    try doc.setTrailingComment(port, "# changed");
    {
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "port: 8080 # changed\n") != null);
    }

    // Delete.
    try doc.setTrailingComment(port, null);
    {
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(
            "# service configuration\nname: api   # user facing\n# stale, replaced below\nport: 8080\n\n# separated from port by a blank line\ndebug: false\n",
            out,
        );
    }
}

test "comment writes cannot smuggle structure through a lone CR" {
    const allocator = testing.allocator;

    // `validateTrailingText` rejects both `\n` and `\r`, because a
    // comment that contains a line break stops being a comment on the
    // next line. `normalizeLeadingText` split on `\n` only, so a lone
    // CR passed validation as part of one "line" that started with `#`,
    // was emitted raw, and — a lone CR being a YAML line break — came
    // back on reparse as a real mapping entry. A validation boundary
    // that lets the caller inject document structure.
    {
        var doc = try Document.parse(allocator, "a: 1\nb: 2\n");
        defer doc.deinit();
        const node = doc.pathGet(&.{"b"}).?;
        try testing.expectError(
            error.InvalidSyntax,
            doc.setLeadingComments(node, "# c\rinjected: yes"),
        );
    }

    // The trailing side already refused it; assert that it stays so.
    {
        var doc = try Document.parse(allocator, "a: 1\n");
        defer doc.deinit();
        const node = doc.pathGet(&.{"a"}).?;
        try testing.expectError(
            error.InvalidSyntax,
            doc.setTrailingComment(node, "# c\rinjected: yes"),
        );
        try testing.expectError(
            error.InvalidSyntax,
            doc.setTrailingComment(node, "# c\ninjected: yes"),
        );
    }

    // A CR inside a *multi-line* leading block is refused too, not just
    // one that happens to be the whole text.
    {
        var doc = try Document.parse(allocator, "a: 1\nb: 2\n");
        defer doc.deinit();
        const node = doc.pathGet(&.{"b"}).?;
        try testing.expectError(
            error.InvalidSyntax,
            doc.setLeadingComments(node, "# one\n# two\rinjected: yes"),
        );
    }

    // Legitimate CRLF-terminated blocks still work: the terminator is
    // stripped, not treated as smuggled structure.
    {
        var doc = try Document.parse(allocator, "a: 1\nb: 2\n");
        defer doc.deinit();
        const node = doc.pathGet(&.{"b"}).?;
        try doc.setLeadingComments(node, "# fine\r\n");
        const out = try doc.write(allocator);
        defer allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "# fine") != null);

        // And what came back is still two entries, not three.
        var again = try Document.parse(allocator, out);
        defer again.deinit();
        try testing.expectEqual(@as(usize, 2), again.root.?.pairs().?.len);
    }
}

test "comment writes refuse bytes the scanner would refuse on re-parse" {
    const allocator = testing.allocator;

    // Same boundary as the lone-CR case, different failure: text that
    // is not valid UTF-8, or carries a NUL, passed validation, was
    // emitted raw, and the written document then failed its own
    // `parse` (error.InvalidUtf8 / error.InvalidSyntax). A write the
    // library cannot read back is not a write; refuse it up front.
    // Everything else the scanner accepts in a comment — NEL, LS, PS,
    // a BOM, C0 controls, DEL — stays accepted and round-trips.
    const bad = [_]struct { text: []const u8, err: anyerror }{
        .{ .text = "# x\xFFy", .err = error.InvalidUtf8 },
        .{ .text = "# x\x85y", .err = error.InvalidUtf8 }, // latin-1 NEL, not UTF-8
        .{ .text = "# x\xC2", .err = error.InvalidUtf8 }, // truncated sequence
        .{ .text = "# x\xED\xA0\x80y", .err = error.InvalidUtf8 }, // surrogate
        .{ .text = "# x\x00y", .err = error.InvalidSyntax },
    };
    for (bad) |case| {
        var doc = try Document.parse(allocator, "a: 1\nb: 2\n");
        defer doc.deinit();
        const node = doc.pathGet(&.{"a"}).?;
        try testing.expectError(case.err, doc.setTrailingComment(node, case.text));
        try testing.expectError(case.err, doc.setLeadingComments(node, case.text));
        // A refused write leaves the document byte-identical.
        const out = try doc.write(allocator);
        defer allocator.free(out);
        try testing.expectEqualStrings("a: 1\nb: 2\n", out);
    }

    const good = [_][]const u8{
        "# x\xC2\x85y: z", // NEL
        "# x\xE2\x80\xA8y: z", // LS
        "# x\xE2\x80\xA9y: z", // PS
        "# x\xEF\xBB\xBFy", // BOM
        "# x\x01y", // C0 control
        "# x\x7Fy", // DEL
        "#", // bare indicator
        "#\t",
        "#no-space",
    };
    for (good) |text| {
        var doc = try Document.parse(allocator, "a: 1\nb: 2\n");
        defer doc.deinit();
        try doc.setTrailingComment(doc.pathGet(&.{"a"}).?, text);
        try doc.setLeadingComments(doc.pathGet(&.{"b"}).?, text);
        const out = try doc.write(allocator);
        defer allocator.free(out);
        var re = try Document.parse(allocator, out);
        defer re.deinit();
        try testing.expectEqual(@as(usize, 2), re.root.?.pairs().?.len);
        try testing.expectEqualStrings("1", re.pathGet(&.{"a"}).?.scalarValue().?);
        try testing.expectEqualStrings("2", re.pathGet(&.{"b"}).?.scalarValue().?);
        try testing.expectEqualStrings(text, re.pathGet(&.{"a"}).?.trailingComment(&re).?);
        try testing.expectEqualStrings(text, re.pathGet(&.{"b"}).?.leadingComments(&re).?);
    }
}

test "comment write: re-setting the same comment is byte-identical" {
    const src =
        \\# service configuration
        \\name: api   # user facing
        \\port: 8080 # one space here
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();

    // Same text, whatever the original spacing: a no-op, so even the
    // three blanks before the first comment survive untouched.
    try doc.setTrailingComment(doc.pathGet(&.{"name"}).?, "# user facing");
    try testing.expect(doc.pathGet(&.{"name"}).?.modified == false);
    // A different text is a real edit and marks the tree.
    try doc.setTrailingComment(doc.pathGet(&.{"name"}).?, "# renamed");
    try testing.expect(doc.pathGet(&.{"name"}).?.modified == true);

    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "# service configuration\nname: api # renamed\nport: 8080 # one space here\n",
        out,
    );
}

test "comment write: leading blocks set, change and delete whole lines" {
    var doc = try Document.parse(testing.allocator, comment_src);
    defer doc.deinit();
    const port = doc.pathGet(&.{"port"}).?;

    try doc.setLeadingComments(port, "# rate limit\n# in requests/second");
    {
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(
            "# service configuration\nname: api   # user facing\n# rate limit\n# in requests/second\nport: 8080\n\n# separated from port by a blank line\ndebug: false\n",
            out,
        );
        try testing.expectEqualStrings(
            "# rate limit\n# in requests/second",
            port.leadingComments(&doc).?,
        );
    }

    // Delete removes the lines whole; the entry below stays put.
    try doc.setLeadingComments(port, null);
    {
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(
            "# service configuration\nname: api   # user facing\nport: 8080\n\n# separated from port by a blank line\ndebug: false\n",
            out,
        );
    }
}

test "comment write: a leading comment on a framed key keeps one `- ` or `? `" {
    // The first key of a sequence item and an explicit key start their
    // entry with framing -- a `- ` or `? ` in [entry_start, start). The
    // written block re-assembled the entry's line with that framing, and
    // the key then re-emitted it from entry_start: `- k: v` came out as
    // `# lead\n- - k: v`, a nested sequence, and `? k` as `? ? k`.
    const cases = [_]struct { in: []const u8, at: []const []const u8, anchor: bool = false, out: []const u8 }{
        .{ .in = "- k: v\n  j: w\n", .at = &.{"0"}, .out = "# lead\n- k: v\n  j: w\n" },
        .{ .in = "items:\n  - k: v\n    j: w\n", .at = &.{ "items", "0" }, .out = "items:\n  # lead\n  - k: v\n    j: w\n" },
        .{ .in = "? k\n: v\n", .at = &.{}, .out = "# lead\n? k\n: v\n" },
        .{ .in = "- ? k\n  : v\n", .at = &.{"0"}, .out = "# lead\n- ? k\n  : v\n" },
        // A modified key takes the same path.
        .{ .in = "- k: v\n  j: w\n", .at = &.{"0"}, .anchor = true, .out = "# lead\n- &x k: v\n  j: w\n" },
        // Control: an unframed key.
        .{ .in = "a: 1\nk: v\n", .at = &.{}, .out = "a: 1\n# lead\nk: v\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.in);
        defer doc.deinit();
        const key = for (doc.root.?.byPath(c.at).?.pairs().?) |p| {
            if (std.mem.eql(u8, p.key.scalarValue().?, "k")) break p.key;
        } else unreachable;
        if (c.anchor) try doc.setAnchor(key, "x");
        try doc.setLeadingComments(key, "# lead");
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.out, out);

        // Read back: the same comment above the same key, value intact.
        var again = try Document.parse(testing.allocator, out);
        defer again.deinit();
        const pair = for (again.root.?.byPath(c.at).?.pairs().?) |p| {
            if (std.mem.eql(u8, p.key.scalarValue().?, "k")) break p;
        } else unreachable;
        try testing.expectEqualStrings("# lead", pair.key.leadingComments(&again).?);
        try testing.expectEqualStrings("v", pair.value.scalarValue().?);
    }
}

test "comment write: every node on an entry line shares one block" {
    // Written blocks used to go wrong wherever several nodes start on one
    // line. Each case writes `# new` through one node and checks the
    // output and that every node on the line reads it back.
    const cases = [_]struct { in: []const u8, at: []const []const u8, out: []const u8 }{
        // The root: the block was tombstoned out of the head and never
        // written, so the old comment was lost and the new one too.
        .{ .in = "# old\na: 1\nb: 2\n", .at = &.{}, .out = "# new\na: 1\nb: 2\n" },
        .{ .in = "- a\n- b\n", .at = &.{}, .out = "# new\n- a\n- b\n" },
        // A sequence item holding a mapping: the item's `- ` was written
        // twice (`- - name: x`), a nested sequence.
        .{ .in = "items:\n  - name: x\n  - name: y\n", .at = &.{ "items", "1" }, .out = "items:\n  - name: x\n  # new\n  - name: y\n" },
        // The first key of an item: its old block sat in the sequence's
        // gap but was tombstoned in the item's list, and survived.
        .{ .in = "- a: 1\n# old\n- b: 2\n", .at = &.{ "1", "b" }, .out = "- a: 1\n# new\n- b: 2\n" },
        // An inline value writes the block above its pair.
        .{ .in = "a: 1\nb: 2\n", .at = &.{"b"}, .out = "a: 1\n# new\nb: 2\n" },
        // An item whose content starts on the line after its `-`.
        .{ .in = "- x\n-\n  name: y\n", .at = &.{ "1", "name" }, .out = "- x\n# new\n-\n  name: y\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.in);
        defer doc.deinit();
        try doc.setLeadingComments(doc.root.?.byPath(c.at).?, "# new");
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.out, out);

        var again = try Document.parse(testing.allocator, out);
        defer again.deinit();
        try testing.expectEqualStrings("# new", again.root.?.byPath(c.at).?.leadingComments(&again).?);
    }
}

test "comment reads: block scalar content and property-only nodes" {
    // A `# ...` line inside a block scalar is content, not the next
    // item's comment; reading it as one also tombstoned it on a write.
    {
        var doc = try Document.parse(testing.allocator, "- >\n  text\n  # not a comment\n- b\n");
        defer doc.deinit();
        try testing.expect(doc.root.?.items().?[1].leadingComments(&doc) == null);
    }
    // A node that is only properties ended at the next token, so its
    // span took the comment lines in between: the next key read no
    // block, and a trailing comment was not read at all.
    {
        var doc = try Document.parse(testing.allocator, "a: &anchor\n# about b\nb: *anchor\nc: &x !!str # t\n");
        defer doc.deinit();
        try testing.expectEqualStrings("# about b", doc.pathGet(&.{"b"}).?.leadingComments(&doc).?);
        try testing.expectEqualStrings("# t", doc.pathGet(&.{"c"}).?.trailingComment(&doc).?);
    }
}

test "comment write: an empty node has no line of its own and is refused" {
    // Its span is a point borrowed from the next token; the write was
    // accepted and then silently dropped.
    var doc = try Document.parse(testing.allocator, "- a\n- \n- b\n");
    defer doc.deinit();
    try testing.expectError(error.InvalidSyntax, doc.setLeadingComments(doc.root.?.items().?[1], "# c"));

    // Unless it is first: then it shares the line of the collection it
    // opens, and the block is the collection's, above that line.
    var first = try Document.parse(testing.allocator, "- \n- b\n");
    defer first.deinit();
    try first.setLeadingComments(first.root.?.items().?[0], "# c");
    const out = try first.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# c\n- \n- b\n", out);
    var again = try Document.parse(testing.allocator, out);
    defer again.deinit();
    try testing.expectEqualStrings("# c", again.root.?.items().?[0].leadingComments(&again).?);
}

test "comment write: a multi-line key stays a key" {
    // A modified key re-emitted through `emitContent` came out as a
    // literal block (`|-` then its lines), which reads back as another
    // mapping.
    var doc = try Document.parse(testing.allocator, "\"a\\nb\": 1\nc: 2\n");
    defer doc.deinit();
    try doc.setLeadingComments(doc.root.?.pairs().?[0].key, "# k");
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# k\n\"a\\nb\": 1\nc: 2\n", out);
}

test "comment reads and writes: a trailing comment on an empty value" {
    // An empty value's span is a point borrowed from the next token, so
    // `push: # c` read no comment although the write put it there; an
    // empty item or document took the write and never emitted it.
    {
        var doc = try Document.parse(testing.allocator, "on:\n  push: # c\n  pull_request:\n");
        defer doc.deinit();
        try testing.expectEqualStrings("# c", doc.pathGet(&.{ "on", "push" }).?.trailingComment(&doc).?);
        const pr = doc.pathGet(&.{ "on", "pull_request" }).?;
        try doc.setTrailingComment(pr, "# new");
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("on:\n  push: # c\n  pull_request: # new\n", out);
        var again = try Document.parse(testing.allocator, out);
        defer again.deinit();
        try testing.expectEqualStrings("# new", again.pathGet(&.{ "on", "pull_request" }).?.trailingComment(&again).?);
    }
    {
        // An explicit key with no value: the comment follows the key.
        var doc = try Document.parse(testing.allocator, "? a # c\n? b\n");
        defer doc.deinit();
        try testing.expectEqualStrings("# c", doc.root.?.pairs().?[0].value.trailingComment(&doc).?);
    }
    // No bytes to hang it on: refused.
    {
        var doc = try Document.parse(testing.allocator, "- \n- b\n");
        defer doc.deinit();
        try testing.expectError(error.InvalidSyntax, doc.setTrailingComment(doc.root.?.items().?[0], "# c"));
    }
    {
        // After a block scalar key with no `:` is inside its content.
        var doc = try Document.parse(testing.allocator, "? >\n  a\n? b\n");
        defer doc.deinit();
        try testing.expectError(error.InvalidSyntax, doc.setTrailingComment(doc.root.?.pairs().?[0].value, "# c"));
    }
    {
        // Its `:` on a line of its own is the value's position.
        var doc = try Document.parse(testing.allocator, "? >\n  a\n:\n");
        defer doc.deinit();
        try doc.setTrailingComment(doc.root.?.pairs().?[0].value, "# c");
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("? >\n  a\n: # c\n", out);
        var again = try Document.parse(testing.allocator, out);
        defer again.deinit();
        try testing.expectEqualStrings("# c", again.root.?.pairs().?[0].value.trailingComment(&again).?);
    }
}

test "comment write: a comment on a brand-new entry, the motivating case" {
    var doc = try Document.parse(testing.allocator, "name: api\n");
    defer doc.deinit();
    try doc.pathSet(&.{"port"}, try doc.createScalar("8080", .plain));

    // The replacement value has no source span; its trailing comment is
    // synthesized at emission time.
    try doc.setTrailingComment(doc.pathGet(&.{"port"}).?, "# user facing");
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("name: api\nport: 8080 # user facing\n", out);

    // Comment round trip: parse(emit(doc)) reads the same comments back.
    var again = try Document.parse(testing.allocator, out);
    defer again.deinit();
    try testing.expectEqualStrings("# user facing", again.pathGet(&.{"port"}).?.trailingComment(&again).?);
}

test "comment write: sibling bytes survive a comment edit" {
    const src =
        \\# head
        \\a: 1  # keep
        \\b: 2
        \\c: [x, y]
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try doc.setLeadingComments(doc.pathGet(&.{"b"}).?, "# new\n# block");
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "# head\na: 1  # keep\n# new\n# block\nb: 2\nc: [x, y]\n",
        out,
    );
}

test "comment write: rejects what it cannot write honestly" {
    var doc = try Document.parse(testing.allocator, "a: 1 # c\nlist:\n  - x\nflow: [1, 2]\n");
    defer doc.deinit();

    // Not a comment / not one line.
    try testing.expectError(error.InvalidSyntax, doc.setTrailingComment(doc.pathGet(&.{"a"}).?, "no hash"));
    try testing.expectError(error.InvalidSyntax, doc.setTrailingComment(doc.pathGet(&.{"a"}).?, "# two\nlines"));
    // Trailing on a block collection: address its last entry instead.
    try testing.expectError(error.InvalidSyntax, doc.setTrailingComment(doc.pathGet(&.{"list"}).?, "# c"));
    // Trailing on the pair's key: the comment lives after the value.
    try testing.expectError(error.InvalidSyntax, doc.setTrailingComment(doc.root.?.pairs().?[0].key, "# c"));
    // Inside a flow collection: not addressable (design, out of scope).
    const flow_item = doc.pathGet(&.{"flow"}).?.items().?[0];
    try testing.expectError(error.InvalidSyntax, doc.setTrailingComment(flow_item, "# c"));
    try testing.expectError(error.InvalidSyntax, doc.setLeadingComments(flow_item, "# c"));
    // Leading text with a non-comment line.
    try testing.expectError(error.InvalidSyntax, doc.setLeadingComments(doc.pathGet(&.{"a"}).?, "# ok\nplain line"));
}

test "comment round trip: every written comment survives write and re-parse" {
    const src =
        \\# doc head
        \\a: 1   # tail of a
        \\b:
        \\  # about b
        \\  - x
        \\  - y  # tail of y
        \\
    ;
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try doc.setTrailingComment(doc.pathGet(&.{"a"}).?, "# new tail");
    try doc.setLeadingComments(doc.pathGet(&.{"b"}).?, "# rewritten");

    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    var again = try Document.parse(testing.allocator, out);
    defer again.deinit();
    try testing.expectEqualStrings("# new tail", again.pathGet(&.{"a"}).?.trailingComment(&again).?);
    try testing.expectEqualStrings("# rewritten", again.pathGet(&.{"b"}).?.leadingComments(&again).?);
    try testing.expectEqualStrings("# doc head", again.pathGet(&.{"a"}).?.leadingComments(&again).?);
    const items = again.pathGet(&.{"b"}).?.items().?;
    try testing.expectEqualStrings("# tail of y", items[1].trailingComment(&again).?);
}

test "comment write then edit: the block stays where it reads back" {
    // A written leading block followed by a structural edit near it: the
    // comment sweep only ever wrote, so none of these was seen. Each
    // result must parse, keep the tree, and put the block where the
    // in-memory reads said it was.
    const edit_mod = @import("edit.zig");
    const Case = struct { in: []const u8, lead: []const u8, edit: edit_mod.Edit, out: []const u8 };
    const cases = [_]Case{
        // The first entry deleted: its block belongs to the container's
        // line and stays above the new first entry. The block writer
        // put that entry's indentation back on top of the successor's
        // own, two levels deep: a different tree, or none.
        .{ .in = "items:\n  - name: x\n  - name: y\n    port: 1\n", .lead = "$.items[0]", .edit = .{ .delete = "$.items[0]" }, .out = "items:\n  # new\n  - name: y\n    port: 1\n" },
        .{ .in = "a:\n  b: 1\n  c:\n    d: 2\n", .lead = "$.a.b", .edit = .{ .delete = "$.a.b" }, .out = "a:\n  # new\n  c:\n    d: 2\n" },
        .{ .in = "k:\n  - a\n  - b\n", .lead = "$.k[0]", .edit = .{ .delete = "$.k[0]" }, .out = "k:\n  # new\n  - b\n" },
        .{ .in = "  a: 1\n  b: 2\n", .lead = "$", .edit = .{ .delete = "$.a" }, .out = "  # new\n  b: 2\n" },
        .{ .in = "a:\n  b: 1\n  c: 2\n", .lead = "$.a.b", .edit = .{ .move = .{ .from = "$.a.b", .to = "$", .key = "z" } }, .out = "a:\n  # new\n  c: 2\nz: 1\n" },
        // A later entry owns its line: deleted with it.
        .{ .in = "a:\n  x: 1\n  y: 2\n  z: 3\n", .lead = "$.a.y", .edit = .{ .delete = "$.a.y" }, .out = "a:\n  x: 1\n  z: 3\n" },
        // Emptied by the delete, the block value keeps its own line and
        // its block above `{}`.
        .{ .in = "a: 1\nv:\n  k: x\nb: 2\n", .lead = "$.v", .edit = .{ .delete = "$.v.k" }, .out = "a: 1\nv:\n  # new\n  {}\nb: 2\n" },
    };
    for (cases) |c| {
        var doc = try Document.parse(testing.allocator, c.in);
        defer doc.deinit();
        var ed = edit_mod.Editor.init(&doc);
        try doc.setLeadingComments(try ed.one(c.lead), "# new");
        try ed.apply(&.{c.edit});
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.out, out);
    }
}

test "comment write after an edit: a block goes where the tree is now" {
    const edit_mod = @import("edit.zig");
    {
        // An insert ahead of `x` gives it a line of its own again: its
        // block goes above it, not above the new first item (which the
        // source lines still said shared the sequence's line).
        var doc = try Document.parse(testing.allocator, "a: 1\nb:\n  - x\n");
        defer doc.deinit();
        var ed = edit_mod.Editor.init(&doc);
        try ed.apply(&.{.{ .insert = .{ .sequence = "$.b", .position = "$.b[0]", .value = try doc.createScalar("z", .plain), .before = true } }});
        try doc.setLeadingComments(try ed.one("$.b[1]"), "# other");
        try testing.expectEqualStrings("# other", (try ed.one("$.b[1]")).leadingComments(&doc).?);
        try testing.expect((try ed.one("$.b[0]")).leadingComments(&doc) == null);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("a: 1\nb:\n  - z\n  # other\n  - x\n", out);
    }
    {
        // A block on a new first item: the original item after it kept
        // its indentation (it was written at column 0, and did not parse).
        var doc = try Document.parse(testing.allocator, "a: 1\nb:\n  - x\n");
        defer doc.deinit();
        var ed = edit_mod.Editor.init(&doc);
        try ed.apply(&.{.{ .insert = .{ .sequence = "$.b", .position = "$.b[0]", .value = try doc.createScalar("z", .plain), .before = true } }});
        try doc.setLeadingComments(try ed.one("$.b[0]"), "# new");
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("a: 1\nb:\n  # new\n  - z\n  - x\n", out);
    }
    {
        // A block on a new item between two original ones, nested: the
        // original after it keeps its indentation.
        var doc = try Document.parse(testing.allocator, "k:\n  - a\n  - b\n");
        defer doc.deinit();
        var ed = edit_mod.Editor.init(&doc);
        try ed.apply(&.{.{ .insert = .{ .sequence = "$.k", .position = "$.k[1]", .value = try doc.createScalar("z", .plain), .before = true } }});
        try doc.setLeadingComments(try ed.one("$.k[1]"), "# new");
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("k:\n  - a\n  # new\n  - z\n  - b\n", out);
    }
    {
        // The in-memory reads follow the tree too: after the insert the
        // block on the sequence's first line is the new item's to read.
        var doc = try Document.parse(testing.allocator, "- a\n- b\n");
        defer doc.deinit();
        var ed = edit_mod.Editor.init(&doc);
        try doc.setLeadingComments(try ed.one("$[0]"), "# new");
        try ed.apply(&.{.{ .insert = .{ .sequence = "$", .position = "$[0]", .value = try doc.createScalar("z", .plain), .before = true } }});
        try testing.expectEqualStrings("# new", (try ed.one("$[0]")).leadingComments(&doc).?);
        try testing.expect((try ed.one("$[1]")).leadingComments(&doc) == null);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("# new\n- z\n- a\n- b\n", out);
    }
    {
        // A block written on an entry that later becomes first is still
        // its own, and still read.
        var doc = try Document.parse(testing.allocator, "a:\n  x: 1\n  y: 2\n");
        defer doc.deinit();
        var ed = edit_mod.Editor.init(&doc);
        try doc.setLeadingComments(try ed.one("$.a.y"), "# new");
        try ed.delete("$.a.x");
        try testing.expectEqualStrings("# new", (try ed.one("$.a.y")).leadingComments(&doc).?);
        try testing.expectEqualStrings("# new", (try ed.one("$.a")).leadingComments(&doc).?);
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("a:\n  # new\n  y: 2\n", out);
    }
}

test "comment write: nothing inside a new subtree is accepted and dropped" {
    // The emitter lays a new subtree out afresh and writes no comments
    // inside it; the write used to be accepted, read back in memory and
    // silently lost.
    const edit_mod = @import("edit.zig");
    var doc = try Document.parse(testing.allocator, "a: 1\nb: 2\n");
    defer doc.deinit();
    var ed = edit_mod.Editor.init(&doc);
    const m = try doc.createMapping();
    try doc.mappingAppend(m, try doc.createScalar("x", .plain), try doc.createScalar("1", .plain));
    try ed.set("$.c", m);
    const x = try ed.one("$.c.x");
    try testing.expectError(error.InvalidSyntax, doc.setLeadingComments(x, "# new"));
    try testing.expectError(error.InvalidSyntax, doc.setTrailingComment(x, "# t"));
    // So is one on the new block value itself: nothing writes a block
    // between `c:` and its first line. The entry's line is its key's.
    try testing.expectError(error.InvalidSyntax, doc.setLeadingComments(try ed.one("$.c"), "# new"));
    const pairs = doc.root.?.pairs().?;
    try doc.setLeadingComments(pairs[pairs.len - 1].key, "# new");
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: 1\nb: 2\n# new\nc:\n  x: 1\n", out);
}

test "comment reads: a collection's trailing comment is its last entry's now" {
    const edit_mod = @import("edit.zig");
    var doc = try Document.parse(testing.allocator, "a:\n  x: 1\n  y: 2 # c\nb: 3\n");
    defer doc.deinit();
    var ed = edit_mod.Editor.init(&doc);
    try testing.expectEqualStrings("# c", (try ed.one("$.a")).trailingComment(&doc).?);
    try doc.setTrailingComment(try ed.one("$.a.x"), "# x");
    try ed.delete("$.a.y");
    try testing.expectEqualStrings("# x", (try ed.one("$.a")).trailingComment(&doc).?);
    // `? key` with no value: the key reads what is written on its value.
    var set = try Document.parse(testing.allocator, "? a\n? b\n");
    defer set.deinit();
    try set.setTrailingComment(set.root.?.pairs().?[0].value, "# t");
    try testing.expectEqualStrings("# t", set.root.?.pairs().?[0].key.trailingComment(&set).?);
}

test "comment write: a value after a synthetic key reads its entry's line" {
    // `: a` has no key bytes: the value is the entry's first byte, and
    // for the first pair it shares the mapping's line. Written there, the
    // block read back from nobody.
    // Not first, the value holds its own line's block.
    {
        var doc = try Document.parse(testing.allocator, ": a\n: b\n");
        defer doc.deinit();
        try doc.setLeadingComments(doc.root.?.pairs().?[1].value, "# probe");
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(": a\n# probe\n: b\n", out);
        var again = try Document.parse(testing.allocator, out);
        defer again.deinit();
        try testing.expectEqualStrings("# probe", again.root.?.pairs().?[1].value.leadingComments(&again).?);
    }
    for ([_][]const u8{ ": a\n: b\n", "- ? : x\n" }) |in| {
        var doc = try Document.parse(testing.allocator, in);
        defer doc.deinit();
        var node = doc.root.?;
        while (true) {
            if (node.items()) |its| node = its[0] else if (node.pairs()) |ps| node = if (ps[0].key.pairs() != null) ps[0].key else ps[0].value else break;
        }
        try doc.setLeadingComments(node, "# probe");
        const out = try doc.write(testing.allocator);
        defer testing.allocator.free(out);
        var again = try Document.parse(testing.allocator, out);
        defer again.deinit();
        var back = again.root.?;
        while (true) {
            if (back.items()) |its| back = its[0] else if (back.pairs()) |ps| back = if (ps[0].key.pairs() != null) ps[0].key else ps[0].value else break;
        }
        try testing.expectEqualStrings("# probe", back.leadingComments(&again).?);
    }
}

test "comment write: a root on the `---` line moves below its block" {
    // It was written `--- \n    # new\n    {a: 1}`: a trailing blank
    // after the marker and the root four columns in.
    const parseAll = @import("yaml.zig").parseAll;
    for ([_][2][]const u8{
        .{ "--- {a: 1}\n", "---\n# new\n{a: 1}\n" },
        .{ "--- !!map {a: 1}\n", "---\n# new\n!!map {a: 1}\n" },
        .{ "x: 1\n--- [1, 2]\n", "x: 1\n---\n# new\n[1, 2]\n" },
    }) |c| {
        var docs = try parseAll(testing.allocator, c[0]);
        defer {
            for (docs.items) |*d| d.deinit();
            docs.deinit(testing.allocator);
        }
        const doc = &docs.items[docs.items.len - 1];
        try doc.setLeadingComments(doc.root.?, "# new");
        const out = try writeAll(testing.allocator, docs.items);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c[1], out);
        var again = try parseAll(testing.allocator, out);
        defer {
            for (again.items) |*d| d.deinit();
            again.deinit(testing.allocator);
        }
        const last = &again.items[again.items.len - 1];
        try testing.expectEqualStrings("# new", last.root.?.leadingComments(last).?);
    }
}

test "comment write in a CRLF document keeps the convention" {
    const src = "# head\r\na: 1 # one\r\nb: 2\r\n";
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try doc.setTrailingComment(doc.pathGet(&.{"b"}).?, "# two");
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# head\r\na: 1 # one\r\nb: 2 # two\r\n", out);

    // And a written leading block uses the same terminator.
    try doc.setLeadingComments(doc.pathGet(&.{"b"}).?, "# lead");
    const out2 = try doc.write(testing.allocator);
    defer testing.allocator.free(out2);
    try testing.expectEqualStrings("# head\r\na: 1 # one\r\n# lead\r\nb: 2 # two\r\n", out2);
}

test "allocation failures in comment writes leak nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, commentWrite, .{});
}

fn commentWrite(allocator: std.mem.Allocator) !void {
    var doc = try Document.parse(allocator, "# head\na: 1 # tail\nb: 2\n");
    defer doc.deinit();
    try doc.setTrailingComment(doc.pathGet(&.{"a"}).?, "# rewritten");
    try doc.setLeadingComments(doc.pathGet(&.{"b"}).?, "# new\n# block");
    const out = try doc.write(allocator);
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "# rewritten") != null);
}

test "read paths walk sequence indices like the edit grammar" {
    var doc = try Document.parse(testing.allocator,
        \\items:
        \\  - first
        \\  - second
        \\"0": map key
        \\deep:
        \\  - k: [a, b]
        \\
    );
    defer doc.deinit();
    // Numeric segments index sequences at any depth.
    try testing.expectEqualStrings("first", doc.pathGet(&.{ "items", "0" }).?.scalarValue().?);
    try testing.expectEqualStrings("second", doc.pathGet(&.{ "items", "1" }).?.scalarValue().?);
    try testing.expectEqualStrings("b", doc.pathGet(&.{ "deep", "0", "k", "1" }).?.scalarValue().?);
    // Out of range: null, not a crash.
    try testing.expect(doc.pathGet(&.{ "items", "2" }) == null);
    // A numeric key on a MAPPING is still an ordinary key.
    try testing.expectEqualStrings("map key", doc.pathGet(&.{"0"}).?.scalarValue().?);
    // Non-numeric segments on a sequence stay null.
    try testing.expect(doc.pathGet(&.{ "items", "first" }) == null);
}

test "deleting the last entry keeps the tail comment on its own line" {
    // Fuzz-found (seed 0xF022, iteration 206) the moment parse stopped
    // dropping the tail: the tombstone consumed the terminator that
    // separated the emptied container from the surviving comment.
    var doc = try Document.parse(testing.allocator, "# head\nkey: value # tail\n# delta");
    defer doc.deinit();
    try testing.expect(try doc.pathDelete(&.{"key"}));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# head\n{}\n# delta", out);

    var again = try Document.parse(testing.allocator, out);
    defer again.deinit();
    const out2 = try again.write(testing.allocator);
    defer testing.allocator.free(out2);
    try testing.expectEqualStrings(out, out2);
}

test "merge keys: an aliased mapping is merged and its key removed" {
    var doc = try Document.parse(testing.allocator,
        \\base: &base
        \\  a: 1
        \\  b: 2
        \\use:
        \\  <<: *base
        \\  c: 3
        \\
    );
    defer doc.deinit();
    try doc.resolveMergeKeys();
    const use = doc.pathGet(&.{"use"}).?;
    try testing.expectEqualStrings("1", use.lookup("a").?.scalarValue().?);
    try testing.expectEqualStrings("2", use.lookup("b").?.scalarValue().?);
    try testing.expectEqualStrings("3", use.lookup("c").?.scalarValue().?);
    try testing.expect(use.lookup("<<") == null);
}

test "merge keys: an explicit key wins over the merged one" {
    var doc = try Document.parse(testing.allocator,
        \\base: &base
        \\  a: 1
        \\  b: 2
        \\use:
        \\  <<: *base
        \\  a: 9
        \\
    );
    defer doc.deinit();
    try doc.resolveMergeKeys();
    const use = doc.pathGet(&.{"use"}).?;
    try testing.expectEqualStrings("9", use.lookup("a").?.scalarValue().?);
    try testing.expectEqualStrings("2", use.lookup("b").?.scalarValue().?);
}

test "merge keys: the earliest sequence source wins" {
    var doc = try Document.parse(testing.allocator,
        \\a: &a
        \\  k: from-a
        \\  x: 1
        \\b: &b
        \\  k: from-b
        \\  y: 2
        \\use:
        \\  <<: [*a, *b]
        \\
    );
    defer doc.deinit();
    try doc.resolveMergeKeys();
    const use = doc.pathGet(&.{"use"}).?;
    try testing.expectEqualStrings("from-a", use.lookup("k").?.scalarValue().?);
    try testing.expectEqualStrings("1", use.lookup("x").?.scalarValue().?);
    try testing.expectEqualStrings("2", use.lookup("y").?.scalarValue().?);
}

test "merge keys: inline mapping and a sequence of inline mappings" {
    var doc = try Document.parse(testing.allocator,
        \\one:
        \\  <<: { a: 1 }
        \\many:
        \\  <<: [{ a: 1, x: 9 }, { b: 2, a: 8 }]
        \\
    );
    defer doc.deinit();
    try doc.resolveMergeKeys();
    const one = doc.pathGet(&.{"one"}).?;
    try testing.expectEqualStrings("1", one.lookup("a").?.scalarValue().?);
    const many = doc.pathGet(&.{"many"}).?;
    try testing.expectEqualStrings("1", many.lookup("a").?.scalarValue().?);
    try testing.expectEqualStrings("2", many.lookup("b").?.scalarValue().?);
    try testing.expect(many.lookup("x") != null);
}

test "merge keys: a source that itself merges is expanded first" {
    var doc = try Document.parse(testing.allocator,
        \\root: &root
        \\  r: 0
        \\mid: &mid
        \\  <<: *root
        \\  m: 1
        \\use:
        \\  <<: *mid
        \\  u: 2
        \\
    );
    defer doc.deinit();
    try doc.resolveMergeKeys();
    const use = doc.pathGet(&.{"use"}).?;
    try testing.expectEqualStrings("0", use.lookup("r").?.scalarValue().?);
    try testing.expectEqualStrings("1", use.lookup("m").?.scalarValue().?);
    try testing.expectEqualStrings("2", use.lookup("u").?.scalarValue().?);
    const mid = doc.pathGet(&.{"mid"}).?;
    try testing.expectEqualStrings("0", mid.lookup("r").?.scalarValue().?);
}

test "merge keys: resolution is bounded in the nodes it copies" {
    // Every `<<: *base` copies the base's pairs into its mapping, and
    // resolution had no bound but depth: 72 KB of merges of a 1000-key
    // base built a 2.4 GB arena over two minutes (each copied key was
    // also checked against every key already there, quadratic per merge).
    const allocator = testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, "base: &b\n");
    for (0..50) |i| try input.print(allocator, "  k{d}: v\n", .{i});
    for (0..100) |i| try input.print(allocator, "m{d}: {{<<: *b, own: 1}}\n", .{i});

    // 100 merges x 50 pairs x 2 nodes = 10,000 copies.
    try testing.expectError(error.LimitExceeded, Document.parseOpts(allocator, input.items, null, .{ .resolve_merge_keys = true, .max_merge_nodes = 5_000 }));
    var doc = try Document.parseOpts(allocator, input.items, null, .{ .resolve_merge_keys = true, .max_merge_nodes = 10_000 });
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 51), doc.pathGet(&.{"m99"}).?.pairs().?.len);
    try testing.expectEqual(@as(usize, 1 << 18), (ParseOptions{}).max_merge_nodes);

    // A refused resolution leaves the document as it was.
    var raw = try Document.parse(allocator, input.items);
    defer raw.deinit();
    try testing.expectError(error.LimitExceeded, raw.resolveMergeKeysLimited(5_000));
    const out = try raw.write(allocator);
    defer allocator.free(out);
    try testing.expectEqualStrings(input.items, out);
}

test "merge keys: a quoted << is an ordinary key" {
    var doc = try Document.parse(testing.allocator,
        \\base: &base
        \\  a: 1
        \\use:
        \\  "<<": *base
        \\
    );
    defer doc.deinit();
    try doc.resolveMergeKeys();
    const use = doc.pathGet(&.{"use"}).?;
    try testing.expect(use.lookup("<<") != null);
    try testing.expect(use.lookup("a") == null);
}

test "merge keys: an invalid value refuses and changes nothing" {
    var doc = try Document.parse(testing.allocator, "use:\n  <<: 5\n");
    defer doc.deinit();
    const before = try doc.write(testing.allocator);
    defer testing.allocator.free(before);
    try testing.expectError(error.InvalidMergeKey, doc.resolveMergeKeys());
    const after = try doc.write(testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try testing.expect(doc.pathGet(&.{"use"}).?.lookup("<<") != null);
}

test "merge keys: a sequence item that is not a mapping is refused" {
    var doc = try Document.parse(testing.allocator, "use:\n  <<: [1]\n");
    defer doc.deinit();
    try testing.expectError(error.InvalidMergeKey, doc.resolveMergeKeys());
}

test "merge keys: a parsed self-referential merge is refused" {
    // yayl accepts recursive anchors, so a parsed document CAN express
    // this: the alias names an enclosing anchor. Refusing is right —
    // copying `parent`'s pairs into `child` would copy `child` itself.
    // (This corrects an earlier comment that claimed the parser rejects
    // every self-reference; it does not, for this shape.)
    var doc = try Document.parse(testing.allocator,
        \\parent: &p
        \\  a: 1
        \\  child:
        \\    <<: *p
        \\
    );
    defer doc.deinit();
    try testing.expectError(error.MergeKeyRecursive, doc.resolveMergeKeys());
}

test "merge keys: a hand-built self-merge is refused" {
    // The built-tree form of the same guard: an alias node whose target
    // is the mapping being resolved. Built directly because a parser
    // shape for this one is not needed to reach the guard.
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    const map = try doc.createMapping();
    doc.root = map;
    try doc.setAnchor(map, "s");
    const alias = try doc.pool.create(Node);
    alias.* = .{ .data = .{ .alias = .{ .name = "s", .target = map } } };
    try doc.mappingAppend(map, try doc.createScalar("<<", .plain), alias);
    try testing.expectError(error.MergeKeyRecursive, doc.resolveMergeKeys());
}

test "merge keys: a document without them is untouched" {
    const src = "a: 1\nb:\n  - x\n  - y\n";
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try doc.resolveMergeKeys();
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "merge keys: parse option resolves, default leaves them alone" {
    const src =
        \\base: &base
        \\  a: 1
        \\use:
        \\  <<: *base
        \\
    ;
    var plain = try Document.parse(testing.allocator, src);
    defer plain.deinit();
    try testing.expect(plain.pathGet(&.{"use"}).?.lookup("<<") != null);

    var doc = try Document.parseOpts(testing.allocator, src, null, .{ .resolve_merge_keys = true });
    defer doc.deinit();
    try testing.expectEqualStrings("1", doc.pathGet(&.{"use"}).?.lookup("a").?.scalarValue().?);

    var docs = try Document.parseAllOpts(testing.allocator, src, null, .{ .resolve_merge_keys = true });
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(testing.allocator);
    }
    try testing.expectEqualStrings("1", docs.items[0].pathGet(&.{"use"}).?.lookup("a").?.scalarValue().?);
}

test "merge keys: resolved output re-parses with the merged values" {
    var doc = try Document.parse(testing.allocator,
        \\defaults: &defaults
        \\  image: rust:1.79
        \\  retry:
        \\    max: 2
        \\build:
        \\  <<: *defaults
        \\  stage: build
        \\
    );
    defer doc.deinit();
    try doc.resolveMergeKeys();
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<<") == null);
    var again = try Document.parse(testing.allocator, out);
    defer again.deinit();
    const build = again.pathGet(&.{"build"}).?;
    try testing.expectEqualStrings("rust:1.79", build.lookup("image").?.scalarValue().?);
    try testing.expectEqualStrings("build", build.lookup("stage").?.scalarValue().?);
    try testing.expectEqualStrings("2", again.pathGet(&.{ "build", "retry", "max" }).?.scalarValue().?);
}

test "merge keys: allocation failures leak nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, mergeResolve, .{});
}

fn mergeResolve(allocator: std.mem.Allocator) !void {
    var doc = try Document.parse(allocator,
        \\base: &base { a: 1, b: 2 }
        \\use: { <<: *base, c: 3 }
        \\
    );
    defer doc.deinit();
    try doc.resolveMergeKeys();
}

test "merge keys: a CRLF document keeps its convention" {
    const src = "base: &b\r\n  a: 1\r\nuse:\r\n  <<: *b\r\n  c: 3\r\n";
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try doc.resolveMergeKeys();
    try testing.expectEqualStrings("1", doc.pathGet(&.{"use"}).?.lookup("a").?.scalarValue().?);
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    // Every break the resolved mapping writes is CRLF too.
    try testing.expect(std.mem.count(u8, out, "\n") == std.mem.count(u8, out, "\r\n"));
    var again = try Document.parse(testing.allocator, out);
    defer again.deinit();
    try testing.expectEqualStrings("1", again.pathGet(&.{"use"}).?.lookup("a").?.scalarValue().?);
}

test "appending to a CRLF mapping keeps the document convention" {
    // The general form of the bug merge resolution surfaced: a brand-new
    // entry's line break came from a hardcoded '\n', so the entry
    // before it ended with a bare LF in a CRLF document.
    var doc = try Document.parse(testing.allocator, "a: 1\r\nb: 2\r\n");
    defer doc.deinit();
    try doc.mappingAppend(doc.root.?, try doc.createScalar("c", .plain), try doc.createScalar("3", .plain));
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: 1\r\nb: 2\r\nc: 3\r\n", out);
}

test "merge keys: the earliest of duplicate merge keys wins" {
    var doc = try Document.parse(testing.allocator,
        \\a: &a { k: from-a }
        \\b: &b { k: from-b }
        \\use:
        \\  <<: *a
        \\  <<: *b
        \\
    );
    defer doc.deinit();
    try doc.resolveMergeKeys();
    try testing.expectEqualStrings("from-a", doc.pathGet(&.{"use"}).?.lookup("k").?.scalarValue().?);
}

test "merge keys: a merge inside a sequence item is resolved" {
    var doc = try Document.parse(testing.allocator,
        \\base: &base { a: 1 }
        \\list:
        \\  - <<: *base
        \\    own: 2
        \\
    );
    defer doc.deinit();
    try doc.resolveMergeKeys();
    const item = doc.pathGet(&.{ "list", "0" }).?;
    try testing.expectEqualStrings("1", item.lookup("a").?.scalarValue().?);
    try testing.expectEqualStrings("2", item.lookup("own").?.scalarValue().?);
}

test "merge keys: a plain << with an explicit tag is still a merge key" {
    var doc = try Document.parse(testing.allocator,
        \\base: &base { a: 1 }
        \\use:
        \\  !!str <<: *base
        \\
    );
    defer doc.deinit();
    try doc.resolveMergeKeys();
    const use = doc.pathGet(&.{"use"}).?;
    try testing.expectEqualStrings("1", use.lookup("a").?.scalarValue().?);
    try testing.expect(use.lookup("<<") == null);
}

test "merge keys: a copied node drops its anchor but the source keeps it" {
    var doc = try Document.parse(testing.allocator,
        \\base: &base
        \\  x: &n 7
        \\alias: *n
        \\use:
        \\  <<: *base
        \\
    );
    defer doc.deinit();
    try doc.resolveMergeKeys();
    const use = doc.pathGet(&.{"use"}).?;
    try testing.expectEqualStrings("7", use.lookup("x").?.scalarValue().?);
    try testing.expectEqualStrings("7", doc.pathGet(&.{"alias"}).?.scalarValue().?);
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    // The copy must not define a second &n.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "&n"));
    var again = try Document.parse(testing.allocator, out);
    defer again.deinit();
    try testing.expectEqualStrings("7", again.pathGet(&.{"alias"}).?.scalarValue().?);
    try testing.expectEqualStrings("7", again.pathGet(&.{ "use", "x" }).?.scalarValue().?);
}

test "merge keys: an alias inside a merged value stays an alias" {
    var doc = try Document.parse(testing.allocator,
        \\other: &o
        \\  v: 1
        \\base: &base
        \\  ref: *o
        \\use:
        \\  <<: *base
        \\
    );
    defer doc.deinit();
    try doc.resolveMergeKeys();
    const ref = doc.pathGet(&.{"use"}).?.lookup("ref").?;
    try testing.expect(ref.isAlias());
    try testing.expectEqualStrings("1", ref.lookup("v").?.scalarValue().?);
}

test "merge keys: parseAllOpts resolves every document" {
    var docs = try Document.parseAllOpts(testing.allocator,
        \\base: &b { a: 1 }
        \\use: { <<: *b }
        \\---
        \\base: &c { x: 2 }
        \\use: { <<: *c }
        \\
    , null, .{ .resolve_merge_keys = true });
    defer {
        for (docs.items) |*d| d.deinit();
        docs.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 2), docs.items.len);
    try testing.expectEqualStrings("1", docs.items[0].pathGet(&.{"use"}).?.lookup("a").?.scalarValue().?);
    try testing.expectEqualStrings("2", docs.items[1].pathGet(&.{"use"}).?.lookup("x").?.scalarValue().?);
}

test "merge keys: a hand-built tree past the depth bound is refused" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    const root = try doc.createMapping();
    doc.root = root;
    var cur = root;
    var i: usize = 0;
    while (i < 1001) : (i += 1) {
        const child = try doc.createMapping();
        try doc.mappingAppend(cur, try doc.createScalar("k", .plain), child);
        cur = child;
    }
    try doc.mappingAppend(cur, try doc.createScalar("<<", .plain), try doc.createScalar("x", .plain));
    try testing.expectError(error.NestingTooDeep, doc.resolveMergeKeys());
}

test "merge keys: an alias to a non-mapping is refused" {
    var doc = try Document.parse(testing.allocator,
        \\name: &name hello
        \\use:
        \\  <<: *name
        \\
    );
    defer doc.deinit();
    try testing.expectError(error.InvalidMergeKey, doc.resolveMergeKeys());
}

test "merge keys: an alias to a sequence of mappings is accepted" {
    var doc = try Document.parse(testing.allocator,
        \\seq: &seq
        \\  - { a: 1 }
        \\  - { b: 2 }
        \\use:
        \\  <<: *seq
        \\
    );
    defer doc.deinit();
    try doc.resolveMergeKeys();
    const use = doc.pathGet(&.{"use"}).?;
    try testing.expectEqualStrings("1", use.lookup("a").?.scalarValue().?);
    try testing.expectEqualStrings("2", use.lookup("b").?.scalarValue().?);
}

test "merge keys: a rootless document is a no-op" {
    var doc = try Document.parse(testing.allocator, "# only a comment\n");
    defer doc.deinit();
    try doc.resolveMergeKeys();
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# only a comment\n", out);
}

test "merge keys: a complex source key is copied and re-reads" {
    // The path marble-owl's probe reached the emitter bug through: a
    // merge source with a non-scalar key, copied into the target.
    var doc = try Document.parse(testing.allocator,
        \\base: &base
        \\  ? [1, 2]
        \\  : pair
        \\  ? {k: v}
        \\  : map-pair
        \\use:
        \\  <<: *base
        \\
    );
    defer doc.deinit();
    try doc.resolveMergeKeys();
    const use = doc.pathGet(&.{"use"}).?;
    try testing.expectEqual(@as(usize, 2), use.pairs().?.len);
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    var again = try Document.parse(testing.allocator, out);
    defer again.deinit();
    const pairs = again.pathGet(&.{"use"}).?.pairs().?;
    try testing.expectEqual(@as(usize, 2), pairs.len);
    try testing.expectEqual(NodeKind.sequence, pairs[0].key.kind());
    try testing.expectEqualStrings("pair", pairs[0].value.scalarValue().?);
    try testing.expectEqual(NodeKind.mapping, pairs[1].key.kind());
    try testing.expectEqualStrings("map-pair", pairs[1].value.scalarValue().?);
}

test "merge keys: the GitLab CI fixture resolves its job templates" {
    // A named gate for tests/fixtures/gitlab-anchors.yaml, the realistic
    // configuration the merge feature exists for. Read at run time rather
    // than embedded: `tests/` is deliberately absent from build.zig.zon's
    // `.paths`, so wiring the fixture into the library module would ship a
    // dangling import to every dependent (exactly what the consumer-smoke
    // gate catches).
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const input = std.Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/gitlab-anchors.yaml",
        testing.allocator,
        .limited(1 << 20),
    ) catch |err| {
        // Never a silent skip: a fixture this gate cannot find is a
        // failure, not a pass.
        std.debug.print(
            "gitlab-anchors.yaml unreadable ({s}) -- run from the repository root\n",
            .{@errorName(err)},
        );
        return err;
    };
    defer testing.allocator.free(input);

    var doc = try Document.parseOpts(testing.allocator, input, null, .{ .resolve_merge_keys = true });
    defer doc.deinit();

    // build-job and test-job carry `<<: *defaults`; each must gain the
    // template's three keys and keep its own.
    for ([_][]const u8{ "build-job", "test-job" }) |name| {
        const job = doc.pathGet(&.{name}) orelse return error.TestUnexpectedResult;
        try testing.expect(job.lookup("<<") == null);
        const before = job.lookup("before_script") orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(usize, 2), before.data.sequence.items.items.len);
        const retry = job.lookup("retry") orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("2", retry.lookup("max").?.scalarValue().?);
        // Its own keys survive the merge.
        try testing.expect(job.lookup("stage") != null);
        try testing.expect(job.lookup("script") != null);
    }
    try testing.expectEqualStrings("build", doc.pathGet(&.{ "build-job", "stage" }).?.scalarValue().?);
    try testing.expectEqualStrings("test", doc.pathGet(&.{ "test-job", "stage" }).?.scalarValue().?);

    // Precedence, the half a template with no key overlap cannot test:
    // build-job takes the template's image, test-job overrides it and
    // must keep its own. Without this the gate survives a merge that
    // clobbers explicit keys.
    try testing.expectEqualStrings("rust:1.79", doc.pathGet(&.{ "build-job", "image" }).?.scalarValue().?);
    try testing.expectEqualStrings("rust:1.79-slim", doc.pathGet(&.{ "test-job", "image" }).?.scalarValue().?);

    // deploy-job is the negative control: it has NO merge key, so
    // resolution must not leak the template into it. Without this, a
    // merge that wrote into every mapping would still pass above.
    const deploy = doc.pathGet(&.{"deploy-job"}) orelse return error.TestUnexpectedResult;
    try testing.expect(deploy.lookup("image") == null);
    try testing.expect(deploy.lookup("before_script") == null);
    try testing.expect(deploy.lookup("retry") == null);
    try testing.expectEqualStrings("deploy", deploy.lookup("stage").?.scalarValue().?);

    // The template itself is untouched by being a merge source.
    const defaults = doc.pathGet(&.{".defaults"}) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("rust:1.79", defaults.lookup("image").?.scalarValue().?);
}

test "sequenceInsert refuses an ancestor instead of building a cycle" {
    const allocator = std.testing.allocator;

    // Regression: `sequenceInsert` skipped the `wouldCycle` guard the two
    // append siblings enforce, so inserting an ancestor under its own
    // descendant built a parent cycle and `markModified` then tripped its
    // assert -- a panic reachable through `Document` (and through
    // `Editor` when a caller passes a node of the same tree).
    var doc = Document.init(allocator);
    defer doc.deinit();
    const root = try doc.createMapping();
    doc.root = root;
    const seq = try doc.createSequence();
    try doc.mappingAppend(root, try doc.createScalar("list", .plain), seq);
    try doc.sequenceAppend(seq, try doc.createScalar("x", .plain));

    // The sequence, and any ancestor of it, cannot become one of its items.
    try std.testing.expectError(error.WouldCycle, doc.sequenceInsert(seq, 0, seq));
    try std.testing.expectError(error.WouldCycle, doc.sequenceInsert(seq, 0, root));
    try std.testing.expectError(error.WouldCycle, doc.sequenceAppend(seq, seq));
    try std.testing.expectError(error.WouldCycle, doc.sequenceAppend(seq, root));

    // Refused means untouched: the tree still emits and reparses.
    const out = try doc.write(allocator);
    defer allocator.free(out);
    var re = try Document.parse(allocator, out);
    defer re.deinit();
    try std.testing.expectEqual(@as(usize, 1), re.pathGet(&.{"list"}).?.items().?.len);
}

test "a read path indexes a sequence only with plain decimal digits" {
    // `std.fmt.parseInt(usize, seg, 10)` also takes `+1` and `1_0`, so
    // `byPath(&.{"items", "1_0"})` answered item 10.
    var doc = try Document.parse(testing.allocator, "items: [a, b, c]\n");
    defer doc.deinit();
    try testing.expectEqualStrings("b", doc.pathGet(&.{ "items", "1" }).?.scalarValue().?);
    for ([_][]const u8{ "+1", "1_0", "-0", " 1", "" }) |seg| {
        try testing.expect(doc.pathGet(&.{ "items", seg }) == null);
    }
}

test "parseCoreInt and parseCoreFloat are the one shared scalar rule" {
    // `value` and `schema` both call these, so they cannot disagree about
    // which scalars are bigints or float specials.
    try std.testing.expectEqual(@as(?i64, 42), parseCoreInt("42"));
    try std.testing.expectEqual(@as(?i64, -7), parseCoreInt("-7"));
    try std.testing.expectEqual(@as(?i64, null), parseCoreInt("99999999999999999999"));
    try std.testing.expectEqual(@as(?f64, 1.5), parseCoreFloat("1.5"));
    try std.testing.expectEqual(std.math.inf(f64), parseCoreFloat(".inf").?);
    try std.testing.expectEqual(@as(?f64, null), parseCoreFloat("not a float"));
}

test "rootlessDocument carries bytes with no node" {
    const allocator = std.testing.allocator;
    var d = try Document.rootlessDocument(allocator, "# c\n");
    defer d.deinit();
    try std.testing.expect(d.root == null);
    const out = try d.write(allocator);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("# c\n", out);
}
