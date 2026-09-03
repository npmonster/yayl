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
| Conversion depth | `value.Limits.max_depth` | 1000 | `parseToValueLimited`, `nodeToValueLimited` |
| Validation depth | `schema.Limits.max_depth` | 1000 | `Schema.validateLimited` |
| Edit walk depth (`..key`, clone) | `edit.max_walk_depth` | 1000 | not adjustable |
| Emission depth | `Emitter.max_depth` | 1000 | `writeOpts`/`writeAllOpts` (`EmitOptions.max_depth`) |
| Embedded NUL bytes | `ParseOptions.embedded_nul` | rejected (`.reject`) | `.truncate` restores the old lossy cut-off |

Two shapes motivate the expansion bounds: N levels each aliasing the
level above M times is M^N values — a 194-byte document reached ~19.5k
values — and a deep tree built programmatically (through
`createSequence`/`sequenceAppend` or `value.toNode`), which the scanner
never sees and `max_nesting` therefore never bounds. Every one of these
bounds returns a typed error (`error.LimitExceeded`,
`error.NestingTooDeep`) rather than growing without limit; on the
failure path the caller gets an error, not a half-built result.

Depth is bounded separately from size, on every recursive walk over the
node graph, and for a reason: a count of values or nodes cannot stand in
for a depth, because a linear chain of N nested collections is N values
but N stack frames. `value.Limits.max_depth`, `schema.Limits.max_depth`,
`edit.max_walk_depth` and `Emitter.max_depth` all default to 1000 and
all return `error.NestingTooDeep`.

They are close but not interchangeable, so do not treat one as a proxy
for another. Conversion, validation and the edit walks charge one level
per node on the path; the emitter charges up to two extra where
emission crosses between its faithful, normalized and flow modes, and
so admits two fewer levels. Measured on a linear built chain at default
limits: a 999-node path converts and validates but fails to emit; 1000
fails everywhere.

**Alias cycles.** An alias may name an *enclosing* anchor. `&a [*a]` is
eight bytes, is accepted by this parser as by libyaml, and describes a
structure of infinite depth: `resolveAlias` on the alias yields the
sequence that contains it. Nothing rejects that at parse time, and
`max_nesting` does not bound it — that cap is on syntactic nesting, not
on the alias graph. The depth bounds above are what stop the walk, and
they are the reason such input returns `error.NestingTooDeep` instead of
exhausting the stack. This applies to parsed input, not only to trees a
consumer builds.

Releases up to and including v0.14.0 did not have those bounds on the
conversion, validation or `..key` edit paths. On v0.14.0 the eight-byte
document above aborts the process through `value.nodeToValue`, and an
eleven-byte one (`&a {k: *a}`) aborts it through `Editor.all("$..key")`;
a tree built past roughly 4,000 to 8,000 levels did the same. Each is a
crash, not a typed error. All of those paths are bounded now, with
regression tests that fail if a bound is removed. If you consume
untrusted YAML with an affected release, upgrade.

`Limits.unlimited` lifts the depth bound along with the size one, which
re-arms exactly that hazard. It is documented for input you produced
yourself; to lift only the size budget, set `max_values` (or
`max_nodes`) and leave `max_depth` at its default.

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

yayl is pure Zig with no third-party dependencies, no C interop, and no
threads in the parsing path. ("No `unsafe` constructs" used to appear
here; Zig has no such keyword, and the claim was not checkable. What is
true and checkable: nodes are arena-owned, callers never free pool
memory, and the pointer casts that do exist are within a single
allocation's provenance.) Inputs are decoded as UTF-8 strictly (invalid
UTF-8 is `error.InvalidUtf8`), and the scanner's bounds are fuzzed: a
deterministic harness mutates the test-suite corpus inside the unit
suite (`src/fuzz.zig`), and a longer manual target exists (`zig build
fuzz`). The harness drives the consuming surfaces too — conversion,
`Value`-to-node round trip, schema validation against nine schema
shapes, and path resolution plus a mutating edit batch — so a defect
reachable only through `value`, `schema` or `edit` is now in range. It
was not before 0.15.0, which is why several such defects survived to be
found by hand. Findings from fuzzing
that would change verified output are treated as security-relevant.
