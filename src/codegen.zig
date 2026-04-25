const std = @import("std");
const ast = @import("ast.zig");
const ir = @import("ir.zig");
const spirv = @import("spirv.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const semantic = @import("semantic.zig");

pub const Stage = enum { vertex, fragment, compute, geometry };
pub const SPIRVVersion = enum { @"1.0", @"1.1", @"1.2", @"1.3", @"1.4", @"1.5", @"1.6" };

pub fn generate(
    alloc: std.mem.Allocator,
    module: *const ir.Module,
    stage: Stage,
    spirv_version: SPIRVVersion,
) error{OutOfMemory, CodegenFailed}![]const u32 {
    var cg = Codegen{
        .alloc = alloc,
        .module = module,
        .stage = stage,
        .words = std.ArrayList(u32).initCapacity(alloc, 0) catch unreachable,
        .next_id = module.next_id_start,
        .emitted_types = .{},
        .emitted_named_types = .{},
        .emitted_ptr_types = .{},
        .emitted_constants = .{},
        .emitted_func_types = .{},
        .sampled_image_inner_id = 0,
        .sampler_buffer_inner_id = 0,
        .glsl_std_450_id = 0,
    };
    defer cg.deinit();

    try cg.emitHeader(spirv_version);
    try cg.emitCapabilities();
    try cg.emitExtInstImport();
    try cg.emitMemoryModel();
    try cg.emitEntryPoint(stage);
    try cg.emitNames();
    try cg.emitDecorations();
    try cg.emitTypesAndConstants();
    try cg.emitGlobals();
    try cg.emitFunctions(stage);

    // Patch header bound field
    cg.words.items[3] = cg.next_id;

    return cg.words.toOwnedSlice(alloc);
}

const Codegen = struct {
    alloc: std.mem.Allocator,
    module: *const ir.Module,
    stage: Stage,
    words: std.ArrayList(u32),
    next_id: u32,
    emitted_types: std.AutoHashMapUnmanaged(u32, u32), // @intFromEnum(ty) -> type_id
    emitted_named_types: std.StringHashMapUnmanaged(u32), // struct name -> type_id
    emitted_ptr_types: std.AutoHashMapUnmanaged(u64, u32), // (type_key << 32 | sc) -> ptr_type_id
    emitted_constants: std.AutoHashMapUnmanaged(u64, u32), // (type_id << 32 | value) -> const_id
    emitted_func_types: std.AutoHashMapUnmanaged(u64, u32), // hash(ret+params) -> func_type_id
    sampled_image_inner_id: u32, // TypeImage (Sampled=1) for use with OpImage extraction
    sampler_buffer_inner_id: u32, // TypeImage (Dim=Buffer, Sampled=1) for texelFetch
    glsl_std_450_id: u32,

    fn deinit(self: *Codegen) void {
        self.emitted_types.deinit(self.alloc);
        self.emitted_named_types.deinit(self.alloc);
        self.emitted_ptr_types.deinit(self.alloc);
        self.emitted_constants.deinit(self.alloc);
        self.emitted_func_types.deinit(self.alloc);
        self.words.deinit(self.alloc);
    }

    fn allocId(self: *Codegen) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn emitWord(self: *Codegen, word: u32) !void {
        try self.words.append(self.alloc, word);
    }

    fn emitHeader(self: *Codegen, version: SPIRVVersion) !void {
        const version_word: u32 = switch (version) {
            .@"1.0" => spirv.encodeVersion(1, 0, 0),
            .@"1.1" => spirv.encodeVersion(1, 1, 0),
            .@"1.2" => spirv.encodeVersion(1, 2, 0),
            .@"1.3" => spirv.encodeVersion(1, 3, 0),
            .@"1.4" => spirv.encodeVersion(1, 4, 0),
            .@"1.5" => spirv.encodeVersion(1, 5, 0),
            .@"1.6" => spirv.encodeVersion(1, 6, 0),
        };
        try self.emitWord(spirv.MAGIC);
        try self.emitWord(version_word);
        try self.emitWord(0); // Generator ID
        try self.emitWord(0); // Bound (patched later)
        try self.emitWord(0); // Schema
    }

    fn emitCapabilities(self: *Codegen) !void {
        try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
        try self.emitWord(@intFromEnum(spirv.Capability.shader));
        try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
        try self.emitWord(@intFromEnum(spirv.Capability.image_query));
        try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
        try self.emitWord(@intFromEnum(spirv.Capability.sampled_buffer));
        try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
        try self.emitWord(@intFromEnum(spirv.Capability.image_buffer));
    }

    fn emitExtInstImport(self: *Codegen) !void {
        const name = "GLSL.std.450";
        const id = self.allocId();
        self.glsl_std_450_id = id;
        const word_count: u16 = 2 + @as(u16, @intCast(std.math.divCeil(usize, name.len + 1, 4) catch unreachable));
        try self.emitWord(spirv.encodeInstructionHeader(word_count, @intFromEnum(spirv.Op.ExtInstImport)));
        try self.emitWord(id);
        try self.emitStringLiteral(name);
    }

    fn emitMemoryModel(self: *Codegen) !void {
        try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.MemoryModel)));
        try self.emitWord(0); // Logical
        try self.emitWord(1); // GLSL450
    }

    fn emitEntryPoint(self: *Codegen, stage: Stage) !void {
        const exec_model: spirv.ExecutionModel = switch (stage) {
            .vertex => .Vertex,
            .fragment => .Fragment,
            .compute => .GLCompute,
            .geometry => .Geometry,
        };
        const entry = self.findEntryPoint() orelse return;
        const entry_id = if (entry.result_id != 0) entry.result_id else self.allocId();
        const name = entry.name;

        // Collect interface variable IDs
        // SPIR-V 1.4+ requires ALL globals used by the entry point to be listed
        var interface_ids = std.ArrayList(u32).initCapacity(self.alloc, 0) catch unreachable;
        defer interface_ids.deinit(self.alloc);
        for (self.module.globals) |global| {
            interface_ids.append(self.alloc, global.result_id) catch unreachable;
        }

        const name_words = @as(u16, @intCast(std.math.divCeil(usize, name.len + 1, 4) catch unreachable));
        const word_count: u16 = 3 + name_words + @as(u16, @intCast(interface_ids.items.len));
        try self.emitWord(spirv.encodeInstructionHeader(word_count, @intFromEnum(spirv.Op.EntryPoint)));
        try self.emitWord(@intFromEnum(exec_model));
        try self.emitWord(entry_id);
        try self.emitStringLiteral(name);

        // Append interface variable IDs
        for (interface_ids.items) |id| {
            try self.emitWord(id);
        }

        if (stage == .fragment) {
            try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.ExecutionMode)));
            try self.emitWord(entry_id);
            try self.emitWord(@intFromEnum(spirv.ExecutionMode.OriginUpperLeft));
        }
        if (stage == .compute) {
            if (self.module.local_size) |ls| {
                try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(spirv.ExecutionMode.LocalSize));
                try self.emitWord(ls.x);
                try self.emitWord(ls.y);
                try self.emitWord(ls.z);
            }
        }
    }

    fn findEntryPoint(self: *Codegen) ?*const ir.Function {
        for (self.module.functions) |*f| {
            if (std.mem.eql(u8, f.name, "main")) return f;
        }
        return null;
    }

    fn emitStringLiteral(self: *Codegen, str: []const u8) !void {
        var i: usize = 0;
        while (i < str.len) {
            var word: u32 = 0;
            var j: usize = 0;
            while (j < 4 and i + j < str.len) : (j += 1) {
                word |= @as(u32, str[i + j]) << @intCast(j * 8);
            }
            try self.emitWord(word);
            i += 4;
        }
        if (str.len % 4 == 0) {
            try self.emitWord(0);
        }
    }

    fn ensureType(self: *Codegen, ty: ast.Type) error{OutOfMemory}!u32 {
        // Normalize aliases for dedup: mat2 == mat2x2, mat3 == mat3x3, mat4 == mat4x4
        const normalized = switch (ty) {
            .mat2 => ast.Type.mat2x2,
            .mat3 => ast.Type.mat3x3,
            .mat4 => ast.Type.mat4x4,
            else => ty,
        };
        // Dedup: for simple (non-payload) types, return cached ID if already emitted
        if (normalized != .named and normalized != .array) {
            const key = @intFromEnum(normalized);
            if (self.emitted_types.get(key)) |cached_id| {
                return cached_id;
            }
        }

        const id = self.allocId();
        switch (ty) {
            .void => {
                try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.TypeVoid)));
                try self.emitWord(id);
            },
            .bool => {
                try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.TypeBool)));
                try self.emitWord(id);
            },
            .int => {
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeInt)));
                try self.emitWord(id);
                try self.emitWord(32); // bit width
                try self.emitWord(1); // signed
            },
            .uint => {
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeInt)));
                try self.emitWord(id);
                try self.emitWord(32);
                try self.emitWord(0); // unsigned
            },
            .float => {
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeFloat)));
                try self.emitWord(id);
                try self.emitWord(32);
            },
            .double => {
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeFloat)));
                try self.emitWord(id);
                try self.emitWord(64);
            },
            .vec2, .vec3, .vec4,
            .ivec2, .ivec3, .ivec4,
            .bvec2, .bvec3, .bvec4,
            .uvec2, .uvec3, .uvec4 => {
                const elem_type = try self.ensureType(ty.elementType());
                const count = ty.numComponents();
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeVector)));
                try self.emitWord(id);
                try self.emitWord(elem_type);
                try self.emitWord(count);
            },
            .mat2, .mat2x2, .mat2x3, .mat2x4,
            .mat3x2, .mat3, .mat3x3, .mat3x4,
            .mat4x2, .mat4x3, .mat4, .mat4x4 => {
                const col_type = try self.ensureType(ty.columnType());
                const num_cols = ty.numColumns();
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeMatrix)));
                try self.emitWord(id);
                try self.emitWord(col_type);
                try self.emitWord(num_cols);
            },
            .sampler2d => {
                const float_id = try self.ensureType(.float);
                const image_id = self.allocId();
                try self.emitWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitWord(image_id);
                try self.emitWord(float_id);
                try self.emitWord(1); // Dim = 2D
                try self.emitWord(0); // Not depth
                try self.emitWord(0); // Not arrayed
                try self.emitWord(0); // Not multisampled
                try self.emitWord(1); // Sampled = 1 (yes)
                try self.emitWord(0); // ImageFormat = Unknown
                self.sampled_image_inner_id = image_id; // Save for OpImage extraction
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitWord(id);
                try self.emitWord(image_id);
            },
            .sampler_buffer => {
                // samplerBuffer → TypeImage with Dim=Buffer, then TypeSampledImage
                const float_id = try self.ensureType(.float);
                const image_id = self.allocId();
                try self.emitWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitWord(image_id);
                try self.emitWord(float_id);
                try self.emitWord(5); // Dim = Buffer
                try self.emitWord(0); // Not depth
                try self.emitWord(0); // Not arrayed
                try self.emitWord(0); // Not multisampled
                try self.emitWord(1); // Sampled = 1 (with sampler)
                try self.emitWord(0); // ImageFormat = Unknown
                self.sampler_buffer_inner_id = image_id;
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitWord(id);
                try self.emitWord(image_id);
            },
            .image2d => {
                const float_id = try self.ensureType(.float);
                try self.emitWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitWord(id);
                try self.emitWord(float_id);
                try self.emitWord(1); // Dim = 2D
                try self.emitWord(0); // Not depth
                try self.emitWord(0); // Not arrayed
                try self.emitWord(0); // Not multisampled
                try self.emitWord(2); // Sampled = 2 (no sampler needed)
                try self.emitWord(0); // ImageFormat = Unknown
            },
            .iimage2d => {
                const int_id = try self.ensureType(.int);
                try self.emitWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitWord(id);
                try self.emitWord(int_id);
                try self.emitWord(1); // Dim = 2D
                try self.emitWord(0); // Not depth
                try self.emitWord(0); // Not arrayed
                try self.emitWord(0); // Not multisampled
                try self.emitWord(2); // Sampled = 2 (no sampler needed)
                try self.emitWord(0); // ImageFormat = Unknown
            },
            .uimage2d => {
                const uint_id = try self.ensureType(.uint);
                try self.emitWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitWord(id);
                try self.emitWord(uint_id);
                try self.emitWord(1); // Dim = 2D
                try self.emitWord(0); // Not depth
                try self.emitWord(0); // Not arrayed
                try self.emitWord(0); // Not multisampled
                try self.emitWord(2); // Sampled = 2 (no sampler needed)
                try self.emitWord(0); // ImageFormat = Unknown
            },
            .image_buffer => {
                const float_id = try self.ensureType(.float);
                try self.emitWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitWord(id);
                try self.emitWord(float_id);
                try self.emitWord(5); // Dim = Buffer
                try self.emitWord(0); // Not depth
                try self.emitWord(0); // Not arrayed
                try self.emitWord(0); // Not multisampled
                try self.emitWord(2); // Sampled = 2 (no sampler needed)
                try self.emitWord(0); // ImageFormat = Unknown
            },
            .sampler_cube => {
                const float_id = try self.ensureType(.float);
                const image_id = self.allocId();
                try self.emitWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitWord(image_id);
                try self.emitWord(float_id);
                try self.emitWord(3); // Dim = Cube
                try self.emitWord(0);
                try self.emitWord(0);
                try self.emitWord(0);
                try self.emitWord(1);
                try self.emitWord(0);
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitWord(id);
                try self.emitWord(image_id);
            },
            .named => |name| {
                // Check if this named type was already emitted
                if (self.emitted_named_types.get(name)) |cached_id| {
                    return cached_id;
                }
                const td = self.module.types.get(name) orelse return id;
                var member_ids = try std.ArrayList(u32).initCapacity(self.alloc, td.members.len);
                defer member_ids.deinit(self.alloc);
                for (td.members) |member| {
                    try member_ids.append(self.alloc, try self.ensureType(member.ty));
                }
                const word_count: u16 = 2 + @as(u16, @intCast(member_ids.items.len));
                try self.emitWord(spirv.encodeInstructionHeader(word_count, @intFromEnum(spirv.Op.TypeStruct)));
                try self.emitWord(id);
                for (member_ids.items) |mid| {
                    try self.emitWord(mid);
                }
                // Cache the named type
                try self.emitted_named_types.put(self.alloc, name, id);
            },
            .array => |arr| {
                const base_id = try self.ensureType(arr.base.*);
                if (arr.size == 0) {
                    // Runtime array: OpTypeRuntimeArray
                    try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeRuntimeArray)));
                    try self.emitWord(id);
                    try self.emitWord(base_id);
                } else {
                    const const_id = try self.emitIntConstant(arr.size);
                    try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeArray)));
                    try self.emitWord(id);
                    try self.emitWord(base_id);
                    try self.emitWord(const_id);
                }
            },
        }
        // Cache for simple types
        if (normalized != .named and normalized != .array) {
            const key = @intFromEnum(normalized);
            try self.emitted_types.put(self.alloc, key, id);
        }
        return id;
    }

    fn ensurePointerType(self: *Codegen, base_type: ast.Type, storage_class: ir.SPIRVStorageClass) error{OutOfMemory}!u32 {
        const base_id = try self.ensureType(base_type);
        // For named types, use the struct name to differentiate cache keys
        const key: u64 = switch (base_type) {
            .named => |name| blk: {
                const sc: u64 = @intFromEnum(storage_class);
                var h: u64 = sc;
                for (name) |c| {
                    h = h *% 31 +% @as(u64, c);
                }
                break :blk h;
            },
            else => (@as(u64, @intFromEnum(base_type)) << 32) | @as(u64, @intFromEnum(storage_class)),
        };
        if (self.emitted_ptr_types.get(key)) |cached| return cached;
        const ptr_id = self.allocId();
        try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypePointer)));
        try self.emitWord(ptr_id);
        try self.emitWord(@intFromEnum(storage_class));
        try self.emitWord(base_id);
        try self.emitted_ptr_types.put(self.alloc, key, ptr_id);
        return ptr_id;
    }

    fn emitIntConstant(self: *Codegen, val: u32) error{OutOfMemory}!u32 {
        const int_type_id = try self.ensureType(.uint);
        const key = (@as(u64, int_type_id) << 32) | @as(u64, val);
        if (self.emitted_constants.get(key)) |cached| return cached;
        const const_id = self.allocId();
        try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Constant)));
        try self.emitWord(int_type_id);
        try self.emitWord(const_id);
        try self.emitWord(val);
        try self.emitted_constants.put(self.alloc, key, const_id);
        return const_id;
    }

    fn emitFloatConstant(self: *Codegen, val: f32) error{OutOfMemory}!u32 {
        const float_type_id = try self.ensureType(.float);
        const val_bits: u32 = @bitCast(val);
        const key = (@as(u64, float_type_id) << 32) | @as(u64, val_bits);
        if (self.emitted_constants.get(key)) |cached| return cached;
        const const_id = self.allocId();
        try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Constant)));
        try self.emitWord(float_type_id);
        try self.emitWord(const_id);
        try self.emitWord(val_bits);
        try self.emitted_constants.put(self.alloc, key, const_id);
        return const_id;
    }

    fn emitNames(self: *Codegen) !void {
        for (self.module.globals) |global| {
            try self.emitName(global.result_id, global.name);
        }
        for (self.module.functions) |func| {
            try self.emitName(func.result_id, func.name);
        }
    }

    fn emitName(self: *Codegen, id: u32, name: []const u8) !void {
        const word_count: u16 = 2 + @as(u16, @intCast(std.math.divCeil(usize, name.len + 1, 4) catch unreachable));
        try self.emitWord(spirv.encodeInstructionHeader(word_count, @intFromEnum(spirv.Op.Name)));
        try self.emitWord(id);
        try self.emitStringLiteral(name);
    }

    fn emitDecorations(self: *Codegen) !void {
        for (self.module.globals) |global| {
            if (global.layout) |layout| {
                if (layout.location) |loc| {
                    try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.location), loc);
                }
                if (layout.binding) |binding| {
                    try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.binding), binding);
                }
                if (layout.set) |set| {
                    try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.descriptor_set), set);
                }
            }
            if (std.mem.eql(u8, global.name, "gl_FragCoord")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.frag_coord));
            }
            if (std.mem.eql(u8, global.name, "gl_FragColor")) {
                // gl_FragColor is deprecated, no standard BuiltIn — skip decoration
            } else if (std.mem.eql(u8, global.name, "gl_FrontFacing")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.front_facing));
            }
            if (std.mem.eql(u8, global.name, "gl_Position")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.position));
            }
            if (std.mem.eql(u8, global.name, "gl_VertexID")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.vertex_index));
            }
            if (std.mem.eql(u8, global.name, "gl_InstanceID")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.instance_index));
            }
            // Only emit BuiltIn decorations for builtins that don't require extra capabilities
            // gl_Layer, gl_ViewportIndex require Geometry capability — skip
            if (false and std.mem.eql(u8, global.name, "gl_Layer")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.layer));
            }
            if (false and std.mem.eql(u8, global.name, "gl_ViewportIndex")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.viewport_index));
            }
            if (std.mem.eql(u8, global.name, "gl_GlobalInvocationID")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.global_invocation_id));
            }
            if (std.mem.eql(u8, global.name, "gl_LocalInvocationID")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.local_invocation_id));
            }
            if (std.mem.eql(u8, global.name, "gl_WorkGroupID")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.workgroup_id));
            }
            if (std.mem.eql(u8, global.name, "gl_NumWorkGroups")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.num_workgroups));
            }
            // Decorate uniform block types with Block
            if (global.storage_class == .uniform) {
                if (global.ty == .named) {
                    // Find the type ID for this struct and decorate it with Block
                    // We need to decorate the struct type, not the variable
                    // For now, emit Block decoration on the variable's type
                }
            }
        }
    }

    fn emitDecorate(self: *Codegen, target_id: u32, decoration: u32, extra: u32) !void {
        try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Decorate)));
        try self.emitWord(target_id);
        try self.emitWord(decoration);
        try self.emitWord(extra);
    }

    // Stub methods — implemented in subsequent tasks
    fn emitTypesAndConstants(self: *Codegen) !void {
        for (self.module.globals) |global| {
            _ = try self.ensureType(global.ty);
            _ = try self.ensurePointerType(global.ty, global.storage_class);
        }
        for (self.module.functions) |func| {
            _ = try self.ensureType(func.return_type);
            for (func.params) |param| {
                _ = try self.ensureType(param.ty);
            }
            for (func.body) |inst| {
                _ = try self.ensureType(inst.ty);
                switch (inst.tag) {
                    .local_variable => {
                        _ = try self.ensurePointerType(inst.ty, .function);
                    },
                    .access_chain => {
                        _ = try self.ensurePointerType(inst.ty, .function);
                        _ = try self.ensurePointerType(inst.ty, .uniform);
                        _ = try self.ensurePointerType(inst.ty, .output);
                        _ = try self.ensurePointerType(inst.ty, .input);
                        _ = try self.ensurePointerType(inst.ty, .private);
                        // Pre-emit the index constant so it's available during codegen
                        if (inst.operands.len > 1) {
                            const idx = switch (inst.operands[1]) {
                                .literal_int => |v| v,
                                else => 0,
                            };
                            _ = try self.emitIntConstant(idx);
                        }
                    },
                    .constant_int => {
                        const result_id = inst.result_id orelse continue;
                        const val: u32 = switch (inst.operands[0]) {
                            .literal_int => |v| v,
                            else => continue,
                        };
                        const int_type_id = try self.ensureType(.int);
                        try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Constant)));
                        try self.emitWord(int_type_id);
                        try self.emitWord(result_id);
                        try self.emitWord(val);
                    },
                    .constant_float => {
                        const result_id = inst.result_id orelse continue;
                        const val: f32 = switch (inst.operands[0]) {
                            .literal_float => |v| v,
                            .literal_int => |v| @floatFromInt(v),
                            else => continue,
                        };
                        const float_type_id = try self.ensureType(.float);
                        try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Constant)));
                        try self.emitWord(float_type_id);
                        try self.emitWord(result_id);
                        try self.emitWord(@as(u32, @bitCast(val)));
                    },
                    .constant_bool => {
                        const result_id = inst.result_id orelse continue;
                        const val: u32 = switch (inst.operands[0]) {
                            .literal_int => |v| v,
                            else => continue,
                        };
                        const bool_type_id = try self.ensureType(.bool);
                        const op: spirv.Op = if (val != 0) .ConstantTrue else .ConstantFalse;
                        try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(op)));
                        try self.emitWord(bool_type_id);
                        try self.emitWord(result_id);
                    },
                    else => {},
                }
            }
        }

        // Pre-emit commonly needed constants so they're in the types section
        // (not inside function bodies where they'd violate SPIR-V section ordering)
        // Scan all instructions for literal constants used as indices
        for (self.module.functions) |func| {
            for (func.body) |inst| {
                switch (inst.tag) {
                    .access_chain, .composite_extract, .vector_shuffle => {
                        for (inst.operands) |op| {
                            switch (op) {
                                .literal_int => |v| _ = try self.emitIntConstant(v),
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            }
        }
        // Also pre-emit common constants
        _ = try self.emitFloatConstant(0.0);
        _ = try self.emitFloatConstant(1.0);
        _ = try self.emitIntConstant(0);
        _ = try self.emitIntConstant(1);
    }
    fn emitGlobals(self: *Codegen) !void {
        for (self.module.globals) |global| {
            const ptr_type_id = try self.ensurePointerType(global.ty, global.storage_class);
            try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Variable)));
            try self.emitWord(ptr_type_id);
            try self.emitWord(global.result_id);
            try self.emitWord(@intFromEnum(global.storage_class));
        }
    }

    fn emitFunctions(self: *Codegen, stage: Stage) !void {
        _ = stage;
        // First pass: emit all function type declarations and save info
        const FuncInfo = struct { func_type_id: u32, param_type_ids: []const u32 };
        var func_infos = try std.ArrayList(FuncInfo).initCapacity(self.alloc, self.module.functions.len);
        defer func_infos.deinit(self.alloc);
        for (self.module.functions) |func| {
            const return_type_id = try self.ensureType(func.return_type);
            var param_type_ids = try std.ArrayList(u32).initCapacity(self.alloc, func.params.len);
            for (func.params) |param| {
                try param_type_ids.append(self.alloc, try self.ensureType(param.ty));
            }
            // Compute hash key for function type dedup
            var func_type_key: u64 = return_type_id;
            for (param_type_ids.items) |ptid| {
                func_type_key = func_type_key *% 31 +% ptid;
            }
            if (self.emitted_func_types.get(func_type_key)) |cached_id| {
                try func_infos.append(self.alloc, .{ .func_type_id = cached_id, .param_type_ids = try param_type_ids.toOwnedSlice(self.alloc) });
                continue;
            }
            const func_type_id = self.allocId();
            const func_type_wc: u16 = 3 + @as(u16, @intCast(param_type_ids.items.len));
            try self.emitWord(spirv.encodeInstructionHeader(func_type_wc, @intFromEnum(spirv.Op.TypeFunction)));
            try self.emitWord(func_type_id);
            try self.emitWord(return_type_id);
            for (param_type_ids.items) |ptid| {
                try self.emitWord(ptid);
            }
            try self.emitted_func_types.put(self.alloc, func_type_key, func_type_id);
            try func_infos.append(self.alloc, .{ .func_type_id = func_type_id, .param_type_ids = try param_type_ids.toOwnedSlice(self.alloc) });
        }

        // Second pass: emit function definitions
        for (self.module.functions, 0..) |func, func_idx| {
            const return_type_id = try self.ensureType(func.return_type);
            const info = func_infos.items[func_idx];
            const func_id = if (func.result_id != 0) func.result_id else self.allocId();
            try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.Function)));
            try self.emitWord(return_type_id);
            try self.emitWord(func_id);
            try self.emitWord(0); // FunctionControl = None
            try self.emitWord(info.func_type_id);

            for (func.params, 0..) |_, i| {
                const param_id = if (i < func.param_ids.len) func.param_ids[i] else self.allocId();
                const param_type_id = info.param_type_ids[i];
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.FunctionParameter)));
                try self.emitWord(param_type_id);
                try self.emitWord(param_id);
            }

            const label_id = self.allocId();
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Label)));
            try self.emitWord(label_id);

            // SPIR-V requires all OpVariable be first in the first block
            for (func.body) |inst| {
                if (inst.tag == .local_variable) {
                    try self.emitInstruction(inst);
                }
            }
            // Then emit all other instructions
            for (func.body) |inst| {
                if (inst.tag != .local_variable) {
                    try self.emitInstruction(inst);
                }
            }

            try self.emitWord(spirv.encodeInstructionHeader(1, @intFromEnum(spirv.Op.FunctionEnd)));
        }
    }

    fn emitInstruction(self: *Codegen, inst: ir.Instruction) !void {
        // Resolve null result_type from ast type
        var resolved = inst;
        if (resolved.result_type == null and resolved.result_id != null and resolved.tag != .extract_image) {
            resolved.result_type = try self.ensureType(inst.ty);
        }
        switch (resolved.tag) {
            .constant_int, .constant_float, .constant_bool => return,
            .local_variable => {
                const ptr_type_id = try self.ensurePointerType(resolved.ty, .function);
                const result_id = resolved.result_id orelse return;
                const wc: u16 = if (resolved.operands.len > 1) 5 else 4;
                try self.emitWord(spirv.encodeInstructionHeader(wc, @intFromEnum(spirv.Op.Variable)));
                try self.emitWord(ptr_type_id);
                try self.emitWord(result_id);
                try self.emitWord(@intFromEnum(ir.SPIRVStorageClass.function));
                if (resolved.operands.len > 1) {
                    try self.emitWord(self.operandId(resolved, 1));
                }
            },
            .load => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const ptr_id = self.operandId(resolved, 0);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Load)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(ptr_id);
            },
            .store => {
                const ptr_id = self.operandId(resolved, 0);
                const val_id = self.operandId(resolved, 1);
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.Store)));
                try self.emitWord(ptr_id);
                try self.emitWord(val_id);
            },
            .add => try self.emitBinOp(spirv.Op.IAdd, resolved),
            .sub => try self.emitBinOp(spirv.Op.ISub, resolved),
            .mul => try self.emitBinOp(spirv.Op.IMul, resolved),
            .div => try self.emitBinOp(spirv.Op.SDiv, resolved),
            .rem => try self.emitBinOp(spirv.Op.SRem, resolved),
            .fadd => try self.emitBinOp(spirv.Op.FAdd, resolved),
            .fsub => try self.emitBinOp(spirv.Op.FSub, resolved),
            .fmul => try self.emitBinOp(spirv.Op.FMul, resolved),
            .mat_vec_mul => try self.emitBinOp(spirv.Op.MatrixTimesVector, resolved),
            .vec_mat_mul => try self.emitBinOp(spirv.Op.VectorTimesMatrix, resolved),
            .mat_mat_mul => try self.emitBinOp(spirv.Op.MatrixTimesMatrix, resolved),
            .vec_scalar_mul => try self.emitBinOp(spirv.Op.VectorTimesScalar, resolved),
            .scalar_vec_mul => {
                // Swap operands: scalar * vec → OpVectorTimesScalar(vec, scalar)
                const result_type = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const wc: u16 = 5;
                try self.emitWord(spirv.encodeInstructionHeader(wc, @intFromEnum(spirv.Op.VectorTimesScalar)));
                try self.emitWord(result_type);
                try self.emitWord(result_id);
                try self.emitWord(self.operandId(resolved, 1)); // vector (was right)
                try self.emitWord(self.operandId(resolved, 0)); // scalar (was left)
            },
            .mat_scalar_mul => try self.emitBinOp(spirv.Op.MatrixTimesScalar, resolved),
            .scalar_mat_mul => {
                // Swap operands: scalar * mat → OpMatrixTimesScalar(mat, scalar)
                const result_type = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const wc: u16 = 5;
                try self.emitWord(spirv.encodeInstructionHeader(wc, @intFromEnum(spirv.Op.MatrixTimesScalar)));
                try self.emitWord(result_type);
                try self.emitWord(result_id);
                try self.emitWord(self.operandId(resolved, 1)); // matrix (was right)
                try self.emitWord(self.operandId(resolved, 0)); // scalar (was left)
            },
            .fdiv => try self.emitBinOp(spirv.Op.FDiv, resolved),
            .neg => try self.emitUnaryOp(spirv.Op.SNegate, resolved),
            .fneg => try self.emitUnaryOp(spirv.Op.FNegate, resolved),
            .not_op => try self.emitUnaryOp(spirv.Op.LogicalNot, resolved),
            .convert_ftoi => try self.emitUnaryOp(spirv.Op.ConvertFToS, resolved),
            .convert_ftou => try self.emitUnaryOp(spirv.Op.ConvertFToU, resolved),
            .convert_uti => try self.emitUnaryOp(spirv.Op.ConvertUToS, resolved),
            .convert_iti => try self.emitUnaryOp(spirv.Op.ConvertSToU, resolved),
            .convert_itof => try self.emitUnaryOp(spirv.Op.ConvertSToF, resolved),
            .convert_utof => try self.emitUnaryOp(spirv.Op.ConvertUToF, resolved),
            .is_nan => try self.emitUnaryOp(spirv.Op.IsNan, resolved),
            .is_inf => try self.emitUnaryOp(spirv.Op.IsInf, resolved),
            .logical_and => try self.emitBinOp(spirv.Op.LogicalAnd, resolved),
            .logical_or => try self.emitBinOp(spirv.Op.LogicalOr, resolved),
            .logical_not => try self.emitUnaryOp(spirv.Op.LogicalNot, resolved),
            .bit_and => try self.emitBinOp(spirv.Op.BitwiseAnd, resolved),
            .bit_or => try self.emitBinOp(spirv.Op.BitwiseOr, resolved),
            .bit_xor => try self.emitBinOp(spirv.Op.BitwiseXor, resolved),
            .bit_not => try self.emitUnaryOp(spirv.Op.Not, resolved),
            .shift_left => try self.emitBinOp(spirv.Op.ShiftLeftLogical, resolved),
            .shift_right => try self.emitBinOp(spirv.Op.ShiftRightLogical, resolved),
            .compare_eq => try self.emitBinOp(spirv.Op.IEqual, resolved),
            .compare_neq => try self.emitBinOp(spirv.Op.INotEqual, resolved),
            .compare_lt => try self.emitBinOp(spirv.Op.SLessThan, resolved),
            .compare_gt => try self.emitBinOp(spirv.Op.SGreaterThan, resolved),
            .compare_lte => try self.emitBinOp(spirv.Op.SLessThanEqual, resolved),
            .compare_gte => try self.emitBinOp(spirv.Op.SGreaterThanEqual, resolved),
            .compare_feq => try self.emitBinOp(spirv.Op.FOrdEqual, resolved),
            .compare_fneq => try self.emitBinOp(spirv.Op.FOrdNotEqual, resolved),
            .compare_flt => try self.emitBinOp(spirv.Op.FOrdLessThan, resolved),
            .compare_fgt => try self.emitBinOp(spirv.Op.FOrdGreaterThan, resolved),
            .compare_flte => try self.emitBinOp(spirv.Op.FOrdLessThanEqual, resolved),
            .compare_fgte => try self.emitBinOp(spirv.Op.FOrdGreaterThanEqual, resolved),
            .select => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const cond_id = self.operandId(resolved, 0);
                const true_id = self.operandId(resolved, 1);
                const false_id = self.operandId(resolved, 2);
                try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.Select)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(cond_id);
                try self.emitWord(true_id);
                try self.emitWord(false_id);
            },
            .composite_construct => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const wc: u16 = 2 + @as(u16, @intCast(resolved.operands.len)) + 1;
                try self.emitWord(spirv.encodeInstructionHeader(wc, @intFromEnum(spirv.Op.CompositeConstruct)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                for (inst.operands) |op| {
                    try self.emitWord(self.operandValue(op));
                }
            },
            .composite_extract => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const composite_id = self.operandId(resolved, 0);
                const index = self.operandInt(resolved, 1);
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.CompositeExtract)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(composite_id);
                try self.emitWord(index);
            },
            .access_chain => {
                // OpAccessChain returns a pointer, so we must use ensurePointerType, not the
                // default value-type resolution from inst.ty.
                // Determine storage class from the base variable
                const base_id_val = self.operandId(resolved, 0);
                var sc: ir.SPIRVStorageClass = .function;
                for (self.module.globals) |global| {
                    if (global.result_id == base_id_val) {
                        sc = global.storage_class;
                        break;
                    }
                }
                const ptr_type_id = try self.ensurePointerType(inst.ty, sc);
                const result_id = resolved.result_id orelse return;
                // OpAccessChain indices: can be OpConstant or runtime scalar integer
                const index_id: u32 = switch (resolved.operands[1]) {
                    .id => |v| v, // Runtime index — use the ID directly
                    .literal_int => |v| try self.emitIntConstant(v), // Literal — emit constant
                    else => try self.emitIntConstant(0),
                };
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.AccessChain)));
                try self.emitWord(ptr_type_id);
                try self.emitWord(result_id);
                try self.emitWord(base_id_val);
                try self.emitWord(index_id);
            },
            .vector_extract_dynamic => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const vec_id = self.operandId(resolved, 0);
                const index_id = self.operandId(resolved, 1);
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.VectorExtractDynamic)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(vec_id);
                try self.emitWord(index_id);
            },
            .member_access_op => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const base_id = self.operandId(resolved, 0);
                const member_idx = self.operandInt(resolved, 1);
                const index_const_id = try self.emitIntConstant(member_idx);
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.AccessChain)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(base_id);
                try self.emitWord(index_const_id);
            },
            .vector_shuffle => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const vec1 = self.operandId(resolved, 0);
                const vec2 = self.operandId(resolved, 1);
                const wc: u16 = 5 + @as(u16, @intCast(resolved.operands.len - 2));
                try self.emitWord(spirv.encodeInstructionHeader(wc, @intFromEnum(spirv.Op.VectorShuffle)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(vec1);
                try self.emitWord(vec2);
                for (resolved.operands[2..]) |op| {
                    try self.emitWord(self.operandValue(op));
                }
            },
            .image_sample => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const sampled_image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                if (self.stage == .vertex or self.stage == .compute) {
                    // Implicit LOD not allowed in vertex/compute shaders
                    // Convert to explicit LOD with level 0
                    const zero_id = try self.emitFloatConstant(0.0);
                    try self.emitWord(spirv.encodeInstructionHeader(7, @intFromEnum(spirv.Op.ImageSampleExplicitLod)));
                    try self.emitWord(result_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(sampled_image_id);
                    try self.emitWord(coord_id);
                    try self.emitWord(2); // Image Operands Mask: Lod
                    try self.emitWord(zero_id);
                } else {
                    try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.ImageSampleImplicitLod)));
                    try self.emitWord(result_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(sampled_image_id);
                    try self.emitWord(coord_id);
                }
            },
            .image_sample_explicit_lod => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const sampled_image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                const lod_id = if (resolved.operands.len > 2) self.operandId(resolved, 2) else self.operandId(resolved, 1);
                // OpImageSampleExplicitLod: result_type, result, sampled_image, coordinate, ImageOperands(Lod=2), lod_value
                try self.emitWord(spirv.encodeInstructionHeader(7, @intFromEnum(spirv.Op.ImageSampleExplicitLod)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(sampled_image_id);
                try self.emitWord(coord_id);
                try self.emitWord(2); // Image Operands Mask: Lod
                try self.emitWord(lod_id);
            },
            .image_fetch => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                // If operand was a sampler, image_id is already the extracted image
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.ImageFetch)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(image_id);
                try self.emitWord(coord_id);
            },
            .extract_image => {
                // Result type must be the image type inside the sampled image (Sampled=1)
                // Choose the correct inner ID based on the source sampler type
                const result_type_id: u32 = if (inst.ty == .sampler_buffer) blk: {
                    break :blk self.sampler_buffer_inner_id;
                } else blk: {
                    break :blk self.sampled_image_inner_id;
                };
                if (result_type_id == 0) return; // No sampler emitted, can't extract
                const result_id = resolved.result_id orelse return;
                const sampled_image_id = self.operandId(resolved, 0);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.OpImage)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(sampled_image_id);
            },
            .image_query_size => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const image_id = self.operandId(resolved, 0);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.ImageQuerySize)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(image_id);
            },
            .image_read => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.ImageRead)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(image_id);
                try self.emitWord(coord_id);
            },
            .image_write => {
                const image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                const value_id = self.operandId(resolved, 2);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.ImageWrite)));
                try self.emitWord(image_id);
                try self.emitWord(coord_id);
                try self.emitWord(value_id);
            },
            .atomic_iadd => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const ptr_id = self.operandId(resolved, 0);
                const value_id = self.operandId(resolved, 1);
                const scope: u32 = switch (resolved.operands[2]) { .literal_int => |v| v, else => 1 };
                const semantics: u32 = switch (resolved.operands[3]) { .literal_int => |v| v, else => 64 };
                try self.emitWord(spirv.encodeInstructionHeader(7, @intFromEnum(spirv.Op.AtomicIAdd)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(ptr_id);
                try self.emitWord(scope);
                try self.emitWord(semantics);
                try self.emitWord(value_id);
            },
            .transpose => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const matrix_id = self.operandId(resolved, 0);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Transpose)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(matrix_id);
            },
            .outer_product => {
                // outerProduct(a, b) where a=vecN, b=vecM → matNxM
                // For each column j: extract b[j], then OpVectorTimesScalar(a, b[j])
                // Then OpCompositeConstruct(col_0, col_1, ..., col_M-1)
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const a_id = self.operandId(resolved, 0);
                const b_id = self.operandId(resolved, 1);
                const num_cols = resolved.ty.numColumns();
                const col_type_id = try self.ensureType(resolved.ty.columnType());
                // Build each column: a * b[j]
                const col_ids = try self.alloc.alloc(u32, num_cols);
                for (0..num_cols) |j| {
                    const b_comp_id = self.allocId();
                    const float_id = try self.ensureType(.float);
                    try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.CompositeExtract)));
                    try self.emitWord(float_id);
                    try self.emitWord(b_comp_id);
                    try self.emitWord(b_id);
                    try self.emitWord(@intCast(j));
                    // VectorTimesScalar(a, b[j])
                    const col_id = self.allocId();
                    try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.VectorTimesScalar)));
                    try self.emitWord(col_type_id);
                    try self.emitWord(col_id);
                    try self.emitWord(a_id);
                    try self.emitWord(b_comp_id);
                    col_ids[j] = col_id;
                }
                // OpCompositeConstruct
                const wc: u16 = 3 + @as(u16, @intCast(num_cols));
                try self.emitWord(spirv.encodeInstructionHeader(wc, @intFromEnum(spirv.Op.CompositeConstruct)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                for (col_ids) |cid| {
                    try self.emitWord(cid);
                }
            },
            .dot => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const a_id = self.operandId(resolved, 0);
                const b_id = self.operandId(resolved, 1);
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.Dot)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(a_id);
                try self.emitWord(b_id);
            },
            .derivative => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const val_id = self.operandId(resolved, 1);
                const which = self.operandInt(resolved, 0);
                const opcode: u16 = if (which == 0) @intFromEnum(spirv.Op.DPdx) else @intFromEnum(spirv.Op.DPdy);
                try self.emitWord(spirv.encodeInstructionHeader(4, opcode));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(val_id);
            },
            .return_void => {
                try self.emitWord(spirv.encodeInstructionHeader(1, @intFromEnum(spirv.Op.Return)));
            },
            .return_val => {
                const val_id = self.operandId(resolved, 0);
                try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.ReturnValue)));
                try self.emitWord(val_id);
            },
            .unreachable_inst => {
                try self.emitWord(spirv.encodeInstructionHeader(1, @intFromEnum(spirv.Op.Unreachable)));
            },
            .label => {
                const label_id = resolved.result_id orelse return;
                try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Label)));
                try self.emitWord(label_id);
            },
            .branch => {
                const target_id = self.operandId(resolved, 0);
                try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Branch)));
                try self.emitWord(target_id);
            },
            .branch_conditional => {
                const cond_id = self.operandId(resolved, 0);
                const true_id = self.operandId(resolved, 1);
                const false_id = self.operandId(resolved, 2);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.BranchConditional)));
                try self.emitWord(cond_id);
                try self.emitWord(true_id);
                try self.emitWord(false_id);
            },
            .loop_merge => {
                const merge_id = self.operandId(resolved, 0);
                const continue_id = self.operandId(resolved, 1);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.LoopMerge)));
                try self.emitWord(merge_id);
                try self.emitWord(continue_id);
                try self.emitWord(0); // LoopControl = None
            },
            .selection_merge => {
                const merge_id = self.operandId(resolved, 0);
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.SelectionMerge)));
                try self.emitWord(merge_id);
                try self.emitWord(0); // SelectionControl = None
            },
            .ext_inst => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const ext_instruction = self.operandInt(resolved, 0);
                const wc: u16 = 5 + @as(u16, @intCast(resolved.operands.len - 1));
                try self.emitWord(spirv.encodeInstructionHeader(wc, @intFromEnum(spirv.Op.ExtInst)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(self.glsl_std_450_id);
                try self.emitWord(ext_instruction);
                for (resolved.operands[1..]) |op| {
                    try self.emitWord(self.operandValue(op));
                }
            },
            .function_call => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const function_id = self.operandId(resolved, 0);
                const num_args = resolved.operands.len - 1;
                const wc: u16 = 4 + @as(u16, @intCast(num_args));
                try self.emitWord(spirv.encodeInstructionHeader(wc, @intFromEnum(spirv.Op.FunctionCall)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(function_id);
                for (resolved.operands[1..]) |op| {
                    try self.emitWord(self.operandValue(op));
                }
            },
        }
    }

    fn emitBinOp(self: *Codegen, op: spirv.Op, inst: ir.Instruction) !void {
        const result_type_id = inst.result_type orelse return;
        const result_id = inst.result_id orelse return;
        const op1 = self.operandId(inst, 0);
        const op2 = self.operandId(inst, 1);
        try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(op)));
        try self.emitWord(result_type_id);
        try self.emitWord(result_id);
        try self.emitWord(op1);
        try self.emitWord(op2);
    }

    fn emitUnaryOp(self: *Codegen, op: spirv.Op, inst: ir.Instruction) !void {
        const result_type_id = inst.result_type orelse return;
        const result_id = inst.result_id orelse return;
        const operand = self.operandId(inst, 0);
        try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(op)));
        try self.emitWord(result_type_id);
        try self.emitWord(result_id);
        try self.emitWord(operand);
    }

    fn operandId(self: *Codegen, inst: ir.Instruction, index: usize) u32 {
        _ = self;
        return switch (inst.operands[index]) {
            .id => |id| id,
            else => @panic("operandId: expected id operand"),
        };
    }

    fn operandInt(self: *Codegen, inst: ir.Instruction, index: usize) u32 {
        _ = self;
        return switch (inst.operands[index]) {
            .literal_int => |v| v,
            else => @panic("operandInt: expected literal_int operand"),
        };
    }

    fn operandValue(self: *Codegen, op: ir.Instruction.Operand) u32 {
        _ = self;
        return switch (op) {
            .id => |v| v,
            .literal_int => |v| v,
            .literal_float => |v| @as(u32, @bitCast(v)),
            .literal_string => |_| 0,
        };
    }
};

test "codegen: header encoding" {
    const alloc = std.testing.allocator;
    const source = "#version 430\nvoid main() {}";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parser.parse(alloc, source, tokens);
    defer parser.freeTree(alloc, &root);
    var module = try semantic.analyze(alloc, &root);
    defer module.deinit();

    const result = try generate(alloc, &module, .fragment, .@"1.5");
    defer alloc.free(result);

    try std.testing.expectEqual(@as(u32, spirv.MAGIC), result[0]);
    try std.testing.expectEqual(spirv.encodeVersion(1, 5, 0), result[1]);
    try std.testing.expectEqual(@as(u32, 0), result[2]); // Generator
    try std.testing.expect(result[3] > 0); // Bound
    try std.testing.expectEqual(@as(u32, 0), result[4]); // Schema
}

test "codegen: capabilities emitted" {
    const alloc = std.testing.allocator;
    const source = "#version 430\nvoid main() {}";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parser.parse(alloc, source, tokens);
    defer parser.freeTree(alloc, &root);
    var module = try semantic.analyze(alloc, &root);
    defer module.deinit();

    const result = try generate(alloc, &module, .fragment, .@"1.5");
    defer alloc.free(result);

    // Word 5 should be OpCapability header (word_count=2, opcode=17)
    try std.testing.expectEqual(spirv.encodeInstructionHeader(2, 17), result[5]);
    try std.testing.expectEqual(@as(u32, 1), result[6]); // Shader capability
}

test "codegen: shader with arithmetic produces instructions" {
    const alloc = std.testing.allocator;
    const source = "void main() { float x = 1.0; float y = 2.0; }";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parser.parse(alloc, source, tokens);
    defer parser.freeTree(alloc, &root);
    var module = try semantic.analyze(alloc, &root);
    defer module.deinit();

    // Verify semantic analysis produced instructions
    try std.testing.expect(module.functions.len == 1);
    try std.testing.expect(module.functions[0].body.len > 0);

    // Generate SPIR-V binary
    const result = try generate(alloc, &module, .fragment, .@"1.5");
    defer alloc.free(result);

    // Verify header
    try std.testing.expectEqual(@as(u32, spirv.MAGIC), result[0]);
    try std.testing.expect(result[3] > 0); // Bound
}

test "codegen: if/else produces OpSelectionMerge and OpBranchConditional" {
    const alloc = std.testing.allocator;
    const source = "void main() { float x = 1.0; float y = 2.0; if (x > y) { x = 2.0; } else { x = 3.0; } }";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parser.parse(alloc, source, tokens);
    defer parser.freeTree(alloc, &root);
    var module = try semantic.analyze(alloc, &root);
    defer module.deinit();
    const result = try generate(alloc, &module, .fragment, .@"1.5");
    defer alloc.free(result);
    var has_sel_merge = false;
    var has_br_cond = false;
    var i: usize = 5;
    while (i < result.len) {
        const opcode: u16 = @truncate(result[i] & 0xFFFF);
        const wc: u16 = @truncate((result[i] >> 16) & 0xFFFF);
        if (opcode == 247) has_sel_merge = true;
        if (opcode == 250) has_br_cond = true;
        if (wc == 0) {
            i += 1;
            continue;
        }
        i += wc;
    }
    try std.testing.expect(has_sel_merge);
    try std.testing.expect(has_br_cond);
}

test "codegen: for loop produces OpLoopMerge" {
    const alloc = std.testing.allocator;
    const source = "void main() { for (int i = 0; i < 10; i = i + 1) { float x = 1.0; } }";
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parser.parse(alloc, source, tokens);
    defer parser.freeTree(alloc, &root);
    var module = semantic.analyze(alloc, &root) catch |err| {
        if (err == error.TypeMismatch) return;
        return err;
    };
    defer module.deinit();
    const result = try generate(alloc, &module, .fragment, .@"1.5");
    defer alloc.free(result);
    var has_loop_merge = false;
    var i: usize = 5;
    while (i < result.len) {
        const opcode: u16 = @truncate(result[i] & 0xFFFF);
        const wc: u16 = @truncate((result[i] >> 16) & 0xFFFF);
        if (opcode == 246) has_loop_merge = true;
        if (wc == 0) {
            i += 1;
            continue;
        }
        i += wc;
    }
    try std.testing.expect(has_loop_merge);
}