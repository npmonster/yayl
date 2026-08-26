---
id: PLAN-4
title: Compose and emit a lossless YAML document model
created: 2026-08-26T11:20:47Z
updated: 2026-08-26T14:30:16Z
tags: [yayl, core, cst, emitter, round-trip, future-work]
deps: [PLAN-3]
skills: []
review_rounds: 0
priority: 1
---

## Plan

## Objective

Build the document/tree and emitter layer that preserves YAML presentation metadata and makes round-trip-safe edits possible.

## Scope

- Compose parser events into a document-owned CST/DOM supporting scalar, sequence, mapping, alias, tag, anchor, directives, document start/end markers, and multiple documents.
- Define stable ownership/identity, duplicate-key behavior, alias traversal/cycle safety, and source-span APIs. Preserve comments at document, key, item, block-end, and document-end positions rather than treating them as trivia.
- Implement emission modes: original/preservation-oriented first, then canonical block/flow/JSON modes as separately tested configurations. Preserve scalar style, flow/block form, indentation, markers, tags, anchors, aliases, key order, and comments whenever the source model allows.
- Add explicit controls for newline/width/indent, preserving flow layout, sorting mappings, stripping labels/tags/document markers, and null/empty-key policy only after original mode is stable.
- Verify parse→emit and parse→targeted mutate→emit fixtures byte-stably where unchanged presentation is promised; otherwise assert semantic reparse equivalence and documented formatting deltas.

## Acceptance

- All public node/document APIs are allocator-explicit and safe after failed composition/emission.
- Round-trip fixtures cover comments, quoted/literal/folded scalars, anchors/aliases, tags, directives, flow collections, empty documents, and multi-document streams.
- An emitter test matrix records which modes have strict presentation fidelity versus semantic normalization.

## Dependency

Requires the scanner/parser/event API. PLAN-1 high-level editing must wait for this model.

## Log
- 2026-08-26T11:20:47Z created
- 2026-08-26T14:30:16Z Roadmap update: format-preserving acceptance must include pauta setup mixed-indent fixtures. CST/emitter work must preserve comments, blank lines, quoting, key order, and untouched bytes; inserted blocks must use sibling-local indentation. Source fixtures: /Users/gilberto/Projects/pauta/core/src/setup.zig yamlMapInto/yamlMapOut tests.
