#!/bin/sh
# Emission oracle: an INDEPENDENT parser checks what yayl produces.
#
# The round-trip and preservation gates check yayl's output with yayl's
# own parser, which shares its author's spec misreadings with the
# emitter. This script instead asserts that LIBFYAML — the C reference
# this library was converted from — can parse every document yayl
# emits, over the yaml-test-suite corpus and the real-world fixtures.
# It checks parseability only, not semantics: a byte-faithful emitter's
# output is not supposed to match libfyaml's, it is supposed to PARSE.
#
# Requires: a C compiler ($CC, default cc) and `make corpus`.
# Exit 0 when every emitted document parses; 1 on any finding.
set -eu

cd "$(dirname "$0")/.."
CC=${CC:-cc}
VENDOR=vendor/libfyaml
WORK=zig-out/emission-oracle

# --- build the libfyaml accept-check tool --------------------------------
mkdir -p "$WORK"
cat > "$WORK/fycheck_main.c" <<'EOF'
/* Acceptance check: exit 0 iff libfyaml parses the file as YAML. */
#include <stdio.h>
#include <stdlib.h>
#include "libfyaml.h"

int main(int argc, char **argv)
{
    if (argc < 2) return 2;
    FILE *f = fopen(argv[1], "rb");
    if (!f) return 2;
    static char buf[1 << 20];
    size_t n = fread(buf, 1, sizeof buf, f);
    fclose(f);

    /* yayl deliberately keeps duplicate mapping keys (documented); the
     * oracle checks PARSEABILITY, not libfyaml's strictness policy. */
    static const struct fy_parse_cfg cfg = { .flags = FYPCF_ALLOW_DUPLICATE_KEYS };
    struct fy_document *fyd = fy_document_build_from_string(&cfg, buf, n);
    if (!fyd) return 1;
    fy_document_destroy(fyd);
    return 0;
}
EOF

if [ ! -x "$WORK/fycheck" ] || [ "$WORK/fycheck_main.c" -nt "$WORK/fycheck" ]; then
    INC="-I$VENDOR/include -I$VENDOR/src/lib -I$VENDOR/src/util -I$VENDOR/src/allocator -I$VENDOR/src/blake3 -I$VENDOR/src/xxhash -I$VENDOR/src/thread"
    SRC="$VENDOR/src/lib/*.c $VENDOR/src/util/*.c $VENDOR/src/allocator/*.c $VENDOR/src/xxhash/*.c"
    SRC="$SRC $VENDOR/src/blake3/fy-blake3.c $VENDOR/src/blake3/blake3_portable.c $VENDOR/src/blake3/blake3_host_state.c $VENDOR/src/blake3/blake3_be_cpusimd.c $VENDOR/src/blake3/blake3_backend.c"
    # Stub the threading/hash backends the parser path never calls (see
    # scripts/differential.sh for the full explanation).
    cat > "$WORK/fycheck_stub.c" <<'EOF'
#include <stddef.h>
void *fy_thread_pool_create(void *a, size_t n) { (void)a; (void)n; return NULL; }
void fy_thread_pool_destroy(void *p) { (void)p; }
int fy_thread_pool_get_num_threads(void *p) { (void)p; return 1; }
char *fy_thread_arg_array_join(void **arr, size_t n, const char *fmt) { (void)arr; (void)n; (void)fmt; return NULL; }
void fy_thread_arg_array_free(void **arr, size_t n) { (void)arr; (void)n; }
struct blake3_hasher_ops { void (*f[8])(void); };
const struct blake3_hasher_ops blake3_hasher_op_portable;
const struct blake3_hasher_ops blake3_hasher_op_cpusimd;
EOF
    $CC $INC -D_GNU_SOURCE "$WORK/fycheck_main.c" "$WORK/fycheck_stub.c" $SRC -o "$WORK/fycheck" -lm \
        || { echo "emission-oracle: FAILED to build libfyaml checker" >&2; exit 1; }
fi

# --- build the yayl emit tool --------------------------------------------
zig build emit

# --- sweep the corpus and the fixtures -----------------------------------
python3 - "$WORK" <<'EOF'
import os, subprocess, sys, re

work = sys.argv[1]
src = "vendor/yaml-test-suite/src"
emit = "zig-out/bin/emit"
fycheck = os.path.join(work, "fycheck")

MARKERS = {
    "␣": " ", "—": "", "»": "\t", "↵": None, "←": "\r",
    "⇔": "﻿", "∎": None,
}

def decode(text: str) -> str:
    out = []
    i = 0
    while i < len(text):
        c = text[i]
        if c == "∎":
            break
        if c == "␣":
            out.append(" "); i += 1
        elif c == "↵":
            i += 1
        elif c == "←":
            out.append("\r"); i += 1
        elif c == "⇔":
            out.append("﻿"); i += 1
        elif c == "—":
            j = i
            while j < len(text) and text[j] == "—":
                j += 1
            if j < len(text) and text[j] == "»":
                out.append("\t"); i = j + 1
            else:
                out.append(c); i += 1
        elif c == "»":
            out.append("\t"); i += 1
        else:
            out.append(c); i += 1
    return "".join(out)

checked = rejected = findings = no_document = 0

def has_document_content(text: str) -> bool:
    """False for streams made only of blank lines, comments and
    document markers (--- / ...): yayl deliberately preserves such
    streams verbatim (0.16.0), and libfyaml rejects them as having no
    document — a stream-boundary convention, not an emission defect.
    A marker line carrying content (--- foo) counts as content."""
    for raw in text.split("\n"):
        line = raw.rstrip("\r")
        t = line.strip(" \t")
        if t == "" or t.startswith("#"):
            continue
        if t == "---" or t == "...":
            continue
        if t.startswith("--- ") or t.startswith("... "):
            # Content on the marker line is still content.
            rest = t[4:].strip(" \t")
            if rest.startswith("#") or rest == "":
                continue
        return True
    return False

def oracle(path: str, label: str) -> None:
    global checked, rejected, findings, no_document
    tmp = os.path.join(work, "emitted.yaml")
    r = subprocess.run([emit, path, tmp], capture_output=True, text=True)
    if r.returncode != 0:
        rejected += 1
        return  # yayl rejected its own input: nothing emitted to check
    emitted = open(tmp, encoding="utf-8").read()
    if not has_document_content(emitted):
        # libfyaml rejects streams without a document; yayl deliberately
        # preserves them (comments are never eaten). Nothing to check.
        no_document += 1
        return
    c = subprocess.run([fycheck, tmp], capture_output=True, text=True)
    checked += 1
    if c.returncode != 0:
        findings += 1
        print(f"ORACLE-FAIL {label}: libfyaml cannot parse yayl's output")
        print("--- emitted ---")
        print(emitted)
        print("--- libfyaml stderr ---")
        print(c.stderr)

# Fixtures: plain files.
for d in ("tests/fixtures",):
    for name in sorted(os.listdir(d)):
        if name.endswith((".yaml", ".yml")):
            oracle(os.path.join(d, name), f"fixture:{name}")

# Corpus: the suite's own yaml payloads, decoded like the other gates.
ids = sorted(d[:-5] for d in os.listdir(src) if d.endswith(".yaml"))
for cid in ids:
    text = open(os.path.join(src, cid + ".yaml"), encoding="utf-8").read()
    if "\n  fail: true" in text:
        continue  # the suite itself says this input is invalid
    m = re.findall(r"\n  yaml: \|([^\n]*?)\n(.*?)\n  [a-z]+:", text, re.S)
    if not m:
        continue
    body = "\n".join(l[4:] if l.startswith("    ") else l for l in m[0][1].split("\n"))
    decoded = decode(body)
    if decoded and not decoded.endswith("\n"):
        decoded += "\n"
    tmp = os.path.join(work, "case-src.yaml")
    open(tmp, "w", encoding="utf-8").write(decoded)
    oracle(tmp, f"corpus:{cid}")

print(f"emission-oracle: {checked} emitted documents checked, {findings} findings, {rejected} inputs yayl rejected, {no_document} streams without a document")
if findings:
    sys.exit(1)
EOF
