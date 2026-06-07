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

    /// Human-readable SPIR-V type spelling for this member (#177 Item 2, for the
    /// JSON serializer). For scalar/vector/matrix members this is the spirv-cross
    /// spelling (`float`, `vec4`, `mat4`, ...). For a struct-typed member this is
    /// the inner struct's declared NAME (e.g. `Light`) — the JSON serializer maps
    /// it to a flat `types` map key (`_<type_id>`). Owned; freed by `freeMembers`.
    type_name: []const u8 = "",

    // ── Layout metadata (read BACK from the SPIR-V decoration table — never recomputed) ──
    /// `ArrayStride` decoration (Decoration 6) on the member's array type. 0 if
    /// the member is not an array.
    array_stride: u32 = 0,
    /// `MatrixStride` decoration (Decoration 7) on the member. 0 if not a matrix.
    matrix_stride: u32 = 0,
    /// True if the member carries `RowMajor` (Decoration 4); false for
    /// `ColMajor` (Decoration 5) or a non-matrix member.
    is_row_major: bool = false,
    /// True if the member's type is `OpTypeRuntimeArray` (an unsized tail array,
    /// e.g. `Particle particles[];`). `array_dim` is 0 in that case.
    is_runtime_array: bool = false,
    /// Fixed element count for a sized array member; 0 for runtime or non-array.
    array_dim: u32 = 0,

    // ── Nested-struct recursion (#177 Item 1) ──
    /// When the member's resolved type is a struct, this holds the INLINED inner
    /// members (recursively). `null` for non-struct members. Offsets of nested
    /// members are RELATIVE to the nested struct (matching spirv-cross). Freed
    /// recursively by `freeMembers`.
    ///
    /// Array-of-struct members ARE expanded as of #177 Item 2: a member whose
    /// type is an array whose ELEMENT is a struct (e.g. `Light lights[4];` or a
    /// runtime `Particle particles[];`) has `members` set to the ELEMENT struct's
    /// inlined members, with the array fields (`array_dim` / `is_runtime_array` /
    /// `array_stride`) describing the array itself.
    members: ?[]const Member = null,

    /// When `members != null`, the SPIR-V type id of the STRUCT those members
    /// belong to (#177 Item 2). For a directly struct-typed member this equals
    /// `type_id`; for an array-of-struct member it is the ELEMENT struct's id.
    /// The JSON serializer uses it to key the flat `types` map (`_<id>`). 0 when
    /// `members == null`.
    inner_type_id: u32 = 0,

    // ── Per-member access qualifiers (#177 Item 3) ──
    /// `Coherent` (Decoration 23) on this member (`OpMemberDecorate`).
    coherent: bool = false,
    /// `Volatile` (Decoration 21) on this member. NOTE: glslpp's own codegen
    /// never emits `Volatile` (the GLSL `volatile` qualifier is dropped at
    /// codegen), so this flag is only populated when reflecting
    /// EXTERNALLY-produced SPIR-V (e.g. glslang).
    is_volatile: bool = false,
    /// `Restrict` (Decoration 19) on this member.
    @"restrict": bool = false,
};

/// Recursively free a member slice and every nested member slice. Frees each
/// member's `name`, recurses into `member.members`, then frees the slice
/// itself — exactly once per allocation, so no double-free or leak.
fn freeMembers(alloc: std.mem.Allocator, members: []const Member) void {
    for (members) |*m| {
        if (m.name.len > 0) alloc.free(m.name);
        if (m.type_name.len > 0) alloc.free(m.type_name);
        if (m.members) |inner| freeMembers(alloc, inner);
    }
    alloc.free(members);
}

pub const Resource = struct {
    name: []const u8 = "",
    /// Human-readable SPIR-V type spelling for the JSON serializer (#177 Item 2).
    /// For buffer blocks (UBO/SSBO/push-constant) this is the block struct's
    /// declared NAME (e.g. `Scene`); the JSON serializer maps it to a flat
    /// `types` map key (`_<type_id>`). For opaque/IO resources it is the type
    /// spelling (e.g. `sampler2D`, `vec4`). Owned; freed by `deinit`.
    type_name: []const u8 = "",
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

    // ── Block-layout metadata (uniform_buffers / storage_buffers / push_constants) ──
    /// Total size of the block's fixed part, computed as the max over all members
    /// of `member.offset + member_extent`, where member_extent accounts for array
    /// length*ArrayStride and matrix column*MatrixStride padding (see
    /// `memberExtent`). This is NOT a std140/std430 recompute — every input is
    /// read from the SPIR-V decoration/type tables; it only combines them.
    /// A block whose only/last member is a runtime array is legitimately 0.
    block_size: u32 = 0,
    /// True if the resource variable carries `NonWritable` (Decoration 24),
    /// i.e. a `readonly` buffer.
    readonly: bool = false,
    /// True if the resource variable carries `NonReadable` (Decoration 25),
    /// i.e. a `writeonly` buffer.
    writeonly: bool = false,
    /// True if the resource variable carries `Coherent` (Decoration 23),
    /// i.e. a `coherent` buffer/image. (#177 Item 3)
    coherent: bool = false,
    /// True if the resource variable carries `Volatile` (Decoration 21),
    /// i.e. a `volatile` buffer/image. NOTE: glslpp's own codegen never emits
    /// `Volatile` (the GLSL `volatile` qualifier is dropped at codegen), so this
    /// flag is only ever populated when reflecting EXTERNALLY-produced SPIR-V
    /// (e.g. glslang).
    is_volatile: bool = false,
    /// True if the resource variable carries `Restrict` (Decoration 19),
    /// i.e. a `restrict` buffer/image.
    @"restrict": bool = false,
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
                    if (res.type_name.len > 0) alloc.free(res.type_name);
                    if (res.members.len > 0) freeMembers(alloc, res.members);
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
    /// `NonWritable` (24) on the variable → readonly buffer.
    nonwritable: bool = false,
    /// `NonReadable` (25) on the variable → writeonly buffer.
    nonreadable: bool = false,
    /// `Coherent` (23) on the variable → coherent buffer/image.
    coherent: bool = false,
    /// `Volatile` (21) on the variable → volatile buffer/image.
    is_volatile: bool = false,
    /// `Restrict` (19) on the variable → restrict buffer/image.
    @"restrict": bool = false,
};

// Per-member layout/access decorations, keyed by memberKey(struct_id, idx).
const MemberDeco = struct {
    matrix_stride: u32 = 0,
    is_row_major: bool = false,
    coherent: bool = false,
    is_volatile: bool = false,
    @"restrict": bool = false,
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
    /// True when this `.array` came from `OpTypeRuntimeArray` (unsized tail array).
    /// Distinguishes a genuine runtime array from a sized array whose length
    /// constant we failed to resolve.
    is_runtime: bool = false,

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
    var astrides = std.AutoHashMap(u32, u32).init(alloc); // array TYPE id → ArrayStride
    defer astrides.deinit();
    var mmat = std.AutoHashMap(u64, MemberDeco).init(alloc); // memberKey → matrix layout + access quals
    defer mmat.deinit();
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
                        24 => { gop.value_ptr.nonwritable = true; }, // NonWritable → readonly
                        25 => { gop.value_ptr.nonreadable = true; }, // NonReadable → writeonly
                        23 => { gop.value_ptr.coherent = true; }, // Coherent
                        21 => { gop.value_ptr.is_volatile = true; }, // Volatile
                        19 => { gop.value_ptr.@"restrict" = true; }, // Restrict
                        6 => { if (wc >= 4) try astrides.put(target, spirv_words[pos + 3]); }, // ArrayStride (on array TYPE id)
                        else => {},
                    }
                }
            },
            72 => { // OpMemberDecorate %struct member Decoration [operand]
                if (wc >= 4) {
                    const struct_id = spirv_words[pos + 1];
                    const member_idx = spirv_words[pos + 2];
                    const deco = spirv_words[pos + 3];
                    const mkey = memberKey(struct_id, member_idx);
                    switch (deco) {
                        35 => { if (wc >= 5) try moffs.put(mkey, spirv_words[pos + 4]); }, // Offset
                        7 => { // MatrixStride
                            if (wc >= 5) {
                                const gop = try mmat.getOrPut(mkey);
                                if (!gop.found_existing) gop.value_ptr.* = .{};
                                gop.value_ptr.matrix_stride = spirv_words[pos + 4];
                            }
                        },
                        4 => { // RowMajor
                            const gop = try mmat.getOrPut(mkey);
                            if (!gop.found_existing) gop.value_ptr.* = .{};
                            gop.value_ptr.is_row_major = true;
                        },
                        5 => { // ColMajor
                            const gop = try mmat.getOrPut(mkey);
                            if (!gop.found_existing) gop.value_ptr.* = .{};
                            gop.value_ptr.is_row_major = false;
                        },
                        23 => { // Coherent
                            const gop = try mmat.getOrPut(mkey);
                            if (!gop.found_existing) gop.value_ptr.* = .{};
                            gop.value_ptr.coherent = true;
                        },
                        21 => { // Volatile
                            const gop = try mmat.getOrPut(mkey);
                            if (!gop.found_existing) gop.value_ptr.* = .{};
                            gop.value_ptr.is_volatile = true;
                        },
                        19 => { // Restrict
                            const gop = try mmat.getOrPut(mkey);
                            if (!gop.found_existing) gop.value_ptr.* = .{};
                            gop.value_ptr.@"restrict" = true;
                        },
                        else => {},
                    }
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
            29 => { // OpTypeRuntimeArray %result %elemType  (unsized tail array)
                if (wc >= 3) {
                    // Mirror OpTypeArray but with no length constant and runtime flag.
                    // byte_size stays 0: the runtime part contributes nothing to the
                    // block's fixed size.
                    try types.put(spirv_words[pos + 1], .{
                        .kind = .array,
                        .element_type_id = spirv_words[pos + 2],
                        .array_len_id = 0,
                        .is_runtime = true,
                    });
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

        // `type_name` (#177 Item 2): for a buffer block (struct pointee) the
        // block struct's declared OpName (mapped to `_<id>` by the JSON
        // serializer); otherwise the spirv-cross type spelling (sampler2D /
        // vec4 / ...).
        const res_type_name: []const u8 = if (tk == .struct_type)
            (if (names.get(pointee)) |sn| (alloc.dupe(u8, sn) catch "") else "")
        else
            spvTypeName(alloc, &types, pointee);

        const res = Resource{
            .name = if (nm.len > 0) alloc.dupe(u8, nm) catch "" else "",
            .type_name = res_type_name,
            .id = v.id,
            .set = d.set,
            .binding = d.binding,
            .location = d.location,
            .type_id = pointee,
            .size = if (pointee_info) |t| t.byte_size else 0,
            .array_size = array_size,
            .image_format = img_format,
            // readonly/writeonly come from NonWritable/NonReadable on the VARIABLE.
            .readonly = d.nonwritable,
            .writeonly = d.nonreadable,
            // coherent/volatile/restrict come from Coherent/Volatile/Restrict on
            // the VARIABLE (how glslpp emits them, like readonly/writeonly).
            .coherent = d.coherent,
            .is_volatile = d.is_volatile,
            .@"restrict" = d.@"restrict",
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

            const ctx = BuildCtx{
                .alloc = alloc,
                .types = &types,
                .names = &names,
                .mnames = &mnames,
                .moffs = &moffs,
                .astrides = &astrides,
                .mmat = &mmat,
                .const_u32 = &const_u32,
            };
            var visited = [_]u32{0} ** MAX_STRUCT_DEPTH;
            res.members = buildMembers(ctx, res.type_id, &visited, 0) catch continue;

            // block_size = max over all members of (offset + member_extent).
            // Computed from member offsets + per-member extents, NOT a recompute of
            // the std140/std430 rules: every input (offset, ArrayStride,
            // MatrixStride, array length, matrix column count) is read from the
            // SPIR-V decoration/type tables. The extent accounts for array
            // length*stride and matrix column*stride padding, which `member.size`
            // (the array ELEMENT byte_size, or colvec*cols for a matrix) does not.
            // A trailing runtime array contributes its offset only (extent 0), so a
            // runtime-only / writeonly block legitimately reports 0.
            //
            // `max` (rather than "last declared member") is robust against
            // out-of-declaration-order members; member offsets are authoritative.
            var bsz: u32 = 0;
            for (res.members, ti.member_type_ids) |m, mid| {
                const end = m.offset + memberExtent(&types, &astrides, &const_u32, m, mid);
                if (end > bsz) bsz = end;
            }
            res.block_size = bsz;
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

// ── #177 Item 2: JSON serialization matching spirv-cross --reflect ──────────

/// Serialize a `ShaderResources` to a JSON document mirroring the schema emitted
/// by `spirv-cross <file>.spv --reflect`. Opt-in (additive — codegen and the
/// Zig-struct reflection API are unchanged). Caller owns the returned slice and
/// must free it with `alloc.free`.
///
/// Schema mirrored (only the fields glslpp models): top-level `entryPoints`,
/// `types` (flat map keyed `_<id>`), `ubos`, `ssbos`, `push_constants`,
/// `textures` (= sampled_images), `images` (= storage_images),
/// `separate_images`, `separate_samplers`, `subpass_inputs`,
/// `acceleration_structures`, `inputs`, `outputs`, and `specialization_constants`
/// (glslpp-specific superset). Empty sections are omitted, matching spirv-cross.
///
/// Struct types are emitted ONCE in `types`; resources and struct-typed members
/// reference them by their `_<id>` key (the flat-map representation chosen for
/// #177 Item 1's inlined Zig structs). Scalar/vector/matrix/sampler members
/// carry their spirv-cross spelling in `type` (`float`/`vec4`/`mat4`/...).
pub fn toJson(alloc: std.mem.Allocator, res: *const ShaderResources) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(alloc);
    const w = JsonWriter{ .alloc = alloc, .buf = &buf };

    try w.raw("{\n");
    var first_section = true;

    // entryPoints (always present)
    {
        try w.sectionHeader(&first_section, "entryPoints");
        try w.raw("[");
        for (res.entry_points, 0..) |ep, i| {
            if (i != 0) try w.raw(",");
            try w.raw("\n    {\n      \"name\" : ");
            try w.jsonString(ep.name);
            try w.raw(",\n      \"mode\" : ");
            try w.jsonString(stageMode(ep.stage));
            try w.raw("\n    }");
        }
        if (res.entry_points.len != 0) try w.raw("\n  ");
        try w.raw("]");
    }

    // types map — collect every distinct struct type referenced by any buffer.
    {
        var collected = std.ArrayList(StructType){};
        defer collected.deinit(alloc);
        for (res.uniform_buffers) |r| try collectStructs(alloc, &collected, r.type_id, r.type_name, r.members);
        for (res.storage_buffers) |r| try collectStructs(alloc, &collected, r.type_id, r.type_name, r.members);
        for (res.push_constants) |r| try collectStructs(alloc, &collected, r.type_id, r.type_name, r.members);

        if (collected.items.len != 0) {
            try w.sectionHeader(&first_section, "types");
            try w.raw("{");
            for (collected.items, 0..) |st, i| {
                if (i != 0) try w.raw(",");
                try w.raw("\n    \"_");
                try w.int(st.id);
                try w.raw("\" : {\n      \"name\" : ");
                try w.jsonString(st.name);
                try w.raw(",\n      \"members\" : ");
                try w.members(st.members, 3);
                try w.raw("\n    }");
            }
            try w.raw("\n  }");
        }
    }

    // ubos / ssbos / push_constants (block resources with type/name/block_size)
    try w.blockSection(&first_section, "ubos", res.uniform_buffers, true);
    try w.blockSection(&first_section, "ssbos", res.storage_buffers, true);
    try w.blockSection(&first_section, "push_constants", res.push_constants, false);

    // opaque resources keyed by set/binding
    try w.bindingSection(&first_section, "textures", res.sampled_images);
    try w.bindingSection(&first_section, "images", res.storage_images);
    try w.bindingSection(&first_section, "separate_images", res.separate_images);
    try w.bindingSection(&first_section, "separate_samplers", res.separate_samplers);
    try w.bindingSection(&first_section, "subpass_inputs", res.subpass_inputs);
    try w.bindingSection(&first_section, "acceleration_structures", res.acceleration_structures);

    // stage IO keyed by location
    try w.locationSection(&first_section, "inputs", res.inputs);
    try w.locationSection(&first_section, "outputs", res.outputs);

    // specialization constants (glslpp superset; spirv-cross emits a similar list)
    if (res.specialization_constants.len != 0) {
        try w.sectionHeader(&first_section, "specialization_constants");
        try w.raw("[");
        for (res.specialization_constants, 0..) |sc, i| {
            if (i != 0) try w.raw(",");
            try w.raw("\n    {\n      \"name\" : ");
            try w.jsonString(sc.name);
            try w.raw(",\n      \"id\" : ");
            try w.int(sc.spec_id);
            try w.raw(",\n      \"default_value\" : ");
            try w.int(sc.default_value_u32);
            try w.raw("\n    }");
        }
        try w.raw("\n  ]");
    }

    try w.raw("\n}");
    return buf.toOwnedSlice(alloc);
}

fn stageMode(s: Stage) []const u8 {
    return switch (s) {
        .vertex => "vert",
        .fragment => "frag",
        .compute => "comp",
        .geometry => "geom",
        .tessellation_control => "tesc",
        .tessellation_evaluation => "tese",
        .unknown => "unknown",
    };
}

/// A struct type entry for the flat `types` map.
const StructType = struct { id: u32, name: []const u8, members: []const Member };

/// Recursively collect distinct struct types (deduped by id) referenced by a
/// member tree, so they can be emitted once in the flat `types` map. `id` is the
/// struct's SPIR-V type id, `name` its declared name, `members` its inlined
/// members.
fn collectStructs(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(StructType),
    id: u32,
    name: []const u8,
    members: []const Member,
) !void {
    for (out.items) |e| if (e.id == id) return; // already collected
    try out.append(alloc, .{ .id = id, .name = name, .members = members });
    for (members) |m| {
        if (m.members) |inner| {
            try collectStructs(alloc, out, m.inner_type_id, m.type_name, inner);
        }
    }
}

/// Minimal JSON writer with correct string escaping. spirv-cross pretty-prints
/// with 4-space-ish indentation; we approximate its layout closely (shape and
/// values are what consumers parse — whitespace is not significant).
const JsonWriter = struct {
    alloc: std.mem.Allocator,
    buf: *std.ArrayList(u8),

    fn raw(self: JsonWriter, s: []const u8) !void {
        try self.buf.appendSlice(self.alloc, s);
    }

    fn int(self: JsonWriter, v: anytype) !void {
        var tmp: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return error.OutOfMemory;
        try self.buf.appendSlice(self.alloc, s);
    }

    /// Emit a JSON string literal with proper escaping of control chars,
    /// quotes and backslashes.
    fn jsonString(self: JsonWriter, s: []const u8) !void {
        try self.buf.append(self.alloc, '"');
        for (s) |c| {
            switch (c) {
                '"' => try self.buf.appendSlice(self.alloc, "\\\""),
                '\\' => try self.buf.appendSlice(self.alloc, "\\\\"),
                '\n' => try self.buf.appendSlice(self.alloc, "\\n"),
                '\r' => try self.buf.appendSlice(self.alloc, "\\r"),
                '\t' => try self.buf.appendSlice(self.alloc, "\\t"),
                0x08 => try self.buf.appendSlice(self.alloc, "\\b"),
                0x0C => try self.buf.appendSlice(self.alloc, "\\f"),
                else => if (c < 0x20) {
                    var tmp: [8]u8 = undefined;
                    const e = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch return error.OutOfMemory;
                    try self.buf.appendSlice(self.alloc, e);
                } else {
                    try self.buf.append(self.alloc, c);
                },
            }
        }
        try self.buf.append(self.alloc, '"');
    }

    fn sectionHeader(self: JsonWriter, first: *bool, key: []const u8) !void {
        if (!first.*) try self.raw(",\n");
        first.* = false;
        try self.raw("  ");
        try self.jsonString(key);
        try self.raw(" : ");
    }

    /// Emit a member array (used by the `types` map). `depth` controls indent.
    fn members(self: JsonWriter, ms: []const Member, depth: usize) !void {
        try self.raw("[");
        for (ms, 0..) |m, i| {
            if (i != 0) try self.raw(",");
            try self.raw("\n");
            try self.indent(depth + 1);
            try self.raw("{\n");
            try self.indent(depth + 2);
            try self.raw("\"name\" : ");
            try self.jsonString(m.name);
            try self.raw(",\n");
            try self.indent(depth + 2);
            try self.raw("\"type\" : ");
            // struct-typed members reference the flat `types` map by `_<id>`.
            if (m.members != null) {
                try self.raw("\"_");
                try self.int(m.inner_type_id);
                try self.raw("\"");
            } else {
                try self.jsonString(m.type_name);
            }
            // array fields (only for array members)
            if (m.is_runtime_array or m.array_dim != 0) {
                try self.raw(",\n");
                try self.indent(depth + 2);
                try self.raw("\"array\" : [ ");
                try self.int(if (m.is_runtime_array) @as(u32, 0) else m.array_dim);
                try self.raw(" ],\n");
                try self.indent(depth + 2);
                try self.raw("\"array_size_is_literal\" : [ true ]");
            }
            // matrix_stride (matrices only)
            if (m.matrix_stride != 0) {
                try self.raw(",\n");
                try self.indent(depth + 2);
                try self.raw("\"matrix_stride\" : ");
                try self.int(m.matrix_stride);
            }
            try self.raw(",\n");
            try self.indent(depth + 2);
            try self.raw("\"offset\" : ");
            try self.int(m.offset);
            // array_stride (arrays only)
            if (m.array_stride != 0) {
                try self.raw(",\n");
                try self.indent(depth + 2);
                try self.raw("\"array_stride\" : ");
                try self.int(m.array_stride);
            }
            // access qualifiers (#177 Item 3) where present
            if (m.coherent) try self.boolField(depth + 2, "coherent");
            if (m.is_volatile) try self.boolField(depth + 2, "volatile");
            if (m.@"restrict") try self.boolField(depth + 2, "restrict");
            try self.raw("\n");
            try self.indent(depth + 1);
            try self.raw("}");
        }
        try self.raw("\n");
        try self.indent(depth);
        try self.raw("]");
    }

    fn boolField(self: JsonWriter, depth: usize, key: []const u8) !void {
        try self.raw(",\n");
        try self.indent(depth);
        try self.jsonString(key);
        try self.raw(" : true");
    }

    fn indent(self: JsonWriter, depth: usize) !void {
        var n: usize = 0;
        while (n < depth) : (n += 1) try self.raw("  ");
    }

    /// ubos / ssbos / push_constants: type (`_<id>` ref), name, block_size,
    /// and (when `with_binding`) set + binding.
    fn blockSection(self: JsonWriter, first: *bool, key: []const u8, list: []const Resource, with_binding: bool) !void {
        if (list.len == 0) return;
        try self.sectionHeader(first, key);
        try self.raw("[");
        for (list, 0..) |r, i| {
            if (i != 0) try self.raw(",");
            try self.raw("\n    {\n      \"type\" : \"_");
            try self.int(r.type_id);
            try self.raw("\",\n      \"name\" : ");
            try self.jsonString(r.name);
            try self.raw(",\n      \"block_size\" : ");
            try self.int(r.block_size);
            if (with_binding) {
                try self.raw(",\n      \"set\" : ");
                try self.int(r.set);
                try self.raw(",\n      \"binding\" : ");
                try self.int(r.binding);
            }
            if (r.readonly) try self.raw(",\n      \"readonly\" : true");
            if (r.writeonly) try self.raw(",\n      \"writeonly\" : true");
            try self.raw("\n    }");
        }
        try self.raw("\n  ]");
    }

    /// textures / images / separate_* / subpass_inputs / accel: type spelling,
    /// name, set, binding.
    fn bindingSection(self: JsonWriter, first: *bool, key: []const u8, list: []const Resource) !void {
        if (list.len == 0) return;
        try self.sectionHeader(first, key);
        try self.raw("[");
        for (list, 0..) |r, i| {
            if (i != 0) try self.raw(",");
            try self.raw("\n    {\n      \"type\" : ");
            try self.jsonString(r.type_name);
            try self.raw(",\n      \"name\" : ");
            try self.jsonString(r.name);
            try self.raw(",\n      \"set\" : ");
            try self.int(r.set);
            try self.raw(",\n      \"binding\" : ");
            try self.int(r.binding);
            if (r.array_size != 0) {
                try self.raw(",\n      \"array\" : [ ");
                try self.int(r.array_size);
                try self.raw(" ]");
            }
            try self.raw("\n    }");
        }
        try self.raw("\n  ]");
    }

    /// inputs / outputs: type spelling, name, location. Built-in IO (no
    /// `Location` decoration, sentinel 0xFFFF_FFFF) is skipped to match
    /// spirv-cross, which only lists user-declared locations.
    fn locationSection(self: JsonWriter, first: *bool, key: []const u8, list: []const Resource) !void {
        var count: usize = 0;
        for (list) |r| {
            if (r.location != 0xFFFF_FFFF) count += 1;
        }
        if (count == 0) return;
        try self.sectionHeader(first, key);
        try self.raw("[");
        var emitted: usize = 0;
        for (list) |r| {
            if (r.location == 0xFFFF_FFFF) continue;
            if (emitted != 0) try self.raw(",");
            emitted += 1;
            try self.raw("\n    {\n      \"type\" : ");
            try self.jsonString(r.type_name);
            try self.raw(",\n      \"name\" : ");
            try self.jsonString(r.name);
            try self.raw(",\n      \"location\" : ");
            try self.int(r.location);
            try self.raw("\n    }");
        }
        try self.raw("\n  ]");
    }
};

/// Max nested-struct recursion depth (#177 Item 1). SPIR-V structs can't cycle
/// by value, but we guard anyway against malformed input.
const MAX_STRUCT_DEPTH = 32;

/// Read-only maps threaded into the recursive `buildMembers`.
const BuildCtx = struct {
    alloc: std.mem.Allocator,
    types: *const std.AutoHashMap(u32, TInfo),
    /// `OpName` table (result id → name). Used to recover struct type NAMES for
    /// struct-typed members so the JSON `types` map can label them (#177 Item 2).
    names: *const std.AutoHashMap(u32, []const u8),
    mnames: *const std.AutoHashMap(u64, []const u8),
    moffs: *const std.AutoHashMap(u64, u32),
    astrides: *const std.AutoHashMap(u32, u32),
    mmat: *const std.AutoHashMap(u64, MemberDeco),
    const_u32: *const std.AutoHashMap(u32, u32),
};

/// Build the member list for the struct type `struct_type_id`, recursing into
/// struct-typed members so the nested tree is INLINED into `Member.members`
/// (#177 Item 1). Nested-member offsets are relative to the nested struct, as
/// captured in the SPIR-V `OpMemberDecorate ... Offset` table (matching
/// spirv-cross). `visited` is the recursion stack of struct-type-ids used as a
/// cycle/depth guard. The returned slice is owned by the caller and freed
/// recursively by `freeMembers`.
fn buildMembers(ctx: BuildCtx, struct_type_id: u32, visited: []u32, depth: u32) ![]const Member {
    const sti = ctx.types.get(struct_type_id) orelse return &.{};
    if (sti.member_type_ids.len == 0) return &.{};

    // Cycle/depth guard: stop if we'd exceed MAX_STRUCT_DEPTH or revisit a
    // struct id already on the recursion stack.
    if (depth >= MAX_STRUCT_DEPTH) return &.{};
    for (visited[0..depth]) |seen| if (seen == struct_type_id) return &.{};
    visited[depth] = struct_type_id;

    var members = try std.ArrayList(Member).initCapacity(ctx.alloc, sti.member_type_ids.len);
    errdefer {
        for (members.items) |*m| {
            if (m.name.len > 0) ctx.alloc.free(m.name);
            if (m.type_name.len > 0) ctx.alloc.free(m.type_name);
            if (m.members) |inner| freeMembers(ctx.alloc, inner);
        }
        members.deinit(ctx.alloc);
    }

    for (sti.member_type_ids, 0..) |mid, i| {
        const mkey = memberKey(struct_type_id, @intCast(i));
        const mname = ctx.mnames.get(mkey) orelse "";
        const offset = ctx.moffs.get(mkey) orelse 0;
        const mt: ?TInfo = ctx.types.get(mid);

        // Per-member matrix layout + access qualifiers.
        var matrix_stride: u32 = 0;
        var is_row_major = false;
        var coherent = false;
        var is_volatile = false;
        var @"restrict" = false;
        if (ctx.mmat.get(mkey)) |md| {
            matrix_stride = md.matrix_stride;
            is_row_major = md.is_row_major;
            coherent = md.coherent;
            is_volatile = md.is_volatile;
            @"restrict" = md.@"restrict";
        }

        // Array layout: ArrayStride is keyed by the array TYPE id; runtime
        // detection comes from OpTypeRuntimeArray (is_runtime), NOT a zero length.
        var array_stride: u32 = 0;
        var array_dim: u32 = 0;
        var is_runtime_array = false;
        if (mt) |t| {
            if (t.kind == .array) {
                array_stride = ctx.astrides.get(mid) orelse 0;
                if (t.is_runtime) {
                    is_runtime_array = true;
                    array_dim = 0;
                } else {
                    array_dim = if (t.array_len_id != 0) (ctx.const_u32.get(t.array_len_id) orelse 0) else 0;
                }
            }
        }

        // Resolve the member's VALUE type id: for an array member this is the
        // element type id (so an array-of-struct references the element struct);
        // for a direct member it is the member type id itself.
        const value_type_id: u32 = if (mt) |t|
            (if (t.kind == .array) t.element_type_id else mid)
        else
            mid;

        // Recurse when the member's value type is a struct (directly OR as an
        // array element). Inner offsets are relative to that struct (matching
        // spirv-cross). `inner_type_id` records the struct id for the flat JSON
        // `types` map.
        var inner: ?[]const Member = null;
        var inner_type_id: u32 = 0;
        if (ctx.types.get(value_type_id)) |vt| {
            if (vt.kind == .struct_type) {
                const sub = try buildMembers(ctx, value_type_id, visited, depth + 1);
                if (sub.len > 0) {
                    inner = sub;
                    inner_type_id = value_type_id;
                }
            }
        }

        // `type_name` (#177 Item 2): for a struct value type, the struct's
        // declared OpName (mapped to `_<id>` by the JSON serializer); otherwise
        // the spirv-cross scalar/vector/matrix/sampler spelling.
        const type_name: []const u8 = if (inner != null)
            (if (ctx.names.get(value_type_id)) |sn| (ctx.alloc.dupe(u8, sn) catch "") else "")
        else
            spvTypeName(ctx.alloc, ctx.types, value_type_id);

        const dup_name = if (mname.len > 0) ctx.alloc.dupe(u8, mname) catch "" else "";
        members.appendAssumeCapacity(.{
            .name = dup_name,
            .type_name = type_name,
            .offset = offset,
            .type_id = mid,
            .type_kind = resolveKind(ctx.types, mid),
            .size = if (mt) |t| t.byte_size else 0,
            .matrix_stride = matrix_stride,
            .is_row_major = is_row_major,
            .array_stride = array_stride,
            .array_dim = array_dim,
            .is_runtime_array = is_runtime_array,
            .members = inner,
            .inner_type_id = inner_type_id,
            .coherent = coherent,
            .is_volatile = is_volatile,
            .@"restrict" = @"restrict",
        });
    }

    return members.toOwnedSlice(ctx.alloc);
}

/// Byte extent a member occupies within its block, used to derive block_size.
/// Unlike `member.size` (the array ELEMENT byte_size, or colvec*cols for a
/// matrix), this accounts for array length*stride and matrix column*stride
/// padding. All formulae verified against `spirv-cross --reflect`:
///   - sized array  → ArrayStride * outer_length  (multidim: the OUTER stride
///                    already spans the inner dims, so outer_stride*outer_count
///                    is the full extent — e.g. float md[2][3] std140:
///                    48 * 2 = 96, block_size 16+96 = 112)
///   - runtime array → 0 (the unsized tail contributes no fixed size)
///   - matrix       → MatrixStride * columns  (mat3 std140: 16 * 3 = 48)
///   - scalar/vector/struct/other → member.size (struct byte_size for nested
///     structs is a sum of member byte_sizes; sufficient for the common case —
///     a tightly-packed nested-struct TAIL can still under/over-count if the
///     struct has its own internal std140 padding; tracked as follow-up #177).
fn memberExtent(
    types: *const std.AutoHashMap(u32, TInfo),
    astrides: *const std.AutoHashMap(u32, u32),
    const_u32: *const std.AutoHashMap(u32, u32),
    m: Member,
    mid: u32,
) u32 {
    const t = types.get(mid) orelse return m.size;
    if (t.kind == .array) {
        if (t.is_runtime) return 0; // unsized tail contributes nothing fixed
        const stride = astrides.get(mid) orelse 0;
        const len = if (t.array_len_id != 0) (const_u32.get(t.array_len_id) orelse 0) else 0;
        if (stride != 0 and len != 0) return stride * len;
        return m.size;
    }
    if (t.kind == .matrix and m.matrix_stride != 0) {
        // component_count on a matrix TInfo is the column count (set at OpTypeMatrix).
        return m.matrix_stride * t.component_count;
    }
    return m.size;
}

/// Produce the spirv-cross type SPELLING for a non-struct type id (#177 Item 2).
/// Maps scalar/vector/matrix/image/sampler kinds to spirv-cross's names
/// (`float`, `int`, `uint`, `bool`, `vec4`, `ivec2`, `mat4`, `mat2x3`,
/// `sampler2D`, ...). For struct types and unknowns returns an empty string —
/// struct members are referenced via the flat `types` map by NAME, handled by
/// the caller (which has the `OpName` table). Result is owned by the caller.
fn spvTypeName(alloc: std.mem.Allocator, types: *const std.AutoHashMap(u32, TInfo), type_id: u32) []const u8 {
    const ti = types.get(type_id) orelse return alloc.dupe(u8, "") catch "";
    switch (ti.kind) {
        .scalar_float => return alloc.dupe(u8, "float") catch "",
        .scalar_int => return alloc.dupe(u8, "int") catch "",
        .scalar_uint => return alloc.dupe(u8, "uint") catch "",
        .scalar_bool => return alloc.dupe(u8, "bool") catch "",
        .vector => {
            const elem = types.get(ti.element_type_id);
            const prefix: []const u8 = if (elem) |e| switch (e.kind) {
                .scalar_float => "vec",
                .scalar_int => "ivec",
                .scalar_uint => "uvec",
                .scalar_bool => "bvec",
                else => "vec",
            } else "vec";
            return std.fmt.allocPrint(alloc, "{s}{d}", .{ prefix, ti.component_count }) catch "";
        },
        .matrix => {
            // element_type_id is the column vector; its component_count is the row count.
            // ti.component_count is the column count.
            const cols = ti.component_count;
            const rows: u32 = if (types.get(ti.element_type_id)) |col| col.component_count else cols;
            if (cols == rows) return std.fmt.allocPrint(alloc, "mat{d}", .{cols}) catch "";
            // spirv-cross spells non-square as matCxR (columns x rows).
            return std.fmt.allocPrint(alloc, "mat{d}x{d}", .{ cols, rows }) catch "";
        },
        .sampled_image => return spvSampledImageName(alloc, types, ti.element_type_id),
        .image => return spvImageName(alloc, types, type_id, false),
        .sampler => return alloc.dupe(u8, "sampler") catch "",
        .acceleration_structure => return alloc.dupe(u8, "accelerationStructure") catch "",
        else => return alloc.dupe(u8, "") catch "",
    }
}

/// Spell a sampled image (combined sampler) like spirv-cross: `sampler2D`,
/// `samplerCube`, `sampler2DArray`, `sampler2DShadow`, etc. `image_type_id` is
/// the `OpTypeImage` referenced by the `OpTypeSampledImage`.
fn spvSampledImageName(alloc: std.mem.Allocator, types: *const std.AutoHashMap(u32, TInfo), image_type_id: u32) []const u8 {
    return spvImageName(alloc, types, image_type_id, true);
}

fn spvImageName(alloc: std.mem.Allocator, types: *const std.AutoHashMap(u32, TInfo), image_type_id: u32, combined: bool) []const u8 {
    const ti = types.get(image_type_id) orelse return alloc.dupe(u8, if (combined) "sampler2D" else "image2D") catch "";
    const prefix: []const u8 = if (combined) "sampler" else "image";
    // SPIR-V `Dim` enum: 0=1D, 1=2D, 2=3D, 3=Cube, 4=Rect, 5=Buffer, 6=SubpassData.
    const dim: []const u8 = switch (ti.image_dim) {
        0 => "1D",
        1 => "2D",
        2 => "3D",
        3 => "Cube",
        4 => "Rect",
        5 => "Buffer",
        else => "2D",
    };
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, dim }) catch "";
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
