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

    // C ABI libraries (M7.2) — build with: zig build c-lib
    //
    // Produces both a static and a shared library so external consumers can
    // pick whichever suits their distribution model. The shared variant gets
    // a `_shared` suffix because on Windows both linkages emit a `.lib` file
    // (the shared one is the import library beside its `.dll`), and the two
    // would otherwise clobber each other in `zig-out/lib`. On ELF platforms
    // the static would be `libglslpp_c.a` and the shared
    // `libglslpp_c_shared.so`. Consumers pick the artifact they want.
    const c_abi_mod = b.createModule(.{
        .root_source_file = b.path("src/c_abi.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_abi_mod.addImport("glslpp", glslpp_mod);

    const c_abi_shared_mod = b.createModule(.{
        .root_source_file = b.path("src/c_abi.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_abi_shared_mod.addImport("glslpp", glslpp_mod);

    const c_lib_step = b.step("c-lib", "Build glslpp C ABI shared + static libraries");
    const c_static = b.addLibrary(.{
        .name = "glslpp_c",
        .root_module = c_abi_mod,
        .linkage = .static,
    });
    const c_shared = b.addLibrary(.{
        .name = "glslpp_c_shared",
        .root_module = c_abi_shared_mod,
        .linkage = .dynamic,
    });
    // Install only when the user explicitly asks for `zig build c-lib`,
    // not on every default build — both artifacts are >1m to compile.
    const install_c_static = b.addInstallArtifact(c_static, .{});
    const install_c_shared = b.addInstallArtifact(c_shared, .{});
    const install_c_headers = b.addInstallDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .header,
        .install_subdir = "",
    });
    c_lib_step.dependOn(&install_c_static.step);
    c_lib_step.dependOn(&install_c_shared.step);
    c_lib_step.dependOn(&install_c_headers.step);

    // C consumer example (M7.3) — build with: zig build c-example
    //
    // Compiles `examples/c/main.c` against the public C header and links it
    // against the static C ABI library. We pick the static handle so the
    // resulting executable runs without runtime DLL search-path concerns on
    // Windows (no need to copy `glslpp_c_shared.dll` next to the .exe).
    const c_example_step = b.step("c-example", "Build the C consumer example demonstrating the glslpp C ABI");
    const c_example_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    c_example_mod.link_libc = true;
    c_example_mod.addCSourceFile(.{
        .file = b.path("examples/c/main.c"),
        .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Wpedantic" },
    });
    c_example_mod.addIncludePath(b.path("include"));
    const c_example_exe = b.addExecutable(.{
        .name = "c-example",
        .root_module = c_example_mod,
    });
    c_example_exe.linkLibrary(c_static);
    b.installArtifact(c_example_exe);
    c_example_step.dependOn(&c_example_exe.step);

    // `zig build run-c-example` — actually execute the C consumer.
    const run_c_example_step = b.step("run-c-example", "Run the C ABI example");
    const run_c_example = b.addRunArtifact(c_example_exe);
    run_c_example_step.dependOn(&run_c_example.step);

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

    // Enumerate analyzer false-positive candidates — run with: zig build enumerate-fp
    // Walks all fixture suites, compiles each with tolerate+strict, reports divergences.
    const enumerate_step = b.step("enumerate-fp", "List analyzer false-positive candidates (strict vs tolerate)");
    const run_enumerate = b.addRunArtifact(runner_exe);
    run_enumerate.addArg("--strict-enumerate");
    enumerate_step.dependOn(&run_enumerate.step);

    // Continuous strict-gate — run with: zig build strict-gate
    // Walks all fixture suites, compiles each with compileToSPIRV (fail-loud after flip),
    // exits non-zero if any curated-valid fixture is newly rejected (FP regression).
    // Known-unsupported fixtures in KNOWN_UNSUPPORTED are counted as XFAIL (not failures).
    const strict_gate_step = b.step("strict-gate", "Verify no curated-valid fixtures are rejected by the fail-loud API");
    const run_strict_gate = b.addRunArtifact(runner_exe);
    run_strict_gate.addArg("--strict-gate");
    strict_gate_step.dependOn(&run_strict_gate.step);

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
    test_step.dependOn(&run_refl_tests.step);

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
    test_step.dependOn(&run_corr_tests.step);

    // Analyzer strict self-test — run with: zig build test-analyzer-strict
    const analyzer_strict_test_step = b.step("test-analyzer-strict", "Run analyzer strict-mode self-test (harness sanity check)");
    const analyzer_strict_mod = b.createModule(.{
        .root_source_file = b.path("tests/analyzer_strict_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    analyzer_strict_mod.addImport("glslpp", glslpp_mod);
    const run_analyzer_strict = b.addRunArtifact(b.addTest(.{
        .root_module = analyzer_strict_mod,
    }));
    analyzer_strict_test_step.dependOn(&run_analyzer_strict.step);
    test_step.dependOn(&run_analyzer_strict.step);

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
    test_step.dependOn(&run_diag_tests.step);

    // C ABI tests (M7.2) — run with: zig build test-c-abi
    const c_abi_test_step = b.step("test-c-abi", "Run C ABI export-wrapper tests");
    const c_abi_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/c_abi_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_abi_test_mod.addImport("glslpp", glslpp_mod);
    // The tests need access to the c_abi module by name so they can call
    // the exported wrappers directly.
    const c_abi_test_inner_mod = b.createModule(.{
        .root_source_file = b.path("src/c_abi.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_abi_test_inner_mod.addImport("glslpp", glslpp_mod);
    c_abi_test_mod.addImport("c_abi", c_abi_test_inner_mod);
    const run_c_abi_tests = b.addRunArtifact(b.addTest(.{
        .name = "c-abi-tests",
        .root_module = c_abi_test_mod,
    }));
    c_abi_test_step.dependOn(&run_c_abi_tests.step);
    test_step.dependOn(&run_c_abi_tests.step);

    // Specialization-constant cross-compile tests (M3) — run with: zig build test-spec-const
    const spec_test_step = b.step("test-spec-const", "Run specialization-constant cross-compile tests");
    const spec_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/spec_const_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    spec_test_mod.addImport("glslpp", glslpp_mod);
    const run_spec_tests = b.addRunArtifact(b.addTest(.{
        .root_module = spec_test_mod,
    }));
    spec_test_step.dependOn(&run_spec_tests.step);
    test_step.dependOn(&run_spec_tests.step);

    // WGSL packing + bitfield tests (M4) — run with: zig build test-wgsl-pack
    const wpack_test_step = b.step("test-wgsl-pack", "Run WGSL packing/bitfield cross-compile tests");
    const wpack_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/wgsl_packing_bitfield_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    wpack_test_mod.addImport("glslpp", glslpp_mod);
    const run_wpack_tests = b.addRunArtifact(b.addTest(.{
        .root_module = wpack_test_mod,
    }));
    wpack_test_step.dependOn(&run_wpack_tests.step);
    test_step.dependOn(&run_wpack_tests.step);

    // Semantic-level bitfield built-in tests — run with: zig build test-bitfield-builtin
    // Covers GLSL 400+ `bitfieldInsert` and `bitfieldExtract` (signed + unsigned)
    // including vector forms. Complements wgsl_packing_bitfield_tests (which
    // hand-crafts SPIR-V) by exercising the real semantic path end-to-end.
    const bitfield_test_step = b.step("test-bitfield-builtin", "Run GLSL bitfield built-in (bitfieldInsert/bitfieldExtract) tests");
    const bitfield_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/bitfield_builtin_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    bitfield_test_mod.addImport("glslpp", glslpp_mod);
    const run_bitfield_tests = b.addRunArtifact(b.addTest(.{
        .root_module = bitfield_test_mod,
    }));
    bitfield_test_step.dependOn(&run_bitfield_tests.step);
    test_step.dependOn(&run_bitfield_tests.step);

    const run_hlsl_tests = b.addRunArtifact(b.addTest(.{
        .name = "hlsl-tests",
        .root_module = hlsl_test_mod,
    }));
    hlsl_test_step.dependOn(&run_hlsl_tests.step);
    test_step.dependOn(&run_hlsl_tests.step);

    // DXC batch test (M5.3) — run with: zig build test-dxc [-- <dxc> <spv_dir> <sm>]
    // Stage-aware: detects each SPIR-V fixture's execution model and selects
    // the matching DXC target profile (ps_*, cs_*, ms_*, as_*); stages we don't
    // yet emit valid HLSL for (vertex/raygen/...) are reported as SKIP.
    // Defaults: dxc=C:/VulkanSDK/.../dxc.exe, spv_dir=tests/spirv_bins, sm=60.
    // Opt-in only: not wired into the main `test` step because it needs DXC.
    const dxc_test_step = b.step("test-dxc", "Run DXC compilation test on all SPIR-V → HLSL outputs (stage-aware)");
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
    // Forward extra `--` args so `zig build test-dxc -- <dxc> <spv_dir> <sm>` works.
    if (b.args) |a| {
        for (a) |arg| run_dxc_test.addArg(arg);
    }
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

    // Mesh codegen body tests (M5.2 v3 — OpStore emission for mesh outputs)
    const mesh_codegen_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/mesh_codegen_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    mesh_codegen_test_mod.addImport("glslpp", glslpp_mod);
    const run_mesh_codegen_tests = b.addRunArtifact(b.addTest(.{
        .name = "mesh-codegen-tests",
        .root_module = mesh_codegen_test_mod,
    }));
    test_step.dependOn(&run_mesh_codegen_tests.step);

    // HLSL mesh signature tests (M5.2: [OutputTopology] + mesh<> signature)
    const hlsl_mesh_test_step = b.step("test-hlsl-mesh", "Run HLSL mesh signature tests");
    const hlsl_mesh_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/hlsl_mesh_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    hlsl_mesh_test_mod.addImport("glslpp", glslpp_mod);
    const run_hlsl_mesh_tests = b.addRunArtifact(b.addTest(.{
        .name = "hlsl-mesh-tests",
        .root_module = hlsl_mesh_test_mod,
    }));
    hlsl_mesh_test_step.dependOn(&run_hlsl_mesh_tests.step);
    test_step.dependOn(&run_hlsl_mesh_tests.step);

    // HLSL vertex signature tests (M5.0: VS_INPUT/VS_OUTPUT + SV_Position;
    // M5.1: SM 5.0 POSITION vs SM 6.0 SV_Position differentiation)
    const hlsl_vertex_test_step = b.step("test-hlsl-vertex", "Run HLSL vertex signature tests");
    const hlsl_vertex_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/hlsl_vertex_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    hlsl_vertex_test_mod.addImport("glslpp", glslpp_mod);
    const run_hlsl_vertex_tests = b.addRunArtifact(b.addTest(.{
        .name = "hlsl-vertex-tests",
        .root_module = hlsl_vertex_test_mod,
    }));
    hlsl_vertex_test_step.dependOn(&run_hlsl_vertex_tests.step);
    test_step.dependOn(&run_hlsl_vertex_tests.step);

    // MSL argument-buffer tests (M6: --msl-argument-buffers option)
    const msl_argbuf_test_step = b.step("test-msl-argbuf", "Run MSL argument-buffer tests");
    const msl_argbuf_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/msl_argbuf_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    msl_argbuf_test_mod.addImport("glslpp", glslpp_mod);
    const run_msl_argbuf_tests = b.addRunArtifact(b.addTest(.{
        .name = "msl-argbuf-tests",
        .root_module = msl_argbuf_test_mod,
    }));
    msl_argbuf_test_step.dependOn(&run_msl_argbuf_tests.step);
    test_step.dependOn(&run_msl_argbuf_tests.step);

    // binding_shift tests (M8.3: binding_shift for GLSL/MSL/WGSL)
    const binding_shift_test_step = b.step("test-binding-shift", "Run binding_shift cross-compile tests");
    const binding_shift_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/binding_shift_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    binding_shift_test_mod.addImport("glslpp", glslpp_mod);
    const run_binding_shift_tests = b.addRunArtifact(b.addTest(.{
        .name = "binding-shift-tests",
        .root_module = binding_shift_test_mod,
    }));
    binding_shift_test_step.dependOn(&run_binding_shift_tests.step);
    test_step.dependOn(&run_binding_shift_tests.step);

    // Buffer reference extension tests (M8.2: GL_EXT_buffer_reference)
    const buffer_ref_test_step = b.step("test-buffer-ref", "Run buffer reference extension recognition tests");
    const buffer_ref_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/buffer_ref_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    buffer_ref_test_mod.addImport("glslpp", glslpp_mod);
    const run_buffer_ref_tests = b.addRunArtifact(b.addTest(.{
        .name = "buffer-ref-tests",
        .root_module = buffer_ref_test_mod,
    }));
    buffer_ref_test_step.dependOn(&run_buffer_ref_tests.step);
    test_step.dependOn(&run_buffer_ref_tests.step);

    // Scalar block layout tests (M8.1: GL_EXT_scalar_block_layout)
    const scalar_layout_test_step = b.step("test-scalar-layout", "Run scalar block layout tests");
    const scalar_layout_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/scalar_layout_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    scalar_layout_test_mod.addImport("glslpp", glslpp_mod);
    const run_scalar_layout_tests = b.addRunArtifact(b.addTest(.{
        .name = "scalar-layout-tests",
        .root_module = scalar_layout_test_mod,
    }));
    scalar_layout_test_step.dependOn(&run_scalar_layout_tests.step);
    test_step.dependOn(&run_scalar_layout_tests.step);

    // std430/std140 matrix layout tests: MatrixStride consistent with reserved
    // offsets, verified against glslangValidator -V.
    const std430_matrix_test_step = b.step("test-std430-matrix-layout", "Run std430/std140 matrix layout tests");
    const std430_matrix_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/std430_matrix_layout_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    std430_matrix_test_mod.addImport("glslpp", glslpp_mod);
    const run_std430_matrix_tests = b.addRunArtifact(b.addTest(.{
        .name = "std430-matrix-layout-tests",
        .root_module = std430_matrix_test_mod,
    }));
    std430_matrix_test_step.dependOn(&run_std430_matrix_tests.step);
    test_step.dependOn(&run_std430_matrix_tests.step);

    // Builtin-registration correctness tests (matrixCompMult, gl_PointCoord).
    // Assert real SPIR-V structure so tolerate-mode empty bodies fail loudly.
    const builtin_reg_test_step = b.step("test-builtin-reg", "Run semantic builtin-registration correctness tests");
    const builtin_reg_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/builtin_registration_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    builtin_reg_test_mod.addImport("glslpp", glslpp_mod);
    const run_builtin_reg_tests = b.addRunArtifact(b.addTest(.{
        .name = "builtin-reg-tests",
        .root_module = builtin_reg_test_mod,
    }));
    builtin_reg_test_step.dependOn(&run_builtin_reg_tests.step);
    test_step.dependOn(&run_builtin_reg_tests.step);

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

    // Library-vs-library benchmark: glslpp vs SPIRV-Cross, both in-process,
    // cross-compiling the same SPIR-V. Requires the Vulkan SDK's spirv-cross
    // static C-API libs; the prebuilt .libs are MSVC, so this exe targets the
    // msvc ABI (glslpp is pure Zig and recompiles cleanly for it).
    //   zig build lib-bench [-Dvulkan-sdk=<path>] -- --iters 2000
    const lib_bench_step = b.step("lib-bench", "Benchmark glslpp vs SPIRV-Cross (in-process, SPIR-V→GLSL/HLSL/MSL)");
    const vk_sdk = b.option([]const u8, "vulkan-sdk", "Vulkan SDK root (for spirv-cross libs/headers)") orelse "C:/VulkanSDK/1.4.341.1";
    const spvc_inc = b.fmt("{s}/Include/spirv_cross", .{vk_sdk});
    const spvc_lib = b.fmt("{s}/Lib", .{vk_sdk});
    const msvc_target = b.resolveTargetQuery(.{ .os_tag = .windows, .abi = .msvc });
    const glslpp_msvc = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = msvc_target,
        .optimize = .ReleaseFast,
    });
    const lib_bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/lib_bench.zig"),
        .target = msvc_target,
        .optimize = .ReleaseFast,
    });
    lib_bench_mod.addImport("glslpp", glslpp_msvc);
    lib_bench_mod.addIncludePath(.{ .cwd_relative = spvc_inc });
    const lib_bench_exe = b.addExecutable(.{ .name = "lib-bench", .root_module = lib_bench_mod });
    lib_bench_exe.linkLibC();
    lib_bench_exe.addLibraryPath(.{ .cwd_relative = spvc_lib });
    for ([_][]const u8{
        "spirv-cross-c",    "spirv-cross-core", "spirv-cross-glsl", "spirv-cross-hlsl",
        "spirv-cross-msl",  "spirv-cross-cpp",  "spirv-cross-reflect", "spirv-cross-util",
    }) |l| lib_bench_exe.linkSystemLibrary(l);
    const run_lib_bench = b.addRunArtifact(lib_bench_exe);
    if (b.args) |a| for (a) |arg| run_lib_bench.addArg(arg);
    lib_bench_step.dependOn(&run_lib_bench.step);

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

    // Tools migrated to Zig 0.15.2 + wired so they stay buildable (regression
    // guard): cross-validate (glslpp vs SPIRV-Cross dumps) and bench-wintty.
    inline for (.{
        .{ "cross-validate", "tools/cross_validate.zig", "Dump glslpp HLSL/GLSL/MSL/SPIR-V for a shader" },
        .{ "bench-wintty", "tools/bench_wintty.zig", "Benchmark the wintty CRT shader (50 iters)" },
    }) |t| {
        const step = b.step(t[0], t[2]);
        const mod = b.createModule(.{ .root_source_file = b.path(t[1]), .target = target, .optimize = optimize });
        mod.addImport("glslpp", glslpp_mod);
        const exe = b.addExecutable(.{ .name = t[0], .root_module = mod });
        const run = b.addRunArtifact(exe);
        if (b.args) |a| for (a) |arg| run.addArg(arg);
        step.dependOn(&run.step);
    }

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
