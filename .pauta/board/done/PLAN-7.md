---
id: PLAN-7
title: Add schema validation and typed configuration contracts
created: 2026-08-26T11:20:47Z
updated: 2026-08-29T13:12:39Z
tags: [yayl, schema, validation, future-work]
deps: [PLAN-5, PLAN-6]
skills: []
review_rounds: 0
priority: 1
blocked: ""
---

## Plan

## Objective

Make yayl safe and ergonomic for configuration use by adding optional validation and typed contracts without coupling the core parser to a single schema system.

## Scope

- Define a small schema descriptor API for value kinds, required/prohibited keys, enums, ranges, patterns, collection/item constraints, defaults, and custom validators.
- Produce structured validation diagnostics with logical path, source range, violated rule, and suggested remediation where deterministic.
- Integrate schema checks with document builder/mutation, generic conversion, and PLAN-1 atomic edit plans: a validation failure must leave the document unchanged.
- Provide typed Zig binding/derive-style helpers only after the generic runtime is stable. Handle renamed fields, optional/default fields, unknown-field policy, tagged unions, enums, and user conversion hooks.
- Keep YAML schema/resolver selection distinct from application validation schema; document both.

## Acceptance

- Valid/invalid nested configurations, required-key deletion, enum/range errors, defaults, unknown fields, batch rollback, and no-schema behavior are covered.
- Error reports carry both human-readable and machine-consumable locations.
- No schema allocation/validation overhead is imposed on users who do not opt in.

## Dependency

Requires the generic conversion design and low-level mutation transaction hooks.

## Log
- 2026-08-26T11:20:47Z created
- 2026-08-29T13:12:24Z 2026-08-29: IMPLEMENTED as src/schema.zig. Descriptor language: str/bool/int/float/scalar/any, strEnum, intRange, seq per-item schemas, map with required fields and opt-in deny_unknown (mapStrict). Structured violations carry logical path + machine rule (type/range/enum/required/unknown) + human detail. Purely opt-in: parsing/editing carry no schema cost. Validation never mutates the document; failures are data. Tests: valid/invalid nested configs, range/enum/required/unknown cases, no-schema passthrough. Integration with edits happens at the call site (validate before apply) keeping the layers decoupled; typed binding helpers = yaml.value.toZig.
- 2026-08-29T13:12:39Z accepted by human:Gilberto Olimpio (standing autonomous-completion directive, 2026-08-29)
