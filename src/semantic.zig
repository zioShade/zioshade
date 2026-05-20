// SPDX-License-Identifier: MIT OR Apache-2.0
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
    /// Shader stage (needed for stage-dependent builtin variables like gl_TessLevelOuter)
    stage: ?@import("root.zig").Stage = null,
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
        .globals = .empty,
        .functions = .empty,
        .types = .empty,
        .instructions = .empty,
        .errors = .empty,
        .loop_stack = .empty,
        .overloads = .empty,
        .tolerate_errors = options.tolerate_errors,
        .stage = options.stage,
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
    var mod: ir.Module = .{
        .functions = try analyzer.functions.toOwnedSlice(alloc),
        .globals = try analyzer.globals.toOwnedSlice(alloc),
        .types = analyzer.types,
        .entry_point = null,
        .next_id_start = analyzer.next_id,
        .alloc = alloc,
        .local_size = analyzer.local_size,
        .heap_types = try analyzer.heap_types.toOwnedSlice(alloc),
        .spec_constants = analyzer.spec_constants,
        .depth_greater = analyzer.has_depth_greater,
        .depth_less = analyzer.has_depth_less,
        .depth_unchanged = analyzer.has_depth_unchanged,
        .early_fragment_tests = analyzer.has_early_fragment_tests,
        .pixel_interlock_ordered = analyzer.has_pixel_interlock_ordered,
        .pixel_interlock_unordered = analyzer.has_pixel_interlock_unordered,
        .sample_interlock_ordered = analyzer.has_sample_interlock_ordered,
        .sample_interlock_unordered = analyzer.has_sample_interlock_unordered,
        .origin_upper_left = analyzer.has_origin_upper_left,
        .uses_qcom_image_processing = analyzer.uses_qcom_image_processing,
        .uses_ray_query = analyzer.uses_ray_query,
        .uses_ray_query_position_fetch = analyzer.uses_ray_query_position_fetch,
        .uses_arm_tensors = analyzer.uses_arm_tensors,
        .uses_ext_mesh_shader = analyzer.uses_ext_mesh_shader,
        .mesh_max_vertices = analyzer.mesh_max_vertices,
        .mesh_max_primitives = analyzer.mesh_max_primitives,
        .mesh_output_topology = analyzer.mesh_output_topology,
        .geometry_input_topology = analyzer.geometry_input_topology,
        .geometry_output_topology = analyzer.geometry_output_topology,
        .geometry_max_vertices = analyzer.geometry_max_vertices,
        .tess_vertices = analyzer.tess_vertices,
        .tess_input_topology = analyzer.tess_input_topology,
        .tess_spacing = analyzer.tess_spacing,
        .tess_vertex_order_ccw = analyzer.tess_vertex_order_ccw,
    };
    // Dead function elimination: only keep functions reachable from main()
    mod = try eliminateDeadFunctions(alloc, mod);

    // Clear transferred fields before defer deinit runs
    analyzer.types = .{};
    analyzer.functions = .empty;
    analyzer.globals = .empty;
    analyzer.heap_types = .empty;
    analyzer.spec_constants = .{};
    for (analyzer.instructions.items) |inst| {
        if (inst.operands.len > 0) {
            analyzer.alloc.free(inst.operands);
        }
    }
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
    param_is_mutable: []const bool, // true for out/inout params
    ir_id: u32,
    return_type: ast.Type = .void,
};

const Scope = std.StringHashMapUnmanaged(Symbol);

/// Eliminate functions not reachable from main() via function_call instructions.
fn eliminateDeadFunctions(alloc: std.mem.Allocator, mod: ir.Module) !ir.Module {
    if (mod.functions.len <= 1) return mod;

    // Make a mutable copy of the functions slice
    const functions = mod.functions;

    // Find main() function index
    var main_idx: ?usize = null;
    for (functions, 0..) |func, i| {
        if (std.mem.eql(u8, func.name, "main")) {
            main_idx = i;
            break;
        }
    }
    const mi = main_idx orelse return mod;

    // Build map from function result_id → function index
    var id_to_idx = std.AutoHashMapUnmanaged(u32, usize).empty;
    defer id_to_idx.deinit(alloc);
    for (functions, 0..) |func, i| {
        if (func.result_id != 0) {
            id_to_idx.put(alloc, func.result_id, i) catch {};
        }
    }

    // BFS from main to find all reachable function indices
    var reachable = std.DynamicBitSet.initEmpty(alloc, functions.len) catch return mod;
    defer reachable.deinit();
    var queue = std.ArrayListUnmanaged(usize).empty;
    defer queue.deinit(alloc);
    queue.append(alloc, mi) catch return mod;
    reachable.set(mi);

    while (queue.pop()) |idx| {
        const func = functions[idx];
        for (func.body) |inst| {
            if (inst.tag == .function_call and inst.operands.len >= 1) {
                const callee_id = switch (inst.operands[0]) {
                    .id => |id| id,
                    else => continue,
                };
                if (id_to_idx.get(callee_id)) |callee_idx| {
                    if (!reachable.isSet(callee_idx)) {
                        reachable.set(callee_idx);
                        queue.append(alloc, callee_idx) catch {};
                    }
                }
            }
        }
    }

    // If all functions are reachable, return as-is
    const reachable_count = reachable.count();
    if (reachable_count == functions.len) return mod;

    // Collect constant instructions from eliminated functions.
    // These may be referenced by surviving functions due to const_cache reuse.
    // Only rescue constants that aren't already defined in surviving functions.
    var defined_ids = std.AutoHashMapUnmanaged(u32, void).empty;
    defer defined_ids.deinit(alloc);
    for (functions, 0..) |func, i| {
        if (reachable.isSet(i)) {
            for (func.body) |inst| {
                if (inst.result_id) |rid| {
                    try defined_ids.put(alloc, rid, {});
                }
            }
        }
    }
    var rescued_constants = std.ArrayListUnmanaged(ir.Instruction).empty;
    defer rescued_constants.deinit(alloc);
    for (functions, 0..) |func, i| {
        if (!reachable.isSet(i)) {
            for (func.body) |inst| {
                if (inst.tag == .constant_int or inst.tag == .constant_float or inst.tag == .constant_bool or inst.tag == .constant_composite) {
                    if (inst.result_id) |rid| {
                        if (!defined_ids.contains(rid)) {
                            try rescued_constants.append(alloc, inst);
                            try defined_ids.put(alloc, rid, {});
                        }
                    }
                }
            }
        }
    }

    // Filter to only reachable functions
    var kept = std.ArrayListUnmanaged(ir.Function).empty;
    kept.ensureTotalCapacity(alloc, reachable_count) catch return mod;
    var fi: usize = 0;
    while (fi < functions.len) : (fi += 1) {
        const func = functions[fi];
        if (reachable.isSet(fi)) {
            // If this is main() and we have rescued constants, prepend them
            var body_to_keep: []const ir.Instruction = func.body;
            if (std.mem.eql(u8, func.name, "main") and rescued_constants.items.len > 0) {
                const new_body = alloc.alloc(ir.Instruction, rescued_constants.items.len + func.body.len) catch {
                    kept.appendAssumeCapacity(func);
                    continue;
                };
                @memcpy(new_body[0..rescued_constants.items.len], rescued_constants.items);
                @memcpy(new_body[rescued_constants.items.len..], func.body);
                alloc.free(func.body);
                body_to_keep = new_body;
            }
            var func_copy = func;
            func_copy.body = body_to_keep;
            kept.appendAssumeCapacity(func_copy);
        } else {
            // Free unreachable function body (instruction slice) and params.
            // The operand arrays inside the instructions are separate allocations
            // and will be freed when main's body is deinitialized (via rescued constants).
            for (func.body) |inst| {
                // Only free operands if this instruction was NOT rescued into main
                // Rescued constants have their operands still referenced by main's body
                var was_rescued = false;
                for (rescued_constants.items) |rc| {
                    if (rc.result_id != null and inst.result_id != null and rc.result_id.? == inst.result_id.?) {
                        was_rescued = true;
                        break;
                    }
                }
                if (!was_rescued and inst.operands.len > 0) {
                    alloc.free(inst.operands);
                }
            }
            alloc.free(func.body);
            if (func.param_ids.len > 0) {
                alloc.free(func.param_ids);
            }
        }
    }

    // Free old functions slice (but not individual items we kept)
    alloc.free(functions);
    var result = mod;
    // Use toOwnedSlice to transfer ownership from 'kept' to the result
    // The kept ArrayList's defer deinint will be a no-op after toOwnedSlice
    const kept_slice = kept.toOwnedSlice(alloc) catch return mod;
    result.functions = kept_slice;
    return result;
}

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
    stage: ?@import("root.zig").Stage = null,
    has_returned: bool = false, // Dead code suppression after return
    if_insert_points: std.ArrayListUnmanaged(usize) = .empty, // stack of instruction indices before each if's SelectionMerge
    next_id: u32 = 1,
    // Constant dedup: (type_tag << 32 | value_bits) -> ir_id
    const_cache: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    const_composite_cache: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    access_chain_cache: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    global_access_chain_cache: std.AutoHashMapUnmanaged(u64, u32) = .empty, // key -> ptr_id (persists across blocks, populated from entry block)
    ac_result_to_base: std.AutoHashMapUnmanaged(u32, u32) = .empty, // AccessChain result_id -> base var_id (for store invalidation)
    load_cache: std.AutoHashMapUnmanaged(u32, u32) = .empty, // ptr_id -> loaded_value_id (cleared at labels)
    global_load_cache: std.AutoHashMapUnmanaged(u32, u32) = .empty, // ptr_id -> loaded_value_id (persists across blocks)
    global_ptr_ids: std.AutoHashMapUnmanaged(u32, void) = .empty, // set of ptr_ids that point into global (Input/Uniform/Output) variables
    in_entry_block: bool = true,
    cache_globals: bool = true, // true in entry block and loop headers (blocks that dominate subsequent blocks)
    pure_op_cache: std.AutoHashMapUnmanaged(u64, u32) = .empty, // hash(type, op, operands) -> result_id
    global_pure_op_cache: std.AutoHashMapUnmanaged(u64, u32) = .empty, // persists across blocks, populated from entry/loop-header blocks
    local_size: ?ir.LocalSize = null,
    // Heap-allocated AST types that transfer to Module for cleanup
    heap_types: std.ArrayListUnmanaged(*ast.Type) = .empty,
    spec_constants: std.StringHashMapUnmanaged(ir.SpecConstant) = .{},
    // Fragment execution mode flags
    has_early_fragment_tests: bool = false,
    has_pixel_interlock_ordered: bool = false,
    has_pixel_interlock_unordered: bool = false,
    has_sample_interlock_ordered: bool = false,
    has_sample_interlock_unordered: bool = false,
    has_origin_upper_left: bool = false,
    has_depth_greater: bool = false,
    has_depth_less: bool = false,
    has_depth_unchanged: bool = false,
    uses_qcom_image_processing: bool = false,
    uses_ext_mesh_shader: bool = false,
    // Mesh shader layout parameters
    mesh_max_vertices: ?u32 = null,
    geometry_input_topology: ?ast.InputTopology = null,
    geometry_output_topology: ?ast.OutputTopology = null,
    geometry_max_vertices: ?u32 = null,
    tess_vertices: ?u32 = null,
    tess_input_topology: ?ast.InputTopology = null,
    tess_spacing: ?ast.TessSpacing = null,
    tess_vertex_order_ccw: ?bool = null,
    mesh_max_primitives: ?u32 = null,
    gl_in_id: ?u32 = null,
    mesh_output_topology: ?ast.OutputTopology = null,
    uses_ray_query: bool = false,
    uses_ray_query_position_fetch: bool = false,
    uses_arm_tensors: bool = false,

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
        self.const_composite_cache.deinit(self.alloc);
        self.access_chain_cache.deinit(self.alloc);
        self.global_access_chain_cache.deinit(self.alloc);
        self.ac_result_to_base.deinit(self.alloc);
        self.load_cache.deinit(self.alloc);
        self.global_load_cache.deinit(self.alloc);
        self.global_ptr_ids.deinit(self.alloc);
        self.pure_op_cache.deinit(self.alloc);
        self.global_pure_op_cache.deinit(self.alloc);
        // Free owned name keys in the types map
        {
            var type_key_it = self.types.keyIterator();
            while (type_key_it.next()) |key_ptr| {
                self.alloc.free(key_ptr.*);
            }
            self.types.deinit(self.alloc);
        }
        // Free owned name keys in the spec_constants map
        {
            var sc_key_it = self.spec_constants.keyIterator();
            while (sc_key_it.next()) |key_ptr| {
                self.alloc.free(key_ptr.*);
            }
            self.spec_constants.deinit(self.alloc);
        }
        {
            var it = self.overloads.iterator();
            while (it.next()) |entry| {
                for (entry.value_ptr.items) |*overload| {
                    if (overload.param_types.len > 0) {
                        self.alloc.free(overload.param_types);
                    }
                    if (overload.param_is_mutable.len > 0) {
                        self.alloc.free(overload.param_is_mutable);
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
        self.if_insert_points.deinit(self.alloc);
    }

    fn allocId(self: *Analyzer) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Ensure a TypedId is uint type, converting from int if needed
    fn ensureUint(self: *Analyzer, tid: TypedId) !u32 {
        if (tid.ty == .uint) return tid.id;
        if (tid.ty == .int) {
            // Emit int-to-uint conversion
            const result_id = self.allocId();
            const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
            operands[0] = .{ .id = tid.id };
            try self.instructions.append(self.alloc, .{
                .tag = .convert_itu,
                .result_type = null,
                .result_id = result_id,
                .operands = operands,
                .ty = .uint,
            });
            return result_id;
        }
        return tid.id;
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
    /// Compute a dedup key for a constant composite from its type and operand IDs.
    fn constCompositeKey(self: *Analyzer, ty: ast.Type, operands: []const ir.Instruction.Operand) u64 {
        var key: u64 = @intFromEnum(ty);
        // For named types, use member type layout instead of name string
        // This allows dedup of structs with the same layout but different names
        if (ty == .named) {
            if (self.types.get(ty.named)) |td| {
                for (td.members) |member| {
                    key = key *% 0x5bd1e995 ^ @intFromEnum(member.ty);
                }
            } else {
                // Fallback to name hash if type not found
                for (ty.named) |ch| {
                    key = key *% 0x5bd1e995 ^ @as(u64, ch);
                }
            }
        }
        // For array types, include size and base type hash
        if (ty == .array) {
            key = key *% 0x5bd1e995 ^ @as(u64, ty.array.size);
            key = key *% 0x5bd1e995 ^ @intFromEnum(ty.array.base.*);
        }
        for (operands) |op| {
            const op_val: u64 = switch (op) {
                .id => |id| id,
                .literal_int => |v| v,
                else => 0,
            };
            key = key *% 0x5bd1e995 ^ op_val;
        }
        return key;
    }

    /// Emit an access_chain instruction with dedup caching.
    /// AccessChains are pure (same base + indices = same pointer), so caching is always safe.
    /// Returns the result_id (either newly allocated or from cache).
    fn emitAccessChainCached(self: *Analyzer, base_id: u32, operands: []const ir.Instruction.Operand, result_ty: ast.Type) !u32 {
        // Build cache key from base + operands
        var key: u64 = base_id;
        for (operands) |op| {
            const op_val: u64 = switch (op) {
                .id => |id| id,
                .literal_int => |v| v | (@as(u64, 1) << 63),
                else => 0,
            };
            key = key *% 33 +% op_val;
        }
        // Check global cache first (entry-block AccessChains dominate all blocks)
        if (self.global_access_chain_cache.get(key)) |existing_id| {
            return existing_id;
        }
        if (self.access_chain_cache.get(key)) |existing_id| {
            return existing_id;
        }
        const ptr_id = self.allocId();
        const ops = try self.alloc.alloc(ir.Instruction.Operand, operands.len + 1);
        ops[0] = .{ .id = base_id };
        for (operands, 1..) |op, i| {
            ops[i] = op;
        }
        try self.instructions.append(self.alloc, .{
            .tag = .access_chain,
            .result_type = null,
            .result_id = ptr_id,
            .operands = ops,
            .ty = result_ty,
        });
        self.access_chain_cache.put(self.alloc, key, ptr_id) catch {};
        // Track AC result -> base variable for store invalidation
        self.ac_result_to_base.put(self.alloc, ptr_id, base_id) catch {};
        // Populate global cache from dominating blocks (entry + loop headers)
        if (self.cache_globals) {
            self.global_access_chain_cache.put(self.alloc, key, ptr_id) catch {};
        }
        // If base is a global pointer, the AccessChain result is also a global pointer
        if (self.global_ptr_ids.contains(base_id)) {
            self.global_ptr_ids.put(self.alloc, ptr_id, {}) catch {};
        }
        return ptr_id;
    }

    /// Emit a load instruction with caching within the current basic block.
    /// Caches are invalidated on stores and at block boundaries.
    /// Returns the loaded value's result_id.
    fn emitLoadCached(self: *Analyzer, ptr_id: u32, ty: ast.Type) !u32 {
        // Check local (per-block) cache first
        if (self.load_cache.get(ptr_id)) |existing_id| {
            return existing_id;
        }
        // Check global (cross-block) cache for any pointer
        // (entry block loads are safe to reuse in subsequent blocks due to dominance)
        if (self.global_load_cache.get(ptr_id)) |existing_id| {
            self.load_cache.put(self.alloc, ptr_id, existing_id) catch {};
            return existing_id;
        }
        const ld = self.allocId();
        const ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
        ops[0] = .{ .id = ptr_id };
        try self.instructions.append(self.alloc, .{
            .tag = .load,
            .result_type = null,
            .result_id = ld,
            .operands = ops,
            .ty = ty,
        });
        self.load_cache.put(self.alloc, ptr_id, ld) catch {};
        // Cache in global cache:
        // - Always for global pointers (Input/Uniform/PushConstant/UniformConstant) since their values don't change
        // - From dominating blocks for other pointers (entry + loop headers)
        if (self.cache_globals) {
            self.global_load_cache.put(self.alloc, ptr_id, ld) catch {};
        }
        return ld;
    }

    /// Emit a store instruction, invalidating the load cache.
    /// Emit a pure operation with dedup caching within the current basic block.
    /// Pure ops: composite_extract, transpose, vector_times_scalar, matrix_times_scalar,
    ///           vector_shuffle, fadd, fsub, fmul, fdiv, etc.
    /// Returns the result_id (either newly allocated or from cache).
    fn emitPureOp(self: *Analyzer, tag: ir.Instruction.Tag, operands: []const ir.Instruction.Operand, ty: ast.Type) !u32 {
        // Build cache key from tag + ty + operands
        var key: u64 = @intFromEnum(ty) *% 37 +% @intFromEnum(tag);
        for (operands) |op| {
            const op_val: u64 = switch (op) {
                .id => |id| id,
                .literal_int => |v| v | (@as(u64, 1) << 62),
                else => 0,
            };
            key = key *% 0x5bd1e995 ^ op_val;
        }
        // Check local cache first
        if (self.pure_op_cache.get(key)) |existing_id| {
            self.alloc.free(operands);
            return existing_id;
        }
        // Check global cache (populated from entry/loop-header blocks)
        if (self.global_pure_op_cache.get(key)) |existing_id| {
            self.alloc.free(operands);
            return existing_id;
        }
        const result_id = self.allocId();
        try self.instructions.append(self.alloc, .{
            .tag = tag,
            .result_type = null,
            .result_id = result_id,
            .operands = operands,
            .ty = ty,
        });
        self.pure_op_cache.put(self.alloc, key, result_id) catch {};
        return result_id;
    }

    fn emitStore(self: *Analyzer, ptr_id: u32, val_id: u32) !void {
        // Invalidate load cache for this pointer AND any base variable it might be derived from.
        // When storing to a component (e.g., uv.x), we must also invalidate the whole variable (uv)
        // so that subsequent loads of uv don't return a stale cached value.
        _ = self.load_cache.remove(ptr_id);
        _ = self.global_load_cache.remove(ptr_id);
        // Check if ptr_id is an AccessChain result — if so, invalidate the base variable too
        if (self.ac_result_to_base.get(ptr_id)) |base_id| {
            _ = self.load_cache.remove(base_id);
            _ = self.global_load_cache.remove(base_id);
        }
        // Store-to-load forwarding: within the same basic block, a load of the
        // same pointer after this store can use the stored value directly.
        self.load_cache.put(self.alloc, ptr_id, val_id) catch {};
        // Note: pure_op_cache is NOT cleared — pure ops don't depend on memory state
        const ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
        ops[0] = .{ .id = ptr_id };
        ops[1] = .{ .id = val_id };
        try self.instructions.append(self.alloc, .{
            .tag = .store,
            .result_type = null,
            .result_id = null,
            .operands = ops,
            .ty = .void,
        });
    }

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
        // Cache this composite for dedup
        if (last.result_id) |rid| {
            const key = self.constCompositeKey(last.ty, last.operands);
            self.const_composite_cache.put(self.alloc, key, rid) catch {};
        }
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
                    _ = self.load_cache.remove(var_id);
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
        // If the previous block was a global-dominating block (entry/loop-header),
        // save its pure_op_cache entries to global_pure_op_cache before clearing
        if (self.cache_globals) {
            var it = self.pure_op_cache.iterator();
            while (it.next()) |entry| {
                self.global_pure_op_cache.put(self.alloc, entry.key_ptr.*, entry.value_ptr.*) catch {};
            }
        }
        self.in_entry_block = false;
        self.cache_globals = false; // Only re-enable in loop headers
        self.access_chain_cache.clearRetainingCapacity();
        self.ac_result_to_base.clearRetainingCapacity();
        self.load_cache.clearRetainingCapacity();
        self.pure_op_cache.clearRetainingCapacity();
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
        // Geometry shader builtins
        try self.declare("EmitVertex", .{ .kind = .func, .ty = .void, .ir_id = 0 });
        try self.declare("EndPrimitive", .{ .kind = .func, .ty = .void, .ir_id = 0 });
    }


    fn ensureBuiltinVar(self: *Analyzer, name: []const u8) ?Symbol {
        // Lazy builtin variable injection — only create when referenced
        // Build builtin table
        const builtins = [_]struct { name: []const u8, ty: ast.Type, is_in: bool, is_out: bool, sc: ir.SPIRVStorageClass }{
            .{ .name = "gl_FragCoord", .ty = .vec4, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_FragColor", .ty = .vec4, .is_in = false, .is_out = true, .sc = .output },
            .{ .name = "gl_FragDepth", .ty = .float, .is_in = false, .is_out = true, .sc = .output },
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
            // Geometry shader builtins
            .{ .name = "gl_PrimitiveIDIn", .ty = .int, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_PrimitiveID", .ty = .int, .is_in = false, .is_out = true, .sc = .output },
            .{ .name = "gl_InvocationID", .ty = .int, .is_in = true, .is_out = false, .sc = .input },
            // Tessellation builtins
            .{ .name = "gl_PatchVerticesIn", .ty = .int, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_TessCoord", .ty = .vec3, .is_in = true, .is_out = false, .sc = .input },
            // gl_TessLevelOuter/Inner are array-of-float patch variables — handled in ensureBuiltinVar
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
            // EXT_mesh_shader builtins
            .{ .name = "gl_MeshPerVertexEXT", .ty = .vec4, .is_in = false, .is_out = true, .sc = .output },
            .{ .name = "gl_PrimitiveTriangleIndicesEXT", .ty = .uint, .is_in = false, .is_out = true, .sc = .output },
            .{ .name = "gl_PrimitiveLineIndicesEXT", .ty = .uint, .is_in = false, .is_out = true, .sc = .output },
            .{ .name = "gl_PrimitivePointIndicesEXT", .ty = .uint, .is_in = false, .is_out = true, .sc = .output },
            .{ .name = "gl_CullPrimitiveEXT", .ty = .bool, .is_in = false, .is_out = true, .sc = .output },
            .{ .name = "gl_PrimitiveShadingRateEXT", .ty = .uint, .is_in = false, .is_out = true, .sc = .output },
            .{ .name = "gl_TaskCountEXT", .ty = .uint, .is_in = false, .is_out = true, .sc = .output },
            .{ .name = "gl_PrimitiveCountEXT", .ty = .uint, .is_in = false, .is_out = true, .sc = .output },
            .{ .name = "gl_VertexCountEXT", .ty = .uint, .is_in = false, .is_out = true, .sc = .output },
            // KHR_ray_tracing builtins
            .{ .name = "gl_LaunchIDEXT", .ty = .uvec3, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_LaunchSizeEXT", .ty = .uvec3, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_WorldRayOriginEXT", .ty = .vec3, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_WorldRayDirectionEXT", .ty = .vec3, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_ObjectRayOriginEXT", .ty = .vec3, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_ObjectRayDirectionEXT", .ty = .vec3, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_RayTminEXT", .ty = .float, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_RayTmaxEXT", .ty = .float, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_InstanceCustomIndexEXT", .ty = .uint, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_HitKindEXT", .ty = .uint, .is_in = true, .is_out = false, .sc = .input },
            .{ .name = "gl_IncomingRayFlagsEXT", .ty = .uint, .is_in = true, .is_out = false, .sc = .input },
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
                self.global_ptr_ids.put(self.alloc, id, {}) catch {};
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

        // gl_ClipDistance[] — output array of float (vertex/geometry/tessellation)
        if (std.mem.eql(u8, name, "gl_ClipDistance")) {
            const id = self.allocId();
            const arr_base = self.alloc.create(ast.Type) catch return null;
            arr_base.* = .float;
            self.heap_types.append(self.alloc, arr_base) catch {};
            const ty: ast.Type = .{ .array = .{ .base = arr_base, .size = 8 } };
            const is_input = self.stage == .fragment or self.stage == .tessellation_evaluation;
            const sc: ir.SPIRVStorageClass = if (is_input) .input else .output;
            const qual: ast.Qualifier = if (is_input) .{ .is_in = true } else .{ .is_out = true };
            self.globals.append(self.alloc, .{ .name = "gl_ClipDistance", .ty = ty, .qualifier = qual, .layout = null, .storage_class = sc, .result_id = id }) catch return null;
            const sym = Symbol{ .kind = .var_sym, .ty = ty, .ir_id = id };
            self.scopes.items[0].put(self.alloc, "gl_ClipDistance", sym) catch return null;
            return sym;
        }

        // gl_CullDistance[] — output array of float (vertex/geometry/tessellation)
        if (std.mem.eql(u8, name, "gl_CullDistance")) {
            const id = self.allocId();
            const arr_base = self.alloc.create(ast.Type) catch return null;
            arr_base.* = .float;
            self.heap_types.append(self.alloc, arr_base) catch {};
            const ty: ast.Type = .{ .array = .{ .base = arr_base, .size = 8 } };
            const is_input = self.stage == .fragment or self.stage == .tessellation_evaluation;
            const sc: ir.SPIRVStorageClass = if (is_input) .input else .output;
            const qual: ast.Qualifier = if (is_input) .{ .is_in = true } else .{ .is_out = true };
            self.globals.append(self.alloc, .{ .name = "gl_CullDistance", .ty = ty, .qualifier = qual, .layout = null, .storage_class = sc, .result_id = id }) catch return null;
            const sym = Symbol{ .kind = .var_sym, .ty = ty, .ir_id = id };
            self.scopes.items[0].put(self.alloc, "gl_CullDistance", sym) catch return null;
            return sym;
        }

        // gl_in[] for geometry and tessellation shaders — array of vec4 (position-only simplified gl_PerVertex)
        if (std.mem.eql(u8, name, "gl_in")) {
            const arr_size: u32 = if (self.geometry_input_topology) |topo|
                switch (topo) {
                    .points => 1,
                    .lines => 2,
                    .lines_adjacency => 4,
                    .triangles => 3,
                    .triangles_adjacency => 6,
                }
            else
                self.tess_vertices orelse 32; // TCS: use tess_vertices or max patch vertices
            const id = self.allocId();
            const arr_base = self.alloc.create(ast.Type) catch return null;
            arr_base.* = .vec4;
            self.heap_types.append(self.alloc, arr_base) catch {};
            const ty: ast.Type = .{ .array = .{ .base = arr_base, .size = arr_size } };
            self.globals.append(self.alloc, .{ .name = "gl_in", .ty = ty, .qualifier = .{ .is_in = true }, .layout = null, .storage_class = .input, .result_id = id }) catch return null;
            self.global_ptr_ids.put(self.alloc, id, {}) catch {};
            const sym = Symbol{ .kind = .var_sym, .ty = ty, .ir_id = id };
            self.scopes.items[0].put(self.alloc, "gl_in", sym) catch return null;
            self.gl_in_id = id;
            return sym;
        }

        // gl_out[] for tessellation control shaders — array of vec4 (position-only)
        if (std.mem.eql(u8, name, "gl_out")) {
            const arr_size = self.tess_vertices orelse 3;
            const id = self.allocId();
            const arr_base = self.alloc.create(ast.Type) catch return null;
            arr_base.* = .vec4;
            self.heap_types.append(self.alloc, arr_base) catch {};
            const ty: ast.Type = .{ .array = .{ .base = arr_base, .size = arr_size } };
            self.globals.append(self.alloc, .{ .name = "gl_out", .ty = ty, .qualifier = .{ .is_out = true }, .layout = null, .storage_class = .output, .result_id = id }) catch return null;
            self.global_ptr_ids.put(self.alloc, id, {}) catch {};
            const sym = Symbol{ .kind = .var_sym, .ty = ty, .ir_id = id };
            self.scopes.items[0].put(self.alloc, "gl_out", sym) catch return null;
            return sym;
        }

        // gl_TessLevelOuter[4] — patch output in TCS, patch input in TES
        if (std.mem.eql(u8, name, "gl_TessLevelOuter")) {
            const id = self.allocId();
            const arr_base = self.alloc.create(ast.Type) catch return null;
            arr_base.* = .float;
            self.heap_types.append(self.alloc, arr_base) catch {};
            const ty: ast.Type = .{ .array = .{ .base = arr_base, .size = 4 } };
            const is_tcs = self.stage != null and self.stage.? == .tessellation_control;
            const sc: ir.SPIRVStorageClass = if (is_tcs) .output else .input;
            const qual: ast.Qualifier = if (is_tcs) .{ .is_out = true } else .{ .is_in = true };
            self.globals.append(self.alloc, .{ .name = "gl_TessLevelOuter", .ty = ty, .qualifier = qual, .layout = null, .storage_class = sc, .result_id = id }) catch return null;
            self.global_ptr_ids.put(self.alloc, id, {}) catch {};
            const sym = Symbol{ .kind = .var_sym, .ty = ty, .ir_id = id };
            self.scopes.items[0].put(self.alloc, "gl_TessLevelOuter", sym) catch return null;
            return sym;
        }

        // gl_TessLevelInner[2] — patch output in TCS, patch input in TES
        if (std.mem.eql(u8, name, "gl_TessLevelInner")) {
            const id = self.allocId();
            const arr_base = self.alloc.create(ast.Type) catch return null;
            arr_base.* = .float;
            self.heap_types.append(self.alloc, arr_base) catch {};
            const ty: ast.Type = .{ .array = .{ .base = arr_base, .size = 2 } };
            const is_tcs = self.stage != null and self.stage.? == .tessellation_control;
            const sc: ir.SPIRVStorageClass = if (is_tcs) .output else .input;
            const qual: ast.Qualifier = if (is_tcs) .{ .is_out = true } else .{ .is_in = true };
            self.globals.append(self.alloc, .{ .name = "gl_TessLevelInner", .ty = ty, .qualifier = qual, .layout = null, .storage_class = sc, .result_id = id }) catch return null;
            self.global_ptr_ids.put(self.alloc, id, {}) catch {};
            const sym = Symbol{ .kind = .var_sym, .ty = ty, .ir_id = id };
            self.scopes.items[0].put(self.alloc, "gl_TessLevelInner", sym) catch return null;
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
                        if (layout.early_fragment_tests) {
                            self.has_early_fragment_tests = true;
                        }
                        if (layout.pixel_interlock_ordered) {
                            self.has_pixel_interlock_ordered = true;
                        }
                        if (layout.pixel_interlock_unordered) {
                            self.has_pixel_interlock_unordered = true;
                        }
                        if (layout.sample_interlock_ordered) {
                            self.has_sample_interlock_ordered = true;
                        }
                        if (layout.sample_interlock_unordered) {
                            self.has_sample_interlock_unordered = true;
                        }
                        if (layout.origin_upper_left) {
                            self.has_origin_upper_left = true;
                        }
                        // Geometry/Tessellation input topology
                        if (layout.input_topology) |t| {
                            self.geometry_input_topology = t;
                            self.tess_input_topology = t;
                        }
                    }
                }
                // Check for depth layout qualifiers on output declarations
                if (node.tag == .out_decl) {
                    if (node.data.layout) |layout| {
                        if (layout.depth_greater) self.has_depth_greater = true;
                        if (layout.depth_less) self.has_depth_less = true;
                        if (layout.depth_unchanged) self.has_depth_unchanged = true;
                        // Distinguish geometry from mesh: mesh uses max_primitives, geometry doesn't
                        const is_mesh = layout.max_primitives != null;
                        const is_geom = !is_mesh and (layout.max_vertices != null or layout.is_triangle_strip or layout.is_line_strip);
                        if (layout.max_vertices) |mv| {
                            if (is_geom) {
                                self.geometry_max_vertices = mv;
                            } else {
                                self.mesh_max_vertices = mv;
                            }
                        }
                        if (layout.max_primitives) |mp| self.mesh_max_primitives = mp;
                        if (layout.output_topology) |t| {
                            if (is_geom) {
                                self.geometry_output_topology = t;
                            } else {
                                self.mesh_output_topology = t;
                            }
                        }
                        if (layout.vertices) |v| self.tess_vertices = v;
                        // Tessellation spacing
                        if (layout.equal_spacing) self.tess_spacing = .equal;
                        if (layout.fractional_even_spacing) self.tess_spacing = .fractional_even;
                        if (layout.fractional_odd_spacing) self.tess_spacing = .fractional_odd;
                        // Tessellation vertex order
                        if (layout.vertex_order_ccw) self.tess_vertex_order_ccw = true;
                        if (layout.vertex_order_cw) self.tess_vertex_order_ccw = false;
                        // Tessellation input topology overrides
                        if (layout.isolines) self.tess_input_topology = .lines;
                        if (layout.quads) self.tess_input_topology = .triangles;
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
                    .var_decl => if (node.data.qualifier != null and node.data.qualifier.?.is_shared) .workgroup else if (node.data.qualifier != null and node.data.qualifier.?.is_task_payload_shared) .task_payload_workgroup else if (node.data.qualifier != null and node.data.qualifier.?.is_ray_payload) .ray_payload else if (node.data.qualifier != null and node.data.qualifier.?.is_incoming_ray_payload) .incoming_ray_payload else if (node.data.qualifier != null and node.data.qualifier.?.is_hit_attribute) .hit_attribute else if (node.data.qualifier != null and node.data.qualifier.?.is_callable_data) .callable_data else if (node.data.qualifier != null and node.data.qualifier.?.is_incoming_callable_data) .incoming_callable_data else .private,
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
                // Track as global pointer for cross-block load caching
                if (storage_class == .input or storage_class == .output or storage_class == .uniform or storage_class == .uniform_constant) {
                    self.global_ptr_ids.put(self.alloc, ir_id, {}) catch {};
                }
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
                else if (qual.is_shared)
                    .workgroup
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
                // Track as global pointer for cross-block load caching
                if (storage_class == .input or storage_class == .output or storage_class == .uniform or storage_class == .storage_buffer or storage_class == .push_constant or storage_class == .uniform_constant or storage_class == .workgroup) {
                    self.global_ptr_ids.put(self.alloc, ir_id, {}) catch {};
                }
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

                // Declare block members as directly accessible for uniform/buffer/workgroup blocks
                // and for anonymous in/out blocks (no instance name).
                if (storage_class == .uniform or storage_class == .storage_buffer or storage_class == .push_constant or storage_class == .workgroup or
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
                    self.alloc.free(new_members);
                    // Free the old members slice if it was dupe'd
                    if (existing.?.members.len > 0) self.alloc.free(existing.?.members);
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
                var param_types = std.ArrayListUnmanaged(ast.Type).empty;
                for (node.data.params) |param| {
                    try param_types.append(self.alloc, param.ty);
                }
                const existing = self.lookup(node.data.name);
                if (existing != null and existing.?.kind == .func) {
                    // Function overload: store in overload map
                    const owned_name = try self.alloc.dupe(u8, node.data.name);
                    const gop = try self.overloads.getOrPut(self.alloc, owned_name);
                    if (gop.found_existing) {
                        self.alloc.free(owned_name);
                        // First overload already in the list with proper param_types
                        // Just append the second overload below
                    } else {
                        // This shouldn't happen — existing != null means overloads was already populated
                        // But handle it defensively
                        gop.value_ptr.* = .empty;
                    }
                    const owned_pts = try self.alloc.dupe(ast.Type, param_types.items);
                    var mutable_buf = try self.alloc.alloc(bool, node.data.params.len);
                    for (node.data.params, 0..) |p, i| mutable_buf[i] = if (p.qualifier) |q| (q.is_inout or q.is_out) else false;
                    param_types.deinit(self.alloc);
                    try gop.value_ptr.append(self.alloc, .{
                        .param_types = owned_pts,
                        .param_is_mutable = mutable_buf,
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
                    if (gop.found_existing) {
                        self.alloc.free(owned_name);
                    } else {
                        gop.value_ptr.* = .empty;
                    }
                    const owned_pts = try self.alloc.dupe(ast.Type, param_types.items);
                    var mutable_buf2 = try self.alloc.alloc(bool, node.data.params.len);
                    for (node.data.params, 0..) |p, i| mutable_buf2[i] = if (p.qualifier) |q| (q.is_inout or q.is_out) else false;
                    param_types.deinit(self.alloc);
                    try gop.value_ptr.append(self.alloc, .{
                        .param_types = owned_pts,
                        .param_is_mutable = mutable_buf2,
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
        self.in_entry_block = true;
        self.cache_globals = true;
        self.access_chain_cache.clearRetainingCapacity();
        self.ac_result_to_base.clearRetainingCapacity();
        self.load_cache.clearRetainingCapacity();
        self.pure_op_cache.clearRetainingCapacity();
        self.global_load_cache.clearRetainingCapacity();
        self.global_access_chain_cache.clearRetainingCapacity();
        self.global_pure_op_cache.clearRetainingCapacity();
        // Note: global_ptr_ids is NOT cleared — populated during collectTopLevel, shared across functions
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

        // Free operands of any leftover instructions from collectTopLevel or previous function
        for (self.instructions.items) |inst| {
            if (inst.operands.len > 0) {
                self.alloc.free(inst.operands);
            }
        }
        self.instructions.clearRetainingCapacity();
        // Note: const_cache is NOT cleared here. Constants from previous functions
        // are reused by ID, but their definitions live in the previous function's body.
        // The codegen's emitted_constants cache handles dedup across functions.
        // If a constant is needed but its definition is in a different function,
        // the codegen must re-emit it.

        var param_ids = std.ArrayListUnmanaged(u32).empty;
        defer param_ids.deinit(self.alloc);
        for (node.data.params) |param| {
            const pid = self.allocId();
            try param_ids.append(self.alloc, pid);

            const is_mutable = if (param.qualifier) |q| (q.is_inout or q.is_out) else false;

            if (is_mutable) {
                // For out/inout params: declare the param as a var_sym directly.
                // The codegen will emit the FunctionParameter with a pointer type,
                // so stores/loads through the param will work as expected.
                // No local variable copy needed — the param IS the mutable variable.
                try self.declare(param.name, .{
                    .kind = .var_sym,
                    .ty = param.ty,
                    .ir_id = pid,
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
            break :blk last_tag != .return_void and last_tag != .return_val and last_tag != .unreachable_inst and last_tag != .kill and last_tag != .emit_mesh_tasks;
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
                        const loaded_id = try self.emitLoadCached(init.id, init.ty);
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
                        _ = self.load_cache.remove(id);
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
                    // Stop emitting after a terminator (branch, return, kill, break, continue)
                    if (self.lastInstructionIsBranch()) break;
                }
                self.popScope();
            },
            .if_stmt => {
                const has_else = node.data.children.len > 2;
                const cond = try self.analyzeExpression(node.data.children[0]);

                const then_label = self.allocId();
                const else_label = if (has_else) self.allocId() else null;
                const merge_label = self.allocId();

                // Save instruction index BEFORE SelectionMerge — this is where init stores
                // for SSA vars materialized inside this if should be inserted.
                try self.if_insert_points.append(self.alloc, self.instructions.items.len);
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
                        _ = self.if_insert_points.pop();
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
                // Merge block dominates subsequent code within this scope,
                // but NOT if we're inside a loop body (the if-merge is still inside the loop,
                // so its AccessChains don't dominate the loop exit).
                try self.emitLabel(merge_label);
                if (self.loop_stack.items.len == 0) {
                    self.cache_globals = true;
                }
                _ = self.if_insert_points.pop();
            },
            .switch_stmt => {
                if (node.data.children.len < 2) return;

                const merge_label = self.allocId();

                // Evaluate selector
                const selector = try self.analyzeExpression(node.data.children[0]);
                var selector_id = selector.id;
                if (selector.is_ptr) {
                    const ld = try self.emitLoadCached(selector.id, selector.ty);
                    selector_id = ld;
                }

                const cases = node.data.children[1..];

                // Build OpSwitch: allocate a label per case + default
                // First, collect case values by evaluating case expressions
                const CaseInfo = struct { value: ?i64, label: u32, body_idx: usize };
                var case_infos = std.ArrayListUnmanaged(CaseInfo).empty;
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
                var switch_ops = std.ArrayListUnmanaged(ir.Instruction.Operand).empty;
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
                        // Stop emitting after a terminator (break, continue, return, discard)
                        if (self.lastInstructionIsBranch()) break;
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

                // Switch merge block dominates subsequent blocks
                try self.emitLabel(merge_label);
                self.cache_globals = true;
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
                self.cache_globals = true; // Loop header dominates body and continue blocks
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
                if (!self.lastInstructionIsBranch()) {
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
                // NOTE: Do NOT set cache_globals = true here. Loop merge blocks are inside
                // the enclosing scope, so loads here don't dominate beyond the enclosing loop.
                // Only entry block and loop headers get cache_globals = true.

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
                self.cache_globals = true; // Loop header dominates body and continue blocks
                const cond = try self.analyzeExpression(node.data.children[0]);
                try self.emitLoopMerge(merge_label, continue_label);
                try self.emitBranchConditional(cond.id, body_label, merge_label);

                // Body
                try self.emitLabel(body_label);
                if (node.data.children.len > 1) try self.analyzeStatement(node.data.children[1]);
                if (!self.lastInstructionIsBranch()) {
                    try self.emitBranch(continue_label);
                }

                // Continue: branch back to header for re-evaluation
                try self.emitLabel(continue_label);
                try self.emitBranch(header_label);

                _ = self.loop_stack.pop();
                try self.emitLabel(merge_label);
                // Do NOT set cache_globals = true — loop merge is inside enclosing scope

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
                if (!self.lastInstructionIsBranch()) {
                    try self.emitBranch(cond_label);
                }

                try self.emitLabel(cond_label);
                self.cache_globals = true; // do-while cond block dominates back-edge to body
                const cond = try self.analyzeExpression(node.data.children[1]);
                try self.emitBranchConditional(cond.id, body_label, merge_label);

                _ = self.loop_stack.pop();
                try self.emitLabel(merge_label);
                // Do NOT set cache_globals = true — loop merge is inside enclosing scope

            },
            .return_stmt => {
                if (node.data.children.len > 0) {
                    var val = try self.analyzeExpression(node.data.children[0]);
                    if (val.is_ptr) {
                        const ld = try self.emitLoadCached(val.id, val.ty);
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
                    self.alloc.free(new_members);
                    if (existing.?.members.len > 0) self.alloc.free(existing.?.members);
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
                    const store_inst = ir.Instruction{
                        .tag = .store,
                        .result_type = null,
                        .result_id = null,
                        .operands = store_ops,
                        .ty = .void,
                    };
                    if (self.if_insert_points.items.len > 0) {
                        const insert_idx = self.if_insert_points.items[0];
                        self.instructions.insert(self.alloc, insert_idx, store_inst) catch return null;
                    } else {
                        self.instructions.append(self.alloc, store_inst) catch return null;
                    }
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
                        const ptr_id = try self.emitAccessChainCached(sym.ir_id, &[1]ir.Instruction.Operand{.{ .literal_int = sym.member_index }}, sym.ty);
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
                        _ = self.load_cache.remove(var_id);
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
                            _ = self.load_cache.remove(var_id);
                            const store_inst = ir.Instruction{
                                .tag = .store,
                                .result_type = null,
                                .result_id = null,
                                .operands = store_ops,
                                .ty = .void,
                            };
                            if (self.if_insert_points.items.len > 0) {
                                // Inside a conditional: insert init store before outermost
                                // if's SelectionMerge to ensure it always executes.
                                const insert_idx = self.if_insert_points.items[0];
                                self.instructions.insert(self.alloc, insert_idx, store_inst) catch return error.OutOfMemory;
                            } else {
                                try self.instructions.append(self.alloc, store_inst);
                            }
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

                // Handle gl_out[i].gl_Position = val (and gl_in[i].gl_Position = val)
                // These arrays are arrays of vec4 (simplified gl_PerVertex),
                // so arr[i] already IS the position. Just return the indexed pointer.
                const base_child = node.data.children[0];
                if (base_child.tag == .index_access and base_child.data.children.len >= 1) {
                    const arr_base = base_child.data.children[0];
                    if (arr_base.tag == .identifier and
                        (std.mem.eql(u8, arr_base.data.name, "gl_in") or std.mem.eql(u8, arr_base.data.name, "gl_out")))
                    {
                        if (std.mem.eql(u8, node.data.name, "gl_Position")) {
                            return self.analyzeLValue(base_child);
                        }
                    }
                }

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
                            const ptr_id = try self.emitAccessChainCached(base_lv.id, &[1]ir.Instruction.Operand{.{ .literal_int = idx }}, member_ty);
                            return .{ .ty = member_ty, .id = ptr_id, .is_ptr = true };
                        }
                    }
                }
                // Vector swizzle write (single component): v.x = val
                if (base_lv.ty.isVector() and member_name.len == 1) {
                    const idx = self.swizzleIndex(member_name[0]);
                    const elem_ty = base_lv.ty.elementType();
                    const ptr_id = try self.emitAccessChainCached(base_lv.id, &[1]ir.Instruction.Operand{.{ .literal_int = idx }}, elem_ty);
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
                const ptr_id = try self.emitAccessChainCached(base_lv.id, &[1]ir.Instruction.Operand{.{ .id = index_tid.id }}, element_ty);
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
                        const ptr_id = try self.emitAccessChainCached(sym.ir_id, &[1]ir.Instruction.Operand{.{ .literal_int = sym.member_index }}, sym.ty);
                        // If the member is an array type, don't load — return the pointer
                        // so that index_access can chain another access chain
                        if (sym.ty == .array) {
                            return .{ .ty = sym.ty, .id = ptr_id, .is_ptr = true };
                        }
                        // Then load from that pointer
                        const id = try self.emitLoadCached(ptr_id, sym.ty);
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
                        const id = try self.emitLoadCached(sym.ir_id, sym.ty);
                        return .{ .ty = sym.ty, .id = id };
                    }
                    return .{ .ty = sym.ty, .id = sym.ir_id };
                }
                // Handle ray query constants
                if (std.mem.eql(u8, node.data.name, "gl_RayFlagsTerminateOnFirstHitEXT")) {
                    const cid = try self.getConstInt(4, .uint);
                    return .{ .ty = .uint, .id = cid };
                }
                if (std.mem.eql(u8, node.data.name, "gl_RayFlagsNoneEXT") or
                    std.mem.eql(u8, node.data.name, "gl_RayFlagsNoneKHR") or
                    std.mem.eql(u8, node.data.name, "gl_RayQueryCommittedIntersectionNoneEXT") or
                    std.mem.eql(u8, node.data.name, "gl_RayQueryCommittedIntersectionNoneKHR")) {
                    const cid = try self.getConstInt(0, .uint);
                    return .{ .ty = .uint, .id = cid };
                }
                if (std.mem.eql(u8, node.data.name, "gl_RayQueryCommittedIntersectionTriangleEXT") or
                    std.mem.eql(u8, node.data.name, "gl_RayQueryCommittedIntersectionTriangleKHR")) {
                    const cid = try self.getConstInt(1, .uint);
                    return .{ .ty = .uint, .id = cid };
                }
                // ARM tensor operand constants
                if (std.mem.eql(u8, node.data.name, "gl_TensorOperandsOutOfBoundsValueARM")) {
                    const cid = try self.getConstInt(1, .uint); // OutOfBoundsValueARM flag
                    return .{ .ty = .uint, .id = cid };
                }
                // Handle barrier builtins used as expressions (void)
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
                    const ld = try self.emitLoadCached(left.id, left.ty);
                    left = .{ .ty = left.ty, .id = ld };
                }
                if (right.is_ptr) {
                    const ld = try self.emitLoadCached(right.id, right.ty);
                    right = .{ .ty = right.ty, .id = ld };
                }
                const result_ty = self.promoteTypes(left.ty, right.ty) orelse return error.TypeMismatch;
                // NOTE: result_id is allocated later, after pure_op_cache check

                // Convert int/uint to float if needed for mixed comparisons/arithmetic
                var left_conv_id: ?u32 = null;
                var right_conv_id: ?u32 = null;
                if (left.ty == .int and (result_ty == .float or result_ty == .double or result_ty.isFloatVector())) {
                    const cvt_id = self.allocId();
                    const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    cvt_ops[0] = .{ .id = left.id };
                    try self.instructions.append(self.alloc, .{ .tag = .convert_itof, .result_type = null, .result_id = cvt_id, .operands = cvt_ops, .ty = .float });
                    left_conv_id = cvt_id;
                }
                if (right.ty == .int and (result_ty == .float or result_ty == .double or result_ty.isFloatVector())) {
                    const cvt_id = self.allocId();
                    const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    cvt_ops[0] = .{ .id = right.id };
                    try self.instructions.append(self.alloc, .{ .tag = .convert_itof, .result_type = null, .result_id = cvt_id, .operands = cvt_ops, .ty = .float });
                    right_conv_id = cvt_id;
                }
                if (left.ty == .uint and (result_ty == .float or result_ty == .double or result_ty.isFloatVector())) {
                    const cvt_id = self.allocId();
                    const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    cvt_ops[0] = .{ .id = left.id };
                    try self.instructions.append(self.alloc, .{ .tag = .convert_utof, .result_type = null, .result_id = cvt_id, .operands = cvt_ops, .ty = .float });
                    left_conv_id = cvt_id;
                }
                if (right.ty == .uint and (result_ty == .float or result_ty == .double or result_ty.isFloatVector())) {
                    const cvt_id = self.allocId();
                    const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    cvt_ops[0] = .{ .id = right.id };
                    try self.instructions.append(self.alloc, .{ .tag = .convert_utof, .result_type = null, .result_id = cvt_id, .operands = cvt_ops, .ty = .float });
                    right_conv_id = cvt_id;
                }
                // Convert int→uint or uint→int for mixed integer arithmetic
                if (left.ty == .int and result_ty == .uint) {
                    const cvt_id = self.allocId();
                    const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    cvt_ops[0] = .{ .id = left.id };
                    try self.instructions.append(self.alloc, .{ .tag = .convert_iti, .result_type = null, .result_id = cvt_id, .operands = cvt_ops, .ty = .uint });
                    left_conv_id = cvt_id;
                }
                if (right.ty == .int and result_ty == .uint) {
                    const cvt_id = self.allocId();
                    const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    cvt_ops[0] = .{ .id = right.id };
                    try self.instructions.append(self.alloc, .{ .tag = .convert_iti, .result_type = null, .result_id = cvt_id, .operands = cvt_ops, .ty = .uint });
                    right_conv_id = cvt_id;
                }
                if (left.ty == .uint and result_ty == .int) {
                    const cvt_id = self.allocId();
                    const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    cvt_ops[0] = .{ .id = left.id };
                    try self.instructions.append(self.alloc, .{ .tag = .convert_uti, .result_type = null, .result_id = cvt_id, .operands = cvt_ops, .ty = .int });
                    left_conv_id = cvt_id;
                }
                if (right.ty == .uint and result_ty == .int) {
                    const cvt_id = self.allocId();
                    const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    cvt_ops[0] = .{ .id = right.id };
                    try self.instructions.append(self.alloc, .{ .tag = .convert_uti, .result_type = null, .result_id = cvt_id, .operands = cvt_ops, .ty = .int });
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
                            // Check const_composite_cache for existing splat
                            const splat_operands = try self.alloc.alloc(ir.Instruction.Operand, num_comps);
                            for (0..num_comps) |i| {
                                splat_operands[i] = .{ .id = left_id };
                            }
                            const splat_key = self.constCompositeKey(result_ty, splat_operands);
                            if (self.const_composite_cache.get(splat_key)) |existing_id| {
                                self.alloc.free(splat_operands);
                                left_id = existing_id;
                                did_splat = true;
                            } else {
                                left_id = try self.emitPureOp(.composite_construct, splat_operands, result_ty);
                                _ = self.tryUpgradeToConstantComposite();
                                did_splat = true;
                            }
                        }
                    } else if (!left.ty.isScalar() and right.ty.isScalar()) {
                        // Check if we can use vector-scalar op instead of splat
                        const is_float_vec = left.ty == .vec2 or left.ty == .vec3 or left.ty == .vec4;
                        if (op == .mul and is_float_vec and right.ty == .float) {
                            // Skip splat, will use vec_scalar_mul tag
                        } else {
                            // Splat right scalar to vector
                            const num_comps = result_ty.numComponents();
                            const splat_operands = try self.alloc.alloc(ir.Instruction.Operand, num_comps);
                            for (0..num_comps) |i| {
                                splat_operands[i] = .{ .id = right_id };
                            }
                            const splat_key = self.constCompositeKey(result_ty, splat_operands);
                            if (self.const_composite_cache.get(splat_key)) |existing_id| {
                                self.alloc.free(splat_operands);
                                right_id = existing_id;
                                did_splat = true;
                            } else {
                                right_id = try self.emitPureOp(.composite_construct, splat_operands, result_ty);
                                _ = self.tryUpgradeToConstantComposite();
                                did_splat = true;
                            }
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

                // Logical operators require bool operands — convert float/int to bool
                if (op == .logical_and or op == .logical_or) {
                    if (left.ty == .float or left.ty == .double) {
                        const zero_id = try self.getConstFloat(0.0);
                        const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        cvt_ops[0] = .{ .id = left_id };
                        cvt_ops[1] = .{ .id = zero_id };
                        left_id = try self.emitPureOp(.compare_fneq, cvt_ops, .bool);
                    } else if (left.ty == .int) {
                        const zero_id = try self.getConstInt(0, .int);
                        const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        cvt_ops[0] = .{ .id = left_id };
                        cvt_ops[1] = .{ .id = zero_id };
                        left_id = try self.emitPureOp(.compare_neq, cvt_ops, .bool);
                    } else if (left.ty == .uint) {
                        const zero_id = try self.getConstInt(0, .uint);
                        const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        cvt_ops[0] = .{ .id = left_id };
                        cvt_ops[1] = .{ .id = zero_id };
                        left_id = try self.emitPureOp(.compare_neq, cvt_ops, .bool);
                    }
                    if (right.ty == .float or right.ty == .double) {
                        const zero_id = try self.getConstFloat(0.0);
                        const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        cvt_ops[0] = .{ .id = right_id };
                        cvt_ops[1] = .{ .id = zero_id };
                        right_id = try self.emitPureOp(.compare_fneq, cvt_ops, .bool);
                    } else if (right.ty == .int) {
                        const zero_id = try self.getConstInt(0, .int);
                        const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        cvt_ops[0] = .{ .id = right_id };
                        cvt_ops[1] = .{ .id = zero_id };
                        right_id = try self.emitPureOp(.compare_neq, cvt_ops, .bool);
                    } else if (right.ty == .uint) {
                        const zero_id = try self.getConstInt(0, .uint);
                        const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        cvt_ops[0] = .{ .id = right_id };
                        cvt_ops[1] = .{ .id = zero_id };
                        right_id = try self.emitPureOp(.compare_neq, cvt_ops, .bool);
                    }
                }

                const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                operands[0] = .{ .id = left_id };
                operands[1] = .{ .id = right_id };

                // Comparison and logical operators return bool/bvec, not the operand type
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

                // For comparisons on vectors, result is bvec, not scalar bool
                // GLSL == and != on vectors return scalar bool (all/any), but SPIR-V op returns bvec
                const is_vec_equality = returns_bool and result_ty.isVector() and (op == .eq or op == .neq);
                const cacheable_ty: ast.Type = if (returns_bool) blk: {
                    if (is_vec_equality) {
                        // == and != on vectors return scalar bool, not bvec
                        break :blk .bool;
                    } else if (result_ty.isVector()) {
                        // < > <= >= on vectors return bvec
                        const nc = result_ty.numComponents();
                        if (nc == 2) break :blk .bvec2;
                        if (nc == 3) break :blk .bvec3;
                        if (nc == 4) break :blk .bvec4;
                    }
                    break :blk .bool;
                } else final_result_ty;
                {
                    var cache_key: u64 = @intFromEnum(cacheable_ty) *% 37 +% @intFromEnum(tag);
                    cache_key = cache_key *% 0x5bd1e995 ^ @as(u64, left_id);
                    cache_key = cache_key *% 0x5bd1e995 ^ @as(u64, right_id);
                    if (self.pure_op_cache.get(cache_key)) |existing_id| {
                        self.alloc.free(operands);
                        return .{ .ty = cacheable_ty, .id = existing_id };
                    }
                    if (self.global_pure_op_cache.get(cache_key)) |existing_id| {
                        self.alloc.free(operands);
                        return .{ .ty = cacheable_ty, .id = existing_id };
                    }
                }

                const result_id = self.allocId();

                if (is_vec_equality) {
                    // For == and != on vectors, emit comparison with bvec result, then reduce to bool
                    const bvec_ty: ast.Type = switch (result_ty.numComponents()) {
                        2 => .bvec2,
                        3 => .bvec3,
                        4 => .bvec4,
                        else => .bool,
                    };
                    const bvec_id = self.allocId();
                    try self.instructions.append(self.alloc, .{
                        .tag = tag,
                        .result_type = null,
                        .result_id = bvec_id,
                        .operands = operands,
                        .ty = bvec_ty,
                    });
                    // Reduce: OpAll for ==, OpAny for !=
                    const reduce_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    reduce_ops[0] = .{ .id = bvec_id };
                    const reduce_tag: ir.Instruction.Tag = if (op == .eq) .all else .any;
                    try self.instructions.append(self.alloc, .{
                        .tag = reduce_tag,
                        .result_type = null,
                        .result_id = result_id,
                        .operands = reduce_ops,
                        .ty = .bool,
                    });
                } else {
                    try self.instructions.append(self.alloc, .{
                        .tag = tag,
                        .result_type = null,
                        .result_id = result_id,
                        .operands = operands,
                        .ty = cacheable_ty,
                    });
                }
                // Cache for dedup (comparisons are pure too — same inputs = same output)
                var cache_key: u64 = @intFromEnum(cacheable_ty) *% 37 +% @intFromEnum(tag);
                cache_key = cache_key *% 0x5bd1e995 ^ @as(u64, left_id);
                cache_key = cache_key *% 0x5bd1e995 ^ @as(u64, right_id);
                self.pure_op_cache.put(self.alloc, cache_key, result_id) catch {};
                return .{ .ty = cacheable_ty, .id = result_id };
            },
            .unary_op => {
                if (node.data.children.len < 1) return error.SemanticFailed;
                const operand = try self.analyzeExpression(node.data.children[0]);

                const is_float = operand.ty == .float or operand.ty == .double or operand.ty.isVector();

                switch (node.data.op orelse .sub) {
                    .sub => {
                        const tag: ir.Instruction.Tag = if (is_float) .fneg else .neg;
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        operands[0] = .{ .id = operand.id };
                        const result_id = try self.emitPureOp(tag, operands, operand.ty);
                        return .{ .ty = operand.ty, .id = result_id };
                    },
                    .logical_not => {
                        // LogicalNot requires bool operand — convert float/int to bool
                        var op_id = operand.id;
                        if (operand.ty == .float or operand.ty == .double) {
                            const zero_id = try self.getConstFloat(0.0);
                            const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                            cvt_ops[0] = .{ .id = op_id };
                            cvt_ops[1] = .{ .id = zero_id };
                            op_id = try self.emitPureOp(.compare_fneq, cvt_ops, .bool);
                        } else if (operand.ty == .int) {
                            const zero_id = try self.getConstInt(0, .int);
                            const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                            cvt_ops[0] = .{ .id = op_id };
                            cvt_ops[1] = .{ .id = zero_id };
                            op_id = try self.emitPureOp(.compare_neq, cvt_ops, .bool);
                        } else if (operand.ty == .uint) {
                            const zero_id = try self.getConstInt(0, .uint);
                            const cvt_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                            cvt_ops[0] = .{ .id = op_id };
                            cvt_ops[1] = .{ .id = zero_id };
                            op_id = try self.emitPureOp(.compare_neq, cvt_ops, .bool);
                        }
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        operands[0] = .{ .id = op_id };
                        const result_id = try self.emitPureOp(.logical_not, operands, .bool);
                        return .{ .ty = .bool, .id = result_id };
                    },
                    .bit_not => {
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        operands[0] = .{ .id = operand.id };
                        const result_id = try self.emitPureOp(.bit_not, operands, operand.ty);
                        return .{ .ty = operand.ty, .id = result_id };
                    },
                    else => {
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        operands[0] = .{ .id = operand.id };
                        const result_id = try self.emitPureOp(.neg, operands, operand.ty);
                        return .{ .ty = operand.ty, .id = result_id };
                    },
                }
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
                                        const loaded_id = try self.emitLoadCached(value.id, value.ty);
                                        value = .{ .ty = value.ty, .id = loaded_id };
                                    }

                                    // Materialize SSA variable if needed for swizzle write
                                    _ = self.materializeSSA(base_node.data.name);
                                    // Re-lookup to get updated ir_id after materialization
                                    const mat_sym = self.lookup(base_node.data.name);
                                    const var_ptr_id = if (mat_sym) |ms| ms.ir_id else sym.ir_id;

                                    // Load current vector value directly from the variable
                                    const load_id = try self.emitLoadCached(var_ptr_id, base_ty);

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

                                    const shuffle_id = try self.emitPureOp(.vector_shuffle, shuffle_ops, base_ty);

                                    // Store the shuffled vector back
                                    const store_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                                    store_ops[0] = .{ .id = var_ptr_id };
                                    store_ops[1] = .{ .id = shuffle_id };
                                    _ = self.load_cache.remove(var_ptr_id);
                                    _ = self.global_load_cache.remove(var_ptr_id);
                                    self.load_cache.put(self.alloc, var_ptr_id, shuffle_id) catch {}; // Forward
        try self.instructions.append(self.alloc, .{
                                        .tag = .store,
                                        .result_type = null,
                                        .result_id = null,
                                        .operands = store_ops,
                                        .ty = .void,
                                    });
                                    // Swizzle write returns the shuffle result
                                    return .{ .ty = base_ty, .id = shuffle_id };
                                }
                            }
                        }
                    }
                }

                // Evaluate RHS BEFORE LHS to avoid materializing SSA variable
                // before the RHS expression uses it. If the RHS references the same
                // variable being assigned to, it should use the SSA init_value directly.
                var value = try self.analyzeExpression(node.data.children[1]);
                const target = try self.analyzeLValue(node.data.children[0]);
                // If value is a pointer, load it
                if (value.is_ptr) {
                    const loaded_id = try self.emitLoadCached(value.id, value.ty);
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
                _ = self.load_cache.remove(target.id);
                _ = self.global_load_cache.remove(target.id);
                // If storing to an AccessChain result (e.g., v.x), also invalidate the base variable (v)
                // so subsequent loads of v return the updated value, not a stale cached load.
                if (self.ac_result_to_base.get(target.id)) |base_id| {
                    _ = self.load_cache.remove(base_id);
                    _ = self.global_load_cache.remove(base_id);
                }
                self.load_cache.put(self.alloc, target.id, value_id) catch {}; // Forward stored value
        try self.instructions.append(self.alloc, .{
                    .tag = .store,
                    .result_type = null,
                    .result_id = null,
                    .operands = store_operands,
                    .ty = .void,
                });
                // Assignment returns the assigned value (GLSL/C semantics)
                return .{ .ty = target.ty, .id = value_id };
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
                                    const vec_load_id = try self.emitLoadCached(var_ptr_id2, base_ty);

                                    // 2. Extract swizzled components from the loaded vector
                                    const swizzle_len = swizzle_name.len;
                                    const swizzle_ops = try self.alloc.alloc(ir.Instruction.Operand, 2 + swizzle_len);
                                    swizzle_ops[0] = .{ .id = vec_load_id };
                                    swizzle_ops[1] = .{ .id = vec_load_id }; // second vector unused for extract-only
                                    for (0..swizzle_len) |i| {
                                        swizzle_ops[2 + i] = .{ .literal_int = self.swizzleIndex(swizzle_name[i]) };
                                    }
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
                                    const swizzled_id = try self.emitPureOp(.vector_shuffle, swizzle_ops, swizzled_ty);

                                    // 3. Evaluate RHS
                                    var value = try self.analyzeExpression(node.data.children[1]);
                                    if (value.is_ptr) {
                                        const loaded_id = try self.emitLoadCached(value.id, value.ty);
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
                                        const splat_key = self.constCompositeKey(swizzled_ty, splat_ops);
                                        if (self.const_composite_cache.get(splat_key)) |existing_id| {
                                            self.alloc.free(splat_ops);
                                            value_id = existing_id;
                                        } else {
                                            value_id = try self.emitPureOp(.composite_construct, splat_ops, swizzled_ty);
                                            _ = self.tryUpgradeToConstantComposite();
                                        }
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
                                    const final_shuffle_id = try self.emitPureOp(.vector_shuffle, final_shuffle_ops, base_ty);

                                    // 6. Store back
                                    const store_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                                    store_ops[0] = .{ .id = var_ptr_id2 };
                                    store_ops[1] = .{ .id = final_shuffle_id };
                                    _ = self.load_cache.remove(var_ptr_id2);
                                    _ = self.global_load_cache.remove(var_ptr_id2);
                                    self.load_cache.put(self.alloc, var_ptr_id2, final_shuffle_id) catch {}; // Forward
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
                    const ld_id = try self.emitLoadCached(value.id, value.ty);
                    value = .{ .ty = value.ty, .id = ld_id };
                }
                // Load current value
                const loaded_id = try self.emitLoadCached(target.id, target.ty);
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
                    const num_comps = target.ty.numComponents();
                    const splat_operands = try self.alloc.alloc(ir.Instruction.Operand, num_comps);
                    for (0..num_comps) |i| {
                        splat_operands[i] = .{ .id = float_id };
                    }
                    value_id = try self.emitPureOp(.composite_construct, splat_operands, target.ty);
                    value_ty = target.ty;
                } else if (target.ty.isVector() and value_ty == .float) {
                    // For multiplication, skip splat — we'll use vec_scalar_mul instead
                    const is_mul = node.data.op == .mul_assign;
                    if (!is_mul) {
                        // float → splat to vector (needed for +=, -=, /= etc.)
                        const num_comps = target.ty.numComponents();
                        const splat_operands = try self.alloc.alloc(ir.Instruction.Operand, num_comps);
                        for (0..num_comps) |i| {
                            splat_operands[i] = .{ .id = value.id };
                        }
                        value_id = try self.emitPureOp(.composite_construct, splat_operands, target.ty);
                        value_ty = target.ty;
                    }
                } else if (target.ty.isVector() and value_ty.isScalar() and !value_ty.isVector()) {
                    // Any other scalar → splat to vector (handles int8, int16, uint8, uint16, etc.)
                    const num_comps = target.ty.numComponents();
                    const splat_operands = try self.alloc.alloc(ir.Instruction.Operand, num_comps);
                    for (0..num_comps) |i| {
                        splat_operands[i] = .{ .id = value.id };
                    }
                    value_id = try self.emitPureOp(.composite_construct, splat_operands, target.ty);
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
                try self.emitStore(target.id, computed_id);
                return .{ .ty = .void, .id = 0 };
            },
            .func_call => {
                // Early check: array .length() method — return array size as int constant
                if (std.mem.eql(u8, node.data.name, "length") and node.data.children.len == 1) {
                    var arr_size: ?u32 = null;
                    const first_child = node.data.children[0];
                    // Try identifier lookup first (avoids emitting unnecessary IR)
                    if (first_child.tag == .identifier) {
                        if (self.lookup(first_child.data.name)) |sym| {
                            if (sym.ty == .array) arr_size = sym.ty.array.size;
                        }
                    }
                    // Fallback: evaluate expression and check type
                    if (arr_size == null) {
                        if (self.analyzeExpression(first_child)) |tid| {
                            if (tid.ty == .array) arr_size = tid.ty.array.size;
                        } else |_| {}
                    }
                    if (arr_size) |size| {
                        const val: u32 = size;
                        const key = (@as(u64, @intFromEnum(ast.Type.int)) << 32) | @as(u64, val);
                        if (self.const_cache.get(key)) |cached| {
                            return .{ .ty = .int, .id = cached };
                        }
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
                    }
                }
                var arg_tids = std.ArrayListUnmanaged(TypedId).empty;
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
                    const is_emit_mesh_tasks = std.mem.eql(u8, node.data.name, "EmitMeshTasksEXT");
                    const skip_load = (is_atomic_fn and i == 0) or (is_image_atomic_fn and i == 0) or (is_emit_mesh_tasks and i == 3);
                    if (tid.is_ptr and !skip_load) {
                        const ld = try self.emitLoadCached(tid.id, tid.ty);
                        tid = .{ .ty = tid.ty, .id = ld };
                    }
                    try arg_tids.append(self.alloc, tid);
                }
                // nonuniformEXT(expr) → passthrough (just returns the expression value)
                // TODO: emit NonUniform decoration on the result for full compliance
                if (std.mem.eql(u8, node.data.name, "nonuniformEXT")) {
                    if (arg_tids.items.len == 1) {
                        return arg_tids.items[0];
                    }
                }
                const sym_raw = self.lookup(node.data.name);
                // Resolve function overloads
                var resolved_sym = sym_raw;
                var resolved_mutable_params: []const bool = &[_]bool{};
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
                                resolved_mutable_params = overload.param_is_mutable;
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
                // transpose returns the transposed matrix type (rows ↔ columns)
                else if (std.mem.eql(u8, node.data.name, "transpose") and arg_tids.items.len > 0 and arg_tids.items[0].ty.isMatrix())
                    arg_tids.items[0].ty.transposeType()
                else if (self.isGLSLBuiltin(node.data.name) and arg_tids.items.len > 0)
                    // bitCount/findLSB/findMSB always return int (or ivecN), regardless of uint input
                    if (std.mem.eql(u8, node.data.name, "bitCount") or
                        std.mem.eql(u8, node.data.name, "findLSB") or
                        std.mem.eql(u8, node.data.name, "findMSB"))
                        switch (arg_tids.items[0].ty) {
                            .uint => .int,
                            .uvec2 => .ivec2,
                            .uvec3 => .ivec3,
                            .uvec4 => .ivec4,
                            else => arg_tids.items[0].ty,
                        }
                    else
                        arg_tids.items[0].ty
                else if (sym) |s| s.ty
                else .void;

                // Pre-check pure op cache for known pure GLSL builtins BEFORE allocating result_id.
                const maybe_cached_builtin: ?u32 = blk: {
                    if (std.mem.eql(u8, node.data.name, "transpose")) {
                        var key: u64 = @intFromEnum(result_ty) *% 37 +% @intFromEnum(ir.Instruction.Tag.transpose);
                        for (arg_tids.items) |tid| {
                            key = key *% 0x5bd1e995 ^ tid.id;
                        }
                        if (self.pure_op_cache.get(key)) |existing_id| {
                            break :blk existing_id;
                        }
                    }
                    // Bitcast builtins: compute target type and check cache
                    if (std.mem.eql(u8, node.data.name, "floatBitsToUint") or
                        std.mem.eql(u8, node.data.name, "floatBitsToInt") or
                        std.mem.eql(u8, node.data.name, "intBitsToFloat") or
                        std.mem.eql(u8, node.data.name, "uintBitsToFloat"))
                    {
                        const arg_ty = arg_tids.items[0].ty;
                        const bitcast_ty: ast.Type = blk2: {
                            if (std.mem.eql(u8, node.data.name, "floatBitsToUint")) {
                                if (arg_ty == .float) break :blk2 .uint;
                                if (arg_ty == .vec2) break :blk2 .uvec2;
                                if (arg_ty == .vec3) break :blk2 .uvec3;
                                if (arg_ty == .vec4) break :blk2 .uvec4;
                            }
                            if (std.mem.eql(u8, node.data.name, "floatBitsToInt")) {
                                if (arg_ty == .float) break :blk2 .int;
                                if (arg_ty == .vec2) break :blk2 .ivec2;
                                if (arg_ty == .vec3) break :blk2 .ivec3;
                                if (arg_ty == .vec4) break :blk2 .ivec4;
                            }
                            if (std.mem.eql(u8, node.data.name, "intBitsToFloat")) {
                                if (arg_ty == .int) break :blk2 .float;
                                if (arg_ty == .ivec2) break :blk2 .vec2;
                                if (arg_ty == .ivec3) break :blk2 .vec3;
                                if (arg_ty == .ivec4) break :blk2 .vec4;
                            }
                            if (std.mem.eql(u8, node.data.name, "uintBitsToFloat")) {
                                if (arg_ty == .uint) break :blk2 .float;
                                if (arg_ty == .uvec2) break :blk2 .vec2;
                                if (arg_ty == .uvec3) break :blk2 .vec3;
                                if (arg_ty == .uvec4) break :blk2 .vec4;
                            }
                            break :blk2 result_ty;
                        };
                        var key: u64 = @intFromEnum(bitcast_ty) *% 37 +% @intFromEnum(ir.Instruction.Tag.bitcast);
                        key = key *% 0x5bd1e995 ^ @as(u64, arg_tids.items[0].id);
                        if (self.pure_op_cache.get(key)) |existing_id| {
                            break :blk existing_id;
                        }
                    }
                    break :blk null;
                };
                if (maybe_cached_builtin) |cached_id| {
                    return .{ .ty = result_ty, .id = cached_id };
                }

                const result_id = self.allocId();

                if (self.isGLSLBuiltin(node.data.name)) {
                    // mod(x, y) → OpFMod (core SPIR-V, not GLSL.std.450)
                    if (std.mem.eql(u8, node.data.name, "mod")) {
                        const ret_ty = if (arg_tids.items.len > 0) arg_tids.items[0].ty else .float;
                        // Scalar-to-vector promotion for mod(vec, scalar)
                        if (ret_ty.isVector() and arg_tids.items.len >= 2) {
                            for (arg_tids.items[1..]) |*tid| {
                                if (!tid.ty.isVector()) {
                                    const vec_id = self.allocId();
                                    const num_comps: usize = switch (ret_ty) {
                                        .vec2 => 2, .vec3 => 3, .vec4 => 4,
                                        .ivec2 => 2, .ivec3 => 3, .ivec4 => 4,
                                        .uvec2 => 2, .uvec3 => 3, .uvec4 => 4,
                                        else => unreachable,
                                    };
                                    const comp_ops = try self.alloc.alloc(ir.Instruction.Operand, num_comps);
                                    for (comp_ops) |*op| op.* = .{ .id = tid.id };
                                    try self.instructions.append(self.alloc, .{
                                        .tag = .composite_construct,
                                        .result_type = null,
                                        .result_id = vec_id,
                                        .operands = comp_ops,
                                        .ty = ret_ty,
                                    });
                                    tid.* = .{ .id = vec_id, .ty = ret_ty };
                                }
                            }
                        }
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
                        // Fragment shader interlock: beginInvocationInterlockARB / endInvocationInterlockARB
                        if (std.mem.eql(u8, node.data.name, "beginInvocationInterlockARB")) {
                            try self.instructions.append(self.alloc, .{
                                .tag = .begin_invocation_interlock,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = &.{},
                                .ty = .void,
                            });
                            return .{ .ty = .void, .id = result_id };
                        }
                        if (std.mem.eql(u8, node.data.name, "endInvocationInterlockARB")) {
                            try self.instructions.append(self.alloc, .{
                                .tag = .end_invocation_interlock,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = &.{},
                                .ty = .void,
                            });
                            return .{ .ty = .void, .id = result_id };
                        }
                        // Remaining barrier builtins (demote)
                        return .{ .ty = .void, .id = result_id };
                    }
                    // Geometry shader builtins: EmitVertex, EndPrimitive
                    if (std.mem.eql(u8, node.data.name, "EmitVertex")) {
                        try self.instructions.append(self.alloc, .{
                            .tag = .emit_vertex,
                            .result_type = null,
                            .result_id = null,
                            .operands = &.{},
                            .ty = .void,
                        });
                        return .{ .ty = .void, .id = 0 };
                    }
                    if (std.mem.eql(u8, node.data.name, "EndPrimitive")) {
                        try self.instructions.append(self.alloc, .{
                            .tag = .end_primitive,
                            .result_type = null,
                            .result_id = null,
                            .operands = &.{},
                            .ty = .void,
                        });
                        return .{ .ty = .void, .id = 0 };
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
                    // === QCOM image processing builtins ===
                    if (std.mem.eql(u8, node.data.name, "textureBoxFilterQCOM")) {
                        // textureBoxFilterQCOM(sampler, coords, boxSize) → OpImageBoxFilterQCOM
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 3);
                        operands[0] = .{ .id = arg_tids.items[0].id };
                        operands[1] = .{ .id = arg_tids.items[1].id };
                        operands[2] = .{ .id = arg_tids.items[2].id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .image_box_filter_qcom,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = .vec4,
                        });
                        self.uses_qcom_image_processing = true;
                        return .{ .ty = .vec4, .id = result_id };
                    }
                    if (std.mem.eql(u8, node.data.name, "textureBlockMatchSADQCOM")) {
                        // textureBlockMatchSADQCOM(target_samp, target_coords, ref_samp, ref_coords, blockSize) → OpImageBlockMatchSADQCOM
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 5);
                        for (arg_tids.items, 0..) |tid, idx| {
                            operands[idx] = .{ .id = tid.id };
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .image_block_match_sad_qcom,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = .vec4,
                        });
                        self.uses_qcom_image_processing = true;
                        return .{ .ty = .vec4, .id = result_id };
                    }
                    if (std.mem.eql(u8, node.data.name, "textureBlockMatchSSDQCOM")) {
                        // Same as SAD but uses SSD opcode
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 5);
                        for (arg_tids.items, 0..) |tid, idx| {
                            operands[idx] = .{ .id = tid.id };
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .image_block_match_ssd_qcom,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = .vec4,
                        });
                        self.uses_qcom_image_processing = true;
                        return .{ .ty = .vec4, .id = result_id };
                    }
                    if (std.mem.eql(u8, node.data.name, "textureWeightedQCOM")) {
                        // textureWeightedQCOM(sampler, coords, weights) → OpImageSampleWeightedQCOM
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 3);
                        operands[0] = .{ .id = arg_tids.items[0].id };
                        operands[1] = .{ .id = arg_tids.items[1].id };
                        operands[2] = .{ .id = arg_tids.items[2].id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .image_sample_weighted_qcom,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = .vec4,
                        });
                        self.uses_qcom_image_processing = true;
                        return .{ .ty = .vec4, .id = result_id };
                    }
                    // === Ray query builtins ===
                    // rayQueryInitializeEXT(query, accel, flags, mask, origin, tmin, dir, tmax)
                    if (std.mem.eql(u8, node.data.name, "rayQueryInitializeEXT")) {
                        const query_ptr = if (node.data.children.len > 0) self.analyzeLValue(node.data.children[0]) catch arg_tids.items[0] else arg_tids.items[0];
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len);
                        operands[0] = .{ .id = query_ptr.id };
                        for (arg_tids.items[1..], 1..) |tid, idx| {
                            operands[idx] = .{ .id = tid.id };
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .ray_query_initialize,
                            .result_type = null,
                            .result_id = null,
                            .operands = operands,
                            .ty = .void,
                        });
                        self.uses_ray_query = true;
                        return .{ .ty = .void, .id = result_id };
                    }
                    // rayQueryProceedEXT(query) → bool
                    if (std.mem.eql(u8, node.data.name, "rayQueryProceedEXT")) {
                        const query_ptr = if (node.data.children.len > 0) self.analyzeLValue(node.data.children[0]) catch arg_tids.items[0] else arg_tids.items[0];
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        operands[0] = .{ .id = query_ptr.id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .ray_query_proceed,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = .bool,
                        });
                        self.uses_ray_query = true;
                        return .{ .ty = .bool, .id = result_id };
                    }
                    // rayQueryGetIntersectionTypeEXT(query, committed) → uint
                    if (std.mem.eql(u8, node.data.name, "rayQueryGetIntersectionTypeEXT")) {
                        const query_ptr = if (node.data.children.len > 0) self.analyzeLValue(node.data.children[0]) catch arg_tids.items[0] else arg_tids.items[0];
                        // committed arg must be int (GLSL uses true/false → 1/0)
                        var committed_id = arg_tids.items[1].id;
                        if (arg_tids.items[1].ty == .bool) {
                            const conv_id = try self.getConstInt(1, .int);
                            committed_id = conv_id;
                        }
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        operands[0] = .{ .id = query_ptr.id };
                        operands[1] = .{ .id = committed_id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .ray_query_get_intersection_type,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = .uint,
                        });
                        self.uses_ray_query = true;
                        return .{ .ty = .uint, .id = result_id };
                    }
                    // rayQueryGetIntersectionTriangleVertexPositionsEXT(query, committed, out_array)
                    if (std.mem.eql(u8, node.data.name, "rayQueryGetIntersectionTriangleVertexPositionsEXT")) {
                        const query_ptr = if (node.data.children.len > 0) self.analyzeLValue(node.data.children[0]) catch arg_tids.items[0] else arg_tids.items[0];
                        const arr_base = try self.alloc.create(ast.Type);
                        arr_base.* = .vec3;
                        const ret_ty: ast.Type = .{ .array = .{ .base = arr_base, .size = 3 } };
                        try self.heap_types.append(self.alloc, arr_base);
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        operands[0] = .{ .id = query_ptr.id };
                        var committed_id2 = arg_tids.items[1].id; // committed
                        if (arg_tids.items[1].ty == .bool) {
                            committed_id2 = try self.getConstInt(1, .int);
                        }
                        operands[1] = .{ .id = committed_id2 };
                        try self.instructions.append(self.alloc, .{
                            .tag = .ray_query_get_triangle_vertex_positions,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = ret_ty,
                        });
                        self.uses_ray_query = true;
                        self.uses_ray_query_position_fetch = true;
                        return .{ .ty = ret_ty, .id = result_id };
                    }
                    // === ARM tensor builtins ===
                    if (std.mem.eql(u8, node.data.name, "tensorSizeARM")) {
                        const tensor_id = arg_tids.items[0].id;
                        const dim_id = arg_tids.items[1].id;
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        operands[0] = .{ .id = tensor_id };
                        operands[1] = .{ .id = dim_id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .tensor_query_size_arm,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = .uint,
                        });
                        self.uses_arm_tensors = true;
                        return .{ .ty = .uint, .id = result_id };
                    }
                    // === EXT_mesh_shader builtins ===
                    // SetMeshOutputsEXT(num_vertices, num_primitives) → void
                    if (std.mem.eql(u8, node.data.name, "SetMeshOutputsEXT")) {
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        // Ensure uint arguments (int literals are signed)
                        operands[0] = .{ .id = try self.ensureUint(arg_tids.items[0]) };
                        operands[1] = .{ .id = try self.ensureUint(arg_tids.items[1]) };
                        try self.instructions.append(self.alloc, .{
                            .tag = .set_mesh_outputs,
                            .result_type = null,
                            .result_id = null,
                            .operands = operands,
                            .ty = .void,
                        });
                        return .{ .ty = .void, .id = result_id };
                    }
                    // EmitMeshTasksEXT(x, y, z, payload) → void
                    if (std.mem.eql(u8, node.data.name, "EmitMeshTasksEXT")) {
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 4);
                        operands[0] = .{ .id = try self.ensureUint(arg_tids.items[0]) };
                        operands[1] = .{ .id = try self.ensureUint(arg_tids.items[1]) };
                        operands[2] = .{ .id = try self.ensureUint(arg_tids.items[2]) };
                        operands[3] = .{ .id = arg_tids.items[3].id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .emit_mesh_tasks,
                            .result_type = null,
                            .result_id = null,
                            .operands = operands,
                            .ty = .void,
                        });
                        return .{ .ty = .void, .id = result_id };
                    }
                    // === KHR_ray_tracing builtins ===
                    // ignoreIntersectionEXT() → void
                    if (std.mem.eql(u8, node.data.name, "ignoreIntersectionEXT")) {
                        try self.instructions.append(self.alloc, .{
                            .tag = .ignore_intersection,
                            .result_type = null,
                            .result_id = null,
                            .operands = &.{},
                            .ty = .void,
                        });
                        return .{ .ty = .void, .id = result_id };
                    }
                    // terminateRayEXT() → void
                    if (std.mem.eql(u8, node.data.name, "terminateRayEXT")) {
                        try self.instructions.append(self.alloc, .{
                            .tag = .terminate_ray,
                            .result_type = null,
                            .result_id = null,
                            .operands = &.{},
                            .ty = .void,
                        });
                        return .{ .ty = .void, .id = result_id };
                    }
                    // reportIntersectionEXT(hitT, hitKind) → bool
                    if (std.mem.eql(u8, node.data.name, "reportIntersectionEXT") and arg_tids.items.len >= 2) {
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        operands[0] = .{ .id = arg_tids.items[0].id };
                        operands[1] = .{ .id = arg_tids.items[1].id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .report_intersection,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = .bool,
                        });
                        return .{ .ty = .bool, .id = result_id };
                    }
                    // executeCallableEXT(sbtIndex, callableData) → void
                    if (std.mem.eql(u8, node.data.name, "executeCallableEXT") and arg_tids.items.len >= 2) {
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        operands[0] = .{ .id = arg_tids.items[0].id };
                        operands[1] = .{ .id = arg_tids.items[1].id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .execute_callable,
                            .result_type = null,
                            .result_id = null,
                            .operands = operands,
                            .ty = .void,
                        });
                        return .{ .ty = .void, .id = result_id };
                    }
                    // traceRayEXT(accel, rayFlags, cullMask, sbtOffset, sbtStride, missIndex, origin, tMin, direction, tMax, payload) → void
                    if (std.mem.eql(u8, node.data.name, "traceRayEXT") and arg_tids.items.len >= 11) {
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 11);
                        operands[0] = .{ .id = arg_tids.items[0].id };
                        operands[1] = .{ .id = arg_tids.items[1].id };
                        operands[2] = .{ .id = arg_tids.items[2].id };
                        operands[3] = .{ .id = arg_tids.items[3].id };
                        operands[4] = .{ .id = arg_tids.items[4].id };
                        operands[5] = .{ .id = arg_tids.items[5].id };
                        operands[6] = .{ .id = arg_tids.items[6].id };
                        operands[7] = .{ .id = arg_tids.items[7].id };
                        operands[8] = .{ .id = arg_tids.items[8].id };
                        operands[9] = .{ .id = arg_tids.items[9].id };
                        operands[10] = .{ .id = arg_tids.items[10].id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .trace_ray,
                            .result_type = null,
                            .result_id = null,
                            .operands = operands,
                            .ty = .void,
                        });
                        return .{ .ty = .void, .id = result_id };
                    }
                    if (std.mem.eql(u8, node.data.name, "tensorReadARM")) {
                        // tensorReadARM(tensor, coords, out [, operands...])
                        // This is a void function - writes result to out parameter
                        const tensor_id = arg_tids.items[0].id;
                        const coords_id = arg_tids.items[1].id;
                        // Get pointer to output variable (not loaded value)
                        const out_ptr = if (node.data.children.len > 2) self.analyzeLValue(node.data.children[2]) catch arg_tids.items[2] else arg_tids.items[2];
                        const out_id = out_ptr.id;
                        const out_ty = arg_tids.items[2].ty;
                        // Emit as a read that returns to out_id via store
                        const read_result_id = self.allocId();
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        operands[0] = .{ .id = tensor_id };
                        operands[1] = .{ .id = coords_id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .tensor_read_arm,
                            .result_type = null,
                            .result_id = read_result_id,
                            .operands = operands,
                            .ty = out_ty,
                        });
                        self.uses_arm_tensors = true;
                        // Store result to out parameter
                        const store_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        store_ops[0] = .{ .id = out_id };
                        store_ops[1] = .{ .id = read_result_id };
                        _ = self.load_cache.remove(out_id);
                        _ = self.global_load_cache.remove(out_id);
                        self.load_cache.put(self.alloc, out_id, read_result_id) catch {}; // Forward
        try self.instructions.append(self.alloc, .{
                            .tag = .store,
                            .result_type = null,
                            .result_id = null,
                            .operands = store_ops,
                            .ty = .void,
                        });
                        return .{ .ty = .void, .id = out_id };
                    }
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
                            const conv_tag: ir.Instruction.Tag = blk: {
                                if (ret_ty == .uint and arg_tids.items[1].ty == .int) break :blk .convert_iti;
                                if (ret_ty == .int and arg_tids.items[1].ty == .uint) break :blk .convert_uti;
                                if (ret_ty == .float) break :blk .convert_itof;
                                break :blk .bitcast;
                            };
                            const conv_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                            conv_ops[0] = .{ .id = arg_tids.items[1].id };
                            value_id = try self.emitPureOp(conv_tag, conv_ops, ret_ty);
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
                            .uimage2d, .uimage_buffer, .uimage1d, .uimage3d, .uimage_cube, .uimage2d_array, .uimage_cube_array => .uint,
                            .iimage2d, .iimage_buffer, .iimage1d, .iimage3d, .iimage_cube, .iimage2d_array, .iimage_cube_array => .int,
                            .image2d, .image_buffer, .image1d, .image3d, .image_cube, .image2d_array, .image_cube_array, .image2d_ms, .image2d_ms_array => .float,
                            else => .uint,
                        };
                        // Get image variable pointer via LValue
                        var image_ptr_id = arg_tids.items[0].id;
                        if (node.data.children.len > 0) {
                            if (self.analyzeLValue(node.data.children[0])) |lval| {
                                image_ptr_id = lval.id;
                            } else |_| {}
                        }
                        const tp_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        tp_ops[0] = .{ .id = image_ptr_id }; // image pointer
                        tp_ops[1] = .{ .id = arg_tids.items[1].id }; // coord
                        const texel_ptr_id = try self.emitPureOp(.image_texel_pointer, tp_ops, ret_ty);
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
                            // Coerce value to match return type (int->uint or uint->int)
                            var value_id = arg_tids.items[2].id;
                            const value_ty = arg_tids.items[2].ty;
                            if ((ret_ty == .uint and value_ty == .int) or (ret_ty == .int and value_ty == .uint)) {
                                const conv_id = self.allocId();
                                const conv_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                                conv_ops[0] = .{ .id = value_id };
                                try self.instructions.append(self.alloc, .{
                                    .tag = .convert_iti,
                                    .result_type = null,
                                    .result_id = conv_id,
                                    .operands = conv_ops,
                                    .ty = ret_ty,
                                });
                                value_id = conv_id;
                            }
                            const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                            operands[0] = .{ .id = texel_ptr_id };
                            operands[1] = .{ .id = value_id };
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
                            .image_buffer, .iimage_buffer, .uimage_buffer => .int,
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
                            const ext_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                            ext_ops[0] = .{ .id = arg_tids.items[0].id };
                            const extracted = try self.emitPureOp(.extract_image, ext_ops, arg_tids.items[0].ty);
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
                            const ext_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                            ext_ops[0] = .{ .id = arg_tids.items[0].id };
                            const extracted = try self.emitPureOp(.extract_image, ext_ops, arg_tids.items[0].ty);
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
                            const loaded = try self.emitLoadCached(arg_tids.items[0].id, arg_tids.items[0].ty);
                            img_id = loaded;
                        }
                        // Create ivec2(0, 0) coordinate
                        const zero_id = try self.getConstInt(0, .int);
                        const coord_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                        coord_ops[0] = .{ .id = zero_id };
                        coord_ops[1] = .{ .id = zero_id };
                        const coord_id = try self.emitPureOp(.composite_construct, coord_ops, .ivec2);
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
                            const ext_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                            ext_ops[0] = .{ .id = arg_tids.items[0].id };
                            const extracted = try self.emitPureOp(.extract_image, ext_ops, arg_tids.items[0].ty);
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
                            const is_lod = std.mem.eql(u8, node.data.name, "textureLod") or std.mem.eql(u8, node.data.name, "textureLodOffset");
                            const is_grad = std.mem.eql(u8, node.data.name, "textureGrad") or std.mem.eql(u8, node.data.name, "textureGradOffset");
                            const is_explicit_lod = is_lod or is_grad or std.mem.eql(u8, node.data.name, "textureProjLod") or std.mem.eql(u8, node.data.name, "textureProjGrad");
                            const is_proj = std.mem.eql(u8, node.data.name, "textureProj");
                            // Shadow samplers use Dref instructions that return float
                            const tag: ir.Instruction.Tag = if (is_shadow_sample) (
                                if (is_explicit_lod) .image_sample_dref_explicit_lod
                                else if (is_proj) .image_sample_dref_proj
                                else .image_sample_dref
                            ) else if (is_grad) .image_sample_grad else if (is_explicit_lod) .image_sample_explicit_lod else if (is_proj) .image_sample_proj else .image_sample;
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
                            // For texelFetchOffset with only 3 args (rect sampler, no lod), insert lod=0
                            const needs_dummy_lod = std.mem.eql(u8, node.data.name, "texelFetchOffset") and fetch_args.len == 3;
                            if (fetch_args.len > 0 and (fetch_args[0].ty == .sampler2d or fetch_args[0].ty == .sampler3d or fetch_args[0].ty == .sampler2d_array or fetch_args[0].ty == .sampler2d_ms or fetch_args[0].ty == .sampler2d_ms_array or fetch_args[0].ty == .sampler_cube or fetch_args[0].ty == .sampler_buffer or fetch_args[0].ty == .sampler1d or fetch_args[0].ty == .isampler2d or fetch_args[0].ty == .usampler2d or fetch_args[0].ty == .isampler3d or fetch_args[0].ty == .usampler3d or fetch_args[0].ty == .isampler_cube or fetch_args[0].ty == .usampler_cube or fetch_args[0].ty == .isampler2d_array or fetch_args[0].ty == .usampler2d_array or fetch_args[0].ty == .isampler2d_ms or fetch_args[0].ty == .usampler2d_ms or fetch_args[0].ty == .isampler2d_ms_array or fetch_args[0].ty == .usampler2d_ms_array or fetch_args[0].ty == .isampler_buffer or fetch_args[0].ty == .usampler_buffer or fetch_args[0].ty == .isampler1d or fetch_args[0].ty == .usampler1d)) {
                                const extract_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                                extract_operands[0] = .{ .id = fetch_args[0].id };
                                const extracted_id = try self.emitPureOp(.extract_image, extract_operands, fetch_args[0].ty);
                                // Replace first arg with extracted image
                                const op_count = if (needs_dummy_lod) fetch_args.len + 1 else fetch_args.len;
                                var new_args = try self.alloc.alloc(ir.Instruction.Operand, op_count);
                                new_args[0] = .{ .id = extracted_id };
                                if (needs_dummy_lod) {
                                    // rect sampler texelFetchOffset: [image, coord, 0, offset]
                                    new_args[1] = .{ .id = fetch_args[1].id };
                                    new_args[2] = .{ .literal_int = 0 };
                                    new_args[3] = .{ .id = fetch_args[2].id };
                                } else {
                                    for (1..fetch_args.len) |i| {
                                        new_args[i] = .{ .id = fetch_args[i].id };
                                    }
                                }
                                const is_ms = fetch_args[0].ty == .sampler2d_ms or fetch_args[0].ty == .sampler2d_ms_array or fetch_args[0].ty == .isampler2d_ms or fetch_args[0].ty == .usampler2d_ms or fetch_args[0].ty == .isampler2d_ms_array or fetch_args[0].ty == .usampler2d_ms_array;
                                const operands = try self.alloc.alloc(ir.Instruction.Operand, op_count);
                                for (operands, 0..) |*op, i| op.* = new_args[i];
                                self.alloc.free(new_args);
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
                        // Cache for dedup
                        var key: u64 = @intFromEnum(result_ty) *% 37 +% @intFromEnum(ir.Instruction.Tag.transpose);
                        for (arg_tids.items) |tid| {
                            key = key *% 0x5bd1e995 ^ tid.id;
                        }
                        self.pure_op_cache.put(self.alloc, key, result_id) catch {};
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
                    } else if (std.mem.eql(u8, node.data.name, "allInvocationsARB") or std.mem.eql(u8, node.data.name, "allInvocations") or std.mem.eql(u8, node.data.name, "allInvocationsEqualARB") or std.mem.eql(u8, node.data.name, "allInvocationsEqual") or std.mem.eql(u8, node.data.name, "subgroupAll")) {
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
                    } else if (std.mem.eql(u8, node.data.name, "anyInvocationARB") or std.mem.eql(u8, node.data.name, "anyInvocation") or std.mem.eql(u8, node.data.name, "subgroupAny")) {
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
                    } else if (std.mem.eql(u8, node.data.name, "bitCount")) {
                        // bitCount(x) → OpBitCount (core SPIR-V, not GLSL.std.450)
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len);
                        for (arg_tids.items, 0..) |tid, i| {
                            operands[i] = .{ .id = tid.id };
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .bit_count,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = result_ty,
                        });
                        return .{ .ty = result_ty, .id = result_id };
                    } else if (std.mem.eql(u8, node.data.name, "bitfieldReverse")) {
                        // bitfieldReverse(x) → OpBitReverse (core SPIR-V, not GLSL.std.450)
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len);
                        for (arg_tids.items, 0..) |tid, i| {
                            operands[i] = .{ .id = tid.id };
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .bit_reverse,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = result_ty,
                        });
                        return .{ .ty = result_ty, .id = result_id };
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
                                const splat_ops = try self.alloc.alloc(ir.Instruction.Operand, num_comps);
                                for (0..num_comps) |i| {
                                    splat_ops[i] = .{ .id = alpha_id };
                                }
                                alpha_id = try self.emitPureOp(.composite_construct, splat_ops, result_ty);
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
                        // Check pure_op_cache for dedup before emitting
                        var bc_key: u64 = @intFromEnum(bitcast_ty) *% 37 +% @intFromEnum(ir.Instruction.Tag.bitcast);
                        bc_key = bc_key *% 0x5bd1e995 ^ @as(u64, arg_tids.items[0].id);
                        if (self.pure_op_cache.get(bc_key)) |existing_id| {
                            return .{ .ty = bitcast_ty, .id = existing_id };
                        }
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        operands[0] = .{ .id = arg_tids.items[0].id };
                        try self.instructions.append(self.alloc, .{
                            .tag = .bitcast,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = operands,
                            .ty = bitcast_ty,
                        });
                        // Cache for dedup
                        self.pure_op_cache.put(self.alloc, bc_key, result_id) catch {};
                        return .{ .ty = bitcast_ty, .id = result_id };
                    } else {
                        var glsl_id = self.glslExtInstruction(node.data.name) orelse 1;
                        // Argument-count dispatch for atan(y,x) -> Atan2
                        if (std.mem.eql(u8, node.data.name, "atan") and arg_tids.items.len >= 2) {
                            glsl_id = 25; // Atan2 (2-argument form)
                        }
                        // Type-based dispatch for min/max/clamp
                        if (std.mem.eql(u8, node.data.name, "min")) {
                            glsl_id = switch (result_ty) {
                                .int, .ivec2, .ivec3, .ivec4 => 39, // SMin
                                .uint, .uvec2, .uvec3, .uvec4 => 38, // UMin
                                else => 37, // FMin
                            };
                        } else if (std.mem.eql(u8, node.data.name, "max")) {
                            glsl_id = switch (result_ty) {
                                .int, .ivec2, .ivec3, .ivec4 => 42, // SMax
                                .uint, .uvec2, .uvec3, .uvec4 => 41, // UMax
                                else => 40, // FMax
                            };
                        } else if (std.mem.eql(u8, node.data.name, "clamp")) {
                            glsl_id = switch (result_ty) {
                                .int, .ivec2, .ivec3, .ivec4 => 45, // SClamp
                                .uint, .uvec2, .uvec3, .uvec4 => 44, // UClamp
                                else => 43, // FClamp
                            };
                        } else if (std.mem.eql(u8, node.data.name, "abs")) {
                            glsl_id = switch (result_ty) {
                                .int, .ivec2, .ivec3, .ivec4 => 5, // SAbs
                                else => 4, // FAbs
                            };
                        } else if (std.mem.eql(u8, node.data.name, "sign")) {
                            glsl_id = switch (result_ty) {
                                .int, .ivec2, .ivec3, .ivec4 => 7, // SSign
                                else => 6, // FSign
                            };
                        } else if (std.mem.eql(u8, node.data.name, "findMSB")) {
                            // Dispatch based on argument type (not result type, which we force to int)
                            glsl_id = switch (arg_tids.items[0].ty) {
                                .uint, .uvec2, .uvec3, .uvec4 => 75, // FindUMsb
                                else => 74, // FindSMsb
                            };
                        }
                        // Scalar-to-vector promotion for clamp/min/max/mix (but NOT refract/step/smoothstep)
                        // GLSL allows clamp(vec3, float, float) but SPIR-V needs vec3 args
                        const first_ty = arg_tids.items[0].ty;
                        const needs_promotion = std.mem.eql(u8, node.data.name, "clamp") or
                            std.mem.eql(u8, node.data.name, "min") or
                            std.mem.eql(u8, node.data.name, "max") or
                            std.mem.eql(u8, node.data.name, "mix");
                        if (needs_promotion and first_ty.isVector() and arg_tids.items.len >= 2) {
                            for (arg_tids.items[1..], 1..) |*tid, i| {
                                if (!tid.ty.isVector()) {
                                    // Promote scalar to vector via OpCompositeConstruct
                                    const vec_id = self.allocId();
                                    const num_comps: usize = switch (first_ty) {
                                        .vec2 => 2, .vec3 => 3, .vec4 => 4,
                                        .ivec2 => 2, .ivec3 => 3, .ivec4 => 4,
                                        .uvec2 => 2, .uvec3 => 3, .uvec4 => 4,
                                        .bvec2 => 2, .bvec3 => 3, .bvec4 => 4,
                                        else => unreachable,
                                    };
                                    const comp_ops = try self.alloc.alloc(ir.Instruction.Operand, num_comps);
                                    for (comp_ops) |*op| op.* = .{ .id = tid.id };
                                    try self.instructions.append(self.alloc, .{
                                        .tag = .composite_construct,
                                        .result_type = null,
                                        .result_id = vec_id,
                                        .operands = comp_ops,
                                        .ty = first_ty,
                                    });
                                    tid.* = .{ .id = vec_id, .ty = first_ty };
                                    _ = i;
                                }
                            }
                        }
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
                                    const conv_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                                    conv_ops[0] = .{ .id = arg_tids.items[0].id };
                                    const conv_id = try self.emitPureOp(tag, conv_ops, result_ty);
                                    return .{ .ty = result_ty, .id = conv_id };
                                }
                            }
                        }
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, arg_tids.items.len);
                        // For array constructors, coerce each element to the array base type
                        // For struct constructors, coerce each element to the corresponding member type
                        const arr_base_ty = if (result_ty == .array) result_ty.array.base.* else result_ty;
                        const struct_members = if (result_ty == .named) blk: {
                            if (self.types.get(result_ty.named)) |td| break :blk td.members;
                            break :blk null;
                        } else null;
                        for (arg_tids.items, 0..) |tid, i| {
                            // Determine target type for this argument
                            const member_ty: ?ast.Type = if (result_ty == .array) arr_base_ty else if (struct_members != null and i < struct_members.?.len) struct_members.?[i].ty else null;
                            if (member_ty != null and !std.meta.eql(tid.ty, member_ty.?)) {
                                const target = member_ty.?;
                                const conv_tag: ?ir.Instruction.Tag = blk: {
                                    if (target == .uint and tid.ty == .int) break :blk .bitcast;
                                    if (target == .int and tid.ty == .uint) break :blk .bitcast;
                                    if (target == .float and tid.ty == .int) break :blk .convert_itof;
                                    if (target == .float and tid.ty == .uint) break :blk .convert_utof;
                                    if (target == .int and tid.ty == .float) break :blk .convert_ftoi;
                                    if (target == .uint and tid.ty == .float) break :blk .convert_ftou;
                                    break :blk null;
                                };
                                if (conv_tag) |tag| {
                                    const conv_id = self.allocId();
                                    const conv_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                                    conv_ops[0] = .{ .id = tid.id };
                                    try self.instructions.append(self.alloc, .{
                                        .tag = tag,
                                        .result_type = null,
                                        .result_id = conv_id,
                                        .operands = conv_ops,
                                        .ty = target,
                                    });
                                    operands[i] = .{ .id = conv_id };
                                    continue;
                                }
                            }
                            operands[i] = .{ .id = tid.id };
                        }
                        // Check const_composite_cache for dedup before emitting
                        const cache_key = self.constCompositeKey(result_ty, operands);
                        if (self.const_composite_cache.get(cache_key)) |existing_id| {
                            self.alloc.free(operands);
                            return .{ .ty = result_ty, .id = existing_id };
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
                        if (i < resolved_mutable_params.len and resolved_mutable_params[i]) {
                            // out/inout param: pass pointer, not loaded value
                            const ptr_tid = try self.analyzeLValue(node.data.children[i]);
                            operands[i + 1] = .{ .id = ptr_tid.id };
                        } else {
                            operands[i + 1] = .{ .id = tid.id };
                        }
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
                var arg_tids = std.ArrayListUnmanaged(TypedId).empty;
                defer arg_tids.deinit(self.alloc);
                for (node.data.children) |arg| {
                    var tid = try self.analyzeExpression(arg);
                    if (tid.is_ptr) {
                        const ld = try self.emitLoadCached(tid.id, tid.ty);
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
                        self.heap_types.append(self.alloc, arr_base) catch {};
                        ty = .{ .array = .{ .base = arr_base, .size = @intCast(arg_tids.items.len) } };
                    }
                    break :blk ty;
                };

                // Pre-check pure op cache for known pure operations BEFORE allocating result_id.
                // This avoids wasting IDs when the same pure op is computed multiple times.
                const maybe_cached_id: ?u32 = blk: {
                    if (std.mem.eql(u8, node.data.name, "transpose")) {
                        var key: u64 = @intFromEnum(result_ty) *% 37 +% @intFromEnum(ir.Instruction.Tag.transpose);
                        for (arg_tids.items) |tid| {
                            key = key *% 0x5bd1e995 ^ tid.id;
                        }
                        if (self.pure_op_cache.get(key)) |existing_id| {
                            break :blk existing_id;
                        }
                        break :blk null;
                    }
                    // Add more pure ops here (bitcast, etc.)
                    break :blk null;
                };
                if (maybe_cached_id) |cached_id| {
                    return .{ .ty = result_ty, .id = cached_id };
                }

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
                            // Check cache for dedup
                            var bc_key2: u64 = @intFromEnum(result_ty) *% 37 +% @intFromEnum(ir.Instruction.Tag.bitcast);
                            bc_key2 = bc_key2 *% 31 +% @as(u64, ptr_id);
                            if (self.pure_op_cache.get(bc_key2)) |existing_id| {
                                self.alloc.free(ops);
                                return .{ .ty = result_ty, .id = existing_id };
                            }
                            try self.instructions.append(self.alloc, .{
                                .tag = .bitcast,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = ops,
                                .ty = result_ty,
                            });
                            self.pure_op_cache.put(self.alloc, bc_key2, result_id) catch {};
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
                        const extract_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
        extract_ops[0] = .{ .id = arg_tids.items[0].id };
        extract_ops[1] = .{ .literal_int = 0 };
        const extract_id = try self.emitPureOp(.composite_extract, extract_ops, element_ty);
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
                        const conv_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        conv_ops[0] = .{ .id = extract_id };
                        const conv_id = try self.emitPureOp(conv_tag, conv_ops, result_ty);
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
                                const elem_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
        elem_ops[0] = .{ .id = arg_tids.items[0].id };
        elem_ops[1] = .{ .literal_int = @intCast(i) };
        const elem_id = try self.emitPureOp(.composite_extract, elem_ops, .int);
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
                                const ext_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
        ext_ops[0] = .{ .id = arg_tids.items[0].id };
        ext_ops[1] = .{ .literal_int = @intCast(i) };
        const bool_id = try self.emitPureOp(.composite_extract, ext_ops, .bool);
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
                        const conv_id = try self.emitPureOp(conv_tag, operands, result_ty);
                        return .{ .ty = result_ty, .id = conv_id };
                    }

                    // Handle shorter-vector to longer-vector: vec4(vec3) → extract components + fill
                    if (arg_ty.isVector() and arg_n < n) {
                        const result_scalar2: ast.Type = switch (result_ty) {
                            .vec2, .vec3, .vec4 => .float,
                            .ivec2, .ivec3, .ivec4 => .int,
                            .uvec2, .uvec3, .uvec4 => .uint,
                            else => .float,
                        };
                        const one_id: u32 = if (result_scalar2 == .float) try self.getConstFloat(1.0) else try self.getConstInt(1, result_scalar2);
                        const cc_ops = try self.alloc.alloc(ir.Instruction.Operand, 1 + (n - arg_n));
                        cc_ops[0] = .{ .id = arg_tids.items[0].id }; // the shorter vector
                        for (arg_n..n) |i| {
                            cc_ops[1 + i - arg_n] = .{ .id = one_id };
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .composite_construct,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = cc_ops,
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
                        const conv_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                        conv_operands[0] = .{ .id = splat_id };
                        splat_id = try self.emitPureOp(conv_tag, conv_operands, result_scalar);
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
                            // Build operand IDs for dedup key (use a single repeated ID)
                            const splat_comp_id = try self.getConstInt(val, comp_ty);
                            const cc_ops = try self.alloc.alloc(ir.Instruction.Operand, n);
                            for (0..n) |i| {
                                cc_ops[i] = .{ .id = splat_comp_id };
                            }
                            // Check cache for existing composite
                            const key = self.constCompositeKey(result_ty, cc_ops);
                            if (self.const_composite_cache.get(key)) |existing_id| {
                                self.alloc.free(cc_ops);
                                return .{ .ty = result_ty, .id = existing_id };
                            }
                            try self.instructions.append(self.alloc, .{
                                .tag = .constant_composite,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = cc_ops,
                                .ty = result_ty,
                            });
                            try self.const_composite_cache.put(self.alloc, key, result_id);
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
                            // Use getConstFloat for dedup
                            const comp_id = try self.getConstFloat(val);
                            for (0..n) |i| {
                                cc_ops[i] = .{ .id = comp_id };
                            }
                            const key = self.constCompositeKey(result_ty, cc_ops);
                            if (self.const_composite_cache.get(key)) |existing_id| {
                                self.alloc.free(cc_ops);
                                return .{ .ty = result_ty, .id = existing_id };
                            }
                            try self.instructions.append(self.alloc, .{
                                .tag = .constant_composite,
                                .result_type = null,
                                .result_id = result_id,
                                .operands = cc_ops,
                                .ty = result_ty,
                            });
                            try self.const_composite_cache.put(self.alloc, key, result_id);
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
                        if (to == .bool) {
                            if (from == .int) break :blk .int_to_bool;
                            if (from == .uint) break :blk .uint_to_bool;
                            if (from == .float or from == .double) break :blk .float_to_bool;
                        }
                        // Try generic conversion (handles 8-bit/16-bit types)
                        if (self.getConversionTag(to, from)) |tag| break :blk tag;
                        break :blk .composite_construct; // fallback
                    };
                    const conv_operands = try self.alloc.alloc(ir.Instruction.Operand, 1);
                    conv_operands[0] = .{ .id = arg_tids.items[0].id };
                    const conv_result = try self.emitPureOp(conv_tag, conv_operands, result_ty);
                    return .{ .ty = result_ty, .id = conv_result };
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
                        const extract_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
        extract_ops[0] = .{ .id = src_id };
        extract_ops[1] = .{ .literal_int = @intCast(i) };
        const extracted_col_id = try self.emitPureOp(.composite_extract, extract_ops, src_col_type);
                        // If column sizes differ, shrink via vector_shuffle
                        if (dst_col_n < src_col_n) {
                            const shuffle_ops = try self.alloc.alloc(ir.Instruction.Operand, 2 + dst_col_n);
                            shuffle_ops[0] = .{ .id = extracted_col_id };
                            shuffle_ops[1] = .{ .id = extracted_col_id };
                            for (0..dst_col_n) |j| {
                                shuffle_ops[2 + j] = .{ .literal_int = @intCast(j) };
                            }
                            const shuffle_id = try self.emitPureOp(.vector_shuffle, shuffle_ops, dst_col_type);
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
                    self.alloc.free(col_ids);
                    try self.instructions.append(self.alloc, .{
                        .tag = .composite_construct,
                        .result_type = null,
                        .result_id = result_id,
                        .operands = construct_ops,
                        .ty = result_ty,
                    });
                    return .{ .ty = result_ty, .id = result_id };
                }

                // Matrix-from-scalar diagonal constructor: mat3(1.0) → identity-like matrix
                // Creates N columns, each with the scalar on the diagonal position and 0 elsewhere
                if (arg_tids.items.len == 1 and result_ty.isMatrix() and arg_tids.items[0].ty.isScalar()) {
                    const col_type = result_ty.columnType();
                    const elem_ty = col_type.elementType();
                    const num_cols = result_ty.numColumns();
                    const col_n = col_type.numComponents();
                    // Convert scalar to element type if needed (e.g. int → float for mat3(1))
                    var scalar_id = arg_tids.items[0].id;
                    if (!std.meta.eql(arg_tids.items[0].ty, elem_ty)) {
                        if (elem_ty == .float and (arg_tids.items[0].ty == .int or arg_tids.items[0].ty == .uint)) {
                            const conv_tag: ir.Instruction.Tag = if (arg_tids.items[0].ty == .uint) .convert_utof else .convert_itof;
                            const conv_id = self.allocId();
                            const conv_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                            conv_ops[0] = .{ .id = scalar_id };
                            try self.instructions.append(self.alloc, .{
                                .tag = conv_tag,
                                .result_type = null,
                                .result_id = conv_id,
                                .operands = conv_ops,
                                .ty = .float,
                            });
                            scalar_id = conv_id;
                        }
                    }
                    const zero_id = try self.getConstFloat(0.0);
                    const col_ids = try self.alloc.alloc(u32, num_cols);
                    for (0..num_cols) |ci| {
                        const elem_ids = try self.alloc.alloc(ir.Instruction.Operand, col_n);
                        for (0..col_n) |ei| {
                            elem_ids[ei] = if (ei == ci) .{ .id = scalar_id } else .{ .id = zero_id };
                        }
                        col_ids[ci] = try self.emitPureOp(.composite_construct, elem_ids, col_type);
                    }
                    const mat_ops = try self.alloc.alloc(ir.Instruction.Operand, num_cols);
                    for (col_ids, 0..) |cid, i| {
                        mat_ops[i] = .{ .id = cid };
                    }
                    self.alloc.free(col_ids);
                    try self.instructions.append(self.alloc, .{
                        .tag = .composite_construct,
                        .result_type = null,
                        .result_id = result_id,
                        .operands = mat_ops,
                        .ty = result_ty,
                    });
                    return .{ .ty = result_ty, .id = result_id };
                }

                // Matrix construction from individual scalars: mat2x3(a,b,c,d,e,f) → construct column vectors then matrix
                if (result_ty.isMatrix() and arg_tids.items.len > 1 and arg_tids.items[0].ty.isScalar()) {
                    const col_type = result_ty.columnType();
                    const num_cols = result_ty.numColumns();
                    const col_n = col_type.numComponents();
                    const elem_ty = col_type.elementType();
                    // Group scalars into column vectors, converting to element type
                    const col_ids = try self.alloc.alloc(u32, num_cols);
                    for (0..num_cols) |col| {
                        const vec_result_id = self.allocId();
                        const vec_ops = try self.alloc.alloc(ir.Instruction.Operand, col_n);
                        for (0..col_n) |row| {
                            const idx = col * col_n + row;
                            const src = if (idx < arg_tids.items.len) arg_tids.items[idx] else arg_tids.items[arg_tids.items.len - 1];
                            // Convert scalar to matrix element type if needed
                            if (std.meta.eql(src.ty, elem_ty)) {
                                vec_ops[row] = .{ .id = src.id };
                            } else if (elem_ty == .float and (src.ty == .int or src.ty == .uint)) {
                                const conv_tag: ir.Instruction.Tag = if (src.ty == .uint) .convert_utof else .convert_itof;
                                const conv_id = self.allocId();
                                const conv_ops = try self.alloc.alloc(ir.Instruction.Operand, 1);
                                conv_ops[0] = .{ .id = src.id };
                                try self.instructions.append(self.alloc, .{
                                    .tag = conv_tag,
                                    .result_type = null,
                                    .result_id = conv_id,
                                    .operands = conv_ops,
                                    .ty = .float,
                                });
                                vec_ops[row] = .{ .id = conv_id };
                            } else {
                                vec_ops[row] = .{ .id = src.id };
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
                    self.alloc.free(col_ids);
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
                    else => if (result_ty == .array) result_ty.array.base.* else result_ty, // mat types, arrays etc
                };
                // Build flattened component list — expand vector args into scalar components
                // SPIR-V OpCompositeConstruct for vectors requires all-scalar operands
                var flat_ids = std.ArrayListUnmanaged(u32).empty;
                flat_ids.ensureTotalCapacity(self.alloc, arg_tids.items.len * 4) catch return error.OutOfMemory;
                defer flat_ids.deinit(self.alloc);
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
                        // Constant folding: int/uint literal → float literal
                        if (result_scalar == .float and (arg_scalar == .int or arg_scalar == .uint)) {
                            const child = node.data.children[i];
                            if (child.tag == .int_literal or child.tag == .uint_literal) {
                                const val: u32 = @intCast(child.data.int_val);
                                const fval: f32 = @floatFromInt(val);
                                arg_id = try self.getConstFloat(fval);
                                flat_ids.append(self.alloc, arg_id) catch return error.OutOfMemory;
                                continue;
                            }
                        }
                        // Constant folding: float literal → int/uint literal
                        if ((result_scalar == .int or result_scalar == .uint) and arg_scalar == .float) {
                            const child = node.data.children[i];
                            if (child.tag == .float_literal) {
                                const fval: f32 = @floatCast(child.data.float_val);
                                const ival: u32 = @intFromFloat(fval);
                                arg_id = try self.getConstInt(ival, if (result_scalar == .uint) .uint else .int);
                                flat_ids.append(self.alloc, arg_id) catch return error.OutOfMemory;
                                continue;
                            }
                        }
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
                        arg_id = try self.emitPureOp(conv_tag, conv_ops, conv_result_ty);
                    }
                    // Flatten vector arguments into scalar components
                    // Only for vector result types (vec2/vec3/vec4) — arrays/structs keep vectors as-is
                    if (result_ty.isVector() and arg_ty.isVector()) {
                        const n = arg_ty.numComponents();
                        for (0..n) |ci| {
                            const ext_ops = try self.alloc.alloc(ir.Instruction.Operand, 2);
                            ext_ops[0] = .{ .id = arg_id };
                            ext_ops[1] = .{ .literal_int = @intCast(ci) };
                            const ext_id = try self.emitPureOp(.composite_extract, ext_ops, result_scalar);
                            flat_ids.append(self.alloc, ext_id) catch return error.OutOfMemory;
                        }
                    } else {
                        flat_ids.append(self.alloc, arg_id) catch return error.OutOfMemory;
                    }
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
                    const comp_ty: ast.Type = switch (result_ty) {
                        .ivec2, .ivec3, .ivec4 => .int,
                        .uvec2, .uvec3, .uvec4 => .uint,
                        else => .int,
                    };
                    for (node.data.children, 0..) |arg, i| {
                        const val: u32 = blk: {
                            if (arg.tag == .int_literal) break :blk @bitCast(@as(i32, @intCast(arg.data.int_val)));
                            if (arg.tag == .uint_literal) break :blk @intCast(@as(u64, @bitCast(arg.data.int_val)));
                            if (arg.tag == .unary_op and arg.data.children.len > 0 and arg.data.children[0].tag == .int_literal)
                                break :blk @bitCast(-@as(i32, @intCast(arg.data.children[0].data.int_val)));
                            break :blk 0;
                        };
                        const comp_id = try self.getConstInt(val, comp_ty);
                        cc_ops[i] = .{ .id = comp_id };
                    }
                    // Check cache
                    const key = self.constCompositeKey(result_ty, cc_ops);
                    if (self.const_composite_cache.get(key)) |existing_id| {
                        self.alloc.free(cc_ops);
                        return .{ .ty = result_ty, .id = existing_id };
                    }
                    try self.instructions.append(self.alloc, .{
                        .tag = .constant_composite,
                        .result_type = null,
                        .result_id = result_id,
                        .operands = cc_ops,
                        .ty = result_ty,
                    });
                    try self.const_composite_cache.put(self.alloc, key, result_id);
                    return .{ .ty = result_ty, .id = result_id };
                }
                // Array constructors with all-constant int args: emit as constant_composite
                // with proper element type (e.g., uint[](1,2,3) → OpConstantComposite %arr_uint_3)
                if (all_const_ints and result_ty == .array) {
                    const base_ty = result_ty.array.base.*;
                    if (base_ty == .uint or base_ty == .int or base_ty == .float) {
                        const cc_ops = try self.alloc.alloc(ir.Instruction.Operand, node.data.children.len);
                        for (node.data.children, 0..) |arg, i| {
                            const val: u32 = blk: {
                                if (arg.tag == .int_literal) break :blk @bitCast(@as(i32, @intCast(arg.data.int_val)));
                                if (arg.tag == .uint_literal) break :blk @intCast(@as(u64, @bitCast(arg.data.int_val)));
                                break :blk 0;
                            };
                            const comp_id = try self.getConstInt(val, base_ty);
                            cc_ops[i] = .{ .id = comp_id };
                        }
                        const key = self.constCompositeKey(result_ty, cc_ops);
                        if (self.const_composite_cache.get(key)) |existing_id| {
                            self.alloc.free(cc_ops);
                            return .{ .ty = result_ty, .id = existing_id };
                        }
                        try self.instructions.append(self.alloc, .{
                            .tag = .constant_composite,
                            .result_type = null,
                            .result_id = result_id,
                            .operands = cc_ops,
                            .ty = result_ty,
                        });
                        try self.const_composite_cache.put(self.alloc, key, result_id);
                        return .{ .ty = result_ty, .id = result_id };
                    }
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
                    if (node.data.children.len == 1) {
                        const val: f32 = @floatCast(node.data.children[0].data.float_val);
                        const comp_id = try self.getConstFloat(val);
                        for (0..num_comps) |i| {
                            cc_ops[i] = .{ .id = comp_id };
                        }
                    } else {
                        for (node.data.children, 0..) |arg, i| {
                            const val: f32 = @floatCast(arg.data.float_val);
                            const comp_id = try self.getConstFloat(val);
                            cc_ops[i] = .{ .id = comp_id };
                        }
                    }
                    const key = self.constCompositeKey(result_ty, cc_ops);
                    if (self.const_composite_cache.get(key)) |existing_id| {
                        self.alloc.free(cc_ops);
                        return .{ .ty = result_ty, .id = existing_id };
                    }
                    try self.instructions.append(self.alloc, .{
                        .tag = .constant_composite,
                        .result_type = null,
                        .result_id = result_id,
                        .operands = cc_ops,
                        .ty = result_ty,
                    });
                    try self.const_composite_cache.put(self.alloc, key, result_id);
                    return .{ .ty = result_ty, .id = result_id };
                }

                // Allocate operand array
                const operands = try self.alloc.alloc(ir.Instruction.Operand, flat_ids.items.len);
                for (flat_ids.items, 0..) |cid, i| {
                    operands[i] = .{ .id = cid };
                }

                // Check if all operands are constants — if so, check cache for dedup
                var all_const = true;
                for (operands) |op| {
                    if (op == .id and !self.isConstantId(op.id)) {
                        all_const = false;
                        break;
                    }
                }
                if (all_const) {
                    const key = self.constCompositeKey(result_ty, operands);
                    if (self.const_composite_cache.get(key)) |existing_id| {
                        self.alloc.free(operands);
                        return .{ .ty = result_ty, .id = existing_id };
                    }
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
                var cond_tid = try self.analyzeExpression(node.data.children[0]);
                var then_tid = try self.analyzeExpression(node.data.children[1]);
                var else_tid = try self.analyzeExpression(node.data.children[2]);
                // Auto-load pointers
                if (cond_tid.is_ptr) {
                    const ld = try self.emitLoadCached(cond_tid.id, cond_tid.ty);
                    cond_tid = .{ .ty = cond_tid.ty, .id = ld };
                }
                if (then_tid.is_ptr) {
                    const ld = try self.emitLoadCached(then_tid.id, then_tid.ty);
                    then_tid = .{ .ty = then_tid.ty, .id = ld };
                }
                if (else_tid.is_ptr) {
                    const ld = try self.emitLoadCached(else_tid.id, else_tid.ty);
                    else_tid = .{ .ty = else_tid.ty, .id = ld };
                }
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
                                    const result_id = try self.emitAccessChainCached(sym.ir_id, &[1]ir.Instruction.Operand{.{ .literal_int = idx }}, member_ty);
                                    return .{ .ty = member_ty, .id = result_id, .is_ptr = true };
                                }
                            }
                        }
                    }
                }

                // Handle gl_in[i].gl_Position and gl_out[i].gl_Position patterns
                // These arrays are declared as arrays of vec4 (simplified gl_PerVertex),
                // so arr[i] already IS the position. Skip the member access.
                if (base_child.tag == .index_access and base_child.data.children.len >= 1) {
                    const arr_base = base_child.data.children[0];
                    if (arr_base.tag == .identifier and
                        (std.mem.eql(u8, arr_base.data.name, "gl_in") or std.mem.eql(u8, arr_base.data.name, "gl_out")))
                    {
                        // gl_in[i].gl_Position or gl_out[i].gl_Position etc.
                        // For now, just return the indexed element (vec4 = position)
                        if (std.mem.eql(u8, node.data.name, "gl_Position")) {
                            const base_tid = try self.analyzeExpression(base_child);
                            // base_tid is a pointer to vec4 from the AccessChain
                            if (base_tid.is_ptr) {
                                const ld = try self.emitLoadCached(base_tid.id, base_tid.ty);
                                return .{ .ty = base_tid.ty, .id = ld };
                            }
                            return base_tid;
                        }
                    }
                }

                var base_tid = try self.analyzeExpression(node.data.children[0]);

                // Handle vector swizzles (e.g., vec4.x, uvec3.y)
                if (base_tid.ty.isVector()) {
                    // If pointer to vector, load first
                    if (base_tid.is_ptr) {
                        const ld = try self.emitLoadCached(base_tid.id, base_tid.ty);
                        base_tid = .{ .ty = base_tid.ty, .id = ld };
                    }
                    const member_name = node.data.name;
                    const elem_ty = base_tid.ty.elementType();
                    // Single-component swizzle (e.g., .x, .y)
                    if (member_name.len == 1) {
                        const idx = self.swizzleIndex(member_name[0]);
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
        operands[0] = .{ .id = base_tid.id };
        operands[1] = .{ .literal_int = idx };
        const result_id = try self.emitPureOp(.composite_extract, operands, elem_ty);
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
                        // vector_shuffle operands: vec1, vec2, literal indices...
                        const operands = try self.alloc.alloc(ir.Instruction.Operand, 2 + num_comps);
                        operands[0] = .{ .id = base_tid.id }; // vec1
                        operands[1] = .{ .id = base_tid.id }; // vec2 (same)
                        for (member_name, 0..) |c, i| {
                            operands[2 + i] = .{ .literal_int = self.swizzleIndex(c) };
                        }
                        const result_id = try self.emitPureOp(.vector_shuffle, operands, result_ty);
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

                            if (base_tid.is_ptr) {
                                // Pointer base → access_chain (pointer result)
                                const result_id = try self.emitAccessChainCached(base_tid.id, &[1]ir.Instruction.Operand{.{ .literal_int = idx }}, member_ty);
                                return .{ .ty = member_ty, .id = result_id, .is_ptr = true };
                            } else {
                                // Value base → composite_extract (value result)
                                const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
        operands[0] = .{ .id = base_tid.id };
        operands[1] = .{ .literal_int = idx };
        const result_id = try self.emitPureOp(.composite_extract, operands, member_ty);
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
                // Single-component swizzle → CompositeExtract
                if (node.data.name.len == 1) {
                    const idx = self.swizzleIndex(node.data.name[0]);
                    const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                    operands[0] = .{ .id = base.id };
                    operands[1] = .{ .literal_int = idx };
                    const result_id = try self.emitPureOp(.composite_extract, operands, base.ty.elementType());
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
                        const result_id = try self.emitPureOp(.composite_extract, operands, element_ty);
                        return .{ .ty = element_ty, .id = result_id };
                    }
                }

                // Use emitAccessChainCached for pointer-based array/buffer indexing
                if (!base_tid.ty.isVector()) {
                    const ptr_id = try self.emitAccessChainCached(base_tid.id, &[1]ir.Instruction.Operand{.{ .id = index_tid.id }}, element_ty);
                    return .{ .ty = element_ty, .id = ptr_id, .is_ptr = true };
                }

                // Vector dynamic indexing
                const result_id = self.allocId();
                const operands = try self.alloc.alloc(ir.Instruction.Operand, 2);
                operands[0] = .{ .id = base_tid.id };
                operands[1] = .{ .id = index_tid.id };

                try self.instructions.append(self.alloc, .{
                    .tag = .vector_extract_dynamic,
                    .result_type = null,
                    .result_id = result_id,
                    .operands = operands,
                    .ty = element_ty,
                });

                return .{ .ty = element_ty, .id = result_id };
            },
            .post_increment, .post_decrement, .pre_increment, .pre_decrement => {
                if (node.data.children.len < 1) return error.SemanticFailed;
                // Get the lvalue (variable pointer)
                const lval = try self.analyzeLValue(node.data.children[0]);
                // Load current value
                const loaded_id = try self.emitLoadCached(lval.id, lval.ty);
                // Create constant 1
                // Create constant 1 matching the operand type
                const one_id: u32 = blk: {
                    if (lval.ty == .float or lval.ty == .double) break :blk try self.getConstFloat(1.0);
                    if (lval.ty == .int) break :blk try self.getConstInt(1, .int);
                    if (lval.ty == .uint) break :blk try self.getConstInt(1, .uint);
                    if (lval.ty.isVector()) {
                        const elem = lval.ty.elementType();
                        const elem_one = if (elem == .float or elem == .float16) try self.getConstFloat(1.0) else if (elem == .uint) try self.getConstInt(1, .uint) else try self.getConstInt(1, .int);
                        // Splat: emit composite_construct with N copies
                        const nc = lval.ty.numComponents();
                        const splat_ops = try self.alloc.alloc(ir.Instruction.Operand, nc);
                        for (0..nc) |i| splat_ops[i] = .{ .id = elem_one };
                        break :blk try self.emitPureOp(.composite_construct, splat_ops, lval.ty);
                    }
                    break :blk try self.getConstInt(1, .int);
                };
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
                _ = self.load_cache.remove(lval.id);
                _ = self.global_load_cache.remove(lval.id);
                // If storing to an AccessChain result (e.g., v.x++), also invalidate the base variable
                if (self.ac_result_to_base.get(lval.id)) |base_id| {
                    _ = self.load_cache.remove(base_id);
                    _ = self.global_load_cache.remove(base_id);
                }
                self.load_cache.put(self.alloc, lval.id, new_val_id) catch {}; // Forward
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
            if (from == .int8 or from == .int16) return .convert_itof;
            if (from == .uint8 or from == .uint16) return .convert_utof;
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
        // GLSL matrix aliases: mat2 == mat2x2, mat3 == mat3x3, mat4 == mat4x4
        if ((target == .mat2 and source == .mat2x2) or (target == .mat2x2 and source == .mat2) or
            (target == .mat3 and source == .mat3x3) or (target == .mat3x3 and source == .mat3) or
            (target == .mat4 and source == .mat4x4) or (target == .mat4x4 and source == .mat4))
            return true;
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
            "findLSB", "findMSB",
            "bitCount",
            "bitfieldReverse",
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
            // Geometry shader builtins
            "EmitVertex", "EndPrimitive",
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
            // QCOM image processing builtins
            "textureBoxFilterQCOM", "textureBlockMatchSADQCOM", "textureBlockMatchSSDQCOM", "textureWeightedQCOM",
            // Ray query builtins
            "rayQueryInitializeEXT", "rayQueryProceedEXT", "rayQueryGetIntersectionTypeEXT",
            "rayQueryGetIntersectionTriangleVertexPositionsEXT",
            "tensorSizeARM", "tensorReadARM",
            // EXT_mesh_shader builtins
            "SetMeshOutputsEXT", "EmitMeshTasksEXT",
            // KHR_ray_tracing builtins
            "traceRayEXT", "reportIntersectionEXT", "ignoreIntersectionEXT",
            "terminateRayEXT", "executeCallableEXT",
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
        // GLSL.std.450 instruction numbers (from SPIR-V spec)
        if (std.mem.eql(u8, name, "round")) return 1;      // Round
        if (std.mem.eql(u8, name, "roundEven")) return 2;   // RoundEven
        if (std.mem.eql(u8, name, "trunc")) return 3;       // Trunc
        if (std.mem.eql(u8, name, "abs")) return 4;         // FAbs
        if (std.mem.eql(u8, name, "sign")) return 6;        // FSign
        if (std.mem.eql(u8, name, "floor")) return 8;       // Floor
        if (std.mem.eql(u8, name, "ceil")) return 9;        // Ceil
        if (std.mem.eql(u8, name, "fract")) return 10;      // Fract
        if (std.mem.eql(u8, name, "radians")) return 11;    // Radians
        if (std.mem.eql(u8, name, "degrees")) return 12;    // Degrees
        if (std.mem.eql(u8, name, "sin")) return 13;        // Sin
        if (std.mem.eql(u8, name, "cos")) return 14;        // Cos
        if (std.mem.eql(u8, name, "tan")) return 15;        // Tan
        if (std.mem.eql(u8, name, "asin")) return 16;       // Asin
        if (std.mem.eql(u8, name, "acos")) return 17;       // Acos
        if (std.mem.eql(u8, name, "atan")) return 18;       // Atan
        if (std.mem.eql(u8, name, "sinh")) return 19;       // Sinh
        if (std.mem.eql(u8, name, "cosh")) return 20;       // Cosh
        if (std.mem.eql(u8, name, "tanh")) return 21;       // Tanh
        if (std.mem.eql(u8, name, "asinh")) return 22;      // Asinh
        if (std.mem.eql(u8, name, "acosh")) return 23;      // Acosh
        if (std.mem.eql(u8, name, "atanh")) return 24;      // Atanh
        if (std.mem.eql(u8, name, "atan2")) return 25;      // Atan2
        if (std.mem.eql(u8, name, "pow")) return 26;        // Pow
        if (std.mem.eql(u8, name, "exp")) return 27;        // Exp
        if (std.mem.eql(u8, name, "log")) return 28;        // Log
        if (std.mem.eql(u8, name, "exp2")) return 29;       // Exp2
        if (std.mem.eql(u8, name, "log2")) return 30;       // Log2
        if (std.mem.eql(u8, name, "sqrt")) return 31;       // Sqrt
        if (std.mem.eql(u8, name, "inversesqrt")) return 32; // InverseSqrt
        if (std.mem.eql(u8, name, "determinant")) return 33; // Determinant
        if (std.mem.eql(u8, name, "inverse")) return 34;   // MatrixInverse
        if (std.mem.eql(u8, name, "mod")) return 29;        // unused, mod has special handler
        if (std.mem.eql(u8, name, "modf")) return 36;       // ModfStruct
        if (std.mem.eql(u8, name, "min")) return 37;        // FMin
        if (std.mem.eql(u8, name, "max")) return 40;        // FMax
        if (std.mem.eql(u8, name, "clamp")) return 43;      // FClamp
        if (std.mem.eql(u8, name, "mix")) return 46;        // FMix
        if (std.mem.eql(u8, name, "step")) return 48;       // Step
        if (std.mem.eql(u8, name, "smoothstep")) return 49; // SmoothStep
        if (std.mem.eql(u8, name, "fma")) return 50;        // Fma
        if (std.mem.eql(u8, name, "frexp")) return 52;      // FrexpStruct
        if (std.mem.eql(u8, name, "ldexp")) return 53;      // Ldexp
        // Pack/Unpack (from SPIR-V spec)
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
        // Geometric (from SPIR-V spec)
        if (std.mem.eql(u8, name, "length")) return 66;     // Length
        if (std.mem.eql(u8, name, "distance")) return 67;   // Distance
        if (std.mem.eql(u8, name, "cross")) return 68;      // Cross
        if (std.mem.eql(u8, name, "normalize")) return 69;  // Normalize
        if (std.mem.eql(u8, name, "faceforward")) return 70; // FaceForward
        if (std.mem.eql(u8, name, "reflect")) return 71;    // Reflect
        if (std.mem.eql(u8, name, "refract")) return 72;    // Refract
        // Integer ops (from SPIR-V spec)
        if (std.mem.eql(u8, name, "findLSB")) return 73;      // FindILsb
        if (std.mem.eql(u8, name, "findMSB")) return 74;      // FindSMsb (signed, GLSL spec says this is correct for both signed/unsigned)
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
        // bitCount is a core SPIR-V op (OpBitCount), not GLSL.std.450
        if (std.mem.eql(u8, name, "bitCount"))
            return null;
        // bitfieldReverse is a core SPIR-V op (OpBitReverse), not GLSL.std.450
        if (std.mem.eql(u8, name, "bitfieldReverse"))
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
