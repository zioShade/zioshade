const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const glslpp_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Expose as named module for consumers (e.g., wintty)
    _ = b.addModule("glslpp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "glslpp",
        .root_module = glslpp_mod,
    });
    b.installArtifact(lib);

    const test_step = b.step("test", "Run all tests");

    const run_unit_tests = b.addRunArtifact(b.addTest(.{
        .name = "glslpp-tests",
        .root_module = glslpp_mod,
    }));
    test_step.dependOn(&run_unit_tests.step);

    const module_files = .{
        "lexer",
        "preprocessor",
        "parser",
        "ast",
        "ir",
        "spirv",
        "semantic",
        "codegen",
        "diagnostic",
    };

    inline for (module_files) |name| {
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        const run_mod_tests = b.addRunArtifact(b.addTest(.{
            .name = b.fmt("{s}-tests", .{name}),
            .root_module = mod,
        }));
        test_step.dependOn(&run_mod_tests.step);
    }

    // SPIR-V validation step — run with: zig build validate
    // Requires spirv-val on PATH (from Vulkan SDK or SPIRV-Tools build).
    const validate_step = b.step("validate", "Run spirv-val on generated SPIR-V binaries");
    const validate_run = b.addSystemCommand(&.{"spirv-val"});
    validate_run.addArg("--help");
    validate_step.dependOn(&validate_run.step);

    // Shader conformance tests — run with: zig build conformance
    // Compiles real shaders from glslang/SPIRV-Cross/Ghostty and validates with spirv-val
    const conformance_step = b.step("conformance", "Run shader conformance tests (glslang + SPIRV-Cross + Ghostty)");
    const runner_mod = b.createModule(.{
        .root_source_file = b.path("tests/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    runner_mod.addImport("glslpp", glslpp_mod);
    const runner_exe = b.addExecutable(.{
        .name = "conformance-runner",
        .root_module = runner_mod,
    });
    const run_conformance = b.addRunArtifact(runner_exe);
    if (b.args) |args| {
        for (args) |arg| {
            run_conformance.addArg(arg);
        }
    }
    conformance_step.dependOn(&run_conformance.step);

    // "build-runner" step: just compile the runner, don't run it
    const build_runner_step = b.step("build-runner", "Build the conformance runner executable");
    build_runner_step.dependOn(&runner_exe.step);

    // HLSL backend tests — run with: zig build test-hlsl
    const hlsl_test_step = b.step("test-hlsl", "Run HLSL backend tests (GLSL → SPIR-V → HLSL pipeline)");
    const hlsl_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/hlsl_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    hlsl_test_mod.addImport("glslpp", glslpp_mod);
    const run_hlsl_tests = b.addRunArtifact(b.addTest(.{
        .name = "hlsl-tests",
        .root_module = hlsl_test_mod,
    }));
    hlsl_test_step.dependOn(&run_hlsl_tests.step);
    test_step.dependOn(&run_hlsl_tests.step);

    // Tool: dump CRT shader HLSL — run with: zig build dump-crt
    const dump_step = b.step("dump-crt", "Dump CRT shader HLSL output");
    const dump_mod = b.createModule(.{
        .root_source_file = b.path("tools/dump_crt_hlsl.zig"),
        .target = target,
        .optimize = optimize,
    });
    dump_mod.addImport("glslpp", glslpp_mod);
    const dump_exe = b.addExecutable(.{
        .name = "dump-crt",
        .root_module = dump_mod,
    });
    const run_dump = b.addRunArtifact(dump_exe);
    dump_step.dependOn(&run_dump.step);
}
