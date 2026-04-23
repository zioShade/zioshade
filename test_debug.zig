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
    std.debug.print("Function has {} children\n", .{func.data.children.len});
    
    // Check third statement (float c = a + b;)
    if (func.data.children.len >= 3) {
        const stmt3 = func.data.children[2];
        std.debug.print("Statement 3 tag: {}\n", .{stmt3.tag});
        if (stmt3.data.children.len > 0) {
            const init = stmt3.data.children[0];
            std.debug.print("Initializer tag: {}\n", .{init.tag});
            std.debug.print("Initializer children len: {}\n", .{init.data.children.len});
            if (init.data.children.len >= 2) {
                const left = init.data.children[0];
                const right = init.data.children[1];
                std.debug.print("Left tag: {}, Right tag: {}\n", .{left.tag, right.tag});
            }
        }
    }
}
