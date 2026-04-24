const std = @import("std");
const ast = @import("ast.zig");

pub const LocalSize = struct { x: u32, y: u32, z: u32 };

pub const Module = struct {
    functions: []const Function,
    globals: []const Global,
    types: std.StringHashMapUnmanaged(TypeDef),
    entry_point: ?*Function,
    next_id_start: u32 = 1,
    alloc: std.mem.Allocator,
    local_size: ?LocalSize = null,

    pub fn deinit(self: *Module) void {
        for (self.functions) |func| {
            for (func.body) |inst| {
                if (inst.operands.len > 0) {
                    self.alloc.free(inst.operands);
                }
            }
            self.alloc.free(func.body);
        }
        self.alloc.free(self.functions);
        self.alloc.free(self.globals);
        var iter = self.types.iterator();
        while (iter.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.members);
        }
        self.types.deinit(self.alloc);
    }
};

pub const Function = struct {
    name: []const u8,
    return_type: ast.Type,
    params: []const ast.FunctionParam,
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
        local_variable,
        load,
        store,
        add,
        sub,
        mul,
        div,
        rem,
        fadd,
        fsub,
        fmul,
        mat_vec_mul,
        vec_mat_mul,
        mat_mat_mul,
        vec_scalar_mul,
        scalar_vec_mul,
        fdiv,
        neg,
        fneg,
        not_op,
        convert_ftoi,
        convert_ftou,
        convert_uti,
        convert_iti,
        convert_itof,
        convert_utof,
        vector_shuffle,
        composite_construct,
        composite_extract,
        access_chain,
        member_access_op,
        image_sample,
        image_fetch,
        return_val,
        return_void,
        branch,
        branch_conditional,
        label,
        loop_merge,
        selection_merge,
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
        shift_left,
        shift_right,
        ext_inst,
        select,
        function_call,
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
};