// SPDX-License-Identifier: MIT OR Apache-2.0
//! `#include` resolution tests.
//!
//! The property under test is CONTAINMENT. Shader source is untrusted input
//! (wintty users load ricing shaders off the internet), so an include must not
//! be able to read a file outside the directory of the including file or a
//! configured `-I` root. Traversal, absolute and drive-rooted spellings are
//! refused before any I/O; a symlink that points out of the root is refused
//! after the candidate path is canonicalized.
//!
//! NOT under test here: `#include` once-only semantics. Cycle detection is keyed
//! on the include token text, which makes every include implicitly include-once
//! even without `#pragma once`. That is a known deviation from C and GLSL and it
//! is tracked separately: fixing it restores correct double inclusion, which is
//! exponential in include depth unless an expansion budget is designed in first.
//! See the backlog row in plans/README.md.
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

test "include: a symlink out of a `-I` root is refused BY NAME, not as not-found" {
    var tree = Tree.create("symlinkroot") catch return error.SkipZigTest;
    const secret = try Tree.writeIn(tree.outside, "secret.glsl", "#define LEAKED 1\n");
    defer alloc.free(secret);
    const link = try Tree.pathIn(tree.root, "link.glsl");
    defer alloc.free(link);

    symLinkAbsolute(secret, link) catch {
        tree.destroy(&.{secret});
        return error.SkipZigTest;
    };
    defer tree.destroy(&.{ secret, link });

    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();

    // Resolution goes through the `-I` roots, where a miss on one root is a
    // normal `continue`. A containment refusal must NOT be swallowed by that
    // loop: it has to reach the caller naming the offending include, the same
    // way a refused spelling does, rather than as a bare not-found.
    const source: [:0]const u8 = "#include \"link.glsl\"\nvoid main() {}";
    try std.testing.expectError(error.UnsafeIncludePath, run(&pp, "", &.{tree.root}, source));
    try std.testing.expect(!pp.defines.contains("LEAKED"));
    try std.testing.expect(pp.unresolved_include);
    try std.testing.expectEqualStrings("link.glsl", pp.unsafe_include_path.?);
}

test "include: a later `-I` root still wins over an earlier refused one" {
    var tree = Tree.create("rootorder") catch return error.SkipZigTest;
    const secret = try Tree.writeIn(tree.outside, "secret.glsl", "#define LEAKED 1\n");
    defer alloc.free(secret);
    const link = try Tree.pathIn(tree.root, "helper.glsl");
    defer alloc.free(link);

    symLinkAbsolute(secret, link) catch {
        tree.destroy(&.{secret});
        return error.SkipZigTest;
    };
    // The second root holds a legitimate file under the SAME spelling.
    const helper = try Tree.writeIn(tree.outside, "helper.glsl", "#define ROOT2_OK 1\n");
    defer alloc.free(helper);
    defer tree.destroy(&.{ secret, link, helper });

    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();

    // A refusal on the first root is sticky but not final: the search continues,
    // and a root that resolves the spelling legitimately still wins.
    const source: [:0]const u8 = "#include \"helper.glsl\"\nvoid main() {}";
    const out = try run(&pp, "", &.{ tree.root, tree.outside }, source);
    defer alloc.free(out);

    try std.testing.expect(!pp.unresolved_include);
    try std.testing.expect(pp.defines.contains("ROOT2_OK"));
    try std.testing.expect(!pp.defines.contains("LEAKED"));
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
// Containment must not change existing include-once or cycle behaviour
// ---------------------------------------------------------------------------

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

test "include: a self-referential cycle terminates" {
    var tree = Tree.create("cycle") catch return error.SkipZigTest;
    const a = try Tree.writeIn(tree.root, "a.glsl", "#include \"a.glsl\"\n#define A_SEEN 1\n");
    defer alloc.free(a);
    const main_path = try Tree.pathIn(tree.root, "main.glsl");
    defer alloc.free(main_path);
    defer tree.destroy(&.{a});

    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();

    // The containment checks sit in front of resolution, so they must not turn a
    // terminating cycle into a hang or an error. Behaviour is unchanged from
    // before this change: the `..`-free spelling passes the spelling check, then
    // the token-keyed `included_files` set stops the second visit of a.glsl, so
    // the file is seen once and no error is raised.
    const source: [:0]const u8 = "#include \"a.glsl\"\nvoid main() {}";
    const out = try run(&pp, main_path, &.{}, source);
    defer alloc.free(out);

    try std.testing.expect(!pp.unresolved_include);
    try std.testing.expect(pp.defines.contains("A_SEEN"));
}

// ---------------------------------------------------------------------------
// Content correctness: token text must outlive the include window
// ---------------------------------------------------------------------------
// The token-text address space has two regions: the top-level source, and the
// interned extra_strings reached via start >= top_source_len (what the parser
// reads through parserSource()). Tokens lexed from an INCLUDED file carry
// offsets relative to the included text, which is valid only while the include
// is being processed: once self.source is restored, an offset below
// top_source_len aliases the TOP source (silent-wrong text) and one at or above
// it indexes extra_strings where nothing was interned (out-of-bounds panic).
// The same aliasing runs the other way for macro bodies stored from the
// top-level stream and expanded inside an include. The tests in this section
// pin the rekeying that keeps every emitted token resolvable forever. The
// motivating shape is ghostty's `common.glsl`: `#include` before `#version`,
// content-heavy header, macros defined and used inside it.

/// Assert every `want` string appears as the text of some output token, read
/// the way the PARSER reads it: parserSource()[tok.start .. tok.start+len].
fn expectTokenTextsContain(
    pp: *preprocessor.Preprocessor,
    original: [:0]const u8,
    tokens: []const lexer.Token,
    want: []const []const u8,
) !void {
    const src = try pp.parserSource(original, alloc);
    defer if (src.ptr != original.ptr) alloc.free(src);
    for (want) |w| {
        var found = false;
        for (tokens) |t| {
            const text = src[t.start .. t.start + t.len];
            if (std.mem.eql(u8, text, w)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("missing token text '{s}'\n", .{w});
            return error.TestExpectedNotFound;
        }
    }
}

test "include: header tokens resolve after the include window" {
    // The header is much LONGER than the top-level source, so a token late in
    // the header has an offset at or above top_source_len: before rekeying,
    // getTokenText routed it into the interned region where nothing was
    // interned and panicked. The macro is also used at top level after the
    // include returns, which needs the stored body to resolve post-restore.
    var tree = try Tree.create("content");
    const hdr_path = try Tree.pathIn(tree.root, "hdr.glsl");
    defer alloc.free(hdr_path);
    const main_path = try Tree.pathIn(tree.root, "main.glsl");
    defer alloc.free(main_path);
    defer tree.destroy(&.{hdr_path});

    var hdr = std.ArrayListUnmanaged(u8).empty;
    defer hdr.deinit(alloc);
    try hdr.appendSlice(alloc, "#version 430 core\n#define HDR_VAL 41\n// ");
    try hdr.appendNTimes(alloc, 'x', 512);
    try hdr.appendSlice(alloc, "\nint hdr_use = HDR_VAL;\n");
    try compat.writeFileAbsolute(alloc, hdr_path, hdr.items);

    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();

    const source: [:0]const u8 = "#include \"hdr.glsl\"\nint top_use = HDR_VAL;\n";
    const out = try run(&pp, main_path, &.{}, source);
    defer alloc.free(out);

    // hdr_use's initializer expands to 41 inside the window; top_use's
    // initializer expands the SAME stored body after the window.
    try expectTokenTextsContain(&pp, source, out, &.{ "hdr_use", "top_use", "41", "int" });
}

test "include: top-level macro body resolves inside the include window" {
    // A macro defined in the top-level source and used INSIDE the header: its
    // stored body tokens are top-source-relative, which reads the wrong bytes
    // while self.source is swapped to the header.
    var tree = try Tree.create("topbody");
    const hdr_path = try Tree.writeIn(tree.root, "hdr.glsl", "#version 430 core\nint hdr_side = TOP_M;\n");
    defer alloc.free(hdr_path);
    const main_path = try Tree.pathIn(tree.root, "main.glsl");
    defer alloc.free(main_path);
    defer tree.destroy(&.{hdr_path});

    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();

    const source: [:0]const u8 = "#define TOP_M 3\n#include \"hdr.glsl\"\nint top_after = TOP_M;\n";
    const out = try run(&pp, main_path, &.{}, source);
    defer alloc.free(out);

    // Both expansions must read the body as "3" — one during the window, one
    // after it.
    try expectTokenTextsContain(&pp, source, out, &.{ "hdr_side", "3" });
}

test "include: spaced #define in a header stays an object macro" {
    // `#define HDR_SPACED (2+3)` — the paren is separated by a space, so this
    // is an OBJECT macro whose body is `(2+3)`. Whether a following `(` makes a
    // macro function-like is decided by token ADJACENCY (start == name.start +
    // name.len), so this test guards that the rekeying of header tokens keeps
    // adjacent tokens contiguous in the interned region.
    var tree = try Tree.create("spaced");
    const hdr_path = try Tree.writeIn(tree.root, "hdr.glsl", "#define HDR_SPACED (2+3)\n#define HDR_FN(x) ((x)+1)\n");
    defer alloc.free(hdr_path);
    const main_path = try Tree.pathIn(tree.root, "main.glsl");
    defer alloc.free(main_path);
    defer tree.destroy(&.{hdr_path});

    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();

    const source: [:0]const u8 = "#include \"hdr.glsl\"\nint a = HDR_SPACED;\nint b = HDR_FN(9);\n";
    const out = try run(&pp, main_path, &.{}, source);
    defer alloc.free(out);

    // HDR_SPACED expands to the object body ( 2 + 3 ); HDR_FN(9) substitutes
    // 9 into the function body. A misclassification of the spaced form would
    // leave HDR_SPACED unexpanded (bare identifier, no call), which the
    // contains-check on ")" would then miss.
    try expectTokenTextsContain(&pp, source, out, &.{ "(", "2", "+", "3", ")", "9" });
}
