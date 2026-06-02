// SPDX-License-Identifier: MIT OR Apache-2.0
//! SPIR-V reflection — extract shader resource information from SPIR-V binary.
const std = @import("std");
const spirv = @import("spirv.zig");
const compact_ids = @import("compact_ids.zig");

pub const TypeKind = enum {
    unknown, scalar_int, scalar_uint, scalar_float, scalar_bool,
    vector, matrix, struct_type, array, sampler, image, sampled_image,
    uniform_buffer, storage_buffer, acceleration_structure,
};

/// SPIR-V image format qualifier (from `OpTypeImage` Format operand).
/// Mirrors the SPIR-V spec's `Image Format` enum; only meaningful for
/// `storage_images` and storage-image-like resources.
pub const ImageFormat = enum(u8) {
    unknown = 0, rgba32f, rgba16f, r32f, rgba8, rgba8_snorm,
    rg32f, rg16f, r11f_g11f_b10f, r16f, rgba16, rgb10_a2, rg16, rg8,
    r16, r8, rgba16_snorm, rg16_snorm, rg8_snorm, r16_snorm, r8_snorm,
    rgba32i, rgba16i, rgba8i, r32i, rg32i, rg16i, rg8i, r16i, r8i,
    rgba32ui, rgba16ui, rgba8ui, r32ui, rgb10_a2ui, rg32ui, rg16ui,
    rg8ui, r16ui, r8ui,

    fn fromSpv(format_op: u32) ImageFormat {
        // SPIR-V Image Format enum runs 0..39 contiguously. Cast if in range.
        if (format_op > 39) return .unknown;
        return @enumFromInt(@as(u8, @intCast(format_op)));
    }
};

pub const Member = struct {
    name: []const u8 = "",
    offset: u32 = 0,
    size: u32 = 0,
    type_id: u32 = 0,
    type_kind: TypeKind = .unknown,
};

pub const Resource = struct {
    name: []const u8 = "",
    id: u32 = 0,
    set: u32 = 0xFFFF_FFFF,
    binding: u32 = 0xFFFF_FFFF,
    location: u32 = 0xFFFF_FFFF,
    type_id: u32 = 0,
    size: u32 = 0,
    members: []const Member = &.{},

    /// Descriptor array dimension: 0 if the resource is not an array (the common
    /// case), else the fixed element count (e.g. `uniform sampler2D tex[4]` → 4).
    /// Runtime-sized resource arrays report 0 (unknown). The reported `type_id`,
    /// kind, members and `image_format` describe the ELEMENT type, not the array.
    array_size: u32 = 0,

    // ── Image-specific (populated only for storage_images / subpass_inputs / separate_images / sampled_images) ──
    /// Image format qualifier (e.g. `.rgba8`) for storage images. `null` otherwise.
    image_format: ?ImageFormat = null,

    // ── Specialization-constant-specific (populated only for `specialization_constants`) ──
    /// `SpecId` decoration value. `0xFFFF_FFFF` if not a spec constant.
    spec_id: u32 = 0xFFFF_FFFF,
    /// Raw 32-bit operand from `OpSpecConstant`. Consumer reinterprets per type
    /// (int / uint / float bitcast / bool 0-or-1).
    default_value_u32: u32 = 0,
};

pub const EntryPoint = struct {
    name: []const u8 = "",
    stage: Stage = .unknown,
};

pub const Stage = enum { unknown, vertex, fragment, compute, geometry, tessellation_control, tessellation_evaluation };

pub const ShaderResources = struct {
    uniform_buffers: []const Resource = &.{},
    storage_buffers: []const Resource = &.{},
    sampled_images: []const Resource = &.{},
    separate_images: []const Resource = &.{},
    separate_samplers: []const Resource = &.{},
    storage_images: []const Resource = &.{},
    inputs: []const Resource = &.{},
    outputs: []const Resource = &.{},
    push_constants: []const Resource = &.{},
    specialization_constants: []const Resource = &.{},
    subpass_inputs: []const Resource = &.{},
    acceleration_structures: []const Resource = &.{},
    entry_points: []const EntryPoint = &.{},

    pub fn deinit(self: *ShaderResources, alloc: std.mem.Allocator) void {
        inline for (std.meta.fields(ShaderResources)) |field| {
            if (field.type == []const Resource) {
                const slice: []const Resource = @field(self, field.name);
                for (slice) |*res| {
                    if (res.name.len > 0) alloc.free(res.name);
                    if (res.members.len > 0) {
                        for (res.members) |*m| {
                            if (m.name.len > 0) alloc.free(m.name);
                        }
                        alloc.free(res.members);
                    }
                }
                if (slice.len > 0) alloc.free(slice);
            } else if (field.type == []const EntryPoint) {
                const slice: []const EntryPoint = @field(self, field.name);
                for (slice) |*ep| {
                    if (ep.name.len > 0) alloc.free(ep.name);
                }
                if (slice.len > 0) alloc.free(slice);
            }
        }
    }
};

// Internal: decoration info
const Deco = struct {
    set: u32 = 0xFFFF_FFFF,
    binding: u32 = 0xFFFF_FFFF,
    location: u32 = 0xFFFF_FFFF,
    spec_id: u32 = 0xFFFF_FFFF,
    is_block: bool = false,
    is_buffer_block: bool = false,
};

// Internal: type info
const TInfo = struct {
    kind: TypeKind = .unknown,
    component_count: u32 = 1,
    element_type_id: u32 = 0,
    pointee_type_id: u32 = 0,
    member_type_ids: []const u32 = &.{},
    byte_size: u32 = 0,
    /// For `.array`: the OpConstant id giving the (fixed) element count, 0 if runtime.
    array_len_id: u32 = 0,

    // Image-specific (only set when kind == .image, from OpTypeImage operands).
    /// Image dimensionality per SPIR-V `Dim` enum: 1=1D, 2=2D, 3=3D, 4=Cube, 5=Rect, 6=SubpassData, 7=Buffer.
    image_dim: u32 = 0,
    /// `Sampled` operand: 0=unknown, 1=sampled image, 2=storage image.
    image_sampled: u32 = 0,
    /// Image format qualifier from the `Format` operand.
    image_format: ImageFormat = .unknown,
};

// Pack (struct_id, member_index) into a single u64 key
inline fn memberKey(struct_id: u32, member: u32) u64 {
    return @as(u64, struct_id) << 32 | @as(u64, member);
}

pub fn reflect(alloc: std.mem.Allocator, spirv_words: []const u32) !ShaderResources {
    if (spirv_words.len < 5) return error.InvalidSPIRV;
    if (spirv_words[0] != 0x07230203) return error.InvalidSPIRV;

    // Collection maps
    var names = std.AutoHashMap(u32, []const u8).init(alloc);
    defer { var it = names.iterator(); while (it.next()) |e| alloc.free(e.value_ptr.*); names.deinit(); }
    var mnames = std.AutoHashMap(u64, []const u8).init(alloc); // key = memberKey(struct_id, idx)
    defer { var it = mnames.iterator(); while (it.next()) |e| alloc.free(e.value_ptr.*); mnames.deinit(); }
    var decos = std.AutoHashMap(u32, Deco).init(alloc);
    defer decos.deinit();
    var types = std.AutoHashMap(u32, TInfo).init(alloc);
    defer types.deinit();
    var moffs = std.AutoHashMap(u64, u32).init(alloc); // key = memberKey(struct_id, idx)
    defer moffs.deinit();
    var const_u32 = std.AutoHashMap(u32, u32).init(alloc); // OpConstant id → 32-bit value (for array lengths)
    defer const_u32.deinit();

    var entry_points = std.ArrayList(EntryPoint).initCapacity(alloc, 4) catch return ShaderResources{};
    defer entry_points.deinit(alloc);
    const VarInfo = struct { id: u32, type_id: u32, sc: u32 };
    var variables = std.ArrayList(VarInfo).initCapacity(alloc, 64) catch return ShaderResources{};
    defer variables.deinit(alloc);
    var spec_consts = std.ArrayList(struct { id: u32, type_id: u32, default_value_u32: u32 }).initCapacity(alloc, 8) catch return ShaderResources{};
    defer spec_consts.deinit(alloc);

    // Walk instructions
    var pos: u32 = 5;
    while (pos < spirv_words.len) {
        const wc: u32 = spirv_words[pos] >> 16;
        const op: u16 = @truncate(spirv_words[pos] & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > spirv_words.len) break;

        switch (op) {
            5 => { // OpName
                if (wc >= 3) {
                    const name = extractStr(alloc, spirv_words[pos + 2 .. ie]) catch "";
                    try names.put(spirv_words[pos + 1], name);
                }
            },
            6 => { // OpMemberName
                if (wc >= 4) {
                    const name = extractStr(alloc, spirv_words[pos + 3 .. ie]) catch "";
                    try mnames.put(memberKey(spirv_words[pos + 1], spirv_words[pos + 2]), name);
                }
            },
            15 => { // OpEntryPoint
                if (wc >= 4) {
                    const stage: Stage = switch (spirv_words[pos + 1]) {
                        0 => .vertex, 4 => .fragment, 5 => .compute,
                        3 => .geometry, 1 => .tessellation_control, 2 => .tessellation_evaluation,
                        else => .unknown,
                    };
                    const name = extractStr(alloc, spirv_words[pos + 3 .. ie]) catch "";
                    try entry_points.append(alloc, .{ .name = name, .stage = stage });
                }
            },
            71 => { // OpDecorate
                if (wc >= 3) {
                    const target = spirv_words[pos + 1];
                    const d = spirv_words[pos + 2];
                    const gop = try decos.getOrPut(target);
                    if (!gop.found_existing) gop.value_ptr.* = .{};
                    switch (d) {
                        34 => { if (wc >= 4) gop.value_ptr.set = spirv_words[pos + 3]; }, // DescriptorSet
                        33 => { if (wc >= 4) gop.value_ptr.binding = spirv_words[pos + 3]; }, // Binding
                        30 => { if (wc >= 4) gop.value_ptr.location = spirv_words[pos + 3]; }, // Location
                        1 => { if (wc >= 4) gop.value_ptr.spec_id = spirv_words[pos + 3]; }, // SpecId
                        2 => { gop.value_ptr.is_block = true; }, // Block
                        3 => { gop.value_ptr.is_buffer_block = true; }, // BufferBlock
                        else => {},
                    }
                }
            },
            72 => { // OpMemberDecorate
                if (wc >= 5 and spirv_words[pos + 3] == 35) { // Offset
                    try moffs.put(memberKey(spirv_words[pos + 1], spirv_words[pos + 2]), spirv_words[pos + 4]);
                }
            },
            59 => { // OpVariable
                if (wc >= 4) {
                    try variables.append(alloc, .{
                        .id = spirv_words[pos + 2],
                        .type_id = spirv_words[pos + 1],
                        .sc = spirv_words[pos + 3],
                    });
                }
            },
            // Types
            21 => { // OpTypeInt
                if (wc >= 2) {
                    var info = TInfo{ .kind = if (wc >= 4 and spirv_words[pos + 3] == 0) .scalar_uint else .scalar_int };
                    if (wc >= 3) info.byte_size = spirv_words[pos + 2] / 8;
                    try types.put(spirv_words[pos + 1], info);
                }
            },
            22 => { // OpTypeFloat
                if (wc >= 2) {
                    var info = TInfo{ .kind = .scalar_float };
                    if (wc >= 3) info.byte_size = spirv_words[pos + 2] / 8;
                    try types.put(spirv_words[pos + 1], info);
                }
            },
            23 => { // OpTypeVector
                if (wc >= 4) {
                    const ct = spirv_words[pos + 2];
                    const cnt = spirv_words[pos + 3];
                    var info = TInfo{ .kind = .vector, .component_count = cnt, .element_type_id = ct };
                    if (types.get(ct)) |t| info.byte_size = t.byte_size * cnt;
                    try types.put(spirv_words[pos + 1], info);
                }
            },
            24 => { // OpTypeMatrix
                if (wc >= 4) {
                    const ct = spirv_words[pos + 2];
                    const cols = spirv_words[pos + 3];
                    var info = TInfo{ .kind = .matrix, .component_count = cols, .element_type_id = ct };
                    if (types.get(ct)) |t| info.byte_size = t.byte_size * cols;
                    try types.put(spirv_words[pos + 1], info);
                }
            },
            25 => { // OpTypeImage = result_id sampledType dim depth arrayed ms sampled format access?
                // Words: [25|wc] result_id sampledType dim depth arrayed ms sampled format [access]
                if (wc >= 9) {
                    try types.put(spirv_words[pos + 1], .{
                        .kind = .image,
                        .element_type_id = spirv_words[pos + 2], // sampledType
                        .image_dim = spirv_words[pos + 3],
                        .image_sampled = spirv_words[pos + 7],
                        .image_format = ImageFormat.fromSpv(spirv_words[pos + 8]),
                    });
                }
            },
            26 => { // OpTypeSampler
                if (wc >= 2) try types.put(spirv_words[pos + 1], .{ .kind = .sampler });
            },
            27 => { // OpTypeSampledImage
                if (wc >= 3) try types.put(spirv_words[pos + 1], .{ .kind = .sampled_image, .element_type_id = spirv_words[pos + 2] });
            },
            28 => { // OpTypeArray %result %elemType %lengthConst
                if (wc >= 4) {
                    var info = TInfo{ .kind = .array, .element_type_id = spirv_words[pos + 2], .array_len_id = spirv_words[pos + 3] };
                    if (types.get(spirv_words[pos + 2])) |t| info.byte_size = t.byte_size;
                    try types.put(spirv_words[pos + 1], info);
                }
            },
            43 => { // OpConstant %type %result %value...  (track scalar ints for array lengths)
                if (wc >= 4) try const_u32.put(spirv_words[pos + 2], spirv_words[pos + 3]);
            },
            30 => { // OpTypeStruct
                if (wc >= 2) {
                    var sz: u32 = 0;
                    for (spirv_words[pos + 2 .. ie]) |mid| {
                        sz += if (types.get(mid)) |t| t.byte_size else 4;
                    }
                    try types.put(spirv_words[pos + 1], .{
                        .kind = .struct_type,
                        .member_type_ids = spirv_words[pos + 2 .. ie],
                        .byte_size = sz,
                    });
                }
            },
            32 => { // OpTypePointer
                if (wc >= 4) {
                    try types.put(spirv_words[pos + 1], .{ .pointee_type_id = spirv_words[pos + 3] });
                }
            },
            48, 49 => { // OpSpecConstantTrue (48), OpSpecConstantFalse (49)
                // No literal payload; default value is implied (1 or 0).
                if (wc >= 3) {
                    try spec_consts.append(alloc, .{
                        .type_id = spirv_words[pos + 1],
                        .id = spirv_words[pos + 2],
                        .default_value_u32 = if (op == 48) 1 else 0,
                    });
                }
            },
            50 => { // OpSpecConstant — typed scalar with explicit default literal
                if (wc >= 4) {
                    try spec_consts.append(alloc, .{
                        .type_id = spirv_words[pos + 1],
                        .id = spirv_words[pos + 2],
                        .default_value_u32 = spirv_words[pos + 3],
                    });
                } else if (wc >= 3) {
                    try spec_consts.append(alloc, .{
                        .type_id = spirv_words[pos + 1],
                        .id = spirv_words[pos + 2],
                        .default_value_u32 = 0,
                    });
                }
            },
            5341 => { // OpTypeAccelerationStructureKHR (extension instruction)
                if (wc >= 2) try types.put(spirv_words[pos + 1], .{ .kind = .acceleration_structure });
            },
            else => {},
        }
        pos = ie;
    }

    // Classify variables
    var ubos = std.ArrayList(Resource).initCapacity(alloc, 16) catch return ShaderResources{};
    defer ubos.deinit(alloc);
    var ssbos = std.ArrayList(Resource).initCapacity(alloc, 16) catch return ShaderResources{};
    defer ssbos.deinit(alloc);
    var sampled = std.ArrayList(Resource).initCapacity(alloc, 16) catch return ShaderResources{};
    defer sampled.deinit(alloc);
    var sep_img = std.ArrayList(Resource).initCapacity(alloc, 16) catch return ShaderResources{};
    defer sep_img.deinit(alloc);
    var sep_samp = std.ArrayList(Resource).initCapacity(alloc, 16) catch return ShaderResources{};
    defer sep_samp.deinit(alloc);
    var stor_img = std.ArrayList(Resource).initCapacity(alloc, 16) catch return ShaderResources{};
    defer stor_img.deinit(alloc);
    var subpass = std.ArrayList(Resource).initCapacity(alloc, 4) catch return ShaderResources{};
    defer subpass.deinit(alloc);
    var ins = std.ArrayList(Resource).initCapacity(alloc, 16) catch return ShaderResources{};
    defer ins.deinit(alloc);
    var outs = std.ArrayList(Resource).initCapacity(alloc, 16) catch return ShaderResources{};
    defer outs.deinit(alloc);
    var pcs = std.ArrayList(Resource).initCapacity(alloc, 16) catch return ShaderResources{};
    defer pcs.deinit(alloc);
    var accels = std.ArrayList(Resource).initCapacity(alloc, 4) catch return ShaderResources{};
    defer accels.deinit(alloc);
    var spec_list = std.ArrayList(Resource).initCapacity(alloc, 8) catch return ShaderResources{};
    defer spec_list.deinit(alloc);

    for (variables.items) |v| {
        const d = decos.get(v.id) orelse Deco{};
        const nm = names.get(v.id) orelse "";
        // Resolve through the pointer, then "de-array" a descriptor array
        // (`sampler2D tex[4]`, `Block blocks[2]`): classify by the ELEMENT type and
        // report the fixed count in `array_size`. Without this, an array of storage
        // images would mis-bucket to sampled_images via the classifier's `else`.
        var pointee = resolvePointee(&types, v.type_id);
        var array_size: u32 = 0;
        if (types.get(pointee)) |pi| {
            if (pi.kind == .array) {
                array_size = if (pi.array_len_id != 0) (const_u32.get(pi.array_len_id) orelse 0) else 0;
                pointee = pi.element_type_id;
            }
        }
        const tk = resolveKind(&types, pointee);
        const pointee_info: ?TInfo = types.get(pointee);

        // For image resources, surface the SPIR-V `Format` operand to the caller.
        const img_format: ?ImageFormat = if (pointee_info) |ti|
            (if (ti.kind == .image and ti.image_format != .unknown) ti.image_format else null)
        else
            null;

        const res = Resource{
            .name = if (nm.len > 0) alloc.dupe(u8, nm) catch "" else "",
            .id = v.id,
            .set = d.set,
            .binding = d.binding,
            .location = d.location,
            .type_id = pointee,
            .size = if (pointee_info) |t| t.byte_size else 0,
            .array_size = array_size,
            .image_format = img_format,
        };

        // Opaque resources (samplers / images / accel structs) are routed by their
        // (de-arrayed) TYPE, not the storage class — glslpp emits sampler ARRAYS
        // with the `Uniform` (2) class rather than `UniformConstant` (0), so keying
        // purely on the storage class would mis-bucket a `sampler2D tex[4]` as a UBO.
        const is_opaque = switch (tk) {
            .sampled_image, .image, .sampler, .acceleration_structure => true,
            else => false,
        };
        if (is_opaque and (v.sc == 0 or v.sc == 2)) {
            switch (tk) {
                .sampled_image => try sampled.append(alloc, res),
                .image => {
                    const ti = pointee_info orelse TInfo{};
                    if (ti.image_dim == 6) { // SubpassData
                        try subpass.append(alloc, res);
                    } else if (ti.image_sampled == 2) { // storage image
                        try stor_img.append(alloc, res);
                    } else {
                        try sep_img.append(alloc, res);
                    }
                },
                .sampler => try sep_samp.append(alloc, res),
                .acceleration_structure => try accels.append(alloc, res),
                else => unreachable,
            }
        } else switch (v.sc) {
            2 => { // Uniform (block)
                const td = decos.get(pointee) orelse Deco{};
                if (td.is_buffer_block) try ssbos.append(alloc, res) else try ubos.append(alloc, res);
            },
            12 => try ssbos.append(alloc, res), // StorageBuffer
            1 => try ins.append(alloc, res), // Input
            3 => try outs.append(alloc, res), // Output
            9 => try pcs.append(alloc, res), // PushConstant
            else => {},
        }
    }

    // Build members for buffer resources
    const buf_lists = [_]*std.ArrayList(Resource){ &ubos, &ssbos, &pcs };
    for (&buf_lists) |list| {
        for (list.items) |*res| {
            const ti = types.get(res.type_id) orelse continue;
            if (ti.member_type_ids.len == 0) continue;

            var members = std.ArrayList(Member).initCapacity(alloc, ti.member_type_ids.len) catch continue;
            for (ti.member_type_ids, 0..) |mid, i| {
                const mname = mnames.get(memberKey(res.type_id, @intCast(i))) orelse "";
                const offset = moffs.get(memberKey(res.type_id, @intCast(i))) orelse 0;
                members.appendAssumeCapacity(.{
                    .name = if (mname.len > 0) alloc.dupe(u8, mname) catch "" else "",
                    .offset = offset,
                    .type_id = mid,
                    .type_kind = resolveKind(&types, mid),
                    .size = if (types.get(mid)) |mt| mt.byte_size else 0,
                });
            }
            res.members = members.items;
        }
    }

    // Spec constants
    for (spec_consts.items) |sc| {
        const d = decos.get(sc.id) orelse Deco{};
        const nm = names.get(sc.id) orelse "";
        try spec_list.append(alloc, .{
            .name = if (nm.len > 0) alloc.dupe(u8, nm) catch "" else "",
            .id = sc.id,
            .type_id = sc.type_id,
            .location = d.spec_id, // legacy: kept for compatibility, mirrors spec_id
            .spec_id = d.spec_id,
            .default_value_u32 = sc.default_value_u32,
        });
    }

    return .{
        .uniform_buffers = ubos.toOwnedSlice(alloc) catch &.{},
        .storage_buffers = ssbos.toOwnedSlice(alloc) catch &.{},
        .sampled_images = sampled.toOwnedSlice(alloc) catch &.{},
        .separate_images = sep_img.toOwnedSlice(alloc) catch &.{},
        .separate_samplers = sep_samp.toOwnedSlice(alloc) catch &.{},
        .storage_images = stor_img.toOwnedSlice(alloc) catch &.{},
        .subpass_inputs = subpass.toOwnedSlice(alloc) catch &.{},
        .inputs = ins.toOwnedSlice(alloc) catch &.{},
        .outputs = outs.toOwnedSlice(alloc) catch &.{},
        .push_constants = pcs.toOwnedSlice(alloc) catch &.{},
        .acceleration_structures = accels.toOwnedSlice(alloc) catch &.{},
        .specialization_constants = spec_list.toOwnedSlice(alloc) catch &.{},
        .entry_points = entry_points.toOwnedSlice(alloc) catch &.{},
    };
}

fn resolvePointee(types: *const std.AutoHashMap(u32, TInfo), type_id: u32) u32 {
    const ti = types.get(type_id) orelse return type_id;
    if (ti.pointee_type_id != 0) return ti.pointee_type_id;
    return type_id;
}

fn resolveKind(types: *const std.AutoHashMap(u32, TInfo), type_id: u32) TypeKind {
    var cur = type_id;
    for (0..10) |_| {
        const ti = types.get(cur) orelse return .unknown;
        if (ti.kind != .unknown) return ti.kind;
        if (ti.pointee_type_id != 0) { cur = ti.pointee_type_id; continue; }
        return .unknown;
    }
    return .unknown;
}

fn extractStr(alloc: std.mem.Allocator, words: []const u32) ![]const u8 {
    if (words.len == 0) return try alloc.dupe(u8, "");
    const bytes = std.mem.sliceAsBytes(words);
    const end = for (bytes, 0..) |b, i| { if (b == 0) break i; } else bytes.len;
    if (end == 0) return try alloc.dupe(u8, "");
    return try alloc.dupe(u8, bytes[0..end]);
}
