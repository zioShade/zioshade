const std = @import("std");
const lexer = @import("src/lexer.zig");
const parser = @import("src/parser.zig");

pub fn main() !void {
    const source = "void main() { float c = a + b; }";
    const alloc = std.heap.page_allocator;
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    
    std.debug.print("Tokens:\n", .{});
    for (tokens, 0..) |tok, i| {
        std.debug.print("  {}: {}\n", .{i, tok.tag});
    }
    
    var root = try parser.parse(alloc, source, tokens);
    defer parser.freeTree(alloc, &root);
    
    const func = root.body[0];
    const stmt = func.data.children[0];
    const init = stmt.data.children[0];
    
    std.debug.print("\nInit: tag={}\n", .{init.tag});
    std.debug.print("Init children len: {}\n", .{init.data.children.len});
    
    if (init.data.children.len >= 2) {
        const left = init.data.children[0];
        const right = init.data.children[1];
        if (left.tag == .identifier) {
            std.debug.print("Left: identifier, name={s}\n", .{left.data.name});
        } else {
            std.debug.print("Left: tag={}\n", .{left.tag});
        }
        if (right.tag == .identifier) {
            std.debug.print("Right: identifier, name={s}\n", .{right.data.name});
        } else {
            std.debug.print("Right: tag={}\n", .{right.tag});
        }
        
        if (left.tag == .binary_op) {
            std.debug.print("Left is binary_op with {} children\n", .{left.data.children.len});
            if (left.data.children.len >= 2) {
                const left_left = left.data.children[0];
                const left_right = left.data.children[1];
                if (left_left.tag == .identifier) {
                    std.debug.print("  Left-Left: identifier, name={s}\n", .{left_left.data.name});
                } else {
                    std.debug.print("  Left-Left: tag={}\n", .{left_left.tag});
                }
                if (left_right.tag == .identifier) {
                    std.debug.print("  Left-Right: identifier, name={s}\n", .{left_right.data.name});
                } else {
                    std.debug.print("  Left-Right: tag={}\n", .{left_right.tag});
                }
            }
        }
    }
}
