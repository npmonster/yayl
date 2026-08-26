//! Character classification — Zig port of libfyaml's fy-ctype.
//!
//! YAML syntax indicators are all ASCII, so these predicates work on raw
//! bytes. Codepoint level classes (printable etc.) live in `utf8.zig` and
//! the scanner. A value of 0 means "end of input" and is accepted by the
//! *z variants, matching libyaml/libfyaml CHECK_AT semantics.

/// ASCII digit.
pub fn isDigit(c: u8) bool {
    return c -% '0' < 10;
}

/// ASCII hex digit; returns its value or null.
pub fn hexValue(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

/// The character class anchors, tags and plain scalars may use:
/// alphanumerics plus '-' and '_'.
pub fn isAlpha(c: u8) bool {
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

/// Space only.
pub fn isSpace(c: u8) bool {
    return c == ' ';
}

pub fn isTab(c: u8) bool {
    return c == '\t';
}

/// Printable inside a plain scalar: everything but control characters.
/// Full YAML printable checking happens on codepoints in the scanner.
pub fn isPrintableAscii(c: u8) bool {
    return c >= 0x20 and c != 0x7F;
}

test "classification basics" {
    const std = @import("std");
    try std.testing.expect(isDigit('0') and isDigit('9') and !isDigit('a'));
    try std.testing.expectEqual(@as(?u8, 15), hexValue('f'));
    try std.testing.expectEqual(@as(?u8, 15), hexValue('F'));
    try std.testing.expect(isAlpha('-') and isAlpha('_') and !isAlpha('.'));
    try std.testing.expect(isBlank(' ') and isBlank('\t') and !isBlank(0));
    try std.testing.expect(isBlankz(0));
    try std.testing.expect(isBreak('\n') and isBreak('\r') and !isBreak(' '));
}
