// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Minimal C consumer for the zioshade C ABI.
//
// Demonstrates the full pipeline:
//   1. Compile a tiny GLSL fragment shader to SPIR-V via zioshade_compile.
//   2. Cross-compile the resulting SPIR-V to HLSL, MSL, and WGSL via the
//      matching zioshade_to_* helpers (GLSL is the input language, so it is
//      not round-tripped here).
//   3. Release every owned buffer via FREE_ALL_OWNED (the zioshade_free_*
//      helpers are NULL-safe no-ops, so one cleanup site serves every path).
//
// Doubles as the M7.3 CI smoke test: if this program runs to completion
// and exits 0 on Windows, Linux, and macOS, the C ABI surface is good.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "zioshade.h"

static const char* GLSL =
    "#version 450\n"
    "layout(location=0) out vec4 fragColor;\n"
    "void main() { fragColor = vec4(1.0, 0.5, 0.25, 1.0); }\n";

// Cap the HLSL preview at this many bytes so CI logs stay readable.
#define HLSL_PREVIEW_BYTES 200

// Release every buffer this example owns. The zioshade_free_* helpers are
// documented NULL-safe no-ops (include/zioshade.h), so this is safe on every
// error path -- the still-unallocated buffers are NULL. One cleanup site beats
// a growing free-list per error path (the leak-matrix a reviewer has to walk).
#define FREE_ALL_OWNED() do { \
    zioshade_free_str(hlsl); \
    zioshade_free_str(msl); \
    zioshade_free_str(wgsl); \
    zioshade_free_u32(spirv_words); \
} while (0)

int main(void) {
    // All owned buffers, pre-NULL so FREE_ALL_OWNED is safe from the start.
    uint32_t* spirv_words = NULL;
    size_t spirv_word_count = 0;
    char* hlsl = NULL; size_t hlsl_len = 0;
    char* msl = NULL;   size_t msl_len = 0;
    char* wgsl = NULL;  size_t wgsl_len = 0;

    // -----------------------------------------------------------------------
    // GLSL -> SPIR-V
    // -----------------------------------------------------------------------
    // Zero-initialise so future-added fields default to 0/NULL -- keeps this
    // example forward-compatible across minor ABI bumps.
    zioshade_compile_options_t opts = {0};
    opts.stage = ZIOSHADE_STAGE_FRAGMENT;
    opts.version = 450;
    opts.is_essl = 0;
    opts.spirv_version_packed = 15;  // SPIR-V 1.5, packed as major*10 + minor

    // Pass strlen(GLSL) rather than sizeof so we honour the "need not be
    // null-terminated" contract -- the impl copies and terminates internally.
    zioshade_status_t st = zioshade_compile(
        GLSL,
        strlen(GLSL),
        &opts,
        &spirv_words,
        &spirv_word_count);
    if (st != ZIOSHADE_OK) {
        const char* msg = zioshade_last_error_message();
        fprintf(stderr, "zioshade_compile failed (status=%d): %s\n",
                (int)st, msg ? msg : "(no message)");
        FREE_ALL_OWNED();
        return 1;
    }
    printf("compiled %zu SPIR-V words\n", spirv_word_count);

    // -----------------------------------------------------------------------
    // SPIR-V -> HLSL
    // -----------------------------------------------------------------------
    st = zioshade_to_hlsl(
        spirv_words,
        spirv_word_count,
        /*binding_shift=*/0,
        /*shader_model=*/60,
        /*entry_point=*/NULL,
        &hlsl,
        &hlsl_len);
    if (st != ZIOSHADE_OK) {
        const char* msg = zioshade_last_error_message();
        fprintf(stderr, "zioshade_to_hlsl failed (status=%d): %s\n",
                (int)st, msg ? msg : "(no message)");
        FREE_ALL_OWNED();
        return 2;
    }

    printf("cross-compiled to %zu bytes of HLSL\n", hlsl_len);

    int trunc = (hlsl_len > HLSL_PREVIEW_BYTES);
    int preview_bytes = trunc ? HLSL_PREVIEW_BYTES : (int)hlsl_len;
    printf("%.*s%s", preview_bytes, hlsl, trunc ? "...\n" : "");
    // Ensure there is a final newline whether or not we truncated.
    if (!trunc && (hlsl_len == 0 || hlsl[hlsl_len - 1] != '\n')) {
        printf("\n");
    }

    // -----------------------------------------------------------------------
    // SPIR-V -> MSL (Metal) and -> WGSL (WebGPU).
    //
    // The C ABI exposes all four backends; this example exercises HLSL (above),
    // MSL, and WGSL -- GLSL is the input language, so it is not round-tripped.
    // WGSL is the one spirv-cross has no backend for at all, a structural reason
    // to reach for zioshade from a WebGPU-facing C/C++ host.
    // -----------------------------------------------------------------------
    st = zioshade_to_msl(spirv_words, spirv_word_count, /*metal_version=*/21,
                         /*argument_buffers=*/0, /*entry_point=*/NULL, &msl, &msl_len);
    if (st != ZIOSHADE_OK) {
        const char* msg = zioshade_last_error_message();
        fprintf(stderr, "zioshade_to_msl failed (status=%d): %s\n",
                (int)st, msg ? msg : "(no message)");
        FREE_ALL_OWNED();
        return 3;
    }
    printf("cross-compiled to %zu bytes of MSL\n", msl_len);

    st = zioshade_to_wgsl(spirv_words, spirv_word_count, /*entry_point=*/NULL,
                          &wgsl, &wgsl_len);
    if (st != ZIOSHADE_OK) {
        const char* msg = zioshade_last_error_message();
        fprintf(stderr, "zioshade_to_wgsl failed (status=%d): %s\n",
                (int)st, msg ? msg : "(no message)");
        FREE_ALL_OWNED();
        return 4;
    }
    printf("cross-compiled to %zu bytes of WGSL\n", wgsl_len);

    // -----------------------------------------------------------------------
    // Release owned buffers, then a NULL-free smoke test (must be no-ops).
    // -----------------------------------------------------------------------
    FREE_ALL_OWNED();
    zioshade_free_str(NULL);
    zioshade_free_u32(NULL);

    return 0;
}
