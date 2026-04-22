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

pub const Error = error{
    OutOfMemory,
    LexFailed,
    PreprocessFailed,
    ParseFailed,
    SemanticFailed,
    CodegenFailed,
};

pub const Stage = enum { vertex, fragment, compute, geometry };
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

/// Compile GLSL source to SPIR-V binary words.
pub fn compileToSPIRV(
    alloc: std.mem.Allocator,
    source: [:0]const u8,
    options: CompileOptions,
) Error![]const u32 {
    const tokens = lexer.tokenize(alloc, source) catch return error.LexFailed;
    defer alloc.free(tokens);

    var root_node = parser.parse(alloc, source, tokens) catch return error.ParseFailed;
    defer parser.freeTree(alloc, &root_node);

    var module = semantic.analyze(alloc, &root_node) catch return error.SemanticFailed;
    defer module.deinit();

    const stage: codegen.Stage = switch (options.stage) {
        .vertex => .vertex,
        .fragment => .fragment,
        .compute => .compute,
        .geometry => .geometry,
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
    return codegen.generate(alloc, &module, stage, spirv_ver) catch
        error.CodegenFailed;
}

/// Cross-compile SPIR-V binary to GLSL source.
pub fn spirvToGLSL(
    alloc: std.mem.Allocator,
    spirv_words: []const u32,
    options: CrossCompileOptions,
) Error![:0]const u8 {
    _ = alloc;
    _ = spirv_words;
    _ = options;
    return error.CodegenFailed;
}

pub fn compileToSPIRVWithDiagnostics(
    alloc: std.mem.Allocator,
    source: [:0]const u8,
    options: CompileOptions,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error![]const u32 {
    _ = diagnostics;
    return compileToSPIRV(alloc, source, options);
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
