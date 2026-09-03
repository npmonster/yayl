---
id: PLAN-14
title: Explicit core tags are ignored, and two unbounded parent-walks
created: 2026-09-03T13:15:14Z
updated: 2026-09-03T13:15:14Z
tags: [correctness, hardening, audit, 0.15.0]
deps: []
skills: []
review_rounds: 0
priority: 1
---

## Plan

Three pre-existing defects found by an adversarial review of PLAN-13
(Fable 5.1, 2026-09-03). None was introduced by PLAN-13; none is in its
scope. Items A and B are independent and can be taken separately.

## A — Explicit core tags are ignored by conversion and validation

`!!str 42` resolves as an **int**, and `!!int '7'` as a **string**. The
tag is present and correct on the node (`tag = tag:yaml.org,2002:str`),
so this is not a scanner defect — the typed surface never reads it:

- `src/value.zig` — `convert` calls `scalarToValue(allocator, s.value, s.style)`,
  passing value and style but not `node.tag`.
- `src/schema.zig` — `checkNodeCoreTag` calls `resolveCoreTag(s, style)`,
  likewise ignoring `node.tag`.

Consequences, each observable today:
- `parseToValue("x: !!str 42")` yields `.int = 42`, not `.string = "42"`.
- `Schema.str` reports a type violation on `!!str 42`.
- `Schema.int` reports one on `!!int '7'`.

`docs/USAGE.md` documents neither the behaviour nor the limitation, so a
consumer has no way to know the tag is inert.

### Done when
- `nodeToValue` honours an explicit core tag (`!!str`, `!!int`, `!!float`,
  `!!bool`, `!!null`) over plain-scalar resolution, and a non-core or
  unknown tag has a documented, tested behaviour rather than an
  accidental one.
- `checkNodeCoreTag` does the same, so `Schema.str` accepts `!!str 42`
  and `Schema.int` rejects it.
- Tests cover each core tag in both directions: a tag that widens the
  type (`!!str 42`) and one that narrows it (`!!int '7'`).
- `docs/USAGE.md` states the rule.
- Every pinned baseline holds unmoved. If honouring tags would move a
  conformance or roundtrip number that is escalation, not scope — the
  emitted bytes must not change, only the typed interpretation.

## B — Two unbounded walks up the parent chain

**B1. `markModified` hangs forever on a parent cycle.** `sequenceAppend(s, s)`,
or `sequenceAppend(a, b)` then `sequenceAppend(b, a)`, spins at 100% CPU
and never returns — no error, no crash, just a hang, on a public API.

- `src/internal.zig` — `attachItem`/`attachPair` set `item.parent`
  unconditionally, with no check that the item is already parented or is
  an ancestor of the target.
- `src/document.zig` — `markModified` walks `parent` with no bound.

A hang is worse than a crash for a server: nothing to catch, nothing in
the logs. The emitter's docs promise a typed error for an "unanchored
cycle", which this contradicts.

**B2. `Editor.apply` deep-clones the whole root on every call**
(`src/edit.zig`), so a built tree of ~20,000 levels aborted the process.
PLAN-13 bounded `cloneNode`, which should cover it — confirm the bound is
actually reached on the `apply` path and add a test if it is not.

### Done when
- `attachItem`/`attachPair` refuse an item that already has a parent, or
  that is an ancestor of the target, with a typed error.
- A test builds each cycle shape and asserts the typed error rather than
  hanging. Give it a timeout so a regression fails the suite instead of
  wedging CI.
- `markModified` cannot loop even if a cycle were introduced by another
  route (bound it, or assert acyclicity).
- The `Editor.apply` path is covered by a depth test.

## C — One SECURITY.md wording fix (trivial)

It claims "no `unsafe` constructs", which is not a Zig concept and is not
checkable. `src/` contains 31 `@constCast`/`@ptrCast`/`undefined` sites,
all legitimate. Reword to something true and verifiable, or drop it.

## Notes
- The reviewer's other findings were handled inside PLAN-13: the parsed
  alias-cycle crash in `collectDescend`, the false "parsed input was
  never affected" claim, the value/schema/emitter boundary discrepancy,
  and a vacuous test assertion.
- Shared checkout: path-limited commits only, no `git add -A`.
- Fold into 0.15.0; none of this needs a release of its own.

## Log
- 2026-09-03T13:15:14Z created
