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

    const unit_tests = b.addTest(.{
        .name = "glslpp-tests",
        .root_module = glslpp_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run all tests").dependOn(&run_unit_tests.step);
}
