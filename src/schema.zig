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

pub const Error = error{ OutOfMemory, LimitExceeded };

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

    /// No bound. Only for input you produced yourself.
    pub const unlimited: Limits = .{ .max_nodes = std.math.maxInt(usize) };
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
        /// Sequence whose items must each match `items`.
        seq: *const Schema,
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

    /// A sequence whose items must each match `items`.
    pub fn seq(items: *const Schema) Schema {
        return .{ .kind = .{ .seq = items } };
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
        var remaining = limits.max_nodes;
        try checkSchema(self, allocator, node, path, &violations, &remaining);
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

fn checkNodeCoreTag(node: *const Node) ?document_mod.CoreTag {
    const s = node.scalarValue() orelse return null;
    return document_mod.resolveCoreTag(s, node.data.scalar.style);
}

fn checkSchema(schema: *const Schema, allocator: std.mem.Allocator, node: *const Node, path: []const u8, out: *std.ArrayList(Violation), remaining: *usize) Error!void {
    if (remaining.* == 0) return error.LimitExceeded;
    remaining.* -= 1;
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
        .seq => |items| {
            const list = cur.items() orelse return typeErr(allocator, path, "a sequence", out);
            for (list, 0..) |item, i| {
                const child_path = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, i });
                defer allocator.free(child_path);
                try checkSchema(items, allocator, item, child_path, out, remaining);
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
                        try checkSchema(field.schema, allocator, p.value, child_path, out, remaining);
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

    const s1 = Schema{ .kind = .{ .seq = &Schema.any } };
    const s2 = Schema{ .kind = .{ .seq = &s1 } };
    const s3 = Schema{ .kind = .{ .seq = &s2 } };

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
