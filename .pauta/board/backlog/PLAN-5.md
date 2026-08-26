---
id: PLAN-5
title: Add document builder, core mutation, and YPath compatibility
created: 2026-08-26T11:20:47Z
updated: 2026-08-26T11:20:53Z
tags: [yayl, document, mutation, ypath, future-work]
deps: [PLAN-4]
skills: []
review_rounds: 0
priority: 1
---

## Plan

## Objective

Provide libfyaml-compatible document construction, low-level safe mutation, and expressive query primitives beneath the planned high-level editor.

## Scope

- Add a builder for scalars, mappings, sequences, tags, anchors, aliases, directives, and document markers, with a precise borrowed-vs-owned input contract.
- Add low-level insert/replace/remove/move operations that preserve document invariants, metadata attachment, source/node identity, and key order. Define error behavior for alias cycles, duplicate keys, cross-document moves, and source/destination overlap.
- Implement a YPath-compatible query layer or document a deliberately different grammar and provide a compatibility adapter. Cover root/path selection, mapping/sequence lookup, wildcards, predicates/filters, recursive traversal, alias-following policy, and deterministic multi-match order.
- Supply mutation rollback primitives or transaction hooks that PLAN-1 can use for atomic batch edits. Do not duplicate PLAN-1's user-facing edit/diff API.

## Acceptance

- Builder and mutation tests use the same round-trip metadata fixtures as the document/emitter card.
- YPath results and errors are differential-tested against pinned libfyaml examples where compatibility is claimed.
- A failed mutation leaves document invariants and emission unchanged; allocator failure is tested.
- PLAN-1 may depend on this card after the lossless document model exists.

## Dependency

Requires the composed document/emitter model.

## Log
- 2026-08-26T11:20:47Z created
