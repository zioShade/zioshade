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
    const stmt3 = func.data.children[2];
    const init = stmt3.data.children[0];
    const left = init.data.children[0];
    
    std.debug.print("Left (should be 'a') tag: {}\n", .{left.tag});
    std.debug.print("Left children len: {}\n", .{left.data.children.len});
    if (left.data.children.len > 0) {
        std.debug.print("Left child 0 tag: {}\n", .{left.data.children[0].tag});
    }
}
