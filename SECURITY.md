# Security Policy

## Supported versions

The latest tagged release is supported. Pre-1.0, the minor version is
the release series and only the most recent one receives fixes —
upgrade to the newest tag rather than pinning an old minor.

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting** for this repository
(Security → Report a vulnerability). Please do not open a public issue
for something exploitable. Include the input that triggers the problem
(smallest reproducer you have) and the version you tested against. You
will get an answer, and credit if you want it.

## Threat model

yayl parses untrusted input: the threat that shapes this library is a
config file or payload an adversary controls. The risks that matter are
resource exhaustion (a small input that explodes into large work) and
memory unsafety. The bounds below are the honest list of what limits
what, and where; every default is sized for a config file you control,
and every one is adjustable through the public API.

### Bounds

| Resource | Bound | Default | Where to change it |
| --- | --- | --- | --- |
| Input size (in-memory entry points) | `ParseOptions.max_input_bytes` | 64 MiB | `yaml.parseOpts` / `parseAllOpts` |
| Input size (files) | `max_bytes` parameter | 64 MiB via `yaml.file.max_bytes_default` | `yaml.file.parseFile` / `parseAllFile` / `readFile` |
| Nesting (scanner/parser) | `ParseOptions.max_nesting` | 200 | `yaml.parseOpts` |
| Simple key length | fixed cap | 1024 characters | not adjustable (spec 7.4.2) |
| Alias expansion (values) | `value.Limits.max_values` | 1,048,576 | `parseToValueLimited`, `nodeToValueLimited`, `Limits.unlimited` to opt out |
| Alias expansion (validation) | `schema.Limits.max_nodes` | 1,048,576 | `Schema.validateLimited` |
| Emission depth | `Emitter.max_depth` | 1000 | `writeOpts`/`writeAllOpts` (`EmitOptions.max_depth`) |
| Embedded NUL bytes | `ParseOptions.embedded_nul` | rejected (`.reject`) | `.truncate` restores the old lossy cut-off |

Two shapes motivate the expansion bounds: N levels each aliasing the
level above M times is M^N values — a 194-byte document reached ~19.5k
values — and a deep tree built programmatically (through
`createSequence`/`sequenceAppend` or `value.toNode`), which the scanner
never sees and `max_nesting` therefore never bounds. Where a bound
applies it returns a typed error (`error.LimitExceeded`,
`error.NestingTooDeep`) rather than growing without limit, and on that
failure path the caller gets an error, not a half-built result.

**Known gap: deep programmatic trees are depth-bounded only in the
emitter.** `Emitter.max_depth` bounds emission, but `value.nodeToValue`
and `Schema.validate` recurse over the node graph carrying only the
node-count budget above — there is no depth counter on either path. A
tree built programmatically past roughly 4,000 to 8,000 levels
overflows the native stack and aborts the process well before
`max_values` or `max_nodes` can fire, so on that path the caller does
not get a typed error at all. Parsed input cannot reach this:
`max_nesting` caps it at 200. Only a consumer that builds such a tree
itself can, and if you build trees from untrusted data you should bound
their depth yourself before converting or validating. A real depth
bound is tracked for a future release.

Parsing itself is bounded in memory: a `Document` is an arena over the
input plus its nodes, and emission writes into a caller-owned buffer.
All allocation failures surface as `error.OutOfMemory`, and the
allocation-failure test sweeps (unit suite) hold that no failure path
leaks.

### What is deliberately NOT done

These are documented gaps, not oversights, and both are relevant if you
consume parsed documents as data:

- **Duplicate mapping keys are kept.** YAML 1.2 requires unique keys;
  yayl keeps what the input contained. Lookups (`lookup`, `pathGet`,
  `value.get`) return the **first** match. If your security posture
  depends on rejecting duplicates, check for them yourself.
- **Merge keys (`<<`) are not resolved.** A `<<` key is an ordinary
  key carrying an alias or sequence; nothing is flattened into the
  mapping. Consumers that expect merge semantics must implement them.

### Memory safety

yayl is pure Zig with no third-party dependencies, no `unsafe`
constructs, no C interop, and no threads in the parsing path. Inputs
are decoded as UTF-8 strictly (invalid UTF-8 is `error.InvalidUtf8`),
and the scanner's bounds are fuzzed: a deterministic harness mutates
the test-suite corpus inside the unit suite (`src/fuzz.zig`), and a
longer manual target exists (`zig build fuzz`). Findings from fuzzing
that would change verified output are treated as security-relevant.
