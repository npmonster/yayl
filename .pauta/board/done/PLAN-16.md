---
id: PLAN-16
title: Resolve YAML merge keys (<<)
created: 2026-09-11T14:01:44Z
updated: 2026-09-14T06:01:36Z
tags: [yaml, merge-keys, design]
deps: []
skills: []
review_rounds: 0
priority: 1
reviewer: marble-owl (plumb peer session)
auto_review: false
blocked: ""
---

## Plan

Scope and implement opt-in YAML merge-key (`<<`) resolution, matching libfyaml where it is coherent and the YAML 1.1 merge rule where the two libfyaml code paths disagree.

The full analysis lives in `docs/design/merge-keys.md`. Summary:

- Core rule: `Document.resolveMergeKeys()` — atomic, opt-in, deep-copies into the document pool.
- Exposure: `ParseOptions.resolve_merge_keys` plus a read-only value convenience; one rule, one place.
- Detection: a mapping pair whose key is a plain scalar exactly `<<`. Values: alias-to-mapping, mapping, or a sequence of either.
- Precedence: explicit keys in the mapping win; the earliest source in a sequence wins. Recursion and size are bounded.
- Never on by default: `tests/fixtures/gitlab-anchors.yaml` and the round-trip/preservation gates pin the current bytes.

Open decisions in the note (value rule, exposure, naming, anchor purge) need a human call before implementation starts.

## Log
- 2026-09-11T14:01:44Z created
- 2026-09-14T04:01:36Z 2026-09-11: implementation complete on main. Commits 3c12954 (feature + tests + docs) and the follow-up coverage commit. Gates: make verify green (fmt, check, Debug+ReleaseSafe tests, examples, conformance 351/351, roundtrip 269/269, preservation all pass, consumer smoke); make differential 269 compared/0 mismatches; make emission-oracle 539 documents/0 findings. 12 merge-key tests in src/document.zig + 1 in src/value.zig. Moved to review; reviewer marble-owl (plumb peer) asked via plumb chat but has not read the request yet. Remaining follow-up recorded in docs/design/merge-keys.md: differential against libfyaml FYPCF_RESOLVE_DOCUMENT.
- 2026-09-14T04:02:21Z Correction to the previous entry: the merge-key suite is 23 tests in src/document.zig plus 1 in src/value.zig (counted with grep), not 12. Second commit is 3d2f92a.
- 2026-09-14T05:13:51Z 2026-09-11: reviewer marble-owl surfaced a pre-existing emitter bug via a probe while reviewing this card: the laid-out path wrote `? K: V` on one line, which re-reads as a mapping key with a null value; reachable through merge resolution copying a complex key. Fixed by marble-owl in e91d04e (emitEntry puts the indicator on its own line) with three round-trip tests; make verify green on e91d04e. I added the merge-side integration test (complex key out of a merge source, copied and re-read). marble-owl also recorded an owed fix in tests/preservation.zig: the explicit_key target category is skipped outright and should be un-skipped -- that is the gap that hid this bug.
- 2026-09-14T05:44:59Z 2026-09-11: reviewer marble-owl returned PASS on all six review questions (atomicity, clone alias targets, emission, precedence, bounds/recursion, untested). Its two code corrections plus the emitter bug it found are all closed: MergeKeyRecursive comment corrected + parsed-input test added; cloneTreeWhole refuses a forward alias instead of pointing the clone at the pre-clone tree; mappingHasKey note added; CRLF-under-merge test added and it found a second pre-existing emitter bug (structural breaks hardcoded LF) now fixed via Emitter.defaultTerminator; explicit_key preservation targets moved from outright-skipped to weakly swept (8 corpus targets swept, gate green). Commits: a2ba956 (emitter CRLF + review cleanups), plus the preservation un-skip commit. All gates green: make verify, make differential (269/0), make emission-oracle (539/0).
- 2026-09-14T05:44:59Z review passed
- 2026-09-14T06:01:36Z 2026-09-11 follow-up (reviewer marble-owl): my explicit_key un-skip was an operation gap — delete/set reuse the key's source span, so the laid-out explicit-key arm was never reached. Added a complex-key map-add (one-item flow-sequence key) on every container the add sweep touches. First red-proof still passed 9/9: assertsSemanticRoundTrip uses yaml.value, which returns error.TypeMismatch for a non-scalar key and silently skips, so the assertion was blind too. Now asserts the reparsed container structurally (sequence key [9] -> value added). Red-proved in a detached worktree with only the emitEntry line reverted: 322 failures, gate 6/9; green with the fix. Commits 2106cc9, b1aeef7. Counter moved from skipped: to 'weak (semantic-only): N explicit-key targets'.
