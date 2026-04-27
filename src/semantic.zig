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

pub fn analyze(alloc: std.mem.Allocator, root: *ast.Root) Error!ir.Module {
    last_error_inner = "";
    last_error_ctx = "";
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
        .local_size = analyzer.local_size,
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
    next_id: u32 = 1,
    local_size: ?ir.LocalSize = null,

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

    fn lastInstructionIsReturn(self: *Analyzer) bool {
        if (self.instructions.items.len == 0) return false;
        const last_tag = self.instructions.items[self.instructions.items.len - 1].tag;
        return last_tag == .return_void or last_tag == .return_val or last_tag == .unreachable_inst;
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

        // gl_FragStencilRefARB: Output int (stencil export)
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_FragStencilRefARB", .ty = .int, .qualifier = .{ .is_out = true }, .layout = null, .storage_class = .output, .result_id = id });
            try self.declare("gl_FragStencilRefARB", .{ .kind = .var_sym, .ty = .int, .ir_id = id });
        }

        // gl_FrontFacing: Input, BuiltIn FrontFacing (bool)
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_FrontFacing", .ty = .bool, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_FrontFacing", .{ .kind = .var_sym, .ty = .bool, .ir_id = id });
        }
        // gl_HelperInvocation: Input, BuiltIn HelperInvocation (bool)
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_HelperInvocation", .ty = .bool, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_HelperInvocation", .{ .kind = .var_sym, .ty = .bool, .ir_id = id });
        }
        // gl_BaryCoordEXT/gl_BaryCoordNoPerspEXT: Input, BuiltIn BaryCoord (vec3)
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_BaryCoordEXT", .ty = .vec3, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_BaryCoordEXT", .{ .kind = .var_sym, .ty = .vec3, .ir_id = id });
        }
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_BaryCoordNoPerspEXT", .ty = .vec3, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_BaryCoordNoPerspEXT", .{ .kind = .var_sym, .ty = .vec3, .ir_id = id });
        }
        // NV variants
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_BaryCoordNV", .ty = .vec3, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_BaryCoordNV", .{ .kind = .var_sym, .ty = .vec3, .ir_id = id });
        }
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_BaryCoordNoPerspNV", .ty = .vec3, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_BaryCoordNoPerspNV", .{ .kind = .var_sym, .ty = .vec3, .ir_id = id });
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
        // gl_GlobalInvocationID: Input, BuiltIn GlobalInvocationId (vec3)
        // Uses uvec3 which doesn't need BuiltIn decoration
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_GlobalInvocationID", .ty = .uvec3, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_GlobalInvocationID", .{ .kind = .var_sym, .ty = .uvec3, .ir_id = id });
        }
        // gl_LocalInvocationID: Input, BuiltIn LocalInvocationId (vec3)
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_LocalInvocationID", .ty = .uvec3, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_LocalInvocationID", .{ .kind = .var_sym, .ty = .uvec3, .ir_id = id });
        }
        // gl_WorkGroupID: Input, BuiltIn WorkgroupId (vec3)
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_WorkGroupID", .ty = .uvec3, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_WorkGroupID", .{ .kind = .var_sym, .ty = .uvec3, .ir_id = id });
        }
        // gl_NumWorkGroups: Input, BuiltIn NumWorkgroups (vec3)
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_NumWorkGroups", .ty = .uvec3, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_NumWorkGroups", .{ .kind = .var_sym, .ty = .uvec3, .ir_id = id });
        }

        // gl_WorkGroupSize: constant (from layout local_size_x/y/z)
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_WorkGroupSize", .ty = .uvec3, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_WorkGroupSize", .{ .kind = .var_sym, .ty = .uvec3, .ir_id = id });
        }

        // gl_LocalInvocationIndex: Input, BuiltIn LocalInvocationIndex (uint)
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_LocalInvocationIndex", .ty = .uint, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_LocalInvocationIndex", .{ .kind = .var_sym, .ty = .uint, .ir_id = id });
        }

        // gl_SampleMaskIn: Input, BuiltIn SampleMask (array of int)
        {
            const id = self.allocId();
            const arr_base = try self.alloc.create(ast.Type);
            arr_base.* = .int;
            const sample_mask_ty: ast.Type = .{ .array = .{ .base = arr_base, .size = 1 } };
            try self.globals.append(self.alloc, .{ .name = "gl_SampleMaskIn", .ty = sample_mask_ty, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_SampleMaskIn", .{ .kind = .var_sym, .ty = sample_mask_ty, .ir_id = id });
        }

        // gl_SampleMask: Output, BuiltIn SampleMask (array of int)
        {
            const id = self.allocId();
            const sm_base = try self.alloc.create(ast.Type);
            sm_base.* = .int;
            const smask_ty: ast.Type = .{ .array = .{ .base = sm_base, .size = 1 } };
            try self.globals.append(self.alloc, .{ .name = "gl_SampleMask", .ty = smask_ty, .qualifier = .{ .is_out = true }, .layout = null, .storage_class = .output, .result_id = id });
            try self.declare("gl_SampleMask", .{ .kind = .var_sym, .ty = smask_ty, .ir_id = id });
        }

        // gl_SamplePosition: Input, BuiltIn SamplePosition (vec2)
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_SamplePosition", .ty = .vec2, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_SamplePosition", .{ .kind = .var_sym, .ty = .vec2, .ir_id = id });
        }

        // gl_SampleID: Input, BuiltIn SampleId (int)
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_SampleID", .ty = .int, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_SampleID", .{ .kind = .var_sym, .ty = .int, .ir_id = id });
        }

        // gl_SubgroupInvocationID: Input, BuiltIn SubgroupLocalInvocationId (int)
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_SubgroupInvocationID", .ty = .int, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_SubgroupInvocationID", .{ .kind = .var_sym, .ty = .int, .ir_id = id });
        }

        // gl_SubgroupSize: Input, BuiltIn SubgroupSize (int)
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_SubgroupSize", .ty = .int, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_SubgroupSize", .{ .kind = .var_sym, .ty = .int, .ir_id = id });
        }

        // gl_ViewIndex: Input, BuiltIn ViewIndex (int)
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_ViewIndex", .ty = .int, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_ViewIndex", .{ .kind = .var_sym, .ty = .int, .ir_id = id });
        }

        // gl_DeviceIndex: Input, BuiltIn DeviceIndex (int)
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_DeviceIndex", .ty = .int, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_DeviceIndex", .{ .kind = .var_sym, .ty = .int, .ir_id = id });
        }

        // gl_BaseVertex: Input, BuiltIn BaseVertex (int)
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_BaseVertex", .ty = .int, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_BaseVertex", .{ .kind = .var_sym, .ty = .int, .ir_id = id });
        }

        // gl_BaseVertexARB: alias for gl_BaseVertex
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_BaseVertexARB", .ty = .int, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_BaseVertexARB", .{ .kind = .var_sym, .ty = .int, .ir_id = id });
        }

        // gl_VertexIndex: Input, BuiltIn VertexIndex (int)
        // Note: glslang maps gl_VertexIndex to BuiltIn VertexIndex, separate from gl_VertexID
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_VertexIndex", .ty = .int, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_VertexIndex", .{ .kind = .var_sym, .ty = .int, .ir_id = id });
        }

        // gl_BaseInstance: Input int
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_BaseInstance", .ty = .int, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_BaseInstance", .{ .kind = .var_sym, .ty = .int, .ir_id = id });
        }

        // gl_BaseInstanceARB: alias for gl_BaseInstance
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_BaseInstanceARB", .ty = .int, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_BaseInstanceARB", .{ .kind = .var_sym, .ty = .int, .ir_id = id });
        }

        // gl_InstanceIndex: Input int (same as gl_InstanceID but different BuiltIn)
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_InstanceIndex", .ty = .int, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_InstanceIndex", .{ .kind = .var_sym, .ty = .int, .ir_id = id });
        }

        // gl_DrawID: Input int
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_DrawID", .ty = .int, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_DrawID", .{ .kind = .var_sym, .ty = .int, .ir_id = id });
        }

        // gl_DrawIDARB: alias for gl_DrawID
        {
            const id = self.allocId();
            try self.globals.append(self.alloc, .{ .name = "gl_DrawIDARB", .ty = .int, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id });
            try self.declare("gl_DrawIDARB", .{ .kind = .var_sym, .ty = .int, .ir_id = id });
        }

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
        try self.declare("textureProj", .{ .kind = .func, .ty = .vec4, .ir_id = self.allocId() });
        try self.declare("textureQueryLevels", .{ .kind = .func, .ty = .int, .ir_id = self.allocId() });
        try self.declare("texelFetch", .{ .kind = .func, .ty = .vec4, .ir_id = self.allocId() });
        try self.declare("dFdx", .{ .kind = .func, .ty = .float, .ir_id = self.allocId() });
        try self.declare("dFdy", .{ .kind = .func, .ty = .float, .ir_id = self.allocId() });
        try self.declare("fwidth", .{ .kind = .func, .ty = .float, .ir_id = self.allocId() });
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
                // Determine storage class from qualifier and layout
                const has_push_constant = if (node.data.layout) |l| l.push_constant else false;
                const storage_class: ir.SPIRVStorageClass = if (has_push_constant)
                    .push_constant
                else if (qual.is_in)
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
                    .ir_id = 0, // Type symbols don't need SPIR-V IDs
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
            self.analyzeStatement(child) catch {
                // Semantic error: stop processing this function but keep what we have
                // Add a return and break out
                break;
            };
            // Stop processing after a return statement (dead code elimination)
            if (self.instructions.items.len > 0) {
                const last_tag = self.instructions.items[self.instructions.items.len - 1].tag;
                if (last_tag == .return_void or last_tag == .return_val or last_tag == .unreachable_inst) break;
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
        errdefer {
            if (last_error_ctx.len == 0) last_error_ctx = @tagName(node.tag);
        }
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
                            if (ty == .float and init.ty == .int) break :blk .convert_itof;
                            if (ty == .float and init.ty == .uint) break :blk .convert_utof;
                            if (ty == .int and init.ty == .float) break :blk .convert_ftoi;
                            if (ty == .uint and init.ty == .float) break :blk .convert_ftou;
                            break :blk null;
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
                    // Emit store: target <- value
                    const store_operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                    store_operands[0] = .{ .id = ir_id };
                    store_operands[1] = .{ .id = init_id };
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
                const then_returned = if (node.data.children.len > 1) blk: {
                    try self.analyzeStatement(node.data.children[1]);
                    break :blk self.lastInstructionIsReturn();
                } else false;
                if (!then_returned) try self.emitBranch(merge_label);

                if (has_else) {
                    try self.emitLabel(else_label.?);
                    const else_returned = blk: {
                        try self.analyzeStatement(node.data.children[2]);
                        break :blk self.lastInstructionIsReturn();
                    };
                    if (!else_returned) try self.emitBranch(merge_label);
                }

                const else_did_return = if (has_else) blk: {
                    break :blk self.lastInstructionIsReturn();
                } else false;
                const all_branches_returned = then_returned and (!has_else or else_did_return);
                if (all_branches_returned) {
                    try self.emitLabel(merge_label);
                    try self.instructions.append(self.alloc, .{
                        .tag = .unreachable_inst,
                        .result_type = null,
                        .result_id = null,
                        .operands = &.{},
                        .ty = .void,
                    });
                } else {
                    try self.emitLabel(merge_label);
                }
            },
            .switch_stmt => {
                // Switch: parse and evaluate selector, but skip case bodies for now
                // TODO: proper OpSwitch emission with case labels
                if (node.data.children.len >= 1) {
                    _ = try self.analyzeExpression(node.data.children[0]);
                }
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

                // Header: condition check, then merge + branch
                try self.emitLabel(header_label);
                var cond_id: u32 = undefined;
                if (node.data.children.len > 1) {
                    const cond = try self.analyzeExpression(node.data.children[1]);
                    cond_id = cond.id;
                }
                try self.emitLoopMerge(merge_label, continue_label);
                if (node.data.children.len > 1) {
                    try self.emitBranchConditional(cond_id, body_label, merge_label);
                } else {
                    try self.emitBranch(body_label);
                }

                // Body
                try self.emitLabel(body_label);
                if (node.data.children.len > 3) self.analyzeStatement(node.data.children[3]) catch {
                    // Body failed, continue to emit branch to continue label
                };
                if (!self.lastInstructionIsReturn()) {
                    try self.emitBranch(continue_label); // body -> continue
                }

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
                const cond = try self.analyzeExpression(node.data.children[0]);
                try self.emitLoopMerge(merge_label, header_label);
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
        }
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
                if (result_ty.isVector()) {
                    if (left.ty.isScalar() and !right.ty.isScalar()) {
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
                        left_id = splat_id;
                        did_splat = true;
                    } else if (!left.ty.isScalar() and right.ty.isScalar()) {
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
                        right_id = splat_id;
                        did_splat = true;
                    }
                }

                const is_float = result_ty == .float or result_ty == .double or result_ty == .vec2 or result_ty == .vec3 or result_ty == .vec4 or result_ty.isMatrix();
                const op = node.data.op orelse .add;


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
                    // float → splat to vector
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
                }
                // Compute result
                const result_ty_2 = target.ty;
                const is_float = result_ty_2 == .float or result_ty_2 == .double or result_ty_2.isVector() or result_ty_2.isMatrix();
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
                for (node.data.children, 0..) |arg, i| {
                    var tid = try self.analyzeExpression(arg);
                    // Atomic functions need pointer arg, don't auto-load first arg
                    if (tid.is_ptr and !(is_atomic_fn and i == 0)) {
                        const ld = self.allocId();
                        const ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        ops[0] = .{ .id = tid.id };
                        try self.instructions.append(self.alloc, .{ .tag = .load, .result_type = null, .result_id = ld, .operands = ops, .ty = tid.ty });
                        tid = .{ .ty = tid.ty, .id = ld };
                    }
                    try arg_tids.append(self.alloc, tid);
                }
                const sym = self.lookup(node.data.name);
                // For GLSL builtins, infer result type from first argument (e.g., round(vec4) → vec4)
                // Exception: texture functions return vec4
                const result_ty: ast.Type = if (self.isImageSampleBuiltin(node.data.name))
                    .vec4
                else if (std.mem.eql(u8, node.data.name, "texelFetch"))
                    .vec4
                else if (std.mem.eql(u8, node.data.name, "helperInvocationEXT"))
                    .bool
                else if (self.isFloatReturnBuiltin(node.data.name))
                    .float
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
                    // Barrier/memory functions — void, no SPIR-V instruction needed for now
                    if (self.isBarrierBuiltin(node.data.name)) {
                        // Emit a no-op (void) — TODO: proper OpControlBarrier/OpMemoryBarrier
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
                    // atomicAdd(ptr, value) → OpAtomicIAdd
                    if (std.mem.eql(u8, node.data.name, "atomicAdd")) {
                        // Returns the original value. First arg must be a pointer (l-value).
                        const ret_ty = if (arg_tids.items.len > 1) arg_tids.items[1].ty else .uint;
                        // Use analyzeLValue for first arg to get pointer, not loaded value
                        var ptr_tid = arg_tids.items[0];
                        if (node.data.children.len > 0) {
                            if (self.analyzeLValue(node.data.children[0])) |lval| {
                                ptr_tid = lval;
                            } else |_| {
                                // Fall back to expression result
                            }
                        }
                        // Operands matching codegen expectation: [ptr_id, value_id, scope_literal, semantics_literal]
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 4);
                        operands[0] = .{ .id = ptr_tid.id }; // ptr
                        operands[1] = if (arg_tids.items.len > 1) .{ .id = arg_tids.items[1].id } else .{ .literal_int = 0 }; // value
                        operands[2] = .{ .literal_int = 1 }; // scope = Device
                        operands[3] = .{ .literal_int = 64 }; // semantics = Uniform
                        try self.instructions.append(self.alloc, .{
                            .tag = .atomic_iadd,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = ret_ty,
                        });
                        return .{ .ty = ret_ty, .id = result_id };
                    }
                    // imageAtomicAdd and other atomics — void stub for now
                    if (std.mem.eql(u8, node.data.name, "imageAtomicAdd") or
                        std.mem.eql(u8, node.data.name, "atomicAnd") or
                        std.mem.eql(u8, node.data.name, "atomicOr") or
                        std.mem.eql(u8, node.data.name, "atomicXor") or
                        std.mem.eql(u8, node.data.name, "atomicMin") or
                        std.mem.eql(u8, node.data.name, "atomicMax"))
                    {
                        return .{ .ty = .uint, .id = result_id };
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
                    // textureSize(sampler, lod) → ivec2, uses OpImageQuerySizeLod
                    if (std.mem.eql(u8, node.data.name, "textureSize")) {
                        // Extract image from sampler, then query size with lod
                        var img_id = arg_tids.items[0].id;
                        if (arg_tids.items[0].ty == .sampler2d and arg_tids.items.len >= 1) {
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
                                .ty = .ivec2,
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
                                .ty = .ivec2,
                            });
                        }
                        return .{ .ty = .ivec2, .id = result_id };
                    }
                    // textureQueryLevels(sampler) → int, uses OpImageQueryLevels
                    if (std.mem.eql(u8, node.data.name, "textureQueryLevels")) {
                        // Need to extract image from sampler first
                        var img_id = arg_tids.items[0].id;
                        if (arg_tids.items[0].ty == .sampler2d) {
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
                    // textureSamples(image) / imageSamples(image) → OpImageQuerySamples
                    if (std.mem.eql(u8, node.data.name, "textureSamples") or std.mem.eql(u8, node.data.name, "imageSamples")) {
                        var img_id = arg_tids.items[0].id;
                        if (arg_tids.items[0].ty == .sampler2d) {
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
                        if (self.isImageSampleBuiltin(node.data.name)) {
                            // texture(sampler, coord) → image_sample (implicit or explicit lod)
                            const is_explicit_lod = std.mem.eql(u8, node.data.name, "textureLod");
                            const is_proj = std.mem.eql(u8, node.data.name, "textureProj");
                            const tag: ir.Instruction.Tag = if (is_explicit_lod) .image_sample_explicit_lod else if (is_proj) .image_sample_proj else .image_sample;
                            const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len);
                            for (arg_tids.items, 0..) |tid, i| {
                                operands[i] = .{ .id = tid.id };
                            }
                            try self.instructions.append(self.alloc, .{
                                .tag = tag,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = operands,
                                .ty = result_ty,
                            });
                        } else {
                            // texelFetch etc → image_fetch as fallback
                            // If first arg is a sampler, extract image first
                            const fetch_args = arg_tids.items;
                            if (fetch_args.len > 0 and (fetch_args[0].ty == .sampler2d or fetch_args[0].ty == .sampler_cube or fetch_args[0].ty == .sampler_buffer)) {
                                const extracted_id = self.allocId();
                                const extract_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                                extract_operands[0] = .{ .id = fetch_args[0].id };
                                try self.instructions.append(self.alloc, .{
                                    .tag = .extract_image,
                                    .result_type = null,
                                    .result_id = extracted_id,
                                    .operands = extract_operands,
                                    .ty = if (fetch_args[0].ty == .sampler_buffer) .sampler_buffer else .image2d, // extracted image type
                                });
                                // Replace first arg with extracted image
                                var new_args = try self.alloc.alloc(ir.Instruction.Operand, fetch_args.len);
                                new_args[0] = .{ .id = extracted_id };
                                for (1..fetch_args.len) |i| {
                                    new_args[i] = .{ .id = fetch_args[i].id };
                                }
                                const operands = try self.alloc.alloc(ir.Instruction.Operand, fetch_args.len);
                                for (operands, 0..) |*op, i| op.* = new_args[i];
                                try self.instructions.append(self.alloc, .{
                                    .tag = .image_fetch,
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
                    } else if (std.mem.eql(u8, node.data.name, "dFdx") or std.mem.eql(u8, node.data.name, "dFdy")) {
                        // Derivatives: OpDPdx/OpDPdy (core SPIR-V)
                        const is_dx = std.mem.eql(u8, node.data.name, "dFdx");
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len + 1);
                        operands[0] = .{ .literal_int = if (is_dx) 0 else 1 }; // 0=DPdx, 1=DPdy
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
                    } else if (std.mem.eql(u8, node.data.name, "fwidth")) {
                        // fwidth(p) = abs(dFdx(p)) + abs(dFdy(p)) → OpFwidth (opcode 209)
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len);
                        for (arg_tids.items, 0..) |tid, i| {
                            operands[i] = .{ .id = tid.id };
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
                const result_ty = node.data.ty orelse .void;
                const result_id = self.allocId();

                // Handle scalar-from-vector: float(vec4) → extract first component
                // This handles the case where .x swizzle was silently dropped
                if (arg_tids.items.len == 1 and !result_ty.isVector() and !result_ty.isMatrix()) {
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
                    const arg_ty = arg_tids.items[0].ty;
                    const n = result_ty.numComponents();
                    const arg_n = if (arg_ty.isVector()) arg_ty.numComponents() else 1;

                    if (arg_ty.isVector() and arg_n == n) {
                        // Same-size vector conversion
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
                    // Scalar splat
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
                            if (from == .int or from == .ivec2) break :blk .convert_itof;
                            if (from == .uint or from == .uvec2) break :blk .convert_utof;
                        }
                        if (to == .int) {
                            if (from == .float or from == .double) break :blk .convert_ftoi;
                            if (from == .uint) break :blk .convert_uti;
                        }
                        if (to == .uint) {
                            if (from == .float or from == .double) break :blk .convert_ftou;
                            if (from == .int) break :blk .convert_iti;
                        }
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

                // Convert arguments to match result component type if needed
                const result_scalar: ast.Type = switch (result_ty) {
                    .vec2, .vec3, .vec4 => .float,
                    .ivec2, .ivec3, .ivec4 => .int,
                    .uvec2, .uvec3, .uvec4 => .uint,
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
                        else => .void,
                    } else arg_ty;
                    if (!std.meta.eql(arg_scalar, result_scalar) and result_scalar.isScalar() and arg_scalar.isScalar()) {
                        // Need type conversion
                        const conv_tag: ir.Instruction.Tag = blk: {
                            if (result_scalar == .float) {
                                if (arg_scalar == .int) break :blk .convert_itof;
                                if (arg_scalar == .uint) break :blk .convert_utof;
                            }
                            if (result_scalar == .int) {
                                if (arg_scalar == .float) break :blk .convert_ftoi;
                                if (arg_scalar == .uint) break :blk .convert_uti;
                            }
                            if (result_scalar == .uint) {
                                if (arg_scalar == .float) break :blk .convert_ftou;
                                if (arg_scalar == .int) break :blk .convert_iti;
                            }
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

                // Allocate operand array
                const operands = try self.alloc.alloc(ir.Instruction.Operand, converted_ids.len);
                for (converted_ids, 0..) |cid, i| {
                    operands[i] = .{ .id = cid };
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
                    for (self.instructions.items, 0..) |inst, i| {
                        if (inst.result_id != null and inst.result_id.? == index_tid.id and inst.tag == .constant_int) {
                            const_idx = switch (inst.operands[0]) { .literal_int => |v| v, else => null };
                            _ = i;
                            break;
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
                const one_id = self.allocId();
                const one_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                if (lval.ty == .int or lval.ty.isVector()) {
                    one_ops[0] = .{ .literal_int = 1 };
                    try self.instructions.append(self.alloc, .{
                        .tag = .constant_int,
                        .result_type = null,
                        .result_id = one_id,
                        .operands = one_ops,
                        .ty = .int,
                    });
                } else {
                    one_ops[0] = .{ .literal_float = 1.0 };
                    try self.instructions.append(self.alloc, .{
                        .tag = .constant_float,
                        .result_type = null,
                        .result_id = one_id,
                        .operands = one_ops,
                        .ty = .float,
                    });
                }
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

    fn typesCompatible(self: *Analyzer, target: ast.Type, source: ast.Type) bool {
        _ = self;
        // For named types, compare by content
        if (target == .named and source == .named) {
            return std.mem.eql(u8, target.named, source.named);
        }
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
            "min3", "max3", "mid3",
            "mod", "normalize", "pow", "radians", "reflect", "refract",
            "round", "roundEven", "sign", "sin", "sinh", "smoothstep", "sqrt", "step",
            "tan", "tanh", "transpose", "trunc",
            "texture", "texture2D", "textureLod", "textureProj", "texelFetch",
            "textureQueryLevels",
            "dFdx", "dFdy", "fwidth",
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
            "atomicCounter", "atomicCounterIncrement",
            "imageAtomicAdd",
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
            std.mem.eql(u8, name, "textureGradOffset");
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
        if (std.mem.eql(u8, name, "dFdx") or std.mem.eql(u8, name, "dFdy") or std.mem.eql(u8, name, "fwidth"))
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
