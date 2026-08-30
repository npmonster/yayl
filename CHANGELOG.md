# Changelog

Notable changes to yayl. Pre-1.0, the minor version is the release
series; APIs may still move, and anything that does is listed here.

## Unreleased

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
with the PLAN-9 quality pass (build/CI gates, ownership model, error
vocabulary, allocation-failure testing).
