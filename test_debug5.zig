const std = @import("std");
const lexer = @import("src/lexer.zig");
const parser = @import("src/parser.zig");

pub fn main() !void {
    // Test with literals first
    const source1 = "void main() { float c = 1.0 + 2.0; }";
    const alloc = std.heap.page_allocator;
    const tokens1 = try lexer.tokenize(alloc, source1);
    defer alloc.free(tokens1);
    var root1 = try parser.parse(alloc, source1, tokens1);
    defer parser.freeTree(alloc, &root1);
    
    const func1 = root1.body[0];
    const stmt1 = func1.data.children[0];
    const init1 = stmt1.data.children[0];
    std.debug.print("With literals: Init tag={}, children.len={}\n", .{init1.tag, init1.data.children.len});
    if (init1.data.children.len >= 2) {
        const left1 = init1.data.children[0];
        const right1 = init1.data.children[1];
        std.debug.print("  Left: tag={}, children.len={}\n", .{left1.tag, left1.data.children.len});
        std.debug.print("  Right: tag={}, children.len={}\n", .{right1.tag, right1.data.children.len});
    }
    
    // Test with identifiers
    const source2 = "void main() { float a = 1.0; float b = 2.0; float c = a + b; }";
    const tokens2 = try lexer.tokenize(alloc, source2);
    defer alloc.free(tokens2);
    var root2 = try parser.parse(alloc, source2, tokens2);
    defer parser.freeTree(alloc, &root2);
    
    const func2 = root2.body[0];
    const stmt2 = func2.data.children[2];
    const init2 = stmt2.data.children[0];
    std.debug.print("\nWith identifiers: Init tag={}, children.len={}\n", .{init2.tag, init2.data.children.len});
    if (init2.data.children.len >= 2) {
        const left2 = init2.data.children[0];
        const right2 = init2.data.children[1];
        std.debug.print("  Left: tag={}, children.len={}\n", .{left2.tag, left2.data.children.len});
        std.debug.print("  Right: tag={}, children.len={}\n", .{right2.tag, right2.data.children.len});
    }
}
