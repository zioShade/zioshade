const std = @import("std");
const glslpp = @import("src/root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    
    const source = @embedFile("tests/spirv-cross/front-facing.frag");
    var module = try glslpp.compileToSPIRV(alloc, source, .{});
    defer module.deinit();
    
    std.debug.print("Module next_id_start={}\n", .{module.next_id_start});
    std.debug.print("Module globals={}\n", .{module.globals.len});
    std.debug.print("Module functions={}\n", .{module.functions.len});
    for (module.functions, 0..) |func, i| {
        std.debug.print("  func[{}]: result_id={}, params={}, body={}\n", .{i, func.result_id, func.params.len, func.body.len});
    }
}
