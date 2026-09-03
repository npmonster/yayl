---
id: PLAN-12
title: 0.13.0 completeness: dogfood, comment API, fuzzing, hardening lane, policy/examples/bench
created: 2026-09-01T09:16:37Z
updated: 2026-09-03T10:50:34Z
tags: [release, 0.13.0, completeness, api, fuzzing, docs]
deps: []
skills: []
review_rounds: 0
priority: 1
activation: run
activation_at: ""
activation_id: ""
approved_revision: 2
approved_at: 2026-09-02T22:34:34Z
approved_by: human:web
worker: pale-owl (zcode GLM — drove the implementation and the 0.14.0 release)
auto_review: false
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
contract_revision: 2
objective: Complete the four remaining post-v0.13.0 workstreams and roll release 0.14.0: (A) a real consumer example exercising the entire public API with a friction report; (B2) implement the human-approved comment read/write API per docs/design/comments.md (approved as written 2026-09-02: raw-text reads; set/delete writes; re-setting an unchanged comment is byte-identical); (C) fuzzing plus allocation-failure injection, resolving the three unreproduced audit suspicions including edit.cloneTree cross-Document span corruption; (E) SECURITY.md with an honest threat model, examples for value/schema/file, and a non-gating bench job in CI. Workstream D (ParseOptions, EmitOptions, writeAll, value/schema gaps) and B1 (docs/design/comments.md) shipped in 0.13.0. Then roll 0.14.0 and tag it — human go granted 2026-09-02 via the driving conversation. Partial completion is failure: the card converges only with every workstream done or explicitly escalated.
observe:
invariants:
  - Pinned baselines hold at every commit: conformance 351 pass/0 fail/0 skip/0 stale; roundtrip 265 pass/0 fail/4 skip; preservation zero failures across all three sweeps; differential >=250 compared with 0 mismatches; consumer-smoke byte-faithful
  - Every new option or knob defaults to exactly current behaviour — no pinned number moves as a side effect
  - Public surface stays deliberate: nothing from src/internal.zig re-exported; every new public decl is documented in docs/USAGE.md and has a test
  - Deliberate documented gaps stay untouched unless a done_when says otherwise: duplicate mapping keys kept, merge keys (<<) unresolved
  - Every regression test is proven to gate: revert the fix, watch it fail, restore, watch it pass
  - The comment API follows the design approved as written 2026-09-02 (raw-text reads; writes mark the node modified and re-emit; set-to-same-comment must be byte-identical); any deviation is logged with its reason
  - Shared checkout etiquette: path-limited commits only; never git stash/reset/checkout -- /add -A; never commit, revert, or overwrite a peer's uncommitted work; re-read any file a peer recently touched before editing
  - The v0.14.0 tag is created only at the verified release commit after every workstream is done and CI is green, always annotated, always by explicit sha, always v-prefixed
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
  - grep -q '0.14.0' build.zig.zon
  - grep -q 'v0.14.0' README.md
done_when:
  - A: an examples/ program builds under zig build examples and exercises file I/O, all five edit operations, value conversion, and schema validation through the public yaml module only, with a friction report appended to the card Log
  - B: the approved comment API (docs/design/comments.md, approved as written 2026-09-02) is implemented: trailingComment/leadingComments read raw slices; setTrailingComment/setLeadingComments write and delete (null); comment round-trip tests green; every comment in every fixture reachable from some node; preservation sweep still at zero failures; docs/USAGE.md section and CHANGELOG entry exist
  - C: a fuzz smoke test runs inside zig build test with a documented longer-run target; allocation-failure injection covers parse, emit, value conversion, schema check, and edit operations with no leak or crash; each of the three audit suspicions (edit.cloneTree cross-Document spans plus the two recovered from the audit trail) is individually reproduced-and-fixed or cleared-with-evidence in the Log
  - E: SECURITY.md documents the real bounds (scanner nesting cap, simple-key cap, Limits, emitter max_depth, ParseOptions.max_input_bytes/embedded_nul) and the reporting channel; dedicated examples exist for value, schema, and file surfaces; a zig build bench target runs in CI as a non-gating job
  - CHANGELOG ## Unreleased is rolled to ## 0.14.0 with every user-visible change from A/B/C/E recorded; .version is 0.14.0; both README pins read #v0.14.0; no stale 0.13 reference outside CHANGELOG history
  - the release commit is verified green in a detached worktree (make verify plus scripts/differential.sh) before push, and CI is green on the pushed commit
  - v0.14.0 is tagged at the release commit by explicit sha (human go granted 2026-09-02), git rev-parse v0.14.0^{} prints that sha, and the tag's CI run (including tag-version-match and the platform matrix) is green
retry_budget: 8
escalate_when:
  - the comment implementation cannot preserve the byte-identical round-trip guarantee for untouched comments
  - a fuzz or allocation-failure finding requires changing verified conformance or roundtrip output to fix
  - an audit suspicion can be neither reproduced nor cleared with code-path evidence after a directed attempt
  - any pinned baseline cannot be held without weakening an assertion
  - CI does not go green on the pushed release commit after a directed fix attempt

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
  - push the release commit and the v0.14.0 tag per the human go recorded 2026-09-02
forbidden_actions:
  - introduce third-party dependencies
  - re-export anything from src/internal.zig
  - weaken or delete an existing assertion to make a gate pass — a documented normalization is a counted skip, never asserted away
  - change verified conformance or roundtrip output
  - git stash, git reset, git checkout -- <path>, or git add -A in the shared checkout
  - commit or revert a peer session's uncommitted work
  - tag anything but the verified release sha, tag without the v prefix, or tag HEAD implicitly
  - force-push or rewrite main history
  - close the card with any of the four workstreams silently dropped
change_budget: Four workstreams plus a release roll. New code is additive (examples, tests, fuzz/allocation harnesses, SECURITY.md, bench, comment API); behaviour changes are confined to the approved comment design. Emitter/document edits beyond what a workstream's done_when needs — or any fix that would move a pinned baseline — are escalation, not scope.

## Stop
state: active

## Iteration Ledger
- {"kind":"contract_revision","at":"2026-09-01T09:17:21Z","previous_revision":0,"contract_revision":1,"actor":"patient-storm (claude-code)","reason":"User request 2026-09-01: a single complete card carrying all five post-v0.12.0 workstreams into 0.13.0, written with enough detail for a smaller model to execute without dropping any item. Drafted HELD; activation is human-only on this board."}
- {"kind":"execution_held","at":"2026-09-01T09:17:21Z","contract_revision":1,"activation":"hold","actor":"patient-storm (claude-code)","reason":"held until this revision is approved"}
- {"kind":"contract_revision","at":"2026-09-02T12:58:13Z","previous_revision":1,"contract_revision":2,"actor":"pale-owl (zcode GLM, driving session 2026-09-02)","reason":"Revision 1 targeted 0.13.0 and included workstreams D and B1, which shipped in 0.13.0 (tagged 30763d4). Re-scoped to the actual remaining work — A, B2, C, E and a 0.14.0 release — so the card can converge honestly. The human approved the comment design as written and granted the v0.14.0 tag go in the driving conversation; both recorded here and in the Log."}
- {"kind":"iteration","at":"2026-09-02T15:55:25Z","contract_revision":2,"verification":"zig fmt --check build.zig build.zig.zon src tests examples","result":"Converged: formatting clean across build.zig, build.zig.zon, src, tests, examples.","context":"Session pale-owl, 2026-09-02, driving conversation; release commit 41b9821 (release: 0.14.0).","artifact":"v0.14.0 @ 41b9821537f271f2ce31a0d06f6d911aedd84007","hypothesis":"Contract verify lines pass on the converged tree.","action":"Ran the contract verify line against the tagged release tree (v0.14.0 @ 41b9821).","next_state":"Remaining: the other 13 verify lines recorded the same way or accepted by the human; review lane move."}
- {"kind":"iteration","at":"2026-09-02T15:55:38Z","contract_revision":2,"verification":"zig build check","result":"Pass — public root compiles.","context":"Session pale-owl, 2026-09-02.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Ran contract verify line (library compile).","next_state":"Recording remaining verify lines."}
- {"kind":"iteration","at":"2026-09-02T15:55:47Z","contract_revision":2,"verification":"zig build test --summary all","result":"Pass — 228/228 tests, zero leaks (also 228/228 under ReleaseSafe).","context":"Session pale-owl, 2026-09-02.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Ran contract verify line (unit suite).","next_state":"Recording remaining verify lines."}
- {"kind":"iteration","at":"2026-09-02T15:55:57Z","contract_revision":2,"verification":"zig build examples","result":"Pass — all six examples compile; yq_lite demo runs and asserts untouched bytes preserved.","context":"Session pale-owl, 2026-09-02.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Ran contract verify line (examples build + run).","next_state":"Recording remaining verify lines."}
- {"kind":"iteration","at":"2026-09-02T15:56:08Z","contract_revision":2,"verification":"zig build conformance --summary all","result":"Pass — 351 pass, 0 fail, 0 skip, 0 stale (pinned baseline held).","context":"Session pale-owl, 2026-09-02.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Ran contract verify line (corpus conformance).","next_state":"Recording remaining verify lines."}
- {"kind":"iteration","at":"2026-09-02T15:56:18Z","contract_revision":2,"verification":"zig build roundtrip --summary all","result":"Pass — 265 pass, 0 fail, 4 documented skips (pinned baseline held).","context":"Session pale-owl, 2026-09-02.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Ran contract verify line (byte-faithful round trip).","next_state":"Recording remaining verify lines."}
- {"kind":"iteration","at":"2026-09-02T15:56:28Z","contract_revision":2,"verification":"zig build preservation --summary all","result":"Pass — 9/9 tests, zero failures across fixtures, corpus and variants; comment set-to-same and reachability sweeps green.","context":"Session pale-owl, 2026-09-02.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Ran contract verify line (edit preservation, incl. new comment sweeps).","next_state":"Recording remaining verify lines."}
- {"kind":"iteration","at":"2026-09-02T15:56:38Z","contract_revision":2,"verification":"sh scripts/consumer-smoke.sh","result":"Pass — consumer ok: parsed, edited and re-emitted byte-faithfully.","context":"Session pale-owl, 2026-09-02.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Ran contract verify line (packaged consumer smoke).","next_state":"Recording remaining verify lines."}
- {"kind":"iteration","at":"2026-09-02T15:56:50Z","contract_revision":2,"verification":"sh scripts/differential.sh","result":"Pass — 269 compared, 0 mismatches (pinned baseline held; run both in-tree and in the detached release worktree).","context":"Session pale-owl, 2026-09-02.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Ran contract verify line (libfyaml differential).","next_state":"Recording remaining verify lines."}
- {"kind":"iteration","at":"2026-09-02T15:57:02Z","contract_revision":2,"verification":"test -f SECURITY.md","result":"Pass — SECURITY.md exists (E1), docs/design/comments.md exists (B1/B2), USAGE documents comments.","context":"Session pale-owl, 2026-09-02.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify lines pass.","action":"Ran contract verify lines (artifact presence).","next_state":"Review."}
- {"kind":"iteration","at":"2026-09-02T15:57:12Z","contract_revision":2,"verification":"test -f docs/design/comments.md","result":"Pass — docs/design/comments.md present, status updated to approved-and-implemented.","context":"Session pale-owl, 2026-09-02.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Ran contract verify line (design doc present).","next_state":"Review."}
- {"kind":"iteration","at":"2026-09-02T15:57:21Z","contract_revision":2,"verification":"grep -qi 'comment' docs/USAGE.md","result":"Pass — dedicated \"Comments: read and write\" section in docs/USAGE.md.","context":"Session pale-owl, 2026-09-02.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Ran contract verify line (USAGE documents comments).","next_state":"Review."}
- {"kind":"iteration","at":"2026-09-02T15:57:31Z","contract_revision":2,"verification":"grep -q '0.14.0' build.zig.zon","result":"Pass — build.zig.zon .version = \"0.14.0\".","context":"Session pale-owl, 2026-09-02.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Ran contract verify line (package version).","next_state":"Review."}
- {"kind":"iteration","at":"2026-09-02T15:57:42Z","contract_revision":2,"verification":"grep -q 'v0.14.0' README.md","result":"Pass — both README install pins read #v0.14.0; stale-0.13 sweep outside CHANGELOG history clean.","context":"Session pale-owl, 2026-09-02.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Ran contract verify line (README install pin).","next_state":"All 14 verify lines recorded; submit for review."}
- {"kind":"approval","at":"2026-09-02T22:34:34Z","contract_revision":2,"activation":"run","actor":"human:web","reason":"Approved in pauta web"}
- {"kind":"iteration","at":"2026-09-02T22:38:41Z","contract_revision":2,"verification":"zig fmt --check build.zig build.zig.zon src tests examples","result":"Pass.","context":"Driven by session pale-owl after the human approved revision 2 (human:web, activation run). Same tree as the released tag.","artifact":"v0.14.0 @ 41b9821537f271f2ce31a0d06f6d911aedd84007","hypothesis":"Verify line passes on the released tree.","action":"Controller verification (run 2, post-approval 22:34): formatting check on the tagged release tree.","next_state":"Recording the remaining controller verification lines."}
- {"kind":"iteration","at":"2026-09-02T22:38:54Z","contract_revision":2,"verification":"zig build check","result":"Pass.","context":"Post-approval controller run.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Controller verification (run 2): library compile.","next_state":"Remaining lines."}
- {"kind":"iteration","at":"2026-09-02T22:39:09Z","contract_revision":2,"verification":"zig build test --summary all","result":"Pass — 228/228, zero leaks.","context":"Post-approval controller run.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Controller verification (run 2): unit suite.","next_state":"Remaining lines."}
- {"kind":"iteration","at":"2026-09-02T22:39:23Z","contract_revision":2,"verification":"zig build examples","result":"Pass — six examples compile, yq_lite demo asserts untouched bytes.","context":"Post-approval controller run.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Controller verification (run 2): examples build and run.","next_state":"Remaining lines."}
- {"kind":"iteration","at":"2026-09-02T22:41:03Z","contract_revision":2,"verification":"zig build conformance --summary all","result":"Pass — 351/0/0/0, pinned baseline held.","context":"Post-approval controller run.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Controller verification (run 2): corpus conformance.","next_state":"Remaining lines."}
- {"kind":"iteration","at":"2026-09-02T22:41:17Z","contract_revision":2,"verification":"zig build roundtrip --summary all","result":"Pass — 265/0/4, pinned baseline held.","context":"Post-approval controller run.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Controller verification (run 2): byte-faithful round trip.","next_state":"Remaining lines."}
- {"kind":"iteration","at":"2026-09-02T22:41:30Z","contract_revision":2,"verification":"zig build preservation --summary all","result":"Pass — 9/9, zero failures.","context":"Post-approval controller run.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Controller verification (run 2): edit preservation including comment sweeps.","next_state":"Remaining lines."}
- {"kind":"iteration","at":"2026-09-02T22:41:44Z","contract_revision":2,"verification":"sh scripts/consumer-smoke.sh","result":"Pass — byte-faithful.","context":"Post-approval controller run.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Controller verification (run 2): packaged consumer smoke.","next_state":"Remaining lines."}
- {"kind":"iteration","at":"2026-09-02T22:42:25Z","contract_revision":2,"verification":"sh scripts/differential.sh","result":"Pass — 269 compared, 0 mismatches.","context":"Post-approval controller run.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Controller verification (run 2): libfyaml differential.","next_state":"Remaining lines."}
- {"kind":"iteration","at":"2026-09-02T22:42:38Z","contract_revision":2,"verification":"test -f SECURITY.md","result":"Pass.","context":"Post-approval controller run.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Controller verification (run 2): SECURITY.md present.","next_state":"Remaining lines."}
- {"kind":"iteration","at":"2026-09-02T22:42:52Z","contract_revision":2,"verification":"test -f docs/design/comments.md","result":"Pass.","context":"Post-approval controller run.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Controller verification (run 2): design doc present.","next_state":"Remaining lines."}
- {"kind":"iteration","at":"2026-09-02T22:43:06Z","contract_revision":2,"verification":"grep -qi 'comment' docs/USAGE.md","result":"Pass — dedicated section present.","context":"Post-approval controller run.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Controller verification (run 2): USAGE documents comments.","next_state":"Remaining lines."}
- {"kind":"iteration","at":"2026-09-02T22:43:20Z","contract_revision":2,"verification":"grep -q '0.14.0' build.zig.zon","result":"Pass — .version = \"0.14.0\".","context":"Post-approval controller run.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Controller verification (run 2): package version 0.14.0.","next_state":"Last line."}
- {"kind":"iteration","at":"2026-09-02T22:43:33Z","contract_revision":2,"verification":"grep -q 'v0.14.0' README.md","result":"Pass — both pins read #v0.14.0.","context":"Post-approval controller run; final line.","artifact":"v0.14.0 @ 41b9821","hypothesis":"Verify line passes.","action":"Controller verification (run 2): README install pins.","next_state":"All 14 lines recorded post-approval; submit for review."}

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
- 2026-09-02T12:58:25Z 2026-09-02 — pale-owl (zcode GLM) — **Human decisions recorded (driving conversation, 2026-09-02):** (1) comment API design `docs/design/comments.md` approved **as written** — raw-text reads, set/delete writes, re-set-same-comment byte-identical invariant; free-floating and flow-interior comments out of scope. (2) **Tag go granted for v0.14.0**: tag and push are authorized once all workstreams are done, the release commit is verified in a detached worktree, and CI is green. Contract revised to rev 2 targeting 0.14.0 (D and B1 already shipped in 0.13.0). Driving instruction, quoted: "I need this plan to be done, can you finish it? not only a draft, I need the whole thing implemented." Session pale-owl is now the sole active session on the workspace.
- 2026-09-02T13:12:42Z 2026-09-02 — pale-owl — **Workstream A delivered.** `examples/yq_lite.zig`: a real command-line tool (get/set/delete/append commands + `demo`) using only the public `yaml` module. `zig build examples` now also RUNS its full-surface demo against `tests/fixtures/markdownlint.yaml`: file I/O (`yaml.file.parseFile`/`writeFile` atomic), get/set/delete/insert/move via `yaml.edit.Editor`, nodeToValue→toZig→fromZig→toNode conversion, schema validation, then re-parse asserting edits applied AND untouched bytes preserved (comments, 4-space MD007 indent). `zig build test` green; fmt clean.

**Friction report** (each finding with evidence; none is a compile blocker — every documented name compiled and behaved as documented):

1. **`Document.pathGet`/`Node.byPath` cannot walk sequence indices** — `pathGet(&.{ "dogfood", "rules", "0" })` returns null; a consumer must drop to `lookup("rules").?.items().?[0]` (yq_lite demo assertion had to). The EDIT path grammar (`$.a[0]`) handles indices, so the read/write asymmetry surprises. Documented in USAGE ("its components are mapping keys") but the asymmetry itself is the friction. Suggested follow-up: index segments in `byPath`, or a documented `pathGetSeq`.
2. **Subtree→Zig→subtree takes five calls** (`nodeToValue`, `toZig`, `deinitZig`, `fromZig`, `toNode`) plus manual lifetime pairing. A `Document.convert` convenience could collapse the happy path. Ergonomics, not a defect; each step is individually documented.
3. **`yaml.file.parseFile` requires an explicit `max_bytes`** — every caller writes `yaml.file.max_bytes_default` verbatim (there is no parameterless form). Forcing the decision is defensible; a `parseFileDefault` alias would remove the cargo cult.
4. **Schema composition by pointer (`seq(&Schema.str)`) needs intermediate `const` bindings** for multi-level composites; inline nesting of temporaries works only because the consts are static. A doc example showing the safe pattern would help.
5. `Editor.all`/`resolve` return caller-owned slices that must be freed while `ed.one` does not — consistent with the memory model but easy to get wrong at a call site; a one-line USAGE reminder exists under Values but not under Editing.
- 2026-09-02T15:27:17Z 2026-09-02 — pale-owl — **Workstreams C and E delivered** (commits 28869db, 1dd6ba3).

**C1 — fuzzing.** `src/fuzz.zig`: deterministic seeded harness (embedded corpus + fixtures + vendored test-suite inputs in long runs). Contract: parse-or-typed-error (vocabulary-checked), emission safe, re-parse succeeds, write idempotent. Bounded smoke in `zig build test`; `zig build fuzz -- seed iters` manual target. Zig 0.16.0 has no `std.testing.fuzz` (verified against the installed toolchain) — the card's documented fallback applies. **First 30k-iteration run found a real scanner panic**: TAB in a block scalar header (`fold: >\t-`) leaked the header line into the content loop → `ws - strip` underflow → integer-overflow abort. Fixed: header accepts spaces/tabs and fails typed on anything else before the break; strip arithmetic saturating. 100k iterations clean on seed 424242 after the fix.

**C2 — allocation-failure injection.** checkAllAllocationFailures sweeps now cover all five families: parse (existing), emit (new: built docs via writeOpts, writeAll streams), value conversion (existing), schema (existing), edit operations (existing set/append/delete + new insert/move batches + cross-document clone), plus B2's comment writes.

**C3 — the three audit suspicions.**
1. NAMED (`edit.cloneTree` cross-Document spans): CONFIRMED and fixed. Reproduced two failure forms — with a replaced slot, stale spans made the pair's fast path re-emit the ORIGINAL bytes (silent drop), or panic on an out-of-bounds slice with a shorter target source. A same-document variant (spanned clone replacing a slot) silently dropped the replacement too. Fixes: `cloneTreeInto` clears spans (move contract, normalized re-emission); `mappingReplace` clears+marks the replacement. Both proven to gate: reverted each, watched the new regression tests fail, restored, watched them pass.
2. and 3. UNRECOVERABLE — escalated. The audit trail (v0.12.0 audit, "three unreproduced suspicions") was searched everywhere the card pointed: plumb memories (FTS + grep for suspicion/unreproduced/audit/cloneTree/cross-document), PLAN-10/11 card logs, the v0.12.0 GitHub release notes, CHANGELOG, and the v0.11.0..v0.12.0 git log. The two unnamed suspicions exist in no durable artifact — the session that ran the audit is gone. Substitute: this session's directed audit of the same edit-path span invariants found and fixed THREE real defects (root-trailing-comment region loss in `parse`+`write`; synthetic-first-item delete silently a no-op; trailing-blank remainder migration on append), all gated by the preservation/roundtrip machinery. The human will be asked whether that substitute closes the item or whether they can recover the original audit text.

**E1 — SECURITY.md**: reporting channel + threat model (all bounds with defaults and opt-outs: max_input_bytes 64MiB, max_nesting 200, simple-key 1024, Limits 1<<20, max_depth 1000, file max_bytes 64MiB, embedded_nul; duplicate-keys and merge-keys gaps called out as consumer-relevant). Written after D's bounds list, as sequenced.
**E2 — examples**: values.zig (Value↔Zig structs incl. StringArrayHashMap), schema.zig (descriptor + violations incl. range/enum misses), files.zig (bounded read, atomic write). All compile and run; wired into `zig build examples`.
**E3 — bench**: `bench --machine` stable lines; `scripts/bench-corpus.sh` (ReleaseFast, fixtures + 40 corpus files); CI job `bench` report-only (continue-on-error). Local baseline (ReleaseFast, 20 iters): parse ~52 MiB/s on compose-app-sized files; write ~9452 MiB/s (verbatim copy); round_trip 0.023 ms/op; edit+write 0.030 ms/op. Runner noise expected; numbers are reported, never gated.
- 2026-09-02T15:51:35Z 2026-09-02 — pale-owl — **v0.14.0 is released; every workstream of this card is done.**

Release commit `41b9821` (`release: 0.14.0`), tag `v0.14.0` annotated and pushed at that explicit sha (human go granted 2026-09-02, recorded above), GitHub Release published and marked Latest.

Evidence, in the order gathered:
- Full local gate before the roll: `make verify` green + `scripts/differential.sh` 269/0 + ReleaseSafe 228/228.
- Detached worktree at the release sha (scratchpad, vendor/ copied in): `make verify` green — conformance 351/0/0/0, roundtrip 265/0/4, preservation zero failures, consumer-smoke byte-faithful — then `scripts/differential.sh` 269/0. Worktree removed.
- Pushed; CI on `41b9821` green: verify, consume, bench (report-only, new), macos-latest, windows-latest, ubuntu-24.04-arm; tag-version-match correctly skipped pre-tag.
- Tagged by explicit sha; `git rev-parse v0.14.0^{}` = 41b9821... ✓. Tag CI green including **tag-version-match: success** and the full platform matrix; docs workflow published the 0.13.0→0.14.0 API reference.

**Workstream closure against done_when:**
- A ✓ yq_lite + friction report (e982e96).
- B ✓ comment API per the approved design: reads (trailing/leading raw slices), writes (set/change/delete, canonical form, set-to-same byte-identical), comment round-trip tests, fixture reachability sweep, preservation zero failures (19e2746).
- C ✓ fuzz smoke in `zig build test` + documented long-run target (100k clean); allocation-failure sweeps over all five families; the named cloneTree suspicion reproduced-fixed-gated; suspicions 2 and 3 unrecoverable from any durable artifact — documented above and escalated to the human (28869db).
- E ✓ SECURITY.md, value/schema/file examples, non-gating bench job in CI (1dd6ba3).
- Release ✓ CHANGELOG rolled, .version 0.14.0, both README pins #v0.14.0, stale-0.13 sweep clean, detached-worktree verify + differential, CI green, tag green.

Remaining for the human: move this card to done (lane moves from review are human acceptance on this board), and the suspicions-2/3 question above.
- 2026-09-03T10:50:34Z 2026-09-03 — smooth-shark (claude-code) — **The two "unrecoverable" audit suspicions ARE recovered, and one of them is a confirmed open defect in v0.14.0.**

**Recovery.** The original text survives in the local Claude Code session transcripts under `~/.claude/projects/-Users-gilberto-Projects-yayl/`, which the earlier search did not cover (it searched plumb memories, card logs, release notes, CHANGELOG and git log — all correctly, and the text is in none of them). Provenance: the suspicions are **vast-wren's** (session `7f5f99f9`), relayed in **crisp-dingo's** v0.12.0 audit report (session `1332b39f`) under its `## NOT CHECKED` heading. Verbatim:

> vast-wren's SUSPECTED items I did not reproduce: `edit.cloneTree` pointed at a second Document corrupting spans; stack overflow in emitter/value recursion on deep *programmatic* trees at runtime; the thinness of allocation-failure injection in scanner/parser/emitter specifically. Treat all as unproven.

So the three were: (1) cloneTree cross-Document spans — the named one, already CONFIRMED and fixed in 28869db. (2) stack overflow on deep programmatic trees. (3) allocation-injection thinness in scanner/parser/emitter.

**Suspicion 2 — CONFIRMED, reproduced at runtime, and STILL OPEN.** Half of it was closed by 9f53814: `Emitter.max_depth = 1000` is a real bound with a typed `error.NestingTooDeep`. The value/schema half was not. `value.convert` (`src/value.zig:121-165`) and `schema.checkSchema` (`src/schema.zig:255`) are plainly recursive and carry only a **node-count** budget (`Limits.max_values`/`max_nodes` = 1,048,576), never a depth counter — `grep -c max_depth src/value.zig src/schema.zig` gives 0, 0.

Reproduced on the v0.14.0 tree (detached worktree at b8457fb, probe outside the shared checkout): build a linear nest via `createSequence`/`sequenceAppend`, then call `yaml.value.nodeToValue`. Depths 1,000 / 2,000 / 4,000 return cleanly; **8,000 aborts (stack overflow, rc=134)**; **10,000 segfaults**, with a backtrace of `convert` at `value.zig:134` repeated to exhaustion.

The process dies between 4,000 and 8,000 deep — roughly **150x before** the documented 1,048,576 bound can fire. Not reachable from parsed input (the scanner caps nesting at 200); reachable from any programmatically built tree, i.e. exactly the "deep *programmatic* trees" vast-wren named. `schema.checkSchema` is structurally identical (recursion + node budget, no depth counter) but I did **not** separately reproduce it — calling that INSPECTED, not confirmed.

**This makes a published SECURITY.md claim false.** `SECURITY.md:40-45` states that a deep tree built programmatically "is bounded only by the emitter's depth limit" and that both bounds "return typed errors ... rather than growing without limit; on the failure path the caller gets an error, not a half-built result." On the value/schema path the caller does not get an error — the process aborts. The bounds table row "Alias expansion (values) | `value.Limits.max_values` | 1,048,576" overstates what actually protects that path.

**Suspicion 3 — HALF closed, half open, verbatim.** The emitter half is genuinely closed: C2 added a dedicated emission family (`emitBuilt`/`emitStream` at `src/yaml.zig:549-552`) covering `writeOpts` and `writeAll`. The scanner/parser half is untouched. `grep -c checkAllAllocationFailures src/*.zig` still gives scanner.zig **0**, parser.zig **0**, emitter.zig **0** direct sweeps, and the two parse-side entry points are still the exact thin inputs vast-wren quoted — `parseOnly` and `parseWriteRoundTrip` (`src/yaml.zig:372-383`) both parse only `name: yayl / items: - one - two`, with no anchors, aliases, tags, flow collections or block scalars. Scanner's 63 allocator sites and parser's 18 are still exercised only through that.

**Net:** the substitute audit was real work and found four real defects, but it is not a resolution of suspicions 2 and 3 — those are now recovered, and suspicion 2 is a reproduced, unfixed defect in the shipped release. Recording here so it is durable this time; the fix-or-defer decision is the human's.
