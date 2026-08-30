//! Generic value runtime — PLAN-6.
//!
//! A schema-free, tagged `Value` for data-oriented YAML work, with
//! conversions in both directions: `parseToValue` (text → Value),
//! `toNode` (Value → document tree), `nodeToValue` (tree → Value), and
//! Zig-native `fromZig`/`toZig` for structs, optionals, enums, slices
//! and scalars via comptime reflection.
//!
//! Ownership: functions returning `Value` allocate a complete owned
//! tree through the caller's allocator; release it with `freeValue`.
//! `toZig` results own their slice storage and are released with
//! `deinitZig`. `toNode` copies all retained data into the document pool.
//!
//! Plain scalar typing delegates to the library's YAML 1.2 core-schema
//! resolver (see `document.scalarKind`); quoted scalars remain strings.
//! Floats are represented as `f64`, so their exact source spelling is
//! not retained.

const std = @import("std");
const diag_mod = @import("diag.zig");
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

/// Conversion failures (`TypeMismatch`, `UnsupportedType`) and OOM,
/// plus the library's whole `YamlError` vocabulary: parse failures
/// keep their identity (bad UTF-8 input is `InvalidUtf8`, not a
/// generic syntax error).
pub const Error = error{ TypeMismatch, UnsupportedType, OutOfMemory } || diag_mod.YamlError;

/// Parse the first document of `input` into a Value. Parse failures
/// keep their real error (`InvalidUtf8`, `InvalidSyntax`, ...).
pub fn parseToValue(alloc: std.mem.Allocator, input: []const u8) Error!Value {
    var doc = try document_mod.Document.parse(alloc, input);
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
            var filled: usize = 0;
            errdefer {
                for (out[0..filled]) |item| freeValue(alloc, item);
                alloc.free(out);
            }
            for (sq.items.items, 0..) |item, i| {
                out[i] = try nodeToValue(alloc, item);
                filled = i + 1;
            }
            return .{ .list = out };
        },
        .mapping => |m| {
            var out = try alloc.alloc(Value.Member, m.pairs.items.len);
            var filled: usize = 0;
            errdefer {
                for (out[0..filled]) |memb| {
                    alloc.free(memb.key);
                    freeValue(alloc, memb.value);
                }
                alloc.free(out);
            }
            for (m.pairs.items, 0..) |p, i| {
                const k = p.key.resolveAlias();
                const key_copy = try alloc.dupe(u8, switch (k.data) {
                    .scalar => |s| s.value,
                    else => return error.TypeMismatch,
                });
                errdefer alloc.free(key_copy);
                out[i] = .{
                    .key = key_copy,
                    .value = try nodeToValue(alloc, p.value),
                };
                filled = i + 1;
            }
            return .{ .map = out };
        },
    }
}

/// Interpret a scalar's text under its style (core schema: only plain
/// scalars get typed).
pub fn scalarToValue(alloc: std.mem.Allocator, text: []const u8, style: ScalarStyle) Error!Value {
    if (style != .plain) return .{ .string = try alloc.dupe(u8, text) };
    switch (document_mod.scalarKind(text, .plain)) {
        .null_ => return .null_,
        .bool_ => return .{ .bool_ = text[0] == 't' or text[0] == 'T' },
        .int => {
            if (std.fmt.parseInt(i64, text, 0)) |i| return .{ .int = i } else |_| {}
            // Out-of-range integers keep their exact text.
            return .{ .bigint = try alloc.dupe(u8, text) };
        },
        .float => {
            if (document_mod.floatSpecial(text)) |f| return .{ .float = f };
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
            if (std.math.isNan(f)) return doc.createScalar(".nan", .plain);
            if (std.math.isPositiveInf(f)) return doc.createScalar(".inf", .plain);
            if (std.math.isNegativeInf(f)) return doc.createScalar("-.inf", .plain);
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
/// (by name), slices of T, arrays, and structs (by field name; missing
/// non-optional fields are `error.TypeMismatch`).
///
/// All slice storage in the returned value is owned by the caller,
/// including slice-valued struct defaults. Release it with `deinitZig`
/// using the same allocator.
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
                        const out = try alloc.alloc(ptr.child, items.len);
                        var filled: usize = 0;
                        errdefer {
                            for (out[0..filled]) |item| deinitZig(ptr.child, alloc, item);
                            alloc.free(out);
                        }
                        for (items, 0..) |item, i| {
                            out[i] = try toZig(ptr.child, alloc, item);
                            filled = i + 1;
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
                var filled: usize = 0;
                errdefer for (out[0..filled]) |item| deinitZig(arr.child, alloc, item);
                for (items, 0..) |item, i| {
                    out[i] = try toZig(arr.child, alloc, item);
                    filled = i + 1;
                }
                return out;
            },
            else => return error.TypeMismatch,
        },
        .@"struct" => switch (value) {
            .map => |members| return toZigStruct(T, alloc, members),
            else => return error.TypeMismatch,
        },
        else => return error.UnsupportedType,
    }
}

/// Release all allocations produced by `toZig(T, alloc, ...)`.
pub fn deinitZig(comptime T: type, alloc: std.mem.Allocator, value: T) void {
    switch (@typeInfo(T)) {
        .optional => |opt| if (value) |item| deinitZig(opt.child, alloc, item),
        .pointer => |ptr| {
            if (ptr.size != .slice) return;
            if (ptr.child != u8) {
                for (value) |item| deinitZig(ptr.child, alloc, item);
            }
            alloc.free(value);
        },
        .array => |arr| {
            for (value) |item| deinitZig(arr.child, alloc, item);
        },
        .@"struct" => |st| {
            inline for (st.fields) |field| {
                deinitZig(field.type, alloc, @field(value, field.name));
            }
        },
        else => {},
    }
}

/// Duplicate allocation-bearing Zig values so defaults returned by
/// `toZig` follow the same ownership rule as parsed fields.
fn cloneZig(comptime T: type, alloc: std.mem.Allocator, value: T) Error!T {
    switch (@typeInfo(T)) {
        .optional => |opt| {
            if (value) |item| return try cloneZig(opt.child, alloc, item);
            return null;
        },
        .pointer => |ptr| {
            if (ptr.size != .slice) return value;
            const out = try alloc.alloc(ptr.child, value.len);
            var filled: usize = 0;
            errdefer {
                for (out[0..filled]) |item| deinitZig(ptr.child, alloc, item);
                alloc.free(out);
            }
            for (value, 0..) |item, i| {
                out[i] = try cloneZig(ptr.child, alloc, item);
                filled = i + 1;
            }
            return out;
        },
        .array => |arr| {
            var out: T = undefined;
            var filled: usize = 0;
            errdefer for (out[0..filled]) |item| deinitZig(arr.child, alloc, item);
            for (value, 0..) |item, i| {
                out[i] = try cloneZig(arr.child, alloc, item);
                filled = i + 1;
            }
            return out;
        },
        .@"struct" => |st| {
            var out: T = undefined;
            var initialized = [_]bool{false} ** st.fields.len;
            errdefer {
                inline for (st.fields, 0..) |field, i| {
                    if (initialized[i]) deinitZig(field.type, alloc, @field(out, field.name));
                }
            }
            inline for (st.fields, 0..) |field, i| {
                @field(out, field.name) = try cloneZig(field.type, alloc, @field(value, field.name));
                initialized[i] = true;
            }
            return out;
        },
        else => return value,
    }
}

/// Struct arm of `toZig`: fields matched by name; defaults and
/// optionals honoured; a missing required field is `TypeMismatch`.
fn toZigStruct(comptime T: type, alloc: std.mem.Allocator, members: []const Value.Member) Error!T {
    const st = @typeInfo(T).@"struct";
    var out: T = undefined;
    var initialized = [_]bool{false} ** st.fields.len;
    errdefer {
        inline for (st.fields, 0..) |field, i| {
            if (initialized[i]) deinitZig(field.type, alloc, @field(out, field.name));
        }
    }

    inline for (st.fields, 0..) |field, i| {
        var found = false;
        for (members) |m| {
            if (std.mem.eql(u8, m.key, field.name)) {
                @field(out, field.name) = try toZig(field.type, alloc, m.value);
                initialized[i] = true;
                found = true;
                break;
            }
        }
        if (!found) {
            if (field.defaultValue()) |d| {
                @field(out, field.name) = try cloneZig(field.type, alloc, d);
            } else if (@typeInfo(field.type) == .optional) {
                @field(out, field.name) = null;
            } else {
                return error.TypeMismatch;
            }
            initialized[i] = true;
        }
    }
    return out;
}

/// Build a fully owned Value from a Zig value. Strings, enum names,
/// sequence items, member storage, and field names are duplicated through
/// `alloc`; release the result with `freeValue` using the same allocator.
pub fn fromZig(alloc: std.mem.Allocator, value: anytype) Error!Value {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    switch (info) {
        .bool => return .{ .bool_ = value },
        .int => return .{ .int = std.math.cast(i64, value) orelse return error.TypeMismatch },
        .comptime_int => return .{ .int = value },
        .float, .comptime_float => return .{ .float = @floatCast(value) },
        .optional => return if (value) |v| fromZig(alloc, v) else .null_,
        .@"enum" => return .{ .string = try alloc.dupe(u8, @tagName(value)) },
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                if (ptr.child == u8) return .{ .string = try alloc.dupe(u8, value) };
                const out = try alloc.alloc(Value, value.len);
                var filled: usize = 0;
                errdefer {
                    for (out[0..filled]) |item| freeValue(alloc, item);
                    alloc.free(out);
                }
                for (value, 0..) |item, i| {
                    out[i] = try fromZig(alloc, item);
                    filled = i + 1;
                }
                return .{ .list = out };
            }
            if (ptr.size == .one) return fromZig(alloc, value.*);
            return error.UnsupportedType;
        },
        .array => |arr| {
            const out = try alloc.alloc(Value, arr.len);
            var filled: usize = 0;
            errdefer {
                for (out[0..filled]) |item| freeValue(alloc, item);
                alloc.free(out);
            }
            for (value, 0..) |item, i| {
                out[i] = try fromZig(alloc, item);
                filled = i + 1;
            }
            return .{ .list = out };
        },
        .@"struct" => |st| {
            const members = try alloc.alloc(Value.Member, st.fields.len);
            var filled: usize = 0;
            errdefer {
                for (members[0..filled]) |m| {
                    alloc.free(m.key);
                    freeValue(alloc, m.value);
                }
                alloc.free(members);
            }
            inline for (st.fields, 0..) |field, i| {
                const key = try alloc.dupe(u8, field.name);
                errdefer alloc.free(key);
                members[i] = .{ .key = key, .value = try fromZig(alloc, @field(value, field.name)) };
                filled = i + 1;
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
    defer deinitZig(Config, testing.allocator, cfg);
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

test "fromZig owns strings, enum names, and slice elements" {
    const Mode = enum { fast, slow };
    const ports_storage = [_]u16{ 80, 443 };
    const Config = struct {
        name: []const u8,
        mode: Mode,
        ports: []const u16,
    };
    const input = Config{
        .name = "yayl",
        .mode = .fast,
        .ports = ports_storage[0..],
    };

    const v = try fromZig(testing.allocator, input);
    defer freeValue(testing.allocator, v);
    try testing.expectEqualStrings("yayl", v.get("name").?.string);
    try testing.expect(v.get("name").?.string.ptr != input.name.ptr);
    try testing.expectEqualStrings("fast", v.get("mode").?.string);
    try testing.expectEqual(@as(i64, 443), v.get("ports").?.at(1).?.int);
}

test "toZig owns nested allocations and cleans partial failures" {
    const Config = struct {
        names: []const []const u8,
        fallback: []const u8 = "fallback",
    };
    const good = try parseToValue(testing.allocator, "names: [one, two]\n");
    defer freeValue(testing.allocator, good);

    const cfg = try toZig(Config, testing.allocator, good);
    defer deinitZig(Config, testing.allocator, cfg);
    try testing.expectEqualStrings("two", cfg.names[1]);
    try testing.expectEqualStrings("fallback", cfg.fallback);

    const bad = try parseToValue(testing.allocator, "[one, 2]\n");
    defer freeValue(testing.allocator, bad);
    try testing.expectError(error.TypeMismatch, toZig([]const []const u8, testing.allocator, bad));
}

test "Value strings remain strings through document nodes" {
    const cases = [_][]const u8{ "42", "true", "0x1F", "null" };
    for (cases) |text| {
        var doc = Document.init(testing.allocator);
        defer doc.deinit();

        const node = try toNode(&doc, .{ .string = text });
        const back = try nodeToValue(testing.allocator, node);
        defer freeValue(testing.allocator, back);

        try testing.expect(back == .string);
        try testing.expectEqualStrings(text, back.string);
    }
}

test "bigint keeps exact text" {
    const v = try parseToValue(testing.allocator, "big: 99999999999999999999\n");
    defer freeValue(testing.allocator, v);
    const big = v.get("big").?;
    try testing.expect(big == .bigint);
    try testing.expectEqualStrings("99999999999999999999", big.bigint);
}

pub fn freeValue(alloc: std.mem.Allocator, v: Value) void {
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

test "parseToValue keeps the real parse error" {
    try testing.expectError(error.InvalidUtf8, parseToValue(testing.allocator, "a: \xff\xfe\n"));
    try testing.expectError(error.InvalidSyntax, parseToValue(testing.allocator, "a: b\n  c: d\n"));
}

test "allocation failures in Zig conversions leak nothing" {
    try std.testing.checkAllAllocationFailures(testing.allocator, zigConversions, .{});
}

fn zigConversions(alloc: std.mem.Allocator) !void {
    const source = try parseToValue(alloc, "names: [one, two]\n");
    defer freeValue(alloc, source);

    const Output = struct {
        names: []const []const u8,
        fallback: []const u8 = "fallback",
    };
    const output = try toZig(Output, alloc, source);
    defer deinitZig(Output, alloc, output);

    const Mode = enum { fast, slow };
    const names = [_][]const u8{ "api", "worker" };
    const Input = struct {
        names: []const []const u8,
        mode: Mode,
    };
    const value = try fromZig(alloc, Input{ .names = names[0..], .mode = .fast });
    defer freeValue(alloc, value);
}

test "allocation failures in value round trip leak nothing" {
    try std.testing.checkAllAllocationFailures(testing.allocator, valueRoundTrip, .{});
}

fn valueRoundTrip(alloc: std.mem.Allocator) !void {
    const v = try parseToValue(alloc,
        \\server:
        \\  ports: [80, 443]
        \\name: yayl
        \\pi: 3.14
        \\
    );
    defer freeValue(alloc, v);

    var doc = Document.init(alloc);
    defer doc.deinit();
    doc.root = try toNode(&doc, v);
    const back = try nodeToValue(alloc, doc.root.?);
    defer freeValue(alloc, back);

    // fromZig with a string field: the value must own its bytes for
    // freeValue to release them.
    const label = try alloc.dupe(u8, "hi");
    defer alloc.free(label);
    const Point = struct { x: i32, label: []const u8 };
    const vp = try fromZig(alloc, Point{ .x = 1, .label = label });
    defer freeValue(alloc, vp);
}
