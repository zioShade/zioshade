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
    _ = alloc;
    _ = source;
    _ = options;
    return error.ParseFailed;
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

test "stub compiles" {
    const alloc = std.testing.allocator;
    const result = compileToSPIRV(alloc, "#version 430\nvoid main() {}", .{});
    try std.testing.expect(result == error.ParseFailed);
}
