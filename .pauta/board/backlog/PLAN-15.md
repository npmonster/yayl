---
id: PLAN-15
title: Track yayl curated-list PRs and registry registration
created: 2026-09-06T08:16:24Z
updated: 2026-09-15T22:12:51Z
tags: []
deps: []
skills: []
review_rounds: 0
priority: 1
plan_draft: false
blocked: "waiting: dreftymac/awesome-yaml#15 ping due ~2026-09-27; registries verified 2026-09-16 — neither lists yayl (Zig-Index: 1000-result GitHub search cap, 1433 repos in topic; Zigistry: unindexed). Both need external action."
---

## Plan

Follow up on the curated-list submissions made on 2026-09-06 to make yayl discoverable. Nothing blocks on these; the work is: check PR review status, respond to maintainer feedback, and confirm the automated registry registrations landed.

**Status 2026-09-16: two of the three PRs are merged; the third is quiet and still inside its waiting window. Both registry listings are now VERIFIED — neither lists yayl, and the Zig-Index cause is identified (their scanner cannot reach it).**

## PRs to check (respond same-day to feedback; one polite ping after ~3 weeks of silence)

- [x] **zigcc/awesome-zig — [PR #260](https://github.com/zigcc/awesome-zig/pull/260)** (primary, ~2.5k stars). **MERGED 2026-09-07** (verified via GitHub API). One-line entry appended at the END of "File Format Processing" with `AI-assisted.` attribution per their policy; their `make all` gate passed (TOC/prettier unchanged, awesome-lint ✔).
- [x] **C-BJ/awesome-zig — [PR #100](https://github.com/C-BJ/awesome-zig/pull/100)** (~1.7k stars). **MERGED 2026-09-11** (verified via GitHub API). Two-line badge+link block in "Compiler & Parser & Interpreter", inserted alphabetically between `luf` and `protozig`.
- [ ] **dreftymac/awesome-yaml — [PR #15](https://github.com/dreftymac/awesome-yaml/pull/15)** (small, slow — last activity 2026-07). First Zig entry in "Parsers" (`* [zig](…)`). Still open on 2026-09-16 (`state: open`, `merged: false`), 0 review comments, no maintainer feedback. Expect weeks of silence; that is normal, not rejection. **Polite ping due ~2026-09-27.**

## Automated registries — VERIFIED 2026-09-16 (no browser needed)

The earlier note that these "must be checked in a browser" was **wrong**. Both registries were checked through their own data sources; both currently do **not** list yayl. Repo state is confirmed good: `npmonster/yayl` carries the `zig-package` topic, and commits have been pushed well after the topic add (through the 0.19.3 series).

- [ ] **Zig-Index** (<https://zig-index.github.io>) — **NOT listed; root cause identified (a bug in their scanner, not in our repo).**
  - Evidence: the registry's own state (`registry.json`, 1193 tracked repos, `lastSync` 2026-09-15T21:57Z) contains no yayl; `database/npmonster/yayl.json` → HTTP 404; yet the repo *does* match their discovery query — `repo:npmonster/yayl topic:zig-package fork:false` → `total_count: 1`.
  - Cause: their scanner pages `topic:zig-package fork:false` (`scripts/update.ts`, GraphQL `search(first: 100, after: $cursor)`). That topic now holds **1433** repos, and GitHub hard-caps any single search at the first **1000** results (verified: `page=11` → HTTP 422 *"Only the first 1000 search results are available"*). 806 repos have ≥3★ and **627 have ≤2★** — yayl (2★) sits in the band that never gets paged.
  - Their fix: shard discovery by star range (e.g. `stars:0..2`, `stars:3..10`, …) so each query stays under the cap. Nothing further to do on our side.
  - Next (needs human go-ahead, public action): file an issue at `Zig-Index/registry` with this evidence — framed as a scanner bug, not a listing request.
- [ ] **Zigistry** (<https://zigistry.dev>) — **NOT listed; cause is on their side.**
  - Evidence: `/search/packages/?q=yayl` → `total: 0` (endpoint verified live: `yaml`→75, `zap`→14, `libvaxis`→7); `q=npmonster`→0; `/users/?q=npmonster`→`"Unknown id."`; programs search → 0.
  - Their documented requirement (add the `zig-package` topic, then push a commit) is already satisfied, so their crawler is simply not picking the repo up.
  - Next: re-check in a few days; if still absent, ask at `zigistry/zigistry` what the crawler requires (the repo has a valid `build.zig.zon`, version 0.19.3, and releases).

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

All three PRs are merged or closed, and yayl is confirmed listed on zig-index.github.io and zigistry.dev. (As of 2026-09-16 both registries are verified NOT listing yayl — see above; Zig-Index needs a fix on their side.)

## Log
- 2026-09-06T08:16:24Z created
- 2026-09-11T14:00:26Z 2026-09-11: verified PR states via GitHub API — zigcc/awesome-zig#260 MERGED 2026-09-07T01:49Z; C-BJ/awesome-zig#100 MERGED 2026-09-11T08:20Z; dreftymac/awesome-yaml#15 still open, 0 comments. Registry listings (zig-index, zigistry) unverified: both sites are client-rendered, direct package URLs 404 for known-listed packages too. Repo topics confirm zig-package; 0.18.0 push satisfies the Zigistry trigger. Parked blocked on the ~2026-09-27 polite ping for #15.
- 2026-09-15T22:12:51Z 2026-09-16: registry verification done programmatically (no browser needed — the earlier assumption was wrong). Neither registry lists yayl. Zig-Index: not in registry.json state (1193 repos, lastSync 2026-09-15T21:57Z), database/npmonster/yayl.json 404s, but the repo matches their discovery query (repo:npmonster/yayl topic:zig-package → total_count 1). Root cause: their scanner pages topic:zig-package fork:false, that topic has 1433 repos, and GitHub caps any search at 1000 results (page=11 → HTTP 422); 627 of those repos have ≤2★, the band yayl (2★) falls in. Zigistry: search/packages?q=yayl → total 0, q=npmonster → 0, /users?q=npmonster → Unknown id, programs → 0, so the topic+push requirement being met has not been picked up. dreftymac PR #15 still open (state open, merged false), ping due ~2026-09-27. Card body de-duplicated and status corrected.
