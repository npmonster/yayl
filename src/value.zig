//! Generic value runtime — PLAN-6.
//!
//! A schema-free, tagged `Value` for data-oriented YAML work, with
//! conversions in both directions: `parseToValue` (text → Value),
//! `Value.toNode` (Value → document tree), `nodeToValue` (tree →
//! Value), and Zig-native `fromZig`/`toZig` for structs, optionals,
//! enums, slices and scalars via comptime reflection.
//!
//! Ownership: `toZig` allocates strings/slices through the caller's
//! allocator and they stay owned by the caller. `fromZig` copies into
//! the document pool when materializing nodes, never borrowing.
//!
//! Scalar typing follows the YAML 1.2 core schema (see
//! `document.scalarKind`); conversions never infer lossy types
//! silently — a quoted "1.0" is a string, and an int field fed
//! `1.0` is a conversion error.

const std = @import("std");
const document_mod = @import("document.zig");
const token_mod = @import("token.zig");

const Document = document_mod.Document;
const Node = document_mod.Node;
const ScalarStyle = token_mod.ScalarStyle;

/// A parsed, untyped YAML value.
pub const Value = union(enum) {
    null_,
    bool_: bool,
    int: i64,
    /// Integers beyond i64 keep their text (no silent loss).
    bigint: []const u8,
    float: f64,
    string: []const u8,
    list: []const Value,
    map: []const Member,

    pub const Member = struct { key: []const u8, value: Value };

    pub fn get(self: Value, key: []const u8) ?Value {
        if (self != .map) return null;
        for (self.map) |m| {
            if (std.mem.eql(u8, m.key, key)) return m.value;
        }
        return null;
    }

    pub fn at(self: Value, index: usize) ?Value {
        if (self != .list) return null;
        if (index >= self.list.len) return null;
        return self.list[index];
    }
};

pub const Error = error{
    TypeMismatch,
    UnsupportedType,
    OutOfMemory,
    /// Re-exported so callers can catch whole-parse failures uniformly.
    InvalidSyntax,
    InvalidUtf8,
};

/// Parse the first document of `input` into a Value.
pub fn parseToValue(alloc: std.mem.Allocator, input: []const u8) Error!Value {
    var doc = document_mod.Document.parse(alloc, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSyntax,
    };
    defer doc.deinit();
    const root = doc.root orelse return .null_;
    return nodeToValue(alloc, root);
}

/// Convert a document subtree into a Value. Strings are duplicated
/// into `alloc`; the tree is untouched.
pub fn nodeToValue(alloc: std.mem.Allocator, node: *const Node) Error!Value {
    const cur = node.resolveAlias();
    switch (cur.data) {
        .scalar => |s| return scalarToValue(alloc, s.value, s.style),
        .alias => unreachable, // resolveAlias never returns alias
        .sequence => |sq| {
            var out = try alloc.alloc(Value, sq.items.items.len);
            for (sq.items.items, 0..) |item, i| {
                out[i] = try nodeToValue(alloc, item);
            }
            return .{ .list = out };
        },
        .mapping => |m| {
            var out = try alloc.alloc(Value.Member, m.pairs.items.len);
            for (m.pairs.items, 0..) |p, i| {
                const k = p.key.resolveAlias();
                out[i] = .{
                    .key = switch (k.data) {
                        .scalar => |s| try alloc.dupe(u8, s.value),
                        else => return error.TypeMismatch,
                    },
                    .value = try nodeToValue(alloc, p.value),
                };
            }
            return .{ .map = out };
        },
    }
}

/// Interpret a scalar's text under its style (core schema: only plain
/// scalars get typed).
pub fn scalarToValue(alloc: std.mem.Allocator, text: []const u8, style: ScalarStyle) Error!Value {
    if (style != .plain and style != .any) return .{ .string = try alloc.dupe(u8, text) };
    switch (document_mod.scalarKind(text, .plain)) {
        .null_ => return .null_,
        .bool_ => return .{ .bool_ = text[0] == 't' or text[0] == 'T' },
        .int => {
            if (std.fmt.parseInt(i64, text, 0)) |i| return .{ .int = i } else |_| {}
            // Out-of-range integers keep their exact text.
            return .{ .bigint = try alloc.dupe(u8, text) };
        },
        .float => {
            const f = std.fmt.parseFloat(f64, text) catch
                return .{ .string = try alloc.dupe(u8, text) };
            return .{ .float = f };
        },
        .str => return .{ .string = try alloc.dupe(u8, text) },
    }
}

/// Materialize a Value as a document tree node (owned by `doc`).
pub fn toNode(doc: *Document, value: Value) Error!*Node {
    switch (value) {
        .null_ => return doc.createScalar("", .plain),
        .bool_ => |b| return doc.createScalar(if (b) "true" else "false", .plain),
        .int => |i| {
            var buf: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
            return doc.createScalar(text, .plain);
        },
        .bigint => |t| return doc.createScalar(t, .plain),
        .float => |f| {
            var buf: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
            return doc.createScalar(text, .plain);
        },
        .string => |s| return doc.createScalar(s, .any),
        .list => |items| {
            const seq = try doc.createSequence();
            for (items) |item| {
                try doc.sequenceAppend(seq, try toNode(doc, item));
            }
            return seq;
        },
        .map => |members| {
            const map = try doc.createMapping();
            for (members) |m| {
                try doc.mappingAppend(map, try doc.createScalar(m.key, .any), try toNode(doc, m.value));
            }
            return map;
        },
    }
}

// ----------------------------------------------------------------------
// Zig-native conversion
// ----------------------------------------------------------------------

/// Convert a Value into a Zig value of type `T`, allocating through
/// `alloc`. Supported: bool, all int/float widths, `?T`, enums
/// (by name), slices of T, and structs (by field name; missing
/// non-optional fields are `error.TypeMismatch`).
pub fn toZig(comptime T: type, alloc: std.mem.Allocator, value: Value) Error!T {
    const info = @typeInfo(T);
    switch (info) {
        .bool => switch (value) {
            .bool_ => |b| return b,
            else => return error.TypeMismatch,
        },
        .int => switch (value) {
            .int => |i| return std.math.cast(T, i) orelse error.TypeMismatch,
            .bigint => |t| {
                const parsed = std.fmt.parseInt(T, t, 0) catch return error.TypeMismatch;
                return parsed;
            },
            else => return error.TypeMismatch,
        },
        .float => switch (value) {
            .int => |i| return @floatFromInt(i),
            .float => |f| return @floatCast(f),
            else => return error.TypeMismatch,
        },
        .optional => |opt| {
            if (value == .null_) return null;
            return try toZig(opt.child, alloc, value);
        },
        .@"enum" => |en| switch (value) {
            .string => |s| {
                inline for (en.fields) |field| {
                    if (std.mem.eql(u8, field.name, s)) {
                        return @enumFromInt(field.value);
                    }
                }
                return error.TypeMismatch;
            },
            else => return error.TypeMismatch,
        },
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                if (ptr.child == u8) {
                    switch (value) {
                        .string => |s| return try alloc.dupe(u8, s),
                        else => return error.TypeMismatch,
                    }
                }
                switch (value) {
                    .list => |items| {
                        var out = try alloc.alloc(ptr.child, items.len);
                        for (items, 0..) |item, i| {
                            out[i] = try toZig(ptr.child, alloc, item);
                        }
                        return out;
                    },
                    else => return error.TypeMismatch,
                }
            }
            return error.UnsupportedType;
        },
        .array => |arr| switch (value) {
            .list => |items| {
                if (items.len != arr.len) return error.TypeMismatch;
                var out: T = undefined;
                for (items, 0..) |item, i| {
                    out[i] = try toZig(arr.child, alloc, item);
                }
                return out;
            },
            else => return error.TypeMismatch,
        },
        .@"struct" => |st| switch (value) {
            .map => |members| {
                var out: T = undefined;
                inline for (st.fields) |field| {
                    var found = false;
                    for (members) |m| {
                        if (std.mem.eql(u8, m.key, field.name)) {
                            @field(out, field.name) = try toZig(field.type, alloc, m.value);
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        if (field.defaultValue()) |d| {
                            @field(out, field.name) = d;
                        } else if (@typeInfo(field.type) == .optional) {
                            @field(out, field.name) = null;
                        } else {
                            return error.TypeMismatch;
                        }
                    }
                }
                return out;
            },
            else => return error.TypeMismatch,
        },
        else => return error.UnsupportedType,
    }
}

/// Build a Value from a Zig value. Everything needed for later
/// `freeValue` (member storage, struct field names) is allocated
/// through `alloc`; string VALUES are still borrowed from the input
/// (dupe them first when the backing memory is transient).
pub fn fromZig(alloc: std.mem.Allocator, value: anytype) Error!Value {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    switch (info) {
        .bool => return .{ .bool_ = value },
        .int => return .{ .int = std.math.cast(i64, value) orelse return error.TypeMismatch },
        .comptime_int => return .{ .int = value },
        .float, .comptime_float => return .{ .float = @floatCast(value) },
        .optional => return if (value) |v| fromZig(alloc, v) else .null_,
        .@"enum" => return .{ .string = @tagName(value) },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return .{ .string = value };
            if (ptr.size == .one) return fromZig(alloc, value.*);
            return error.UnsupportedType;
        },
        .array => |arr| {
            const out = try alloc.alloc(Value, arr.len);
            for (value, 0..) |item, i| out[i] = try fromZig(alloc, item);
            return .{ .list = out };
        },
        .@"struct" => |st| {
            const members = try alloc.alloc(Value.Member, st.fields.len);
            inline for (st.fields, 0..) |field, i| {
                members[i] = .{ .key = try alloc.dupe(u8, field.name), .value = try fromZig(alloc, @field(value, field.name)) };
            }
            return .{ .map = members };
        },
        .null => return .null_,
        else => return error.UnsupportedType,
    }
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

test "parse to value and inspect" {
    const v = try parseToValue(testing.allocator,
        \\name: yayl
        \\count: 3
        \\ratio: 2.5
        \\enabled: true
        \\tags: [a, b]
        \\note: "42"
        \\missing: ~
        \\
    );
    defer freeValue(testing.allocator, v);
    try testing.expectEqualStrings("yayl", v.get("name").?.string);
    try testing.expectEqual(@as(i64, 3), v.get("count").?.int);
    try testing.expectEqual(@as(f64, 2.5), v.get("ratio").?.float);
    try testing.expect(v.get("enabled").?.bool_);
    try testing.expectEqual(@as(usize, 2), v.get("tags").?.list.len);
    // Quoted "42" stays a string: no silent type inference.
    try testing.expectEqualStrings("42", v.get("note").?.string);
    try testing.expect(v.get("missing").? == .null_);
}

test "value round trip through the document model" {
    const v = try parseToValue(testing.allocator,
        \\server:
        \\  ports: [80, 443]
        \\
    );
    defer freeValue(testing.allocator, v);

    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    const root = try toNode(&doc, v);
    doc.root = root;
    try testing.expectEqualStrings("80", root.lookup("server").?.lookup("ports").?.items().?[0].scalarValue().?);

    const back = try nodeToValue(testing.allocator, root);
    defer freeValue(testing.allocator, back);
    try testing.expectEqual(@as(i64, 443), back.get("server").?.get("ports").?.at(1).?.int);
}

test "zig struct conversion" {
    const Config = struct {
        name: []const u8,
        replicas: u8 = 1,
        enabled: bool,
        ratio: ?f64 = null,
        mode: enum { fast, slow },
    };
    const v = try parseToValue(testing.allocator,
        \\name: api
        \\enabled: false
        \\mode: fast
        \\
    );
    defer freeValue(testing.allocator, v);

    const cfg = try toZig(Config, testing.allocator, v);
    defer testing.allocator.free(cfg.name);
    try testing.expectEqualStrings("api", cfg.name);
    try testing.expectEqual(@as(u8, 1), cfg.replicas); // default applied
    try testing.expect(!cfg.enabled);
    try testing.expect(cfg.ratio == null);
    try testing.expectEqual(.fast, cfg.mode);

    // Type errors are loud: a string into a bool field.
    const bad = try parseToValue(testing.allocator, "enabled: notabool\n");
    defer freeValue(testing.allocator, bad);
    try testing.expectError(error.TypeMismatch, toZig(Config, testing.allocator, bad));
}

test "fromZig builds values and nodes" {
    const Point = struct { x: i32, y: i32 };
    const p = Point{ .x = 1, .y = -2 };
    const v = try fromZig(testing.allocator, p);
    try testing.expectEqual(@as(i64, -2), v.get("y").?.int);
    defer freeValue(testing.allocator, v);

    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    doc.root = try toNode(&doc, v);
    const out = try doc.write(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("x: 1\ny: -2\n", out);
    // The materialized node re-parses to the same value.
    const back = try parseToValue(testing.allocator, out);
    defer freeValue(testing.allocator, back);
    try testing.expectEqual(@as(i64, 1), back.get("x").?.int);
}

test "bigint keeps exact text" {
    const v = try parseToValue(testing.allocator, "big: 99999999999999999999\n");
    defer freeValue(testing.allocator, v);
    const big = v.get("big").?;
    try testing.expect(big == .bigint);
    try testing.expectEqualStrings("99999999999999999999", big.bigint);
}

fn freeValue(alloc: std.mem.Allocator, v: Value) void {
    switch (v) {
        .string => |s| alloc.free(s),
        .bigint => |s| alloc.free(s),
        .list => |items| {
            for (items) |item| freeValue(alloc, item);
            alloc.free(items);
        },
        .map => |members| {
            for (members) |m| {
                alloc.free(m.key);
                freeValue(alloc, m.value);
            }
            alloc.free(members);
        },
        else => {},
    }
}
