const std = @import("std");
const lexer = @import("src/lexer.zig");
const parser = @import("src/parser.zig");
const semantic = @import("src/semantic.zig");
const codegen = @import("src/codegen.zig");

pub fn main() !void {
    const source =
        \\float square(float x) {
        \\    return x * x;
        \\}
        \\
        \\struct Light {
        \\    vec3 position;
        \\    float intensity;
        \\};
        \\
        \\void main() {
        \\    float x = 2.0;
        \\    float y = square(x);
        \\
        \\    Light light;
        \\    light.position = vec3(1.0, 2.0, 3.0);
        \\
        \\    vec3 pos = light.position;
        \\    float intensity = light.intensity;
        \\}
    ;

    const alloc = std.heap.page_allocator;
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parser.parse(alloc, source, tokens);
    defer parser.freeTree(alloc, &root);
    var module = try semantic.analyze(alloc, &root);
    defer module.deinit();

    std.debug.print("=== Module Info ===\n", .{});
    std.debug.print("Functions: {}\n", .{module.functions.len});
    std.debug.print("Globals: {}\n", .{module.globals.len});

    // Check square function
    for (module.functions) |func| {
        std.debug.print("\n=== Function: {s} ===\n", .{func.name});
        std.debug.print("Return type: {}\n", .{func.return_type});
        std.debug.print("Instructions: {}\n", .{func.body.len});

        var has_function_call = false;
        var has_access_chain = false;
        var has_store = false;

        for (func.body) |inst| {
            std.debug.print("  Inst: {}, operands.len={}, result_id={?}\n", .{ inst.tag, inst.operands.len, inst.result_id });

            if (inst.tag == .function_call) {
                has_function_call = true;
                std.debug.print("    -> FunctionCall detected!\n", .{});
                if (inst.operands.len > 0) {
                    if (inst.operands[0] == .id) {
                        std.debug.print("    -> Function ID: {}\n", .{inst.operands[0].id});
                    }
                }
            }

            if (inst.tag == .access_chain) {
                has_access_chain = true;
                std.debug.print("    -> AccessChain detected!\n", .{});
                if (inst.operands.len >= 2) {
                    std.debug.print("    -> Base ID: {}, Index: {}\n", .{ inst.operands[0], inst.operands[1] });
                }
            }

            if (inst.tag == .member_access_op) {
                has_access_chain = true;
                std.debug.print("    -> MemberAccessOp detected!\n", .{});
            }

            if (inst.tag == .store) {
                has_store = true;
            }
        }

        if (std.mem.eql(u8, func.name, "main")) {
            if (has_function_call) {
                std.debug.print("    *** Main function calls square()! ***\n", .{});
            }
            if (has_access_chain) {
                std.debug.print("    *** Main function uses member access! ***\n", .{});
            }
        }
    }

    // Generate SPIR-V
    std.debug.print("\n=== Generating SPIR-V ===\n", .{});
    const spirv_binary = try codegen.generate(alloc, &module, .fragment, .@"1.5");
    defer alloc.free(spirv_binary);

    std.debug.print("SPIR-V binary size: {} words\n", .{spirv_binary.len});

    // Check for OpFunctionCall (opcode 57)
    var has_op_function_call = false;
    var has_op_access_chain = false;
    var i: usize = 5; // Skip header

    while (i < spirv_binary.len) {
        const word = spirv_binary[i];
        const opcode: u16 = @truncate(word & 0xFFFF);
        const wc: u16 = @truncate((word >> 16) & 0xFFFF);

        if (opcode == 57) { // OpFunctionCall
            has_op_function_call = true;
            std.debug.print("Found OpFunctionCall at word {}\n", .{i});
            if (i + 3 < spirv_binary.len) {
                std.debug.print("  Result type: {}, Result ID: {}, Function ID: {}\n", .{ spirv_binary[i + 1], spirv_binary[i + 2], spirv_binary[i + 3] });
            }
        }

        if (opcode == 65) { // OpAccessChain
            has_op_access_chain = true;
            std.debug.print("Found OpAccessChain at word {}\n", .{i});
        }

        if (wc == 0 or wc > 100) {
            i += 1;
            continue;
        }
        i += wc;
    }

    if (has_op_function_call) {
        std.debug.print("\n*** SUCCESS: OpFunctionCall found in SPIR-V output! ***\n", .{});
    } else {
        std.debug.print("\n*** ERROR: OpFunctionCall NOT found in SPIR-V output! ***\n", .{});
    }

    if (has_op_access_chain) {
        std.debug.print("*** SUCCESS: OpAccessChain found in SPIR-V output! ***\n", .{});
    } else {
        std.debug.print("*** ERROR: OpAccessChain NOT found in SPIR-V output! ***\n", .{});
    }
}
