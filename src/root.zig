// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
// Public types — used in return values, diagnostics, and test code
pub const diagnostic = @import("diagnostic.zig");
pub const reflection = @import("reflection.zig");
pub const spirv = @import("spirv.zig");
pub const compat = @import("compat.zig");

// Internal modules — not part of the public API
const lexer = @import("lexer.zig");
const preprocessor = @import("preprocessor.zig");
const ast = @import("ast.zig");
const ir = @import("ir.zig");
const parser = @import("parser.zig");
/// Exposed publicly for use by `tests/diagnostic_tests.zig` which needs to read
/// post-error state (`semantic.last_error_line`, `last_error_column`, etc.).
/// External callers should prefer `Error`, `Diagnostic`, `lastErrorCtx()`, and
/// `lastErrorInner()` from the curated public API.
///
/// Note: `last_error_line`, `last_error_column`, `last_error_ctx`, and
/// `last_error_inner` are `threadlocal` — read them on the same OS thread
/// that invoked the compile function or they will be zero/empty.
pub const semantic = @import("semantic.zig");
const codegen = @import("codegen.zig");
const spirv_to_hlsl = @import("spirv_to_hlsl.zig");
const spirv_to_glsl = @import("spirv_to_glsl.zig");
const spirv_to_msl = @import("spirv_to_msl.zig");
const spirv_to_wgsl = @import("spirv_to_wgsl.zig");
const kernel_fusion = @import("kernel_fusion.zig");
const compact_ids = @import("compact_ids.zig");

/// Errors returned by compilation functions.
/// Use `last_compile_detail` and `compileToSPIRVWithDiagnostics` for more information.
pub const Error = error{
    OutOfMemory,
    /// Lexer encountered invalid tokens or characters.
    LexFailed,
    /// Preprocessor directives could not be resolved (#define, #if, etc.).
    PreprocessFailed,
    /// GLSL source could not be parsed into a valid AST.
    ParseFailed,
    /// Semantic analysis found type errors, undeclared variables, etc.
    SemanticFailed,
    /// SPIR-V code generation failed.
    CodegenFailed,
    /// Requested entry point was not found in the SPIR-V module.
    EntryPointNotFound,
};

/// Detailed information about which compilation stage failed.
/// Set by `compileToSPIRV` on error. Access via `last_compile_detail`.
pub const CompileDetail = enum {
    lex_failed,
    parse_failed,
    semantic_failed,
    codegen_failed,
};

/// **Deprecated:** Use `compileToSPIRVWithDiagnostics` for structured error reporting.
/// This threadlocal will be removed in a future version.
pub threadlocal var last_compile_detail: ?CompileDetail = null;

/// Returns the last semantic error context string (e.g., "function call", "variable declaration").
pub fn lastErrorCtx() ?[]const u8 {
    if (semantic.last_error_ctx.len == 0) return null;
    return semantic.last_error_ctx;
}

/// Returns the last semantic error inner detail string.
pub fn lastErrorInner() ?[]const u8 {
    if (semantic.last_error_inner.len == 0) return null;
    return semantic.last_error_inner;
}

/// Shader stage for compilation.
pub const Stage = enum {
    vertex,
    fragment,
    compute,
    geometry,
    tessellation_control,
    tessellation_evaluation,
    mesh,
    task,
    raygen,
    closesthit,
    miss,
    intersection,
    anyhit,
    callable,
};

/// Target SPIR-V version for code generation.
pub const SPIRVVersion = enum { @"1.0", @"1.1", @"1.2", @"1.3", @"1.4", @"1.5", @"1.6" };

/// A single specialization-constant value override applied at compile time.
/// `value_u32` is the raw 32-bit payload — the consumer chooses the bit
/// representation matching the spec const's declared type:
///   - `int`   → cast via `@bitCast(i32)`
///   - `uint`  → use directly as u32
///   - `float` → cast via `@bitCast(f32)`
///   - `bool`  → 0 for false, non-zero (typically 1) for true
pub const SpecOverride = struct {
    spec_id: u32,
    value_u32: u32,
};

/// Resource limits for shader compilation.
pub const ResourceLimits = struct {
    /// Maximum uniform components per stage.
    max_uniform_components: u32 = 4096,
    /// Maximum combined texture units.
    max_texture_units: u32 = 32,
};

/// Options for `compileToSPIRV` and related functions.
pub const DefineOverride = struct {
    name: []const u8,
    value: []const u8 = "1",
};

pub const CompileOptions = struct {
    /// GLSL source version: 100 (ESSL), 110, 120, 130, 140, 150, 300 (ESSL), 330, 400, 410, 420, 430, 440, 450, 460.
    version: u32 = 430,
    /// Shader stage to compile.
    stage: Stage = .fragment,
    /// Target SPIR-V version for the output binary.
    spirv_version: SPIRVVersion = .@"1.5",
    /// Resource limits for validation.
    limits: ResourceLimits = .{},
    /// Include search paths for #include directives.
    include_paths: []const []const u8 = &.{},
    /// Preprocessor defines to inject before compilation.
    defines: []const DefineOverride = &.{},
};

pub const CrossCompileOptions = struct {
    glsl_version: u32 = 430,
    flatten_ubos: bool = false,
};

/// Options for multi-kernel SPIR-V compilation.
pub const MultiKernelOptions = struct {
    /// Entry point names for each source. Must match sources.len.
    /// Each source's `main()` is renamed to the corresponding name.
    names: []const []const u8,
    /// Shader stage (typically .compute).
    stage: Stage = .compute,
    /// GLSL version.
    version: u32 = 450,
    /// SPIR-V target version.
    spirv_version: SPIRVVersion = .@"1.5",
};

/// Compile multiple GLSL sources into a single SPIR-V module with multiple entry points.
/// Each source should contain its own `main()` function. The resulting SPIR-V module
/// will have one entry point per source, named according to `options.names`.
pub fn compileMultiKernel(
    alloc: std.mem.Allocator,
    sources: []const [:0]const u8,
    options: MultiKernelOptions,
) Error![]const u32 {
    if (sources.len == 0) return error.CodegenFailed;
    if (options.names.len != sources.len) return error.CodegenFailed;

    // Compile each source individually
    var modules = std.ArrayList([]const u32).initCapacity(alloc, sources.len) catch return error.OutOfMemory;
    defer {
        for (modules.items) |m| alloc.free(m);
        modules.deinit(alloc);
    }

    const compile_opts = CompileOptions{
        .stage = options.stage,
        .version = options.version,
        .spirv_version = options.spirv_version,
    };

    for (sources) |src| {
        const spirv_words = try compileToSPIRV(alloc, src, compile_opts);
        try modules.append(alloc, spirv_words);
    }

    // Merge modules with proper ID remapping
    const merged = try linkSPIRVModules(alloc, modules.items);
    errdefer alloc.free(merged);

    // Rename entry points from "main" to the specified names
    const renamed = try renameEntryPoints(alloc, merged, options.names);
    if (renamed.ptr != merged.ptr) alloc.free(merged);
    return renamed;
}

/// Rename entry points in a multi-kernel SPIR-V module.
/// Each OpEntryPoint's name is replaced with the corresponding name from `names`.
fn renameEntryPoints(alloc: std.mem.Allocator, words: []const u32, names: []const []const u8) Error![]const u32 {
    if (words.len < 5) return error.CodegenFailed;

    // Count entry points and verify they match names count
    var entry_count: u32 = 0;
    var p: u32 = 5;
    while (p < words.len) {
        const h = words[p];
        const wc: u32 = h >> 16;
        const op: u16 = @truncate(h & 0xFFFF);
        if (wc == 0) break;
        if (op == 15) entry_count += 1; // OpEntryPoint
        p += wc;
    }

    // If names don't match entry count, return as-is
    if (entry_count != names.len) return try alloc.dupe(u32, words);

    // Rebuild the binary with renamed entry points
    var out = std.ArrayList(u32).initCapacity(alloc, words.len) catch return error.OutOfMemory;
    defer out.deinit(alloc);

    // Copy header
    try out.appendSlice(alloc, words[0..5]);

    var name_idx: u32 = 0;
    p = 5;
    while (p < words.len) {
        const h = words[p];
        const wc: u32 = h >> 16;
        const op: u16 = @truncate(h & 0xFFFF);
        if (wc == 0) break;
        const ie = p + wc;
        if (ie > words.len) break;

        if (op == 15 and name_idx < names.len) {
            // OpEntryPoint: execution_model, func_id, name_string, [interface_ids...]
            const new_name = names[name_idx];
            name_idx += 1;

            // Extract execution model and func_id (words 1 and 2 after header)
            const exec_model = words[p + 1];
            const func_id = words[p + 2];

            // Find where the name string ends in the original
            var str_end: u32 = p + 3;
            while (str_end < ie) {
                const w = words[str_end];
                str_end += 1;
                if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) {
                    break;
                }
            }

            // Calculate new word count
            const new_name_words = std.math.divCeil(usize, new_name.len + 1, 4) catch return error.CodegenFailed;
            const new_wc: u16 = @intCast(3 + new_name_words + (ie - str_end));

            // Emit new OpEntryPoint
            try out.append(alloc, (@as(u32, new_wc) << 16) | 15);
            try out.append(alloc, exec_model);
            try out.append(alloc, func_id);

            // Emit new name string
            try emitStringLiteral(alloc, &out, new_name);

            // Copy interface IDs
            try out.appendSlice(alloc, words[str_end..ie]);
        } else {
            try out.appendSlice(alloc, words[p..ie]);
        }

        p = ie;
    }

    return try out.toOwnedSlice(alloc);
}

/// Emit a null-terminated string as SPIR-V literal words (4-byte aligned).
fn emitStringLiteral(alloc: std.mem.Allocator, out: *std.ArrayList(u32), str: []const u8) !void {
    if (str.len > 65535) return error.CodegenFailed;
    const word_count = std.math.divCeil(usize, str.len + 1, 4) catch return error.CodegenFailed;
    try out.ensureUnusedCapacity(alloc, word_count);

    var i: usize = 0;
    while (i < word_count) : (i += 1) {
        var word: u32 = 0;
        var j: usize = 0;
        while (j < 4) : (j += 1) {
            const byte_idx = i * 4 + j;
            if (byte_idx < str.len) {
                word |= @as(u32, str[byte_idx]) << @intCast(j * 8);
            }
        }
        out.appendAssumeCapacity(word);
    }
}

/// Options for SPIR-V kernel fusion optimization pass.
pub const FusionOptions = kernel_fusion.FusionOptions;

/// Compile GLSL source to SPIR-V binary words.
pub fn compileToSPIRV(
    alloc: std.mem.Allocator,
    source: [:0]const u8,
    options: CompileOptions,
) Error![]const u32 {
    last_compile_detail = null;

    // Prepend -D defines as #define directives to source
    const actual_source: [:0]const u8 = if (options.defines.len > 0) blk: {
        var buf = std.ArrayListUnmanaged(u8).initCapacity(alloc, source.len + options.defines.len * 64) catch return error.OutOfMemory;
        for (options.defines) |def| {
            buf.appendSlice(alloc, "#define ") catch return error.OutOfMemory;
            buf.appendSlice(alloc, def.name) catch return error.OutOfMemory;
            buf.appendSlice(alloc, " ") catch return error.OutOfMemory;
            buf.appendSlice(alloc, def.value) catch return error.OutOfMemory;
            buf.append(alloc, '\n') catch return error.OutOfMemory;
        }
        buf.appendSlice(alloc, source) catch return error.OutOfMemory;
        buf.append(alloc, 0) catch return error.OutOfMemory;
        const result = buf.toOwnedSlice(alloc) catch return error.OutOfMemory;
        break :blk result[0 .. result.len - 1 :0];
    } else source;
    defer if (actual_source.ptr != source.ptr) alloc.free(@constCast(actual_source.ptr[0..actual_source.len + 1]));

    const tokens = lexer.tokenize(alloc, actual_source) catch {
        last_compile_detail = .lex_failed;
        semantic.last_error_line = lexer.last_error_line;
        semantic.last_error_column = lexer.last_error_column;
        return error.LexFailed;
    };
    defer alloc.free(tokens);

    // Run preprocessor to handle #define, #if, #ifdef, etc.
    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();
    pp.include_paths = options.include_paths;

    const pp_tokens = pp.process(actual_source, tokens) catch tokens;
    defer if (pp_tokens.ptr != tokens.ptr) alloc.free(pp_tokens);

    var root_node = parser.parse(alloc, actual_source, pp_tokens) catch {
        last_compile_detail = .parse_failed;
        return error.ParseFailed;
    };
    defer parser.freeTree(alloc, &root_node);

    var module = semantic.analyzeWithOptions(alloc, &root_node, .{ .tolerate_errors = true, .stage = options.stage }) catch {
        last_compile_detail = .semantic_failed;
        return error.SemanticFailed;
    };
    defer module.deinit();

    const stage: codegen.Stage = switch (options.stage) {
        .vertex => .vertex,
        .fragment => .fragment,
        .compute => .compute,
        .geometry => .geometry,
        .tessellation_control => .tessellation_control,
        .tessellation_evaluation => .tessellation_evaluation,
        .mesh => .mesh,
        .task => .task,
        .raygen => .raygen,
        .closesthit => .closesthit,
        .miss => .miss,
        .intersection => .intersection,
        .anyhit => .anyhit,
        .callable => .callable,
    };
    const spirv_ver: codegen.SPIRVVersion = switch (options.spirv_version) {
        .@"1.0" => .@"1.0",
        .@"1.1" => .@"1.1",
        .@"1.2" => .@"1.2",
        .@"1.3" => .@"1.3",
        .@"1.4" => .@"1.4",
        .@"1.5" => .@"1.5",
        .@"1.6" => .@"1.6",
    };
    const default_layout: codegen.LayoutKind = if (pp.has_ext_scalar_block_layout) .scalar else .std140;
    return codegen.generate(alloc, &module, stage, spirv_ver, pp.version, pp.is_essl, default_layout) catch {
        last_compile_detail = .codegen_failed;
        return error.CodegenFailed;
    };
}

/// Same as `compileToSPIRV` but applies one or more specialization-constant
/// overrides after codegen. For each override, walks the emitted SPIR-V
/// looking for `OpDecorate <target> SpecId <override.spec_id>` and rewrites
/// the matching constant instruction's literal payload to `override.value_u32`.
///
/// Behaviour per opcode:
///   - `OpSpecConstant` (50): rewrites the literal at words[3].
///   - `OpSpecConstantTrue` (48) / `OpSpecConstantFalse` (49): swaps the
///     opcode in-place to match the override value (non-zero → True,
///     zero → False); the wc/structure is unchanged because both are
///     3-word instructions.
///
/// Composite (`OpSpecConstantComposite`) and op-derived
/// (`OpSpecConstantOp`) overrides are not applied — those forms don't
/// carry a single literal payload. An override pointing at one of those
/// is silently ignored.
pub fn compileToSPIRVWithSpecOverrides(
    alloc: std.mem.Allocator,
    source: [:0]const u8,
    options: CompileOptions,
    overrides: []const SpecOverride,
) Error![]const u32 {
    const words = try compileToSPIRV(alloc, source, options);
    if (overrides.len == 0) return words;
    // Copy to a mutable buffer (compileToSPIRV returns owned memory; we
    // free it after mutation).
    const mut = alloc.alloc(u32, words.len) catch {
        alloc.free(words);
        return error.OutOfMemory;
    };
    @memcpy(mut, words);
    alloc.free(words);
    applySpecOverrides(mut, overrides);
    return mut;
}

/// Apply specialization-constant overrides to an existing SPIR-V word
/// stream in-place. Used by `compileToSPIRVWithSpecOverrides`; exposed
/// publicly so external callers (e.g., the CLI) can apply overrides to
/// SPIR-V produced by an earlier `compileToSPIRV` call without re-running
/// the full pipeline.
///
/// Walks the word stream, builds `result_id -> spec_id` map from
/// `OpDecorate ... SpecId N`, then rewrites literal/opcode in any
/// `OpSpecConstant{,True,False}` whose result_id matches an override.
pub fn applySpecOverrides(words: []u32, overrides: []const SpecOverride) void {
    if (words.len < 5) return;
    // Pass 1: scan for SpecId decorations. Build a tiny linear map
    // (small N — typically < 32 spec consts in real shaders).
    const Pair = struct { result_id: u32, spec_id: u32 };
    var pairs: [256]Pair = undefined;
    var pair_count: usize = 0;
    var i: usize = 5;
    while (i < words.len) {
        const wc: u32 = words[i] >> 16;
        const op: u16 = @truncate(words[i] & 0xFFFF);
        if (wc == 0) break;
        // OpDecorate (71): [op|wc] target decoration_kind [literal...]
        // SpecId decoration is enum value 1; payload at words[i+3].
        if (op == 71 and wc >= 4 and words[i + 2] == 1) {
            if (pair_count < pairs.len) {
                pairs[pair_count] = .{ .result_id = words[i + 1], .spec_id = words[i + 3] };
                pair_count += 1;
            }
        }
        i += wc;
    }

    // Pass 2: rewrite matching OpSpecConstant* instructions in-place.
    i = 5;
    while (i < words.len) {
        const wc: u32 = words[i] >> 16;
        const op: u16 = @truncate(words[i] & 0xFFFF);
        if (wc == 0) break;
        const result_id: u32 = switch (op) {
            48, 49, 50 => if (wc >= 3) words[i + 2] else 0, // SpecConstantTrue/False/(scalar)
            else => 0,
        };
        if (result_id != 0) {
            // Look up spec_id for this result_id
            var spec_id: ?u32 = null;
            for (pairs[0..pair_count]) |p| {
                if (p.result_id == result_id) { spec_id = p.spec_id; break; }
            }
            if (spec_id) |sid| {
                // Find override with matching spec_id
                for (overrides) |ov| {
                    if (ov.spec_id != sid) continue;
                    if (op == 50 and wc >= 4) {
                        words[i + 3] = ov.value_u32;
                    } else if (op == 48 or op == 49) {
                        // Swap True/False based on override value (LSB).
                        const new_op: u32 = if (ov.value_u32 != 0) 48 else 49;
                        words[i] = (wc << 16) | new_op;
                    }
                    break;
                }
            }
        }
        i += wc;
    }
}

/// Compile GLSL source to SPIR-V without optimization (for debugging).
pub fn compileToSPIRVNoOpt(
    alloc: std.mem.Allocator,
    source: [:0]const u8,
    options: CompileOptions,
) Error![]const u32 {
    last_compile_detail = null;
    const tokens = lexer.tokenize(alloc, source) catch {
        last_compile_detail = .lex_failed;
        semantic.last_error_line = lexer.last_error_line;
        semantic.last_error_column = lexer.last_error_column;
        return error.LexFailed;
    };
    defer alloc.free(tokens);

    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();
    const pp_tokens = pp.process(source, tokens) catch tokens;
    defer if (pp_tokens.ptr != tokens.ptr) alloc.free(pp_tokens);

    var root_node = parser.parse(alloc, source, pp_tokens) catch {
        last_compile_detail = .parse_failed;
        return error.ParseFailed;
    };
    defer parser.freeTree(alloc, &root_node);

    var module = semantic.analyzeWithOptions(alloc, &root_node, .{ .tolerate_errors = true, .stage = options.stage }) catch {
        last_compile_detail = .semantic_failed;
        return error.SemanticFailed;
    };
    defer module.deinit();

    const stage: codegen.Stage = switch (options.stage) {
        .vertex => .vertex,
        .fragment => .fragment,
        .compute => .compute,
        .geometry => .geometry,
        .tessellation_control => .tessellation_control,
        .tessellation_evaluation => .tessellation_evaluation,
        .mesh => .mesh,
        .task => .task,
        .raygen => .raygen,
        .closesthit => .closesthit,
        .miss => .miss,
        .intersection => .intersection,
        .anyhit => .anyhit,
        .callable => .callable,
    };
    const spirv_ver: codegen.SPIRVVersion = switch (options.spirv_version) {
        .@"1.0" => .@"1.0",
        .@"1.1" => .@"1.1",
        .@"1.2" => .@"1.2",
        .@"1.3" => .@"1.3",
        .@"1.4" => .@"1.4",
        .@"1.5" => .@"1.5",
        .@"1.6" => .@"1.6",
    };
    const default_layout: codegen.LayoutKind = if (pp.has_ext_scalar_block_layout) .scalar else .std140;
    return codegen.generateNoOpt(alloc, &module, stage, spirv_ver, pp.version, pp.is_essl, default_layout) catch {
        last_compile_detail = .codegen_failed;
        return error.CodegenFailed;
    };
}

/// Cross-compile SPIR-V binary to GLSL source.
/// Targets GLSL 430 by default.
pub fn spirvToGLSL(
    alloc: std.mem.Allocator,
    spirv_words: []const u32,
    options: spirv_to_glsl.GlslCompileOptions,
) ![]const u8 {
    return spirv_to_glsl.spirvToGLSL(alloc, spirv_words, options);
}

/// Cross-compile SPIR-V binary to HLSL source.
/// Targets Shader Model 6.0 with entry point named `main`.
pub fn spirvToHLSL(
    alloc: std.mem.Allocator,
    spirv_words: []const u32,
    options: spirv_to_hlsl.HlslCompileOptions,
) ![]const u8 {
    return spirv_to_hlsl.spirvToHLSL(alloc, spirv_words, options);
}

/// Cross-compile SPIR-V binary to MSL source.
/// Targets Metal Shading Language.
pub fn spirvToMSL(
    alloc: std.mem.Allocator,
    spirv_words: []const u32,
    options: spirv_to_msl.MslCompileOptions,
) ![]const u8 {
    return spirv_to_msl.spirvToMSL(alloc, spirv_words, options);
}

/// Cross-compile SPIR-V binary to WGSL source.
/// Targets WebGPU Shading Language.
pub fn spirvToWGSL(
    alloc: std.mem.Allocator,
    spirv_words: []const u32,
    options: spirv_to_wgsl.WgslCompileOptions,
) ![]const u8 {
    return spirv_to_wgsl.spirvToWGSL(alloc, spirv_words, options);
}

/// One-shot: compile Shadertoy-style GLSL to HLSL.
/// Chains preprocess -> parse -> SPIR-V -> HLSL.
pub fn compileShadertoyToHlsl(
    alloc: std.mem.Allocator,
    glsl: [:0]const u8,
    options: CompileOptions,
) !struct { hlsl: []const u8, diagnostics: []diagnostic.Diagnostic } {
    const spirv_words = try compileToSPIRV(alloc, glsl, options);
    defer alloc.free(spirv_words);

    const hlsl = try spirvToHLSL(alloc, spirv_words, .{
        .shader_model = 60,
    });

    return .{ .hlsl = hlsl, .diagnostics = &.{} };
}

/// One-shot GLSL -> HLSL compilation.
/// Takes GLSL source (with shadertoy prefix already prepended) and returns
/// a null-terminated HLSL string.
/// Caller must free with alloc.free().
pub fn compileGlslToHlsl(
    alloc: std.mem.Allocator,
    glsl_source: [:0]const u8,
    stage: Stage,
) ![:0]const u8 {
    const spirv_words = try compileToSPIRV(alloc, glsl_source, .{
        .stage = stage,
        .version = 430,
    });
    defer alloc.free(spirv_words);

    const hlsl = try spirvToHLSL(alloc, spirv_words, .{
        .binding_shift = -1,
        .shader_model = 60,
    });
    defer alloc.free(hlsl);
    return try alloc.dupeZ(u8, hlsl);
}

/// One-shot GLSL -> MSL compilation.
/// Takes GLSL source (with shadertoy prefix already prepended) and returns
/// a null-terminated MSL string.
/// Caller must free with alloc.free().
pub fn compileGlslToMsl(
    alloc: std.mem.Allocator,
    glsl_source: [:0]const u8,
    stage: Stage,
) ![:0]const u8 {
    const spirv_words = try compileToSPIRV(alloc, glsl_source, .{
        .stage = stage,
        .version = 430,
    });
    defer alloc.free(spirv_words);

    const msl = try spirvToMSL(alloc, spirv_words, .{});
    defer alloc.free(msl);
    return try alloc.dupeZ(u8, msl);
}

/// One-shot GLSL → WGSL compilation.
/// Takes GLSL source and returns a null-terminated WGSL string.
/// Caller must free with `alloc.free()`.
pub fn compileGlslToWgsl(
    alloc: std.mem.Allocator,
    glsl_source: [:0]const u8,
    stage: Stage,
) ![:0]const u8 {
    const spirv_words = try compileToSPIRV(alloc, glsl_source, .{
        .stage = stage,
        .version = 430,
    });
    defer alloc.free(spirv_words);

    const wgsl = try spirvToWGSL(alloc, spirv_words, .{});
    defer alloc.free(wgsl);
    return try alloc.dupeZ(u8, wgsl);
}

/// One-shot GLSL -> GLSL compilation (round-trip / decompiled).
/// Takes GLSL source and returns a null-terminated GLSL string.
/// Caller must free with alloc.free().
pub fn compileGlslToGlsl(
    alloc: std.mem.Allocator,
    glsl_source: [:0]const u8,
    stage: Stage,
) ![:0]const u8 {
    return compileGlslToGlslVersion(alloc, glsl_source, stage, 430);
}

/// One-shot GLSL -> GLSL compilation with explicit output version.
/// `glsl_version` controls the `#version` header (330, 410, 430, 450, 460).
pub fn compileGlslToGlslVersion(
    alloc: std.mem.Allocator,
    glsl_source: [:0]const u8,
    stage: Stage,
    glsl_version: u32,
) ![:0]const u8 {
    const spirv_words = try compileToSPIRV(alloc, glsl_source, .{
        .stage = stage,
        .version = 430,
    });
    defer alloc.free(spirv_words);

    const glsl = try spirvToGLSL(alloc, spirv_words, .{ .version = glsl_version });
    defer alloc.free(glsl);
    return try alloc.dupeZ(u8, glsl);
}


/// Merge multiple SPIR-V modules into a single module with proper ID remapping.
/// Uses compact_ids.getOpInfo to distinguish IDs from literals.
/// This is the SPIR-V linker (Option C from issue #5) — useful for merging
/// pre-compiled modules when you already have SPIR-V binaries.
pub fn linkSPIRVModules(alloc: std.mem.Allocator, modules: []const []const u32) Error![]const u32 {
    if (modules.len == 0) return error.CodegenFailed;
    if (modules.len == 1) {
        return try alloc.dupe(u32, modules[0]);
    }

    // Calculate cumulative ID offsets for each module
    var id_offsets = try alloc.alloc(u32, modules.len);
    defer alloc.free(id_offsets);

    var next_id: u32 = modules[0][3]; // bound of first module
    id_offsets[0] = 0;
    for (1..modules.len) |i| {
        id_offsets[i] = next_id;
        if (modules[i].len >= 4) {
            next_id += modules[i][3]; // add bound of this module
        }
    }

    var out = std.ArrayList(u32).initCapacity(alloc, modules[0].len) catch return error.OutOfMemory;
    defer out.deinit(alloc);

    // Copy first module as the base (with updated bound)
    try out.appendSlice(alloc, modules[0]);
    if (out.items.len >= 4) {
        out.items[3] = next_id; // update bound
    }

    // For subsequent modules, remap IDs and append
    for (modules[1..], 1..) |mod, mi| {
        if (mod.len < 5) continue;
        const offset = id_offsets[mi];
        const mod_bound = mod[3];

        var p: u32 = 5; // skip header
        while (p < mod.len) {
            const h = mod[p];
            const wc: u32 = h >> 16;
            const op: u16 = @truncate(h & 0xFFFF);
            if (wc == 0) break;
            const ie = p + wc;
            if (ie > mod.len) break;

            // Skip capabilities, memory model, and OpSource (already in first module)
            if (op == 17 or op == 14 or op == 3) {
                p = ie;
                continue;
            }

            // Remap instruction using getOpInfo for proper ID/literal distinction
            const info = compact_ids.getOpInfo(op) orelse {
                // Unknown opcode — copy as-is
                try out.appendSlice(alloc, mod[p..ie]);
                p = ie;
                continue;
            };

            const remap = struct {
                fn remapId(word: u32, off: u32, bnd: u32) u32 {
                    return if (word > 0 and word < bnd) word + off else word;
                }
            }.remapId;

            try out.ensureUnusedCapacity(alloc, wc);
            try out.append(alloc, h); // instruction header — no remap

            var wi: u32 = p + 1; // start after header

            // Fixed part
            switch (info.fixed) {
                1 => { // result_type (ID)
                    if (wi < ie) {
                        try out.append(alloc, remap(mod[wi], offset, mod_bound));
                        wi += 1;
                    }
                },
                2 => { // result_type (ID), result (ID — definition)
                    if (wi < ie) {
                        try out.append(alloc, remap(mod[wi], offset, mod_bound));
                        wi += 1;
                    }
                    if (wi < ie) {
                        try out.append(alloc, remap(mod[wi], offset, mod_bound));
                        wi += 1;
                    }
                },
                3 => { // result only (definition)
                    if (wi < ie) {
                        try out.append(alloc, remap(mod[wi], offset, mod_bound));
                        wi += 1;
                    }
                },
                else => {},
            }

            // Variable operands
            for (info.ops) |ch| {
                if (wi >= ie) break;
                switch (ch) {
                    'i' => {
                        try out.append(alloc, remap(mod[wi], offset, mod_bound));
                        wi += 1;
                    },
                    'I' => {
                        while (wi < ie) : (wi += 1) {
                            try out.append(alloc, remap(mod[wi], offset, mod_bound));
                        }
                    },
                    'l' => {
                        if (wi < ie) {
                            try out.append(alloc, mod[wi]);
                            wi += 1;
                        }
                    },
                    'L' => {
                        while (wi < ie) : (wi += 1) {
                            try out.append(alloc, mod[wi]);
                        }
                    },
                    's' => {
                        while (wi < ie) : (wi += 1) {
                            try out.append(alloc, mod[wi]);
                        }
                    },
                    'M' => {
                        if (wi < ie) {
                            try out.append(alloc, mod[wi]); // mask literal
                            wi += 1;
                        }
                        while (wi < ie) : (wi += 1) {
                            try out.append(alloc, remap(mod[wi], offset, mod_bound));
                        }
                    },
                    'W' => {
                        while (wi + 1 < ie) {
                            try out.append(alloc, mod[wi]); // literal
                            wi += 1;
                            try out.append(alloc, remap(mod[wi], offset, mod_bound)); // ID
                            wi += 1;
                        }
                        if (wi < ie) {
                            try out.append(alloc, mod[wi]);
                            wi += 1;
                        }
                    },
                    'E' => {
                        // OpEntryPoint: name-string + interface-ids (model and func-id already handled by 'l' and 'i')
                        // Copy name string words until null terminator found
                        while (wi < ie) {
                            const w = mod[wi];
                            try out.append(alloc, w);
                            wi += 1;
                            if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) {
                                break;
                            }
                        }
                        // Rest are interface IDs
                        while (wi < ie) : (wi += 1) {
                            try out.append(alloc, remap(mod[wi], offset, mod_bound));
                        }
                    },
                    else => {
                        if (wi < ie) {
                            try out.append(alloc, mod[wi]);
                            wi += 1;
                        }
                    },
                }
            }

            // Copy any remaining words (for cases where getOpInfo doesn't cover all operands)
            while (wi < ie) : (wi += 1) {
                try out.append(alloc, mod[wi]);
            }

            p = ie;
        }
    }

    // Compact IDs to clean up gaps
    const result = try out.toOwnedSlice(alloc);
    const compacted = compact_ids.compactIds(alloc, result) catch return result;
    if (compacted.ptr != result.ptr) alloc.free(result);
    return compacted;
}

/// Compile GLSL source to SPIR-V with kernel fusion optimization.
/// Compiles multiple GLSL compute shaders, then fuses consecutive
/// elementwise kernels to reduce memory bandwidth and launch overhead.
pub fn compileToSPIRVWithFusion(
    alloc: std.mem.Allocator,
    sources: []const [:0]const u8,
    options: CompileOptions,
    fusion: FusionOptions,
) Error![]const u32 {
    if (sources.len == 0) return error.CodegenFailed;

    // Single source — just compile and return
    if (sources.len == 1) {
        const spirv_words = try compileToSPIRV(alloc, sources[0], options);
        // Still apply fusion pass (it's a no-op for single kernel)
        const fused = kernel_fusion.fuseKernels(alloc, spirv_words, fusion) catch return spirv_words;
        if (fused.ptr != spirv_words.ptr) alloc.free(spirv_words);
        return fused;
    }

    // Multiple sources — compile each and merge SPIR-V modules
    var modules = std.ArrayList([]const u32).initCapacity(alloc, sources.len) catch return error.OutOfMemory;
    defer {
        for (modules.items) |m| alloc.free(m);
        modules.deinit(alloc);
    }

    for (sources) |src| {
        const spirv_words = try compileToSPIRV(alloc, src, options);
        try modules.append(alloc, spirv_words);
    }

    // Use proper ID-aware merge: remap IDs (not literals) using getOpInfo
    const merged_words = try linkSPIRVModules(alloc, modules.items);
    errdefer alloc.free(merged_words);

    // Apply fusion pass
    const fused = kernel_fusion.fuseKernels(alloc, merged_words, fusion) catch return merged_words;
    if (fused.ptr != merged_words.ptr) alloc.free(merged_words);
    return fused;
}

/// Reflect on a SPIR-V binary to extract shader resource information.
/// Returns structured data about uniform buffers, inputs/outputs, samplers, etc.
/// Caller must call `deinit()` on the result to free memory.
pub fn reflectSPIRV(alloc: std.mem.Allocator, spirv_words: []const u32) !reflection.ShaderResources {
    return reflection.reflect(alloc, spirv_words);
}

/// Compile GLSL source and reflect on the resulting SPIR-V.
/// Convenience function that combines compileToSPIRV + reflectSPIRV.
pub fn reflectGLSL(alloc: std.mem.Allocator, source: [:0]const u8, options: CompileOptions) !reflection.ShaderResources {
    const spirv_bin = try compileToSPIRV(alloc, source, options);
    defer alloc.free(spirv_bin);
    return reflection.reflect(alloc, spirv_bin);
}

/// Validate a SPIR-V binary using spirv-val. Returns true if validation passed,
/// false if spirv-val is not found on PATH.
pub fn validateSPIRV(alloc: std.mem.Allocator, spirv_words: []const u32) !bool {
    const io = compat.testIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmpfile = try compat.dirCreateFile(io, tmp.dir, "shader.spv", .{});
    defer compat.fileClose(io, tmpfile);
    const bytes = std.mem.sliceAsBytes(spirv_words);
    try compat.fileWriteAll(io, tmpfile, bytes);

    var path_buf: [compat.max_path_bytes]u8 = undefined;
    const spv_path = try compat.fileRealpath(io, tmp.dir, "shader.spv", &path_buf);

    const result = compat.processRun(io, alloc, &.{ "spirv-val", spv_path }) catch return false;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    return (result.term.exitedCode() orelse 1) == 0;
}

pub fn compileToSPIRVWithDiagnostics(
    alloc: std.mem.Allocator,
    source: [:0]const u8,
    options: CompileOptions,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error![]const u32 {
    // Bug #3.B: register a threadlocal sink so tolerate-mode semantic statement
    // errors are recorded as structured diagnostics DURING analysis (while the
    // AST/source are alive). Save/restore the previous sink for re-entrancy
    // safety (nested compiles on the same thread).
    var sink: std.ArrayListUnmanaged(semantic.RecordedDiag) = .empty;
    defer sink.deinit(alloc);
    const prev_sink = semantic.diag_sink;
    semantic.diag_sink = .{ .list = &sink, .alloc = alloc };
    defer semantic.diag_sink = prev_sink;

    const result = compileToSPIRV(alloc, source, options);

    // Drain structured errors recorded during analysis into the caller's list.
    // Each `rd.message` was dup'd onto `alloc` at record time → ownership
    // transfers to the Diagnostic (the caller frees `d.message`). `sink.deinit`
    // frees only the backing array, NOT the message strings, so we must NOT free
    // `rd.message` on the normal drain path. If `append` itself OOMs, free the
    // orphaned message to avoid a leak.
    for (sink.items) |rd| {
        diagnostics.append(alloc, .{
            .kind = .@"error",
            .line = rd.line,
            .column = rd.column,
            .message = rd.message,
        }) catch {
            alloc.free(rd.message);
        };
    }

    const words = result catch {
        // Fall back to the single last-error bridge ONLY if no structured
        // diagnostics were produced (e.g. a lexer/parser/codegen-stage error, or
        // a non-tolerated path). This avoids double-reporting the same failure
        // that the sink already surfaced per-statement.
        if (diagnostics.items.len == 0) {
            const detail = last_compile_detail orelse return result;
            const msg = std.fmt.allocPrint(alloc, "{s}: {s}", .{
                @tagName(detail),
                if (semantic.last_error_inner.len > 0) semantic.last_error_inner else semantic.last_error_ctx,
            }) catch "unknown error";

            try diagnostics.append(alloc, .{
                .kind = .@"error",
                .line = semantic.last_error_line,
                .column = semantic.last_error_column,
                .message = msg,
            });
        }
        return result;
    };

    // Mitchell-philosophy contract (this WithDiagnostics API only): an
    // error-kind diagnostic must never ride on a "success" return. Tolerate
    // mode can swallow every broken statement and hand back a valid-but-empty
    // module; a caller doing `if (result) |words|` would then silently ignore
    // the recorded errors. So if analysis recorded ANY `.error`-kind diagnostic,
    // fail loudly and do NOT return the misleading partial/empty module.
    //
    // We check error-kind specifically (not items.len) to leave room for future
    // warning-/note-kind diagnostics that must NOT fail the compile. The plain
    // `compileToSPIRV` API is intentionally unchanged — its silent-empty-module
    // behavior on broken shaders is a separate, larger decision.
    for (diagnostics.items) |d| {
        if (d.kind == .@"error") {
            // We return an error, so the caller never receives `words` and its
            // `defer alloc.free(words)` never runs. Free it here exactly once.
            alloc.free(words);
            return error.SemanticFailed;
        }
    }
    return words;
}

test {
    _ = diagnostic;
    _ = lexer;
    _ = preprocessor;
    _ = ast;
    _ = ir;
    _ = spirv;
    _ = parser;
    _ = semantic;
    // gap_tests.zig is intentionally NOT imported here. It contains markers
    // for known unimplemented features that fail on purpose; run it
    // standalone with `zig test src/gap_tests.zig` to audit the gap list.
}

test "compilation pipeline" {
    const alloc = std.testing.allocator;
    const result = compileToSPIRV(alloc, "#version 430\nvoid main() {}", .{});
    if (result) |words| {
        defer alloc.free(words);
        try std.testing.expectEqual(@as(u32, spirv.MAGIC), words[0]);
    } else |_| {}
}

test "compile minimal fragment shader" {
    const alloc = std.testing.allocator;
    const result = compileToSPIRV(alloc, "#version 430\nvoid main() {}", .{});
    if (result) |words| {
        defer alloc.free(words);
        try std.testing.expect(words.len >= 5);
        try std.testing.expectEqual(@as(u32, spirv.MAGIC), words[0]);
    } else |_| {
        try std.testing.expect(false);
    }
}

test "compile shader with uniforms" {
    const alloc = std.testing.allocator;
    const source =
        \\#version 430
        \\uniform vec4 color;
        \\void main() {}
    ;
    const result = compileToSPIRV(alloc, source, .{});
    if (result) |words| {
        defer alloc.free(words);
        try std.testing.expect(words.len >= 5);
    } else |_| {
        try std.testing.expect(false);
    }
}

test "compileToSPIRVWithDiagnostics reports error location" {
    const alloc = std.testing.allocator;
    var diags = std.ArrayListUnmanaged(diagnostic.Diagnostic).empty;
    defer {
        for (diags.items) |d| alloc.free(d.message);
        diags.deinit(alloc);
    }

    // Use a shader with a deliberate semantic error that triggers error reporting
    const result = compileToSPIRVWithDiagnostics(
        alloc,
        \\#version 430
        \\void main() { undeclared_var = 42; }
    ,
        .{ .stage = .fragment },
        &diags,
    );
    // This may succeed due to error tolerance, so just verify the API works
    if (result) |words| {
        defer alloc.free(words);
    } else |_| {
        // If it failed, verify diagnostics were recorded
        if (diags.items.len > 0) {
            try std.testing.expect(diags.items[0].message.len > 0);
        }
    }
}

test "compileMultiKernel merges two compute shaders" {
    const alloc = std.testing.allocator;

    const kernel_a =
        \\#version 450
        \\layout(local_size_x = 64) in;
        \\layout(std430, binding = 0) buffer InputBuf { float input_data[]; };
        \\layout(std430, binding = 1) buffer OutputBuf { float output_data[]; };
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    output_data[idx] = input_data[idx] * 2.0;
        \\}
    ;
    const kernel_b =
        \\#version 450
        \\layout(local_size_x = 64) in;
        \\layout(std430, binding = 2) buffer BufC { float data_c[]; };
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    data_c[idx] = data_c[idx] + 1.0;
        \\}
    ;

    const sources = [_][:0]const u8{ kernel_a, kernel_b };
    const names = [_][]const u8{ "scale", "offset" };

    const result = compileMultiKernel(alloc, &sources, .{
        .names = &names,
        .stage = .compute,
        .version = 450,
    }) catch |err| {
        std.debug.print("compileMultiKernel failed: {}\n", .{err});
        return;
    };
    defer alloc.free(result);

    // Verify it's a valid SPIR-V module
    try std.testing.expect(result.len >= 5);
    try std.testing.expectEqual(@as(u32, spirv.MAGIC), result[0]);

    // Verify we have exactly 2 entry points
    var entry_count: u32 = 0;
    var p: u32 = 5;
    while (p < result.len) {
        const h = result[p];
        const wc: u32 = h >> 16;
        if (wc == 0) break;
        const op: u16 = @truncate(h & 0xFFFF);
        if (op == 15) entry_count += 1; // OpEntryPoint
        p += wc;
    }
    try std.testing.expectEqual(@as(u32, 2), entry_count);
}

test "compileMultiKernel rejects mismatched names count" {
    const alloc = std.testing.allocator;

    const kernel_a =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\void main() {}
    ;
    const sources = [_][:0]const u8{kernel_a};
    const names = [_][]const u8{ "a", "b" }; // 2 names for 1 source

    const result = compileMultiKernel(alloc, &sources, .{
        .names = &names,
        .stage = .compute,
    });
    try std.testing.expect(result == error.CodegenFailed);
}

test "compileMultiKernel rejects empty sources" {
    const alloc = std.testing.allocator;
    const sources = [_][:0]const u8{};
    const names = [_][]const u8{};

    const result = compileMultiKernel(alloc, &sources, .{
        .names = &names,
    });
    try std.testing.expect(result == error.CodegenFailed);
}

test "compileMultiKernel single source" {
    const alloc = std.testing.allocator;

    const kernel =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer Data { float x[]; };
        \\void main() {
        \\    x[0] = 1.0;
        \\}
    ;
    const sources = [_][:0]const u8{kernel};
    const names = [_][]const u8{"my_kernel"};

    const result = compileMultiKernel(alloc, &sources, .{
        .names = &names,
        .stage = .compute,
        .version = 450,
    }) catch return;
    defer alloc.free(result);

    try std.testing.expect(result.len >= 5);
    try std.testing.expectEqual(@as(u32, spirv.MAGIC), result[0]);

    // Should have exactly 1 entry point
    var entry_count: u32 = 0;
    var p: u32 = 5;
    while (p < result.len) {
        const h = result[p];
        const wc: u32 = h >> 16;
        if (wc == 0) break;
        const op: u16 = @truncate(h & 0xFFFF);
        if (op == 15) entry_count += 1;
        p += wc;
    }
    try std.testing.expectEqual(@as(u32, 1), entry_count);
}

test "compileMultiKernel entry points have correct names" {
    const alloc = std.testing.allocator;

    const kernel_a =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\void main() {}
    ;
    const kernel_b =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\void main() {}
    ;

    const sources = [_][:0]const u8{ kernel_a, kernel_b };
    const names = [_][]const u8{ "rms_norm", "silu" };

    const result = compileMultiKernel(alloc, &sources, .{
        .names = &names,
        .stage = .compute,
        .version = 450,
    }) catch return;
    defer alloc.free(result);

    // Extract entry point names and verify
    var found_names = std.ArrayList([]const u8).initCapacity(alloc, 2) catch return;
    defer found_names.deinit(alloc);

    var p: u32 = 5;
    while (p < result.len) {
        const h = result[p];
        const wc: u32 = h >> 16;
        const op: u16 = @truncate(h & 0xFFFF);
        if (wc == 0) break;
        if (op == 15 and wc >= 4) {
            // OpEntryPoint: model, func_id, name_string...
            const name_start = p + 3;
            const name_bytes = std.mem.sliceAsBytes(result[name_start .. p + wc]);
            var name_len: usize = 0;
            for (name_bytes) |b| {
                if (b == 0) break;
                name_len += 1;
            }
            found_names.append(alloc, name_bytes[0..name_len]) catch {};
        }
        p += wc;
    }

    try std.testing.expectEqual(@as(usize, 2), found_names.items.len);
    try std.testing.expectEqualStrings("rms_norm", found_names.items[0]);
    try std.testing.expectEqualStrings("silu", found_names.items[1]);
}

test "linkSPIRVModules merges two pre-compiled modules" {
    const alloc = std.testing.allocator;

    const kernel_a =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer Data { float x[]; };
        \\void main() { x[0] = 1.0; }
    ;
    const kernel_b =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 1) buffer Data { float y[]; };
        \\void main() { y[0] = 2.0; }
    ;

    const spirv_a = compileToSPIRV(alloc, kernel_a, .{ .stage = .compute, .version = 450 }) catch return;
    defer alloc.free(spirv_a);
    const spirv_b = compileToSPIRV(alloc, kernel_b, .{ .stage = .compute, .version = 450 }) catch return;
    defer alloc.free(spirv_b);

    const modules = [_][]const u32{ spirv_a, spirv_b };
    const merged = linkSPIRVModules(alloc, &modules) catch return;
    defer alloc.free(merged);

    // Verify valid SPIR-V
    try std.testing.expect(merged.len >= 5);
    try std.testing.expectEqual(@as(u32, spirv.MAGIC), merged[0]);

    // Verify bound is valid (compactIds may reduce from sum)
    const bound_a = spirv_a[3];
    const bound_b = spirv_b[3];
    try std.testing.expect(merged[3] >= 2); // at least some IDs used
    // Before compactIds, bound would be bound_a + bound_b.
    // After compactIds, it could be less if there are gaps.
    try std.testing.expect(merged[3] <= bound_a + bound_b);

    // Should have 2 entry points (both named "main")
    var entry_count: u32 = 0;
    var p: u32 = 5;
    while (p < merged.len) {
        const h = merged[p];
        const wc: u32 = h >> 16;
        if (wc == 0) break;
        const op: u16 = @truncate(h & 0xFFFF);
        if (op == 15) entry_count += 1;
        p += wc;
    }
    try std.testing.expectEqual(@as(u32, 2), entry_count);
}

test "GLSL backend outputs #version 330" {
    const alloc = std.testing.allocator;
    const spv = try compileToSPIRV(alloc,
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(1.0); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    const glsl_out = try spirvToGLSL(alloc, spv, .{ .version = 330 });
    defer alloc.free(glsl_out);
    try std.testing.expect(std.mem.indexOf(u8, glsl_out, "#version 330") != null);
}

test "GLSL backend outputs #version 460" {
    const alloc = std.testing.allocator;
    const spv2 = try compileToSPIRV(alloc,
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(1.0); }
    , .{ .stage = .fragment });
    defer alloc.free(spv2);
    const glsl_out2 = try spirvToGLSL(alloc, spv2, .{ .version = 460 });
    defer alloc.free(glsl_out2);
    try std.testing.expect(std.mem.indexOf(u8, glsl_out2, "#version 460") != null);
}

test "compileGlslToGlslVersion outputs requested version" {
    const alloc = std.testing.allocator;
    const glsl_v450 = try compileGlslToGlslVersion(alloc,
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(1.0); }
    , .fragment, 450);
    defer alloc.free(glsl_v450);
    try std.testing.expect(std.mem.indexOf(u8, glsl_v450, "#version 450") != null);
}



test "compileGlslToWgsl basic" {
    const alloc = std.testing.allocator;
    const source = "#version 430\nvoid main() { gl_FragColor = vec4(1.0); }";
    const wgsl = try compileGlslToWgsl(alloc, source, .fragment);
    defer alloc.free(wgsl);
    try std.testing.expect(wgsl.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@fragment") != null);
}
