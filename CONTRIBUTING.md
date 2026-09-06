# Contributing

yayl is developed end-to-end by AI coding agents under human direction
and review. The playbook any contributor — human or agent — follows
lives in [AGENTS.md](AGENTS.md); read it before touching code.

## Ground rules

- **Zig 0.16.0**: CI pins this exact version; `build.zig.zon` sets it
  as `.minimum_zig_version`, so a later 0.16.x also builds.
- **Conversion first**: yayl ports libfyaml's architecture. When in
  doubt, match its observable behavior, and mark deliberate deviations
  with a `PORT NOTE:` comment.
- **Idiomatic Zig**: tagged unions, error unions, explicit allocators,
  tests next to the code they cover, doc comments on public API.
- **DRY**: one implementation per rule; refactor instead of copying.
- **No silent divergence**: behavior changes need a test or a written
  note that the old behavior was unobservable.

## Before you open a PR

```sh
make verify        # every gate except differential (which needs a C compiler)
make differential  # optional: event parity vs libfyaml (needs a C compiler)
```

`make help` lists every target; the gates and their current numbers are
in the README's Development section.

The suite must stay green with **zero leaks** (tests run under
`std.testing.allocator`). Public allocating operations need
allocation-failure injection (`std.testing.checkAllAllocationFailures`).
Everything is merged to `main`; work happens on the pauta board, one
card per change, with evidence logged on the card.

## Cutting a release

Releases are cut from `main` by hand — there is no release workflow;
`ci.yml` gates the tag and `docs.yml` republishes the API reference to
GitHub Pages on every `v*` tag.

1. Turn the changelog's pending notes into a `## X.Y.Z — date` section
   in [CHANGELOG.md](CHANGELOG.md), bump `.version` in
   `build.zig.zon`, and update the `zig fetch --save` pin in the
   README to the new tag.
2. Run the whole suite **before** cutting the release commit, not
   after — a change can invalidate a test that encoded the old
   behavior.
3. Gate in a detached worktree (a shared checkout may hold another
   session's uncommitted work): `make verify`, plus
   `scripts/differential.sh` with `vendor/` copied in.
4. Commit as `release: X.Y.Z`, push `main`, then tag the pushed
   commit by explicit sha (`git tag -a vX.Y.Z <sha>`) and push the tag.
5. Publish the GitHub Release: `gh release create vX.Y.Z --title ...
   --notes-file ...`, the notes being a short summary paragraph plus
   the new changelog section — that is the convention every existing
   release follows.

## Reporting issues

Include a minimal YAML input and what you expected. Parser/emitter
bugs: say what libfyaml does with the same input if you know — that
decides whether it is a bug or a documented divergence.
