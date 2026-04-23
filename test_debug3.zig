const std = @import("std");
const lexer = @import("src/lexer.zig");
const parser = @import("src/parser.zig");

pub fn main() !void {
    const source = "void main() { float a = 1.0; float b = 2.0; float c = a + b; }";
    const alloc = std.heap.page_allocator;
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parser.parse(alloc, source, tokens);
    defer parser.freeTree(alloc, &root);
    
    const func = root.body[0];
    
    // Check each statement
    for (func.data.children, 0..) |stmt, i| {
        std.debug.print("Statement {}: tag={}, children.len={}\n", .{i, stmt.tag, stmt.data.children.len});
        if (stmt.data.children.len > 0) {
            const init = stmt.data.children[0];
            std.debug.print("  Init: tag={}, children.len={}\n", .{init.tag, init.data.children.len});
        }
    }
}
