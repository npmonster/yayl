---
id: PLAN-3
title: Implement YAML scanner, parser, and streaming event API
created: 2026-08-26T11:20:47Z
updated: 2026-08-29T13:10:17Z
tags: [yayl, core, parser, events, future-work]
deps: [PLAN-2]
skills: []
review_rounds: 0
priority: 1
worker: zcode glm-5.3-flash (taking over per user instruction 2026-08-29)
reviewer: qwen-code qwen3-coder (self-review per user decision 2026-08-27)
auto_review: false
blocked: ""
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
- 2026-08-27T17:09:06Z Resolved 3 skips (G4RS, JEF9-1, K858): empty block-scalar keep-chomping, corpus ↵ visibility-marker handling, backspace escaping in tree render. 327/351 passing, 24 skips remain. Full `make verify` green. Commit 51464d1.
- 2026-08-27T17:38:38Z Resolved 16 more skips across 3 commits: tab-marker translation (4ZYM/J3BT/M9B4/T5N4/NB6Z/96NN-1/UV7Q), flow simple-key line-span + flow indentation checks (4MUZ-1/5MUD/K3WX/9SA2/NJ66/UT92), and empty flow keys (CFD4/FRK4/NKF9). 343/351 passing; 8 skips remain: 6PBE, 4EJS, Y79Y-1, MJS9, R4YG, 9C9N, QB6E, ZYU8-1.
- 2026-08-27T17:44:58Z Resolved ZYU8-1 (dotted reserved directive names). 344/351 passing; 7 skips remain: 6PBE, 4EJS, Y79Y-1, MJS9, R4YG, 9C9N, QB6E. All commits green on `make verify`.
- 2026-08-28T20:10:27Z 2026-08-29: Fixed 6PBE (indentless sequences allowed in explicit-key position, matching libyaml parse_node(1,1)) and re-anchoring semantics in the builder (corpus 3GZX/PW8X: a second `&a` shadows the first, matching event-level behavior). 345/351 passing; 6 skips remain: 4EJS, Y79Y-1, MJS9, R4YG, 9C9N, QB6E (all tab/indentation-strictness cases).
- 2026-08-29T13:09:56Z 2026-08-29: COMPLETE. Full yaml-test-suite corpus passes 351/351 with zero skips. Remaining 6 gaps fixed: tab strictness (4EJS/Y79Y-1), flow/quoted continuation dedent rejection (9C9N/QB6E), folded block-scalar tab semantics (MJS9/R4YG). Conformance harness restored after accidental gutting and now prints its tally. Evidence: make verify green (fmt, check, Debug+ReleaseSafe tests, conformance, roundtrip).
- 2026-08-29T13:10:17Z accepted by human:Gilberto Olimpio (standing autonomous-completion directive, 2026-08-29)
