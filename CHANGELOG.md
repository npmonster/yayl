# Changelog

Notable changes to yayl. Pre-1.0, the minor version is the release
series; APIs may still move, and anything that does is listed here.

## Unreleased

### Fixed

**Conversion and validation are depth-bounded.** `value.nodeToValue` and
`Schema.validate` recurse over the node graph, and carried only a
node-count budget (`max_values`/`max_nodes`, 1,048,576) to stop them. A
count cannot stand in for a depth: a linear chain of N nested
collections is N values but N stack frames, so a tree built through
`createSequence`/`sequenceAppend` past roughly 4,000 to 8,000 levels
overflowed the native stack and **aborted the process** long before the
budget could fire — no typed error, no recovery. Reproduced on both
paths (4,000 clean, 8,000 abort, 10,000 segfault) before the fix.

`value.Limits` and `schema.Limits` now carry `max_depth`, defaulting to
1000 to match `Emitter.max_depth`, and return `error.NestingTooDeep`
past it — so a tree conversion accepts is one emission will serialize.
Parsed input was never affected (`max_nesting` caps nesting at 200);
this is for trees a consumer builds. `Limits.unlimited` lifts the depth
bound too, which re-arms the hazard, and now says so.

This was the second of the three v0.12.0 audit suspicions, whose
original text was recovered from the session record on 2026-09-03.

### Changed

**`schema.Error` gained `NestingTooDeep`.** Required by the bound above.
Callers that switch exhaustively over `schema.Error` need a new arm;
`value.Error` already admitted it through `YamlError` and is unchanged.

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
