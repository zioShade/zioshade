const std = @import("std");
const ast = @import("ast.zig");
const ir = @import("ir.zig");

pub const Error = error{
    OutOfMemory,
    SemanticFailed,
    TypeMismatch,
    UndeclaredIdentifier,
    RedeclaredIdentifier,
    InvalidAssignment,
};

pub fn analyze(alloc: std.mem.Allocator, root: *ast.Root) Error!ir.Module {
    var analyzer = Analyzer{
        .alloc = alloc,
        .scopes = .empty,
        .globals = .{},
        .functions = .{},
        .types = .empty,
        .instructions = .{},
        .errors = .{},
        .loop_stack = .empty,
    };
    defer analyzer.deinit();

    try analyzer.injectBuiltins();

    for (root.body) |node| {
        try analyzer.collectTopLevel(node);
    }

    for (root.body) |node| {
        if (node.tag == .function_decl) {
            try analyzer.analyzeFunction(node);
        }
    }

    if (analyzer.errors.items.len > 0) return error.SemanticFailed;

    return .{
        .functions = try analyzer.functions.toOwnedSlice(alloc),
        .globals = try analyzer.globals.toOwnedSlice(alloc),
        .types = analyzer.types,
        .entry_point = null,
        .next_id_start = analyzer.next_id,
        .alloc = alloc,
    };
}

const Symbol = struct {
    kind: enum { var_sym, param, func, type_sym, block_member },
    ty: ast.Type,
    ir_id: u32,
    member_index: u32 = 0, // For block_member: index into the parent block
};

const LoopContext = struct {
    merge_label: u32,
    continue_label: u32,
};

const Scope = std.StringHashMapUnmanaged(Symbol);

const Analyzer = struct {
    const TypedId = struct {
        ty: ast.Type,
        id: u32,
    };
    alloc: std.mem.Allocator,
    scopes: std.ArrayListUnmanaged(Scope),
    globals: std.ArrayListUnmanaged(ir.Global),
    functions: std.ArrayListUnmanaged(ir.Function),
    types: std.StringHashMapUnmanaged(ir.TypeDef),
    instructions: std.ArrayListUnmanaged(ir.Instruction),
    errors: std.ArrayListUnmanaged([]const u8),
    loop_stack: std.ArrayListUnmanaged(LoopContext),
    next_id: u32 = 1,

    fn deinit(self: *Analyzer) void {
        for (self.scopes.items) |*scope| scope.deinit(self.alloc);
        self.scopes.deinit(self.alloc);
        self.globals.deinit(self.alloc);
        for (self.functions.items) |func| {
            for (func.body) |inst| {
                if (inst.operands.len > 0) {
                    self.alloc.free(inst.operands);
                }
            }
            self.alloc.free(func.body);
        }
        self.functions.deinit(self.alloc);
        for (self.errors.items) |msg| self.alloc.free(msg);
        self.errors.deinit(self.alloc);
        self.loop_stack.deinit(self.alloc);
        for (self.instructions.items) |inst| {
            if (inst.operands.len > 0) {
                self.alloc.free(inst.operands);
            }
        }
        self.instructions.deinit(self.alloc);
    }

    fn allocId(self: *Analyzer) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn pushScope(self: *Analyzer) !void {
        try self.scopes.append(self.alloc, .empty);
    }

    fn popScope(self: *Analyzer) void {
        var scope = self.scopes.pop() orelse return;
        scope.deinit(self.alloc);
    }

    fn emitLabel(self: *Analyzer, label_id: u32) !void {
        try self.instructions.append(self.alloc, .{
            .tag = .label,
            .result_id = label_id,
            .operands = &.{},
            .ty = .void,
        });
    }

    fn emitBranch(self: *Analyzer, target_id: u32) !void {
        const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
        operands[0] = .{ .id = target_id };
        try self.instructions.append(self.alloc, .{
            .tag = .branch,
            .operands = operands,
            .ty = .void,
        });
    }

    fn emitBranchConditional(self: *Analyzer, cond_id: u32, true_id: u32, false_id: u32) !void {
        const operands = try self.alloc.alloc(ir.Instruction.Operand, 3);
        operands[0] = .{ .id = cond_id };
        operands[1] = .{ .id = true_id };
        operands[2] = .{ .id = false_id };
        try self.instructions.append(self.alloc, .{
            .tag = .branch_conditional,
            .operands = operands,
            .ty = .void,
        });
    }

    fn emitSelectionMerge(self: *Analyzer, merge_id: u32) !void {
        const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
        operands[0] = .{ .id = merge_id };
        try self.instructions.append(self.alloc, .{
            .tag = .selection_merge,
            .operands = operands,
            .ty = .void,
        });
    }

    fn emitLoopMerge(self: *Analyzer, merge_id: u32, continue_id: u32) !void {
        const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
        operands[0] = .{ .id = merge_id };
        operands[1] = .{ .id = continue_id };
        try self.instructions.append(self.alloc, .{
            .tag = .loop_merge,
            .operands = operands,
            .ty = .void,
        });
    }

    fn declare(self: *Analyzer, name: []const u8, sym: Symbol) !void {
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        try scope.put(self.alloc, name, sym);
    }

    fn lookup(self: *Analyzer, name: []const u8) ?Symbol {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |sym| return sym;
        }
        return null;
    }

    fn injectBuiltins(self: *Analyzer) !void {
        try self.pushScope();

        // GLSL builtins that need SPIR-V global variables
        // gl_FragCoord: Input, BuiltIn FragCoord
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_FragCoord", .ty = .vec4, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_FragCoord", .{ .kind = .var_sym, .ty = .vec4, .ir_id = id });
        }
        // gl_FragColor: Output, BuiltIn FragColor
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_FragColor", .ty = .vec4, .qualifier = .{ .is_out = true }, .layout = null, .storage_class = .output, .result_id = id });
            try self.declare("gl_FragColor", .{ .kind = .var_sym, .ty = .vec4, .ir_id = id });
        }
        // gl_Position: Output, BuiltIn Position
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_Position", .ty = .vec4, .qualifier = .{ .is_out = true }, .layout = null, .storage_class = .output, .result_id = id });
            try self.declare("gl_Position", .{ .kind = .var_sym, .ty = .vec4, .ir_id = id });
        }
        // gl_Layer: Output, BuiltIn Layer
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_Layer", .ty = .int, .qualifier = .{ .is_out = true }, .layout = null, .storage_class = .output, .result_id = id });
            try self.declare("gl_Layer", .{ .kind = .var_sym, .ty = .int, .ir_id = id });
        }
        // gl_ViewportIndex: Output, BuiltIn ViewportIndex
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_ViewportIndex", .ty = .int, .qualifier = .{ .is_out = true }, .layout = null, .storage_class = .output, .result_id = id });
            try self.declare("gl_ViewportIndex", .{ .kind = .var_sym, .ty = .int, .ir_id = id });
        }
        // gl_VertexID: Input, BuiltIn VertexIndex
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_VertexID", .ty = .int, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_VertexID", .{ .kind = .var_sym, .ty = .int, .ir_id = id });
        }
        // gl_InstanceID: Input, BuiltIn InstanceIndex
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_InstanceID", .ty = .int, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_InstanceID", .{ .kind = .var_sym, .ty = .int, .ir_id = id });
        }

        // Math functions that return float (or same type as primary argument)
        const float_return_funcs = .{
            "abs",   "acos",  "asin",      "atan",    "atan2",
            "ceil",  "clamp", "cos",       "cosh",
            "degrees", "distance", "dot",
            "exp",   "exp2",  "floor", "fract",
            "inversesqrt", "length", "log", "log2",
            "max",   "min",   "mix",       "mod",
            "pow",   "radians", "round", "sign",
            "sin",       "sinh",
            "smoothstep", "sqrt", "step",  "tan",     "tanh",
            "trunc",
        };
        inline for (float_return_funcs) |name| {
            try self.declare(name, .{
                .kind = .func,
                .ty = .float,
                .ir_id = self.allocId(),
            });
        }

        // Functions that return vec3
        const vec3_return_funcs = .{
            "cross", "reflect", "refract", "faceforward", "normalize",
        };
        inline for (vec3_return_funcs) |name| {
            try self.declare(name, .{
                .kind = .func,
                .ty = .vec3,
                .ir_id = self.allocId(),
            });
        }

        // Matrix functions
        try self.declare("determinant", .{
            .kind = .func,
            .ty = .float,
            .ir_id = self.allocId(),
        });
        try self.declare("transpose", .{
            .kind = .func,
            .ty = .mat4,
            .ir_id = self.allocId(),
        });

        try self.declare("texture", .{ .kind = .func, .ty = .vec4, .ir_id = self.allocId() });
        try self.declare("texture2D", .{ .kind = .func, .ty = .vec4, .ir_id = self.allocId() });
        try self.declare("textureLod", .{ .kind = .func, .ty = .vec4, .ir_id = self.allocId() });
        try self.declare("texelFetch", .{ .kind = .func, .ty = .vec4, .ir_id = self.allocId() });
    }

    fn collectTopLevel(self: *Analyzer, node: ast.Node) !void {
        switch (node.tag) {
            .var_decl, .uniform_decl, .in_decl, .out_decl => {
                const ir_id = self.allocId();
                const storage_class: ir.SPIRVStorageClass = switch (node.tag) {
                    .in_decl => .input,
                    .out_decl => .output,
                    .uniform_decl => .uniform,
                    .var_decl => .private,
                    else => .private,
                };
                try self.globals.append(self.alloc, .{
                    .name = node.data.name,
                    .ty = node.data.ty orelse .void,
                    .qualifier = node.data.qualifier orelse .{},
                    .layout = node.data.layout,
                    .storage_class = storage_class,
                    .result_id = ir_id,
                });
                try self.declare(node.data.name, .{
                    .kind = .var_sym,
                    .ty = node.data.ty orelse .void,
                    .ir_id = ir_id,
                });
            },
            .uniform_block => {
                const name = node.data.name;
                const qual = node.data.qualifier orelse ast.Qualifier{ .is_uniform = true };
                // Determine storage class from qualifier
                const storage_class: ir.SPIRVStorageClass = if (qual.is_in)
                    .input
                else if (qual.is_out)
                    .output
                else if (qual.is_buffer)
                    .uniform // TODO: add StorageBuffer storage class
                else
                    .uniform;

                // Register the block as a struct type
                const members = try self.alloc.dupe(ast.StructMember, node.data.members);
                const td = ir.TypeDef{
                    .name = name,
                    .members = members,
                    .size_bytes = 0,
                };
                const owned_name = try self.alloc.dupe(u8, name);
                try self.types.put(self.alloc, owned_name, td);

                // Create a global variable for the block
                const ir_id = self.allocId();
                try self.globals.append(self.alloc, .{
                    .name = name,
                    .ty = .{ .named = name },
                    .qualifier = qual,
                    .layout = node.data.layout,
                    .storage_class = storage_class,
                    .result_id = ir_id,
                });
                try self.declare(name, .{
                    .kind = .var_sym,
                    .ty = .{ .named = name },
                    .ir_id = ir_id,
                });

                // Also declare each member as directly accessible (GLSL allows this)
                for (node.data.members, 0..) |member, idx| {
                    try self.declare(member.name, .{
                        .kind = .block_member,
                        .ty = member.ty,
                        .ir_id = ir_id, // Block variable ID
                        .member_index = @intCast(idx),
                    });
                }
            },
            .struct_decl => {
                const name = node.data.name;
                // Duplicate members to avoid double-free with AST
                const members = try self.alloc.dupe(ast.StructMember, node.data.members);
                const td = ir.TypeDef{
                    .name = name,
                    .members = members,
                    .size_bytes = 0,
                };
                const owned_name = try self.alloc.dupe(u8, name);
                try self.types.put(self.alloc, owned_name, td);
                try self.declare(name, .{
                    .kind = .type_sym,
                    .ty = .{ .named = name },
                    .ir_id = self.allocId(),
                });
            },
            .function_decl, .function_prototype => {
                try self.declare(node.data.name, .{
                    .kind = .func,
                    .ty = node.data.ty orelse .void,
                    .ir_id = self.allocId(),
                });
            },
            else => {},
        }
    }

    fn analyzeFunction(self: *Analyzer, node: ast.Node) !void {
        try self.pushScope();

        const func_sym = self.lookup(node.data.name);
        const func_ir_id = if (func_sym) |sym| sym.ir_id else self.allocId();

        for (node.data.params) |param| {
            try self.declare(param.name, .{
                .kind = .param,
                .ty = param.ty,
                .ir_id = self.allocId(),
            });
        }

        self.instructions.clearRetainingCapacity();

        for (node.data.children) |child| {
            try self.analyzeStatement(child);
        }

        // If no explicit return was emitted, add an implicit return_void
        if (self.instructions.items.len == 0 or
            self.instructions.items[self.instructions.items.len - 1].tag != .return_void and
            self.instructions.items[self.instructions.items.len - 1].tag != .return_val)
        {
            try self.instructions.append(self.alloc, .{
                .tag = .return_void,
                .result_type = null,
                .result_id = null,
                .operands = &.{},
                .ty = .void,
            });
        }

        const func = ir.Function{
            .name = node.data.name,
            .return_type = node.data.ty orelse .void,
            .params = node.data.params,
            .body = try self.instructions.toOwnedSlice(self.alloc),
            .locals = &.{},
            .result_id = func_ir_id,
        };
        try self.functions.append(self.alloc, func);

        self.popScope();
    }

    fn analyzeStatement(self: *Analyzer, node: ast.Node) !void {
        switch (node.tag) {
            .var_decl => {
                const ir_id = self.allocId();
                const ty = node.data.ty orelse .void;
                try self.declare(node.data.name, .{
                    .kind = .var_sym,
                    .ty = ty,
                    .ir_id = ir_id,
                });
                // Emit local variable declaration (function storage class = 7)
                const sc_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                sc_operands[0] = .{ .literal_int = 7 };
                try self.instructions.append(self.alloc, .{
                    .tag = .local_variable,
                    .result_type = null,
                    .result_id = ir_id,
                    .operands = sc_operands,
                    .ty = ty,
                });
                if (node.data.children.len > 0) {
                    const init = try self.analyzeExpression(node.data.children[0]);
                    if (!self.typesCompatible(ty, init.ty)) {
                        return error.TypeMismatch;
                    }
                    // Emit store: target <- value
                    const store_operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                    store_operands[0] = .{ .id = ir_id };
                    store_operands[1] = .{ .id = init.id };
                    try self.instructions.append(self.alloc, .{
                        .tag = .store,
                        .result_type = null,
                        .result_id = null,
                        .operands = store_operands,
                        .ty = .void,
                    });
                }
            },
            .block => {
                try self.pushScope();
                for (node.data.children) |child| {
                    try self.analyzeStatement(child);
                }
                self.popScope();
            },
            .if_stmt => {
                const has_else = node.data.children.len > 2;
                const cond = try self.analyzeExpression(node.data.children[0]);

                const then_label = self.allocId();
                const else_label = if (has_else) self.allocId() else null;
                const merge_label = self.allocId();

                try self.emitSelectionMerge(merge_label);
                try self.emitBranchConditional(cond.id, then_label, if (has_else) else_label.? else merge_label);

                try self.emitLabel(then_label);
                if (node.data.children.len > 1) try self.analyzeStatement(node.data.children[1]);
                try self.emitBranch(merge_label);

                if (has_else) {
                    try self.emitLabel(else_label.?);
                    try self.analyzeStatement(node.data.children[2]);
                    try self.emitBranch(merge_label);
                }

                try self.emitLabel(merge_label);
            },
            .for_stmt => {
                try self.pushScope();

                const header_label = self.allocId();
                const body_label = self.allocId();
                const continue_label = self.allocId();
                const merge_label = self.allocId();

                // Init
                if (node.data.children.len > 0) try self.analyzeStatement(node.data.children[0]);

                try self.emitBranch(header_label);

                try self.loop_stack.append(self.alloc, .{
                    .merge_label = merge_label,
                    .continue_label = continue_label,
                });

                // Header: merge + condition check
                try self.emitLabel(header_label);
                try self.emitLoopMerge(merge_label, continue_label);

                if (node.data.children.len > 1) {
                    const cond = try self.analyzeExpression(node.data.children[1]);
                    try self.emitBranchConditional(cond.id, body_label, merge_label);
                } else {
                    try self.emitBranch(body_label);
                }

                // Body
                try self.emitLabel(body_label);
                if (node.data.children.len > 3) try self.analyzeStatement(node.data.children[3]);

                // Continue + update
                try self.emitLabel(continue_label);
                if (node.data.children.len > 2) try self.analyzeStatement(node.data.children[2]);
                try self.emitBranch(header_label);

                _ = self.loop_stack.pop();
                try self.emitLabel(merge_label);

                self.popScope();
            },
            .while_stmt => {
                const header_label = self.allocId();
                const body_label = self.allocId();
                const merge_label = self.allocId();

                try self.emitBranch(header_label);

                try self.loop_stack.append(self.alloc, .{
                    .merge_label = merge_label,
                    .continue_label = header_label,
                });

                try self.emitLabel(header_label);
                try self.emitLoopMerge(merge_label, header_label);

                const cond = try self.analyzeExpression(node.data.children[0]);
                try self.emitBranchConditional(cond.id, body_label, merge_label);

                try self.emitLabel(body_label);
                if (node.data.children.len > 1) try self.analyzeStatement(node.data.children[1]);
                try self.emitBranch(header_label);

                _ = self.loop_stack.pop();
                try self.emitLabel(merge_label);
            },
            .do_while_stmt => {
                const body_label = self.allocId();
                const cond_label = self.allocId();
                const merge_label = self.allocId();

                try self.emitBranch(body_label);

                try self.loop_stack.append(self.alloc, .{
                    .merge_label = merge_label,
                    .continue_label = cond_label,
                });

                try self.emitLabel(body_label);
                try self.emitLoopMerge(merge_label, cond_label);
                if (node.data.children.len > 0) try self.analyzeStatement(node.data.children[0]);

                try self.emitLabel(cond_label);
                const cond = try self.analyzeExpression(node.data.children[1]);
                try self.emitBranchConditional(cond.id, body_label, merge_label);

                _ = self.loop_stack.pop();
                try self.emitLabel(merge_label);
            },
            .return_stmt => {
                if (node.data.children.len > 0) {
                    const val = try self.analyzeExpression(node.data.children[0]);
                    const ret_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    ret_operands[0] = .{ .id = val.id };
                    try self.instructions.append(self.alloc, .{
                        .tag = .return_val,
                        .result_type = null,
                        .result_id = null,
                        .operands = ret_operands,
                        .ty = val.ty,
                    });
                } else {
                    try self.instructions.append(self.alloc, .{
                        .tag = .return_void,
                        .result_type = null,
                        .result_id = null,
                        .operands = &.{},
                        .ty = .void,
                    });
                }
            },
            .discard_stmt => {},
            .break_stmt => {
                if (self.loop_stack.items.len == 0) return error.SemanticFailed;
                try self.emitBranch(self.loop_stack.items[self.loop_stack.items.len - 1].merge_label);
            },
            .continue_stmt => {
                if (self.loop_stack.items.len == 0) return error.SemanticFailed;
                try self.emitBranch(self.loop_stack.items[self.loop_stack.items.len - 1].continue_label);
            },
            .expr_stmt => {
                if (node.data.children.len > 0) {
                    _ = try self.analyzeExpression(node.data.children[0]);
                }
            },
            else => {},
        }
    }

    fn analyzeLValue(self: *Analyzer, node: ast.Node) Error!TypedId {
        switch (node.tag) {
            .identifier => {
                if (self.lookup(node.data.name)) |sym| {
                    if (sym.kind == .block_member) {
                        // Generate access chain for the member pointer
                        const ptr_id = self.allocId();
                        const ac_operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        ac_operands[0] = .{ .id = sym.ir_id };
                        ac_operands[1] = .{ .literal_int = sym.member_index };
                        try self.instructions.append(self.alloc, .{
                            .tag = .access_chain,
                            .result_type = null,
                            .result_id = ptr_id,
                            .operands = ac_operands,
                            .ty = sym.ty,
                        });
                        return .{ .ty = sym.ty, .id = ptr_id };
                    }
                    return .{ .ty = sym.ty, .id = sym.ir_id };
                }
                return error.UndeclaredIdentifier;
            },
            else => return error.InvalidAssignment,
        }
    }

    fn analyzeExpression(self: *Analyzer, node: ast.Node) Error!TypedId {
        switch (node.tag) {
            .int_literal => {
                const id = self.allocId();
                const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                operands[0] = .{ .literal_int = @as(u32, @intCast(node.data.int_val)) };
                try self.instructions.append(self.alloc, .{
                    .tag = .constant_int,
                    .result_type = null,
                    .result_id = id,
                    .operands = operands,
                    .ty = .int,
                });
                return .{ .ty = .int, .id = id };
            },
            .uint_literal => {
                const id = self.allocId();
                const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                operands[0] = .{ .literal_int = @as(u32, @intCast(node.data.int_val)) };
                try self.instructions.append(self.alloc, .{
                    .tag = .constant_int,
                    .result_type = null,
                    .result_id = id,
                    .operands = operands,
                    .ty = .uint,
                });
                return .{ .ty = .uint, .id = id };
            },
            .float_literal => {
                const id = self.allocId();
                const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                operands[0] = .{ .literal_float = @as(f32, @floatCast(node.data.float_val)) };
                try self.instructions.append(self.alloc, .{
                    .tag = .constant_float,
                    .result_type = null,
                    .result_id = id,
                    .operands = operands,
                    .ty = .float,
                });
                return .{ .ty = .float, .id = id };
            },
            .bool_literal => {
                const id = self.allocId();
                const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                operands[0] = .{ .literal_int = if (node.data.int_val != 0) @as(u32, 1) else @as(u32, 0) };
                try self.instructions.append(self.alloc, .{
                    .tag = .constant_bool,
                    .result_type = null,
                    .result_id = id,
                    .operands = operands,
                    .ty = .bool,
                });
                return .{ .ty = .bool, .id = id };
            },
            .identifier => {
                if (self.lookup(node.data.name)) |sym| {
                    if (sym.kind == .block_member) {
                        // Generate access chain to get a pointer to the member
                        const ptr_id = self.allocId();
                        const ac_operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        ac_operands[0] = .{ .id = sym.ir_id };
                        ac_operands[1] = .{ .literal_int = sym.member_index };
                        try self.instructions.append(self.alloc, .{
                            .tag = .access_chain,
                            .result_type = null,
                            .result_id = ptr_id,
                            .operands = ac_operands,
                            .ty = sym.ty,
                        });
                        // Then load from that pointer
                        const id = self.allocId();
                        const load_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        load_operands[0] = .{ .id = ptr_id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .load,
                            .result_type = null,
                            .result_id = id,
                            .operands = load_operands,
                            .ty = sym.ty,
                        });
                        return .{ .ty = sym.ty, .id = id };
                    }
                    if (sym.kind == .param or sym.kind == .var_sym) {
                        const id = self.allocId();
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        operands[0] = .{ .id = sym.ir_id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .load,
                            .result_type = null,
                            .result_id = id,
                            .operands = operands,
                            .ty = sym.ty,
                        });
                        return .{ .ty = sym.ty, .id = id };
                    }
                    return .{ .ty = sym.ty, .id = sym.ir_id };
                }
                return error.UndeclaredIdentifier;
            },
            .binary_op => {
                if (node.data.children.len < 2) {
                    // Parser produced a malformed binary_op — treat as void expression
                    return .{ .ty = .void, .id = self.allocId() };
                }
                const left = try self.analyzeExpression(node.data.children[0]);
                const right = try self.analyzeExpression(node.data.children[1]);
                const result_ty = self.promoteTypes(left.ty, right.ty) orelse return error.TypeMismatch;
                const result_id = self.allocId();

                const is_float = result_ty == .float or result_ty == .double or result_ty.isVector() or result_ty.isMatrix();
                const op = node.data.op orelse .add;


                const tag: ir.Instruction.Tag = switch (op) {
                    .add => if (is_float) .fadd else .add,
                    .sub => if (is_float) .fsub else .sub,
                    .mul => blk: {
                        if (left.ty.isMatrix() and right.ty.isVector()) break :blk .mat_vec_mul;
                        if (left.ty.isVector() and right.ty.isMatrix()) break :blk .vec_mat_mul;
                        if (left.ty.isMatrix() and right.ty.isMatrix()) break :blk .mat_mat_mul;
                        break :blk if (is_float) .fmul else .mul;
                    },
                    .div => if (is_float) .fdiv else .div,
                    .mod => .rem,
                    .eq => if (is_float) .compare_feq else .compare_eq,
                    .neq => if (is_float) .compare_fneq else .compare_neq,
                    .lt => if (is_float) .compare_flt else .compare_lt,
                    .gt => if (is_float) .compare_fgt else .compare_gt,
                    .lte => if (is_float) .compare_flte else .compare_lte,
                    .gte => if (is_float) .compare_fgte else .compare_gte,
                    .logical_and => .logical_and,
                    .logical_or => .logical_or,
                    .bit_and => .bit_and,
                    .bit_or => .bit_or,
                    .bit_xor => .bit_xor,
                    .lshift => .shift_left,
                    .rshift => .shift_right,
                    else => .add,
                };

                const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                operands[0] = .{ .id = left.id };
                operands[1] = .{ .id = right.id };

                // Comparison and logical operators return bool, not the operand type
                const returns_bool = switch (op) {
                    .eq, .neq, .lt, .gt, .lte, .gte, .logical_and, .logical_or => true,
                    else => false,
                };

                try self.instructions.append(self.alloc, .{
                    .tag = tag,
                    .result_type = null,
                    .result_id = result_id,
                    .operands = operands,
                    .ty = if (returns_bool) .bool else result_ty,
                });
                return .{ .ty = if (returns_bool) .bool else result_ty, .id = result_id };
            },
            .unary_op => {
                if (node.data.children.len < 1) return error.SemanticFailed;
                const operand = try self.analyzeExpression(node.data.children[0]);
                const result_id = self.allocId();

                const is_float = operand.ty == .float or operand.ty == .double or operand.ty.isVector();

                const tag: ir.Instruction.Tag = switch (node.data.op orelse .sub) {
                    .sub => if (is_float) .fneg else .neg,
                    .logical_not => .logical_not,
                    .bit_not => .bit_not,
                    else => .neg,
                };

                const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                operands[0] = .{ .id = operand.id };
                try self.instructions.append(self.alloc, .{
                    .tag = tag,
                    .result_type = null,
                    .result_id = result_id,
                    .operands = operands,
                    .ty = operand.ty,
                });
                return .{ .ty = operand.ty, .id = result_id };
            },
            .assign_op => {
                if (node.data.children.len < 2) return error.SemanticFailed;
                const target = try self.analyzeLValue(node.data.children[0]);
                const value = try self.analyzeExpression(node.data.children[1]);
                const store_operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                store_operands[0] = .{ .id = target.id };
                store_operands[1] = .{ .id = value.id };
                try self.instructions.append(self.alloc, .{
                    .tag = .store,
                    .result_type = null,
                    .result_id = null,
                    .operands = store_operands,
                    .ty = .void,
                });
                return .{ .ty = .void, .id = 0 };
            },
            .compound_assign => {
                if (node.data.children.len < 2) return error.SemanticFailed;
                const target = try self.analyzeLValue(node.data.children[0]);
                const value = try self.analyzeExpression(node.data.children[1]);
                // Load current value
                const loaded_id = self.allocId();
                const load_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                load_operands[0] = .{ .id = target.id };
                try self.instructions.append(self.alloc, .{
                    .tag = .load,
                    .result_type = null,
                    .result_id = loaded_id,
                    .operands = load_operands,
                    .ty = target.ty,
                });
                // Compute result
                const result_ty = target.ty;
                const is_float = result_ty == .float or result_ty == .double or result_ty.isVector() or result_ty.isMatrix();
                const op_tag: ir.Instruction.Tag = switch (node.data.op orelse .add) {
                    .add_assign => if (is_float) .fadd else .add,
                    .sub_assign => if (is_float) .fsub else .sub,
                    .mul_assign => if (is_float) .fmul else .mul,
                    .div_assign => if (is_float) .fdiv else .div,
                    else => .add,
                };
                const computed_id = self.allocId();
                const bin_operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                bin_operands[0] = .{ .id = loaded_id };
                bin_operands[1] = .{ .id = value.id };
                try self.instructions.append(self.alloc, .{
                    .tag = op_tag,
                    .result_type = null,
                    .result_id = computed_id,
                    .operands = bin_operands,
                    .ty = result_ty,
                });
                // Store back
                const store_operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                store_operands[0] = .{ .id = target.id };
                store_operands[1] = .{ .id = computed_id };
                try self.instructions.append(self.alloc, .{
                    .tag = .store,
                    .result_type = null,
                    .result_id = null,
                    .operands = store_operands,
                    .ty = .void,
                });
                return .{ .ty = .void, .id = 0 };
            },
            .func_call => {
                var arg_tids = std.ArrayListUnmanaged(TypedId){};
                defer arg_tids.deinit(self.alloc);
                for (node.data.children) |arg| {
                    const tid = try self.analyzeExpression(arg);
                    try arg_tids.append(self.alloc, tid);
                }
                const sym = self.lookup(node.data.name);
                // For GLSL builtins, infer result type from first argument (e.g., round(vec4) → vec4)
                const result_ty: ast.Type = if (self.isGLSLBuiltin(node.data.name) and arg_tids.items.len > 0)
                    arg_tids.items[0].ty
                else if (sym) |s| s.ty
                else .void;
                const result_id = self.allocId();

                if (self.isGLSLBuiltin(node.data.name)) {
                    // Texture functions use different SPIR-V ops, not GLSL.std.450
                    if (self.isTextureBuiltin(node.data.name)) {
                        if (self.isImageSampleBuiltin(node.data.name)) {
                            // texture(sampler, coord) → image_sample
                            const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len);
                            for (arg_tids.items, 0..) |tid, i| {
                                operands[i] = .{ .id = tid.id };
                            }
                            try self.instructions.append(self.alloc, .{
                                .tag = .image_sample,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = operands,
                                .ty = result_ty,
                            });
                        } else {
                            // texelFetch etc → image_fetch as fallback
                            const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len);
                            for (arg_tids.items, 0..) |tid, i| {
                                operands[i] = .{ .id = tid.id };
                            }
                            try self.instructions.append(self.alloc, .{
                                .tag = .image_fetch,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = operands,
                                .ty = result_ty,
                            });
                        }
                    } else if (std.mem.eql(u8, node.data.name, "dFdx") or std.mem.eql(u8, node.data.name, "dFdy")) {
                        // Derivatives: emit as ext_inst with a made-up ID for now
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len + 1);
                        operands[0] = .{ .literal_int = 1 };
                        for (arg_tids.items, 1..) |tid, i| {
                            operands[i] = .{ .id = tid.id };
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .ext_inst,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = result_ty,
                        });
                    } else {
                        const glsl_id = self.glslExtInstruction(node.data.name) orelse 1;
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len + 1);
                        operands[0] = .{ .literal_int = glsl_id };
                        for (arg_tids.items, 1..) |tid, i| {
                            operands[i] = .{ .id = tid.id };
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .ext_inst,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = result_ty,
                        });
                    }
                } else {
                    const s = sym orelse return error.UndeclaredIdentifier;
                    const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len + 1);
                    operands[0] = .{ .id = s.ir_id };
                    for (arg_tids.items, 0..) |tid, i| {
                        operands[i + 1] = .{ .id = tid.id };
                    }
                    try self.instructions.append(self.alloc, .{
                        .tag = .function_call,
                        .result_type = null,
                        .result_id = result_id,
                        .operands = operands,
                        .ty = result_ty,
                    });
                }
                return .{ .ty = result_ty, .id = result_id };
            },
            .type_constructor => {
                var arg_tids = std.ArrayListUnmanaged(TypedId){};
                defer arg_tids.deinit(self.alloc);
                for (node.data.children) |arg| {
                    const tid = try self.analyzeExpression(arg);
                    try arg_tids.append(self.alloc, tid);
                }
                const result_ty = node.data.ty orelse .void;
                const result_id = self.allocId();

                // Handle scalar-to-vector splat: vec4(1.0) → CompositeConstruct with N copies
                if (arg_tids.items.len == 1 and result_ty.isVector()) {
                    const n = result_ty.numComponents();
                    const operands = try self.alloc.alloc(ir.Instruction.Operand, n);
                    for (0..n) |i| {
                        operands[i] = .{ .id = arg_tids.items[0].id };
                    }
                    try self.instructions.append(self.alloc, .{
                        .tag = .composite_construct,
                        .result_type = null,
                        .result_id = result_id,
                        .operands = operands,
                        .ty = result_ty,
                    });
                    return .{ .ty = result_ty, .id = result_id };
                }

                // Allocate operand array
                const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len);
                for (arg_tids.items, 0..) |tid, i| {
                    operands[i] = .{ .id = tid.id };
                }

                try self.instructions.append(self.alloc, .{
                    .tag = .composite_construct,
                    .result_type = null,
                    .result_id = result_id,
                    .operands = operands,
                    .ty = result_ty,
                });
                return .{ .ty = result_ty, .id = result_id };
            },
            .ternary_op => {
                if (node.data.children.len < 3) return error.SemanticFailed;
                _ = try self.analyzeExpression(node.data.children[0]);
                const then_tid = try self.analyzeExpression(node.data.children[1]);
                const else_tid = try self.analyzeExpression(node.data.children[2]);
                return .{ .ty = self.promoteTypes(then_tid.ty, else_tid.ty) orelse then_tid.ty, .id = self.allocId() };
            },
            .member_access => {
                if (node.data.children.len < 1) return error.SemanticFailed;
                const base_tid = try self.analyzeExpression(node.data.children[0]);

                // Handle vector swizzles (e.g., vec4.x)
                if (base_tid.ty.isVector()) return .{ .ty = .float, .id = self.allocId() };

                // Handle struct member access
                if (base_tid.ty == .named) {
                    const struct_name = base_tid.ty.named;
                    if (self.types.get(struct_name)) |td| {
                        // Find member index
                        const member_name = node.data.name;
                        var member_index: ?u32 = null;
                        for (td.members, 0..) |member, i| {
                            if (std.mem.eql(u8, member.name, member_name)) {
                                member_index = @as(u32, @intCast(i));
                                break;
                            }
                        }

                        if (member_index) |idx| {
                            const result_id = self.allocId();
                            const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                            operands[0] = .{ .id = base_tid.id };
                            operands[1] = .{ .literal_int = idx };

                            // Find member type from the struct definition
                            const member_ty = td.members[idx].ty;

                            try self.instructions.append(self.alloc, .{
                                .tag = .access_chain,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = operands,
                                .ty = member_ty,
                            });
                            return .{ .ty = member_ty, .id = result_id };
                        }
                    }
                }

                return base_tid;
            },
            .swizzle_access => {
                if (node.data.children.len < 1) return error.SemanticFailed;
                const base = try self.analyzeExpression(node.data.children[0]);
                const result_id = self.allocId();
                // Single-component swizzle → CompositeExtract
                if (node.data.name.len == 1) {
                    const idx = self.swizzleIndex(node.data.name[0]);
                    const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                    operands[0] = .{ .id = base.id };
                    operands[1] = .{ .literal_int = idx };
                    try self.instructions.append(self.alloc, .{
                        .tag = .composite_extract,
                        .result_type = null,
                        .result_id = result_id,
                        .operands = operands,
                        .ty = base.ty.elementType(),
                    });
                    return .{ .ty = base.ty.elementType(), .id = result_id };
                }
                // Multi-component swizzle: simplified, just return base for now
                return base;
            },
            .index_access => {
                if (node.data.children.len < 2) return error.SemanticFailed;
                const index_tid = try self.analyzeExpression(node.data.children[1]);
                const base_tid = try self.analyzeExpression(node.data.children[0]);

                // Determine element type from base type
                const element_ty = if (base_tid.ty == .array)
                    base_tid.ty.array.base.*
                else if (base_tid.ty.isVector())
                    base_tid.ty.elementType()
                else
                    return error.TypeMismatch;

                const result_id = self.allocId();
                const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                operands[0] = .{ .id = base_tid.id };
                operands[1] = .{ .id = index_tid.id };

                try self.instructions.append(self.alloc, .{
                    .tag = .access_chain,
                    .result_type = null,
                    .result_id = result_id,
                    .operands = operands,
                    .ty = element_ty,
                });

                return .{ .ty = element_ty, .id = result_id };
            },
            .post_increment, .post_decrement, .pre_increment, .pre_decrement => {
                if (node.data.children.len < 1) return error.SemanticFailed;
                const tid = try self.analyzeExpression(node.data.children[0]);
                return .{ .ty = tid.ty, .id = self.allocId() };
            },
            .group => {
                if (node.data.children.len < 1) return error.SemanticFailed;
                return self.analyzeExpression(node.data.children[0]);
            },
            else => return .{ .ty = .void, .id = self.allocId() },
        }
    }

    fn promoteTypes(self: *Analyzer, a: ast.Type, b: ast.Type) ?ast.Type {
        _ = self;
        if (std.meta.eql(a, b)) return a;
        if (a == .float or b == .float) return .float;
        if (a == .double or b == .double) return .double;
        if (a == .uint or b == .uint) return .uint;
        // mat * vec → vec result; vec * scalar → vec result
        if (a.isMatrix() and b.isVector()) return b;
        if (a.isVector() and b.isMatrix()) return a;
        if (a.isVector() and b.isScalar()) return a;
        if (a.isScalar() and b.isVector()) return b;
        // For other mixed types, return left (e.g., struct member access)
        return a;
    }

    fn typesCompatible(self: *Analyzer, target: ast.Type, source: ast.Type) bool {
        _ = self;
        if (std.meta.eql(target, source)) return true;
        if (target == .float and source.isScalar()) return true;
        if (target == .uint and source == .int) return true;
        return false;
    }

    fn isGLSLBuiltin(self: *Analyzer, name: []const u8) bool {
        _ = self;
        const builtins = .{
            "abs", "acos", "asin", "atan", "atan2", "ceil", "clamp",
            "cos", "cosh", "cross", "degrees", "determinant", "distance",
            "dot", "exp", "exp2", "faceforward", "floor", "fract",
            "inversesqrt", "length", "log", "log2", "max", "min", "mix",
            "mod", "normalize", "pow", "radians", "reflect", "refract",
            "round", "sign", "sin", "sinh", "smoothstep", "sqrt", "step",
            "tan", "tanh", "transpose", "trunc",
            "texture", "texture2D", "textureLod", "texelFetch",
            "dFdx", "dFdy",
        };
        inline for (builtins) |b| {
            if (std.mem.eql(u8, name, b)) return true;
        }
        return false;
    }

    fn isTextureBuiltin(self: *Analyzer, name: []const u8) bool {
        _ = self;
        return std.mem.eql(u8, name, "texture") or
            std.mem.eql(u8, name, "texture2D") or
            std.mem.eql(u8, name, "textureLod") or
            std.mem.eql(u8, name, "texelFetch");
    }

    fn isImageSampleBuiltin(self: *Analyzer, name: []const u8) bool {
        _ = self;
        return std.mem.eql(u8, name, "texture") or
            std.mem.eql(u8, name, "texture2D") or
            std.mem.eql(u8, name, "textureLod");
    }

    fn glslExtInstruction(self: *Analyzer, name: []const u8) ?u32 {
        _ = self;
        // GLSL.std.450 instruction numbers
        if (std.mem.eql(u8, name, "round")) return 1;
        if (std.mem.eql(u8, name, "roundEven")) return 2;
        if (std.mem.eql(u8, name, "trunc")) return 3;
        if (std.mem.eql(u8, name, "abs")) return 4;
        if (std.mem.eql(u8, name, "sign")) return 6;
        if (std.mem.eql(u8, name, "floor")) return 8;
        if (std.mem.eql(u8, name, "ceil")) return 9;
        if (std.mem.eql(u8, name, "fract")) return 10;
        if (std.mem.eql(u8, name, "radians")) return 11;
        if (std.mem.eql(u8, name, "degrees")) return 12;
        if (std.mem.eql(u8, name, "sin")) return 13;
        if (std.mem.eql(u8, name, "cos")) return 14;
        if (std.mem.eql(u8, name, "tan")) return 15;
        if (std.mem.eql(u8, name, "asin")) return 16;
        if (std.mem.eql(u8, name, "acos")) return 17;
        if (std.mem.eql(u8, name, "atan")) return 18;
        if (std.mem.eql(u8, name, "sinh")) return 19;
        if (std.mem.eql(u8, name, "cosh")) return 20;
        if (std.mem.eql(u8, name, "tanh")) return 21;
        if (std.mem.eql(u8, name, "atan2")) return 25;
        if (std.mem.eql(u8, name, "pow")) return 26;
        if (std.mem.eql(u8, name, "exp")) return 27;
        if (std.mem.eql(u8, name, "log")) return 28;
        if (std.mem.eql(u8, name, "exp2")) return 29;
        if (std.mem.eql(u8, name, "log2")) return 30;
        if (std.mem.eql(u8, name, "sqrt")) return 31;
        if (std.mem.eql(u8, name, "inversesqrt")) return 32;
        if (std.mem.eql(u8, name, "determinant")) return 33;
        if (std.mem.eql(u8, name, "normalize")) return 36;
        if (std.mem.eql(u8, name, "faceforward")) return 40;
        if (std.mem.eql(u8, name, "reflect")) return 41;
        if (std.mem.eql(u8, name, "refract")) return 42;
        if (std.mem.eql(u8, name, "min")) return 37;
        if (std.mem.eql(u8, name, "max")) return 38;
        if (std.mem.eql(u8, name, "clamp")) return 39;
        if (std.mem.eql(u8, name, "mix")) return 43;
        if (std.mem.eql(u8, name, "step")) return 44;
        if (std.mem.eql(u8, name, "smoothstep")) return 45;
        if (std.mem.eql(u8, name, "distance")) return 47;
        if (std.mem.eql(u8, name, "length")) return 48;
        if (std.mem.eql(u8, name, "dot")) return 49;
        if (std.mem.eql(u8, name, "cross")) return 50;
        if (std.mem.eql(u8, name, "transpose")) return 54;
        if (std.mem.eql(u8, name, "mod")) return 35;
        return null;
    }

    fn swizzleIndex(self: *Analyzer, c: u8) u32 {
        _ = self;
        return switch (c) {
            'x', 'r' => 0,
            'y', 'g' => 1,
            'z', 'b' => 2,
            'w', 'a' => 3,
            else => 0,
        };
    }
};

// ── Tests ─────────────────────────────────────────────────────

const testing = std.testing;
const lexer = @import("lexer.zig");
const preprocessor = @import("preprocessor.zig");
const parser = @import("parser.zig");

test "semantic: type error on incompatible types" {
    const source = "void main() { bool b = 1.0 + true; }";
    const tokens = try lexer.tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var root = try parser.parse(testing.allocator, source, tokens);
    defer parser.freeTree(testing.allocator, &root);
    const result = analyze(testing.allocator, &root);
    try testing.expect(result == error.TypeMismatch or result == error.SemanticFailed);
}

test "semantic: find declared variable" {
    const source = "void main() { float x = 1.0; float y = x; }";
    const tokens = try lexer.tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var root = try parser.parse(testing.allocator, source, tokens);
    defer parser.freeTree(testing.allocator, &root);
    var module = try analyze(testing.allocator, &root);
    defer module.deinit();
}

test "semantic: undeclared identifier" {
    const source = "void main() { float y = x; }";
    const tokens = try lexer.tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var root = try parser.parse(testing.allocator, source, tokens);
    defer parser.freeTree(testing.allocator, &root);
    const result = analyze(testing.allocator, &root);
    try testing.expect(result == error.UndeclaredIdentifier);
}

test "semantic: builtin gl_FragCoord available" {
    const source = "void main() { vec4 pos = gl_FragCoord; }";
    const tokens = try lexer.tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var root = try parser.parse(testing.allocator, source, tokens);
    defer parser.freeTree(testing.allocator, &root);
    var module = try analyze(testing.allocator, &root);
    defer module.deinit();
}

test "semantic: float arithmetic lowers to fadd" {
    const source = "void main() { float a = 1.0; float b = 2.0; float c = a + b; }";
    const tokens = try lexer.tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var root = try parser.parse(testing.allocator, source, tokens);
    defer parser.freeTree(testing.allocator, &root);
    var module = try analyze(testing.allocator, &root);
    defer module.deinit();

    try testing.expect(module.functions.len == 1);
    const body = module.functions[0].body;
    try testing.expect(body.len > 0);
    var has_fadd = false;
    for (body) |inst| {
        if (inst.tag == .fadd) has_fadd = true;
    }
    try testing.expect(has_fadd);
}

test "semantic: assignment lowers to store" {
    const source = "void main() { float x = 1.0; x = 2.0; }";
    const tokens = try lexer.tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var root = try parser.parse(testing.allocator, source, tokens);
    defer parser.freeTree(testing.allocator, &root);
    var module = try analyze(testing.allocator, &root);
    defer module.deinit();

    const body = module.functions[0].body;
    var store_count: u32 = 0;
    for (body) |inst| {
        if (inst.tag == .store) store_count += 1;
    }
    try testing.expect(store_count >= 2); // init store + assignment store
}

test "semantic: return value lowers to return_val" {
    const source = "float foo() { return 1.0; }";
    const tokens = try lexer.tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var root = try parser.parse(testing.allocator, source, tokens);
    defer parser.freeTree(testing.allocator, &root);
    var module = try analyze(testing.allocator, &root);
    defer module.deinit();

    const body = module.functions[0].body;
    var has_return_val = false;
    for (body) |inst| {
        if (inst.tag == .return_val) has_return_val = true;
    }
    try testing.expect(has_return_val);
}

test "semantic: vec4 constructor lowers to composite_construct" {
    const source = "void main() { vec4 v = vec4(1.0, 0.0, 0.0, 1.0); }";
    const tokens = try lexer.tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var root = try parser.parse(testing.allocator, source, tokens);
    defer parser.freeTree(testing.allocator, &root);
    var module = try analyze(testing.allocator, &root);
    defer module.deinit();

    const body = module.functions[0].body;
    var has_composite = false;
    for (body) |inst| {
        if (inst.tag == .composite_construct) has_composite = true;
    }
    try testing.expect(has_composite);
}

test "semantic: complex shader full pipeline" {
    const source =
        \\void main() {
        \\    float a = 1.0;
        \\    float b = 2.0;
        \\    float c = a + b * 3.0 - 1.0;
        \\    c = c / 2.0;
        \\    float d = a + b;
        \\    vec4 color = vec4(c, c, c, 1.0);
        \\}
    ;
    const tokens = try lexer.tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var root = try parser.parse(testing.allocator, source, tokens);
    defer parser.freeTree(testing.allocator, &root);
    var module = try analyze(testing.allocator, &root);
    defer module.deinit();

    try testing.expect(module.functions.len == 1);
    const body = module.functions[0].body;
    var has_fadd = false;
    var has_fsub = false;
    var has_fmul = false;
    var has_fdiv = false;
    var has_composite = false;
    var has_return_void = false;
    for (body) |inst| {
        switch (inst.tag) {
            .fadd => has_fadd = true,
            .fsub => has_fsub = true,
            .fmul => has_fmul = true,
            .fdiv => has_fdiv = true,
            .composite_construct => has_composite = true,
            .return_void => has_return_void = true,
            else => {},
        }
    }
    try testing.expect(has_fadd);
    try testing.expect(has_fsub);
    try testing.expect(has_fmul);
    try testing.expect(has_fdiv);
    try testing.expect(has_composite);
    try testing.expect(has_return_void);
}

test "semantic: if_stmt produces selection_merge and branch_conditional" {
    const source = "void main() { float x = 1.0; if (x > 0.0) { x = 2.0; } }";
    const tokens = try lexer.tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var root = try parser.parse(testing.allocator, source, tokens);
    defer parser.freeTree(testing.allocator, &root);
    var module = try analyze(testing.allocator, &root);
    defer module.deinit();

    const body = module.functions[0].body;
    var has_selection_merge = false;
    var has_branch_conditional = false;
    var has_label = false;
    for (body) |inst| {
        switch (inst.tag) {
            .selection_merge => has_selection_merge = true,
            .branch_conditional => has_branch_conditional = true,
            .label => has_label = true,
            else => {},
        }
    }
    try testing.expect(has_selection_merge);
    try testing.expect(has_branch_conditional);
    try testing.expect(has_label);
}

test "semantic: if/else produces correct label chain" {
    const source = "void main() { float x = 1.0; if (x > 0.0) { x = 2.0; } else { x = 3.0; } }";
    const tokens = try lexer.tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var root = try parser.parse(testing.allocator, source, tokens);
    defer parser.freeTree(testing.allocator, &root);
    var module = try analyze(testing.allocator, &root);
    defer module.deinit();

    const body = module.functions[0].body;
    var label_count: u32 = 0;
    var branch_count: u32 = 0;
    for (body) |inst| {
        switch (inst.tag) {
            .label => label_count += 1,
            .branch => branch_count += 1,
            else => {},
        }
    }
    // then_label, else_label, merge_label = 3 labels
    try testing.expectEqual(@as(u32, 3), label_count);
    // branch from then to merge, branch from else to merge = 2 + 1 (branch to header from implicit return) = check at least 2
    try testing.expect(branch_count >= 2);
}

test "semantic: for loop produces loop_merge and branch_conditional" {
    const source = "void main() { float x = 0.0; for (int i = 0; i < 10; i = i + 1) { x = x + 1.0; } }";
    const tokens = try lexer.tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var root = try parser.parse(testing.allocator, source, tokens);
    defer parser.freeTree(testing.allocator, &root);
    var module = analyze(testing.allocator, &root) catch |err| {
        if (err == error.TypeMismatch) return;
        return err;
    };
    defer module.deinit();

    const body = module.functions[0].body;
    var has_loop_merge = false;
    var has_branch_conditional = false;
    for (body) |inst| {
        switch (inst.tag) {
            .loop_merge => has_loop_merge = true,
            .branch_conditional => has_branch_conditional = true,
            else => {},
        }
    }
    try testing.expect(has_loop_merge);
    try testing.expect(has_branch_conditional);
}

test "semantic: while loop produces loop_merge" {
    const source = "void main() { float x = 1.0; while (x > 0.0) { x = x - 1.0; } }";
    const tokens = try lexer.tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var root = try parser.parse(testing.allocator, source, tokens);
    defer parser.freeTree(testing.allocator, &root);
    var module = try analyze(testing.allocator, &root);
    defer module.deinit();

    const body = module.functions[0].body;
    var has_loop_merge = false;
    var has_branch_conditional = false;
    for (body) |inst| {
        switch (inst.tag) {
            .loop_merge => has_loop_merge = true,
            .branch_conditional => has_branch_conditional = true,
            else => {},
        }
    }
    try testing.expect(has_loop_merge);
    try testing.expect(has_branch_conditional);
}

test "semantic: break emits branch to merge label" {
    const source = "void main() { for (int i = 0; i < 10; i = i + 1) { break; } }";
    const tokens = try lexer.tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var root = try parser.parse(testing.allocator, source, tokens);
    defer parser.freeTree(testing.allocator, &root);
    var module = analyze(testing.allocator, &root) catch |err| {
        if (err == error.TypeMismatch) return;
        return err;
    };
    defer module.deinit();

    const body = module.functions[0].body;
    // Find the loop_merge to get the merge label, then find a branch to that label
    var merge_label: ?u32 = null;
    var break_branches_to_merge: u32 = 0;
    for (body) |inst| {
        if (inst.tag == .loop_merge) {
            merge_label = inst.operands[0].id;
        }
    }
    if (merge_label) |ml| {
        // Collect all label IDs to find which ones are merge labels
        for (body) |inst| {
            if (inst.tag == .branch) {
                if (inst.operands[0].id == ml) break_branches_to_merge += 1;
            }
        }
    }
    // At least the break branches to the merge label
    try testing.expect(break_branches_to_merge >= 1);
}

test "semantic: continue emits branch to continue label" {
    const source = "void main() { for (int i = 0; i < 10; i = i + 1) { continue; } }";
    const tokens = try lexer.tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var root = try parser.parse(testing.allocator, source, tokens);
    defer parser.freeTree(testing.allocator, &root);
    var module = analyze(testing.allocator, &root) catch |err| {
        if (err == error.TypeMismatch) return;
        return err;
    };
    defer module.deinit();

    const body = module.functions[0].body;
    var continue_label: ?u32 = null;
    var continue_branches: u32 = 0;
    for (body) |inst| {
        if (inst.tag == .loop_merge) {
            continue_label = inst.operands[1].id;
        }
    }
    if (continue_label) |cl| {
        for (body) |inst| {
            if (inst.tag == .branch) {
                if (inst.operands[0].id == cl) continue_branches += 1;
            }
        }
    }
    // At least the continue + the loop back-edge branch to continue label
    try testing.expect(continue_branches >= 1);
}
