---
id: PLAN-13
title: Depth-bound value/schema recursion, and close the scanner/parser allocation-sweep gap
created: 2026-09-03T11:01:32Z
updated: 2026-09-03T11:01:32Z
tags: [hardening, security, 0.15.0, audit]
deps: []
skills: []
review_rounds: 0
priority: 1
---

## Plan

The two residuals from vast-wren's v0.12.0 audit, recovered 2026-09-03 and
recorded with full provenance and evidence in PLAN-12's Log. Both are real,
both are still open in v0.14.0. PLAN-12 shipped the release honestly; this
card carries what it did not close.

## Origin

The audit's original text was recovered from the local Claude Code session
transcripts (`~/.claude/projects/-Users-gilberto-Projects-yayl/`). The
suspicions are vast-wren's (session `7f5f99f9`), relayed in crisp-dingo's
v0.12.0 audit report (session `1332b39f`) under `## NOT CHECKED`:

> vast-wren's SUSPECTED items I did not reproduce: `edit.cloneTree` pointed
> at a second Document corrupting spans; stack overflow in emitter/value
> recursion on deep *programmatic* trees at runtime; the thinness of
> allocation-failure injection in scanner/parser/emitter specifically.

Suspicion 1 (cloneTree) was confirmed and fixed in 28869db. This card is
suspicions 2 and 3.

## A — Depth-bound value and schema recursion (CONFIRMED defect)

`value.convert` (`src/value.zig:121-165`) and `schema.checkSchema`
(`src/schema.zig:255`) recurse over the node graph carrying only a
node-count budget (`Limits.max_values` / `Limits.max_nodes`, both
1,048,576). Neither has a depth counter: `grep -c max_depth src/value.zig
src/schema.zig` gives 0, 0.

Reproduced on the v0.14.0 tree (detached worktree at b8457fb): a linear
nest built with `createSequence`/`sequenceAppend`, then `nodeToValue`.
Depths 1,000 / 2,000 / 4,000 return cleanly; 8,000 aborts with a stack
overflow (rc=134); 10,000 segfaults, the backtrace showing `convert` at
`value.zig:134` repeated to exhaustion. The process dies roughly 150x
before the documented budget can fire, and with no typed error.

Not reachable from parsed input — the scanner caps nesting at 200. It is a
consumer-built-tree hazard: `createSequence`/`sequenceAppend` loops, or
`value.toNode` / `fromZig` over a deep structure.

`schema.checkSchema` is structurally identical and is expected to fail the
same way, but was NOT separately reproduced. Treat it as INSPECTED until a
probe exists; part of this card's work is to settle it either way.

The doc half already landed in 085eba4: SECURITY.md now records this as a
known gap with the real numbers, and CHANGELOG has an Unreleased entry.
That commit is a retraction, not a fix — this card is the fix.

### Done when
- `value.convert` and `schema.checkSchema` carry a depth bound that returns
  a typed error (mirror `Emitter.max_depth`'s shape and its
  `error.NestingTooDeep`, or a new typed error if that reads better), with
  a caller-adjustable default consistent with the emitter's 1000.
- A test builds a tree past the bound and asserts the typed error, for BOTH
  the value path and the schema path — no process abort.
- The schema path is either reproduced-then-fixed or cleared with a probe
  and code-path evidence, and which one is recorded here.
- SECURITY.md's "Known gap" paragraph is replaced by the real bound, its
  table gains the row, and the CHANGELOG Unreleased entry becomes a fix
  rather than a retraction.
- Every pinned baseline holds unmoved: conformance 351/0/0/0, roundtrip
  265/0/4, preservation zero failures, differential >= 250 compared with 0
  mismatches, consumer-smoke byte-faithful.
- Each new test is proven to gate: revert the fix, watch it fail, restore,
  watch it pass.

## B — Allocation-failure injection for scanner and parser

vast-wren's suspicion 3, half-closed. PLAN-12's C2 genuinely added the
emission family (`emitBuilt` / `emitStream`, `src/yaml.zig:549-552`). The
scanner/parser half is untouched and the original complaint still holds
verbatim: `grep -c checkAllAllocationFailures src/*.zig` gives scanner.zig
0, parser.zig 0, emitter.zig 0 direct sweeps, and the two parse-side entry
points — `parseOnly` and `parseWriteRoundTrip` (`src/yaml.zig:372-383`) —
still parse only `name: yayl\nitems:\n  - one\n  - two\n`.

That input reaches almost none of the allocating surface. Scanner has 63
allocator sites and parser 18, exercised only through it. The audit's exact
words: it "misses most of the allocating surface" — no anchors, aliases,
tags, flow collections or block scalars.

### Done when
- The parse-side `checkAllAllocationFailures` inputs cover anchors, aliases,
  tags, flow collections (both flow mapping and flow sequence), block
  scalars (literal and folded, with chomping indicators), multi-document
  streams, and comments — not one fixture each bolted on, but inputs chosen
  so scanner and parser allocator sites are actually reached.
- Evidence that coverage moved, not just that the tests pass: report which
  scanner/parser allocator sites the new inputs reach that the old two did
  not, however that is measured.
- No leak and no crash under the sweep; `zig build test` green.

## Notes
- Shared checkout: path-limited commits only, no `git add -A`, no stash or
  reset, and re-read any file a peer touched. Peer `indigo-wolf` was active
  2026-09-03.
- A depth bound is a behaviour change on a public path. If any pinned
  baseline would move to accommodate it, that is escalation, not scope.
- Nothing here needs a release of its own; fold it into 0.15.0.

## Log
- 2026-09-03T11:01:32Z created
