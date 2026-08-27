# Conformance testing

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
a target card — nothing is skipped silently.
