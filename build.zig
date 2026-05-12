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
        "kernel_fusion",
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

    // Cross-comparison tests: glslpp vs spirv-cross output
    // Run with: zig build test-cross-compare
    // Requires glslangValidator and spirv-cross in PATH
    const cross_compare_step = b.step("test-cross-compare", "Run cross-comparison tests (glslpp vs spirv-cross)");
    const cross_compare_mod = b.createModule(.{
        .root_source_file = b.path("tests/cross_compare_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    cross_compare_mod.addImport("glslpp", glslpp_mod);
    const run_cross_compare = b.addRunArtifact(b.addTest(.{
        .name = "cross-compare-tests",
        .root_module = cross_compare_mod,
    }));
    cross_compare_step.dependOn(&run_cross_compare.step);
    test_step.dependOn(&run_cross_compare.step);

    // Mesh/Task shader tests
    const mesh_task_test_step = b.step("test-mesh-task", "Run mesh/task shader compilation tests");
    const mesh_task_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/mesh_task_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    mesh_task_test_mod.addImport("glslpp", glslpp_mod);
    const run_mesh_task_tests = b.addRunArtifact(b.addTest(.{
        .name = "mesh-task-tests",
        .root_module = mesh_task_test_mod,
    }));
    mesh_task_test_step.dependOn(&run_mesh_task_tests.step);
    test_step.dependOn(&run_mesh_task_tests.step);

    // Ray tracing pipeline tests
    const ray_tracing_test_step = b.step("test-ray-tracing", "Run ray tracing pipeline tests");
    const ray_tracing_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/ray_tracing_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    ray_tracing_test_mod.addImport("glslpp", glslpp_mod);
    const run_ray_tracing_tests = b.addRunArtifact(b.addTest(.{
        .name = "ray-tracing-tests",
        .root_module = ray_tracing_test_mod,
    }));
    ray_tracing_test_step.dependOn(&run_ray_tracing_tests.step);
    test_step.dependOn(&run_ray_tracing_tests.step);

    // Tool: dump any shader — run with: zig build dump-shader -- <prefix.glsl> <shader.glsl> <output_prefix>
    // Generates .hlsl, .glsl, .msl, .spv
    const dump_shader_step = b.step("dump-shader", "Dump shader to all output formats (HLSL/GLSL/MSL/SPIR-V)");
    const dump_shader_mod = b.createModule(.{
        .root_source_file = b.path("tools/dump_shader.zig"),
        .target = target,
        .optimize = optimize,
    });
    dump_shader_mod.addImport("glslpp", glslpp_mod);
    const dump_shader_exe = b.addExecutable(.{
        .name = "dump-shader",
        .root_module = dump_shader_mod,
    });
    const run_dump_shader = b.addRunArtifact(dump_shader_exe);
    if (b.args) |a| {
        for (a) |arg| run_dump_shader.addArg(arg);
    }
    dump_shader_step.dependOn(&run_dump_shader.step);

    // Convenience: dump CRT shader (all formats)
    const dump_crt_all_step = b.step("dump-crt", "Dump CRT shader to HLSL/GLSL/MSL/SPIR-V");
    const run_dump_crt = b.addRunArtifact(dump_shader_exe);
    run_dump_crt.addArgs(&.{
        "tests/wintty/shadertoy_prefix.glsl",
        "tests/wintty/test_crt.glsl",
        "tests/wintty/crt_output",
    });
    dump_crt_all_step.dependOn(&run_dump_crt.step);

    // Convenience: dump focus shader (all formats)
    const dump_focus_step = b.step("dump-focus", "Dump focus shader to HLSL/GLSL/MSL/SPIR-V");
    const run_dump_focus = b.addRunArtifact(dump_shader_exe);
    run_dump_focus.addArgs(&.{
        "tests/wintty/shadertoy_prefix.glsl",
        "tests/wintty/test_focus.glsl",
        "tests/wintty/focus_output",
    });
    dump_focus_step.dependOn(&run_dump_focus.step);

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

    // DXC HLSL validation — run with: zig build validate-hlsl
    // Requires dxc.exe on PATH (from Vulkan SDK or Windows SDK)
    const validate_hlsl_step = b.step("validate-hlsl", "Validate wintty shader HLSL output with DXC");
    const dxc_run = b.addSystemCommand(&.{"dxc"});
    dxc_run.addArgs(&.{
        "-T", "ps_6_0",
        "-E", "main",
        "-Wno-ignored-attributes",
        "tests/wintty/crt_output.hlsl",
    });
    validate_hlsl_step.dependOn(&dxc_run.step);

    // Validate focus shader too
    const dxc_focus = b.addSystemCommand(&.{"dxc"});
    dxc_focus.addArgs(&.{
        "-T", "ps_6_0",
        "-E", "main",
        "-Wno-ignored-attributes",
        "tests/wintty/focus_output.hlsl",
    });
    validate_hlsl_step.dependOn(&dxc_focus.step);

    // glslangValidator GLSL validation — run with: zig build validate-glsl
    const validate_glsl_step = b.step("validate-glsl", "Validate wintty shader GLSL output with glslangValidator");
    const glsl_val_crt = b.addSystemCommand(&.{"glslangValidator", "-S", "frag", "tests/wintty/crt_output.glsl"});
    validate_glsl_step.dependOn(&glsl_val_crt.step);
    const glsl_val_focus = b.addSystemCommand(&.{"glslangValidator", "-S", "frag", "tests/wintty/focus_output.glsl"});
    validate_glsl_step.dependOn(&glsl_val_focus.step);

    // Run all validations — run with: zig build validate
    const validate_all_step = b.step("validate-all", "Validate all shader outputs (HLSL + GLSL)");
    validate_all_step.dependOn(&dxc_run.step);
    validate_all_step.dependOn(&dxc_focus.step);
    validate_all_step.dependOn(&glsl_val_crt.step);
    validate_all_step.dependOn(&glsl_val_focus.step);
}
