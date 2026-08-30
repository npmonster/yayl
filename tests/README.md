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
empty, so conformance is 351/351 with no skips.

## Round-trip gate

Run: `zig build roundtrip` (or `make roundtrip`). `tests/roundtrip.zig`
re-emits every corpus case and the `tests/fixtures` files, and requires
the output to equal the input byte for byte. Results land in
`zig-out/roundtrip-report.json`, one record per case.

This harness keeps its **own** `skips` table, and unlike the conformance
one it is not empty: four cases (`HWV9`, `8G76`, `98YD`, `QT73`) are
streams containing no document at all, so there is nothing to re-emit.
libfyaml produces no output for them either. A skipped case that starts
passing fails the gate, so the table cannot outlive a fix.

Quote round-trip numbers as `pass/total` from a fresh report — the
denominator includes the skips.
