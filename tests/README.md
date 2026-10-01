# Corpus test harnesses

Pinned corpus: [yaml/yaml-test-suite](https://github.com/yaml/yaml-test-suite)
at revision `da267a5c4782e7361e82889e76c0dc7df0e1e870` (fetched by
`make corpus` into `vendor/yaml-test-suite`, which is gitignored).

License: MIT (c) 2016-2020 Ingy döt Net — see the corpus `License` file.

Run: `zig build conformance` (or `make conformance`). The harness
(`tests/conformance.zig`) parses every case with yayl and compares the
rendered event tree against the case's expected tree at capability
level; `fail: true` cases must be rejected. Results land in
`zig-out/conformance-report.json` as one record per case with
`id`, `name`, `status` (pass/fail/skip) and `reason`.

Skips live in the harness's `skips` table and always carry a reason and
a target card — nothing is skipped silently. That table is currently
empty: every record passes, the 46 unnamed sub-cases included, so
conformance is 397/397 with no skips.

## Round-trip gate

Run: `zig build roundtrip` (or `make roundtrip`). `tests/roundtrip.zig`
re-emits every corpus case and the `tests/fixtures` files, and requires
the output to equal the input byte for byte. Results land in
`zig-out/roundtrip-report.json`, one record per case.

This harness keeps its **own** `skips` table. Like the conformance one
it is currently empty: the four cases that lived here (`HWV9`, `8G76`,
`98YD`, `QT73` — streams containing no document at all) round trip since
the fix that gives a content-free stream a rootless document carrying
its bytes, so a fully commented-out file comes back whole. A skipped
case that starts passing fails the gate, so the table cannot outlive a
fix.

Quote round-trip numbers as `pass/total` from a fresh report — the
denominator includes the skips.

## Randomized edit differential

Run: `zig build randedit -- [seed] [iterations] [steps]` (or
`make randedit RANDEDIT_ARGS="seed iterations steps"`; the defaults,
1 2 4, are a smoke). `tests/randedit.zig` takes every valid corpus case
and every fixture, in five variants (as written, CRLF, CR, a byte order
mark, no final line break), and applies up to `steps` random steps
`iterations` times each: a direct node operation (anchor, tag, comments)
or an `Editor` batch of one to three edits, on a random document of the
stream. After every step the stream must write, parse back with the same
document count, read back as the tree in memory (kinds, anchors, tags,
scalar values and the core type each resolves to, alias names), and
reproduce itself when parsed and written again. A batch made to fail must
leave the output byte-identical; a set to an identical scalar must change
no byte; every allocation goes through a 256 MB cap that must be back at
0 when the run ends.

It exits 1 on any finding and prints the first 40 in full (seed,
iteration, case, variant, the ops and the bytes), so a finding
reproduces from its line. It also prints a hash of every stream written:
two builds that must write the same bytes, a refactor, print the same
hash for the same arguments. CI runs seed 1 at 20 iterations,
report-only while it soaks; a release review runs ~60 iterations a seed
over several seeds.
