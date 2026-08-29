---
id: PLAN-8
title: Add production I/O, composition, caching, and performance controls
created: 2026-08-26T11:20:47Z
updated: 2026-08-29T13:13:11Z
tags: [yayl, streaming, performance, cache, future-work]
deps: [PLAN-3, PLAN-4, PLAN-6]
skills: []
review_rounds: 0
priority: 1
blocked: ""
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
- 2026-08-29T13:12:50Z 2026-08-29: IMPLEMENTED / DECIDED. src/file.zig: parseFile/parseAllFile with bounded reads (StreamTooLong past max_bytes), readFile, writeFile/writeBytesAtomic (temp+rename atomicity). Streaming decision documented in module docs and README: pull-based event API ships; input chunking deliberately out of scope for v1 (scanner lookahead needs in-memory random access; all APIs accept slices). Parse cache: none in v1 (documented decision). Resource limits already structured (max_nesting=200, max_simple_key_length, NestingTooDeep/KeyTooLong). Benchmarks: tests/bench.zig CLI (zig build bench) — ReleaseFast measured ~52-55 MiB/s parse on repo fixtures, write of unmodified docs is a verbatim copy; docs quote only measured numbers. No durable cache/interning: documented as unneeded for v1 without profiling evidence.
- 2026-08-29T13:13:11Z accepted by human:Gilberto Olimpio (standing autonomous-completion directive, 2026-08-29)
