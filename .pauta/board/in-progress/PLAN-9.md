---
id: PLAN-9
title: Refactor Yayl into an idiomatic, warning-free Zig 0.16 foundation
created: 2026-08-26T11:26:32Z
updated: 2026-08-26T15:27:16Z
tags: [yayl, zig, quality, refactor, testing, architecture]
deps: []
skills: []
review_rounds: 0
priority: 1
worker: qwen-code qwen3-coder
reviewer: qwen-code qwen3-coder (self-review per user decision 2026-08-27)
auto_review: true
---

## Plan

## Objective

Turn the current Yayl foundation into an idiomatic, warning-free Zig 0.16 library whose public API, ownership model, error handling, types, build graph, documentation, and tests are strong enough to support the parser/document work in PLAN-2 through PLAN-8.

“Best Zig project” means evidence against the current Zig language reference and build system, established Zig community practice, and Yayl’s actual risks. It does not mean maximizing abstraction or line-count reduction. Prefer explicit code, standard-library reuse, impossible invalid states, clear lifetimes, exhaustive tests, and small reviewable changes.

## Research baseline

Use these sources during implementation and record any version-sensitive departure in the card log:

- [Zig 0.16 language reference and style guide](https://ziglang.org/documentation/0.16.0/): canonical formatting and naming, prefer const, no shadowing, explicit allocator/OOM handling, errdefer, tagged unions, exhaustive switches, doctests, leak-detecting test allocator, and documentation guidance.
- [Zig 0.16 build-system guide](https://ziglang.org/learn/build-system/): create root modules through the current module API, compile and run test artifacts, and make build graph coverage explicit.
- [Zig 0.16 release notes](https://ziglang.org/download/0.16.0/release-notes.html): package fingerprints are required; test timeouts and current build behavior are available.
- [Zig project principles](https://ziglang.org/): no hidden control flow and no hidden allocations.
- [Zig community allocator discussion](https://ziggit.dev/t/allocators-best-practices-anti-patterns/14043): allocator names and contracts should communicate lifetime (arena, general-purpose/individually freed, scratch); group equal lifetimes instead of defaulting to complex object ownership.
- [Zig community anytype guidance](https://ziggit.dev/t/generic-programming-and-anytype/3228): use anytype only where requirements are local and obvious; avoid long duck-typed call chains.
- [Zig community allocation-failure testing guidance](https://ziggit.dev/t/how-to-config-std-testing-failingallocator/5765): use std.testing.checkAllAllocationFailures where applicable instead of testing one guessed failure index.

The Zig 0.16 reference is authoritative when community advice conflicts or older examples use a different standard-library API.

## Verified current-state findings (2026-08-26)

The implementation must begin by reproducing these findings and logging the exact command output:

1. The installed and declared toolchain is Zig 0.16.0.
2. The configured Plumb verify task fails immediately because build.zig.zon lacks the required fingerprint. Zig suggests 0xc49f7ed159fd2afc, but regenerate/confirm it through the Zig tool rather than copying this snapshot blindly.
3. build.zig points the public module and test artifact at src/yaml.zig, which does not exist.
4. zig fmt --check build.zig src/*.zig reports src/utf8.zig.
5. zig ast-check finds that Pool.init’s allocator parameter shadows Pool.allocator.
6. Running each existing module test independently finds a real leak: Diag.emit allocates each message, while Diag.deinit only deinitializes the ArrayList backing storage.
7. Plumb/ZLS diagnostics over existing tracked files are otherwise clean, but that result is not compile truth because Zig lazily analyzes declarations and the package root is missing.
8. Plumb’s structural audit finds 24 undocumented exported declarations.
9. Event and Token each store a separate type discriminator and tagged Data union, allowing contradictory states. Token.Data includes directive data but TokenType has no directive case.
10. ctype.isPrintableAscii returns true for bytes 0x80 through 0xFF despite its name.
11. utf8.encode accepts the full u21 domain and can encode surrogate or out-of-range scalar values; countCodepoints silently returns a valid-prefix count on invalid input.
12. Pool.create publicly accepts any type but initializes it with std.mem.zeroes(T), while its safety claim is only true for an undocumented subset of types.
13. Diag.render uses a fixed 4096-byte temporary and silently drops an overlong formatted diagnostic.
14. Token and Event have almost no consumer blast radius yet; this is the least expensive point to correct their representation before PLAN-3 builds on it.
15. build.zig and build.zig.zon already contain uncommitted work. Re-read and preserve concurrent/human changes; never overwrite or reset them.

## Scope guard

This card refactors and hardens the existing foundation. It may add the missing public root, build/test/CI/documentation infrastructure, and focused test support. It must not implement the YAML scanner, parser, CST/document, emitter, editing API, schema system, or performance features owned by PLAN-2 through PLAN-8.

Preserve intended libfyaml compatibility at behavior boundaries, but do not preserve C-shaped representation when Zig can encode the invariant more safely. Any behavior change requires a characterization test or a written explanation that the old behavior was unobservable/invalid.

Do not introduce a dependency until the standard library has been evaluated and rejected with a recorded reason. Do not add a generic helper merely to remove similar-looking lines.

## Phase 0 — restore truthful build and quality gates

1. Re-read dirty build files and inspect peer activity before editing.
2. Make build.zig.zon a valid Zig 0.16 package: confirm the stable package fingerprint, minimum version, and narrow paths so package archives exclude .pauta, .plumb, caches, and unrelated local state.
3. Add src/yaml.zig as the documented public root. Explicitly re-export only supported API; add a root test/import block that forces every current module and its tests into the test graph.
4. Update build.zig to the canonical Zig 0.16 module/test shape. Ensure a normal build actually compiles the public root instead of registering an otherwise unanalyzed module.
5. Add named quality steps or scripts with one canonical entry point. At minimum:
   - zig fmt --check build.zig build.zig.zon src
   - zig build test --summary all in Debug
   - zig build test -Doptimize=ReleaseSafe --summary all
   - a bounded test timeout
   - ZLS/Plumb diagnostics with zero warnings or errors
6. Add CI using an exact Zig 0.16.x version. Treat every compiler, linker, formatter, language-server, test-runner, and build-system warning as a failure. Zig normally promotes many questionable constructs to errors; do not hide diagnostics or add blanket suppressions.
7. Add a README with supported status, Zig version, build/test commands, allocator/lifetime overview, and a minimal compiling import example.

Gate: a clean checkout runs the canonical verification command successfully in Debug and ReleaseSafe with zero warnings, zero leaks, all modules analyzed, and no skipped test hidden from the summary.

## Phase 1 — review and stabilize the public model

For every pub declaration, record whether it is required now, internal implementation detail, or speculative future API. Keep the public surface minimal because the package is pre-1.0 and downstream feature cards have not yet established all semantics.

1. Replace duplicated discriminator plus payload state in Token and Event with a single authoritative tagged-union representation, or prove why a separate tag is required and enforce consistency through private fields/constructors. The chosen form must make a mismatched tag/payload unrepresentable.
2. Resolve directive representation so every payload has a corresponding tag and every tag’s payload is exhaustive.
3. Review whether names repeat their namespace (for example token.TokenType) and follow Zig’s fully-qualified-name guidance without obscuring domain language.
4. Define Mark semantics precisely: line/column base, byte offset, Unicode counting, and whether zero means start or invalid. Rename Mark.zero if its value is line 1/column 1 and the name remains misleading.
5. Replace the speculative monolithic YamlError with error sets attached to implemented layers. Public functions must expose stable, meaningful errors; internal inferred error sets are allowed only where they do not leak into unstable public function types. Never collapse OOM or malformed input into null.
6. Document slice ownership and lifetime for every token/event/diagnostic field: borrowed input, arena-owned, caller-owned, or static. No hidden allocation or ownership transfer.
7. Add doc comments and focused doctests/examples for every public declaration. Documentation must state assumptions and safety consequences using Zig’s assume/assert terminology.

Gate: every exported declaration is intentional and documented; public examples compile; invalid token/event tag-payload combinations cannot be constructed through the supported API; exhaustive switches fail to compile when a new case is added without handling.

## Phase 2 — harden primitives and reuse the standard library

### ctype.zig

- Rename predicates to the YAML semantic class they actually implement; isAlpha currently includes digits, dash, and underscore.
- Compare each operation with std.ascii and reuse the standard function when behavior is identical. Keep a Yayl helper only for YAML-specific sentinel or character-class semantics.
- Correct the ASCII boundary bug and exhaustively test all 256 byte values with table/reference assertions, plus YAML indicator and NUL boundaries.
- Prefer clear range/switch expressions over clever wrapping arithmetic unless a benchmark demonstrates a meaningful difference.

### utf8.zig

- Compare the codec with std.unicode in Zig 0.16. Reuse it directly or wrap it narrowly when the required YAML error/position semantics differ; record the reason for any custom codec.
- Make EOF, malformed UTF-8, and invalid Unicode scalar values distinguishable where callers need diagnostics. Never silently return a prefix count for invalid input unless the API name and docs explicitly promise prefix semantics.
- Validate encode inputs and reject surrogates and values above U+10FFFF.
- Add exhaustive boundary tables, differential tests against std.unicode, round trips across 1/2/3/4-byte boundaries, truncated/overlong sequences, surrogate ranges, maximum scalar, and property/fuzz tests.
- Add YAML printable-codepoint checks separately from UTF-8 validity.

### pool.zig

- Name allocator parameters by lifetime contract (for example backing_allocator or arena_allocator) and remove shadowing.
- Remove or constrain generic zero-initialization. Prefer allocate-then-explicitly-initialize, createValue(T, value), or a type-specific constructor so invalid pointers/enums/struct invariants cannot be fabricated by std.mem.zeroes.
- Document reset invalidation: every pointer/slice allocated from the pool becomes invalid after reset/deinit.
- Test retain-capacity behavior only as an implementation property, not a public promise, unless measured and required.
- Add allocation-failure tests and repeated reset/deinit tests with std.testing.allocator.

### diag.zig

- Choose one coherent ownership model. If Diag owns messages, free every message and use errdefer so append failure frees the just-formatted message. If all storage is arena-owned, encode that contract in construction/naming and do not pretend generic allocator deinit provides individual ownership.
- Replace the 4096-byte temporary/silent catch with a growable or streaming writer that either renders the full message or returns a real error.
- Test append failure, render failure, long messages, Unicode, empty lists, repeated render, and deinit with the leak-detecting allocator.
- Keep diagnostic formatting separate from diagnostic storage so future parser code can write to caller-provided sinks without hidden I/O.

Gate: primitives pass targeted unit, leak, OOM, boundary, and fuzz/property tests; standard-library duplication has either been removed or justified; APIs do not hide malformed input or fabricate invalid values.

## Phase 3 — DRY and reuse review

Run this review only after behavior and ownership are characterized:

1. Use Plumb workspace search, symbols, references, and topology impact before adding or moving a helper.
2. Build a duplication inventory by semantic responsibility, not text similarity: scalar style/directives, marks/ranges, allocator ownership, tag naming, rendering, and UTF-8 traversal.
3. Keep one canonical definition for a domain type and re-export it where useful. Avoid parallel “almost the same” types that drift.
4. Extract a helper when at least two call sites share the same invariant and error/ownership contract, or when one helper isolates a security/correctness boundary. Leave repeated code in place when the operations only look similar.
5. Prefer std.mem, std.ascii, std.unicode, standard writers, ArrayList, tagged unions, and explicit error unions over local frameworks.
6. Keep anytype/comptime APIs short, locally understandable, and covered by compile-time tests. Prefer concrete types or narrow interfaces when requirements would otherwise be discovered through a long compiler error chain.
7. Measure before adding caches, pooling layers beyond the existing document-lifetime arena, branch tricks, or specialized containers.

Gate: the review log lists each accepted/rejected abstraction with call sites and ownership/error compatibility. No abstraction exists solely to satisfy a DRY metric.

## Phase 4 — testing, analysis, and review discipline

1. Keep focused unit tests beside implementation. Add integration tests through the public yayl import so internal tests cannot be the only evidence.
2. Ensure lazy analysis does not hide broken public declarations: compile doctests/examples and instantiate every generic/public path.
3. Use std.testing.allocator for normal allocating tests and std.testing.checkAllAllocationFailures for public allocation-owning operations where feasible.
4. Add deterministic fuzz/property entry points for ctype/UTF-8 now and extend the same harness in PLAN-2/PLAN-3. Seeds that find failures become permanent regressions.
5. Test Debug and ReleaseSafe. Add cross-target compilation for at least the project’s stated supported tier-1 targets; run only where the host can execute.
6. Add negative tests for malformed inputs and invariant violations. Tests must demonstrate the intended failure before the fix when practical.
7. For each phase, run Plumb topology_affected, focused tests, then the full canonical verify task. Record commands, toolchain version, counts, warnings, skipped cases, and limitations in the card log.
8. Perform one independent review after implementation, focused on public API stability, allocator/lifetime correctness, error fidelity, invalid-state prevention, test honesty, standard-library reuse, and unnecessary abstraction. Fix blocking findings and re-run the full gates.

## Completion criteria

- Canonical Debug and ReleaseSafe verification succeeds from a clean checkout on Zig 0.16.x.
- zig fmt --check, Zig compilation/AST analysis, ZLS/Plumb diagnostics, build/test output, and CI contain zero warnings and zero errors.
- No test leaks memory; allocation-failure tests cover every currently public allocating operation.
- Every current module is reachable from the public root and analyzed by the build/test graph.
- Every exported declaration is intentional, documented, and exercised by a doctest, unit test, integration test, or explicit compile-only test.
- Token/Event states are internally consistent by construction; directive cases are complete.
- ctype, UTF-8, Pool, Mark, error, and diagnostics findings above are resolved with regression evidence.
- No hidden allocations, hidden ownership transfer, silent truncation, invalid-value fabrication, or invalid-input prefix success remains.
- Standard-library reuse decisions and rejected abstractions are documented.
- PLAN-2 can begin from a green, warning-free, leak-free baseline without reopening foundational API/lifetime questions.

## Sequencing with the existing board

This card should be completed before PLAN-2. PLAN-3 through PLAN-8 already depend directly or transitively on PLAN-2, so one dependency edge is sufficient to place the quality refactor ahead of the feature chain. Do not combine this refactor with scanner/parser implementation.

## Log
- 2026-08-26T11:26:32Z created
- 2026-08-26T15:27:16Z Reproduced current state (Zig 0.16.0, sandbox-safe cache via ZIG_GLOBAL_CACHE_DIR=./.zig-cache-global): zig build + test Debug 47/47 pass; ReleaseSafe 47/47 pass; zig fmt --check clean; ast-check clean. Findings since card creation: #2 fingerprint present (0xc49f7ed1a8db0b85), #3 src/yaml.zig exists, #4 fmt clean, #5 Pool.init shadowing fixed (param renamed gpa), #6 Diag leak fixed (deinit frees messages). Still open: #9 Token/Event dual tag+payload (directive tag now exists), #10 isPrintableAscii 0x80-0xFF true (no external callers), #11 utf8.encode unvalidated + countCodepoints prefix semantics (no external callers), #12 create/createUninit duplicate (zeroes removed), #13 render 4096-byte silent-truncate remains, build.zig.zon .paths = all (needs narrowing), emit() missing errdefer on append failure.
