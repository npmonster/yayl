---
id: PLAN-16
title: Resolve YAML merge keys (<<)
created: 2026-09-11T14:01:44Z
updated: 2026-09-11T14:01:44Z
tags: [yaml, merge-keys, design]
deps: []
skills: []
review_rounds: 0
priority: 1
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
