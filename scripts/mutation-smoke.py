#!/usr/bin/env python3
"""Recheck selected production regressions, not the whole historical campaign.

Compile failures, timeouts and resource limits fail the gate; none count as a
killed or equivalent mutation. Each baseline must actually run its named test.
The source tree is copied into a temporary directory and never edited in place.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
REPORT = ROOT / "zig-out" / "mutation-smoke"
LIMIT_MB = 3072
TIMEOUT = 180
MUTANTS = [
    ("null-root-cr-bound", "document.zig", "k + 1 < body.items.len",
     "k + 1 <= body.items.len", "a document whose root is null is still a document"),
    ("empty-root-newline", "emitter.zig", "if (stop <= doc.region_end)",
     "if (stop < doc.region_end)", "a root set in an empty document keeps the file's final line break"),
    ("mapping-tail-bound", "emitter.zig", "stop >= le and value.pending_trailing",
     "stop > le and value.pending_trailing", "a collection re-emitted at the end of a file with no final line break writes its tail once"),
    ("sequence-tail-bound", "emitter.zig", "stop >= le and item.pending_trailing",
     "stop > le and item.pending_trailing", "a collection re-emitted at the end of a file with no final line break writes its tail once"),
    ("indentless-step", "emitter.zig", "child_col > key_col",
     "child_col >= key_col", "the indent step is not measured from an indentless sequence"),
    ("block-header-bound", "emitter.zig", "h >= s.end or (src[h]",
     "h > s.end or (src[h]", "a re-emitted block scalar keeps the column of its first content line"),
    ("block-properties-bound", "emitter.zig", "while (h < s.end and (src[h]",
     "while (h <= s.end and (src[h]", "a re-emitted block scalar keeps the column of its first content line"),
    ("block-content-indent", "emitter.zig", "if (body.len > 0) return line.len - body.len;",
     "if (body.len >= 0) return line.len - body.len;", "a re-emitted block scalar keeps the column of its first content line"),
    ("non-ascii-quote", "emitter.zig", "c < 0x80 and !ctype.isPrintableAscii(c)",
     "c <= 0x80 and !ctype.isPrintableAscii(c)", "single quotes stay for text past ASCII"),
    ("tab-normalization", "emitter.zig", "c == '\\t' and self.normalized_tabs.contains(at)",
     "c == 0x0b and self.normalized_tabs.contains(at)", "edited values normalize only adjacent tab-only lines"),
    ("flow-root-placement", "emitter.zig",
     "if (internal.inlineValue(node)) try self.placeBlock(node, s.end);",
     "if (false) try self.placeBlock(node, s.end);", "an edited flow root normalizes its tab gap"),
    ("stream-tab-source", "document.zig",
     "doc.shared_source == docs[i - 1].shared_source",
     "true", "tab normalization offsets do not carry into separately parsed documents"),
    ("stream-tab-cleanup", "document.zig",
     "defer preceding_tabs.deinit(allocator);",
     "", "allocation failures normalizing tab-only lines leak nothing"),
    ("array-conversion-cleanup", "value.zig",
     "errdefer for (out[0..filled]) |item| deinitZig(arr.child, allocator, item);\n                for (items,",
     "for (items,", "a fixed array conversion that fails part way frees what it converted"),
    ("array-default-cleanup", "value.zig",
     "errdefer for (out[0..filled]) |item| deinitZig(arr.child, allocator, item);\n            for (value,",
     "for (value,", "allocation failures cloning an array default leak nothing"),
    ("schema-budget-cleanup", "schema.zig",
     "errdefer allocator.free(p);\n    try b.chargeBytes(p.len);",
     "try b.chargeBytes(p.len);", "running out of the byte budget at any point leaks nothing"),
]


def tree_rss(pid):
    """Sum live descendants as well as the direct build/test process."""
    snapshot = subprocess.run(["ps", "-axo", "pid=,ppid=,rss="],
                              capture_output=True, text=True, check=True)
    rows = [tuple(map(int, line.split())) for line in snapshot.stdout.splitlines()]
    descendants = {pid}
    while True:
        added = {child for child, parent, _ in rows if parent in descendants}
        before = len(descendants)
        descendants.update(added)
        if len(descendants) == before:
            return sum(rss for child, _, rss in rows if child in descendants)


def bounded_run(command, directory, log):
    start = time.monotonic()
    peak_kb = 0
    outcome = "exited"
    with log.open("w") as output:
        process = subprocess.Popen(command, cwd=directory, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            while process.poll() is None:
                peak_kb = max(peak_kb, tree_rss(process.pid))
                if peak_kb > LIMIT_MB * 1024:
                    outcome = "memory-limit"
                    break
                if time.monotonic() - start > TIMEOUT:
                    outcome = "timeout"
                    break
                time.sleep(0.1)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
    return {"outcome": outcome, "exit_code": process.returncode,
            "peak_tree_mb": round(peak_kb / 1024, 1),
            "seconds": round(time.monotonic() - start, 2), "log": log.name}


def passed(result):
    return result["outcome"] == "exited" and result["exit_code"] == 0


def classification(compile_result, run_result, selected_test_seen):
    if not passed(compile_result):
        return "compile-or-infrastructure-failure"
    if run_result["outcome"] != "exited":
        return "resource-or-infrastructure-failure"
    if not selected_test_seen:
        return "test-not-executed"
    return "survived" if passed(run_result) else "killed"


def self_check():
    ok = {"outcome": "exited", "exit_code": 0}
    failed = {"outcome": "exited", "exit_code": 1}
    timed_out = {"outcome": "timeout", "exit_code": -9}
    assert classification(ok, failed, True) == "killed"
    assert classification(ok, ok, True) == "survived"
    assert classification(failed, failed, True) == "compile-or-infrastructure-failure"
    assert classification(ok, timed_out, True) == "resource-or-infrastructure-failure"
    assert classification(ok, failed, False) == "test-not-executed"


def main():
    self_check()
    zig = subprocess.check_output(["sh", "scripts/zig-path.sh"], cwd=ROOT,
                                  text=True).strip()
    REPORT.mkdir(parents=True, exist_ok=True)
    report = {"scope": "16 selected regressions; no general equivalence claim",
              "zig": subprocess.check_output([zig, "version"], text=True).strip(),
              "memory_limit_tree_mb": LIMIT_MB, "command_timeout_seconds": TIMEOUT,
              "mutations": []}
    sources = {name: (ROOT / "src" / name).read_text()
               for name in {m[1] for m in MUTANTS}}
    report["source_sha256"] = {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted((ROOT / "src").glob("*.zig"))
    }
    report["runner_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    try:
        with tempfile.TemporaryDirectory(prefix="yayl-mutations-") as temp:
            tree = Path(temp)
            shutil.copytree(ROOT / "src", tree / "src")
            shutil.copy2(ROOT / "build.zig.zon", tree / "build.zig.zon")
            for name, file, old, new, test in MUTANTS:
                entry = {"name": name, "file": file, "test": test, "old": old, "new": new}
                report["mutations"].append(entry)
                if sources[file].count(old) != 1:
                    entry["status"] = "stale-mutation"
                    raise RuntimeError(f"{name}: mutation anchor must match exactly once")
                binary = tree / "test-bin"
                command = [zig, "test", "src/yaml.zig", "--test-filter", test,
                           "--test-no-exec", f"-femit-bin={binary}"]
                for phase in ("baseline", "mutant"):
                    (tree / "src" / file).write_text(
                        sources[file] if phase == "baseline" else sources[file].replace(old, new))
                    compiled = bounded_run(command, tree, REPORT / f"{name}-{phase}-compile.log")
                    entry[phase + "_compile"] = compiled
                    if not passed(compiled):
                        entry["status"] = "compile-or-infrastructure-failure"
                        raise RuntimeError(f"{name}: {phase} did not compile cleanly")
                    log = REPORT / f"{name}-{phase}-test.log"
                    ran = bounded_run([str(binary)], tree, log)
                    entry[phase + "_test"] = ran
                    seen = test in log.read_text()
                    if phase == "baseline":
                        if not passed(ran) or not seen:
                            entry["status"] = "baseline-failure"
                            raise RuntimeError(f"{name}: baseline must run and pass its selected test")
                    else:
                        entry["status"] = classification(compiled, ran, seen)
                        if entry["status"] != "killed":
                            raise RuntimeError(f"{name}: {entry['status']}")
                (tree / "src" / file).write_text(sources[file])
                print(f"{name}: killed", flush=True)
    finally:
        (REPORT / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"mutation smoke: {len(report['mutations'])} selected mutations killed; logs in {REPORT}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"mutation smoke failed: {error}", file=sys.stderr)
        sys.exit(1)
