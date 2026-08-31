# AGENTS.md — yayl conversion playbook

Guidance for AI agents (and humans) continuing the conversion of **libfyaml**
(C) into this native-Zig YAML library. Read this before touching code.

## Mission

1. **Conversion first.** yayl is a port of libfyaml's architecture: scanner →
   parser → document model → emitter. When in doubt, match libfyaml's
   observable behavior (token streams, event streams, scalar values).
2. **Idiomatic Zig.** The port must read like Zig, not translated C:
   tagged unions instead of type enums + unions, `!T` error unions instead of
   `FYEC_*` codes, allocator-passing containers, tests next to code.
3. **DRY.** One implementation per rule. Folding logic, quoting decisions,
   indent bookkeeping, and diagnostics each live in exactly one place. If you
   copy-paste a rule, refactor it into a helper instead.
4. **No silent divergence.** Every intentional deviation from libfyaml is
   marked with a `PORT NOTE:` comment and tracked below.

## Ground rules for changes

- **Work through plumb**. All code work goes through the plumb MCP
  daemon; setup and the full tool policy are in [Working with plumb](#working-with-plumb) at the end of this file.
- Run `zig build test` before and after any change; the suite must stay green
  with **zero leaks** (tests run under `std.testing.allocator`). CI runs the
  canonical `make verify` gate on Zig 0.16.0.
- OOM paths are real code: anything that registers a fresh allocation must
  `errdefer` it (seven real leaks were found this way). Public allocating
  operations are covered by `std.testing.checkAllAllocationFailures`.
- Also verify `-Doptimize=ReleaseSafe` (part of `make verify`); no Debug-only
  assumptions.
- Memory ownership model:
  - `Document` owns a `Pool` (arena). Nodes and their strings live there and
    are freed in one shot by `Document.deinit`.
  - `Scanner`/`Parser` own transient buffers (`temp_bytes`, `temp_params`) and
    free them in `deinit`. Anything that outlives the parser (document nodes)
    must be **copied into the document pool** — never borrow scanner memory.
  - Builder copies scalar values, anchors and tags into the pool for exactly
    this reason; keep it that way.
- Errors: return error unions. Use `fail`/`failWith` in scanner/parser so a
  `Diag` (when attached) records a positioned message. Return `error.X`
  literals, never integer codes.
- Tests: keep them in the same file as the code (Zig convention). The root
  `src/yaml.zig` `test { _ = <module>; }` block pulls every module's tests in;
  new modules must be added there.

### Verification and shared-checkout discipline

- `zig build check` cannot validate visibility or signature changes that only
  become reachable through `src/edit.zig`; run `zig build test` for those
  changes.
- `make verify` covers formatting, library compilation, Debug and ReleaseSafe
  tests, conformance, unchanged round trips, and edit preservation.
- Parsing, differential, and unchanged round-trip gates do not exercise edits;
  `zig build preservation` is the edit gate.
- Prove every regression test red without its fix, verify CI-only behaviour in
  CI, and remeasure reported counts instead of copying stale totals.
- In a shared checkout, check sessions and claims, share intent before editing,
  and commit completed work immediately. Normally use `git commit -- <paths>`:
  a bare `git commit` consumes the whole index, including another session's
  staged work.
- Never stash, overwrite the live tree with `cp`, or run
  `git checkout -- <file>` without first proving the target clean; each can
  discard another session's uncommitted work. Use a detached worktree for
  before/after comparisons.
- If overlap on a dirty file is unavoidable, build the intended file in a
  detached worktree or temporary path, then stage its blob without touching the
  live file:

  ```sh
  blob=$(git hash-object -w /absolute/path/to/prepared-file)
  git update-index --cacheinfo 100644 "$blob" path/to/file
  git diff --cached -- path/to/file
  git diff --cached --name-only
  git commit -m "message"
  ```

  This is the one index-only exception to path-limited commits: the final bare
  commit is intentional because `git commit -- <paths>` would read the dirty
  working-tree file again. The whole index must contain only the reviewed blob.

## Module map and conversion status

| libfyaml file(s)      | Zig module(s)          | Status                                                            |
| --------------------- | ---------------------- | ----------------------------------------------------------------- |
| `fy-pool.c`           | `src/pool.zig`         | ✅ done — wraps `std.heap.ArenaAllocator` (`reset` supported)      |
| `fy-diag.c`           | `src/diag.zig`         | ✅ core — levels/marks/render done; source excerpts not yet        |
| `fy-utf8.c`           | `src/utf8.zig`         | ✅ done — strict decode/encode/validate                            |
| `fy-ctype.c`          | `src/ctype.zig`        | ✅ done — byte-level classes (indicators are ASCII)                |
| `fy-scan.c`           | `src/scanner.zig`      | ✅ done — full corpus green (351/351, zero skips)                  |
| `fy-parse.c`          | `src/parser.zig`       | ✅ done — event streams byte-identical to libfyaml (differential)  |
| `fy-event.c`          | `src/event.zig`        | ✅ done                                                            |
| `fy-doc.c` `fy-node.c` `fy-docbuilder.c` | `src/document.zig` | ✅ done — semantic model + per-node/entry spans (comments and blank lines round-trip) |
| `fy-emit.c`           | `src/emitter.zig`      | ✅ done — faithful (untouched bytes exact) + normalized emit; modified subtrees normalize internal layout, new/moved ones re-emit block at the measured indent |
| `fy-atom.c`           | —                      | ⬜ not ported (atom interning; optional optimization)              |
| `fy-tag.c`            | in `parser.zig`        | 🟡 shorthand resolution done; no `fy_tag` cache                    |
| `fy-wpool.c`          | —                      | ⬜ out of scope for v1 (threading)                                 |
| `fy-markup.c`         | `src/markup.zig`       | ✅ done — source-span arithmetic behind byte-faithful round trips  |

### Scanner status

The full pinned yaml-test-suite corpus passes (351/351, zero skips):
explicit keys, tab strictness (column-0 tabs indenting constructs are
rejected; separation tabs are fine), flow/quoted continuation
indentation bounds, block scalar folding/indentation indicators.
`make verify` and `make roundtrip` keep it honest (stale-skip guard).

### Parser status

Event streams are byte-identical to vendored libfyaml on all 269
comparable corpus cases (`make differential`). Anchor re-definition
shadows (corpus semantics). Nesting/length limits are structured
errors.

### Emitter status

Two modes: **faithful** (parsed documents: untouched subtrees re-emit
verbatim via `markup.Src` spans; modified slots re-emit in place with
sibling bytes preserved; tombstones skip deleted entries; folded
scalars keep `>` when re-folding is lossless) and **normalized**
(programmatic documents). Modified subtrees normalize their internal
layout; untouched bytes are exact. New and moved subtrees have no
layout to preserve, so they re-emit in block style at the document's
measured indent width.

## Documented v1 scope decisions

- **Streaming input**: the parser is pull-based at the event level;
  input chunking is deliberately out of scope (see `src/file.zig`
  module docs for the rationale).
- **Parse cache**: none in v1 (same note).
- **Threading (`fy-wpool`)** and **atom interning (`fy-atom`)** remain
  optional, out of scope.

## Verification strategy

- **Unit tests**: token streams, event streams, scalar values, emitter
  quoting, round trips, editing, value conversion, schemas, file I/O,
  allocation-failure injection — `zig build test`.
- **Conformance gate**: full yaml-test-suite corpus, event-tree
  comparison, zero skips — `make conformance`.
- **Round-trip gate**: `emit(parseAll(x)) == x` over the corpus and
  real-world fixtures — `make roundtrip`.
- **Differential gate**: event streams vs the compiled vendored
  libfyaml over the corpus — `make differential`.

## Zig 0.16 gotchas already paid for (don't re-learn these)

- `std.ArrayList(T)` is the **unmanaged** list: init `= .empty`, every method
  takes the allocator as the first argument (`append(alloc, x)`,
  `deinit(alloc)`, `toOwnedSlice(alloc)`); `pop()` returns `?T`.
- `std.StringHashMap`/`std.AutoHashMap` are **managed**: create with
  `T.init(alloc)`, methods take no allocator, `deinit()` takes none.
- `b.addTest(.{ .root_module = ... })` — 0.16 wants a module, not
  `root_source_file`; same for `addExecutable`/`addLibrary`.
- `build.zig.zon` requires `.fingerprint` and `.name` as an enum literal.
- In `std.fmt` strings, a literal `}` must be written `}}` (e.g. error
  message `"expected ',' or '}}'"`).
- Error-set annotations like `YamlError!T` break as soon as the body can
  return `error.OutOfMemory`; prefer inferred `!T` on internal functions and
  keep `YamlError` for classification, not annotation.
- `std.mem.zeroes` refuses tagged unions — pool allocations are uninitialised
  and must be assigned immediately (`Pool.create` contract).
- `std.io` was overhauled (new `Io` system); this library deliberately avoids
  it and emits into `std.ArrayList(u8)`.

## Repo map

```
build.zig, build.zig.zon     build script + package manifest
src/yaml.zig                 public root: re-exports, parse/parseAll, tests
src/{pool,diag,utf8,ctype}.zig     foundations
src/{token,scanner}.zig            tokenizer
src/{event,parser}.zig             event parser
src/document.zig                   node model, builder, path/mutation API
src/emitter.zig                    serializer
README.md                          user-facing docs
```

## Definition of done for a conversion task

1. Behavior matches libfyaml for the feature in question (test proves it).
2. Code follows the conventions above; helpers reused, not duplicated.
3. `zig build test` green, zero leaks; `PORT NOTE` comments updated/removed.

## Working with plumb

All code work in this repository goes through the [plumb](https://github.com/plumbkit/plumb) MCP daemon. If you are an external contributor and don't have plumb yet, install it from <https://github.com/plumbkit/plumb> and run `plumb serve` in this workspace (see its README for MCP client setup).
Operate this workspace through the plumb MCP daemon, and start with
`session_start({workspace: <absolute path>})` — passing a stable
per-conversation `session_id` (mint one shaped like `dsh-yayl-x7q2`; use your
harness's conversation id if it states one) on every `session_start`. Several
conversations share one plumb connection, and plumb keeps workspace pins,
read-tracking and mail apart only per declared identity: an unidentified
`session_start` re-pins the connection for every conversation on it. Never
pass `force: true` to move a pin unless your human asked for that exact move.
