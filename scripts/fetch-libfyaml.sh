#!/bin/sh
# Fetch the pinned libfyaml reference used by the differential gate.
#
# libfyaml is the specification yayl is tested against: scripts/differential.sh
# compiles this checkout with the system C compiler and compares its event
# stream against ours over the whole corpus. It is a development-time
# reference only -- yayl neither links nor embeds it, and nothing here ships
# in the package (see `.paths` in build.zig.zon).
set -eu

PINNED_REV="04e0b58135c2e1a9264e1c4b915a6c8e750aa923"
DEST="vendor/libfyaml"

if [ -d "$DEST/src/lib" ]; then
    echo "libfyaml already present at $DEST"
    exit 0
fi

if ! command -v git >/dev/null 2>&1; then
    echo "git is required to fetch libfyaml" >&2
    exit 1
fi

mkdir -p vendor
git clone --quiet --filter=blob:none https://github.com/pantoniou/libfyaml "$DEST"
git -C "$DEST" checkout --quiet "$PINNED_REV"

echo "libfyaml fetched at $DEST ($PINNED_REV)"
