const std = @import("std");
const lexer = @import("src/lexer.zig");
const parser = @import("src/parser.zig");
const semantic = @import("src/semantic.zig");

pub fn main() !void {
    const source = "void main() { float x = 1.0; }";
    const alloc = std.heap.page_allocator;
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parser.parse(alloc, source, tokens);
    defer parser.freeTree(alloc, &root);
    var module = try semantic.analyze(alloc, &root);
    defer module.deinit();
    
    const func = module.functions[0];
    std.debug.print("Function has {} instructions\n", .{func.body.len});
    
    for (func.body, 0..) |inst, i| {
        std.debug.print("Inst {}: tag={}, operands.len={}\n", .{i, inst.tag, inst.operands.len});
        if (inst.operands.len > 0) {
            const op = inst.operands[0];
            std.debug.print("  Operand 0: {}\n", .{op});
        }
    }
}
