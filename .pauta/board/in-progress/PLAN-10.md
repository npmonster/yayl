---
id: PLAN-10
title: v0.9 release readiness: Zig quality round 2, docs overhaul, release packaging
created: 2026-08-30T01:49:35Z
updated: 2026-08-30T03:33:05Z
tags: []
deps: []
skills: []
review_rounds: 0
priority: 1
activation: hold
activation_at: ""
activation_id: ""
worker: zcode glm-5.3-flash
reviewer: independent review agent (user-directed 2026-08-30)
auto_review: false
---

## Plan

# v0.9 Release Readiness — Zig Quality Round 2 (PLAN-9 follow-up)

## Context

The codebase grew a lot since PLAN-9 converged (2026-08-27). A 2026-08-30 audit (three read-only explorations + plumb structural queries + `run_task verify` ground truth) confirms the suite is green but found remaining gaps vs Zig community guidelines and open-source release readiness. This card documents the full fix plan so an independent agent can review the outcome.

## Audit evidence (2026-08-30)

- **Correctness**: `edit.zig:279` and `edit.zig:347-348` swallow `error.OutOfMemory` as "no match" (`catch return`). `value.zig:66-69` (`parseToValue`) collapses every parse error to `error.InvalidSyntax`, discarding `InvalidUtf8` etc. `Document.parse`/`parseAll` (`document.zig:294-308`) hardcode a null Diag, so users of `yaml.parse` get bare error codes with no message.
- **Duplication (violates the DRY rule)**: special-float table in `document.zig:222` (`looksLikeFloat`) vs `value.zig:414` (`floatSpecial`); `inlineValue` switch re-implemented in `emitEntry` (`emitter.zig:397` vs `554`); `writeLiteral`/`writeFolded` shared preamble (`emitter.zig:709` vs `787`); `Document.pathSet` (`document.zig:545`) vs `Editor.applySet` (`edit.zig:292`); `Scanner.fail/failWith` (`scanner.zig:170`) vs `Parser.fail` (`parser.zig:139`); four temp-buffer trackers (`ownTemp`/`ownParams` vs `trackBytes`/`trackTags`).
- **Small cleanups**: `applyInsert` takes `anytype` for no reason (`edit.zig:353`); pointless `self_dropPairSpan` wrapper (`edit.zig:420`); `Schema.check` forwarding wrapper (`schema.zig:84`); allocator param naming drift; `file.zig` param-order inconsistency.
- **Coverage**: `file.parseAllFile` has zero tests; no allocation-failure injection for `parseAll` (multi-doc), value conversion, `schema.validate`, or file I/O; `Schema.mapStrict`/`Schema.scalar` never referenced by tests; fuzz is ASCII-only ≤256 bytes fixed seed; conformance/roundtrip silently skip when the corpus is absent (vacuous CI pass risk); CI runs neither roundtrip nor differential and is Linux-only.
- **Docs/packaging**: `build.zig.zon` says version `0.1.0`; `.paths` excludes `docs/` (fetched packages ship no usage guide); no CHANGELOG/CONTRIBUTING/examples; README lacks the agent-development disclosure (user requirement) and a Road-to-1.0 note; doc-comment gaps on `Diag.emit`, `Emitter.emitDocument`, schema constructors, `edit.zig` types; AGENTS.md module map rows stale vs the green gates. Topology's "126 undocumented exports" was checked and is mostly false positives (doc comments are present; index imprecision).
- **Long functions**: `checkSchema` (`schema.zig:136`, 104 lines) and `toZig` (`value.zig:173`, 96 lines) to be decomposed into per-kind helpers with focused tests. Scanner's long functions (`scanBlockScalar` 197 lines etc.) stay deliberately — they mirror libfyaml and are byte-exact-verified; churn risk beats benefit.
- **Ground truth at start**: `run_task verify` green (build + tests, Debug + ReleaseSafe). README install URL `github.com/npmonster/yayl` kept (user question unanswered; flag before tagging).

## Work plan

### Phase A — Correctness & API hardening
1. Editor OOM fix: distinguish `error.OutOfMemory` from no-match in `applyOne` `.delete` and `applyDelete`; regression tests.
2. `parseToValue` propagates real errors instead of collapsing to `InvalidSyntax`; tests for `InvalidUtf8` etc.
3. Public diagnostics: add `parseDiag`/`parseAllDiag(allocator, input, *Diag)` to `yaml.zig`, thread `?*Diag` through `Document.parse`/`parseAll`; tests assert positioned messages. Non-breaking addition.
   - Deliberately NOT changed: `parseAll` return type (documented ArrayList convention) and no writer-sink API (documented avoid-std.io scope decision in `src/file.zig`).

### Phase B — DRY consolidation
4. One special-float home; consumers reuse it.
5. Emitter: `emitEntry` calls `inlineValue()`; extract `writeBlockHeader` for literal/folded.
6. Shared walk-and-replace core for `pathSet`/`applySet` (byte-verbatim edit tests protect this).
7. Unified fail helper over Diag for scanner/parser; one temp-tracker pattern.
8. Cleanups from the list above (concrete type for `applyInsert`, inline wrapper, drop forwarding wrapper, `alloc` naming, consistent file.zig param order).
9. Decompose `checkSchema` and `toZig` into per-kind helpers.

### Phase C — Test coverage
10. `parseAllFile` test; failure-injection suites for parseAll/value/schema/file/Editor.apply; direct `Schema.mapStrict`/`Schema.scalar` and `Emitter.emitDocument` tests; multibyte UTF-8 fuzz (deterministic seed).
11. CI: add roundtrip + differential gates; fail CI if a corpus gate runs zero cases (vacuous-pass guard).

### Phase D — Docs & release packaging
12. README: agent-development statement (short, factual, near top), "Road to 1.0" (0.9 = public hardening release, seeking real-world use), `parseDiag` snippet; keep brief/direct, delegate detail to USAGE.md.
13. Fill remaining `///` gaps on pub decls; doctest coverage for key APIs; sanity-run `make docs`.
14. USAGE.md diagnostics section + accuracy pass; AGENTS.md module-map refresh; `build.zig.zon` → 0.9.0 with `.paths` including `docs/USAGE.md` and `examples/`; new CHANGELOG.md, CONTRIBUTING.md, examples/ (2 tiny compile-checked programs wired into build.zig + CI).

### Phase E — Verification & convergence
15. Full gates: `run_task verify`; `make conformance` (351/351), `make roundtrip`, `make differential` (269/269); plumb diagnostics clean; fmt clean; Debug + ReleaseSafe; zero leaks.
16. Logical commits via plumb git on main; card review by an independent agent (user-directed); fix blocking findings; converge card with evidence.

## Constraints (from AGENTS.md)
- Pool owns document nodes/strings; never borrow scanner memory into documents; errdefer every fresh allocation.
- Tests next to code; every module stays wired into `src/yaml.zig`'s test block.
- `PORT NOTE:` for any intentional deviation; error unions with `fail`/`failWith` positioned diagnostics.
- No new dependencies; std-lib reuse preferred.

## Loop
contract_version: 1
contract_revision: 1
objective: Take yayl from green to v0.9.0 public-release quality: fix correctness bugs found in the 2026-08-30 audit (Editor OOM-swallow, parseToValue error collapsing, unsurfaced diagnostics), consolidate duplicated logic per the DRY rule, close test-coverage gaps, add CI gates and vacuous-pass guards, and ship release packaging (version 0.9.0, CHANGELOG, CONTRIBUTING, examples, docs overhaul with agent-development disclosure and Road to 1.0). Round 2 of the PLAN-9 quality pass after the codebase grew.
observe:
invariants:
  - Document pool owns nodes/strings; scanner/parser memory never borrowed into documents
  - Every fresh allocation gets an errdefer
  - Tests stay in the same file as code; new modules pulled into yaml.zig test block
  - Intentional deviations from libfyaml get PORT NOTE comments
  - zig fmt clean; zero warnings; zero leaks in Debug and ReleaseSafe
verify:
  - zig fmt --check build.zig build.zig.zon src tests examples
  - zig build check
  - zig build test --summary all
  - zig build test -Doptimize=ReleaseSafe --summary all
  - grep -q '0.9.0' build.zig.zon
  - grep -qi 'agent' README.md
  - test -f CHANGELOG.md
  - test -f CONTRIBUTING.md
  - test -d examples
done_when:
  - zig fmt --check clean over build.zig build.zig.zon src tests examples
  - zig build check passes
  - zig build test passes in Debug with zero leaks
  - zig build test -Doptimize=ReleaseSafe passes
  - make conformance reports 351/351 and make roundtrip passes with corpus present
  - make differential reports 269/269 parity
  - OOM no longer swallowed in Editor delete paths; regression tests prove it
  - parseToValue propagates real errors; parseDiag/parseAllDiag public and tested
  - parseAllFile tested; checkAllAllocationFailures covers parseAll, value, schema, file I/O, Editor.apply
  - Schema.mapStrict/Schema.scalar and Emitter.emitDocument have direct tests; multibyte fuzz added
  - CI runs roundtrip + differential and fails on zero-case vacuous runs
  - build.zig.zon version is 0.9.0 and .paths ships docs/USAGE.md and examples/
  - CHANGELOG.md, CONTRIBUTING.md and examples/ exist and are wired into build.zig
  - README states agent development and Road to 1.0; doc-comment gaps filled; USAGE.md has diagnostics section; AGENTS.md module map refreshed
  - all work merged on main; no leftover branches or worktrees
retry_budget: 5
escalate_when:
  - any conformance/roundtrip/differential gate regression cannot be fixed without changing verified output
  - a DRY refactor would change verified emit output
  - corpus fetch fails and gates cannot run

## Authority
allowed_paths:
  - src/**
  - tests/**
  - examples/**
  - docs/**
  - README.md
  - AGENTS.md
  - CHANGELOG.md
  - CONTRIBUTING.md
  - build.zig
  - build.zig.zon
  - Makefile
  - .github/workflows/ci.yml
allowed_external_actions:
  - run scripts/fetch-corpus.sh to vendor the pinned yaml-test-suite corpus for conformance/roundtrip gates
forbidden_actions:
  - introduce third-party dependencies
  - decompose scanner.zig long functions (byte-exact-verified)
  - change verified conformance/roundtrip/differential output
  - force-push or rewrite main history
change_budget: Refactor + additive API + docs/packaging. No behavior change to verified parser/emitter output: conformance (351/351), roundtrip (265/265 + fixtures) and differential (269/269) gates must stay byte-identical. Scanner long functions deliberately NOT decomposed (mirrors libfyaml, byte-exact-verified).

## Stop
state: active

## Iteration Ledger
- {"kind":"contract_revision","at":"2026-08-30T01:49:35Z","previous_revision":0,"contract_revision":1,"actor":"zcode glm-5.3-flash","reason":"User approved the v0.9 release-readiness plan (2026-08-30): quality round 2 after the codebase grew post-PLAN-9, plus docs/packaging for a public release. Card documents audit evidence and the full fix plan for independent review."}
- {"kind":"execution_held","at":"2026-08-30T01:49:35Z","contract_revision":1,"activation":"hold","actor":"zcode glm-5.3-flash","reason":"held until this revision is approved"}
- {"kind":"iteration","at":"2026-08-30T03:11:52Z","contract_revision":1,"verification":"zig fmt --check build.zig build.zig.zon src tests examples","result":"pass (exit 0, no output)","context":"PLAN-10 completion sweep, 2026-08-30, all work on main at a79324d","artifact":"git a79324d (HEAD, main)","hypothesis":"Formatting gate passes over every source tree including the new examples/","action":"Run controller verification: zig fmt --check build.zig build.zig.zon src tests examples","next_state":"remaining verify entries"}
- {"kind":"iteration","at":"2026-08-30T03:12:04Z","contract_revision":1,"verification":"zig build check","result":"pass","context":"PLAN-10 completion sweep","artifact":"git a79324d (HEAD, main)","hypothesis":"The public root compiles (no lazily-unanalysed declarations)","action":"Run controller verification: zig build check","next_state":"remaining verify entries"}
- {"kind":"iteration","at":"2026-08-30T03:12:13Z","contract_revision":1,"verification":"zig build test --summary all","result":"pass — 145/145, zero leaks","context":"PLAN-10 completion sweep; suite includes new failure-injection, fuzz, parseAllFile, schema/emitter direct tests","artifact":"git a79324d (HEAD, main)","hypothesis":"Zero leaks (std.testing.allocator), all 145 tests pass in Debug","action":"Run controller verification: zig build test --summary all","next_state":"remaining verify entries"}
- {"kind":"iteration","at":"2026-08-30T03:12:43Z","contract_revision":1,"verification":"zig build test -Doptimize=ReleaseSafe --summary all","result":"pass — 145/145","context":"PLAN-10 completion sweep; guards against Debug-only assumptions","artifact":"git a79324d (HEAD, main)","hypothesis":"All 145 tests pass under ReleaseSafe","action":"Run controller verification: zig build test -Doptimize=ReleaseSafe --summary all","next_state":"remaining verify entries"}
- {"kind":"iteration","at":"2026-08-30T03:12:51Z","contract_revision":1,"verification":"grep -q '0.9.0' build.zig.zon","result":"pass","context":"PLAN-10 completion sweep; release version bump","artifact":"git a79324d (HEAD, main)","hypothesis":"Package version is 0.9.0 for the public release","action":"Run controller verification: grep -q '0.9.0' build.zig.zon","next_state":"remaining verify entries"}
- {"kind":"iteration","at":"2026-08-30T03:12:59Z","contract_revision":1,"verification":"grep -qi 'agent' README.md","result":"pass — README carries the \"Developed by agents\" callout","context":"PLAN-10 completion sweep; user-required agent-development disclosure","artifact":"git a79324d (HEAD, main)","hypothesis":"README states the project is developed by agents","action":"Run controller verification: grep -qi 'agent' README.md","next_state":"remaining verify entries"}
- {"kind":"iteration","at":"2026-08-30T03:13:29Z","contract_revision":1,"verification":"test -f CHANGELOG.md","result":"pass","context":"PLAN-10 completion sweep; release packaging files","artifact":"git a79324d (HEAD, main)","hypothesis":"CHANGELOG exists with the 0.9.0 entry","action":"Run controller verification: test -f CHANGELOG.md","next_state":"remaining verify entries"}
- {"kind":"iteration","at":"2026-08-30T03:13:40Z","contract_revision":1,"verification":"test -f CONTRIBUTING.md","result":"pass","context":"PLAN-10 completion sweep; release packaging files","artifact":"git a79324d (HEAD, main)","hypothesis":"CONTRIBUTING exists (agent playbook pointer + make verify contract)","action":"Run controller verification: test -f CONTRIBUTING.md","next_state":"remaining verify entries"}
- {"kind":"iteration","at":"2026-08-30T03:14:26Z","contract_revision":1,"verification":"test -d examples","result":"pass","context":"PLAN-10 completion sweep; release packaging files","artifact":"git a79324d (HEAD, main)","hypothesis":"examples/ exists and is wired into build.zig (zig build examples compiled and ran both programs successfully)","action":"Run controller verification: test -d examples","next_state":"all contract verify entries recorded; submit for review and start the independent review agent"}

## Log
- 2026-08-30T01:49:35Z created
- 2026-08-30T03:11:13Z 2026-08-30T05:20:00Z Execution complete (commits 01587b8, 2682fc5, c5f85c1, a79324d on main). Evidence: zig build test Debug 145/145 zero leaks; ReleaseSafe 145/145; make verify green (fmt incl. examples + check + both optim modes + conformance 351-case corpus + roundtrip); make differential 269 compared / 0 mismatches; zig build examples compiled and both programs run (parseDiag emits "2:4: error: mapping values are not allowed in this context"; edit example byte-faithful). Phase A: Editor deletes no longer swallow OOM (regression: OOM-injected delete batch); parseToValue keeps real error identity; parseDiag/parseAllDiag added; InvalidCodepoint added to YamlError (was reachable but unnamed). Phase B DRY: diag.emitBestEffort (4 call sites unified), floatSpecial single home, mappingWalkOrCreate/mappingReplace shared by pathSet+applySet (pathSet now reports NotAMapping instead of InvalidSyntax for a non-mapping intermediate — deliberate, more precise), writeBlockHeader/stripTrailingNewlines shared by literal+folded, Edit.insert named type, self_dropPairSpan inlined, Schema.check wrapper removed, file.zig Error derives from diag.YamlError, parser.trackBytes errdefer leak fix. Phase C: parseAllFile tested (was zero); failure injection over parseAll/value/schema/file/Editor found and fixed 4 real library leaks (nodeToValue partial list/map + member key; Schema.validate errdefer freed list but not violation strings; appendViolation + required-arm partial struct init; fromZig struct/array); direct Schema.mapStrict/Schema.scalar + Emitter.emitDocument tests; seeded fuzz extended to multibyte UTF-8 and arbitrary bytes; conformance/roundtrip fail on zero-case corpus (vacuous guard, >= 300); missing fixtures dir now an error; CI adds roundtrip + differential + report-count assertion. Phase D: version 0.9.0; .paths ships docs/USAGE.md + examples + CHANGELOG + CONTRIBUTING; README states "Developed by agents" end-to-end AI development under human direction, Road to 1.0 section, quick start moved to std.process.Init idiom; AGENTS.md module map refreshed (scanner/parser/document/emitter rows stale, markup claimed unported despite src/markup.zig); doc comments filled (schema constructors, edit.Error/Insert, Diag.emit, Emitter.emitDocument). DECISIONS (considered and rejected): cross-module temp-tracker generic (4 call sites with different finalize-vs-register contracts — PLAN-9 rule: leave code that only looks similar); scanner long-function decomposition and colIsize helper (byte-exact-verified libfyaml-mirroring code; churn > benefit); parseAll return-type change and writer-sink API (documented v1 scope decisions — avoid-std.io, ArrayList convention); pool.init backing_allocator naming kept (PLAN-9 lifetime-contract decision). FLAG: README install URL github.com/npmonster/yayl not user-confirmed — confirm before tagging v0.9.0.
- 2026-08-30T03:31:11Z 2026-08-30T05:45:00Z Independent review round 1 (read-only reviewer agent, user-directed): all 7 gates re-run independently and PASS (Debug 145/145 zero leaks, ReleaseSafe 145/145, fmt clean, check green, roundtrip 265 pass + fixtures, conformance 351/0/0, differential 269 compared / 0 mismatches, examples build and run). Acceptance A-M: 12 pass, E partial. FINDINGS: [blocking] Editor.applySet still contained its hand-rolled walk-and-replace — the consolidation rewrite was lost when an aborted transaction was reconstructed, contradicting the card/CHANGELOG claim; [non-blocking] dead floatSpecial twin in value.zig; [non-blocking] parseDiag example comment said 2:3, verified output is 2:4 (examples/parse.zig, README, USAGE.md); [non-blocking] pathSet fall-through on a replace miss would append a duplicate key. All four fixed in commit 6daf853 (applySet now uses mappingWalkOrCreate/mappingReplace with unchanged AmbiguousOperation/NotAMapping semantics; defensive loud error instead of duplicate append; dead twin deleted; docs corrected). Gates re-run green after fixes: Debug 145/145 zero leaks, ReleaseSafe 145/145, roundtrip + conformance pass, examples byte-faithful. Reviewer re-verification requested. BOARD NOTE: submit_for_review/move are gated on daemon-run controller verification, and contract activation is human-only on this board (activate_execution refused for this caller); the strict-loop lane transitions therefore await the user's activation/approval in the board UI. Code work is complete and merged on main.
- 2026-08-30T03:33:05Z 2026-08-30T06:05:00Z Independent review round 2: all four findings RESOLVED (applySet consolidation verified with unchanged AmbiguousOperation/NotAMapping semantics and correct key-slice cleanup; single floatSpecial home confirmed by grep; 2:4 doc correction matches verified example output; replace-miss now a loud InvalidSyntax in both pathSet and applySet). Reviewer re-ran Debug 145/145 zero leaks, ReleaseSafe 145/145, fmt clean at 6daf853 and confirmed the editing-layer-only diff cannot alter verified emit output. VERDICT: PASS. Note: peer session radiant-hound's commit 3c2f848 (its own review fixes: pub freeValue, .inf/.nan value round trips, %TAG piecewise, tombstone OOM propagation, atomic-write hardening, differential harness PyYAML parsing) landed at 10:41 before this card's edits began — clean sequencing, no collisions, and it was inside the reviewed range. Tidy state: single branch main at 6daf853, no leftover branches or worktrees, no stray test artifacts. REMAINING BOARD ACTION (human): contract revision 1 activation is human-only on this board, and the daemon's controller verification gates the review/done transitions; activate/approve PLAN-10 in the board UI to move it through review to done. All code work is merged on main.
