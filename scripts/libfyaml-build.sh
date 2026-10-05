#!/bin/sh
# One pin and one warning-free build recipe for the development reference.
# Source this file from a script running at the repository root.
LIBFYAML_REV="04e0b58135c2e1a9264e1c4b915a6c8e750aa923"

build_libfyaml_reference() {
    fy_output=$1
    fy_main=$2
    fy_stub="${fy_output}_stub.c"
    # These generated backends are outside the parser/document paths.
    cat > "$fy_stub" <<'EOF'
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
    # VERSION is normally supplied by libfyaml's configure step. This
    # direct build uses the pinned source revision as its version instead.
    # CC retains the conventional ability to name a compiler plus flags.
    ${CC:-cc} -Werror -D_GNU_SOURCE "-DVERSION=\"$LIBFYAML_REV\"" \
        -I"$VENDOR/include" -I"$VENDOR/src/lib" -I"$VENDOR/src/util" \
        -I"$VENDOR/src/allocator" -I"$VENDOR/src/blake3" \
        -I"$VENDOR/src/xxhash" -I"$VENDOR/src/thread" \
        "$fy_main" "$fy_stub" "$VENDOR"/src/lib/*.c \
        "$VENDOR"/src/util/*.c "$VENDOR"/src/allocator/*.c "$VENDOR"/src/xxhash/*.c \
        "$VENDOR/src/blake3/fy-blake3.c" "$VENDOR/src/blake3/blake3_portable.c" \
        "$VENDOR/src/blake3/blake3_host_state.c" "$VENDOR/src/blake3/blake3_be_cpusimd.c" \
        "$VENDOR/src/blake3/blake3_backend.c" -o "$fy_output" -lm
}
