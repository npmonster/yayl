---
id: PLAN-15
title: Track yayl curated-list PRs and registry registration
created: 2026-09-06T08:16:24Z
updated: 2026-09-06T08:16:34Z
tags: []
deps: []
skills: []
review_rounds: 0
priority: 1
plan_draft: false
---

## Plan

Follow up on the curated-list submissions made on 2026-09-06 to make yayl discoverable. Nothing blocks on these; the work is: check PR review status, respond to maintainer feedback, and confirm the automated registry registrations landed.

## PRs to check (respond same-day to feedback; one polite ping after ~3 weeks of silence)

- [ ] **zigcc/awesome-zig — [PR #260](https://github.com/zigcc/awesome-zig/pull/260)** (primary, ~2.5k stars). One-line entry appended at the END of "File Format Processing" with `AI-assisted.` attribution per their policy; their `make all` gate passed (TOC/prettier unchanged, awesome-lint ✔). Maintainers merge external entry PRs actively (e.g. #251, #252).
- [ ] **C-BJ/awesome-zig — [PR #100](https://github.com/C-BJ/awesome-zig/pull/100)** (~1.7k stars). Two-line badge+link block in "Compiler & Parser & Interpreter", inserted alphabetically between `luf` and `protozig`. Maintainers are responsive (3 community PRs merged recently, 0 open backlog) — likely first to merge.
- [ ] **dreftymac/awesome-yaml — [PR #15](https://github.com/dreftymac/awesome-yaml/pull/15)** (small, slow — last activity 2026-07). First Zig entry in "Parsers" (`* [zig](…)`). Expect weeks of silence; that is normal, not rejection.

## Automated registries to verify

- [ ] **Zig-Index** (<https://zig-index.github.io>): `zig-package` topic was added to npmonster/yayl on 2026-09-06; listing is fully automated and should appear within hours. If missing after 24h, re-check topics (`gh repo view npmonster/yayl`).
- [ ] **Zigistry** (<https://zigistry.dev>): needs a PUSHED COMMIT on npmonster/yayl *after* the topic add to trigger indexing. Will trigger naturally with the next real commit — do not manufacture one. Suggested natural trigger: the next release's README `zig fetch` example bump. Verify yayl is listed ~24h after that push.

## If maintainers request changes

Edit the existing PR branch (don't open new PRs). Branches live on the golimpio forks:
- `golimpio/awesome-zig`, branch `add-yayl`
- `golimpio/awesome-yaml`, branch `add-yayl-zig-parser`
- `golimpio/awesome-zig-1`, branch `add-yayl` (auto-suffixed fork name)

Entry copy as submitted (for rewording requests):
- zigcc: `- [npmonster/yayl](https://github.com/npmonster/yayl) - YAML 1.2 parser, editor and emitter for Zig. Byte-faithful round trips keep untouched bytes, comments and layout intact. AI-assisted.`
- dreftymac: `* [zig](https://github.com/npmonster/yayl)`
- C-BJ: badge line `![Star](https://img.shields.io/github/stars/npmonster/yayl?color=orange)` + `[yayl🗒️YAML 1.2 parser, editor and emitter for Zig](https://github.com/npmonster/yayl)`

## Standing rules

- One PR per list, never cross-reference the other lists in PR bodies (spam guard).
- Withdrawal path: close the PR — zero residual impact.
- Out of scope (deliberately): brandonhimpfen/awesome-zig (8 stars, anti-promotional policy), json-next/awesome-yaml (poor structural fit). Social announcements (HN, r/Zig, ziggit) are a separate future plan, best after merges.

## Done when

All three PRs are merged or closed, and yayl is confirmed listed on zig-index.github.io and zigistry.dev.

## Log
- 2026-09-06T08:16:24Z created
