// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Minimal C consumer for the glslpp C ABI.
//
// Demonstrates the full pipeline:
//   1. Compile a tiny GLSL fragment shader to SPIR-V via glslpp_compile.
//   2. Cross-compile the resulting SPIR-V to HLSL via glslpp_to_hlsl.
//   3. Release both buffers via the matching glslpp_free_* helpers.
//
// Doubles as the M7.3 CI smoke test: if this program runs to completion
// and exits 0 on Windows, Linux, and macOS, the C ABI surface is good.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "glslpp.h"

static const char* GLSL =
    "#version 450\n"
    "layout(location=0) out vec4 fragColor;\n"
    "void main() { fragColor = vec4(1.0, 0.5, 0.25, 1.0); }\n";

// Cap the HLSL preview at this many bytes so CI logs stay readable.
#define HLSL_PREVIEW_BYTES 200

int main(void) {
    // -----------------------------------------------------------------------
    // GLSL -> SPIR-V
    // -----------------------------------------------------------------------
    glslpp_compile_options_t opts;
    opts.stage = GLSLPP_STAGE_FRAGMENT;
    opts.version = 450;
    opts.is_essl = 0;
    opts.spirv_version_packed = 15;

    uint32_t* spirv_words = NULL;
    size_t spirv_word_count = 0;

    // Pass strlen(GLSL) rather than sizeof so we honour the "need not be
    // null-terminated" contract — the impl copies and terminates internally.
    glslpp_status_t st = glslpp_compile(
        GLSL,
        strlen(GLSL),
        &opts,
        &spirv_words,
        &spirv_word_count);
    if (st != GLSLPP_OK) {
        const char* msg = glslpp_last_error_message();
        fprintf(stderr, "glslpp_compile failed (status=%d): %s\n",
                (int)st, msg ? msg : "(no message)");
        return 1;
    }
    printf("compiled %zu SPIR-V words\n", spirv_word_count);

    // -----------------------------------------------------------------------
    // SPIR-V -> HLSL
    // -----------------------------------------------------------------------
    char* hlsl = NULL;
    size_t hlsl_len = 0;

    st = glslpp_to_hlsl(
        spirv_words,
        spirv_word_count,
        /*binding_shift=*/0,
        /*shader_model=*/60,
        /*entry_point=*/NULL,
        &hlsl,
        &hlsl_len);
    if (st != GLSLPP_OK) {
        const char* msg = glslpp_last_error_message();
        fprintf(stderr, "glslpp_to_hlsl failed (status=%d): %s\n",
                (int)st, msg ? msg : "(no message)");
        glslpp_free_u32(spirv_words);
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
    // Release owned buffers.
    // -----------------------------------------------------------------------
    glslpp_free_str(hlsl);
    glslpp_free_u32(spirv_words);

    // NULL-free smoke test: must be a no-op, not a crash.
    glslpp_free_str(NULL);
    glslpp_free_u32(NULL);

    return 0;
}
