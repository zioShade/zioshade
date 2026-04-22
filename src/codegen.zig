const std = @import("std");
const ast = @import("ast.zig");
const ir = @import("ir.zig");
const spirv = @import("spirv.zig");

pub fn generate(
    alloc: std.mem.Allocator,
    module: *const ir.Module,
    stage: enum { vertex, fragment, compute, geometry },
    spirv_version: enum { @"1.0", @"1.1", @"1.2", @"1.3", @"1.4", @"1.5", @"1.6" },
) error{OutOfMemory, CodegenFailed}![]const u32 {
    var cg = Codegen{
        .alloc = alloc,
        .module = module,
        .words = std.ArrayList(u32).init(alloc),
        .next_id = 1,
        .type_cache = .empty,
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

    return cg.words.toOwnedSlice();
}

const Codegen = struct {
    alloc: std.mem.Allocator,
    module: *const ir.Module,
    words: std.ArrayList(u32),
    next_id: u32,
    type_cache: std.AutoHashMapUnmanaged(ast.Type, u32),
    glsl_std_450_id: u32,

    fn deinit(self: *Codegen) void {
        self.type_cache.deinit(self.alloc);
        self.words.deinit();
    }

    fn allocId(self: *Codegen) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn emitWord(self: *Codegen, word: u32) !void {
        try self.words.append(word);
    }

    fn emitHeader(self: *Codegen, version: anytype) !void {
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

    fn emitEntryPoint(self: *Codegen, stage: anytype) !void {
        const exec_model: spirv.ExecutionModel = switch (stage) {
            .vertex => .Vertex,
            .fragment => .Fragment,
            .compute => .GLCompute,
            .geometry => .Geometry,
        };
        const entry = self.findEntryPoint() orelse return;
        const entry_id = if (entry.result_id != 0) entry.result_id else self.allocId();
        const name = entry.name;
        const word_count: u16 = 4 + @as(u16, @intCast(std.math.divCeil(usize, name.len + 1, 4) catch unreachable));
        try self.emitWord(spirv.encodeInstructionHeader(word_count, @intFromEnum(spirv.Op.EntryPoint)));
        try self.emitWord(@intFromEnum(exec_model));
        try self.emitWord(entry_id);
        try self.emitStringLiteral(name);

        if (stage == .fragment) {
            try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.ExecutionMode)));
            try self.emitWord(entry_id);
            try self.emitWord(@intFromEnum(spirv.ExecutionMode.OriginUpperLeft));
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
        if (self.type_cache.get(ty)) |id| return id;
        const id = self.allocId();
        try self.type_cache.put(self.alloc, ty, id);
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
            .mat2, .mat3, .mat4,
            .mat2x2, .mat2x3, .mat2x4,
            .mat3x2, .mat3x3, .mat3x4,
            .mat4x2, .mat4x3, .mat4x4 => {
                const col_type = try self.ensureType(switch (ty) {
                    .mat2, .mat2x2 => ast.Type.vec2,
                    .mat2x3 => ast.Type.vec3,
                    .mat2x4 => ast.Type.vec4,
                    .mat3x2 => ast.Type.vec2,
                    .mat3, .mat3x3 => ast.Type.vec3,
                    .mat3x4 => ast.Type.vec4,
                    .mat4x2 => ast.Type.vec2,
                    .mat4x3 => ast.Type.vec3,
                    .mat4, .mat4x4 => ast.Type.vec4,
                    else => unreachable,
                });
                const num_cols = ty.numComponents() / switch (ty) {
                    .mat2, .mat2x2 => 2,
                    .mat2x3 => 3,
                    .mat2x4 => 4,
                    .mat3x2 => 2,
                    .mat3, .mat3x3 => 3,
                    .mat3x4 => 4,
                    .mat4x2 => 2,
                    .mat4x3 => 3,
                    .mat4, .mat4x4 => 4,
                    else => unreachable,
                };
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
                try self.emitWord(1); // Is multisampled
                try self.emitWord(1); // Sampled = 1 (yes)
                try self.emitWord(0); // ImageFormat = Unknown
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitWord(id);
                try self.emitWord(image_id);
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
                try self.emitWord(1);
                try self.emitWord(1);
                try self.emitWord(0);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitWord(id);
                try self.emitWord(image_id);
            },
            .named => |name| {
                const td = self.module.types.get(name) orelse return id;
                var member_ids = std.ArrayList(u32).init(self.alloc);
                defer member_ids.deinit();
                for (td.members) |member| {
                    try member_ids.append(try self.ensureType(member.ty));
                }
                const word_count: u16 = 2 + @as(u16, @intCast(member_ids.items.len));
                try self.emitWord(spirv.encodeInstructionHeader(word_count, @intFromEnum(spirv.Op.TypeStruct)));
                try self.emitWord(id);
                for (member_ids.items) |mid| {
                    try self.emitWord(mid);
                }
            },
            .array => |arr| {
                const base_id = try self.ensureType(arr.base.*);
                const const_id = try self.emitIntConstant(arr.size);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeArray)));
                try self.emitWord(id);
                try self.emitWord(base_id);
                try self.emitWord(const_id);
            },
        }
        return id;
    }

    fn ensurePointerType(self: *Codegen, base_type: ast.Type, storage_class: ir.SPIRVStorageClass) error{OutOfMemory}!u32 {
        const base_id = try self.ensureType(base_type);
        const ptr_id = self.allocId();
        try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypePointer)));
        try self.emitWord(ptr_id);
        try self.emitWord(@intFromEnum(storage_class));
        try self.emitWord(base_id);
        return ptr_id;
    }

    fn emitIntConstant(self: *Codegen, val: u32) error{OutOfMemory}!u32 {
        const int_type_id = try self.ensureType(.uint);
        const const_id = self.allocId();
        try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Constant)));
        try self.emitWord(int_type_id);
        try self.emitWord(const_id);
        try self.emitWord(val);
        return const_id;
    }

    // Stub methods — implemented in subsequent tasks
    fn emitNames(self: *Codegen) !void {
        _ = self;
    }
    fn emitDecorations(self: *Codegen) !void {
        _ = self;
    }
    fn emitTypesAndConstants(self: *Codegen) !void {
        for (self.module.globals) |global| {
            _ = try self.ensureType(global.ty);
        }
        for (self.module.functions) |func| {
            _ = try self.ensureType(func.return_type);
            for (func.params) |param| {
                _ = try self.ensureType(param.ty);
            }
        }
    }
    fn emitGlobals(self: *Codegen) !void {
        _ = self;
    }
    fn emitFunctions(self: *Codegen, stage: anytype) !void {
        _ = self;
        _ = stage;
    }
};
