# Independent review prompt: yayl production hardening

Use this document as the complete assignment for an independent reviewer.
Do your own source inspection and execution; do not treat the author's report
or the supplied earlier transcript as proof.

## Objective

Decide whether the proposed changes safely address the production concerns
identified after yayl 0.20.1. Find concrete defects, missing regression coverage,
misleading gate results, or behavior changes beyond the user's authorization.
Give a release recommendation supported by reproducible evidence.

Repository: https://github.com/npmonster/yayl
Local workspace: /Users/gilberto/Projects/yayl
Baseline: v0.20.1, commit 6edb6046a16aaecda16b3cf270f8eb6b9c40c01e
Review branch: fix/production-hardening
Compare the baseline with the current branch head; record the exact head SHA
your review covers. Check any later commits before approving release.

Read AGENTS.md first. In this workspace, operate through Plumb and call
session_start with your own stable conversation identity. Inspect active
sessions and claims. Use an isolated checkout for destructive probes and
negative controls. Do not overwrite another session's files, merge, tag or publish as part of
this review.

## User-authorized behavior

The user chose to normalize affected whitespace after edits by default:

- Replace each leading tab in adjacent blank lines with one space.
- Also replace leading tabs before adjacent comments with spaces.
- Keep comment text exact.
- Preserve line endings, unrelated source gaps and entire documents that have
  not been edited.
- Do not normalize scalar content tabs or indentation throughout the file.

This addresses a libyaml 0.2.5 interoperability problem: quoting a replacement
value alone still leaves some following tab-containing blank/comment lines
unreadable by libyaml. YAML validity and libyaml acceptance are separate
questions. Use the YAML 1.2.2 grammar when parser opinions disagree:
https://yaml.org/spec/1.2.2/

## Changes to inspect

1. **Emitter:** src/emitter.zig records source offsets of affected tabs during
   edited-node placement. A shared source-copy routine replaces only those
   offsets. State is cleared per emitted document and released in deinit.
   src/document.zig carries affected separator offsets only between contiguous
   regions sharing one source, because a separator may be stored in the next
   document's head. Check that independently parsed sources cannot cause
   offset collisions to rewrite scalar content.
   src/edit.zig tests exact bytes, unchanged documents, unrelated gaps,
   repeated writes and allocation failures.

2. **Independent oracle:** tests/libyaml_compat.zig generates edited YAML.
   tests/libyaml_compat.c parses the entire stream with independently installed
   libyaml and checks document count and the edited scalar's bytes.
   scripts/libyaml-compat.sh builds/runs both. The build.zig step generates
   fixtures; the make target also runs the independent reader.

3. **Reference build:** scripts/libfyaml-build.sh supplies the pinned source
   revision as VERSION, shares the three C build recipes, and uses -Werror.
   Check that the shared stubs preserve the previously exercised reference
   paths and that warnings are fixed without disabling warning categories.

4. **Compiler selection:** scripts/zig-path.sh selects exactly Zig 0.16.0 from
   an explicit ZIG, PATH, or an already installed zvm toolchain. Make and gate
   scripts use it. It must fail clearly for an explicit incompatible compiler.
   It must not download a compiler or alter global shell configuration.

5. **Mutation evidence:** scripts/mutation-smoke.py rechecks 16 named boundary
   and cleanup regressions in temporary source copies. Each baseline must run
   and pass its selected test. Each mutant must compile successfully and fail
   that test. Compile errors, timeouts, memory limits and missing test execution
   fail the gate separately. It records source hashes, exit codes, sampled
   aggregate process-tree RSS, runtimes and logs.

6. **CI:** emission-oracle and randedit lose continue-on-error. New libyaml and
   mutation jobs are blocking. Benchmarks remain informational. The aggregate
   Quality gates job requires success from every correctness job, and fails
   when any dependency fails or is skipped/cancelled. Check actual job/step
   conclusions on the exact reviewed commit and the server-side required-check
   policy for main; a red workflow alone is not enforced branch protection.

7. **Claims:** README, USAGE, CONTRIBUTING, AGENTS and CHANGELOG document the
   whitespace exception, exact tested compiler, dependencies and gate scope.
   Historical mutation survivors are described as unobserved to differ on
   sampled inputs, never formally equivalent.

## Setup and reproduction

Use Zig 0.16.0, Python 3, a C compiler, pkg-config and libyaml headers.
On macOS: brew install libyaml pkg-config
On Debian/Ubuntu: apt-get install libyaml-dev pkg-config

Project commands select the installed supported compiler. To be explicit:

```sh
export ZIG=/absolute/path/to/zig-0.16.0
"$ZIG" version
make verify
make randedit RANDEDIT_ARGS="26006 20 4"
make randedit RANDEDIT_ARGS="941013 20 4"
```

Run the full gate in a fresh checkout so stale binaries or vendor/cache state
cannot hide missing dependencies. Record exit status as well as output.
The pinned corpora are fetched by the make prerequisites.

Expected gate structure (remeasure the counts):

- Unit tests in Debug and ReleaseSafe, with zero leaks.
- Conformance: 397 records, no skips/failures.
- Unchanged round trips: 303 records, no skips/failures.
- Edit preservation over fixtures and valid corpus cases.
- Event differential: 269 comparable records, zero mismatches.
- Resolved merge differential: eight comparisons, zero mismatches.
- Emission oracle: 816 emitted documents over three paths, zero findings.
- Random edits: seed 1, 20 iterations, four steps; 31,700 runs, zero findings.
- Independent libyaml: 960 edited streams, half via write and half via writeAll;
  exact edited values and one/two documents as appropriate.
- Targeted mutations: 16 killed, no invalid/resource/infrastructure outcomes.

Inspect zig-out/mutation-smoke/report.json and every relevant compile/test log.
Ensure the selected test actually ran. The memory limit is monitored using
sampled process-tree RSS; do not describe this as a formal hard upper bound or
use it to attribute unrelated system-wide memory changes.

## Required focused checks

### Byte preservation and interoperability

Probe LF, CRLF and CR; BOM/no BOM; zero/one/several spaces before a tab;
several tabs; empty/comment lines at EOF; comments containing tabs in their
text; mapping/sequence/root replacements; nested collections; aliases;
flow collections; explicit keys; document markers; tombstones from deletion;
new/moved values; single-document and writeAll paths.

Check that a no-op edit remains byte-identical. Check that normalization stops
at the next content line or document marker and does not corrupt
multiline scalar contents, or rewrite gaps adjacent only to unchanged values.
Verify values with an independent reader, rather than only yayl reading itself.
Any uncovered shape warrants a concrete regression test or an explicit finding.

### Previously fixed production bugs

Independently recheck the v0.20.1 regressions: null-valued roots retain document
identity; direct removal of a parsed root removes its old bytes; empty-document
root edits keep final line breaks, including CR; property-only values at EOF
and block scalar bounds do not panic; trailing comments are emitted once.
Distinguish a null-valued root from a removed root in both code and expectations.
Recheck tab indentation rejection/acceptance against the spec, not majority
parser voting.

### Negative controls and allocation failure

In a disposable source copy, remove the tab replacement and confirm both the
regression and independent libyaml oracle detect it. Restore your disposable
copy afterward. The original author observed this regression red before
applying the fix; reproduce it yourself.

Review the three errdefer mutations and their allocation-failure tests.
Ensure deleted cleanup really causes a leak detected by the test, rather than
an unrelated compilation failure.

Verify mutation classification does not count compilation failures, missing
test runs, timeout kills, memory aborts or absent trace output as equivalence.
Review the runner's classification checks and exercise additional failure
paths if you see ambiguity.

### CI and packaging

Inspect the workflow configuration and live CI for the reviewed SHA. Confirm
the independent jobs are not report-only, skipped or vacuous. Inspect their
step conclusions, logs and artifacts. Confirm the packaged consumer still
builds when .paths in build.zig.zon is applied; development-only libyaml/Python
dependencies must not become runtime dependencies for library consumers.

Do not infer that passing PR CI means main or the published release contains
the fix. Separately record main HEAD, release tag/commit, open PRs and the
actual version in the production consumer, if available.

## Evidence and limits

The earlier 449-mutant campaign's full scratch artifacts were removed before
this work. The new persistent gate covers 16 specified regressions; it is not
a rerun or proof of equivalence for every historical survivor. Finite random
tests cannot establish that the whole library is bug-free.

Do not repeat historical credit use, background-process cleanup or free-memory
attribution as verified facts from repository state. Operational claims need
independent evidence and are separate from library correctness.

## Deliverable

Return:

1. Reviewed base/head SHAs, compiler/parser versions, commands and exit status.
2. Findings ordered by severity, with file:line, minimal reproducer, expected
   versus actual output, production impact and a proposed smallest correction.
3. A table of each acceptance requirement: pass, fail, or not verified, with
   the evidence that supports it.
4. Coverage gaps and remaining uncertainty, stated precisely.
5. A release recommendation: approve, approve with named conditions, or block.

If you find no defects, say exactly what you inspected and executed. Do not
convert passing finite tests into a universal correctness claim.
