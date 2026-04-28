const std = @import("std");

pub const Root = struct {
    version: ?u32,
    body: []const Node,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *Root) void {
        self.alloc.free(self.body);
    }
};

pub const Node = struct {
    tag: Tag,
    loc: Loc,
    data: Data,

    pub const Loc = struct {
        line: u32,
        column: u32,
    };

    pub const Tag = enum {
        precision_decl,
        var_decl,
        var_decl_multi,
        uniform_decl,
        uniform_block,
        in_decl,
        out_decl,
        layout_decl,
        struct_decl,
        function_decl,
        function_prototype,
        block,
        if_stmt,
        for_stmt,
        while_stmt,
        do_while_stmt,
        switch_stmt,
        return_stmt,
        discard_stmt,
        break_stmt,
        continue_stmt,
        expr_stmt,
        int_literal,
        uint_literal,
        float_literal,
        bool_literal,
        identifier,
        index_access,
        member_access,
        swizzle_access,
        func_call,
        type_constructor,
        unary_op,
        binary_op,
        ternary_op,
        assign_op,
        compound_assign,
        post_increment,
        post_decrement,
        pre_increment,
        pre_decrement,
        group,
    };

    pub const Data = struct {
        op: ?Op = null,
        int_val: i64 = 0,
        float_val: f64 = 0,
        name: []const u8 = "",
        ty: ?Type = null,
        children: []const Node = &.{},
        qualifier: ?Qualifier = null,
        layout: ?Layout = null,
        members: []const StructMember = &.{},
        params: []const FunctionParam = &.{},
    };
};

pub const Op = enum {
    add, sub, mul, div, mod,
    eq, neq, lt, gt, lte, gte,
    logical_and, logical_or, logical_not,
    bit_and, bit_or, bit_xor, bit_not,
    lshift, rshift,
    assign,
    add_assign, sub_assign, mul_assign, div_assign, mod_assign,
    and_assign, or_assign, xor_assign, lshift_assign, rshift_assign,
};

pub const Type = union(enum) {
    void,
    bool,
    int,
    uint,
    float,
    double,
    vec2, vec3, vec4,
    ivec2, ivec3, ivec4,
    bvec2, bvec3, bvec4,
    uvec2, uvec3, uvec4,
    mat2, mat3, mat4,
    mat2x2, mat2x3, mat2x4,
    mat3x2, mat3x3, mat3x4,
    mat4x2, mat4x3, mat4x4,
    sampler2d,
    sampler2d_array,
    sampler3d,
    sampler1d,
    sampler1d_shadow,
    sampler2d_ms,
    sampler2d_ms_array,
    sampler_buffer,
    image2d,
    iimage2d,
    uimage2d,
    image_buffer,
    image2d_ms,
    image2d_ms_array,
    image1d,
    iimage1d,
    uimage1d,
    image3d,
    iimage3d,
    uimage3d,
    image_cube,
    iimage_cube,
    uimage_cube,
    image2d_array,
    iimage2d_array,
    uimage2d_array,
    image_cube_array,
    iimage_cube_array,
    uimage_cube_array,
    sampler2d_shadow,
    sampler_cube_shadow,
    sampler2d_array_shadow,
    sampler_cube_array_shadow,
    sampler_cube,
    // Integer samplers (return ivec4 from texture ops)
    isampler2d,
    isampler3d,
    isampler_cube,
    isampler2d_array,
    isampler2d_ms,
    isampler2d_ms_array,
    isampler_cube_array,
    isampler1d,
    isampler1d_array,
    isampler_buffer,
    // Unsigned samplers (return uvec4 from texture ops)
    usampler2d,
    usampler3d,
    usampler_cube,
    usampler2d_array,
    usampler2d_ms,
    usampler2d_ms_array,
    usampler_cube_array,
    usampler1d,
    usampler1d_array,
    usampler_buffer,
    named: []const u8,
    array: struct { base: *const Type, size: u32 },

    pub fn scalarSize(self: Type) u32 {
        return switch (self) {
            .bool => 1,
            .int, .uint => 4,
            .float => 4,
            .double => 8,
            .void, .sampler2d, .sampler2d_array, .sampler3d, .sampler1d, .sampler2d_ms, .sampler2d_ms_array, .sampler_buffer, .image2d, .iimage2d, .uimage2d, .image_buffer, .image2d_ms, .image2d_ms_array, .image1d, .iimage1d, .uimage1d, .image3d, .iimage3d, .uimage3d, .image_cube, .iimage_cube, .uimage_cube, .image2d_array, .iimage2d_array, .uimage2d_array, .image_cube_array, .iimage_cube_array, .uimage_cube_array, .sampler2d_shadow, .sampler1d_shadow, .sampler_cube_shadow, .sampler2d_array_shadow, .sampler_cube_array_shadow, .sampler_cube, .isampler2d, .isampler3d, .isampler_cube, .isampler2d_array, .isampler2d_ms, .isampler2d_ms_array, .isampler_cube_array, .isampler1d, .isampler1d_array, .isampler_buffer, .usampler2d, .usampler3d, .usampler_cube, .usampler2d_array, .usampler2d_ms, .usampler2d_ms_array, .usampler_cube_array, .usampler1d, .usampler1d_array, .usampler_buffer, .named, .array => 0,
            else => 4,
        };
    }

    pub fn numComponents(self: Type) u32 {
        return switch (self) {
            .void => 0,
            .bool, .int, .uint, .float, .double => 1,
            .vec2, .ivec2, .bvec2, .uvec2 => 2,
            .vec3, .ivec3, .bvec3, .uvec3 => 3,
            .vec4, .ivec4, .bvec4, .uvec4 => 4,
            .mat2, .mat2x2 => 4,
            .mat3, .mat3x3 => 9,
            .mat4, .mat4x4 => 16,
            .mat2x3 => 6, .mat2x4 => 8,
            .mat3x2 => 6, .mat3x4 => 12,
            .mat4x2 => 8, .mat4x3 => 12,
            .sampler2d, .sampler2d_array, .sampler3d, .sampler1d, .sampler2d_ms, .sampler2d_ms_array, .sampler_buffer, .image2d, .iimage2d, .uimage2d, .image_buffer, .image2d_ms, .image2d_ms_array, .image1d, .iimage1d, .uimage1d, .image3d, .iimage3d, .uimage3d, .image_cube, .iimage_cube, .uimage_cube, .image2d_array, .iimage2d_array, .uimage2d_array, .image_cube_array, .iimage_cube_array, .uimage_cube_array, .sampler2d_shadow, .sampler1d_shadow, .sampler_cube_shadow, .sampler2d_array_shadow, .sampler_cube_array_shadow, .sampler_cube, .isampler2d, .isampler3d, .isampler_cube, .isampler2d_array, .isampler2d_ms, .isampler2d_ms_array, .isampler_cube_array, .isampler1d, .isampler1d_array, .isampler_buffer, .usampler2d, .usampler3d, .usampler_cube, .usampler2d_array, .usampler2d_ms, .usampler2d_ms_array, .usampler_cube_array, .usampler1d, .usampler1d_array, .usampler_buffer, .named, .array => 0,
        };
    }

    pub fn isScalar(self: Type) bool {
        return switch (self) {
            .bool, .int, .uint, .float, .double => true,
            else => false,
        };
    }

    pub fn isBoolVector(self: Type) bool {
        return switch (self) {
            .bvec2, .bvec3, .bvec4 => true,
            else => false,
        };
    }

    pub fn isVector(self: Type) bool {
        return switch (self) {
            .vec2, .vec3, .vec4,
            .ivec2, .ivec3, .ivec4,
            .bvec2, .bvec3, .bvec4,
            .uvec2, .uvec3, .uvec4 => true,
            else => false,
        };
    }

    pub fn isFloatVector(self: Type) bool {
        return switch (self) {
            .vec2, .vec3, .vec4 => true,
            else => false,
        };
    }

    pub fn isIntVector(self: Type) bool {
        return switch (self) {
            .ivec2, .ivec3, .ivec4,
            .uvec2, .uvec3, .uvec4 => true,
            else => false,
        };
    }

    pub fn isMatrix(self: Type) bool {
        return switch (self) {
            .mat2, .mat3, .mat4,
            .mat2x2, .mat2x3, .mat2x4,
            .mat3x2, .mat3x3, .mat3x4,
            .mat4x2, .mat4x3, .mat4x4 => true,
            else => false,
        };
    }

    /// For matrix types, returns the column vector type (vec2/vec3/vec4)
    /// In GLSL matCxR: C columns, R rows → column type is vecR
    pub fn columnType(self: Type) Type {
        return switch (self) {
            .mat2, .mat2x2, .mat3x2, .mat4x2 => .vec2,
            .mat2x3, .mat3, .mat3x3, .mat4x3 => .vec3,
            .mat2x4, .mat3x4, .mat4, .mat4x4 => .vec4,
            else => .void,
        };
    }

    /// For matrix types, returns the number of columns
    /// In GLSL matCxR: C columns
    pub fn numColumns(self: Type) u32 {
        return switch (self) {
            .mat2, .mat2x2 => 2,
            .mat2x3, .mat2x4 => 2,
            .mat3x2, .mat3, .mat3x3 => 3,
            .mat3x4 => 3,
            .mat4x2, .mat4x3, .mat4, .mat4x4 => 4,
            else => 0,
        };
    }

    pub fn isSampler(self: Type) bool {
        return switch (self) {
            .sampler2d, .sampler2d_array, .sampler3d, .sampler1d, .sampler2d_ms, .sampler2d_ms_array, .sampler_buffer, .image2d, .iimage2d, .uimage2d, .image_buffer, .image2d_ms, .image2d_ms_array, .image1d, .iimage1d, .uimage1d, .image3d, .iimage3d, .uimage3d, .image_cube, .iimage_cube, .uimage_cube, .image2d_array, .iimage2d_array, .uimage2d_array, .image_cube_array, .iimage_cube_array, .uimage_cube_array, .sampler2d_shadow, .sampler1d_shadow, .sampler_cube_shadow, .sampler2d_array_shadow, .sampler_cube_array_shadow, .sampler_cube, .isampler2d, .isampler3d, .isampler_cube, .isampler2d_array, .isampler2d_ms, .isampler2d_ms_array, .isampler_cube_array, .isampler1d, .isampler1d_array, .isampler_buffer, .usampler2d, .usampler3d, .usampler_cube, .usampler2d_array, .usampler2d_ms, .usampler2d_ms_array, .usampler_cube_array, .usampler1d, .usampler1d_array, .usampler_buffer => true,
            else => false,
        };
    }

    /// True for combined image-sampler types (need OpImage extraction)
    pub fn isCombinedSampler(self: Type) bool {
        return switch (self) {
            .sampler2d, .sampler2d_array, .sampler3d, .sampler1d, .sampler2d_ms, .sampler2d_ms_array, .sampler_buffer, .sampler_cube,
            .sampler2d_shadow, .sampler1d_shadow, .sampler_cube_shadow, .sampler2d_array_shadow, .sampler_cube_array_shadow,
            .isampler2d, .isampler3d, .isampler_cube, .isampler2d_array, .isampler2d_ms, .isampler2d_ms_array, .isampler_cube_array, .isampler1d, .isampler1d_array, .isampler_buffer,
            .usampler2d, .usampler3d, .usampler_cube, .usampler2d_array, .usampler2d_ms, .usampler2d_ms_array, .usampler_cube_array, .usampler1d, .usampler1d_array, .usampler_buffer => true,
            else => false,
        };
    }

    pub fn elementType(self: Type) Type {
        return switch (self) {
            .vec2, .vec3, .vec4 => .float,
            .ivec2, .ivec3, .ivec4 => .int,
            .bvec2, .bvec3, .bvec4 => .bool,
            .uvec2, .uvec3, .uvec4 => .uint,
            .mat2, .mat3, .mat4,
            .mat2x2, .mat2x3, .mat2x4,
            .mat3x2, .mat3x3, .mat3x4,
            .mat4x2, .mat4x3, .mat4x4 => .float,
            .array => |a| a.base.*,
            else => self,
        };
    }

    /// For a scalar type, return the vector type with N components.
    pub fn toVec2(self: Type) Type {
        return switch (self) {
            .float => .vec2,
            .int => .ivec2,
            .uint => .uvec2,
            .bool => .bvec2,
            else => self,
        };
    }
    pub fn toVec3(self: Type) Type {
        return switch (self) {
            .float => .vec3,
            .int => .ivec3,
            .uint => .uvec3,
            .bool => .bvec3,
            else => self,
        };
    }
    pub fn toVec4(self: Type) Type {
        return switch (self) {
            .float => .vec4,
            .int => .ivec4,
            .uint => .uvec4,
            .bool => .bvec4,
            else => self,
        };
    }

    /// Returns the scalar base type for sampler types (float for regular, int for isampler, uint for usampler)
    pub fn samplerBaseType(self: Type) Type {
        return switch (self) {
            .sampler2d, .sampler2d_array, .sampler3d, .sampler1d, .sampler2d_ms, .sampler2d_ms_array, .sampler_buffer,
            .sampler2d_shadow, .sampler1d_shadow, .sampler_cube_shadow, .sampler2d_array_shadow,
            .sampler_cube_array_shadow,
            .sampler_cube, .image2d, .image_buffer, .image2d_ms, .image2d_ms_array,
            .image1d, .image3d, .image_cube, .image2d_array, .image_cube_array => .float,
            .isampler2d, .isampler3d, .isampler_cube, .isampler2d_array, .isampler2d_ms,
            .isampler2d_ms_array, .isampler_cube_array, .isampler1d, .isampler1d_array,
            .isampler_buffer, .iimage2d, .iimage1d, .iimage3d, .iimage_cube, .iimage2d_array, .iimage_cube_array => .int,
            .usampler2d, .usampler3d, .usampler_cube, .usampler2d_array, .usampler2d_ms,
            .usampler2d_ms_array, .usampler_cube_array, .usampler1d, .usampler1d_array,
            .usampler_buffer, .uimage2d, .uimage1d, .uimage3d, .uimage_cube, .uimage2d_array, .uimage_cube_array => .uint,
            else => .float,
        };
    }

    /// Returns the texel result type for sampler types (vec4, ivec4, or uvec4)
    pub fn samplerResultType(self: Type) Type {
        return self.samplerBaseType().toVec4();
    }
};

pub const Qualifier = packed struct {
    is_const: bool = false,
    is_in: bool = false,
    is_out: bool = false,
    is_uniform: bool = false,
    is_inout: bool = false,
    is_buffer: bool = false,
    is_shared: bool = false,
    is_readonly: bool = false,
    is_writeonly: bool = false,
    is_flat: bool = false,
};

pub const Layout = struct {
    location: ?u32 = null,
    binding: ?u32 = null,
    set: ?u32 = null,
    std140: bool = false,
    std430: bool = false,
    push_constant: bool = false,
    local_size_x: ?u32 = null,
    local_size_y: ?u32 = null,
    local_size_z: ?u32 = null,
};

pub const StructMember = struct {
    name: []const u8,
    ty: Type,
    qualifier: ?Qualifier = null,
    layout: ?Layout = null,
};

pub const FunctionParam = struct {
    name: []const u8,
    ty: Type,
    qualifier: ?Qualifier = null,
};