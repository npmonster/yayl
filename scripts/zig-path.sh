#!/bin/sh
# Print the compiler path used by project commands. An explicit ZIG wins;
# otherwise prefer PATH, then an already-installed pinned zvm toolchain.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
required=$(sed -n 's/^[[:space:]]*\.minimum_zig_version = "\([^"]*\)".*/\1/p' "$root/build.zig.zon")

matches() {
    [ -x "$1" ] && [ "$("$1" version 2>/dev/null)" = "$required" ]
}

if [ -n "${ZIG:-}" ]; then
    candidate=$(command -v "$ZIG" 2>/dev/null || true)
    if [ -n "$candidate" ] && matches "$candidate"; then
        printf '%s\n' "$candidate"
        exit 0
    fi
    echo "yayl requires Zig $required; ZIG=$ZIG does not select that version." >&2
    exit 1
fi

candidate=$(command -v zig 2>/dev/null || true)
if [ -n "$candidate" ] && matches "$candidate"; then
    printf '%s\n' "$candidate"
    exit 0
fi
for candidate in "${HOME}/.zvm/$required/zig" "${HOME}/.zvm/bin/zig"; do
    if matches "$candidate"; then
        printf '%s\n' "$candidate"
        exit 0
    fi
done
echo "yayl requires Zig $required. Install it and set ZIG=/absolute/path/to/zig." >&2
exit 1
