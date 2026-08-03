// SPDX-License-Identifier: MIT OR Apache-2.0
//! `#include` resolution tests.
//!
//! Two properties are under test, and both are security- or correctness-critical:
//!
//!   1. CONTAINMENT. Shader source is untrusted input (wintty users load ricing
//!      shaders off the internet), so an include must not be able to read a file
//!      outside the directory of the including file or a configured `-I` root.
//!      Traversal, absolute and drive-rooted spellings are refused before any
//!      I/O; a symlink that points out of the root is refused after the
//!      candidate path is canonicalized.
//!   2. INCLUDE-ONCE IS OPT-IN. Cycle detection is keyed on the resolved path
//!      and behaves as an ACTIVE include stack, so a header included twice is
//!      included twice (C and GLSL semantics) unless it says `#pragma once`.
//!      The old token-keyed permanent set silently dropped the second inclusion,
//!      which compiles with missing declarations: a silent wrong answer.
//!
//! The preprocessor is an internal module, so it is imported directly rather
//! than through the public `zioshade` surface (see build.zig).

const std = @import("std");
/// Imported as its own module: a Zig source file may belong to only one module,
/// so this test cannot also pull in the public `zioshade` module (which owns
/// src/preprocessor.zig). `lexer` and `compat` are re-exported from here for the
/// same reason, and so the token type matches what `process` expects.
const preprocessor = @import("preprocessor");
const lexer = preprocessor.lexer;
const compat = preprocessor.compat;

const alloc = std.testing.allocator;

// ---------------------------------------------------------------------------
// Temp-tree scaffolding
// ---------------------------------------------------------------------------

/// A per-test include tree under the system temp dir:
///
///   <base>/root/     the include root (and the directory of the including file)
///   <base>/outside/  a sibling the include root must never reach
const Tree = struct {
    base: []u8,
    root: []u8,
    outside: []u8,

    fn create(name: []const u8) !Tree {
        // Per-run-unique so concurrent test binaries do not race on one path.
        const token = compat.randomInt(u64);
        const base = try compat.tempFilePathFmt(alloc, "zioshade_include_{s}_{x}", .{ name, token });
        errdefer alloc.free(base);
        try compat.makeDirAbsolute(alloc, base);

        const root = try std.fs.path.join(alloc, &.{ base, "root" });
        errdefer alloc.free(root);
        try compat.makeDirAbsolute(alloc, root);

        const outside = try std.fs.path.join(alloc, &.{ base, "outside" });
        errdefer alloc.free(outside);
        try compat.makeDirAbsolute(alloc, outside);

        return .{ .base = base, .root = root, .outside = outside };
    }

    /// Absolute path of `name` under `dir`. Caller owns.
    fn pathIn(dir: []const u8, name: []const u8) ![]u8 {
        return std.fs.path.join(alloc, &.{ dir, name });
    }

    fn writeIn(dir: []const u8, name: []const u8, data: []const u8) ![]u8 {
        const p = try pathIn(dir, name);
        errdefer alloc.free(p);
        try compat.writeFileAbsolute(alloc, p, data);
        return p;
    }

    /// Best-effort cleanup: leftovers live under the system temp dir, so a
    /// failure here must not fail the test that was actually being run.
    fn destroy(self: *Tree, files: []const []const u8) void {
        for (files) |f| compat.deleteFileAbsolute(alloc, f) catch {};
        deleteDirAbsolute(self.outside) catch {};
        deleteDirAbsolute(self.root) catch {};
        deleteDirAbsolute(self.base) catch {};
        alloc.free(self.outside);
        alloc.free(self.root);
        alloc.free(self.base);
    }
};

/// `std.fs.deleteDirAbsolute` moved behind `std.Io` on 0.16. Local to the tests,
/// so it stays out of src/compat.zig.
fn deleteDirAbsolute(abs_path: []const u8) !void {
    if (compat.is_0_16) {
        var main_io = compat.MainIo().init(alloc);
        defer main_io.deinit();
        return std.Io.Dir.deleteDirAbsolute(main_io.io(), abs_path);
    } else {
        return std.fs.deleteDirAbsolute(abs_path);
    }
}

/// `std.fs.symLinkAbsolute` moved behind `std.Io` on 0.16. Same reasoning.
fn symLinkAbsolute(target_path: []const u8, link_path: []const u8) !void {
    if (compat.is_0_16) {
        var main_io = compat.MainIo().init(alloc);
        defer main_io.deinit();
        return std.Io.Dir.symLinkAbsolute(main_io.io(), target_path, link_path, .{});
    } else {
        return std.fs.symLinkAbsolute(target_path, link_path, .{});
    }
}

/// Run the preprocessor over `source` with the given including-file path and
/// `-I` roots. The caller inspects `pp` afterwards, so `pp` is caller-owned.
fn run(
    pp: *preprocessor.Preprocessor,
    source_file_path: []const u8,
    include_paths: []const []const u8,
    source: [:0]const u8,
) ![]const lexer.Token {
    pp.source_file_path = source_file_path;
    pp.include_paths = include_paths;
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    return pp.process(source, tokens);
}

// ---------------------------------------------------------------------------
// Containment: refused spellings
// ---------------------------------------------------------------------------

test "include: a `..` traversal is refused and the file is never read" {
    var tree = Tree.create("traversal") catch return error.SkipZigTest;
    const secret = try Tree.writeIn(tree.outside, "secret.glsl", "#define LEAKED 1\n");
    defer alloc.free(secret);
    const main_path = try Tree.pathIn(tree.root, "main.glsl");
    defer alloc.free(main_path);
    defer tree.destroy(&.{secret});

    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();

    const source: [:0]const u8 = "#include \"../outside/secret.glsl\"\nvoid main() {}";
    try std.testing.expectError(error.UnsafeIncludePath, run(&pp, main_path, &.{}, source));

    // Refused before any I/O: nothing was read, and the caller sees the honest
    // error even through a best-effort `process(...) catch tokens`.
    try std.testing.expectEqual(@as(usize, 0), pp.included_sources.items.len);
    try std.testing.expect(pp.unresolved_include);
    try std.testing.expect(!pp.defines.contains("LEAKED"));
    try std.testing.expectEqualStrings("../outside/secret.glsl", pp.unsafe_include_path.?);
}

test "include: an absolute path is refused" {
    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();

    const source: [:0]const u8 = "#include \"/etc/passwd\"\nvoid main() {}";
    try std.testing.expectError(error.UnsafeIncludePath, run(&pp, "shaders/main.glsl", &.{}, source));
    try std.testing.expectEqual(@as(usize, 0), pp.included_sources.items.len);
    try std.testing.expect(pp.unresolved_include);
}

test "include: a Windows drive-rooted path is refused" {
    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();

    const source: [:0]const u8 = "#include \"C:/Windows/win.ini\"\nvoid main() {}";
    try std.testing.expectError(error.UnsafeIncludePath, run(&pp, "shaders/main.glsl", &.{}, source));
    try std.testing.expectEqual(@as(usize, 0), pp.included_sources.items.len);
}

test "include: a system include `<..>` is refused the same way" {
    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();

    // The policy is on the spelling, not on the bracket form: `<>` includes are
    // resolved against the `-I` roots, and traversal must not escape those either.
    const source: [:0]const u8 = "#include <../../../etc/passwd>\nvoid main() {}";
    try std.testing.expectError(error.UnsafeIncludePath, run(&pp, "", &.{"shaders"}, source));
    try std.testing.expectEqual(@as(usize, 0), pp.included_sources.items.len);
}

test "include: a symlink pointing out of the root is refused" {
    var tree = Tree.create("symlink") catch return error.SkipZigTest;
    const secret = try Tree.writeIn(tree.outside, "secret.glsl", "#define LEAKED 1\n");
    defer alloc.free(secret);
    const link = try Tree.pathIn(tree.root, "link.glsl");
    defer alloc.free(link);
    const main_path = try Tree.pathIn(tree.root, "main.glsl");
    defer alloc.free(main_path);

    // Platforms without symlink support (unprivileged Windows, some CI images)
    // cannot exercise the case the realpath check exists for.
    symLinkAbsolute(secret, link) catch {
        tree.destroy(&.{secret});
        // Skipped because this host cannot create a symlink; the spelling check
        // still covers `..` and absolute escapes on it.
        return error.SkipZigTest;
    };
    defer tree.destroy(&.{ secret, link });

    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();

    // The spelling is innocent; only canonicalization reveals the escape.
    const source: [:0]const u8 = "#include \"link.glsl\"\nvoid main() {}";
    try std.testing.expectError(error.UnsafeIncludePath, run(&pp, main_path, &.{}, source));
    try std.testing.expect(!pp.defines.contains("LEAKED"));
    try std.testing.expect(pp.unresolved_include);
}

// ---------------------------------------------------------------------------
// Containment: legitimate includes still resolve
// ---------------------------------------------------------------------------

test "include: a sibling header next to the source still resolves" {
    var tree = Tree.create("sibling") catch return error.SkipZigTest;
    const helper = try Tree.writeIn(tree.root, "helper.glsl", "#define HELPER_OK 1\n");
    defer alloc.free(helper);
    const main_path = try Tree.pathIn(tree.root, "main.glsl");
    defer alloc.free(main_path);
    defer tree.destroy(&.{helper});

    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();

    const source: [:0]const u8 = "#include \"helper.glsl\"\nvoid main() {}";
    const out = try run(&pp, main_path, &.{}, source);
    defer alloc.free(out);

    try std.testing.expect(!pp.unresolved_include);
    try std.testing.expect(pp.defines.contains("HELPER_OK"));
}

test "include: a header found through a `-I` root still resolves" {
    var tree = Tree.create("incroot") catch return error.SkipZigTest;
    const helper = try Tree.writeIn(tree.root, "helper.glsl", "#define ROOT_OK 1\n");
    defer alloc.free(helper);
    defer tree.destroy(&.{helper});

    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();

    // No including-file path, so resolution goes through the `-I` roots.
    const source: [:0]const u8 = "#include \"helper.glsl\"\nvoid main() {}";
    const out = try run(&pp, "", &.{tree.root}, source);
    defer alloc.free(out);

    try std.testing.expect(!pp.unresolved_include);
    try std.testing.expect(pp.defines.contains("ROOT_OK"));
}

// ---------------------------------------------------------------------------
// Include-once is opt-in
// ---------------------------------------------------------------------------

test "include: the same header twice without `#pragma once` is included twice" {
    var tree = Tree.create("twice") catch return error.SkipZigTest;
    const twice = try Tree.writeIn(tree.root, "twice.glsl", "#define TWICE_TOKEN 1\n");
    defer alloc.free(twice);
    const main_path = try Tree.pathIn(tree.root, "main.glsl");
    defer alloc.free(main_path);
    defer tree.destroy(&.{twice});

    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();

    // The `#undef` between the two includes is the discriminator: if the second
    // include is silently dropped (the old token-keyed permanent set), the macro
    // stays undefined and the shader compiles with a missing declaration.
    const source: [:0]const u8 =
        "#include \"twice.glsl\"\n" ++
        "#undef TWICE_TOKEN\n" ++
        "#include \"twice.glsl\"\n" ++
        "void main() {}";
    const out = try run(&pp, main_path, &.{}, source);
    defer alloc.free(out);

    try std.testing.expect(!pp.unresolved_include);
    try std.testing.expect(pp.defines.contains("TWICE_TOKEN"));
}

test "include: `#pragma once` still suppresses the second inclusion" {
    var tree = Tree.create("once") catch return error.SkipZigTest;
    const once = try Tree.writeIn(tree.root, "once.glsl", "#pragma once\n#define ONCE_TOKEN 1\n");
    defer alloc.free(once);
    const main_path = try Tree.pathIn(tree.root, "main.glsl");
    defer alloc.free(main_path);
    defer tree.destroy(&.{once});

    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();

    const source: [:0]const u8 =
        "#include \"once.glsl\"\n" ++
        "#undef ONCE_TOKEN\n" ++
        "#include \"once.glsl\"\n" ++
        "void main() {}";
    const out = try run(&pp, main_path, &.{}, source);
    defer alloc.free(out);

    try std.testing.expect(!pp.unresolved_include);
    // The second include was suppressed by the pragma, so the `#undef` stands.
    try std.testing.expect(!pp.defines.contains("ONCE_TOKEN"));
    try std.testing.expectEqual(@as(usize, 1), pp.pragma_once_files.count());
}

test "include: a genuine a -> b -> a cycle terminates with an honest error" {
    var tree = Tree.create("cycle") catch return error.SkipZigTest;
    const a = try Tree.writeIn(tree.root, "a.glsl", "#include \"b.glsl\"\n");
    defer alloc.free(a);
    const b = try Tree.writeIn(tree.root, "b.glsl", "#include \"a.glsl\"\n");
    defer alloc.free(b);
    const main_path = try Tree.pathIn(tree.root, "main.glsl");
    defer alloc.free(main_path);
    defer tree.destroy(&.{ a, b });

    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();

    const source: [:0]const u8 = "#include \"a.glsl\"\nvoid main() {}";
    try std.testing.expectError(error.IncludeCycle, run(&pp, main_path, &.{}, source));
    try std.testing.expect(pp.unresolved_include);
    // The active include stack is unwound on every exit path, error paths
    // included, so nothing is left behind to misreport a later inclusion.
    try std.testing.expectEqual(@as(usize, 0), pp.included_files.count());
}

test "include: two different files sharing a spelling under two roots both resolve" {
    var tree = Tree.create("collide") catch return error.SkipZigTest;
    // root/shared.glsl and outside/shared.glsl share a spelling but are distinct
    // files. Token-keyed bookkeeping collided them and dropped the second.
    const first = try Tree.writeIn(tree.root, "shared.glsl", "#define FIRST_ROOT 1\n");
    defer alloc.free(first);
    const second = try Tree.writeIn(tree.outside, "shared.glsl", "#define SECOND_ROOT 1\n");
    defer alloc.free(second);
    defer tree.destroy(&.{ first, second });

    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();

    // Both roots are configured; the first include takes root, then it is
    // removed from the search so the second include lands in outside.
    const source_first: [:0]const u8 = "#include \"shared.glsl\"\nvoid main() {}";
    const out_first = try run(&pp, "", &.{tree.root}, source_first);
    defer alloc.free(out_first);
    try std.testing.expect(pp.defines.contains("FIRST_ROOT"));

    const source_second: [:0]const u8 = "#include \"shared.glsl\"\nvoid main() {}";
    pp.include_paths = &.{tree.outside};
    const tokens_second = try lexer.tokenize(alloc, source_second);
    defer alloc.free(tokens_second);
    const out_second = try pp.process(source_second, tokens_second);
    defer alloc.free(out_second);

    try std.testing.expect(!pp.unresolved_include);
    try std.testing.expect(pp.defines.contains("SECOND_ROOT"));
}
