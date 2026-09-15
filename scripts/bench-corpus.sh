#!/bin/sh
# Bench the hot paths (parse, write, round trip, edit+write) over the
# fixtures and — when vendored — a bounded slice of the yaml-test-suite
# corpus, printing one stable machine-readable line per measurement.
#
# Reports only: numbers on shared runners are too noisy for thresholds,
# so nothing here gates a build. Run locally for a fuller sweep:
#
#   sh scripts/bench-corpus.sh [extra bench args, e.g. 200]
set -eu

ITERS="${1:-20}"
BENCH="zig-out/bin/bench"

zig build bench -Doptimize=ReleaseFast

for f in tests/fixtures/*.yaml tests/fixtures/*.yml; do
    [ -f "$f" ] || continue
    "$BENCH" --machine "$f" "$ITERS" || echo "yayl_bench op=error file=$f"
done

if [ -d vendor/yaml-test-suite/src ]; then
    n=0
    # The corpus is a FLAT directory of <case>.yaml; the older
    # <case>/in.yaml layout is accepted too, in case the fetch script
    # changes. A glob that matches nothing must not report a clean zero.
    for f in vendor/yaml-test-suite/src/*/in.yaml vendor/yaml-test-suite/src/*.yaml; do
        [ -f "$f" ] || continue
        n=$((n + 1))
        [ "$n" -le 40 ] || break
        "$BENCH" --machine "$f" "$ITERS" || echo "yayl_bench op=error file=$f"
    done
    if [ "$n" -eq 0 ]; then
        echo "yayl_bench op=summary corpus_files=0 corpus_not_vendored=1"
    else
        echo "yayl_bench op=summary corpus_files=$n"
    fi
else
    echo "yayl_bench op=summary corpus_files=0 corpus_not_vendored=1"
fi
