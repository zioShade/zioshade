// SPDX-License-Identifier: MIT OR Apache-2.0
//
// glslpp public C ABI header.
//
// This is the C-callable surface for glslpp — a GLSL -> SPIR-V compiler
// with cross-compilation backends to HLSL, GLSL, MSL, and WGSL. The Zig
// implementation lives in `src/`; this header is the stable contract for
// non-Zig consumers (C, C++, Rust via bindgen, Python via ctypes, etc.).
//
// Header-only for milestone M7.1 — the Zig export wrappers ship in M7.2,
// and a C consumer + CI integration ship in M7.3.
//
// Memory ownership rules
// ----------------------
// All `*_t* out_ptr` parameters that return heap buffers (`spirv_words`,
// `hlsl`, `glsl`, `msl`, `wgsl`) are populated by the callee. The caller
// owns the returned buffer and MUST release it via the matching freer:
//
//   uint32_t* words           -> glslpp_free_u32(words)
//   char*     {hlsl|glsl|...} -> glslpp_free_str(buf)
//
// Calling the C runtime `free()` directly on these pointers is UNDEFINED
// BEHAVIOR. The implementation uses a length-prefix layout (the visible
// pointer is offset from the underlying allocator block), so `free()`
// will see a bogus header. Always use the glslpp_free_* helpers.
//
// Thread-safety
// -------------
// Each call manages its own arena via a threadlocal allocator. Concurrent
// calls from different threads are safe. The `glslpp_last_error_*` getters
// read threadlocal state owned by the calling thread.

#ifndef GLSLPP_H
#define GLSLPP_H

/* Semantic version of the glslpp C ABI. Bump MAJOR on any ABI break.
 *
 * NOTE: This is the version of the C ABI surface defined by this header,
 * NOT the version of the glslpp library as a whole. The library version
 * lives in `build.zig.zon` and evolves independently. The C ABI starts at
 * 0.1.0 and only bumps when the structural shape of this header changes
 * (new/removed/reordered functions, struct field layout changes, enum
 * value renumbering, etc.) — not on every library release. Do NOT try to
 * sync these to the library version automatically.
 */
#define GLSLPP_VERSION_MAJOR 0
#define GLSLPP_VERSION_MINOR 1
#define GLSLPP_VERSION_PATCH 0

/* Export-visibility macro for public function declarations.
 *
 * Consumers building against a shared glslpp library should define
 * `GLSLPP_USE_SHARED` before including this header on Windows so the
 * declarations resolve to `__declspec(dllimport)`. The glslpp build
 * itself defines `GLSLPP_BUILD_SHARED` when producing a shared library
 * so the same declarations become `__declspec(dllexport)`. On ELF
 * platforms with GCC/Clang, `GLSLPP_BUILD_SHARED` opts the symbols into
 * default visibility for `-fvisibility=hidden` builds. In all other
 * cases (static linking, unknown compiler) `GLSLPP_API` expands to
 * nothing.
 */
#if defined(_WIN32) || defined(__CYGWIN__)
  #if defined(GLSLPP_BUILD_SHARED)
    #define GLSLPP_API __declspec(dllexport)
  #elif defined(GLSLPP_USE_SHARED)
    #define GLSLPP_API __declspec(dllimport)
  #else
    #define GLSLPP_API
  #endif
#else
  #if defined(GLSLPP_BUILD_SHARED) && (defined(__GNUC__) || defined(__clang__))
    #define GLSLPP_API __attribute__((visibility("default")))
  #else
    #define GLSLPP_API
  #endif
#endif

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * Status codes
 * -------------------------------------------------------------------------*/

/**
 * Return code for every glslpp_* function.
 *
 * Mirrors `glslpp.Error` from `src/root.zig`. `GLSLPP_ERR_INVALID_INPUT` is
 * additional to the Zig error set and covers C-side argument validation
 * (NULL pointers, out-of-range enums, zero-length SPIR-V, etc.).
 */
typedef enum {
    GLSLPP_OK              = 0,
    GLSLPP_ERR_OOM         = 1, /* Out of memory. */
    GLSLPP_ERR_LEX         = 2, /* Lexer failed (invalid tokens). */
    GLSLPP_ERR_PREPROCESS  = 3, /* Preprocessor failed (#if, #include, ...). */
    GLSLPP_ERR_PARSE       = 4, /* Parser failed (syntax error). */
    GLSLPP_ERR_SEMANTIC    = 5, /* Semantic analysis failed (type error, ...). */
    GLSLPP_ERR_CODEGEN     = 6, /* SPIR-V or backend codegen failed. */
    GLSLPP_ERR_INVALID_INPUT = 7 /* C-side argument validation failed. */
} glslpp_status_t;

/* ---------------------------------------------------------------------------
 * Shader stage
 * -------------------------------------------------------------------------*/

/**
 * Shader stage selector for `glslpp_compile`.
 *
 * Values mirror the Zig `Stage` enum order (`src/root.zig`):
 * vertex, fragment, compute, geometry, tess_control, tess_eval, mesh,
 * task, raygen, closesthit, miss, intersection, anyhit, callable.
 */
typedef enum {
    GLSLPP_STAGE_VERTEX       = 0,
    GLSLPP_STAGE_FRAGMENT     = 1,
    GLSLPP_STAGE_COMPUTE      = 2,
    GLSLPP_STAGE_GEOMETRY     = 3,
    GLSLPP_STAGE_TESS_CONTROL = 4,
    GLSLPP_STAGE_TESS_EVAL    = 5,
    GLSLPP_STAGE_MESH         = 6,
    GLSLPP_STAGE_TASK         = 7,
    GLSLPP_STAGE_RAYGEN       = 8,
    GLSLPP_STAGE_CLOSESTHIT   = 9,
    GLSLPP_STAGE_MISS         = 10,
    GLSLPP_STAGE_INTERSECTION = 11,
    GLSLPP_STAGE_ANYHIT       = 12,
    GLSLPP_STAGE_CALLABLE     = 13
} glslpp_stage_t;

/* ---------------------------------------------------------------------------
 * Compile options
 * -------------------------------------------------------------------------*/

/**
 * Options for `glslpp_compile`.
 *
 * Note: `include_paths` and `defines` from the Zig `CompileOptions` are not
 * yet exposed through the C ABI — if you need them, run your own
 * preprocessing pass against the GLSL source before calling
 * `glslpp_compile`. They may be added in a later milestone.
 */
/* glslpp_compile_options_t: fields may be added across glslpp minor versions.
 * Consumers MUST recompile against the header that matches the library
 * version they link to. There is no `struct_size` discriminator (yet).
 * Check GLSLPP_VERSION_MAJOR/MINOR at compile time if you need to feature-gate.
 */
typedef struct {
    /** Shader stage. Default: GLSLPP_STAGE_FRAGMENT. */
    glslpp_stage_t stage;

    /**
     * GLSL language version * 100 (e.g., 430 for #version 430,
     * 450 for #version 450). Default: 430.
     */
    uint32_t version;

    /**
     * Non-zero if the input is GLSL ES (OpenGL ES Shading Language)
     * rather than desktop GLSL. Used at the preprocessor layer for
     * dialect-specific behavior. Mostly informational at this layer.
     * Default: 0 (desktop GLSL).
     */
    int is_essl;

    /**
     * Target SPIR-V version, encoded as major*10 + minor.
     * Valid values: 10, 11, 12, 13, 14, 15, 16 (= SPIR-V 1.0 .. 1.6).
     * Default: 15 (SPIR-V 1.5).
     */
    uint32_t spirv_version_packed;
} glslpp_compile_options_t;

/* ---------------------------------------------------------------------------
 * GLSL -> SPIR-V
 * -------------------------------------------------------------------------*/

/**
 * Compile GLSL source to a SPIR-V module.
 *
 * @param glsl_source        Pointer to GLSL source bytes. Need NOT be
 *                           null-terminated — the impl copies and adds a
 *                           terminator internally. Must be non-NULL if
 *                           `glsl_len > 0`.
 * @param glsl_len           Length of `glsl_source` in bytes.
 * @param opts               Compile options. If NULL, defaults are used:
 *                           stage=FRAGMENT, version=430, is_essl=0,
 *                           spirv_version_packed=15.
 * @param spirv_words        OUT: receives a pointer to a freshly allocated
 *                           buffer of `*spirv_word_count` u32 SPIR-V words.
 *                           On success the caller MUST release it via
 *                           `glslpp_free_u32`. Set to NULL on failure.
 * @param spirv_word_count   OUT: number of 32-bit words written
 *                           (NOT bytes — multiply by 4 for byte length).
 *                           Set to 0 on failure.
 *
 * @return GLSLPP_OK on success, or one of the GLSLPP_ERR_* codes. On
 *         failure, see `glslpp_last_error_message`/`_line`/`_column` for
 *         diagnostics. `*spirv_words` is set to NULL on failure.
 */
GLSLPP_API glslpp_status_t glslpp_compile(
    const char* glsl_source,
    size_t glsl_len,
    const glslpp_compile_options_t* opts,
    uint32_t** spirv_words,
    size_t* spirv_word_count);

/* ---------------------------------------------------------------------------
 * SPIR-V -> backend languages
 * -------------------------------------------------------------------------*/

/**
 * Cross-compile a SPIR-V module to HLSL source.
 *
 * @param spirv_words        Pointer to SPIR-V words.
 * @param spirv_word_count   Number of 32-bit words.
 * @param binding_shift      Offset added to every descriptor binding in
 *                           the HLSL output. Use 0 for no shift; negative
 *                           values are allowed by the i32 type but
 *                           typically unused. Mirrors
 *                           `HlslCompileOptions.binding_shift`.
 * @param shader_model       HLSL shader model, packed as major*10 + minor
 *                           (e.g., 60 = SM 6.0, 62 = SM 6.2).
 * @param entry_point        Entry-point name to translate. NULL is treated
 *                           as the literal string "main".
 * @param hlsl               OUT: pointer to a UTF-8 HLSL source buffer.
 *                           The buffer IS null-terminated for convenience,
 *                           but `*hlsl_len` does NOT include the
 *                           terminator. On success the caller MUST
 *                           release it via `glslpp_free_str`. Set to NULL
 *                           on failure.
 * @param hlsl_len           OUT: HLSL source length in bytes, EXCLUDING
 *                           the trailing null terminator. Set to 0 on
 *                           failure.
 *
 * @return GLSLPP_OK or a GLSLPP_ERR_* code.
 */
GLSLPP_API glslpp_status_t glslpp_to_hlsl(
    const uint32_t* spirv_words,
    size_t spirv_word_count,
    int32_t binding_shift,
    uint32_t shader_model,
    const char* entry_point,
    char** hlsl,
    size_t* hlsl_len);

/**
 * Cross-compile a SPIR-V module to GLSL source.
 *
 * @param spirv_words        Pointer to SPIR-V words.
 * @param spirv_word_count   Number of 32-bit words.
 * @param glsl_version       Target GLSL language version * 100
 *                           (e.g., 330, 450).
 * @param es                 Non-zero to emit GLSL ES (e.g., for WebGL /
 *                           mobile) rather than desktop GLSL.
 * @param entry_point        Entry-point name. NULL is treated as "main".
 * @param glsl               OUT: pointer to a UTF-8 GLSL source buffer,
 *                           null-terminated for convenience. Free with
 *                           `glslpp_free_str`. Set to NULL on failure.
 * @param glsl_len           OUT: byte length excluding the terminator.
 *                           Set to 0 on failure.
 *
 * @return GLSLPP_OK or a GLSLPP_ERR_* code.
 */
GLSLPP_API glslpp_status_t glslpp_to_glsl(
    const uint32_t* spirv_words,
    size_t spirv_word_count,
    uint32_t glsl_version,
    int es,
    const char* entry_point,
    char** glsl,
    size_t* glsl_len);

/**
 * Cross-compile a SPIR-V module to Metal Shading Language source.
 *
 * @param spirv_words        Pointer to SPIR-V words.
 * @param spirv_word_count   Number of 32-bit words.
 * @param metal_version      Target Metal version, packed as
 *                           major*10 + minor (e.g., 21 = Metal 2.1,
 *                           30 = Metal 3.0). Mirrors
 *                           `spirv_to_msl.MslCompileOptions.metal_version`.
 * @param argument_buffers   Reserved for M6. The Metal argument-buffer
 *                           code path is not yet implemented; this
 *                           parameter is part of the ABI now to avoid a
 *                           breaking change later, but the impl currently
 *                           ignores it. Pass 0.
 * @param entry_point        Entry-point name. NULL is treated as "main".
 * @param msl                OUT: pointer to a UTF-8 MSL source buffer,
 *                           null-terminated for convenience. Free with
 *                           `glslpp_free_str`. Set to NULL on failure.
 * @param msl_len            OUT: byte length excluding the terminator.
 *                           Set to 0 on failure.
 *
 * @return GLSLPP_OK or a GLSLPP_ERR_* code.
 */
GLSLPP_API glslpp_status_t glslpp_to_msl(
    const uint32_t* spirv_words,
    size_t spirv_word_count,
    uint32_t metal_version,
    int argument_buffers,
    const char* entry_point,
    char** msl,
    size_t* msl_len);

/**
 * Cross-compile a SPIR-V module to WGSL source.
 *
 * @param spirv_words        Pointer to SPIR-V words.
 * @param spirv_word_count   Number of 32-bit words.
 * @param entry_point        Entry-point name. NULL is treated as "main".
 * @param wgsl               OUT: pointer to a UTF-8 WGSL source buffer,
 *                           null-terminated for convenience. Free with
 *                           `glslpp_free_str`. Set to NULL on failure.
 * @param wgsl_len           OUT: byte length excluding the terminator.
 *                           Set to 0 on failure.
 *
 * @return GLSLPP_OK or a GLSLPP_ERR_* code.
 */
GLSLPP_API glslpp_status_t glslpp_to_wgsl(
    const uint32_t* spirv_words,
    size_t spirv_word_count,
    const char* entry_point,
    char** wgsl,
    size_t* wgsl_len);

/* ---------------------------------------------------------------------------
 * Error reporting
 * -------------------------------------------------------------------------*/

/**
 * Returns a pointer to a null-terminated, UTF-8 description of the most
 * recent error on the calling thread, or NULL if no error has been
 * recorded.
 *
 * The returned pointer is NOT owned by the caller — it references a
 * threadlocal buffer that is overwritten by the next failing glslpp_*
 * call on the same thread. Copy the string if you need to retain it.
 * Do NOT free it.
 */
GLSLPP_API const char* glslpp_last_error_message(void);

/**
 * Returns the 1-based source line of the most recent error on the
 * calling thread, or 0 if no error has been recorded / the error has
 * no associated source location.
 */
GLSLPP_API uint32_t glslpp_last_error_line(void);

/**
 * Returns the 1-based source column of the most recent error on the
 * calling thread, or 0 if no error has been recorded / the error has
 * no associated source location.
 */
GLSLPP_API uint32_t glslpp_last_error_column(void);

/* ---------------------------------------------------------------------------
 * Buffer release
 * -------------------------------------------------------------------------*/

/**
 * Release a `char*` buffer previously returned by `glslpp_to_hlsl`,
 * `glslpp_to_glsl`, `glslpp_to_msl`, or `glslpp_to_wgsl`.
 *
 * Passing NULL is a no-op. Passing a pointer that did NOT originate from
 * one of the listed functions — for example a pointer from `malloc`,
 * `strdup`, or a different library — is UNDEFINED BEHAVIOR. The impl
 * uses an internal length-prefix layout, so the C `free()` is NOT a
 * valid substitute.
 */
GLSLPP_API void glslpp_free_str(char* s);

/**
 * Release a `uint32_t*` buffer previously returned by `glslpp_compile`
 * via its `spirv_words` out-parameter.
 *
 * Passing NULL is a no-op. Passing a pointer that did NOT originate from
 * `glslpp_compile` is UNDEFINED BEHAVIOR. The C `free()` is NOT a valid
 * substitute (the visible pointer is offset from the underlying
 * allocator block).
 */
GLSLPP_API void glslpp_free_u32(uint32_t* p);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* GLSLPP_H */
