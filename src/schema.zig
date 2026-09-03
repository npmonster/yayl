//! Schema validation.
//!
//! A small, opt-in schema descriptor language over the document model.
//! Nothing here is required for parsing or editing: a schema validates
//! a node and produces structured violations with the logical path,
//! and never mutates the document.
//!
//!     const schema = Schema.map(&.{
//!         .{ .key = "name", .schema = Schema.str, .required = true },
//!         .{ .key = "port", .schema = Schema.intRange(1, 65535), .required = true },
//!         .{ .key = "tags", .schema = Schema.seq(Schema.str) },
//!     });
//!     const violations = try schema.validate(allocator, node, "$");
//!     // violations carry path + rule; caller frees with freeViolations.
//!
//! Unknown mapping keys are allowed unless `deny_unknown` is set.
//! Validation never fails the document: failures are data.

const std = @import("std");
const document_mod = @import("document.zig");

const Node = document_mod.Node;

pub const Error = error{ OutOfMemory, LimitExceeded, NestingTooDeep };

/// Bounds on how much of a document one validation may walk.
///
/// Validation resolves aliases, so a node reached through M aliases is
/// walked M times: the work is bounded by the expanded tree, not by the
/// input. Same shape as `value.Limits`, and it matters for the same
/// reason — see that type for the arithmetic.
pub const Limits = struct {
    /// Maximum nodes one validation may visit. Validation stops with
    /// `error.LimitExceeded` on the node that would exceed it.
    max_nodes: usize = 1 << 20,

    /// Deepest nesting one validation will descend before returning
    /// `error.NestingTooDeep`.
    ///
    /// Validation is recursive, so this bounds native stack use, and a
    /// node count cannot stand in for it: a linear chain of N nested
    /// collections is N nodes but N frames deep. Composition branches
    /// (`all_of`, `any_of`, `one_of`, `nullable`) re-enter on the same
    /// node, so a deeply composed schema charges depth without
    /// descending the document — deliberately, since those frames are
    /// just as real. Same default as `value.Limits.max_depth` and
    /// `Emitter.max_depth`.
    max_depth: usize = 1000,

    /// No bound. Only for input you produced yourself.
    ///
    /// This lifts the depth bound as well, which re-arms the stack
    /// overflow it exists to prevent. To lift only the node budget, set
    /// `max_nodes` and leave `max_depth` alone.
    pub const unlimited: Limits = .{
        .max_nodes = std.math.maxInt(usize),
        .max_depth = std.math.maxInt(usize),
    };
};

pub const Schema = struct {
    kind: Kind,

    pub const Kind = union(enum) {
        any,
        str,
        bool,
        int,
        float,
        /// Scalar string restricted to a fixed set.
        str_enum: []const []const u8,
        /// Integer range, inclusive.
        int_range: struct { min: i64, max: i64 },
        /// Float range, inclusive. Integers satisfy it too, as they do
        /// for `float`: YAML's core schema resolves `1` as an int, and
        /// rejecting it where a number was asked for is a papercut.
        float_range: struct { min: f64, max: f64 },
        /// String length in codepoints, inclusive. Codepoints rather
        /// than bytes: a bound written as "at most 32 characters" means
        /// characters, and a multibyte name would fail a byte bound for
        /// no reason the author intended.
        str_len: struct { min: usize, max: usize },
        /// Sequence whose items must each match `items`, optionally
        /// with a bound on how many there are.
        seq: struct { items: *const Schema, min_len: ?usize = null, max_len: ?usize = null },
        /// Null, or the inner schema. Distinct from a non-required
        /// field: the key must be present, its value may be null.
        nullable: *const Schema,
        /// Must match every branch.
        all_of: []const *const Schema,
        /// Must match at least one branch.
        any_of: []const *const Schema,
        /// Must match exactly one branch.
        one_of: []const *const Schema,
        /// Mapping with declared fields. Unknown keys are allowed
        /// unless `deny_unknown` is set.
        map: struct { fields: []const Field, deny_unknown: bool = false },
        /// Any scalar (no structure).
        scalar,
    };

    pub const Field = struct {
        key: []const u8,
        schema: *const Schema,
        required: bool = false,
    };

    pub const str = Schema{ .kind = .str };
    pub const boolean = Schema{ .kind = .bool };
    pub const int = Schema{ .kind = .int };
    pub const float = Schema{ .kind = .float };
    pub const scalar = Schema{ .kind = .scalar };
    pub const any = Schema{ .kind = .any };

    /// A string restricted to one of `values`.
    pub fn strEnum(values: []const []const u8) Schema {
        return .{ .kind = .{ .str_enum = values } };
    }

    /// An integer in the inclusive range `[min, max]`.
    pub fn intRange(min: i64, max: i64) Schema {
        return .{ .kind = .{ .int_range = .{ .min = min, .max = max } } };
    }

    /// A number in the inclusive range `[min, max]`. Integers qualify.
    pub fn floatRange(min: f64, max: f64) Schema {
        return .{ .kind = .{ .float_range = .{ .min = min, .max = max } } };
    }

    /// A string of `min` to `max` codepoints, inclusive.
    pub fn strLen(min: usize, max: usize) Schema {
        return .{ .kind = .{ .str_len = .{ .min = min, .max = max } } };
    }

    /// A sequence whose items must each match `items`.
    pub fn seq(items: *const Schema) Schema {
        return .{ .kind = .{ .seq = .{ .items = items } } };
    }

    /// A sequence of `min` to `max` items, each matching `items`.
    pub fn seqLen(items: *const Schema, min: usize, max: usize) Schema {
        return .{ .kind = .{ .seq = .{ .items = items, .min_len = min, .max_len = max } } };
    }

    /// Null, or `inner`. Use for a key that must be present but whose
    /// value may be null; a merely optional key is `required = false`.
    pub fn nullable(inner: *const Schema) Schema {
        return .{ .kind = .{ .nullable = inner } };
    }

    /// Matches only if every branch matches.
    pub fn allOf(branches: []const *const Schema) Schema {
        return .{ .kind = .{ .all_of = branches } };
    }

    /// Matches if at least one branch matches.
    pub fn anyOf(branches: []const *const Schema) Schema {
        return .{ .kind = .{ .any_of = branches } };
    }

    /// Matches only if exactly one branch matches.
    pub fn oneOf(branches: []const *const Schema) Schema {
        return .{ .kind = .{ .one_of = branches } };
    }

    /// A mapping with declared `fields`; unknown keys are allowed.
    pub fn map(fields: []const Field) Schema {
        return .{ .kind = .{ .map = .{ .fields = fields } } };
    }

    /// Mapping that also rejects undeclared keys.
    pub fn mapStrict(fields: []const Field) Schema {
        return .{ .kind = .{ .map = .{ .fields = fields, .deny_unknown = true } } };
    }

    /// Validate `node` under the default `Limits`; returns the list of
    /// violations (empty when valid). `path` is the logical path
    /// reported in violations.
    pub fn validate(
        self: *const Schema,
        allocator: std.mem.Allocator,
        node: *const Node,
        path: []const u8,
    ) Error![]Violation {
        return self.validateLimited(allocator, node, path, .{});
    }

    /// `validate` with an explicit bound on nodes visited.
    pub fn validateLimited(
        self: *const Schema,
        allocator: std.mem.Allocator,
        node: *const Node,
        path: []const u8,
        limits: Limits,
    ) Error![]Violation {
        var violations: std.ArrayList(Violation) = .empty;
        errdefer {
            for (violations.items) |*v| v.deinitSelf(allocator);
            violations.deinit(allocator);
        }
        var budget: Budget = .{ .remaining = limits.max_nodes, .max_depth = limits.max_depth };
        try checkSchema(self, allocator, node, path, &violations, &budget);
        return violations.toOwnedSlice(allocator);
    }
};

pub const Violation = struct {
    /// Logical path of the offending node, e.g. `$.server.port`.
    path: []const u8,
    /// Machine-readable rule name, e.g. "required", "type", "range".
    rule: []const u8,
    /// Human-readable detail.
    detail: []const u8,

    pub fn deinitSelf(self: *Violation, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.detail);
    }
};

pub fn freeViolations(allocator: std.mem.Allocator, violations: []Violation) void {
    for (violations) |v| {
        allocator.free(v.path);
        allocator.free(v.detail);
    }
    allocator.free(violations);
}

/// Append one violation, owning its path and detail strings: a
/// failure while building or appending releases the partial pair.
fn appendViolation(allocator: std.mem.Allocator, out: *std.ArrayList(Violation), path: []const u8, rule: []const u8, comptime fmt: []const u8, args: anytype) Error!void {
    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);
    const detail = try std.fmt.allocPrint(allocator, fmt, args);
    errdefer allocator.free(detail);
    try out.append(allocator, .{ .path = path_copy, .rule = rule, .detail = detail });
}

fn typeErr(allocator: std.mem.Allocator, path: []const u8, want: []const u8, out: *std.ArrayList(Violation)) Error!void {
    return appendViolation(allocator, out, path, "type", "expected {s}", .{want});
}

/// Does `branch` match `node`? Runs a full validation into a scratch
/// list and reports only whether it was empty.
///
/// The branch's own violations are deliberately dropped: under `any_of`
/// a failing branch is not an error, it is a branch that did not apply,
/// and surfacing four sets of failures for a value that had to match
/// one of four forms buries the actual problem. The composite reports
/// one violation naming the composition instead.
///
/// Budget is shared with the enclosing validation, so exploring
/// branches cannot escape `Limits.max_nodes`.
fn branchMatches(
    branch: *const Schema,
    allocator: std.mem.Allocator,
    node: *const Node,
    path: []const u8,
    b: *Budget,
) Error!bool {
    var scratch: std.ArrayList(Violation) = .empty;
    defer {
        for (scratch.items) |*v| v.deinitSelf(allocator);
        scratch.deinit(allocator);
    }
    try checkSchema(branch, allocator, node, path, &scratch, b);
    return scratch.items.len == 0;
}

fn checkNodeCoreTag(node: *const Node) ?document_mod.CoreTag {
    const s = node.scalarValue() orelse return null;
    return document_mod.resolveCoreTag(s, node.data.scalar.style);
}

/// What one validation has left to spend: nodes it may still visit, and
/// how deep the walk currently is. Shared with every branch explored, so
/// composition cannot escape either bound.
const Budget = struct {
    remaining: usize,
    depth: usize = 0,
    max_depth: usize,

    /// One unit per node visited.
    fn charge(self: *Budget) Error!void {
        if (self.remaining == 0) return error.LimitExceeded;
        self.remaining -= 1;
    }

    /// Open one nesting level, or fail. Paired with `leave`.
    fn enter(self: *Budget) Error!void {
        if (self.depth >= self.max_depth) return error.NestingTooDeep;
        self.depth += 1;
    }

    fn leave(self: *Budget) void {
        // Every caller pairs this with `enter` through `defer`, which
        // holds on the error path too. An unpaired call would wrap.
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
    }
};

fn checkSchema(schema: *const Schema, allocator: std.mem.Allocator, node: *const Node, path: []const u8, out: *std.ArrayList(Violation), b: *Budget) Error!void {
    try b.charge();
    try b.enter();
    defer b.leave();
    const cur = node.resolveAlias();
    switch (schema.kind) {
        .any => {},
        .scalar => {
            if (!cur.isScalar()) try typeErr(allocator, path, "a scalar", out);
        },
        .str => {
            const s = cur.scalarValue() orelse return typeErr(allocator, path, "a string", out);
            if (document_mod.resolveCoreTag(s, cur.data.scalar.style) != .str) {
                try typeErr(allocator, path, "a string", out);
            }
        },
        .bool => {
            if (checkNodeCoreTag(cur) != .bool) try typeErr(allocator, path, "a boolean", out);
        },
        .int => {
            if (checkNodeCoreTag(cur) != .int) try typeErr(allocator, path, "an integer", out);
        },
        .float => {
            const k = checkNodeCoreTag(cur);
            if (k != .float and k != .int) try typeErr(allocator, path, "a number", out);
        },
        .str_enum => |values| {
            const s = cur.scalarValue() orelse return typeErr(allocator, path, "a string", out);
            for (values) |v| {
                if (std.mem.eql(u8, v, s)) return;
            }
            try appendViolation(allocator, out, path, "enum", "'{s}' is not one of the allowed values", .{s});
        },
        .int_range => |r| {
            const k = checkNodeCoreTag(cur);
            if (k != .int) return typeErr(allocator, path, "an integer", out);
            const text = cur.scalarValue().?;
            const v = std.fmt.parseInt(i64, text, 0) catch {
                try typeErr(allocator, path, "an integer", out);
                return;
            };
            if (v < r.min or v > r.max) {
                try appendViolation(allocator, out, path, "range", "{d} is outside [{d}, {d}]", .{ v, r.min, r.max });
            }
        },
        .float_range => |r| {
            const k = checkNodeCoreTag(cur);
            if (k != .float and k != .int) return typeErr(allocator, path, "a number", out);
            const text = cur.scalarValue().?;
            const v = std.fmt.parseFloat(f64, text) catch
                document_mod.floatSpecial(text) orelse {
                try typeErr(allocator, path, "a number", out);
                return;
            };
            // A NaN fails every comparison, so test for it rather than
            // letting `v < min` quietly report it as in range.
            if (std.math.isNan(v) or v < r.min or v > r.max) {
                try appendViolation(allocator, out, path, "range", "{d} is outside [{d}, {d}]", .{ v, r.min, r.max });
            }
        },
        .str_len => |r| {
            const s = cur.scalarValue() orelse return typeErr(allocator, path, "a string", out);
            const n = std.unicode.utf8CountCodepoints(s) catch s.len;
            if (n < r.min or n > r.max) {
                try appendViolation(allocator, out, path, "length", "length {d} is outside [{d}, {d}]", .{ n, r.min, r.max });
            }
        },
        .seq => |spec| {
            const list = cur.items() orelse return typeErr(allocator, path, "a sequence", out);
            if (spec.min_len) |min| if (list.len < min) {
                try appendViolation(allocator, out, path, "length", "{d} items, at least {d} required", .{ list.len, min });
            };
            if (spec.max_len) |max| if (list.len > max) {
                try appendViolation(allocator, out, path, "length", "{d} items, at most {d} allowed", .{ list.len, max });
            };
            for (list, 0..) |item, i| {
                const child_path = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, i });
                defer allocator.free(child_path);
                try checkSchema(spec.items, allocator, item, child_path, out, b);
            }
        },
        .nullable => |inner| {
            if (checkNodeCoreTag(cur) == .null) return;
            try checkSchema(inner, allocator, node, path, out, b);
        },
        .all_of => |branches| {
            // Every branch reports into the caller's list directly: with
            // `all_of` each failure is a real failure, and the author
            // wants to see all of them, not just the first.
            for (branches) |branch| {
                try checkSchema(branch, allocator, node, path, out, b);
            }
        },
        .any_of, .one_of => |branches| {
            var matched: usize = 0;
            for (branches) |branch| {
                if (try branchMatches(branch, allocator, node, path, b)) matched += 1;
            }
            switch (schema.kind) {
                .any_of => if (matched == 0) {
                    try appendViolation(allocator, out, path, "any_of", "matches none of the {d} allowed forms", .{branches.len});
                },
                .one_of => if (matched != 1) {
                    try appendViolation(allocator, out, path, "one_of", "matches {d} of the {d} allowed forms, exactly one required", .{ matched, branches.len });
                },
                else => unreachable,
            }
        },
        .map => |map_spec| {
            const fields = map_spec.fields;
            const pairs = cur.pairs() orelse return typeErr(allocator, path, "a mapping", out);
            // Required keys.
            for (fields) |field| {
                if (!field.required) continue;
                var found = false;
                for (pairs) |p| {
                    const kv = p.key.scalarValue() orelse continue;
                    if (std.mem.eql(u8, kv, field.key)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    const child = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, field.key });
                    errdefer allocator.free(child);
                    const detail = try std.fmt.allocPrint(allocator, "required key '{s}' is missing", .{field.key});
                    errdefer allocator.free(detail);
                    try out.append(allocator, .{ .path = child, .rule = "required", .detail = detail });
                }
            }
            // Per-field and unknown-key checks.
            for (pairs) |p| {
                const kv = p.key.scalarValue() orelse continue;
                const child_path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, kv });
                defer allocator.free(child_path);
                var matched = false;
                for (fields) |field| {
                    if (std.mem.eql(u8, field.key, kv)) {
                        try checkSchema(field.schema, allocator, p.value, child_path, out, b);
                        matched = true;
                        break;
                    }
                }
                if (!matched and map_spec.deny_unknown) {
                    try appendViolation(allocator, out, child_path, "unknown", "unknown key '{s}'", .{kv});
                }
            }
        },
    }
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

test "valid and invalid configurations" {
    const schema = Schema.map(&.{
        .{ .key = "name", .schema = &Schema.str, .required = true },
        .{ .key = "port", .schema = &Schema.intRange(1, 65535), .required = true },
        .{ .key = "mode", .schema = &Schema.strEnum(&.{ "fast", "slow" }) },
        .{ .key = "tags", .schema = &Schema.seq(&Schema.str) },
        .{ .key = "debug", .schema = &Schema.boolean },
    });

    var good = try document_mod.Document.parse(testing.allocator,
        \\name: api
        \\port: 8080
        \\mode: fast
        \\tags: [a, b]
        \\debug: true
        \\
    );
    defer good.deinit();
    {
        const violations = try schema.validate(testing.allocator, good.root.?, "$");
        defer freeViolations(testing.allocator, violations);
        try testing.expectEqual(@as(usize, 0), violations.len);
    }

    var bad = try document_mod.Document.parse(testing.allocator,
        \\name: 42
        \\port: 99999
        \\mode: medium
        \\tags: [a, 3]
        \\debug: sometimes
        \\
    );
    defer bad.deinit();
    {
        const violations = try schema.validate(testing.allocator, bad.root.?, "$");
        defer freeViolations(testing.allocator, violations);
        // name (type), port (range), mode (enum), tags[1] (type),
        // debug (type), port required? present. Missing nothing else.
        try testing.expectEqual(@as(usize, 5), violations.len);
        try testing.expectEqualStrings("type", violations[0].rule);
        try testing.expectEqualStrings("$.name", violations[0].path);
        try testing.expectEqualStrings("range", violations[1].rule);
        try testing.expectEqualStrings("enum", violations[2].rule);
        try testing.expectEqualStrings("$.tags[1]", violations[3].path);
        try testing.expectEqualStrings("type", violations[4].rule);
    }
}

test "required key violation" {
    const schema = Schema.map(&.{
        .{ .key = "host", .schema = &Schema.str, .required = true },
    });
    var doc = try document_mod.Document.parse(testing.allocator, "port: 1\n");
    defer doc.deinit();
    const violations = try schema.validate(testing.allocator, doc.root.?, "$");
    defer freeViolations(testing.allocator, violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqualStrings("required", violations[0].rule);
    try testing.expectEqualStrings("$.host", violations[0].path);
}

test "no schema means no overhead: any passes anything" {
    var doc = try document_mod.Document.parse(testing.allocator, "a: [1, {b: c}]\n");
    defer doc.deinit();
    const violations = try Schema.any.validate(testing.allocator, doc.root.?, "$");
    defer freeViolations(testing.allocator, violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "strict mapping rejects unknown keys and scalar accepts any scalar" {
    const schema = Schema.mapStrict(&.{
        .{ .key = "name", .schema = &Schema.str, .required = true },
    });
    var doc = try document_mod.Document.parse(testing.allocator, "name: api\nextra: 1\n");
    defer doc.deinit();
    const violations = try schema.validate(testing.allocator, doc.root.?, "$");
    defer freeViolations(testing.allocator, violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqualStrings("unknown", violations[0].rule);
    try testing.expectEqualStrings("$.extra", violations[0].path);

    // Schema.scalar: any scalar passes; containers do not.
    var doc2 = try document_mod.Document.parse(testing.allocator, "a: 1\n");
    defer doc2.deinit();
    {
        const v = try Schema.scalar.validate(testing.allocator, doc2.pathGet(&.{"a"}).?, "$");
        defer freeViolations(testing.allocator, v);
        try testing.expectEqual(@as(usize, 0), v.len);
    }
    {
        const v = try Schema.scalar.validate(testing.allocator, doc2.root.?, "$");
        defer freeViolations(testing.allocator, v);
        try testing.expectEqual(@as(usize, 1), v.len);
        try testing.expectEqualStrings("type", v[0].rule);
    }
}

test "allocation failures in validation leak nothing" {
    try std.testing.checkAllAllocationFailures(testing.allocator, validateConfig, .{});
}

fn validateConfig(allocator: std.mem.Allocator) !void {
    const schema = Schema.map(&.{
        .{ .key = "name", .schema = &Schema.str, .required = true },
        .{ .key = "port", .schema = &Schema.intRange(1, 65535), .required = true },
        .{ .key = "tags", .schema = &Schema.seq(&Schema.str) },
    });
    var doc = try document_mod.Document.parse(allocator, "name: api\nport: 99999\ntags: [a, b]\n");
    defer doc.deinit();
    const violations = try schema.validate(allocator, doc.root.?, "$");
    defer freeViolations(allocator, violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
}

test "validation walks a bounded number of nodes" {
    // Aliases are resolved on the way down, so a recursive schema walks
    // the EXPANDED tree: this input is ~130 bytes and 4 nested levels of
    // five aliases each, so `l3` expands to 1 + 5 + 25 + 125 nodes.
    //
    // The schema has to recurse for this to bite. `Schema.any` returns
    // without descending, so it visits exactly one node no matter what
    // it is pointed at -- which is why this test nests `seq` schemas
    // rather than using `any` at the top.
    const src =
        \\l0: &l0 [x, x, x, x, x]
        \\l1: &l1 [*l0, *l0, *l0, *l0, *l0]
        \\l2: &l2 [*l1, *l1, *l1, *l1, *l1]
        \\l3: &l3 [*l2, *l2, *l2, *l2, *l2]
        \\
    ;
    var doc = try document_mod.Document.parse(testing.allocator, src);
    defer doc.deinit();
    const deep = doc.pathGet(&.{"l3"}).?;

    const s1 = Schema.seq(&Schema.any);
    const s2 = Schema.seq(&s1);
    const s3 = Schema.seq(&s2);

    // A tight bound stops the walk instead of letting it run to the
    // expanded size.
    try testing.expectError(
        error.LimitExceeded,
        s3.validateLimited(testing.allocator, deep, "$", .{ .max_nodes = 8 }),
    );

    // The default is a bound, not absent.
    try testing.expectEqual(@as(usize, 1 << 20), (Limits{}).max_nodes);

    // A bound above the expanded size validates normally, so the guard
    // does not reject ordinary documents.
    const violations = try s3.validateLimited(testing.allocator, deep, "$", .{ .max_nodes = 10_000 });
    defer freeViolations(testing.allocator, violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "float range, string length and sequence length" {
    const allocator = testing.allocator;
    var doc = try document_mod.Document.parse(allocator,
        \\ratio: 0.75
        \\whole: 2
        \\huge: 12.5
        \\name: café
        \\empty: ""
        \\tags: [a, b, c]
        \\one: [x]
        \\nan: .nan
        \\
    );
    defer doc.deinit();

    const cases = [_]struct { key: []const u8, schema: Schema, want: usize, rule: []const u8 = "" }{
        .{ .key = "ratio", .schema = Schema.floatRange(0, 1), .want = 0 },
        // An integer satisfies a number bound, as it does for `float`.
        .{ .key = "whole", .schema = Schema.floatRange(0, 10), .want = 0 },
        .{ .key = "huge", .schema = Schema.floatRange(0, 1), .want = 1 },
        // NaN compares false against everything; it must not pass a
        // range check by default.
        // "range", not "type": `.nan` really is a float under the core
        // schema, so this asserts we parsed it and then rejected it on
        // the comparison, rather than never recognising it as a number.
        .{ .key = "nan", .schema = Schema.floatRange(0, 1), .want = 1, .rule = "range" },
        // Codepoints, not bytes: "café" is 4 characters in 5 bytes.
        .{ .key = "name", .schema = Schema.strLen(1, 4), .want = 0 },
        .{ .key = "name", .schema = Schema.strLen(1, 3), .want = 1 },
        .{ .key = "empty", .schema = Schema.strLen(1, 8), .want = 1 },
        .{ .key = "tags", .schema = Schema.seqLen(&Schema.str, 1, 3), .want = 0 },
        .{ .key = "tags", .schema = Schema.seqLen(&Schema.str, 1, 2), .want = 1 },
        .{ .key = "one", .schema = Schema.seqLen(&Schema.str, 2, 5), .want = 1 },
    };
    for (cases) |c| {
        const violations = try c.schema.validate(allocator, doc.pathGet(&.{c.key}).?, "$");
        defer freeViolations(allocator, violations);
        testing.expectEqual(c.want, violations.len) catch |err| {
            std.debug.print("key '{s}' produced {d} violations, wanted {d}\n", .{ c.key, violations.len, c.want });
            return err;
        };
        if (c.rule.len > 0) try testing.expectEqualStrings(c.rule, violations[0].rule);
    }
}

test "nullable is not the same as optional" {
    const allocator = testing.allocator;
    var doc = try document_mod.Document.parse(allocator, "a: null\nb: 7\nc: text\n");
    defer doc.deinit();

    const s = Schema.nullable(&Schema.int);
    for ([_][]const u8{ "a", "b" }) |key| {
        const violations = try s.validate(allocator, doc.pathGet(&.{key}).?, "$");
        defer freeViolations(allocator, violations);
        try testing.expectEqual(@as(usize, 0), violations.len);
    }
    {
        const violations = try s.validate(allocator, doc.pathGet(&.{"c"}).?, "$");
        defer freeViolations(allocator, violations);
        try testing.expectEqual(@as(usize, 1), violations.len);
    }

    // The distinction: a required key whose value may be null still has
    // to be present. `required = false` would accept its absence.
    const with_null = Schema.map(&.{.{ .key = "a", .schema = &s, .required = true }});
    var missing = try document_mod.Document.parse(allocator, "other: 1\n");
    defer missing.deinit();
    const violations = try with_null.validate(allocator, missing.root.?, "$");
    defer freeViolations(allocator, violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqualStrings("required", violations[0].rule);
}

test "allOf, anyOf and oneOf" {
    const allocator = testing.allocator;
    var doc = try document_mod.Document.parse(allocator, "n: 5\nbig: 500\nword: hello\n");
    defer doc.deinit();

    const in_low = Schema.intRange(0, 10);
    const in_high = Schema.intRange(5, 1000);

    const cases = [_]struct { key: []const u8, schema: Schema, want: usize, rule: []const u8 }{
        // allOf reports each failing branch, because each is a real
        // requirement: 500 is in [5,1000] but not in [0,10].
        .{ .key = "n", .schema = Schema.allOf(&.{ &in_low, &in_high }), .want = 0, .rule = "" },
        .{ .key = "big", .schema = Schema.allOf(&.{ &in_low, &in_high }), .want = 1, .rule = "range" },
        // anyOf: one branch is enough, and a total miss reports once
        // rather than once per branch.
        .{ .key = "big", .schema = Schema.anyOf(&.{ &in_low, &in_high }), .want = 0, .rule = "" },
        .{ .key = "word", .schema = Schema.anyOf(&.{ &in_low, &in_high }), .want = 1, .rule = "any_of" },
        // oneOf: 5 satisfies both ranges, which is one too many.
        .{ .key = "n", .schema = Schema.oneOf(&.{ &in_low, &in_high }), .want = 1, .rule = "one_of" },
        .{ .key = "big", .schema = Schema.oneOf(&.{ &in_low, &in_high }), .want = 0, .rule = "" },
        .{ .key = "word", .schema = Schema.oneOf(&.{ &in_low, &in_high }), .want = 1, .rule = "one_of" },
    };
    for (cases) |c| {
        const violations = try c.schema.validate(allocator, doc.pathGet(&.{c.key}).?, "$");
        defer freeViolations(allocator, violations);
        testing.expectEqual(c.want, violations.len) catch |err| {
            std.debug.print("key '{s}' produced {d} violations, wanted {d}\n", .{ c.key, violations.len, c.want });
            return err;
        };
        if (c.want > 0) try testing.expectEqualStrings(c.rule, violations[0].rule);
    }
}

test "validation is depth-bounded, on the document and on the schema" {
    const allocator = testing.allocator;
    const Document = document_mod.Document;

    // Recovered from the v0.12.0 audit (vast-wren, suspicion 2). Like
    // `value.convert`, validation recursed once per level with only the
    // node budget to stop it, and a linear chain is one node per level —
    // so the 1<<20 budget could not fire before the native stack gave
    // out. Reproduced on macOS arm64 against v0.14.0 with a
    // self-referential schema: 4,000 levels validated cleanly, 8,000
    // segfaulted.
    //
    // A schema that is its own item schema descends once per document
    // level, which is what makes the document's depth the binding one.
    var deep: Schema = undefined;
    deep = Schema.seq(&deep);

    {
        var doc = Document.init(allocator);
        defer doc.deinit();
        const root = try doc.createSequence();
        doc.root = root;
        var cur = root;
        var i: usize = 0;
        while (i < 1200) : (i += 1) {
            const child = try doc.createSequence();
            try doc.sequenceAppend(cur, child);
            cur = child;
        }

        try testing.expectError(error.NestingTooDeep, deep.validate(allocator, root, "$"));
    }

    // The default is a bound, not absent, and agrees with value's.
    try testing.expectEqual(@as(usize, 1000), (Limits{}).max_depth);

    // Ordinary documents are nowhere near it.
    {
        var doc = Document.init(allocator);
        defer doc.deinit();
        const root = try doc.createSequence();
        doc.root = root;
        var cur = root;
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            const child = try doc.createSequence();
            try doc.sequenceAppend(cur, child);
            cur = child;
        }
        const violations = try deep.validate(allocator, root, "$");
        defer allocator.free(violations);
        try testing.expectEqual(@as(usize, 0), violations.len);
    }

    // Composition re-enters on the same node, so a deeply composed
    // schema is bounded too — those frames are just as real as the ones
    // spent descending the document. A chain of `nullable` over a
    // non-null scalar recurses once per link.
    {
        var doc = try Document.parse(allocator, "x: 1\n");
        defer doc.deinit();
        const node = doc.pathGet(&.{"x"}).?;

        var chain: [40]Schema = undefined;
        chain[39] = Schema.any;
        var i: usize = 39;
        while (i > 0) : (i -= 1) chain[i - 1] = .{ .kind = .{ .nullable = &chain[i] } };

        try testing.expectError(
            error.NestingTooDeep,
            chain[0].validateLimited(allocator, node, "$.x", .{ .max_depth = 8 }),
        );

        // Under a bound that admits the whole chain it validates.
        const violations = try chain[0].validateLimited(allocator, node, "$.x", .{ .max_depth = 64 });
        defer allocator.free(violations);
        try testing.expectEqual(@as(usize, 0), violations.len);
    }
}

test "a composition branch cannot escape the node budget" {
    const allocator = testing.allocator;
    var doc = try document_mod.Document.parse(allocator, "s: [1, 2, 3, 4, 5]\n");
    defer doc.deinit();
    // Branch exploration shares the enclosing budget; without that, a
    // composite over N branches would multiply the work a bound was
    // meant to cap.
    const branch = Schema.seq(&Schema.int);
    const composite = Schema.anyOf(&.{ &branch, &branch, &branch });
    try testing.expectError(error.LimitExceeded, composite.validateLimited(
        allocator,
        doc.pathGet(&.{"s"}).?,
        "$",
        .{ .max_nodes = 8 },
    ));
}
