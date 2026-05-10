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

    // GLSL backend tests — run with: zig build test-glsl
    const glsl_test_step = b.step("test-glsl", "Run GLSL backend tests (GLSL → SPIR-V → GLSL pipeline)");
    const glsl_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/glsl_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    glsl_test_mod.addImport("glslpp", glslpp_mod);
    const run_glsl_tests = b.addRunArtifact(b.addTest(.{
        .name = "glsl-tests",
        .root_module = glsl_test_mod,
    }));
    glsl_test_step.dependOn(&run_glsl_tests.step);
    test_step.dependOn(&run_glsl_tests.step);

    // MSL backend tests — run with: zig build test-msl
    const msl_test_step = b.step("test-msl", "Run MSL backend tests (GLSL → SPIR-V → MSL pipeline)");
    const msl_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/msl_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    msl_test_mod.addImport("glslpp", glslpp_mod);
    const run_msl_tests = b.addRunArtifact(b.addTest(.{
        .name = "msl-tests",
        .root_module = msl_test_mod,
    }));
    msl_test_step.dependOn(&run_msl_tests.step);
    test_step.dependOn(&run_msl_tests.step);

    // Reference correctness tests - run with: zig build test-reference
    // Uses spirv-cross test shaders (Apache-2.0) + hand-crafted patterns
    const reference_test_step = b.step("test-reference", "Run reference correctness tests");
    const reference_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/reference_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    reference_test_mod.addImport("glslpp", glslpp_mod);
    const run_reference_tests = b.addRunArtifact(b.addTest(.{
        .name = "reference-tests",
        .root_module = reference_test_mod,
    }));
    reference_test_step.dependOn(&run_reference_tests.step);
    test_step.dependOn(&run_reference_tests.step);

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

    // Benchmark — run with: zig build bench
    const bench_step = b.step("bench", "Run wintty shader benchmark");
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench_wintty.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("glslpp", glslpp_mod);
    const bench_exe = b.addExecutable(.{
        .name = "bench-wintty",
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&run_bench.step);

    // Tool: dump SPIR-V binary — run with: zig build dump-spv
    const dump_spv_step = b.step("dump-spv", "Compile GLSL to SPIR-V binary");
    const dump_spv_mod = b.createModule(.{
        .root_source_file = b.path("tools/dump_spv.zig"),
        .target = target,
        .optimize = optimize,
    });
    dump_spv_mod.addImport("glslpp", glslpp_mod);
    const dump_spv_exe = b.addExecutable(.{
        .name = "dump-spv",
        .root_module = dump_spv_mod,
    });
    const run_dump_spv = b.addRunArtifact(dump_spv_exe);
    if (b.args) |a| {
        for (a) |arg| run_dump_spv.addArg(arg);
    }
    dump_spv_step.dependOn(&run_dump_spv.step);
}
