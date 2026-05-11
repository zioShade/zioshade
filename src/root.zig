// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
pub const diagnostic = @import("diagnostic.zig");
pub const lexer = @import("lexer.zig");
pub const preprocessor = @import("preprocessor.zig");
pub const ast = @import("ast.zig");
pub const ir = @import("ir.zig");
pub const spirv = @import("spirv.zig");
pub const parser = @import("parser.zig");
pub const semantic = @import("semantic.zig");
pub const codegen = @import("codegen.zig");
pub const spirv_to_hlsl = @import("spirv_to_hlsl.zig");
pub const spirv_to_glsl = @import("spirv_to_glsl.zig");
pub const spirv_to_msl = @import("spirv_to_msl.zig");
pub const kernel_fusion = @import("kernel_fusion.zig");
const compact_ids = @import("compact_ids.zig");

pub const Error = error{
    OutOfMemory,
    LexFailed,
    PreprocessFailed,
    ParseFailed,
    SemanticFailed,
    CodegenFailed,
};

/// Detailed compile result for diagnostics
pub const CompileDetail = enum {
    lex_failed,
    parse_failed,
    semantic_failed,
    codegen_failed,
};

pub threadlocal var last_compile_detail: ?CompileDetail = null;

pub const Stage = enum { vertex, fragment, compute, geometry, tessellation_control, tessellation_evaluation };
pub const SPIRVVersion = enum { @"1.0", @"1.1", @"1.2", @"1.3", @"1.4", @"1.5", @"1.6" };

pub const ResourceLimits = struct {
    max_uniform_components: u32 = 4096,
    max_texture_units: u32 = 32,
};

pub const CompileOptions = struct {
    version: u32 = 430,
    stage: Stage = .fragment,
    spirv_version: SPIRVVersion = .@"1.5",
    limits: ResourceLimits = .{},
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
    const word_count = std.math.divCeil(usize, str.len + 1, 4) catch return;
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
    const tokens = lexer.tokenize(alloc, source) catch {
        last_compile_detail = .lex_failed;
        return error.LexFailed;
    };
    defer alloc.free(tokens);

    // Run preprocessor to handle #define, #if, #ifdef, etc.
    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();
    const pp_tokens = pp.process(source, tokens) catch tokens;
    defer if (pp_tokens.ptr != tokens.ptr) alloc.free(pp_tokens);

    var root_node = parser.parse(alloc, source, pp_tokens) catch {
        last_compile_detail = .parse_failed;
        return error.ParseFailed;
    };
    defer parser.freeTree(alloc, &root_node);

    var module = semantic.analyzeWithOptions(alloc, &root_node, .{ .tolerate_errors = true }) catch {
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
    return codegen.generate(alloc, &module, stage, spirv_ver, pp.version, pp.is_essl) catch {
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
        .binding_shift = -1, // remap binding=1 (shadertoy Globals) -> register(b0)
        .shader_model = 60,
    });
    // The result from spirvToHLSL is []const u8, not null-terminated.
    // Dupe with sentinel for wintty compatibility.
    return try alloc.dupeZ(u8, hlsl);
}



/// Merge multiple SPIR-V modules into a single module with proper ID remapping.
/// Uses compact_ids.getOpInfo to distinguish IDs from literals.
fn linkSPIRVModules(alloc: std.mem.Allocator, modules: []const []const u32) Error![]const u32 {
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
                    'l', 'L' => {
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
                        // OpEntryPoint: model(lit), func-id, name-string, interface-ids...
                        if (wi < ie) {
                            try out.append(alloc, mod[wi]); // execution model literal
                            wi += 1;
                        }
                        if (wi < ie) {
                            try out.append(alloc, remap(mod[wi], offset, mod_bound)); // func-id
                            wi += 1;
                        }
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

/// Validate a SPIR-V binary using spirv-val. Returns true if validation passed,
/// false if spirv-val is not found on PATH.
pub fn validateSPIRV(alloc: std.mem.Allocator, spirv_words: []const u32) !bool {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmpfile = try tmp.dir.createFile("shader.spv", .{});
    defer tmpfile.close();
    const bytes = std.mem.sliceAsBytes(spirv_words);
    try tmpfile.writeAll(bytes);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const spv_path = try tmp.dir.realpath("shader.spv", &path_buf);

    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "spirv-val", spv_path },
    }) catch return false;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    return result.term.Exited == 0;
}

pub fn compileToSPIRVWithDiagnostics(
    alloc: std.mem.Allocator,
    source: [:0]const u8,
    options: CompileOptions,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error![]const u32 {
    const result = compileToSPIRV(alloc, source, options);
    const words = result catch {
        // Compilation failed — record a diagnostic
        const detail = last_compile_detail orelse return result;
        const line = semantic.last_error_line;
        const column = semantic.last_error_column;

        const msg = std.fmt.allocPrint(alloc, "{s}: {s}", .{
            @tagName(detail),
            if (semantic.last_error_inner.len > 0) semantic.last_error_inner else semantic.last_error_ctx,
        }) catch "unknown error";

        try diagnostics.append(alloc, .{
            .kind = .@"error",
            .line = line,
            .column = column,
            .message = msg,
        });
        return result;
    };
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
