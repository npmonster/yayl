//! UTF-8 codec for the scanner — strict RFC 3629 UTF-8 built on
//! `std.unicode`.
//!
//! libfyaml carries its own fy-utf8; instead of a hand-rolled port, YAYL
//! reuses `std.unicode` (which already rejects overlong forms, surrogates
//! and everything above U+10FFFF) and wraps it only where the scanner
//! needs index-position and EOF semantics the standard functions do not
//! offer:
//!
//!  * `decode` works at an arbitrary index and distinguishes end of input
//!    (null) from malformed input (`error.InvalidUtf8`); the sized
//!    `std.unicode.utf8Decode*` functions assume an exactly-sized array.
//!  * `encode` narrows the two std "cannot encode" errors into one, so
//!    escape handling reports a single condition.
//!  * `countCodepoints` fails on invalid input instead of counting a
//!    valid prefix.
//!
//! PORT NOTE: libfyaml's fy_utf8_* helpers collapse into this module.

const std = @import("std");

/// A decoded codepoint and its byte length.
pub const DecodeResult = struct {
    cp: u21,
    len: usize,
};

pub const DecodeError = error{
    /// The byte at `i` does not begin a valid UTF-8 sequence: bad lead
    /// byte, truncated sequence, overlong encoding, encoded surrogate or
    /// value above U+10FFFF.
    InvalidUtf8,
};

/// Decode one codepoint at `bytes[i]`.
///
/// Returns null on end of input and `error.InvalidUtf8` on malformed
/// input — the two are deliberately distinct so callers can position a
/// diagnostic on malformed bytes while treating EOF as a normal
/// terminator.
pub fn decode(bytes: []const u8, i: usize) DecodeError!?DecodeResult {
    if (i >= bytes.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return error.InvalidUtf8;
    if (i + len > bytes.len) return error.InvalidUtf8;
    const cp: u21 = switch (len) {
        1 => bytes[i],
        2 => std.unicode.utf8Decode2(bytes[i..][0..2].*) catch return error.InvalidUtf8,
        3 => std.unicode.utf8Decode3(bytes[i..][0..3].*) catch return error.InvalidUtf8,
        4 => std.unicode.utf8Decode4(bytes[i..][0..4].*) catch return error.InvalidUtf8,
        else => unreachable, // utf8ByteSequenceLength only returns 1..4
    };
    return .{ .cp = cp, .len = len };
}

pub const EncodeError = error{
    /// The codepoint is a UTF-16 surrogate half or above U+10FFFF and
    /// has no UTF-8 representation.
    InvalidCodepoint,
};

/// Encode one codepoint into `out`, returning the number of bytes
/// written. `out` must have room for at least 4 bytes.
pub fn encode(cp: u21, out: *[4]u8) EncodeError!usize {
    const len = std.unicode.utf8Encode(cp, out) catch return error.InvalidCodepoint;
    return len;
}

/// Strictly validate a whole buffer.
pub fn valid(bytes: []const u8) bool {
    return std.unicode.utf8ValidateSlice(bytes);
}

/// Number of codepoints in a buffer; `error.InvalidUtf8` on malformed
/// input. (Never returns a valid-prefix count — callers that want prefix
/// semantics must say so.)
pub fn countCodepoints(bytes: []const u8) DecodeError!usize {
    return std.unicode.utf8CountCodepoints(bytes) catch error.InvalidUtf8;
}

/// YAML 1.2 §5.1 printable codepoint: the characters that may appear in
/// a YAML character stream. Distinct from UTF-8 validity — a codepoint
/// can be valid UTF-8 yet unprintable (e.g. U+0007 BEL).
pub fn isPrintableCodepoint(cp: u21) bool {
    return switch (cp) {
        0x9, 0xA, 0xD, 0x85 => true,
        0x20...0x7E, 0xA0...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF => true,
        else => false,
    };
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
        const r = (try decode(s, i)).?;
        try std.testing.expectEqual(e.cp, r.cp);
        try std.testing.expectEqual(e.len, r.len);
        i += r.len;
    }
    try std.testing.expectEqual(s.len, i);
    try std.testing.expect(valid(s));
    try std.testing.expectEqual(@as(usize, 4), try countCodepoints(s));
    // EOF is null, not an error.
    try std.testing.expectEqual(@as(?DecodeResult, null), try decode(s, i));
    try std.testing.expectEqual(@as(?DecodeResult, null), try decode("", 0));
}

test "malformed input is an error, distinct from EOF" {
    const cases = [_][]const u8{
        &.{ 0xC0, 0x80 }, // overlong NUL
        &.{ 0xC1, 0xBF }, // overlong (lead byte C1 is never valid)
        &.{ 0xED, 0xA0, 0x80 }, // encoded surrogate U+D800
        &.{ 0xED, 0xBF, 0xBF }, // encoded surrogate U+DFFF
        &.{ 0xF4, 0x90, 0x80, 0x80 }, // above U+10FFFF
        &.{ 0xE2, 0x82 }, // truncated 3-byte sequence
        &.{0x80}, // lone continuation byte
        &.{ 0xF5, 0x80, 0x80, 0x80 }, // lead byte beyond F4
        &.{ 0xE2, 0x28, 0xA1 }, // non-continuation inside sequence
    };
    for (cases) |c| {
        try std.testing.expectError(error.InvalidUtf8, decode(c, 0));
        try std.testing.expect(!valid(c));
        try std.testing.expectError(error.InvalidUtf8, countCodepoints(c));
    }
}

test "encode roundtrip at the 1/2/3/4-byte boundaries" {
    const boundaries = [_]u21{ 0x0, 0x7F, 0x80, 0x7FF, 0x800, 0xFFFF, 0x10000, 0x10FFFF };
    for (boundaries) |cp| {
        var buf: [4]u8 = undefined;
        const len = try encode(cp, &buf);
        try std.testing.expectEqual(@as(usize, std.unicode.utf8CodepointSequenceLength(cp) catch unreachable), len);
        const r = (try decode(buf[0..len], 0)).?;
        try std.testing.expectEqual(cp, r.cp);
        try std.testing.expectEqual(len, r.len);
    }
}

test "encode rejects surrogates and out-of-range values" {
    var buf: [4]u8 = undefined;
    for ([_]u21{ 0xD800, 0xDFFF, 0x110000, 0x1FFFFF }) |cp| {
        try std.testing.expectError(error.InvalidCodepoint, encode(cp, &buf));
    }
}

test "encode agrees with std.unicode.utf8ValidCodepoint" {
    // Sample every boundary neighborhood rather than the full u21 range.
    var cp: u21 = 0;
    var buf: [4]u8 = undefined;
    while (cp <= 0x110001) : (cp += 1) {
        if (cp > 0x1200 and cp < 0xD7F0) {
            cp = 0xD7F0; // skip the large valid middle
            continue;
        }
        if (cp > 0xE010 and cp < 0xFFE0) {
            cp = 0xFFE0;
            continue;
        }
        const result = encode(cp, &buf);
        if (std.unicode.utf8ValidCodepoint(cp)) {
            const len = try result;
            try std.testing.expectEqual(@as(usize, std.unicode.utf8CodepointSequenceLength(cp) catch unreachable), len);
        } else {
            try std.testing.expectError(error.InvalidCodepoint, result);
        }
    }
}

test "valid agrees with std.unicode on random buffers" {
    var prng = std.Random.DefaultPrng.init(0x7a6d); // fixed seed: deterministic
    const random = prng.random();
    var buf: [64]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 1000) : (iteration += 1) {
        const len = random.uintAtMost(usize, buf.len);
        random.bytes(buf[0..len]);
        try std.testing.expectEqual(std.unicode.utf8ValidateSlice(buf[0..len]), valid(buf[0..len]));
    }
    // And on valid strings of every encoding length.
    for ([_][]const u8{ "a", "é", "中", "😀", "aé中😀" }) |s| {
        try std.testing.expect(valid(s));
        try std.testing.expectEqual(std.unicode.utf8ValidateSlice(s), valid(s));
    }
}

test "isPrintableCodepoint follows YAML 1.2 section 5.1" {
    const cases = [_]struct { cp: u21, want: bool }{
        .{ .cp = 0x8, .want = false },
        .{ .cp = 0x9, .want = true }, // TAB
        .{ .cp = 0xA, .want = true }, // LF
        .{ .cp = 0xB, .want = false },
        .{ .cp = 0xC, .want = false },
        .{ .cp = 0xD, .want = true }, // CR
        .{ .cp = 0x1F, .want = false },
        .{ .cp = 0x20, .want = true },
        .{ .cp = 0x7E, .want = true },
        .{ .cp = 0x7F, .want = false }, // DEL
        .{ .cp = 0x84, .want = false },
        .{ .cp = 0x85, .want = true }, // NEL
        .{ .cp = 0x86, .want = false },
        .{ .cp = 0x9F, .want = false },
        .{ .cp = 0xA0, .want = true },
        .{ .cp = 0xD7FF, .want = true },
        .{ .cp = 0xD800, .want = false }, // surrogate range excluded
        .{ .cp = 0xDFFF, .want = false },
        .{ .cp = 0xE000, .want = true },
        .{ .cp = 0xFFFD, .want = true },
        .{ .cp = 0xFFFE, .want = false },
        .{ .cp = 0xFFFF, .want = false },
        .{ .cp = 0x10000, .want = true },
        .{ .cp = 0x10FFFF, .want = true },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.want, isPrintableCodepoint(c.cp));
    }
}
