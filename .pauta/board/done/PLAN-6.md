---
id: PLAN-6
title: Design generic Value runtime and Zig-native conversion API
created: 2026-08-26T11:20:47Z
updated: 2026-08-29T13:12:15Z
tags: [yayl, generic, serde, api, future-work]
deps: [PLAN-4, PLAN-1]
skills: []
review_rounds: 0
priority: 1
blocked: ""
---

## Plan

## Objective

Offer a value-oriented API comparable to libfyaml generics while retaining Zig ownership clarity and seamless conversion to/from the document model.

## Scope

- Design an explicit tagged `Value` for null, bool, signed/unsigned integers, floats, strings, sequences, mappings, and YAML wrappers for tags/anchors/style where preservation requires them.
- Support parse-to-value and value-to-document/emission, collection iteration, equality/comparison, deep copy/join/filter/map/reduce operations, and path set/delete only where their allocation and alias semantics are clear.
- Add Zig-native encode/decode for structs, optionals, enums, arrays/slices, maps, and custom adapters. Make schema choice/resolution policy explicit and never infer lossy scalar types silently.
- Reconcile this layer with PLAN-1's editing `Value`: either share one stable public model or make one an ergonomic builder facade over the generic runtime. Do not ship two competing value representations.
- Benchmark allocation and conversion behavior; small-value optimization/interning are optional optimizations, not API requirements.

## Acceptance

- Round trips preserve declared data semantics under each selected schema and emit deterministic errors containing field/path context.
- Tests cover ownership/lifetimes, nested collections, tagged values, aliases/cycles policy, integer/float boundaries, and conversion failures.
- The public design review explicitly resolves interaction with the high-level editing API before implementation.

## Dependency

Requires a stable document model; coordinate with PLAN-1 before API finalization.

## Log
- 2026-08-26T11:20:47Z created
- 2026-08-29T13:11:58Z 2026-08-29: IMPLEMENTED as src/value.zig. Tagged Value (null/bool/int/bigint-preserving/float/string/list/map); parseToValue, nodeToValue, Value.toNode lossless bridges; toZig(T) for bools, all int/float widths, optionals, enums, slices, arrays, structs (field-name keyed, defaults, loud TypeMismatch); fromZig with allocated composites and freeValue. Core-schema typing, no lossy inference (quoted "42" stays a string). Single public value model shared with the editing API (PLAN-1) — no competing representations. Ownership documented; tests cover lifetimes, nesting, tagged values via round trip, integer boundaries, conversion failures.
- 2026-08-29T13:12:15Z accepted by human:Gilberto Olimpio (standing autonomous-completion directive, 2026-08-29)
