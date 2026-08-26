---
id: PLAN-1
title: Design high-level, round-trip-safe YAML editing API
created: 2026-08-26T11:16:16Z
updated: 2026-08-26T14:30:12Z
tags: [yayl, api, yaml, future-work, discovery-required]
deps: [PLAN-5]
skills: []
review_rounds: 0
priority: 1
---

## Plan

## Objective

Design and implement yayl's high-level, comment-preserving YAML editing API so it exceeds Rust yaml-edit in expressive paths, atomic multi-edit workflows, typed value construction, deferred previews, and optional schema-aware validation.

## Preconditions and scope guard

This repository currently contains only `LICENSE`; no Zig source, build manifest, CST/mutation layer, test suite, or benchmark harness is available. Do not begin production implementation until the upstream source is present and the discovery checkpoint below is complete. Do not modify the low-level CST or mutation layer.

## Discovery checkpoint (required before Phase 1)

1. Inventory the repository with `rg --files` and identify the actual Zig package root, build command(s), parser, emitter, CST node types, document ownership/allocator model, and mutation primitives. Do not assume `src/cst.zig`, `src/mutate.zig`, `src/edit.zig`, or any other path.
2. Read the discovered public APIs and existing inline/integration tests. Record exact source and test paths plus the round-trip fixture strategy in the card log.
3. Confirm a baseline: debug and ReleaseSafe builds/tests pass with zero warnings. If no test or benchmark harness exists, make its creation an explicit first implementation subtask and define a reproducible Rust yaml-edit comparison workload; do not claim the performance target was measured before that exists.
4. Resolve design decisions before coding: public Document ownership, traversal semantics for wildcard/filter/recursive descent, filter grammar and supported predicates, no-match vs invalid-path behavior, duplicate map-key policy, comment attachment semantics, and transaction/rollback mechanism.

## Phase 1 — Path engine

- Add a public slice-backed `Path` representation in the API module selected by discovery, preserving source ranges instead of copying path fragments where feasible.
- Support map-key segments, sequence indices, wildcard `[*]`, conditional `[?filter]`, and recursive descent `..`; document the exact grammar, escaping rules, ordering/deduplication rules, and filter predicate subset.
- Return a structured path error containing failure byte offset, expected construct, and human-readable diagnostic. Separate parse failures from evaluation/type/no-match failures where the host error model permits.
- Provide traversal results that retain node/context information needed by editing without exposing unsafe CST internals.
- Tests: valid and malformed grammar at byte boundaries; quoted/escaped keys; root/scalar/map/sequence mismatches; empty/multiple results; wildcard order; recursive-cycle/nontermination protection; filter semantics; comments and aliases if yayl supports them; allocation-failure coverage for owning helpers.
- Gate: all project tests and focused path tests pass, parsing has documented allocation behavior, and path-only round-trip fixtures prove parsing/traversal does not mutate emitted YAML.

## Phase 2 — High-level atomic edits

- Add public `Document` methods: `set`, `delete`, `insert_before`, `insert_after`, `move`, and `batch([]const Edit)`, using Zig naming conventions and documented error sets compatible with the discovered API.
- Define a type-safe `Edit` tagged union and structured edit/path-context errors. `set` may create intermediate maps/sequences only under a documented deterministic rule; ambiguous container choice must error rather than silently guess.
- Implement batch and move through a transaction/undo strategy over existing mutation primitives. A failed operation must restore byte-for-byte emission and tree invariants; aliasing and source/destination overlap must be rejected or defined explicitly.
- Preserve key order, comments, whitespace, scalar style, and sibling formatting. Define how attached comments move/delete and add fixture assertions for each rule.
- Gate: failure-injected batch rollback test; parse-edit-emit-reparse validity; metadata-preservation fixtures; allocator failure tests; full debug and ReleaseSafe test commands are warning-free.

## Phase 3 — typed Value construction

- Add a public `Value` tagged union plus scalar/map/sequence builders that allocate exclusively through the caller/document allocator and can materialize compatible CST nodes through the discovered mutation layer.
- Support strings, signed/unsigned integers, floats, booleans, nested structs, arrays/slices. Specify ownership and lifetime for borrowed strings and reflection-supported input types.
- Implement conservative scalar-style selection: plain only when YAML-safe; quote unsafe/ambiguous text; use block styles only when content and surrounding context permit. Preserve an explicit-style override for callers needing stable output.
- Tests: YAML syntax hazards, Unicode, empty/multiline strings, numeric edge cases, nested values, allocation failures, and comment-preserving set/insert integration.
- Gate: public examples compile; no unnecessary allocation claim without allocator-instrumented evidence; all tests pass warning-free.

## Phase 4 — deferred plan and diff

- Add `EditPlan` that records the same operations without touching a `Document`; expose plan builders, atomic `apply`, and a deterministic human-readable `diff`.
- Specify validation time: syntax and plan-local checks occur while building; document-dependent resolution/conflicts occur at apply. A failed apply must leave the document unchanged.
- Ensure the preview labels paths and operation type, handles multi-match edits, and does not expose secrets/content unexpectedly without an explicit rendering option.
- Tests: a plan does not mutate source; stable diff snapshots; conflicts caused by document changes; rollback; equivalence of direct batch and plan apply.
- Gate: all test/build checks pass; preview assertions document stable output contract.

## Phase 5 — optional schema-aware validation

- Design schema as an optional, non-invasive descriptor layer; no schema must retain Phase 1–4 behavior and cost characteristics.
- Validate value kind, required keys, enum membership, and nested constraints at edit time with structured errors containing both logical path and violated rule.
- Define validation for auto-created intermediates, wildcard/multi-target edits, moves, and partial batches; schema failure must participate in atomic rollback.
- Tests: valid/invalid nested cases, required-key deletion, enums, no-schema compatibility, and schema errors inside batches/plans.
- Gate: warning-free debug/ReleaseSafe suite and rollback/round-trip fixtures pass.

## Cross-cutting acceptance evidence

- All public APIs have doc comments plus small usage examples aligned to the discovered package layout.
- Use only explicit allocators; no global mutable state or hidden ownership transfer.
- Treat compiler, formatter, linter, and test warnings as failures.
- Add a reproducible benchmark comparing equivalent yayl and Rust yaml-edit workloads. The initial performance target is yayl no slower than 2x; report environment, versions, fixture size, repetitions, and measured result. If the comparator cannot express an operation (e.g. wildcard batch/preview), mark it capability-only rather than inventing a timing.
- Finish each phase with an independent review of API compatibility, diagnostics quality, transaction safety, memory behavior, and round-trip fidelity before beginning its dependent phase.

## Sequencing and dependencies

Discovery/bootstrap -> Phase 1 -> Phase 2 -> Phase 3 -> Phase 4 -> Phase 5. Phase 5 is optional for initial release, but its extension points must not require breaking the Phase 1–4 public API.

## Current blocker

Source and build/test infrastructure are absent from the checked-out repository. Once they are added, complete the discovery checkpoint, split this parent card into bounded implementation cards by phase, and attach exact file/test paths and measured baseline evidence.

## Log
- 2026-08-26T11:16:16Z created
- 2026-08-26T14:30:12Z Roadmap update: pauta setup acceptance fixtures are now known. Required operations are setting mcp_servers.pauta.command (including absent-key creation) and inserting/removing a named sub-block while preserving unrelated comments, blank lines, quoting, whitespace, and key order. Mixed 4/2-space fixtures must derive indentation from the sibling block, not a file-wide minimum. Reference tests: yamlMapInto (hermes) mixed-indent preservation and missing-command repoint insertion. Source: /Users/gilberto/Projects/pauta/core/src/setup.zig.
