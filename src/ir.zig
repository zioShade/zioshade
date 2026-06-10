// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const ast = @import("ast.zig");

pub const LocalSize = struct { x: u32, y: u32, z: u32 };

// Specialization constant entry.
//
// For SCALAR spec consts (`OpSpecConstant` / `OpSpecConstantTrue/False`),
// `component_literals` is a length-1 slice — for bools it carries 0/1 so
// codegen can pick `True` vs `False`.
//
// For VECTOR/MATRIX spec consts (`OpSpecConstantComposite`), the slice
// length matches `numComponents()` for the `type_tag` (2/3/4 for vec,
// 4/9/16 for mat). Codegen emits one `OpSpecConstant` per component
// (each with its own `SpecId = spec_id + i`) and groups them with an
// `OpSpecConstantComposite` whose result_id is the entry's `result_id`.
//
// The slice is allocated from the Module's allocator and freed in
// `Module.deinit`.
pub const SpecConstant = struct {
    result_id: u32,
    spec_id: u32,
    component_literals: []const u32,
    type_tag: u32,
};

/// Derived specialization-constant expression: const int X = SIZE * 2;
/// emits an OpSpecConstantOp (opcode 52) that the consumer re-evaluates
/// at pipeline-creation time whenever any leaf spec constant is overridden.
/// result_id is the SSA id assigned to the derived const so that
/// references in shader code resolve to it directly.
pub const SpecConstantOp = struct {
    /// SSA id of the derived const itself.
    result_id: u32,
    /// AST type tag of the result (matches operand types -- v1 limits scope
    /// to scalar arithmetic so all operands share this type).
    type_tag: u32,
    /// SPIR-V opcode applied to the operands. v1 emits one of:
    /// IAdd(128), FAdd(129), ISub(130), FSub(131), IMul(132), FMul(133),
    /// SDiv(135), FDiv(136).
    spirv_opcode: u32,
    /// IDs of the operands. Each must already be a regular OpConstant or
    /// a spec constant / derived spec constant emitted earlier. Owned
    /// slice; freed in `Module.deinit`.
    operand_ids: []const u32,
    /// User-visible GLSL identifier this derived constant was bound to,
    /// if any. Set for top-level `const T NAME = <spec-expr>;` declarations;
    /// `null` for intermediate sub-expressions that never receive a user-
    /// facing binding. Codegen uses this (when set) to emit an OpName so
    /// downstream backends print the original identifier instead of the
    /// auto-generated `v{id}` fallback. Borrowed view into the
    /// `spec_constant_ops` map key when present; not separately owned.
    user_name: ?[]const u8 = null,
};

/// Literal constants required by spec_constant_ops operands. Semantic emits
/// an entry per literal (deduped by type+value); codegen lowers each to an
/// OpConstant before the OpSpecConstantOp consumers, and also populates the
/// codegen-side emitted_constants cache so function-body references reuse
/// the same SSA id.
pub const SpecOpLiteralConst = struct {
    result_id: u32,
    type_tag: u32,
    /// For int/uint/bool: raw u32 value. For float: f32 bit-pattern.
    value: u32,
};

pub const Module = struct {
    functions: []const Function,
    globals: []const Global,
    types: std.StringHashMapUnmanaged(TypeDef),
    entry_point: ?*Function,
    next_id_start: u32 = 1,
    alloc: std.mem.Allocator,
    local_size: ?LocalSize = null,
    // Heap-allocated AST types that must be freed with the module
    heap_types: []*ast.Type = &.{},
    spec_constants: std.StringHashMapUnmanaged(SpecConstant) = .{},
    /// Derived spec-const expressions: keyed by GLSL identifier; insertion-
    /// ordered so codegen can emit them in their natural dependency order
    /// (operands always refer to earlier entries or to scalar spec consts).
    spec_constant_ops: std.StringArrayHashMapUnmanaged(SpecConstantOp) = .{},
    /// Literal-constant operands referenced by spec_constant_ops. Owned;
    /// freed in Module.deinit. Order doesn't matter (codegen scans by value).
    spec_op_literals: []const SpecOpLiteralConst = &.{},
    /// Self-contained constant instructions (scalar OpConstants + the folded
    /// OpConstantComposite) for module-scope `const` global initializers,
    /// in dependency order (operands appear before the composite that uses
    /// them). Codegen replays these in the constants section BEFORE emitting
    /// the global OpVariables, so a Private variable's initializer operand
    /// (`Global.initializer_id`) is never a forward reference. Owned; each
    /// instruction's `operands` slice and the outer slice are freed in deinit.
    global_init_constants: []const Instruction = &.{},
    // Fragment shader depth / early test flags
    depth_greater: bool = false,
    depth_less: bool = false,
    depth_unchanged: bool = false,
    early_fragment_tests: bool = false,
    pixel_interlock_ordered: bool = false,
    pixel_interlock_unordered: bool = false,
    sample_interlock_ordered: bool = false,
    sample_interlock_unordered: bool = false,
    origin_upper_left: bool = false,
    uses_qcom_image_processing: bool = false,
    uses_ray_query: bool = false,
    uses_ray_query_position_fetch: bool = false,
    uses_arm_tensors: bool = false,
    uses_ext_mesh_shader: bool = false,
    // interpolateAtCentroid/Sample/Offset → OpCapability InterpolationFunction.
    uses_interpolation_function: bool = false,
    // textureGatherOffsets (ConstOffsets image operand) → OpCapability
    // ImageGatherExtended.
    uses_image_gather_extended: bool = false,
    qcom_block_match_textures: []const u32 = &.{},
    qcom_weight_textures: []const u32 = &.{},
    // Mesh shader layout parameters
    mesh_max_vertices: ?u32 = null,
    mesh_max_primitives: ?u32 = null,
    mesh_output_topology: ?ast.OutputTopology = null,
    geometry_input_topology: ?ast.InputTopology = null,
    geometry_output_topology: ?ast.OutputTopology = null,
    geometry_max_vertices: ?u32 = null,
    tess_vertices: ?u32 = null,
    tess_input_topology: ?ast.InputTopology = null,
    tess_spacing: ?ast.TessSpacing = null,
    tess_vertex_order_ccw: ?bool = null,

    pub fn deinit(self: *Module) void {
        for (self.functions) |func| {
            for (func.body) |inst| {
                if (inst.operands.len > 0) {
                    self.alloc.free(inst.operands);
                }
            }
            self.alloc.free(func.body);
            if (func.param_ids.len > 0) {
                self.alloc.free(func.param_ids);
            }
        }
        self.alloc.free(self.functions);
        self.alloc.free(self.globals);
        var iter = self.types.iterator();
        while (iter.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.members);
        }
        self.types.deinit(self.alloc);
        // Free spec_constants keys and component_literals slices
        {
            var sc_iter = self.spec_constants.iterator();
            while (sc_iter.next()) |entry| {
                self.alloc.free(entry.key_ptr.*);
                if (entry.value_ptr.component_literals.len > 0) {
                    self.alloc.free(entry.value_ptr.component_literals);
                }
            }
        }
        self.spec_constants.deinit(self.alloc);
        // Free spec_constant_ops keys and operand_ids slices
        {
            var sco_iter = self.spec_constant_ops.iterator();
            while (sco_iter.next()) |entry| {
                self.alloc.free(entry.key_ptr.*);
                if (entry.value_ptr.operand_ids.len > 0) {
                    self.alloc.free(entry.value_ptr.operand_ids);
                }
            }
        }
        self.spec_constant_ops.deinit(self.alloc);
        if (self.spec_op_literals.len > 0) {
            self.alloc.free(self.spec_op_literals);
        }
        for (self.global_init_constants) |inst| {
            if (inst.operands.len > 0) self.alloc.free(inst.operands);
        }
        if (self.global_init_constants.len > 0) {
            self.alloc.free(self.global_init_constants);
        }
        // Free heap-allocated AST types
        for (self.heap_types) |ptr| {
            self.alloc.destroy(ptr);
        }
        if (self.heap_types.len > 0) {
            self.alloc.free(self.heap_types);
        }
    }
};

pub const Function = struct {
    name: []const u8,
    return_type: ast.Type,
    params: []const ast.FunctionParam,
    param_ids: []const u32 = &.{},
    body: []const Instruction,
    locals: []const Local,
    result_id: u32 = 0,
};

pub const Global = struct {
    name: []const u8,
    ty: ast.Type,
    qualifier: ast.Qualifier,
    layout: ?ast.Layout,
    storage_class: SPIRVStorageClass,
    result_id: u32 = 0,
    /// For a module-scope `const` global (lowered to a Private OpVariable):
    /// the result-id of the folded OpConstantComposite that codegen emits as
    /// the variable's initializer operand (word-count 5). The composite (and
    /// its scalar operands) live in `Module.global_init_constants`. null = no
    /// initializer (the OpVariable is word-count 4 as before).
    initializer_id: ?u32 = null,
};

pub const Local = struct {
    name: []const u8,
    ty: ast.Type,
    result_id: u32 = 0,
};

pub const TypeDef = struct {
    name: []const u8,
    members: []const ast.StructMember,
    size_bytes: u32,
    is_buffer_reference: bool = false,
    /// True only when this type was declared as an `in`/`out` interface BLOCK
    /// (`in Name { ... } inst;`), as opposed to a plain `struct` that merely
    /// happens to be used as an input/output variable (`struct S {..}; in S v;`).
    /// Real in/out interface blocks require an `OpDecorate <struct> Block`
    /// decoration (the adjacent stage interface-matches on it); plain struct IO
    /// variables do NOT (glslang emits no Block for them). UBO/SSBO blocks get
    /// Block via the storage-class scan in codegen, so this flag is set ONLY for
    /// the in/out case. The distinction is in the AST (`.uniform_block` node) but
    /// otherwise lost in the IR, so it is carried here.
    is_io_interface_block: bool = false,
};

pub const Instruction = struct {
    tag: Tag,
    result_type: ?u32 = null,
    result_id: ?u32 = null,
    operands: []const Operand = &.{},
    ty: ast.Type = .void, // AST type for codegen type resolution

    pub const Tag = enum {
        constant_int,
        constant_float,
        constant_bool,
        constant_composite,
        control_barrier,
        memory_barrier,
        spec_constant,
        local_variable,
        load,
        store,
        add,
        sub,
        mul,
        div,
        rem,
        umod,
        fadd,
        fsub,
        fmod,
        fmul,
        mat_vec_mul,
        vec_mat_mul,
        mat_mat_mul,
        vec_scalar_mul,
        scalar_vec_mul,
        mat_scalar_mul,
        scalar_mat_mul,
        fdiv,
        neg,
        fneg,
        not_op,
        convert_ftoi,
        convert_ftou,
        convert_uti,
        convert_iti,
        convert_itof,
        convert_itu,
        bitcast,
        convert_utof,
        convert_narrow, // OpSConvert: int/int16 → int8, or ivec4 → i8vec4
        convert_widen, // OpSConvert: int8/int16 → int, or i8vec4 → ivec4
        convert_ftof, // OpFConvert: float ↔ float16, or vec4 ↔ f16vec4
        bool_to_float,
        bool_to_int,
        bool_to_uint,
        int_to_bool,
        uint_to_bool,
        float_to_bool,
        is_nan,
        is_inf,
        any,
        all,
        vector_shuffle,
        composite_construct,
        composite_extract,
        access_chain,
        array_length, // OpArrayLength — runtime SSBO array .length()
        vector_extract_dynamic,
        member_access_op,
        image_sample,
        image_sample_explicit_lod,
        image_sample_grad,
        image_sample_proj,
        image_sample_dref,
        image_sample_dref_explicit_lod,
        image_sample_dref_proj,
        image_gather,
        // textureGatherOffsets: like image_gather but carries a 4-element
        // constant ivec2 offsets array, emitted as the ConstOffsets image
        // operand. Fixed operand layout: [sampled_image, coord, component,
        // offsets_array] (component is always present, defaulted to const int 0
        // in semantic when GLSL omits it). A dedicated tag keeps plain
        // image_gather codegen byte-identical and lets the cross-compile
        // backends honest-error on the unrepresentable per-texel offsets.
        image_gather_offsets,
        image_dref_gather,
        image_fetch,
        image_fetch_ms,
        extract_image,
        sampled_image,
        image_query_size,
        image_query_size_lod,
        image_query_levels,
        image_query_samples,
        image_query_lod,
        image_read,
        image_write,
        image_box_filter_qcom,
        image_block_match_sad_qcom,
        image_block_match_ssd_qcom,
        image_sample_weighted_qcom,
        ray_query_initialize,
        ray_query_proceed,
        ray_query_get_intersection_type,
        ray_query_get_triangle_vertex_positions,
        tensor_query_size_arm,
        tensor_read_arm,
        image_texel_pointer,
        atomic_iadd,
        atomic_isub,
        atomic_smin,
        atomic_umin,
        atomic_smax,
        atomic_umax,
        atomic_and,
        atomic_or,
        atomic_xor,
        atomic_exchange,
        atomic_comp_swap,
        atomic_fadd,
        transpose,
        outer_product,
        dot,
        derivative,
        fwidth,
        return_val,
        return_void,
        kill,
        unreachable_inst,
        branch,
        branch_conditional,
        label,
        loop_merge,
        selection_merge,
        switch_inst,
        compare_eq,
        compare_neq,
        compare_lt,
        compare_gt,
        compare_lte,
        compare_gte,
        compare_feq,
        compare_fneq,
        compare_flt,
        compare_fgt,
        compare_flte,
        compare_fgte,
        logical_and,
        logical_or,
        logical_not,
        bit_and,
        bit_or,
        bit_xor,
        bit_not,
        bit_count,
        bit_reverse,
        bit_field_insert,
        bit_field_s_extract,
        bit_field_u_extract,
        shift_left,
        shift_right,
        ext_inst,
        select,
        function_call,
        group_all,
        group_any,
        group_non_uniform_elect,
        set_mesh_outputs,
        emit_mesh_tasks,
        report_intersection,
        ignore_intersection,
        terminate_ray,
        execute_callable,
        trace_ray,
        begin_invocation_interlock,
        end_invocation_interlock,
        emit_vertex,
        end_primitive,
    };

    pub const Operand = union(enum) {
        id: u32,
        literal_int: u32,
        literal_float: f32,
        literal_string: []const u8,
    };
};

pub const SPIRVStorageClass = enum(u32) {
    uniform_constant = 0,
    input = 1,
    uniform = 2,
    output = 3,
    private = 6,
    function = 7,
    push_constant = 9,
    workgroup = 4,
    physical_storage_buffer = 5349,
    storage_buffer = 12,
    image = 11,
    task_payload_workgroup = 5402,
    ray_payload = 5338,
    incoming_ray_payload = 5339,
    hit_attribute = 5340,
    callable_data = 5328,
    incoming_callable_data = 5327,
};
