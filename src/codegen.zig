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
    glsl_version: u32,
    is_essl: bool,
) error{OutOfMemory, CodegenFailed}![]const u32 {
    var cg = Codegen{
        .alloc = alloc,
        .module = module,
        .stage = stage,
        .glsl_version = glsl_version,
        .is_essl = is_essl,
        .spirv_version = spirv_version,
        .words = std.ArrayList(u32).initCapacity(alloc, 0) catch unreachable,
        .type_section = std.ArrayList(u32).initCapacity(alloc, 0) catch unreachable,
        .decoration_section = std.ArrayList(u32).initCapacity(alloc, 0) catch unreachable,
        .name_section = std.ArrayList(u32).initCapacity(alloc, 0) catch unreachable,
        .next_id = module.next_id_start,
        .emitted_types = .{},
        .emitted_array_types = .{},
        .emitted_array_stride = .{},
        .emitted_struct_layout = .{},
        .emitted_named_types = .{},
        .emitted_ptr_types = .{},
        .emitted_constants = .{},
        .constant_alias = .{},
        .emitted_func_types = .{},
        .layout_visited = .{},
        .default_row_major = false,
        .ptr_storage_class = .{},
        .sampled_image_inner_id = 0,
        .sampled_image_3d_inner_id = 0,
        .sampled_image_2d_array_inner_id = 0,
        .sampled_image_1d_inner_id = 0,
        .sampled_image_ms_inner_id = 0,
        .sampled_image_ms_array_inner_id = 0,
        .sampler_buffer_inner_id = 0,
        .sampled_image_int_inner_id = 0,
        .sampled_image_uint_inner_id = 0,
        .sampled_image_int_ms_inner_id = 0,
        .sampled_image_uint_ms_inner_id = 0,
        .sampled_image_int_ms_array_inner_id = 0,
        .sampled_image_uint_ms_array_inner_id = 0,
        .sampled_image_int_1d_inner_id = 0,
        .sampled_image_uint_1d_inner_id = 0,
        .sampled_image_cube_inner_id = 0,
        .glsl_std_450_id = 0,
    };
    defer cg.deinit();

    try cg.emitHeader(spirv_version);
    try cg.emitCapabilities();
    try cg.emitExtensions();
    try cg.emitExtInstImport();
    try cg.emitMemoryModel();
    try cg.emitEntryPoint(stage);
    try cg.emitSource();
    const names_end_pos = cg.words.items.len;
    try cg.emitNames();
    try cg.emitDecorations();
    const decorations_end_pos = cg.words.items.len;
    try cg.emitTypesAndConstants();
    // Splice struct type names (OpName/OpMemberName from ensureType)
    // These must go in the debug section (after emitNames, before emitDecorations)
    if (cg.name_section.items.len > 0) {
        const after_names_words = try cg.allocator().dupe(u32, cg.words.items[names_end_pos..]);
        cg.words.shrinkRetainingCapacity(names_end_pos);
        try cg.words.appendSlice(cg.allocator(), cg.name_section.items);
        try cg.words.appendSlice(cg.allocator(), after_names_words);
        cg.allocator().free(after_names_words);
    }
    // Splice struct layout decorations (Block, Offset, ArrayStride)
    // These are accumulated in decoration_section during emitTypesAndConstants.
    // They must go in the annotation section (between emitDecorations and types).
    if (cg.decoration_section.items.len > 0) {
        const dec_end_adjusted = if (cg.name_section.items.len > 0) decorations_end_pos + cg.name_section.items.len else decorations_end_pos;
        const type_words = try cg.allocator().dupe(u32, cg.words.items[dec_end_adjusted..]);
        cg.words.shrinkRetainingCapacity(dec_end_adjusted);
        try cg.words.appendSlice(cg.allocator(), cg.decoration_section.items);
        try cg.words.appendSlice(cg.allocator(), type_words);
        cg.allocator().free(type_words);
    }
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
    glsl_version: u32,
    is_essl: bool,
    spirv_version: SPIRVVersion,
    words: std.ArrayList(u32),
    type_section: std.ArrayList(u32), // Types/constants emitted during function codegen
    decoration_section: std.ArrayList(u32), // Struct layout decorations (Block, Offset, ArrayStride)
    name_section: std.ArrayList(u32), // OpName/OpMemberName for struct types
    in_functions: bool = false,
    next_id: u32,
    emitted_types: std.AutoHashMapUnmanaged(u32, u32), // @intFromEnum(ty) -> type_id
    emitted_array_types: std.AutoHashMapUnmanaged(u64, u32), // hash -> type_id
    emitted_array_stride: std.AutoHashMapUnmanaged(u32, void), // array type_ids with ArrayStride already emitted
    emitted_struct_layout: std.AutoHashMapUnmanaged(u32, void), // struct type_ids with layout decorations already emitted
    emitted_named_types: std.StringHashMapUnmanaged(u32), // struct name -> type_id
    emitted_ptr_types: std.AutoHashMapUnmanaged(u64, u32), // (type_key << 32 | sc) -> ptr_type_id
    emitted_constants: std.AutoHashMapUnmanaged(u64, u32), // (type_id << 32 | value) -> const_id
    constant_alias: std.AutoHashMapUnmanaged(u32, u32), // IR result_id -> actual constant_id (dedup)
    emitted_func_types: std.AutoHashMapUnmanaged(u64, u32), // hash(ret+params) -> func_type_id
    layout_visited: std.AutoHashMapUnmanaged(u32, void), // struct type_ids currently being laid out (cycle detection)
    default_row_major: bool, // current block-level matrix layout
    ptr_storage_class: std.AutoHashMapUnmanaged(u32, ir.SPIRVStorageClass), // result_id -> storage class for pointers
    sampled_image_inner_id: u32, // TypeImage (Sampled=1) for use with OpImage extraction
    sampled_image_3d_inner_id: u32,
    sampled_image_2d_array_inner_id: u32,
    sampled_image_1d_inner_id: u32,
    sampled_image_ms_inner_id: u32, // TypeImage (Multisampled=1, Sampled=1)
    sampled_image_ms_array_inner_id: u32, // TypeImage (Multisampled=1, Arrayed=1, Sampled=1)
    sampler_buffer_inner_id: u32, // TypeImage (Dim=Buffer, Sampled=1) for texelFetch
    sampled_image_int_inner_id: u32, // TypeImage (int, Sampled=1) for integer sampler OpImage extraction
    sampled_image_uint_inner_id: u32, // TypeImage (uint, Sampled=1) for unsigned sampler OpImage extraction
    sampled_image_int_ms_inner_id: u32,
    sampled_image_uint_ms_inner_id: u32,
    sampled_image_int_ms_array_inner_id: u32,
    sampled_image_uint_ms_array_inner_id: u32,
    sampled_image_int_1d_inner_id: u32,
    sampled_image_uint_1d_inner_id: u32,
    sampled_image_cube_inner_id: u32, // TypeImage (Dim=Cube, Sampled=1)
    glsl_std_450_id: u32,

    fn deinit(self: *Codegen) void {
        self.emitted_types.deinit(self.alloc);
        self.emitted_array_types.deinit(self.alloc);
        self.emitted_array_stride.deinit(self.alloc);
        self.emitted_struct_layout.deinit(self.alloc);
        self.emitted_named_types.deinit(self.alloc);
        self.emitted_ptr_types.deinit(self.alloc);
        self.emitted_constants.deinit(self.alloc);
        self.constant_alias.deinit(self.alloc);
        self.emitted_func_types.deinit(self.alloc);
        self.layout_visited.deinit(self.alloc);
        self.ptr_storage_class.deinit(self.alloc);
        self.words.deinit(self.alloc);
        self.type_section.deinit(self.alloc);
        self.decoration_section.deinit(self.alloc);
        self.name_section.deinit(self.alloc);
    }

    fn allocId(self: *Codegen) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn emitWord(self: *Codegen, word: u32) !void {
        try self.words.append(self.alloc, word);
    }

    // Emit a word to the type section when in function codegen, main stream otherwise
    fn emitTypeWord(self: *Codegen, word: u32) !void {
        if (self.in_functions) {
            try self.type_section.append(self.alloc, word);
        } else {
            try self.words.append(self.alloc, word);
        }
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
        // Always emit Shader capability
        try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
        try self.emitWord(@intFromEnum(spirv.Capability.shader));

        // Only emit additional capabilities if the module actually uses them
        var has_subgroup_vote = false;
        var has_float_atomic = false;

        for (self.module.functions) |func| {
            for (func.body) |inst| {
                switch (inst.tag) {
                    .group_all, .group_any => has_subgroup_vote = true,
                    .atomic_fadd => has_float_atomic = true,
                    else => {},
                }
            }
        }

        // Check for specific image-related capabilities based on actual usage
        var has_image_query = false;
        var has_sampler1d = false;
        var has_sampler_buffer = false;
        var has_cube_array = false;
        var has_sampler2d_ms_array = false;

        for (self.module.functions) |func| {
            for (func.body) |inst| {
                switch (inst.tag) {
                    .image_query_size, .image_query_size_lod,
                    .image_query_levels, .image_query_samples,
                    => has_image_query = true,
                    else => {},
                }
            }
        }

        // Check global sampler types for type-specific capabilities
        var has_storage_image_ms = false;
        for (self.module.globals) |global| {
            switch (global.ty) {
                .sampler1d, .isampler1d, .usampler1d, .image1d, .iimage1d, .uimage1d => has_sampler1d = true,
                .sampler_buffer, .isampler_buffer, .usampler_buffer => has_sampler_buffer = true,
                .sampler2d_ms_array, .isampler2d_ms_array, .usampler2d_ms_array, .image2d_ms_array => {
                    has_sampler2d_ms_array = true;
                    has_storage_image_ms = true;
                },
                .image2d_ms, .sampler2d_ms, .isampler2d_ms, .usampler2d_ms => has_storage_image_ms = true,
                .sampler_cube_array_shadow, .isampler_cube_array, .usampler_cube_array,
                .image_cube_array, .iimage_cube_array, .uimage_cube_array => has_cube_array = true,
                else => {},
            }
        }

        if (has_image_query) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.image_query));
        }
        if (has_sampler1d) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.image_1d));
        }
        if (has_sampler_buffer) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.sampled_buffer));
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.image_buffer));
        }
        if (has_sampler2d_ms_array) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.image_ms_array));
        }
        if (has_storage_image_ms) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.storage_image_multisample));
        }
        if (has_cube_array) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.image_cube_array));
        }
        if (has_subgroup_vote) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.subgroup_vote_khr));
        }
        if (has_float_atomic) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.atomic_float32_add_ext));
        }
        if (self.hasBufferReference()) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.physical_storage_buffer_addresses));
            // Int64 capability is required for 64-bit buffer pointers
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.int64));
        }
        // Emit 8/16-bit type capabilities if needed
        var has_int8 = false;
        var has_int16 = false;
        var has_float16 = false;
        for (self.module.globals) |global| {
            has_int8 = has_int8 or self.typeUsesInt8(global.ty);
            has_int16 = has_int16 or self.typeUsesInt16(global.ty);
            has_float16 = has_float16 or self.typeUsesFloat16(global.ty);
        }
        // Also check struct members for 8/16-bit types
        var type_iter = self.module.types.iterator();
        while (type_iter.next()) |entry| {
            for (entry.value_ptr.members) |member| {
                has_int8 = has_int8 or self.typeUsesInt8(member.ty);
                has_int16 = has_int16 or self.typeUsesInt16(member.ty);
                has_float16 = has_float16 or self.typeUsesFloat16(member.ty);
            }
        }
        // Also check function IR instructions for 8/16-bit types
        for (self.module.functions) |func| {
            for (func.body) |inst| {
                has_int8 = has_int8 or self.typeUsesInt8(inst.ty);
                has_int16 = has_int16 or self.typeUsesInt16(inst.ty);
                has_float16 = has_float16 or self.typeUsesFloat16(inst.ty);
            }
        }
        if (has_int8) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.int8));
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.storage_uniform_buffer_block8));
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.storage_push_constant8));
        }
        if (has_int16) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.int16));
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.storage_uniform16));
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.storage_push_constant16));
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.storage_buffer16_bit));
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.storage_input_output16));
        }
        if (has_float16) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.float16));
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.storage_uniform16));
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.storage_push_constant16));
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.storage_buffer16_bit));
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.storage_input_output16));
        }
    }

    fn typeUsesFloat16(self: *Codegen, ty: ast.Type) bool {
        return switch (ty) {
            .float16, .f16vec2, .f16vec3, .f16vec4 => true,
            .array => |arr| self.typeUsesFloat16(arr.base.*),
            else => false,
        };
    }
    fn typeUsesInt8(self: *Codegen, ty: ast.Type) bool {
        return switch (ty) {
            .int8, .i8vec2, .i8vec3, .i8vec4, .uint8, .u8vec2, .u8vec3, .u8vec4 => true,
            .array => |arr| self.typeUsesInt8(arr.base.*),
            else => false,
        };
    }
    fn typeUsesInt16(self: *Codegen, ty: ast.Type) bool {
        return switch (ty) {
            .int16, .i16vec2, .i16vec3, .i16vec4, .uint16, .u16vec2, .u16vec3, .u16vec4 => true,
            .array => |arr| self.typeUsesInt16(arr.base.*),
            else => false,
        };
    }

    fn emitExtensions(self: *Codegen) !void {
        // Check if subgroup vote ops are used
        var has_subgroup_vote = false;
        for (self.module.functions) |func| {
            for (func.body) |inst| {
                switch (inst.tag) {
                    .group_all, .group_any => has_subgroup_vote = true,
                    else => {},
                }
                if (has_subgroup_vote) break;
            }
            if (has_subgroup_vote) break;
        }
        if (has_subgroup_vote) {
            const ext_name = "SPV_KHR_subgroup_vote";
            const ext_word_count: u16 = 1 + @as(u16, @intCast(std.math.divCeil(usize, ext_name.len + 1, 4) catch unreachable));
            try self.emitWord(spirv.encodeInstructionHeader(ext_word_count, @intFromEnum(spirv.Op.Extension)));
            const num_words = std.math.divCeil(usize, ext_name.len + 1, 4) catch unreachable;
            const ext_words = try self.alloc.alloc(u32, num_words);
            @memset(ext_words, 0);
            for (ext_name, 0..) |byte, idx| {
                const word_idx = idx / 4;
                const byte_idx = idx % 4;
                ext_words[word_idx] |= @as(u32, byte) << @intCast(byte_idx * 8);
            }
            for (ext_words) |w| try self.emitWord(w);
            self.alloc.free(ext_words);
        }
        // Check if float atomics are used — need SPV_EXT_shader_atomic_float_add
        var has_float_atomic = false;
        for (self.module.functions) |func| {
            for (func.body) |inst| {
                if (inst.tag == .atomic_fadd) {
                    has_float_atomic = true;
                    break;
                }
            }
            if (has_float_atomic) break;
        }
        if (has_float_atomic) {
            const ext_name = "SPV_EXT_shader_atomic_float_add";
            const ext_word_count: u16 = 1 + @as(u16, @intCast(std.math.divCeil(usize, ext_name.len + 1, 4) catch unreachable));
            try self.emitWord(spirv.encodeInstructionHeader(ext_word_count, @intFromEnum(spirv.Op.Extension)));
            const num_words = std.math.divCeil(usize, ext_name.len + 1, 4) catch unreachable;
            const ext_words = try self.alloc.alloc(u32, num_words);
            @memset(ext_words, 0);
            for (ext_name, 0..) |byte, idx| {
                const word_idx = idx / 4;
                const byte_idx = idx % 4;
                ext_words[word_idx] |= @as(u32, byte) << @intCast(byte_idx * 8);
            }
            for (ext_words) |w| try self.emitWord(w);
            self.alloc.free(ext_words);
        }
        // Emit SPV_KHR_physical_storage_buffer extension for buffer_reference
        if (self.hasBufferReference()) {
            const ext_name2 = "SPV_KHR_physical_storage_buffer";
            const ext_word_count2: u16 = 1 + @as(u16, @intCast(std.math.divCeil(usize, ext_name2.len + 1, 4) catch unreachable));
            try self.emitWord(spirv.encodeInstructionHeader(ext_word_count2, @intFromEnum(spirv.Op.Extension)));
            const num_words2 = std.math.divCeil(usize, ext_name2.len + 1, 4) catch unreachable;
            const ext_words2 = try self.alloc.alloc(u32, num_words2);
            @memset(ext_words2, 0);
            for (ext_name2, 0..) |byte, idx| {
                const word_idx = idx / 4;
                const byte_idx = idx % 4;
                ext_words2[word_idx] |= @as(u32, byte) << @intCast(byte_idx * 8);
            }
            for (ext_words2) |w| try self.emitWord(w);
            self.alloc.free(ext_words2);
        }
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

    fn hasBufferReference(self: *Codegen) bool {
        var it = self.module.types.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.is_buffer_reference) return true;
        }
        return false;
    }

    fn emitMemoryModel(self: *Codegen) !void {
        try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.MemoryModel)));
        if (self.hasBufferReference()) {
            try self.emitWord(@intFromEnum(spirv.AddressingModel.PhysicalStorageBuffer64));
        } else {
            try self.emitWord(0); // Logical
        }
        try self.emitWord(1); // GLSL450
    }

    fn emitSource(self: *Codegen) !void {
        // OpSource SourceLanguage version
        // ESSL=1 (OpenGL ES Shading Language), GLSL=2 (OpenGL Shading Language)
        const source_lang: u32 = if (self.is_essl) 1 else 2;
        try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.Source)));
        try self.emitWord(source_lang);
        try self.emitWord(self.glsl_version);
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
        // SPIR-V 1.0-1.3: only Input/Output storage class variables
        var interface_ids = std.ArrayList(u32).initCapacity(self.alloc, 0) catch unreachable;
        defer interface_ids.deinit(self.alloc);
        const list_all = @intFromEnum(self.spirv_version) >= 4; // 1.4+
        for (self.module.globals) |global| {
            if (list_all or global.storage_class == .input or global.storage_class == .output) {
                interface_ids.append(self.alloc, global.result_id) catch unreachable;
            }
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
                try self.emitTypeWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.TypeVoid)));
                try self.emitTypeWord(id);
            },
            .bool => {
                try self.emitTypeWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.TypeBool)));
                try self.emitTypeWord(id);
            },
            .int => {
                try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeInt)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(32); // bit width
                try self.emitTypeWord(1); // signed
            },
            .uint => {
                try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeInt)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(32);
                try self.emitTypeWord(0); // unsigned
            },
            .int8 => {
                try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeInt)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(8);
                try self.emitTypeWord(1); // signed
            },
            .uint8 => {
                try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeInt)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(8);
                try self.emitTypeWord(0); // unsigned
            },
            .int16 => {
                try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeInt)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(16);
                try self.emitTypeWord(1); // signed
            },
            .uint16 => {
                try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeInt)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(16);
                try self.emitTypeWord(0); // unsigned
            },
            .float16 => {
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeFloat)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(16);
            },
            .float => {
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeFloat)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(32);
            },
            .double => {
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeFloat)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(64);
            },
            .vec2, .vec3, .vec4,
            .ivec2, .ivec3, .ivec4,
            .bvec2, .bvec3, .bvec4,
            .uvec2, .uvec3, .uvec4,
            .i8vec2, .i8vec3, .i8vec4,
            .u8vec2, .u8vec3, .u8vec4,
            .i16vec2, .i16vec3, .i16vec4,
            .u16vec2, .u16vec3, .u16vec4,
            .f16vec2, .f16vec3, .f16vec4 => {
                const elem_type = try self.ensureType(ty.elementType());
                const count = ty.numComponents();
                try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeVector)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(elem_type);
                try self.emitTypeWord(count);
            },
            .mat2, .mat2x2, .mat2x3, .mat2x4,
            .mat3x2, .mat3, .mat3x3, .mat3x4,
            .mat4x2, .mat4x3, .mat4, .mat4x4 => {
                const col_type = try self.ensureType(ty.columnType());
                const num_cols = ty.numColumns();
                try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeMatrix)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(col_type);
                try self.emitTypeWord(num_cols);
            },
            .sampler2d => {
                const float_id = try self.ensureType(.float);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(1); // Dim = 2D
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(0); // Not arrayed
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(1); // Sampled = 1 (yes)
                try self.emitTypeWord(0); // ImageFormat = Unknown
                self.sampled_image_inner_id = image_id; // Save for OpImage extraction
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .sampler2d_array => {
                const float_id = try self.ensureType(.float);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(1); // Dim = 2D
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(1); // Arrayed = 1
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(1); // Sampled = 1 (yes)
                try self.emitTypeWord(0); // ImageFormat = Unknown
                self.sampled_image_2d_array_inner_id = image_id;
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .sampler3d => {
                const float_id = try self.ensureType(.float);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(2); // Dim = 3D
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(0); // Not arrayed
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(1); // Sampled = 1 (yes)
                try self.emitTypeWord(0); // ImageFormat = Unknown
                self.sampled_image_3d_inner_id = image_id;
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .sampler1d => {
                const float_id = try self.ensureType(.float);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(0); // Dim = 1D
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(0); // Not arrayed
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(1); // Sampled = 1 (yes)
                try self.emitTypeWord(0); // ImageFormat = Unknown
                self.sampled_image_1d_inner_id = image_id;
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .sampler1d_shadow => {
                const float_id = try self.ensureType(.float);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(0); // Dim = 1D
                try self.emitTypeWord(1); // Depth = 1
                try self.emitTypeWord(0); // Not arrayed
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(1); // Sampled = 1 (yes)
                try self.emitTypeWord(0); // ImageFormat = Unknown
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .sampler_buffer => {
                // samplerBuffer → TypeImage with Dim=Buffer, then TypeSampledImage
                const float_id = try self.ensureType(.float);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(5); // Dim = Buffer
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(0); // Not arrayed
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(1); // Sampled = 1 (with sampler)
                try self.emitTypeWord(0); // ImageFormat = Unknown
                self.sampler_buffer_inner_id = image_id;
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .image2d => {
                const float_id = try self.ensureType(.float);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(1); // Dim = 2D
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(0); // Not arrayed
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(2); // Sampled = 2 (no sampler needed)
                try self.emitTypeWord(0); // ImageFormat = Unknown
            },
            .iimage2d => {
                const int_id = try self.ensureType(.int);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(int_id);
                try self.emitTypeWord(1); // Dim = 2D
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(0); // Not arrayed
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(2); // Sampled = 2 (no sampler needed)
                try self.emitTypeWord(0); // ImageFormat = Unknown
            },
            .uimage2d => {
                const uint_id = try self.ensureType(.uint);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(uint_id);
                try self.emitTypeWord(1); // Dim = 2D
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(0); // Not arrayed
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(2); // Sampled = 2 (no sampler needed)
                try self.emitTypeWord(0); // ImageFormat = Unknown
            },
            .image_buffer => {
                const float_id = try self.ensureType(.float);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(5); // Dim = Buffer
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(0); // Not arrayed
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(2); // Sampled = 2 (no sampler needed)
                try self.emitTypeWord(0); // ImageFormat = Unknown
            },
            .image2d_ms => {
                const float_id = try self.ensureType(.float);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(1); // Dim = 2D
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(0); // Not arrayed
                try self.emitTypeWord(1); // Multisampled = 1
                try self.emitTypeWord(2); // Sampled = 2 (no sampler needed)
                try self.emitTypeWord(0); // ImageFormat = Unknown
            },
            .image2d_ms_array => {
                const float_id = try self.ensureType(.float);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(1); // Dim = 2D
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(1); // Arrayed = 1
                try self.emitTypeWord(1); // Multisampled = 1
                try self.emitTypeWord(2); // Sampled = 2 (no sampler needed)
                try self.emitTypeWord(0); // ImageFormat = Unknown
            },
            .image1d => {
                const float_id = try self.ensureType(.float);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(0); // Dim = 1D
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(0); // Not arrayed
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(2); // Sampled = 2
                try self.emitTypeWord(0);
            },
            .iimage1d => {
                const int_id = try self.ensureType(.int);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(int_id);
                try self.emitTypeWord(0); // Dim = 1D
                try self.emitTypeWord(0);
                try self.emitTypeWord(0);
                try self.emitTypeWord(0);
                try self.emitTypeWord(2);
                try self.emitTypeWord(0);
            },
            .uimage1d => {
                const uint_id = try self.ensureType(.uint);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(uint_id);
                try self.emitTypeWord(0); // Dim = 1D
                try self.emitTypeWord(0);
                try self.emitTypeWord(0);
                try self.emitTypeWord(0);
                try self.emitTypeWord(2);
                try self.emitTypeWord(0);
            },
            .image3d => {
                const float_id = try self.ensureType(.float);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(2); // Dim = 3D
                try self.emitTypeWord(0);
                try self.emitTypeWord(0);
                try self.emitTypeWord(0);
                try self.emitTypeWord(2);
                try self.emitTypeWord(0);
            },
            .iimage3d => {
                const int_id = try self.ensureType(.int);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(int_id);
                try self.emitTypeWord(2); // Dim = 3D
                try self.emitTypeWord(0);
                try self.emitTypeWord(0);
                try self.emitTypeWord(0);
                try self.emitTypeWord(2);
                try self.emitTypeWord(0);
            },
            .uimage3d => {
                const uint_id = try self.ensureType(.uint);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(uint_id);
                try self.emitTypeWord(2); // Dim = 3D
                try self.emitTypeWord(0);
                try self.emitTypeWord(0);
                try self.emitTypeWord(0);
                try self.emitTypeWord(2);
                try self.emitTypeWord(0);
            },
            .image_cube => {
                const float_id = try self.ensureType(.float);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(3); // Dim = Cube
                try self.emitTypeWord(0);
                try self.emitTypeWord(0);
                try self.emitTypeWord(0);
                try self.emitTypeWord(2);
                try self.emitTypeWord(0);
            },
            .iimage_cube => {
                const int_id = try self.ensureType(.int);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(int_id);
                try self.emitTypeWord(3); // Dim = Cube
                try self.emitTypeWord(0);
                try self.emitTypeWord(0);
                try self.emitTypeWord(0);
                try self.emitTypeWord(2);
                try self.emitTypeWord(0);
            },
            .uimage_cube => {
                const uint_id = try self.ensureType(.uint);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(uint_id);
                try self.emitTypeWord(3); // Dim = Cube
                try self.emitTypeWord(0);
                try self.emitTypeWord(0);
                try self.emitTypeWord(0);
                try self.emitTypeWord(2);
                try self.emitTypeWord(0);
            },
            .image2d_array => {
                const float_id = try self.ensureType(.float);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(1); // Dim = 2D
                try self.emitTypeWord(0);
                try self.emitTypeWord(1); // Arrayed = 1
                try self.emitTypeWord(0);
                try self.emitTypeWord(2);
                try self.emitTypeWord(0);
            },
            .iimage2d_array => {
                const int_id = try self.ensureType(.int);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(int_id);
                try self.emitTypeWord(1); // Dim = 2D
                try self.emitTypeWord(0);
                try self.emitTypeWord(1); // Arrayed = 1
                try self.emitTypeWord(0);
                try self.emitTypeWord(2);
                try self.emitTypeWord(0);
            },
            .uimage2d_array => {
                const uint_id = try self.ensureType(.uint);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(uint_id);
                try self.emitTypeWord(1); // Dim = 2D
                try self.emitTypeWord(0);
                try self.emitTypeWord(1); // Arrayed = 1
                try self.emitTypeWord(0);
                try self.emitTypeWord(2);
                try self.emitTypeWord(0);
            },
            .image_cube_array => {
                const float_id = try self.ensureType(.float);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(3); // Dim = Cube
                try self.emitTypeWord(0);
                try self.emitTypeWord(1); // Arrayed = 1
                try self.emitTypeWord(0);
                try self.emitTypeWord(2);
                try self.emitTypeWord(0);
            },
            .iimage_cube_array => {
                const int_id = try self.ensureType(.int);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(int_id);
                try self.emitTypeWord(3); // Dim = Cube
                try self.emitTypeWord(0);
                try self.emitTypeWord(1); // Arrayed = 1
                try self.emitTypeWord(0);
                try self.emitTypeWord(2);
                try self.emitTypeWord(0);
            },
            .uimage_cube_array => {
                const uint_id = try self.ensureType(.uint);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(uint_id);
                try self.emitTypeWord(3); // Dim = Cube
                try self.emitTypeWord(0);
                try self.emitTypeWord(1); // Arrayed = 1
                try self.emitTypeWord(0);
                try self.emitTypeWord(2);
                try self.emitTypeWord(0);
            },
            .sampler_cube => {
                const float_id = try self.ensureType(.float);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(3); // Dim = Cube
                try self.emitTypeWord(0);
                try self.emitTypeWord(0);
                try self.emitTypeWord(0);
                try self.emitTypeWord(1);
                try self.emitTypeWord(0);
                self.sampled_image_cube_inner_id = image_id;
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .sampler2d_shadow => {
                const float_id = try self.ensureType(.float);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(1); // Dim = 2D
                try self.emitTypeWord(1); // Depth = 1
                try self.emitTypeWord(0); // Not arrayed
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(1); // Sampled = 1
                try self.emitTypeWord(0); // ImageFormat = Unknown
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .sampler_cube_shadow => {
                const float_id = try self.ensureType(.float);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(3); // Dim = Cube
                try self.emitTypeWord(1); // Depth = 1
                try self.emitTypeWord(0); // Not arrayed
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(1); // Sampled = 1
                try self.emitTypeWord(0); // ImageFormat = Unknown
                self.sampled_image_cube_inner_id = image_id;
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .sampler_cube_array_shadow => {
                const float_id = try self.ensureType(.float);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(3); // Dim = Cube
                try self.emitTypeWord(1); // Depth = 1
                try self.emitTypeWord(1); // Arrayed = 1
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(1); // Sampled = 1
                try self.emitTypeWord(0); // ImageFormat = Unknown
                self.sampled_image_cube_inner_id = image_id; // Cube array uses same inner
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .sampler2d_array_shadow => {
                const float_id = try self.ensureType(.float);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(1); // Dim = 2D
                try self.emitTypeWord(1); // Depth = 1
                try self.emitTypeWord(1); // Arrayed = 1
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(1); // Sampled = 1
                try self.emitTypeWord(0); // ImageFormat = Unknown
                self.sampled_image_1d_inner_id = image_id;
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .sampler2d_ms => {
                const float_id = try self.ensureType(.float);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(1); // Dim = 2D
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(0); // Not arrayed
                try self.emitTypeWord(1); // Multisampled = 1
                try self.emitTypeWord(1); // Sampled = 1 (with sampler)
                try self.emitTypeWord(0); // ImageFormat = Unknown
                self.sampled_image_ms_inner_id = image_id;
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .sampler2d_ms_array => {
                const float_id = try self.ensureType(.float);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(1); // Dim = 2D
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(1); // Arrayed = 1
                try self.emitTypeWord(1); // Multisampled = 1
                try self.emitTypeWord(1); // Sampled = 1 (with sampler)
                try self.emitTypeWord(0); // ImageFormat = Unknown
                self.sampled_image_ms_array_inner_id = image_id;
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            // Integer sampler types — same as float counterparts but with int as sampled type
            .isampler2d => {
                const base_id = try self.ensureType(.int);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(1); // Dim = 2D
                try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0);
                self.sampled_image_int_inner_id = image_id;
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .usampler2d => {
                const base_id = try self.ensureType(.uint);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(1); // Dim = 2D
                try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0);
                self.sampled_image_uint_inner_id = image_id;
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .isampler3d => {
                const base_id = try self.ensureType(.int);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(2); // Dim = 3D
                try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0);
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .usampler3d => {
                const base_id = try self.ensureType(.uint);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(2); // Dim = 3D
                try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0);
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .isampler_cube => {
                const base_id = try self.ensureType(.int);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(3); // Dim = Cube
                try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0);
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .usampler_cube => {
                const base_id = try self.ensureType(.uint);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(3); // Dim = Cube
                try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0);
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .isampler2d_array => {
                const base_id = try self.ensureType(.int);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(1); // Dim = 2D
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(1); // Arrayed = 1
                try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0);
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .usampler2d_array => {
                const base_id = try self.ensureType(.uint);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(1); // Dim = 2D
                try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0);
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .isampler2d_ms => {
                const base_id = try self.ensureType(.int);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(1); try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(1); try self.emitTypeWord(0);
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .usampler2d_ms => {
                const base_id = try self.ensureType(.uint);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(1); try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(1); try self.emitTypeWord(0);
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .isampler2d_ms_array => {
                const base_id = try self.ensureType(.int);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(1); try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(1); try self.emitTypeWord(1); try self.emitTypeWord(0);
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .usampler2d_ms_array => {
                const base_id = try self.ensureType(.uint);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(1); try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(1); try self.emitTypeWord(1); try self.emitTypeWord(0);
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .isampler_cube_array => {
                const base_id = try self.ensureType(.int);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(3); // Dim = Cube
                try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0);
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .usampler_cube_array => {
                const base_id = try self.ensureType(.uint);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(3); // Dim = Cube
                try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0);
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .isampler1d => {
                const base_id = try self.ensureType(.int);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(0); // Dim = 1D
                try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0);
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .usampler1d => {
                const base_id = try self.ensureType(.uint);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(0); // Dim = 1D
                try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0);
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .isampler1d_array => {
                const base_id = try self.ensureType(.int);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(0); // Dim = 1D
                try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0);
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .usampler1d_array => {
                const base_id = try self.ensureType(.uint);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(0); // Dim = 1D
                try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0);
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .isampler_buffer => {
                const base_id = try self.ensureType(.int);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(5); // Dim = Buffer
                try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0);
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .usampler_buffer => {
                const base_id = try self.ensureType(.uint);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(base_id);
                try self.emitTypeWord(5); // Dim = Buffer
                try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(0); try self.emitTypeWord(1); try self.emitTypeWord(0);
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .named => |name| {
                // Check if this named type was already emitted
                if (self.emitted_named_types.get(name)) |cached_id| {
                    return cached_id;
                }
                const td = self.module.types.get(name) orelse {
                    // Named type not found — emit empty struct as placeholder
                    const word_count: u16 = 2;
                    try self.emitTypeWord(spirv.encodeInstructionHeader(word_count, @intFromEnum(spirv.Op.TypeStruct)));
                    try self.emitTypeWord(id);
                    try self.emitted_named_types.put(self.alloc, name, id);
                    return id;
                };
                // Forward-declare: cache the ID before processing members
                // to break recursive type cycles (e.g., Node containing Node)
                try self.emitted_named_types.put(self.alloc, name, id);

                // For buffer_reference types, check for self-referential members
                // If found, emit OpTypeForwardPointer upfront
                var self_ptr_id: u32 = 0;
                if (td.is_buffer_reference) {
                    var has_self_ref = false;
                    for (td.members) |member| {
                        var resolved_ty = member.ty;
                        while (resolved_ty == .array) resolved_ty = resolved_ty.array.base.*;
                        if (resolved_ty == .named and std.mem.eql(u8, resolved_ty.named, name)) {
                            has_self_ref = true;
                            break;
                        }
                    }
                    if (has_self_ref) {
                        // Allocate pointer ID and emit forward pointer
                        self_ptr_id = self.allocId();
                        try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeForwardPointer)));
                        try self.emitTypeWord(self_ptr_id);
                        try self.emitTypeWord(5349); // PhysicalStorageBuffer
                        const ptr_key = (@as(u64, id) << 32) | @as(u64, 5349);
                        try self.emitted_ptr_types.put(self.alloc, ptr_key, self_ptr_id);
                    }
                }

                var member_ids = try std.ArrayList(u32).initCapacity(self.alloc, td.members.len);
                defer member_ids.deinit(self.alloc);
                for (td.members) |member| {
                    // If member is a buffer_reference named type, emit PhysicalStorageBuffer pointer
                    var resolved_ty = member.ty;
                    while (resolved_ty == .array) resolved_ty = resolved_ty.array.base.*;
                    if (resolved_ty == .named) {
                        const member_td = self.module.types.get(resolved_ty.named);
                        if (member_td != null and member_td.?.is_buffer_reference) {
                            // Self-referential: use the forward-declared pointer
                            if (self_ptr_id != 0 and std.mem.eql(u8, resolved_ty.named, name) and member.ty == .named) {
                                try member_ids.append(self.alloc, self_ptr_id);
                                continue;
                            }
                            // Emit the struct type first (if not already emitted)
                            const struct_id = try self.ensureType(member.ty);
                            // For arrays of buffer_reference, we need the pointer to the struct
                            // not the struct itself as the member type
                            if (member.ty == .named) {
                                // Emit OpTypePointer PhysicalStorageBuffer <struct>
                                const ptr_key = (@as(u64, struct_id) << 32) | @as(u64, 5349);
                                if (self.emitted_ptr_types.get(ptr_key)) |ptr_id| {
                                    try member_ids.append(self.alloc, ptr_id);
                                } else {
                                    const ptr_id = self.allocId();
                                    try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypePointer)));
                                    try self.emitTypeWord(ptr_id);
                                    try self.emitTypeWord(5349); // PhysicalStorageBuffer
                                    try self.emitTypeWord(struct_id);
                                    try self.emitted_ptr_types.put(self.alloc, ptr_key, ptr_id);
                                    try member_ids.append(self.alloc, ptr_id);
                                }
                                continue;
                            }
                            // For arrays of buffer_reference types, fall through
                        }
                    }
                    try member_ids.append(self.alloc, try self.ensureType(member.ty));
                }
                const word_count: u16 = 2 + @as(u16, @intCast(member_ids.items.len));
                try self.emitTypeWord(spirv.encodeInstructionHeader(word_count, @intFromEnum(spirv.Op.TypeStruct)));
                try self.emitTypeWord(id);
                for (member_ids.items) |mid| {
                    try self.emitTypeWord(mid);
                }
                // Emit OpName for this struct type
                try self.emitNameSectionName(id, name);
                // Emit OpMemberName for each struct member
                for (td.members, 0..) |member, i| {
                    if (member.name.len > 0) {
                        try self.emitNameSectionMemberName(id, @as(u32, @intCast(i)), member.name);
                    }
                }
                // Emit UBO/SSBO decorations: Block + Offset/MatrixStride/ArrayStride
                // Check if this named type is used as a uniform/storage buffer global
                var needs_block = false;
                var block_is_std430 = false;
                var block_row_major = false;
                for (self.module.globals) |global| {
                    if (global.storage_class != .uniform and global.storage_class != .storage_buffer) continue;
                    if (global.ty != .named) continue;
                    if (!std.mem.eql(u8, global.ty.named, name)) continue;
                    needs_block = true;
                    if (global.layout) |l| {
                        block_is_std430 = l.std430;
                        block_row_major = l.row_major;
                    }
                    break;
                }
                // Buffer_reference types also need Block decoration
                if (td.is_buffer_reference) needs_block = true;
                if (needs_block) {
                    try self.emitDecorationSectionDecorateNoExtra(id, @intFromEnum(spirv.Decoration.block));
                    self.default_row_major = block_row_major;
                    try self.emitNestedStructLayout(id, td.members, block_is_std430);
                    self.default_row_major = false;
                }
                // If we emitted a forward pointer, now emit the actual pointer definition
                if (self_ptr_id != 0) {
                    try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypePointer)));
                    try self.emitTypeWord(self_ptr_id);
                    try self.emitTypeWord(5349); // PhysicalStorageBuffer
                    try self.emitTypeWord(id); // The struct type
                }
            },
            .array => |arr| {
                // Check if element type is a buffer_reference named type — use PhysicalStorageBuffer pointer
                var resolved_base = arr.base.*;
                while (resolved_base == .array) resolved_base = resolved_base.array.base.*;
                const is_buf_ref_elem = if (resolved_base == .named) blk: {
                    const td = self.module.types.get(resolved_base.named);
                    break :blk td != null and td.?.is_buffer_reference;
                } else false;

                const base_id: u32 = if (is_buf_ref_elem and arr.base.* == .named) blk: {
                    // Element is a buffer_reference type — emit PhysicalStorageBuffer pointer
                    const struct_id = try self.ensureType(arr.base.*);
                    const ptr_key = (@as(u64, struct_id) << 32) | @as(u64, 5349);
                    if (self.emitted_ptr_types.get(ptr_key)) |cached| break :blk cached;
                    const ptr_id = self.allocId();
                    try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypePointer)));
                    try self.emitTypeWord(ptr_id);
                    try self.emitTypeWord(5349); // PhysicalStorageBuffer
                    try self.emitTypeWord(struct_id);
                    try self.emitted_ptr_types.put(self.alloc, ptr_key, ptr_id);
                    break :blk ptr_id;
                } else try self.ensureType(arr.base.*);

                const cache_key = (@as(u64, base_id) << 32) | @as(u64, arr.size);
                if (self.emitted_array_types.get(cache_key)) |cached_id| {
                    return cached_id;
                }
                if (arr.size == 0) {
                    // Runtime array: OpTypeRuntimeArray
                    try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeRuntimeArray)));
                    try self.emitTypeWord(id);
                    try self.emitTypeWord(base_id);
                } else {
                    const const_id = try self.emitIntConstant(arr.size);
                    try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeArray)));
                    try self.emitTypeWord(id);
                    try self.emitTypeWord(base_id);
                    try self.emitTypeWord(const_id);
                }
                try self.emitted_array_types.put(self.alloc, cache_key, id);
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
        // Use the actual type ID as key to correctly distinguish different array/nested types
        const key: u64 = (@as(u64, base_id) << 32) | @as(u64, @intFromEnum(storage_class));
        if (self.emitted_ptr_types.get(key)) |cached| return cached;
        const ptr_id = self.allocId();
        try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypePointer)));
        try self.emitTypeWord(ptr_id);
        try self.emitTypeWord(@intFromEnum(storage_class));
        try self.emitTypeWord(base_id);
        try self.emitted_ptr_types.put(self.alloc, key, ptr_id);
        return ptr_id;
    }

    fn emitIntConstant(self: *Codegen, val: u32) error{OutOfMemory}!u32 {
        const int_type_id = try self.ensureType(.uint);
        const key = (@as(u64, int_type_id) << 32) | @as(u64, val);
        if (self.emitted_constants.get(key)) |cached| return cached;
        const const_id = self.allocId();
        try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Constant)));
        try self.emitTypeWord(int_type_id);
        try self.emitTypeWord(const_id);
        try self.emitTypeWord(val);
        try self.emitted_constants.put(self.alloc, key, const_id);
        return const_id;
    }

    fn emitSignedIntConstant(self: *Codegen, val: u32) error{OutOfMemory}!u32 {
        const int_type_id = try self.ensureType(.int);
        const key = (@as(u64, int_type_id) << 32) | @as(u64, val);
        if (self.emitted_constants.get(key)) |cached| return cached;
        const const_id = self.allocId();
        try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Constant)));
        try self.emitTypeWord(int_type_id);
        try self.emitTypeWord(const_id);
        try self.emitTypeWord(val);
        try self.emitted_constants.put(self.alloc, key, const_id);
        return const_id;
    }

    fn emitAtomicOp(self: *Codegen, inst: ir.Instruction, op: spirv.Op) !void {
        const result_type_id = if (inst.result_type) |rt| rt else try self.ensureType(inst.ty);
        const result_id = inst.result_id orelse return;
        const ptr_id = self.operandId(inst, 0);
        const value_id = self.operandId(inst, 1);
        const scope_id = try self.emitIntConstant(1); // Device scope
        const semantics_id = try self.emitIntConstant(64); // Uniform semantics
        try self.emitWord(spirv.encodeInstructionHeader(7, @intFromEnum(op)));
        try self.emitWord(result_type_id);
        try self.emitWord(result_id);
        try self.emitWord(ptr_id);
        try self.emitWord(scope_id);
        try self.emitWord(semantics_id);
        try self.emitWord(value_id);
    }

    fn emitFloatConstant(self: *Codegen, val: f32) error{OutOfMemory}!u32 {
        const float_type_id = try self.ensureType(.float);
        const val_bits: u32 = @bitCast(val);
        const key = (@as(u64, float_type_id) << 32) | @as(u64, val_bits);
        if (self.emitted_constants.get(key)) |cached| return cached;
        const const_id = self.allocId();
        try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Constant)));
        try self.emitTypeWord(float_type_id);
        try self.emitTypeWord(const_id);
        try self.emitTypeWord(val_bits);
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

    fn emitMemberName(self: *Codegen, type_id: u32, member_index: u32, name: []const u8) !void {
        const word_count: u16 = 3 + @as(u16, @intCast(std.math.divCeil(usize, name.len + 1, 4) catch unreachable));
        try self.emitWord(spirv.encodeInstructionHeader(word_count, @intFromEnum(spirv.Op.MemberName)));
        try self.emitWord(type_id);
        try self.emitWord(member_index);
        try self.emitStringLiteral(name);
    }

    // Name section variants (for struct types emitted during ensureType)
    fn emitNameSectionName(self: *Codegen, id: u32, name: []const u8) !void {
        const word_count: u16 = 2 + @as(u16, @intCast(std.math.divCeil(usize, name.len + 1, 4) catch unreachable));
        try self.name_section.append(self.alloc, spirv.encodeInstructionHeader(word_count, @intFromEnum(spirv.Op.Name)));
        try self.name_section.append(self.alloc, id);
        // String literal to name_section
        var buf: [256]u8 = undefined;
        const encoded = self.encodeStringLiteral(name, &buf);
        try self.name_section.appendSlice(self.alloc, encoded);
    }

    fn emitNameSectionMemberName(self: *Codegen, type_id: u32, member_index: u32, name: []const u8) !void {
        const word_count: u16 = 3 + @as(u16, @intCast(std.math.divCeil(usize, name.len + 1, 4) catch unreachable));
        try self.name_section.append(self.alloc, spirv.encodeInstructionHeader(word_count, @intFromEnum(spirv.Op.MemberName)));
        try self.name_section.append(self.alloc, type_id);
        try self.name_section.append(self.alloc, member_index);
        var buf: [256]u8 = undefined;
        const encoded = self.encodeStringLiteral(name, &buf);
        try self.name_section.appendSlice(self.alloc, encoded);
    }

    fn encodeStringLiteral(self: *Codegen, str: []const u8, buf: []u8) []u32 {
        _ = self;
        const total_bytes = str.len + 1; // include null terminator
        const word_count = std.math.divCeil(usize, total_bytes, 4) catch unreachable;
        @memcpy(buf[0..str.len], str);
        buf[str.len] = 0; // null terminator
        // Pad remaining bytes to 0
        const padded_len = word_count * 4;
        for (str.len + 1..padded_len) |i| buf[i] = 0;
        // Convert to u32 words
        const words = @as([*]u32, @ptrCast(@alignCast(buf.ptr)))[0..word_count];
        return words;
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
                } else if (layout.binding != null and (global.storage_class == .uniform or global.storage_class == .storage_buffer)) {
                    // Default descriptor set is 0 for UBO/SSBO
                    try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.descriptor_set), 0);
                }
            }
            if (std.mem.eql(u8, global.name, "gl_FragCoord")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.frag_coord));
            }
            if (std.mem.eql(u8, global.name, "gl_FragColor")) {
                // gl_FragColor is deprecated, no standard BuiltIn — skip decoration
            } else if (std.mem.eql(u8, global.name, "gl_FrontFacing")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.front_facing));
            } else if (std.mem.eql(u8, global.name, "gl_HelperInvocation")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.helper_invocation));
            }
            if (std.mem.eql(u8, global.name, "gl_Position")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.position));
            }
            if (std.mem.eql(u8, global.name, "gl_VertexID") or std.mem.eql(u8, global.name, "gl_VertexIndex")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), 42); // VertexIndex
            }
            if (std.mem.eql(u8, global.name, "gl_InstanceID") or std.mem.eql(u8, global.name, "gl_InstanceIndex")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), 43); // InstanceIndex
            }
            // Only emit BuiltIn decorations for builtins that don't require extra capabilities
            // gl_Layer, gl_ViewportIndex require Geometry capability — skip
            if (false and std.mem.eql(u8, global.name, "gl_Layer")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.layer));
            }
            if (false and std.mem.eql(u8, global.name, "gl_ViewportIndex")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.view_index));
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
            if (std.mem.eql(u8, global.name, "gl_LocalInvocationIndex")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.local_invocation_index));
            }
            // Skip BuiltIn decoration for builtins requiring extra capabilities
            // gl_SampleMaskIn, gl_SamplePosition → SampleRateShading
            // gl_ViewIndex → MultiView
            // gl_DeviceIndex → DeviceGroup
            // gl_BaseVertex, gl_BaseVertexARB → DrawParameters
            // gl_VertexIndex → already covered by gl_VertexID
            // Decorate uniform/storage buffer struct types with Block/BufferBlock + Offset
            // (emitted inline in ensureType for named structs)
            // Emit Flat decoration for flat-qualified IO variables
            if (global.qualifier.is_flat and (global.storage_class == .input or global.storage_class == .output)) {
                try self.emitDecorateNoExtra(global.result_id, @intFromEnum(spirv.Decoration.flat));
            }
            // Emit Centroid decoration for centroid-qualified IO variables
            if (global.qualifier.is_centroid and (global.storage_class == .input or global.storage_class == .output)) {
                try self.emitDecorateNoExtra(global.result_id, @intFromEnum(spirv.Decoration.centroid));
            }
            // Emit NoPerspective decoration for noperspective-qualified IO variables
            if (global.qualifier.is_noperspective and (global.storage_class == .input or global.storage_class == .output)) {
                try self.emitDecorateNoExtra(global.result_id, @intFromEnum(spirv.Decoration.no_perspective));
            }
            // Emit NonWritable/NonReadable/Coherent/Restrict for buffer and image variables
            if (global.storage_class == .storage_buffer) {
                if (global.qualifier.is_readonly) {
                    try self.emitDecorateNoExtra(global.result_id, @intFromEnum(spirv.Decoration.non_writable));
                }
                if (global.qualifier.is_writeonly) {
                    try self.emitDecorateNoExtra(global.result_id, @intFromEnum(spirv.Decoration.non_readable));
                }
            }
            // Coherent and Restrict apply to storage buffers and uniform (image/sampler) variables
            if (global.storage_class == .storage_buffer or global.storage_class == .uniform) {
                if (global.qualifier.is_coherent) {
                    try self.emitDecorateNoExtra(global.result_id, @intFromEnum(spirv.Decoration.coherent));
                }
                if (global.qualifier.is_restrict) {
                    try self.emitDecorateNoExtra(global.result_id, @intFromEnum(spirv.Decoration.restrict));
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

    fn emitMemberDecorate(self: *Codegen, struct_type_id: u32, member_index: u32, decoration: u32, extra: u32) !void {
        try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.MemberDecorate)));
        try self.emitWord(struct_type_id);
        try self.emitWord(member_index);
        try self.emitWord(decoration);
        try self.emitWord(extra);
    }

    fn emitDecorateNoExtra(self: *Codegen, target_id: u32, decoration: u32) !void {
        try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.Decorate)));
        try self.emitWord(target_id);
        try self.emitWord(decoration);
    }

    // Decoration section variants (emitted before types)
    fn emitDecorationSectionDecorate(self: *Codegen, target_id: u32, decoration: u32, extra: u32) !void {
        try self.decoration_section.append(self.alloc, spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Decorate)));
        try self.decoration_section.append(self.alloc, target_id);
        try self.decoration_section.append(self.alloc, decoration);
        try self.decoration_section.append(self.alloc, extra);
    }

    fn emitDecorationSectionDecorateNoExtra(self: *Codegen, target_id: u32, decoration: u32) !void {
        try self.decoration_section.append(self.alloc, spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.Decorate)));
        try self.decoration_section.append(self.alloc, target_id);
        try self.decoration_section.append(self.alloc, decoration);
    }

    fn emitDecorationSectionMemberDecorate(self: *Codegen, struct_type_id: u32, member_index: u32, decoration: u32, extra: u32) !void {
        try self.decoration_section.append(self.alloc, spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.MemberDecorate)));
        try self.decoration_section.append(self.alloc, struct_type_id);
        try self.decoration_section.append(self.alloc, member_index);
        try self.decoration_section.append(self.alloc, decoration);
        try self.decoration_section.append(self.alloc, extra);
    }

    fn emitDecorationSectionMemberDecorateNoExtra(self: *Codegen, struct_type_id: u32, member_index: u32, decoration: u32) !void {
        try self.decoration_section.append(self.alloc, spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.MemberDecorate)));
        try self.decoration_section.append(self.alloc, struct_type_id);
        try self.decoration_section.append(self.alloc, member_index);
        try self.decoration_section.append(self.alloc, decoration);
    }

    /// Compute alignment for a type (std140 or std430)
    fn layoutAlignment(self: *Codegen, ty: ast.Type, is_std430: bool) u32 {
        if (is_std430) {
            return switch (ty) {
                .int8, .uint8 => 1,
                .int16, .uint16, .float16 => 2,
                .i8vec2, .u8vec2 => 2,
                .i16vec2, .u16vec2, .f16vec2 => 4,
                .i8vec3, .u8vec3, .i8vec4, .u8vec4 => 4,
                .i16vec3, .u16vec3, .f16vec3, .i16vec4, .u16vec4, .f16vec4 => 8,
                .float, .int, .uint, .bool => 4,
                .vec2, .ivec2, .uvec2 => 8,
                .vec3, .vec4, .ivec3, .ivec4, .uvec3, .uvec4 => 16,
                .mat2, .mat2x2, .mat3, .mat3x3, .mat4, .mat4x4,
                .mat2x3, .mat2x4, .mat3x2, .mat3x4, .mat4x2, .mat4x3 => 16,
                .array => |arr| self.layoutAlignment(arr.base.*, is_std430), // std430: array alignment = element alignment
                .named => |name| blk: {
                    // Struct alignment = max alignment of its members
                    const td = self.module.types.get(name) orelse break :blk 16;
                    if (td.is_buffer_reference) break :blk 8; // pointer alignment
                    const type_id = self.emitted_named_types.get(name) orelse break :blk 16;
                    if (self.layout_visited.contains(type_id)) break :blk 8; // self-ref cycle: pointer
                    self.layout_visited.put(self.alloc, type_id, {}) catch break :blk 16;
                    defer _ = self.layout_visited.remove(type_id);
                    var max_align: u32 = 4;
                    for (td.members) |member| {
                        const ma = self.layoutAlignment(member.ty, is_std430);
                        if (ma > max_align) max_align = ma;
                    }
                    break :blk max_align;
                },
                else => 4,
            };
        }
        return switch (ty) {
            .float, .int, .uint, .bool => 4,
            .vec2, .ivec2, .uvec2 => 8,
            .vec3, .vec4, .ivec3, .ivec4, .uvec3, .uvec4 => 16,
            .mat2, .mat2x2, .mat3, .mat3x3, .mat4, .mat4x4,
            .mat2x3, .mat2x4, .mat3x2, .mat3x4, .mat4x2, .mat4x3 => 16,
            .array => 16, // std140: array alignment is vec4 (16)
            .named => |name| blk: {
                // Struct alignment = max alignment of its members
                const td = self.module.types.get(name) orelse break :blk 16;
                if (td.is_buffer_reference) break :blk 8; // pointer alignment
                const type_id = self.emitted_named_types.get(name) orelse break :blk 16;
                if (self.layout_visited.contains(type_id)) break :blk 8; // self-ref cycle
                self.layout_visited.put(self.alloc, type_id, {}) catch break :blk 16;
                defer _ = self.layout_visited.remove(type_id);
                var max_align: u32 = 4;
                for (td.members) |member| {
                    const ma = self.layoutAlignment(member.ty, is_std430);
                    if (ma > max_align) max_align = ma;
                }
                break :blk max_align;
            },
            else => 4,
        };
    }

    /// Compute size for a type (std140 or std430)
    fn layoutSize(self: *Codegen, ty: ast.Type, is_std430: bool) u32 {
        return switch (ty) {
            .int8, .uint8 => 1,
            .int16, .uint16, .float16 => 2,
            .i8vec2, .u8vec2 => 2,
            .i16vec2, .u16vec2, .f16vec2 => 4,
            .i8vec3, .u8vec3 => 3,
            .i16vec3, .u16vec3, .f16vec3 => 6,
            .i8vec4, .u8vec4 => 4,
            .i16vec4, .u16vec4, .f16vec4 => 8,
            .float, .int, .uint, .bool => 4,
            .vec2, .ivec2, .uvec2 => 8,
            .vec3, .ivec3, .uvec3 => 12,
            .vec4, .ivec4, .uvec4 => 16,
            .mat2, .mat2x2 => 2 * 16,
            .mat3, .mat3x3 => 3 * 16,
            .mat4, .mat4x4 => 4 * 16,
            .mat2x3, .mat2x4 => if (self.default_row_major) self.matrixRowCount(ty) * 16 else 2 * 16,
            .mat3x2, .mat3x4 => if (self.default_row_major) self.matrixRowCount(ty) * 16 else 3 * 16,
            .mat4x2, .mat4x3 => if (self.default_row_major) self.matrixRowCount(ty) * 16 else 4 * 16,
            .array => |arr| blk: {
                const stride = self.layoutArrayStride(ty, is_std430);
                break :blk stride * arr.size;
            },
            .named => |name| blk: {
                // Buffer_reference types used as members are pointers (8 bytes)
                const td = self.module.types.get(name) orelse break :blk 0;
                if (td.is_buffer_reference) break :blk 8;
                // Get the type_id for cycle detection
                const type_id = self.emitted_named_types.get(name) orelse break :blk 0;
                if (self.layout_visited.contains(type_id)) break :blk 8; // Self-referential: treat as pointer (8 bytes)
                self.layout_visited.put(self.alloc, type_id, {}) catch break :blk 0;
                defer _ = self.layout_visited.remove(type_id);
                var sz: u32 = 0;
                for (td.members) |member| {
                    const alignment = self.layoutAlignment(member.ty, is_std430);
                    sz = std.mem.alignForward(u32, sz, alignment);
                    sz += self.layoutSize(member.ty, is_std430);
                }
                const struct_align = self.layoutAlignment(.{ .named = name }, is_std430);
                break :blk std.mem.alignForward(u32, sz, struct_align);
            },
            else => 4,
        };
    }

    /// Compute array stride (std140 or std430)
    fn layoutArrayStride(self: *Codegen, ty: ast.Type, is_std430: bool) u32 {
        const arr = ty.array;
        // For buffer_reference element types, use pointer size (8 bytes)
        var resolved_base = arr.base.*;
        while (resolved_base == .array) resolved_base = resolved_base.array.base.*;
        if (resolved_base == .named) {
            const td = self.module.types.get(resolved_base.named);
            if (td != null and td.?.is_buffer_reference) {
                // PhysicalStorageBuffer pointer is 8 bytes, 8-byte aligned
                const stride = std.mem.alignForward(u32, 8, 8);
                if (is_std430) return stride;
                return std.mem.alignForward(u32, stride, 16); // std140
            }
        }
        const elem_size = self.layoutSize(arr.base.*, is_std430);
        const elem_align = self.layoutAlignment(arr.base.*, is_std430);
        const rounded_elem = std.mem.alignForward(u32, elem_size, elem_align);
        if (is_std430) {
            return rounded_elem; // std430: no extra rounding to 16
        }
        return std.mem.alignForward(u32, rounded_elem, 16); // std140: round up to vec4
    }

    /// Emit Offset/ColMajor/MatrixStride/ArrayStride for struct members, recursing into nested structs
    fn emitNestedStructLayout(self: *Codegen, struct_type_id: u32, members: []const ast.StructMember, is_std430: bool) !void {
        try self.emitNestedStructLayoutInner(struct_type_id, members, is_std430, self.default_row_major);
    }

    fn emitNestedStructLayoutInner(self: *Codegen, struct_type_id: u32, members: []const ast.StructMember, is_std430: bool, parent_row_major: bool) !void {
        // Prevent decorating the same struct twice
        if (self.emitted_struct_layout.contains(struct_type_id)) return;
        try self.emitted_struct_layout.put(self.alloc, struct_type_id, {});
        var offset: u32 = 0;
        for (members, 0..) |member, i| {
            const member_is_row_major = if (member.layout) |l| l.row_major else parent_row_major;
            // Temporarily set default_row_major for layoutSize/layoutArrayStride
            const saved_row_major = self.default_row_major;
            self.default_row_major = member_is_row_major;
            defer self.default_row_major = saved_row_major;
            const alignment = self.layoutAlignment(member.ty, is_std430);
            offset = std.mem.alignForward(u32, offset, alignment);
            try self.emitDecorationSectionMemberDecorate(struct_type_id, @intCast(i), @intFromEnum(spirv.Decoration.offset), offset);
            const size = self.layoutSize(member.ty, is_std430);
            offset += size;
            // RowMajor/ColMajor + MatrixStride for matrix members (direct or element of array)
            var effective_ty = member.ty;
            while (effective_ty == .array) effective_ty = effective_ty.array.base.*;
            if (self.isMatrixType(effective_ty)) {
                if (member_is_row_major) {
                    try self.emitDecorationSectionMemberDecorateNoExtra(struct_type_id, @intCast(i), @intFromEnum(spirv.Decoration.row_major));
                } else {
                    try self.emitDecorationSectionMemberDecorateNoExtra(struct_type_id, @intCast(i), @intFromEnum(spirv.Decoration.col_major));
                }
                // MatrixStride: the stride between columns (col_major) or rows (row_major)
                const mat_stride: u32 = if (member_is_row_major) blk: {
                    // RowMajor: stride = alignment of vec<column_count>
                    const cols = self.matrixColumnCount(effective_ty);
                    break :blk if (is_std430) switch (cols) {
                        2 => 8,
                        3 => 16,
                        4 => 16,
                        else => 16,
                    } else 16; // std140 always vec4-aligned
                } else blk: {
                    // ColMajor: stride = alignment of vec<row_count>
                    const rows = self.matrixRowCount(effective_ty);
                    break :blk if (is_std430) switch (rows) {
                        2 => 8,
                        3 => 16,
                        4 => 16,
                        else => 16,
                    } else 16; // std140 always vec4-aligned
                };
                try self.emitDecorationSectionMemberDecorate(struct_type_id, @intCast(i), @intFromEnum(spirv.Decoration.matrix_stride), mat_stride);
            }
            // ArrayStride for array members (all nesting levels)
            if (member.ty == .array) {
                try self.emitArrayStrideRecursive(member.ty, is_std430);
                // Recurse into nested struct arrays: emit Offset for the element struct members
                if (effective_ty == .named) {
                    const elem_td = self.module.types.get(effective_ty.named) orelse continue;
                    const elem_type_id = self.emitted_named_types.get(effective_ty.named) orelse continue;
                    try self.emitNestedStructLayoutInner(elem_type_id, elem_td.members, is_std430, member_is_row_major);
                }
            }
            // Recurse into direct nested struct members
            if (member.ty == .named) {
                const nested_td = self.module.types.get(member.ty.named) orelse continue;
                const nested_type_id = self.emitted_named_types.get(member.ty.named) orelse continue;
                try self.emitNestedStructLayoutInner(nested_type_id, nested_td.members, is_std430, member_is_row_major);
            }
        }
    }

    fn isMatrixType(self: *Codegen, ty: ast.Type) bool {
        _ = self;
        return switch (ty) {
            .mat2, .mat2x2, .mat2x3, .mat2x4,
            .mat3, .mat3x2, .mat3x3, .mat3x4,
            .mat4, .mat4x2, .mat4x3, .mat4x4 => true,
            else => false,
        };
    }

    /// Emit ArrayStride for array types at all nesting levels
    fn emitArrayStrideRecursive(self: *Codegen, ty: ast.Type, is_std430: bool) !void {
        if (ty != .array) return;
        const arr = ty.array;
        // Must use same base_id logic as ensureType for arrays (buffer_reference → pointer)
        var resolved_base = arr.base.*;
        while (resolved_base == .array) resolved_base = resolved_base.array.base.*;
        const is_buf_ref_elem = if (resolved_base == .named) blk: {
            const td = self.module.types.get(resolved_base.named);
            break :blk td != null and td.?.is_buffer_reference;
        } else false;
        const base_type_id: u32 = if (is_buf_ref_elem and arr.base.* == .named) blk: {
            const struct_id = try self.ensureType(arr.base.*);
            const ptr_key = (@as(u64, struct_id) << 32) | @as(u64, 5349);
            break :blk self.emitted_ptr_types.get(ptr_key) orelse struct_id;
        } else try self.ensureType(arr.base.*);

        const cache_key = (@as(u64, base_type_id) << 32) | @as(u64, arr.size);
        if (self.emitted_array_types.get(cache_key)) |array_type_id| {
            if (!self.emitted_array_stride.contains(array_type_id)) {
                const stride = self.layoutArrayStride(ty, is_std430);
                try self.emitDecorationSectionDecorate(array_type_id, @intFromEnum(spirv.Decoration.array_stride), stride);
                try self.emitted_array_stride.put(self.alloc, array_type_id, {});
            }
        }
        // Recurse into nested arrays
        if (arr.base.* == .array) {
            try self.emitArrayStrideRecursive(arr.base.*, is_std430);
        }
    }

    fn matrixRowCount(self: *Codegen, ty: ast.Type) u32 {
        _ = self;
        return switch (ty) {
            .mat2, .mat2x2 => 2,
            .mat2x3 => 3,
            .mat2x4 => 4,
            .mat3, .mat3x2 => 2,
            .mat3x3 => 3,
            .mat3x4 => 4,
            .mat4, .mat4x2 => 2,
            .mat4x3 => 3,
            .mat4x4 => 4,
            else => 0,
        };
    }

    fn matrixColumnCount(self: *Codegen, ty: ast.Type) u32 {
        _ = self;
        return switch (ty) {
            .mat2, .mat2x2 => 2,
            .mat2x3 => 2,
            .mat2x4 => 2,
            .mat3, .mat3x2 => 3,
            .mat3x3 => 3,
            .mat3x4 => 3,
            .mat4, .mat4x2 => 4,
            .mat4x3 => 4,
            .mat4x4 => 4,
            else => 0,
        };
    }

    // Stub methods — implemented in subsequent tasks
    fn emitTypesAndConstants(self: *Codegen) !void {
        // Emit named struct types and global types/pointer types.
        // All other types and constants are emitted on-demand via the two-buffer system.
        // Collect referenced type names first
        var referenced_names = std.StringHashMapUnmanaged(void).empty;
        defer referenced_names.deinit(self.alloc);
        for (self.module.globals) |global| {
            if (global.ty == .named) {
                try referenced_names.put(self.alloc, global.ty.named, {});
                // Also reference members' types
                if (self.module.types.get(global.ty.named)) |td| {
                    for (td.members) |member| {
                        if (member.ty == .named) try referenced_names.put(self.alloc, member.ty.named, {});
                        if (member.ty == .array) {
                            if (member.ty.array.base.* == .named) try referenced_names.put(self.alloc, member.ty.array.base.*.named, {});
                        }
                    }
                }
            }
        }
        for (self.module.functions) |func| {
            if (func.return_type == .named) try referenced_names.put(self.alloc, func.return_type.named, {});
            for (func.params) |param| {
                if (param.ty == .named) try referenced_names.put(self.alloc, param.ty.named, {});
            }
            for (func.body) |inst| {
                if (inst.ty == .named) try referenced_names.put(self.alloc, inst.ty.named, {});
            }
        }
        var type_iter = self.module.types.iterator();
        while (type_iter.next()) |entry| {
            if (referenced_names.contains(entry.key_ptr.*)) {
                _ = try self.ensureType(.{ .named = entry.key_ptr.* });
            }
        }
        for (self.module.globals) |global| {
            _ = try self.ensureType(global.ty);
            _ = try self.ensurePointerType(global.ty, global.storage_class);
            // Track storage class for this global's result_id
            try self.ptr_storage_class.put(self.alloc, global.result_id, global.storage_class);
            // Struct member types are emitted on-demand during function codegen via two-buffer
            // (no pre-scan needed)
        }
        for (self.module.functions) |func| {
            // Types emitted on-demand via two-buffer during emitFunctions
            _ = func;
        }
        // Emit member-level NonWritable/NonReadable for readonly/writeonly buffer blocks
        for (self.module.globals) |global| {
            if (global.storage_class != .storage_buffer) continue;
            if (global.ty != .named) continue;
            const block_type_id = self.emitted_named_types.get(global.ty.named) orelse continue;
            const td = self.module.types.get(global.ty.named) orelse continue;
            if (td.members.len == 0) continue;
            if (global.qualifier.is_readonly) {
                try self.emitDecorationSectionMemberDecorateNoExtra(block_type_id, 0, @intFromEnum(spirv.Decoration.non_writable));
            }
            if (global.qualifier.is_writeonly) {
                try self.emitDecorationSectionMemberDecorateNoExtra(block_type_id, 0, @intFromEnum(spirv.Decoration.non_readable));
            }
        }
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
        self.in_functions = true;
        const functions_start_pos = self.words.items.len;
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

        // Splice type_section words before the function code
        if (self.type_section.items.len > 0) {
            // Save function words (from functions_start_pos to end)
            const func_words = try self.allocator().dupe(u32, self.words.items[functions_start_pos..]);
            // Truncate to where functions start
            self.words.shrinkRetainingCapacity(functions_start_pos);
            // Append type section words
            try self.words.appendSlice(self.allocator(), self.type_section.items);
            // Append function words back
            try self.words.appendSlice(self.allocator(), func_words);
            self.allocator().free(func_words);
        }
        self.in_functions = false;
    }

    fn allocator(self: *Codegen) std.mem.Allocator {
        return self.alloc;
    }

    fn emitInstruction(self: *Codegen, inst: ir.Instruction) !void {
        // Resolve null result_type from ast type
        var resolved = inst;
        if (resolved.result_type == null and resolved.result_id != null and resolved.tag != .extract_image and resolved.tag != .image_sample_dref and resolved.tag != .image_sample_dref_explicit_lod and resolved.tag != .image_sample_dref_proj and resolved.tag != .image_dref_gather) {
            resolved.result_type = try self.ensureType(inst.ty);
        }
        // For Dref instructions, result type is always float
        if (resolved.result_type == null and resolved.result_id != null and (resolved.tag == .image_sample_dref or resolved.tag == .image_sample_dref_explicit_lod or resolved.tag == .image_sample_dref_proj)) {
            resolved.result_type = try self.ensureType(.float);
        }
        // For DrefGather, result type is always vec4
        if (resolved.result_type == null and resolved.result_id != null and resolved.tag == .image_dref_gather) {
            resolved.result_type = try self.ensureType(.vec4);
        }
        switch (resolved.tag) {
            .constant_int, .constant_float, .constant_bool => {
                // Emit constants via type section when in functions
                switch (resolved.tag) {
                    .constant_int => {
                        const val: u32 = switch (resolved.operands[0]) {
                            .literal_int => |v| v,
                            else => return,
                        };
                        const int_type_id = try self.ensureType(resolved.ty);
                        const cache_key = (@as(u64, int_type_id) << 32) | @as(u64, val);
                        // Check if pre-scan already emitted this constant
                        if (self.emitted_constants.get(cache_key)) |existing_id| {
                            // Map IR result_id to existing constant for operand resolution
                            const ir_id = resolved.result_id orelse return;
                            if (ir_id != existing_id) {
                                try self.constant_alias.put(self.alloc, ir_id, existing_id);
                            }
                            return;
                        }
                        const ir_id = resolved.result_id orelse return;
                        try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Constant)));
                        try self.emitTypeWord(int_type_id);
                        try self.emitTypeWord(ir_id);
                        try self.emitTypeWord(val);
                        try self.emitted_constants.put(self.alloc, cache_key, ir_id);
                    },
                    .constant_float => {
                        const val: f32 = switch (resolved.operands[0]) {
                            .literal_float => |v| v,
                            .literal_int => |v| @floatFromInt(v),
                            else => return,
                        };
                        const float_type_id = try self.ensureType(.float);
                        const cache_key = (@as(u64, float_type_id) << 32) | @as(u64, @as(u32, @bitCast(val)));
                        if (self.emitted_constants.get(cache_key)) |existing_id| {
                            const ir_id = resolved.result_id orelse return;
                            if (ir_id != existing_id) {
                                try self.constant_alias.put(self.alloc, ir_id, existing_id);
                            }
                            return;
                        }
                        const ir_id = resolved.result_id orelse return;
                        try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Constant)));
                        try self.emitTypeWord(float_type_id);
                        try self.emitTypeWord(ir_id);
                        try self.emitTypeWord(@as(u32, @bitCast(val)));
                        try self.emitted_constants.put(self.alloc, cache_key, ir_id);
                    },
                    .constant_bool => {
                        const val: u32 = switch (resolved.operands[0]) {
                            .literal_int => |v| v,
                            else => return,
                        };
                        const bool_type_id = try self.ensureType(.bool);
                        const op: spirv.Op = if (val != 0) .ConstantTrue else .ConstantFalse;
                        try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(op)));
                        try self.emitTypeWord(bool_type_id);
                        try self.emitTypeWord(resolved.result_id orelse return);
                    },
                    else => {},
                }
                return;
            },
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
                // PhysicalStorageBuffer loads require Aligned memory operand
                if (self.ptr_storage_class.get(ptr_id)) |sc| {
                    if (sc == .physical_storage_buffer) {
                        try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.Load)));
                        try self.emitWord(result_type_id);
                        try self.emitWord(result_id);
                        try self.emitWord(ptr_id);
                        try self.emitWord(2); // Aligned memory operand bit
                        try self.emitWord(16); // alignment
                        return;
                    }
                }
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Load)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(ptr_id);
            },
            .store => {
                const ptr_id = self.operandId(resolved, 0);
                const val_id = self.operandId(resolved, 1);
                // PhysicalStorageBuffer stores require Aligned memory operand
                if (self.ptr_storage_class.get(ptr_id)) |sc| {
                    if (sc == .physical_storage_buffer) {
                        try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.Store)));
                        try self.emitWord(ptr_id);
                        try self.emitWord(val_id);
                        try self.emitWord(2); // Aligned memory operand bit
                        try self.emitWord(16); // alignment
                        return;
                    }
                }
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.Store)));
                try self.emitWord(ptr_id);
                try self.emitWord(val_id);
            },
            .add => try self.emitBinOp(spirv.Op.IAdd, resolved),
            .sub => try self.emitBinOp(spirv.Op.ISub, resolved),
            .mul => try self.emitBinOp(spirv.Op.IMul, resolved),
            .div => try self.emitBinOp(spirv.Op.SDiv, resolved),
            .rem => try self.emitBinOp(spirv.Op.SRem, resolved),
            .umod => try self.emitBinOp(spirv.Op.UMod, resolved),
            .fadd => try self.emitBinOp(spirv.Op.FAdd, resolved),
            .fsub => try self.emitBinOp(spirv.Op.FSub, resolved),
            .fmod => try self.emitBinOp(spirv.Op.FMod, resolved),
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
            .convert_uti => try self.emitUnaryOp(spirv.Op.Bitcast, resolved),
            .convert_iti => try self.emitUnaryOp(spirv.Op.Bitcast, resolved),
            .convert_itof => try self.emitUnaryOp(spirv.Op.ConvertSToF, resolved),
            .bitcast => try self.emitUnaryOp(spirv.Op.Bitcast, resolved),
            .convert_utof => try self.emitUnaryOp(spirv.Op.ConvertUToF, resolved),
            .bool_to_float, .bool_to_int, .bool_to_uint => {
                // bool → numeric: use OpSelect(T, bool, T(1), T(0))
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const cond_id = self.operandId(resolved, 0);
                const one_id: u32 = switch (resolved.tag) {
                    .bool_to_float => try self.emitFloatConstant(1.0),
                    .bool_to_int, .bool_to_uint => try self.emitIntConstant(1),
                    else => return,
                };
                const zero_id: u32 = switch (resolved.tag) {
                    .bool_to_float => try self.emitFloatConstant(0.0),
                    .bool_to_int, .bool_to_uint => try self.emitIntConstant(0),
                    else => return,
                };
                try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.Select)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(cond_id);
                try self.emitWord(one_id);
                try self.emitWord(zero_id);
            },
            .is_nan => try self.emitUnaryOp(spirv.Op.IsNan, resolved),
            .is_inf => try self.emitUnaryOp(spirv.Op.IsInf, resolved),
            .any => try self.emitUnaryOp(spirv.Op.Any, resolved),
            .all => try self.emitUnaryOp(spirv.Op.All, resolved),
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
                const sc: ir.SPIRVStorageClass = sc: {
                    // First check our tracked pointer storage classes
                    if (self.ptr_storage_class.get(base_id_val)) |tracked_sc| break :sc tracked_sc;
                    // Fallback: check globals
                    for (self.module.globals) |global| {
                        if (global.result_id == base_id_val) break :sc global.storage_class;
                    }
                    break :sc .function;
                };
                const result_id = resolved.result_id orelse return;
                // Track the result pointer's storage class for chained access chains
                try self.ptr_storage_class.put(self.alloc, result_id, sc);
                // OpAccessChain indices: can be OpConstant or runtime scalar integer
                const index_id: u32 = switch (resolved.operands[1]) {
                    .id => |v| self.constant_alias.get(v) orelse v, // Runtime index — use the ID directly (may be aliased)
                    .literal_int => |v| try self.emitSignedIntConstant(v), // Literal — emit signed constant (matches glslang)
                    else => try self.emitSignedIntConstant(0),
                };

                // Check if the result type is a buffer_reference named type
                // If so, the member IS a PhysicalStorageBuffer pointer, so the access chain
                // should produce a StorageBuffer pointer to that pointer, then load it.
                var is_buf_ref_member = false;
                if (inst.ty == .named) {
                    const td = self.module.types.get(inst.ty.named);
                    if (td != null and td.?.is_buffer_reference) {
                        is_buf_ref_member = true;
                    }
                }

                if (is_buf_ref_member) {
                    // Access chain: get a pointer to the PhysicalStorageBuffer pointer member
                    const struct_id = try self.ensureType(inst.ty);
                    const phys_ptr_key = (@as(u64, struct_id) << 32) | @as(u64, 5349);
                    const phys_ptr_id = self.emitted_ptr_types.get(phys_ptr_key) orelse struct_id;
                    // Create pointer-to-pointer type: StorageBuffer -> PhysicalStorageBuffer pointer
                    const ptr_to_ptr_key = (@as(u64, phys_ptr_id) << 32) | @as(u64, @intFromEnum(sc));
                    const ptr_type_id = if (self.emitted_ptr_types.get(ptr_to_ptr_key)) |cached| cached else blk: {
                        const pid = self.allocId();
                        try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypePointer)));
                        try self.emitTypeWord(pid);
                        try self.emitTypeWord(@intFromEnum(sc));
                        try self.emitTypeWord(phys_ptr_id);
                        try self.emitted_ptr_types.put(self.alloc, ptr_to_ptr_key, pid);
                        break :blk pid;
                    };
                    try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.AccessChain)));
                    try self.emitWord(ptr_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(base_id_val);
                    try self.emitWord(index_id);
                    // Now load the PhysicalStorageBuffer pointer
                    const loaded_id = self.allocId();
                    try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Load)));
                    try self.emitWord(phys_ptr_id);
                    try self.emitWord(loaded_id);
                    try self.emitWord(result_id);
                    // Alias the result_id to the loaded pointer for subsequent access chains
                    try self.constant_alias.put(self.alloc, result_id, loaded_id);
                    // Track the loaded pointer as PhysicalStorageBuffer
                    try self.ptr_storage_class.put(self.alloc, loaded_id, .physical_storage_buffer);
                } else {
                    const ptr_type_id = try self.ensurePointerType(inst.ty, sc);
                    try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.AccessChain)));
                    try self.emitWord(ptr_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(base_id_val);
                    try self.emitWord(index_id);
                }
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
                const index_const_id = try self.emitSignedIntConstant(member_idx);
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
            .image_sample_proj => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const sampled_image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                // OpImageSampleProjImplicitLod: result_type, result, sampled_image, coordinate
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.ImageSampleProjImplicitLod)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(sampled_image_id);
                try self.emitWord(coord_id);
            },
            .image_sample_dref => {
                // OpImageSampleDrefImplicitLod: result_type(float), result, sampled_image, coordinate_without_dref, Dref
                // GLSL coord has Dref as last component; SPIR-V needs it separate
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const sampled_image_id = self.operandId(resolved, 0);
                const float_id = try self.ensureType(.float);

                // For samplerCubeArrayShadow, Dref is a separate arg (operand[2])
                if (resolved.operands.len >= 3 and inst.ty == .sampler_cube_array_shadow) {
                    const coord_id = self.operandId(resolved, 1);
                    const dref_id = self.operandId(resolved, 2);
                    try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.ImageSampleDrefImplicitLod)));
                    try self.emitWord(result_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(sampled_image_id);
                    try self.emitWord(coord_id);
                    try self.emitWord(dref_id);
                } else {
                const coord_id = self.operandId(resolved, 1);
                // Extract Dref from last component of coord
                const dref_id = self.allocId();
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.CompositeExtract)));
                try self.emitWord(float_id);
                try self.emitWord(dref_id);
                try self.emitWord(coord_id);
                // Determine last component index based on sampler type
                const last_idx: u32 = switch (inst.ty) {
                    .sampler2d_shadow => 2, // vec3(u,v,dref) → extract [2]
                    .sampler2d_array_shadow => 3, // vec4(u,v,layer,dref) → extract [3]
                    .sampler_cube_shadow => 3, // vec4(u,v,z,dref) → extract [3]
                    .sampler1d_shadow => 1, // vec2(u,dref) → extract [1]
                    else => 3,
                };
                try self.emitWord(last_idx);
                // Shrink coordinate: use VectorShuffle to drop last component
                const shrink_ty: ast.Type = switch (inst.ty) {
                    .sampler2d_shadow => .vec2, // vec3 → vec2
                    .sampler2d_array_shadow => .vec3, // vec4 → vec3
                    .sampler_cube_shadow => .vec3, // vec4 → vec3
                    .sampler1d_shadow => .float, // vec2 → float
                    else => .vec3,
                };
                const shrink_type_id = try self.ensureType(shrink_ty);
                const shrunk_coord_id = self.allocId();
                if (shrink_ty == .float) {
                    // 1D shadow: extract scalar coordinate from vec2
                    const float_type_id = try self.ensureType(.float);
                    try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.CompositeExtract)));
                    try self.emitWord(float_type_id);
                    try self.emitWord(shrunk_coord_id);
                    try self.emitWord(coord_id);
                    try self.emitWord(0); // extract first component
                } else {
                    const num_comp: u32 = switch (shrink_ty) {
                        .vec2 => 2,
                        .vec3 => 3,
                        else => 3,
                    };
                    try self.emitWord(spirv.encodeInstructionHeader(@as(u16, @intCast(5 + num_comp)), @intFromEnum(spirv.Op.VectorShuffle)));
                    try self.emitWord(shrink_type_id);
                    try self.emitWord(shrunk_coord_id);
                    try self.emitWord(coord_id);
                    try self.emitWord(coord_id);
                    for (0..num_comp) |i| try self.emitWord(@intCast(i));
                }
                // Emit the Dref instruction
                try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.ImageSampleDrefImplicitLod)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(sampled_image_id);
                try self.emitWord(shrunk_coord_id);
                try self.emitWord(dref_id);
                }
            },
            .image_sample_dref_explicit_lod => {
                // OpImageSampleDrefExplicitLod: result_type(float), result, sampled_image, coord_without_dref, Dref, ImageOperands(Lod)
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const sampled_image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                const float_id = try self.ensureType(.float);
                // Extract Dref from last component of coord
                const dref_id = self.allocId();
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.CompositeExtract)));
                try self.emitWord(float_id);
                try self.emitWord(dref_id);
                try self.emitWord(coord_id);
                const last_idx: u32 = switch (inst.ty) {
                    .sampler2d_shadow => 2,
                    .sampler2d_array_shadow => 3,
                    .sampler_cube_shadow => 3,
                    .sampler1d_shadow => 1,
                    else => 3,
                };
                try self.emitWord(last_idx);
                // Shrink coordinate
                const shrink_ty: ast.Type = switch (inst.ty) {
                    .sampler2d_shadow => .vec2,
                    .sampler2d_array_shadow => .vec3,
                    .sampler_cube_shadow => .vec3,
                    .sampler1d_shadow => .float,
                    else => .vec3,
                };
                const shrink_type_id = try self.ensureType(shrink_ty);
                const shrunk_coord_id = self.allocId();
                if (shrink_ty == .float) {
                    const float_type_id = try self.ensureType(.float);
                    try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.CompositeExtract)));
                    try self.emitWord(float_type_id);
                    try self.emitWord(shrunk_coord_id);
                    try self.emitWord(coord_id);
                    try self.emitWord(0);
                } else {
                    const num_comp: u32 = switch (shrink_ty) {
                        .vec2 => 2,
                        .vec3 => 3,
                        else => 3,
                    };
                    try self.emitWord(spirv.encodeInstructionHeader(@as(u16, @intCast(5 + num_comp)), @intFromEnum(spirv.Op.VectorShuffle)));
                    try self.emitWord(shrink_type_id);
                    try self.emitWord(shrunk_coord_id);
                    try self.emitWord(coord_id);
                    try self.emitWord(coord_id);
                    for (0..num_comp) |i| try self.emitWord(@intCast(i));
                }
                const lod_id = if (resolved.operands.len >= 3) self.operandId(resolved, 2) else return;
                // Image Operand Lod mask = bit 1 (0x2)
                try self.emitWord(spirv.encodeInstructionHeader(8, @intFromEnum(spirv.Op.ImageSampleDrefExplicitLod)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(sampled_image_id);
                try self.emitWord(shrunk_coord_id);
                try self.emitWord(dref_id);
                try self.emitWord(2); // Image Operand Lod mask (bit 1)
                try self.emitWord(lod_id);
            },
            .image_sample_dref_proj => {
                // OpImageSampleProjDrefImplicitLod: result_type(float), result, sampled_image, coordinate_with_proj, Dref
                // For Proj, the coordinate includes the projection divisor as the last component
                // The Dref is the component before that.
                // For sampler2DShadow: coord is vec4(u,v,dref,proj) — Dref at index 2
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const sampled_image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                const float_id = try self.ensureType(.float);
                // For proj shadow, extract Dref: for sampler2DShadow with vec4, dref is at index 2
                const dref_idx: u32 = switch (inst.ty) {
                    .sampler2d_shadow => 2, // vec4(u,v,dref,proj)
                    .sampler1d_shadow => 1, // vec4(s,dref,proj,pad)
                    else => 3,
                };
                const dref_id = self.allocId();
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.CompositeExtract)));
                try self.emitWord(float_id);
                try self.emitWord(dref_id);
                try self.emitWord(coord_id);
                try self.emitWord(dref_idx);
                try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.ImageSampleProjDrefImplicitLod)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(sampled_image_id);
                try self.emitWord(coord_id);
                try self.emitWord(dref_id);
            },
            .image_gather => {
                // OpImageGather: result_type(vec4), result, sampled_image, coordinate, component
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const sampled_image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                // Component index (arg 2) or default 0
                const component_id = if (resolved.operands.len > 2) self.operandId(resolved, 2) else try self.emitIntConstant(0);
                try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.ImageGather)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(sampled_image_id);
                try self.emitWord(coord_id);
                try self.emitWord(component_id);
            },
            .image_dref_gather => {
                // OpImageDrefGather: result_type(vec4), result, sampled_image, coordinate, dref
                // GLSL: textureGather(sampler, coord.xy, dref) — dref is separate arg
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const sampled_image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                const dref_id = if (resolved.operands.len > 2) self.operandId(resolved, 2) else dref: {
                    // Fallback: extract last component from coord
                    const float_id = try self.ensureType(.float);
                    const ext_id = self.allocId();
                    try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.CompositeExtract)));
                    try self.emitWord(float_id);
                    try self.emitWord(ext_id);
                    try self.emitWord(coord_id);
                    try self.emitWord(2);
                    break :dref ext_id;
                };
                try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.ImageDrefGather)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(sampled_image_id);
                try self.emitWord(coord_id);
                try self.emitWord(dref_id);
            },
            .image_fetch, .image_fetch_ms => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                // For MS images, add Image Operand Sample with 3rd arg
                if (resolved.tag == .image_fetch_ms and resolved.operands.len >= 3) {
                    const sample_id = self.operandId(resolved, 2);
                    try self.emitWord(spirv.encodeInstructionHeader(7, @intFromEnum(spirv.Op.ImageFetch)));
                    try self.emitWord(result_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(image_id);
                    try self.emitWord(coord_id);
                    try self.emitWord(64); // Image Operand Sample mask (bit 6)
                    try self.emitWord(sample_id);
                } else {
                    try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.ImageFetch)));
                    try self.emitWord(result_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(image_id);
                    try self.emitWord(coord_id);
                }
            },
            .extract_image => {
                // Result type must be the image type inside the sampled image (Sampled=1)
                // Choose the correct inner ID based on the source sampler type
                const result_type_id: u32 = if (inst.ty == .sampler_buffer) blk: {
                    break :blk self.sampler_buffer_inner_id;
                } else if (inst.ty == .sampler3d) blk: {
                    break :blk if (self.sampled_image_3d_inner_id != 0) self.sampled_image_3d_inner_id else self.sampled_image_inner_id;
                } else if (inst.ty == .sampler2d_array) blk: {
                    break :blk if (self.sampled_image_2d_array_inner_id != 0) self.sampled_image_2d_array_inner_id else self.sampled_image_inner_id;
                } else if (inst.ty == .image2d_ms or inst.ty == .sampler2d_ms) blk: {
                    break :blk self.sampled_image_ms_inner_id;
                } else if (inst.ty == .image2d_ms_array or inst.ty == .sampler2d_ms_array) blk: {
                    break :blk self.sampled_image_ms_array_inner_id;
                } else if (inst.ty == .sampler1d or inst.ty == .sampler1d_shadow) blk: {
                    break :blk self.sampled_image_1d_inner_id;
                } else if (inst.ty == .sampler_cube or inst.ty == .sampler_cube_shadow or inst.ty == .sampler_cube_array_shadow) blk: {
                    break :blk self.sampled_image_cube_inner_id;
                } else if (inst.ty == .isampler2d or inst.ty == .isampler3d or inst.ty == .isampler_cube or inst.ty == .isampler2d_array) blk: {
                    break :blk if (self.sampled_image_int_inner_id != 0) self.sampled_image_int_inner_id else self.sampled_image_inner_id;
                } else if (inst.ty == .usampler2d or inst.ty == .usampler3d or inst.ty == .usampler_cube or inst.ty == .usampler2d_array) blk: {
                    break :blk if (self.sampled_image_uint_inner_id != 0) self.sampled_image_uint_inner_id else self.sampled_image_inner_id;
                } else if (inst.ty == .isampler2d_ms) blk: {
                    break :blk if (self.sampled_image_int_ms_inner_id != 0) self.sampled_image_int_ms_inner_id else self.sampled_image_ms_inner_id;
                } else if (inst.ty == .usampler2d_ms) blk: {
                    break :blk if (self.sampled_image_uint_ms_inner_id != 0) self.sampled_image_uint_ms_inner_id else self.sampled_image_ms_inner_id;
                } else if (inst.ty == .isampler2d_ms_array) blk: {
                    break :blk if (self.sampled_image_int_ms_array_inner_id != 0) self.sampled_image_int_ms_array_inner_id else self.sampled_image_ms_array_inner_id;
                } else if (inst.ty == .usampler2d_ms_array) blk: {
                    break :blk if (self.sampled_image_uint_ms_array_inner_id != 0) self.sampled_image_uint_ms_array_inner_id else self.sampled_image_ms_array_inner_id;
                } else if (inst.ty == .isampler1d) blk: {
                    break :blk if (self.sampled_image_int_1d_inner_id != 0) self.sampled_image_int_1d_inner_id else self.sampled_image_1d_inner_id;
                } else if (inst.ty == .usampler1d) blk: {
                    break :blk if (self.sampled_image_uint_1d_inner_id != 0) self.sampled_image_uint_1d_inner_id else self.sampled_image_1d_inner_id;
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
            .image_query_size_lod => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const image_id = self.operandId(resolved, 0);
                const lod_id = self.operandId(resolved, 1);
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.ImageQuerySizeLod)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(image_id);
                try self.emitWord(lod_id);
            },
            .image_query_levels => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const image_id = self.operandId(resolved, 0);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.ImageQueryLevels)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(image_id);
            },
            .image_query_samples => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const image_id = self.operandId(resolved, 0);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.ImageQuerySamples)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(image_id);
            },
            .image_read => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                if (resolved.operands.len >= 3) {
                    // MS image: imageLoad(image, coord, sample_index)
                    // OpImageRead result_type result image coordinate [ImageOperands Sample]
                    const sample_id = self.operandId(resolved, 2);
                    try self.emitWord(spirv.encodeInstructionHeader(7, @intFromEnum(spirv.Op.ImageRead)));
                    try self.emitWord(result_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(image_id);
                    try self.emitWord(coord_id);
                    try self.emitWord(64); // Image Operands Mask: Sample (bit 6)
                    try self.emitWord(sample_id);
                } else {
                    try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.ImageRead)));
                    try self.emitWord(result_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(image_id);
                    try self.emitWord(coord_id);
                }
            },
            .image_write => {
                const image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                if (resolved.operands.len >= 4) {
                    // MS image: imageStore(image, coord, sample_index, value)
                    // OpImageWrite image coordinate texel [ImageOperands Sample]
                    const sample_id = self.operandId(resolved, 2);
                    const value_id = self.operandId(resolved, 3);
                    try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.ImageWrite)));
                    try self.emitWord(image_id);
                    try self.emitWord(coord_id);
                    try self.emitWord(value_id);
                    try self.emitWord(64); // Image Operands Mask: Sample (bit 6)
                    try self.emitWord(sample_id);
                } else {
                    const value_id = self.operandId(resolved, 2);
                    try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.ImageWrite)));
                    try self.emitWord(image_id);
                    try self.emitWord(coord_id);
                    try self.emitWord(value_id);
                }
            },
            .image_texel_pointer => {
                // OpImageTexelPointer: produces a pointer to the texel
                // Result type must be OpTypePointer(image_storage_class, texel_type)
                const result_type_id = try self.ensurePointerType(inst.ty, .image);
                const result_id = resolved.result_id orelse return;
                const image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                const sample_id = try self.emitIntConstant(0); // sample = 0
                try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.ImageTexelPointer)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(image_id);
                try self.emitWord(coord_id);
                try self.emitWord(sample_id);
                // Register as pointer in UniformConstant storage class
                try self.ptr_storage_class.put(self.alloc, result_id, .image);
            },
            .atomic_iadd => {
                try self.emitAtomicOp(resolved, spirv.Op.AtomicIAdd);
            },
            .atomic_isub => {
                try self.emitAtomicOp(resolved, spirv.Op.AtomicISub);
            },
            .atomic_smin => {
                try self.emitAtomicOp(resolved, spirv.Op.AtomicSMin);
            },
            .atomic_umin => {
                try self.emitAtomicOp(resolved, spirv.Op.AtomicUMin);
            },
            .atomic_smax => {
                try self.emitAtomicOp(resolved, spirv.Op.AtomicSMax);
            },
            .atomic_umax => {
                try self.emitAtomicOp(resolved, spirv.Op.AtomicUMax);
            },
            .atomic_and => {
                try self.emitAtomicOp(resolved, spirv.Op.AtomicAnd);
            },
            .atomic_or => {
                try self.emitAtomicOp(resolved, spirv.Op.AtomicOr);
            },
            .atomic_xor => {
                try self.emitAtomicOp(resolved, spirv.Op.AtomicXor);
            },
            .atomic_exchange => {
                try self.emitAtomicOp(resolved, spirv.Op.AtomicExchange);
            },
            .atomic_fadd => {
                try self.emitAtomicOp(resolved, spirv.Op.AtomicFAddEXT);
            },
            .atomic_comp_swap => {
                // OpAtomicCompareExchange: 9 words
                // result_type, result, ptr, scope, semantics(unequal), semantics(equal), unequal_value, equal_value
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const ptr_id = self.operandId(resolved, 0);
                const comparator_id = self.operandId(resolved, 1);
                const value_id = self.operandId(resolved, 2);
                const scope_id = try self.emitIntConstant(1); // Device
                const sem_ne_id = try self.emitIntConstant(64); // Uniform
                const sem_eq_id = try self.emitIntConstant(64); // Uniform
                try self.emitWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.AtomicCompareExchange)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(ptr_id);
                try self.emitWord(scope_id);
                try self.emitWord(sem_ne_id);
                try self.emitWord(sem_eq_id);
                try self.emitWord(value_id);
                try self.emitWord(comparator_id);
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
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const a_id = self.operandId(resolved, 0);
                const b_id = self.operandId(resolved, 1);
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.OuterProduct)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(a_id);
                try self.emitWord(b_id);
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
            .fwidth => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const val_id = self.operandId(resolved, 0);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Fwidth)));
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
            .group_all => {
                // OpSubgroupAllKHR: predicate → bool (no scope needed)
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const predicate_id = self.operandId(resolved, 0);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.SubgroupAllKHR)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(predicate_id);
            },
            .group_any => {
                // OpSubgroupAnyKHR: predicate → bool (no scope needed)
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const predicate_id = self.operandId(resolved, 0);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.SubgroupAnyKHR)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(predicate_id);
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
        const raw_id = switch (inst.operands[index]) {
            .id => |id| id,
            else => @panic("operandId: expected id operand"),
        };
        return self.constant_alias.get(raw_id) orelse raw_id;
    }

    fn operandInt(self: *Codegen, inst: ir.Instruction, index: usize) u32 {
        _ = self;
        return switch (inst.operands[index]) {
            .literal_int => |v| v,
            else => @panic("operandInt: expected literal_int operand"),
        };
    }

    fn operandValue(self: *Codegen, op: ir.Instruction.Operand) u32 {
        return switch (op) {
            .id => |v| self.constant_alias.get(v) orelse v,
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

    const result = try generate(alloc, &module, .fragment, .@"1.5", 450, false);
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

    const result = try generate(alloc, &module, .fragment, .@"1.5", 450, false);
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
    const result = try generate(alloc, &module, .fragment, .@"1.5", 450, false);
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
    const result = try generate(alloc, &module, .fragment, .@"1.5", 450, false);
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
    const result = try generate(alloc, &module, .fragment, .@"1.5", 450, false);
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