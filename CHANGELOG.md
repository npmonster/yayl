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
