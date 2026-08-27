#!/bin/sh
# Fetch the pinned YAML Test Suite corpus (see tests/README.md).
set -eu

PINNED_REV="da267a5c4782e7361e82889e76c0dc7df0e1e870"
DEST="vendor/yaml-test-suite"

if [ -d "$DEST/src" ]; then
    echo "corpus already present at $DEST"
    exit 0
fi

mkdir -p vendor
if command -v git >/dev/null 2>&1; then
    git clone --quiet https://github.com/yaml/yaml-test-suite "$DEST"
    git -C "$DEST" checkout --quiet "$PINNED_REV"
else
    echo "git is required to fetch the corpus" >&2
    exit 1
fi

echo "corpus fetched at $DEST ($PINNED_REV)"
