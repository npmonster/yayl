# Changelog

Notable changes to yayl. Pre-1.0, the minor version is the release
series; APIs may still move, and anything that does is listed here.

## Unreleased

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
