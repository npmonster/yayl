#!/bin/sh
# libyaml independently reads output from edits, including preserved gap lines.
set -eu
cd "$(dirname "$0")/.."
ZIG=$(sh scripts/zig-path.sh)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists yaml-0.1; then
    echo "libyaml compatibility gate requires libyaml development headers and pkg-config." >&2
    echo "Install libyaml-dev (Linux) or libyaml (Homebrew)." >&2
    exit 1
fi
${CC:-cc} -Wall -Wextra -Werror $(pkg-config --cflags yaml-0.1) \
    tests/libyaml_compat.c -o "$work/check" $(pkg-config --libs yaml-0.1)
"$ZIG" build libyaml-compat -- "$work"
"$work/check" "$work"/*.yaml
