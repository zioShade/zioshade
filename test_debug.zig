const std = @import("std");
const lexer = @import("src/lexer.zig");
const parser = @import("src/parser.zig");
const semantic_mod = @import("src/semantic.zig");
const fs = std.fs;

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const file = try fs.cwd().openFile("tests/spirv-cross/pixel-interlock-ordered.frag", .{});
    defer file.close();
    const src = try file.readToEndAlloc(alloc, 10*1024*1024);
    defer alloc.free(src);
    const srcz = try alloc.dupeZ(u8, src);
    defer alloc.free(srcz);

    const tokens = try lexer.tokenize(alloc, srcz);
    defer alloc.free(tokens);
    std.debug.print("Tokens: {d}\n", .{tokens.len});

    var root_node = try parser.parse(alloc, srcz, tokens);
    defer parser.freeTree(alloc, &root_node);
    std.debug.print("AST body nodes: {d}\n", .{root_node.body.len});

    var module = semantic_mod.analyze(alloc, &root_node) catch {
        std.debug.print("\nSemantic FAILED: ctx={s} inner={s}\n", .{semantic_mod.last_error_ctx, semantic_mod.last_error_inner});
        return;
    };
    defer module.deinit();
    std.debug.print("\nSemantic SUCCESS!\n", .{});
}
