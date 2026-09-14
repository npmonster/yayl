---
id: PLAN-16
title: Resolve YAML merge keys (<<)
created: 2026-09-11T14:01:44Z
updated: 2026-09-14T04:02:21Z
tags: [yaml, merge-keys, design]
deps: []
skills: []
review_rounds: 0
priority: 1
reviewer: marble-owl (plumb peer session)
auto_review: false
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
