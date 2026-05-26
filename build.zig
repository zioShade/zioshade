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

    // CLI tool — build with: zig build cli
    const cli_step = b.step("cli", "Build the glslpp CLI tool");
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("glslpp", glslpp_mod);
    const cli_exe = b.addExecutable(.{
        .name = "glslpp",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);
    cli_step.dependOn(&cli_exe.step);

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

    // Reflection tests — run with: zig build test-reflection
    const refl_test_step = b.step("test-reflection", "Run SPIR-V reflection API tests");
    const refl_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/reflection_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    refl_test_mod.addImport("glslpp", glslpp_mod);
    const run_refl_tests = b.addRunArtifact(b.addTest(.{
        .root_module = refl_test_mod,
    }));
    refl_test_step.dependOn(&run_refl_tests.step);

    // Correctness tests (G1/G4/G10) — run with: zig build test-correctness
    const corr_test_step = b.step("test-correctness", "Run correctness tests for reflection, GLSL versions, HLSL SM5");
    const corr_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/correctness_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    corr_test_mod.addImport("glslpp", glslpp_mod);
    const run_corr_tests = b.addRunArtifact(b.addTest(.{
        .root_module = corr_test_mod,
    }));
    corr_test_step.dependOn(&run_corr_tests.step);

    // Diagnostic tests (G3) — run with: zig build test-diagnostic
    const diag_test_step = b.step("test-diagnostic", "Run diagnostic quality tests");
    const diag_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/diagnostic_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    diag_test_mod.addImport("glslpp", glslpp_mod);
    const run_diag_tests = b.addRunArtifact(b.addTest(.{
        .root_module = diag_test_mod,
    }));
    diag_test_step.dependOn(&run_diag_tests.step);

    const run_hlsl_tests = b.addRunArtifact(b.addTest(.{
        .name = "hlsl-tests",
        .root_module = hlsl_test_mod,
    }));
    hlsl_test_step.dependOn(&run_hlsl_tests.step);
    test_step.dependOn(&run_hlsl_tests.step);

    // DXC batch test — run with: zig build test-dxc
    const dxc_test_step = b.step("test-dxc", "Run DXC compilation test on all SPIR-V → HLSL outputs");
    const dxc_test_mod = b.createModule(.{
        .root_source_file = b.path("tools/dxc_batch_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    dxc_test_mod.addImport("glslpp", glslpp_mod);
    const dxc_exe = b.addExecutable(.{
        .name = "dxc-batch-test",
        .root_module = dxc_test_mod,
    });
    const run_dxc_test = b.addRunArtifact(dxc_exe);
    dxc_test_step.dependOn(&run_dxc_test.step);

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

    // WGSL backend tests — run with: zig build test-wgsl
    const wgsl_test_step = b.step("test-wgsl", "Run WGSL backend tests (GLSL → SPIR-V → WGSL pipeline)");
    const wgsl_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/wgsl_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    wgsl_test_mod.addImport("glslpp", glslpp_mod);
    const run_wgsl_tests = b.addRunArtifact(b.addTest(.{
        .name = "wgsl-tests",
        .root_module = wgsl_test_mod,
    }));
    wgsl_test_step.dependOn(&run_wgsl_tests.step);
    test_step.dependOn(&run_wgsl_tests.step);

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

    // Optimizer regression tests
    const opt_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/optimizer_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    opt_test_mod.addImport("glslpp", glslpp_mod);
    const run_opt_tests = b.addRunArtifact(b.addTest(.{
        .name = "optimizer-tests",
        .root_module = opt_test_mod,
    }));
    test_step.dependOn(&run_opt_tests.step);

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

    // Mesh/task regression tests (bugs fixed during conformance hardening)
    const mesh_reg_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/mesh_regression_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    mesh_reg_test_mod.addImport("glslpp", glslpp_mod);
    const run_mesh_reg_tests = b.addRunArtifact(b.addTest(.{
        .name = "mesh-reg-tests",
        .root_module = mesh_reg_test_mod,
    }));
    test_step.dependOn(&run_mesh_reg_tests.step);

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
    const bench_step = b.step("bench", "Run quick shader benchmark");
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench_quick.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("glslpp", glslpp_mod);
    const bench_exe = b.addExecutable(.{
        .name = "bench-quick",
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

    // Tool: SPIR-V to GLSL — run with: zig build spv-to-glsl -- <input.spv> <output.glsl>
    const spv_to_glsl_step = b.step("spv-to-glsl", "Convert SPIR-V to GLSL via glslpp");
    const spv_to_glsl_mod = b.createModule(.{
        .root_source_file = b.path("tools/spv_to_glsl.zig"),
        .target = target,
        .optimize = optimize,
    });
    spv_to_glsl_mod.addImport("glslpp", glslpp_mod);
    const spv_to_glsl_exe = b.addExecutable(.{
        .name = "spv-to-glsl",
        .root_module = spv_to_glsl_mod,
    });
    const run_spv_to_glsl = b.addRunArtifact(spv_to_glsl_exe);
    if (b.args) |a| {
        for (a) |arg| run_spv_to_glsl.addArg(arg);
    }
    spv_to_glsl_step.dependOn(&run_spv_to_glsl.step);

    // Tool: SPIR-V to HLSL — run with: zig build spv-to-hlsl -- <input.spv> <output.hlsl>
    const spv_to_hlsl_step = b.step("spv-to-hlsl", "Convert SPIR-V to HLSL via glslpp");
    const spv_to_hlsl_mod = b.createModule(.{
        .root_source_file = b.path("tools/spv_to_hlsl.zig"),
        .target = target,
        .optimize = optimize,
    });
    spv_to_hlsl_mod.addImport("glslpp", glslpp_mod);
    const spv_to_hlsl_exe = b.addExecutable(.{
        .name = "spv-to-hlsl",
        .root_module = spv_to_hlsl_mod,
    });
    const run_spv_to_hlsl = b.addRunArtifact(spv_to_hlsl_exe);
    if (b.args) |a| {
        for (a) |arg| run_spv_to_hlsl.addArg(arg);
    }
    spv_to_hlsl_step.dependOn(&run_spv_to_hlsl.step);

    // Tool: SPIR-V dump — compile GLSL through glslpp and dump SPIR-V binary
    const spv_dump_step = b.step("spv-dump", "Compile GLSL to SPIR-V via glslpp and dump binary");
    const spv_dump_mod = b.createModule(.{
        .root_source_file = b.path("tools/spv_dump.zig"),
        .target = target,
        .optimize = optimize,
    });
    spv_dump_mod.addImport("glslpp", glslpp_mod);
    const spv_dump_exe = b.addExecutable(.{
        .name = "spv-dump",
        .root_module = spv_dump_mod,
    });
    const run_spv_dump = b.addRunArtifact(spv_dump_exe);
    if (b.args) |a| {
        for (a) |arg| run_spv_dump.addArg(arg);
    }
    spv_dump_step.dependOn(&run_spv_dump.step);

    // Tool: Dump SPIR-V without optimization (for debugging optimizer bugs)
    const spv_noopt_step = b.step("spv-noopt", "Compile GLSL to unoptimized SPIR-V");
    const spv_noopt_mod = b.createModule(.{
        .root_source_file = b.path("tools/spv_dump_noopt.zig"),
        .target = target,
        .optimize = optimize,
    });
    spv_noopt_mod.addImport("glslpp", glslpp_mod);
    const spv_noopt_exe = b.addExecutable(.{
        .name = "spv-noopt",
        .root_module = spv_noopt_mod,
    });
    const run_spv_noopt = b.addRunArtifact(spv_noopt_exe);
    if (b.args) |a| {
        for (a) |arg| run_spv_noopt.addArg(arg);
    }
    spv_noopt_step.dependOn(&run_spv_noopt.step);

    // Tool: Fuzz test — generate random GLSL and validate through glslpp
    const fuzz_step = b.step("fuzz", "Run structured GLSL fuzzer");
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tools/fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_mod.addImport("glslpp", glslpp_mod);
    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz-test",
        .root_module = fuzz_mod,
    });
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    if (b.args) |a| {
        for (a) |arg| run_fuzz.addArg(arg);
    }
    fuzz_step.dependOn(&run_fuzz.step);

    // Real-world WGSL validation — run with: zig build test-realworld
    const realworld_step = b.step("test-realworld", "Run real-world WGSL validation (requires naga)");
    const realworld_mod = b.createModule(.{
        .root_source_file = b.path("tests/realworld_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    realworld_mod.addImport("glslpp", glslpp_mod);
    const realworld_exe = b.addExecutable(.{
        .name = "realworld-tests",
        .root_module = realworld_mod,
    });
    const run_realworld = b.addRunArtifact(realworld_exe);
    if (b.args) |a| {
        for (a) |arg| run_realworld.addArg(arg);
    }
    realworld_step.dependOn(&run_realworld.step);

    // Head-to-head benchmark — runs glslpp vs glslang+spirv-cross subprocess.
    // Build/run with: zig build bench-compare
    const bench_compare_step = b.step("bench-compare", "Run glslpp vs glslang+spirv-cross head-to-head benchmark");
    const bench_compare_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench_compare.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_compare_mod.addImport("glslpp", glslpp_mod);
    const bench_compare_exe = b.addExecutable(.{
        .name = "bench-compare",
        .root_module = bench_compare_mod,
    });
    const run_bench_compare = b.addRunArtifact(bench_compare_exe);
    if (b.args) |a| {
        for (a) |arg| run_bench_compare.addArg(arg);
    }
    bench_compare_step.dependOn(&run_bench_compare.step);

    // Examples — build with: zig build examples
    // Each example is a real installable executable that imports the glslpp
    // module so it cannot drift out of sync with the library API.
    const examples_step = b.step("examples", "Build the example programs in examples/");
    const example_names = .{ "glsl_to_hlsl", "reflect_uniforms" };
    inline for (example_names) |name| {
        const ex_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        ex_mod.addImport("glslpp", glslpp_mod);
        const ex_exe = b.addExecutable(.{
            .name = b.fmt("example-{s}", .{name}),
            .root_module = ex_mod,
        });
        const ex_install = b.addInstallArtifact(ex_exe, .{});
        examples_step.dependOn(&ex_install.step);
    }
}
