//! Schema validation — PLAN-7.
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
//!     const violations = try schema.validate(alloc, node, "$");
//!     // violations carry path + rule; caller frees with freeViolations.
//!
//! Unknown mapping keys are allowed unless `deny_unknown` is set.
//! Validation never fails the document: failures are data.

const std = @import("std");
const document_mod = @import("document.zig");

const Node = document_mod.Node;

pub const Error = error{OutOfMemory};

pub const Schema = struct {
    kind: Kind,

    pub const Kind = union(enum) {
        any,
        str,
        bool_,
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
    pub const bool_ = Schema{ .kind = .bool_ };
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

    /// Validate `node`; returns the list of violations (empty when
    /// valid). `path` is the logical path reported in violations.
    pub fn validate(
        self: *const Schema,
        alloc: std.mem.Allocator,
        node: *const Node,
        path: []const u8,
    ) Error![]Violation {
        var violations: std.ArrayList(Violation) = .empty;
        errdefer {
            for (violations.items) |*v| v.deinitSelf(alloc);
            violations.deinit(alloc);
        }
        try checkSchema(self, alloc, node, path, &violations);
        return violations.toOwnedSlice(alloc);
    }
};

pub const Violation = struct {
    /// Logical path of the offending node, e.g. `$.server.port`.
    path: []const u8,
    /// Machine-readable rule name, e.g. "required", "type", "range".
    rule: []const u8,
    /// Human-readable detail.
    detail: []const u8,

    pub fn deinitSelf(self: *Violation, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        alloc.free(self.detail);
    }
};

pub fn freeViolations(alloc: std.mem.Allocator, violations: []Violation) void {
    for (violations) |v| {
        alloc.free(v.path);
        alloc.free(v.detail);
    }
    alloc.free(violations);
}

/// Append one violation, owning its path and detail strings: a
/// failure while building or appending releases the partial pair.
fn appendViolation(alloc: std.mem.Allocator, out: *std.ArrayList(Violation), path: []const u8, rule: []const u8, comptime fmt: []const u8, args: anytype) Error!void {
    const path_copy = try alloc.dupe(u8, path);
    errdefer alloc.free(path_copy);
    const detail = try std.fmt.allocPrint(alloc, fmt, args);
    errdefer alloc.free(detail);
    try out.append(alloc, .{ .path = path_copy, .rule = rule, .detail = detail });
}

fn typeErr(alloc: std.mem.Allocator, path: []const u8, want: []const u8, out: *std.ArrayList(Violation)) Error!void {
    return appendViolation(alloc, out, path, "type", "expected {s}", .{want});
}

fn checkNodeCoreTag(node: *const Node) ?document_mod.CoreTag {
    const s = node.scalarValue() orelse return null;
    return document_mod.resolveCoreTag(s, node.data.scalar.style);
}

fn checkSchema(schema: *const Schema, alloc: std.mem.Allocator, node: *const Node, path: []const u8, out: *std.ArrayList(Violation)) Error!void {
    const cur = node.resolveAlias();
    switch (schema.kind) {
        .any => {},
        .scalar => {
            if (!cur.isScalar()) try typeErr(alloc, path, "a scalar", out);
        },
        .str => {
            const s = cur.scalarValue() orelse return typeErr(alloc, path, "a string", out);
            if (document_mod.resolveCoreTag(s, cur.data.scalar.style) != .str) {
                try typeErr(alloc, path, "a string", out);
            }
        },
        .bool_ => {
            if (checkNodeCoreTag(cur) != .bool_) try typeErr(alloc, path, "a boolean", out);
        },
        .int => {
            if (checkNodeCoreTag(cur) != .int) try typeErr(alloc, path, "an integer", out);
        },
        .float => {
            const k = checkNodeCoreTag(cur);
            if (k != .float and k != .int) try typeErr(alloc, path, "a number", out);
        },
        .str_enum => |values| {
            const s = cur.scalarValue() orelse return typeErr(alloc, path, "a string", out);
            for (values) |v| {
                if (std.mem.eql(u8, v, s)) return;
            }
            try appendViolation(alloc, out, path, "enum", "'{s}' is not one of the allowed values", .{s});
        },
        .int_range => |r| {
            const k = checkNodeCoreTag(cur);
            if (k != .int) return typeErr(alloc, path, "an integer", out);
            const text = cur.scalarValue().?;
            const v = std.fmt.parseInt(i64, text, 0) catch {
                try typeErr(alloc, path, "an integer", out);
                return;
            };
            if (v < r.min or v > r.max) {
                try appendViolation(alloc, out, path, "range", "{d} is outside [{d}, {d}]", .{ v, r.min, r.max });
            }
        },
        .seq => |items| {
            const list = cur.items() orelse return typeErr(alloc, path, "a sequence", out);
            for (list, 0..) |item, i| {
                const child_path = try std.fmt.allocPrint(alloc, "{s}[{d}]", .{ path, i });
                defer alloc.free(child_path);
                try checkSchema(items, alloc, item, child_path, out);
            }
        },
        .map => |map_spec| {
            const fields = map_spec.fields;
            const pairs = cur.pairs() orelse return typeErr(alloc, path, "a mapping", out);
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
                    const child = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ path, field.key });
                    errdefer alloc.free(child);
                    const detail = try std.fmt.allocPrint(alloc, "required key '{s}' is missing", .{field.key});
                    errdefer alloc.free(detail);
                    try out.append(alloc, .{ .path = child, .rule = "required", .detail = detail });
                }
            }
            // Per-field and unknown-key checks.
            for (pairs) |p| {
                const kv = p.key.scalarValue() orelse continue;
                const child_path = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ path, kv });
                defer alloc.free(child_path);
                var matched = false;
                for (fields) |field| {
                    if (std.mem.eql(u8, field.key, kv)) {
                        try checkSchema(field.schema, alloc, p.value, child_path, out);
                        matched = true;
                        break;
                    }
                }
                if (!matched and map_spec.deny_unknown) {
                    try appendViolation(alloc, out, child_path, "unknown", "unknown key '{s}'", .{kv});
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
        .{ .key = "debug", .schema = &Schema.bool_ },
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

fn validateConfig(alloc: std.mem.Allocator) !void {
    const schema = Schema.map(&.{
        .{ .key = "name", .schema = &Schema.str, .required = true },
        .{ .key = "port", .schema = &Schema.intRange(1, 65535), .required = true },
        .{ .key = "tags", .schema = &Schema.seq(&Schema.str) },
    });
    var doc = try document_mod.Document.parse(alloc, "name: api\nport: 99999\ntags: [a, b]\n");
    defer doc.deinit();
    const violations = try schema.validate(alloc, doc.root.?, "$");
    defer freeViolations(alloc, violations);
    try testing.expectEqual(@as(usize, 1), violations.len);
}
