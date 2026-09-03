//! Source markup — Zig port of libfyaml's fy-markup role (CST spans).
//!
//! libfyaml achieves byte-faithful round trips by keeping per-node
//! references into the original input and reconstructing untouched
//! regions verbatim. This module provides the byte-offset scanning
//! helpers that derive a node's *presentation* extent (the `-`/`?`
//! entry indicator it sits under, the trailing comment on its last
//! line, the line geometry around an offset) from those spans.
//!
//! Everything here is pure source-slice arithmetic: no allocation, no
//! parser state, so it is trivially testable and safe to call during
//! emission.

const std = @import("std");

/// Node presentation metadata, stored on parsed nodes (see
/// `Node.src`). Offsets are byte offsets into `Document.source`.
///
///   entry_start  first byte of the entry this node occupies: the `-`
///                of a block sequence item, the `?` of an explicit key,
///                or `start` when there is no indicator. Everything
///                between `entry_start` and `start` is the indicator
///                and its trailing blanks.
///   start/end    the node's own bytes, including any `&anchor`/`!tag`
///                properties (the parser's start mark covers them) and,
///                for flow collections, the closing bracket. Block
///                collections end at their last child's `end`.
///   synthetic    true for the empty scalars the parser synthesizes for
///                missing keys/values; their span is a point borrowed
///                from the next token and must not be emitted verbatim.
pub const Src = struct {
    entry_start: usize,
    start: usize,
    end: usize,
    synthetic: bool = false,
};

/// The offset of the first byte of the line containing `offset`.
pub fn lineStart(source: []const u8, offset: usize) usize {
    // A lone CR is a line break too (YAML 1.2 §5.4:
    // `b-break ::= CRLF | CR | LF`), and the scanner agrees —
    // `ctype.isBreak` accepts both. Scanning for `\n` alone made these
    // helpers disagree with the scanner about where a line ends, which
    // let a document's source region swallow the `---` belonging to the
    // next one.
    var i = @min(offset, source.len);
    while (i > 0) : (i -= 1) {
        switch (source[i - 1]) {
            '\n' => return i,
            '\r' => {
                // CRLF is ONE break, ending after the LF. An offset
                // sitting on that LF is therefore still on the earlier
                // line, so keep scanning rather than returning a
                // position wedged between the two bytes.
                if (i < source.len and source[i] == '\n') continue;
                return i;
            },
            else => {},
        }
    }
    return 0;
}

/// The offset just past the line terminator ending the line that
/// contains `offset`: the index of the next line's first byte (or
/// `source.len`). Handles all three YAML line breaks — `\n`, `\r\n` and
/// a lone `\r` — since `b-break ::= CRLF | CR | LF` and the scanner
/// breaks lines on any of them.
pub fn lineEnd(source: []const u8, offset: usize) usize {
    var i = lineStart(source, offset);
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') return i + 1;
        if (source[i] == '\r') {
            return if (i + 1 < source.len and source[i + 1] == '\n') i + 2 else i + 1;
        }
    }
    return source.len;
}

/// The offset of the line terminator itself (the `\n`, or the `\r` of a
/// `\r\n` or lone `\r`), or `source.len` for the final unterminated
/// line.
pub fn newlineAt(source: []const u8, offset: usize) usize {
    var i = lineStart(source, offset);
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n' or source[i] == '\r') return i;
    }
    return source.len;
}

/// 0-based column (in bytes) of `offset` within its line. YAML columns
/// count codepoints, but for indentation derivation bytes are what the
/// emitter needs (indentation is ASCII spaces).
pub fn columnOf(source: []const u8, offset: usize) usize {
    return offset - lineStart(source, offset);
}

/// Walk backwards from a node's content start to find the block entry
/// indicator (`-` or `?`) that introduces it, if any. Returns
/// `content_start` when the node starts its own entry (no indicator).
///
/// The scan crosses only spaces/tabs on the same line, then the newline
/// when the indicator sits alone on the previous line (`-\n  content`).
pub fn entryStart(source: []const u8, content_start: usize) usize {
    var i = content_start;
    while (i > 0 and (source[i - 1] == ' ' or source[i - 1] == '\t')) i -= 1;
    if (i == 0) return content_start;
    const prev = source[i - 1];
    if (prev == '-' or prev == '?') return i - 1;
    if (prev == '\n' or prev == '\r') {
        // The indicator may sit alone at the end of the previous line.
        if (i < 2) return content_start;
        var j = if (prev == '\n') i - 1 else i - 2;
        while (j > 0 and (source[j - 1] == ' ' or source[j - 1] == '\t')) j -= 1;
        if (j > 0 and (source[j - 1] == '-' or source[j - 1] == '?')) {
            // Only when that line holds nothing but the indicator:
            // every byte before it must be blanks.
            const ls = lineStart(source, j - 1);
            for (source[ls .. j - 1]) |c| {
                if (c != ' ' and c != '\t') return content_start;
            }
            return j - 1;
        }
    }
    return content_start;
}

/// Find the end of the `:` that terminates a mapping key starting the
/// scan at `after` (the key's content end). Skips blanks; returns
/// `after` when there is no value indicator (explicit-key-only pair).
pub fn colonEnd(source: []const u8, after: usize) usize {
    var i = after;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
    if (i < source.len and source[i] == ':') return i + 1;
    return after;
}

/// Skip blanks forward from `offset`, returning the first offset that
/// is not a space or tab. Used to keep the author's spacing after a
/// `:` when the value it introduced has been replaced and its own span
/// is gone.
pub fn spaceEnd(source: []const u8, offset: usize) usize {
    var i = offset;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
    return i;
}

/// True when the rest of the line at/after `offset` (before the line
/// terminator) contains a `#` comment. Everything between a node's
/// content end and its line terminator can only be blanks and a comment
/// (the grammar guarantees no other token can follow there), so a plain
/// byte scan is exact.
pub fn remainderHasComment(source: []const u8, offset: usize) bool {
    const nl = newlineAt(source, offset);
    return std.mem.indexOfScalar(u8, source[offset..nl], '#') != null;
}

/// The raw trailing comment after content ending at `end`: a
/// `{start, end}` span covering the `#` through the last byte before the
/// line terminator, or null when the remainder holds no comment. The
/// blanks between the content and the `#` are not part of the span --
/// they are presentation, and comment writes canonicalize them.
pub fn trailingCommentSpan(source: []const u8, end: usize) ?[2]usize {
    if (end > source.len) return null;
    const nl = newlineAt(source, end);
    var i = end;
    while (i < nl and (source[i] == ' ' or source[i] == '\t')) i += 1;
    if (i < nl and source[i] == '#') return .{ i, nl };
    return null;
}

/// The raw leading comment block immediately above the line containing
/// `entry_start`: a `{start, end}` span covering the `#` of the topmost
/// line through the last byte of the bottom-most line's comment, with
/// the interior newlines and indentation included and the final line
/// terminator excluded. Null when the line directly above is not a
/// comment. The scan stops at a blank line -- that is the rule that
/// makes "belongs to this entry" decidable -- and at any non-comment
/// line, so a block separated from its entry, or a free-floating one,
/// attaches to nothing.
pub fn leadingCommentSpan(source: []const u8, entry_start: usize) ?[2]usize {
    const own = lineStart(source, entry_start);
    if (own == 0) return null; // first line: nothing above to attach
    var line = lineStart(source, own - 1); // the line directly above
    var top_hash: ?usize = null;
    var bottom_end: usize = 0;
    while (true) {
        const nl = newlineAt(source, line);
        var i = line;
        while (i < nl and (source[i] == ' ' or source[i] == '\t')) i += 1;
        if (i >= nl or source[i] != '#') break;
        top_hash = i;
        if (bottom_end == 0) bottom_end = nl;
        if (line == 0) break;
        const prev = lineStart(source, line - 1);
        if (prev == line) break; // cannot rise further
        line = prev;
    }
    if (top_hash) |th| {
        // A CRLF terminator's `\r` belongs to the line break, not to
        // the comment.
        var end = bottom_end;
        if (end > th and source[end - 1] == '\r') end -= 1;
        return .{ th, end };
    }
    return null;
}

/// The indentation (in bytes) of the line containing `offset`: the
/// number of leading spaces. Tabs count as one byte each; the scanner
/// rejects tab indentation in block context, so this only matters for
/// re-deriving sibling columns in already-accepted input.
pub fn indentOf(source: []const u8, offset: usize) usize {
    const ls = lineStart(source, offset);
    var i: usize = 0;
    while (ls + i < source.len and source[ls + i] == ' ') i += 1;
    return i;
}

test "lineStart and lineEnd over simple lines" {
    const src = "aa: 1\nbbb: 2\n";
    try std.testing.expectEqual(@as(usize, 0), lineStart(src, 0));
    try std.testing.expectEqual(@as(usize, 0), lineStart(src, 3));
    try std.testing.expectEqual(@as(usize, 6), lineStart(src, 6));
    try std.testing.expectEqual(@as(usize, 6), lineStart(src, 9));
    try std.testing.expectEqual(@as(usize, 6), lineEnd(src, 0));
    try std.testing.expectEqual(@as(usize, 6), lineEnd(src, 5));
    try std.testing.expectEqual(@as(usize, 13), lineEnd(src, 6));
    try std.testing.expectEqual(@as(usize, 13), lineEnd(src, 12));
}

test "lineEnd handles crlf and missing final newline" {
    const src = "a: 1\r\nb: 2";
    try std.testing.expectEqual(@as(usize, 6), lineEnd(src, 0));
    try std.testing.expectEqual(@as(usize, 10), lineEnd(src, 6));
    try std.testing.expectEqual(@as(usize, 10), newlineAt(src, 6));
    try std.testing.expectEqual(@as(usize, 10), lineEnd(src, 8));
}

test "newlineAt finds the terminator byte" {
    const src = "a: 1\nb: 2\n";
    try std.testing.expectEqual(@as(usize, 4), newlineAt(src, 0));
    try std.testing.expectEqual(@as(usize, 9), newlineAt(src, 5));
}

test "columnOf and indentOf" {
    const src = "a: 1\n  b: 2";
    try std.testing.expectEqual(@as(usize, 4), columnOf(src, 4));
    try std.testing.expectEqual(@as(usize, 2), columnOf(src, 7));
    try std.testing.expectEqual(@as(usize, 2), indentOf(src, 7));
    try std.testing.expectEqual(@as(usize, 0), indentOf(src, 0));
}

test "entryStart finds dash indicators" {
    // Same-line dash: item content starts after "- ".
    const src = "- a\n- b\n";
    try std.testing.expectEqual(@as(usize, 0), entryStart(src, 2));
    try std.testing.expectEqual(@as(usize, 4), entryStart(src, 6));
    // Nested dash.
    const nested = "k:\n  - a\n  - b\n";
    try std.testing.expectEqual(@as(usize, 5), entryStart(nested, 7));
    try std.testing.expectEqual(@as(usize, 11), entryStart(nested, 13));
    // Dash alone on the previous line.
    const alone = "-\n  a\n";
    try std.testing.expectEqual(@as(usize, 0), entryStart(alone, 4));
    // Compact nested sequence: inner item content.
    const compact = "- - a\n";
    try std.testing.expectEqual(@as(usize, 2), entryStart(compact, 4));
    // No indicator: mapping value.
    const map = "k: v\n";
    try std.testing.expectEqual(@as(usize, 3), entryStart(map, 3));
    // Plain scalar starting with '-' is not an indicator.
    const neg = "k: -1\n";
    try std.testing.expectEqual(@as(usize, 3), entryStart(neg, 3));
    // Explicit key indicator; the value after ':' has no indicator.
    const complex = "? k\n: v\n";
    try std.testing.expectEqual(@as(usize, 0), entryStart(complex, 2));
    try std.testing.expectEqual(@as(usize, 6), entryStart(complex, 6));
    // Tiny inputs must not overflow the backward scans.
    try std.testing.expectEqual(@as(usize, 0), entryStart("", 0));
    try std.testing.expectEqual(@as(usize, 0), entryStart("-", 0));
    try std.testing.expectEqual(@as(usize, 1), entryStart("\r", 1));
    try std.testing.expectEqual(@as(usize, 1), entryStart("\n", 1));
}

test "entryStart rejects bogus previous-line indicators" {
    // Previous line has content besides the indicator: not an entry.
    const src = "x: 1\n  a\n";
    try std.testing.expectEqual(@as(usize, 6), entryStart(src, 6));
    // Content starting with '-' at line start is its own indicator
    // position (block sequence), never a false backward match.
    const seq = "- -a\n";
    try std.testing.expectEqual(@as(usize, 0), entryStart(seq, 2));
}

test "colonEnd skips blanks and stops at the colon" {
    const src = "k: v\nk2:  \n";
    try std.testing.expectEqual(@as(usize, 2), colonEnd(src, 1));
    try std.testing.expectEqual(@as(usize, 8), colonEnd(src, 7));
    // No colon (explicit key only).
    const no_colon = "? k\n: v\n";
    try std.testing.expectEqual(@as(usize, 3), colonEnd(no_colon, 3));
}

test "remainderHasComment" {
    const src = "a: 1 # one\nb: 2\n";
    try std.testing.expect(remainderHasComment(src, 4));
    try std.testing.expect(!remainderHasComment(src, 11));
    try std.testing.expect(!remainderHasComment(src, 4 + 2)); // "one" region? offset 6 -> "one"
    // '#' at end of input without newline.
    const tail = "a: 1 #";
    try std.testing.expect(remainderHasComment(tail, 5));
}

test "trailingCommentSpan returns the raw hash-through-end bytes" {
    const src = "port: 8080   # user facing\nb: 2\n";
    // Content ends after "8080" (offset 11); the span starts at the '#'.
    const span = trailingCommentSpan(src, 11).?;
    try std.testing.expectEqualStrings("# user facing", src[span[0]..span[1]]);
    // No comment on the next line.
    try std.testing.expect(trailingCommentSpan(src, 27) == null);
    // A '#' in a value does not leak: only blanks may precede it.
    try std.testing.expect(trailingCommentSpan("a: x#y\n", 5) == null);
    // Unterminated final line still reads.
    const tail = "k: v # end";
    const t = trailingCommentSpan(tail, 4).?;
    try std.testing.expectEqualStrings("# end", tail[t[0]..t[1]]);
}

test "leadingCommentSpan stacks upward and stops at blanks and content" {
    // One comment directly above the entry ('h' of host is at 16).
    const one = "# the main host\nhost: localhost\n";
    {
        const span = leadingCommentSpan(one, 16).?;
        try std.testing.expectEqualStrings("# the main host", one[span[0]..span[1]]);
    }
    // Stacked: topmost '#' through the bottom line's end.
    const stacked = "# one\n# two\nkey: v\n";
    {
        const span = leadingCommentSpan(stacked, 12).?;
        try std.testing.expectEqualStrings("# one\n# two", stacked[span[0]..span[1]]);
    }
    // A blank line breaks the attachment.
    const blanked = "# far away\n\nkey: v\n";
    try std.testing.expect(leadingCommentSpan(blanked, 12) == null);
    // A non-comment line does too.
    const content = "prev: 1\nkey: v\n";
    try std.testing.expect(leadingCommentSpan(content, 8) == null);
    // First line of the document: nothing above to attach.
    try std.testing.expect(leadingCommentSpan("key: v\n", 0) == null);
    // Indented comments keep their indentation inside the span
    // (the '-' of the item is at 25).
    const indented = "top:\n  # about the value\n  - a\n";
    {
        const span = leadingCommentSpan(indented, 25).?;
        try std.testing.expectEqualStrings("# about the value", indented[span[0]..span[1]]);
    }
    // CRLF: the terminator bytes stay outside the span ('k' is at 7).
    const crlf = "# win\r\nk: v\r\n";
    {
        const span = leadingCommentSpan(crlf, 7).?;
        try std.testing.expectEqualStrings("# win", crlf[span[0]..span[1]]);
    }
}
