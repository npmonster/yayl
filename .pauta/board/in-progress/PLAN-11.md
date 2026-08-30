---
id: PLAN-11
title: Edit-path coverage: sweep the operations and documents the gate cannot see
created: 2026-08-30T11:36:55Z
updated: 2026-08-30T12:02:37Z
tags: [testing, emitter, edit-path]
deps: []
skills: []
review_rounds: 0
priority: 1
activation: hold
activation_at: ""
activation_id: ""
---

## Plan

# Edit-path coverage — widen what the preservation sweep looks at

## Context

`make preservation` (added 9095205, wired into verify + CI at 34c5bbf) is the
only gate that exercises the edit path: the round-trip gate never edits, and
conformance and the differential harness compare parse/event behaviour, not
edit output. It found nine real defects that every other gate was green
through, all predating v0.9.0 — including one that emitted output which
**re-parsed cleanly** while a sequence-of-mappings had silently become a
mapping.

The gate is now green, but it is narrow: 14 hand-picked fixtures, three of the
five public `Edit` operations. This card widens what it looks at. The premise
is that the remaining defects are in the shapes the sweep has never visited,
not in the assertions it makes.

Full write-up with evidence:
https://claude.ai/code/artifact/c64ae5b9-54fb-4903-b19c-966de9a9ea9c

## Evidence (2026-08-30)

- **Two of five edit operations are unswept.** The sweep counts deletes, sets,
  map adds, seq appends and rollbacks. `Edit.move` and `Edit.insert` are swept
  at no position. `applyMove` detaches through `dropPairSpan`/`dropItemSpan` —
  the exact functions that carried four of the nine defects. A peer
  independently rediscovered the indent-doubling bug *through `move`* while it
  was being found through `delete`: same broken span arithmetic, different
  entry point.
- **The corpus is never edited.** `vendor/yaml-test-suite` holds 269 valid
  documents that `tests/roundtrip.zig` already parses and emits. They cover
  explicit keys (`? key`), every block-scalar chomping and indentation
  indicator, tag directives, deep flow nesting and CRLF — shapes the 14
  real-world fixtures barely touch and the edit path has never seen.
- **A no-op edit changes the file at 12% of positions.** Probe: set every
  scalar to the value it already holds, where the expected output *is* the
  input. 17 of 140 positions across six fixtures rewrote the file. Triaged:
  `$.on.push.branches[0]` reformats a flow collection (`[ x ]` -> `[x]`,
  author's spacing lost) and `$.jobs.build.steps[1].run` loses two columns of
  literal-block indent — both byte-faithfulness breaks. `$.description`
  (folded scalar collapsing to one line) needs triage against the documented
  fallback in `docs/USAGE.md`. `$.volumes.db-data` (`db-data:` -> `db-data: ""`)
  is a probe artifact: `scalarValue()` returns `""` for a null node, so the
  probe conflated null with empty string — an API sharp edge, not an emitter
  defect.
- **Every sweep applies exactly one edit.** The tombstone layer is stateful: a
  container accumulates `dropped` ranges and a second edit sees a tree the
  first already changed. Several of the nine were *ordering* bugs (span
  recorded before vs after detach; a successor re-emitting framing its
  predecessor consumed), which is the class that compounds under batching.
- **No fixture uses CRLF, a BOM, or a missing final newline**, though
  `markup.lineEnd` documents `\r\n` handling and the scanner offsets a BOM by
  three bytes.
- **25 positions are unaddressable** because a key contains a dot
  (`.defaults`, `pymdownx.highlight`); the path grammar has no quoting form.
  Counted honestly rather than hidden, but they are real coverage gaps.

## Work plan

Ordered by expected defects per hour. Items 1-2 are the bulk of the value.

### Phase A — Operations the sweep has never run
1. `insert` sweep: pure line insertion at every addressable sequence position,
   as the append sweep already asserts. **Unclaimed.**
2. `move` sweep: for every ordered pair of addressable containers, move each
   child across; assert re-parse, value tree equals input-minus-source-plus-
   destination, and every line outside both containers byte-identical.
   **Coordinate first — a move sweep was reported in flight by a peer.**

### Phase B — Documents the sweep has never seen
3. Run the sweep over the vendored corpus as a separate step from the fixture
   sweep, so a corpus regression stays legible. Expect the *skip* counters to
   jump rather than the sweep counters; verify skips land in the right
   categories rather than swallowing real positions.
4. Derive CRLF, BOM-prefixed and no-final-newline variants of each fixture
   in memory (no new committed fixtures). If BOM sweeps fail, suspect the
   scanner's `mark.offset`/`pos` divergence, not the emitter.

### Phase C — Invariants and defects
5. Fix the two confirmed byte-faithfulness breaks (flow-collection spacing,
   literal-block indent), each with a regression test proven to fail without
   the fix. Triage the folded-scalar case against the USAGE claim first.
6. Make set-to-same-value a permanent sweep assertion, not a one-off probe.
7. Multi-edit composition: delete two sibling entries in both orders, assert
   identical and semantically correct. Then a seeded-RNG version that prints
   the seed on failure.

### Phase D — Decisions, not code
8. Dotted keys: either add a quoting form to the path grammar
   (`$["pymdownx.highlight"]`) and sweep those positions, or document the
   limitation in the USAGE grammar table. Leaving it undecided is the one
   option to avoid — dotted keys are common in real config.

## Constraints

- `tests/preservation.zig` has an owner; coordinate before editing it.
- Keep the sweep fast. It runs in ~50s because it uses a `DebugAllocator` with
  `stack_trace_frames = 0`; `std.testing.allocator`'s per-allocation stack
  traces cost ~30x across ~2500 parse/emit cycles and make it CI-hostile.
- Assert semantically, not just syntactically. Value-tree comparison already
  runs on the 376 exempt positions; any new sweep should assert the same way.
  Re-parse alone cannot see the worst defect class.
- One shared checkout, several agents: path-limited commits, never `git stash`.

## Loop
contract_version: 1
contract_revision: 1
objective: Widen the edit-preservation sweep to the operations and documents it has never visited, and fix what that exposes. Cover Edit.insert and Edit.move (2 of 5 public edit operations are swept at no position), sweep the 269 vendored corpus documents in addition to the 14 real-world fixtures, add CRLF/BOM/no-final-newline variants, make set-to-same-value a permanent assertion, and fix the two confirmed byte-faithfulness breaks it already found (flow-collection spacing, literal-block indent).
observe:
  - make preservation is green and finishes in roughly 50 seconds before any change
  - tests/preservation.zig currently reports counters for deletes, sets, map adds, seq appends and rollbacks only — no moves, no inserts
  - a peer may already have a move sweep in flight; coordinate before writing one
invariants:
  - Assert semantically, not just syntactically: value-tree comparison already runs on the 376 exempt positions and any new sweep asserts the same way — re-parse alone cannot see a structure that changed but still parses
  - The sweep stays fast enough for CI: keep the DebugAllocator with stack_trace_frames = 0; std.testing.allocator's per-allocation stack traces cost ~30x across the sweep's parse/emit cycles
  - Positions exempt from line-shape assertions are counted, never silently skipped; referenced-anchor is the one category that cannot assert re-parse, because a dangling alias is the expected outcome
  - Every regression test is proven to gate: revert the fix, watch the test fail, restore
  - Shared checkout: path-limited commits only, never git stash
  - No behaviour change to verified parser output — conformance stays 351/351 and roundtrip stays 265 pass / 4 skip
verify:
  - zig fmt --check build.zig src tests
  - zig build check
  - zig build test --summary all
  - zig build preservation
  - zig build roundtrip
  - zig build conformance
  - grep -q 'stats.inserts' tests/preservation.zig
  - grep -q 'stats.moves' tests/preservation.zig
  - grep -q 'stack_trace_frames' tests/preservation.zig
done_when:
  - tests/preservation.zig reports non-zero insert and move counts in its summary line with zero failures
  - the sweep runs over the vendored yaml-test-suite corpus as a step separate from the fixture sweep, with its own counts, and skip counters are verified to land in the right categories rather than swallowing real positions
  - CRLF, BOM-prefixed and no-final-newline variants of each fixture are swept, derived in memory with no new committed fixtures
  - set-to-same-value is a permanent sweep assertion: setting a scalar to the value it already holds is byte-identical at every swept position
  - the flow-collection spacing break is fixed (branches: [ x ] no longer reformats to [x]) with a regression test proven to fail without the fix
  - the literal-block indent break is fixed (a block scalar keeps its original indentation when its pair is edited) with a regression test proven to fail without the fix
  - the folded-scalar case is triaged against the claim in docs/USAGE.md and either fixed or documented as a legitimate normalization — not left ambiguous
  - multi-edit composition is covered: two sibling deletes in either order produce identical, semantically correct output
  - the dotted-key path limitation is decided — either a quoting form is added to the grammar and those positions are swept, or the limitation is documented in the USAGE path-grammar table
  - make preservation still finishes in under two minutes
  - conformance still reports 351/351 and roundtrip 265 pass / 4 skip
  - CHANGELOG Unreleased records any user-visible fix
retry_budget: 5
escalate_when:
  - a corpus sweep failure cannot be distinguished from a legitimate normalization without changing what the gate asserts
  - fixing the flow or block-scalar break would change verified conformance or roundtrip output
  - the sweep cannot be kept under two minutes once the corpus is included
  - a peer holds tests/preservation.zig and the coordination is unresolved

## Authority
allowed_paths:
  - tests/**
  - src/emitter.zig
  - src/document.zig
  - src/edit.zig
  - docs/USAGE.md
  - CHANGELOG.md
  - build.zig
  - Makefile
allowed_external_actions:
  - run scripts/fetch-corpus.sh to vendor the pinned yaml-test-suite corpus if it is absent
forbidden_actions:
  - introduce third-party dependencies
  - swap the sweep allocator back to std.testing.allocator
  - weaken an assertion to make a position pass — a documented normalization is counted as a skip, never asserted away
  - change verified conformance or roundtrip output
  - commit with git add -A in the shared checkout
  - force-push or rewrite main history
change_budget: Additive test coverage plus targeted emitter fixes for the two confirmed byte-faithfulness breaks. No behaviour change to parse output. Emitter changes are confined to the normalized re-emission path for flow collections and block scalars; if a fix reaches further than that, escalate rather than widening the diff.

## Stop
state: active

## Iteration Ledger
- {"kind":"contract_revision","at":"2026-08-30T11:37:30Z","previous_revision":0,"contract_revision":1,"actor":"idle-glacier (claude-code)","reason":"Handover from the edit-preservation session. The gate added in 9095205 found nine defects every other gate was green through, then went green itself — but it only sweeps 14 fixtures and three of five public edit operations. This contract widens what it looks at. Drafted HELD; activation is human-only on this board."}
- {"kind":"execution_held","at":"2026-08-30T11:37:30Z","contract_revision":1,"activation":"hold","actor":"idle-glacier (claude-code)","reason":"held until this revision is approved"}
- {"kind":"iteration","at":"2026-08-30T11:50:28Z","contract_revision":1,"verification":"zig build preservation","result":"FAILED after 1m50.77s: 1952 move cases; hundreds of failures. Major classes are invalid YAML when moving into mapping containers that are sequence items, subtree value changes, and leaf-count loss. Runtime is already close to the 2-minute ceiling before corpus and variants.","context":"PLAN-11 change budget authorizes additive coverage plus the two narrow flow-spacing/literal-indent fixes; these move failures require broader editor/emitter work and overlap live peer WIP.","artifact":"tests/preservation.zig move sweep and src/edit.zig ancestor markModified fix (uncommitted peer WIP)","hypothesis":"The in-flight move sweep is a bounded addition that remains green and leaves enough runtime headroom for corpus and fixture variants.","action":"Ran the preservation gate against the current shared-checkout WIP without editing the peer-owned sweep.","next_state":"Human scope decision: split the broader move repair into a dependency/follow-up and narrow PLAN-11's move gate, or explicitly widen this contract and runtime budget."}

## Log
- 2026-08-30T11:36:55Z created
- 2026-08-30T12:02:37Z 2026-08-30 user direction: complete PLAN-11 as one job. Do not split the exposed move/editor defects into additional plans and do not reduce assertions to manufacture a pass. Existing peer move work remains part of PLAN-11; this session owns the remaining acceptance items after explicit handoff.
