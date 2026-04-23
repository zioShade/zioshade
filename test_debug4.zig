const std = @import("std");
const lexer = @import("src/lexer.zig");
const parser = @import("src/parser.zig");

pub fn main() !void {
    const source = "void main() { float c = a + b; }";
    const alloc = std.heap.page_allocator;
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parser.parse(alloc, source, tokens);
    defer parser.freeTree(alloc, &root);
    
    const func = root.body[0];
    const stmt = func.data.children[0];
    std.debug.print("Statement tag: {}\n", .{stmt.tag});
    const init = stmt.data.children[0];
    std.debug.print("Init tag: {}, children.len={}\n", .{init.tag, init.data.children.len});
    
    if (init.data.children.len >= 2) {
        const left = init.data.children[0];
        const right = init.data.children[1];
        std.debug.print("Left: tag={}, children.len={}\n", .{left.tag, left.data.children.len});
        std.debug.print("Right: tag={}, children.len={}\n", .{right.tag, right.data.children.len});
        
        if (left.data.children.len >= 2) {
            const left_left = left.data.children[0];
            const left_right = left.data.children[1];
            std.debug.print("  Left-Left: tag={}\n", .{left_left.tag});
            std.debug.print("  Left-Right: tag={}\n", .{left_right.tag});
        }
    }
}
