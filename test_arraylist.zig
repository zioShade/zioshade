const std = @import("std");
test "ArrayList init" {
    const alloc = std.testing.allocator;
    var list = std.ArrayList(u32).initCapacity(alloc, 0) catch unreachable;
    defer list.deinit(alloc);
    try list.append(alloc, 42);
}
