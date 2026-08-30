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
make verify        # fmt + compile + Debug & ReleaseSafe tests
                   # + corpus conformance + byte-faithful round trips
make differential  # optional: event parity vs libfyaml (C compiler)
```

The suite must stay green with **zero leaks** (tests run under
`std.testing.allocator`). Public allocating operations need
allocation-failure injection (`std.testing.checkAllAllocationFailures`).
Everything is merged to `main`; work happens on the pauta board, one
card per change, with evidence logged on the card.

## Reporting issues

Include a minimal YAML input and what you expected. Parser/emitter
bugs: say what libfyaml does with the same input if you know — that
decides whether it is a bug or a documented divergence.
