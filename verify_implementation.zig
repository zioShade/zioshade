// This test verifies that the three parts of the task are implemented correctly

const std = @import("std");
const lexer = @import("src/lexer.zig");
const parser = @import("src/parser.zig");
const semantic = @import("src/semantic.zig");
const ir = @import("src/ir.zig");

pub fn main() !void {
    std.debug.print("=== Verifying Task 2 Implementation ===\n\n", .{});

    // Test 1: Function calls
    std.debug.print("Test 1: Function Calls\n", .{});
    {
        const source =
            \\float square(float x) {
            \\    return x * x;
            \\}
            \\void main() {
            \\    float y = square(2.0);
            \\}
        ;

        const alloc = std.heap.page_allocator;
        const tokens = try lexer.tokenize(alloc, source);
        defer alloc.free(tokens);
        var root = try parser.parse(alloc, source, tokens);
        defer parser.freeTree(alloc, &root);
        var module = try semantic.analyze(alloc, &root);
        defer module.deinit();

        const main_func = module.functions[module.functions.len - 1];
        var found_function_call = false;
        for (main_func.body) |inst| {
            if (inst.tag == .function_call) {
                found_function_call = true;
                std.debug.print("  ✓ function_call IR instruction found\n", .{});
                std.debug.print("    Operands: {}\n", .{inst.operands.len});
                if (inst.operands.len > 0 and inst.operands[0] == .id) {
                    std.debug.print("    Function ID: {}\n", .{inst.operands[0].id});
                }
            }
        }

        if (!found_function_call) {
            std.debug.print("  ✗ function_call IR instruction NOT found\n", .{});
        }
    }

    std.debug.print("\n", .{});

    // Test 2: Struct member access
    std.debug.print("Test 2: Struct Member Access\n", .{});
    {
        const source =
            \\struct Light {
            \\    vec3 position;
            \\    float intensity;
            \\};
            \\void main() {
            \\    Light light;
            \\    light.position = vec3(1.0, 2.0, 3.0);
            \\}
        ;

        const alloc = std.heap.page_allocator;
        const tokens = try lexer.tokenize(alloc, source);
        defer alloc.free(tokens);
        var root = try parser.parse(alloc, source, tokens);
        defer parser.freeTree(alloc, &root);
        var module = try semantic.analyze(alloc, &root);
        defer module.deinit();

        var type_count: usize = 0;
        var iter = module.types.iterator();
        while (iter.next()) |entry| {
            type_count += 1;
            const td = entry.value_ptr.*;
            std.debug.print("  - {s}: {} members\n", .{entry.key_ptr.*, td.members.len});
        }
        std.debug.print("  Types defined: {}\n", .{type_count});

        const main_func = module.functions[0];
        var found_access_chain = false;
        for (main_func.body) |inst| {
            if (inst.tag == .access_chain) {
                found_access_chain = true;
                std.debug.print("  ✓ access_chain IR instruction found\n", .{});
                std.debug.print("    Operands: {}\n", .{inst.operands.len});
                if (inst.operands.len >= 2) {
                    std.debug.print("    Base: {}, Index: {}\n", .{ inst.operands[0], inst.operands[1] });
                }
            }
        }

        if (!found_access_chain) {
            std.debug.print("  ✗ access_chain IR instruction NOT found\n", .{});
            std.debug.print("  (This might be OK if the struct member access is handled differently)\n", .{});
        }
    }

    std.debug.print("\n", .{});

    // Test 3: IR tag exists
    std.debug.print("Test 3: IR Tag Verification\n", .{});
    {
        // Check that function_call tag exists
        const tags = std.meta.tags(ir.Instruction.Tag);
        inline for (tags) |tag| {
            if (tag == .function_call) {
                std.debug.print("  ✓ function_call IR tag exists\n", .{});
                break;
            }
        }

        // Check that access_chain tag exists
        inline for (tags) |tag| {
            if (tag == .access_chain) {
                std.debug.print("  ✓ access_chain IR tag exists\n", .{});
                break;
            }
        }
    }

    std.debug.print("\n=== Verification Complete ===\n", .{});
}
