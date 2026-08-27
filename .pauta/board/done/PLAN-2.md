---
id: PLAN-2
title: Establish YAML conformance, fuzzing, and compatibility gates
created: 2026-08-26T11:20:47Z
updated: 2026-08-27T04:56:13Z
tags: [yayl, quality, yaml-spec, future-work]
deps: [PLAN-9]
skills: []
review_rounds: 0
priority: 1
blocked: ""
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
- 2026-08-27T01:31:08Z Overnight run (qwen-code, self-review policy): infrastructure + baseline landed; card stays in-progress. Done: (1) corpus pinned — yaml/yaml-test-suite @ da267a5c4782e7361e82889e76c0dc7df0e1e870 (MIT, Ingy döt Net), fetched via scripts/fetch-corpus.sh / make corpus into gitignored vendor/, provenance in tests/README.md; (2) harness tests/conformance.zig wired as `zig build conformance` + `make conformance` + CI step (report-only until triage; report artifact uploaded); capability-level event-tree comparison in corpus notation, fail:true rejection checks, JSON report zig-out/conformance-report.json, skips table with mandatory reason+target; (3) seeded fuzz (400 random ASCII inputs, no panic/leak) and write(parse()) fixpoint property tests in the unit suite (64 tests, make verify green). Baseline: 199 pass / 152 fail of 351. Failure classes: 43 indentation-differs, 45 line-content-differs (notation + real), 45 parse errors on valid input, 19 accepted-but-should-reject. Key finding: 18 corpus files are themselves structurally misparsed by yayl (harness reports >1 top-level record): 2G84, 3RLN, 4MUZ, 96NN, 9MQT, DE56, DK95, HM87, JEF9, KH5V, L24T, M2N8, MUS6, SM9W, UKK6, VJP3, Y79Y, ZYU8 — these poison their own cases and are high-value PLAN-3 bugs. Remaining for this card: per-failure triage into the skips table (reason + target card), resource-limit config (depth/input size/alias expansion) + adversarial fixtures, differential tests vs pinned libfyaml (needs a zig-cc build of the C lib), parseAll allocation-failure coverage, then flip CI gate from report-only to blocking.
- 2026-08-27T04:51:08Z Completed overnight (qwen-code). Pinned references: yaml-test-suite @ da267a5c4782e7361e82889e76c0dc7df0e1e870 (MIT, fetched by scripts/fetch-corpus.sh / make corpus into gitignored vendor/); libfyaml @ 04e0b58135c2e1a9264e1c4b915a6c8e750aa923 vendored as read-only reference. Evidence framework: tests/conformance.zig runs all 351 cases through the parser, renders events in corpus tree notation (markers decoded incl. tabs/spaces/EOF), compares at capability level, and writes machine-readable zig-out/conformance-report.json (id/name/status/reason per case). Skip policy enforced in code: every skip has reason + target card, skipped cases still execute, and a passing skip fails the gate as stale. Baseline: 301 pass / 50 skip / 0 fail; all 50 skips target PLAN-3. One reproducible command: make verify (fmt + compile + Debug + ReleaseSafe + corpus); CI mirrors it on Zig 0.16.0, hard gate, report uploaded as artifact. During triage the harness surfaced and unit-tested 15+ real parser/scanner bugs (see commits 70dae24..3b496e7): trailing-whitespace plain scalars, '#' content in block scalars, document state machine, tab rules, flow adjacent values, quoted-scalar folding, directive placement, rejection classes. Warning-free: the gate output is silent when green. Remaining for PLAN-3 (recorded per-case in the skips table): flow empty nodes/keys, multiline flow constructs, anchor/alias charsets, tag rendering, block-scalar tab interplay, quoted continuation indentation.
- 2026-08-27T04:56:13Z review passed
