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

- Run `zig build test` before and after any change; the suite must stay green
  with **zero leaks** (tests run under `std.testing.allocator`). The canonical
  gate is `make verify` (fmt + library compile + Debug and ReleaseSafe tests);
  CI runs the same on Zig 0.16.0.
- OOM paths are real code: anything that registers a fresh allocation must
  `errdefer` it (three real leaks were found this way). Public allocating
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

## Module map and conversion status

| libfyaml file(s)      | Zig module(s)          | Status                                                            |
| --------------------- | ---------------------- | ----------------------------------------------------------------- |
| `fy-pool.c`           | `src/pool.zig`         | ✅ done — wraps `std.heap.ArenaAllocator` (`reset` supported)      |
| `fy-diag.c`           | `src/diag.zig`         | ✅ core — levels/marks/render done; source excerpts not yet        |
| `fy-utf8.c`           | `src/utf8.zig`         | ✅ done — strict decode/encode/validate                            |
| `fy-ctype.c`          | `src/ctype.zig`        | ✅ done — byte-level classes (indicators are ASCII)                |
| `fy-scan.c`           | `src/scanner.zig`      | 🟡 most — see "Scanner gaps"                                       |
| `fy-parse.c`          | `src/parser.zig`       | 🟡 most — state machine ported; see "Parser gaps"                  |
| `fy-event.c`          | `src/event.zig`        | ✅ done                                                            |
| `fy-doc.c` `fy-node.c` `fy-docbuilder.c` | `src/document.zig` | 🟡 semantic model done; no CST (markup/comment) yet |
| `fy-emit.c`           | `src/emitter.zig`      | 🟡 semantic emit done; not byte-identical round trip yet           |
| `fy-atom.c`           | —                      | ⬜ not ported (atom interning; optional optimization)              |
| `fy-tag.c`            | in `parser.zig`        | 🟡 shorthand resolution done; no `fy_tag` cache                    |
| `fy-wpool.c`          | —                      | ⬜ out of scope for v1 (threading)                                 |
| `fy-markup.c`         | —                      | ⬜ not ported (fy-extension markup)                                |

### Scanner gaps (`fy-scan.c` parity work)

- Complex keys via `?` are tokenized but not exercised end-to-end.
- Edge cases of plain-scalar continuation (document indicators mid-scalar,
  tab-in-indentation diagnostics) implemented but lightly tested.
- No input chunking/streaming reader yet: the whole input must be in memory
  (libfyaml has a reader layer; Zig port reads a `[]const u8`).

### Parser gaps

- Anchor redefinition rules per document are enforced (duplicate → error),
  but libfyaml's exact alias/anchor mark bookkeeping is simplified.
- `%YAML` versions > 1.x are rejected; libfyaml warns on some.

### Emitter gaps (the big one)

- Emits from the **semantic tree**, so formatting is normalized: original
  comments, blank lines, indentation width and key order quirks are not
  preserved. libfyaml's round-trip mode preserves all of these via the CST.
- Anchored nodes are de-duplicated with `*alias` on second emission; nodes
  without anchors are duplicated (graph → tree flattening).
- Folded scalars (`>`) are emitted as literal (`|`) when re-quoting is
  required (lossless, but style changes).

## The main remaining goal: comment-preserving round trip

libfyaml's headline feature is byte-faithful round-trip editing, which
requires a **CST** that keeps comments and original formatting. Path:

1. Vendor the reference: `git clone https://github.com/pantoniou/libfyaml
   vendor/libfyaml` (already in `.gitignore`; treat as read-only reference).
2. Port `fy-markup`/comment attachment: extend `Token` with comment spans,
   attach to adjacent nodes during build.
3. Add per-node "original text" spans so unmodified subtrees re-emit
   byte-identically; fall back to the current emitter for new/modified nodes.
4. Differential testing: for a corpus of YAML files, assert
   `emit(parse(x)) == x` byte-for-byte.

## Verification strategy

- **Unit tests** (current): token streams, event streams, scalar values,
  emitter quoting, round trips, allocation-failure injection over the public
  parse/write API — `zig build test` (62 tests).
- **Next**: port libfyaml's `tests/` data-driven cases (YAML test suite
  inputs with expected token/event/dump outputs) as embedded or generated
  fixtures; compare Zig output to recorded libfyaml output.
- **Later**: differential fuzzing (Zig parser vs. C parser via `zig cc`
  build of vendored libfyaml).

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
