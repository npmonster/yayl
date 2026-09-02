---
id: PLAN-12
title: 0.13.0 completeness: dogfood, comment API, fuzzing, hardening lane, policy/examples/bench
created: 2026-09-01T09:16:37Z
updated: 2026-09-02T07:59:08Z
tags: [release, 0.13.0, completeness, api, fuzzing, docs]
deps: []
skills: []
review_rounds: 0
priority: 1
activation: hold
activation_at: ""
activation_id: ""
---

## Plan

# 0.13.0 completeness — five workstreams, all mandatory

**ALL FIVE workstreams (A–E) below are required. This card is not done when one of them is done. It is done when every done_when line in the contract is satisfied and the 0.13.0 release is rolled.** Do not close, submit, or declare success with any workstream unfinished. If one workstream is blocked, log the blocker, escalate, and continue the others — never silently drop it.

## Context — state of the project as of 2026-09-01

- **v0.12.0 is released**: tagged at commit 7a0f539, pushed, CI fully green including the first real run of the platform matrix (windows-latest, ubuntu-24.04-arm, macos-latest), tag-version-match, and the consume-as-a-dependency job.
- **Post-tag work already on main**: 9f53814 "fix(emit): bound emission depth so a built tree cannot overflow the stack" (Emitter.max_depth = 1000, error.NestingTooDeep). More hardening is in flight from the plumb session **vast-wren** — see Workstream D.
- **Pinned green baselines** — these exact results must hold at every commit of this card unless a done_when explicitly changes them:
  - `zig build conformance` → 351 pass, 0 fail, 0 skip, 0 stale
  - `zig build roundtrip` → 265 pass, 0 fail, 4 skip
  - `zig build preservation` → all tests pass, zero failures, all three sweeps (fixtures, corpus, variants)
  - `sh scripts/consumer-smoke.sh` → "consumer ok: parsed, edited and re-emitted byte-faithfully"
  - `scripts/differential.sh` → ≥250 compared (currently 269), 0 mismatches. NOTE: `make verify` does NOT run differential; run it separately.
- **Repo facts a worker must know**:
  - Zig 0.16.0 (CI pins it via mlugg/setup-zig).
  - `vendor/` is gitignored. A fresh clone/worktree needs `sh scripts/fetch-corpus.sh` and `sh scripts/fetch-libfyaml.sh` before conformance/roundtrip/differential work; in the existing checkout it is already present.
  - The full local gate is `make verify` (fmt, check, test Debug + ReleaseSafe, examples, conformance, roundtrip, preservation, consumer-smoke) PLUS `scripts/differential.sh` PLUS `make consume`.
  - Public API surface is `src/yaml.zig` (what consumers see). Internals deliberately unreachable to consumers live in `src/internal.zig`. Do NOT re-export internals.
  - Documented, deliberate gaps (do not "fix" in passing): duplicate mapping keys are kept (lenient), merge keys (`<<`) are not resolved.
  - Existing limits: scanner nesting cap 200 (`scanner.max_nesting`), alias-expansion budgets `value.Limits`/`schema.Limits` (default 1 << 20, `Limits.unlimited` to opt out, error.LimitExceeded), emitter `max_depth` 1000 (error.NestingTooDeep).
- **Shared checkout** — several agent sessions share this one working tree. Rules: check `workspace_sessions` (plumb) before starting; announce intent with `share_intent`/`leave_note`; NEVER `git stash`, `git reset`, `git checkout -- <file>`, or `git add -A`; commit path-limited (`git commit -m msg -- <files>`); treat any file a peer recently touched as potentially changed and re-read before editing.

---

## Workstream A — Dogfood: a real consumer exercising the whole public API (item 1)

**Why**: no real program has used the full surface end-to-end; API friction is invisible until something real consumes it.

**Build** `examples/yq_lite.zig` (name it to match existing example naming — look in `examples/` first): a small command-line YAML tool using ONLY the public `yaml` module, exercising every public surface area:
1. Parse a file from disk (the file I/O API in `src/file.zig`'s public surface, not raw std.fs).
2. Get, set, delete, insert, and move values by path (the edit API).
3. Convert a subtree to a native Zig value and back (the value API, `src/value.zig` surface).
4. Validate against a schema (the schema API, `src/schema.zig` surface).
5. Re-emit and write back atomically; unedited regions must be byte-identical.

Read `docs/USAGE.md` and the public decls of `src/yaml.zig` FIRST and use the documented names exactly — do not guess API names; if a documented name does not compile, that is a finding (doc bug), log it.

**Also produce** a friction report: every place the API forced an awkward workaround, an undocumented behaviour, a missing convenience, or a doc mismatch. Append it to this card's Log AND file each concrete defect as its own follow-up note in the Log with file:line evidence.

**Wire it in**: the example must build under `zig build examples` so CI compiles it forever.

**Done when**: the example builds and runs against a real YAML file in CI's examples step; the friction report is in the Log (an empty report is suspicious — look harder).

---

## Workstream B — Comment read/write API (item 2) — DESIGN FIRST, then implement

**Why**: the library's headline is comment preservation, yet comments exist only as passive gap bytes — no way to read, add, edit, or delete one. Two prior agents (crisp-dingo, vast-wren) independently agreed this needs a design pass because it touches comment spans in the markup/source layer and therefore the round-trip guarantee.

**Phase B1 — design document** at `docs/design/comments.md`, covering at minimum:
- Representation: how a comment attaches to a node — leading (own-line comments above), trailing/inline (same line after value), and document-level head/foot comments. Where spans live in the source-markup layer (study how `src/document.zig` / the markup types track spans today before proposing).
- Read surface: given a node/path, return its comments (which kinds, in what form — raw text with or without `#`?).
- Write surface: set/append/delete a comment at a node; what happens to a comment whose node is deleted or moved (does it travel with the node? orphan? delete?).
- Round-trip contract: an untouched comment stays byte-identical (already true via gap bytes); a written comment emits in a canonical form; parse(emit(doc)) must yield the same comments back (comment round-trip test).
- Edge cases to address explicitly: comments inside flow collections, comments between a key and its value, multiple stacked leading comments, comment-only documents, CRLF documents.
- Out of scope is fine — but every exclusion must be written down.

**STOP after B1**: post the design in the Log and request human review via `request_decision`. Do NOT start B2 until the design is approved. This is the one human gate inside the card.

**Phase B2 — implement** the approved design: API in the public surface, emitter support, preservation-sweep additions asserting comment survival across every existing edit sweep, comment round-trip tests, `docs/USAGE.md` section, CHANGELOG Unreleased entry.

**Done when**: approved design doc committed; read+write+delete of comments works via public API with tests; preservation sweep still zero failures; comment round-trip test green.

---

## Workstream C — Fuzzing + allocation-failure injection (item 3)

**Why**: standard hardening for a parser library, still absent; also the best tool to resolve three unreproduced suspicions.

**C1 — fuzz harness** for the scanner/parser: arbitrary bytes into `Document.parse` (and the streaming event API) must produce either a parsed document or a typed error — never a crash, hang, stack overflow, or leak. Prefer Zig 0.16's built-in fuzzing (`std.testing.fuzz` / `zig build test --fuzz`) if it works in this build graph; verify against Zig 0.16 documentation rather than memory. If the built-in fuzzer is not workable, fall back to a deterministic randomized harness: seeded PRNG mutating corpus documents, seed printed on failure so every crash is reproducible. Seed corpus: `vendor/yaml-test-suite` inputs + the 14 fixtures. Add a bounded smoke version (a few seconds) to `zig build test` so CI always runs some fuzzing; long runs stay a manual target.
- Also fuzz the second-order property: for inputs that parse, emit must not crash, and parse(emit(parse(x))) must succeed (idempotence probe — this held 369/369 on the corpus previously; keep it true).

**C2 — allocation-failure injection**: use `std.testing.checkAllAllocationFailures` (verify the Zig 0.16 name) over: parse, emit, the value conversion entry points, schema check, and the edit operations. Contract: on any allocation failure, a typed OOM error and no leak, no crash, no partially-corrupted document reachable afterwards. Run under the leak-checking test allocator. Beware runtime: bound the input sizes so the sweep stays CI-viable (see PLAN-11's allocator-cost lesson: per-allocation stack traces cost ~30x; use the same `stack_trace_frames = 0` DebugAllocator trick for big sweeps).

**C3 — the three unreproduced suspicions** (from the v0.12.0 audit; none proven, none cleared): the named one is `edit.cloneTree` pointed at a second Document possibly corrupting spans. Find the other two in the audit trail (search plumb memories and PLAN-10/11 logs for "suspicion"/"unreproduced"; ask peer sessions if still live). For each: write a directed test that tries hard to reproduce; either (a) reproduce → fix → regression test proven to gate (revert fix, watch it fail, restore), or (b) record in the Log why it cannot happen, with the specific code path evidence. "Ran out of ideas" is escalation, not closure.

**Done when**: fuzz smoke runs in `zig build test`; a documented longer fuzz target exists; allocation-failure sweep green over all five entry-point families; all three suspicions individually resolved-or-cleared in the Log with evidence.

---

## Workstream D — Land the hardening lane (item 4) — COORDINATE, don't duplicate

**Why**: vast-wren (a peer plumb session) declared and partially delivered this lane. The emitter depth bound is already on main (9f53814). The rest was in flight: public **ParseOptions** (input-size bound, configurable max_nesting, embedded-NUL policy) across scanner/parser/document/yaml/diag, **EmitOptions + multi-document write**, and value/schema surface gaps.

**Protocol — follow exactly**:
1. `workspace_sessions` (plumb): is vast-wren still active? What did it recently touch/commit?
2. `git log --oneline -20` — what has already landed since 9f53814?
3. If vast-wren is live: `leave_note` to vast-wren announcing this card, ask what remains in its lane and what it wants reviewed vs. taken over. Wait a reasonable window (`check_messages` with wait); silence is not refusal — proceed read-only until answered, and never edit a file its recent writes touch.
4. If vast-wren is gone: take over from what is committed. Its uncommitted work, if any remains in the tree, is NOT yours — do not commit or revert it; escalate instead.

**The work**: review-and-integrate what landed (correctness, tests, docs, CHANGELOG Unreleased entries, no public-surface leaks of internals), and implement whatever of the declared scope never landed. Every option in ParseOptions/EmitOptions needs: a default that preserves current behaviour exactly (pinned baselines must not move), a test for the non-default path, and a `docs/USAGE.md` mention.

**Done when**: ParseOptions (input-size bound, configurable nesting, embedded-NUL policy) and EmitOptions + multi-document write exist in the public API with tests and docs; the value/schema surface gaps vast-wren enumerated are closed or explicitly logged as deferred with reasons; all pinned baselines unchanged.

---

## Workstream E — SECURITY.md, examples, bench in CI (item 5)

**E1 — SECURITY.md** at repo root: supported versions (latest tagged release), how to report (GitHub private vulnerability reporting for this repo), and the actual threat model — yayl parses untrusted input, so enumerate the real bounds and their defaults honestly: scanner nesting cap 200, value/schema alias-expansion Limits (1 << 20 default, opt-out exists), emitter max_depth 1000, plus whatever ParseOptions adds from Workstream D (write E1 AFTER D lands so this list is true). Also state the documented gaps (duplicate keys kept, merge keys unresolved) since both are security-relevant to consumers.

**E2 — examples** for the three undocumented-by-example surfaces: value conversion, schema validation, file I/O. One focused example file each in `examples/`, matching the existing examples' style and wired into `zig build examples` so CI compiles them. If Workstream A's yq_lite already covers a surface well, a thin dedicated example is still required — examples are documentation, one concept each.

**E3 — bench in CI**: a `zig build bench` target timing the hot paths (parse, emit, parse+edit+emit round trip) over the corpus, printing stable machine-readable lines. Wire into CI as a NON-GATING job (report numbers, never fail the build on them — shared runners are too noisy for thresholds; that can come later). Record the local baseline numbers in the Log.

**Done when**: SECURITY.md exists and is accurate against the code; three examples compile in CI; bench target runs locally and in CI without gating.

---

## Release 0.13.0 — roll and tag (LAST, after A–E are all done)

1. Confirm every done_when above is satisfied; every workstream logged.
2. Roll: move CHANGELOG `## Unreleased` content under `## 0.13.0 — <date>`; set `.version = "0.13.0"` in `build.zig.zon`; update BOTH README install pins to `#v0.13.0`; sweep for stale `0.12` references outside CHANGELOG history (`git grep '0\.12' -- . ':!CHANGELOG.md'`).
3. Commit `release: 0.13.0` (path-limited).
4. Verify the release commit in a DETACHED WORKTREE (the shared tree may be dirty with peers' work): `git worktree add --detach <scratch>/verify-<sha> <sha>`, copy `vendor/` from the main checkout into it, run `make verify` AND `scripts/differential.sh` there. All pinned numbers must hold. Remove the worktree after.
5. Push the release commit; wait for CI green (including the platform matrix).
6. **STOP — ask the human for the tag go.** Tags are permanent here by design. With the go: `git tag -a v0.13.0 <release-sha> -m "yayl v0.13.0"` — ALWAYS by explicit sha (HEAD moves under you on this tree) and ALWAYS with the `v` prefix (CI's tag-version-match only runs on `refs/tags/v*`; an unprefixed tag silently skips the check). Verify `git rev-parse v0.13.0^{}` prints the release sha, then push the tag, then confirm the tag's CI run is green.

---

## Suggested order

A and C are independent — start either. B1 (design) early, since its human-approval gate has latency; B2 after approval. D early read-only (coordination), implementation as the peer lane clarifies. E1 strictly after D; E2/E3 anytime. Release roll strictly last. If this card is later decomposed into child cards (delegate-and-decompose skill), the release-roll child must depend on all five workstream children — completeness is the point of this card.

## Loop
contract_version: 1
contract_revision: 1
objective: Complete ALL FIVE post-v0.12.0 workstreams and roll release 0.13.0: (A) a real consumer example exercising the entire public API with a friction report; (B) a design-approved comment read/write API — the library's largest product gap; (C) fuzzing plus allocation-failure injection, resolving the three unreproduced audit suspicions including edit.cloneTree cross-Document span corruption; (D) land the hardening lane in coordination with peer session vast-wren — ParseOptions (input-size bound, configurable nesting, embedded-NUL policy), EmitOptions + multi-document write, value/schema surface gaps; (E) SECURITY.md with an honest threat model, examples for value/schema/file, and a non-gating bench job in CI. Then roll and (with explicit human go) tag v0.13.0. Partial completion is failure: the card converges only with every workstream done or explicitly escalated.
observe:
  - v0.12.0 is tagged at 7a0f539 and its CI run is fully green, including the platform matrix's first real run (windows-latest, ubuntu-24.04-arm, macos-latest)
  - 9f53814 (emitter depth bound) is already on main under CHANGELOG ## Unreleased; peer session vast-wren has declared more hardening in flight across scanner/parser/document/yaml/diag — check plumb workspace_sessions and git log before writing anything in those files
  - the shared checkout may be dirty with peers' uncommitted work at any moment; git status clean is never assumed
  - make verify does NOT run scripts/differential.sh; both are required for full evidence
  - vendor/ is gitignored — a fresh worktree needs scripts/fetch-corpus.sh + scripts/fetch-libfyaml.sh (or a copy of vendor/) before conformance/roundtrip/differential can run
invariants:
  - Pinned baselines hold at every commit: conformance 351 pass/0 fail/0 skip/0 stale; roundtrip 265 pass/0 fail/4 skip; preservation zero failures across all three sweeps; differential >=250 compared with 0 mismatches; consumer-smoke byte-faithful
  - Every new option (ParseOptions, EmitOptions, comment API) defaults to exactly current behaviour — no pinned number moves as a side effect
  - Public surface stays deliberate: nothing from src/internal.zig re-exported; every new public decl is documented in docs/USAGE.md and has a test
  - Deliberate documented gaps stay untouched unless a done_when says otherwise: duplicate mapping keys kept, merge keys (<<) unresolved
  - Every regression test is proven to gate: revert the fix, watch it fail, restore, watch it pass
  - Shared checkout etiquette: path-limited commits only; never git stash/reset/checkout -- /add -A; never commit, revert, or overwrite a peer's uncommitted work; re-read any file a peer recently touched before editing
  - Workstream B implementation does not start before the B1 design document is human-approved via request_decision
  - The v0.13.0 tag is created only after explicit human go, always annotated, always by explicit sha, always v-prefixed
verify:
  - zig fmt --check build.zig build.zig.zon src tests examples
  - zig build check
  - zig build test --summary all
  - zig build examples
  - zig build conformance --summary all
  - zig build roundtrip --summary all
  - zig build preservation --summary all
  - sh scripts/consumer-smoke.sh
  - sh scripts/differential.sh
  - test -f SECURITY.md
  - test -f docs/design/comments.md
  - grep -qi 'comment' docs/USAGE.md
  - grep -q '0.13.0' build.zig.zon
  - grep -q 'v0.13.0' README.md
done_when:
  - A: an examples/ program builds under zig build examples and exercises file I/O, all five edit operations, value conversion, and schema validation through the public yaml module only, with a friction report appended to the card Log
  - B: docs/design/comments.md exists, was approved by the human via request_decision BEFORE implementation, and the implemented comment API can read, write, and delete leading and inline comments through the public surface with round-trip tests green and the preservation sweep still at zero failures
  - C: a fuzz smoke test runs inside zig build test with a documented longer-run target; allocation-failure injection covers parse, emit, value conversion, schema check, and edit operations with no leak or crash; each of the three audit suspicions (edit.cloneTree cross-Document spans plus the two recovered from the audit trail) is individually reproduced-and-fixed or cleared-with-evidence in the Log
  - D: ParseOptions (input-size bound, configurable max_nesting, embedded-NUL policy) and EmitOptions plus multi-document write exist in the public API with tests and USAGE docs, coordinated with vast-wren per the card protocol; value/schema surface gaps closed or logged as deferred with reasons
  - E: SECURITY.md documents the real bounds (scanner cap, Limits, emitter depth, ParseOptions) and the reporting channel; dedicated examples exist for value, schema, and file surfaces; a zig build bench target runs in CI as a non-gating job
  - CHANGELOG ## Unreleased is rolled to ## 0.13.0 with every user-visible change from A-E recorded; .version is 0.13.0; both README pins read #v0.13.0; no stale 0.12 reference outside CHANGELOG history
  - the release commit is verified green in a detached worktree (make verify plus differential) before push, and CI is green on the pushed commit
  - v0.13.0 is tagged at the release commit by explicit sha with human go recorded in the Log, git rev-parse v0.13.0^{} prints that sha, and the tag's CI run (including tag-version-match and the platform matrix) is green
retry_budget: 8
escalate_when:
  - the comment-API design cannot preserve the byte-identical round-trip guarantee for untouched comments
  - a fuzz or allocation-failure finding requires changing verified conformance or roundtrip output to fix
  - an audit suspicion can be neither reproduced nor cleared with code-path evidence after a directed attempt
  - vast-wren's lane conflicts with this card and coordination is unresolved, or its uncommitted work blocks a required file
  - any pinned baseline cannot be held without weakening an assertion
  - the human tag go is not granted — the card stops at the pushed release commit, tag pending

## Authority
allowed_paths:
  - src/
  - tests/
  - examples/
  - docs/
  - scripts/
  - .github/workflows/
  - SECURITY.md
  - CHANGELOG.md
  - README.md
  - build.zig
  - build.zig.zon
  - Makefile
allowed_external_actions:
  - run scripts/fetch-corpus.sh and scripts/fetch-libfyaml.sh to vendor pinned corpora
  - create and remove a detached git worktree under the session scratchpad for release verification
  - plumb leave_note/check_messages/share_intent to coordinate with peer sessions
  - push the release commit and, only after explicit human go, the v0.13.0 tag
forbidden_actions:
  - introduce third-party dependencies
  - re-export anything from src/internal.zig
  - weaken or delete an existing assertion to make a gate pass — a documented normalization is a counted skip, never asserted away
  - change verified conformance or roundtrip output
  - git stash, git reset, git checkout -- <path>, or git add -A in the shared checkout
  - commit or revert a peer session's uncommitted work
  - tag without explicit human go, tag without the v prefix, or tag HEAD implicitly instead of the release sha
  - force-push or rewrite main history
  - close the card with any of the five workstreams silently dropped
change_budget: Five additive workstreams plus a release roll. New code is additive (examples, tests, fuzz/allocation harnesses, SECURITY.md, bench, comment API, options structs); behaviour changes are confined to opt-in options and the approved comment design. Emitter/parser edits beyond what a workstream's done_when needs — or any fix that would move a pinned baseline — are escalation, not scope.

## Stop
state: active

## Iteration Ledger
- {"kind":"contract_revision","at":"2026-09-01T09:17:21Z","previous_revision":0,"contract_revision":1,"actor":"patient-storm (claude-code)","reason":"User request 2026-09-01: a single complete card carrying all five post-v0.12.0 workstreams into 0.13.0, written with enough detail for a smaller model to execute without dropping any item. Drafted HELD; activation is human-only on this board."}
- {"kind":"execution_held","at":"2026-09-01T09:17:21Z","contract_revision":1,"activation":"hold","actor":"patient-storm (claude-code)","reason":"held until this revision is approved"}

## Log
- 2026-09-01T09:16:37Z created
- 2026-09-01T10:32:37Z vast-wren (peer session, plumb) — **Workstream D is delivered; B1 is delivered.** Logged here so this card's contract reflects the tree rather than the plan. Nothing below was done under this card's authority: the card is HELD and unapproved. It was my own lane, agreed with crisp-dingo by plumb before the card existed, and it happens to satisfy D. Re-verify rather than trusting this entry.

Commits on main, all after v0.12.0 (7a0f539), all under CHANGELOG `## Unreleased`, each verified with `make verify` end to end before commit:

- `9f53814` fix(emit): `Emitter.max_depth` (1000) + `error.NestingTooDeep`, guarding emitContent/emitNode/emitFlowBody. Closes the stack-overflow path on a tree built rather than parsed — the scanner's 200 cap never applies to one that was never scanned. Reviewed by patient-storm, which confirmed by full trace that those three heads are every descending path.
- `25942b1` feat(parse): **ParseOptions** = `scanner.Options` — `max_input_bytes` (64 MiB, entirely new: the in-memory entry points had no bound at all), `max_nesting` (200, previously unreachable without hand-rolling a Scanner), `embedded_nul`. New `error.InputTooLarge`, checked before scanning. `parseOpts`/`parseAllOpts` added; `parse`/`parseAll`/`parseDiag`/`parseAllDiag` keep their signatures and delegate with defaults.
- `9596f27` feat(emit): **writeAll** — the stream counterpart `parseAll` never had. Inserts `---` only where a boundary is required and absent. The round-trip gate now runs THROUGH it, which is how corpus L383 was found (document 1's region ends mid-line at `--- foo`, its trailing comment lives in document 2's leading bytes; the first version cut that line in half). Byte-exactness is therefore checked against 265 real streams, not six hand-written shapes.
- `b5c9a50` fix(diag): review fixes from patient-storm — the NUL diagnostic was rendering as `1:1` because `Diag.render` prints line:column and never offset, so the one thing a user reads was wrong; `markOf` now computes both, and the test pins `2:4`. UTF-16 BOM named instead of blamed on a stray NUL. `max_depth` doc corrected from "≥ half" to `max_depth - 2`.
- `2a93f9f` feat(schema): `floatRange`, `strLen` (codepoints), `seqLen`, `nullable`, `allOf`/`anyOf`/`oneOf`. Branch exploration shares the enclosing `Limits` budget, so a composite cannot multiply work past the bound (there is a test). `Kind.seq` payload changed from `*const Schema` to a struct; `Schema.seq(items)` unchanged.
- `7f1ef7d` feat(value): string-keyed maps (all four std spellings, detected by shape), tagged unions (externally tagged), single-item pointers in `toZig`. Duplicate keys: first wins, matching `Node.lookup`.
- `417c7d7` feat(emit): **EmitOptions** via `writeOpts`/`writeAllOpts` — indent for content the emitter lays out itself, clamped 1..8, plus the depth bound. A test asserts it CANNOT reach bytes that re-emit verbatim: the round-trip guarantee outranks a layout preference.
- `5799f11` docs(design): **`docs/design/comments.md`** — workstream B1. Awaiting the human decision your contract gates B2 on.

**Against D's done_when:** ParseOptions ✓, EmitOptions ✓, multi-document write ✓, tests ✓, USAGE docs ✓, coordinated with vast-wren ✓ (I am vast-wren). Value/schema surface gaps closed rather than deferred.

**Pinned baselines held at every commit**, re-verified on the last one: conformance 351/0/0/0, roundtrip 265 pass/0 fail/4 skip, preservation zero failures across fixtures/corpus/variants, consumer-smoke byte-faithful. `make verify` green. I did NOT run `scripts/differential.sh` — that is an honest gap in my evidence, and your contract requires it.

**One behaviour change** the release notes must carry, deliberately not silent: a NUL byte in the input is now rejected (`error.InvalidSyntax`) instead of truncating the input there. The argument that settles it, found by patient-storm: `Document.source` kept the *truncated* slice and faithful emission writes `source` back, so parse → edit → write on a NUL-carrying file destroyed everything after the NUL **in the file**. `.embedded_nul = .truncate` opts back in. CHANGELOG carries it under its own "Behaviour changes — read this before upgrading" heading, at crisp-dingo's request, alongside the new 64 MiB input bound.

**Still open from D and adjacent, for whoever takes this card:** `scripts/differential.sh` not run by me; merge keys (`<<`) still unresolved and duplicate keys still kept (both deliberate, both documented); no regex constraint in schema (no regex engine in std — documented as a decision, not an omission); emission buffers by design and has no writer sink (faithful emission writes behind its own cursor, so a forward-only writer cannot express it — now documented in README's limitations rather than left to be discovered).
- 2026-09-02T07:59:08Z vast-wren — **v0.13.0 is released.** On direct human instruction, which overrides this card's sequencing. Logged so the card is not left describing a world that no longer exists; I have not moved its lane, approved it, or submitted it.

Release commit `30763d4` (`release: 0.13.0`), tag `v0.13.0` annotated and pushed at that explicit sha, GitHub Release published and marked Latest.

Evidence, in the order it was gathered:
- Detached worktree at the release sha under my scratchpad (not the shared checkout), vendor/ copied in: `make verify` green — conformance 351 pass/0 fail/0 skip/0 stale, roundtrip 265 pass/0 fail/4 skip, preservation zero failures across fixtures/corpus/variants, consumer-smoke byte-faithful. Then `scripts/differential.sh` separately: 269 compared, 0 mismatches. Worktree removed.
- Pushed; CI on `30763d4` green on all six jobs — verify, Consume as a dependency, macos-latest, windows-latest, ubuntu-24.04-arm (tag-version-match correctly skipped, no tag yet).
- Tagged, pushed; CI on the tag green including **tag-version-match: success**, plus the docs workflow, which means the API reference is published for 0.13.0.

**What shipped:** workstream D in full (ParseOptions, EmitOptions, writeAll/writeAllOpts, value/schema surface gaps) and B1 (`docs/design/comments.md`).

**What did NOT ship, and is now 0.14.0 work — the card's remaining scope:**
- **A** — no dogfooding consumer example, no friction report.
- **B2** — comment API unimplemented. The design doc is committed and still needs the human decision this card gates it on. Comments remain preserved but not addressable.
- **C** — no fuzzing beyond the three fixed-seed smoke tests in `src/yaml.zig`; no allocation-failure injection for scanner (63 allocator sites), parser (18) or emitter (17); the three audit suspicions are all still unresolved, including `edit.cloneTree` pointed at a second Document.
- **E** — no SECURITY.md, no examples for value/schema/file, no bench job in CI.

The release notes say all of that explicitly under a "Not in this release" heading rather than letting a reader infer it.

**One thing a re-scoper should know:** E1 (SECURITY.md) was contingent on D landing so the bounds list would be true. D has landed, so E1 is now unblocked and the list it must document is: scanner `max_nesting` 200 and the 1024-character simple-key cap; `value.Limits`/`schema.Limits` at 1 << 20 with `Limits.unlimited`; `Emitter.max_depth` 1000; and `ParseOptions.max_input_bytes` 64 MiB plus `embedded_nul`. Four bounds in three places, all reachable from `ParseOptions`' doc comment, which cross-references the others.

Also closed en route: the **v0.12.0 GitHub Release object**, which never existed — `gh release list` had v0.11.0 as Latest until today because crisp-dingo's token was read-only. Both v0.12.0 and v0.13.0 now have Release objects with notes.
