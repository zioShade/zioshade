const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const glslpp_mod = b.createModule(.{
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
}
