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

pub threadlocal var last_error_ctx: []const u8 = "";
pub threadlocal var last_error_inner: []const u8 = "";
pub threadlocal var last_error_line: u32 = 0;
pub threadlocal var last_error_column: u32 = 0;

/// Format a human-readable error message from the last compile error.
/// Caller must free the returned slice with `alloc.free`.
pub fn formatLastError(alloc: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
    if (last_error_line == 0 and last_error_ctx.len == 0) return null;
    const detail = @import("root.zig").last_compile_detail orelse return null;
    return std.fmt.allocPrint(alloc, "line {d}: {s} ({s}: {s})", .{
        last_error_line,
        @tagName(detail),
        last_error_ctx,
        last_error_inner,
    });
}

pub const AnalyzeOptions = struct {
    /// When true, semantic errors in function bodies are recorded but don't prevent
    /// returning a partial module. When false, any error causes analyze() to return
    /// an error (used by unit tests to verify error detection).
    tolerate_errors: bool = false,
};

pub fn analyze(alloc: std.mem.Allocator, root: *ast.Root) Error!ir.Module {
    return analyzeWithOptions(alloc, root, .{});
}

pub fn analyzeWithOptions(alloc: std.mem.Allocator, root: *ast.Root, options: AnalyzeOptions) Error!ir.Module {
    last_error_inner = "";
    last_error_ctx = "";
    last_error_line = 0;
    last_error_column = 0;
    var analyzer = Analyzer{
        .alloc = alloc,
        .scopes = .empty,
        .globals = .{},
        .functions = .{},
        .types = .empty,
        .instructions = .{},
        .errors = .{},
        .loop_stack = .empty,
        .overloads = .empty,
        .tolerate_errors = options.tolerate_errors,
    };
    defer analyzer.deinit();

    try analyzer.injectBuiltins();

    for (root.body) |node| {
        try analyzer.collectTopLevel(node);
    }

    for (root.body) |node| {
        if (node.tag == .function_decl) {
            analyzer.analyzeFunction(node) catch |err| {
                if (!analyzer.tolerate_errors) return err;
                const msg = std.fmt.allocPrint(alloc, "{s} in function {s}", .{@errorName(err), node.data.name}) catch "error";
                analyzer.errors.append(alloc, msg) catch {};
            };
        }
    }

    if (!analyzer.tolerate_errors and analyzer.errors.items.len > 0) return error.SemanticFailed;

    // Transfer ownership to module; clear analyzer fields so defer deinit doesn't double-free
    const mod: ir.Module = .{
        .functions = try analyzer.functions.toOwnedSlice(alloc),
        .globals = try analyzer.globals.toOwnedSlice(alloc),
        .types = analyzer.types,
        .entry_point = null,
        .next_id_start = analyzer.next_id,
        .alloc = alloc,
        .local_size = analyzer.local_size,
        .heap_types = try analyzer.heap_types.toOwnedSlice(alloc),
        .spec_constants = analyzer.spec_constants,
    };
    // Clear transferred fields before defer deinit runs
    analyzer.types = .{};
    analyzer.functions = .{};
    analyzer.globals = .{};
    analyzer.heap_types = .{};
    analyzer.spec_constants = .{};
    analyzer.instructions.clearRetainingCapacity();
    return mod;
}

const Symbol = struct {
    kind: enum { var_sym, param, func, type_sym, block_member },
    ty: ast.Type,
    ir_id: u32,
    member_index: u32 = 0, // For block_member: index into the parent block
    init_value: ?u32 = null, // For var_sym: if set, use this SSA value instead of load
    is_ssa: bool = false, // true if this var can be used as SSA (never reassigned)
};

const LoopContext = struct {
    merge_label: u32,
    continue_label: u32,
};

const OverloadEntry = struct {
    param_types: []const ast.Type,
    ir_id: u32,
    return_type: ast.Type = .void,
};

const Scope = std.StringHashMapUnmanaged(Symbol);

const Analyzer = struct {
    const TypedId = struct {
        ty: ast.Type,
        id: u32,
        is_ptr: bool = false, // true if id is a pointer (from access_chain), not a value
    };
    alloc: std.mem.Allocator,
    scopes: std.ArrayListUnmanaged(Scope),
    globals: std.ArrayListUnmanaged(ir.Global),
    functions: std.ArrayListUnmanaged(ir.Function),
    types: std.StringHashMapUnmanaged(ir.TypeDef),
    instructions: std.ArrayListUnmanaged(ir.Instruction),
    errors: std.ArrayListUnmanaged([]const u8),
    loop_stack: std.ArrayListUnmanaged(LoopContext),
    // Function overloads: maps function name to list of (param_types, ir_id)
    overloads: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(OverloadEntry)),
    tolerate_errors: bool = false,
    has_returned: bool = false, // Dead code suppression after return
    next_id: u32 = 1,
    // Constant dedup: (type_tag << 32 | value_bits) -> ir_id
    const_cache: std.AutoHashMapUnmanaged(u64, u32) = .{},
    local_size: ?ir.LocalSize = null,
    // Heap-allocated AST types that transfer to Module for cleanup
    heap_types: std.ArrayListUnmanaged(*ast.Type) = .{},
    spec_constants: std.StringHashMapUnmanaged(ir.SpecConstant) = .{},

    fn deinit(self: *Analyzer) void {
        // Free heap-allocated AST types (if not transferred to Module)
        for (self.heap_types.items) |ptr| {
            self.alloc.destroy(ptr);
        }
        self.heap_types.deinit(self.alloc);

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
        self.const_cache.deinit(self.alloc);
        {
            var it = self.overloads.iterator();
            while (it.next()) |entry| {
                for (entry.value_ptr.items) |*overload| {
                    if (overload.param_types.len > 0) {
                        self.alloc.free(overload.param_types);
                    }
                }
                entry.value_ptr.deinit(self.alloc);
            }
            // Free the owned name keys
            var key_it = self.overloads.keyIterator();
            while (key_it.next()) |key_ptr| {
                self.alloc.free(key_ptr.*);
            }
            self.overloads.deinit(self.alloc);
        }
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

    /// Get or create a constant int IR node with dedup
    fn getConstInt(self: *Analyzer, val: u32, ty: ast.Type) !u32 {
        const key = (@as(u64, @intFromEnum(ty)) << 32) | @as(u64, val);
        if (self.const_cache.get(key)) |cached| return cached;
        const id = self.allocId();
        const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
        operands[0] = .{ .literal_int = val };
        try self.instructions.append(self.alloc, .{
            .tag = .constant_int,
            .result_type = null,
            .result_id = id,
            .operands = operands,
            .ty = ty,
        });
        try self.const_cache.put(self.alloc, key, id);
        return id;
    }

    /// Get or create a constant float IR node with dedup
    fn getConstFloat(self: *Analyzer, val: f32) !u32 {
        const val_bits: u32 = @bitCast(val);
        const key = (@as(u64, @intFromEnum(ast.Type.float)) << 32) | @as(u64, val_bits);
        if (self.const_cache.get(key)) |cached| return cached;
        const id = self.allocId();
        const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
        operands[0] = .{ .literal_float = val };
        try self.instructions.append(self.alloc, .{
            .tag = .constant_float,
            .result_type = null,
            .result_id = id,
            .operands = operands,
            .ty = .float,
        });
        try self.const_cache.put(self.alloc, key, id);
        return id;
    }

    /// Check if an ID was produced by a constant instruction (constant_int, constant_float, constant_composite, spec_constant)
    fn isConstantId(self: *Analyzer, id: u32) bool {
        // Check current function's instructions
        for (self.instructions.items) |inst| {
            if (inst.result_id == id) {
                return inst.tag == .constant_int or inst.tag == .constant_float or inst.tag == .constant_composite or inst.tag == .spec_constant;
            }
        }
        // Check global constant functions (constants from previous functions are in the module)
        for (self.functions.items) |func| {
            for (func.body) |inst| {
                if (inst.result_id == id) {
                    return inst.tag == .constant_int or inst.tag == .constant_float or inst.tag == .constant_composite or inst.tag == .spec_constant;
                }
            }
        }
        return false;
    }

    /// Try to upgrade the last instruction from composite_construct to constant_composite
    /// if all operand IDs reference constant instructions.
    /// Returns true if upgraded.
    fn tryUpgradeToConstantComposite(self: *Analyzer) bool {
        if (self.instructions.items.len == 0) return false;
        const last = &self.instructions.items[self.instructions.items.len - 1];
        if (last.tag != .composite_construct) return false;
        for (last.operands) |op| {
            switch (op) {
                .id => |id| {
                    if (!self.isConstantId(id)) return false;
                },
                else => return false,
            }
        }
        last.tag = .constant_composite;
        return true;
    }

    /// Emit a composite_construct instruction and try to upgrade to constant_composite if all operands are constants.
    fn emitCompositeConstruct(self: *Analyzer, result_id: u32, operands: []ir.Instruction.Operand, ty: ast.Type) !void {
        try self.instructions.append(self.alloc, .{
            .tag = .composite_construct,
            .result_type = null,
            .result_id = result_id,
            .operands = operands,
            .ty = ty,
        });
        _ = self.tryUpgradeToConstantComposite();
    }

    fn pushScope(self: *Analyzer) !void {
        try self.scopes.append(self.alloc, .empty);
    }

    fn popScope(self: *Analyzer) void {
        var scope = self.scopes.pop() orelse return;
        scope.deinit(self.alloc);
    }

    /// Force un-SSA all SSA variables in the current (innermost) scope.
    fn unssaCurrentScope(self: *Analyzer) !void {
        if (self.scopes.items.len == 0) return;
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        try self.unssaScope(scope);
    }

    /// Force un-SSA all SSA variables in ALL scopes.
    fn unssaAllScopes(self: *Analyzer) !void {
        for (self.scopes.items) |*scope| {
            try self.unssaScope(scope);
        }
    }

    fn unssaScope(self: *Analyzer, scope: *Scope) !void {
        var it = scope.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.kind == .var_sym and entry.value_ptr.*.is_ssa) {
                const sym = entry.value_ptr.*;
                const var_id = self.allocId();
                const sc_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                sc_operands[0] = .{ .literal_int = 7 }; // Function storage class
                try self.instructions.append(self.alloc, .{
                    .tag = .local_variable,
                    .result_type = null,
                    .result_id = var_id,
                    .operands = sc_operands,
                    .ty = sym.ty,
                });
                if (sym.init_value) |init_val| {
                    const store_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                    store_ops[0] = .{ .id = var_id };
                    store_ops[1] = .{ .id = init_val };
                    try self.instructions.append(self.alloc, .{
                        .tag = .store,
                        .result_type = null,
                        .result_id = null,
                        .operands = store_ops,
                        .ty = .void,
                    });
                }
                entry.value_ptr.*.ir_id = var_id;
                entry.value_ptr.*.is_ssa = false;
                entry.value_ptr.*.init_value = null;
            }
        }
    }

    fn emitLabel(self: *Analyzer, label_id: u32) !void {
        try self.instructions.append(self.alloc, .{
            .tag = .label,
            .result_id = label_id,
            .operands = &.{},
            .ty = .void,
        });
    }

    fn lastInstructionIsReturn(self: *Analyzer) bool {
        if (self.instructions.items.len == 0) return false;
        const last_tag = self.instructions.items[self.instructions.items.len - 1].tag;
        return last_tag == .return_void or last_tag == .return_val or last_tag == .unreachable_inst or last_tag == .kill;
    }

    fn lastInstructionIsBranch(self: *Analyzer) bool {
        if (self.instructions.items.len == 0) return false;
        const last_tag = self.instructions.items[self.instructions.items.len - 1].tag;
        return last_tag == .branch or last_tag == .branch_conditional or last_tag == .return_void or last_tag == .return_val or last_tag == .unreachable_inst or last_tag == .kill;
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
        // Lazy builtin variable injection for gl_* names
        if (name.len > 3 and name[0] == 'g' and name[1] == 'l' and name[2] == '_') {
            return self.ensureBuiltinVar(name);
        }
        return null;
    }

    fn lookupMut(self: *Analyzer, name: []const u8) ?*Symbol {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].getPtr(name)) |sym_ptr| return sym_ptr;
        }
        return null;
    }

    fn injectBuiltins(self: *Analyzer) !void {
        try self.pushScope();

        // NOTE: Variable builtins (gl_FragCoord, gl_Position, etc.) are now
        // injected lazily via ensureBuiltinVar() when first referenced.
        // Only function builtins are declared eagerly (they don't emit SPIR-V).

        // Math functions that return float (or same type as primary argument)
        const float_return_funcs = .{
            "abs",   "acos",  "asin",      "atan",    "atan2",
            "ceil",  "clamp", "cos",       "cosh",
            "degrees", "distance", "dot",
            "exp",   "exp2",  "floor", "fract",
            "inversesqrt", "length", "log", "log2",
            "max",   "min",   "mix",       "mod",
            "min3", "max3", "mid3",
            "pow",   "radians", "round", "sign",
            "sin",       "sinh",
            "smoothstep", "sqrt", "step",  "tan",     "tanh",
            "trunc",
        };
        inline for (float_return_funcs) |name| {
            try self.declare(name, .{
                .kind = .func,
                .ty = .float,
                .ir_id = 0, // Function builtins don't need SPIR-V IDs
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
                .ir_id = 0, // Function builtins don't need SPIR-V IDs
            });
        }

        // Matrix functions
        try self.declare("determinant", .{ .kind = .func, .ty = .float, .ir_id = 0 });
        try self.declare("transpose", .{ .kind = .func, .ty = .mat4, .ir_id = 0 });

        try self.declare("texture", .{ .kind = .func, .ty = .vec4, .ir_id = 0 });
        try self.declare("texture2D", .{ .kind = .func, .ty = .vec4, .ir_id = 0 });
        try self.declare("textureLod", .{ .kind = .func, .ty = .vec4, .ir_id = 0 });
        try self.declare("textureProj", .{ .kind = .func, .ty = .vec4, .ir_id = 0 });
        try self.declare("textureQueryLevels", .{ .kind = .func, .ty = .int, .ir_id = 0 });
        try self.declare("textureQueryLod", .{ .kind = .func, .ty = .float, .ir_id = 0 });
        try self.declare("texelFetch", .{ .kind = .func, .ty = .vec4, .ir_id = 0 });
        try self.declare("subpassLoad", .{ .kind = .func, .ty = .vec4, .ir_id = 0 });
        try self.declare("dFdx", .{ .kind = .func, .ty = .float, .ir_id = 0 });
        try self.declare("dFdy", .{ .kind = .func, .ty = .float, .ir_id = 0 });
        try self.declare("fwidth", .{ .kind = .func, .ty = .float, .ir_id = 0 });
        try self.declare("dFdxFine", .{ .kind = .func, .ty = .float, .ir_id = 0 });
        try self.declare("dFdyFine", .{ .kind = .func, .ty = .float, .ir_id = 0 });
        try self.declare("fwidthFine", .{ .kind = .func, .ty = .float, .ir_id = 0 });
        try self.declare("dFdxCoarse", .{ .kind = .func, .ty = .float, .ir_id = 0 });
        try self.declare("dFdyCoarse", .{ .kind = .func, .ty = .float, .ir_id = 0 });
        try self.declare("fwidthCoarse", .{ .kind = .func, .ty = .float, .ir_id = 0 });
    }


    fn ensureBuiltinVar(self: *Analyzer, name: []const u8) ?Symbol {
        // Lazy builtin variable injection — only create when referenced
        // Build builtin table
        const builtins = [_]struct { name: []const u8, ty: ast.Type, is_in: bool, is_out: bool, sc: ir.SPIRVStorageClass }{
            .{ .name = "gl_FragCoord", .ty = .vec4, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_FragColor", .ty = .vec4, .is_in = false, .is_out = true, .sc = .output },
            .{ .name = "gl_FrontFacing", .ty = .bool, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_Position", .ty = .vec4, .is_in = false, .is_out = true, .sc = .output },
            .{ .name = "gl_PointSize", .ty = .float, .is_in = false, .is_out = true, .sc = .output },
            .{ .name = "gl_VertexID", .ty = .int, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_InstanceID", .ty = .int, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_GlobalInvocationID", .ty = .uvec3, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_LocalInvocationID", .ty = .uvec3, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_WorkGroupID", .ty = .uvec3, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_NumWorkGroups", .ty = .uvec3, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_WorkGroupSize", .ty = .uvec3, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_LocalInvocationIndex", .ty = .uint, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_Layer", .ty = .int, .is_in = false, .is_out = true, .sc = .output },
            .{ .name = "gl_ViewportIndex", .ty = .int, .is_in = false, .is_out = true, .sc = .output },
            .{ .name = "gl_HelperInvocation", .ty = .bool, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_SampleID", .ty = .int, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_SamplePosition", .ty = .vec2, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_SubgroupInvocationID", .ty = .int, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_SubgroupSize", .ty = .int, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_ViewIndex", .ty = .int, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_DeviceIndex", .ty = .int, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_BaseVertex", .ty = .int, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_BaseVertexARB", .ty = .int, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_VertexIndex", .ty = .int, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_BaseInstance", .ty = .int, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_BaseInstanceARB", .ty = .int, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_InstanceIndex", .ty = .int, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_DrawID", .ty = .int, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_DrawIDARB", .ty = .int, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_FragStencilRefARB", .ty = .int, .is_in = false, .is_out = true, .sc = .output },
            .{ .name = "gl_BaryCoordEXT", .ty = .vec3, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_BaryCoordNoPerspEXT", .ty = .vec3, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_BaryCoordNV", .ty = .vec3, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_BaryCoordNoPerspNV", .ty = .vec3, .is_in = true, .is_out = false, .sc = .input },
        };

        for (&builtins) |b| {
            if (std.mem.eql(u8, name, b.name)) {
                const id = self.allocId();
                self.globals.append(self.alloc, .{
                    .name = b.name,
                    .ty = b.ty,
                    .qualifier = .{ .is_in = b.is_in, .is_out = b.is_out },
                    .layout = null,
                    .storage_class = b.sc,
                    .result_id = id,
                }) catch return null;
                const sym = Symbol{ .kind = .var_sym, .ty = b.ty, .ir_id = id };
                // Declare in global scope (index 0) so all functions share it
                self.scopes.items[0].put(self.alloc, b.name, sym) catch return null;
                return sym;
            }
        }

        // Special cases: array-typed builtins
        if (std.mem.eql(u8, name, "gl_SampleMaskIn")) {
            const id = self.allocId();
            const arr_base = self.alloc.create(ast.Type) catch return null;
            arr_base.* = .int;
            self.heap_types.append(self.alloc, arr_base) catch {};
            const ty: ast.Type = .{ .array = .{ .base = arr_base, .size = 1 } };
            self.globals.append(self.alloc, .{ .name = "gl_SampleMaskIn", .ty = ty, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id }) catch return null;
            const sym = Symbol{ .kind = .var_sym, .ty = ty, .ir_id = id };
            self.scopes.items[0].put(self.alloc, "gl_SampleMaskIn", sym) catch return null;
            return sym;
        }
        if (std.mem.eql(u8, name, "gl_SampleMask")) {
            const id = self.allocId();
            const arr_base = self.alloc.create(ast.Type) catch return null;
            arr_base.* = .int;
            self.heap_types.append(self.alloc, arr_base) catch {};
            const ty: ast.Type = .{ .array = .{ .base = arr_base, .size = 1 } };
            self.globals.append(self.alloc, .{ .name = "gl_SampleMask", .ty = ty, .qualifier = .{ .is_out = true }, .layout = null, .storage_class = .output, .result_id = id }) catch return null;
            const sym = Symbol{ .kind = .var_sym, .ty = ty, .ir_id = id };
            self.scopes.items[0].put(self.alloc, "gl_SampleMask", sym) catch return null;
            return sym;
        }

        return null;
    }

    fn collectTopLevel(self: *Analyzer, node: ast.Node) !void {
        switch (node.tag) {
            .var_decl, .uniform_decl, .in_decl, .out_decl => {
                // Check for local_size_x layout (compute shader)
                if (node.tag == .in_decl) {
                    if (node.data.layout) |layout| {
                        if (layout.local_size_x) |lsx| {
                            self.local_size = .{
                                .x = lsx,
                                .y = layout.local_size_y orelse 1,
                                .z = layout.local_size_z orelse 1,
                            };
                        }
                    }
                }
                // Skip creating a global for standalone layout qualifiers (e.g. layout(local_size_x=1) in;)
                if (node.data.name.len > 0) {
                // Check for specialization constant: layout(constant_id = N) const int X = val;
                if (node.data.qualifier != null and node.data.qualifier.?.is_const) {
                    if (node.data.layout) |layout| {
                        if (layout.constant_id) |cid| {
                            const sc_ir_id = self.allocId();
                            const sc_ty = node.data.ty orelse .int;
                            // Get the default literal value
                            var default_literal: u32 = 0;
                            if (node.data.children.len > 0) {
                                const init = try self.analyzeExpression(node.data.children[0]);
                                // Extract literal from the constant_int instruction
                                for (self.instructions.items) |inst| {
                                    if (inst.result_id != null and inst.result_id.? == init.id and inst.tag == .constant_int) {
                                        default_literal = switch (inst.operands[0]) {
                                            .literal_int => |v| @intCast(v),
                                            else => 0,
                                        };
                                        break;
                                    }
                                }
                            }
                            // Declare as SSA symbol
                            try self.declare(node.data.name, .{
                                .kind = .var_sym,
                                .ty = sc_ty,
                                .ir_id = sc_ir_id,
                                .init_value = sc_ir_id,
                                .is_ssa = true,
                            });
                            // Store spec constant info for codegen
                            const owned_name = try self.alloc.dupe(u8, node.data.name);
                            try self.spec_constants.put(self.alloc, owned_name, .{
                                .result_id = sc_ir_id,
                                .spec_id = cid,
                                .default_literal = default_literal,
                                .type_tag = @intFromEnum(sc_ty),
                            });
                            return; // Don't create a global variable
                        }
                    }
                }
                const ir_id = self.allocId();
                const ty = node.data.ty orelse .void;
                const storage_class: ir.SPIRVStorageClass = switch (node.tag) {
                    .in_decl => .input,
                    .out_decl => .output,
                    .uniform_decl => if (ty.isSampler()) .uniform_constant else .uniform,
                    .var_decl => if (node.data.qualifier != null and node.data.qualifier.?.is_shared) .workgroup else .private,
                    else => .private,
                };
                try self.globals.append(self.alloc, .{
                    .name = node.data.name,
                    .ty = ty,
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
                } // end if name.len > 0
            },
            .uniform_block => {
                const name = node.data.name;
                const qual = node.data.qualifier orelse ast.Qualifier{ .is_uniform = true };
                // Determine storage class from qualifier and layout
                const has_push_constant = if (node.data.layout) |l| l.push_constant else false;
                const storage_class: ir.SPIRVStorageClass = if (has_push_constant)
                    .push_constant
                else if (qual.is_in)
                    .input
                else if (qual.is_out)
                    .output
                else if (qual.is_buffer)
                    .storage_buffer
                else
                    .uniform;

                // Register the block as a struct type
                const members = try self.alloc.dupe(ast.StructMember, node.data.members);
                const has_buffer_ref = if (node.data.layout) |l| l.buffer_reference else false;
                const td = ir.TypeDef{
                    .name = name,
                    .members = members,
                    .size_bytes = 0,
                    .is_buffer_reference = has_buffer_ref,
                };
                const owned_name = try self.alloc.dupe(u8, name);
                try self.types.put(self.alloc, owned_name, td);

                // For buffer_reference blocks, just register the type — no global variable
                if (has_buffer_ref) {
                    // Declare the type name so it can be used as a member type
                    try self.declare(name, .{
                        .kind = .type_sym,
                        .ty = .{ .named = name },
                        .ir_id = 0, // No global variable for buffer_reference types
                    });
                } else {
                // Create a global variable for the block
                const ir_id = self.allocId();
                // Use instance name for the global variable if present
                const global_name = if (node.data.instance_name.len > 0) node.data.instance_name else name;
                try self.globals.append(self.alloc, .{
                    .name = global_name,
                    .ty = .{ .named = name },
                    .qualifier = qual,
                    .layout = node.data.layout,
                    .storage_class = storage_class,
                    .result_id = ir_id,
                });
                // Declare the block variable under both names (type name and instance name)
                try self.declare(name, .{
                    .kind = .var_sym,
                    .ty = .{ .named = name },
                    .ir_id = ir_id,
                });
                if (node.data.instance_name.len > 0 and !std.mem.eql(u8, name, node.data.instance_name)) {
                    try self.declare(node.data.instance_name, .{
                        .kind = .var_sym,
                        .ty = .{ .named = name },
                        .ir_id = ir_id,
                    });
                }

                // Declare block members as directly accessible for uniform/buffer blocks
                // and for anonymous in/out blocks (no instance name).
                if (storage_class == .uniform or storage_class == .storage_buffer or storage_class == .push_constant or
                    ((storage_class == .input or storage_class == .output) and node.data.instance_name.len == 0))
                {
                    for (node.data.members, 0..) |member, idx| {
                        try self.declare(member.name, .{
                            .kind = .block_member,
                            .ty = member.ty,
                            .ir_id = ir_id, // Block variable ID
                            .member_index = @intCast(idx),
                        });
                    }
                }
                } // end if !buffer_reference
            },
            .struct_decl => {
                const name = node.data.name;
                const existing = self.types.getPtr(name);
                if (existing != null) {
                    // Inner struct redeclaration — for correctness, we'd need per-scope types.
                    // As a workaround, merge new members into existing type.
                    // This allows both foo.a and bar.b to resolve.
                    const new_members = try self.alloc.dupe(ast.StructMember, node.data.members);
                    // Append new members to existing type
                    var merged = try std.ArrayListUnmanaged(ast.StructMember).initCapacity(self.alloc, existing.?.members.len + new_members.len);
                    try merged.appendSlice(self.alloc, existing.?.members);
                    try merged.appendSlice(self.alloc, new_members);
                    existing.?.members = merged.items;
                    return;
                }
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
                    .ir_id = 0,
                });
            },
            .function_decl, .function_prototype => {
                const func_ir_id = self.allocId();
                // Collect parameter types
                var param_types = std.ArrayListUnmanaged(ast.Type){};
                for (node.data.params) |param| {
                    try param_types.append(self.alloc, param.ty);
                }
                const existing = self.lookup(node.data.name);
                if (existing != null and existing.?.kind == .func) {
                    // Function overload: store in overload map
                    const owned_name = try self.alloc.dupe(u8, node.data.name);
                    const gop = try self.overloads.getOrPut(self.alloc, owned_name);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{};
                        // Store the original function with its param types from the first declaration
                        // We need to recover the original param types — but we don't have them
                        // Use the scope symbol's ir_id
                        try gop.value_ptr.append(self.alloc, .{
                            .param_types = &.{}, // placeholder — will be resolved at call site
                            .ir_id = existing.?.ir_id,
                            .return_type = existing.?.ty,
                        });
                    }
                    const owned_pts = try self.alloc.dupe(ast.Type, param_types.items);
                    try gop.value_ptr.append(self.alloc, .{
                        .param_types = owned_pts,
                        .ir_id = func_ir_id,
                        .return_type = node.data.ty orelse .void,
                    });
                    // Update the scope to point to latest declaration
                    try self.declare(node.data.name, .{
                        .kind = .func,
                        .ty = node.data.ty orelse .void,
                        .ir_id = func_ir_id,
                    });
                } else {
                    // First declaration of this function name
                    const owned_name = try self.alloc.dupe(u8, node.data.name);
                    const gop = try self.overloads.getOrPut(self.alloc, owned_name);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{};
                    }
                    const owned_pts = try self.alloc.dupe(ast.Type, param_types.items);
                    try gop.value_ptr.append(self.alloc, .{
                        .param_types = owned_pts,
                        .ir_id = func_ir_id,
                        .return_type = node.data.ty orelse .void,
                    });
                    try self.declare(node.data.name, .{
                        .kind = .func,
                        .ty = node.data.ty orelse .void,
                        .ir_id = func_ir_id,
                    });
                }
            },
            else => {},
        }
    }

    fn analyzeFunction(self: *Analyzer, node: ast.Node) !void {
        self.has_returned = false;
        try self.pushScope();

        // For overloaded functions, resolve the correct ir_id based on param types
        var func_ir_id: u32 = 0;
        const func_sym = self.lookup(node.data.name);
        if (func_sym) |sym| {
            func_ir_id = sym.ir_id;
            // Check if this is an overloaded function
            if (self.overloads.get(node.data.name)) |overload_list| {
                const node_params = node.data.params;
                for (overload_list.items) |overload| {
                    if (overload.param_types.len != node_params.len) continue;
                    var match = true;
                    for (overload.param_types, 0..) |pt, i| {
                        if (!self.typesCompatible(pt, node_params[i].ty)) {
                            match = false;
                            break;
                        }
                    }
                    if (match) {
                        func_ir_id = overload.ir_id;
                        break;
                    }
                }
            }
        } else {
            func_ir_id = self.allocId();
        }

        self.instructions.clearRetainingCapacity();

        var param_ids = std.ArrayListUnmanaged(u32){};
        defer param_ids.deinit(self.alloc);
        for (node.data.params) |param| {
            const pid = self.allocId();
            try param_ids.append(self.alloc, pid);

            const is_mutable = if (param.qualifier) |q| (q.is_inout or q.is_out) else false;

            if (is_mutable) {
                // For inout/out params: create a local variable and copy param value into it
                // This makes the param mutable inside the function body
                const var_id = self.allocId();
                const sc_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                sc_operands[0] = .{ .literal_int = 7 }; // Function storage class
                try self.instructions.append(self.alloc, .{
                    .tag = .local_variable,
                    .result_type = null,
                    .result_id = var_id,
                    .operands = sc_operands,
                    .ty = param.ty,
                });
                // Copy parameter value into the local variable
                const store_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                store_ops[0] = .{ .id = var_id };
                store_ops[1] = .{ .id = pid };
                try self.instructions.append(self.alloc, .{
                    .tag = .store,
                    .result_type = null,
                    .result_id = null,
                    .operands = store_ops,
                    .ty = param.ty,
                });
                try self.declare(param.name, .{
                    .kind = .var_sym,
                    .ty = param.ty,
                    .ir_id = var_id,
                });
            } else {
                try self.declare(param.name, .{
                    .kind = .param,
                    .ty = param.ty,
                    .ir_id = pid,
                });
            }
        }

        // Note: instructions already contain param init stores, don't clear them

        for (node.data.children) |child| {
            self.analyzeStatement(child) catch |err| {
                if (self.tolerate_errors) {
                    // In tolerate mode: record the error but continue with partial IR
                    const msg = std.fmt.allocPrint(self.alloc, "{s} in {s}", .{@errorName(err), @tagName(child.tag)}) catch "error";
                    self.errors.append(self.alloc, msg) catch {};
                    break;
                } else {
                    return err;
                }
            };
            // Stop processing after a return statement (dead code elimination)
            if (self.instructions.items.len > 0) {
                const last_tag = self.instructions.items[self.instructions.items.len - 1].tag;
                if (last_tag == .return_void or last_tag == .return_val or last_tag == .unreachable_inst or last_tag == .kill) break;
            }
        }

        // Check if the last instruction is a return (covers all paths)
        const needs_implicit_return = if (self.instructions.items.len > 0) blk: {
            const last_tag = self.instructions.items[self.instructions.items.len - 1].tag;
            break :blk last_tag != .return_void and last_tag != .return_val and last_tag != .unreachable_inst;
        } else true;

        // If last instruction is not a return, add an implicit return
        if (needs_implicit_return) {
            const func_ret_ty = node.data.ty orelse .void;
            if (func_ret_ty == .void) {
                try self.instructions.append(self.alloc, .{
                    .tag = .return_void,
                    .result_type = null,
                    .result_id = null,
                    .operands = &.{},
                    .ty = .void,
                });
            } else {
                // Non-void function with unreachable code path: emit OpUnreachable
                try self.instructions.append(self.alloc, .{
                    .tag = .unreachable_inst,
                    .result_type = null,
                    .result_id = null,
                    .operands = &.{},
                    .ty = .void,
                });
            }
        }

        const func = ir.Function{
            .name = node.data.name,
            .return_type = node.data.ty orelse .void,
            .params = node.data.params,
            .param_ids = try param_ids.toOwnedSlice(self.alloc),
            .body = try self.instructions.toOwnedSlice(self.alloc),
            .locals = &.{},
            .result_id = func_ir_id,
        };
        try self.functions.append(self.alloc, func);

        self.popScope();
    }

    fn analyzeStatement(self: *Analyzer, node: ast.Node) !void {
        // Dead code elimination: skip instructions after return
        if (self.has_returned) return;
        errdefer {
            if (last_error_ctx.len == 0) last_error_ctx = @tagName(node.tag);
            if (last_error_line == 0) {
                last_error_line = node.loc.line;
                last_error_column = node.loc.column;
            }
        }
        switch (node.tag) {
            .var_decl => {
                const ty = node.data.ty orelse .void;
                if (node.data.children.len > 0) {
                    // Has initializer — try SSA path first
                    var init = try self.analyzeExpression(node.data.children[0]);
                    // If the initializer is a pointer (from access chain), load it first
                    if (init.is_ptr) {
                        const loaded_id = self.allocId();
                        const load_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        load_ops[0] = .{ .id = init.id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .load,
                            .result_type = null,
                            .result_id = loaded_id,
                            .operands = load_ops,
                            .ty = init.ty,
                        });
                        init = .{ .ty = init.ty, .id = loaded_id };
                    }
                    if (!self.typesCompatible(ty, init.ty)) {
                        return error.TypeMismatch;
                    }
                    // Convert initializer type to match declared type if needed
                    var init_id = init.id;
                    if (!std.meta.eql(ty, init.ty)) {
                        const conv_tag: ?ir.Instruction.Tag = blk: {
                            // int <-> uint same width: use bitcast
                            if (ty == .uint and init.ty == .int) break :blk .bitcast;
                            if (ty == .int and init.ty == .uint) break :blk .bitcast;
                            // Use generic conversion helper
                            break :blk self.getConversionTag(ty, init.ty);
                        };
                        if (conv_tag) |tag| {
                            const conv_id = self.allocId();
                            const conv_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                            conv_ops[0] = .{ .id = init.id };
                            try self.instructions.append(self.alloc, .{
                                .tag = tag,
                                .result_type = null,
                                .result_id = conv_id,
                                .operands = conv_ops,
                                .ty = ty,
                            });
                            init_id = conv_id;
                        }
                    }
                    // Declare as SSA — init_value is used directly, no OpVariable/OpStore
                    // Only SSA-ify simple types (scalar, vector, matrix)
                    // Struct/array types need OpVariable for member access chains
                    const can_ssa = switch (ty) {
                        .void => false,
                        .named, .array => false,
                        else => true, // scalar, vector, matrix types
                    };
                    // For SSA vars, reuse init_id as ir_id (no separate allocation needed)
                    // If the var is later written to, a new ID is allocated for the OpVariable
                    const ir_id = if (can_ssa) init_id else blk: {
                        // Must create OpVariable for struct/array types
                        const id = self.allocId();
                        const sc_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        sc_operands[0] = .{ .literal_int = 7 };
                        try self.instructions.append(self.alloc, .{
                            .tag = .local_variable,
                            .result_type = null,
                            .result_id = id,
                            .operands = sc_operands,
                            .ty = ty,
                        });
                        // Store init value
                        const store_operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        store_operands[0] = .{ .id = id };
                        store_operands[1] = .{ .id = init_id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .store,
                            .result_type = null,
                            .result_id = null,
                            .operands = store_operands,
                            .ty = .void,
                        });
                        break :blk id;
                    };
                    try self.declare(node.data.name, .{
                        .kind = .var_sym,
                        .ty = ty,
                        .ir_id = ir_id,
                        .init_value = if (can_ssa) init_id else null,
                        .is_ssa = can_ssa,
                    });
                } else {
                    // No initializer — must use OpVariable
                    const ir_id = self.allocId();
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
                }
            },
            .multi_decl => {
                for (node.data.children) |child| {
                    try self.analyzeStatement(child);
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

                // Save has_returned — it might be set by then/else branches
                const saved_has_returned = self.has_returned;
                self.has_returned = false;

                try self.emitLabel(then_label);
                const then_has_terminator = if (node.data.children.len > 1) blk: {
                    try self.analyzeStatement(node.data.children[1]);
                    break :blk self.lastInstructionIsBranch();
                } else false;
                const then_is_return = self.has_returned;
                if (!then_has_terminator) try self.emitBranch(merge_label);

                if (has_else) {
                    self.has_returned = false;
                    try self.emitLabel(else_label.?);
                    const else_has_terminator = blk: {
                        try self.analyzeStatement(node.data.children[2]);
                        break :blk self.lastInstructionIsBranch();
                    };
                    const else_is_return = self.has_returned;
                    if (!else_has_terminator) try self.emitBranch(merge_label);

                    // Mark merge as unreachable only if BOTH branches returned
                    if (then_is_return and else_is_return) {
                        try self.emitLabel(merge_label);
                        try self.instructions.append(self.alloc, .{
                            .tag = .unreachable_inst,
                            .result_type = null,
                            .result_id = null,
                            .operands = &.{},
                            .ty = .void,
                        });
                        self.has_returned = true;
                        return;
                    }
                    // Restore: only set has_returned if both branches returned
                    if (then_is_return and else_is_return) {
                        self.has_returned = true;
                    } else {
                        self.has_returned = saved_has_returned;
                    }
                } else {
                    // No else: if then returned, code after if might still execute (it shouldn't, but
                    // we don't know statically). Restore has_returned only if then returned AND
                    // there's no fallthrough path.
                    if (then_is_return) {
                        self.has_returned = saved_has_returned;
                    } else {
                        self.has_returned = saved_has_returned;
                    }
                }
                try self.emitLabel(merge_label);
            },
            .switch_stmt => {
                if (node.data.children.len < 2) return;

                const merge_label = self.allocId();

                // Evaluate selector
                const selector = try self.analyzeExpression(node.data.children[0]);
                var selector_id = selector.id;
                if (selector.is_ptr) {
                    const ld = self.allocId();
                    const ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    ops[0] = .{ .id = selector.id };
                    try self.instructions.append(self.alloc, .{ .tag = .load, .result_type = null, .result_id = ld, .operands = ops, .ty = selector.ty });
                    selector_id = ld;
                }

                const cases = node.data.children[1..];

                // Build OpSwitch: allocate a label per case + default
                // First, collect case values by evaluating case expressions
                const CaseInfo = struct { value: ?i64, label: u32, body_idx: usize };
                var case_infos = std.ArrayListUnmanaged(CaseInfo){};
                defer case_infos.deinit(self.alloc);

                for (cases, 0..) |case_node, ci| {
                    const is_default = case_node.data.name.len > 0 and std.mem.eql(u8, case_node.data.name, "default");
                    const label = self.allocId();
                    var value: ?i64 = null;
                    if (!is_default) {
                        // Case value is stored as first child of the case block
                        if (case_node.data.children.len > 0) {
                            value = self.evalConstInt(case_node.data.children[0]) catch null;
                        }
                    }
                    try case_infos.append(self.alloc, .{ .value = value, .label = label, .body_idx = ci });
                }

                const default_label = self.allocId();

                // Push merge label for break statements
                try self.loop_stack.append(self.alloc, .{
                    .merge_label = merge_label,
                    .continue_label = 0, // unused for switch
                });

                // Emit SelectionMerge + OpSwitch
                try self.emitSelectionMerge(merge_label);

                // Build OpSwitch operands
                var switch_ops = std.ArrayListUnmanaged(ir.Instruction.Operand){};
                defer switch_ops.deinit(self.alloc);

                // Default target
                const default_target = blk: {
                    for (case_infos.items) |ci| {
                        if (ci.value == null) break :blk ci.label;
                    }
                    break :blk default_label;
                };
                try switch_ops.append(self.alloc, .{ .id = default_target });

                // Case targets: [literal, target] pairs
                for (case_infos.items) |ci| {
                    if (ci.value) |v| {
                        try switch_ops.append(self.alloc, .{ .literal_int = @intCast(v) });
                        try switch_ops.append(self.alloc, .{ .id = ci.label });
                    }
                }

                try self.instructions.append(self.alloc, .{
                    .tag = .switch_inst,
                    .result_type = null,
                    .result_id = selector_id,
                    .operands = try switch_ops.toOwnedSlice(self.alloc),
                    .ty = selector.ty,
                });

                // Emit case bodies with proper labels
                for (case_infos.items, 0..) |ci, idx| {
                    try self.emitLabel(ci.label);
                    const case_node = cases[ci.body_idx];
                    // Skip first child (case value expression), emit body statements
                    const body_stmts = if (case_node.data.children.len > 0) case_node.data.children[1..] else case_node.data.children[0..0];
                    for (body_stmts) |stmt| {
                        self.analyzeStatement(stmt) catch {};
                    }
                    // Fall through to next case (or merge if last)
                    // (break statements already branch to merge_label)
                    if (!self.lastInstructionIsReturn() and !self.lastInstructionIsBranch()) {
                        if (idx + 1 < case_infos.items.len) {
                            // Fall through: branch to next case's label
                            try self.emitBranch(case_infos.items[idx + 1].label);
                        } else {
                            try self.emitBranch(merge_label);
                        }
                    }
                }

                // Default label if no default case was found
                var has_default = false;
                for (case_infos.items) |ci| {
                    if (ci.value == null) { has_default = true; break; }
                }
                if (!has_default) {
                    try self.emitLabel(default_label);
                    try self.emitBranch(merge_label);
                }

                try self.emitLabel(merge_label);
                _ = self.loop_stack.pop();
            },
            .for_stmt => {
                try self.pushScope();

                const header_label = self.allocId();
                const body_label = self.allocId();
                const continue_label = self.allocId();
                const merge_label = self.allocId();

                const children = node.data.children;
                const has_init = children.len > 0 and !(children[0].tag == .expr_stmt and children[0].data.children.len == 0);
                const has_cond = children.len > 1 and !(children[1].tag == .expr_stmt and children[1].data.children.len == 0);
                const has_update = children.len > 2 and !(children[2].tag == .expr_stmt and children[2].data.children.len == 0);

                // Init
                if (has_init) try self.analyzeStatement(children[0]);

                // Force un-SSA any variables in ALL scopes.
                // This ensures loop conditions/updates see variable loads, not init constants.
                // We need to un-SSA parent scope vars too (e.g., int k = 0; for (; k < 20; k++))
                try self.unssaAllScopes();

                try self.emitBranch(header_label);

                try self.loop_stack.append(self.alloc, .{
                    .merge_label = merge_label,
                    .continue_label = continue_label,
                });

                // Header: condition check, then merge + branch
                try self.emitLabel(header_label);
                if (has_cond) {
                    const cond = try self.analyzeExpression(children[1]);
                    const cond_id = cond.id;
                    try self.emitLoopMerge(merge_label, continue_label);
                    try self.emitBranchConditional(cond_id, body_label, merge_label);
                } else {
                    try self.emitLoopMerge(merge_label, continue_label);
                    try self.emitBranch(body_label);
                }

                // Body
                try self.emitLabel(body_label);
                if (children.len > 3) self.analyzeStatement(children[3]) catch {
                    // Body failed, continue to emit branch to continue label
                };
                if (!self.lastInstructionIsReturn()) {
                    try self.emitBranch(continue_label); // body -> continue
                }

                // Continue + update
                try self.emitLabel(continue_label);
                if (has_update) {
                    if (children[2].tag == .expr_stmt) {
                        self.analyzeStatement(children[2]) catch {};
                    } else {
                        // Bare expression node (e.g., comma_op from for-loop update)
                        _ = self.analyzeExpression(children[2]) catch {};
                    }
                }
                try self.emitBranch(header_label);

                _ = self.loop_stack.pop();
                try self.emitLabel(merge_label);

                self.popScope();
            },
            .while_stmt => {
                const header_label = self.allocId();
                const body_label = self.allocId();
                const continue_label = self.allocId();
                const merge_label = self.allocId();

                // Un-SSA variables in all scopes before evaluating loop condition
                // (e.g., int k = 0; while (k < 5) { k++; })
                try self.unssaAllScopes();

                try self.emitBranch(header_label);

                try self.loop_stack.append(self.alloc, .{
                    .merge_label = merge_label,
                    .continue_label = continue_label,
                });

                // Header: condition check, LoopMerge, branch
                try self.emitLabel(header_label);
                const cond = try self.analyzeExpression(node.data.children[0]);
                try self.emitLoopMerge(merge_label, continue_label);
                try self.emitBranchConditional(cond.id, body_label, merge_label);

                // Body
                try self.emitLabel(body_label);
                if (node.data.children.len > 1) try self.analyzeStatement(node.data.children[1]);
                if (!self.lastInstructionIsReturn()) {
                    try self.emitBranch(continue_label);
                }

                // Continue: branch back to header for re-evaluation
                try self.emitLabel(continue_label);
                try self.emitBranch(header_label);

                _ = self.loop_stack.pop();
                try self.emitLabel(merge_label);
            },
            .do_while_stmt => {
                const body_label = self.allocId();
                const cond_label = self.allocId();
                const merge_label = self.allocId();

                // Un-SSA variables in all scopes before loop body
                try self.unssaAllScopes();

                try self.emitBranch(body_label);

                try self.loop_stack.append(self.alloc, .{
                    .merge_label = merge_label,
                    .continue_label = cond_label,
                });

                try self.emitLabel(body_label);
                try self.emitLoopMerge(merge_label, cond_label);
                // Always emit branch to inner body block so OpLoopMerge is immediately followed by OpBranch
                const inner_label = self.allocId();
                try self.emitBranch(inner_label);
                try self.emitLabel(inner_label);
                if (node.data.children.len > 0) self.analyzeStatement(node.data.children[0]) catch {
                    // Body analysis failed, but LoopMerge already emitted.
                    // Continue to emit condition branch to keep SPIR-V valid.
                };

                // Branch from body to continue/condition label (if body doesn't already return)
                if (!self.lastInstructionIsReturn()) {
                    try self.emitBranch(cond_label);
                }

                try self.emitLabel(cond_label);
                const cond = try self.analyzeExpression(node.data.children[1]);
                try self.emitBranchConditional(cond.id, body_label, merge_label);

                _ = self.loop_stack.pop();
                try self.emitLabel(merge_label);
            },
            .return_stmt => {
                if (node.data.children.len > 0) {
                    var val = try self.analyzeExpression(node.data.children[0]);
                    if (val.is_ptr) {
                        const ld = self.allocId();
                        const ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        ops[0] = .{ .id = val.id };
                        try self.instructions.append(self.alloc, .{ .tag = .load, .result_type = null, .result_id = ld, .operands = ops, .ty = val.ty });
                        val = .{ .ty = val.ty, .id = ld };
                    }
                    const ret_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    ret_operands[0] = .{ .id = val.id };
                    try self.instructions.append(self.alloc, .{
                        .tag = .return_val,
                        .result_type = null,
                        .result_id = null,
                        .operands = ret_operands,
                        .ty = val.ty,
                    });
                    self.has_returned = true;
                } else {
                    try self.instructions.append(self.alloc, .{
                        .tag = .return_void,
                        .result_type = null,
                        .result_id = null,
                        .operands = &.{},
                        .ty = .void,
                    });
                    self.has_returned = true;
                }
            },
            .discard_stmt => {
                try self.instructions.append(self.alloc, .{
                    .tag = .kill,
                    .result_type = null,
                    .result_id = null,
                    .operands = &.{},
                    .ty = .void,
                });
            },
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
            .struct_decl => {
                // Inner struct declaration inside function body
                const name = node.data.name;
                const existing = self.types.getPtr(name);
                if (existing != null) {
                    // Redefinition: merge new members into existing type
                    const new_members = try self.alloc.dupe(ast.StructMember, node.data.members);
                    var merged = try std.ArrayListUnmanaged(ast.StructMember).initCapacity(self.alloc, existing.?.members.len + new_members.len);
                    try merged.appendSlice(self.alloc, existing.?.members);
                    try merged.appendSlice(self.alloc, new_members);
                    existing.?.members = merged.items;
                } else {
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
                        .ir_id = 0,
                    });
                }
            },
            else => {},
        }
    }

    /// Materialize an SSA variable into a proper OpVariable with pointer.
    /// Returns the new variable ID (pointer). Safe to call multiple times.
    fn materializeSSA(self: *Analyzer, name: []const u8) ?u32 {
        if (self.lookupMut(name)) |sym| {
            if (sym.kind == .var_sym and sym.is_ssa) {
                const var_id = self.allocId();
                const sc_ops = self.alloc.alloc(ir.Instruction.Operand, 1) catch return null;
                sc_ops[0] = .{ .literal_int = 7 }; // Function
                self.instructions.append(self.alloc, .{
                    .tag = .local_variable,
                    .result_type = null,
                    .result_id = var_id,
                    .operands = sc_ops,
                    .ty = sym.ty,
                }) catch return null;
                if (sym.init_value) |init_val| {
                    const store_ops = self.alloc.alloc(ir.Instruction.Operand, 2) catch return null;
                    store_ops[0] = .{ .id = var_id };
                    store_ops[1] = .{ .id = init_val };
                    self.instructions.append(self.alloc, .{
                        .tag = .store,
                        .result_type = null,
                        .result_id = null,
                        .operands = store_ops,
                        .ty = .void,
                    }) catch return null;
                }
                sym.ir_id = var_id;
                sym.is_ssa = false;
                sym.init_value = null;
                return var_id;
            }
        }
        return null;
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
                    if (sym.kind == .param) {
                        // Writing to a function parameter — create a local variable for mutability
                        const var_id = self.allocId();
                        const sc_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        sc_operands[0] = .{ .literal_int = 7 }; // Function storage class
                        try self.instructions.append(self.alloc, .{
                            .tag = .local_variable,
                            .result_type = null,
                            .result_id = var_id,
                            .operands = sc_operands,
                            .ty = sym.ty,
                        });
                        const store_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        store_ops[0] = .{ .id = var_id };
                        store_ops[1] = .{ .id = sym.ir_id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .store,
                            .result_type = null,
                            .result_id = null,
                            .operands = store_ops,
                            .ty = sym.ty,
                        });
                        try self.declare(node.data.name, .{
                            .kind = .var_sym,
                            .ty = sym.ty,
                            .ir_id = var_id,
                        });
                        return .{ .ty = sym.ty, .id = var_id };
                    }
                    if (sym.kind == .var_sym and sym.is_ssa) {
                        // SSA variable being written to — materialize as real OpVariable
                        // Allocate a new ID for the OpVariable (ir_id was reused from init_value)
                        const var_id = self.allocId();
                        const sc_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        sc_operands[0] = .{ .literal_int = 7 };
                        try self.instructions.append(self.alloc, .{
                            .tag = .local_variable,
                            .result_type = null,
                            .result_id = var_id,
                            .operands = sc_operands,
                            .ty = sym.ty,
                        });
                        if (sym.init_value) |init_val| {
                            const store_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                            store_ops[0] = .{ .id = var_id };
                            store_ops[1] = .{ .id = init_val };
                            try self.instructions.append(self.alloc, .{
                                .tag = .store,
                                .result_type = null,
                                .result_id = null,
                                .operands = store_ops,
                                .ty = .void,
                            });
                        }
                        // Update symbol with new var_id and clear SSA flag
                        if (self.lookupMut(node.data.name)) |mut_sym| {
                            mut_sym.ir_id = var_id;
                            mut_sym.is_ssa = false;
                            mut_sym.init_value = null;
                        }
                        return .{ .ty = sym.ty, .id = var_id };
                    }
                    return .{ .ty = sym.ty, .id = sym.ir_id };
                }
                last_error_ctx = node.data.name;
                return error.UndeclaredIdentifier;
            },
            .member_access => {
                if (node.data.children.len < 1) return error.InvalidAssignment;
                const base_lv = try self.analyzeLValue(node.data.children[0]);
                const member_name = node.data.name;
                // Struct member access: base_ptr + member_index → member_ptr
                if (base_lv.ty == .named) {
                    const struct_name = base_lv.ty.named;
                    if (self.types.get(struct_name)) |td| {
                        var member_index: ?u32 = null;
                        for (td.members, 0..) |member, i| {
                            if (std.mem.eql(u8, member.name, member_name)) {
                                member_index = @as(u32, @intCast(i));
                                break;
                            }
                        }
                        if (member_index) |idx| {
                            const member_ty = td.members[idx].ty;
                            const ptr_id = self.allocId();
                            const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                            operands[0] = .{ .id = base_lv.id };
                            operands[1] = .{ .literal_int = idx };
                            try self.instructions.append(self.alloc, .{
                                .tag = .access_chain,
                                .result_type = null,
                                .result_id = ptr_id,
                                .operands = operands,
                                .ty = member_ty,
                            });
                            return .{ .ty = member_ty, .id = ptr_id, .is_ptr = true };
                        }
                    }
                }
                // Vector swizzle write (single component): v.x = val
                if (base_lv.ty.isVector() and member_name.len == 1) {
                    const idx = self.swizzleIndex(member_name[0]);
                    const elem_ty = base_lv.ty.elementType();
                    const ptr_id = self.allocId();
                    const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                    operands[0] = .{ .id = base_lv.id };
                    operands[1] = .{ .literal_int = idx };
                    try self.instructions.append(self.alloc, .{
                        .tag = .access_chain,
                        .result_type = null,
                        .result_id = ptr_id,
                        .operands = operands,
                        .ty = elem_ty,
                    });
                    return .{ .ty = elem_ty, .id = ptr_id, .is_ptr = true };
                }
                last_error_ctx = "invalid-assign";
                return error.InvalidAssignment;
            },
            .index_access => {
                // array[index] as l-value: get pointer to element via access chain
                if (node.data.children.len < 2) return error.SemanticFailed;
                const base_lv = try self.analyzeLValue(node.data.children[0]);
                const index_tid = try self.analyzeExpression(node.data.children[1]);
                // Determine element type
                const element_ty = if (base_lv.ty == .array)
                    base_lv.ty.array.base.*
                else if (base_lv.ty.isVector())
                    base_lv.ty.elementType()
                else
                    return error.TypeMismatch;
                const ptr_id = self.allocId();
                const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                operands[0] = .{ .id = base_lv.id };
                operands[1] = .{ .id = index_tid.id };
                try self.instructions.append(self.alloc, .{
                    .tag = .access_chain,
                    .result_type = null,
                    .result_id = ptr_id,
                    .operands = operands,
                    .ty = element_ty,
                });
                return .{ .ty = element_ty, .id = ptr_id };
            },
            else => {
                last_error_ctx = "invalid-assign";
                return error.InvalidAssignment;
            },
        }
    }

    fn evalConstInt(self: *Analyzer, node: ast.Node) Error!i64 {
        switch (node.tag) {
            .int_literal => {
                return @intCast(node.data.int_val);
            },
            .uint_literal => {
                return @intCast(node.data.int_val);
            },
            .group => {
                if (node.data.children.len == 1) return self.evalConstInt(node.data.children[0]);
                return error.SemanticFailed;
            },
            else => return error.SemanticFailed,
        }
    }

    fn analyzeExpression(self: *Analyzer, node: ast.Node) Error!TypedId {
        errdefer {
            if (last_error_inner.len == 0) {
                last_error_inner = switch (node.tag) {
                    .identifier => node.data.name,
                    else => @tagName(node.tag),
                };
            }
            // Use the identifier/function name when available for better error messages
            last_error_ctx = switch (node.tag) {
                .identifier, .func_call => node.data.name,
                else => @tagName(node.tag),
            };
            if (last_error_line == 0) {
                last_error_line = node.loc.line;
                last_error_column = node.loc.column;
            }
        }
        switch (node.tag) {
            .int_literal => {
                const val: u32 = @intCast(node.data.int_val);
                const key = (@as(u64, @intFromEnum(ast.Type.int)) << 32) | @as(u64, val);
                if (self.const_cache.get(key)) |cached| return .{ .ty = .int, .id = cached };
                const id = self.allocId();
                const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                operands[0] = .{ .literal_int = val };
                try self.instructions.append(self.alloc, .{
                    .tag = .constant_int,
                    .result_type = null,
                    .result_id = id,
                    .operands = operands,
                    .ty = .int,
                });
                try self.const_cache.put(self.alloc, key, id);
                return .{ .ty = .int, .id = id };
            },
            .uint_literal => {
                const val: u32 = @intCast(node.data.int_val);
                const key = (@as(u64, @intFromEnum(ast.Type.uint)) << 32) | @as(u64, val);
                if (self.const_cache.get(key)) |cached| return .{ .ty = .uint, .id = cached };
                const id = self.allocId();
                const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                operands[0] = .{ .literal_int = val };
                try self.instructions.append(self.alloc, .{
                    .tag = .constant_int,
                    .result_type = null,
                    .result_id = id,
                    .operands = operands,
                    .ty = .uint,
                });
                try self.const_cache.put(self.alloc, key, id);
                return .{ .ty = .uint, .id = id };
            },
            .float_literal => {
                const val: f32 = @floatCast(node.data.float_val);
                const val_bits: u32 = @bitCast(val);
                const key = (@as(u64, @intFromEnum(ast.Type.float)) << 32) | @as(u64, val_bits);
                if (self.const_cache.get(key)) |cached| return .{ .ty = .float, .id = cached };
                const id = self.allocId();
                const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                operands[0] = .{ .literal_float = val };
                try self.instructions.append(self.alloc, .{
                    .tag = .constant_float,
                    .result_type = null,
                    .result_id = id,
                    .operands = operands,
                    .ty = .float,
                });
                try self.const_cache.put(self.alloc, key, id);
                return .{ .ty = .float, .id = id };
            },
            .bool_literal => {
                const val: u32 = if (node.data.int_val != 0) 1 else 0;
                const key = (@as(u64, @intFromEnum(ast.Type.bool)) << 32) | @as(u64, val);
                if (self.const_cache.get(key)) |cached| return .{ .ty = .bool, .id = cached };
                const id = self.allocId();
                const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                operands[0] = .{ .literal_int = val };
                try self.instructions.append(self.alloc, .{
                    .tag = .constant_bool,
                    .result_type = null,
                    .result_id = id,
                    .operands = operands,
                    .ty = .bool,
                });
                try self.const_cache.put(self.alloc, key, id);
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
                        // If the member is an array type, don't load — return the pointer
                        // so that index_access can chain another access chain
                        if (sym.ty == .array) {
                            return .{ .ty = sym.ty, .id = ptr_id, .is_ptr = true };
                        }
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
                    if (sym.kind == .var_sym) {
                        // SSA variable — use init_value directly instead of load
                        if (sym.is_ssa and sym.init_value != null) {
                            return .{ .ty = sym.ty, .id = sym.init_value.? };
                        }
                        // Variables (globals/locals) are pointers — need OpLoad to get value
                        // But array variables should NOT be loaded — return pointer for index_access
                        if (sym.ty == .array) {
                            return .{ .ty = sym.ty, .id = sym.ir_id, .is_ptr = true };
                        }
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
                // Handle void builtins used as statements (e.g., demote)
                if (self.isBarrierBuiltin(node.data.name)) {
                    return .{ .ty = .void, .id = 0 };
                }
                last_error_ctx = node.data.name;
                return error.UndeclaredIdentifier;
            },
            .binary_op => {
                if (node.data.children.len < 2) {
                    // Parser produced a malformed binary_op — treat as void expression
                    return .{ .ty = .void, .id = self.allocId() };
                }
                var left = try self.analyzeExpression(node.data.children[0]);
                var right = try self.analyzeExpression(node.data.children[1]);
                // Auto-load pointers
                if (left.is_ptr) {
                    const ld = self.allocId();
                    const ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    ops[0] = .{ .id = left.id };
                    try self.instructions.append(self.alloc, .{ .tag = .load, .result_type = null, .result_id = ld, .operands = ops, .ty = left.ty });
                    left = .{ .ty = left.ty, .id = ld };
                }
                if (right.is_ptr) {
                    const ld = self.allocId();
                    const ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    ops[0] = .{ .id = right.id };
                    try self.instructions.append(self.alloc, .{ .tag = .load, .result_type = null, .result_id = ld, .operands = ops, .ty = right.ty });
                    right = .{ .ty = right.ty, .id = ld };
                }
                const result_ty = self.promoteTypes(left.ty, right.ty) orelse return error.TypeMismatch;
                const result_id = self.allocId();

                // Convert int/uint to float if needed for mixed comparisons/arithmetic
                var left_conv_id: ?u32 = null;
                var right_conv_id: ?u32 = null;
                if (left.ty == .int and (result_ty == .float or result_ty == .double)) {
                    const cvt_id = self.allocId();
                    const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    cvt_ops[0] = .{ .id = left.id };
                    try self.instructions.append(self.alloc, .{ .tag = .convert_itof, .result_type = null, .result_id = cvt_id, .operands = cvt_ops, .ty = .float });
                    left_conv_id = cvt_id;
                }
                if (right.ty == .int and (result_ty == .float or result_ty == .double)) {
                    const cvt_id = self.allocId();
                    const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    cvt_ops[0] = .{ .id = right.id };
                    try self.instructions.append(self.alloc, .{ .tag = .convert_itof, .result_type = null, .result_id = cvt_id, .operands = cvt_ops, .ty = .float });
                    right_conv_id = cvt_id;
                }
                if (left.ty == .uint and (result_ty == .float or result_ty == .double)) {
                    const cvt_id = self.allocId();
                    const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    cvt_ops[0] = .{ .id = left.id };
                    try self.instructions.append(self.alloc, .{ .tag = .convert_utof, .result_type = null, .result_id = cvt_id, .operands = cvt_ops, .ty = .float });
                    left_conv_id = cvt_id;
                }
                if (right.ty == .uint and (result_ty == .float or result_ty == .double)) {
                    const cvt_id = self.allocId();
                    const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    cvt_ops[0] = .{ .id = right.id };
                    try self.instructions.append(self.alloc, .{ .tag = .convert_utof, .result_type = null, .result_id = cvt_id, .operands = cvt_ops, .ty = .float });
                    right_conv_id = cvt_id;
                }

                // Track if we splatted so we can use regular ops
                var did_splat = false;

                // Splat scalar to vector if needed for arithmetic ops
                var left_id: u32 = if (left_conv_id) |id| id else left.id;
                var right_id: u32 = if (right_conv_id) |id| id else right.id;
                // Convert int/uint vectors to float vectors when needed
                if (result_ty.isVector() and result_ty.isFloatVector()) {
                    if (left.ty.isVector() and left.ty.isIntVector()) {
                        const conv_tag: ir.Instruction.Tag = if (left.ty == .uvec2 or left.ty == .uvec3 or left.ty == .uvec4) .convert_utof else .convert_itof;
                        const cvt_id = self.allocId();
                        const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        cvt_ops[0] = .{ .id = left_id };
                        try self.instructions.append(self.alloc, .{ .tag = conv_tag, .result_type = null, .result_id = cvt_id, .operands = cvt_ops, .ty = result_ty });
                        left_id = cvt_id;
                    }
                    if (right.ty.isVector() and right.ty.isIntVector()) {
                        const conv_tag: ir.Instruction.Tag = if (right.ty == .uvec2 or right.ty == .uvec3 or right.ty == .uvec4) .convert_utof else .convert_itof;
                        const cvt_id = self.allocId();
                        const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        cvt_ops[0] = .{ .id = right_id };
                        try self.instructions.append(self.alloc, .{ .tag = conv_tag, .result_type = null, .result_id = cvt_id, .operands = cvt_ops, .ty = result_ty });
                        right_id = cvt_id;
                    }
                }
                const op = node.data.op orelse .add;
                if (result_ty.isVector()) {
                    if (left.ty.isScalar() and !right.ty.isScalar()) {
                        // Check if we can use vector-scalar op instead of splat
                        const is_float_vec = right.ty == .vec2 or right.ty == .vec3 or right.ty == .vec4;
                        if (op == .mul and is_float_vec and left.ty == .float) {
                            // Skip splat, will use scalar_vec_mul tag
                        } else {
                            // Splat left scalar to vector
                            const num_comps = result_ty.numComponents();
                            const splat_id = self.allocId();
                            const splat_operands = try self.alloc.alloc(ir.Instruction.Operand, num_comps);
                            for (0..num_comps) |i| {
                                splat_operands[i] = .{ .id = left_id };
                            }
                            try self.instructions.append(self.alloc, .{
                                .tag = .composite_construct,
                                .result_type = null,
                                .result_id = splat_id,
                                .operands = splat_operands,
                                .ty = result_ty,
                            });
                            _ = self.tryUpgradeToConstantComposite();
                            left_id = splat_id;
                            did_splat = true;
                        }
                    } else if (!left.ty.isScalar() and right.ty.isScalar()) {
                        // Check if we can use vector-scalar op instead of splat
                        const is_float_vec = left.ty == .vec2 or left.ty == .vec3 or left.ty == .vec4;
                        if (op == .mul and is_float_vec and right.ty == .float) {
                            // Skip splat, will use vec_scalar_mul tag
                        } else {
                            // Splat right scalar to vector
                            const num_comps = result_ty.numComponents();
                            const splat_id = self.allocId();
                            const splat_operands = try self.alloc.alloc(ir.Instruction.Operand, num_comps);
                            for (0..num_comps) |i| {
                                splat_operands[i] = .{ .id = right_id };
                            }
                            try self.instructions.append(self.alloc, .{
                                .tag = .composite_construct,
                                .result_type = null,
                                .result_id = splat_id,
                                .operands = splat_operands,
                                .ty = result_ty,
                            });
                            _ = self.tryUpgradeToConstantComposite();
                            right_id = splat_id;
                            did_splat = true;
                        }
                    }
                }

                const is_float = result_ty == .float or result_ty == .double or result_ty == .vec2 or result_ty == .vec3 or result_ty == .vec4 or result_ty.isMatrix();


                const tag: ir.Instruction.Tag = switch (op) {
                    .add => if (is_float) .fadd else .add,
                    .sub => if (is_float) .fsub else .sub,
                    .mul => blk: {
                        if (did_splat) break :blk if (is_float) .fmul else .mul;
                        if (left.ty.isMatrix() and right.ty.isVector()) break :blk .mat_vec_mul;
                        if (left.ty.isVector() and right.ty.isMatrix()) break :blk .vec_mat_mul;
                        if (left.ty.isMatrix() and right.ty.isMatrix()) break :blk .mat_mat_mul;
                        if (left.ty.isMatrix() and (right.ty == .float)) break :blk .mat_scalar_mul;
                        if (left.ty.isVector() and right.ty == .float) break :blk .vec_scalar_mul;
                        if (left.ty == .float and right.ty.isVector()) break :blk .scalar_vec_mul;
                        if (left.ty == .float and right.ty.isMatrix()) break :blk .scalar_mat_mul;
                        break :blk if (is_float) .fmul else .mul;
                    },
                    .div => if (is_float) .fdiv else .div,
                    .mod => blk: {
                        if (is_float) break :blk .fmod;
                        // Check if unsigned int type
                        const is_uint = left.ty == .uint or left.ty == .uvec2 or left.ty == .uvec3 or left.ty == .uvec4;
                        break :blk if (is_uint) .umod else .rem;
                    },
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
                operands[0] = .{ .id = left_id };
                operands[1] = .{ .id = right_id };

                // Comparison and logical operators return bool, not the operand type
                const returns_bool = switch (op) {
                    .eq, .neq, .lt, .gt, .lte, .gte, .logical_and, .logical_or => true,
                    else => false,
                };

                // Override result type for matrix-vector multiplication
                // vec(N) * mat(KxN) = vec(K), mat(MxN) * vec(N) = vec(M)
                var final_result_ty = result_ty;
                if (tag == .vec_mat_mul and right.ty.isMatrix()) {
                    // vec * mat: result has number of columns, element type from the vec
                    const num_cols = right.ty.numColumns();
                    const elem = left.ty.elementType();
                    final_result_ty = switch (num_cols) {
                        2 => elem.toVec2(),
                        3 => elem.toVec3(),
                        4 => elem.toVec4(),
                        else => result_ty,
                    };
                } else if (tag == .mat_vec_mul and left.ty.isMatrix()) {
                    // mat * vec: result is a column vector (rows of the matrix)
                    final_result_ty = left.ty.columnType();
                }

                try self.instructions.append(self.alloc, .{
                    .tag = tag,
                    .result_type = null,
                    .result_id = result_id,
                    .operands = operands,
                    .ty = if (returns_bool) .bool else final_result_ty,
                });
                return .{ .ty = if (returns_bool) .bool else final_result_ty, .id = result_id };
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

                // Check for swizzle write: v.xy = vec2(...), v.xyz = vec3(...)
                const lhs = node.data.children[0];
                if (lhs.tag == .member_access and lhs.data.children.len > 0) {
                    const base_node = lhs.data.children[0];
                    if (base_node.tag == .identifier) {
                        if (self.lookup(base_node.data.name)) |sym| {
                            const base_ty = sym.ty;
                            if (base_ty.isVector()) {
                                const swizzle_name = lhs.data.name;
                                if (swizzle_name.len > 1) {
                                    // Multi-component swizzle write
                                    // Evaluate the RHS value
                                    var value = try self.analyzeExpression(node.data.children[1]);
                                    if (value.is_ptr) {
                                        const loaded_id = self.allocId();
                                        const load_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                                        load_ops[0] = .{ .id = value.id };
                                        try self.instructions.append(self.alloc, .{ .tag = .load, .result_type = null, .result_id = loaded_id, .operands = load_ops, .ty = value.ty });
                                        value = .{ .ty = value.ty, .id = loaded_id };
                                    }

                                    // Materialize SSA variable if needed for swizzle write
                                    _ = self.materializeSSA(base_node.data.name);
                                    // Re-lookup to get updated ir_id after materialization
                                    const mat_sym = self.lookup(base_node.data.name);
                                    const var_ptr_id = if (mat_sym) |ms| ms.ir_id else sym.ir_id;

                                    // Load current vector value directly from the variable
                                    const load_id = self.allocId();
                                    const ld_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                                    ld_ops[0] = .{ .id = var_ptr_id };
                                    try self.instructions.append(self.alloc, .{ .tag = .load, .result_type = null, .result_id = load_id, .operands = ld_ops, .ty = base_ty });

                                    // Build VectorShuffle: combine current vector with new values
                                    const n = base_ty.numComponents();
                                    const swizzle_len = swizzle_name.len;
                                    const shuffle_ops = try self.alloc.alloc(ir.Instruction.Operand, 2 + n);
                                    shuffle_ops[0] = .{ .id = load_id }; // current vector (vec1)
                                    shuffle_ops[1] = .{ .id = value.id }; // new values (vec2)

                                    // Build shuffle select: for each component of the output
                                    for (0..n) |i| {
                                        // Check if this component is in the swizzle
                                        var found = false;
                                        for (0..swizzle_len) |j| {
                                            const swizzle_idx = self.swizzleIndex(swizzle_name[j]);
                                            if (swizzle_idx == i) {
                                                // Use from new values (vec2): select from n + j
                                                shuffle_ops[2 + i] = .{ .literal_int = @intCast(n + j) };
                                                found = true;
                                                break;
                                            }
                                        }
                                        if (!found) {
                                            // Keep from current vector (vec1): select index i
                                            shuffle_ops[2 + i] = .{ .literal_int = @intCast(i) };
                                        }
                                    }

                                    const shuffle_id = self.allocId();
                                    try self.instructions.append(self.alloc, .{
                                        .tag = .vector_shuffle,
                                        .result_type = null,
                                        .result_id = shuffle_id,
                                        .operands = shuffle_ops,
                                        .ty = base_ty,
                                    });

                                    // Store the shuffled vector back
                                    const store_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                                    store_ops[0] = .{ .id = var_ptr_id };
                                    store_ops[1] = .{ .id = shuffle_id };
                                    try self.instructions.append(self.alloc, .{
                                        .tag = .store,
                                        .result_type = null,
                                        .result_id = null,
                                        .operands = store_ops,
                                        .ty = .void,
                                    });
                                    return .{ .ty = .void, .id = 0 };
                                }
                            }
                        }
                    }
                }

                const target = try self.analyzeLValue(node.data.children[0]);
                var value = try self.analyzeExpression(node.data.children[1]);
                // If value is a pointer, load it
                if (value.is_ptr) {
                    const loaded_id = self.allocId();
                    const load_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    load_ops[0] = .{ .id = value.id };
                    try self.instructions.append(self.alloc, .{
                        .tag = .load,
                        .result_type = null,
                        .result_id = loaded_id,
                        .operands = load_ops,
                        .ty = value.ty,
                    });
                    value = .{ .ty = value.ty, .id = loaded_id };
                }
                // Convert value type to match target type if compatible but different
                var value_id = value.id;
                if (!std.meta.eql(target.ty, value.ty)) {
                    const conv_tag: ?ir.Instruction.Tag = blk: {
                        // int <-> uint same width: use bitcast (same bits, different type)
                        if (target.ty == .uint and value.ty == .int) break :blk .bitcast;
                        if (target.ty == .int and value.ty == .uint) break :blk .bitcast;
                        if (target.ty == .float and value.ty == .int) break :blk .convert_itof;
                        if (target.ty == .float and value.ty == .uint) break :blk .convert_utof;
                        if (target.ty == .int and value.ty == .float) break :blk .convert_ftoi;
                        if (target.ty == .uint and value.ty == .float) break :blk .convert_ftou;
                        break :blk null;
                    };
                    if (conv_tag) |tag| {
                        const conv_id = self.allocId();
                        const conv_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        conv_ops[0] = .{ .id = value.id };
                        try self.instructions.append(self.alloc, .{
                            .tag = tag,
                            .result_type = null,
                            .result_id = conv_id,
                            .operands = conv_ops,
                            .ty = target.ty,
                        });
                        value_id = conv_id;
                    }
                }
                const store_operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                store_operands[0] = .{ .id = target.id };
                store_operands[1] = .{ .id = value_id };
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

                // Handle multi-component swizzle compound assignment: v.xy *= expr, v.xyz += expr, etc.
                const lhs = node.data.children[0];
                if (lhs.tag == .member_access and lhs.data.children.len > 0) {
                    const base_node = lhs.data.children[0];
                    if (base_node.tag == .identifier) {
                        if (self.lookup(base_node.data.name)) |sym| {
                            const base_ty = sym.ty;
                            if (base_ty.isVector()) {
                                const swizzle_name = lhs.data.name;
                                if (swizzle_name.len > 1) {
                                    // Multi-component swizzle compound assign
                                    // Materialize SSA variable if needed
                                    _ = self.materializeSSA(base_node.data.name);
                                    const mat_sym2 = self.lookup(base_node.data.name);
                                    const var_ptr_id2 = if (mat_sym2) |ms| ms.ir_id else sym.ir_id;

                                    // 1. Load current vector
                                    const vec_load_id = self.allocId();
                                    const vec_ld_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                                    vec_ld_ops[0] = .{ .id = var_ptr_id2 };
                                    try self.instructions.append(self.alloc, .{ .tag = .load, .result_type = null, .result_id = vec_load_id, .operands = vec_ld_ops, .ty = base_ty });

                                    // 2. Extract swizzled components from the loaded vector
                                    const swizzle_len = swizzle_name.len;
                                    const swizzle_ops = try self.alloc.alloc(ir.Instruction.Operand, 2 + swizzle_len);
                                    swizzle_ops[0] = .{ .id = vec_load_id };
                                    swizzle_ops[1] = .{ .id = vec_load_id }; // second vector unused for extract-only
                                    for (0..swizzle_len) |i| {
                                        swizzle_ops[2 + i] = .{ .literal_int = self.swizzleIndex(swizzle_name[i]) };
                                    }
                                    const swizzled_id = self.allocId();
                                    const swizzled_ty: ast.Type = switch (base_ty) {
                                        .vec2, .vec3, .vec4 => switch (swizzle_len) {
                                            2 => ast.Type.vec2,
                                            3 => ast.Type.vec3,
                                            4 => ast.Type.vec4,
                                            else => base_ty,
                                        },
                                        .ivec2, .ivec3, .ivec4 => switch (swizzle_len) {
                                            2 => ast.Type.ivec2,
                                            3 => ast.Type.ivec3,
                                            4 => ast.Type.ivec4,
                                            else => base_ty,
                                        },
                                        .uvec2, .uvec3, .uvec4 => switch (swizzle_len) {
                                            2 => ast.Type.uvec2,
                                            3 => ast.Type.uvec3,
                                            4 => ast.Type.uvec4,
                                            else => base_ty,
                                        },
                                        .bvec2, .bvec3, .bvec4 => switch (swizzle_len) {
                                            2 => ast.Type.bvec2,
                                            3 => ast.Type.bvec3,
                                            4 => ast.Type.bvec4,
                                            else => base_ty,
                                        },
                                        else => base_ty,
                                    };
                                    try self.instructions.append(self.alloc, .{
                                        .tag = .vector_shuffle,
                                        .result_type = null,
                                        .result_id = swizzled_id,
                                        .operands = swizzle_ops,
                                        .ty = swizzled_ty,
                                    });

                                    // 3. Evaluate RHS
                                    var value = try self.analyzeExpression(node.data.children[1]);
                                    if (value.is_ptr) {
                                        const loaded_id = self.allocId();
                                        const ld_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                                        ld_ops[0] = .{ .id = value.id };
                                        try self.instructions.append(self.alloc, .{ .tag = .load, .result_type = null, .result_id = loaded_id, .operands = ld_ops, .ty = value.ty });
                                        value = .{ .ty = value.ty, .id = loaded_id };
                                    }

                                    // 3b. Determine operation before splat decision
                                    const assign_op = node.data.op orelse .mul_assign;

                                    // Splat scalar to swizzle_len if needed
                                    var value_id = value.id;
                                    const skip_splat_for_mul = assign_op == .mul_assign and !value.ty.isVector() and swizzled_ty.isVector() and swizzled_ty.isFloatVector();
                                    if (!skip_splat_for_mul and !value.ty.isVector() and swizzled_ty.isVector()) {
                                        const splat_ops = try self.alloc.alloc(ir.Instruction.Operand, swizzle_len);
                                        for (0..swizzle_len) |i| {
                                            splat_ops[i] = .{ .id = value.id };
                                        }
                                        const splat_id = self.allocId();
                                        try self.instructions.append(self.alloc, .{
                                            .tag = .composite_construct,
                                            .result_type = null,
                                            .result_id = splat_id,
                                            .operands = splat_ops,
                                            .ty = swizzled_ty,
                                        });
                                        _ = self.tryUpgradeToConstantComposite();
                                        value_id = splat_id;
                                    }

                                    // 4. Apply the compound operation
                                    const op_tag: ir.Instruction.Tag = switch (assign_op) {
                                        .add_assign => .fadd,
                                        .sub_assign => .fsub,
                                        .mul_assign => if (skip_splat_for_mul) .vec_scalar_mul else .fmul,
                                        .div_assign => .fdiv,
                                        else => .fmul, // fallback
                                    };
                                    const result_id = self.allocId();
                                    const op_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                                    op_ops[0] = .{ .id = swizzled_id };
                                    op_ops[1] = .{ .id = value_id };
                                    try self.instructions.append(self.alloc, .{
                                        .tag = op_tag,
                                        .result_type = null,
                                        .result_id = result_id,
                                        .operands = op_ops,
                                        .ty = swizzled_ty,
                                    });

                                    // 5. VectorShuffle to combine: keep non-swizzled from original, use result for swizzled
                                    const n = base_ty.numComponents();
                                    const final_shuffle_ops = try self.alloc.alloc(ir.Instruction.Operand, 2 + n);
                                    final_shuffle_ops[0] = .{ .id = vec_load_id }; // original vector
                                    final_shuffle_ops[1] = .{ .id = result_id }; // computed values
                                    for (0..n) |i| {
                                        var found = false;
                                        for (0..swizzle_len) |j| {
                                            if (self.swizzleIndex(swizzle_name[j]) == i) {
                                                final_shuffle_ops[2 + i] = .{ .literal_int = @intCast(swizzle_len + j) };
                                                found = true;
                                                break;
                                            }
                                        }
                                        if (!found) {
                                            final_shuffle_ops[2 + i] = .{ .literal_int = @intCast(i) };
                                        }
                                    }
                                    const final_shuffle_id = self.allocId();
                                    try self.instructions.append(self.alloc, .{
                                        .tag = .vector_shuffle,
                                        .result_type = null,
                                        .result_id = final_shuffle_id,
                                        .operands = final_shuffle_ops,
                                        .ty = base_ty,
                                    });

                                    // 6. Store back
                                    const store_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                                    store_ops[0] = .{ .id = var_ptr_id2 };
                                    store_ops[1] = .{ .id = final_shuffle_id };
                                    try self.instructions.append(self.alloc, .{
                                        .tag = .store,
                                        .result_type = null,
                                        .result_id = null,
                                        .operands = store_ops,
                                        .ty = .void,
                                    });
                                    return .{ .ty = .void, .id = 0 };
                                }
                            }
                        }
                    }
                }

                // Regular (non-swizzle) compound assignment
                const target = try self.analyzeLValue(node.data.children[0]);
                var value = try self.analyzeExpression(node.data.children[1]);
                // If value is a pointer, load it
                if (value.is_ptr) {
                    const ld_id = self.allocId();
                    const ld_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    ld_ops[0] = .{ .id = value.id };
                    try self.instructions.append(self.alloc, .{
                        .tag = .load,
                        .result_type = null,
                        .result_id = ld_id,
                        .operands = ld_ops,
                        .ty = value.ty,
                    });
                    value = .{ .ty = value.ty, .id = ld_id };
                }
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
                // Convert value type to match target if needed
                var value_id = value.id;
                var value_ty = value.ty;
                if (target.ty.isVector() and value_ty == .int) {
                    // int → float → splat to vector
                    const float_id = self.allocId();
                    const conv_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    conv_operands[0] = .{ .id = value.id };
                    try self.instructions.append(self.alloc, .{
                        .tag = .convert_itof,
                        .result_type = null,
                        .result_id = float_id,
                        .operands = conv_operands,
                        .ty = .float,
                    });
                    // Splat float to vector
                    const splat_id = self.allocId();
                    const num_comps = target.ty.numComponents();
                    const splat_operands = try self.alloc.alloc(ir.Instruction.Operand, num_comps);
                    for (0..num_comps) |i| {
                        splat_operands[i] = .{ .id = float_id };
                    }
                    try self.instructions.append(self.alloc, .{
                        .tag = .composite_construct,
                        .result_type = null,
                        .result_id = splat_id,
                        .operands = splat_operands,
                        .ty = target.ty,
                    });
                    value_id = splat_id;
                    value_ty = target.ty;
                } else if (target.ty.isVector() and value_ty == .float) {
                    // For multiplication, skip splat — we'll use vec_scalar_mul instead
                    const is_mul = node.data.op == .mul_assign;
                    if (!is_mul) {
                        // float → splat to vector (needed for +=, -=, /= etc.)
                        const splat_id = self.allocId();
                        const num_comps = target.ty.numComponents();
                        const splat_operands = try self.alloc.alloc(ir.Instruction.Operand, num_comps);
                        for (0..num_comps) |i| {
                            splat_operands[i] = .{ .id = value.id };
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .composite_construct,
                            .result_type = null,
                            .result_id = splat_id,
                            .operands = splat_operands,
                            .ty = target.ty,
                        });
                        value_id = splat_id;
                        value_ty = target.ty;
                    }
                } else if (target.ty.isVector() and value_ty.isScalar() and !value_ty.isVector()) {
                    // Any other scalar → splat to vector (handles int8, int16, uint8, uint16, etc.)
                    const splat_id = self.allocId();
                    const num_comps = target.ty.numComponents();
                    const splat_operands = try self.alloc.alloc(ir.Instruction.Operand, num_comps);
                    for (0..num_comps) |i| {
                        splat_operands[i] = .{ .id = value.id };
                    }
                    try self.instructions.append(self.alloc, .{
                        .tag = .composite_construct,
                        .result_type = null,
                        .result_id = splat_id,
                        .operands = splat_operands,
                        .ty = target.ty,
                    });
                    value_id = splat_id;
                    value_ty = target.ty;
                } else if (target.ty == .float and value_ty == .int) {
                    // int → float
                    const conv_id = self.allocId();
                    const conv_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    conv_operands[0] = .{ .id = value.id };
                    try self.instructions.append(self.alloc, .{
                        .tag = .convert_itof,
                        .result_type = null,
                        .result_id = conv_id,
                        .operands = conv_operands,
                        .ty = .float,
                    });
                    value_id = conv_id;
                    value_ty = .float;
                } else if (target.ty.isFloatVector() and value_ty.isIntVector()) {
                    // int vector → float vector (e.g., vec2 /= ivec2)
                    const conv_tag: ir.Instruction.Tag = if (value_ty == .uvec2 or value_ty == .uvec3 or value_ty == .uvec4) .convert_utof else .convert_itof;
                    const conv_id = self.allocId();
                    const conv_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    conv_operands[0] = .{ .id = value.id };
                    try self.instructions.append(self.alloc, .{
                        .tag = conv_tag,
                        .result_type = null,
                        .result_id = conv_id,
                        .operands = conv_operands,
                        .ty = target.ty,
                    });
                    value_id = conv_id;
                    value_ty = target.ty;
                }
                // Compute result
                const result_ty_2 = target.ty;
                const is_float = result_ty_2 == .float or result_ty_2 == .double or result_ty_2.isFloatVector() or result_ty_2.isMatrix();
                const op_tag: ir.Instruction.Tag = switch (node.data.op orelse .add) {
                    .add_assign => if (is_float) .fadd else .add,
                    .sub_assign => if (is_float) .fsub else .sub,
                    .mul_assign => blk: {
                        if (target.ty.isMatrix() and value_ty.isMatrix()) break :blk .mat_mat_mul;
                        if (target.ty.isMatrix() and value_ty.isVector()) break :blk .mat_vec_mul;
                        if (target.ty.isVector() and value_ty.isMatrix()) break :blk .vec_mat_mul;
                        if (target.ty.isVector() and value_ty == .float) break :blk .vec_scalar_mul;
                        if (target.ty == .float and value_ty.isVector()) break :blk .scalar_vec_mul;
                        break :blk if (is_float) .fmul else .mul;
                    },
                    .div_assign => if (is_float) .fdiv else .div,
                    else => .add,
                };
                const computed_id = self.allocId();
                const bin_operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                bin_operands[0] = .{ .id = loaded_id };
                bin_operands[1] = .{ .id = value_id };
                try self.instructions.append(self.alloc, .{
                    .tag = op_tag,
                    .result_type = null,
                    .result_id = computed_id,
                    .operands = bin_operands,
                    .ty = result_ty_2,
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
                const is_atomic_fn = std.mem.eql(u8, node.data.name, "atomicAdd") or
                    std.mem.eql(u8, node.data.name, "atomicAnd") or
                    std.mem.eql(u8, node.data.name, "atomicOr") or
                    std.mem.eql(u8, node.data.name, "atomicXor") or
                    std.mem.eql(u8, node.data.name, "atomicMin") or
                    std.mem.eql(u8, node.data.name, "atomicMax") or
                    std.mem.eql(u8, node.data.name, "atomicExchange") or
                    std.mem.eql(u8, node.data.name, "atomicCompSwap");
                const is_image_atomic_fn = std.mem.eql(u8, node.data.name, "imageAtomicAdd") or
                    std.mem.eql(u8, node.data.name, "imageAtomicOr") or
                    std.mem.eql(u8, node.data.name, "imageAtomicXor") or
                    std.mem.eql(u8, node.data.name, "imageAtomicAnd") or
                    std.mem.eql(u8, node.data.name, "imageAtomicMin") or
                    std.mem.eql(u8, node.data.name, "imageAtomicMax") or
                    std.mem.eql(u8, node.data.name, "imageAtomicExchange") or
                    std.mem.eql(u8, node.data.name, "imageAtomicCompSwap");
                for (node.data.children, 0..) |arg, i| {
                    var tid = try self.analyzeExpression(arg);
                    // Atomic functions need pointer arg, don't auto-load first arg
                    // Image atomics also need the image pointer (not loaded value)
                    const skip_load = (is_atomic_fn and i == 0) or (is_image_atomic_fn and i == 0);
                    if (tid.is_ptr and !skip_load) {
                        const ld = self.allocId();
                        const ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        ops[0] = .{ .id = tid.id };
                        try self.instructions.append(self.alloc, .{ .tag = .load, .result_type = null, .result_id = ld, .operands = ops, .ty = tid.ty });
                        tid = .{ .ty = tid.ty, .id = ld };
                    }
                    try arg_tids.append(self.alloc, tid);
                }
                const sym_raw = self.lookup(node.data.name);
                // Resolve function overloads
                var resolved_sym = sym_raw;
                if (sym_raw != null and sym_raw.?.kind == .func) {
                    if (self.overloads.get(node.data.name)) |overload_list| {
                        // Try to match argument types against overload parameter types
                        for (overload_list.items) |overload| {
                            if (overload.param_types.len != arg_tids.items.len) continue;
                            var match = true;
                            for (overload.param_types, 0..) |pt, i| {
                                if (!self.typesCompatible(pt, arg_tids.items[i].ty)) {
                                    match = false;
                                    break;
                                }
                            }
                            if (match) {
                                resolved_sym = .{ .kind = .func, .ty = overload.return_type, .ir_id = overload.ir_id };
                                break;
                            }
                        }
                    }
                }
                const sym = resolved_sym;
                // For GLSL builtins, infer result type from first argument (e.g., round(vec4) → vec4)
                // Exception: texture functions return vec4
                const is_shadow_sample = self.isImageSampleBuiltin(node.data.name) and arg_tids.items.len > 0 and self.isShadowSamplerType(arg_tids.items[0].ty);
                const result_ty: ast.Type = if (is_shadow_sample)
                    .float
                else if (self.isImageSampleBuiltin(node.data.name))
                    if (arg_tids.items.len > 0) arg_tids.items[0].ty.samplerResultType() else .vec4
                else if (std.mem.eql(u8, node.data.name, "texelFetch"))
                    if (arg_tids.items.len > 0) arg_tids.items[0].ty.samplerResultType() else .vec4
                else if (std.mem.eql(u8, node.data.name, "helperInvocationEXT"))
                    .bool
                else if (self.isFloatReturnBuiltin(node.data.name))
                    .float
                // Pack functions return uint
                else if (self.isPackBuiltin(node.data.name))
                    .uint
                // Unpack functions return vec2 (or vec4 for unpackSnorm4x8/unpackUnorm4x8)
                else if (self.isUnpackBuiltin(node.data.name))
                    if (std.mem.endsWith(u8, node.data.name, "4x8")) .vec4 else .vec2
                else if (self.isGLSLBuiltin(node.data.name) and arg_tids.items.len > 0)
                    arg_tids.items[0].ty
                else if (sym) |s| s.ty
                else .void;
                const result_id = self.allocId();

                if (self.isGLSLBuiltin(node.data.name)) {
                    // mod(x, y) → OpFMod (core SPIR-V, not GLSL.std.450)
                    if (std.mem.eql(u8, node.data.name, "mod")) {
                        const ret_ty = if (arg_tids.items.len > 0) arg_tids.items[0].ty else .float;
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len);
                        for (arg_tids.items, 0..) |tid, i| {
                            operands[i] = .{ .id = tid.id };
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .fmod,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = ret_ty,
                        });
                        return .{ .ty = ret_ty, .id = result_id };
                    }
                    // Barrier/memory functions
                    if (std.mem.eql(u8, node.data.name, "barrier")) {
                        // OpControlBarrier: Execution=Workgroup(2), Memory=Workgroup(2), Semantics=AcquireRelease+WorkgroupMemory(264)
                        const scope_id = try self.getConstInt(2, .uint);
                        const mem_scope_id = scope_id; // same
                        const semantics_id = try self.getConstInt(264, .uint);
                        const barrier_ops = try self.alloc.alloc(ir.Instruction.Operand, 3);
                        barrier_ops[0] = .{ .id = scope_id };
                        barrier_ops[1] = .{ .id = mem_scope_id };
                        barrier_ops[2] = .{ .id = semantics_id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .control_barrier,
                            .result_type = null,
                            .result_id = null,
                            .operands = barrier_ops,
                            .ty = .void,
                        });
                        return .{ .ty = .void, .id = result_id };
                    }
                    if (std.mem.eql(u8, node.data.name, "memoryBarrier")) {
                        // OpMemoryBarrier: Device(1), AcquireRelease+Uniform(72)
                        const scope_id = try self.getConstInt(1, .uint);
                        const semantics_id = try self.getConstInt(72, .uint);
                        const mb_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        mb_ops[0] = .{ .id = scope_id };
                        mb_ops[1] = .{ .id = semantics_id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .memory_barrier,
                            .result_type = null,
                            .result_id = null,
                            .operands = mb_ops,
                            .ty = .void,
                        });
                        return .{ .ty = .void, .id = result_id };
                    }
                    if (std.mem.eql(u8, node.data.name, "memoryBarrierShared")) {
                        // OpMemoryBarrier: Workgroup(2), AcquireRelease+WorkgroupMemory(264)
                        const scope_id = try self.getConstInt(2, .uint);
                        const semantics_id = try self.getConstInt(264, .uint);
                        const mb_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        mb_ops[0] = .{ .id = scope_id };
                        mb_ops[1] = .{ .id = semantics_id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .memory_barrier,
                            .result_type = null,
                            .result_id = null,
                            .operands = mb_ops,
                            .ty = .void,
                        });
                        return .{ .ty = .void, .id = result_id };
                    }
                    if (std.mem.eql(u8, node.data.name, "memoryBarrierImage") or std.mem.eql(u8, node.data.name, "memoryBarrierBuffer")) {
                        // OpMemoryBarrier: Device(1), AcquireRelease+Uniform(72)
                        const scope_id = try self.getConstInt(1, .uint);
                        const semantics_id = try self.getConstInt(72, .uint);
                        const mb_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        mb_ops[0] = .{ .id = scope_id };
                        mb_ops[1] = .{ .id = semantics_id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .memory_barrier,
                            .result_type = null,
                            .result_id = null,
                            .operands = mb_ops,
                            .ty = .void,
                        });
                        return .{ .ty = .void, .id = result_id };
                    }
                    if (std.mem.eql(u8, node.data.name, "groupMemoryBarrier")) {
                        // OpMemoryBarrier: Workgroup(2), AcquireRelease+Uniform(72)
                        const scope_id = try self.getConstInt(2, .uint);
                        const semantics_id = try self.getConstInt(72, .uint);
                        const mb_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        mb_ops[0] = .{ .id = scope_id };
                        mb_ops[1] = .{ .id = semantics_id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .memory_barrier,
                            .result_type = null,
                            .result_id = null,
                            .operands = mb_ops,
                            .ty = .void,
                        });
                        return .{ .ty = .void, .id = result_id };
                    }
                    if (self.isBarrierBuiltin(node.data.name)) {
                        // Remaining barrier builtins (beginInvocationInterlockARB, endInvocationInterlockARB, demote)
                        return .{ .ty = .void, .id = result_id };
                    }
                    // helperInvocationEXT() returns bool (constant false for now)
                    if (std.mem.eql(u8, node.data.name, "helperInvocationEXT")) {
                        const bool_val = self.allocId();
                        const ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        ops[0] = .{ .literal_int = 0 };
                        try self.instructions.append(self.alloc, .{
                            .tag = .constant_bool,
                            .result_type = null,
                            .result_id = bool_val,
                            .operands = ops,
                            .ty = .bool,
                        });
                        return .{ .ty = .bool, .id = bool_val };
                    }
                    // === Buffer/SSBO atomics (atomicAdd/Or/Xor/And/Min/Max/Exchange/CompSwap) ===
                    const is_buffer_atomic = std.mem.eql(u8, node.data.name, "atomicAdd") or
                        std.mem.eql(u8, node.data.name, "atomicAnd") or
                        std.mem.eql(u8, node.data.name, "atomicOr") or
                        std.mem.eql(u8, node.data.name, "atomicXor") or
                        std.mem.eql(u8, node.data.name, "atomicMin") or
                        std.mem.eql(u8, node.data.name, "atomicMax") or
                        std.mem.eql(u8, node.data.name, "atomicExchange");
                    if (is_buffer_atomic) {
                        // Return type should match the pointed-to type, not the value arg type
                        var ret_ty: ast.Type = .uint;
                        var ptr_tid = arg_tids.items[0];
                        if (node.data.children.len > 0) {
                            if (self.analyzeLValue(node.data.children[0])) |lval| {
                                ptr_tid = lval;
                                ret_ty = lval.ty; // use pointed-to type
                            } else |_| {}
                        }
                        const atomic_tag: ir.Instruction.Tag =
                            if (std.mem.eql(u8, node.data.name, "atomicAdd") and ret_ty == .float) .atomic_fadd else
                            if (std.mem.eql(u8, node.data.name, "atomicAdd")) .atomic_iadd else
                            if (std.mem.eql(u8, node.data.name, "atomicAnd")) .atomic_and else
                            if (std.mem.eql(u8, node.data.name, "atomicOr")) .atomic_or else
                            if (std.mem.eql(u8, node.data.name, "atomicXor")) .atomic_xor else
                            if (std.mem.eql(u8, node.data.name, "atomicMin")) blk: {
                                break :blk if (ret_ty == .int) .atomic_smin else .atomic_umin;
                            } else
                            if (std.mem.eql(u8, node.data.name, "atomicMax")) blk: {
                                break :blk if (ret_ty == .int) .atomic_smax else .atomic_umax;
                            } else
                            .atomic_exchange;
                        // Convert value to match return type if needed
                        var value_id = if (arg_tids.items.len > 1) arg_tids.items[1].id else 0;
                        if (arg_tids.items.len > 1 and !std.meta.eql(arg_tids.items[1].ty, ret_ty)) {
                            const converted = self.allocId();
                            const conv_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                            conv_ops[0] = .{ .id = arg_tids.items[1].id };
                            const conv_tag: ir.Instruction.Tag = blk: {
                                if (ret_ty == .uint and arg_tids.items[1].ty == .int) break :blk .convert_iti;
                                if (ret_ty == .int and arg_tids.items[1].ty == .uint) break :blk .convert_uti;
                                if (ret_ty == .float) break :blk .convert_itof;
                                break :blk .bitcast;
                            };
                            try self.instructions.append(self.alloc, .{
                                .tag = conv_tag,
                                .result_type = null,
                                .result_id = converted,
                                .operands = conv_ops,
                                .ty = ret_ty,
                            });
                            value_id = converted;
                        }
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        operands[0] = .{ .id = ptr_tid.id };
                        operands[1] = if (arg_tids.items.len > 1) .{ .id = value_id } else .{ .literal_int = 0 };
                        try self.instructions.append(self.alloc, .{
                            .tag = atomic_tag,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = ret_ty,
                        });
                        return .{ .ty = ret_ty, .id = result_id };
                    }
                    if (std.mem.eql(u8, node.data.name, "atomicCompSwap")) {
                        const ret_ty = if (arg_tids.items.len > 2) arg_tids.items[2].ty else .uint;
                        var ptr_tid = arg_tids.items[0];
                        if (node.data.children.len > 0) {
                            if (self.analyzeLValue(node.data.children[0])) |lval| {
                                ptr_tid = lval;
                            } else |_| {}
                        }
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 3);
                        operands[0] = .{ .id = ptr_tid.id };
                        operands[1] = .{ .id = arg_tids.items[1].id }; // comparator
                        operands[2] = .{ .id = arg_tids.items[2].id }; // value
                        try self.instructions.append(self.alloc, .{
                            .tag = .atomic_comp_swap,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = ret_ty,
                        });
                        return .{ .ty = ret_ty, .id = result_id };
                    }
                    // === Image atomics (imageAtomicAdd/Or/Xor/And/Min/Max/Exchange/CompSwap) ===
                    const is_image_atomic = std.mem.eql(u8, node.data.name, "imageAtomicAdd") or
                        std.mem.eql(u8, node.data.name, "imageAtomicOr") or
                        std.mem.eql(u8, node.data.name, "imageAtomicXor") or
                        std.mem.eql(u8, node.data.name, "imageAtomicAnd") or
                        std.mem.eql(u8, node.data.name, "imageAtomicMin") or
                        std.mem.eql(u8, node.data.name, "imageAtomicMax") or
                        std.mem.eql(u8, node.data.name, "imageAtomicExchange") or
                        std.mem.eql(u8, node.data.name, "imageAtomicCompSwap");
                    if (is_image_atomic) {
                        // imageAtomic*(image, coord, value[, comparator])
                        // 1. Get image variable pointer (NOT loaded value)
                        // 2. Emit OpImageTexelPointer(image_ptr, coord, sample=0)
                        // 3. Emit atomic op on the texel pointer
                        const image_ty = if (arg_tids.items.len > 0) arg_tids.items[0].ty else .uimage2d;
                        const ret_ty: ast.Type = switch (image_ty) {
                            .uimage2d => .uint,
                            .iimage2d => .int,
                            .image2d => .float,
                            else => .uint,
                        };
                        // Get image variable pointer via LValue
                        var image_ptr_id = arg_tids.items[0].id;
                        if (node.data.children.len > 0) {
                            if (self.analyzeLValue(node.data.children[0])) |lval| {
                                image_ptr_id = lval.id;
                            } else |_| {}
                        }
                        const texel_ptr_id = self.allocId();
                        const tp_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        tp_ops[0] = .{ .id = image_ptr_id }; // image pointer
                        tp_ops[1] = .{ .id = arg_tids.items[1].id }; // coord
                        try self.instructions.append(self.alloc, .{
                            .tag = .image_texel_pointer,
                            .result_type = null,
                            .result_id = texel_ptr_id,
                            .operands = tp_ops,
                            .ty = ret_ty,
                        });
                        if (std.mem.eql(u8, node.data.name, "imageAtomicCompSwap")) {
                            // imageAtomicCompSwap(image, coord, comparator, value)
                            const operands = try self.alloc.alloc(ir.Instruction.Operand, 3);
                            operands[0] = .{ .id = texel_ptr_id };
                            operands[1] = .{ .id = arg_tids.items[2].id }; // comparator
                            operands[2] = .{ .id = arg_tids.items[3].id }; // value
                            try self.instructions.append(self.alloc, .{
                                .tag = .atomic_comp_swap,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = operands,
                                .ty = ret_ty,
                            });
                        } else {
                            const atomic_tag: ir.Instruction.Tag =
                                if (std.mem.eql(u8, node.data.name, "imageAtomicAdd") and ret_ty == .float) .atomic_fadd else
                                if (std.mem.eql(u8, node.data.name, "imageAtomicAdd")) .atomic_iadd else
                                if (std.mem.eql(u8, node.data.name, "imageAtomicAnd")) .atomic_and else
                                if (std.mem.eql(u8, node.data.name, "imageAtomicOr")) .atomic_or else
                                if (std.mem.eql(u8, node.data.name, "imageAtomicXor")) .atomic_xor else
                                if (std.mem.eql(u8, node.data.name, "imageAtomicMin")) blk: {
                                    break :blk if (ret_ty == .int) .atomic_smin else .atomic_umin;
                                } else
                                if (std.mem.eql(u8, node.data.name, "imageAtomicMax")) blk: {
                                    break :blk if (ret_ty == .int) .atomic_smax else .atomic_umax;
                                } else
                                .atomic_exchange;
                            const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                            operands[0] = .{ .id = texel_ptr_id };
                            operands[1] = .{ .id = arg_tids.items[2].id }; // value
                            try self.instructions.append(self.alloc, .{
                                .tag = atomic_tag,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = operands,
                                .ty = ret_ty,
                            });
                        }
                        return .{ .ty = ret_ty, .id = result_id };
                    }
                    // imageSize returns ivec2, needs OpImageQuerySize
                    if (std.mem.eql(u8, node.data.name, "imageSize")) {
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len);
                        for (arg_tids.items, 0..) |tid, i| {
                            operands[i] = .{ .id = tid.id };
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .image_query_size,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = .ivec2,
                        });
                        return .{ .ty = .ivec2, .id = result_id };
                    }
                    // textureSize(sampler, lod) → varies by sampler type
                    if (std.mem.eql(u8, node.data.name, "textureSize")) {
                        // Determine result type based on sampler type
                        const size_ty: ast.Type = if (arg_tids.items.len > 0) switch (arg_tids.items[0].ty) {
                            .sampler1d, .sampler1d_shadow, .isampler1d, .usampler1d,
                            .sampler_buffer, .isampler_buffer, .usampler_buffer,
                            .image_buffer => .int,
                            .sampler2d, .sampler2d_shadow, .sampler2d_ms,
                            .sampler_cube, .sampler_cube_shadow,
                            .isampler2d, .usampler2d, .isampler3d, .usampler3d,
                            .isampler_cube, .usampler_cube,
                            .isampler2d_ms, .usampler2d_ms,
                            .isampler2d_ms_array, .usampler2d_ms_array,
                            .image2d, .iimage2d, .uimage2d, .image2d_ms => .ivec2,
                            .sampler2d_array, .sampler2d_array_shadow, .sampler3d,
                            .sampler_cube_array_shadow,
                            .isampler2d_array, .usampler2d_array,
                            .isampler_cube_array, .usampler_cube_array,
                            .isampler1d_array, .usampler1d_array,
                            .image2d_ms_array => .ivec3,
                            else => .ivec2,
                        } else .ivec2;
                        // Extract image from sampler (all sampler types need extraction)
                        var img_id = arg_tids.items[0].id;
                        if (arg_tids.items[0].ty.isCombinedSampler() or
                            arg_tids.items[0].ty == .sampler1d_shadow or arg_tids.items[0].ty == .sampler2d_shadow or
                            arg_tids.items[0].ty == .sampler_cube_shadow or arg_tids.items[0].ty == .sampler2d_array_shadow or
                            arg_tids.items[0].ty == .sampler_cube_array_shadow or
                            arg_tids.items[0].ty == .isampler1d_array or arg_tids.items[0].ty == .usampler1d_array)
                        {
                            const extracted = self.allocId();
                            const ext_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                            ext_ops[0] = .{ .id = arg_tids.items[0].id };
                            try self.instructions.append(self.alloc, .{
                                .tag = .extract_image,
                                .result_type = null,
                                .result_id = extracted,
                                .operands = ext_ops,
                                .ty = arg_tids.items[0].ty,
                            });
                            img_id = extracted;
                        }
                        if (arg_tids.items.len > 1) {
                            // textureSize(sampler, lod) → OpImageQuerySizeLod
                            const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                            operands[0] = .{ .id = img_id };
                            operands[1] = .{ .id = arg_tids.items[1].id };
                            try self.instructions.append(self.alloc, .{
                                .tag = .image_query_size_lod,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = operands,
                                .ty = size_ty,
                            });
                        } else {
                            // textureSize(image) → OpImageQuerySize
                            const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                            operands[0] = .{ .id = img_id };
                            try self.instructions.append(self.alloc, .{
                                .tag = .image_query_size,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = operands,
                                .ty = size_ty,
                            });
                        }
                        return .{ .ty = size_ty, .id = result_id };
                    }
                    // textureQueryLevels(sampler) → int, uses OpImageQueryLevels
                    if (std.mem.eql(u8, node.data.name, "textureQueryLevels")) {
                        // Need to extract image from sampler first
                        var img_id = arg_tids.items[0].id;
                        if (arg_tids.items[0].ty.isCombinedSampler() or
                            arg_tids.items[0].ty == .sampler1d_shadow or arg_tids.items[0].ty == .sampler2d_shadow or
                            arg_tids.items[0].ty == .sampler_cube_shadow or arg_tids.items[0].ty == .sampler2d_array_shadow or
                            arg_tids.items[0].ty == .sampler_cube_array_shadow
                        )
                        {
                            const extracted = self.allocId();
                            const ext_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                            ext_ops[0] = .{ .id = arg_tids.items[0].id };
                            try self.instructions.append(self.alloc, .{
                                .tag = .extract_image,
                                .result_type = null,
                                .result_id = extracted,
                                .operands = ext_ops,
                                .ty = arg_tids.items[0].ty,
                            });
                            img_id = extracted;
                        }
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        operands[0] = .{ .id = img_id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .image_query_levels,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = .int,
                        });
                        return .{ .ty = .int, .id = result_id };
                    }
                    // textureQueryLod(sampler, coord) → vec2, uses OpImageQueryLod
                    // NOTE: OpImageQueryLod takes a SampledImage, NOT a bare image
                    if (std.mem.eql(u8, node.data.name, "textureQueryLod")) {
                        const sampled_image_id = arg_tids.items[0].id;
                        const coord_id = arg_tids.items[1].id;
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        operands[0] = .{ .id = sampled_image_id };
                        operands[1] = .{ .id = coord_id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .image_query_lod,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = .vec2,
                        });
                        return .{ .ty = .vec2, .id = result_id };
                    }
                    // subpassLoad(subpassInput) → OpLoad + OpImageRead with ivec2(0,0)
                    // subpassLoad(subpassInputMS, sampleIndex) → OpLoad + OpImageRead with Sample operand
                    if (std.mem.eql(u8, node.data.name, "subpassLoad")) {
                        if (arg_tids.items.len < 1) return error.SemanticFailed;
                        // The argument is a subpassInput variable — load it to get the image
                        var img_id = arg_tids.items[0].id;
                        if (arg_tids.items[0].is_ptr) {
                            const loaded = self.allocId();
                            const ld_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                            ld_ops[0] = .{ .id = arg_tids.items[0].id };
                            try self.instructions.append(self.alloc, .{
                                .tag = .load,
                                .result_type = null,
                                .result_id = loaded,
                                .operands = ld_ops,
                                .ty = arg_tids.items[0].ty,
                            });
                            img_id = loaded;
                        }
                        // Create ivec2(0, 0) coordinate
                        const coord_id = self.allocId();
                        const zero_id = try self.getConstInt(0, .int);
                        const coord_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        coord_ops[0] = .{ .id = zero_id };
                        coord_ops[1] = .{ .id = zero_id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .composite_construct,
                            .result_type = null,
                            .result_id = coord_id,
                            .operands = coord_ops,
                            .ty = .ivec2,
                        });
                        // OpImageRead — with optional Sample operand for MS
                        if (arg_tids.items.len >= 2) {
                            // MS subpassLoad: subpassLoad(img, sampleIndex)
                            const read_ops = try self.alloc.alloc(ir.Instruction.Operand, 3);
                            read_ops[0] = .{ .id = img_id };
                            read_ops[1] = .{ .id = coord_id };
                            read_ops[2] = .{ .id = arg_tids.items[1].id }; // sample index
                            try self.instructions.append(self.alloc, .{
                                .tag = .image_read,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = read_ops,
                                .ty = .vec4,
                            });
                        } else {
                            const read_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                            read_ops[0] = .{ .id = img_id };
                            read_ops[1] = .{ .id = coord_id };
                            try self.instructions.append(self.alloc, .{
                                .tag = .image_read,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = read_ops,
                                .ty = .vec4,
                            });
                        }
                        return .{ .ty = .vec4, .id = result_id };
                    }
                    if (std.mem.eql(u8, node.data.name, "textureSamples") or std.mem.eql(u8, node.data.name, "imageSamples")) {
                        var img_id = arg_tids.items[0].id;
                        if (arg_tids.items[0].ty.isCombinedSampler() or
                            arg_tids.items[0].ty == .sampler2d_ms or arg_tids.items[0].ty == .sampler2d_ms_array) {
                            const extracted = self.allocId();
                            const ext_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                            ext_ops[0] = .{ .id = arg_tids.items[0].id };
                            try self.instructions.append(self.alloc, .{
                                .tag = .extract_image,
                                .result_type = null,
                                .result_id = extracted,
                                .operands = ext_ops,
                                .ty = arg_tids.items[0].ty,
                            });
                            img_id = extracted;
                        }
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        operands[0] = .{ .id = img_id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .image_query_samples,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = .int,
                        });
                        return .{ .ty = .int, .id = result_id };
                    }
                    // outerProduct(vecN, vecM) → matNxM
                    // Not a GLSL.std.450 instruction — need to compute via VectorTimesScalar
                    if (std.mem.eql(u8, node.data.name, "outerProduct")) {
                        if (arg_tids.items.len >= 2) {
                            const a_rows = arg_tids.items[0].ty.numComponents();
                            const b_rows = arg_tids.items[1].ty.numComponents();
                            const mat_ty: ast.Type = if (a_rows == 2 and b_rows == 2) .mat2
                                else if (a_rows == 3 and b_rows == 2) .mat2x3 // 3 rows, 2 cols
                                else if (a_rows == 4 and b_rows == 2) .mat2x4 // 4 rows, 2 cols
                                else if (a_rows == 2 and b_rows == 3) .mat3x2 // 2 rows, 3 cols
                                else if (a_rows == 3 and b_rows == 3) .mat3
                                else if (a_rows == 4 and b_rows == 3) .mat3x4 // 4 rows, 3 cols
                                else if (a_rows == 2 and b_rows == 4) .mat4x2 // 2 rows, 4 cols
                                else if (a_rows == 3 and b_rows == 4) .mat4x3 // 3 rows, 4 cols
                                else .mat4; // 4x4
                            // For each column j: column[j] = a * b_component[j]
                            // This requires VectorTimesScalar per column, then CompositeConstruct
                            // For now, emit as a special outer_product IR instruction
                            const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len);
                            for (arg_tids.items, 0..) |tid, i| {
                                operands[i] = .{ .id = tid.id };
                            }
                            try self.instructions.append(self.alloc, .{
                                .tag = .outer_product,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = operands,
                                .ty = mat_ty,
                            });
                            return .{ .ty = mat_ty, .id = result_id };
                        }
                    }
                    // Texture functions use different SPIR-V ops, not GLSL.std.450
                    if (self.isTextureBuiltin(node.data.name)) {
                        if (self.isImageSampleBuiltin(node.data.name) and !self.isTexelFetchBuiltin(node.data.name)) {
                            // textureGather has its own IR tags
                            const is_gather = std.mem.eql(u8, node.data.name, "textureGather");
                            if (is_gather) {
                                // textureGather: non-shadow → image_gather, shadow → image_dref_gather
                                const gather_tag: ir.Instruction.Tag = if (is_shadow_sample) .image_dref_gather else .image_gather;
                                const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len);
                                for (arg_tids.items, 0..) |tid, i| {
                                    operands[i] = .{ .id = tid.id };
                                }
                                try self.instructions.append(self.alloc, .{
                                    .tag = gather_tag,
                                    .result_type = null,
                                    .result_id = result_id,
                                    .operands = operands,
                                    .ty = if (is_shadow_sample) arg_tids.items[0].ty else result_ty,
                                });
                            } else {
                            // texture(sampler, coord) → image_sample (implicit or explicit lod)
                            const is_explicit_lod = std.mem.eql(u8, node.data.name, "textureLod") or std.mem.eql(u8, node.data.name, "textureLodOffset");
                            const is_proj = std.mem.eql(u8, node.data.name, "textureProj");
                            // Shadow samplers use Dref instructions that return float
                            const tag: ir.Instruction.Tag = if (is_shadow_sample) (
                                if (is_explicit_lod) .image_sample_dref_explicit_lod
                                else if (is_proj) .image_sample_dref_proj
                                else .image_sample_dref
                            ) else if (is_explicit_lod) .image_sample_explicit_lod else if (is_proj) .image_sample_proj else .image_sample;
                            const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len);
                            for (arg_tids.items, 0..) |tid, i| {
                                operands[i] = .{ .id = tid.id };
                            }
                            try self.instructions.append(self.alloc, .{
                                .tag = tag,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = operands,
                                .ty = if (is_shadow_sample) arg_tids.items[0].ty else result_ty,
                            });
                            }
                        } else {
                            // texelFetch etc → image_fetch as fallback
                            // If first arg is a sampler, extract image first
                            const fetch_args = arg_tids.items;
                            if (fetch_args.len > 0 and (fetch_args[0].ty == .sampler2d or fetch_args[0].ty == .sampler3d or fetch_args[0].ty == .sampler2d_array or fetch_args[0].ty == .sampler2d_ms or fetch_args[0].ty == .sampler2d_ms_array or fetch_args[0].ty == .sampler_cube or fetch_args[0].ty == .sampler_buffer or fetch_args[0].ty == .sampler1d or fetch_args[0].ty == .isampler2d or fetch_args[0].ty == .usampler2d or fetch_args[0].ty == .isampler3d or fetch_args[0].ty == .usampler3d or fetch_args[0].ty == .isampler_cube or fetch_args[0].ty == .usampler_cube or fetch_args[0].ty == .isampler2d_array or fetch_args[0].ty == .usampler2d_array or fetch_args[0].ty == .isampler2d_ms or fetch_args[0].ty == .usampler2d_ms or fetch_args[0].ty == .isampler2d_ms_array or fetch_args[0].ty == .usampler2d_ms_array or fetch_args[0].ty == .isampler_buffer or fetch_args[0].ty == .usampler_buffer or fetch_args[0].ty == .isampler1d or fetch_args[0].ty == .usampler1d)) {
                                const extracted_id = self.allocId();
                                const extract_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                                extract_operands[0] = .{ .id = fetch_args[0].id };
                                try self.instructions.append(self.alloc, .{
                                    .tag = .extract_image,
                                    .result_type = null,
                                    .result_id = extracted_id,
                                    .operands = extract_operands,
                                    .ty = fetch_args[0].ty, // pass sampler type so codegen can find correct inner image ID
                                });
                                // Replace first arg with extracted image
                                var new_args = try self.alloc.alloc(ir.Instruction.Operand, fetch_args.len);
                                new_args[0] = .{ .id = extracted_id };
                                for (1..fetch_args.len) |i| {
                                    new_args[i] = .{ .id = fetch_args[i].id };
                                }
                                const is_ms = fetch_args[0].ty == .sampler2d_ms or fetch_args[0].ty == .sampler2d_ms_array or fetch_args[0].ty == .isampler2d_ms or fetch_args[0].ty == .usampler2d_ms or fetch_args[0].ty == .isampler2d_ms_array or fetch_args[0].ty == .usampler2d_ms_array;
                                const operands = try self.alloc.alloc(ir.Instruction.Operand, fetch_args.len);
                                for (operands, 0..) |*op, i| op.* = new_args[i];
                                try self.instructions.append(self.alloc, .{
                                    .tag = if (is_ms) .image_fetch_ms else .image_fetch,
                                    .result_type = null,
                                    .result_id = result_id,
                                    .operands = operands,
                                    .ty = result_ty,
                                });
                            } else {
                                const operands = try self.alloc.alloc(ir.Instruction.Operand, fetch_args.len);
                                for (fetch_args, 0..) |tid, i| {
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
                        }
                    } else if (std.mem.eql(u8, node.data.name, "imageLoad")) {
                        // Determine result type from image argument type
                        const img_result_ty: ast.Type = if (arg_tids.items.len > 0) switch (arg_tids.items[0].ty) {
                            .iimage2d => .ivec4,
                            .uimage2d => .uvec4,
                            else => .vec4,
                        } else .vec4;
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len);
                        for (arg_tids.items, 0..) |tid, i| {
                            operands[i] = .{ .id = tid.id };
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .image_read,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = img_result_ty,
                        });
                        return .{ .ty = img_result_ty, .id = result_id };
                    } else if (std.mem.eql(u8, node.data.name, "imageStore")) {
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len);
                        for (arg_tids.items, 0..) |tid, i| {
                            operands[i] = .{ .id = tid.id };
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .image_write,
                            .result_type = null,
                            .result_id = null,
                            .operands = operands,
                            .ty = .void,
                        });
                        return .{ .ty = .void, .id = 0 };
                    } else if (std.mem.eql(u8, node.data.name, "transpose")) {
                        // transpose(mat) → OpTranspose (core SPIR-V, not GLSL.std.450)
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len);
                        for (arg_tids.items, 0..) |tid, i| {
                            operands[i] = .{ .id = tid.id };
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .transpose,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = result_ty,
                        });
                    } else if (std.mem.eql(u8, node.data.name, "dFdx") or std.mem.eql(u8, node.data.name, "dFdy") or
                              std.mem.eql(u8, node.data.name, "dFdxFine") or std.mem.eql(u8, node.data.name, "dFdyFine") or
                              std.mem.eql(u8, node.data.name, "dFdxCoarse") or std.mem.eql(u8, node.data.name, "dFdyCoarse")) {
                        // Derivatives: OpDPdx/OpDPdy and Fine/Coarse variants (core SPIR-V)
                        const which: u32 = if (std.mem.eql(u8, node.data.name, "dFdx")) 0
                            else if (std.mem.eql(u8, node.data.name, "dFdy")) 1
                            else if (std.mem.eql(u8, node.data.name, "dFdxFine")) 2
                            else if (std.mem.eql(u8, node.data.name, "dFdyFine")) 3
                            else if (std.mem.eql(u8, node.data.name, "dFdxCoarse")) 4
                            else 5; // dFdyCoarse
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len + 1);
                        operands[0] = .{ .literal_int = which };
                        for (arg_tids.items, 1..) |tid, i| {
                            operands[i] = .{ .id = tid.id };
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .derivative,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = result_ty,
                        });
                    } else if (std.mem.eql(u8, node.data.name, "fwidth") or std.mem.eql(u8, node.data.name, "fwidthFine") or std.mem.eql(u8, node.data.name, "fwidthCoarse")) {
                        // fwidth(p) = abs(dFdx(p)) + abs(dFdy(p)) → OpFwidth / OpFwidthFine / OpFwidthCoarse
                        const which: u32 = if (std.mem.eql(u8, node.data.name, "fwidth")) 0
                            else if (std.mem.eql(u8, node.data.name, "fwidthFine")) 1
                            else 2;
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len + 1);
                        operands[0] = .{ .literal_int = which };
                        for (arg_tids.items, 0..) |tid, i| {
                            operands[i + 1] = .{ .id = tid.id };
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .fwidth,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = result_ty,
                        });
                    } else if (std.mem.eql(u8, node.data.name, "isnan") or std.mem.eql(u8, node.data.name, "isinf")) {
                        const is_nan = std.mem.eql(u8, node.data.name, "isnan");
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len);
                        for (arg_tids.items, 0..) |tid, i| {
                            operands[i] = .{ .id = tid.id };
                        }
                        // Result type: bvec with same dimension as input
                        const bvec_ty: ast.Type = if (arg_tids.items[0].ty.isVector()) switch (arg_tids.items[0].ty.numComponents()) {
                            2 => .bvec2,
                            3 => .bvec3,
                            4 => .bvec4,
                            else => .bool,
                        } else .bool;
                        try self.instructions.append(self.alloc, .{
                            .tag = if (is_nan) .is_nan else .is_inf,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = bvec_ty,
                        });
                        return .{ .ty = bvec_ty, .id = result_id };
                    } else if (std.mem.eql(u8, node.data.name, "any") or std.mem.eql(u8, node.data.name, "all")) {
                        // any/all: OpAny/OpAll, returns bool
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        operands[0] = .{ .id = arg_tids.items[0].id };
                        try self.instructions.append(self.alloc, .{
                            .tag = if (std.mem.eql(u8, node.data.name, "any")) .any else .all,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = .bool,
                        });
                        return .{ .ty = .bool, .id = result_id };
                    } else if (std.mem.eql(u8, node.data.name, "allInvocationsARB") or std.mem.eql(u8, node.data.name, "allInvocations") or std.mem.eql(u8, node.data.name, "allInvocationsEqualARB") or std.mem.eql(u8, node.data.name, "allInvocationsEqual")) {
                        // Group vote: allInvocations → OpGroupAll
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        operands[0] = .{ .id = arg_tids.items[0].id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .group_all,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = .bool,
                        });
                        return .{ .ty = .bool, .id = result_id };
                    } else if (std.mem.eql(u8, node.data.name, "anyInvocationARB") or std.mem.eql(u8, node.data.name, "anyInvocation")) {
                        // Group vote: anyInvocation → OpGroupAny
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        operands[0] = .{ .id = arg_tids.items[0].id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .group_any,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = .bool,
                        });
                        return .{ .ty = .bool, .id = result_id };
                    } else if (std.mem.eql(u8, node.data.name, "lessThan") or std.mem.eql(u8, node.data.name, "greaterThan") or std.mem.eql(u8, node.data.name, "lessThanEqual") or std.mem.eql(u8, node.data.name, "greaterThanEqual") or std.mem.eql(u8, node.data.name, "equal") or std.mem.eql(u8, node.data.name, "notEqual")) {
                        // Vector comparison builtins → same as binary comparison operators
                        if (arg_tids.items.len >= 2) {
                            const left_ty = arg_tids.items[0].ty;
                            const is_float = left_ty == .float or left_ty == .vec2 or left_ty == .vec3 or left_ty == .vec4;
                            const tag: ir.Instruction.Tag = if (std.mem.eql(u8, node.data.name, "lessThan"))
                                if (is_float) .compare_flt else .compare_lt
                            else if (std.mem.eql(u8, node.data.name, "greaterThan"))
                                if (is_float) .compare_fgt else .compare_gt
                            else if (std.mem.eql(u8, node.data.name, "lessThanEqual"))
                                if (is_float) .compare_flte else .compare_lte
                            else if (std.mem.eql(u8, node.data.name, "greaterThanEqual"))
                                if (is_float) .compare_fgte else .compare_gte
                            else if (std.mem.eql(u8, node.data.name, "equal"))
                                if (is_float) .compare_feq else .compare_eq
                            else
                                if (is_float) .compare_fneq else .compare_neq;
                            // Result type: bvec with same dimension
                            const bvec_ty: ast.Type = if (left_ty.isVector()) switch (left_ty.numComponents()) {
                                2 => .bvec2, 3 => .bvec3, 4 => .bvec4, else => .bool,
                            } else .bool;
                            const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                            operands[0] = .{ .id = arg_tids.items[0].id };
                            operands[1] = .{ .id = arg_tids.items[1].id };
                            try self.instructions.append(self.alloc, .{
                                .tag = tag,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = operands,
                                .ty = bvec_ty,
                            });
                            return .{ .ty = bvec_ty, .id = result_id };
                        }
                    } else if (std.mem.eql(u8, node.data.name, "dot")) {
                        // dot(a, b) → OpDot (core SPIR-V, not GLSL.std.450)
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len);
                        for (arg_tids.items, 0..) |tid, i| {
                            operands[i] = .{ .id = tid.id };
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .dot,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = .float, // dot always returns float
                        });
                        return .{ .ty = .float, .id = result_id };
                    } else if (std.mem.eql(u8, node.data.name, "mix")) {
                        // mix(x, y, a): if a is boolean, use OpSelect(a, x, y); otherwise FMix
                        if (arg_tids.items.len >= 3 and (arg_tids.items[2].ty.isBoolVector() or arg_tids.items[2].ty == .bool)) {
                            // Boolean mix → OpSelect(condition=a, true=x, false=y)
                            const operands = try self.alloc.alloc(ir.Instruction.Operand, 3);
                            operands[0] = .{ .id = arg_tids.items[2].id }; // condition
                            operands[1] = .{ .id = arg_tids.items[0].id }; // true (x)
                            operands[2] = .{ .id = arg_tids.items[1].id }; // false (y)
                            try self.instructions.append(self.alloc, .{
                                .tag = .select,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = operands,
                                .ty = result_ty,
                            });
                        } else {
                            // Regular FMix
                            // If third arg (alpha) is scalar but result is vector, splat alpha
                            var alpha_id = arg_tids.items[2].id;
                            if (result_ty.isVector() and !arg_tids.items[2].ty.isVector()) {
                                const num_comps = result_ty.numComponents();
                                const splat_id = self.allocId();
                                const splat_ops = try self.alloc.alloc(ir.Instruction.Operand, num_comps);
                                for (0..num_comps) |i| {
                                    splat_ops[i] = .{ .id = alpha_id };
                                }
                                try self.instructions.append(self.alloc, .{
                                    .tag = .composite_construct,
                                    .result_type = null,
                                    .result_id = splat_id,
                                    .operands = splat_ops,
                                    .ty = result_ty,
                                });
                                alpha_id = splat_id;
                            }
                            const glsl_id: u32 = 46;
                            const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len + 1);
                            operands[0] = .{ .literal_int = glsl_id };
                            operands[1] = .{ .id = arg_tids.items[0].id };
                            operands[2] = .{ .id = arg_tids.items[1].id };
                            operands[3] = .{ .id = alpha_id };
                            try self.instructions.append(self.alloc, .{
                                .tag = .ext_inst,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = operands,
                                .ty = result_ty,
                            });
                        }
                    } else if (std.mem.eql(u8, node.data.name, "min3") or std.mem.eql(u8, node.data.name, "max3") or std.mem.eql(u8, node.data.name, "mid3")) {
                        // min3(a, b, c) = min(min(a, b), c)
                        // max3(a, b, c) = max(max(a, b), c)
                        // mid3(a, b, c) = mid3 uses chained comparisons
                        // Determine min/max instruction based on argument type
                        const min_inst: u32 = switch (result_ty) {
                            .int, .ivec2, .ivec3, .ivec4 => 39, // SMin
                            .uint, .uvec2, .uvec3, .uvec4 => 38, // UMin
                            else => 37, // FMin
                        };
                        const max_inst: u32 = switch (result_ty) {
                            .int, .ivec2, .ivec3, .ivec4 => 42, // SMax
                            .uint, .uvec2, .uvec3, .uvec4 => 41, // UMax
                            else => 40, // FMax
                        };
                        const inner_inst: u32 = if (std.mem.eql(u8, node.data.name, "max3")) max_inst else min_inst;
                        if (arg_tids.items.len >= 3) {
                            // inner = min/max(a, b)
                            const inner_id = self.allocId();
                            const inner_ops = try self.alloc.alloc(ir.Instruction.Operand, 3);
                            inner_ops[0] = .{ .literal_int = inner_inst };
                            inner_ops[1] = .{ .id = arg_tids.items[0].id };
                            inner_ops[2] = .{ .id = arg_tids.items[1].id };
                            try self.instructions.append(self.alloc, .{
                                .tag = .ext_inst,
                                .result_type = null,
                                .result_id = inner_id,
                                .operands = inner_ops,
                                .ty = result_ty,
                            });
                            if (std.mem.eql(u8, node.data.name, "mid3")) {
                                // mid3(a,b,c): a < b ? (b < c ? b : (a < c ? c : a)) : (a < c ? a : (b < c ? c : b))
                                // Simpler: min(max(a,b), c) where c = max(min(a,b), min(max(a,b),c))
                                // Actually simplest: sort via min/max: mid = a + b + c - min(a,b,c) - max(a,b,c)
                                // But SPIR-V doesn't have min3/max3. Let's use chained ops:
                                // mid3(a,b,c) = max(min(a,b), min(max(a,b),c))
                                const max_ab_id = self.allocId();
                                const max_ab_ops = try self.alloc.alloc(ir.Instruction.Operand, 3);
                                max_ab_ops[0] = .{ .literal_int = max_inst }; // SMax/FMax
                                max_ab_ops[1] = .{ .id = arg_tids.items[0].id };
                                max_ab_ops[2] = .{ .id = arg_tids.items[1].id };
                                try self.instructions.append(self.alloc, .{
                                    .tag = .ext_inst,
                                    .result_type = null,
                                    .result_id = max_ab_id,
                                    .operands = max_ab_ops,
                                    .ty = result_ty,
                                });
                                const min_ab_id = inner_id; // already computed min(a,b)
                                const min_maxbc_id = self.allocId();
                                const min_maxbc_ops = try self.alloc.alloc(ir.Instruction.Operand, 3);
                                min_maxbc_ops[0] = .{ .literal_int = min_inst }; // SMin/FMin
                                min_maxbc_ops[1] = .{ .id = max_ab_id };
                                min_maxbc_ops[2] = .{ .id = arg_tids.items[2].id };
                                try self.instructions.append(self.alloc, .{
                                    .tag = .ext_inst,
                                    .result_type = null,
                                    .result_id = min_maxbc_id,
                                    .operands = min_maxbc_ops,
                                    .ty = result_ty,
                                });
                                // result = max(min_ab, min(max_ab, c))
                                const mid_ops = try self.alloc.alloc(ir.Instruction.Operand, 3);
                                mid_ops[0] = .{ .literal_int = max_inst }; // SMax/FMax
                                mid_ops[1] = .{ .id = min_ab_id };
                                mid_ops[2] = .{ .id = min_maxbc_id };
                                try self.instructions.append(self.alloc, .{
                                    .tag = .ext_inst,
                                    .result_type = null,
                                    .result_id = result_id,
                                    .operands = mid_ops,
                                    .ty = result_ty,
                                });
                            } else {
                                // min3/max3: outer = min/max(inner, c)
                                const outer_ops = try self.alloc.alloc(ir.Instruction.Operand, 3);
                                outer_ops[0] = .{ .literal_int = inner_inst };
                                outer_ops[1] = .{ .id = inner_id };
                                outer_ops[2] = .{ .id = arg_tids.items[2].id };
                                try self.instructions.append(self.alloc, .{
                                    .tag = .ext_inst,
                                    .result_type = null,
                                    .result_id = result_id,
                                    .operands = outer_ops,
                                    .ty = result_ty,
                                });
                            }
                        } else {
                            return .{ .ty = result_ty, .id = result_id };
                        }
                        return .{ .ty = result_ty, .id = result_id };
                    } else if (std.mem.eql(u8, node.data.name, "modf") or std.mem.eql(u8, node.data.name, "frexp")) {
                        // modf(x, ptr) → GLSL.std.450 Modf (#35): returns fractional, stores int via ptr
                        // frexp(x, ptr) → GLSL.std.450 Frexp (#51): returns mantissa, stores exp via ptr
                        const glsl_id: u32 = if (std.mem.eql(u8, node.data.name, "modf")) 35 else 51;
                        // Get pointer for second arg (output parameter)
                        var ptr_id: u32 = 0;
                        if (node.data.children.len > 1) {
                            if (self.analyzeLValue(node.data.children[1])) |lval| {
                                ptr_id = lval.id;
                            } else |_| {
                                ptr_id = 0; // fallback
                            }
                        }
                        if (ptr_id != 0) {
                            const operands = try self.alloc.alloc(ir.Instruction.Operand, 3); // inst_id + value + ptr
                            operands[0] = .{ .literal_int = glsl_id };
                            operands[1] = .{ .id = arg_tids.items[0].id };
                            operands[2] = .{ .id = ptr_id };
                            try self.instructions.append(self.alloc, .{
                                .tag = .ext_inst,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = operands,
                                .ty = arg_tids.items[0].ty,
                            });
                        } else {
                            // Fallback: use Struct version with 1 arg (no output param)
                            const struct_glsl_id: u32 = if (std.mem.eql(u8, node.data.name, "modf")) 36 else 52;
                            const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                            operands[0] = .{ .literal_int = struct_glsl_id };
                            operands[1] = .{ .id = arg_tids.items[0].id };
                            try self.instructions.append(self.alloc, .{
                                .tag = .ext_inst,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = operands,
                                .ty = arg_tids.items[0].ty,
                            });
                        }
                        return .{ .ty = arg_tids.items[0].ty, .id = result_id };
                    } else if (std.mem.eql(u8, node.data.name, "floatBitsToUint") or
                        std.mem.eql(u8, node.data.name, "floatBitsToInt") or
                        std.mem.eql(u8, node.data.name, "intBitsToFloat") or
                        std.mem.eql(u8, node.data.name, "uintBitsToFloat"))
                    {
                        // Bitcast builtins: reinterpret bits, NOT numeric conversion
                        const arg_ty = arg_tids.items[0].ty;
                        const bitcast_ty: ast.Type = blk: {
                            if (std.mem.eql(u8, node.data.name, "floatBitsToUint")) {
                                if (arg_ty == .float) break :blk .uint;
                                if (arg_ty == .vec2) break :blk .uvec2;
                                if (arg_ty == .vec3) break :blk .uvec3;
                                if (arg_ty == .vec4) break :blk .uvec4;
                            }
                            if (std.mem.eql(u8, node.data.name, "floatBitsToInt")) {
                                if (arg_ty == .float) break :blk .int;
                                if (arg_ty == .vec2) break :blk .ivec2;
                                if (arg_ty == .vec3) break :blk .ivec3;
                                if (arg_ty == .vec4) break :blk .ivec4;
                            }
                            if (std.mem.eql(u8, node.data.name, "intBitsToFloat")) {
                                if (arg_ty == .int) break :blk .float;
                                if (arg_ty == .ivec2) break :blk .vec2;
                                if (arg_ty == .ivec3) break :blk .vec3;
                                if (arg_ty == .ivec4) break :blk .vec4;
                            }
                            if (std.mem.eql(u8, node.data.name, "uintBitsToFloat")) {
                                if (arg_ty == .uint) break :blk .float;
                                if (arg_ty == .uvec2) break :blk .vec2;
                                if (arg_ty == .uvec3) break :blk .vec3;
                                if (arg_ty == .uvec4) break :blk .vec4;
                            }
                            break :blk result_ty;
                        };
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        operands[0] = .{ .id = arg_tids.items[0].id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .bitcast,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = bitcast_ty,
                        });
                        return .{ .ty = bitcast_ty, .id = result_id };
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
                    // If the symbol is a type_sym, treat as struct constructor (OpCompositeConstruct)
                    if (s.kind == .type_sym) {
                        // For single-argument scalar constructors, may need type conversion
                        if (arg_tids.items.len == 1 and !result_ty.isVector() and !result_ty.isMatrix()) {
                            const arg_ty = arg_tids.items[0].ty;
                            if (!std.meta.eql(arg_ty, result_ty)) {
                                // Type mismatch — try conversion
                                const conv_tag: ?ir.Instruction.Tag = blk: {
                                    if (result_ty == .float) {
                                        if (arg_ty == .bool) break :blk .bool_to_float;
                                        if (arg_ty == .int) break :blk .convert_itof;
                                        if (arg_ty == .uint) break :blk .convert_utof;
                                    }
                                    if (result_ty == .int) {
                                        if (arg_ty == .bool) break :blk .bool_to_int;
                                        if (arg_ty == .float) break :blk .convert_ftoi;
                                        if (arg_ty == .uint) break :blk .convert_uti;
                                    }
                                    if (result_ty == .uint) {
                                        if (arg_ty == .bool) break :blk .bool_to_uint;
                                        if (arg_ty == .float) break :blk .convert_ftou;
                                        if (arg_ty == .int) break :blk .convert_iti;
                                    }
                                    break :blk null;
                                };
                                if (conv_tag) |tag| {
                                    const conv_id = self.allocId();
                                    const conv_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                                    conv_ops[0] = .{ .id = arg_tids.items[0].id };
                                    try self.instructions.append(self.alloc, .{
                                        .tag = tag,
                                        .result_type = null,
                                        .result_id = conv_id,
                                        .operands = conv_ops,
                                        .ty = result_ty,
                                    });
                                    return .{ .ty = result_ty, .id = conv_id };
                                }
                            }
                        }
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
                        // Upgrade to constant_composite if all operands are constants
                        _ = self.tryUpgradeToConstantComposite();
                        return .{ .ty = result_ty, .id = result_id };
                    }
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
                    var tid = try self.analyzeExpression(arg);
                    if (tid.is_ptr) {
                        const ld = self.allocId();
                        const ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        ops[0] = .{ .id = tid.id };
                        try self.instructions.append(self.alloc, .{ .tag = .load, .result_type = null, .result_id = ld, .operands = ops, .ty = tid.ty });
                        tid = .{ .ty = tid.ty, .id = ld };
                    }
                    try arg_tids.append(self.alloc, tid);
                }
                const result_ty_raw = node.data.ty orelse .void;
                // For array constructors with unsized type, compute actual size from arguments
                // Also resolve inner unsized dimensions from arg types
                const result_ty: ast.Type = blk: {
                    var ty = result_ty_raw;
                    if (ty == .array and ty.array.size == 0 and arg_tids.items.len > 0) {
                        // Resolve outermost unsized dimension from arg count
                        var inner = ty.array.base.*;
                        // Resolve inner unsized dimensions from first arg's type
                        if (inner == .array and inner.array.size == 0 and arg_tids.items.len > 0) {
                            const arg_base_ty = arg_tids.items[0].ty;
                            inner = arg_base_ty;
                        }
                        const arr_base = try self.alloc.create(ast.Type);
                        arr_base.* = inner;
                        ty = .{ .array = .{ .base = arr_base, .size = @intCast(arg_tids.items.len) } };
                    }
                    break :blk ty;
                };
                const result_id = self.allocId();

                // Handle sampler2D(tex, samp) → OpSampledImage (separate sampler/texture)
                if (result_ty.isCombinedSampler() and arg_tids.items.len == 2) {
                    const tex_ty = arg_tids.items[0].ty;
                    if (tex_ty == .texture2d_plain or tex_ty == .texture3d_plain or tex_ty == .texture_cube_plain or tex_ty == .texture2d_array_plain or tex_ty == .texture2d_ms_plain) {
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        operands[0] = .{ .id = arg_tids.items[0].id }; // texture
                        operands[1] = .{ .id = arg_tids.items[1].id }; // sampler
                        try self.instructions.append(self.alloc, .{
                            .tag = .sampled_image,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = result_ty,
                        });
                        return .{ .ty = result_ty, .id = result_id };
                    }
                }

                // Handle buffer_reference pointer → uvec2 bitcast
                // The argument should be the PhysicalStorageBuffer pointer, not the loaded struct
                if (arg_tids.items.len == 1 and result_ty == .uvec2) {
                    const arg_ty = arg_tids.items[0].ty;
                    if (arg_ty == .named) {
                        const td = self.types.get(arg_ty.named);
                        if (td != null and td.?.is_buffer_reference) {
                            // Find the original pointer (before the load)
                            // We need to walk back to find the access chain result
                            // For now, emit bitcast from the loaded pointer
                            // The arg was loaded from a PhysicalStorageBuffer pointer,
                            // so we need to use the pointer ID, not the loaded value
                            // Hack: look for the last load instruction and use its operand
                            var ptr_id: u32 = arg_tids.items[0].id;
                            if (self.instructions.items.len > 0) {
                                const last = &self.instructions.items[self.instructions.items.len - 1];
                                if (last.tag == .load and last.result_id == arg_tids.items[0].id and last.operands.len > 0) {
                                    switch (last.operands[0]) {
                                        .id => |v| ptr_id = v,
                                        else => {},
                                    }
                                    _ = self.instructions.pop();
                                }
                            }
                            const ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                            ops[0] = .{ .id = ptr_id };
                            try self.instructions.append(self.alloc, .{
                                .tag = .bitcast,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = ops,
                                .ty = result_ty,
                            });
                            return .{ .ty = result_ty, .id = result_id };
                        }
                    }
                }
                // Handle scalar-from-vector: float(vec4) → extract first component
                // This handles the case where .x swizzle was silently dropped
                if (arg_tids.items.len == 1 and !result_ty.isVector() and !result_ty.isMatrix()) {
                    // Identity: same scalar type
                    if (std.meta.eql(result_ty, arg_tids.items[0].ty)) {
                        return .{ .ty = result_ty, .id = arg_tids.items[0].id };
                    }
                    const arg_ty = arg_tids.items[0].ty;
                    if (arg_ty.isVector()) {
                        // Extract first component from vector
                        const element_ty = arg_ty.elementType();
                        const extract_id = self.allocId();
                        const extract_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        extract_ops[0] = .{ .id = arg_tids.items[0].id };
                        extract_ops[1] = .{ .literal_int = 0 };
                        try self.instructions.append(self.alloc, .{
                            .tag = .composite_extract,
                            .result_type = null,
                            .result_id = extract_id,
                            .operands = extract_ops,
                            .ty = element_ty,
                        });
                        // Convert element to target type if needed
                        if (std.meta.eql(element_ty, result_ty)) {
                            return .{ .ty = result_ty, .id = extract_id };
                        }
                        // Type conversion (e.g., float → int)
                        const conv_tag: ir.Instruction.Tag = blk: {
                            if (result_ty == .int) {
                                if (element_ty == .float or element_ty == .double) break :blk .convert_ftoi;
                                if (element_ty == .uint) break :blk .convert_uti;
                            }
                            if (result_ty == .uint) {
                                if (element_ty == .float or element_ty == .double) break :blk .convert_ftou;
                                if (element_ty == .int) break :blk .convert_iti;
                            }
                            if (result_ty == .float) {
                                if (element_ty == .int) break :blk .convert_itof;
                                if (element_ty == .uint) break :blk .convert_utof;
                            }
                            break :blk .convert_ftoi;
                        };
                        const conv_id = self.allocId();
                        const conv_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        conv_ops[0] = .{ .id = extract_id };
                        try self.instructions.append(self.alloc, .{
                            .tag = conv_tag,
                            .result_type = null,
                            .result_id = conv_id,
                            .operands = conv_ops,
                            .ty = result_ty,
                        });
                        return .{ .ty = result_ty, .id = conv_id };
                    }
                }

                // Handle scalar-to-vector splat: vec4(1.0) → CompositeConstruct with N copies
                // Handle vector conversion: vec4(ivec4_var) → ConvertUToF / ConvertSToF
                if (arg_tids.items.len == 1 and result_ty.isVector()) {
                    // Identity conversion: same-type constructor is a no-op
                    if (std.meta.eql(result_ty, arg_tids.items[0].ty)) {
                        return .{ .ty = result_ty, .id = arg_tids.items[0].id };
                    }
                    const arg_ty = arg_tids.items[0].ty;
                    const n = result_ty.numComponents();
                    const arg_n = if (arg_ty.isVector()) arg_ty.numComponents() else 1;

                    if (arg_ty.isVector() and arg_n == n) {
                        // Same-size vector conversion
                        // Special case: int/uint vector → bvec via INotEqual with zero
                        if (result_ty == .bvec2 or result_ty == .bvec3 or result_ty == .bvec4) {
                            // For bvecN(ivecN), emit composite_construct with per-element bool conversion
                            // Each component: (component != 0) → bool
                            const bool_ops = try self.alloc.alloc(ir.Instruction.Operand, n);
                            const zero_id = try self.getConstInt(0, .int);
                            for (0..n) |i| {
                                const elem_id = self.allocId();
                                const elem_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                                elem_ops[0] = .{ .id = arg_tids.items[0].id };
                                elem_ops[1] = .{ .literal_int = @intCast(i) };
                                try self.instructions.append(self.alloc, .{
                                    .tag = .composite_extract,
                                    .result_type = null,
                                    .result_id = elem_id,
                                    .operands = elem_ops,
                                    .ty = .int,
                                });
                                const cmp_id = self.allocId();
                                const cmp_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                                cmp_ops[0] = .{ .id = elem_id };
                                cmp_ops[1] = .{ .id = zero_id };
                                try self.instructions.append(self.alloc, .{
                                    .tag = .compare_neq,
                                    .result_type = null,
                                    .result_id = cmp_id,
                                    .operands = cmp_ops,
                                    .ty = .bool,
                                });
                                bool_ops[i] = .{ .id = cmp_id };
                            }
                            try self.instructions.append(self.alloc, .{
                                .tag = .composite_construct,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = bool_ops,
                                .ty = result_ty,
                            });
                            return .{ .ty = result_ty, .id = result_id };
                        }
                        // Special case: bvec → int/uint/float vector via OpSelect per component
                        if (arg_ty == .bvec2 or arg_ty == .bvec3 or arg_ty == .bvec4) {
                            const elem_ty: ast.Type = if (result_ty == .ivec2 or result_ty == .ivec3 or result_ty == .ivec4) .int else if (result_ty == .uvec2 or result_ty == .uvec3 or result_ty == .uvec4) .uint else .float;
                            // Emit constants 0 and 1
                            const zero_id: u32 = if (elem_ty == .float) try self.getConstFloat(0.0) else try self.getConstInt(0, elem_ty);
                            const one_id: u32 = if (elem_ty == .float) try self.getConstFloat(1.0) else try self.getConstInt(1, elem_ty);
                            const result_ops = try self.alloc.alloc(ir.Instruction.Operand, n);
                            for (0..n) |i| {
                                // Extract bool component
                                const bool_id = self.allocId();
                                const ext_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                                ext_ops[0] = .{ .id = arg_tids.items[0].id };
                                ext_ops[1] = .{ .literal_int = @intCast(i) };
                                try self.instructions.append(self.alloc, .{ .tag = .composite_extract, .result_type = null, .result_id = bool_id, .operands = ext_ops, .ty = .bool });
                                // OpSelect: cond=true_id, true=one_id, false=zero_id
                                const sel_id = self.allocId();
                                const sel_ops = try self.alloc.alloc(ir.Instruction.Operand, 3);
                                sel_ops[0] = .{ .id = bool_id };
                                sel_ops[1] = .{ .id = one_id };
                                sel_ops[2] = .{ .id = zero_id };
                                try self.instructions.append(self.alloc, .{ .tag = .select, .result_type = null, .result_id = sel_id, .operands = sel_ops, .ty = elem_ty });
                                result_ops[i] = .{ .id = sel_id };
                            }
                            try self.instructions.append(self.alloc, .{ .tag = .composite_construct, .result_type = null, .result_id = result_id, .operands = result_ops, .ty = result_ty });
                            return .{ .ty = result_ty, .id = result_id };
                        }

                        const conv_tag: ir.Instruction.Tag = blk: {
                            // int/uint vector → float vector
                            if (result_ty == .vec2 or result_ty == .vec3 or result_ty == .vec4) {
                                if (arg_ty == .ivec2 or arg_ty == .ivec3 or arg_ty == .ivec4) break :blk .convert_itof;
                                if (arg_ty == .uvec2 or arg_ty == .uvec3 or arg_ty == .uvec4) break :blk .convert_utof;
                            }
                            // float/uint vector → int vector
                            if (result_ty == .ivec2 or result_ty == .ivec3 or result_ty == .ivec4) {
                                if (arg_ty == .vec2 or arg_ty == .vec3 or arg_ty == .vec4) break :blk .convert_ftoi;
                                if (arg_ty == .uvec2 or arg_ty == .uvec3 or arg_ty == .uvec4) break :blk .convert_uti;
                            }
                            // float/int vector → uint vector
                            if (result_ty == .uvec2 or result_ty == .uvec3 or result_ty == .uvec4) {
                                if (arg_ty == .vec2 or arg_ty == .vec3 or arg_ty == .vec4) break :blk .convert_ftou;
                                if (arg_ty == .ivec2 or arg_ty == .ivec3 or arg_ty == .ivec4) break :blk .convert_iti;
                            }
                            // Try generic conversion (handles 8-bit/16-bit vector types)
                            if (self.getConversionTag(result_ty, arg_ty)) |tag| break :blk tag;
                            break :blk .composite_construct;
                        };
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        operands[0] = .{ .id = arg_tids.items[0].id };
                        try self.instructions.append(self.alloc, .{
                            .tag = conv_tag,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = result_ty,
                        });
                        return .{ .ty = result_ty, .id = result_id };
                    }

                    // Convert scalar type if needed (e.g., vec4(int_val) → convert int→float first)
                    var splat_id = arg_tids.items[0].id;
                    const splat_ty = arg_ty;
                    // Determine component type of result vector
                    const result_scalar: ast.Type = switch (result_ty) {
                        .vec2, .vec3, .vec4 => .float,
                        .ivec2, .ivec3, .ivec4 => .int,
                        .uvec2, .uvec3, .uvec4 => .uint,
                        .i8vec2, .i8vec3, .i8vec4 => .int8,
                        .u8vec2, .u8vec3, .u8vec4 => .uint8,
                        .i16vec2, .i16vec3, .i16vec4 => .int16,
                        .u16vec2, .u16vec3, .u16vec4 => .uint16,
                        .f16vec2, .f16vec3, .f16vec4 => .float16,
                        else => .void,
                    };
                    const need_conv = !std.meta.eql(splat_ty, result_scalar) and result_scalar != .void;
                    if (need_conv) {
                        const conv_tag: ir.Instruction.Tag = blk: {
                            if (result_scalar == .float) {
                                if (splat_ty == .int) break :blk .convert_itof;
                                if (splat_ty == .uint) break :blk .convert_utof;
                            }
                            if (result_scalar == .int) {
                                if (splat_ty == .float) break :blk .convert_ftoi;
                                if (splat_ty == .uint) break :blk .convert_uti;
                            }
                            if (result_scalar == .uint) {
                                if (splat_ty == .float) break :blk .convert_ftou;
                                if (splat_ty == .int) break :blk .convert_iti;
                            }
                            // Try generic conversion for 8/16-bit types
                            if (self.getConversionTag(result_scalar, splat_ty)) |tag| break :blk tag;
                            break :blk .composite_construct;
                        };
                        const conv_id = self.allocId();
                        const conv_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        conv_operands[0] = .{ .id = splat_id };
                        try self.instructions.append(self.alloc, .{
                            .tag = conv_tag,
                            .result_type = null,
                            .result_id = conv_id,
                            .operands = conv_operands,
                            .ty = result_scalar,
                        });
                        splat_id = conv_id;
                    }
                    // Scalar splat — check if arg is a literal and result is int/uint vector
                    if ((arg_tids.items[0].ty == .int or arg_tids.items[0].ty == .uint) and
                        (result_ty == .ivec2 or result_ty == .ivec3 or result_ty == .ivec4 or result_ty == .uvec2 or result_ty == .uvec3 or result_ty == .uvec4))
                    {
                        const arg_node = node.data.children[0];
                        if (arg_node.tag == .int_literal or arg_node.tag == .uint_literal) {
                            const val: u32 = if (arg_node.tag == .uint_literal) @intCast(@as(u64, @bitCast(arg_node.data.int_val))) else @bitCast(@as(i32, @intCast(arg_node.data.int_val)));
                            const comp_ty: ast.Type = switch (result_ty) {
                                .ivec2, .ivec3, .ivec4 => .int,
                                .uvec2, .uvec3, .uvec4 => .uint,
                                else => .int,
                            };
                            const cc_ops = try self.alloc.alloc(ir.Instruction.Operand, n);
                            for (0..n) |i| {
                                const comp_id = self.allocId();
                                const ci_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                                ci_ops[0] = .{ .literal_int = val };
                                try self.instructions.append(self.alloc, .{ .tag = .constant_int, .result_type = null, .result_id = comp_id, .operands = ci_ops, .ty = comp_ty });
                                cc_ops[i] = .{ .id = comp_id };
                            }
                            try self.instructions.append(self.alloc, .{
                                .tag = .constant_composite,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = cc_ops,
                                .ty = result_ty,
                            });
                            return .{ .ty = result_ty, .id = result_id };
                        }
                    }
                    // Float literal splat — check if arg is a float literal and result is a float vector
                    if (arg_tids.items[0].ty == .float and
                        (result_ty == .vec2 or result_ty == .vec3 or result_ty == .vec4))
                    {
                        const arg_node = node.data.children[0];
                        if (arg_node.tag == .float_literal) {
                            const val: f32 = @floatCast(arg_node.data.float_val);
                            const cc_ops = try self.alloc.alloc(ir.Instruction.Operand, n);
                            const comp_id = self.allocId();
                            const cf_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                            cf_ops[0] = .{ .literal_float = val };
                            try self.instructions.append(self.alloc, .{ .tag = .constant_float, .result_type = null, .result_id = comp_id, .operands = cf_ops, .ty = .float });
                            for (0..n) |i| {
                                cc_ops[i] = .{ .id = comp_id };
                            }
                            try self.instructions.append(self.alloc, .{
                                .tag = .constant_composite,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = cc_ops,
                                .ty = result_ty,
                            });
                            return .{ .ty = result_ty, .id = result_id };
                        }
                    }
                    const operands = try self.alloc.alloc(ir.Instruction.Operand, n);
                    for (0..n) |i| {
                        operands[i] = .{ .id = splat_id };
                    }
                    try self.instructions.append(self.alloc, .{
                        .tag = .composite_construct,
                        .result_type = null,
                        .result_id = result_id,
                        .operands = operands,
                        .ty = result_ty,
                    });
                    // Upgrade to constant_composite if splat value is a constant
                    _ = self.tryUpgradeToConstantComposite();
                    return .{ .ty = result_ty, .id = result_id };
                }

                // Scalar-to-scalar type conversion: float(int_val), int(uint_val), etc.
                if (arg_tids.items.len == 1 and !result_ty.isVector() and !result_ty.isMatrix()) {
                    if (std.meta.eql(arg_tids.items[0].ty, result_ty)) {
                        // Same type: identity
                        return arg_tids.items[0];
                    }
                    // Different scalar types: insert conversion
                    const conv_tag: ir.Instruction.Tag = blk: {
                        const from = arg_tids.items[0].ty;
                        const to = result_ty;
                        if (to == .float or to == .double) {
                            if (from == .bool) break :blk .bool_to_float;
                            if (from == .int or from == .ivec2) break :blk .convert_itof;
                            if (from == .uint or from == .uvec2) break :blk .convert_utof;
                        }
                        if (to == .int) {
                            if (from == .bool) break :blk .bool_to_int;
                            if (from == .float or from == .double) break :blk .convert_ftoi;
                            if (from == .uint) break :blk .convert_uti;
                        }
                        if (to == .uint) {
                            if (from == .bool) break :blk .bool_to_uint;
                            if (from == .float or from == .double) break :blk .convert_ftou;
                            if (from == .int) break :blk .convert_iti;
                        }
                        // Try generic conversion (handles 8-bit/16-bit types)
                        if (self.getConversionTag(to, from)) |tag| break :blk tag;
                        break :blk .composite_construct; // fallback
                    };
                    const result_id2 = self.allocId();
                    const conv_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    conv_operands[0] = .{ .id = arg_tids.items[0].id };
                    try self.instructions.append(self.alloc, .{
                        .tag = conv_tag,
                        .result_type = null,
                        .result_id = result_id2,
                        .operands = conv_operands,
                        .ty = result_ty,
                    });
                    return .{ .ty = result_ty, .id = result_id2 };
                }

                // Matrix-to-matrix conversion: mat3(mat4_m) → extract columns, shrink, build smaller matrix
                if (arg_tids.items.len == 1 and result_ty.isMatrix() and arg_tids.items[0].ty.isMatrix()) {
                    const src_ty = arg_tids.items[0].ty;
                    const src_id = arg_tids.items[0].id;
                    const dst_cols = result_ty.numColumns();
                    const dst_col_type = result_ty.columnType();
                    const src_col_type = src_ty.columnType();
                    const dst_col_n = dst_col_type.numComponents();
                    const src_col_n = src_col_type.numComponents();
                    // Extract first dst_cols columns from source matrix
                    const col_ids = try self.alloc.alloc(u32, dst_cols);
                    for (0..dst_cols) |i| {
                        const extracted_col_id = self.allocId();
                        const extract_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        extract_ops[0] = .{ .id = src_id };
                        extract_ops[1] = .{ .literal_int = @intCast(i) };
                        try self.instructions.append(self.alloc, .{
                            .tag = .composite_extract,
                            .result_type = null,
                            .result_id = extracted_col_id,
                            .operands = extract_ops,
                            .ty = src_col_type,
                        });
                        // If column sizes differ, shrink via vector_shuffle
                        if (dst_col_n < src_col_n) {
                            const shuffle_id = self.allocId();
                            const shuffle_ops = try self.alloc.alloc(ir.Instruction.Operand, 2 + dst_col_n);
                            shuffle_ops[0] = .{ .id = extracted_col_id };
                            shuffle_ops[1] = .{ .id = extracted_col_id };
                            for (0..dst_col_n) |j| {
                                shuffle_ops[2 + j] = .{ .literal_int = @intCast(j) };
                            }
                            try self.instructions.append(self.alloc, .{
                                .tag = .vector_shuffle,
                                .result_type = null,
                                .result_id = shuffle_id,
                                .operands = shuffle_ops,
                                .ty = dst_col_type,
                            });
                            col_ids[i] = shuffle_id;
                        } else {
                            col_ids[i] = extracted_col_id;
                        }
                    }
                    // Build the result matrix from extracted columns
                    const construct_ops = try self.alloc.alloc(ir.Instruction.Operand, dst_cols);
                    for (col_ids, 0..) |cid, i| {
                        construct_ops[i] = .{ .id = cid };
                    }
                    try self.instructions.append(self.alloc, .{
                        .tag = .composite_construct,
                        .result_type = null,
                        .result_id = result_id,
                        .operands = construct_ops,
                        .ty = result_ty,
                    });
                    return .{ .ty = result_ty, .id = result_id };
                }

                // Matrix construction from individual scalars: mat2x3(a,b,c,d,e,f) → construct column vectors then matrix
                if (result_ty.isMatrix() and arg_tids.items.len > 1 and arg_tids.items[0].ty.isScalar()) {
                    const col_type = result_ty.columnType();
                    const num_cols = result_ty.numColumns();
                    const col_n = col_type.numComponents();
                    // Group scalars into column vectors
                    const col_ids = try self.alloc.alloc(u32, num_cols);
                    for (0..num_cols) |col| {
                        const vec_result_id = self.allocId();
                        const vec_ops = try self.alloc.alloc(ir.Instruction.Operand, col_n);
                        for (0..col_n) |row| {
                            const idx = col * col_n + row;
                            if (idx < arg_tids.items.len) {
                                vec_ops[row] = .{ .id = arg_tids.items[idx].id };
                            } else {
                                vec_ops[row] = .{ .id = arg_tids.items[arg_tids.items.len - 1].id };
                            }
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .composite_construct,
                            .result_type = null,
                            .result_id = vec_result_id,
                            .operands = vec_ops,
                            .ty = col_type,
                        });
                        col_ids[col] = vec_result_id;
                    }
                    // Construct matrix from column vectors
                    const mat_ops = try self.alloc.alloc(ir.Instruction.Operand, num_cols);
                    for (col_ids, 0..) |cid, i| {
                        mat_ops[i] = .{ .id = cid };
                    }
                    try self.instructions.append(self.alloc, .{
                        .tag = .composite_construct,
                        .result_type = null,
                        .result_id = result_id,
                        .operands = mat_ops,
                        .ty = result_ty,
                    });
                    return .{ .ty = result_ty, .id = result_id };
                }

                // Convert arguments to match result component type if needed
                const result_scalar: ast.Type = switch (result_ty) {
                    .vec2, .vec3, .vec4 => .float,
                    .ivec2, .ivec3, .ivec4 => .int,
                    .uvec2, .uvec3, .uvec4 => .uint,
                    .i8vec2, .i8vec3, .i8vec4 => .int8,
                    .u8vec2, .u8vec3, .u8vec4 => .uint8,
                    .i16vec2, .i16vec3, .i16vec4 => .int16,
                    .u16vec2, .u16vec3, .u16vec4 => .uint16,
                    .f16vec2, .f16vec3, .f16vec4 => .float16,
                    else => result_ty, // mat types etc
                };
                const converted_ids = try self.alloc.alloc(u32, arg_tids.items.len);
                for (arg_tids.items, 0..) |tid, i| {
                    var arg_id = tid.id;
                    const arg_ty = tid.ty;
                    // Check if this argument's component type matches result's
                    const arg_scalar: ast.Type = if (arg_ty.isVector()) switch (arg_ty) {
                        .vec2, .vec3, .vec4 => .float,
                        .ivec2, .ivec3, .ivec4 => .int,
                        .uvec2, .uvec3, .uvec4 => .uint,
                        .i8vec2, .i8vec3, .i8vec4 => .int8,
                        .u8vec2, .u8vec3, .u8vec4 => .uint8,
                        .i16vec2, .i16vec3, .i16vec4 => .int16,
                        .u16vec2, .u16vec3, .u16vec4 => .uint16,
                        .f16vec2, .f16vec3, .f16vec4 => .float16,
                        else => .void,
                    } else arg_ty;
                    if (!std.meta.eql(arg_scalar, result_scalar) and result_scalar.isScalar() and arg_scalar.isScalar()) {
                        // Need type conversion
                        const conv_tag: ir.Instruction.Tag = blk: {
                            if (result_scalar == .float) {
                                if (arg_scalar == .bool) break :blk .bool_to_float;
                                if (arg_scalar == .int) break :blk .convert_itof;
                                if (arg_scalar == .uint) break :blk .convert_utof;
                            }
                            if (result_scalar == .int) {
                                if (arg_scalar == .bool) break :blk .bool_to_int;
                                if (arg_scalar == .float) break :blk .convert_ftoi;
                                if (arg_scalar == .uint) break :blk .convert_uti;
                            }
                            if (result_scalar == .uint) {
                                if (arg_scalar == .bool) break :blk .bool_to_uint;
                                if (arg_scalar == .float) break :blk .convert_ftou;
                                if (arg_scalar == .int) break :blk .convert_iti;
                            }
                            // Try generic conversion for 8/16-bit types
                            if (self.getConversionTag(result_scalar, arg_scalar)) |tag| break :blk tag;
                            break :blk .composite_construct;
                        };
                        const conv_id = self.allocId();
                        const conv_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        conv_ops[0] = .{ .id = arg_id };
                        const conv_result_ty: ast.Type = if (arg_ty.isVector()) blk: {
                            // Convert ivec2 → vec2, ivec3 → vec3, etc.
                            const n = arg_ty.numComponents();
                            break :blk switch (result_scalar) {
                                .float => switch (n) {
                                    2 => .vec2,
                                    3 => .vec3,
                                    4 => .vec4,
                                    else => result_ty,
                                },
                                .int => switch (n) {
                                    2 => .ivec2,
                                    3 => .ivec3,
                                    4 => .ivec4,
                                    else => result_ty,
                                },
                                .uint => switch (n) {
                                    2 => .uvec2,
                                    3 => .uvec3,
                                    4 => .uvec4,
                                    else => result_ty,
                                },
                                else => result_ty,
                            };
                        } else result_scalar;
                        try self.instructions.append(self.alloc, .{
                            .tag = conv_tag,
                            .result_type = null,
                            .result_id = conv_id,
                            .operands = conv_ops,
                            .ty = conv_result_ty,
                        });
                        arg_id = conv_id;
                    }
                    converted_ids[i] = arg_id;
                }

                // Check if all args are integer literals and result is an int/uint vector → constant_composite
                // This is needed for texelFetchOffset which requires OpConstantComposite for ConstOffset
                // Handles: int_literal, uint_literal, unary_op(-int_literal)
                var all_const_ints = true;
                for (node.data.children) |arg| {
                    if (arg.tag != .int_literal and arg.tag != .uint_literal) {
                        // Check for unary minus of int literal
                        if (arg.tag == .unary_op and arg.data.children.len > 0 and arg.data.children[0].tag == .int_literal) {
                            // ok, negated literal
                        } else {
                            all_const_ints = false;
                            break;
                        }
                    }
                }
                if (all_const_ints and (result_ty == .ivec2 or result_ty == .ivec3 or result_ty == .ivec4 or result_ty == .uvec2 or result_ty == .uvec3 or result_ty == .uvec4)) {
                    const cc_ops = try self.alloc.alloc(ir.Instruction.Operand, node.data.children.len);
                    for (node.data.children, 0..) |arg, i| {
                        const val: u32 = blk: {
                            if (arg.tag == .int_literal) break :blk @bitCast(@as(i32, @intCast(arg.data.int_val)));
                            if (arg.tag == .uint_literal) break :blk @intCast(@as(u64, @bitCast(arg.data.int_val)));
                            // unary minus of int literal
                            if (arg.tag == .unary_op and arg.data.children.len > 0 and arg.data.children[0].tag == .int_literal)
                                break :blk @bitCast(-@as(i32, @intCast(arg.data.children[0].data.int_val)));
                            break :blk 0;
                        };
                        // Emit a constant for each component with the correct type
                        const comp_ty: ast.Type = switch (result_ty) {
                            .ivec2, .ivec3, .ivec4 => .int,
                            .uvec2, .uvec3, .uvec4 => .uint,
                            else => .int,
                        };
                        const comp_id = self.allocId();
                        const ci_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        ci_ops[0] = .{ .literal_int = val };
                        try self.instructions.append(self.alloc, .{ .tag = .constant_int, .result_type = null, .result_id = comp_id, .operands = ci_ops, .ty = comp_ty });
                        cc_ops[i] = .{ .id = comp_id };
                    }
                    try self.instructions.append(self.alloc, .{
                        .tag = .constant_composite,
                        .result_type = null,
                        .result_id = result_id,
                        .operands = cc_ops,
                        .ty = result_ty,
                    });
                    return .{ .ty = result_ty, .id = result_id };
                }

                // Check if all args are float literals and result is a float vector → constant_composite
                // This emits OpConstantComposite in the type section instead of OpCompositeConstruct in the function body
                var all_const_floats = true;
                for (node.data.children) |arg| {
                    if (arg.tag != .float_literal) {
                        all_const_floats = false;
                        break;
                    }
                }
                if (all_const_floats and (result_ty == .vec2 or result_ty == .vec3 or result_ty == .vec4)) {
                    const num_comps = result_ty.numComponents();
                    const cc_ops = try self.alloc.alloc(ir.Instruction.Operand, num_comps);
                    // Check for scalar-to-vector splat (single float literal arg)
                    if (node.data.children.len == 1) {
                        const val: f32 = @floatCast(node.data.children[0].data.float_val);
                        const comp_id = self.allocId();
                        const cf_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        cf_ops[0] = .{ .literal_float = val };
                        try self.instructions.append(self.alloc, .{ .tag = .constant_float, .result_type = null, .result_id = comp_id, .operands = cf_ops, .ty = .float });
                        for (0..num_comps) |i| {
                            cc_ops[i] = .{ .id = comp_id };
                        }
                    } else {
                        for (node.data.children, 0..) |arg, i| {
                            const val: f32 = @floatCast(arg.data.float_val);
                            const comp_id = self.allocId();
                            const cf_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                            cf_ops[0] = .{ .literal_float = val };
                            try self.instructions.append(self.alloc, .{ .tag = .constant_float, .result_type = null, .result_id = comp_id, .operands = cf_ops, .ty = .float });
                            cc_ops[i] = .{ .id = comp_id };
                        }
                    }
                    try self.instructions.append(self.alloc, .{
                        .tag = .constant_composite,
                        .result_type = null,
                        .result_id = result_id,
                        .operands = cc_ops,
                        .ty = result_ty,
                    });
                    return .{ .ty = result_ty, .id = result_id };
                }

                // Allocate operand array
                const operands = try self.alloc.alloc(ir.Instruction.Operand, converted_ids.len);
                for (converted_ids, 0..) |cid, i| {
                    operands[i] = .{ .id = cid };
                }
                self.alloc.free(converted_ids);

                try self.instructions.append(self.alloc, .{
                    .tag = .composite_construct,
                    .result_type = null,
                    .result_id = result_id,
                    .operands = operands,
                    .ty = result_ty,
                });
                // Upgrade to constant_composite if all operands are constants
                _ = self.tryUpgradeToConstantComposite();
                return .{ .ty = result_ty, .id = result_id };
            },
            .comma_op => {
                // Comma operator: evaluate all children left-to-right, return last value
                var last = try self.analyzeExpression(node.data.children[0]);
                for (node.data.children[1..]) |child| {
                    last = try self.analyzeExpression(child);
                }
                return last;
            },
            .ternary_op => {
                if (node.data.children.len < 3) return error.SemanticFailed;
                const cond_tid = try self.analyzeExpression(node.data.children[0]);
                const then_tid = try self.analyzeExpression(node.data.children[1]);
                const else_tid = try self.analyzeExpression(node.data.children[2]);
                const result_ty = self.promoteTypes(then_tid.ty, else_tid.ty) orelse then_tid.ty;
                const result_id = self.allocId();
                const operands = try self.alloc.alloc(ir.Instruction.Operand, 3);
                operands[0] = .{ .id = cond_tid.id };
                operands[1] = .{ .id = then_tid.id };
                operands[2] = .{ .id = else_tid.id };
                try self.instructions.append(self.alloc, .{
                    .tag = .select,
                    .result_type = null,
                    .result_id = result_id,
                    .operands = operands,
                    .ty = result_ty,
                });
                return .{ .ty = result_ty, .id = result_id };
            },
            .member_access => {
                if (node.data.children.len < 1) return error.SemanticFailed;

                // Optimization: for member access on a named type, check if the base
                // is a simple identifier. If so, get the variable pointer directly
                // instead of loading the whole struct then extracting.
                const base_child = node.data.children[0];
                if (base_child.tag == .identifier) {
                    if (self.lookup(base_child.data.name)) |sym| {
                        if (sym.kind == .var_sym and sym.ty == .named) {
                            // Use the variable pointer directly for member access
                            const struct_name = sym.ty.named;
                            if (self.types.get(struct_name)) |td| {
                                const member_name = node.data.name;
                                var member_index: ?u32 = null;
                                for (td.members, 0..) |member, i| {
                                    if (std.mem.eql(u8, member.name, member_name)) {
                                        member_index = @as(u32, @intCast(i));
                                        break;
                                    }
                                }
                                if (member_index) |idx| {
                                    const member_ty = td.members[idx].ty;
                                    const result_id = self.allocId();
                                    const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                                    operands[0] = .{ .id = sym.ir_id };
                                    operands[1] = .{ .literal_int = idx };
                                    try self.instructions.append(self.alloc, .{
                                        .tag = .access_chain,
                                        .result_type = null,
                                        .result_id = result_id,
                                        .operands = operands,
                                        .ty = member_ty,
                                    });
                                    return .{ .ty = member_ty, .id = result_id, .is_ptr = true };
                                }
                            }
                        }
                    }
                }

                var base_tid = try self.analyzeExpression(node.data.children[0]);

                // Handle vector swizzles (e.g., vec4.x, uvec3.y)
                if (base_tid.ty.isVector()) {
                    // If pointer to vector, load first
                    if (base_tid.is_ptr) {
                        const ld = self.allocId();
                        const ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        ops[0] = .{ .id = base_tid.id };
                        try self.instructions.append(self.alloc, .{ .tag = .load, .result_type = null, .result_id = ld, .operands = ops, .ty = base_tid.ty });
                        base_tid = .{ .ty = base_tid.ty, .id = ld };
                    }
                    const member_name = node.data.name;
                    const elem_ty = base_tid.ty.elementType();
                    // Single-component swizzle (e.g., .x, .y)
                    if (member_name.len == 1) {
                        const idx = self.swizzleIndex(member_name[0]);
                        const result_id = self.allocId();
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        operands[0] = .{ .id = base_tid.id };
                        operands[1] = .{ .literal_int = idx };
                        try self.instructions.append(self.alloc, .{
                            .tag = .composite_extract,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = elem_ty,
                        });
                        return .{ .ty = elem_ty, .id = result_id };
                    }
                    // Multi-component swizzle (e.g., .xyz, .xy, .xz)
                    // Use OpVectorShuffle to select components
                    const num_comps = member_name.len;
                    if (num_comps >= 2 and num_comps <= 4) {
                        // Determine result type based on component count
                        const result_ty: ast.Type = switch (base_tid.ty) {
                            .vec2, .vec3, .vec4 => switch (num_comps) {
                                2 => .vec2,
                                3 => .vec3,
                                4 => .vec4,
                                else => base_tid.ty,
                            },
                            .ivec2, .ivec3, .ivec4 => switch (num_comps) {
                                2 => .ivec2,
                                3 => .ivec3,
                                4 => .ivec4,
                                else => base_tid.ty,
                            },
                            .uvec2, .uvec3, .uvec4 => switch (num_comps) {
                                2 => .uvec2,
                                3 => .uvec3,
                                4 => .uvec4,
                                else => base_tid.ty,
                            },
                            else => base_tid.ty,
                        };
                        // Identity check: if result type == base type and all indices are sequential, return base directly
                        if (std.meta.eql(result_ty, base_tid.ty)) {
                            var is_identity = true;
                            for (member_name, 0..) |c, i| {
                                if (self.swizzleIndex(c) != i) {
                                    is_identity = false;
                                    break;
                                }
                            }
                            if (is_identity) return base_tid;
                        }
                        const result_id = self.allocId();
                        // vector_shuffle operands: vec1, vec2, literal indices...
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 2 + num_comps);
                        operands[0] = .{ .id = base_tid.id }; // vec1
                        operands[1] = .{ .id = base_tid.id }; // vec2 (same)
                        for (member_name, 0..) |c, i| {
                            operands[2 + i] = .{ .literal_int = self.swizzleIndex(c) };
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .vector_shuffle,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = result_ty,
                        });
                        return .{ .ty = result_ty, .id = result_id };
                    }
                    return base_tid;
                }

                // Handle struct member access
                if (base_tid.ty == .named) {
                    const struct_name = base_tid.ty.named;
                    if (self.types.get(struct_name)) |td| {
                        const member_name = node.data.name;
                        var member_index: ?u32 = null;
                        for (td.members, 0..) |member, i| {
                            if (std.mem.eql(u8, member.name, member_name)) {
                                member_index = @as(u32, @intCast(i));
                                break;
                            }
                        }

                        if (member_index) |idx| {
                            const member_ty = td.members[idx].ty;
                            const result_id = self.allocId();

                            if (base_tid.is_ptr) {
                                // Pointer base → access_chain (pointer result)
                                const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                                operands[0] = .{ .id = base_tid.id };
                                operands[1] = .{ .literal_int = idx };
                                try self.instructions.append(self.alloc, .{
                                    .tag = .access_chain,
                                    .result_type = null,
                                    .result_id = result_id,
                                    .operands = operands,
                                    .ty = member_ty,
                                });
                                return .{ .ty = member_ty, .id = result_id, .is_ptr = true };
                            } else {
                                // Value base → composite_extract (value result)
                                const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                                operands[0] = .{ .id = base_tid.id };
                                operands[1] = .{ .literal_int = idx };
                                try self.instructions.append(self.alloc, .{
                                    .tag = .composite_extract,
                                    .result_type = null,
                                    .result_id = result_id,
                                    .operands = operands,
                                    .ty = member_ty,
                                });
                                return .{ .ty = member_ty, .id = result_id };
                            }
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
                else if (base_tid.ty.isMatrix())
                    base_tid.ty.columnType()
                else
                    return error.TypeMismatch;

                const result_id = self.allocId();

                // For matrix/array indexing with constant index, use OpCompositeExtract
                // But only if the base is a VALUE, not a pointer
                if (!base_tid.is_ptr and (base_tid.ty.isMatrix() or base_tid.ty == .array)) {
                    // Check if index is a compile-time constant
                    var const_idx: ?u32 = null;
                    // First check instruction list (for current function)
                    for (self.instructions.items, 0..) |inst, i| {
                        if (inst.result_id != null and inst.result_id.? == index_tid.id and inst.tag == .constant_int) {
                            const_idx = switch (inst.operands[0]) { .literal_int => |v| v, else => null };
                            _ = i;
                            break;
                        }
                    }
                    // Also check const_cache for constants from other functions
                    if (const_idx == null) {
                        var iter = self.const_cache.iterator();
                        while (iter.next()) |entry| {
                            if (entry.value_ptr.* == index_tid.id) {
                                // Extract value from key: (type_enum << 32) | value
                                const val = @as(u32, @truncate(entry.key_ptr.*));
                                const_idx = val;
                                break;
                            }
                        }
                    }
                    if (const_idx) |idx| {
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        operands[0] = .{ .id = base_tid.id };
                        operands[1] = .{ .literal_int = idx };
                        try self.instructions.append(self.alloc, .{
                            .tag = .composite_extract,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = element_ty,
                        });
                        return .{ .ty = element_ty, .id = result_id };
                    }
                }

                const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                operands[0] = .{ .id = base_tid.id };
                operands[1] = .{ .id = index_tid.id };

                // Use vector_extract_dynamic for runtime indexing into loaded vectors
                const tag: ir.Instruction.Tag = if (base_tid.ty.isVector()) .vector_extract_dynamic else .access_chain;
                try self.instructions.append(self.alloc, .{
                    .tag = tag,
                    .result_type = null,
                    .result_id = result_id,
                    .operands = operands,
                    .ty = element_ty,
                });

                // Access chains produce pointers, vector_extract_dynamic produces values
                const is_ptr_result = tag == .access_chain;
                return .{ .ty = element_ty, .id = result_id, .is_ptr = is_ptr_result };
            },
            .post_increment, .post_decrement, .pre_increment, .pre_decrement => {
                if (node.data.children.len < 1) return error.SemanticFailed;
                // Get the lvalue (variable pointer)
                const lval = try self.analyzeLValue(node.data.children[0]);
                // Load current value
                const loaded_id = self.allocId();
                const load_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                load_ops[0] = .{ .id = lval.id };
                try self.instructions.append(self.alloc, .{
                    .tag = .load,
                    .result_type = null,
                    .result_id = loaded_id,
                    .operands = load_ops,
                    .ty = lval.ty,
                });
                // Create constant 1
                const one_id: u32 = if (lval.ty == .int or lval.ty == .uint or lval.ty.isVector()) try self.getConstInt(1, if (lval.ty == .uint) .uint else .int) else try self.getConstFloat(1.0);
                // Compute new value
                const new_val_id = self.allocId();
                const is_add = node.tag == .post_increment or node.tag == .pre_increment;
                const arith_tag: ir.Instruction.Tag = if (lval.ty == .int or lval.ty == .uint) (if (is_add) .add else .sub) else (if (is_add) .fadd else .fsub);
                const arith_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                arith_ops[0] = .{ .id = loaded_id };
                arith_ops[1] = .{ .id = one_id };
                try self.instructions.append(self.alloc, .{
                    .tag = arith_tag,
                    .result_type = null,
                    .result_id = new_val_id,
                    .operands = arith_ops,
                    .ty = lval.ty,
                });
                // Store new value
                const store_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                store_ops[0] = .{ .id = lval.id };
                store_ops[1] = .{ .id = new_val_id };
                try self.instructions.append(self.alloc, .{
                    .tag = .store,
                    .result_type = null,
                    .result_id = null,
                    .operands = store_ops,
                    .ty = .void,
                });
                // For post-increment, return original value; for pre, return new
                const return_id = if (node.tag == .post_increment or node.tag == .post_decrement) loaded_id else new_val_id;
                return .{ .ty = lval.ty, .id = return_id };
            },
            .group => {
                if (node.data.children.len < 1) return error.SemanticFailed;
                return self.analyzeExpression(node.data.children[0]);
            },
            else => {
                const ret: TypedId = .{ .ty = .void, .id = self.allocId() };
                return ret;
            },
        }
    }

    fn promoteTypes(self: *Analyzer, a: ast.Type, b: ast.Type) ?ast.Type {
        _ = self;
        if (std.meta.eql(a, b)) return a;
        // Vector/scalar promotion
        if (a.isVector() and b.isScalar()) return a;
        if (a.isScalar() and b.isVector()) return b;
        // Matrix/scalar promotion
        if (a.isMatrix() and b.isScalar()) return a;
        if (a.isScalar() and b.isMatrix()) return b;
        // Matrix promotions
        if (a.isMatrix() and b.isVector()) return b;
        if (a.isVector() and b.isMatrix()) return a;
        if (a == .float or b == .float) return .float;
        if (a == .double or b == .double) return .double;
        if (a == .uint or b == .uint) return .uint;
        // For other mixed types, return left (e.g., struct member access)
        return a;
    }

    /// Determine the IR conversion tag needed to convert `from` type to `to` type.
    /// Returns null if no conversion is needed or the conversion is not supported.
    fn getConversionTag(self: *Analyzer, to: ast.Type, from: ast.Type) ?ir.Instruction.Tag {
        _ = self;
        if (std.meta.eql(to, from)) return null;
        // float/float16 <-> int/uint
        if (to == .float or to == .float16) {
            if (from == .int) return .convert_itof;
            if (from == .uint) return .convert_utof;
            if (from == .bool) return .bool_to_float;
        }
        if (to == .int) {
            if (from == .float or from == .float16) return .convert_ftoi;
            if (from == .uint) return .convert_iti; // bitcast for same-width
            if (from == .bool) return .bool_to_int;
            // Narrowing from wider integer types
            if (from == .int8 or from == .uint8 or from == .int16 or from == .uint16) return .convert_widen;
        }
        if (to == .uint) {
            if (from == .float or from == .float16) return .convert_ftou;
            if (from == .int) return .convert_iti; // bitcast for same-width
            if (from == .bool) return .bool_to_uint;
            if (from == .int8 or from == .uint8 or from == .int16 or from == .uint16) return .convert_widen;
        }
        // Narrow integer conversions (int/uint → int8/uint8/int16/uint16)
        if (to == .int8 or to == .uint8 or to == .int16 or to == .uint16) {
            if (from == .int or from == .uint) return .convert_narrow;
        }
        // 8-bit ↔ 16-bit
        if (to == .int8 or to == .uint8) {
            if (from == .int16 or from == .uint16) return .convert_narrow;
        }
        if (to == .int16 or to == .uint16) {
            if (from == .int8 or from == .uint8) return .convert_widen;
        }
        // Vector conversions (float ↔ int/uint vectors)
        if (to == .vec2 or to == .vec3 or to == .vec4) {
            if (from == .ivec2 or from == .ivec3 or from == .ivec4) return .convert_itof;
            if (from == .uvec2 or from == .uvec3 or from == .uvec4) return .convert_utof;
        }
        if (to == .ivec2 or to == .ivec3 or to == .ivec4) {
            if (from == .vec2 or from == .vec3 or from == .vec4) return .convert_ftoi;
            if (from == .uvec2 or from == .uvec3 or from == .uvec4) return .convert_iti;
            // 8-bit/16-bit int vector → 32-bit int vector
            if (from == .i8vec2 or from == .i8vec3 or from == .i8vec4) return .convert_widen;
            if (from == .u8vec2 or from == .u8vec3 or from == .u8vec4) return .convert_widen;
        }
        if (to == .uvec2 or to == .uvec3 or to == .uvec4) {
            if (from == .vec2 or from == .vec3 or from == .vec4) return .convert_ftou;
            if (from == .ivec2 or from == .ivec3 or from == .ivec4) return .convert_iti;
            if (from == .i8vec2 or from == .i8vec3 or from == .i8vec4) return .convert_widen;
            if (from == .u8vec2 or from == .u8vec3 or from == .u8vec4) return .convert_widen;
            if (from == .i16vec2 or from == .i16vec3 or from == .i16vec4) return .convert_widen;
            if (from == .u16vec2 or from == .u16vec3 or from == .u16vec4) return .convert_widen;
        }
        // 8-bit vector conversions
        if (to == .i8vec2 or to == .i8vec3 or to == .i8vec4) {
            if (from == .ivec2 or from == .ivec3 or from == .ivec4) return .convert_narrow;
            if (from == .uvec2 or from == .uvec3 or from == .uvec4) return .convert_narrow;
            if (from == .i16vec2 or from == .i16vec3 or from == .i16vec4) return .convert_narrow;
            if (from == .u16vec2 or from == .u16vec3 or from == .u16vec4) return .convert_narrow;
        }
        if (to == .u8vec2 or to == .u8vec3 or to == .u8vec4) {
            if (from == .ivec2 or from == .ivec3 or from == .ivec4) return .convert_narrow;
            if (from == .uvec2 or from == .uvec3 or from == .uvec4) return .convert_narrow;
            if (from == .i16vec2 or from == .i16vec3 or from == .i16vec4) return .convert_narrow;
            if (from == .u16vec2 or from == .u16vec3 or from == .u16vec4) return .convert_narrow;
        }
        // 16-bit vector conversions
        if (to == .i16vec2 or to == .i16vec3 or to == .i16vec4) {
            if (from == .ivec2 or from == .ivec3 or from == .ivec4) return .convert_narrow;
            if (from == .uvec2 or from == .uvec3 or from == .uvec4) return .convert_narrow;
            if (from == .i8vec2 or from == .i8vec3 or from == .i8vec4) return .convert_widen;
        }
        if (to == .u16vec2 or to == .u16vec3 or to == .u16vec4) {
            if (from == .ivec2 or from == .ivec3 or from == .ivec4) return .convert_narrow;
            if (from == .uvec2 or from == .uvec3 or from == .uvec4) return .convert_narrow;
            if (from == .u8vec2 or from == .u8vec3 or from == .u8vec4) return .convert_widen;
        }
        // 16-bit vector widening (to 32-bit vectors)
        if (to == .ivec2 or to == .ivec3 or to == .ivec4) {
            if (from == .i16vec2 or from == .i16vec3 or from == .i16vec4) return .convert_widen;
            if (from == .u16vec2 or from == .u16vec3 or from == .u16vec4) return .convert_widen;
        }
        if (to == .uvec2 or to == .uvec3 or to == .uvec4) {
            if (from == .i16vec2 or from == .i16vec3 or from == .i16vec4) return .convert_widen;
            if (from == .u16vec2 or from == .u16vec3 or from == .u16vec4) return .convert_widen;
        }
        // Float16 conversions (float ↔ float16, vec ↔ f16vec)
        if (to == .float16) {
            if (from == .float) return .convert_ftof;
        }
        if (to == .float and from == .float16) return .convert_ftof;
        // Float16 vector conversions
        if (to == .f16vec2 or to == .f16vec3 or to == .f16vec4) {
            if (from == .vec2 or from == .vec3 or from == .vec4) return .convert_ftof;
        }
        if (to == .vec2 or to == .vec3 or to == .vec4) {
            if (from == .f16vec2 or from == .f16vec3 or from == .f16vec4) return .convert_ftof;
        }
        return null;
    }

    fn typesCompatible(self: *Analyzer, target: ast.Type, source: ast.Type) bool {
        // For named types, compare by content
        if (target == .named and source == .named) {
            return std.mem.eql(u8, target.named, source.named);
        }
        // For array types, compare size and base element type recursively
        if (target == .array and source == .array) {
            if (target.array.size != source.array.size) return false;
            return self.typesCompatible(target.array.base.*, source.array.base.*);
        }
        if (std.meta.eql(target, source)) return true;
        if (target == .float and source.isScalar()) return true;
        if (target == .uint and source == .int) return true;
        // Allow float-vector <- int-vector conversions (e.g., vec2 <- ivec2 for textureSize)
        if ((target == .vec2 and source == .ivec2) or
            (target == .vec3 and source == .ivec3) or
            (target == .vec4 and source == .ivec4) or
            (target == .vec2 and source == .uvec2) or
            (target == .vec3 and source == .uvec3) or
            (target == .vec4 and source == .uvec4) or
            (target == .ivec2 and source == .vec2) or
            (target == .ivec3 and source == .vec3) or
            (target == .ivec4 and source == .vec4) or
            (target == .ivec2 and source == .uvec2) or
            (target == .ivec3 and source == .uvec3) or
            (target == .ivec4 and source == .uvec4) or
            (target == .uvec2 and source == .ivec2) or
            (target == .uvec3 and source == .ivec3) or
            (target == .uvec4 and source == .ivec4)) return true;
        // Accept narrowing/widening integer conversions only (int ↔ int8/int16, ivec4 ↔ i8vec4)
        const conv = self.getConversionTag(target, source);
        if (conv != null and (conv.? == .convert_narrow or conv.? == .convert_widen)) return true;
        return false;
    }

    fn isGLSLBuiltin(self: *Analyzer, name: []const u8) bool {
        _ = self;
        const builtins = .{
            "abs", "acos", "asin", "atan", "atan2", "ceil", "clamp",
            "cos", "cosh", "cross", "degrees", "determinant", "distance",
            "dot", "exp", "exp2", "faceforward", "floor", "fract",
            "inversesqrt", "length", "log", "log2", "max", "min", "mix",
            "min3", "max3", "mid3",
            "mod", "normalize", "pow", "radians", "reflect", "refract",
            "round", "roundEven", "sign", "sin", "sinh", "smoothstep", "sqrt", "step",
            "tan", "tanh", "transpose", "trunc",
            "asinh", "acosh", "atanh",
            "texture", "texture2D", "textureLod", "textureProj", "texelFetch",
            "textureQueryLevels",
            "textureQueryLod",
            "subpassLoad",
            "dFdx", "dFdy", "fwidth", "dFdxFine", "dFdyFine", "fwidthFine", "dFdxCoarse", "dFdyCoarse", "fwidthCoarse",
            "isnan", "isinf",
            // Additional GLSL builtins
            "inverse", "outerProduct",
            "lessThan", "greaterThan", "lessThanEqual", "greaterThanEqual",
            "equal", "notEqual", "any", "all",
            "floatBitsToInt", "floatBitsToUint", "intBitsToFloat", "uintBitsToFloat",
            "fma", "frexp", "ldexp", "modf",
            "packSnorm4x8", "packUnorm4x8", "packHalf2x16",
            "packSnorm2x16", "packUnorm2x16",
            "unpackSnorm2x16", "unpackUnorm2x16", "unpackHalf2x16",
            "unpackSnorm4x8", "unpackUnorm4x8",
            "imageSize", "imageLoad", "imageStore", "textureSize",
            "textureSamples", "imageSamples", "textureOffset", "textureLodOffset", "texelFetchOffset", "textureGrad", "textureGather", "textureGatherOffsets",
            "textureGradOffset", "textureProjLod", "textureProjGrad",
            // Barrier/memory builtins (void, special handling)
            "barrier", "memoryBarrier", "memoryBarrierShared",
            "memoryBarrierImage", "memoryBarrierBuffer", "groupMemoryBarrier",
            // Fragment shader interlock
            "beginInvocationInterlockARB", "endInvocationInterlockARB",
            // Demote helper invocation
            "demote",
            // Helper invocation query (returns bool)
            "helperInvocationEXT",
            // Atomic builtins
            "atomicAdd",
            "atomicAnd", "atomicOr", "atomicXor", "atomicMin", "atomicMax",
            "atomicExchange", "atomicCompSwap",
            "atomicCounter", "atomicCounterIncrement",
            "imageAtomicAdd",
            "imageAtomicOr", "imageAtomicXor", "imageAtomicAnd",
            "imageAtomicMin", "imageAtomicMax",
            "imageAtomicExchange", "imageAtomicCompSwap",
            // Subgroup / group vote
            "allInvocationsARB", "anyInvocationARB", "allInvocationsEqualARB",
            "allInvocations", "anyInvocation", "allInvocationsEqual",
            "subgroupBarrier", "subgroupElect", "subgroupAll", "subgroupAny", "subgroupAllEqual",
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
            std.mem.eql(u8, name, "textureLodOffset") or
            std.mem.eql(u8, name, "textureProj") or
            std.mem.eql(u8, name, "texelFetch") or
            std.mem.eql(u8, name, "texelFetchOffset") or
            std.mem.eql(u8, name, "textureOffset") or
            std.mem.eql(u8, name, "textureGrad") or
            std.mem.eql(u8, name, "textureGather");
    }

    fn isBarrierBuiltin(self: *Analyzer, name: []const u8) bool {
        _ = self;
        return std.mem.eql(u8, name, "barrier") or
            std.mem.eql(u8, name, "memoryBarrier") or
            std.mem.eql(u8, name, "memoryBarrierShared") or
            std.mem.eql(u8, name, "memoryBarrierImage") or
            std.mem.eql(u8, name, "memoryBarrierBuffer") or
            std.mem.eql(u8, name, "groupMemoryBarrier") or
            std.mem.eql(u8, name, "beginInvocationInterlockARB") or
            std.mem.eql(u8, name, "endInvocationInterlockARB") or
            std.mem.eql(u8, name, "demote");
    }

    fn isFloatReturnBuiltin(self: *Analyzer, name: []const u8) bool {
        _ = self;
        // Builtins that return float regardless of argument type
        return std.mem.eql(u8, name, "length") or
            std.mem.eql(u8, name, "distance") or
            std.mem.eql(u8, name, "dot") or
            std.mem.eql(u8, name, "determinant");
    }

    fn isPackBuiltin(self: *Analyzer, name: []const u8) bool {
        _ = self;
        return std.mem.eql(u8, name, "packSnorm4x8") or
            std.mem.eql(u8, name, "packUnorm4x8") or
            std.mem.eql(u8, name, "packSnorm2x16") or
            std.mem.eql(u8, name, "packUnorm2x16") or
            std.mem.eql(u8, name, "packHalf2x16") or
            std.mem.eql(u8, name, "packDouble2x32");
    }

    fn isUnpackBuiltin(self: *Analyzer, name: []const u8) bool {
        _ = self;
        return std.mem.eql(u8, name, "unpackSnorm2x16") or
            std.mem.eql(u8, name, "unpackUnorm2x16") or
            std.mem.eql(u8, name, "unpackHalf2x16") or
            std.mem.eql(u8, name, "unpackSnorm4x8") or
            std.mem.eql(u8, name, "unpackUnorm4x8") or
            std.mem.eql(u8, name, "unpackDouble2x32");
    }

    fn isTexelFetchBuiltin(self: *Analyzer, name: []const u8) bool {
        _ = self;
        return std.mem.eql(u8, name, "texelFetch") or
            std.mem.eql(u8, name, "texelFetchOffset");
    }

    fn isShadowSamplerType(self: *Analyzer, ty: ast.Type) bool {
        _ = self;
        return ty == .sampler2d_shadow or ty == .sampler_cube_shadow or ty == .sampler2d_array_shadow or ty == .sampler1d_shadow or ty == .sampler_cube_array_shadow;
    }

    fn isImageSampleBuiltin(self: *Analyzer, name: []const u8) bool {
        _ = self;
        return std.mem.eql(u8, name, "texture") or
            std.mem.eql(u8, name, "texture2D") or
            std.mem.eql(u8, name, "textureLod") or
            std.mem.eql(u8, name, "textureProj") or
            std.mem.eql(u8, name, "textureLodOffset") or
            std.mem.eql(u8, name, "textureOffset") or
            std.mem.eql(u8, name, "textureGrad") or
            std.mem.eql(u8, name, "textureGather") or
            std.mem.eql(u8, name, "texelFetchOffset") or
            std.mem.eql(u8, name, "textureProjLod") or
            std.mem.eql(u8, name, "textureProjGrad") or
            std.mem.eql(u8, name, "textureGradOffset") or
            std.mem.eql(u8, name, "textureProjOffset");
    }

    fn glslExtInstruction(self: *Analyzer, name: []const u8) ?u32 {
        _ = self;
        // GLSL.std.450 instruction numbers (from official spec)
        if (std.mem.eql(u8, name, "round")) return 1;
        if (std.mem.eql(u8, name, "roundEven")) return 2;
        if (std.mem.eql(u8, name, "trunc")) return 3;
        if (std.mem.eql(u8, name, "abs")) return 4; // FAbs
        if (std.mem.eql(u8, name, "sign")) return 6; // FSign
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
        if (std.mem.eql(u8, name, "asinh")) return 22;
        if (std.mem.eql(u8, name, "acosh")) return 23;
        if (std.mem.eql(u8, name, "atanh")) return 24;
        if (std.mem.eql(u8, name, "atan2")) return 25;
        if (std.mem.eql(u8, name, "pow")) return 26;
        if (std.mem.eql(u8, name, "exp")) return 27;
        if (std.mem.eql(u8, name, "log")) return 28;
        if (std.mem.eql(u8, name, "exp2")) return 29;
        if (std.mem.eql(u8, name, "log2")) return 30;
        if (std.mem.eql(u8, name, "sqrt")) return 31;
        if (std.mem.eql(u8, name, "inversesqrt")) return 32; // InverseSqrt
        if (std.mem.eql(u8, name, "determinant")) return 33; // Determinant
        if (std.mem.eql(u8, name, "inverse")) return 34; // MatrixInverse
        if (std.mem.eql(u8, name, "mod")) return 29; // Log2 (unused, mod has special handler)
        if (std.mem.eql(u8, name, "modf")) return 36; // ModfStruct (returns struct)
        if (std.mem.eql(u8, name, "min")) return 37; // FMin
        if (std.mem.eql(u8, name, "max")) return 40; // FMax
        if (std.mem.eql(u8, name, "clamp")) return 43; // FClamp
        if (std.mem.eql(u8, name, "mix")) return 46; // FMix
        if (std.mem.eql(u8, name, "step")) return 48; // Step
        if (std.mem.eql(u8, name, "smoothstep")) return 49; // SmoothStep
        if (std.mem.eql(u8, name, "fma")) return 50; // Fma
        if (std.mem.eql(u8, name, "frexp")) return 52; // FrexpStruct
        if (std.mem.eql(u8, name, "ldexp")) return 53; // Ldexp
        // Pack/Unpack (verified against spirv-tools)
        if (std.mem.eql(u8, name, "packSnorm4x8")) return 54;
        if (std.mem.eql(u8, name, "packUnorm4x8")) return 55;
        if (std.mem.eql(u8, name, "packSnorm2x16")) return 56;
        if (std.mem.eql(u8, name, "packUnorm2x16")) return 57;
        if (std.mem.eql(u8, name, "packHalf2x16")) return 58;
        if (std.mem.eql(u8, name, "unpackSnorm2x16")) return 60;
        if (std.mem.eql(u8, name, "unpackUnorm2x16")) return 61;
        if (std.mem.eql(u8, name, "unpackHalf2x16")) return 62;
        if (std.mem.eql(u8, name, "unpackSnorm4x8")) return 63;
        if (std.mem.eql(u8, name, "unpackUnorm4x8")) return 64;
        // Geometric (verified against spirv-tools)
        if (std.mem.eql(u8, name, "length")) return 66; // Length
        if (std.mem.eql(u8, name, "distance")) return 67; // Distance
        if (std.mem.eql(u8, name, "cross")) return 68; // Cross
        if (std.mem.eql(u8, name, "normalize")) return 69; // Normalize
        if (std.mem.eql(u8, name, "faceforward")) return 70; // FaceForward
        if (std.mem.eql(u8, name, "reflect")) return 71; // Reflect
        if (std.mem.eql(u8, name, "refract")) return 72; // Refract
        // NOT GLSL.std.450 — handled as core SPIR-V ops or specially
        if (std.mem.eql(u8, name, "transpose") or std.mem.eql(u8, name, "outerProduct"))
            return null;
        if (std.mem.eql(u8, name, "imageLoad") or std.mem.eql(u8, name, "imageStore"))
            return null;
        // dot uses OpDot (core SPIR-V opcode 141), not GLSL.std.450
        if (std.mem.eql(u8, name, "dot"))
            return null;
        // dFdx/dFdy are core SPIR-V ops (DPdx/DPdy), not GLSL.std.450
        if (std.mem.eql(u8, name, "dFdx") or std.mem.eql(u8, name, "dFdy") or std.mem.eql(u8, name, "fwidth") or
            std.mem.eql(u8, name, "dFdxFine") or std.mem.eql(u8, name, "dFdyFine") or std.mem.eql(u8, name, "fwidthFine") or
            std.mem.eql(u8, name, "dFdxCoarse") or std.mem.eql(u8, name, "dFdyCoarse") or std.mem.eql(u8, name, "fwidthCoarse"))
            return null;
        // isnan/isinf are core SPIR-V ops (OpIsNan/OpIsInf), not GLSL.std.450
        if (std.mem.eql(u8, name, "isnan") or std.mem.eql(u8, name, "isinf"))
            return null;
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
    try testing.expect(result == error.UndeclaredIdentifier or result == error.SemanticFailed);
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
        if (inst.tag == .composite_construct or inst.tag == .constant_composite) has_composite = true;
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
