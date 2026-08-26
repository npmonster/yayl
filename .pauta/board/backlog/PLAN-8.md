---
id: PLAN-8
title: Add production I/O, composition, caching, and performance controls
created: 2026-08-26T11:20:47Z
updated: 2026-08-26T11:20:53Z
tags: [yayl, streaming, performance, cache, future-work]
deps: [PLAN-3, PLAN-4, PLAN-6]
skills: []
review_rounds: 0
priority: 1
---

## Plan

## Objective

Close the operational gaps between a parser library and a production-grade YAML toolkit, prioritizing portable explicit controls over hidden global behavior.

## Scope

- Add reader/writer adapters for files, buffers, and streaming I/O; support multi-document composition, include search paths/loader policy, joins, and filters with an explicit filesystem/security boundary.
- Implement resolver policy for anchors and merge keys, alias-following controls, cycle/expansion limits, and deterministic composition diagnostics.
- Add opt-in parse caching keyed by content/options/version; first provide an in-memory bounded cache, then consider durable cache/storage only with format-versioning, integrity verification, atomic writes, recovery, and concurrent-access tests.
- Add optional string interning/dedup and automatic-anchor emission after profiling proves their value. Never make caching or durable storage a prerequisite for normal parsing.
- Build reproducible benchmarks for parse, emit, round-trip editing, streaming memory use, generic conversion, and adversarial resource limits. Compare like-for-like against pinned libfyaml/fyaml workloads and report hardware/toolchain/configuration.

## Acceptance

- Streaming workloads have bounded memory evidence and do not require a full document unless requested.
- File/include/cache operations have documented path, permission, integrity, invalidation, and concurrent-access behavior.
- All performance claims are benchmark-backed; cache misses/corruption recover safely without changing parse correctness.

## Dependency

Streaming parser work can start after the event API; composition/caching that relies on documents/generics waits for those stable APIs.

## Log
- 2026-08-26T11:20:47Z created
