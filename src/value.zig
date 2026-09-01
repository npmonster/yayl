//! Generic value runtime.
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
//! resolver (see `document.resolveCoreTag`); quoted scalars remain strings.
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
    null,
    bool: bool,
    int: i64,
    /// Integers beyond i64 keep their text (no silent loss).
    bigint: []const u8,
    float: f64,
    string: []const u8,
    /// Spelled as the node model spells it: the spec's node kinds are
    /// scalar, sequence and mapping (3.2.1.1).
    sequence: []const Value,
    mapping: []const Pair,

    /// One key/value pair of a mapping (spec 3.2.1.1).
    pub const Pair = struct { key: []const u8, value: Value };

    pub fn get(self: Value, key: []const u8) ?Value {
        if (self != .mapping) return null;
        for (self.mapping) |m| {
            if (std.mem.eql(u8, m.key, key)) return m.value;
        }
        return null;
    }

    pub fn at(self: Value, index: usize) ?Value {
        if (self != .sequence) return null;
        if (index >= self.sequence.len) return null;
        return self.sequence[index];
    }
};

/// Conversion failures (`TypeMismatch`, `UnsupportedType`) and OOM,
/// plus the library's whole `YamlError` vocabulary: parse failures
/// keep their identity (bad UTF-8 input is `InvalidUtf8`, not a
/// generic syntax error).
pub const Error = error{ TypeMismatch, UnsupportedType, OutOfMemory, LimitExceeded } || diag_mod.YamlError;

/// Bounds on how much one conversion may materialise.
///
/// Conversion expands aliases by copying, so output size is not bounded
/// by input size: a document of N nesting levels that each alias the
/// level above M times converts to M^N values. 194 bytes reaches ~19.5k
/// values at 6x5; 10x10 is 10^10. The parse and document layers are not
/// affected — an alias stays a single node there, and nesting is capped
/// at 200 — so this bound exists only where the copying happens.
pub const Limits = struct {
    /// Maximum Values one conversion may produce, counting every scalar,
    /// sequence slot and mapping entry. Conversion stops with
    /// `error.LimitExceeded` on the value that would exceed it.
    max_values: usize = 1 << 20,

    /// No bound. Only for input you produced yourself.
    pub const unlimited: Limits = .{ .max_values = std.math.maxInt(usize) };
};

/// Parse the first document of `input` into a Value, under the default
/// `Limits`. Parse failures keep their real error (`InvalidUtf8`,
/// `InvalidSyntax`, ...).
pub fn parseToValue(allocator: std.mem.Allocator, input: []const u8) Error!Value {
    return parseToValueLimited(allocator, input, .{});
}

/// `parseToValue` with an explicit expansion bound.
pub fn parseToValueLimited(allocator: std.mem.Allocator, input: []const u8, limits: Limits) Error!Value {
    var doc = try document_mod.Document.parse(allocator, input);
    defer doc.deinit();
    const root = doc.root orelse return .null;
    return nodeToValueLimited(allocator, root, limits);
}

/// Convert a document subtree into a Value under the default `Limits`.
/// Strings are duplicated into `allocator`; the tree is untouched.
pub fn nodeToValue(allocator: std.mem.Allocator, node: *const Node) Error!Value {
    return nodeToValueLimited(allocator, node, .{});
}

/// `nodeToValue` with an explicit expansion bound. Pass
/// `Limits.unlimited` only for input you produced yourself.
pub fn nodeToValueLimited(allocator: std.mem.Allocator, node: *const Node, limits: Limits) Error!Value {
    var remaining = limits.max_values;
    return convert(allocator, node, &remaining);
}

/// One unit of budget per Value produced. Charged on entry, so the
/// error fires on the value that would exceed the bound rather than
/// after the allocation for it.
fn charge(remaining: *usize) Error!void {
    if (remaining.* == 0) return error.LimitExceeded;
    remaining.* -= 1;
}

fn convert(allocator: std.mem.Allocator, node: *const Node, remaining: *usize) Error!Value {
    try charge(remaining);
    const cur = node.resolveAlias();
    switch (cur.data) {
        .scalar => |s| return scalarToValue(allocator, s.value, s.style),
        .alias => unreachable, // resolveAlias never returns alias
        .sequence => |sq| {
            var out = try allocator.alloc(Value, sq.items.items.len);
            var filled: usize = 0;
            errdefer {
                for (out[0..filled]) |item| freeValue(allocator, item);
                allocator.free(out);
            }
            for (sq.items.items, 0..) |item, i| {
                out[i] = try convert(allocator, item, remaining);
                filled = i + 1;
            }
            return .{ .sequence = out };
        },
        .mapping => |m| {
            var out = try allocator.alloc(Value.Pair, m.pairs.items.len);
            var filled: usize = 0;
            errdefer {
                for (out[0..filled]) |memb| {
                    allocator.free(memb.key);
                    freeValue(allocator, memb.value);
                }
                allocator.free(out);
            }
            for (m.pairs.items, 0..) |p, i| {
                const k = p.key.resolveAlias();
                const key_copy = try allocator.dupe(u8, switch (k.data) {
                    .scalar => |s| s.value,
                    else => return error.TypeMismatch,
                });
                errdefer allocator.free(key_copy);
                out[i] = .{
                    .key = key_copy,
                    .value = try convert(allocator, p.value, remaining),
                };
                filled = i + 1;
            }
            return .{ .mapping = out };
        },
    }
}

/// Interpret a scalar's text under its style (core schema: only plain
/// scalars get typed).
pub fn scalarToValue(allocator: std.mem.Allocator, text: []const u8, style: ScalarStyle) Error!Value {
    if (style != .plain) return .{ .string = try allocator.dupe(u8, text) };
    switch (document_mod.resolveCoreTag(text, .plain)) {
        .null => return .null,
        .bool => return .{ .bool = text[0] == 't' or text[0] == 'T' },
        .int => {
            if (std.fmt.parseInt(i64, text, 0)) |i| return .{ .int = i } else |_| {}
            // Out-of-range integers keep their exact text.
            return .{ .bigint = try allocator.dupe(u8, text) };
        },
        .float => {
            if (document_mod.floatSpecial(text)) |f| return .{ .float = f };
            const f = std.fmt.parseFloat(f64, text) catch
                return .{ .string = try allocator.dupe(u8, text) };
            return .{ .float = f };
        },
        .str => return .{ .string = try allocator.dupe(u8, text) },
    }
}

/// Materialize a Value as a document tree node (owned by `doc`).
pub fn toNode(doc: *Document, value: Value) Error!*Node {
    switch (value) {
        .null => return doc.createScalar("", .plain),
        .bool => |b| return doc.createScalar(if (b) "true" else "false", .plain),
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
        .sequence => |items| {
            const seq = try doc.createSequence();
            for (items) |item| {
                try doc.sequenceAppend(seq, try toNode(doc, item));
            }
            return seq;
        },
        .mapping => |members| {
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

/// The value type of a string-keyed std map, or null for anything else.
///
/// A YAML mapping with keys known only at runtime — a `labels:` block, a
/// `matrix:` of arbitrary names — has no struct to convert into, and
/// before this it had no typed path at all. Recognized by shape rather
/// than by name so all four std spellings work:
/// `StringHashMap`, `StringHashMapUnmanaged`, `StringArrayHashMap` and
/// `StringArrayHashMapUnmanaged`. The array variants keep insertion
/// order, which is usually what you want for YAML.
fn StringMapValue(comptime T: type) ?type {
    if (@typeInfo(T) != .@"struct") return null;
    if (!@hasDecl(T, "KV")) return null;
    const kv = @typeInfo(T.KV);
    if (kv != .@"struct") return null;
    var value_type: ?type = null;
    inline for (kv.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "key")) {
            if (field.type != []const u8) return null;
        } else if (std.mem.eql(u8, field.name, "value")) {
            value_type = field.type;
        } else return null;
    }
    return value_type;
}

/// Managed maps carry their allocator; unmanaged ones take it per call.
fn mapIsManaged(comptime T: type) bool {
    return @hasField(T, "allocator");
}

fn emptyMap(comptime T: type, allocator: std.mem.Allocator) T {
    return if (comptime mapIsManaged(T)) T.init(allocator) else .empty;
}

fn mapPut(comptime T: type, map: *T, allocator: std.mem.Allocator, key: []const u8, value: anytype) Error!void {
    if (comptime mapIsManaged(T)) return map.put(key, value);
    return map.put(allocator, key, value);
}

/// Release a converted map: every duplicated key, every converted
/// value, then the map's own storage.
fn deinitStringMap(comptime T: type, allocator: std.mem.Allocator, map: *T) void {
    const V = comptime StringMapValue(T).?;
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        deinitZig(V, allocator, entry.value_ptr.*);
    }
    if (comptime mapIsManaged(T)) map.deinit() else map.deinit(allocator);
}

/// Convert a Value into a Zig value of type `T`, allocating through
/// `allocator`. Supported: bool, all int/float widths, `?T`, enums
/// (by name), slices of T, arrays, and structs (by field name; missing
/// non-optional fields are `error.TypeMismatch`).
///
/// All slice storage in the returned value is owned by the caller,
/// including slice-valued struct defaults. Release it with `deinitZig`
/// using the same allocator.
pub fn toZig(comptime T: type, allocator: std.mem.Allocator, value: Value) Error!T {
    const info = @typeInfo(T);
    switch (info) {
        .bool => switch (value) {
            .bool => |b| return b,
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
            if (value == .null) return null;
            return try toZig(opt.child, allocator, value);
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
                        .string => |s| return try allocator.dupe(u8, s),
                        else => return error.TypeMismatch,
                    }
                }
                switch (value) {
                    .sequence => |items| {
                        const out = try allocator.alloc(ptr.child, items.len);
                        var filled: usize = 0;
                        errdefer {
                            for (out[0..filled]) |item| deinitZig(ptr.child, allocator, item);
                            allocator.free(out);
                        }
                        for (items, 0..) |item, i| {
                            out[i] = try toZig(ptr.child, allocator, item);
                            filled = i + 1;
                        }
                        return out;
                    },
                    else => return error.TypeMismatch,
                }
            }
            if (ptr.size == .one) {
                // Symmetry with `fromZig`, which already serialized a
                // `*T` by dereferencing it.
                const out = try allocator.create(ptr.child);
                errdefer allocator.destroy(out);
                out.* = try toZig(ptr.child, allocator, value);
                return out;
            }
            return error.UnsupportedType;
        },
        .@"union" => |un| {
            if (un.tag_type == null) return error.UnsupportedType;
            // Externally tagged, as JSON does it: exactly one entry,
            // whose key is the active field's name.
            const members = switch (value) {
                .mapping => |m| m,
                else => return error.TypeMismatch,
            };
            if (members.len != 1) return error.TypeMismatch;
            inline for (un.fields) |field| {
                if (std.mem.eql(u8, field.name, members[0].key)) {
                    if (field.type == void) return @unionInit(T, field.name, {});
                    return @unionInit(T, field.name, try toZig(field.type, allocator, members[0].value));
                }
            }
            return error.TypeMismatch;
        },
        .array => |arr| switch (value) {
            .sequence => |items| {
                if (items.len != arr.len) return error.TypeMismatch;
                var out: T = undefined;
                var filled: usize = 0;
                errdefer for (out[0..filled]) |item| deinitZig(arr.child, allocator, item);
                for (items, 0..) |item, i| {
                    out[i] = try toZig(arr.child, allocator, item);
                    filled = i + 1;
                }
                return out;
            },
            else => return error.TypeMismatch,
        },
        .@"struct" => switch (value) {
            .mapping => |members| {
                if (comptime StringMapValue(T)) |V| {
                    var map = emptyMap(T, allocator);
                    errdefer deinitStringMap(T, allocator, &map);
                    for (members) |m| {
                        // First key wins, matching `Node.lookup`. YAML
                        // permits duplicates and this library keeps
                        // them, so a map has to choose; silently
                        // preferring the last would disagree with every
                        // other read path.
                        if (map.contains(m.key)) continue;
                        const key = try allocator.dupe(u8, m.key);
                        errdefer allocator.free(key);
                        const converted = try toZig(V, allocator, m.value);
                        errdefer deinitZig(V, allocator, converted);
                        try mapPut(T, &map, allocator, key, converted);
                    }
                    return map;
                }
                return toZigStruct(T, allocator, members);
            },
            else => return error.TypeMismatch,
        },
        else => return error.UnsupportedType,
    }
}

/// Release all allocations produced by `toZig(T, allocator, ...)`.
pub fn deinitZig(comptime T: type, allocator: std.mem.Allocator, value: T) void {
    switch (@typeInfo(T)) {
        .optional => |opt| if (value) |item| deinitZig(opt.child, allocator, item),
        .pointer => |ptr| {
            if (ptr.size == .one) {
                deinitZig(ptr.child, allocator, value.*);
                allocator.destroy(value);
                return;
            }
            if (ptr.size != .slice) return;
            if (ptr.child != u8) {
                for (value) |item| deinitZig(ptr.child, allocator, item);
            }
            allocator.free(value);
        },
        .array => |arr| {
            for (value) |item| deinitZig(arr.child, allocator, item);
        },
        .@"union" => |un| {
            if (un.tag_type == null) return;
            inline for (un.fields) |field| {
                if (value == @field(std.meta.Tag(T), field.name)) {
                    return deinitZig(field.type, allocator, @field(value, field.name));
                }
            }
        },
        .@"struct" => |st| {
            if (comptime StringMapValue(T) != null) {
                var copy = value;
                deinitStringMap(T, allocator, &copy);
                return;
            }
            inline for (st.fields) |field| {
                deinitZig(field.type, allocator, @field(value, field.name));
            }
        },
        else => {},
    }
}

/// Duplicate allocation-bearing Zig values so defaults returned by
/// `toZig` follow the same ownership rule as parsed fields.
fn cloneZig(comptime T: type, allocator: std.mem.Allocator, value: T) Error!T {
    switch (@typeInfo(T)) {
        .optional => |opt| {
            if (value) |item| return try cloneZig(opt.child, allocator, item);
            return null;
        },
        .pointer => |ptr| {
            if (ptr.size == .one) {
                const out = try allocator.create(ptr.child);
                errdefer allocator.destroy(out);
                out.* = try cloneZig(ptr.child, allocator, value.*);
                return out;
            }
            if (ptr.size != .slice) return value;
            const out = try allocator.alloc(ptr.child, value.len);
            var filled: usize = 0;
            errdefer {
                for (out[0..filled]) |item| deinitZig(ptr.child, allocator, item);
                allocator.free(out);
            }
            for (value, 0..) |item, i| {
                out[i] = try cloneZig(ptr.child, allocator, item);
                filled = i + 1;
            }
            return out;
        },
        .array => |arr| {
            var out: T = undefined;
            var filled: usize = 0;
            errdefer for (out[0..filled]) |item| deinitZig(arr.child, allocator, item);
            for (value, 0..) |item, i| {
                out[i] = try cloneZig(arr.child, allocator, item);
                filled = i + 1;
            }
            return out;
        },
        .@"union" => |un| {
            if (un.tag_type == null) return value;
            inline for (un.fields) |field| {
                if (value == @field(std.meta.Tag(T), field.name)) {
                    if (field.type == void) return value;
                    return @unionInit(T, field.name, try cloneZig(field.type, allocator, @field(value, field.name)));
                }
            }
            return value;
        },
        .@"struct" => |st| {
            if (comptime StringMapValue(T)) |V| {
                var out = emptyMap(T, allocator);
                errdefer deinitStringMap(T, allocator, &out);
                var it = value.iterator();
                while (it.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(key);
                    const cloned = try cloneZig(V, allocator, entry.value_ptr.*);
                    errdefer deinitZig(V, allocator, cloned);
                    try mapPut(T, &out, allocator, key, cloned);
                }
                return out;
            }
            var out: T = undefined;
            var initialized = [_]bool{false} ** st.fields.len;
            errdefer {
                inline for (st.fields, 0..) |field, i| {
                    if (initialized[i]) deinitZig(field.type, allocator, @field(out, field.name));
                }
            }
            inline for (st.fields, 0..) |field, i| {
                @field(out, field.name) = try cloneZig(field.type, allocator, @field(value, field.name));
                initialized[i] = true;
            }
            return out;
        },
        else => return value,
    }
}

/// Struct arm of `toZig`: fields matched by name; defaults and
/// optionals honored; a missing required field is `TypeMismatch`.
fn toZigStruct(comptime T: type, allocator: std.mem.Allocator, members: []const Value.Pair) Error!T {
    const st = @typeInfo(T).@"struct";
    var out: T = undefined;
    var initialized = [_]bool{false} ** st.fields.len;
    errdefer {
        inline for (st.fields, 0..) |field, i| {
            if (initialized[i]) deinitZig(field.type, allocator, @field(out, field.name));
        }
    }

    inline for (st.fields, 0..) |field, i| {
        var found = false;
        for (members) |m| {
            if (std.mem.eql(u8, m.key, field.name)) {
                @field(out, field.name) = try toZig(field.type, allocator, m.value);
                initialized[i] = true;
                found = true;
                break;
            }
        }
        if (!found) {
            if (field.defaultValue()) |d| {
                @field(out, field.name) = try cloneZig(field.type, allocator, d);
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
/// `allocator`; release the result with `freeValue` using the same allocator.
pub fn fromZig(allocator: std.mem.Allocator, value: anytype) Error!Value {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    switch (info) {
        .bool => return .{ .bool = value },
        .int => return .{ .int = std.math.cast(i64, value) orelse return error.TypeMismatch },
        .comptime_int => return .{ .int = value },
        .float, .comptime_float => return .{ .float = @floatCast(value) },
        .optional => return if (value) |v| fromZig(allocator, v) else .null,
        .@"enum" => return .{ .string = try allocator.dupe(u8, @tagName(value)) },
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                if (ptr.child == u8) return .{ .string = try allocator.dupe(u8, value) };
                const out = try allocator.alloc(Value, value.len);
                var filled: usize = 0;
                errdefer {
                    for (out[0..filled]) |item| freeValue(allocator, item);
                    allocator.free(out);
                }
                for (value, 0..) |item, i| {
                    out[i] = try fromZig(allocator, item);
                    filled = i + 1;
                }
                return .{ .sequence = out };
            }
            if (ptr.size == .one) return fromZig(allocator, value.*);
            return error.UnsupportedType;
        },
        .array => |arr| {
            const out = try allocator.alloc(Value, arr.len);
            var filled: usize = 0;
            errdefer {
                for (out[0..filled]) |item| freeValue(allocator, item);
                allocator.free(out);
            }
            for (value, 0..) |item, i| {
                out[i] = try fromZig(allocator, item);
                filled = i + 1;
            }
            return .{ .sequence = out };
        },
        .@"union" => |un| {
            if (un.tag_type == null) return error.UnsupportedType;
            // Externally tagged: one entry keyed by the active field.
            const members = try allocator.alloc(Value.Pair, 1);
            errdefer allocator.free(members);
            inline for (un.fields) |field| {
                if (value == @field(std.meta.Tag(T), field.name)) {
                    const key = try allocator.dupe(u8, field.name);
                    errdefer allocator.free(key);
                    const inner: Value = if (field.type == void)
                        .null
                    else
                        try fromZig(allocator, @field(value, field.name));
                    members[0] = .{ .key = key, .value = inner };
                    return .{ .mapping = members };
                }
            }
            unreachable; // a tagged union is always one of its fields
        },
        .@"struct" => |st| {
            if (comptime StringMapValue(T) != null) {
                const members = try allocator.alloc(Value.Pair, value.count());
                var filled: usize = 0;
                errdefer {
                    for (members[0..filled]) |m| {
                        allocator.free(m.key);
                        freeValue(allocator, m.value);
                    }
                    allocator.free(members);
                }
                var it = value.iterator();
                while (it.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(key);
                    members[filled] = .{ .key = key, .value = try fromZig(allocator, entry.value_ptr.*) };
                    filled += 1;
                }
                return .{ .mapping = members };
            }
            const members = try allocator.alloc(Value.Pair, st.fields.len);
            var filled: usize = 0;
            errdefer {
                for (members[0..filled]) |m| {
                    allocator.free(m.key);
                    freeValue(allocator, m.value);
                }
                allocator.free(members);
            }
            inline for (st.fields, 0..) |field, i| {
                const key = try allocator.dupe(u8, field.name);
                errdefer allocator.free(key);
                members[i] = .{ .key = key, .value = try fromZig(allocator, @field(value, field.name)) };
                filled = i + 1;
            }
            return .{ .mapping = members };
        },
        .null => return .null,
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
    try testing.expect(v.get("enabled").?.bool);
    try testing.expectEqual(@as(usize, 2), v.get("tags").?.sequence.len);
    // Quoted "42" stays a string: no silent type inference.
    try testing.expectEqualStrings("42", v.get("note").?.string);
    try testing.expect(v.get("missing").? == .null);
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

pub fn freeValue(allocator: std.mem.Allocator, v: Value) void {
    switch (v) {
        .string => |s| allocator.free(s),
        .bigint => |s| allocator.free(s),
        .sequence => |items| {
            for (items) |item| freeValue(allocator, item);
            allocator.free(items);
        },
        .mapping => |members| {
            for (members) |m| {
                allocator.free(m.key);
                freeValue(allocator, m.value);
            }
            allocator.free(members);
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

fn zigConversions(allocator: std.mem.Allocator) !void {
    const source = try parseToValue(allocator, "names: [one, two]\n");
    defer freeValue(allocator, source);

    const Output = struct {
        names: []const []const u8,
        fallback: []const u8 = "fallback",
    };
    const output = try toZig(Output, allocator, source);
    defer deinitZig(Output, allocator, output);

    const Mode = enum { fast, slow };
    const names = [_][]const u8{ "api", "worker" };
    const Input = struct {
        names: []const []const u8,
        mode: Mode,
    };
    const value = try fromZig(allocator, Input{ .names = names[0..], .mode = .fast });
    defer freeValue(allocator, value);
}

test "allocation failures in value round trip leak nothing" {
    try std.testing.checkAllAllocationFailures(testing.allocator, valueRoundTrip, .{});
}

fn valueRoundTrip(allocator: std.mem.Allocator) !void {
    const v = try parseToValue(allocator,
        \\server:
        \\  ports: [80, 443]
        \\name: yayl
        \\pi: 3.14
        \\
    );
    defer freeValue(allocator, v);

    var doc = Document.init(allocator);
    defer doc.deinit();
    doc.root = try toNode(&doc, v);
    const back = try nodeToValue(allocator, doc.root.?);
    defer freeValue(allocator, back);

    // fromZig with a string field: the value must own its bytes for
    // freeValue to release them.
    const label = try allocator.dupe(u8, "hi");
    defer allocator.free(label);
    const Point = struct { x: i32, label: []const u8 };
    const vp = try fromZig(allocator, Point{ .x = 1, .label = label });
    defer freeValue(allocator, vp);
}

// The amplification this bound exists for: each level aliases the one
// above five times, so the value count is ~5^levels while the input
// stays a few hundred bytes.
fn aliasBomb(allocator: std.mem.Allocator, levels: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "l0: &l0 [x, x, x, x, x]\n");
    for (1..levels) |i| {
        const line = try std.fmt.allocPrint(
            allocator,
            "l{d}: &l{d} [*l{d}, *l{d}, *l{d}, *l{d}, *l{d}]\n",
            .{ i, i, i - 1, i - 1, i - 1, i - 1, i - 1 },
        );
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }
    return buf.toOwnedSlice(allocator);
}

test "alias expansion is bounded, and the bound is configurable" {
    const allocator = std.testing.allocator;

    // Small input, enormous output: 8 levels is ~5^8 leaves from well
    // under a kilobyte of YAML.
    const bomb = try aliasBomb(allocator, 8);
    defer allocator.free(bomb);
    try std.testing.expect(bomb.len < 1024);

    // A caller-supplied bound stops it. The budget is charged per value
    // produced, so this returns after ~10k values rather than after the
    // hundreds of thousands the document would expand to.
    try std.testing.expectError(
        error.LimitExceeded,
        parseToValueLimited(allocator, bomb, .{ .max_values = 10_000 }),
    );

    // The default is a bound, not absent. Asserted directly rather than
    // by converting a document large enough to trip it: that would make
    // this test allocate a million values every run.
    try std.testing.expectEqual(@as(usize, 1 << 20), (Limits{}).max_values);

    // The bound is not so tight that ordinary documents trip it: the
    // same shape at 3 levels is ~125 leaves and converts fine.
    const small = try aliasBomb(allocator, 3);
    defer allocator.free(small);
    const v = try parseToValueLimited(allocator, small, .{ .max_values = 1000 });
    defer freeValue(allocator, v);

    // And an explicit opt-out still works, for input you produced.
    const v2 = try parseToValueLimited(allocator, small, Limits.unlimited);
    defer freeValue(allocator, v2);
}

test "dynamic mappings convert to string maps, in all four spellings" {
    const allocator = testing.allocator;
    const src = "labels:\n  app: api\n  tier: backend\n  region: eu\n";

    // A `labels:` block has no struct to convert into: the keys are the
    // data. Before this it had no typed path at all.
    inline for (.{
        std.StringHashMapUnmanaged([]const u8),
        std.StringArrayHashMapUnmanaged([]const u8),
        std.StringHashMap([]const u8),
    }) |T| {
        var doc = try Document.parse(allocator, src);
        defer doc.deinit();
        const node = doc.pathGet(&.{"labels"}).?;

        const v = try nodeToValue(allocator, node);
        defer freeValue(allocator, v);

        var map = try toZig(T, allocator, v);
        defer deinitZig(T, allocator, map);

        try testing.expectEqual(@as(usize, 3), map.count());
        try testing.expectEqualStrings("api", map.get("app").?);
        try testing.expectEqualStrings("backend", map.get("tier").?);
        try testing.expectEqualStrings("eu", map.get("region").?);
    }

    // The array-backed spelling keeps insertion order, which is the
    // reason to prefer it for YAML.
    {
        var doc = try Document.parse(allocator, src);
        defer doc.deinit();
        const v = try nodeToValue(allocator, doc.pathGet(&.{"labels"}).?);
        defer freeValue(allocator, v);
        const T = std.StringArrayHashMapUnmanaged([]const u8);
        var map = try toZig(T, allocator, v);
        defer deinitZig(T, allocator, map);
        try testing.expectEqualStrings("app", map.keys()[0]);
        try testing.expectEqualStrings("tier", map.keys()[1]);
        try testing.expectEqualStrings("region", map.keys()[2]);
    }
}

test "a map round trips through fromZig" {
    const allocator = testing.allocator;
    const T = std.StringArrayHashMapUnmanaged(i64);
    var map: T = .empty;
    defer map.deinit(allocator);
    try map.put(allocator, "one", 1);
    try map.put(allocator, "two", 2);

    const v = try fromZig(allocator, map);
    defer freeValue(allocator, v);
    try testing.expectEqual(@as(usize, 2), v.mapping.len);
    try testing.expectEqualStrings("one", v.mapping[0].key);
    try testing.expectEqual(@as(i64, 1), v.mapping[0].value.int);

    var back = try toZig(T, allocator, v);
    defer deinitZig(T, allocator, back);
    try testing.expectEqual(@as(i64, 2), back.get("two").?);
}

test "a duplicate key in a mapping keeps the first, like lookup" {
    const allocator = testing.allocator;
    // YAML permits duplicates and this library keeps them, so a map
    // conversion has to choose. `Node.lookup` returns the first; a map
    // that silently kept the last would disagree with every other read
    // path in the library.
    var doc = try Document.parse(allocator, "m:\n  k: first\n  k: second\n");
    defer doc.deinit();
    const node = doc.pathGet(&.{"m"}).?;
    try testing.expectEqualStrings("first", node.lookup("k").?.scalarValue().?);

    const v = try nodeToValue(allocator, node);
    defer freeValue(allocator, v);
    const T = std.StringArrayHashMapUnmanaged([]const u8);
    var map = try toZig(T, allocator, v);
    defer deinitZig(T, allocator, map);
    try testing.expectEqual(@as(usize, 1), map.count());
    try testing.expectEqualStrings("first", map.get("k").?);
}

test "tagged unions convert both ways" {
    const allocator = testing.allocator;
    const Source = union(enum) {
        path: []const u8,
        port: u16,
        inherit: void,
    };

    // Externally tagged, as JSON does it: one entry keyed by the active
    // field.
    var doc = try Document.parse(allocator, "a:\n  path: /etc/app\nb:\n  port: 8080\nc:\n  inherit: null\n");
    defer doc.deinit();

    {
        const v = try nodeToValue(allocator, doc.pathGet(&.{"a"}).?);
        defer freeValue(allocator, v);
        const got = try toZig(Source, allocator, v);
        defer deinitZig(Source, allocator, got);
        try testing.expectEqualStrings("/etc/app", got.path);
    }
    {
        const v = try nodeToValue(allocator, doc.pathGet(&.{"b"}).?);
        defer freeValue(allocator, v);
        const got = try toZig(Source, allocator, v);
        defer deinitZig(Source, allocator, got);
        try testing.expectEqual(@as(u16, 8080), got.port);
    }
    {
        const v = try nodeToValue(allocator, doc.pathGet(&.{"c"}).?);
        defer freeValue(allocator, v);
        const got = try toZig(Source, allocator, v);
        defer deinitZig(Source, allocator, got);
        try testing.expect(got == .inherit);
    }

    // Out again.
    const out = try fromZig(allocator, Source{ .port = 443 });
    defer freeValue(allocator, out);
    try testing.expectEqual(@as(usize, 1), out.mapping.len);
    try testing.expectEqualStrings("port", out.mapping[0].key);
    try testing.expectEqual(@as(i64, 443), out.mapping[0].value.int);

    // Ambiguity is an error, not a guess.
    {
        var two = try Document.parse(allocator, "x:\n  path: /a\n  port: 1\n");
        defer two.deinit();
        const v = try nodeToValue(allocator, two.pathGet(&.{"x"}).?);
        defer freeValue(allocator, v);
        try testing.expectError(error.TypeMismatch, toZig(Source, allocator, v));
    }
    // An untagged union stays unsupported: there is nothing to name the
    // active field with.
    {
        const Bare = union { a: u8, b: u8 };
        const v: Value = .{ .mapping = &.{} };
        try testing.expectError(error.UnsupportedType, toZig(Bare, allocator, v));
    }
}

test "single-item pointers convert in both directions" {
    const allocator = testing.allocator;
    // `fromZig` already serialized a `*T` by dereferencing it; `toZig`
    // had no matching arm, so a type it could write it could not read.
    var doc = try Document.parse(allocator, "n: 42\n");
    defer doc.deinit();
    const v = try nodeToValue(allocator, doc.pathGet(&.{"n"}).?);
    defer freeValue(allocator, v);

    const got = try toZig(*i64, allocator, v);
    defer deinitZig(*i64, allocator, got);
    try testing.expectEqual(@as(i64, 42), got.*);

    const back = try fromZig(allocator, got);
    defer freeValue(allocator, back);
    try testing.expectEqual(@as(i64, 42), back.int);
}

test "a defaulted map field is cloned, not aliased" {
    const allocator = testing.allocator;
    const Map = std.StringArrayHashMapUnmanaged([]const u8);
    const Config = struct {
        name: []const u8,
        // A field default is comptime data shared by every conversion.
        // `toZig` promises the caller owns everything it returns, so a
        // default has to be cloned rather than handed out by reference
        // -- otherwise `deinitZig` would free storage the next call
        // still expects to be there.
        labels: Map = .empty,
    };

    var doc = try Document.parse(allocator, "name: api\n");
    defer doc.deinit();
    const v = try nodeToValue(allocator, doc.root.?);
    defer freeValue(allocator, v);

    var got = try toZig(Config, allocator, v);
    defer deinitZig(Config, allocator, got);
    try testing.expectEqualStrings("api", got.name);
    try testing.expectEqual(@as(usize, 0), got.labels.count());

    // The cloned map is independent: writing to it cannot reach back
    // into the default.
    try got.labels.put(allocator, try allocator.dupe(u8, "k"), try allocator.dupe(u8, "v"));
    try testing.expectEqual(@as(usize, 1), got.labels.count());

    var second = try toZig(Config, allocator, v);
    defer deinitZig(Config, allocator, second);
    try testing.expectEqual(@as(usize, 0), second.labels.count());
}
