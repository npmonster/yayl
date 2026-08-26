//! UTF-8 codec — Zig port of libfyaml's fy-utf8.
//!
//! Deliberately small: validate, decode, encode and measure. The scanner
//! counts columns in codepoints, so every consumed character goes through
//! `decode` which enforces strict RFC 3629 UTF-8 (no overlong forms, no
//! surrogates, nothing above U+10FFFF).

pub const DecodeResult = struct {
    cp: u21,
    len: usize,
};

/// Decode one codepoint at `bytes[i]`. Returns null on EOF or invalid input.
pub fn decode(bytes: []const u8, i: usize) ?DecodeResult {
    if (i >= bytes.len) return null;
    const b0 = bytes[i];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };

    var len: usize = 0;
    var cp: u21 = 0;
    var min: u21 = 0;
    if (b0 >= 0xC2 and b0 <= 0xDF) {
        len = 2;
        cp = @as(u21, b0 & 0x1F);
        min = 0x80;
    } else if (b0 >= 0xE0 and b0 <= 0xEF) {
        len = 3;
        cp = @as(u21, b0 & 0x0F);
        min = 0x800;
    } else if (b0 >= 0xF0 and b0 <= 0xF4) {
        len = 4;
        cp = @as(u21, b0 & 0x07);
        min = 0x10000;
    } else return null;

    if (i + len > bytes.len) return null;
    for (1..len) |k| {
        const b = bytes[i + k];
        if (b < 0x80 or b > 0xBF) return null;
        cp = (cp << 6) | @as(u21, b & 0x3F);
    }
    // Reject overlong encodings, surrogates and out-of-range values.
    if (cp < min or (cp >= 0xD800 and cp <= 0xDFFF) or cp > 0x10FFFF) return null;
    return .{ .cp = cp, .len = len };
}

/// Encode one codepoint into `out`, returning the number of bytes written.
/// `out` must have room for at least 4 bytes.
pub fn encode(cp: u21, out: *[4]u8) usize {
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return 1;
    } else if (cp < 0x800) {
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    } else {
        out[0] = @intCast(0xF0 | (cp >> 18));
        out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[3] = @intCast(0x80 | (cp & 0x3F));
        return 4;
    }
}

/// Strictly validate a whole buffer.
pub fn valid(bytes: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        const r = decode(bytes, i) orelse return false;
        i += r.len;
    }
    return true;
}

/// Number of codepoints in a valid UTF-8 buffer.
pub fn countCodepoints(bytes: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const r = decode(bytes, i) orelse break;
        i += r.len;
        n += 1;
    }
    return n;
}

test "decode ascii and multibyte" {
    const s = "a\u{00E9}\u{4E2D}\u{1F600}";
    var i: usize = 0;
    const expect = [_]struct { cp: u21, len: usize }{
        .{ .cp = 'a', .len = 1 },
        .{ .cp = 0xE9, .len = 2 },
        .{ .cp = 0x4E2D, .len = 3 },
        .{ .cp = 0x1F600, .len = 4 },
    };
    for (expect) |e| {
        const r = decode(s, i).?;
        try @import("std").testing.expectEqual(e.cp, r.cp);
        try @import("std").testing.expectEqual(e.len, r.len);
        i += r.len;
    }
    try @import("std").testing.expectEqual(s.len, i);
    try @import("std").testing.expect(valid(s));
    try @import("std").testing.expectEqual(@as(usize, 4), countCodepoints(s));
}

test "reject invalid sequences" {
    try @import("std").testing.expect(!valid(&[_]u8{0xC0, 0x80})); // overlong NUL
    try @import("std").testing.expect(!valid(&[_]u8{0xED, 0xA0, 0x80})); // surrogate
    try @import("std").testing.expect(!valid(&[_]u8{0xF4, 0x90, 0x80, 0x80})); // > U+10FFFF
    try @import("std").testing.expect(!valid(&[_]u8{0xE2, 0x82})); // truncated
}

test "encode roundtrip" {
    const std = @import("std");
    for ([_]u21{ 0x41, 0xE9, 0x4E2D, 0x10FFFF }) |cp| {
        var buf: [4]u8 = undefined;
        const len = encode(cp, &buf);
        const r = decode(buf[0..len], 0).?;
        try std.testing.expectEqual(cp, r.cp);
        try std.testing.expectEqual(len, r.len);
    }
}
