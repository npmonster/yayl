# Changelog

Notable changes to yayl. Pre-1.0, the minor version is the release
series; APIs may still move, and anything that does is listed here.

## Unreleased

### Fixed

**Strings with a CR, NUL, ESC, DEL or other control byte were written in
a style that cannot spell them.** Single quotes and block scalars have no
escapes, so the byte went out raw: `a\rb` read back as `a b` at the root
and did not parse as a mapping value, a NUL did not parse at all, and a
CRLF inside a multi-line string lost its CR. Any string holding an ASCII
control other than tab and line feed, or DEL, is now written
double-quoted with escapes, whatever style was asked for. Over the
corpus and fixtures the only output that changes is corpus G4RS rebuilt
through `yaml.value`, whose `\b` and `\r\n` were written raw into literal
blocks and read back changed. (#7)

**A root string with a `---` or `...` line was cut off at that line.**
A root block scalar's content sits at column 0, where such a line (with
a blank or nothing after the marker) is a document marker, so
`"a\n---\nb\n"` read back as `"a\n"`. At column 0 those values now fall
back to double quotes; below the root, and for lines like `---x` that
are not markers, the block form is kept. A new sweep writes and re-reads
every string up to three bytes over control bytes, quotes, blanks and
indicators (two bytes in each explicitly requested style; five over
dashes, dots, blanks and line breaks) as a root, a block and flow mapping key and value, a sequence item and
a nested value, and each comes back unchanged. (#8)

**An edit under a root that shares its line with `---` dropped a dash.**
`--- {a: 1}` with `$.a` set to 2 was written `--{a: 2}`, valid YAML that
reads back as a mapping keyed `--{a`; flow, tagged, anchored and
replaced scalar roots were all affected. `markup.entryStart` took the
marker's last dash for a `- ` block-entry indicator, so the root's entry
started inside `---` and a modified root was re-emitted without it. A
dash directly after another dash is no longer taken for an indicator. A
new preservation sweep sets every scalar of seventeen marker-line
streams (flow and scalar roots, tags, anchors, comments, CRLF, BOM,
directives, several documents) and checks that exactly that scalar's
bytes change. (#9)

**An empty item in a flow sequence was written as nothing.** Setting an
item of `s: [a, b]` to the empty plain scalar (YAML's null) wrote
`s: [, b]`, which does not parse, or `s: [a, ]`, which has one item. An
empty plain scalar stays unwritten where YAML allows it (`key:`, `- `,
`{k: }`), but as a flow sequence item with no anchor or tag it is now
written `null`, so the item keeps its place and its value. (#10)

**An anchor set on a parsed mapping key was silently dropped.**
`setAnchor` on the key of `k: v` succeeded, but the document was written
back as `k: v`: the emitter copied a key's source bytes whenever it had
any, without asking whether the key had been modified since. Keys now
follow the same rule as values, so `&x k: v` is written, clearing the
anchor writes `k: v`, and a key's `- ` or `? ` framing and untouched
sibling keys keep their bytes. (#11)

**A delete matching several nodes reported success and deleted
nothing.** `Editor.delete("$.items[*]")` and `delete("$.items[?k=1]")`
left the document unchanged when they matched several nodes, and failed
with `error.AmbiguousOperation` when they matched exactly one: the target
was looked up with `one`, whose "not exactly one" error was taken for
"no match". A delete now removes every node its path matches, as a
trailing `..` descent already did: `[*]` empties a list or mapping,
`[?k=v]` removes every matching item, and a wildcard or filter earlier
in the path (`$.items[*].tmp`) applies to every item. A path of keys and
indices still names at most one node, and matching nothing is still a
no-op. It is all or nothing: a match whose removal would strand an alias
(`error.AnchorReferenced`) or that is reached through an alias container
(`error.AliasPath`) refuses the whole delete. Behaviour change: deletes
that match several nodes used to be silent no-ops. (#12)

**Writing a leading comment corrupted or lost the document in many
positions.** A new preservation sweep writes a comment on every writable
node of every fixture and corpus document and reads it back: 733 of 2,334
writes failed. The causes:

- On the first key of a sequence item or an explicit key, the `- ` or
  `? ` was written twice (`- - k: v`, a nested sequence), and on an item
  holding a mapping the same happened to the item's `- `.
- On the root, the old comment block was removed and the new one never
  written.
- Several nodes start on one entry line (an item and its first key, a
  block value and its first entry, a key and its inline value), and a
  written block went to whichever node was named. The first key of an
  item then recorded its tombstone in the wrong container, so the old
  block survived next to the new one. A block now belongs to the
  outermost node starting on the line; every node there reads and
  writes that one block.
- A `# ...` content line of a block scalar was read as the next entry's
  comment, and a node made only of properties (`a: &anchor`, `- !!str`)
  had a span running to the next token, taking the comment lines in
  between (and a trailing `# comment` on it was not read at all).
- A comment written for an empty node was accepted and dropped; it is now
  refused with `error.InvalidSyntax`, as the read side has nothing there.
- A written block for an explicit key's value dropped the `: ` indicator.

A modified mapping key is also re-emitted under the rules for keys: since
the #11 fix, a multi-line key given a comment or an anchor came out as a
literal block, a different mapping.

**A modified keep-chomped block scalar grew on every write.** A `|+` or
`>+` block keeps its trailing line breaks as value, and in the source
they sit after its slot. When the node was modified (a new anchor, tag
or comment, or a new value with trailing breaks) the block was re-written
with its whole value and then those source blank lines were written
again, which the keep chomping took in: `keep\n\n` read back as
`keep\n\n\n`. The blank lines are now skipped after a re-written keep
block.

**Edits inside a compact collection after an explicit `: ` or `? `
changed or broke the document.** With `? a` / `: - b` (the value's first
entry on the `: ` line), replacing or deleting that entry tombstoned the
whole line, `: ` included: `$.a[0]` set gave `? a\n  - X`, a different
tree, and a compact mapping value (`: x: 1`) no longer parsed after any
edit. A re-emitted value also broke its line after the `: `. The first
entry's line keeps the framing of the nodes around it (`- `, `? `, `: `)
whatever the edit, as it already did for a sequence item's `- `, and a
modified collection key no longer writes its `? ` twice or leaves a blank
line before `: value`.

**A trailing comment on an empty value could be written but not read.**
`push: # c` read no comment (an empty value's span is a point borrowed
from the next token), so a comment written there did not read back; an
empty item or document took the write and never emitted it. An empty
mapping value now reads the comment after its key and colon (`push:`,
`? key`), and a trailing comment on an empty item or document, or after a
block scalar key with no `:`, is refused with `error.InvalidSyntax`. The
comment sweep now writes a trailing comment on every writable node too.

**An explicit core tag accepted text outside its type's grammar.**
`!!int` text was read with `std.fmt.parseInt(.., 0)` and `!!float` with
`std.fmt.parseFloat`, which take much more than the YAML 1.2 core schema:
`!!int 0b101` converted to 5, `!!int 1_000` to 1000, `!!float nan` to a
NaN and `!!float 0x10` to 16, although each is a string untagged, and
`Schema.int` passed `!!int abc`. An explicit core tag now holds only text
spelled as its type (`!!int 0x1F`, `!!int '7'`, `!!float 1` and `.inf`
still do); anything else is `error.TypeMismatch` from `yaml.value` and a
type violation from `yaml.schema`. `toZig` holds a hand-built `.bigint`
to the same rule, and a read path (`pathGet`, `byPath`) indexes a
sequence only with plain digits (`1_0` and `+1` were items 10 and 1).

**A query through aliases of aliases could run forever.** Queries
resolve aliases, and a node reached again was walked again, so 20
levels of 10 aliases (about 800 bytes) named 10^20 paths: `all("$..x")`
never returned, and wildcard steps multiplied the same way. A descent now
never re-walks a subtree it has finished and each step expands an alias
target once, so a query costs the document's size (that test runs in
20 ms). An alias cycle still fails with `error.NestingTooDeep`. Wildcard
and filter results list each node once, as descent already did, and a
trailing-descent delete no longer re-walks the document after every
removal.

**Converting aliases to Values was bounded in count but not in bytes.**
`value.Limits.max_values` counts Values, but every expanded alias copies
its strings: one 64 KiB anchored string behind four levels of ten aliases
is only 10^4 Values, and asked for about 700 MB from a 65 KiB input. The
new `value.Limits.max_bytes` (64 MiB by default, like the input limit)
bounds the text one conversion copies, with `error.LimitExceeded`; a
document without aliases never copies more text than it holds.

**Merge-key resolution had no size bound, and each merge was
quadratic.** Every `<<` copies its source's pairs into its mapping, with
nothing bounding the total but depth: 72 KB of merges of a 1000-key
mapping built a 2.4 GB document over two minutes, since each copied key
was also compared with every key already there. The new
`ParseOptions.max_merge_nodes` (262,144 by default) stops resolution with
`error.LimitExceeded` (now part of `YamlError`), leaving the document as
it was; `Document.resolveMergeKeysLimited` takes the bound directly. The
key check is a hash lookup, so a merge costs what it copies: 100 merges
of that mapping take a sixth of the time they did.

**Every edit cost the size of the whole document.** `Editor.apply` (and
so every `set`, `delete`, `insert`, `append` and `move`) deep-cloned the
tree to stay atomic, and the clone was left in the document's arena: 800
single-key sets on an 8,000-key mapping took 20 s and grew the arena by
4.3 GB. A batch now edits in place and records each change in an undo
journal, which a failed batch rolls back, so the document is left as it
was (spans, tombstones, parent links and `modified` flags included; a
new test fails a nine-edit batch at each of its allocations and compares
the whole tree with a fresh parse; a second batch covers root, descent,
wildcard and block-item changes, and merge resolution is failed at each
of its allocations the same way). The same 800 sets take 74 ms and
leave the arena as it was. Merge-key resolution uses the same journal
instead of its own whole-tree clone. The alias checks that guard a delete
or replacement now walk the tree only when the doomed subtree defines an
anchor.

**A same-document clone set as the root or a block sequence item wrote
the wrong document.** `edit.cloneTree` keeps a copy's source spans, and
the emitter, finding the copy clean, wrote the bytes of the slot it was
copied from and carried on from where that slot ended. Set as the root
of `a: 1\nb: 2\n`, a clone of `$.a` was written `1\nb: 2\n`, which does
not parse; a clone of `- p` set as the root of `- p\n- q\n` vanished;
set, appended or inserted as a block sequence item it re-wrote the lines
after its source. Mapping values were already handled. Every attach now
clears the attached node's own span and marks it, so it is written at
its new position like a moved node, and a node set as the root leaves
its old parent. (Found while checking the undo journal.)

**A written leading comment next to a structural edit broke the
document or went to the wrong entry.** The comment sweep only wrote
comments; a second sweep now follows every write with one of five edits
next to it (delete the entry, its neighbours or the first entry; insert
before it), 7,334 cases, and checks that the output re-parses to the
tree the same edit gives without the comment, writes it at most once,
and puts it where the in-memory reads said it was. Run against the code
before these fixes it reports 1,936 failures: 102 outputs that do not
parse, 8 changed trees, and the rest comments that read back from a
different node than the one holding them in memory.

- A block written above a collection's first entry, with that entry then
  deleted or moved, was followed by the entry's indentation on top of the
  successor's own: `items:\n  # new\n    - name: y` (unparseable), or a
  mapping silently re-nested one level down.
- A block on a new first item left the original item after it at
  column 0, which did not parse.
- After an insert ahead of an item, a block written on that item went
  above the new first item: which entry shares a collection's line is
  now read from the tree as it is, not from the source lines. The reads
  follow the same rule, and a block on an entry that has since become
  first is still read.
- A collection's trailing comment read its source end, stale once its
  last entry changed; it now reads its last entry's. A `? key` with no
  value reads the comment written on its value, which follows the key.
- Comments written inside a new subtree (`$.c.x` after setting `$.c` to a
  new mapping) were accepted, read back in memory and dropped on write;
  they are refused with `error.InvalidSyntax`, as the emitter lays those
  subtrees out afresh. A block on an emptied block value is kept above
  its `{}`.
- A block written on a root sharing the `---` line came out as
  `--- \n    # new\n    {a: 1}`; the root now moves below it, at column 0
  (`---\n# new\n{a: 1}`).

A block written through any node on a line now replaces what is written
above that line, and lives as long as the outermost node on it: a
collection's first entry shares the collection's line, so its block
stays above whichever entry is first, as a source comment does, while a
later entry's block is deleted with it (`Document.setLeadingComments`,
USAGE). A leading block on an empty first entry (`- ` over `- b`) is now
written above the line it shares with its collection, where it reads
back, instead of being refused.

**Edits beside property lines and bare indicators.** Three edits wrote
YAML that does not parse, all on main:

- A new first entry of a collection whose anchor or tag sits on a line of
  its own went above that line: `&sequence\n- a` with an item inserted
  first became `- zz\n&sequence\n- a`, and setting its first entry
  moved that entry above it too. The preservation sweep skipped every
  such collection for this reason; it now sweeps them (488 deletes, 428
  sets, 173 inserts and 1,997 moves over the fixtures, up from 474, 418,
  166 and 1,955), where the code before this fix fails 16 of them.
- Emptying a collection whose `-` stood alone on the line above it
  (`-\n  - x`) wrote its `[]` at column 0, outside the item.
- Deleting an explicit-key pair whose `:` stood on a line of its own
  (`? a\n  :`) left the `:` behind (`{}\n  :`). A valueless pair now ends
  at its value indicator wherever it is, which also makes the position
  after that `:` a trailing comment position of the value.

**A write one level below an alias went through it.** `error.AliasPath`
fired only when the container being edited was itself the alias: with
`a: &x {k: 1, inner: {j: 2}}` and `b: *x`, `delete("$.b.k")` was refused
but `delete("$.b.inner.j")`, `set` of the same path, `$.b..j`, and an
insert, append or move through `$.b` edited the anchored mapping that
every alias shares. Queries now report when a match was reached by
stepping out of an alias, at any step or inside a descent, and every
write refuses that. A descent over the whole document reaches an
anchored node directly first, so `delete("$..j")` still deletes it.

**The fuzz harness.** Its header claimed Zig 0.16.0 has no
`std.testing.fuzz`; it has one, whose coverage-guided mode does not build
on that toolchain (a type error in its own test runner), and the note
now says so. Its list of expected errors was kept by hand and lacked
`AliasPath`, so the edit API's correct refusal of a write through an
alias would have been reported as a harness failure; the list is now
derived from the library's error sets.

**`parseAll` copied the whole stream into every document.** Each
document of a multi-document stream duplicated the *entire* input into
its own arena (its spans are offsets into the stream), so memory was
documents x stream: doubling the input quadrupled it, a 32 KiB stream of
tiny documents held 180 MB, and 1 MiB of `---\na: 1\n` (116,509
documents) wanted about 114 GiB, enough to exhaust a 64 GB machine,
while `max_input_bytes` (64 MiB) bounded nothing. The stream is now
copied once and shared by reference count: the last document to be
deinitialized frees it, documents stay valid in any order of release,
and the same 1 MiB stream holds about 190 MB (about 1.6 KB per document,
linear). Emitted bytes, spans and the public API are unchanged; the
conformance, round-trip, preservation and libfyaml gates produce
identical output. `SECURITY.md` and the memory model in `docs/USAGE.md`
now state what a stream costs. (#1)

**Writing a long one-line flow collection was quadratic.** Before
emitting, the emitter measures the document's indent width, and for
every mapping pair it took the key's column first, a scan back to the
start of the key's line, then checked whether it needed it (only a
block child compares against it). On a flow mapping that sits on one
line (minified JSON is exactly that) the scan is as long as the line,
so a `write` cost pairs x line length: 256 KB took 1.4 to 2.3 s, 1 MB
about 30 s, and every doubling of the input quadrupled it, while
parsing the same input is linear (about a second at 1 MB). The column
is now taken only where it is compared, so the same 256 KB writes in
0.2 to 1.1 ms. Output is byte-identical; the change reorders one
computation and nothing else. (#4)

**`writeAll` was quadratic in the number of documents.** Before
appending each document after the first, it asked whether the output so
far already ended in a `...` marker (so no `---` is needed), and
answered by walking every line of that output to find the last
non-blank one. That is the whole stream written so far, once per
document, so N documents cost N x output: 32 KB of tiny documents took
47 ms, every doubling quadrupled it, and a 1 MiB stream would take
close to a minute to write back. Scanning back to the start of the
last line is no better when a document ends mid-line (see the next
entry): the last line can be the whole buffer. The answer is now kept as
the output is written, so each byte is looked at once, and each document
is emitted on its own before it is joined on, so its emitter no longer
measures the line the previous document ended on (16,000 such documents
took 11 s to write, and take 9 ms). Parsed streams are written back
byte-identical:
the tracker is checked against the old definition on all 335,923
strings up to length 7 over the marker's dot, both blanks, every line
break and one byte of ordinary content, fed whole, one byte at a time
and split in two at every position. (#5)

**`writeAll` merged documents when one ended mid-line.** A document
parsed from text with no final line break is written back without one,
and the next document's bytes were appended to its last line, where a
`---` is not a marker: `--- x` and `--- y` were written `--- x--- y`,
one document holding `x--- y`. The same went for `x` then `--- y`, and
for `y` after a `...` with no line break (`x\n...y`, one document; with a
blank after the marker, a parse error). A directive after a document that
did not end with `...` became part of it (`x` then `%YAML 1.2\n--- y`
read back `x %YAML 1.2`), and a comment starting the next document was
glued to the value (`x# c`). `writeAll` now ends the line first unless the
next document's bytes only finish it with blanks or a comment (how a
parsed stream splits `--- x # c`), and closes the previous document with
`...` before a directive. Parsed streams are still written back
byte-identical.

**A hostile tag injected YAML structure when it was written back.** The
reader decodes `%XX` escapes in a tag, and the emitter wrote the decoded
bytes raw: `role: !!str%0Aadmin:%20true user` merged, moved or re-emitted
came out as `role: !!str` and a new key `admin: true user`. Tags are now
written with a handle for their prefix (the document's own `%TAG`
handles, else `!!` and `!` unless the document redefined them, which were
also ignored) and every byte outside the tag alphabet escaped, so they
read back as themselves; a tag with no spelling (a blank or `>` in a
verbatim tag) is refused with `error.InvalidSyntax`. A tag escape that
decodes to invalid UTF-8 (`!e!%ff`) is now a parse error, as in
libfyaml.

**Programmatic text the emitter could not spell was written raw.**
Found by a sweep of 310,536 built documents, each re-parsed by yayl and
by libfyaml:

- An alias used as a key was written `*r: v`, but `:` may be part of an
  anchor name, so it read back as an alias named `r:` (flow keys, and
  block keys after a value edit). It is written `*r : v`.
- A key over 1024 characters was written as an implicit key, which the
  spec (and yayl's own parser) refuses; it is now written `? key`.
- A string starting with a byte order mark was written plain at the
  start of a document, where the reader drops the mark as an encoding
  mark (`\u{FEFF}a` read back `a`); it is quoted now, and a block
  scalar line at column 0 never starts with one.
- C1 controls and U+FFFE/U+FFFF are not printable and may not appear raw;
  they are written as `\u` escapes in double quotes.
- A scalar that is not valid UTF-8 was written raw, output neither yayl
  nor libfyaml parses; the write now fails with `error.InvalidUtf8`. An
  anchor or alias name YAML cannot spell fails with
  `error.InvalidSyntax`, and `Document.setAnchor` refuses control
  characters, non-printable characters, invalid UTF-8 and the byte order
  mark as well as blanks and flow indicators.
- Two valid forms that libfyaml misreads are avoided: a root block
  scalar with an anchor or tag is written after `--- ` on the marker
  line, and a plain scalar starting with `:` in a flow collection is
  quoted.

**The value and schema layers disagreed with the core schema in
places.**

- The non-specific tag `!` resolved by content, so `! 12` was an
  integer; it is a string (spec example 6.28), as `!` on a collection
  was already a sequence or mapping.
- A core tag naming a different kind of node (`!!seq 42`, `!!int [1]`,
  `!!str {a: 1}`) was accepted; it is `error.TypeMismatch` from
  `yaml.value` and a type violation from `yaml.schema`, like `!!int abc`.
- `toZig` into a float returned an infinity for a value the type cannot
  hold (`1e39` into `f32`, `70000` into `f16`) where an integer target
  refuses one; it is `error.TypeMismatch` now. A `.bigint` converts to a
  float instead of failing, and `0o` and long `0x` integers convert to
  the nearest float: `std.fmt.parseFloat` does not read `0o` and
  truncated a long hex mantissa (`0x1FFFFFFFFFFFFFFFFFFF` came out one
  unit in the last place low), so `Schema.floatRange` also refused
  `0o17`.
- A tagged union's `void` field accepted any value; only null reads
  back into it, as `fromZig` writes it.
- `fromZig` of a non-exhaustive enum's unnamed value panicked in
  ReleaseSafe; it is `error.TypeMismatch`. A string literal
  (`.{ .name = "yayl" }`) became a sequence of bytes; it is a string.
- `toZig` failed to compile inside the library for sentinel slices
  (`[:0]const u8`), zero-length arrays and structs with `comptime`
  fields; all three convert.

**Schema validation was not bounded in bytes.** Each violation quotes
the value it rejects, and aliases repeat it: a 64 KiB anchored string
behind three levels of ten aliases made 1,000 violations and 62 MB from
a 65 KB input, and one more level passed 512 MB. `schema.Limits` has a
`max_bytes` (64 MiB by default, like `value.Limits.max_bytes`) charged
for violation text and the paths built on the way down.

**Three parse shapes were quadratic.**

- Every open simple key had its span recounted in codepoints on every
  token once it passed 1024 bytes: nested flow collections of multibyte
  text scanned at a few kilobytes a second (10 KB took 15.7 s in Debug,
  and takes 70 ms). The count is kept on the key.
- Each collection value searched its mapping's pairs from the front, so
  a mapping of mappings (`kN:\n  x: 1`) was quadratic: 80,000 entries
  took a second in ReleaseSafe.
- `%TAG` handles were found by a linear search, for the duplicate check
  and for every tag: 64,000 directives took 5 s.

**Parsing, diagnostics and files.**

- `.embedded_nul = .truncate` dropped everything after the NUL from the
  tree but not from the document's source, so a write emitted the NUL and
  the bytes after it, which a default parse refuses. They stay dropped.
- `parse` stopped at the first document's end event, so a first document
  followed by content that cannot begin another (`[1, 2] garbage`,
  `"a"\nb: 1`, `!a !b x`) came back as if whole, the rest dropped
  without a word. It fails now; a malformed *later* document still does
  not fail a single-document parse.
- An undefined alias and a failed merge-key resolution left the `Diag`
  empty, and invalid UTF-8 was always reported at 1:1. Each now records
  a positioned diagnostic.
- `file.readFile` refused a file of exactly `max_bytes`, which the parse
  accepts; `parseFile`'s `max_bytes` could lower the parse's input bound
  but not raise it, and files took no `ParseOptions`. See Changed.
- `file.writeBytesAtomic` (and `writeFile`) through a symbolic link
  replaced the link with a regular file and left the real file as it
  was; it replaces the file the link points to now. The temp file was
  named after the target plus a suffix, so a long but legal file name
  failed with `error.NameTooLong`; it has a short name of its own.
- SECURITY.md said merge keys are never resolved, and SECURITY.md and
  USAGE said the emitter admits two fewer levels than conversion; it
  admits up to two fewer, and one on a linear chain.

**Edits wrote YAML that did not parse, or that read back as another
tree.** A randomized differential over the fixtures and the corpus (about
63,000 edits and batches, each written, read back and compared with the
tree in memory) found these; each is pinned by a regression test:

- Any edit to a document opening with a byte order mark: its three bytes
  were counted as columns, so the first entry moved three columns in.
  The preservation sweep skipped such documents for this reason; it now
  sweeps them (42 variant documents, up from 28).
- A block scalar written by an edit took in what followed it: a comment
  after the old value on its line (`a: 1 # c` set to `x\ny` read back
  `y # c`), comment lines indented as deep as its content, and, for
  keep chomping, the blank lines after it. A block scalar now ends its
  own line, sits deeper than the comments after it, moves a same-line
  comment onto its header (`a: |- # c`), and a keep-chomped one takes
  over the blank lines it would absorb.
- A new block collection replacing a root that shared its line with
  `---` or a tab was written on that line (`--- - x`); content was glued
  to a document marker (`{}...`, `x...`, `---x`).
- An item whose dash carried a comment (`- # c\n  x`) had its span start
  at its content, so deleting it left a null item and setting it wrote
  the new item above the old dash.
- An empty new item left only `- ` on its line, and the next item read it
  as its own framing (`- - x`, a nested sequence); an item inserted
  first with a block scalar left the next item at column 0; once every
  original entry of a collection was gone, new ones went to the
  enclosing item's column (`-\n  - 42` refilled wrote `- x`).
- A written leading comment kept the caller's own indentation, which
  could put it inside a block scalar above; it is written at the entry's
  column, as documented.
- A replaced flow-mapping value lost its `:` when the colon was not
  right after the key (`{"foo"\n: "bar"}`, `{foo, b: 1}`).
- A new entry after a keep-chomped block in a CRLF document was written
  between the CR and the LF; a comment in a flow collection of a
  CR-terminated document hid a delete.
- An anchor set on, changed on or cleared from a parsed block collection
  or an empty value was never written; an empty key with an anchor or
  tag lost the blank before its `:` (`&c: b` defines `c:`).
- Deleting an entry with a null key (`: a`) left it in the output, and
  moving one copied it.
- A trailing comment written on the last entry of a file with no final
  line break was dropped; a new entry after a whitespace-only last line
  went inside the block scalar above it.
- Setting a node as a value of its own descendant panicked in ReleaseSafe;
  it is `error.WouldCycle`, as the append paths already returned.
- An anchor set on an alias was silently never written (YAML gives
  aliases no properties); it is `error.InvalidSyntax`.
- Defining an anchor name again ahead of an alias bound to the earlier
  definition (`setAnchor`, or a set, insert, append or move carrying the
  anchor) rebinds that alias once the document is written and read back,
  while in memory it kept its target; such an edit is refused with the
  new `error.AnchorShadowed`.
- A path starting `$` and a key character took the `$` for the root:
  `delete("$ref")` deleted `ref`. `$` is the root only before `.`, `[`
  or nothing, and text after a segment (`$.items[0]name`) is an invalid
  path.
- A set whose parent path matched several nodes reported
  `error.UnknownPath`; it is `error.AmbiguousOperation`.
- A replaced sequence item lost the comment on its line (a mapping
  value's kept it); it stays, on the block header for a block scalar. An
  item under a line holding several indicators (`- -` over a comment
  line) had its span start at its content, so deleting it left a null
  item. A new block scalar in a CRLF document broke its lines with `\n`.
  Clearing a collection's anchor that stood on a line of its own left the
  line empty.
- `writeAll` wrote nothing for a document built with no root, so its
  neighbours read back as one document; it writes an explicit empty
  document (`---`). A byte order mark opening a later document became
  content of it (`\u{FEFF}b: 2` a key); it is dropped there.
- `defaultTerminator` rescanned the source for its first line break on
  every call, a scan as long as the document for one written on a single
  line; it is taken once.

**The whole yaml-test-suite corpus passes, with no skips.** The 15
unnamed sub-cases that were tracked skips now pass: a `\<TAB>` escape in
a double-quoted scalar is a tab (3RLN, DE56, KH5V); a whitespace-only
last line deeper than a block scalar's indentation is content (`x` over
three spaces is `x\n \n`, L24T); and a tab is refused where it would
indent, as libfyaml refuses it: after `-`, `?` or an explicit key's `:`
ahead of a nested block construct (`-\t-`, `?\tkey:`), and ahead of a
quoted or flow continuation line's block column (DK95, Y79Y). Two valid
shapes were refused and are accepted: a blank line holding a tab after a
nested block collection (DK95), and a tab-indented comment line after a
plain scalar (`foo: 1` over `\t# c`). The round-trip and preservation
gates lose their skips with them. The non-specific tag `!` was resolved
through a `%TAG !` directive; it stays `!`.

**Edits whose output read back as a different document, or not at
all.** A randomized edit differential (edit, write, read back, compare
with the tree in memory; plain, CRLF, CR, byte-order-mark and
no-final-newline variants of the corpus and fixtures) found these, now
fixed and pinned by regression tests:

- A block scalar ending a file with no final line break, followed by a
  new entry: a keep-chomped `|+` value gained a line break, also when the
  block was nested in the last entry, and a last line of blanks that was
  content (`   ` under `  x`) was dropped.
- A keep-chomped block's trailing blank lines are its value, but a move
  or delete left them behind, and a moved copy wrote them again.
- Emptying the inner sequence of `- -` with another item after it wrote
  that item twice (`- []- y`); an item inserted ahead of such an empty
  item left it at column 0, an outer item; a document ending in one lost
  its final line break.
- An emptied sequence at its key's column under `- key:` wrote `[]` at
  the key's column, where it read as the next key.
- A block scalar was written above a line opening with a tab, which no
  reader accepts; such a value is quoted instead. A block scalar written
  ahead of comment or whitespace-only lines deeper than its content took
  them in; its content goes deeper than them.
- A new entry in a mapping whose first remaining entry is an explicit
  key with its `?` on a line of its own was written at the key text's
  column and did not parse.
- An alias placed ahead of its anchor, or over the node carrying it, was
  accepted and written as a document that does not parse; it is
  `error.AnchorReferenced`.
- A root replaced after leading blanks (`\t{}`) kept a tab as its
  indentation; an empty document's root anchor or tag (`--- &x`) was
  dropped; a byte order mark that is content (the first bytes of a key)
  became the stream's mark once what preceded it was deleted, and was
  lost.
- Properties over several lines (`&a` over `!!map`) lost their second
  line when an entry below was edited; an explicit key's new empty value
  with an anchor or tag was written on the key's line (`? a: &x`); a flow
  mapping key whose `:` ended its line had the new value glued to it.
- A move or delete of an entry that had moved up onto a deleted entry's
  line left that line's indentation in front of its successor, and a
  deleted explicit null key (`?` over `:`) left its `?` behind.
- Cosmetic: a new block value at the end of a mapping left a blank line
  after it, a literal block's empty lines were written indented, and an
  original block scalar re-emitted in place was indented at its `|`
  column rather than its content's.

**A second, independent randomized edit differential found more edits that
wrote another document, or none.** It runs the same check as the one
above, written again from scratch so that what one misses the other may
not (the corpus and fixtures in plain, CRLF, CR, byte-order-mark and
no-final-newline variants; random edits through the Editor API, each
written, read back and compared with the tree in memory), and it also
requires a batch that fails to leave the output byte-identical and a set to
an identical scalar to change no byte. On ten seeds (about 950,000
documents and 2.1 million edit batches) it reported 679 failures on the
release candidate (430 documents that read back as another tree, 234 that
did not parse, 15 that lost or gained a document), and 733 on ten fresh
seeds; it reports none on either set now, and every failed batch
(about 840,000 in each set) left the output byte-identical. What it found, now fixed
and pinned by tests that fail without the fix:

- A tag or anchor on a block collection under a key whose line ends in a
  comment, or with comment lines below it, was written at column 0, the
  key's own, where it reads as the key's sibling (`k: # note` / `&x` /
  `  - b` did not parse). It went there whenever the collection's first
  entry had been replaced, moved or deleted, and, for a sequence at its
  key's column, whenever that entry was given a comment. It is now on a
  line of its own at the entries' column, or one step in from the key when
  they sat at the key's.
- A tag or anchor on a root collection indented by a blank or more left
  its first entry at column 0 over its siblings (` &x` / `- a` /
  ` - b`), and a mapping root did not parse. The line after a root's
  properties was broken with a line feed in a CRLF or CR document
  (cosmetic: the document still read back).
- A block scalar written beside lines a deleted entry owned took a
  whitespace-only line, or a comment, from behind it into its value:
  the indentation it needs is measured from what will follow it, and the
  measurement stopped at the deleted entry. The blank lines a keep-chomped
  block takes were missed the same way when the entry behind it had been
  deleted.
- A trailing comment travelling with an item that became a block scalar's
  value was written after the block, where it can be read as a line of it
  (at a one-space indentation step, ` # c` under `|+` was content); it
  goes on the header line, as it does for an item of a sequence.
- A first document with no content (its root set to null, or left empty)
  was written as nothing, and `\n---\nb: 2` reads back as one document. It
  gets a `---` of its own, after the byte order mark if there is one.
- `? e` with no value, followed by a new entry with no key text, was
  written `: v`, the value of `e`; the new entry is written `?` over `: v`,
  in a sequence item's compact form (`- ? e`) too.
- A new entry beside an empty key that has properties (`- !!str : a`)
  was measured from the `:` after them, as far right as that column.
- Removing the entries ahead of a compact item's survivor left the
  survivor's own indentation behind the dash (`-   ports: [80]`) when a
  later entry had been deleted first.
- A new entry written straight after an empty item's `- ` or an emptied
  explicit key's `: ` continued that line (`s:` / `- t: x`, `? d` /
  `: n: x`), making it the item's or the value's own.

### Changed

- `edit.cloneTreeWhole` is removed. It existed for the clone the undo
  journal replaced, and nothing else called it; `cloneTree` (same
  document) and `cloneTreeInto` (another document) are unchanged.
- `edit.Error` and `edit.CloneError` no longer list `UnknownAlias`, which
  only `cloneTreeWhole` returned. With it went the other effect of that
  clone: any batch on a hand-built tree holding a forward alias (one
  whose anchor comes later) failed with `error.UnknownAlias`. Such a
  batch now runs, and one that would delete or replace the anchor is
  refused with `error.AnchorReferenced`, like any stranding edit.
- `Editor.one` returns `error.AmbiguousOperation` for a path that
  matches several nodes; it returned `error.UnknownPath`, as for a path
  that matches nothing, so the two could not be told apart (asked for in
  #12). The single-target edits (`insert`, `append`, `move`) report the
  same, as `set` already did.
- `Document.markModified` and `Document.retargetAliases` return an error
  union (`!void`): a batch records their changes in its undo journal,
  which can run out of memory. Callers add `try`.
- `value.Limits` has a `max_bytes` field and `ParseOptions` a
  `max_merge_nodes` field (see Fixed); `diag.YamlError` gains
  `LimitExceeded`.
- `schema.Limits` has a `max_bytes` field (see Fixed).
- `yaml.file` gains `parseFileOpts` and `parseAllFileOpts`, which take
  a `Diag` and `ParseOptions`; `parseFile` and `parseAllFile` pass their
  `max_bytes` to the parse as `max_input_bytes`, so it can raise the
  64 MiB default.
- Writes that used to produce unreadable output now fail:
  `error.InvalidUtf8` for a scalar that is not UTF-8, `error.InvalidSyntax`
  for an anchor, alias or tag that YAML cannot spell. `setAnchor` refuses
  more names (see Fixed).
- Conversions that used to succeed wrongly now return
  `error.TypeMismatch`: a tag naming another kind of node, a float out of
  its target's range, a non-null value for a `void` union field, and an
  unnamed non-exhaustive enum value. `! 12` converts to a string.
- `parse` fails on a first document followed by content that cannot
  begin another document.
- `writeFile` through a symbolic link replaces the link's target.
- `edit.Error` gains `AnchorShadowed` (see Fixed), which `setAnchor` can
  return too; `setAnchor` on an alias is `error.InvalidSyntax`.
- A path starting `$` followed by a key character is a key (`$ref`),
  and text after a segment is `error.InvalidPath`.
- A block scalar the emitter writes always ends its last line, and a
  written leading comment is written at the entry's column.
- A `move` of a subtree whose anchors or aliases cross its boundary was
  refused with `error.AnchorReferenced` whenever they did, even when every
  alias still followed its anchor afterwards. The batch is now judged on
  the tree it leaves: refused when an alias ends up ahead of its anchor,
  allowed otherwise. A batch that places an alias gets the same check.
- `Token.Scalar` and `Event.ScalarEvent` gain `content_end` (defaulted to
  null): where a block scalar's content ends in the source.
- The preservation sweep's list of unparseable sub-cases, and the gap it
  kept for L24T-2, are gone with the skips.
- `document.scalarCoreTag` returns `?CoreTag`: null when an explicit core
  tag contradicts the scalar's text (`!!int abc`, `!!int 0b101`) or names a
  collection (`!!seq 42`); it returned a tag whatever the text said.
  `value` and `schema` report those as `error.TypeMismatch`.
- `markup.leadingCommentSpan` takes a third argument, `floor`: the offset
  before which no line is part of the block (the end of what precedes the
  entry), so the content lines of a block scalar above are not read as
  comments. Pass 0 for the earlier behaviour.

### Added

- `Document.setTag(node, tag)` sets or clears a tag, refusing one the
  document cannot spell when it is set rather than when it is written.
- `Document.createAlias(target)` makes an alias to an anchored node, to
  place like any other node.
- Helpers the emitter and the value layer share are public in their
  modules: `document.coreTextFits`, `document.tagContradictsKind`,
  `scanner.max_simple_key_chars` and, in `markup`, `propertiesEnd`,
  `propertiesLineEnd`, `emptyItemDash` and `valueIndicatorEnd`. They serve
  the library's own layers.

## 0.19.3 — 2026-09-15

An independent review of the 0.19.2 tree found five high-severity
defects. All five are fixed here, each with a regression test.

### Fixed

**A `%YAML` directive could abort the process.** The minor version was
accumulated into a `u8` with no bound, so `%YAML 1.300` overflowed and
panicked (Debug/ReleaseSafe) or silently wrapped (ReleaseFast) on
untrusted input; `%YAML 1.250` was accepted unchecked. Versions are now
parsed into a wider accumulator and range-checked to the set libfyaml
accepts — 1.1, 1.2, and experimental 1.3 — with anything else returning
`error.UnsupportedVersion` before any allocation.

**A float `Value` panicked on emission.** `value.toNode` formatted a
float into a 64-byte buffer with `catch unreachable`, so a magnitude
like `1e300` (~301 decimal digits) hit `error.NoSpaceLeft` and panicked.
Floats now use a buffer that holds any finite `f64` in full decimal, and
gain a fractional part when the form would otherwise reparse as an
integer (`1.0` used to emit `1`, `-0.0` used to emit `-0`), so a float
Value round-trips as a float.

**Deleting or moving an anchored mapping KEY stranded its aliases.** The
stranding guard inspected only a pair's value, but a pair is removed key
and all, so `&k key: 1\nref: *k` with `$.key` deleted emitted `ref: *k`
with no `&k` — a document that does not reparse. `Editor` now guards the
key as well; `Document.mappingRemove`/`pathDelete` stay raw and are
documented as not performing the check.

**`sequenceInsert` could build a parent cycle and panic.** Unlike its
append siblings it skipped the cycle guard, so inserting an ancestor
under its own descendant tripped `markModified`'s assert. All three
attach paths now share one guard, which reports a cycle as
`error.WouldCycle` and a chain past the walk bound as
`error.NestingTooDeep`.

**An OOM while copying `%TAG` directives leaked the whole document
arena.** `parseStream`'s `document_start` arm only published the new
`Document` to the function-scope `errdefer` after the fallible
directive copy. It is now published before the first allocation, and the
allocation-failure sweep carries a custom `%TAG` case so the window is
actually exercised.

### Medium and low findings (second pass)

The same review's medium and low findings are fixed too, each with a
regression test:

- **Emitter M1/M2.** A scalar mapping key dropped its own `&anchor`/`!tag`
  in the normalized paths (non-scalar keys kept theirs); and
  `inferIndentStep` recursed the whole tree before the depth-checked walk,
  so a deep grafted subtree segfaulted instead of returning
  `error.NestingTooDeep`.
- **Scanner M3/M13, L12.** `max_nesting` bounded flow levels and block
  indents separately, admitting twice the documented cap; a control byte in
  an anchor/alias name silently truncated it; and `markOf` counted only LF,
  so a NUL diagnostic after a lone CR named the wrong line.
- **Schema M4/M5, value M6.** `strEnum`/`strLen` bypassed the core-tag
  gate; an integer too wide for `i64` was reported as "expected an integer"
  rather than a range violation; and `value`/`schema` now share one scalar
  interpreter (`parseCoreInt` / `parseCoreFloat`).
- **File M12.** Atomic writes took the umask default for the temp file, so
  rewriting a 0o600 secret widened it. The temp is now created restrictively
  and the target's exact mode is applied with `fchmod`; a create mode is
  umask-filtered, which narrowed a 0o666 target to 0o644.
- **Parser M14.** `%TAG` handles/prefixes are validated (`%TAG foo bar` and
  `%TAG !e tag:x` were accepted before).
- **Harness.** Two report writers share one JSON escaper; the round-trip
  report no longer stores every failure reason in one scratch buffer; a
  `fail: true` conformance case is only "rejected" for the declared error
  vocabulary (not `OutOfMemory`); the corpus loader frees every field on a
  partial allocation failure; the bench CLI no longer panics on a
  non-mapping root; `merge-differential` runs in CI; `bench-corpus.sh`
  globs the flat corpus; the emission oracle has a coverage floor; and
  `build.zig.zon` ships the merge-keys design doc and `SECURITY.md`.

### Corpus coverage correction

`tests/corpus_common.zig` dropped every corpus record without a `name`
field, which silently hid 46 real sub-cases. They are loaded now. Fifteen
of them fail (tab-marker escapes, tab strictness, one tree diff) and are
tracked as skips in `tests/conformance.zig` -- the round-trip and
preservation gates track the same set -- rather than left hidden. The
stale-skip guards fail the gate if any starts passing. Conformance is
382 pass / 15 skip / 0 fail.

## 0.19.2 — 2026-09-14

No library code changed. This release is the result of an independent
review of 0.19.1's assurance work, which found two real defects in it.

### Fixed

**`make merge-differential` crashed on a block scalar.** The comparator
split the canonical dump into lines and ignored the scalar length
prefix, so any merge source containing a multi-line value — `script: |`,
the ordinary case in the CI and Ansible configs merge keys exist for —
desynchronized the reader and aborted the gate. The grammar was
length-prefixed; the code that read it was not. It now parses by byte
offset and consumes exactly `len`. `tests/fixtures/merge/block-scalar.yaml`
covers it (and broke the old reader), and the compared floor rises to 8.

**The delete and set sweeps skipped complex-key documents.** Both routed
through `yaml.value`, which answers `error.TypeMismatch` for a non-scalar
key, so those documents had their semantic check silently dropped — the
same class of blind spot 0.19.1 fixed in `assertsSemanticRoundTrip`, in
the sweeps that call it. `nodeMinusEql` and `nodeSetEql` apply the same
rules to the node trees, comparing keys structurally. Semantic skips are
now 0 in all three sets (corpus was 3), and the corpus makes 95
structural comparisons where it made 92.

### Changed

**The preservation sweep reports which comparison ran.** Every run now
prints `semantic comparison: N via yaml.value, M via structural fallback`
and `semantic skips (yaml.value cannot represent): K` per set, so the
question "is the weaker path quietly becoming the common case?" is
answered by the gate instead of re-argued from a code reading. The
measured answer: the structural fallback is entered by the complex-key
operations and nothing else.

## 0.19.1 — 2026-09-14

No library code changed in this release: every entry below is assurance
work. The version moves so the gates that now exist are pinned to a tag.

### Added

**`make merge-differential` — a semantic differential for merge keys.**
The emission oracle's `merged` mode proves libfyaml can *parse* what yayl
emits after resolution; it cannot prove the resolved *values* agree,
because a merge that picks the wrong source still emits valid YAML. The
new gate dumps both sides in one canonical, length-prefixed form — yayl
through a `dump-merged` mode on the emit CLI, libfyaml through
`FYPCF_RESOLVE_DOCUMENT` — over `tests/fixtures/merge/`: 7 compared, 0
mismatches. Anchors, aliases and mapping entry order are normalized away
(see `docs/design/merge-keys.md` for why each is not part of a value);
sequence order is not. PORT NOTE: libfyaml's document path is alias-only
and rejects a repeated key, so three fixtures cannot be compared — they
are named and counted on every run, never silently skipped, and each must
still resolve under yayl.

**The GitLab CI fixture is a named gate.** `tests/fixtures/gitlab-anchors.yaml`
resolution is asserted in the unit suite: build-job and test-job gain the
template's `image`/`before_script`/`retry` and keep their own entries,
test-job's explicit `image` override survives the merge, and deploy-job —
which has no merge key — is the negative control proving resolution does
not leak into a mapping that never asked for it.

### Fixed

**The preservation sweep's semantic assertion was a no-op for complex
keys.** `assertsSemanticRoundTrip` did `nodeToValue(...) catch return`,
and `yaml.value` answers `error.TypeMismatch` for a non-scalar key — so
the assertion silently passed every document holding one, which is why
the `? K: V` emitter bug survived as long as it did. It now falls back to
a structural comparison of the edited and re-parsed trees; no
`catch return` remains, and a rootless/rooted mismatch is a failure.
The complex-add sweep's bespoke check is collapsed into it, verified
equivalent rather than assumed.

**CRLF documents are swept by the add and insert sweeps.** Those sweeps
skipped every CRLF document on grounds that predate
`Emitter.defaultTerminator`; the skip was stale and was hiding 314
targets in the variants set. Removed, at full line-shape strength rather
than routed through the weak branch. All three sets report 0 crlf skips.

## 0.19.0 — 2026-09-14

### Added

**Opt-in merge-key (`<<`) resolution.** YAML 1.2 dropped merge keys, but
Kubernetes, GitLab CI and Ansible files use them, so yayl expands them on
request. `ParseOptions.resolve_merge_keys = true` — or
`Document.resolveMergeKeys` on an existing document — treats a mapping pair
whose key is a plain `<<` as a merge: the value may be a mapping, an alias
to one, or a sequence of those; an explicit key in the mapping wins over a
merged one, and among sequence sources the earliest wins. The `<<` entry is
removed. `yaml.value.parseToValueResolved` is the read-only route. Off by
default, so a plain parse still reproduces the YAML 1.2 bytes exactly and
the round-trip and preservation gates are unchanged. Resolution is
merge-only: aliases outside the merged mapping are kept and anchors are not
purged, unlike libfyaml's `fy_document_resolve`. An invalid value is
`error.InvalidMergeKey`; a merge that reaches itself is
`error.MergeKeyRecursive`. See `docs/design/merge-keys.md`.

### Fixed

**A laid-out explicit key put its value indicator on the key's own line.**
`? K: V` re-reads as an explicit key that IS the mapping `{K: V}`, with a
null value, so a complex key and its value were both changed by a round
trip. `Emitter.emitEntry` now writes `? K`, a newline at the key's column,
then `:`. Only the laid-out path was affected; an unmodified entry still
re-emits from its source span. Reachable from any programmatic complex key,
and from merge resolution, which copies complex keys out of a merge source.
Found during review of the merge-key work.

**Structural line breaks ignored the document's CRLF convention.** The
emitter's laid-out paths — a brand-new entry's line, a restored break, a
written comment, an explicit-key indicator — hardcoded `\n`, so appending a
pair to a CRLF mapping left the previous entry terminated by a bare LF, and
merge resolution rewrote a CRLF mapping the same way.
`Emitter.defaultTerminator` now takes the convention from the source's first
break and every structural break uses it; a programmatic or single-line
source still breaks with `\n`. Found while adding CRLF coverage to the
merge-key tests.

### Changed

**The emission oracle checks a third path: merge resolution.** A `merged`
mode parses with `ParseOptions.resolve_merge_keys`, re-emits, and has the
vendored libfyaml parse the result — the first independent check of the
merge path's output. 816 emitted documents across the three modes, 0
findings. The oracle stays report-only in CI.

## 0.18.0 — 2026-09-07

### Fixed

**Cross-document clones no longer point into the document they came
from.** `edit.cloneTreeInto` copied a node's anchor, tag and written
comments by SLICE. Every one of those is duped into the SOURCE
document's pool, so the copy dangled the moment that document was
freed — reading the clone's anchor, or emitting it, was a use-after-free.
All four are now duped into the destination's pool. An alias whose
anchor lives outside the cloned subtree was worse: it kept a `*Node`
belonging to the other document (`resolveAlias` dereferences it
unconditionally, so every `isScalar`/`pairs`/`scalarValue` call on the
clone was a use-after-free) and emitted `*name` with no `&name` to match,
which does not parse. Such an alias is now FOLLOWED for its value, which
is what the function already documented; a second alias to the same name
still clones as an alias, pointing at the copy. The pair `src_end` and
the collection tombstones are byte offsets into the source, so they are
cleared with the rest of the spans instead of travelling to a document
where they mean nothing.

**A string that looks like another type survives a `yaml.value` round
trip.** `value.toNode` builds string scalars (and mapping keys) with
style `.any` — "emitter, you pick" — and the emitter picked plain
whenever the text was syntactically safe. So `Value{ .string = "90210" }`
went out as bare `90210` and came back a `.int`; a postal code became a
number, and `toZig` into a `[]const u8` field failed with
`error.TypeMismatch`. `.any` now quotes anything that would resolve to a
non-`str` core tag. `.plain` still means "the author wrote it bare" and
is untouched, so nothing about faithful re-emission changes.

**Plain scalars inside flow collections are quoted when they hold a flow
indicator.** `plainSafe` only inspected the FIRST byte for `,[]{}`, so an
edited flow item whose text contained one was emitted bare: setting an
item of `a: [x, y]` to `hello, world` produced `[hello, world, y]`, which
re-parses as three items, and a value containing `]` closed the sequence
early and left a syntax error behind. Flow context now disqualifies a
plain scalar holding any of `,[]{}` anywhere in the value.

**Block scalars the literal form cannot express fall back to quoting.**
`literalSafe` checked only `value[0]`, so `writeLiteral` produced blocks
that do not re-parse: content that is nothing but line breaks, a first
content line the reader would take the block's indentation from (leaving
every later line under-indented), and a line starting with a tab where
indentation is read. Found by the new emission-oracle mode below.

**`!!int` is no longer less capable than the bare form.** An untagged
integer too wide for `i64` kept its exact digits as `Value.bigint`;
adding the tag — which says MORE about the value — turned it into
`error.TypeMismatch`. Both paths now widen. `!!int abc` is still an
error: the tag has to be true.

**`value.fromZig` widens instead of failing.** A `u64` or `u128` past
`maxInt(i64)` — a byte count, a hash, a snowflake id — returned
`error.TypeMismatch` rather than using the `Value.bigint` that exists for
exactly this. A `comptime_int` past the range widened too, where it
previously would not compile.

**A non-scalar mapping key no longer walks past `deny_unknown`.**
`schema` skipped complex keys (`[a]: v`, spec 7.4.2) entirely, so a
strict map never reported them. No declared field can name one, so it is
unknown by construction and is now reported as such. Its value stays
unvalidated, exactly like the value under an unknown scalar key.

**`file.writeBytesAtomic` no longer refuses deep paths.** The temp name
went into a fixed 512-byte buffer, so a path longer than ~495 bytes —
well inside `PATH_MAX` on every platform — failed an otherwise valid
atomic write with `error.NoSpaceLeft`. The buffer is now sized from
`std.fs.max_path_bytes`, and a path the platform itself cannot represent
returns `error.NameTooLong`.

### Changed

**The emission oracle checks two emission paths, not one.** It only ever
re-emitted PARSED documents, where every scalar carries the style its
author wrote — so the emitter's own style-choosing code (`.any`, and the
block-scalar decisions) had never been seen by an independent parser. A
`value` mode now rebuilds each document through `yaml.value` before
emitting, which forces that decision for every scalar. Its first run
found three defects, all fixed above. 539 emitted documents across the
two modes, 0 findings. `tests/emit.zig` also returns the exit statuses it
always documented (3 = yayl rejected the input, 4 = mode not applicable);
both previously came out as 1, so the oracle could not tell them apart.

## 0.17.0 — 2026-09-06

If you are on 0.16.0 and delete entries, move to this release: 0.16.0
shipped with the indicator-only-line bug below, which makes a delete
next to an empty `- ` item write a document that does not re-parse.

### Added

**`Document.setAnchor(node, name)`.** Define or clear a node's anchor.
Clearing or renaming one an alias still names is refused with
`error.AnchorReferenced`; a name must use the YAML anchor alphabet (no
blanks, no `,[]{}`). This closes the last gap in the alias story: an
aliased SCALAR was immutable while referenced, because the anchor lives
on the node, `set` refused to replace that node, and no API could build
a replacement carrying an anchor. Now `set` treats a replacement that
carries the replaced node's anchor as the anchor moving with the slot,
and points the document's aliases at the new node:

    const two = try doc.createScalar("2", .plain);
    try doc.setAnchor(two, "x");
    try ed.set("$.a", two);      // a: &x 2 -- and $.b (*x) reads 2

A replacement without the anchor, or with a different one, is still
refused. Alongside, `apply`'s clone now re-registers scalar anchors as it
already did for collections, so an alias to an anchored scalar points
into the clone rather than at the pre-clone node.

**The emission oracle.** `make emission-oracle` (and a report-only CI
job) checks every document yayl emits over the corpus and fixtures with
an INDEPENDENT parser — the vendored libfyaml — closing the assurance
gap where yayl's own parser re-read yayl's output and shared its
author's assumptions. Parseability only: a byte-faithful emitter's
output is not supposed to match libfyaml's, it is supposed to parse.
First full run: 277/277 emitted documents accepted.

### Fixed

**`delete("$..k")` no longer fails backwards on its own grammar.** A
recursive-descent delete matched one node and errored
(`error.AmbiguousOperation`), and matched several and silently did
NOTHING — reported success while changing nothing. A trailing descent
now deletes every node it matches, in document order, atomically: any
victim whose removal would strand an alias refuses the whole delete,
and the prefix resolves through the full query grammar, so
`$..in..k` deletes every `k` beneath every `in`. USAGE documents the
semantics.

**An indicator-only line captured the entry below it.** `markup.entryStart`
walks back from a key to the `-`/`?` that introduces it and accepts an
indicator sitting alone on the previous line (the `-\n  content` shape).
It required only that nothing but blanks precede the indicator, never
that the content be indented UNDER it. So in `a: 1\nb:\n  - \nc: 1\n`,
key `c` at column 0 was handed the entry_start of the `-` at column 2;
emitting `c` re-wrote the item, and deleting `$.a` produced
`b:\n  - \n- \nc: 1\n`, which does not reparse. A block entry's content
always sits deeper than its indicator, so content at the same or a lower
column belongs to an enclosing collection. Not CR-specific — plain LF
reproduces identically; `? ` behaves the same way and is covered. The
long-run fuzzer, which had 7 of 8 seeds failing on this shape, is clean
at 100k iterations on all 8.

**Comment writes refuse bytes the scanner refuses.** `setTrailingComment`
and `setLeadingComments` validated for `#` and line breaks only, so text
that was not valid UTF-8 (or carried a NUL) was accepted, emitted raw,
and the written document then failed its own `parse` with
`error.InvalidUtf8`. The same boundary the lone-CR fix closed in 0.16.0,
from the other side: a write the library cannot read back is now refused
up front, `error.InvalidUtf8` for malformed UTF-8 and `error.InvalidSyntax`
for a NUL, leaving the document byte-identical. Everything the scanner
does accept inside a comment — NEL, LS, PS, a BOM, C0 controls, DEL, a
bare `#` — is still accepted and round-trips to the same tree.

**Recursive descent reported a node twice when an alias also reached
it.** `$..k` resolves aliases as it walks, so with `a: &x {k: 1}` and
`b: *x` the one `k` came back as two matches from `ed.all`, and a
caller applying one edit per match applied it twice. Each query now
reports every node once, first occurrence in document order; the
descent delete collects its victims the same way. `$.b..k`, where the
walk has to go through the alias to find anything, still finds it.

### Documentation

Anchor-obligation checks are by name, not position: with a shadowed
anchor (`- &x 1`, `- &x 2`, `- *x`) deleting the first item is refused
although the alias resolves to the second. Safe side; USAGE says so.

## 0.16.0 — 2026-09-05

### Fixed

**`parse` kept dropping the document's tail.** The single-document
entry point stopped before the stream-end bookkeeping that hands the
last document its tail, so `write(parse("a: 1\n# c\n"))` came back as
`a: 1\n` — the exact "eats your comments" failure this library exists
to prevent, through the most common API. `parseAll` was always exact.
The tail is now claimed when only blank and comment lines follow the
first document; a `---`, a directive, or a bare document after `...`
still clamps the region in front of the next one, and a malformed
second document still cannot fail a successful first parse.

**Deleting the last real entry glued the emptied container to a
surviving tail comment.** `# head\nkey: value # tail\n# delta` minus
`$.key` emitted `{}# delta` — the deleted entry's tombstone consumed
the terminator separating `{}` from the comment. Found by the fuzz
harness's edit oracle the moment the tail stopped being dropped. The
tail now re-owns the break when the first live byte after the
deletions is a comment and the cursor is mid-line.

**Emptying a nested block sequence deleted the outer item too.**
`dropItemSpan` kept the outer `- ` only when a successor could move up
onto its line; deleting the LAST inner item took the whole line,
indicator included. `- - x` minus `$[0][0]` emitted a bare `[]`, and
under a key the `[]` landed at the parent's column, which does not
parse. Mappings already got this right (`- a: 1` minus `$[0].a` is
`- {}`); sequences now mirror the three cases: successor moves up, a
comment in between keeps the indicator on its own line, no successor
leaves `- []`.

**A modified scalar or flow sequence item lost its `- `.** The item
indicator lives in the bytes ahead of the item's content. A block
collection's slot walk re-emits it with the first entry, but a scalar,
an alias, or a flow collection is written from the content start, and
nothing wrote the indicator: `- {a: 1}` with `$[0].a` set came out as
`{a: Z}` at the parent's column, a trailing comment written on `- a`
produced `a # c`, and a refilled `- {}` emitted `{c: Z}`, which does
not parse. `emitItem` writes the framing for those items now.

**Emptying a container ate the comments between its entries.**
Deleting every entry re-emits `{}` / `[]` straight from the tree, and
that skipped the container's source entirely — `a: 1\n# note\nb: 2`
minus both entries came back as `{}`, although deleting them one at a
time kept the comment. The lines the tombstones leave are written
verbatim, then the empty collection follows on its own line at the
value's column (`# note\n{}`; nested, `m:\n  # note\n  {}`).

**A leading comment written on the first item opened the file with a
blank line.** `writePendingLeadingText` broke the line whenever the
output did not end in a newline, which an empty output does not.

**A deleted entry came back when its emptied container gained a new
one.** Deleting the sole entry of a mapping empties it (`{}`); adding an
entry afterwards, in the same session, re-emitted the deleted line ahead
of the new one: `a: 1` minus `$.a` plus `$.b` wrote `a: 1\nb: Z\n`. The
brand-new-entry path copied "the rest of the open line" verbatim,
without consulting tombstones — and at the start of a container that
line *is* the tombstone. At the root the deleted entry resurrected; at
the first item of a sequence the new key was glued after the old one
(`- c: 3\nc: Z`), which does not parse. Found by a compose probe (two
edits in memory versus edit, write, reparse, edit). The remainder is
now written only when a previous *entry* holds the line open, and
through the tombstone-aware gap walk.

**Deleting an explicit-key entry left a null key behind.** The pair
tombstone treated the `? ` of an explicit key like a sequence item's
`- ` indicator — framing that outlives the entry — so `? a\n: 1\n? b\n:
2\n` minus `$.b` emitted `? a\n: 1\n? \n`, which reads back as
`{a: 1, null: null}`. Only a `- ` ahead of the key on its line is kept
now (`- ? a` still keeps its `- `).

**A comment write could smuggle document structure through a lone CR.**
`setLeadingComments` validated its text by splitting on `\n` and
requiring each line to start with `#`. A lone `\r` is a YAML line break
but not a `\n`, so `"# c\rinjected: yes"` was one "line" starting with
`#`: it passed validation, was emitted raw, and came back on reparse as
a real mapping entry. Caller input crossing a validation boundary into
document structure. `setTrailingComment` already refused CR outright;
the leading side has to permit CRLF between lines, so it now refuses the
lone form specifically.

**An edit in a CR-terminated document duplicated an entry.**
`markup.entryStart` walks back from a key to find the `-` or `?` that
introduces it, and stepped back TWO bytes over a `\r`, assuming it was
the LF of a CRLF. For a *lone* CR that lands inside the previous line,
so in `a: 1\rb:\r  - x\rc:\r` the key `c` looked as though it sat under
the `-`, its `entry_start` pointed there, and emitting the entry
re-wrote the sequence item:

    delete $.a  ->  b:\r  - x\n- x\rc:\r

Duplicated content, an LF smuggled into a CR document, and output that
does not reparse. The unedited round trip was unaffected — the region is
one verbatim slice — which is why no round-trip gate saw it. CRLF and LF
were always correct and stay so.

**A comment-only file was erased by a round trip.** A stream with no node
content produced no document, so there was nothing to re-emit and
`writeAll(parseAll("# c\n"))` returned the empty string. For a library
whose pitch is that the others eat your comments, silently emptying a
fully commented-out config file is the one answer it cannot give.

Such a stream now yields **one document with a null root** whose region
carries those bytes, and the faithful emitter writes them back verbatim.
Genuinely empty input still yields no documents — there are no bytes to
preserve.

This removed the last four entries from the round-trip skip table
(`HWV9`, `8G76`, `98YD`, `QT73`, all "no document in stream"), taking the
corpus round trip from **265 pass / 4 skip to 269 pass / 0 skip**. The
table's own stale-skip assertion is what caught that they had outlived
the bug.

**Behaviour change worth checking before upgrading:** `parseAll` now
returns 1 rather than 0 for a stream of only comments, blank lines, or a
lone `...`. Consumers that iterate documents must tolerate
`root == null` — which `parse` could already return. The previous
behaviour matched libfyaml, but libfyaml does not promise byte-faithful
round trips and this library does.

**An edit that would strand an alias is refused instead of corrupting.**
An anchor lives on the node that defines it, so deleting or replacing
that node while `*name` survives emitted a document that does not parse
(`error.UnknownAlias` on the way back in). `delete` and `set` now return
`error.AnchorReferenced` when the target subtree defines an anchor an
alias outside it still references. The preservation sweep knew the shape
and *skipped* those positions rather than asserting, so nothing caught
that the output was unreadable.

Two consequences worth knowing. Deleting the alias, or an anchor nothing
references, is unaffected. But a `set` on a referenced anchored node is
now always refused, because `createScalar` cannot attach an anchor and
so no replacement carrying `&name` can be constructed — a real builder
limitation, and still strictly better than emitting a broken document.

**Mutating through an alias path is refused instead of failing
dishonestly.** Reads forward through aliases; writes did not, and their
failures lied: `set`/`append`/`insert` through an alias container
surfaced as `error.InvalidSyntax`, blaming the path, and `delete`
through one reported SUCCESS while changing nothing. Every mutation
entry point now refuses an alias container with the new
`error.AliasPath`. Editing the anchor's side remains the supported
route — the target is shared, so the alias reflects the change.

**A move can no longer put an alias ahead of its anchor.** `move` was
exempt from the anchor-stranding check because it keeps both nodes in
the document — but an alias needs its anchor to come before it, and a
move only ever appends at the destination, so moving `- &x 1` to the
root of `- &x 1\n- *x` emitted `- *x` first: unparseable. A move is now
refused (`error.AnchorReferenced`) when an anchor/alias pair crosses the
moved subtree's boundary in either direction; a move where both ends
travel together keeps working.

**Deleting a sibling could corrupt a document into unparseable bytes.**
An entry whose key is a synthesized empty scalar (`: 1`) has no bytes of
its own — its span is a point borrowed from the following token — and
`emitPairEdited` skipped the whole leading-gap block for such a key. The
gap is where the terminator separating it from the previous entry lives,
so deleting any sibling dropped that terminator and joined two lines:
`a: 1\nb:\n  - y: z\n: 1\n` minus `$.a` emitted `b:\n  - y: z: 1\n`,
which this library cannot reparse. Only the edited path reaches that
code — an untouched region is emitted verbatim in one slice — so no
round-trip gate could see it.

**A wholly CR-terminated stream was neither byte-faithful nor a
fixpoint.** Three sites knew only `\n` and a lone-CR document hit them
together: `Emitter.endsWithNewline` read a trailing `\r` as "not at a
line start" and wrote a second terminator; `Emitter.pendingLine`
measured the current column from the last `\n`, spanning CR-terminated
lines, which is the column re-emitted blocks are indented against; and
`startsDocument`/`endsStream` split on `\n` before trimming `\r`, so
`---\r-` was a single line, did not read as a marker, and `writeAll`
injected another `---`. `-\r---\r-` re-emitted as `-\r\n---\n---\r-`
and grew from there. Found at seed 303, iteration 224765.

### Changed

**Read paths walk sequence indices.** A `pathGet`/`Node.byPath`
segment that parses as a decimal number now indexes into a sequence —
`pathGet(&.{ "items", "0" })` is the first item — mirroring the edit
grammar's `[N]`, so a read no longer needs to drop to
`lookup(...).items()[...]` by hand. On a mapping the same segment stays
an ordinary key; `pathSet`/`pathDelete` remain key-walkers.

**The fuzz harness applies seed transforms, not just mutations.** Byte
flips almost never produce a document terminated *consistently* one way,
but that global shape is what the line-handling code branches on — the
emitter's terminator convention only matters when a whole document uses
it. Every seed now also runs with its line endings rewritten to CR and
to CRLF, taking the long run from 381 seeds to 1143 and reaching that
class deliberately rather than by luck.

**The fuzz harness checks that independent edits commute.** Two edits at
positions where neither path is a prefix of the other must produce the
same bytes in either order; if they do not, one left the other's spans
or tombstones in a state that depends on when it ran.

**The fuzz harness checks that an edited document still reparses and is
still a fixpoint.** `fuzzOnce` asserted write/reparse/write stability for
untouched documents only, but a modified document travels a different
path through the emitter — stale spans, live tombstones, subtrees
re-emitted normalized in place. The two unbounded-growth bugs fixed in
0.15.0 were violations of exactly that property on the untouched path;
nothing was checking the edited one. It found the delete corruption
above on its first run.

**The fuzz harness derives edit paths from the parsed tree.** It used
eight literal paths, which on a mutated non-mapping input resolve to
nothing, so the edit surface saw almost no real positions. Paths are now
built by walking each document, giving two oracles: a derived path must
resolve to the node it was derived for (pointer equality), and setting a
scalar to the value it already has must re-emit byte for byte. Duplicate
keys and nodes carrying an anchor or tag are excluded, both for
documented reasons.

## 0.15.0 — 2026-09-04

### Fixed

**Recursive walks over the node graph are depth-bounded.** `nodeToValue`,
`Schema.validate`, `$..key` edit descent and subtree cloning all recursed
with no depth bound. Conversion and validation carried only a node-count
budget (`max_values`/`max_nodes`, 1,048,576), and a count cannot stand in
for a depth: a linear chain of N nested collections is N values but N
stack frames.

Two inputs reach it, and **one of them is parsed, not built**. An alias
may name an enclosing anchor: `&a [*a]` is eight bytes, parses (libyaml
accepts it too), and describes a cycle of unbounded depth, because
resolving the alias yields the sequence that contains it. `max_nesting`
does not bound that — the cap is on syntactic nesting, not on the alias
graph. Separately, a tree built through `createSequence`/`sequenceAppend`
can nest arbitrarily deep.

On v0.14.0 both abort the process rather than returning an error:
`value.nodeToValue` on `&a [*a]` segfaults, `Editor.all("$..key")` on
`&a {k: *a}` (eleven bytes) segfaults, and a built chain past roughly
4,000 to 8,000 levels does the same. **Consumers handling untrusted YAML
should upgrade.**

`value.Limits` and `schema.Limits` now carry `max_depth`, and `edit` a
`max_walk_depth`, all defaulting to 1000 to sit alongside
`Emitter.max_depth`, all returning `error.NestingTooDeep`. Note the
bounds are close but not identical: the emitter admits two levels fewer,
since it charges extra where emission crosses between its faithful,
normalized and flow modes — at default limits a 999-node path converts
and validates but does not emit. `Limits.unlimited` lifts the depth
bound too, re-arming the hazard, and now says so.

This was the second of the three v0.12.0 audit suspicions, whose original
text was recovered from the session record on 2026-09-03. The parsed
alias cycle was not part of it — an adversarial review of the fix found
that, and it is the more serious half.

**Explicit core tags are honoured by conversion and validation.**
`!!str 42` converted to the integer `42`, and `Schema.str` reported a
type violation on it, because the typed surface read the plain-scalar
resolution and ignored the tag the node carried. Now `!!str 42` is the
string `"42"`, `!!int '7'` is the integer `7`, and both surfaces agree.
A tag whose content cannot be read as the type it names (`!!int abc`) is
`error.TypeMismatch` rather than a silent fallback. Non-core tags are
unaffected, as are untagged scalars.

**Building a parent cycle is refused instead of hanging.**
`sequenceAppend(s, s)`, or appending `a` under `b` and then `b` under
`a`, left `markModified` walking the `parent` chain forever: 100% CPU,
no error, no crash. `mappingAppend` and `sequenceAppend` now return
`error.WouldCycle` when the child is the target or one of its ancestors,
and the parent walk is bounded so a cycle can never become a hang again.

**A lone CR let a document swallow the next document's marker, and the
round trip grew without bound.** YAML 1.2 §5.4 makes a lone `\r` a line
break (`b-break ::= CRLF | CR | LF`) and the scanner treats it as one, so
`x\r---\n` is two documents. But `markup.lineStart`/`lineEnd`/`newlineAt`
scanned for `\n` only, so the first document's source region ran past the
CR and swallowed the `---\n` belonging to the second. Emission then wrote
those bytes as document one's content *and* a fresh `---` for document
two, so each round trip added four bytes — 6, 10, 14, and on forever.
Both byte-faithfulness and emitter idempotence were broken by six bytes
of input.

The three line-scanning helpers now recognise all three break spellings,
keeping CRLF a single break so an offset can never land between the two
bytes. `Emitter.terminatorAt` follows, since `newlineAt` now reports the
CR of a CRLF rather than the LF.

Found by the extended fuzz harness at seed 987654321, iteration 28041 —
the first campaign run after the corpus was actually being loaded.

**A synthesized trailing empty scalar let a document swallow the next
marker too.** Same growth, a different route in: when a root's last
descendant is a synthesized empty scalar, the root's `end` is a point
borrowed from the following token and already sits on the next line, so
running to that line's end took in the `---` that marks the next
document. `-\n---\n` grew by four bytes per round trip, without bound.
`finishRegion` already guarded this for a *synthetic root* (corpus
6XDY), but that check cannot see a real root whose last child is
synthetic. Implicit regions are now clamped so they can never reach into
a `---` or `...` line. Found by the extended fuzz harness at seed 44444,
iteration 43175.

**The fuzz harness reaches the consuming surfaces.** It drove `parseAll`,
`writeAll` and the event API only, so every defect in `value`, `schema`
and `edit` was structurally outside what it could find — which is why the
depth-bound crashes, the parsed alias cycle, the ignored core tags and the
parent-cycle hang all had to be found by hand. Each iteration now also
converts to a `Value` and back through `toNode`, validates against nine
schema shapes (including a self-referential one that descends per
document level, and a composition), and resolves eight paths before
applying a mutating edit batch and re-parsing the result. The typed-error
vocabulary was widened to match.

**The long fuzz target never loaded the corpus it advertised.** It looked
for `vendor/yaml-test-suite/src/<case>/in.yaml`, but the vendored tree is
flat `<case>.yaml` files, so the directory check skipped all 351 of them
and every long run was seeded from the 30 built-in and fixture seeds.
Both layouts are accepted now: `zig build fuzz` goes from 30 seeds to
381.

### Changed

**Error sets gained new members.** `schema.Error` and `edit.Error` gained
`NestingTooDeep` for the depth bounds; `edit.Error` and `value.Error`
gained `WouldCycle` for the attach guard. Callers that switch
exhaustively over any of these need new arms. `value.Error` already
admitted `NestingTooDeep` through `YamlError`.

**The scanner/parser allocation-failure sweep got much broader.** It ran
on a flat four-line mapping, which the v0.12.0 audit flagged as missing
"most of the allocating surface" — no anchors, aliases, tags, flow
collections or block scalars — while `scanner.zig` (63 allocator sites)
and `parser.zig` (18) have no sweep of their own. The sweep input now
carries all of those plus directives, comments, both block scalar styles
with chomping, and both quoted styles, taking one parse from 32
allocation-failure points to 112. A test asserts the breadth so it
cannot quietly regress. This was the third audit suspicion.

## 0.14.0 — 2026-09-02

### Added

**Comments are addressable.** `node.trailingComment(&doc)` and
`node.leadingComments(&doc)` return a node's trailing and leading
comments as raw slices into the source (`"# user facing"`), and
`doc.setTrailingComment(node, text)` / `doc.setLeadingComments(node,
text)` write, change, and delete them (`null` deletes). Written
comments re-emit canonically — `content # text`, leading lines at the
entry's column, the document's line-ending convention kept — and
re-setting the comment a node already has is a byte-identical no-op,
asserted per comment position by the preservation sweep. Reads are
safe by construction: they compute spans over bytes the emitter
already copies, so no emitted byte can change. Free-floating comments
(blank-line-separated, document head before `---`) and comments inside
flow collections are out of scope and stay pure source bytes. Design
and rationale: `docs/design/comments.md`.

### Fixed

- `Document.parse` + `write` no longer drop a trailing comment on the
  root node's own line (`a: 1 # c`): the document's round-trip region
  now ends where the root's last line ends. `parseAll` masked this by
  attributing those bytes to the next document's head; a single
  `parse` lost them.
- Deleting the first item of a block sequence when that item is an
  empty scalar (`- # Empty`) was a silent no-op: the item's span is a
  borrowed point, so no tombstone was recorded and the next item's gap
  re-emitted the deleted line verbatim.
- Inserting into a sequence after a line that ends in trailing blanks
  (tabs or spaces before the line break) migrated those blanks onto
  the wrong line; a brand-new entry now carries the previous entry's
  line remainder with it.
- A TAB in a block scalar header (`fold: >\t-`) passed the
  whitespace check, left the scanner mid-line, and leaked the rest of
  the header line into the content loop, where an arithmetic underflow
  panicked (`integer overflow` in `scanBlockScalar`). Found by the new
  fuzz harness on its first long run; the header now accepts spaces
  and tabs and rejects anything else before the line break with a
  typed error.
- Replacing a mapping value with a node that carries presentation
  spans from elsewhere — a `cloneTree` copy — silently re-emitted the
  original bytes instead of the replacement (or read out of bounds
  when the span named a shorter source). Replacements now re-emit
  normalized; `edit.cloneTreeInto` is the safe cross-document form.

### Added

**Fuzzing.** A deterministic seeded harness (`src/fuzz.zig`) mutates a
seed corpus — embedded shapes, the fixtures, and vendored
yaml-test-suite inputs — and asserts the contract: parse or a typed
error, safe emission, re-parse, and write idempotence. A bounded smoke
runs inside `zig build test`; `zig build fuzz -- <seed> <iterations>`
is the reproducible long-run target (the same seed replays the same
inputs, so a reported failure is rerunnable).

**Cross-document copies.** `yaml.edit.cloneTreeInto(doc, node)`
deep-clones a subtree into another document with spans cleared — the
copy re-emits normalized, like a moved subtree. (`cloneTree` remains
the same-document form the editor's batches use.)

**Benchmarks in CI.** `scripts/bench-corpus.sh` times the hot paths
(parse, write, round trip, edit+write) over the fixtures and a bounded
corpus slice, printing stable machine-readable lines; CI runs it as a
report-only job (`continue-on-error`) — numbers, never gates.

**Security policy.** `SECURITY.md` documents the reporting channel and
the actual threat model for untrusted input: every bound (input size,
nesting, alias expansion, emission depth, NUL policy), its default,
and how to change it.

**Examples** for the value, schema, and file surfaces
(`examples/values.zig`, `examples/schema.zig`, `examples/files.zig`),
compile-checked and wired into `zig build examples` alongside the
`yq_lite` dogfood tool, whose full-surface demo now also RUNS in the
examples build.

## 0.13.0 — 2026-09-02

### Behaviour changes — read this before upgrading

Two calls that used to succeed can now return an error. Both are
deliberate and both have an opt-out; neither is a silent change.

**A NUL byte in the input is rejected** — `error.InvalidSyntax`, with a
positioned diagnostic — where it previously truncated the input at that
byte and parsed the prefix as if nothing were missing.

The old behaviour was libyaml's, where a C string has no choice about
ending at a NUL. Zig has a length and no such constraint, and YAML 1.2
does not admit the byte at all (spec 5.1 `c-printable` excludes #x0).
The decisive argument is what it did to this library's own headline
workflow: `Document.source` kept the *truncated* slice, and faithful
emission writes `source` back out, so `parse` → edit → `write` on a file
containing a stray NUL silently destroyed everything after it — in the
file. That is data destruction on the primary path, not a compatibility
quirk.

To restore the old behaviour, opt in explicitly:

```zig
var doc = try yaml.parseOpts(allocator, input, null, .{ .embedded_nul = .truncate });
```

A UTF-16 stream (which is mostly NULs to a byte reader) is now named as
such — `error.InvalidUtf8`, "input has a UTF-16 byte order mark" —
rather than reported as a stray NUL.

**Input over 64 MiB is rejected** with the new `error.InputTooLarge`,
where the in-memory entry points previously had no bound at all. If you
stream large documents through `yaml.parse`, raise it:

```zig
var doc = try yaml.parseOpts(allocator, input, null, .{ .max_input_bytes = 512 << 20 });
```

### Added

- `yaml.writeAll(allocator, docs)` serializes a whole stream — the
  counterpart `parseAll` never had. `writeAll(parseAll(input))` is
  byte-exact, and unlike concatenating `doc.write()` by hand it cannot
  silently merge two documents into one: without a `---` between them,
  two mappings become one mapping with duplicate keys. A marker is
  inserted only where a boundary is required and absent.

  The round-trip gate now runs through `writeAll` rather than a
  hand-rolled concatenation, so the byte-exactness claim is checked
  against the whole corpus (265 streams) rather than the unit tests'
  handful of shapes. It caught one: corpus L383, where a document's
  region ends mid-line at `--- foo` and its own trailing comment belongs
  to the *next* document's leading bytes.

- `EmitOptions`, via `Document.writeOpts` and `writeAllOpts`, chooses
  the indent width for content the emitter lays out itself and carries
  the emission depth bound. A parsed document still measures its own
  convention by default — a new subtree should match the file it lands
  in — but a document built from nothing had no convention to measure
  and no way to say what it wanted; it was 2 spaces, always. The value
  is clamped to 1..8, since 0 would emit YAML that does not re-parse.

  It cannot affect bytes that re-emit verbatim, and there is a test
  that asserts exactly that: the round-trip guarantee outranks a layout
  preference.

- `toZig` / `fromZig` handle the three shapes they were rejecting.

  **String-keyed maps.** A `labels:` block whose keys are the data had
  no typed path at all: a YAML mapping could only become a fixed
  struct. All four std spellings work — `StringHashMap`,
  `StringHashMapUnmanaged`, `StringArrayHashMap`,
  `StringArrayHashMapUnmanaged` — recognised by shape rather than by
  name. The array-backed ones keep insertion order. On a duplicate key
  the first wins, matching `Node.lookup`.

  **Tagged unions**, externally tagged as JSON does it: one entry keyed
  by the active field, `void` written as null. Zero entries or two is
  `error.TypeMismatch`, not a guess; an untagged union stays
  `error.UnsupportedType`, since nothing names the active field.

  **Single-item pointers in `toZig`.** `fromZig` already serialized a
  `*T` by dereferencing it, so a type the library could write it could
  not read back.

- Schema gains the constraints it was missing: `floatRange`, `strLen`
  (counted in codepoints, so a multibyte name is not penalised),
  `seqLen`, `nullable`, and the compositions `allOf` / `anyOf` /
  `oneOf`. `nullable` is the distinction a non-required field could not
  express — the key must be present, its value may be null.

  `anyOf` and `oneOf` report one violation naming the composition
  instead of the failures of every branch, since a branch that does not
  apply is not an error; `allOf` reports each failing branch. Branch
  exploration shares the enclosing `Limits` budget, so a composite
  cannot multiply work past the bound.

  `Kind.seq` changed payload from `*const Schema` to a struct carrying
  the item schema and optional length bounds. `Schema.seq(items)` is
  unchanged; only code building `.kind = .{ .seq = ... }` by hand is
  affected.

  Still absent, deliberately: a regex/pattern constraint. Zig's standard
  library has no regex engine, and vendoring one to back a single
  descriptor is the wrong trade.

- `ParseOptions` and the `parseOpts` / `parseAllOpts` entry points
  (`Document.parseOpts` / `parseAllOpts` underneath) put the parse
  bounds in the caller's hands. `max_input_bytes` (64 MiB) is a new
  bound: the in-memory entry points had none, and `yaml.file`'s limit
  only ever covered reads from disk. `max_nesting` (200) was previously
  reachable only by hand-rolling a `Scanner`. Over-long input fails with
  the new `error.InputTooLarge` before it is scanned.

### Fixed

- Emission is depth-bounded. `Emitter` carries `max_depth` (1000) and
  returns `error.NestingTooDeep` past it. 0.12.0 bounded the two layers
  that copy — `value` and `schema` — but `Document.write` was still
  unbounded: `emitContent`/`emitNode`/`emitFlowBody` recurse per nesting
  level, and the scanner's 200-level cap does not apply to a tree that
  was never scanned. A document built through `createSequence` +
  `sequenceAppend` in a loop, or through `value.toNode` from a deep Zig
  value, overflowed the native stack instead of returning an error.
  Parsed documents cannot reach the bound.

## 0.12.0 — 2026-09-01

### Added

- `value.Limits` and `schema.Limits` bound alias expansion, with
  `parseToValueLimited`, `nodeToValueLimited` and
  `Schema.validateLimited` to set one and `Limits.unlimited` to opt out.
  Both layers expand aliases by copying, so output size is a function of
  the expanded tree rather than of the input: N levels each aliasing the
  level above M times is M^N values. A 194-byte document reached ~19,530
  values at 6×5; 10×10 is 10^10. The default bound is 1 << 20 for both,
  and exceeding it returns the new `error.LimitExceeded` rather than
  allocating without end.

  The scanner's existing caps (nesting 200, simple-key length) already
  covered the scanner, parser, document and emitter layers — an alias
  stays one node there. This is the second bound, for the two layers
  that copy. Note that a schema only walks the expansion if it recurses:
  `Schema.any` returns without descending, so it visits exactly one node
  whatever it is pointed at.

### Changed

- `sequenceReplace` and `mappingReplace` moved to `src/internal.zig`,
  completing the move below. They are the same leak and were missed the
  first time — `sequenceReplace`'s own doc comment said "Not part of the
  supported API" while it was reachable as
  `yaml.Document.sequenceReplace`. The public surface of `yaml.Document`
  is now 22 declarations; all six internals are compile errors from a
  consumer.

- The INTERNAL document-model plumbing — `attachPair`, `attachItem`,
  `dropPairSpan`, `dropItemSpan` — moved from `Document` methods to free
  functions in `src/internal.zig`, a file the module root never
  re-exports. They were always documented as unsupported (`pub` only
  because `edit.zig` calls them across a file boundary), but as methods
  they travelled with the flattened `yaml.Document` type and stayed
  reachable to downstream consumers. Now `yaml.Document.attachPair` (and
  every other route: `yaml.document.*`, `yaml.internal`, reflection over
  the decl lists) is a compile error. No supported API changed; a
  consumer that was calling these had no correctness guarantee anyway —
  the `attach*` pair skips `markModified`, which silently drops the
  edit on re-emission.

### Added

- Quoted path segments: `$["a.b"]` and `$['a.b']` address a key
  literally, for keys the dotted form cannot express. The grammar splits
  on `.` and `[`, so `pymdownx.highlight` read as two nested keys and
  `.defaults` as a recursive descent — the normal case in this library's
  own target domain (Kubernetes annotations, mkdocs, GitLab). The empty
  key is addressable as `$[""]`, since `"": v` is legal YAML. A quoted
  segment is an ordinary key segment, so it composes with the rest of
  the grammar. There is still no escaping, so a key containing both
  quote characters remains unaddressable.

  This supersedes the 0.11.0 note that the limitation "is documented in
  the usage guide": it is now fixed rather than documented. The
  preservation sweep's unaddressable count goes from 25 to 0 on the
  fixtures and 52 to 0 on the variants; the 21 remaining on the corpus
  are explicit `? key` mappings, which have no path form at all.

### Fixed

- `Editor.set` no longer collapses a recoverable flow sequence when replacing
  a scalar or alias: multi-line spacing, comments, commas, trailing commas, and
  surrounding sibling bytes stay exact. The replacement inherits the old
  item's non-synthetic slot span, including its property bytes, so removed
  anchors and tags cannot reappear. Flow insertion and removal still require
  comma reflow and remain outside this preservation path.

- `scripts/differential.sh` exits 1 when fewer than 250 cases were
  compared. It previously reported success having compared nothing — a
  corpus that failed to fetch, or a filter that excluded everything,
  passed the gate silently. Conformance and round-trip already assert a
  floor for exactly this reason.

- `make verify` runs `examples` and the new `consume` target (the
  packaged-consumer smoke test) instead of describing itself as "the
  full gate" while skipping both. `consume` is the only gate that can
  catch a source file missing from `.paths`, which keeps every other
  gate green while every dependent fails to build. There was no Make
  target wrapping `scripts/consumer-smoke.sh` at all before this.

### Documentation

Four statements that were false, now corrected — the same class of error
this project has hit repeatedly, so they are listed rather than folded
quietly into other entries.

- The README said replacing an item of a flow *sequence* collapses the
  collection to one line. The flow-sequence fix above made that false;
  layout, comments and trailing commas survive. The USAGE skip-category
  list carried the same claim.
- `Mapping`'s doc comment claimed `Document.mappingAppend` "rejects
  duplicate keys". It does not, and neither does the parser. Documented
  as the deliberate choice it is: YAML 1.2 §3.2.1.1 requires unique
  keys, but real-world files carry duplicates and dropping one silently
  is worse than keeping it. Both entries survive a round trip; `lookup`
  and path reads return the first.
- `collectDescend` was commented "Depth-bounded pre-order walk". It
  takes no depth parameter and checks nothing; for parsed input the
  scanner's nesting cap bounds it transitively, but a programmatically
  built tree can nest as deep as the builder went.
- `make verify` was called "the full gate" in CONTRIBUTING.md and
  "everything below except differential" in the README while omitting
  two gates.

Two real gaps are now documented rather than left to be discovered:
duplicate mapping keys are kept rather than rejected, and merge keys
(`<<: *base`) are not resolved — correct for YAML 1.2, where merge keys
are a 1.1-era extension, but a surprise to anyone arriving from
Kubernetes or GitLab configuration.

## 0.11.0 — 2026-08-31

### Changed

Terminology alignment with the YAML 1.2.2 spec and the Zig style guide.
Every rename below is compiler-caught; nothing fails silently.

| Old | New |
| --- | --- |
| `ScalarKind` | `CoreTag` |
| `scalarKind()` | `resolveCoreTag()` |
| `NodeType` | `NodeKind` |
| `Node.nodeType()` | `Node.kind()` |
| `Token.Kind` (union) | `Token.Data` |
| `Token.Type` (discriminant) | `Token.Kind` |
| `Token.typeName()` | `Token.kindName()` |
| `token.kind` (field) | `token.data` |
| `Event.Kind` (union) | `Event.Data` |
| `Event.Type` (discriminant) | `Event.Kind` |
| `event.kind` (field) | `event.data` |
| `yaml.NodeType` | `yaml.NodeKind` |
| `yaml.EventType` | `yaml.EventKind` |
| — | `yaml.TokenKind` (was missing) |
| `Value.list` | `Value.sequence` |
| `Value.map` | `Value.mapping` |
| `Value.Member` | `Value.Pair` |
| `Value.null_` / `.bool_` | `Value.null` / `.bool` |
| `CoreTag.null_` / `.bool_` | `CoreTag.null` / `.bool` |
| `Schema.bool_` | `Schema.boolean` |
| `Diag.alloc` (field) | `Diag.allocator` |
| `alloc:` parameters | `allocator:` |

The spec reserves "kind" for the three node kinds — scalar, sequence and
mapping (3.2.1.1) — and calls the mapping's content key/value pairs. It
uses "sequence" and "mapping" in prose; `seq`/`map` are tag spellings.
`CoreTag` names what the enum holds without colliding with `Node.tag`,
which is a fully resolved tag URI. Trailing underscores are gone because
bare `null` and `bool` are legal Zig field names; `Schema.boolean` is the
one that cannot follow, being a declaration rather than a field.

### Removed

- `UnexpectedToken`, `DuplicateAnchor`, `InvalidDirective` and
  `KeyTooLong` from the public `YamlError` set. None was returned from
  anywhere: a grammar violation, a malformed directive and an over-long
  simple key all surface as `InvalidSyntax`, and re-anchoring is legal
  and shadows, so there was no duplicate-anchor condition to report.
  The error vocabulary is now 14 names down to 10, all reachable.

### Fixed

- The `[?key=value]` path filter was documented as matching "mapping
  items". It matches every child that is a mapping, whether that child
  is a sequence entry or a mapping value.
- `attachPair`, `attachItem`, `dropPairSpan` and `dropItemSpan` now
  document why calling them from outside the library corrupts a
  document: the two `drop*` functions must run before an entry is
  detached, because the span is derived from where the next entry
  starts. They stay `pub` because `edit.zig` calls them across a file
  boundary and `pub` in Zig is file-granular.
- The path grammar's inability to address a key containing `.`, `[` or
  `]` is documented in the usage guide rather than only counted inside
  the preservation harness.


### Fixed

- A byte-order mark shifted every span of the documents it prefixed
  three bytes out of alignment: the scanner skipped the BOM in its
  byte cursor but not in its mark, so re-emissions that sliced spans
  individually truncated the tail. A BOM followed directly by a
  comment line additionally failed to parse: the '#' check looked
  only at the preceding byte, which the BOM's last byte is, and did
  not recognize the line start. Both found by the preservation gate's
  BOM fixture variants.
- Moving a subtree whose ancestors had never been edited re-used the
  ancestor's original bytes, so the move became a copy — the subtree
  appeared at the destination and stayed at the source. Moving now
  marks the whole ancestor chain modified, like every other editing
  path already did.
- A mapping that is a sequence item measured inserted keys from the
  item's `- ` indicator instead of its own entries, so a key added
  under a `steps:`-style list landed one indentation level out and
  the output stopped parsing.
- A moved or programmatic empty plain scalar — YAML null — was
  emitted as an empty quoted string; it now stays a null, without a
  trailing space.
- Setting a scalar to what it already holds (same value, style,
  anchor and tag) is now a byte-identical no-op instead of replacing
  the entry and re-emitting it normalized: flow spacing
  (`branches: [ x ]`), block scalar indentation and folding, and
  anchors and tags all stay exactly as written. A different style or
  tag remains a real edit.
- Deleting two mapping entries in one batch — or in two successive
  edits — could resurrect the second-deleted entry's bytes: tombstone
  ranges were recorded in the order the deletes ran, while emission
  skips them in document order. Ranges are now kept sorted.
- Inserting an item before a sequence item whose line carries a
  trailing comment emitted the successor's line ahead of itself and
  then again in place. The comment now stays with its own entry.
- Editing an explicit-key entry (`? key`) emitted `? key: value`,
  which does not parse: a value the entry did not have now moves onto
  a `: value` line at the indicator's column. Adding a plain key to
  an explicit-key mapping indented it to the key text's column, where
  it parsed as the previous entry's value; new entries now sit at the
  indicator column.

### Changed

- `make preservation` now sweeps `Edit.insert` and `Edit.move` at
  every addressable position, edits all 269 valid yaml-test-suite
  corpus documents and CRLF/BOM/no-final-newline variants of every
  fixture, keeps set-to-same-value as a permanent byte-identical
  assertion, and compares every output's semantic value tree against
  the edited document — in addition to the previous line-shape
  checks. Shapes that legitimately normalize are counted as skips,
  never asserted away.
- A multi-line flow mapping keeps its layout when one of its values is
  changed, instead of collapsing to a single line and dropping any
  comments inside it. The bytes between flow entries are now treated as
  a gap in the same sense block containers already use. Adding or
  removing a flow entry, and replacing an item of a flow sequence, still
  normalize: there is no original slot left to write the entry into, and
  re-flowing separators around a hole is a different job.

## 0.10.0 — 2026-08-30

### Fixed

- `value.fromZig` now returns uniformly owned value trees, including
  strings, enum names, and general slices; `value.toZig` cleans up
  partially built values and exposes `yaml.value.deinitZig` for returned
  slice storage and slice-valued defaults.
- `nodeToValue` no longer resolves programmatic strings such as `"42"`
  into core-schema numbers or booleans after `toNode`; they remain
  strings.
- Atomic file writes remove their temporary file when the final rename
  fails.
- A simple key of fewer than 1024 characters could be rejected if it
  contained non-ASCII text: the 1024 bound counted bytes rather than
  characters. It now counts characters, per YAML 1.2.2 7.4.2 and 8.2.2.
- A version string, semver-style key or IP fragment could be typed as a
  number during core-schema tag resolution: `+0x1F` resolved to the
  integer 31, and `1.2.3` to a float. The hex and octal int forms take
  no sign and are lowercase only, and the float form allows a single dot
  before a single exponent whose digits are required (YAML 1.2.2
  10.3.2). Present since v0.9.0.
- Corrected published claims that were false: the round-trip gate is
  265/269 with four documented skips, not 265/265; `error.KeyTooLong`
  was documented as reachable and is not; `Unterminated` was documented
  for flow collections, which return `InvalidSyntax`.
- Deleting the first key of a mapping that is a sequence item destroyed
  the item's `- ` indicator, silently turning a sequence of mappings
  into a mapping. The result re-parsed cleanly, so nothing downstream
  caught it. The indicator belongs to the item rather than the entry: it
  now stays, and the next entry moves up onto it — or keeps a line of
  its own when a comment sits between them and cannot be moved.
- Deleting the first child of a nested block collection re-indented the
  surviving sibling, doubling its indentation (two spaces became four).
  Invisible at the top level, where the indent is zero.
- Editing an entry inside a flow collection dropped the parent's `: `,
  emitting `ints[0, 1]` for `ints: [0, 1]`. Flow entries share a line
  with their parent key, so the line-range tombstones that let block
  emission skip a removed entry are no longer recorded for them.
- Setting the last key of a mapping that is a sequence item appended a
  blank line — that is, every list-of-objects document: Kubernetes
  containers, CI job steps, Compose services.
- Deleting a mapping's last entry could overwrite the surviving entry's
  trailing comment with the deleted entry's own.
- Appending to a mapping placed the new entry ahead of the previous
  entry's trailing comment, moving the comment onto the new line; and
  could swallow a blank line separating the block from what followed.
- Replacing an item of a nested sequence (`- - a`) consumed the outer
  item's indicator, and replacing a collection's only entry indented the
  replacement one level too deep.
- Replacing or emptying a collection placed `{}` / `[]` at column zero
  instead of under its key, which does not re-parse.
- Emptying a collection in the zero-indent sequence style (`- ` items at
  their parent key's own column, as Kubernetes and mkdocs write it) put
  the `{}` / `[]` at the key's column, where a flow node reads as the
  key's sibling rather than its value, and swallowed the `- ` indicator
  along with the entry. The conventionally indented form of the same
  edit re-parsed cleanly while silently dropping a sequence item.
- The byte-exact round-trip gate only globbed `*.yaml`, so four `.yml`
  fixtures — 366 of 776 fixture lines — were never checked. They pass;
  the gate had been reporting on roughly half of what it claimed to
  cover. A count guard now fails the gate if the glob matches nothing,
  rather than passing quietly.

### Changed

- Subtrees the emitter owns — brand-new ones, and moved ones — now
  re-emit in block layout instead of collapsing to single-line flow.
  Replacing a value with a fresh mapping, appending one to a block
  sequence, and moving a subtree all now match the document they land
  in. Flow is still used where it is the right answer: collections
  written in flow style, and empty ones.
- The emitter measures a document's indentation convention (the first
  nested block container's entry column, minus the column of the key
  owning it) instead of assuming two spaces, so an insert into a
  four-space file indents by four.

### Added

- `Editor.set` and `Editor.delete` accept sequence indices anywhere in a
  path (`$.list[2].name`, `$.list[2][0]`), not only as the final
  segment; `set` addresses a sequence slot by index. Previously these
  returned `error.AmbiguousOperation`.
- `make preservation`: an edit-preservation gate that sweeps every
  addressable edit position in every real-world fixture and asserts an
  edit changes only the lines it should — deletes remove one contiguous
  run, sets change one line, adds insert without disturbing anything.
  Positions exempt from line-shape assertions (documented
  normalizations) still assert the weaker invariant that the emitter
  never produces invalid YAML. Every fix above was found by this sweep.

## 0.9.0 — 2026-08-30

First public release. The stack is feature-complete: scanner → parser
→ CST-backed document model → emitter, plus an editing API, a value
runtime, optional schema validation, and bounded atomic file I/O.

Quality gates: full yaml-test-suite corpus (351/351, zero skips),
byte-faithful round trips over the corpus and real-world fixtures,
event-stream parity with libfyaml (269 compared, 0 mismatches),
allocation-failure injection across the public API with zero leaks,
Debug and ReleaseSafe, cross-compile checks for x86_64-linux and
aarch64-linux.

### Added

- `parseDiag` / `parseAllDiag`: positioned diagnostics (line, column,
  message) collected into a caller-owned `Diag` alongside the error
  return.
- `Document.mappingWalkOrCreate` / `Document.mappingReplace`: the
  shared mapping walk-and-replace core used by `pathSet` and the
  editor.
- Allocation-failure suites for `parseAll`, value conversion, schema
  validation, file reads and `Editor` batches; direct tests for
  `Schema.mapStrict`/`Schema.scalar` and `Emitter.emitDocument`;
  `parseAllFile` tests; seeded fuzzing over multibyte UTF-8 and
  arbitrary bytes.
- CI: round-trip and differential gates; conformance/roundtrip fail on
  a mis-loaded corpus instead of passing vacuously.
- CHANGELOG, CONTRIBUTING, and compile-checked examples (`zig build
  examples`).

### Fixed

- Editor deletes no longer swallow `error.OutOfMemory`: a failed
  allocation mid-batch rolls the batch back atomically instead of
  silently reporting success.
- `value.parseToValue` keeps the real error identity (`InvalidUtf8` is
  no longer collapsed into `InvalidSyntax`).
- Four leaks under allocation failure in value conversion and schema
  violation building, found by the new failure-injection tests.
- `Parser.trackBytes` releases its buffer when tracking fails.
- `error.InvalidCodepoint` added to the public `YamlError` vocabulary
  (it was reachable but unnamed).

### Changed

- `pathSet` reports `error.NotAMapping` (was `InvalidSyntax`) when an
  intermediate node on the path is not a mapping.
- Internal DRY pass: one special-float spelling table, one best-effort
  diagnostics helper (`diag.emitBestEffort`), shared block-scalar
  header emission, `Edit.insert` payload is a named type (`Insert`).

## 0.1.0 — 2026-08-27

Foundation: pool, diagnostics, UTF-8, character classes, token/scanner
layer, event parser, document model with builder, and the emitter —
with the quality pass (build/CI gates, ownership model, error
vocabulary, allocation-failure testing).
