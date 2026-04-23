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
        .alloc = alloc,
    };
}

const Symbol = struct {
    kind: enum { var_sym, param, func, type_sym },
    ty: ast.Type,
    ir_id: u32,
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
    next_id: u32 = 1,

    fn deinit(self: *Analyzer) void {
        for (self.scopes.items) |*scope| scope.deinit(self.alloc);
        self.scopes.deinit(self.alloc);
        self.globals.deinit(self.alloc);
        self.functions.deinit(self.alloc);
        for (self.errors.items) |msg| self.alloc.free(msg);
        self.errors.deinit(self.alloc);
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

        try self.declare("gl_FragCoord", .{
            .kind = .var_sym,
            .ty = .vec4,
            .ir_id = self.allocId(),
        });

        try self.declare("gl_FragColor", .{
            .kind = .var_sym,
            .ty = .vec4,
            .ir_id = self.allocId(),
        });

        const math_funcs = .{
            "abs",   "acos",  "asin",      "atan",    "atan2",
            "ceil",  "clamp", "cos",       "cosh",    "cross",
            "degrees", "determinant", "distance", "dot",
            "exp",   "exp2",  "faceforward", "floor", "fract",
            "inversesqrt", "length", "log", "log2",
            "max",   "min",   "mix",       "mod",     "normalize",
            "pow",   "radians", "reflect", "refract",
            "round", "sign",  "sin",       "sinh",
            "smoothstep", "sqrt", "step",  "tan",     "tanh",
            "transpose",  "trunc",
        };
        inline for (math_funcs) |name| {
            try self.declare(name, .{
                .kind = .func,
                .ty = .void,
                .ir_id = self.allocId(),
            });
        }

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
                    else => .function,
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
            .struct_decl => {
                const name = node.data.name;
                const td = ir.TypeDef{
                    .name = name,
                    .members = node.data.members,
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
            .result_id = 0,
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
                if (node.data.children.len > 0) {
                    _ = try self.analyzeExpression(node.data.children[0]);
                }
                if (node.data.children.len > 1) try self.analyzeStatement(node.data.children[1]);
                if (node.data.children.len > 2) try self.analyzeStatement(node.data.children[2]);
            },
            .for_stmt => {
                try self.pushScope();
                for (node.data.children) |child| {
                    try self.analyzeStatement(child);
                }
                self.popScope();
            },
            .while_stmt, .do_while_stmt => {
                for (node.data.children) |child| {
                    try self.analyzeStatement(child);
                }
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
            .discard_stmt, .break_stmt, .continue_stmt => {},
            .expr_stmt => {
                if (node.data.children.len > 0) {
                    _ = try self.analyzeExpression(node.data.children[0]);
                }
            },
            else => {},
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

                const is_float = result_ty == .float or result_ty == .double;

                const tag: ir.Instruction.Tag = switch (node.data.op orelse .add) {
                    .add => if (is_float) .fadd else .add,
                    .sub => if (is_float) .fsub else .sub,
                    .mul => if (is_float) .fmul else .mul,
                    .div => if (is_float) .fdiv else .div,
                    .mod => .rem,
                    .eq => .compare_eq,
                    .neq => .compare_neq,
                    .lt => .compare_lt,
                    .gt => .compare_gt,
                    .lte => .compare_lte,
                    .gte => .compare_gte,
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
                try self.instructions.append(self.alloc, .{
                    .tag = tag,
                    .result_type = null,
                    .result_id = result_id,
                    .operands = operands,
                    .ty = result_ty,
                });
                return .{ .ty = result_ty, .id = result_id };
            },
            .unary_op => {
                if (node.data.children.len < 1) return error.SemanticFailed;
                const operand = try self.analyzeExpression(node.data.children[0]);
                const result_id = self.allocId();

                const is_float = operand.ty == .float or operand.ty == .double;

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
                const target = try self.analyzeExpression(node.data.children[0]);
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
                const target = try self.analyzeExpression(node.data.children[0]);
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
                const is_float = result_ty == .float or result_ty == .double;
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
                const result_ty: ast.Type = if (sym) |s| s.ty else .void;
                const result_id = self.allocId();

                if (self.isGLSLBuiltin(node.data.name)) {
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
                // For non-builtin functions, just allocate the result_id (function calls not yet supported)
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
                if (base_tid.ty.isVector()) return .{ .ty = .float, .id = self.allocId() };
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
                _ = try self.analyzeExpression(node.data.children[1]);
                const base_tid = try self.analyzeExpression(node.data.children[0]);
                return .{ .ty = base_tid.ty, .id = self.allocId() };
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
        return null;
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
        };
        inline for (builtins) |b| {
            if (std.mem.eql(u8, name, b)) return true;
        }
        return false;
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
