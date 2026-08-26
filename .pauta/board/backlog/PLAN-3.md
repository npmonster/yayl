---
id: PLAN-3
title: Implement YAML scanner, parser, and streaming event API
created: 2026-08-26T11:20:47Z
updated: 2026-08-26T11:20:57Z
tags: [yayl, core, parser, events, future-work]
deps: [PLAN-2]
skills: []
review_rounds: 0
priority: 1
---

## Plan

## Objective

Turn the existing character, UTF-8, pool, and diagnostics primitives into a standards-aware YAML scanner/parser with a public streaming event API.

## Scope

- Implement tokens for directives, document markers, flow/block collections, scalar styles, tags, anchors, aliases, comments, and source marks; retain slices into input whenever safe.
- Implement an iterative parser with explicit limits and rich diagnostics, supporting YAML 1.2 by default and explicit version/schema policy hooks. Define any staged YAML 1.1/1.3 compatibility separately.
- Expose a pull/callback event stream for multi-document inputs so applications can process large YAML without building a full document. Events must carry anchors/tags/styles/marks sufficient for a compatible emitter/composer.
- Support JSON compatibility mode and documented relaxed-flow/JSONL-like mode only when explicitly configured.
- Cover duplicate-key policy, directives, aliases, malformed nesting, scalar edge cases, and error recovery/multiple diagnostics according to the policy established in the conformance card.

## Acceptance

- Event traces pass the applicable pinned YAML Test Suite and libfyaml differential fixtures.
- The parser cannot recurse unboundedly or spin on invalid input; resource-limit failures are structured diagnostics.
- Public parser/event examples compile with explicit allocator and input lifetime rules.
- This is a prerequisite for document composition, emission, and editing; do not expose an unstable CST as the long-term public API.

## Log
- 2026-08-26T11:20:47Z created
