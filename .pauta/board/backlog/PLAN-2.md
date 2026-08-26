---
id: PLAN-2
title: Establish YAML conformance, fuzzing, and compatibility gates
created: 2026-08-26T11:20:47Z
updated: 2026-08-26T11:26:41Z
tags: [yayl, quality, yaml-spec, future-work]
deps: [PLAN-9]
skills: []
review_rounds: 0
priority: 1
---

## Plan

## Objective

Create the evidence framework that prevents yayl from accumulating parser/emitter incompatibilities while the port is built.

## Scope

- Import or reproducibly fetch the upstream YAML Test Suite corpus; pin its revision and record the licensing/provenance.
- Build a table-driven harness that runs parser, event, document, and emitter assertions at the capability level. Each skipped case must carry a reason and a target card, never silently pass.
- Add differential tests against a pinned libfyaml version for accepted/rejected input, normalized event stream, and emit/reparse validity. Do not require byte identity where output style is intentionally configurable.
- Add fuzz/property tests for UTF-8 boundaries, scanner/parser progress, nesting, aliases, block scalars, comments, and parse→emit→parse semantic equivalence. Ensure malformed input never panics, loops, or leaks.
- Define resource-limit configuration (depth, token/input size, alias expansion/work) and adversarial fixtures, even if initial defaults are conservative.
- Add allocator-failure tests for every public allocation-owning layer as it lands, and make test/build warnings fatal in CI.

## Acceptance

- One reproducible command runs focused tests, the pinned corpus, fuzz seeds/property tests, and differential fixtures.
- A machine-readable pass/fail/skip report identifies the exact upstream test case and feature reason.
- CI preserves regression corpus and runs warning-free in debug and ReleaseSafe.
- The card log records the pinned upstream versions and baseline coverage before parser work proceeds.

## Log
- 2026-08-26T11:20:47Z created
