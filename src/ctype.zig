//! Character classification — Zig port of libfyaml's fy-ctype.
//!
//! YAML syntax indicators are all ASCII, so these predicates work on raw
//! bytes. Codepoint level classes (printable etc.) live in `utf8.zig`.
//! A value of 0 means "end of input" and is accepted by the *z variants,
//! matching libyaml/libfyaml CHECK_AT semantics.
//!
//! Predicates whose behavior is identical to `std.ascii` are not
//! duplicated here — callers use `std.ascii` directly (for example
//! `std.ascii.isDigit`). What remains carries YAML-specific character
//! classes or the EOF sentinel semantics `std.ascii` cannot express.

const std = @import("std");

/// ASCII hex digit; returns its value or null.
///
/// Kept instead of `std.fmt.charToDigit` because the scanner's escape
/// and tag-URI probes want the `?u8` shape, not error handling.
pub fn hexValue(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

/// YAML "word" character: ASCII letter, digit, '-' or '_'.
///
/// Superset of the YAML 1.2 `ns-word-char` production (which excludes
/// '_'), following the libyaml/libfyaml IS_ALPHA convention. Used for
/// directive names, anchor/alias names, tag handles and tag URIs.
pub fn isWordChar(c: u8) bool {
    switch (c) {
        '0'...'9', 'a'...'z', 'A'...'Z', '-', '_' => return true,
        else => return false,
    }
}

/// Space or tab (0 terminates input and is therefore not blank).
pub fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// CR or LF.
pub fn isBreak(c: u8) bool {
    return c == '\n' or c == '\r';
}

/// Blank, break or end of input.
pub fn isBlankz(c: u8) bool {
    return c == 0 or isBlank(c) or isBreak(c);
}

/// Space only. `std.ascii.isSpace` is not a substitute: it also accepts
/// \v and \f, which YAML does not treat as blank.
pub fn isSpace(c: u8) bool {
    return c == ' ';
}

pub fn isTab(c: u8) bool {
    return c == '\t';
}

/// Printable ASCII byte: 0x20..0x7E.
///
/// Bytes 0x80 and above are UTF-8 lead/continuation bytes and must be
/// judged at codepoint level with `utf8.isPrintableCodepoint`, never by
/// this predicate.
pub fn isPrintableAscii(c: u8) bool {
    return c >= 0x20 and c < 0x7F;
}

test "hexValue" {
    for (0..256) |b| {
        const c: u8 = @intCast(b);
        const got = hexValue(c);
        const want: ?u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => null,
        };
        try std.testing.expectEqual(want, got);
    }
}

test "isWordChar covers all 256 bytes" {
    for (0..256) |b| {
        const c: u8 = @intCast(b);
        const want = std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
        try std.testing.expectEqual(want, isWordChar(c));
    }
}

test "blank/break/blankz boundaries" {
    for (0..256) |b| {
        const c: u8 = @intCast(b);
        try std.testing.expectEqual(c == ' ' or c == '\t', isBlank(c));
        try std.testing.expectEqual(c == '\n' or c == '\r', isBreak(c));
        try std.testing.expectEqual(c == 0 or c == ' ' or c == '\t' or c == '\n' or c == '\r', isBlankz(c));
        try std.testing.expectEqual(c == ' ', isSpace(c));
        try std.testing.expectEqual(c == '\t', isTab(c));
    }
    // The EOF sentinel is blankz but neither blank nor break.
    try std.testing.expect(isBlankz(0));
    try std.testing.expect(!isBlank(0) and !isBreak(0));
}

test "isPrintableAscii covers all 256 bytes" {
    for (0..256) |b| {
        const c: u8 = @intCast(b);
        // Exactly the printable ASCII range 0x20..0x7E; DEL (0x7F) and
        // every non-ASCII byte are excluded.
        const want = b >= 0x20 and b <= 0x7E;
        try std.testing.expectEqual(want, isPrintableAscii(c));
    }
}
